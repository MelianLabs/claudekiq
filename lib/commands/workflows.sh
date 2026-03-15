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
  if [[ ${#wf_items[@]} -gt 0 ]]; then
    result_json=$(printf '%s\n' "${wf_items[@]}" | jq -s '.')
  else
    result_json="[]"
  fi

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

  # Validate agent steps have prompt or target
  local agent_step_errors
  agent_step_errors=$(jq -r '
    .steps[] | select(.type == "agent") |
    if (.prompt == null or .prompt == "") and (.target == null or .target == "") then
      "Agent step '\''\(.id)'\'': needs either '\''prompt'\'' or '\''target'\'' field"
    else empty end
  ' <<< "$wf_json" 2>/dev/null)
  while IFS= read -r err; do
    [[ -n "$err" ]] && errors+=("$err")
  done <<< "$agent_step_errors"

  # Warn on deprecated args_template usage
  local deprecated_warnings
  deprecated_warnings=$(jq -r '
    .steps[] | select(.args_template != null and .args_template != "") |
    "Step '\''\(.id)'\'': '\''args_template'\'' is deprecated, use '\''prompt'\'' instead"
  ' <<< "$wf_json" 2>/dev/null)
  while IFS= read -r warn; do
    [[ -n "$warn" ]] && cq_warn "$warn"
  done <<< "$deprecated_warnings"

  # Validate model fields against known models
  local model_errors
  model_errors=$(jq -r '.steps[] | select(.model != null and .model != "") | "\(.id):\(.model)"' <<< "$wf_json" 2>/dev/null)
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local sid="${entry%%:*}"
    local smodel="${entry#*:}"
    if ! cq_valid_model "$smodel"; then
      local known_models
      known_models=$(cq_resolve_config | jq -r '.models // [] | join(", ")')
      errors+=("Step '${sid}': unknown model '${smodel}'. Known: ${known_models}")
    fi
  done <<< "$model_errors"

  # Check step types against known types + plugins
  local type_warnings
  type_warnings=$(jq -r '.steps[].type // empty' <<< "$wf_json" | sort -u | while IFS= read -r stype; do
    [[ -z "$stype" ]] && continue
    local kind
    kind=$(cq_resolve_step_type "$stype")
    if [[ "$kind" == "convention" ]]; then
      echo "INFO: Step type '${stype}' will be treated as convention-based agent step" >&2
    fi
  done)
  while IFS= read -r warn; do
    [[ -n "$warn" ]] && errors+=("$warn")
  done <<< "$type_warnings"

  # Validate parallel steps have branches array
  local parallel_errors
  parallel_errors=$(jq -r '
    .steps[] | select(.type == "parallel") |
    if (.branches == null or (.branches | length) == 0) then
      "Parallel step '\''\(.id)'\'': requires non-empty '\''branches'\'' array"
    else empty end
  ' <<< "$wf_json" 2>/dev/null)
  while IFS= read -r err; do
    [[ -n "$err" ]] && errors+=("$err")
  done <<< "$parallel_errors"

  # Validate parallel branch definitions
  local branch_errors
  branch_errors=$(jq -r '
    .steps[] | select(.type == "parallel") | .id as $pid |
    .branches // [] | to_entries[] |
    (if .value.id == null or .value.id == "" then "Parallel step '\''\($pid)'\'' branch \(.key): missing '\''id'\''" else empty end),
    (if .value.type == null or .value.type == "" then "Parallel step '\''\($pid)'\'' branch '\''\(.value.id // .key)'\'': missing '\''type'\''" else empty end)
  ' <<< "$wf_json" 2>/dev/null)
  while IFS= read -r err; do
    [[ -n "$err" ]] && errors+=("$err")
  done <<< "$branch_errors"

  # Validate workflow steps have template field
  local workflow_errors
  workflow_errors=$(jq -r '
    .steps[] | select(.type == "workflow") |
    if (.template == null or .template == "") then
      "Workflow step '\''\(.id)'\'': requires '\''template'\'' field"
    else empty end
  ' <<< "$wf_json" 2>/dev/null)
  while IFS= read -r err; do
    [[ -n "$err" ]] && errors+=("$err")
  done <<< "$workflow_errors"

  # Check for duplicate step IDs
  local dupes
  dupes=$(jq -r '[.steps[].id] | group_by(.) | map(select(length > 1)) | .[0][0] // empty' <<< "$wf_json")
  [[ -n "$dupes" ]] && errors+=("Duplicate step ID: ${dupes}")

  # Validate agent targets (check @target references exist)
  local agent_warnings
  agent_warnings=$(_validate_agent_targets_check "$wf_json")
  while IFS= read -r warn; do
    [[ -n "$warn" ]] && errors+=("$warn")
  done <<< "$agent_warnings"

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

# Check agent targets and return warnings (non-fatal for validate)
_validate_agent_targets_check() {
  local wf_json="$1"
  local targets
  targets=$(jq -r '.steps[] | select(.type == "agent") | .target // "" | select(startswith("@")) | ltrimstr("@")' <<< "$wf_json" 2>/dev/null)
  [[ -z "$targets" ]] && return 0

  local settings_file="${CQ_PROJECT_ROOT}/.claudekiq/settings.json"
  local available_agents=""
  if [[ -f "$settings_file" ]]; then
    available_agents=$(jq -r '.agents // [] | .[].name' "$settings_file" 2>/dev/null)
  fi

  local target
  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    [[ -f "${CQ_PROJECT_ROOT}/.claude/agents/${target}.md" ]] && continue
    if [[ -n "$available_agents" ]] && echo "$available_agents" | grep -qx "$target"; then
      continue
    fi
    local mapped
    mapped=$(cq_resolve_agent_target "$target")
    if [[ "$mapped" != "$target" ]]; then
      [[ -f "${CQ_PROJECT_ROOT}/.claude/agents/${mapped}.md" ]] && continue
      if [[ -n "$available_agents" ]] && echo "$available_agents" | grep -qx "$mapped"; then
        continue
      fi
    fi
    echo "Agent '@${target}' referenced in workflow but not found (run 'cq scan' to discover agents)"
  done <<< "$targets"
}

# Convenience alias: cq validate <workflow>
cmd_validate() {
  local name="${1:?Usage: cq validate <workflow>}"
  local file
  file=$(cq_find_workflow "$name") || cq_die "Workflow not found: ${name}"
  cmd_workflows_validate "$file"
}
