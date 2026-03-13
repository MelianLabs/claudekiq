#!/usr/bin/env bats
load setup.bash

setup() {
  setup_test_project
}

teardown() {
  teardown_test_project
}

@test "add-step appends step to workflow" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" add-step "$run_id" '{"id":"extra","type":"bash","target":"echo extra","gate":"auto"}' >/dev/null 2>&1
  local count
  count=$(jq 'length' ".claudekiq/runs/$run_id/steps.json")
  [ "$count" -eq 4 ]
}

@test "add-step inserts after specified step" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" add-step "$run_id" '{"id":"extra","type":"bash","target":"echo extra","gate":"auto"}' --after step-a >/dev/null 2>&1
  local second_id
  second_id=$(jq -r '.[1].id' ".claudekiq/runs/$run_id/steps.json")
  [ "$second_id" = "extra" ]
}

@test "add-step initializes state for new step" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" add-step "$run_id" '{"id":"extra","type":"bash","target":"echo extra","gate":"auto"}' >/dev/null 2>&1
  [ "$(step_state "$run_id" extra status)" = "pending" ]
}

@test "add-step with invalid JSON fails" {
  local run_id
  run_id=$(start_minimal)
  run "$CQ" add-step "$run_id" 'not json'
  [ "$status" -eq 1 ]
}

@test "add-step without id fails" {
  local run_id
  run_id=$(start_minimal)
  run "$CQ" add-step "$run_id" '{"type":"bash"}'
  [ "$status" -eq 1 ]
}

@test "add-steps inserts subflow steps" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" add-steps "$run_id" --flow minimal --after step-a >/dev/null 2>&1
  local count
  count=$(jq 'length' ".claudekiq/runs/$run_id/steps.json")
  # 3 original + 3 from subflow = 6
  [ "$count" -eq 6 ]
}

@test "add-steps prefixes subflow step IDs" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" add-steps "$run_id" --flow minimal --after step-a >/dev/null 2>&1
  local prefixed_id
  prefixed_id=$(jq -r '.[1].id' ".claudekiq/runs/$run_id/steps.json")
  [ "$prefixed_id" = "step-a.step-a" ]
}

@test "add-steps initializes state for all new steps" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" add-steps "$run_id" --flow minimal --after step-a >/dev/null 2>&1
  [ "$(step_state "$run_id" step-a.step-a status)" = "pending" ]
  [ "$(step_state "$run_id" step-a.step-b status)" = "pending" ]
  [ "$(step_state "$run_id" step-a.step-c status)" = "pending" ]
}

@test "set-next changes step routing" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" set-next "$run_id" step-a step-c >/dev/null 2>&1
  "$CQ" step-done "$run_id" step-a pass >/dev/null 2>&1
  # Should jump to step-c (skipping step-b)
  [ "$(run_meta "$run_id" current_step)" = "step-c" ]
}

@test "set-next to end completes workflow" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" set-next "$run_id" step-a end >/dev/null 2>&1
  "$CQ" step-done "$run_id" step-a pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "completed" ]
}

@test "set-next nonexistent run fails" {
  run "$CQ" set-next nonexist step-a step-b
  [ "$status" -eq 1 ]
}
