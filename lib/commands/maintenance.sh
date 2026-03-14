#!/usr/bin/env bash
# maintenance.sh — Cleanup, heartbeat, stale detection

cmd_cleanup() {
  local config ttl removed=0
  config=$(cq_resolve_config)
  ttl=$(echo "$config" | jq -r '.ttl // 2592000')

  local run_id
  for run_id in $(cq_run_ids); do
    local run_dir meta status
    run_dir=$(cq_run_dir "$run_id")
    meta=$(cq_read_meta "$run_id" 2>/dev/null) || continue
    status=$(echo "$meta" | jq -r '.status')

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

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --argjson n "$removed" '{removed:$n}'
  else
    echo "Removed ${removed} expired run(s)."
  fi
}

cmd_heartbeat() {
  local run_id="${1:?Usage: cq heartbeat <run_id>}"
  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"

  local run_dir
  run_dir=$(cq_run_dir "$run_id")
  local ts
  ts=$(cq_now)
  echo "$ts" > "${run_dir}/.heartbeat"

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg ts "$ts" --arg rid "$run_id" '{run_id:$rid, heartbeat:$ts}'
  fi
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

  local stale_json="[]"
  local run_id

  for run_id in $(cq_run_ids); do
    local run_dir meta status
    run_dir=$(cq_run_dir "$run_id")
    meta=$(cq_read_meta "$run_id" 2>/dev/null) || continue
    status=$(echo "$meta" | jq -r '.status')

    # Only check running workflows
    [[ "$status" == "running" ]] || continue

    local hb_file="${run_dir}/.heartbeat"
    if [[ ! -f "$hb_file" ]]; then
      # No heartbeat file — can't determine staleness
      continue
    fi

    local age
    age=$(cq_file_age "$hb_file")
    if [[ "$age" -ge "$timeout" ]]; then
      local current_step
      current_step=$(echo "$meta" | jq -r '.current_step // "-"')
      stale_json=$(echo "$stale_json" | jq \
        --arg rid "$run_id" --argjson age "$age" --arg step "$current_step" \
        '. + [{run_id:$rid, heartbeat_age:$age, current_step:$step}]')

      if [[ "$mark" == "true" ]]; then
        cq_update_meta "$run_id" '.status = "blocked"'
        cq_log_event "$run_dir" "run_blocked" \
          "$(jq -cn --argjson age "$age" --argjson timeout "$timeout" \
            '{reason:"heartbeat_stale", heartbeat_age:$age, timeout:$timeout}')"
      fi
    fi
  done

  local count
  count=$(echo "$stale_json" | jq 'length')

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --argjson stale "$stale_json" --argjson count "$count" \
      --argjson marked "$([[ "$mark" == "true" ]] && echo "true" || echo "false")" \
      '{stale:$stale, count:$count, marked:$marked}'
  else
    if [[ "$count" -eq 0 ]]; then
      echo "No stale runs detected."
    else
      echo "Stale runs (${count}):"
      local i
      for ((i = 0; i < count; i++)); do
        local rid age step
        rid=$(echo "$stale_json" | jq -r --argjson i "$i" '.[$i].run_id')
        age=$(echo "$stale_json" | jq -r --argjson i "$i" '.[$i].heartbeat_age')
        step=$(echo "$stale_json" | jq -r --argjson i "$i" '.[$i].current_step')
        local action=""
        [[ "$mark" == "true" ]] && action=" → marked blocked"
        echo "  $(cq_marker "blocked") ${rid}  step: ${step}  (heartbeat ${age}s ago)${action}"
      done
    fi
  fi
}
