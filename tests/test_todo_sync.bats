#!/usr/bin/env bats
# test_todo_sync.bats — Tests for TODO bidirectional sync

load setup.bash

setup() {
  setup_test_project
  cp "$FIXTURES"/with_routing.yml .claudekiq/workflows/
}

teardown() {
  teardown_test_project
}

# Helper: create a gated run and get a pending TODO
# with_routing workflow: read-input -> implement (human gate)
# Human gate triggers on step-done, so we need to complete implement too
create_gated_run() {
  local run_id
  run_id=$(start_with_routing --mode=feature)
  "$CQ" step-done "$run_id" read-input pass >/dev/null 2>&1
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  echo "$run_id"
}

@test "todos sync --json returns empty when no pending TODOs" {
  local run_id
  run_id=$(start_minimal)
  local result
  result=$("$CQ" todos sync --json 2>/dev/null)
  local count
  count=$(jq '.todos | length' <<< "$result")
  [[ "$count" -eq 0 ]]
}

@test "todos sync --json returns pending TODOs in native format" {
  local run_id
  run_id=$(create_gated_run)

  local result
  result=$("$CQ" todos sync --json 2>/dev/null)
  local count
  count=$(jq '.todos | length' <<< "$result")
  [[ "$count" -gt 0 ]]

  # Verify native format structure
  local first_todo
  first_todo=$(jq '.todos[0]' <<< "$result")
  [[ $(jq -r '.id' <<< "$first_todo") != "null" ]]
  [[ $(jq -r '.content' <<< "$first_todo") == *"[cq]"* ]]
  [[ $(jq -r '.status' <<< "$first_todo") == "pending" ]]
  [[ $(jq -r '.metadata.run_id' <<< "$first_todo") == "$run_id" ]]
  [[ $(jq -r '.metadata.step_id' <<< "$first_todo") != "null" ]]
}

@test "todos sync --json includes run_ids array" {
  local run_id
  run_id=$(create_gated_run)

  local result
  result=$("$CQ" todos sync --json 2>/dev/null)
  local run_ids_count
  run_ids_count=$(jq '.run_ids | length' <<< "$result")
  [[ "$run_ids_count" -gt 0 ]]
  [[ $(jq -r '.run_ids[0]' <<< "$result") == "$run_id" ]]
}

@test "todos sync creates sync state file" {
  local run_id
  run_id=$(create_gated_run)

  "$CQ" todos sync --json >/dev/null 2>&1

  local sync_file="$TEST_DIR/.claudekiq/runs/$run_id/todos/.sync_state.json"
  [[ -f "$sync_file" ]]

  local last_sync
  last_sync=$(jq -r '.last_sync' "$sync_file")
  [[ "$last_sync" != "null" ]]
}

@test "todos apply-sync resolves pending TODO" {
  local run_id
  run_id=$(create_gated_run)

  # Get the TODO id
  local todos
  todos=$("$CQ" todos --json 2>/dev/null)
  local todo_id
  todo_id=$(jq -r '.[0].id' <<< "$todos")
  [[ -n "$todo_id" && "$todo_id" != "null" ]]

  # Apply resolution via sync
  local input
  input=$(jq -cn --arg tid "$todo_id" --arg rid "$run_id" \
    '{resolutions: [{todo_id: $tid, run_id: $rid, action: "dismiss"}]}')

  local result
  result=$(echo "$input" | "$CQ" todos apply-sync --json 2>/dev/null)
  local applied
  applied=$(jq -r '.applied' <<< "$result")
  [[ "$applied" -eq 1 ]]

  # Verify TODO is no longer pending
  local remaining
  remaining=$("$CQ" todos --json 2>/dev/null)
  local remaining_count
  remaining_count=$(jq 'length' <<< "$remaining")
  [[ "$remaining_count" -eq 0 ]]
}

@test "todos apply-sync skips already resolved TODOs" {
  local run_id
  run_id=$(create_gated_run)

  local todos
  todos=$("$CQ" todos --json 2>/dev/null)
  local todo_id
  todo_id=$(jq -r '.[0].id' <<< "$todos")

  # Resolve via normal path first
  "$CQ" todo 1 dismiss >/dev/null 2>&1

  # Try to apply-sync the same TODO
  local input
  input=$(jq -cn --arg tid "$todo_id" --arg rid "$run_id" \
    '{resolutions: [{todo_id: $tid, run_id: $rid, action: "approve"}]}')

  local result
  result=$(echo "$input" | "$CQ" todos apply-sync --json 2>/dev/null)
  local applied
  applied=$(jq -r '.applied' <<< "$result")
  [[ "$applied" -eq 0 ]]
}

@test "todos sync human-readable output" {
  local run_id
  run_id=$(create_gated_run)

  local result
  result=$("$CQ" todos sync 2>/dev/null)
  [[ "$result" == *"Synced"* ]]
  [[ "$result" == *"pending TODO"* ]]
}

@test "todos sync with --flow filter" {
  local run_id1 run_id2
  run_id1=$(create_gated_run)
  run_id2=$(create_gated_run)

  local result
  result=$("$CQ" todos sync --flow "$run_id1" --json 2>/dev/null)
  local count
  count=$(jq '.todos | length' <<< "$result")
  # Should only have TODOs from run_id1
  local all_from_run1
  all_from_run1=$(jq --arg rid "$run_id1" '[.todos[] | select(.metadata.run_id == $rid)] | length' <<< "$result")
  [[ "$count" -eq "$all_from_run1" ]]
}

@test "todos sync excludes .sync_state.json from TODO listing" {
  local run_id
  run_id=$(create_gated_run)

  # First sync creates the .sync_state.json
  "$CQ" todos sync --json >/dev/null 2>&1

  # Second sync should not include .sync_state.json as a TODO
  local result
  result=$("$CQ" todos sync --json 2>/dev/null)
  local count
  count=$(jq '.todos | length' <<< "$result")
  # Should still be exactly the pending TODOs, not including sync state
  [[ "$count" -gt 0 ]]
  # Verify no TODO has sync_state in its id
  local sync_state_count
  sync_state_count=$(jq '[.todos[] | select(.id | contains("sync_state"))] | length' <<< "$result")
  [[ "$sync_state_count" -eq 0 ]]
}
