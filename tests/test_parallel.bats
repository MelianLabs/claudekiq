#!/usr/bin/env bats
load setup.bash

setup() {
  setup_test_project
  cp "$FIXTURES"/with-parallel.yml .claudekiq/workflows/
}

teardown() {
  teardown_test_project
}

@test "parallel: step definition preserved in steps.json" {
  local run_id
  run_id=$("$CQ" start with-parallel --json 2>/dev/null | jq -r '.run_id')
  local steps
  steps=$("$CQ" status "$run_id" --json 2>/dev/null | jq '.steps')

  local step_type fail_strategy
  step_type=$(echo "$steps" | jq -r '.[] | select(.id == "run-checks") | .type')
  fail_strategy=$(echo "$steps" | jq -r '.[] | select(.id == "run-checks") | .fail_strategy')

  [ "$step_type" = "parallel" ]
  [ "$fail_strategy" = "wait_all" ]
}

@test "parallel: has nested steps array" {
  local run_id
  run_id=$("$CQ" start with-parallel --json 2>/dev/null | jq -r '.run_id')
  local steps
  steps=$("$CQ" status "$run_id" --json 2>/dev/null | jq '.steps')

  local child_count
  child_count=$(echo "$steps" | jq '.[] | select(.id == "run-checks") | .steps | length')
  [ "$child_count" -eq 2 ]

  local child1_id child2_id
  child1_id=$(echo "$steps" | jq -r '.[] | select(.id == "run-checks") | .steps[0].id')
  child2_id=$(echo "$steps" | jq -r '.[] | select(.id == "run-checks") | .steps[1].id')
  [ "$child1_id" = "run-tests" ]
  [ "$child2_id" = "run-lint" ]
}

@test "parallel: step-done pass advances past parallel" {
  local run_id
  run_id=$("$CQ" start with-parallel --json 2>/dev/null | jq -r '.run_id')
  "$CQ" step-done "$run_id" prepare pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" current_step)" = "run-checks" ]

  # Runner would execute parallel children and then mark parent as pass
  "$CQ" step-done "$run_id" run-checks pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" current_step)" = "done" ]
}

@test "parallel: validates workflow" {
  run "$CQ" workflows validate "$FIXTURES/with-parallel.yml"
  [ "$status" -eq 0 ]
}

@test "parallel: standalone mode --json" {
  local result
  result=$("$CQ" --json parallel --steps='[{"id":"a","type":"bash","target":"echo hello"},{"id":"b","type":"bash","target":"echo world"}]' 2>/dev/null)
  [ "$(echo "$result" | jq -r '.outcome')" = "pass" ]
  [ "$(echo "$result" | jq '.results | length')" = "2" ]
  [ "$(echo "$result" | jq -r '.results[0].outcome')" = "pass" ]
  [ "$(echo "$result" | jq -r '.results[1].outcome')" = "pass" ]
}

@test "parallel: standalone with failure" {
  local result
  result=$("$CQ" --json parallel --steps='[{"id":"ok","type":"bash","target":"echo ok"},{"id":"bad","type":"bash","target":"exit 1"}]' 2>/dev/null) || true
  [ "$(echo "$result" | jq -r '.outcome')" = "fail" ]
  [ "$(echo "$result" | jq -r '.results[0].outcome')" = "pass" ]
  [ "$(echo "$result" | jq -r '.results[1].outcome')" = "fail" ]
}

@test "parallel: workflow mode --json" {
  local run_id
  run_id=$("$CQ" start with-parallel --json 2>/dev/null | jq -r '.run_id')
  "$CQ" step-done "$run_id" prepare pass >/dev/null 2>&1
  local result
  result=$("$CQ" --json parallel "$run_id" run-checks 2>/dev/null)
  [ "$(echo "$result" | jq -r '.outcome')" = "pass" ]
  [ "$(echo "$result" | jq -r '.run_id')" = "$run_id" ]
  [ "$(echo "$result" | jq '.results | length')" = "2" ]
}
