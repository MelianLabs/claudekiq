#!/usr/bin/env bats
# test_inheritance.bats — Tests for workflow inheritance (Phase 4)

load setup.bash

setup() {
  setup_test_project
  cp "$FIXTURES"/base-workflow.yml .claudekiq/workflows/
  cp "$FIXTURES"/child-workflow.yml .claudekiq/workflows/
}

teardown() {
  teardown_test_project
}

@test "start resolves extends: base steps are inherited" {
  local run_id
  run_id=$(start_with_template "child-workflow")
  [ -n "$run_id" ]

  # Should have base steps (lint, run-tests minus removed commit) + child step (plan)
  local step_ids
  step_ids=$(jq -r '.[].id' "$TEST_DIR/.claudekiq/runs/$run_id/steps.json")
  [[ "$step_ids" == *"lint"* ]]
  [[ "$step_ids" == *"run-tests"* ]]
  [[ "$step_ids" == *"plan"* ]]
}

@test "extends: override merges fields into base step" {
  local run_id
  run_id=$(start_with_template "child-workflow")

  # run-tests should have gate=review and max_visits=5 from override
  local gate max_visits
  gate=$(jq -r '.[] | select(.id == "run-tests") | .gate' "$TEST_DIR/.claudekiq/runs/$run_id/steps.json")
  max_visits=$(jq -r '.[] | select(.id == "run-tests") | .max_visits' "$TEST_DIR/.claudekiq/runs/$run_id/steps.json")
  [ "$gate" = "review" ]
  [ "$max_visits" = "5" ]
}

@test "extends: remove filters out base steps" {
  local run_id
  run_id=$(start_with_template "child-workflow")

  # commit step should be removed
  local has_commit
  has_commit=$(jq '[.[] | select(.id == "commit")] | length' "$TEST_DIR/.claudekiq/runs/$run_id/steps.json")
  [ "$has_commit" -eq 0 ]
}

@test "extends: child steps are appended after base steps" {
  local run_id
  run_id=$(start_with_template "child-workflow")

  # plan should be the last step (appended)
  local last_step
  last_step=$(jq -r '.[-1].id' "$TEST_DIR/.claudekiq/runs/$run_id/steps.json")
  [ "$last_step" = "plan" ]
}

@test "extends: child defaults override base defaults" {
  local run_id
  run_id=$(start_with_template "child-workflow")

  local mode
  mode=$(jq -r '.mode' "$TEST_DIR/.claudekiq/runs/$run_id/ctx.json")
  [ "$mode" = "feature" ]
}

# Helper to start a workflow by template name
start_with_template() {
  local template="$1"
  "$CQ" start "$template" --json 2>/dev/null | jq -r '.run_id'
}
