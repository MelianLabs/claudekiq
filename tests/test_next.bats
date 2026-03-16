#!/usr/bin/env bats
# Tests for cq next command

load setup

setup() { setup_test_project; }
teardown() { teardown_test_project; }

@test "next shows current step" {
  local run_id
  run_id=$(start_minimal)
  run "$CQ" next "$run_id"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Step A"
}

@test "next --json returns step definition" {
  local run_id
  run_id=$(start_minimal)
  run "$CQ" next "$run_id" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.step_id == "step-a"'
  echo "$output" | jq -e '.step != null'
  echo "$output" | jq -e '.index == 0'
  echo "$output" | jq -e '.total > 0'
}

@test "next after advancing shows next step" {
  local run_id
  run_id=$(start_minimal)
  advance_step "$run_id" pass
  run "$CQ" next "$run_id" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.step_id == "step-b"'
  echo "$output" | jq -e '.index == 1'
}

@test "next requires run_id" {
  run "$CQ" next
  [ "$status" -ne 0 ]
}

@test "next fails on nonexistent run" {
  run "$CQ" next nonexistent
  [ "$status" -ne 0 ]
}

@test "next in schema" {
  run "$CQ" schema next
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.command == "next"'
}
