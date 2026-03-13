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

# Convert a cq schema parameter to JSON Schema property
_mcp_param_to_property() {
  local param="$1"
  local name type desc
  name=$(echo "$param" | jq -r '.name' | sed 's/^--//' | sed 's/=.*$//' | tr '-' '_')
  type=$(echo "$param" | jq -r '.type // "string"')
  desc=$(echo "$param" | jq -r '.description // ""')

  # Map cq types to JSON Schema types
  local json_type="string"
  case "$type" in
    integer) json_type="integer" ;;
    boolean) json_type="boolean" ;;
    json)    json_type="string" ;;
    *)       json_type="string" ;;
  esac

  jq -cn --arg name "$name" --arg type "$json_type" --arg desc "$desc" \
    '{($name): {type:$type, description:$desc}}'
}

# Build the tools list from cq schema
_mcp_build_tools() {
  local tools="[]"

  # Commands to expose as MCP tools (skip meta commands like help, schema, version, init, config)
  local commands=("start" "status" "list" "log" "pause" "resume" "cancel" "retry"
                  "step-done" "skip" "todos" "todo" "ctx" "add-step" "add-steps"
                  "set-next" "workflows" "heartbeat" "check-stale" "cleanup"
                  "workers")

  local cmd
  for cmd in "${commands[@]}"; do
    local schema_json
    schema_json=$(cmd_schema "$cmd" 2>/dev/null) || continue

    local desc
    desc=$(echo "$schema_json" | jq -r '.description // ""')

    # Build input schema from parameters
    local properties="{}"
    local required="[]"
    local params
    params=$(echo "$schema_json" | jq -c '.parameters // []')
    local param_count
    param_count=$(echo "$params" | jq 'length')

    local i
    for ((i = 0; i < param_count; i++)); do
      local param name type param_desc is_required
      param=$(echo "$params" | jq --argjson i "$i" '.[$i]')
      name=$(echo "$param" | jq -r '.name' | sed 's/^--//' | sed 's/=.*$//' | tr '-' '_')
      type=$(echo "$param" | jq -r '.type // "string"')
      param_desc=$(echo "$param" | jq -r '.description // ""')
      is_required=$(echo "$param" | jq -r '.required // false')

      local json_type="string"
      case "$type" in
        integer) json_type="integer" ;;
        boolean) json_type="boolean" ;;
        *)       json_type="string" ;;
      esac

      properties=$(echo "$properties" | jq \
        --arg name "$name" --arg type "$json_type" --arg desc "$param_desc" \
        '. + {($name): {type:$type, description:$desc}}')

      if [[ "$is_required" == "true" ]]; then
        required=$(echo "$required" | jq --arg n "$name" '. + [$n]')
      fi
    done

    local input_schema
    input_schema=$(jq -cn --argjson props "$properties" --argjson req "$required" \
      '{type:"object", properties:$props, required:$req}')

    # Tool name: replace hyphens with underscores, prefix with cq_
    local tool_name="cq_$(echo "$cmd" | tr '-' '_')"

    tools=$(echo "$tools" | jq \
      --arg name "$tool_name" --arg desc "$desc" --argjson schema "$input_schema" \
      '. + [{name:$name, description:$desc, inputSchema:$schema}]')
  done

  echo "$tools"
}

# Handle tools/list request
_mcp_handle_tools_list() {
  local id="$1"
  local tools
  tools=$(_mcp_build_tools)
  _mcp_respond "$id" "$(jq -cn --argjson tools "$tools" '{tools:$tools}')"
}

# Dispatch a tool call to the appropriate cq command
_mcp_dispatch_tool() {
  local tool_name="$1" arguments="$2"

  # Force JSON output
  CQ_JSON="true"

  # Strip cq_ prefix and convert underscores back to hyphens
  local cmd
  cmd=$(echo "$tool_name" | sed 's/^cq_//' | tr '_' '-')

  # Build argument list from JSON arguments
  local args=()

  case "$cmd" in
    start)
      local template
      template=$(echo "$arguments" | jq -r '.template // empty')
      [[ -n "$template" ]] && args+=("$template")
      # Add key=value pairs from remaining args
      local keys
      keys=$(echo "$arguments" | jq -r 'to_entries[] | select(.key != "template") | "\(.key)=\(.value)"')
      while IFS= read -r kv; do
        [[ -n "$kv" ]] && args+=("--$kv")
      done <<< "$keys"
      cmd_start "${args[@]}"
      ;;
    status)
      local run_id
      run_id=$(echo "$arguments" | jq -r '.run_id // empty')
      [[ -n "$run_id" ]] && args+=("$run_id")
      cmd_status "${args[@]}"
      ;;
    list)
      cmd_list
      ;;
    log)
      local run_id tail_n
      run_id=$(echo "$arguments" | jq -r '.run_id // empty')
      tail_n=$(echo "$arguments" | jq -r '.tail // empty')
      [[ -n "$run_id" ]] && args+=("$run_id")
      [[ -n "$tail_n" ]] && args+=("--tail" "$tail_n")
      cmd_log "${args[@]}"
      ;;
    pause)
      local run_id
      run_id=$(echo "$arguments" | jq -r '.run_id // empty')
      cmd_pause "$run_id"
      ;;
    resume)
      local run_id
      run_id=$(echo "$arguments" | jq -r '.run_id // empty')
      cmd_resume "$run_id"
      ;;
    cancel)
      local run_id
      run_id=$(echo "$arguments" | jq -r '.run_id // empty')
      cmd_cancel "$run_id"
      ;;
    retry)
      local run_id
      run_id=$(echo "$arguments" | jq -r '.run_id // empty')
      cmd_retry "$run_id"
      ;;
    step-done)
      local run_id step_id outcome result_json
      run_id=$(echo "$arguments" | jq -r '.run_id // empty')
      step_id=$(echo "$arguments" | jq -r '.step_id // empty')
      outcome=$(echo "$arguments" | jq -r '.outcome // empty')
      result_json=$(echo "$arguments" | jq -r '.result_json // empty')
      args=("$run_id" "$step_id" "$outcome")
      [[ -n "$result_json" ]] && args+=("$result_json")
      cmd_step_done "${args[@]}"
      ;;
    skip)
      local run_id step_id
      run_id=$(echo "$arguments" | jq -r '.run_id // empty')
      step_id=$(echo "$arguments" | jq -r '.step_id // empty')
      args=("$run_id")
      [[ -n "$step_id" ]] && args+=("$step_id")
      cmd_skip "${args[@]}"
      ;;
    todos)
      local flow
      flow=$(echo "$arguments" | jq -r '.flow // empty')
      [[ -n "$flow" ]] && args+=("--flow" "$flow")
      cmd_todos "${args[@]}"
      ;;
    todo)
      local index action note
      index=$(echo "$arguments" | jq -r '.index // empty')
      action=$(echo "$arguments" | jq -r '.action // empty')
      note=$(echo "$arguments" | jq -r '.note // empty')
      args=("$index" "$action")
      [[ -n "$note" ]] && args+=("--note" "$note")
      cmd_todo "${args[@]}"
      ;;
    ctx)
      local subcommand key value run_id
      subcommand=$(echo "$arguments" | jq -r '.subcommand // empty')
      key=$(echo "$arguments" | jq -r '.key // empty')
      value=$(echo "$arguments" | jq -r '.value // empty')
      run_id=$(echo "$arguments" | jq -r '.run_id // empty')
      if [[ -n "$subcommand" ]]; then
        args+=("$subcommand")
        [[ -n "$key" ]] && args+=("$key")
        [[ -n "$value" ]] && args+=("$value")
      fi
      [[ -n "$run_id" ]] && args+=("$run_id")
      cmd_ctx "${args[@]}"
      ;;
    add-step)
      local run_id step_json after
      run_id=$(echo "$arguments" | jq -r '.run_id // empty')
      step_json=$(echo "$arguments" | jq -r '.step_json // empty')
      after=$(echo "$arguments" | jq -r '.after // empty')
      args=("$run_id" "$step_json")
      [[ -n "$after" ]] && args+=("--after" "$after")
      cmd_add_step "${args[@]}"
      ;;
    add-steps)
      local run_id flow after
      run_id=$(echo "$arguments" | jq -r '.run_id // empty')
      flow=$(echo "$arguments" | jq -r '.flow // empty')
      after=$(echo "$arguments" | jq -r '.after // empty')
      args=("$run_id" "--flow" "$flow")
      [[ -n "$after" ]] && args+=("--after" "$after")
      cmd_add_steps "${args[@]}"
      ;;
    set-next)
      local run_id step_id target
      run_id=$(echo "$arguments" | jq -r '.run_id // empty')
      step_id=$(echo "$arguments" | jq -r '.step_id // empty')
      target=$(echo "$arguments" | jq -r '.target // empty')
      cmd_set_next "$run_id" "$step_id" "$target"
      ;;
    workflows)
      local subcommand name
      subcommand=$(echo "$arguments" | jq -r '.subcommand // "list"')
      name=$(echo "$arguments" | jq -r '.name // empty')
      args=("$subcommand")
      [[ -n "$name" ]] && args+=("$name")
      cmd_workflows "${args[@]}"
      ;;
    heartbeat)
      local run_id
      run_id=$(echo "$arguments" | jq -r '.run_id // empty')
      cmd_heartbeat "$run_id"
      ;;
    check-stale)
      local timeout mark
      timeout=$(echo "$arguments" | jq -r '.timeout // empty')
      mark=$(echo "$arguments" | jq -r '.mark // empty')
      [[ -n "$timeout" ]] && args+=("--timeout=$timeout")
      [[ "$mark" == "true" ]] && args+=("--mark")
      cmd_check_stale "${args[@]}"
      ;;
    cleanup)
      local max_age
      max_age=$(echo "$arguments" | jq -r '.max_age // empty')
      [[ -n "$max_age" ]] && args+=("--max-age=$max_age")
      cmd_cleanup "${args[@]}"
      ;;
    workers)
      local subcommand session_id job_id action data
      subcommand=$(echo "$arguments" | jq -r '.subcommand // "help"')
      session_id=$(echo "$arguments" | jq -r '.session_id // empty')
      job_id=$(echo "$arguments" | jq -r '.job_id // empty')
      action=$(echo "$arguments" | jq -r '.action // empty')
      data=$(echo "$arguments" | jq -r '.data // empty')
      args=("$subcommand")
      [[ -n "$session_id" ]] && args+=("$session_id")
      [[ -n "$job_id" ]] && args+=("$job_id")
      [[ -n "$action" ]] && args+=("$action")
      [[ -n "$data" ]] && args+=("$data")
      cmd_workers "${args[@]}"
      ;;
    *)
      echo "Unknown tool: ${tool_name}" >&2
      return 1
      ;;
  esac
}

# Handle tools/call request
_mcp_handle_tools_call() {
  local id="$1" params="$2"

  local tool_name arguments
  tool_name=$(echo "$params" | jq -r '.name')
  arguments=$(echo "$params" | jq -c '.arguments // {}')

  local output exit_code
  output=$(_mcp_dispatch_tool "$tool_name" "$arguments" 2>&1) && exit_code=0 || exit_code=$?

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
    id=$(echo "$line" | jq -r '.id // null')
    method=$(echo "$line" | jq -r '.method // ""')
    params=$(echo "$line" | jq -c '.params // {}')

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
