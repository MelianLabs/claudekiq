#!/usr/bin/env bash
# ctx.sh — Context variable commands

cmd_ctx() {
  local subcmd="${1:-}"

  case "$subcmd" in
    get)
      shift
      local key="${1:?Usage: cq ctx get <key> <run_id>}"
      local run_id="${2:?Usage: cq ctx get <key> <run_id>}"
      cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"
      local val
      val=$(cq_ctx_get "$run_id" "$key")
      if [[ "$CQ_JSON" == "true" ]]; then
        jq -cn --arg k "$key" --arg v "$val" '{($k):$v}'
      else
        echo "$val"
      fi
      ;;
    set)
      shift
      local key="${1:?Usage: cq ctx set <key> <value> <run_id>}"
      local value="${2:?Usage: cq ctx set <key> <value> <run_id>}"
      local run_id="${3:?Usage: cq ctx set <key> <value> <run_id>}"
      cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"
      cq_ctx_set "$run_id" "$key" "$value"
      cq_info "Set ${key}=${value} for run ${run_id}"
      if [[ "$CQ_JSON" == "true" ]]; then
        jq -cn --arg k "$key" --arg v "$value" --arg id "$run_id" '{key:$k, value:$v, run_id:$id}'
      fi
      ;;
    *)
      # Show all context for a run
      local run_id="${subcmd:?Usage: cq ctx <run_id>}"
      cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"
      local ctx
      ctx=$(cq_read_ctx "$run_id")
      if [[ "$CQ_JSON" == "true" ]]; then
        echo "$ctx" | jq '.'
      else
        echo "$ctx" | jq -r 'to_entries[] | "  \(.key) = \(.value)"'
      fi
      ;;
  esac
}
