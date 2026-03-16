#!/usr/bin/env bats
# test_hooks_internal.bats — Tests for internal hook handler commands

load setup.bash

setup() {
  setup_test_project
  # Initialize git repo for diff tracking
  cd "$TEST_DIR"
  git init -q
  git add -A
  git commit -q -m "init" --allow-empty
}

teardown() {
  teardown_test_project
}

@test "_stage-context exits cleanly with no active run" {
  run "$CQ" _stage-context
  [ "$status" -eq 0 ]
}

@test "_stage-context captures modified files for active run" {
  local run_id
  run_id=$(start_minimal)

  # Set current step to running status (stage-context only runs for running steps)
  local current_step
  current_step=$(run_meta "$run_id" current_step)
  local state_file="$TEST_DIR/.claudekiq/runs/$run_id/state.json"
  local state
  state=$(jq --arg id "$current_step" '.[$id].status = "running"' "$state_file")
  echo "$state" > "$state_file"

  # Create a modified file so git diff has something
  echo "hello" > "$TEST_DIR/test_file.txt"
  git add "$TEST_DIR/test_file.txt"

  # Simulate Edit hook input with file path
  local hook_input
  hook_input=$(jq -cn --arg fp "$TEST_DIR/test_file.txt" '{tool_input: {file_path: $fp}}')
  echo "$hook_input" | "$CQ" _stage-context 2>/dev/null || true

  # Check that _modified_files was set in context
  local modified
  modified=$("$CQ" ctx get _modified_files "$run_id" 2>/dev/null)
  [[ -n "$modified" ]]
  [[ "$modified" == *"test_file.txt"* ]]
}

@test "_stage-context updates step state files array" {
  local run_id
  run_id=$(start_minimal)

  # Set current step to running status (stage-context only runs for running steps)
  local current_step
  current_step=$(run_meta "$run_id" current_step)
  local state_file="$TEST_DIR/.claudekiq/runs/$run_id/state.json"
  local state
  state=$(jq --arg id "$current_step" '.[$id].status = "running"' "$state_file")
  echo "$state" > "$state_file"

  echo "content" > "$TEST_DIR/src_file.ts"
  git add "$TEST_DIR/src_file.ts"

  local hook_input
  hook_input=$(jq -cn --arg fp "$TEST_DIR/src_file.ts" '{tool_input: {file_path: $fp}}')
  echo "$hook_input" | "$CQ" _stage-context 2>/dev/null || true

  # Check step state has files
  local files
  files=$(jq --arg id "$current_step" '.[$id].files // []' "$state_file")
  local files_count
  files_count=$(jq 'length' <<< "$files")
  [[ "$files_count" -gt 0 ]]
}

@test "_stage-context ignores .claudekiq/runs/ files" {
  local run_id
  run_id=$(start_minimal)

  # Simulate hook input with a run file path (should be ignored)
  local hook_input
  hook_input=$(jq -cn --arg fp "$TEST_DIR/.claudekiq/runs/$run_id/meta.json" '{tool_input: {file_path: $fp}}')
  echo "$hook_input" | "$CQ" _stage-context 2>/dev/null || true

  # _modified_files should not include the run file
  local modified
  modified=$("$CQ" ctx get _modified_files "$run_id" 2>/dev/null || true)
  if [[ -n "$modified" ]]; then
    [[ "$modified" != *".claudekiq/runs/"* ]]
  fi
}

@test "_pre-commit-validate exits cleanly with no active run" {
  local exit_code=0
  echo '{}' | "$CQ" _pre-commit-validate 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 0 ]
}

@test "_pre-commit-validate blocks commit in strict mode" {
  local run_id
  run_id=$(start_minimal)

  # Ensure strict safety
  jq '.safety = "strict"' "$TEST_DIR/.claudekiq/settings.json" > "$TEST_DIR/.claudekiq/settings.json.tmp"
  mv "$TEST_DIR/.claudekiq/settings.json.tmp" "$TEST_DIR/.claudekiq/settings.json"

  local exit_code=0
  local err
  err=$(echo '{}' | "$CQ" _pre-commit-validate 2>&1) || exit_code=$?
  [ "$exit_code" -eq 2 ]
  [[ "$err" == *"Blocked"* ]]
}

@test "_pre-commit-validate allows commit in relaxed mode" {
  local run_id
  run_id=$(start_minimal)

  jq '.safety = "relaxed"' "$TEST_DIR/.claudekiq/settings.json" > "$TEST_DIR/.claudekiq/settings.json.tmp"
  mv "$TEST_DIR/.claudekiq/settings.json.tmp" "$TEST_DIR/.claudekiq/settings.json"

  local exit_code=0
  echo '{}' | "$CQ" _pre-commit-validate 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 0 ]
}

@test "_pre-commit-validate allows step with allows_commit=true" {
  local run_id
  run_id=$(start_minimal)

  # Add allows_commit to current step
  local steps
  steps=$(cat "$TEST_DIR/.claudekiq/runs/$run_id/steps.json")
  local current_step
  current_step=$(run_meta "$run_id" current_step)
  steps=$(jq --arg id "$current_step" '[.[] | if .id == $id then . + {allows_commit: true} else . end]' <<< "$steps")
  echo "$steps" > "$TEST_DIR/.claudekiq/runs/$run_id/steps.json"

  jq '.safety = "strict"' "$TEST_DIR/.claudekiq/settings.json" > "$TEST_DIR/.claudekiq/settings.json.tmp"
  mv "$TEST_DIR/.claudekiq/settings.json.tmp" "$TEST_DIR/.claudekiq/settings.json"

  local exit_code=0
  echo '{}' | "$CQ" _pre-commit-validate 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 0 ]
}

@test "_pre-commit-validate allows step with commit in name" {
  local run_id
  run_id=$(start_minimal)

  # Rename current step to include "commit"
  local current_step
  current_step=$(run_meta "$run_id" current_step)
  local steps
  steps=$(cat "$TEST_DIR/.claudekiq/runs/$run_id/steps.json")
  steps=$(jq --arg id "$current_step" '[.[] | if .id == $id then .id = "commit-changes" | .name = "Commit Changes" else . end]' <<< "$steps")
  echo "$steps" > "$TEST_DIR/.claudekiq/runs/$run_id/steps.json"
  # Update meta to point to new step id
  jq '.current_step = "commit-changes"' "$TEST_DIR/.claudekiq/runs/$run_id/meta.json" > "$TEST_DIR/.claudekiq/runs/$run_id/meta.json.tmp"
  mv "$TEST_DIR/.claudekiq/runs/$run_id/meta.json.tmp" "$TEST_DIR/.claudekiq/runs/$run_id/meta.json"

  jq '.safety = "strict"' "$TEST_DIR/.claudekiq/settings.json" > "$TEST_DIR/.claudekiq/settings.json.tmp"
  mv "$TEST_DIR/.claudekiq/settings.json.tmp" "$TEST_DIR/.claudekiq/settings.json"

  local exit_code=0
  echo '{}' | "$CQ" _pre-commit-validate 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 0 ]
}

@test "_capture-output exits cleanly with no active run" {
  local exit_code=0
  echo '{}' | "$CQ" _capture-output 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 0 ]
}

@test "_capture-output stores response summary in context" {
  local run_id
  run_id=$(start_minimal)

  local hook_input
  hook_input=$(jq -cn '{response: {content: "I fixed the bug by updating the API endpoint"}}')
  echo "$hook_input" | "$CQ" _capture-output 2>/dev/null || true

  local current_step
  current_step=$(run_meta "$run_id" current_step)
  local result
  result=$("$CQ" ctx get "_result_${current_step}" "$run_id" 2>/dev/null)
  [[ -n "$result" ]]
  [[ "$result" == *"fixed the bug"* ]]
}

@test "step-done logs files array in step_done event" {
  local run_id
  run_id=$(start_minimal)

  # Stage a file modification to the step state
  local current_step
  current_step=$(run_meta "$run_id" current_step)
  local state
  state=$(cat "$TEST_DIR/.claudekiq/runs/$run_id/state.json")
  state=$(jq --arg id "$current_step" '.[$id].files = ["src/app.ts", "tests/app.test.ts"]' <<< "$state")
  echo "$state" > "$TEST_DIR/.claudekiq/runs/$run_id/state.json"

  "$CQ" step-done "$run_id" "$current_step" pass >/dev/null 2>&1

  # Check log has files
  local log_entry
  log_entry=$(tail -3 "$TEST_DIR/.claudekiq/runs/$run_id/log.jsonl" | grep "step_done" | tail -1)
  local files_count
  files_count=$(jq '.data.files | length' <<< "$log_entry")
  [[ "$files_count" -eq 2 ]]
}

# --- _safety-check tests ---

@test "_safety-check blocks rm_claudekiq in strict mode" {
  jq '.safety = "strict"' "$TEST_DIR/.claudekiq/settings.json" > "$TEST_DIR/.claudekiq/settings.json.tmp"
  mv "$TEST_DIR/.claudekiq/settings.json.tmp" "$TEST_DIR/.claudekiq/settings.json"

  local exit_code=0
  "$CQ" _safety-check rm_claudekiq 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 2 ]
}

@test "_safety-check warns rm_claudekiq in relaxed mode" {
  jq '.safety = "relaxed"' "$TEST_DIR/.claudekiq/settings.json" > "$TEST_DIR/.claudekiq/settings.json.tmp"
  mv "$TEST_DIR/.claudekiq/settings.json.tmp" "$TEST_DIR/.claudekiq/settings.json"

  local exit_code=0
  "$CQ" _safety-check rm_claudekiq 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 0 ]
}

@test "_safety-check respects per-operation policy map" {
  # Set safety as a map with rm_claudekiq=warn but edit_run_files=block
  jq '.safety = {"rm_claudekiq":"warn","edit_run_files":"block","git_checkout":"block","git_commit":"block"}' \
    "$TEST_DIR/.claudekiq/settings.json" > "$TEST_DIR/.claudekiq/settings.json.tmp"
  mv "$TEST_DIR/.claudekiq/settings.json.tmp" "$TEST_DIR/.claudekiq/settings.json"

  local exit_code=0
  "$CQ" _safety-check rm_claudekiq 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 0 ]

  exit_code=0
  "$CQ" _safety-check edit_run_files 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 2 ]
}

@test "_safety-check git_checkout allows when no active runs" {
  # No runs are active
  local exit_code=0
  "$CQ" _safety-check git_checkout 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 0 ]
}

@test "_safety-check git_checkout blocks when runs are active" {
  local run_id
  run_id=$(start_minimal)

  jq '.safety = "strict"' "$TEST_DIR/.claudekiq/settings.json" > "$TEST_DIR/.claudekiq/settings.json.tmp"
  mv "$TEST_DIR/.claudekiq/settings.json.tmp" "$TEST_DIR/.claudekiq/settings.json"

  local exit_code=0
  "$CQ" _safety-check git_checkout 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 2 ]
}

@test "_safety-check git_force_push blocks in strict mode" {
  jq '.safety = "strict"' "$TEST_DIR/.claudekiq/settings.json" > "$TEST_DIR/.claudekiq/settings.json.tmp"
  mv "$TEST_DIR/.claudekiq/settings.json.tmp" "$TEST_DIR/.claudekiq/settings.json"

  local exit_code=0
  "$CQ" _safety-check git_force_push 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 2 ]
}

@test "_safety-check git_force_push warns in relaxed mode" {
  jq '.safety = "relaxed"' "$TEST_DIR/.claudekiq/settings.json" > "$TEST_DIR/.claudekiq/settings.json.tmp"
  mv "$TEST_DIR/.claudekiq/settings.json.tmp" "$TEST_DIR/.claudekiq/settings.json"

  local exit_code=0
  "$CQ" _safety-check git_force_push 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 0 ]
}

@test "_safety-check git_reset_hard blocks in strict mode" {
  jq '.safety = "strict"' "$TEST_DIR/.claudekiq/settings.json" > "$TEST_DIR/.claudekiq/settings.json.tmp"
  mv "$TEST_DIR/.claudekiq/settings.json.tmp" "$TEST_DIR/.claudekiq/settings.json"

  local exit_code=0
  "$CQ" _safety-check git_reset_hard 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 2 ]
}

@test "_safety-check git_rebase blocks in strict mode" {
  jq '.safety = "strict"' "$TEST_DIR/.claudekiq/settings.json" > "$TEST_DIR/.claudekiq/settings.json.tmp"
  mv "$TEST_DIR/.claudekiq/settings.json.tmp" "$TEST_DIR/.claudekiq/settings.json"

  local exit_code=0
  "$CQ" _safety-check git_rebase 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 2 ]
}

@test "step state initializes with empty files array" {
  local run_id
  run_id=$(start_minimal)

  local current_step
  current_step=$(run_meta "$run_id" current_step)
  local files
  files=$(step_state "$run_id" "$current_step" "files")
  # Should be an empty array (or null for pre-existing states)
  [[ "$files" == "[]" || "$files" == "null" ]]
}
