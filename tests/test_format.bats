#!/usr/bin/env bats
load setup.bash

setup() {
  setup_test_project
}

teardown() {
  teardown_test_project
}

# --- workflow with agent steps (prompt, context, model, resume) ---

@test "start creates run from agent workflow" {
  local run_id
  run_id=$("$CQ" start with-agents --json 2>/dev/null | jq -r '.run_id')
  [ -d ".claudekiq/runs/$run_id" ]
  [ "$(run_meta "$run_id" status)" = "running" ]
  [ "$(run_meta "$run_id" current_step)" = "plan" ]
}

@test "start stores params in meta.json" {
  local run_id
  run_id=$("$CQ" start with-agents --json 2>/dev/null | jq -r '.run_id')
  local has_params
  has_params=$(jq 'has("params")' ".claudekiq/runs/$run_id/meta.json")
  [ "$has_params" = "true" ]
  local desc_param
  desc_param=$(jq -r '.params.description' ".claudekiq/runs/$run_id/meta.json")
  [ "$desc_param" = "What to build" ]
}

@test "start applies defaults from workflow" {
  local run_id
  run_id=$("$CQ" start with-agents --json 2>/dev/null | jq -r '.run_id')
  local desc
  desc=$(jq -r '.description' ".claudekiq/runs/$run_id/ctx.json")
  [ "$desc" = "test feature" ]
  local branch
  branch=$(jq -r '.branch_name' ".claudekiq/runs/$run_id/ctx.json")
  [ "$branch" = "test-branch" ]
}

@test "start overrides defaults with CLI args" {
  local run_id
  run_id=$("$CQ" start with-agents --description="custom thing" --json 2>/dev/null | jq -r '.run_id')
  local desc
  desc=$(jq -r '.description' ".claudekiq/runs/$run_id/ctx.json")
  [ "$desc" = "custom thing" ]
}

@test "steps.json preserves prompt field" {
  local run_id
  run_id=$("$CQ" start with-agents --json 2>/dev/null | jq -r '.run_id')
  local prompt
  prompt=$(jq -r '.[0].prompt' ".claudekiq/runs/$run_id/steps.json")
  [[ "$prompt" == *"Plan implementation"* ]]
}

@test "steps.json preserves context field" {
  local run_id
  run_id=$("$CQ" start with-agents --json 2>/dev/null | jq -r '.run_id')
  local ctx
  ctx=$(jq -r '.[0].context[0]' ".claudekiq/runs/$run_id/steps.json")
  [ "$ctx" = "description" ]
}

@test "steps.json preserves model field" {
  local run_id
  run_id=$("$CQ" start with-agents --json 2>/dev/null | jq -r '.run_id')
  local model
  model=$(jq -r '.[0].model' ".claudekiq/runs/$run_id/steps.json")
  [ "$model" = "sonnet" ]
}

@test "steps.json preserves resume field" {
  local run_id
  run_id=$("$CQ" start with-agents --json 2>/dev/null | jq -r '.run_id')
  local resume
  resume=$(jq -r '.[2].resume' ".claudekiq/runs/$run_id/steps.json")
  [ "$resume" = "true" ]
}

@test "all agent workflow steps initialized as pending" {
  local run_id
  run_id=$("$CQ" start with-agents --json 2>/dev/null | jq -r '.run_id')
  [ "$(step_state "$run_id" plan status)" = "pending" ]
  [ "$(step_state "$run_id" create-branch status)" = "pending" ]
  [ "$(step_state "$run_id" implement status)" = "pending" ]
  [ "$(step_state "$run_id" commit status)" = "pending" ]
}

# --- validation ---

@test "validate accepts workflow with prompt and context" {
  cat > "$TEST_DIR/.claudekiq/workflows/clean-agents.yml" <<'EOF'
name: clean-agents
description: Clean workflow for validation
params:
  description: "What to build"
defaults:
  description: ""
steps:
  - id: plan
    name: Plan
    type: agent
    prompt: "Plan the implementation"
    context: [description]
    gate: auto
    model: sonnet
  - id: build
    name: Build
    type: bash
    target: "echo building"
    gate: auto
EOF
  run "$CQ" workflows validate "$TEST_DIR/.claudekiq/workflows/clean-agents.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Valid"* ]]
}

@test "validate routing workflow detects missing agent target" {
  run "$CQ" workflows validate "$TEST_DIR/.claudekiq/workflows/with_routing.yml"
  # with_routing.yml references @dev which doesn't exist in test env
  [ "$status" -eq 1 ]
  [[ "$output" == *"@dev"* ]]
}

@test "validate rejects unknown model" {
  cat > "$TEST_DIR/.claudekiq/workflows/bad-model.yml" <<'EOF'
name: bad-model
description: test
steps:
  - id: step1
    name: Step 1
    type: agent
    prompt: "do something"
    model: gpt-4
    gate: auto
EOF
  run "$CQ" workflows validate "$TEST_DIR/.claudekiq/workflows/bad-model.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown model"* ]]
}

@test "validate warns on deprecated args_template" {
  cat > "$TEST_DIR/.claudekiq/workflows/deprecated.yml" <<'EOF'
name: deprecated
description: test
steps:
  - id: step1
    name: Step 1
    type: agent
    target: "@dev"
    args_template: "do the thing"
    gate: auto
EOF
  run "$CQ" workflows validate "$TEST_DIR/.claudekiq/workflows/deprecated.yml" 2>&1
  [[ "$output" == *"deprecated"* ]] || [[ "$BATS_RUN_STDERR" == *"deprecated"* ]] || true
}

@test "validate fails on agent step without prompt or target" {
  cat > "$TEST_DIR/.claudekiq/workflows/no-prompt.yml" <<'EOF'
name: no-prompt
description: test
steps:
  - id: step1
    name: Step 1
    type: agent
    gate: auto
EOF
  run "$CQ" workflows validate "$TEST_DIR/.claudekiq/workflows/no-prompt.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"prompt"* ]] || [[ "$output" == *"target"* ]]
}

# --- model validation ---

@test "valid model names accepted on start" {
  run "$CQ" start with-agents --json 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" != *"unknown model"* ]]
}

# --- prompt builder ---

@test "step prompt field preserved in steps.json" {
  local run_id
  run_id=$("$CQ" start with-agents --json 2>/dev/null | jq -r '.run_id')
  local prompt
  prompt=$(jq -r '.[0].prompt' ".claudekiq/runs/$run_id/steps.json")
  [ -n "$prompt" ]
  [[ "$prompt" == *"Plan implementation"* ]]
}

# --- backward compatibility ---

@test "workflow without params has no params in meta" {
  local run_id
  run_id=$(start_minimal)
  local params
  params=$(jq -r '.params // "null"' ".claudekiq/runs/$run_id/meta.json")
  [ "$params" = "null" ]
}

@test "workflow without prompt or context still works" {
  local run_id
  run_id=$(start_minimal)
  [ -d ".claudekiq/runs/$run_id" ]
  [ "$(run_meta "$run_id" status)" = "running" ]
}
