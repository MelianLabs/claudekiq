#!/usr/bin/env bash
# todos.sh — Human action commands: todos, todo

cmd_todos() {
  local filter_run=""
  local subcommand=""

  # Check if first arg is a subcommand
  if [[ $# -gt 0 ]]; then
    case "$1" in
      sync|apply-sync) subcommand="$1"; shift ;;
    esac
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --flow=*) filter_run="${1#*=}" ;;
      --flow) shift; filter_run="$1" ;;
    esac
    shift
  done

  case "$subcommand" in
    sync)
      _todos_sync "$filter_run"
      return
      ;;
    apply-sync)
      _todos_apply_sync
      return
      ;;
  esac

  local todos
  todos=$(cq_list_todos "$filter_run")
  local count
  count=$(jq 'length' <<< "$todos")

  if [[ "$CQ_JSON" == "true" ]]; then
    jq '.' <<< "$todos"
  else
    if [[ "$count" -eq 0 ]]; then
      echo "No pending actions."
      return
    fi
    echo "Pending actions:"
    jq -r '.[] | "\(.step_name)\t\(.action)\t\(.run_id)\t\(.description // "")\t\(.priority)"' <<< "$todos" | \
      { local i=0; while IFS=$'\t' read -r step_name action run_id description priority; do
        i=$((i + 1))
        printf "  #%d  [%s] %s — %s\n" "$i" "$priority" "$step_name" "$action"
        [[ -n "$description" ]] && printf "       %s\n" "$description"
        printf "       run: %s\n" "$run_id"
      done; }
  fi
}

# Output pending TODOs in native TodoWrite-compatible format
_todos_sync() {
  local filter_run="${1:-}"
  local native_payload
  native_payload=$(cq_todos_as_native_format "$filter_run")

  # Update sync state for each run that has pending TODOs
  local run_ids
  run_ids=$(jq -r '.run_ids[]' <<< "$native_payload" 2>/dev/null)
  for run_id in $run_ids; do
    local run_todos
    run_todos=$(jq -c --arg rid "$run_id" '[.todos[] | select(.metadata.run_id == $rid) | {id: .id}]' <<< "$native_payload")
    cq_todo_mark_synced "$run_id" "$run_todos"
  done

  if [[ "$CQ_JSON" == "true" ]]; then
    jq '.' <<< "$native_payload"
  else
    local count
    count=$(jq '.todos | length' <<< "$native_payload")
    if [[ "$count" -eq 0 ]]; then
      echo "No pending TODOs to sync."
    else
      echo "Synced ${count} pending TODO(s) for native integration."
      jq -r '.todos[] | "  - \(.content) [\(.priority)]"' <<< "$native_payload"
    fi
  fi
}

# Accept resolutions from native system (reads JSON from stdin)
_todos_apply_sync() {
  local input
  input=$(cat)
  [[ -z "$input" ]] && cq_die "Usage: echo '{\"resolutions\":[...]}' | cq todos apply-sync"

  local result
  result=$(cq_todos_apply_sync "$input")

  if [[ "$CQ_JSON" == "true" ]]; then
    jq '.' <<< "$result"
  else
    local applied
    applied=$(jq -r '.applied' <<< "$result")
    echo "Applied ${applied} resolution(s) from native TODO system."
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
  todo_id=$(jq -r '.id' <<< "$todo")
  run_id=$(jq -r '.run_id' <<< "$todo")
  step_id=$(jq -r '.step_id' <<< "$todo")

  local run_dir
  run_dir=$(cq_require_run "$run_id" "cq todo <#> <action>")

  case "$action" in
    approve|override)
      cq_update_todo "$run_id" "$todo_id" "done"

      # Mark step as passed
      local state ts
      ts=$(cq_now)
      state=$(cq_read_state "$run_id")
      state=$(jq --arg id "$step_id" --arg ts "$ts" \
        '.[$id].status = "passed" | .[$id].result = "pass" | .[$id].finished_at = $ts' <<< "$state")
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

  cq_json_out --arg todo_id "$todo_id" --arg action "$action" --arg run_id "$run_id" \
    '{todo_id:$todo_id, action:$action, run_id:$run_id}' || true
}
