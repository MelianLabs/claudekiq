#!/usr/bin/env bats
# test_parallel.bats — Tests for parallel step type

load setup.bash

setup() {
  setup_test_project
  cp "$FIXTURES"/with-parallel.yml .claudekiq/workflows/
}

teardown() {
  teardown_test_project
}

start_parallel() {
  "$CQ" start with-parallel "$@" --json 2>/dev/null | jq -r '.run_id'
}

@test "parallel step type resolves as builtin" {
  local kind
  kind=$(source "$CQ_ROOT/lib/core.sh" 2>/dev/null; CQ_PROJECT_ROOT="$TEST_DIR"; cq_resolve_step_type "parallel")
  [[ "$kind" == "builtin" ]]
}

@test "parallel step initializes branch state" {
  local run_id
  run_id=$(start_parallel)

  local branches
  branches=$(jq '."parallel-tests".branches' "$TEST_DIR/.claudekiq/runs/$run_id/state.json")
  [[ "$branches" != "null" ]]

  local branch_count
  branch_count=$(jq 'keys | length' <<< "$branches")
  [[ "$branch_count" -eq 3 ]]

  # All branches should be pending
  local pending_count
  pending_count=$(jq '[to_entries[] | select(.value.status == "pending")] | length' <<< "$branches")
  [[ "$pending_count" -eq 3 ]]
}

@test "step-done with --branches updates all branches" {
  local run_id
  run_id=$(start_parallel)
  # Advance to parallel step
  "$CQ" step-done "$run_id" setup pass >/dev/null 2>&1

  # Complete parallel step with branch results
  local branches_json='{"unit-tests":{"status":"passed","result":"pass"},"lint":{"status":"passed","result":"pass"},"integration":{"status":"passed","result":"pass"}}'
  "$CQ" step-done "$run_id" parallel-tests pass --branches="$branches_json" >/dev/null 2>&1

  # Verify branches updated
  local branches
  branches=$(jq '."parallel-tests".branches' "$TEST_DIR/.claudekiq/runs/$run_id/state.json")
  local passed_count
  passed_count=$(jq '[to_entries[] | select(.value.result == "pass")] | length' <<< "$branches")
  [[ "$passed_count" -eq 3 ]]
}

@test "parallel step passes when all branches pass" {
  local run_id
  run_id=$(start_parallel)
  "$CQ" step-done "$run_id" setup pass >/dev/null 2>&1

  local branches_json='{"unit-tests":{"status":"passed","result":"pass"},"lint":{"status":"passed","result":"pass"},"integration":{"status":"passed","result":"pass"}}'
  "$CQ" step-done "$run_id" parallel-tests pass --branches="$branches_json" >/dev/null 2>&1

  local step_result
  step_result=$(step_state "$run_id" "parallel-tests" "result")
  [[ "$step_result" == "pass" ]]

  # Should advance to done step
  assert_current_step "$run_id" "done"
}

@test "parallel step fails when any branch fails" {
  local run_id
  run_id=$(start_parallel)
  "$CQ" step-done "$run_id" setup pass >/dev/null 2>&1

  local branches_json='{"unit-tests":{"status":"passed","result":"pass"},"lint":{"status":"failed","result":"fail"},"integration":{"status":"passed","result":"pass"}}'
  "$CQ" step-done "$run_id" parallel-tests fail --branches="$branches_json" >/dev/null 2>&1

  local step_result
  step_result=$(step_state "$run_id" "parallel-tests" "result")
  [[ "$step_result" == "fail" ]]
}

@test "parallel step logs branch results" {
  local run_id
  run_id=$(start_parallel)
  "$CQ" step-done "$run_id" setup pass >/dev/null 2>&1

  local branches_json='{"unit-tests":{"status":"passed","result":"pass"},"lint":{"status":"passed","result":"pass"},"integration":{"status":"passed","result":"pass"}}'
  "$CQ" step-done "$run_id" parallel-tests pass --branches="$branches_json" >/dev/null 2>&1

  # Check log has parallel step_done event with branches
  local log_entry
  log_entry=$(grep '"type":"parallel"' "$TEST_DIR/.claudekiq/runs/$run_id/log.jsonl" | tail -1)
  [[ -n "$log_entry" ]]
  local branch_count
  branch_count=$(jq '.data.branches | keys | length' <<< "$log_entry")
  [[ "$branch_count" -eq 3 ]]
}

@test "validate accepts parallel workflow" {
  run "$CQ" workflows validate "$FIXTURES/with-parallel.yml"
  [ "$status" -eq 0 ]
}

@test "validate rejects parallel step without branches" {
  local bad_file="$TEST_DIR/bad-parallel.yml"
  cat > "$bad_file" <<'EOF'
name: bad-parallel
description: Missing branches
steps:
  - id: bad
    type: parallel
    gate: auto
EOF
  run "$CQ" workflows validate "$bad_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"branches"* ]]
}
