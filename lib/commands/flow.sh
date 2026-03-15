#!/usr/bin/env bash
# flow.sh — Flow control: pause, resume, cancel, retry

cmd_pause() {
  local run_id="${1:?Usage: cq pause <run_id>}"
  local run_dir
  run_dir=$(cq_require_run "$run_id" "cq pause <run_id>")

  local meta status
  meta=$(cq_read_meta "$run_id")
  status=$(jq -r '.status' <<< "$meta")

  case "$status" in
    running|queued|gated)
      cq_update_meta "$run_id" '.status = "paused"'
      cq_log_event "$run_dir" "run_paused" '{}'
      # Cascade pause to child runs
      _cascade_to_children "$run_id" "pause"
      cq_json_out --arg id "$run_id" '{run_id:$id, status:"paused"}' || \
        cq_info "$(cq_marker "paused") Paused run ${run_id}"
      ;;
    *)
      cq_die "Cannot pause run in '${status}' status"
      ;;
  esac
}

cmd_resume() {
  local run_id="${1:?Usage: cq resume <run_id>}"
  local run_dir
  run_dir=$(cq_require_run "$run_id" "cq resume <run_id>")

  local meta status
  meta=$(cq_read_meta "$run_id")
  status=$(jq -r '.status' <<< "$meta")

  [[ "$status" == "paused" ]] || cq_die "Cannot resume run in '${status}' status (must be paused)"

  cq_update_meta "$run_id" '.status = "running"'
  cq_log_event "$run_dir" "run_resumed" '{}'

  local current_step
  current_step=$(jq -r '.current_step // ""' <<< "$meta")
  cq_json_out --arg id "$run_id" '{run_id:$id, status:"running"}' || {
    cq_info "$(cq_marker "running") Resumed run ${run_id}"
    cq_hint "Run resumed. Enter the runner loop to continue from step '${current_step}'."
  }
}

cmd_cancel() {
  local run_id="${1:?Usage: cq cancel <run_id>}"
  local run_dir
  run_dir=$(cq_require_run "$run_id" "cq cancel <run_id>")

  local meta status
  meta=$(cq_read_meta "$run_id")
  status=$(jq -r '.status' <<< "$meta")

  case "$status" in
    completed|cancelled)
      cq_die "Cannot cancel run in '${status}' status"
      ;;
    *)
      cq_update_meta "$run_id" '.status = "cancelled"'
      cq_log_event "$run_dir" "run_cancelled" '{}'
      # Cascade cancel to child runs
      _cascade_to_children "$run_id" "cancel"
      cq_json_out --arg id "$run_id" '{run_id:$id, status:"cancelled"}' || {
        cq_info "$(cq_marker "cancelled") Cancelled run ${run_id}"
        cq_hint "Run cancelled. Update the workflow Task to cancelled via TaskUpdate."
      }
      ;;
  esac
}

cmd_retry() {
  local run_id="${1:?Usage: cq retry <run_id>}"
  local run_dir
  run_dir=$(cq_require_run "$run_id" "cq retry <run_id>")

  local meta status
  meta=$(cq_read_meta "$run_id")
  status=$(jq -r '.status' <<< "$meta")

  [[ "$status" == "failed" || "$status" == "blocked" ]] || cq_die "Cannot retry run in '${status}' status (must be failed or blocked)"

  local current_step
  current_step=$(jq -r '.current_step' <<< "$meta")

  # Reset the failed step to pending
  if [[ -n "$current_step" && "$current_step" != "null" ]]; then
    local state
    state=$(cq_read_state "$run_id")
    state=$(jq --arg id "$current_step" \
      '.[$id].status = "pending" | .[$id].result = null | .[$id].finished_at = null' <<< "$state")
    cq_write_json "${run_dir}/state.json" "$state"
  fi

  cq_update_meta "$run_id" '.status = "running"'
  cq_log_event "$run_dir" "run_retried" \
    "$(jq -cn --arg step "$current_step" '{step:$step}')"

  cq_json_out --arg id "$run_id" --arg step "$current_step" '{run_id:$id, status:"running", retry_step:$step}' || \
    cq_info "$(cq_marker "running") Retrying run ${run_id} from step '${current_step}'"
}

# Cascade a flow control action to child sub-workflow runs
_cascade_to_children() {
  local parent_run_id="$1" action="$2"
  local child_run_id
  for child_run_id in $(cq_child_run_ids "$parent_run_id"); do
    local child_status
    child_status=$(jq -r '.status' "$(cq_run_dir "$child_run_id")/meta.json" 2>/dev/null) || continue
    case "$action" in
      pause)
        case "$child_status" in
          running|queued|gated) cmd_pause "$child_run_id" >/dev/null 2>&1 || true ;;
        esac
        ;;
      cancel)
        case "$child_status" in
          completed|cancelled) ;;
          *) cmd_cancel "$child_run_id" >/dev/null 2>&1 || true ;;
        esac
        ;;
    esac
  done
}
