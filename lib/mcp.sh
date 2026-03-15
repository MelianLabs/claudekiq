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

# Build the tools list from cq schema
_mcp_build_tools() {
  # Commands to expose as MCP tools (skip meta commands like help, schema, version, init, config)
  local commands
  read -ra commands <<< "$(cq_command_list)"

  local -a tool_items=()
  local cmd
  for cmd in "${commands[@]}"; do
    local schema_json
    schema_json=$(cmd_schema "$cmd" 2>/dev/null) || continue

    local desc
    desc=$(jq -r '.description // ""' <<< "$schema_json")

    # Build input schema from parameters
    local properties="{}"
    local required="[]"
    local params param_count
    params=$(jq -c '.parameters // []' <<< "$schema_json")
    param_count=$(jq 'length' <<< "$params")

    local i
    for ((i = 0; i < param_count; i++)); do
      local param name type param_desc is_required json_type
      param=$(jq --argjson i "$i" '.[$i]' <<< "$params")
      name=$(jq -r '.name' <<< "$param" | sed 's/^--//' | sed 's/=.*$//' | tr '-' '_')
      type=$(jq -r '.type // "string"' <<< "$param")
      param_desc=$(jq -r '.description // ""' <<< "$param")
      is_required=$(jq -r '.required // false' <<< "$param")

      json_type=$(_mcp_json_type "$type")

      properties=$(jq \
        --arg name "$name" --arg type "$json_type" --arg desc "$param_desc" \
        '. + {($name): {type:$type, description:$desc}}' <<< "$properties")

      if [[ "$is_required" == "true" ]]; then
        required=$(jq --arg n "$name" '. + [$n]' <<< "$required")
      fi
    done

    local input_schema
    input_schema=$(jq -cn --argjson props "$properties" --argjson req "$required" \
      '{type:"object", properties:$props, required:$req}')

    # Tool name: replace hyphens with underscores, prefix with cq_
    local tool_name="cq_$(echo "$cmd" | tr '-' '_')"

    tool_items+=("$(jq -cn \
      --arg name "$tool_name" --arg desc "$desc" --argjson schema "$input_schema" \
      '{name:$name, description:$desc, inputSchema:$schema}')")
  done

  if [[ ${#tool_items[@]} -gt 0 ]]; then
    printf '%s\n' "${tool_items[@]}" | jq -s '.'
  else
    echo "[]"
  fi
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
      template=$(_mcp_arg "template" "$arguments")
      [[ -n "$template" ]] && args+=("$template")
      local keys
      keys=$(jq -r 'to_entries[] | select(.key != "template") | "\(.key)=\(.value)"' <<< "$arguments")
      while IFS= read -r kv; do
        [[ -n "$kv" ]] && args+=("--$kv")
      done <<< "$keys"
      cmd_start "${args[@]}"
      ;;
    status)
      local run_id
      run_id=$(_mcp_arg "run_id" "$arguments")
      [[ -n "$run_id" ]] && args+=("$run_id")
      cmd_status "${args[@]}"
      ;;
    list)
      cmd_list
      ;;
    log)
      local run_id tail_n
      run_id=$(_mcp_arg "run_id" "$arguments")
      tail_n=$(_mcp_arg "tail" "$arguments")
      [[ -n "$run_id" ]] && args+=("$run_id")
      [[ -n "$tail_n" ]] && args+=("--tail" "$tail_n")
      cmd_log "${args[@]}"
      ;;
    pause|resume|cancel|retry|heartbeat)
      cmd_"$(echo "$cmd" | tr '-' '_')" "$(_mcp_arg "run_id" "$arguments")"
      ;;
    step-done)
      local run_id step_id outcome result_json
      run_id=$(_mcp_arg "run_id" "$arguments")
      step_id=$(_mcp_arg "step_id" "$arguments")
      outcome=$(_mcp_arg "outcome" "$arguments")
      result_json=$(_mcp_arg "result_json" "$arguments")
      args=("$run_id" "$step_id" "$outcome")
      [[ -n "$result_json" ]] && args+=("$result_json")
      cmd_step_done "${args[@]}"
      ;;
    skip)
      local run_id step_id
      run_id=$(_mcp_arg "run_id" "$arguments")
      step_id=$(_mcp_arg "step_id" "$arguments")
      args=("$run_id")
      [[ -n "$step_id" ]] && args+=("$step_id")
      cmd_skip "${args[@]}"
      ;;
    todos)
      local flow
      flow=$(_mcp_arg "flow" "$arguments")
      [[ -n "$flow" ]] && args+=("--flow" "$flow")
      cmd_todos "${args[@]}"
      ;;
    todo)
      local index action note
      index=$(_mcp_arg "index" "$arguments")
      action=$(_mcp_arg "action" "$arguments")
      note=$(_mcp_arg "note" "$arguments")
      args=("$index" "$action")
      [[ -n "$note" ]] && args+=("--note" "$note")
      cmd_todo "${args[@]}"
      ;;
    ctx)
      local subcommand key value run_id
      subcommand=$(_mcp_arg "subcommand" "$arguments")
      key=$(_mcp_arg "key" "$arguments")
      value=$(_mcp_arg "value" "$arguments")
      run_id=$(_mcp_arg "run_id" "$arguments")
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
      run_id=$(_mcp_arg "run_id" "$arguments")
      step_json=$(_mcp_arg "step_json" "$arguments")
      after=$(_mcp_arg "after" "$arguments")
      args=("$run_id" "$step_json")
      [[ -n "$after" ]] && args+=("--after" "$after")
      cmd_add_step "${args[@]}"
      ;;
    add-steps)
      local run_id flow after
      run_id=$(_mcp_arg "run_id" "$arguments")
      flow=$(_mcp_arg "flow" "$arguments")
      after=$(_mcp_arg "after" "$arguments")
      args=("$run_id" "--flow" "$flow")
      [[ -n "$after" ]] && args+=("--after" "$after")
      cmd_add_steps "${args[@]}"
      ;;
    set-next)
      local run_id step_id target
      run_id=$(_mcp_arg "run_id" "$arguments")
      step_id=$(_mcp_arg "step_id" "$arguments")
      target=$(_mcp_arg "target" "$arguments")
      cmd_set_next "$run_id" "$step_id" "$target"
      ;;
    workflows)
      local subcommand name
      subcommand=$(_mcp_arg "subcommand" "$arguments")
      [[ -z "$subcommand" ]] && subcommand="list"
      name=$(_mcp_arg "name" "$arguments")
      args=("$subcommand")
      [[ -n "$name" ]] && args+=("$name")
      cmd_workflows "${args[@]}"
      ;;
    check-stale)
      local timeout mark
      timeout=$(_mcp_arg "timeout" "$arguments")
      mark=$(_mcp_arg "mark" "$arguments")
      [[ -n "$timeout" ]] && args+=("--timeout=$timeout")
      [[ "$mark" == "true" ]] && args+=("--mark")
      cmd_check_stale "${args[@]}"
      ;;
    cleanup)
      local max_age
      max_age=$(_mcp_arg "max_age" "$arguments")
      [[ -n "$max_age" ]] && args+=("--max-age=$max_age")
      cmd_cleanup "${args[@]}"
      ;;
    scan)
      cmd_scan
      ;;
    for-each)
      local over delimiter var command run_id step_id
      over=$(_mcp_arg "over" "$arguments")
      delimiter=$(_mcp_arg "delimiter" "$arguments")
      var=$(_mcp_arg "var" "$arguments")
      command=$(_mcp_arg "command" "$arguments")
      run_id=$(_mcp_arg "run_id" "$arguments")
      step_id=$(_mcp_arg "step_id" "$arguments")
      if [[ -n "$run_id" && -n "$step_id" ]]; then
        cmd_for_each "$run_id" "$step_id"
      else
        args=()
        [[ -n "$over" ]] && args+=("--over=$over")
        [[ -n "$delimiter" ]] && args+=("--delimiter=$delimiter")
        [[ -n "$var" ]] && args+=("--var=$var")
        [[ -n "$command" ]] && args+=("--command=$command")
        cmd_for_each "${args[@]}"
      fi
      ;;
    parallel)
      local steps_json fail_strategy run_id step_id
      steps_json=$(_mcp_arg "steps" "$arguments")
      fail_strategy=$(_mcp_arg "fail_strategy" "$arguments")
      run_id=$(_mcp_arg "run_id" "$arguments")
      step_id=$(_mcp_arg "step_id" "$arguments")
      if [[ -n "$run_id" && -n "$step_id" ]]; then
        cmd_parallel "$run_id" "$step_id"
      else
        args=()
        [[ -n "$steps_json" ]] && args+=("--steps=$steps_json")
        [[ -n "$fail_strategy" ]] && args+=("--fail-strategy=$fail_strategy")
        cmd_parallel "${args[@]}"
      fi
      ;;
    batch)
      local workflow jobs_json run_id step_id
      workflow=$(_mcp_arg "workflow" "$arguments")
      jobs_json=$(_mcp_arg "jobs" "$arguments")
      run_id=$(_mcp_arg "run_id" "$arguments")
      step_id=$(_mcp_arg "step_id" "$arguments")
      if [[ -n "$run_id" && -n "$step_id" ]]; then
        cmd_batch "$run_id" "$step_id"
      else
        args=()
        [[ -n "$workflow" ]] && args+=("--workflow=$workflow")
        [[ -n "$jobs_json" ]] && args+=("--jobs=$jobs_json")
        cmd_batch "${args[@]}"
      fi
      ;;
    workers)
      local subcommand session_id job_id action data
      subcommand=$(_mcp_arg "subcommand" "$arguments")
      [[ -z "$subcommand" ]] && subcommand="help"
      session_id=$(_mcp_arg "session_id" "$arguments")
      job_id=$(_mcp_arg "job_id" "$arguments")
      action=$(_mcp_arg "action" "$arguments")
      data=$(_mcp_arg "data" "$arguments")
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
