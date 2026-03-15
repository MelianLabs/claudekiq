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
      cq_json_out --arg k "$key" --arg v "$val" '{($k):$v}' || \
        echo "$val"
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

      # Support dot-notation for nested keys (e.g., safety.git_commit)
      if [[ "$key" == *.* ]]; then
        local path
        path=$(echo "$key" | sed 's/\./"."/g')
        path=".\"${path}\""
        # Try to parse value as JSON, fall back to string
        if jq '.' <<< "$value" >/dev/null 2>&1; then
          config=$(jq --argjson v "$value" "${path} = \$v" <<< "$config")
        else
          config=$(jq --arg v "$value" "${path} = \$v" <<< "$config")
        fi
      else
        # Try to parse value as JSON, fall back to string
        if jq '.' <<< "$value" >/dev/null 2>&1; then
          config=$(jq --arg k "$key" --argjson v "$value" '.[$k] = $v' <<< "$config")
        else
          config=$(jq --arg k "$key" --arg v "$value" '.[$k] = $v' <<< "$config")
        fi
      fi
      jq '.' <<< "$config" > "$config_file"

      cq_json_out --arg k "$key" --arg v "$value" '{key:$k, value:$v}' || \
        cq_info "Set ${key}=${value}"
      ;;
    "")
      # Show resolved config
      local config
      config=$(cq_resolve_config)
      jq '.' <<< "$config"
      ;;
    *)
      cq_die "Unknown config subcommand: ${subcmd}"
      ;;
  esac
}
