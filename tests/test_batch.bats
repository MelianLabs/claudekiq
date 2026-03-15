#!/usr/bin/env bats
load setup.bash

setup() {
  setup_test_project
  cp "$FIXTURES"/with-batch.yml .claudekiq/workflows/
}

teardown() {
  teardown_test_project
}

@test "batch: step definition preserved in steps.json" {
  local run_id
  run_id=$("$CQ" start with-batch --json 2>/dev/null | jq -r '.run_id')
  local steps
  steps=$("$CQ" status "$run_id" --json 2>/dev/null | jq '.steps')

  local step_type max_workers
  step_type=$(echo "$steps" | jq -r '.[] | select(.id == "process-all") | .type')
  max_workers=$(echo "$steps" | jq -r '.[] | select(.id == "process-all") | .max_workers')

  [ "$step_type" = "batch" ]
  [ "$max_workers" = "3" ]
}

@test "batch: step-done pass advances past batch" {
  local run_id
  run_id=$("$CQ" start with-batch --json 2>/dev/null | jq -r '.run_id')
  "$CQ" step-done "$run_id" prepare pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" current_step)" = "process-all" ]

  "$CQ" step-done "$run_id" process-all pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" current_step)" = "done" ]
}

@test "batch: validates workflow" {
  run "$CQ" workflows validate "$FIXTURES/with-batch.yml"
  [ "$status" -eq 0 ]
}
