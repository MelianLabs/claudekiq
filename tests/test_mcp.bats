#!/usr/bin/env bats
# test_mcp.bats — Tests for MCP stdio server

load setup.bash

setup() {
  setup_test_project
}

teardown() {
  teardown_test_project
}

# Helper: send a JSON-RPC request to cq mcp and capture the response
mcp_request() {
  echo "$1" | "$CQ" mcp 2>/dev/null
}

# Helper: send multiple JSON-RPC requests (one per line)
mcp_requests() {
  printf '%s\n' "$@" | "$CQ" mcp 2>/dev/null
}

# ============================================================
# initialize
# ============================================================

@test "mcp initialize returns server info" {
  local resp
  resp=$(mcp_request '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}')
  [ "$(echo "$resp" | jq -r '.result.serverInfo.name')" = "cq" ]
  [ "$(echo "$resp" | jq -r '.result.protocolVersion')" = "2024-11-05" ]
  [ "$(echo "$resp" | jq -r '.result.capabilities.tools')" = "{}" ]
}

@test "mcp initialize includes version" {
  local resp
  resp=$(mcp_request '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}')
  [ "$(echo "$resp" | jq -r '.result.serverInfo.version')" != "null" ]
  [ "$(echo "$resp" | jq -r '.result.serverInfo.version')" != "" ]
}

# ============================================================
# tools/list
# ============================================================

@test "mcp tools/list returns tools array" {
  local resp
  resp=$(mcp_request '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
  [ "$(echo "$resp" | jq -r '.result.tools | type')" = "array" ]
  [ "$(echo "$resp" | jq '.result.tools | length')" -gt 0 ]
}

@test "mcp tools/list includes cq_start tool" {
  local resp
  resp=$(mcp_request '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
  local has_start
  has_start=$(echo "$resp" | jq '[.result.tools[] | select(.name == "cq_start")] | length')
  [ "$has_start" -eq 1 ]
}

@test "mcp tools/list includes cq_status tool" {
  local resp
  resp=$(mcp_request '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
  local has_status
  has_status=$(echo "$resp" | jq '[.result.tools[] | select(.name == "cq_status")] | length')
  [ "$has_status" -eq 1 ]
}

@test "mcp tools have inputSchema" {
  local resp
  resp=$(mcp_request '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
  local schema_type
  schema_type=$(echo "$resp" | jq -r '.result.tools[0].inputSchema.type')
  [ "$schema_type" = "object" ]
}

@test "mcp tools use underscore names" {
  local resp
  resp=$(mcp_request '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
  # All tool names should start with cq_ and have no hyphens
  local bad_names
  bad_names=$(echo "$resp" | jq '[.result.tools[] | select(.name | test("-"))] | length')
  [ "$bad_names" -eq 0 ]
}

# ============================================================
# tools/call
# ============================================================

@test "mcp tools/call cq_workflows list" {
  local resp
  resp=$(mcp_request '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"cq_workflows","arguments":{"subcommand":"list"}}}')
  [ "$(echo "$resp" | jq -r '.result.content[0].type')" = "text" ]
  [[ "$(echo "$resp" | jq -r '.result.content[0].text')" == *"minimal"* ]]
}

@test "mcp tools/call cq_list returns JSON" {
  local resp
  resp=$(mcp_request '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"cq_list","arguments":{}}}')
  [ "$(echo "$resp" | jq -r '.result.content[0].type')" = "text" ]
  # Output should be valid JSON (array)
  echo "$(echo "$resp" | jq -r '.result.content[0].text')" | jq '.' >/dev/null
}

@test "mcp tools/call cq_start starts a workflow" {
  local resp
  resp=$(mcp_request '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"cq_start","arguments":{"template":"minimal"}}}')
  [ "$(echo "$resp" | jq -r '.result.isError // false')" = "false" ]
  local text
  text=$(echo "$resp" | jq -r '.result.content[0].text')
  [ "$(echo "$text" | jq -r '.run_id')" != "null" ]
  [ "$(echo "$text" | jq -r '.status')" = "running" ]
}

@test "mcp tools/call cq_status with run_id" {
  local rid
  rid=$(start_minimal)

  local resp
  resp=$(mcp_request "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"cq_status\",\"arguments\":{\"run_id\":\"$rid\"}}}")
  [ "$(echo "$resp" | jq -r '.result.isError // false')" = "false" ]
  local text
  text=$(echo "$resp" | jq -r '.result.content[0].text')
  [ "$(echo "$text" | jq -r '.meta.status')" = "running" ]
}

@test "mcp tools/call cq_heartbeat" {
  local rid
  rid=$(start_minimal)

  local resp
  resp=$(mcp_request "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"cq_heartbeat\",\"arguments\":{\"run_id\":\"$rid\"}}}")
  [ "$(echo "$resp" | jq -r '.result.isError // false')" = "false" ]
  [ -f "$TEST_DIR/.claudekiq/runs/$rid/.heartbeat" ]
}

@test "mcp tools/call returns error for unknown tool" {
  local resp
  resp=$(mcp_request '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"cq_nonexistent","arguments":{}}}')
  [ "$(echo "$resp" | jq -r '.result.isError')" = "true" ]
}

# ============================================================
# error handling
# ============================================================

@test "mcp unknown method returns error" {
  local resp
  resp=$(mcp_request '{"jsonrpc":"2.0","id":9,"method":"unknown/method","params":{}}')
  [ "$(echo "$resp" | jq -r '.error.code')" = "-32601" ]
}

@test "mcp notification does not produce response" {
  local resp
  resp=$(mcp_request '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}')
  # Notifications have no id, so no response should be produced
  # The output should be empty or not contain an id-based response
  [[ -z "$resp" || "$resp" == "" ]]
}

# ============================================================
# multi-message session
# ============================================================

@test "mcp handles initialize + tools/list sequence" {
  local resp
  resp=$(mcp_requests \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')

  # Should have two responses (initialize + tools/list, not the notification)
  local count
  count=$(echo "$resp" | jq -s 'length')
  [ "$count" -eq 2 ]

  # First is initialize
  [ "$(echo "$resp" | jq -s '.[0].result.serverInfo.name')" = "\"cq\"" ]
  # Second is tools/list
  [ "$(echo "$resp" | jq -s '.[1].result.tools | type')" = "\"array\"" ]
}

# ============================================================
# schema
# ============================================================

@test "schema mcp returns valid JSON" {
  run "$CQ" schema mcp
  [ "$status" -eq 0 ]
  echo "$output" | jq '.' >/dev/null
  [[ "$output" == *"mcp"* ]]
}
