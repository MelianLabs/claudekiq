#!/usr/bin/env bash
# workflows.sh — Workflow template management commands

cmd_workflows() {
  local subcmd="${1:-list}"
  shift 2>/dev/null || true

  case "$subcmd" in
    list)     cmd_workflows_list "$@" ;;
    show)     cmd_workflows_show "$@" ;;
    validate) cmd_workflows_validate "$@" ;;
    *)        cq_die "Unknown workflows subcommand: $subcmd" ;;
  esac
}

cmd_workflows_list() {
  local workflows
  workflows=$(cq_list_workflows)

  if [[ -z "$workflows" ]]; then
    if [[ "$CQ_JSON" == "true" ]]; then
      echo '[]'
    else
      echo "No workflows found."
    fi
    return
  fi

  # Read workflow data once, build both JSON and text from same data
  local -a wf_items=()
  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local file desc=""
    file=$(cq_find_workflow "$name") || continue
    local wf_json
    wf_json=$(cq_yaml_to_json "$file")
    desc=$(jq -r '.description // ""' <<< "$wf_json")
    wf_items+=("$(jq -cn --arg n "$name" --arg d "$desc" '{name:$n, description:$d}')")
  done <<< "$workflows"

  local result_json
  result_json=$(cq_json_array ${wf_items[@]+"${wf_items[@]}"})

  if [[ "$CQ_JSON" == "true" ]]; then
    jq '.' <<< "$result_json"
  else
    jq -r '.[] | "\(.name)\t\(.description)"' <<< "$result_json" | \
      while IFS=$'\t' read -r n d; do
        printf "  %-20s %s\n" "$n" "$d"
      done
  fi
}

cmd_workflows_show() {
  local name="${1:?Usage: cq workflows show <name>}"
  local file
  file=$(cq_find_workflow "$name") || cq_die "Workflow not found: ${name}"

  local wf_json
  wf_json=$(cq_yaml_to_json "$file")

  if [[ "$CQ_JSON" == "true" ]]; then
    jq '.' <<< "$wf_json"
  else
    local wf_name desc default_priority
    wf_name=$(jq -r '.name // ""' <<< "$wf_json")
    desc=$(jq -r '.description // ""' <<< "$wf_json")
    default_priority=$(jq -r '.default_priority // "normal"' <<< "$wf_json")

    echo "Workflow: ${wf_name:-$name}"
    [[ -n "$desc" ]] && echo "Description: $desc"
    echo "Priority: $default_priority"
    echo ""
    echo "Steps:"
    jq -r '.steps[] | "  \(.id)\t\(.type)\t\(.name // "")\tgate=\(.gate // "auto")"' <<< "$wf_json"
  fi
}

cmd_workflows_validate() {
  local file="${1:?Usage: cq workflows validate <file>}"
  [[ -f "$file" ]] || cq_die "File not found: ${file}"

  local wf_json errors=()
  wf_json=$(cq_yaml_to_json "$file") || cq_die "Invalid YAML: ${file}"

  # Check required fields
  local wf_name
  wf_name=$(jq -r '.name // empty' <<< "$wf_json")
  [[ -z "$wf_name" ]] && errors+=("Missing 'name' field")

  # Check steps exist and are non-empty
  local step_count
  step_count=$(jq '.steps | length' <<< "$wf_json")
  [[ "$step_count" -eq 0 ]] && errors+=("Steps must be non-empty")

  # Validate each step using a single jq call
  local step_errors
  step_errors=$(jq -r '
    .steps | to_entries[] |
    (if .value.id == null or .value.id == "" then "Step \(.key): missing '\''id'\''" else empty end),
    (if .value.type == null or .value.type == "" then "Step \(.key): missing '\''type'\''" else empty end),
    (if .value.id != null and .value.id != "" and (.value.id | test("^[a-z0-9_-]+$") | not) then
      "Step '\''\(.value.id)'\'': ID must match [a-z0-9_-]+"
    else empty end)
  ' <<< "$wf_json" 2>/dev/null)
  while IFS= read -r err; do
    [[ -n "$err" ]] && errors+=("$err")
  done <<< "$step_errors"

  # Check for duplicate step IDs
  local dupes
  dupes=$(jq -r '[.steps[].id] | group_by(.) | map(select(length > 1)) | .[0][0] // empty' <<< "$wf_json")
  [[ -n "$dupes" ]] && errors+=("Duplicate step ID: ${dupes}")

  if [[ ${#errors[@]} -gt 0 ]]; then
    if [[ "$CQ_JSON" == "true" ]]; then
      printf '%s\n' "${errors[@]}" | jq -Rcs 'split("\n") | map(select(. != "")) | {valid:false, errors:.}'
    else
      echo "Validation FAILED for ${file}:"
      printf '  - %s\n' "${errors[@]}"
    fi
    return 1
  fi

  cq_json_out '{valid:true, errors:[]}' || echo "Valid: ${file}"
}
