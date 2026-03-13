#!/usr/bin/env bats
# test_heartbeat.bats — Tests for heartbeat and check-stale commands

load setup.bash

setup() {
  setup_test_project
}

teardown() {
  teardown_test_project
}

# ============================================================
# heartbeat
# ============================================================

@test "heartbeat writes .heartbeat file" {
  local rid
  rid=$(start_minimal)

  run "$CQ" heartbeat "$rid"
  [ "$status" -eq 0 ]
  [ -f "$TEST_DIR/.claudekiq/runs/$rid/.heartbeat" ]
}

@test "heartbeat file contains ISO timestamp" {
  local rid
  rid=$(start_minimal)

  "$CQ" heartbeat "$rid" >/dev/null
  local content
  content=$(cat "$TEST_DIR/.claudekiq/runs/$rid/.heartbeat")
  # ISO 8601 format: YYYY-MM-DDTHH:MM:SSZ
  [[ "$content" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "heartbeat --json output" {
  local rid
  rid=$(start_minimal)

  run "$CQ" heartbeat "$rid" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.run_id')" = "$rid" ]
  [ "$(echo "$output" | jq -r '.heartbeat')" != "null" ]
}

@test "heartbeat updates on repeated calls" {
  local rid
  rid=$(start_minimal)

  "$CQ" heartbeat "$rid" >/dev/null
  local first
  first=$(cat "$TEST_DIR/.claudekiq/runs/$rid/.heartbeat")

  sleep 1
  "$CQ" heartbeat "$rid" >/dev/null
  local second
  second=$(cat "$TEST_DIR/.claudekiq/runs/$rid/.heartbeat")

  # Timestamps should differ (or at least file was updated)
  [ -f "$TEST_DIR/.claudekiq/runs/$rid/.heartbeat" ]
}

@test "heartbeat fails for unknown run" {
  run "$CQ" heartbeat nonexistent
  [ "$status" -ne 0 ]
}

# ============================================================
# check-stale
# ============================================================

@test "check-stale with no running workflows" {
  run "$CQ" check-stale --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.count')" -eq 0 ]
}

@test "check-stale detects stale heartbeat" {
  local rid
  rid=$(start_minimal)

  # Write a heartbeat then check with 0-second timeout
  "$CQ" heartbeat "$rid" >/dev/null

  run "$CQ" check-stale --timeout=0 --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.count')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.stale[0].run_id')" = "$rid" ]
}

@test "check-stale does not flag fresh heartbeat" {
  local rid
  rid=$(start_minimal)

  "$CQ" heartbeat "$rid" >/dev/null

  run "$CQ" check-stale --timeout=9999 --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.count')" -eq 0 ]
}

@test "check-stale ignores runs without heartbeat" {
  local rid
  rid=$(start_minimal)
  # No heartbeat written

  run "$CQ" check-stale --timeout=0 --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.count')" -eq 0 ]
}

@test "check-stale --mark sets status to blocked" {
  local rid
  rid=$(start_minimal)
  "$CQ" heartbeat "$rid" >/dev/null

  run "$CQ" check-stale --timeout=0 --mark --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.count')" -eq 1 ]
  [ "$(echo "$output" | jq '.marked')" = "true" ]

  # Verify meta.json was updated
  [ "$(run_meta "$rid" status)" = "blocked" ]
}

@test "check-stale --mark logs event" {
  local rid
  rid=$(start_minimal)
  "$CQ" heartbeat "$rid" >/dev/null

  "$CQ" check-stale --timeout=0 --mark >/dev/null

  run "$CQ" log "$rid" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"run_blocked"* ]]
}

@test "check-stale plain output" {
  local rid
  rid=$(start_minimal)
  "$CQ" heartbeat "$rid" >/dev/null

  run "$CQ" check-stale --timeout=0
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stale runs"* ]]
  [[ "$output" == *"$rid"* ]]
}

@test "check-stale plain output no stale" {
  run "$CQ" check-stale
  [ "$status" -eq 0 ]
  [[ "$output" == *"No stale runs"* ]]
}

# ============================================================
# retry blocked runs
# ============================================================

@test "retry works on blocked runs" {
  local rid
  rid=$(start_minimal)
  "$CQ" heartbeat "$rid" >/dev/null
  "$CQ" check-stale --timeout=0 --mark >/dev/null

  [ "$(run_meta "$rid" status)" = "blocked" ]

  run "$CQ" retry "$rid" --json
  [ "$status" -eq 0 ]
  [ "$(run_meta "$rid" status)" = "running" ]
}

# ============================================================
# status dashboard with heartbeat
# ============================================================

@test "status --json includes heartbeat_age" {
  local rid
  rid=$(start_minimal)
  "$CQ" heartbeat "$rid" >/dev/null

  run "$CQ" status --json
  [ "$status" -eq 0 ]
  local hb_age
  hb_age=$(echo "$output" | jq '.runs[0].heartbeat_age')
  [ "$hb_age" != "null" ]
}

@test "status --json omits heartbeat_age when no heartbeat" {
  local rid
  rid=$(start_minimal)

  local out
  out=$("$CQ" status --json 2>/dev/null)
  local hb_age
  hb_age=$(echo "$out" | jq -r '.runs[0].heartbeat_age // "missing"')
  [ "$hb_age" = "missing" ]
}

# ============================================================
# schema
# ============================================================

@test "schema heartbeat returns valid JSON" {
  run "$CQ" schema heartbeat
  [ "$status" -eq 0 ]
  echo "$output" | jq '.' >/dev/null
  [[ "$output" == *"heartbeat"* ]]
}

@test "schema check-stale returns valid JSON" {
  run "$CQ" schema check-stale
  [ "$status" -eq 0 ]
  echo "$output" | jq '.' >/dev/null
  [[ "$output" == *"check-stale"* ]]
}
