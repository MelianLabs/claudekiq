#!/usr/bin/env bash
# setup.bash — Shared test helpers for cq BATS tests

CQ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CQ="${CQ_ROOT}/cq"
FIXTURES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures"

setup_test_project() {
  TEST_DIR=$(mktemp -d)
  cd "$TEST_DIR"
  "$CQ" init >/dev/null 2>&1
  # Copy minimal fixture
  cp "$FIXTURES"/minimal.yml .claudekiq/workflows/
  cp "$FIXTURES"/with_routing.yml .claudekiq/workflows/
  cp "$FIXTURES"/with-agents.yml .claudekiq/workflows/ 2>/dev/null || true
}

teardown_test_project() {
  cd /
  rm -rf "$TEST_DIR"
}

# Start minimal workflow and capture run ID
start_minimal() {
  "$CQ" start minimal "$@" --json 2>/dev/null | jq -r '.run_id'
}

start_with_routing() {
  "$CQ" start with_routing "$@" --json 2>/dev/null | jq -r '.run_id'
}

# Get a field from meta.json
run_meta() {
  local run_id="$1" field="$2"
  jq -r ".$field" "$TEST_DIR/.claudekiq/runs/$run_id/meta.json"
}

# Get a field from state.json for a step
step_state() {
  local run_id="$1" step_id="$2" field="$3"
  jq -r --arg id "$step_id" '.[$id].'"$field" "$TEST_DIR/.claudekiq/runs/$run_id/state.json"
}

# --- Convenience helpers to reduce test boilerplate ---

# Complete the current step with given outcome (default: pass)
# Usage: advance_step "$run_id" [outcome] [result_json]
advance_step() {
  local run_id="$1" outcome="${2:-pass}" result="${3:-}"
  local current_step
  current_step=$(run_meta "$run_id" current_step)
  local args=("$run_id" "$current_step" "$outcome")
  [[ -n "$result" ]] && args+=("$result")
  "$CQ" step-done "${args[@]}" >/dev/null 2>&1
}

# Assert run status matches expected value
assert_status() {
  local run_id="$1" expected="$2"
  local actual
  actual=$(run_meta "$run_id" status)
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected status '${expected}' but got '${actual}'" >&2
    return 1
  fi
}

# Assert current step matches expected value
assert_current_step() {
  local run_id="$1" expected="$2"
  local actual
  actual=$(run_meta "$run_id" current_step)
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected current_step '${expected}' but got '${actual}'" >&2
    return 1
  fi
}
