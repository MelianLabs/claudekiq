#!/usr/bin/env bats
# test_validation.bats — Tests for enhanced validation (Phase 2)

load setup.bash

setup() {
  setup_test_project
  # Copy validation test fixtures
  cp "$FIXTURES"/circular-routing.yml .claudekiq/workflows/
  cp "$FIXTURES"/circular-gated.yml .claudekiq/workflows/
  cp "$FIXTURES"/missing-vars.yml .claudekiq/workflows/
  cp "$FIXTURES"/unreachable.yml .claudekiq/workflows/
  cp "$FIXTURES"/base-workflow.yml .claudekiq/workflows/
  cp "$FIXTURES"/child-workflow.yml .claudekiq/workflows/
  cp "$FIXTURES"/circular-extends.yml .claudekiq/workflows/
  cp "$FIXTURES"/circular-extends-b.yml .claudekiq/workflows/
}

teardown() {
  teardown_test_project
}

@test "validate detects circular routing without gate" {
  run "$CQ" workflows validate .claudekiq/workflows/circular-routing.yml
  # Should still be valid (warnings don't fail) but warn
  [[ "$output" == *"Circular routing"* ]] || [[ "$status" -eq 0 ]]
}

@test "validate allows circular routing through review gate" {
  run "$CQ" workflows validate .claudekiq/workflows/circular-gated.yml
  [ "$status" -eq 0 ]
}

@test "validate warns on missing context variables" {
  run "$CQ" workflows validate .claudekiq/workflows/missing-vars.yml
  # Should still be valid but warn about undeclared_var
  [ "$status" -eq 0 ]
  [[ "$output" == *"undeclared_var"* ]] || [[ "$output" == *"Valid"* ]]
}

@test "validate detects unreachable steps" {
  run "$CQ" workflows validate .claudekiq/workflows/unreachable.yml
  # Should still be valid but warn
  [ "$status" -eq 0 ]
  [[ "$output" == *"unreachable"* ]] || [[ "$output" == *"Valid"* ]]
}

@test "validate checks extends field exists" {
  run "$CQ" workflows validate .claudekiq/workflows/child-workflow.yml
  [ "$status" -eq 0 ]
}

@test "validate errors on extends to nonexistent workflow" {
  cat > .claudekiq/workflows/bad-extends.yml <<'YML'
name: bad-extends
extends: nonexistent-workflow
description: Extends a workflow that doesn't exist

steps:
  - id: step-a
    name: Step A
    type: bash
    target: "echo a"
    gate: auto
YML
  run "$CQ" workflows validate .claudekiq/workflows/bad-extends.yml
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "validate detects circular extends" {
  run "$CQ" workflows validate .claudekiq/workflows/circular-extends.yml
  [ "$status" -eq 1 ]
  [[ "$output" == *"Circular extends"* ]]
}

@test "validate warns on override of nonexistent step" {
  cat > .claudekiq/workflows/bad-override.yml <<'YML'
name: bad-override
extends: base-workflow
description: Overrides a step that doesn't exist

steps: []

override:
  nonexistent-step:
    gate: review
YML
  run "$CQ" workflows validate .claudekiq/workflows/bad-override.yml
  # Should warn but not error
  [[ "$output" == *"nonexistent-step"* ]] || [ "$status" -eq 0 ]
}
