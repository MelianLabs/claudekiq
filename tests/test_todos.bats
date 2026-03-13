#!/usr/bin/env bats
load setup.bash

setup() {
  setup_test_project
}

teardown() {
  teardown_test_project
}

@test "human gate creates todo" {
  local run_id
  run_id=$(start_with_routing --mode=feature)
  "$CQ" step-done "$run_id" read-input pass >/dev/null 2>&1
  # implement has human gate
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "gated" ]
  local todo_count
  todo_count=$("$CQ" --json todos | jq 'length')
  [ "$todo_count" -eq 1 ]
}

@test "todos shows pending actions" {
  local run_id
  run_id=$(start_with_routing --mode=feature)
  "$CQ" step-done "$run_id" read-input pass >/dev/null 2>&1
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  run "$CQ" todos
  [ "$status" -eq 0 ]
  [[ "$output" == *"Implement"* ]]
}

@test "todos --json" {
  local run_id
  run_id=$(start_with_routing --mode=feature)
  "$CQ" step-done "$run_id" read-input pass >/dev/null 2>&1
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  local output
  output=$("$CQ" --json todos)
  echo "$output" | jq -e '.[0].step_id == "implement"'
}

@test "todo approve advances workflow" {
  local run_id
  run_id=$(start_with_routing --mode=feature)
  "$CQ" step-done "$run_id" read-input pass >/dev/null 2>&1
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  "$CQ" todo 1 approve >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "running" ]
  [ "$(run_meta "$run_id" current_step)" = "run-tests" ]
}

@test "todo reject fails workflow" {
  local run_id
  run_id=$(start_with_routing --mode=feature)
  "$CQ" step-done "$run_id" read-input pass >/dev/null 2>&1
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  "$CQ" todo 1 reject >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "failed" ]
}

@test "todo dismiss leaves workflow unchanged" {
  local run_id
  run_id=$(start_with_routing --mode=feature)
  "$CQ" step-done "$run_id" read-input pass >/dev/null 2>&1
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  "$CQ" todo 1 dismiss >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "gated" ]
}

@test "todo override advances like approve" {
  local run_id
  run_id=$(start_with_routing --mode=feature)
  "$CQ" step-done "$run_id" read-input pass >/dev/null 2>&1
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  "$CQ" todo 1 override >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "running" ]
}

@test "todos empty when no pending actions" {
  start_minimal >/dev/null
  run "$CQ" todos
  [ "$status" -eq 0 ]
  [[ "$output" == *"No pending"* ]]
}

@test "todo invalid action fails" {
  local run_id
  run_id=$(start_with_routing --mode=feature)
  "$CQ" step-done "$run_id" read-input pass >/dev/null 2>&1
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  run "$CQ" todo 1 bad_action
  [ "$status" -eq 1 ]
}

@test "todo nonexistent index fails" {
  run "$CQ" todo 99 approve
  [ "$status" -eq 1 ]
}

@test "review gate pass advances immediately" {
  local run_id
  run_id=$(start_with_routing --mode=feature)
  "$CQ" step-done "$run_id" read-input pass >/dev/null 2>&1
  # implement has human gate
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  "$CQ" todo 1 approve >/dev/null 2>&1
  # Now at run-tests (review gate)
  "$CQ" step-done "$run_id" run-tests pass >/dev/null 2>&1
  # on_pass goes to done
  [ "$(run_meta "$run_id" current_step)" = "done" ]
}

@test "review gate fail retries when visits < max" {
  local run_id
  run_id=$(start_with_routing --mode=feature)
  "$CQ" step-done "$run_id" read-input pass >/dev/null 2>&1
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  "$CQ" todo 1 approve >/dev/null 2>&1
  # Now at run-tests with max_visits=3
  "$CQ" step-done "$run_id" run-tests fail >/dev/null 2>&1
  # on_fail goes to implement (visit 1 < 3)
  [ "$(run_meta "$run_id" current_step)" = "implement" ]
}

@test "review gate escalates at max_visits" {
  local run_id
  run_id=$(start_with_routing --mode=feature)
  "$CQ" step-done "$run_id" read-input pass >/dev/null 2>&1
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  "$CQ" todo 1 approve >/dev/null 2>&1

  # Fail run-tests 3 times (max_visits=3)
  "$CQ" step-done "$run_id" run-tests fail >/dev/null 2>&1
  # Visit 1 - routes to implement via on_fail
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  "$CQ" todo 1 approve >/dev/null 2>&1
  "$CQ" step-done "$run_id" run-tests fail >/dev/null 2>&1
  # Visit 2 - still below max
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  "$CQ" todo 1 approve >/dev/null 2>&1
  "$CQ" step-done "$run_id" run-tests fail >/dev/null 2>&1
  # Visit 3 = max_visits → should create TODO with override action
  [ "$(run_meta "$run_id" status)" = "gated" ]
  local action
  action=$("$CQ" --json todos | jq -r '.[0].action')
  [ "$action" = "override" ]
}

@test "todos filtered by --flow" {
  local run_id1 run_id2
  "$CQ" config set concurrency 5 >/dev/null
  run_id1=$(start_with_routing --mode=feature)
  run_id2=$(start_with_routing --mode=feature)
  "$CQ" step-done "$run_id1" read-input pass >/dev/null 2>&1
  "$CQ" step-done "$run_id1" implement pass >/dev/null 2>&1
  "$CQ" step-done "$run_id2" read-input pass >/dev/null 2>&1
  "$CQ" step-done "$run_id2" implement pass >/dev/null 2>&1

  local total filtered
  total=$("$CQ" --json todos | jq 'length')
  filtered=$("$CQ" --json todos --flow "$run_id1" | jq 'length')
  [ "$total" -eq 2 ]
  [ "$filtered" -eq 1 ]
}
