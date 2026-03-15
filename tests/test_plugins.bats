#!/usr/bin/env bats
# test_plugins.bats — Tests for step type resolution (agent-backed custom types)

load setup.bash

setup() { setup_test_project; }
teardown() { teardown_test_project; }

# --- cq_resolve_step_type tests ---

@test "resolve_step_type returns builtin for bash" {
  source "$CQ_ROOT/lib/core.sh"
  export CQ_PROJECT_ROOT="$TEST_DIR"

  result=$(cq_resolve_step_type "bash")
  [ "$result" = "builtin" ]
}

@test "resolve_step_type returns builtin for agent" {
  source "$CQ_ROOT/lib/core.sh"
  export CQ_PROJECT_ROOT="$TEST_DIR"

  result=$(cq_resolve_step_type "agent")
  [ "$result" = "builtin" ]
}

@test "resolve_step_type returns builtin for all built-in types" {
  source "$CQ_ROOT/lib/core.sh"
  export CQ_PROJECT_ROOT="$TEST_DIR"

  for t in bash agent skill; do
    result=$(cq_resolve_step_type "$t")
    [ "$result" = "builtin" ]
  done
}

@test "resolve_step_type returns agent for agent-backed custom type" {
  source "$CQ_ROOT/lib/core.sh"
  export CQ_PROJECT_ROOT="$TEST_DIR"

  mkdir -p .claude/agents
  cp "$FIXTURES/mock-agent.md" .claude/agents/deploy.md

  result=$(cq_resolve_step_type "deploy")
  [ "$result" = "agent" ]
}

@test "resolve_step_type returns convention for missing type" {
  source "$CQ_ROOT/lib/core.sh"
  export CQ_PROJECT_ROOT="$TEST_DIR"

  result=$(cq_resolve_step_type "nonexistent")
  [ "$result" = "convention" ]
}

@test "resolve_step_type returns convention for custom type like review" {
  source "$CQ_ROOT/lib/core.sh"
  export CQ_PROJECT_ROOT="$TEST_DIR"

  result=$(cq_resolve_step_type "review")
  [ "$result" = "convention" ]
}

@test "resolve_step_type checks scan results for agent" {
  source "$CQ_ROOT/lib/core.sh"
  export CQ_PROJECT_ROOT="$TEST_DIR"

  # Write scan results with an agent that doesn't have a .md file on disk
  jq '. + {"agents":[{"name":"remote-deploy"}]}' .claudekiq/settings.json > .claudekiq/settings.json.tmp
  mv .claudekiq/settings.json.tmp .claudekiq/settings.json

  result=$(cq_resolve_step_type "remote-deploy")
  [ "$result" = "agent" ]
}

# --- Workflow validation with custom types ---

@test "workflows validate treats unknown type as convention-based" {
  cat > .claudekiq/workflows/custom-type.yml <<'YAML'
name: custom-type-test
description: Test custom step types
steps:
  - id: step1
    type: nonexistent-type
    target: "echo hello"
    gate: auto
YAML

  run "$CQ" workflows validate .claudekiq/workflows/custom-type.yml
  [ "$status" -eq 0 ]
}

@test "workflows validate passes with agent-backed custom type" {
  mkdir -p .claude/agents
  cp "$FIXTURES/mock-agent.md" .claude/agents/deploy.md

  cat > .claudekiq/workflows/agent-plugin.yml <<'YAML'
name: agent-plugin-test
description: Test agent-backed plugin type
steps:
  - id: step1
    type: deploy
    target: "deploy to staging"
    gate: auto
YAML

  run "$CQ" workflows validate .claudekiq/workflows/agent-plugin.yml
  [ "$status" -eq 0 ]
}
