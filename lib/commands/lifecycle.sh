#!/usr/bin/env bash
# lifecycle.sh — Workflow lifecycle: start, status, list, log

cmd_start() {
  local template="" priority="" ctx_vars=()

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --priority=*) priority="${1#*=}" ;;
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

  # Determine priority
  if [[ -z "$priority" ]]; then
    priority=$(echo "$wf_json" | jq -r '.default_priority // empty')
    [[ -z "$priority" ]] && priority=$(cq_config_get "default_priority")
    [[ -z "$priority" ]] && priority="normal"
  fi
  cq_valid_priority "$priority" || cq_die "Invalid priority: ${priority}"

  # Check concurrency
  local config max_concurrency running_count
  config=$(cq_resolve_config)
  max_concurrency=$(echo "$config" | jq -r '.concurrency // 1')
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
  local ctx
  local defaults
  defaults=$(echo "$wf_json" | jq '.defaults // {}')
  ctx=$(echo "$defaults" | jq '.')

  # Apply CLI context variables
  local idx=0
  while [[ $idx -lt ${#ctx_vars[@]} ]]; do
    local k="${ctx_vars[$idx]}"
    local v="${ctx_vars[$((idx + 1))]}"
    ctx=$(echo "$ctx" | jq --arg k "$k" --arg v "$v" '.[$k] = $v')
    idx=$((idx + 2))
  done

  # Write meta.json
  local first_step
  first_step=$(echo "$wf_json" | jq -r '.steps[0].id')
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
    '{id:$id, template:$template, status:$status, priority:$priority,
      created_at:$created_at, updated_at:$updated_at,
      current_step:$current_step, started_by:$started_by}')
  cq_write_json "${run_dir}/meta.json" "$meta"

  # Write ctx.json
  cq_write_json "${run_dir}/ctx.json" "$ctx"

  # Write steps.json (copy step definitions)
  local steps
  steps=$(echo "$wf_json" | jq '.steps')
  cq_write_json "${run_dir}/steps.json" "$steps"

  # Write state.json (initialize all steps as pending)
  local state='{}'
  local step_id
  for step_id in $(echo "$steps" | jq -r '.[].id'); do
    state=$(echo "$state" | jq --arg id "$step_id" \
      '.[$id] = {"status":"pending","visits":0,"attempt":0,"result":null,"started_at":null,"finished_at":null}')
  done
  cq_write_json "${run_dir}/state.json" "$state"

  # Initialize log
  touch "${run_dir}/log.jsonl"
  cq_log_event "$run_dir" "run_started" \
    "$(jq -cn --arg tpl "$template" --arg priority "$priority" '{template:$tpl, priority:$priority}')"

  # Fire on_start hook
  cq_fire_hook "on_start" "$run_dir"

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg id "$run_id" --arg status "$initial_status" --arg template "$template" \
      '{run_id:$id, status:$status, template:$template}'
  else
    local marker
    marker=$(cq_marker "$initial_status")
    echo "${marker} Started workflow '${template}' — run ${run_id} (${initial_status})"
  fi
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
    if [[ "$CQ_JSON" == "true" ]]; then
      echo '{"runs":[],"todos":[]}'
    else
      echo "No active workflow runs."
    fi
    return
  fi

  if [[ "$CQ_JSON" == "true" ]]; then
    local runs_json="[]"
    for run_id in "${all_runs[@]}"; do
      local meta
      meta=$(cq_read_meta "$run_id" 2>/dev/null) || continue
      # Add heartbeat info if available
      local run_dir hb_file
      run_dir=$(cq_run_dir "$run_id")
      hb_file="${run_dir}/.heartbeat"
      if [[ -f "$hb_file" ]]; then
        local hb_age
        hb_age=$(cq_file_age "$hb_file")
        meta=$(echo "$meta" | jq --argjson age "$hb_age" '. + {heartbeat_age:$age}')
      fi
      runs_json=$(echo "$runs_json" | jq --argjson m "$meta" '. + [$m]')
    done
    local todos
    todos=$(cq_list_todos)
    jq -cn --argjson runs "$runs_json" --argjson todos "$todos" \
      '{runs:$runs, todos:$todos}'
  else
    echo "=== Workflow Dashboard ==="
    echo ""
    for run_id in "${all_runs[@]}"; do
      local meta status template priority current_step
      meta=$(cq_read_meta "$run_id" 2>/dev/null) || continue
      status=$(echo "$meta" | jq -r '.status')
      template=$(echo "$meta" | jq -r '.template')
      priority=$(echo "$meta" | jq -r '.priority')
      current_step=$(echo "$meta" | jq -r '.current_step // "-"')
      local marker
      marker=$(cq_marker "$status")
      printf "  %s %-8s %-15s %-8s step: %s\n" "$marker" "$run_id" "$template" "[$priority]" "$current_step"
    done

    # Show pending TODOs
    local todos
    todos=$(cq_list_todos)
    local todo_count
    todo_count=$(echo "$todos" | jq 'length')
    if [[ "$todo_count" -gt 0 ]]; then
      echo ""
      echo "Pending actions (${todo_count}):"
      local i
      for ((i = 0; i < todo_count; i++)); do
        local todo step_name action run
        todo=$(echo "$todos" | jq --argjson i "$i" '.[$i]')
        step_name=$(echo "$todo" | jq -r '.step_name')
        action=$(echo "$todo" | jq -r '.action')
        run=$(echo "$todo" | jq -r '.run_id')
        printf "  #%d  %s — %s (run %s)\n" "$((i + 1))" "$step_name" "$action" "$run"
      done
    fi
  fi
}

_status_detail() {
  local run_id="$1"
  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"

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
    status=$(echo "$meta" | jq -r '.status')
    template=$(echo "$meta" | jq -r '.template')
    priority=$(echo "$meta" | jq -r '.priority')
    current_step=$(echo "$meta" | jq -r '.current_step // "-"')
    created_at=$(echo "$meta" | jq -r '.created_at')

    local marker
    marker=$(cq_marker "$status")

    echo "Run: ${run_id}  ${marker} ${status}"
    echo "Template: ${template}  Priority: ${priority}"
    echo "Started: ${created_at}"
    echo "Current step: ${current_step}"
    echo ""
    echo "Steps:"

    local step_count i
    step_count=$(echo "$steps" | jq 'length')
    for ((i = 0; i < step_count; i++)); do
      local sid stype
      sid=$(echo "$steps" | jq -r --argjson i "$i" '.[$i].id')
      stype=$(echo "$steps" | jq -r --argjson i "$i" '.[$i].type')
      local sstatus svisits
      sstatus=$(echo "$state" | jq -r --arg id "$sid" '.[$id].status // "pending"')
      svisits=$(echo "$state" | jq -r --arg id "$sid" '.[$id].visits // 0')
      local sm
      sm=$(cq_marker "$sstatus")
      printf "  %s %-20s %-8s %-10s visits:%s\n" "$sm" "$sid" "$stype" "$sstatus" "$svisits"
    done
  fi
}

cmd_list() {
  local runs_json="[]"
  local run_id

  for run_id in $(cq_run_ids); do
    local meta
    meta=$(cq_read_meta "$run_id" 2>/dev/null) || continue
    runs_json=$(echo "$runs_json" | jq --argjson m "$meta" '. + [$m]')
  done

  if [[ "$CQ_JSON" == "true" ]]; then
    echo "$runs_json" | jq '.'
  else
    if [[ $(echo "$runs_json" | jq 'length') -eq 0 ]]; then
      echo "No workflow runs."
      return
    fi
    echo "$runs_json" | jq -r '.[] | "\(.id)\t\(.status)\t\(.template)\t\(.priority)"' | \
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
  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"

  local log_file
  log_file="$(cq_run_dir "$run_id")/log.jsonl"
  [[ -f "$log_file" ]] || { echo "No log entries."; return; }

  if [[ "$CQ_JSON" == "true" ]]; then
    if [[ -n "$tail_n" ]]; then
      tail -n "$tail_n" "$log_file" | jq -s '.'
    else
      jq -s '.' "$log_file"
    fi
  else
    local line
    if [[ -n "$tail_n" ]]; then
      tail -n "$tail_n" "$log_file"
    else
      cat "$log_file"
    fi | while IFS= read -r line; do
      local ts event data_str
      ts=$(echo "$line" | jq -r '.ts')
      event=$(echo "$line" | jq -r '.event')
      data_str=$(echo "$line" | jq -c '.data // {}')
      printf "  %s  %-20s %s\n" "$ts" "$event" "$data_str"
    done
  fi
}
