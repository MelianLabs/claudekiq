#!/usr/bin/env bash
# maintenance.sh — Cleanup, heartbeat, stale detection

cmd_cleanup() {
  local config ttl removed=0
  config=$(cq_resolve_config)
  ttl=$(jq -r '.ttl // 2592000' <<< "$config")

  local run_id
  for run_id in $(cq_run_ids); do
    local run_dir meta status
    run_dir=$(cq_run_dir "$run_id")
    meta=$(cq_read_meta "$run_id" 2>/dev/null) || continue
    status=$(jq -r '.status' <<< "$meta")

    # Only clean up completed, failed, or cancelled runs
    case "$status" in
      completed|failed|cancelled) ;;
      *) continue ;;
    esac

    local age
    age=$(cq_file_age "${run_dir}/meta.json")
    if [[ "$age" -ge "$ttl" ]]; then
      rm -rf "$run_dir"
      removed=$((removed + 1))
    fi
  done

  cq_json_out --argjson n "$removed" '{removed:$n}' || \
    echo "Removed ${removed} expired run(s)."
}

cmd_heartbeat() {
  local run_id="${1:?Usage: cq heartbeat <run_id>}"
  local run_dir
  run_dir=$(cq_require_run "$run_id" "cq heartbeat <run_id>")
  local ts
  ts=$(cq_now)
  echo "$ts" > "${run_dir}/.heartbeat"

  cq_json_out --arg ts "$ts" --arg rid "$run_id" '{run_id:$rid, heartbeat:$ts}' || true
}

cmd_check_stale() {
  local timeout=120
  local mark=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout=*) timeout="${1#*=}" ;;
      --mark)      mark=true ;;
      *)           ;;
    esac
    shift
  done

  local -a stale_items=()
  local run_id

  for run_id in $(cq_run_ids); do
    local run_dir meta status
    run_dir=$(cq_run_dir "$run_id")
    meta=$(cq_read_meta "$run_id" 2>/dev/null) || continue
    status=$(jq -r '.status' <<< "$meta")

    # Only check running workflows
    [[ "$status" == "running" ]] || continue

    local hb_file="${run_dir}/.heartbeat"
    [[ -f "$hb_file" ]] || continue

    local age
    age=$(cq_file_age "$hb_file")
    if [[ "$age" -ge "$timeout" ]]; then
      local current_step
      current_step=$(jq -r '.current_step // "-"' <<< "$meta")
      stale_items+=("$(jq -cn --arg rid "$run_id" --argjson age "$age" --arg step "$current_step" \
        '{run_id:$rid, heartbeat_age:$age, current_step:$step}')")

      if [[ "$mark" == "true" ]]; then
        cq_update_meta "$run_id" '.status = "blocked"'
        cq_log_event "$run_dir" "run_blocked" \
          "$(jq -cn --argjson age "$age" --argjson timeout "$timeout" \
            '{reason:"heartbeat_stale", heartbeat_age:$age, timeout:$timeout}')"
      fi
    fi
  done

  local stale_json count
  if [[ ${#stale_items[@]} -gt 0 ]]; then
    stale_json=$(printf '%s\n' "${stale_items[@]}" | jq -s '.')
  else
    stale_json="[]"
  fi
  count=${#stale_items[@]}

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --argjson stale "$stale_json" --argjson count "$count" \
      --argjson marked "$([[ "$mark" == "true" ]] && echo "true" || echo "false")" \
      '{stale:$stale, count:$count, marked:$marked}'
  else
    if [[ "$count" -eq 0 ]]; then
      echo "No stale runs detected."
    else
      echo "Stale runs (${count}):"
      jq -r '.[] | "  \(.run_id)  step: \(.current_step)  (heartbeat \(.heartbeat_age)s ago)"' <<< "$stale_json" | \
        while IFS= read -r line; do
          local action=""
          [[ "$mark" == "true" ]] && action=" → marked blocked"
          echo "  $(cq_marker "blocked")${line}${action}"
        done
    fi
  fi
}
