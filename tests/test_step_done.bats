#!/usr/bin/env bats
load setup.bash

setup() {
  setup_test_project
}

teardown() {
  teardown_test_project
}

@test "step-done pass marks step passed" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" step-done "$run_id" step-a pass >/dev/null 2>&1
  [ "$(step_state "$run_id" step-a status)" = "passed" ]
}

@test "step-done increments visits" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" step-done "$run_id" step-a pass >/dev/null 2>&1
  [ "$(step_state "$run_id" step-a visits)" = "1" ]
}

@test "step-done pass advances to next step" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" step-done "$run_id" step-a pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" current_step)" = "step-b" ]
}

@test "step-done on last step completes workflow" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" step-done "$run_id" step-a pass >/dev/null 2>&1
  "$CQ" step-done "$run_id" step-b pass >/dev/null 2>&1
  "$CQ" step-done "$run_id" step-c pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "completed" ]
}

@test "step-done fail marks step failed" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" step-done "$run_id" step-a fail >/dev/null 2>&1
  [ "$(step_state "$run_id" step-a status)" = "failed" ]
  [ "$(step_state "$run_id" step-a result)" = "fail" ]
}

@test "step-done logs step_done event" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" step-done "$run_id" step-a pass >/dev/null 2>&1
  grep -q '"step_done"' ".claudekiq/runs/$run_id/log.jsonl"
}

@test "step-done sets finished_at" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" step-done "$run_id" step-a pass >/dev/null 2>&1
  local finished
  finished=$(step_state "$run_id" step-a finished_at)
  [ "$finished" != "null" ]
}

@test "step-done with result_json stores data" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" step-done "$run_id" step-a pass '{"key":"value"}' >/dev/null 2>&1
  local result_data
  result_data=$(jq -r '.["step-a"].result_data.key' ".claudekiq/runs/$run_id/state.json")
  [ "$result_data" = "value" ]
}

@test "step-done rejects invalid outcome" {
  local run_id
  run_id=$(start_minimal)
  run "$CQ" step-done "$run_id" step-a maybe
  [ "$status" -eq 1 ]
  [[ "$output" == *"pass"*"fail"* ]]
}

@test "step-done nonexistent run fails" {
  run "$CQ" step-done nonexist step-a pass
  [ "$status" -eq 1 ]
}

@test "step-done follows on_pass routing" {
  local run_id
  run_id=$(start_with_routing --mode=feature)
  "$CQ" step-done "$run_id" read-input pass >/dev/null 2>&1
  # Should skip to implement (feature routing)
  [ "$(run_meta "$run_id" current_step)" = "implement" ]
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  # implement has human gate, so...
  # Actually implement is human gate - let's test on_pass with run-tests
}

@test "step-done follows on_fail routing" {
  local run_id
  run_id=$(start_with_routing --mode=feature)
  # Navigate to run-tests: read-input → implement (human gate) → approve → run-tests
  "$CQ" step-done "$run_id" read-input pass >/dev/null 2>&1
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  "$CQ" todo 1 approve >/dev/null 2>&1
  # Now at run-tests
  "$CQ" step-done "$run_id" run-tests fail >/dev/null 2>&1
  # on_fail of run-tests is implement
  [ "$(run_meta "$run_id" current_step)" = "implement" ]
}

@test "step-done follows conditional routing" {
  local run_id
  run_id=$(start_with_routing --mode=bug)
  "$CQ" step-done "$run_id" read-input pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" current_step)" = "investigate" ]
}

@test "step-done conditional routing default fallback" {
  local run_id
  run_id=$(start_with_routing --mode=unknown)
  "$CQ" step-done "$run_id" read-input pass >/dev/null 2>&1
  # default route goes to implement
  [ "$(run_meta "$run_id" current_step)" = "implement" ]
}

@test "skip marks step as skipped and advances" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" skip "$run_id" >/dev/null 2>&1
  [ "$(step_state "$run_id" step-a status)" = "skipped" ]
  [ "$(run_meta "$run_id" current_step)" = "step-b" ]
}

@test "skip named step" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" skip "$run_id" step-a >/dev/null 2>&1
  [ "$(step_state "$run_id" step-a status)" = "skipped" ]
}

@test "skip all steps completes workflow" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" skip "$run_id" >/dev/null 2>&1
  "$CQ" skip "$run_id" >/dev/null 2>&1
  "$CQ" skip "$run_id" >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "completed" ]
}
