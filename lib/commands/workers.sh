#!/usr/bin/env bash
# workers.sh — Parallel orchestration: workers init, status, answer, cleanup

cmd_workers() {
  local subcmd="${1:-}"
  shift 2>/dev/null || true

  case "$subcmd" in
    init)
      _workers_init "$@"
      ;;
    status)
      _workers_status "$@"
      ;;
    answer)
      _workers_answer "$@"
      ;;
    cleanup)
      _workers_cleanup "$@"
      ;;
    ""|help)
      cq_info "Usage: cq workers <init|status|answer|cleanup>"
      cq_info ""
      cq_info "Subcommands:"
      cq_info "  init                    Create a new worker session"
      cq_info "  status <session_id>     Show status of all workers in a session"
      cq_info "  answer <sid> <jid> <action> [data]  Answer a gated worker"
      cq_info "  cleanup [--max-age=N]   Remove old worker sessions"
      ;;
    *)
      cq_die "Unknown workers subcommand: ${subcmd}"
      ;;
  esac
}

_workers_init() {
  local session_id
  session_id=$(cq_gen_id)
  local workers_dir="${CQ_PROJECT_ROOT}/.claudekiq/workers/${session_id}"
  mkdir -p "$workers_dir"

  local ts
  ts=$(cq_now)

  jq -cn \
    --arg sid "$session_id" \
    --arg ts "$ts" \
    --arg root "$CQ_PROJECT_ROOT" \
    '{session_id:$sid, created_at:$ts, parent_root:$root}' \
    > "${workers_dir}/manifest.json"

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg sid "$session_id" --arg dir "$workers_dir" \
      '{session_id:$sid, directory:$dir}'
  else
    echo "Worker session ${session_id} created."
  fi
}

_workers_status() {
  local session_id="${1:?Usage: cq workers status <session_id>}"
  local workers_dir="${CQ_PROJECT_ROOT}/.claudekiq/workers/${session_id}"

  if [[ ! -d "$workers_dir" ]]; then
    cq_die "Worker session '${session_id}' not found"
  fi

  local jobs_json="[]"
  local status_file
  for status_file in "${workers_dir}"/*.status.json; do
    [[ -f "$status_file" ]] || continue
    local job_data
    job_data=$(cat "$status_file")
    local job_id
    job_id=$(basename "$status_file" .status.json)
    job_data=$(echo "$job_data" | jq --arg jid "$job_id" '. + {job_id:$jid}')
    jobs_json=$(echo "$jobs_json" | jq --argjson j "$job_data" '. + [$j]')
  done

  # Aggregate counts
  local running gated completed failed
  running=$(echo "$jobs_json" | jq '[.[] | select(.status=="running")] | length')
  gated=$(echo "$jobs_json" | jq '[.[] | select(.status=="gated")] | length')
  completed=$(echo "$jobs_json" | jq '[.[] | select(.status=="completed")] | length')
  failed=$(echo "$jobs_json" | jq '[.[] | select(.status=="failed")] | length')
  local total
  total=$(echo "$jobs_json" | jq 'length')

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn \
      --arg sid "$session_id" \
      --argjson jobs "$jobs_json" \
      --argjson running "$running" \
      --argjson gated "$gated" \
      --argjson completed "$completed" \
      --argjson failed "$failed" \
      --argjson total "$total" \
      '{session_id:$sid, total:$total, running:$running, gated:$gated, completed:$completed, failed:$failed, jobs:$jobs}'
  else
    echo "Session: ${session_id} — ${total} workers (${running} running, ${gated} gated, ${completed} completed, ${failed} failed)"
    echo "$jobs_json" | jq -r '.[] | "  [\(.job_id)] \(.status) — step: \(.step // "n/a")"'
  fi
}

_workers_answer() {
  local session_id="${1:?Usage: cq workers answer <session_id> <job_id> <action> [data_json]}"
  local job_id="${2:?Usage: cq workers answer <session_id> <job_id> <action> [data_json]}"
  local action="${3:?Usage: cq workers answer <session_id> <job_id> <action> [data_json]}"
  local data_json="${4:-"{}"}"

  local workers_dir="${CQ_PROJECT_ROOT}/.claudekiq/workers/${session_id}"
  if [[ ! -d "$workers_dir" ]]; then
    cq_die "Worker session '${session_id}' not found"
  fi

  local ts
  ts=$(cq_now)

  # Build the answer JSON — try data as JSON object, fall back to string wrapper
  local answer_json
  answer_json=$(jq -cn \
    --arg action "$action" \
    --argjson data "$data_json" \
    --arg ts "$ts" \
    '{action:$action, data:$data, answered_at:$ts}' 2>/dev/null) || \
  answer_json=$(jq -cn \
    --arg action "$action" \
    --arg rawdata "$data_json" \
    --arg ts "$ts" \
    '{action:$action, data:{message:$rawdata}, answered_at:$ts}')

  echo "$answer_json" > "${workers_dir}/${job_id}.answer.json"

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg sid "$session_id" --arg jid "$job_id" --arg action "$action" \
      '{session_id:$sid, job_id:$jid, action:$action}'
  else
    echo "Answer sent to worker ${job_id}: ${action}"
  fi
}

_workers_cleanup() {
  local max_age=2592000  # 30 days default

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max-age=*) max_age="${1#*=}" ;;
      *) ;;
    esac
    shift
  done

  local workers_base="${CQ_PROJECT_ROOT}/.claudekiq/workers"
  if [[ ! -d "$workers_base" ]]; then
    if [[ "$CQ_JSON" == "true" ]]; then
      jq -cn '{removed:0}'
    else
      echo "No worker sessions found."
    fi
    return 0
  fi

  local removed=0
  local session_dir
  for session_dir in "${workers_base}"/*/; do
    [[ -d "$session_dir" ]] || continue
    local manifest="${session_dir}manifest.json"
    [[ -f "$manifest" ]] || continue

    local age
    age=$(cq_file_age "$manifest")
    if [[ "$age" -ge "$max_age" ]]; then
      rm -rf "$session_dir"
      removed=$((removed + 1))
    fi
  done

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --argjson n "$removed" '{removed:$n}'
  else
    echo "Removed ${removed} expired worker session(s)."
  fi
}
