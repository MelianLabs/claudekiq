#!/usr/bin/env bats
load setup.bash

setup() {
  setup_test_project
}

teardown() {
  teardown_test_project
}

@test "e2e: minimal workflow happy path" {
  local run_id
  run_id=$(start_minimal --greeting=world)

  # Verify context
  local greeting
  greeting=$("$CQ" ctx get greeting "$run_id")
  [ "$greeting" = "world" ]

  # Step through all steps
  "$CQ" step-done "$run_id" step-a pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" current_step)" = "step-b" ]

  "$CQ" step-done "$run_id" step-b pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" current_step)" = "step-c" ]

  "$CQ" step-done "$run_id" step-c pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "completed" ]

  # Verify all steps passed
  [ "$(step_state "$run_id" step-a status)" = "passed" ]
  [ "$(step_state "$run_id" step-b status)" = "passed" ]
  [ "$(step_state "$run_id" step-c status)" = "passed" ]

  # Verify log has all events
  local events
  events=$(jq -s '[.[].event]' ".claudekiq/runs/$run_id/log.jsonl")
  echo "$events" | jq -e '. | index("run_started")'
  echo "$events" | jq -e '. | index("step_done")'
  echo "$events" | jq -e '. | index("run_completed")'
}

@test "e2e: routing workflow with bug mode" {
  local run_id
  run_id=$(start_with_routing --mode=bug)

  # read-input → investigate (bug routing)
  "$CQ" step-done "$run_id" read-input pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" current_step)" = "investigate" ]

  # investigate → implement (explicit next)
  "$CQ" step-done "$run_id" investigate pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" current_step)" = "implement" ]

  # implement has human gate
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "gated" ]
  "$CQ" todo 1 approve >/dev/null 2>&1

  # run-tests → done (pass via on_pass)
  "$CQ" step-done "$run_id" run-tests pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" current_step)" = "done" ]

  # done → end (last step in route)
  "$CQ" step-done "$run_id" done pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "completed" ]
}

@test "e2e: routing workflow with feature mode" {
  local run_id
  run_id=$(start_with_routing --mode=feature)

  # read-input → implement (feature routing skips investigate)
  "$CQ" step-done "$run_id" read-input pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" current_step)" = "implement" ]

  # implement has human gate
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "gated" ]
  "$CQ" todo 1 approve >/dev/null 2>&1

  # run-tests → done (pass)
  "$CQ" step-done "$run_id" run-tests pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" current_step)" = "done" ]

  "$CQ" step-done "$run_id" done pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "completed" ]
}

@test "e2e: test retry loop with review gate" {
  local run_id
  run_id=$(start_with_routing --mode=feature)

  "$CQ" step-done "$run_id" read-input pass >/dev/null 2>&1
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  "$CQ" todo 1 approve >/dev/null 2>&1

  # Fail run-tests, should loop back to implement
  "$CQ" step-done "$run_id" run-tests fail >/dev/null 2>&1
  [ "$(run_meta "$run_id" current_step)" = "implement" ]
  [ "$(step_state "$run_id" run-tests visits)" = "1" ]

  # Fix and retry
  "$CQ" step-done "$run_id" implement pass >/dev/null 2>&1
  "$CQ" todo 1 approve >/dev/null 2>&1
  "$CQ" step-done "$run_id" run-tests pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" current_step)" = "done" ]
  [ "$(step_state "$run_id" run-tests visits)" = "2" ]
}

@test "e2e: dynamic modification during run" {
  local run_id
  run_id=$(start_minimal)

  "$CQ" step-done "$run_id" step-a pass >/dev/null 2>&1

  # Add a step after step-b
  "$CQ" add-step "$run_id" '{"id":"injected","type":"bash","target":"echo injected","gate":"auto"}' --after step-b >/dev/null 2>&1

  # Override routing
  "$CQ" set-next "$run_id" step-b injected >/dev/null 2>&1
  "$CQ" step-done "$run_id" step-b pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" current_step)" = "injected" ]

  "$CQ" step-done "$run_id" injected pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" current_step)" = "step-c" ]

  "$CQ" step-done "$run_id" step-c pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "completed" ]
}

@test "e2e: pause resume cancel flow" {
  local run_id
  run_id=$(start_minimal)

  "$CQ" pause "$run_id" >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "paused" ]

  "$CQ" resume "$run_id" >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "running" ]

  "$CQ" cancel "$run_id" >/dev/null 2>&1
  [ "$(run_meta "$run_id" status)" = "cancelled" ]
}

@test "e2e: context variables flow through workflow" {
  local run_id
  run_id=$(start_minimal --greeting=world)

  # Set additional context
  "$CQ" ctx set extra_var "test_value" "$run_id" >/dev/null 2>&1

  # Verify
  [ "$("$CQ" ctx get greeting "$run_id")" = "world" ]
  [ "$("$CQ" ctx get extra_var "$run_id")" = "test_value" ]

  # Verify full context JSON
  local ctx
  ctx=$("$CQ" --json ctx "$run_id")
  echo "$ctx" | jq -e '.greeting == "world"'
  echo "$ctx" | jq -e '.extra_var == "test_value"'
}

@test "e2e: JSON output mode for full lifecycle" {
  local output run_id

  # Start
  output=$("$CQ" --json start minimal)
  run_id=$(echo "$output" | jq -r '.run_id')
  echo "$output" | jq -e '.status'

  # Status
  output=$("$CQ" --json status "$run_id")
  echo "$output" | jq -e '.meta.status == "running"'

  # Step done
  output=$("$CQ" --json step-done "$run_id" step-a pass)
  echo "$output" | jq -e '.outcome == "pass"'

  # List
  output=$("$CQ" --json list)
  echo "$output" | jq -e 'length >= 1'

  # Log
  output=$("$CQ" --json log "$run_id")
  echo "$output" | jq -e 'length >= 1'
}

@test "e2e: multiple concurrent runs" {
  "$CQ" config set concurrency 3 >/dev/null
  local run1 run2 run3
  run1=$(start_minimal)
  run2=$(start_minimal)
  run3=$(start_minimal)

  # All three should be running
  [ "$(run_meta "$run1" status)" = "running" ]
  [ "$(run_meta "$run2" status)" = "running" ]
  [ "$(run_meta "$run3" status)" = "running" ]

  # Complete run1
  "$CQ" skip "$run1" >/dev/null 2>&1
  "$CQ" skip "$run1" >/dev/null 2>&1
  "$CQ" skip "$run1" >/dev/null 2>&1
  [ "$(run_meta "$run1" status)" = "completed" ]

  # Others still running
  [ "$(run_meta "$run2" status)" = "running" ]
}

@test "e2e: cleanup removes old completed runs" {
  local run_id
  run_id=$(start_minimal)
  "$CQ" skip "$run_id" >/dev/null 2>&1
  "$CQ" skip "$run_id" >/dev/null 2>&1
  "$CQ" skip "$run_id" >/dev/null 2>&1

  # Set TTL to 0 so it expires immediately
  "$CQ" config set ttl 0 >/dev/null

  run "$CQ" cleanup
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed 1"* ]]

  # Run directory should be gone
  [ ! -d ".claudekiq/runs/$run_id" ]
}
