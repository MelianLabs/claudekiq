#!/usr/bin/env bash
# flow.sh — Flow control: pause, resume, cancel, retry

cmd_pause() {
  local run_id="${1:?Usage: cq pause <run_id>}"
  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"

  local meta status
  meta=$(cq_read_meta "$run_id")
  status=$(echo "$meta" | jq -r '.status')

  case "$status" in
    running|queued|gated)
      cq_update_meta "$run_id" '.status = "paused"'
      local run_dir
      run_dir=$(cq_run_dir "$run_id")
      cq_log_event "$run_dir" "run_paused" '{}'
      cq_info "$(cq_marker "paused") Paused run ${run_id}"
      if [[ "$CQ_JSON" == "true" ]]; then
        jq -cn --arg id "$run_id" '{run_id:$id, status:"paused"}'
      fi
      ;;
    *)
      cq_die "Cannot pause run in '${status}' status"
      ;;
  esac
}

cmd_resume() {
  local run_id="${1:?Usage: cq resume <run_id>}"
  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"

  local meta status
  meta=$(cq_read_meta "$run_id")
  status=$(echo "$meta" | jq -r '.status')

  [[ "$status" == "paused" ]] || cq_die "Cannot resume run in '${status}' status (must be paused)"

  cq_update_meta "$run_id" '.status = "running"'
  local run_dir
  run_dir=$(cq_run_dir "$run_id")
  cq_log_event "$run_dir" "run_resumed" '{}'
  cq_info "$(cq_marker "running") Resumed run ${run_id}"

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg id "$run_id" '{run_id:$id, status:"running"}'
  fi
}

cmd_cancel() {
  local run_id="${1:?Usage: cq cancel <run_id>}"
  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"

  local meta status
  meta=$(cq_read_meta "$run_id")
  status=$(echo "$meta" | jq -r '.status')

  case "$status" in
    completed|cancelled)
      cq_die "Cannot cancel run in '${status}' status"
      ;;
    *)
      cq_update_meta "$run_id" '.status = "cancelled"'
      local run_dir
      run_dir=$(cq_run_dir "$run_id")
      cq_log_event "$run_dir" "run_cancelled" '{}'
      cq_info "$(cq_marker "cancelled") Cancelled run ${run_id}"
      if [[ "$CQ_JSON" == "true" ]]; then
        jq -cn --arg id "$run_id" '{run_id:$id, status:"cancelled"}'
      fi
      ;;
  esac
}

cmd_retry() {
  local run_id="${1:?Usage: cq retry <run_id>}"
  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"

  local meta status
  meta=$(cq_read_meta "$run_id")
  status=$(echo "$meta" | jq -r '.status')

  [[ "$status" == "failed" || "$status" == "blocked" ]] || cq_die "Cannot retry run in '${status}' status (must be failed or blocked)"

  local run_dir current_step
  run_dir=$(cq_run_dir "$run_id")
  current_step=$(echo "$meta" | jq -r '.current_step')

  # Reset the failed step to pending
  if [[ -n "$current_step" && "$current_step" != "null" ]]; then
    local state ts
    ts=$(cq_now)
    state=$(cq_read_state "$run_id")
    state=$(echo "$state" | jq --arg id "$current_step" \
      '.[$id].status = "pending" | .[$id].result = null | .[$id].finished_at = null')
    cq_write_json "${run_dir}/state.json" "$state"
  fi

  cq_update_meta "$run_id" '.status = "running"'
  cq_log_event "$run_dir" "run_retried" \
    "$(jq -cn --arg step "$current_step" '{step:$step}')"
  cq_info "$(cq_marker "running") Retrying run ${run_id} from step '${current_step}'"

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg id "$run_id" --arg step "$current_step" '{run_id:$id, status:"running", retry_step:$step}'
  fi
}
