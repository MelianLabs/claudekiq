#!/usr/bin/env bats
load setup.bash

setup() {
  setup_test_project
}

teardown() {
  teardown_test_project
}

@test "start creates run directory" {
  local run_id
  run_id=$(start_minimal)
  [ -d ".claudekiq/runs/$run_id" ]
  [ -f ".claudekiq/runs/$run_id/meta.json" ]
  [ -f ".claudekiq/runs/$run_id/ctx.json" ]
  [ -f ".claudekiq/runs/$run_id/steps.json" ]
  [ -f ".claudekiq/runs/$run_id/state.json" ]
  [ -f ".claudekiq/runs/$run_id/log.jsonl" ]
}

@test "start sets initial status to running" {
  local run_id
  run_id=$(start_minimal)
  [ "$(run_meta "$run_id" status)" = "running" ]
}

@test "start sets current_step to first step" {
  local run_id
  run_id=$(start_minimal)
  [ "$(run_meta "$run_id" current_step)" = "step-a" ]
}

@test "start applies default context from workflow" {
  local run_id
  run_id=$(start_minimal)
  local greeting
  greeting=$(jq -r '.greeting' ".claudekiq/runs/$run_id/ctx.json")
  [ "$greeting" = "hello" ]
}

@test "start applies CLI context overrides" {
  local run_id
  run_id=$(start_minimal --greeting=world)
  local greeting
  greeting=$(jq -r '.greeting' ".claudekiq/runs/$run_id/ctx.json")
  [ "$greeting" = "world" ]
}

@test "start uses default priority" {
  local run_id
  run_id=$(start_minimal)
  [ "$(run_meta "$run_id" priority)" = "normal" ]
}

@test "start accepts --priority flag" {
  local run_id
  run_id=$("$CQ" start minimal --priority=urgent --json 2>/dev/null | jq -r '.run_id')
  [ "$(run_meta "$run_id" priority)" = "urgent" ]
}

@test "start rejects invalid priority" {
  run "$CQ" start minimal --priority=mega
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid priority"* ]]
}

@test "start initializes all steps as pending" {
  local run_id
  run_id=$(start_minimal)
  [ "$(step_state "$run_id" step-a status)" = "pending" ]
  [ "$(step_state "$run_id" step-b status)" = "pending" ]
  [ "$(step_state "$run_id" step-c status)" = "pending" ]
}

@test "start initializes visits to 0" {
  local run_id
  run_id=$(start_minimal)
  [ "$(step_state "$run_id" step-a visits)" = "0" ]
}

@test "start logs run_started event" {
  local run_id
  run_id=$(start_minimal)
  local event
  event=$(head -1 ".claudekiq/runs/$run_id/log.jsonl" | jq -r '.event')
  [ "$event" = "run_started" ]
}

@test "start copies steps from template" {
  local run_id
  run_id=$(start_minimal)
  local count
  count=$(jq 'length' ".claudekiq/runs/$run_id/steps.json")
  [ "$count" -eq 3 ]
}

@test "start nonexistent template fails" {
  run "$CQ" start nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "start queues when concurrency exceeded" {
  # Set concurrency to 1 (default)
  "$CQ" config set concurrency 1 >/dev/null
  local run1 run2
  run1=$(start_minimal)
  run2=$(start_minimal)
  [ "$(run_meta "$run1" status)" = "running" ]
  [ "$(run_meta "$run2" status)" = "queued" ]
}

@test "list shows all runs" {
  start_minimal >/dev/null
  start_minimal >/dev/null
  local output
  output=$("$CQ" --json list)
  local count
  count=$(echo "$output" | jq 'length')
  [ "$count" -eq 2 ]
}

@test "status dashboard" {
  start_minimal >/dev/null
  run "$CQ" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dashboard"* ]]
}

@test "status with run_id shows detail" {
  local run_id
  run_id=$(start_minimal)
  run "$CQ" status "$run_id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"step-a"* ]]
}

@test "log shows events" {
  local run_id
  run_id=$(start_minimal)
  run "$CQ" log "$run_id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"run_started"* ]]
}
