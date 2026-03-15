#!/usr/bin/env bash
# mcp.sh — MCP (Model Context Protocol) stdio server for cq

# MCP protocol version we support
_MCP_PROTOCOL_VERSION="2024-11-05"

# Write a JSON-RPC response to stdout
_mcp_respond() {
  local id="$1" result="$2"
  jq -cn --argjson id "$id" --argjson result "$result" \
    '{"jsonrpc":"2.0","id":$id,"result":$result}'
}

# Write a JSON-RPC error to stdout
_mcp_error() {
  local id="$1" code="$2" message="$3"
  jq -cn --argjson id "$id" --argjson code "$code" --arg msg "$message" \
    '{"jsonrpc":"2.0","id":$id,"error":{"code":$code,"message":$msg}}'
}

# Handle initialize request
_mcp_handle_initialize() {
  local id="$1"
  _mcp_respond "$id" "$(jq -cn \
    --arg ver "$_MCP_PROTOCOL_VERSION" \
    --arg name "cq" \
    --arg version "$CQ_VERSION" \
    '{protocolVersion:$ver, capabilities:{tools:{}}, serverInfo:{name:$name, version:$version}}')"
}

# Map cq types to JSON Schema types
_mcp_json_type() {
  case "$1" in
    integer) echo "integer" ;;
    boolean) echo "boolean" ;;
    *)       echo "string" ;;
  esac
}

# Extract an argument from JSON, returning empty string if not present
_mcp_arg() {
  jq -r --arg k "$1" '.[$k] // empty' <<< "$2"
}

# Build the tools list from compact schema data in a single jq pass
_mcp_build_tools() {
  local commands
  commands=$(cq_command_list)
  local data
  data=$(_cq_schema_data)

  echo "$commands" | tr ' ' '\n' | jq -Rcs --argjson data "$data" '
    split("\n") | map(select(. != "")) | map(
      . as $cmd |
      $data[$cmd] // null |
      if . == null then empty
      else
        {
          name: ("cq_" + ($cmd | gsub("-"; "_"))),
          description: .d,
          inputSchema: {
            type: "object",
            properties: ([.a[] | {
              key: (.[0] | ltrimstr("--") | split("=")[0] | gsub("-"; "_")),
              value: {
                type: (if .[1] == "integer" then "integer" elif .[1] == "boolean" then "boolean" else "string" end),
                description: .[3]
              }
            }] | from_entries),
            required: [.a[] | select(.[2] == true) | .[0] | ltrimstr("--") | split("=")[0] | gsub("-"; "_")]
          }
        }
      end
    )
  '
}

# Handle tools/list request
_mcp_handle_tools_list() {
  local id="$1"
  local tools
  tools=$(_mcp_build_tools)
  _mcp_respond "$id" "$(jq -cn --argjson tools "$tools" '{tools:$tools}')"
}

# Generic schema-driven tool dispatcher
# Reads positional args from schema and builds command arguments automatically
_mcp_dispatch_tool() {
  local tool_name="$1" arguments="$2"

  # Force JSON output
  CQ_JSON="true"

  # Strip cq_ prefix and convert underscores back to hyphens
  local cmd
  cmd=$(echo "$tool_name" | sed 's/^cq_//' | tr '_' '-')

  # Get schema for this command
  local schema_json
  schema_json=$(cmd_schema "$cmd" 2>/dev/null) || {
    echo "Unknown tool: ${tool_name}" >&2
    return 1
  }

  # Build argument list
  local args=()

  # Special handling for 'start' command — extra keys become --key=val
  if [[ "$cmd" == "start" ]]; then
    local template
    template=$(_mcp_arg "template" "$arguments")
    [[ -n "$template" ]] && args+=("$template")
    local keys
    keys=$(jq -r 'to_entries[] | select(.key != "template") | "\(.key)=\(.value)"' <<< "$arguments")
    while IFS= read -r kv; do
      [[ -n "$kv" ]] && args+=("--$kv")
    done <<< "$keys"
    cmd_start "${args[@]}"
    return
  fi

  # Check if this is a subcommand-style command
  local subcommand_param
  subcommand_param=$(jq -r '.subcommand_param // empty' <<< "$schema_json")

  # Extract positional args in order from schema
  local positional
  positional=$(jq -r '.positional // [] | .[]' <<< "$schema_json")

  if [[ -n "$positional" ]]; then
    while IFS= read -r param_name; do
      [[ -z "$param_name" ]] && continue
      # Normalize: convert hyphens to underscores for JSON key lookup
      local json_key
      json_key=$(echo "$param_name" | tr '-' '_')
      local val
      val=$(_mcp_arg "$json_key" "$arguments")
      [[ -n "$val" ]] && args+=("$val")
    done <<< "$positional"
  fi

  # Extract --flag=value args from remaining parameters (those starting with --)
  local flag_params
  flag_params=$(jq -r '.parameters // [] | .[] | select(.name | startswith("--")) | .name | ltrimstr("--") | split("=")[0]' <<< "$schema_json")
  if [[ -n "$flag_params" ]]; then
    while IFS= read -r flag_name; do
      [[ -z "$flag_name" ]] && continue
      local json_key
      json_key=$(echo "$flag_name" | tr '-' '_')
      local val
      val=$(_mcp_arg "$json_key" "$arguments")
      if [[ -n "$val" ]]; then
        # Boolean flags: just add the flag without value
        if [[ "$val" == "true" ]]; then
          local param_type
          param_type=$(jq -r --arg n "--${flag_name}" '.parameters[] | select(.name == $n) | .type // "string"' <<< "$schema_json")
          if [[ "$param_type" == "boolean" ]]; then
            args+=("--${flag_name}")
          else
            args+=("--${flag_name}=${val}")
          fi
        else
          args+=("--${flag_name}=${val}")
        fi
      fi
    done <<< "$flag_params"
  fi

  # Dispatch to the command function
  local func_name="cmd_$(echo "$cmd" | tr '-' '_')"
  "$func_name" "${args[@]}"
}

# Handle tools/call request
_mcp_handle_tools_call() {
  local id="$1" params="$2"

  local tool_name arguments
  tool_name=$(jq -r '.name' <<< "$params")
  arguments=$(jq -c '.arguments // {}' <<< "$params")

  local output exit_code
  output=$(_mcp_dispatch_tool "$tool_name" "$arguments" 2>/dev/null) && exit_code=0 || exit_code=$?

  if [[ $exit_code -eq 0 ]]; then
    _mcp_respond "$id" "$(jq -cn --arg text "$output" \
      '{content:[{type:"text",text:$text}]}')"
  else
    _mcp_respond "$id" "$(jq -cn --arg text "$output" \
      '{content:[{type:"text",text:$text}],isError:true}')"
  fi
}

# Main MCP server loop
cq_mcp_serve() {
  # Log to stderr (stdout is reserved for MCP protocol)
  echo "cq mcp server v${CQ_VERSION} starting..." >&2

  local line
  while IFS= read -r line; do
    # Skip empty lines
    [[ -z "$line" ]] && continue

    local id method params
    id=$(jq -r '.id // null' <<< "$line")
    method=$(jq -r '.method // ""' <<< "$line")
    params=$(jq -c '.params // {}' <<< "$line")

    case "$method" in
      initialize)
        _mcp_handle_initialize "$id"
        ;;
      initialized)
        # Notification, no response needed
        ;;
      tools/list)
        _mcp_handle_tools_list "$id"
        ;;
      tools/call)
        _mcp_handle_tools_call "$id" "$params"
        ;;
      notifications/*)
        # Notifications don't need responses
        ;;
      *)
        if [[ "$id" != "null" ]]; then
          _mcp_error "$id" -32601 "Method not found: ${method}"
        fi
        ;;
    esac
  done
}
