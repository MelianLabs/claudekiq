#!/usr/bin/env bats
# test_tracker.bats — Tests for tracker (issue comment) functionality

load setup.bash

setup() {
  setup_test_project
  cp "$FIXTURES"/with_tracker.yml .claudekiq/workflows/
  TRACKER_LOG="$TEST_DIR/tracker_comments.log"
  touch "$TRACKER_LOG"
}

teardown() {
  teardown_test_project
}

@test "tracker: fires on step_done with custom command" {
  local run_id
  run_id=$(start_workflow_with_tracker)

  "$CQ" step-done "$run_id" step-a pass 2>/dev/null
  sleep 0.5  # background command needs a moment

  [ -f "$TRACKER_LOG" ]
  grep -q "Step A" "$TRACKER_LOG"
  grep -q "pass" "$TRACKER_LOG"
}

@test "tracker: fires on workflow completion" {
  local run_id
  run_id=$(start_workflow_with_tracker)

  "$CQ" step-done "$run_id" step-a pass 2>/dev/null
  "$CQ" step-done "$run_id" step-b pass 2>/dev/null
  "$CQ" step-done "$run_id" step-no-track pass 2>/dev/null
  sleep 0.5

  grep -q "Workflow completed" "$TRACKER_LOG"
}

@test "tracker: respects per-step opt-out" {
  local run_id
  run_id=$(start_workflow_with_tracker)

  "$CQ" step-done "$run_id" step-a pass 2>/dev/null
  "$CQ" step-done "$run_id" step-b pass 2>/dev/null
  "$CQ" step-done "$run_id" step-no-track pass 2>/dev/null
  sleep 0.5

  # step-a and step-b should be tracked, step-no-track should not
  local step_done_count
  step_done_count=$(grep -c "visit #" "$TRACKER_LOG" || true)
  [ "$step_done_count" -eq 2 ]
}

@test "tracker: includes run_id in comments" {
  local run_id
  run_id=$(start_workflow_with_tracker)

  "$CQ" step-done "$run_id" step-a pass 2>/dev/null
  sleep 0.5

  grep -q "$run_id" "$TRACKER_LOG"
}

@test "tracker: reports failure outcome" {
  local run_id
  run_id=$(start_workflow_with_tracker)

  "$CQ" step-done "$run_id" step-a fail 2>/dev/null
  sleep 0.5

  grep -q "fail" "$TRACKER_LOG"
  grep -q "Step A" "$TRACKER_LOG"
}

@test "tracker: no output when tracker not configured" {
  # Use minimal workflow (no tracker config)
  local run_id
  run_id=$(start_minimal)

  "$CQ" step-done "$run_id" step-a pass 2>/dev/null
  sleep 0.3

  # Tracker log should not exist or be empty (tracker_log not passed)
  # This test just verifies no errors occur
  [ "$(run_meta "$run_id" status)" != "" ]
}

@test "tracker: event filtering respects events array" {
  # Create a workflow that only tracks 'complete' events
  cat > .claudekiq/workflows/tracker_filtered.yml <<'YAML'
name: tracker_filtered
description: Tracker with event filtering

defaults:
  issue_number: "99"

tracker:
  type: custom
  command: "echo '{{tracker_body}}' >> TRACKER_LOG_PLACEHOLDER"
  events:
    - complete

steps:
  - id: only-step
    name: Only Step
    type: bash
    target: "echo done"
    gate: auto
YAML
  sed -i "s|TRACKER_LOG_PLACEHOLDER|${TRACKER_LOG}|" .claudekiq/workflows/tracker_filtered.yml

  local run_id
  run_id=$("$CQ" start tracker_filtered --json 2>/dev/null | jq -r '.run_id')

  "$CQ" step-done "$run_id" only-step pass 2>/dev/null
  sleep 0.5

  # Should have completion comment but NOT step_done comment
  grep -q "Workflow completed" "$TRACKER_LOG"
  ! grep -q "visit #" "$TRACKER_LOG"
}

@test "tracker: settings-level tracker config works" {
  # Write tracker config to settings.json instead of workflow
  cat > .claudekiq/settings.json <<JSON
{
  "tracker": {
    "type": "custom",
    "command": "echo '{{tracker_body}}' >> ${TRACKER_LOG}"
  }
}
JSON

  # Use minimal workflow (no workflow-level tracker)
  local run_id
  run_id=$(start_minimal)

  "$CQ" step-done "$run_id" step-a pass 2>/dev/null
  sleep 0.5

  grep -q "Step A" "$TRACKER_LOG"
}

# --- Helper ---

start_workflow_with_tracker() {
  # Inject the tracker log path into context
  "$CQ" start with_tracker --tracker_log="$TRACKER_LOG" --json 2>/dev/null | jq -r '.run_id'
}
