#!/usr/bin/env bats
# test_sub_workflows.bats — Tests for sub-workflow step type

load setup.bash

setup() {
  setup_test_project
  cp "$FIXTURES"/with-sub-workflow.yml .claudekiq/workflows/
  cp "$FIXTURES"/sub-deploy.yml .claudekiq/workflows/
}

teardown() {
  teardown_test_project
}

@test "workflow step type resolves as builtin" {
  local kind
  kind=$(source "$CQ_ROOT/lib/core.sh" 2>/dev/null; CQ_PROJECT_ROOT="$TEST_DIR"; cq_resolve_step_type "workflow")
  [[ "$kind" == "builtin" ]]
}

@test "start with --parent links child to parent" {
  local parent_id
  parent_id=$("$CQ" start with-sub-workflow --json 2>/dev/null | jq -r '.run_id')

  local child_id
  child_id=$("$CQ" start sub-deploy --parent="$parent_id" --parent-step=deploy-staging --json 2>/dev/null | jq -r '.run_id')

  # Check child has parent linkage
  local child_parent
  child_parent=$(jq -r '.parent_run_id' "$TEST_DIR/.claudekiq/runs/$child_id/meta.json")
  [[ "$child_parent" == "$parent_id" ]]

  local child_step
  child_step=$(jq -r '.parent_step_id' "$TEST_DIR/.claudekiq/runs/$child_id/meta.json")
  [[ "$child_step" == "deploy-staging" ]]

  # Check parent has child in children array
  local children_count
  children_count=$(jq '.children | length' "$TEST_DIR/.claudekiq/runs/$parent_id/meta.json")
  [[ "$children_count" -eq 1 ]]

  local child_ref
  child_ref=$(jq -r '.children[0].run_id' "$TEST_DIR/.claudekiq/runs/$parent_id/meta.json")
  [[ "$child_ref" == "$child_id" ]]
}

@test "cancel parent cascades to child" {
  local parent_id
  parent_id=$("$CQ" start with-sub-workflow --json 2>/dev/null | jq -r '.run_id')

  local child_id
  child_id=$("$CQ" start sub-deploy --parent="$parent_id" --parent-step=deploy-staging --json 2>/dev/null | jq -r '.run_id')

  "$CQ" cancel "$parent_id" >/dev/null 2>&1

  local child_status
  child_status=$(jq -r '.status' "$TEST_DIR/.claudekiq/runs/$child_id/meta.json")
  [[ "$child_status" == "cancelled" ]]
}

@test "pause parent cascades to child" {
  local parent_id
  parent_id=$("$CQ" start with-sub-workflow --json 2>/dev/null | jq -r '.run_id')

  local child_id
  child_id=$("$CQ" start sub-deploy --parent="$parent_id" --parent-step=deploy-staging --json 2>/dev/null | jq -r '.run_id')

  "$CQ" pause "$parent_id" >/dev/null 2>&1

  local child_status
  child_status=$(jq -r '.status' "$TEST_DIR/.claudekiq/runs/$child_id/meta.json")
  [[ "$child_status" == "paused" ]]
}

@test "child completion propagates outputs to parent context" {
  local parent_id
  parent_id=$("$CQ" start with-sub-workflow --json 2>/dev/null | jq -r '.run_id')
  # Advance parent to deploy-staging step
  "$CQ" step-done "$parent_id" prepare pass >/dev/null 2>&1

  local child_id
  child_id=$("$CQ" start sub-deploy --parent="$parent_id" --parent-step=deploy-staging --json 2>/dev/null | jq -r '.run_id')

  # Set a value in child context
  "$CQ" ctx set deploy_url "https://staging.example.com" "$child_id" >/dev/null 2>&1

  # Complete child workflow
  "$CQ" step-done "$child_id" build pass >/dev/null 2>&1
  "$CQ" step-done "$child_id" deploy pass >/dev/null 2>&1

  # Check that output was copied to parent context
  local parent_url
  parent_url=$("$CQ" ctx get "sub_deploy-staging.deploy_url" "$parent_id" 2>/dev/null)
  [[ "$parent_url" == "https://staging.example.com" ]]
}

@test "copy_context_map resolves interpolation from parent" {
  local parent_id
  parent_id=$("$CQ" start with-sub-workflow --environment=production --json 2>/dev/null | jq -r '.run_id')

  # Manually test context copy
  local child_id
  child_id=$("$CQ" start sub-deploy --parent="$parent_id" --parent-step=deploy-staging --json 2>/dev/null | jq -r '.run_id')

  # Manually call copy_context_map
  source "$CQ_ROOT/lib/core.sh" 2>/dev/null
  source "$CQ_ROOT/lib/storage.sh" 2>/dev/null
  CQ_PROJECT_ROOT="$TEST_DIR"
  cq_copy_context_map "$parent_id" "$child_id" '{"environment": "{{environment}}"}'

  local child_env
  child_env=$(jq -r '.environment' "$TEST_DIR/.claudekiq/runs/$child_id/ctx.json")
  [[ "$child_env" == "production" ]]
}

@test "validate accepts workflow step with template" {
  run "$CQ" workflows validate "$FIXTURES/with-sub-workflow.yml"
  [ "$status" -eq 0 ]
}

@test "validate rejects workflow step without template" {
  local bad_file="$TEST_DIR/bad-workflow.yml"
  cat > "$bad_file" <<'EOF'
name: bad-workflow
description: Missing template
steps:
  - id: bad
    type: workflow
    gate: auto
EOF
  run "$CQ" workflows validate "$bad_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"template"* ]]
}

@test "child_run_ids returns children" {
  local parent_id
  parent_id=$("$CQ" start with-sub-workflow --json 2>/dev/null | jq -r '.run_id')
  local child_id
  child_id=$("$CQ" start sub-deploy --parent="$parent_id" --parent-step=deploy-staging --json 2>/dev/null | jq -r '.run_id')

  source "$CQ_ROOT/lib/core.sh" 2>/dev/null
  source "$CQ_ROOT/lib/storage.sh" 2>/dev/null
  CQ_PROJECT_ROOT="$TEST_DIR"

  local children
  children=$(cq_child_run_ids "$parent_id")
  [[ "$children" == *"$child_id"* ]]
}
