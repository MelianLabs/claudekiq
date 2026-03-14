#!/usr/bin/env bash
# ctx.sh — Context variable commands

cmd_ctx() {
  local subcmd="${1:-}"

  case "$subcmd" in
    get)
      shift
      local key="${1:?Usage: cq ctx get <key> <run_id>}"
      local run_id="${2:?Usage: cq ctx get <key> <run_id>}"
      cq_require_run "$run_id" "cq ctx get <key> <run_id>" >/dev/null
      local val
      val=$(cq_ctx_get "$run_id" "$key")
      cq_json_out --arg k "$key" --arg v "$val" '{($k):$v}' || \
        echo "$val"
      ;;
    set)
      shift
      local key="${1:?Usage: cq ctx set <key> <value> <run_id>}"
      local value="${2:?Usage: cq ctx set <key> <value> <run_id>}"
      local run_id="${3:?Usage: cq ctx set <key> <value> <run_id>}"
      cq_require_run "$run_id" "cq ctx set <key> <value> <run_id>" >/dev/null
      cq_ctx_set "$run_id" "$key" "$value"
      cq_json_out --arg k "$key" --arg v "$value" --arg id "$run_id" '{key:$k, value:$v, run_id:$id}' || \
        cq_info "Set ${key}=${value} for run ${run_id}"
      ;;
    *)
      # Show all context for a run
      local run_id="${subcmd:?Usage: cq ctx <run_id>}"
      cq_require_run "$run_id" "cq ctx <run_id>" >/dev/null
      local ctx
      ctx=$(cq_read_ctx "$run_id")
      if [[ "$CQ_JSON" == "true" ]]; then
        jq '.' <<< "$ctx"
      else
        jq -r 'to_entries[] | "  \(.key) = \(.value)"' <<< "$ctx"
      fi
      ;;
  esac
}
