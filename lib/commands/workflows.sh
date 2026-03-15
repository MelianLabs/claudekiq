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

  # Validate extends field if present
  local extends_name
  extends_name=$(jq -r '.extends // empty' <<< "$wf_json")
  if [[ -n "$extends_name" ]]; then
    if ! cq_find_workflow "$extends_name" >/dev/null 2>&1; then
      errors+=("Workflow extends '${extends_name}' but base workflow not found")
    fi
    # Check for circular extends
    local chain="$extends_name"
    local visited_extends=("$(jq -r '.name // empty' <<< "$wf_json")")
    local current_extends="$extends_name"
    while [[ -n "$current_extends" ]]; do
      local ce
      for ce in "${visited_extends[@]}"; do
        if [[ "$ce" == "$current_extends" ]]; then
          errors+=("Circular extends detected: ${chain}")
          current_extends=""
          break 2
        fi
      done
      visited_extends+=("$current_extends")
      local base_file
      base_file=$(cq_find_workflow "$current_extends" 2>/dev/null) || break
      local base_json
      base_json=$(cq_yaml_to_json "$base_file" 2>/dev/null) || break
      current_extends=$(jq -r '.extends // empty' <<< "$base_json")
      [[ -n "$current_extends" ]] && chain="${chain} -> ${current_extends}"
    done
  fi

  # Validate override IDs exist in base workflow
  local override_keys
  override_keys=$(jq -r '.override // {} | keys[]' <<< "$wf_json" 2>/dev/null)
  if [[ -n "$override_keys" && -n "$extends_name" ]]; then
    local base_file base_json base_step_ids
    base_file=$(cq_find_workflow "$extends_name" 2>/dev/null)
    if [[ -n "$base_file" ]]; then
      base_json=$(cq_yaml_to_json "$base_file" 2>/dev/null)
      if [[ -n "$base_json" ]]; then
        base_step_ids=$(jq -r '.steps[].id' <<< "$base_json" 2>/dev/null)
        local ok
        while IFS= read -r ok; do
          [[ -z "$ok" ]] && continue
          if ! echo "$base_step_ids" | grep -qx "$ok"; then
            cq_warn "Override step '${ok}' not found in base workflow '${extends_name}'"
          fi
        done <<< "$override_keys"
      fi
    fi
  fi

  # Validate remove IDs exist in base workflow
  local remove_ids
  remove_ids=$(jq -r '.remove // [] | .[]' <<< "$wf_json" 2>/dev/null)
  if [[ -n "$remove_ids" && -n "$extends_name" ]]; then
    local base_file base_json base_step_ids
    base_file=$(cq_find_workflow "$extends_name" 2>/dev/null)
    if [[ -n "$base_file" ]]; then
      base_json=$(cq_yaml_to_json "$base_file" 2>/dev/null)
      if [[ -n "$base_json" ]]; then
        base_step_ids=$(jq -r '.steps[].id' <<< "$base_json" 2>/dev/null)
        local ri
        while IFS= read -r ri; do
          [[ -z "$ri" ]] && continue
          if ! echo "$base_step_ids" | grep -qx "$ri"; then
            cq_warn "Remove step '${ri}' not found in base workflow '${extends_name}'"
          fi
        done <<< "$remove_ids"
      fi
    fi
  fi

  # Circular routing detection
  local validation_warnings
  validation_warnings=$(_validate_circular_routing "$wf_json")
  while IFS= read -r w; do
    [[ -n "$w" ]] && cq_warn "$w"
  done <<< "$validation_warnings"

  # Missing context variable detection
  validation_warnings=$(_validate_missing_context_vars "$wf_json")
  while IFS= read -r w; do
    [[ -n "$w" ]] && cq_warn "$w"
  done <<< "$validation_warnings"

  # Unreachable step detection
  validation_warnings=$(_validate_unreachable_steps "$wf_json")
  while IFS= read -r w; do
    [[ -n "$w" ]] && cq_warn "$w"
  done <<< "$validation_warnings"

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

# Circular routing detection: find cycles that don't pass through a gate
# Outputs warning lines to stdout
_validate_circular_routing() {
  local wf_json="$1"

  # Build adjacency list from routing fields: src:dst:gate
  local edges
  edges=$(jq -r '
    .steps[] |
    .id as $id | .gate as $gate |
    (
      (if .on_pass then "\($id):\(.on_pass):\($gate // "auto")" else empty end),
      (if .on_fail then "\($id):\(.on_fail):\($gate // "auto")" else empty end),
      (if .on_timeout then "\($id):\(.on_timeout):\($gate // "auto")" else empty end),
      (if .next then
        if (.next | type) == "string" then "\($id):\(.next):\($gate // "auto")"
        elif (.next | type) == "array" then
          (.next[] | if .goto then "\($id):\(.goto):\($gate // "auto")" elif .default then "\($id):\(.default):\($gate // "auto")" else empty end)
        else empty end
      else empty end)
    )
  ' <<< "$wf_json" 2>/dev/null)

  [[ -z "$edges" ]] && return 0

  local step_ids
  step_ids=$(jq -r '.steps[].id' <<< "$wf_json")

  local step_id
  while IFS= read -r step_id; do
    [[ -z "$step_id" ]] && continue
    local found_cycle=false passes_gate=false

    # BFS to find if step_id can reach itself
    local queue="$step_id" seen=""
    while [[ -n "$queue" ]]; do
      local current="${queue%% *}"
      queue="${queue#"$current"}"
      queue="${queue# }"

      local succ
      while IFS= read -r succ; do
        [[ -z "$succ" ]] && continue
        local src="${succ%%:*}"
        local rest="${succ#*:}"
        local dst="${rest%%:*}"
        local gate="${rest#*:}"

        [[ "$src" != "$current" ]] && continue

        if [[ "$dst" == "$step_id" ]]; then
          found_cycle=true
          if [[ "$gate" == "review" || "$gate" == "human" ]]; then
            passes_gate=true
          fi
          continue
        fi

        # Skip if already seen
        case " $seen " in
          *" $dst "*) continue ;;
        esac
        seen="$seen $dst"
        if [[ "$gate" == "review" || "$gate" == "human" ]]; then
          passes_gate=true
        fi
        queue="$queue $dst"
      done <<< "$edges"
    done

    if [[ "$found_cycle" == "true" && "$passes_gate" == "false" ]]; then
      echo "Circular routing detected at step '${step_id}' — may cause infinite loop (no gate in cycle)"
    fi
  done <<< "$step_ids"
}

# Missing context variable detection: find {{var}} references not in defaults/params
# Outputs warning lines to stdout
_validate_missing_context_vars() {
  local wf_json="$1"

  local refs
  refs=$(jq -r '
    .steps[] | select(.type == "bash") | .target // "" |
    [scan("\\{\\{([^}]+)\\}\\}") | .[0]] | .[]
  ' <<< "$wf_json" 2>/dev/null)
  [[ -z "$refs" ]] && return 0

  local declared
  declared=$(jq -r '
    ((.defaults // {} | keys[]),
     (.params // {} | keys[]))
  ' <<< "$wf_json" 2>/dev/null)

  local ref
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    ref=$(echo "$ref" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ "$ref" == *"|"* || "$ref" == *"["* ]] && continue
    local top_key="${ref%%.*}"
    if [[ -n "$declared" ]] && echo "$declared" | grep -qx "$top_key"; then
      continue
    fi
    echo "Context variable '{{${ref}}}' referenced in bash step but not declared in defaults or params (may be set at runtime)"
  done <<< "$refs"
}

# Unreachable step detection: find steps not reachable from the first step
# Outputs warning lines to stdout
_validate_unreachable_steps() {
  local wf_json="$1"

  local step_ids
  step_ids=$(jq -r '.steps[].id' <<< "$wf_json")
  [[ -z "$step_ids" ]] && return 0

  local first_step
  first_step=$(jq -r '.steps[0].id' <<< "$wf_json")

  # Build reachable set via BFS from first step
  local reachable="$first_step"
  local queue="$first_step"

  while [[ -n "$queue" ]]; do
    local current="${queue%% *}"
    queue="${queue#"$current"}"
    queue="${queue# }"

    # Get successors via jq: explicit routes + implicit next (only if no explicit routing)
    local successors
    successors=$(jq -r --arg id "$current" '
      .steps as $steps |
      ($steps | to_entries[] | select(.value.id == $id) | .key) as $idx |
      $steps[$idx] as $step |
      (
        ($step.on_pass // empty),
        ($step.on_fail // empty),
        ($step.on_timeout // empty),
        (if $step.next then
          if ($step.next | type) == "string" then $step.next
          elif ($step.next | type) == "array" then
            ($step.next[] | (.goto // empty), (.default // empty))
          else empty end
        else empty end)
      ) as $explicit |
      # Collect explicit routes
      [$explicit] | if length > 0 then .[]
      else
        # Only add implicit next if no explicit routes
        if ($idx + 1) < ($steps | length) then $steps[$idx + 1].id else empty end
      end
    ' <<< "$wf_json" 2>/dev/null)
    # Fallback if jq above is too complex: try simpler approach
    if [[ -z "$successors" ]]; then
      successors=$(jq -r --arg id "$current" '
        .steps as $steps |
        ($steps | to_entries[] | select(.value.id == $id)) as $entry |
        $entry.value as $step | $entry.key as $idx |
        [($step.on_pass // empty), ($step.on_fail // empty), ($step.on_timeout // empty),
         (if $step.next then
           if ($step.next | type) == "string" then $step.next
           elif ($step.next | type) == "array" then ($step.next[] | (.goto // empty), (.default // empty))
           else empty end
         else empty end)] |
        if length > 0 then .[] else (if ($idx + 1) < ($steps | length) then $steps[$idx + 1].id else empty end) end
      ' <<< "$wf_json" 2>/dev/null)
    fi

    local succ
    while IFS= read -r succ; do
      [[ -z "$succ" ]] && continue
      case " $reachable " in
        *" $succ "*) continue ;;
      esac
      reachable="$reachable $succ"
      queue="$queue $succ"
    done <<< "$successors"
  done

  # Check which steps are unreachable
  local sid
  while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue
    case " $reachable " in
      *" $sid "*) ;;
      *) echo "Step '${sid}' is unreachable from the first step" ;;
    esac
  done <<< "$step_ids"
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
