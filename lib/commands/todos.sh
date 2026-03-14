#!/usr/bin/env bash
# todos.sh — Human action commands: todos, todo

cmd_todos() {
  local filter_run=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --flow=*) filter_run="${1#*=}" ;;
      --flow) shift; filter_run="$1" ;;
    esac
    shift
  done

  local todos
  todos=$(cq_list_todos "$filter_run")
  local count
  count=$(echo "$todos" | jq 'length')

  if [[ "$CQ_JSON" == "true" ]]; then
    echo "$todos" | jq '.'
  else
    if [[ "$count" -eq 0 ]]; then
      echo "No pending actions."
      return
    fi
    echo "Pending actions:"
    local i
    for ((i = 0; i < count; i++)); do
      local todo step_name action run_id description priority
      todo=$(echo "$todos" | jq --argjson i "$i" '.[$i]')
      step_name=$(echo "$todo" | jq -r '.step_name')
      action=$(echo "$todo" | jq -r '.action')
      run_id=$(echo "$todo" | jq -r '.run_id')
      description=$(echo "$todo" | jq -r '.description // ""')
      priority=$(echo "$todo" | jq -r '.priority')
      printf "  #%d  [%s] %s — %s\n" "$((i + 1))" "$priority" "$step_name" "$action"
      [[ -n "$description" ]] && printf "       %s\n" "$description"
      printf "       run: %s\n" "$run_id"
    done
  fi
}

cmd_todo() {
  local index="${1:?Usage: cq todo <#> approve|reject|override|dismiss}"
  local action="${2:?Usage: cq todo <#> approve|reject|override|dismiss}"
  shift 2
  # --note is accepted but currently informational only
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note=*) ;; # accepted, not used yet
      --note) shift ;;
    esac
    shift
  done

  case "$action" in
    approve|reject|override|dismiss) ;;
    *) cq_die "Invalid action: ${action}. Must be approve|reject|override|dismiss" ;;
  esac

  # Find the TODO
  local todo
  todo=$(cq_find_todo_by_index "$index")
  [[ -z "$todo" || "$todo" == "null" ]] && cq_die "No pending action at #${index}"

  local todo_id run_id step_id
  todo_id=$(echo "$todo" | jq -r '.id')
  run_id=$(echo "$todo" | jq -r '.run_id')
  step_id=$(echo "$todo" | jq -r '.step_id')

  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"

  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  case "$action" in
    approve|override)
      cq_update_todo "$run_id" "$todo_id" "done"

      # Mark step as passed
      local state ts
      ts=$(cq_now)
      state=$(cq_read_state "$run_id")
      state=$(echo "$state" | jq --arg id "$step_id" --arg ts "$ts" \
        '.[$id].status = "passed" | .[$id].result = "pass" | .[$id].finished_at = $ts')
      cq_write_json "${run_dir}/state.json" "$state"

      cq_log_event "$run_dir" "todo_${action}" \
        "$(jq -cn --arg tid "$todo_id" --arg sid "$step_id" '{todo_id:$tid, step_id:$sid}')"

      # Advance the run
      _advance_run "$run_id" "$step_id" "pass"

      cq_info "$(cq_marker "passed") Action #${index} ${action}d — advancing run ${run_id}"
      ;;

    reject)
      cq_update_todo "$run_id" "$todo_id" "done"
      cq_update_meta "$run_id" '.status = "failed"'
      cq_log_event "$run_dir" "todo_rejected" \
        "$(jq -cn --arg tid "$todo_id" --arg sid "$step_id" '{todo_id:$tid, step_id:$sid}')"
      cq_fire_hook "on_fail" "$run_dir"
      cq_info "$(cq_marker "failed") Action #${index} rejected — run ${run_id} failed"
      ;;

    dismiss)
      cq_update_todo "$run_id" "$todo_id" "dismissed"
      cq_log_event "$run_dir" "todo_dismissed" \
        "$(jq -cn --arg tid "$todo_id" '{todo_id:$tid}')"
      cq_info "Action #${index} dismissed"
      ;;
  esac

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg todo_id "$todo_id" --arg action "$action" --arg run_id "$run_id" \
      '{todo_id:$todo_id, action:$action, run_id:$run_id}'
  fi
}
