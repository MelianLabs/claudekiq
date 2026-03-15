#!/usr/bin/env bats
# test_workers.bats — Tests for cq workers commands

load setup.bash

setup() {
  setup_test_project
}

teardown() {
  teardown_test_project
}

# ============================================================
# workers init
# ============================================================

@test "workers init creates session directory" {
  run "$CQ" workers init --json
  [ "$status" -eq 0 ]
  local sid
  sid=$(echo "$output" | jq -r '.session_id')
  [ -d "$TEST_DIR/.claudekiq/workers/$sid" ]
  [ -f "$TEST_DIR/.claudekiq/workers/$sid/manifest.json" ]
}

@test "workers init manifest has correct fields" {
  run "$CQ" workers init --json
  [ "$status" -eq 0 ]
  local sid
  sid=$(echo "$output" | jq -r '.session_id')
  local manifest
  manifest=$(cat "$TEST_DIR/.claudekiq/workers/$sid/manifest.json")
  [ "$(echo "$manifest" | jq -r '.session_id')" = "$sid" ]
  [ "$(echo "$manifest" | jq -r '.parent_root')" = "$TEST_DIR" ]
  [ "$(echo "$manifest" | jq -r '.created_at')" != "null" ]
}

@test "workers init plain output" {
  run "$CQ" workers init
  [ "$status" -eq 0 ]
  [[ "$output" == *"Worker session"* ]]
  [[ "$output" == *"created"* ]]
}

# ============================================================
# workers status
# ============================================================

@test "workers status with no status files" {
  run "$CQ" workers init --json
  local sid
  sid=$(echo "$output" | jq -r '.session_id')

  run "$CQ" workers status "$sid" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.total')" -eq 0 ]
  [ "$(echo "$output" | jq '.running')" -eq 0 ]
}

@test "workers status reads status files" {
  run "$CQ" workers init --json
  local sid
  sid=$(echo "$output" | jq -r '.session_id')
  local wdir="$TEST_DIR/.claudekiq/workers/$sid"

  # Write some status files
  echo '{"status":"running","step":"fix"}' > "$wdir/BUG-1.status.json"
  echo '{"status":"gated","step":"review"}' > "$wdir/BUG-2.status.json"
  echo '{"status":"completed","summary":"done"}' > "$wdir/BUG-3.status.json"

  run "$CQ" workers status "$sid" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.total')" -eq 3 ]
  [ "$(echo "$output" | jq '.running')" -eq 1 ]
  [ "$(echo "$output" | jq '.gated')" -eq 1 ]
  [ "$(echo "$output" | jq '.completed')" -eq 1 ]
}

@test "workers status includes job_id in output" {
  run "$CQ" workers init --json
  local sid
  sid=$(echo "$output" | jq -r '.session_id')
  local wdir="$TEST_DIR/.claudekiq/workers/$sid"

  echo '{"status":"running","step":"fix"}' > "$wdir/BUG-42.status.json"

  run "$CQ" workers status "$sid" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.jobs[0].job_id')" = "BUG-42" ]
  [ "$(echo "$output" | jq -r '.jobs[0].status')" = "running" ]
}

@test "workers status fails for unknown session" {
  run "$CQ" workers status nonexistent
  [ "$status" -ne 0 ]
}

@test "workers status plain output" {
  run "$CQ" workers init --json
  local sid
  sid=$(echo "$output" | jq -r '.session_id')
  local wdir="$TEST_DIR/.claudekiq/workers/$sid"

  echo '{"status":"running","step":"fix"}' > "$wdir/BUG-1.status.json"

  run "$CQ" workers status "$sid"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Session:"* ]]
  [[ "$output" == *"1 running"* ]]
}

# ============================================================
# workers answer
# ============================================================

@test "workers answer creates answer file" {
  run "$CQ" workers init --json
  local sid
  sid=$(echo "$output" | jq -r '.session_id')

  run "$CQ" workers answer "$sid" BUG-1 approve --json
  [ "$status" -eq 0 ]

  local answer
  answer=$(cat "$TEST_DIR/.claudekiq/workers/$sid/BUG-1.answer.json")
  [ "$(echo "$answer" | jq -r '.action')" = "approve" ]
  [ "$(echo "$answer" | jq -r '.answered_at')" != "null" ]
}

@test "workers answer with data json" {
  run "$CQ" workers init --json
  local sid
  sid=$(echo "$output" | jq -r '.session_id')

  run "$CQ" workers answer "$sid" BUG-1 approve '{"fix_approach":"rollback"}' --json
  [ "$status" -eq 0 ]

  local answer
  answer=$(cat "$TEST_DIR/.claudekiq/workers/$sid/BUG-1.answer.json")
  [ "$(echo "$answer" | jq -r '.action')" = "approve" ]
  [ "$(echo "$answer" | jq -r '.data.fix_approach')" = "rollback" ]
}

@test "workers answer with plain string data" {
  run "$CQ" workers init --json
  local sid
  sid=$(echo "$output" | jq -r '.session_id')

  run "$CQ" workers answer "$sid" BUG-1 approve "just a note" --json
  [ "$status" -eq 0 ]

  local answer
  answer=$(cat "$TEST_DIR/.claudekiq/workers/$sid/BUG-1.answer.json")
  [ "$(echo "$answer" | jq -r '.data.message')" = "just a note" ]
}

@test "workers answer fails for unknown session" {
  run "$CQ" workers answer nonexistent BUG-1 approve
  [ "$status" -ne 0 ]
}

@test "workers answer plain output" {
  run "$CQ" workers init --json
  local sid
  sid=$(echo "$output" | jq -r '.session_id')

  run "$CQ" workers answer "$sid" BUG-1 approve
  [ "$status" -eq 0 ]
  [[ "$output" == *"Answer sent"* ]]
  [[ "$output" == *"BUG-1"* ]]
}

# ============================================================
# workers cleanup
# ============================================================

@test "workers cleanup removes nothing when empty" {
  run "$CQ" workers cleanup --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.removed')" -eq 0 ]
}

@test "workers cleanup respects max-age" {
  run "$CQ" workers init --json
  local sid
  sid=$(echo "$output" | jq -r '.session_id')

  # With max-age=0, everything should be removed
  run "$CQ" workers cleanup --max-age=0 --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.removed')" -eq 1 ]
  [ ! -d "$TEST_DIR/.claudekiq/workers/$sid" ]
}

# ============================================================
# workers help
# ============================================================

@test "workers help shows usage" {
  run "$CQ" workers help
  [ "$status" -eq 0 ]
  [[ "$output" == *"init"* ]]
  [[ "$output" == *"status"* ]]
  [[ "$output" == *"answer"* ]]
}

@test "workers with no subcommand shows usage" {
  run "$CQ" workers
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

# ============================================================
# init creates plugin.json with workers skill reference
# ============================================================

@test "init creates plugin.json referencing cq-workers" {
  run jq -e '.skills[] | select(endswith("/cq-workers"))' "$TEST_DIR/.claude-plugin/plugin.json"
  [ "$status" -eq 0 ]
}

@test "init adds workers dir to gitignore" {
  run grep -F '.claudekiq/workers/' "$TEST_DIR/.gitignore"
  [ "$status" -eq 0 ]
}

# ============================================================
# schema
# ============================================================

@test "schema workers returns valid JSON" {
  run "$CQ" schema workers
  [ "$status" -eq 0 ]
  echo "$output" | jq '.' >/dev/null
  [[ "$output" == *"workers"* ]]
}
