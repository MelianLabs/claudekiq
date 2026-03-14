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

  if [[ "$CQ_JSON" == "true" ]]; then
    local json="[]"
    local name
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      local file desc=""
      file=$(cq_find_workflow "$name") || continue
      local wf_json
      wf_json=$(cq_yaml_to_json "$file")
      desc=$(echo "$wf_json" | jq -r '.description // ""')
      json=$(echo "$json" | jq --arg n "$name" --arg d "$desc" '. + [{name:$n, description:$d}]')
    done <<< "$workflows"
    echo "$json" | jq '.'
  else
    if [[ -z "$workflows" ]]; then
      echo "No workflows found."
      return
    fi
    local name
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      local file desc=""
      file=$(cq_find_workflow "$name") || continue
      local wf_json
      wf_json=$(cq_yaml_to_json "$file")
      desc=$(echo "$wf_json" | jq -r '.description // ""')
      printf "  %-20s %s\n" "$name" "$desc"
    done <<< "$workflows"
  fi
}

cmd_workflows_show() {
  local name="${1:?Usage: cq workflows show <name>}"
  local file
  file=$(cq_find_workflow "$name") || cq_die "Workflow not found: ${name}"

  local wf_json
  wf_json=$(cq_yaml_to_json "$file")

  if [[ "$CQ_JSON" == "true" ]]; then
    echo "$wf_json" | jq '.'
  else
    local wf_name desc default_priority
    wf_name=$(echo "$wf_json" | jq -r '.name // ""')
    desc=$(echo "$wf_json" | jq -r '.description // ""')
    default_priority=$(echo "$wf_json" | jq -r '.default_priority // "normal"')

    echo "Workflow: ${wf_name:-$name}"
    [[ -n "$desc" ]] && echo "Description: $desc"
    echo "Priority: $default_priority"
    echo ""
    echo "Steps:"
    echo "$wf_json" | jq -r '.steps[] | "  \(.id)\t\(.type)\t\(.name // "")\tgate=\(.gate // "auto")"'
  fi
}

cmd_workflows_validate() {
  local file="${1:?Usage: cq workflows validate <file>}"
  [[ -f "$file" ]] || cq_die "File not found: ${file}"

  local wf_json errors=()
  wf_json=$(cq_yaml_to_json "$file") || cq_die "Invalid YAML: ${file}"

  # Check required fields
  local wf_name
  wf_name=$(echo "$wf_json" | jq -r '.name // empty')
  [[ -z "$wf_name" ]] && errors+=("Missing 'name' field")

  # Check steps exist and are non-empty
  local step_count
  step_count=$(echo "$wf_json" | jq '.steps | length')
  [[ "$step_count" -eq 0 ]] && errors+=("Steps must be non-empty")

  # Validate each step
  local i step_id step_type
  for ((i = 0; i < step_count; i++)); do
    step_id=$(echo "$wf_json" | jq -r --argjson i "$i" '.steps[$i].id // empty')
    step_type=$(echo "$wf_json" | jq -r --argjson i "$i" '.steps[$i].type // empty')

    [[ -z "$step_id" ]] && errors+=("Step $i: missing 'id'")
    [[ -z "$step_type" ]] && errors+=("Step $i: missing 'type'")

    # Validate ID format
    if [[ -n "$step_id" && ! "$step_id" =~ ^[a-z0-9_-]+$ ]]; then
      errors+=("Step '${step_id}': ID must match [a-z0-9_-]+")
    fi
  done

  # Check for duplicate step IDs
  local dupes
  dupes=$(echo "$wf_json" | jq -r '[.steps[].id] | group_by(.) | map(select(length > 1)) | .[0][0] // empty')
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

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn '{valid:true, errors:[]}'
  else
    echo "Valid: ${file}"
  fi
}
