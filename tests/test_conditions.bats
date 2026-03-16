#!/usr/bin/env bats
load setup.bash

setup() {
  # Source core.sh for unit testing condition evaluation
  export CQ_JSON="false"
  export CQ_PROJECT_ROOT="/tmp/cq-test-$$"
  source "${CQ_ROOT}/lib/core.sh"
}

# --- Existing operators (regression) ---

@test "condition: == equality" {
  cq_evaluate_condition "hello == hello"
}

@test "condition: == inequality returns false" {
  run bash -c "source '${CQ_ROOT}/lib/core.sh' && cq_evaluate_condition 'hello == world'"
  [ "$status" -ne 0 ]
}

@test "condition: != not equal" {
  cq_evaluate_condition "hello != world"
}

@test "condition: contains" {
  cq_evaluate_condition "hello world contains world"
}

@test "condition: empty with empty lhs" {
  cq_evaluate_condition " empty"
}

@test "condition: empty with non-empty value fails" {
  run bash -c "source '${CQ_ROOT}/lib/core.sh' && cq_evaluate_condition 'some_value empty'"
  [ "$status" -ne 0 ]
}

@test "condition: not_empty" {
  cq_evaluate_condition "hello not_empty"
}

# --- Numeric comparisons ---

@test "condition: > greater than (true)" {
  cq_evaluate_condition "5 > 3"
}

@test "condition: > greater than (false)" {
  run bash -c "source '${CQ_ROOT}/lib/core.sh' && cq_evaluate_condition '2 > 3'"
  [ "$status" -ne 0 ]
}

@test "condition: < less than" {
  cq_evaluate_condition "2 < 5"
}

@test "condition: >= greater or equal (equal)" {
  cq_evaluate_condition "3 >= 3"
}

@test "condition: >= greater or equal (greater)" {
  cq_evaluate_condition "5 >= 3"
}

@test "condition: <= less or equal" {
  cq_evaluate_condition "3 <= 5"
}

@test "condition: > with zero" {
  cq_evaluate_condition "1 > 0"
}

@test "condition: > zero false" {
  run bash -c "source '${CQ_ROOT}/lib/core.sh' && cq_evaluate_condition '0 > 0'"
  [ "$status" -ne 0 ]
}

# --- Regex matching ---

@test "condition: matches regex (simple)" {
  cq_evaluate_condition "feature matches feat"
}

@test "condition: matches regex (anchored)" {
  cq_evaluate_condition "rails,webpack matches rails"
}

@test "condition: matches regex (no match)" {
  run bash -c "source '${CQ_ROOT}/lib/core.sh' && cq_evaluate_condition 'hello matches ^world'"
  [ "$status" -ne 0 ]
}

# --- Compound AND ---

@test "condition: AND both true" {
  cq_evaluate_condition "a == a AND b == b"
}

@test "condition: AND first false" {
  run bash -c "source '${CQ_ROOT}/lib/core.sh' && cq_evaluate_condition 'a == x AND b == b'"
  [ "$status" -ne 0 ]
}

@test "condition: AND second false" {
  run bash -c "source '${CQ_ROOT}/lib/core.sh' && cq_evaluate_condition 'a == a AND b == x'"
  [ "$status" -ne 0 ]
}

@test "condition: AND triple" {
  cq_evaluate_condition "1 == 1 AND 2 == 2 AND 3 == 3"
}

# --- Compound OR ---

@test "condition: OR first true" {
  cq_evaluate_condition "a == a OR b == x"
}

@test "condition: OR second true" {
  cq_evaluate_condition "a == x OR b == b"
}

@test "condition: OR both false" {
  run bash -c "source '${CQ_ROOT}/lib/core.sh' && cq_evaluate_condition 'a == x OR b == y'"
  [ "$status" -ne 0 ]
}

# --- Numeric + compound ---

@test "condition: numeric AND compound" {
  cq_evaluate_condition "5 > 0 AND 3 < 10"
}

@test "condition: numeric OR compound" {
  cq_evaluate_condition "0 > 5 OR 3 < 10"
}

# --- Integration: conditions in workflow routing ---

@test "condition: routing with numeric > in workflow" {
  setup_test_project
  cat > "$TEST_DIR/.claudekiq/workflows/numeric.yml" <<'EOF'
name: numeric
description: Test numeric conditions
defaults:
  critical_count: "3"
steps:
  - id: check
    name: Check
    type: bash
    target: "echo check"
    gate: auto
    next:
      - when: "{{critical_count}} > 0"
        goto: fix
      - default: done
  - id: fix
    name: Fix
    type: bash
    target: "echo fix"
    gate: auto
  - id: done
    name: Done
    type: bash
    target: "echo done"
    gate: auto
EOF
  local run_id
  run_id=$("$CQ" start numeric --json 2>/dev/null | jq -r '.run_id')
  "$CQ" step-done "$run_id" check pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" current_step)" = "fix" ]
  teardown_test_project
}

@test "condition: routing with matches in workflow" {
  setup_test_project
  cat > "$TEST_DIR/.claudekiq/workflows/regex.yml" <<'EOF'
name: regex
description: Test regex conditions
defaults:
  stacks: "rails,webpack"
steps:
  - id: detect
    name: Detect
    type: bash
    target: "echo detect"
    gate: auto
    next:
      - when: "{{stacks}} matches rails"
        goto: run-rails
      - default: done
  - id: run-rails
    name: Run Rails
    type: bash
    target: "echo rails"
    gate: auto
  - id: done
    name: Done
    type: bash
    target: "echo done"
    gate: auto
EOF
  local run_id
  run_id=$("$CQ" start regex --json 2>/dev/null | jq -r '.run_id')
  "$CQ" step-done "$run_id" detect pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" current_step)" = "run-rails" ]
  teardown_test_project
}
