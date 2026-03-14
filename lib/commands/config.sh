#!/usr/bin/env bash
# config.sh — Configuration commands

cmd_config() {
  local subcmd="${1:-}"

  case "$subcmd" in
    get)
      shift
      local key="${1:?Usage: cq config get <key>}"
      local val
      val=$(cq_config_get "$key")
      if [[ "$CQ_JSON" == "true" ]]; then
        jq -cn --arg k "$key" --arg v "$val" '{($k):$v}'
      else
        echo "$val"
      fi
      ;;
    set)
      shift
      local is_global=false
      if [[ "$1" == "--global" ]]; then
        is_global=true
        shift
      fi
      local key="${1:?Usage: cq config set [--global] <key> <value>}"
      local value="${2:?Usage: cq config set [--global] <key> <value>}"

      local config_file
      if $is_global; then
        config_file="${HOME}/.cq/config.json"
        mkdir -p "${HOME}/.cq"
      else
        config_file="${CQ_PROJECT_ROOT}/.claudekiq/settings.json"
      fi

      # Ensure file exists
      [[ -f "$config_file" ]] || echo '{}' > "$config_file"

      local config
      config=$(cat "$config_file")
      # Try to parse value as JSON, fall back to string
      if echo "$value" | jq '.' >/dev/null 2>&1; then
        config=$(echo "$config" | jq --arg k "$key" --argjson v "$value" '.[$k] = $v')
      else
        config=$(echo "$config" | jq --arg k "$key" --arg v "$value" '.[$k] = $v')
      fi
      echo "$config" | jq '.' > "$config_file"

      cq_info "Set ${key}=${value}"
      if [[ "$CQ_JSON" == "true" ]]; then
        jq -cn --arg k "$key" --arg v "$value" '{key:$k, value:$v}'
      fi
      ;;
    "")
      # Show resolved config
      local config
      config=$(cq_resolve_config)
      echo "$config" | jq '.'
      ;;
    *)
      cq_die "Unknown config subcommand: ${subcmd}"
      ;;
  esac
}
