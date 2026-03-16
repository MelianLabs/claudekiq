#!/usr/bin/env bats
# test_context_builders.bats — Tests for context builder resolution

load setup.bash

setup() {
  setup_test_project
  cd "$TEST_DIR"
  git init -q
  git add -A
  git commit -q -m "init" --allow-empty
}

teardown() {
  teardown_test_project
}

@test "_resolve-context with no builders returns empty" {
  local run_id
  run_id=$(start_minimal)

  run "$CQ" _resolve-context "$run_id" step-a
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_resolve-context with git_diff builder" {
  local run_id
  run_id=$(start_minimal)

  # Add context_builders to step-a
  local steps
  steps=$(cat "$TEST_DIR/.claudekiq/runs/$run_id/steps.json")
  steps=$(jq '[.[] | if .id == "step-a" then . + {context_builders: [{type: "git_diff"}]} else . end]' <<< "$steps")
  echo "$steps" > "$TEST_DIR/.claudekiq/runs/$run_id/steps.json"

  # Create a git diff
  echo "new content" > "$TEST_DIR/changed.txt"
  git add "$TEST_DIR/changed.txt"

  run "$CQ" _resolve-context "$run_id" step-a
  [ "$status" -eq 0 ]
  [[ "$output" == *"Git Diff"* ]]
  [[ "$output" == *"changed.txt"* ]]
}

@test "_resolve-context with error_context builder" {
  local run_id
  run_id=$(start_minimal)

  # Set error_output in state for step-a
  local state
  state=$(cat "$TEST_DIR/.claudekiq/runs/$run_id/state.json")
  state=$(jq '.["step-a"].error_output = "TypeError: undefined is not a function"' <<< "$state")
  echo "$state" > "$TEST_DIR/.claudekiq/runs/$run_id/state.json"

  # Add context_builders to step-a
  local steps
  steps=$(cat "$TEST_DIR/.claudekiq/runs/$run_id/steps.json")
  steps=$(jq '[.[] | if .id == "step-a" then . + {context_builders: [{type: "error_context"}]} else . end]' <<< "$steps")
  echo "$steps" > "$TEST_DIR/.claudekiq/runs/$run_id/steps.json"

  run "$CQ" _resolve-context "$run_id" step-a
  [ "$status" -eq 0 ]
  [[ "$output" == *"Previous Error"* ]]
  [[ "$output" == *"TypeError"* ]]
}

@test "_resolve-context with file_contents builder" {
  local run_id
  run_id=$(start_minimal)

  # Create a file to read
  echo "hello world" > "$TEST_DIR/src/app.ts" 2>/dev/null || { mkdir -p "$TEST_DIR/src" && echo "hello world" > "$TEST_DIR/src/app.ts"; }

  # Add context_builders to step-a
  local steps
  steps=$(cat "$TEST_DIR/.claudekiq/runs/$run_id/steps.json")
  steps=$(jq --arg p "$TEST_DIR/src/app.ts" '[.[] | if .id == "step-a" then . + {context_builders: [{type: "file_contents", paths: [$p]}]} else . end]' <<< "$steps")
  echo "$steps" > "$TEST_DIR/.claudekiq/runs/$run_id/steps.json"

  run "$CQ" _resolve-context "$run_id" step-a
  [ "$status" -eq 0 ]
  [[ "$output" == *"File:"* ]]
  [[ "$output" == *"hello world"* ]]
}

@test "_resolve-context with command_output builder" {
  local run_id
  run_id=$(start_minimal)

  # Add context_builders to step-a
  local steps
  steps=$(cat "$TEST_DIR/.claudekiq/runs/$run_id/steps.json")
  steps=$(jq '[.[] | if .id == "step-a" then . + {context_builders: [{type: "command_output", command: "echo test-output-123"}]} else . end]' <<< "$steps")
  echo "$steps" > "$TEST_DIR/.claudekiq/runs/$run_id/steps.json"

  run "$CQ" _resolve-context "$run_id" step-a
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-output-123"* ]]
}

@test "_resolve-context with error_context builder but no previous error" {
  local run_id
  run_id=$(start_minimal)

  # Add context_builders to step-a (no error_output in state)
  local steps
  steps=$(cat "$TEST_DIR/.claudekiq/runs/$run_id/steps.json")
  steps=$(jq '[.[] | if .id == "step-a" then . + {context_builders: [{type: "error_context"}]} else . end]' <<< "$steps")
  echo "$steps" > "$TEST_DIR/.claudekiq/runs/$run_id/steps.json"

  run "$CQ" _resolve-context "$run_id" step-a
  [ "$status" -eq 0 ]
  # Should return empty when no error exists
  [[ "$output" != *"Previous Error"* ]]
}
