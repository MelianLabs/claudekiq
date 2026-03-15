#!/usr/bin/env bats
# test_interpolation.bats — Tests for jq-based interpolation engine

load setup.bash

setup() {
  setup_test_project
}

teardown() {
  teardown_test_project
}

# Helper: run cq_interpolate via cq's bash environment
interpolate() {
  local template="$1" ctx="$2"
  "$CQ" --json version >/dev/null 2>&1  # warm up to ensure cq is loadable
  bash -c "
    source '${CQ_ROOT}/lib/core.sh'
    CQ_JSON=false
    CQ_PROJECT_ROOT='$TEST_DIR'
    cq_interpolate \"\$1\" \"\$2\"
  " -- "$template" "$ctx"
}

@test "interpolation: simple key" {
  local result
  result=$(interpolate 'hello {{name}}' '{"name":"world"}')
  [ "$result" = "hello world" ]
}

@test "interpolation: multiple keys" {
  local result
  result=$(interpolate '{{a}} and {{b}}' '{"a":"hello","b":"world"}')
  [ "$result" = "hello and world" ]
}

@test "interpolation: repeated key" {
  local result
  result=$(interpolate '{{x}} or {{x}}' '{"x":"val"}')
  [ "$result" = "val or val" ]
}

@test "interpolation: missing key returns empty" {
  local result
  result=$(interpolate 'val={{missing}}' '{"other":"x"}')
  [ "$result" = "val=" ]
}

@test "interpolation: no vars passes through" {
  local result
  result=$(interpolate 'no vars here' '{}')
  [ "$result" = "no vars here" ]
}

@test "interpolation: nested object access" {
  local result
  result=$(interpolate 'timeout={{config.timeout}}' '{"config":{"timeout":30}}')
  [ "$result" = "timeout=30" ]
}

@test "interpolation: array indexing" {
  local result
  result=$(interpolate 'first={{items[0].name}}' '{"items":[{"name":"alpha"},{"name":"beta"}]}')
  [ "$result" = "first=alpha" ]
}

@test "interpolation: jq pipe expression" {
  local result
  result=$(interpolate 'count={{items | length}}' '{"items":[1,2,3]}')
  [ "$result" = "count=3" ]
}

@test "interpolation: deeply nested access" {
  local result
  result=$(interpolate '{{a.b.c}}' '{"a":{"b":{"c":"deep"}}}')
  [ "$result" = "deep" ]
}

@test "interpolation: mixed simple and nested" {
  local result
  result=$(interpolate '{{name}} has {{config.timeout}}s timeout' '{"name":"deploy","config":{"timeout":60}}')
  [ "$result" = "deploy has 60s timeout" ]
}

@test "interpolation: backward compat with workflow context" {
  # This simulates real workflow usage
  local run_id
  run_id=$(start_minimal)

  # Set context variable
  "$CQ" ctx set branch_name my-branch "$run_id" >/dev/null 2>&1
  local ctx
  ctx=$("$CQ" ctx "$run_id" --json 2>/dev/null)

  local result
  result=$(interpolate 'git checkout -b {{branch_name}}' "$ctx")
  [ "$result" = "git checkout -b my-branch" ]
}
