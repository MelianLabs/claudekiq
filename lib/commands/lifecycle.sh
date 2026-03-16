#!/usr/bin/env bash
# lifecycle.sh — Workflow lifecycle: start, status, list, log

cmd_start() {
  local template="" priority="" ctx_vars=()
  local parent_run_id="" parent_step_id=""

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --priority=*) priority="${1#*=}" ;;
      --parent=*)   parent_run_id="${1#*=}" ;;
      --parent-step=*) parent_step_id="${1#*=}" ;;
      --headless)   CQ_HEADLESS="true"; CQ_JSON="true" ;;
      --*)
        local key="${1#--}"
        local val="${key#*=}"
        key="${key%%=*}"
        ctx_vars+=("$key" "$val")
        ;;
      *)
        if [[ -z "$template" ]]; then
          template="$1"
        fi
        ;;
    esac
    shift
  done

  [[ -z "$template" ]] && cq_die "Usage: cq start <template> [--key=val]..."

  # Find and parse workflow
  local wf_file
  wf_file=$(cq_find_workflow "$template") || cq_die "Workflow not found: ${template}"
  local wf_json
  wf_json=$(cq_yaml_to_json "$wf_file")

  # Resolve workflow inheritance (extends)
  wf_json=$(cq_resolve_workflow_inheritance "$wf_json")

  # Validate agent targets
  _validate_agent_targets "$wf_json"

  # Validate model fields (warn only, don't block)
  _validate_step_models "$wf_json"

  # Determine priority
  if [[ -z "$priority" ]]; then
    priority=$(jq -r '.default_priority // empty' <<< "$wf_json")
    [[ -z "$priority" ]] && priority=$(cq_config_get "default_priority")
    [[ -z "$priority" ]] && priority="normal"
  fi
  cq_valid_priority "$priority" || cq_die "Invalid priority: ${priority}"

  # Check concurrency
  local config max_concurrency running_count
  config=$(cq_resolve_config)
  max_concurrency=$(jq -r '.concurrency // 1' <<< "$config")
  running_count=$(_count_running_runs)
  local initial_status="running"
  if [[ "$running_count" -ge "$max_concurrency" ]]; then
    initial_status="queued"
  fi

  # Generate run ID
  local run_id
  run_id=$(cq_gen_id)
  local run_dir
  run_dir=$(cq_run_dir "$run_id")
  mkdir -p "$run_dir"

  local ts
  ts=$(cq_now)

  # Build context from defaults + CLI args
  local ctx defaults
  defaults=$(jq '.defaults // {}' <<< "$wf_json")
  ctx="$defaults"

  # Apply CLI context variables
  local idx=0
  while [[ $idx -lt ${#ctx_vars[@]} ]]; do
    local k="${ctx_vars[$idx]}"
    local v="${ctx_vars[$((idx + 1))]}"
    ctx=$(jq --arg k "$k" --arg v "$v" '.[$k] = $v' <<< "$ctx")
    idx=$((idx + 2))
  done

  # Write meta.json (include params if present)
  local first_step
  first_step=$(jq -r '.steps[0].id' <<< "$wf_json")
  local params
  params=$(jq '.params // null' <<< "$wf_json")
  local meta
  meta=$(jq -cn \
    --arg id "$run_id" \
    --arg template "$template" \
    --arg status "$initial_status" \
    --arg priority "$priority" \
    --arg created_at "$ts" \
    --arg updated_at "$ts" \
    --arg current_step "$first_step" \
    --arg started_by "user" \
    --argjson params "$params" \
    '{id:$id, template:$template, status:$status, priority:$priority,
      created_at:$created_at, updated_at:$updated_at,
      current_step:$current_step, started_by:$started_by}
      + (if $params != null then {params:$params} else {} end)')

  # Add parent linkage for sub-workflows
  if [[ -n "$parent_run_id" ]]; then
    meta=$(jq --arg prid "$parent_run_id" --arg psid "$parent_step_id" \
      '. + {parent_run_id: $prid, parent_step_id: $psid}' <<< "$meta")
    # Register child in parent meta
    cq_update_meta "$parent_run_id" \
      '.children = ((.children // []) + [{"run_id": $crid, "step_id": $csid, "template": $ctpl}])' \
      --arg crid "$run_id" --arg csid "$parent_step_id" --arg ctpl "$template"
  fi

  cq_write_json "${run_dir}/meta.json" "$meta"

  # Write ctx.json
  cq_write_json "${run_dir}/ctx.json" "$ctx"

  # Write steps.json (copy step definitions)
  local steps
  steps=$(jq '.steps' <<< "$wf_json")
  cq_write_json "${run_dir}/steps.json" "$steps"

  # Write state.json (initialize all steps as pending, including parallel branch state)
  local state
  state=$(jq '
    [.[].id] | reduce .[] as $id ({};
      .[$id] = {"status":"pending","visits":0,"attempt":0,"result":null,"started_at":null,"finished_at":null,"files":[]})
  ' <<< "$steps")

  # Add branch state for parallel steps
  local parallel_info
  parallel_info=$(jq -c '[.[] | select(.type == "parallel" and .branches != null and (.branches | length) > 0) | {id, branches}]' <<< "$steps")
  if [[ "$parallel_info" != "[]" ]]; then
    state=$(jq --argjson psteps "$parallel_info" '
      reduce ($psteps[] | .id as $pid | .branches as $br |
        {key: $pid, value: ([($br // [])[] | {key: .id, value: {"status":"pending","result":null}}] | from_entries)}
      ) as $p (.; .[$p.key].branches = $p.value)
    ' <<< "$state")
  fi
  cq_write_json "${run_dir}/state.json" "$state"

  # Initialize log
  touch "${run_dir}/log.jsonl"
  cq_log_event "$run_dir" "run_started" \
    "$(jq -cn --arg tpl "$template" --arg priority "$priority" '{template:$tpl, priority:$priority}')"

  # Fire on_start hook
  cq_fire_hook "on_start" "$run_dir"

  if cq_json_out --arg id "$run_id" --arg status "$initial_status" --arg template "$template" \
    '{run_id:$id, status:$status, template:$template}'; then
    :
  else
    local marker
    marker=$(cq_marker "$initial_status")
    echo "${marker} Started workflow '${template}' — run ${run_id} (${initial_status})"
    cq_hint "Create a Task with TaskCreate to track this workflow run."
    if [[ "$initial_status" == "queued" ]]; then
      cq_hint "Run is queued. Another run is active. It will start when the current run completes."
    fi
  fi
}

# Validate that all @target agent references in agent steps exist.
# Only validates when scan data is available (scanned_at is set in settings.json).
_validate_agent_targets() {
  local wf_json="$1"

  # Only validate if scan data exists (skip in fresh/unconfigured projects)
  local settings_file="${CQ_PROJECT_ROOT}/.claudekiq/settings.json"
  if [[ ! -f "$settings_file" ]]; then return 0; fi
  local scanned_at
  scanned_at=$(jq -r '.scanned_at // empty' "$settings_file" 2>/dev/null)
  [[ -z "$scanned_at" ]] && return 0

  # Extract all agent step targets that start with @
  local targets
  targets=$(jq -r '.steps[] | select(.type == "agent") | .target // "" | select(startswith("@")) | ltrimstr("@")' <<< "$wf_json" 2>/dev/null)
  [[ -z "$targets" ]] && return 0

  # Load available agents from scan results
  local available_agents
  available_agents=$(jq -r '.agents // [] | .[].name' "$settings_file" 2>/dev/null)

  local target
  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    # Check: agent file on disk?
    [[ -f "${CQ_PROJECT_ROOT}/.claude/agents/${target}.md" ]] && continue
    # Check: in scan results?
    if [[ -n "$available_agents" ]] && echo "$available_agents" | grep -qx "$target"; then
      continue
    fi
    # Check: agent mapping?
    local mapped
    mapped=$(cq_resolve_agent_target "$target")
    if [[ "$mapped" != "$target" ]]; then
      [[ -f "${CQ_PROJECT_ROOT}/.claude/agents/${mapped}.md" ]] && continue
      if [[ -n "$available_agents" ]] && echo "$available_agents" | grep -qx "$mapped"; then
        continue
      fi
    fi
    # Not found — warn but don't block (agent may be available at runtime)
    local avail_list
    avail_list=$(echo "$available_agents" | tr '\n' ', ' | sed 's/,$//')
    [[ -z "$avail_list" ]] && avail_list="(none found)"
    cq_warn "Agent '${target}' not found. Available agents: ${avail_list}. Run 'cq scan' to update."
  done <<< "$targets"
}

# Validate model fields on steps (warn only)
_validate_step_models() {
  local wf_json="$1"
  local models
  models=$(jq -r '.steps[] | select(.model != null) | "\(.id):\(.model)"' <<< "$wf_json" 2>/dev/null)
  [[ -z "$models" ]] && return 0

  local entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local step_id="${entry%%:*}"
    local model="${entry#*:}"
    if ! cq_valid_model "$model"; then
      cq_warn "Step '${step_id}' has unknown model '${model}'. Known models: $(cq_resolve_config | jq -r '.models // [] | join(", ")')"
    fi
  done <<< "$models"
}

_count_running_runs() {
  local count=0
  local run_id
  for run_id in $(cq_run_ids); do
    local status
    status=$(jq -r '.status' "$(cq_run_dir "$run_id")/meta.json" 2>/dev/null)
    [[ "$status" == "running" ]] && count=$((count + 1))
  done
  echo "$count"
}

cmd_status() {
  local run_id="${1:-}"

  if [[ -n "$run_id" ]]; then
    _status_detail "$run_id"
  else
    _status_dashboard
  fi
}

_status_dashboard() {
  local all_runs=()
  local run_id
  for run_id in $(cq_run_ids); do
    all_runs+=("$run_id")
  done

  if [[ ${#all_runs[@]} -eq 0 ]]; then
    cq_json_out '{runs:[], todos:[]}' || echo "No active workflow runs."
    return
  fi

  # Collect run data once
  local -a run_metas=()
  for run_id in "${all_runs[@]}"; do
    local meta
    meta=$(cq_read_meta "$run_id" 2>/dev/null) || continue
    local run_dir="${CQ_PROJECT_ROOT}/.claudekiq/runs/${run_id}"
    local hb_file="${run_dir}/.heartbeat"
    if [[ -f "$hb_file" ]]; then
      local hb_age
      hb_age=$(cq_file_age "$hb_file")
      meta=$(jq --argjson age "$hb_age" '. + {heartbeat_age:$age}' <<< "$meta")
    fi
    run_metas+=("$meta")
  done

  local runs_json
  runs_json=$(cq_items_to_json "${run_metas[@]+"${run_metas[@]}"}")

  if [[ "$CQ_JSON" == "true" ]]; then
    local todos
    todos=$(cq_list_todos)
    jq -cn --argjson runs "$runs_json" --argjson todos "$todos" \
      '{runs:$runs, todos:$todos}'
  else
    echo "=== Workflow Dashboard ==="
    echo ""
    jq -r '.[] | "\(.id)\t\(.status)\t\(.template)\t\(.priority)\t\(.current_step // "-")"' <<< "$runs_json" | \
      while IFS=$'\t' read -r id status template priority current_step; do
        local marker
        marker=$(cq_marker "$status")
        printf "  %s %-8s %-15s %-8s step: %s\n" "$marker" "$id" "$template" "[$priority]" "$current_step"
      done

    # Show pending TODOs
    local todos
    todos=$(cq_list_todos)
    local todo_count
    todo_count=$(jq 'length' <<< "$todos")
    if [[ "$todo_count" -gt 0 ]]; then
      echo ""
      echo "Pending actions (${todo_count}):"
      jq -r '.[] | "\(.step_name)\t\(.action)\t\(.run_id)"' <<< "$todos" | \
        { local i=0; while IFS=$'\t' read -r step_name action run; do
          i=$((i + 1))
          printf "  #%d  %s — %s (run %s)\n" "$i" "$step_name" "$action" "$run"
        done; }
    fi
  fi
}

_status_detail() {
  local run_id="$1"
  cq_require_run "$run_id" "cq status <run_id>" >/dev/null

  local meta ctx steps state
  meta=$(cq_read_meta "$run_id")
  ctx=$(cq_read_ctx "$run_id")
  steps=$(cq_read_steps "$run_id")
  state=$(cq_read_state "$run_id")

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --argjson meta "$meta" --argjson ctx "$ctx" \
      --argjson steps "$steps" --argjson state "$state" \
      '{meta:$meta, ctx:$ctx, steps:$steps, state:$state}'
  else
    local status template priority current_step created_at
    status=$(jq -r '.status' <<< "$meta")
    template=$(jq -r '.template' <<< "$meta")
    priority=$(jq -r '.priority' <<< "$meta")
    current_step=$(jq -r '.current_step // "-"' <<< "$meta")
    created_at=$(jq -r '.created_at' <<< "$meta")

    local marker
    marker=$(cq_marker "$status")

    echo "Run: ${run_id}  ${marker} ${status}"
    echo "Template: ${template}  Priority: ${priority}"
    echo "Started: ${created_at}"
    echo "Current step: ${current_step}"
    echo ""
    echo "Steps:"

    # Use jq to format step list in one call instead of N+1 calls per step
    jq -r --argjson state "$state" '
      .[] | "\(.id)\t\(.type)\t\($state[.id].status // "pending")\t\($state[.id].visits // 0)"
    ' <<< "$steps" | while IFS=$'\t' read -r sid stype sstatus svisits; do
      local sm
      sm=$(cq_marker "$sstatus")
      printf "  %s %-20s %-8s %-10s visits:%s\n" "$sm" "$sid" "$stype" "$sstatus" "$svisits"
    done
  fi
}

cmd_list() {
  local -a run_items=()
  local run_id

  for run_id in $(cq_run_ids); do
    local meta
    meta=$(cq_read_meta "$run_id" 2>/dev/null) || continue
    run_items+=("$meta")
  done

  local runs_json
  runs_json=$(cq_items_to_json "${run_items[@]+"${run_items[@]}"}")

  if [[ "$CQ_JSON" == "true" ]]; then
    jq '.' <<< "$runs_json"
  else
    if [[ $(jq 'length' <<< "$runs_json") -eq 0 ]]; then
      echo "No workflow runs."
      return
    fi
    jq -r '.[] | "\(.id)\t\(.status)\t\(.template)\t\(.priority)"' <<< "$runs_json" | \
      while IFS=$'\t' read -r id status template priority; do
        local marker
        marker=$(cq_marker "$status")
        printf "  %s %-8s %-12s %-15s\n" "$marker" "$id" "$status" "$template"
      done
  fi
}

cmd_log() {
  local run_id="" tail_n=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tail=*) tail_n="${1#*=}" ;;
      --tail) shift; tail_n="$1" ;;
      *) [[ -z "$run_id" ]] && run_id="$1" ;;
    esac
    shift
  done

  [[ -z "$run_id" ]] && cq_die "Usage: cq log <run_id> [--tail N]"
  local run_dir
  run_dir=$(cq_require_run "$run_id" "cq log <run_id> [--tail N]")

  local log_file="${run_dir}/log.jsonl"
  [[ -f "$log_file" ]] || { echo "No log entries."; return; }

  if [[ "$CQ_JSON" == "true" ]]; then
    if [[ -n "$tail_n" ]]; then
      tail -n "$tail_n" "$log_file" | jq -s '.'
    else
      jq -s '.' "$log_file"
    fi
  else
    if [[ -n "$tail_n" ]]; then
      tail -n "$tail_n" "$log_file"
    else
      cat "$log_file"
    fi | jq -r '"  \(.ts)  \(.event | . + " " * (20 - length))  \(.data // {} | tostring)"'
  fi
}
