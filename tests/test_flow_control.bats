#!/usr/bin/env bats
load setup.bash

setup() {
  setup_test_project
}

teardown() {
  teardown_test_project
}

@test "pause running workflow" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" pause "$run_id" >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "paused" ]
}

@test "pause logs event" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" pause "$run_id" >/dev/null 2>&1
  grep -q '"run_paused"' ".claudekiq/runs/$run_id/log.jsonl"
}

@test "pause completed workflow fails" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" skip "$run_id" >/dev/null 2>&1
  "$CQ" skip "$run_id" >/dev/null 2>&1
  "$CQ" skip "$run_id" >/dev/null 2>&1
  run "$CQ" pause "$run_id"
  [ "$status" -eq 1 ]
}

@test "resume paused workflow" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" pause "$run_id" >/dev/null 2>&1
  "$CQ" resume "$run_id" >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "running" ]
}

@test "resume non-paused workflow fails" {
  local run_id
  run_id=$(start_minimal)
  run "$CQ" resume "$run_id"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be paused"* ]]
}

@test "cancel running workflow" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" cancel "$run_id" >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "cancelled" ]
}

@test "cancel completed workflow fails" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" skip "$run_id" >/dev/null 2>&1
  "$CQ" skip "$run_id" >/dev/null 2>&1
  "$CQ" skip "$run_id" >/dev/null 2>&1
  run "$CQ" cancel "$run_id"
  [ "$status" -eq 1 ]
}

@test "cancel cancelled workflow fails" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" cancel "$run_id" >/dev/null 2>&1
  run "$CQ" cancel "$run_id"
  [ "$status" -eq 1 ]
}

@test "retry failed workflow" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" step-done "$run_id" step-a fail >/dev/null 2>&1
  # For minimal workflow with auto gate, fail on step-a advances to step-b
  # Let's make a workflow that actually fails...
  # Actually for auto gate, fail still advances. Let's manually set status to failed.
  # We'll use a different approach - mark the run as failed via a step failure path

  # Reset: use with_routing which has human gate
  run_id=$(start_with_routing --mode=feature)
  "$CQ" step-done "$run_id" read-input pass >/dev/null 2>&1
  # Now at implement with human gate — need to mark step done to trigger gate
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  "$CQ" todo 1 reject >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "failed" ]

  "$CQ" retry "$run_id" >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "running" ]
  [ "$(step_state "$run_id" implement status)" = "pending" ]
}

@test "retry non-failed workflow fails" {
  local run_id
  run_id=$(start_minimal)
  run "$CQ" retry "$run_id"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be failed"* ]]
}
