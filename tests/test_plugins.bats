#!/usr/bin/env bats
# test_plugins.bats — Tests for plugin system (step type resolution)

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

  for t in bash agent skill manual subflow for_each parallel batch; do
    result=$(cq_resolve_step_type "$t")
    [ "$result" = "builtin" ]
  done
}

@test "resolve_step_type returns agent for agent-backed plugin" {
  source "$CQ_ROOT/lib/core.sh"
  export CQ_PROJECT_ROOT="$TEST_DIR"

  mkdir -p .claude/agents
  cp "$FIXTURES/mock-agent.md" .claude/agents/deploy.md

  result=$(cq_resolve_step_type "deploy")
  [ "$result" = "agent" ]
}

@test "resolve_step_type returns plugin for bash plugin" {
  source "$CQ_ROOT/lib/core.sh"
  export CQ_PROJECT_ROOT="$TEST_DIR"

  mkdir -p .claudekiq/plugins
  cp "$FIXTURES/mock-plugin.sh" .claudekiq/plugins/deploy.sh
  chmod +x .claudekiq/plugins/deploy.sh

  result=$(cq_resolve_step_type "deploy")
  [ "$result" = "plugin" ]
}

@test "resolve_step_type agent takes priority over bash plugin" {
  source "$CQ_ROOT/lib/core.sh"
  export CQ_PROJECT_ROOT="$TEST_DIR"

  # Both exist
  mkdir -p .claude/agents
  cp "$FIXTURES/mock-agent.md" .claude/agents/deploy.md
  mkdir -p .claudekiq/plugins
  cp "$FIXTURES/mock-plugin.sh" .claudekiq/plugins/deploy.sh
  chmod +x .claudekiq/plugins/deploy.sh

  result=$(cq_resolve_step_type "deploy")
  [ "$result" = "agent" ]
}

@test "resolve_step_type returns unknown for missing type" {
  source "$CQ_ROOT/lib/core.sh"
  export CQ_PROJECT_ROOT="$TEST_DIR"

  result=$(cq_resolve_step_type "nonexistent")
  [ "$result" = "unknown" ]
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

@test "resolve_step_type checks scan results for plugin" {
  source "$CQ_ROOT/lib/core.sh"
  export CQ_PROJECT_ROOT="$TEST_DIR"

  # Write scan results with a plugin that doesn't have a .sh file on disk
  jq '. + {"plugins":[{"name":"custom-step"}]}' .claudekiq/settings.json > .claudekiq/settings.json.tmp
  mv .claudekiq/settings.json.tmp .claudekiq/settings.json

  result=$(cq_resolve_step_type "custom-step")
  [ "$result" = "plugin" ]
}

# --- Bash plugin execution protocol ---

@test "bash plugin receives step JSON on stdin" {
  mkdir -p .claudekiq/plugins
  cat > .claudekiq/plugins/echo-input.sh <<'PLUGIN'
#!/usr/bin/env bash
input=$(cat)
echo "{\"status\":\"pass\",\"output\":{\"received\":$input}}"
PLUGIN
  chmod +x .claudekiq/plugins/echo-input.sh

  local step_json='{"id":"test","type":"echo-input","target":"hello"}'
  local result
  result=$(echo "$step_json" | CQ_RUN_ID=test CQ_STEP_ID=test CQ_PROJECT_ROOT="$TEST_DIR" .claudekiq/plugins/echo-input.sh)

  [ "$(echo "$result" | jq -r '.status')" = "pass" ]
  [ "$(echo "$result" | jq -r '.output.received.target')" = "hello" ]
}

@test "bash plugin exit 0 means pass" {
  mkdir -p .claudekiq/plugins
  cat > .claudekiq/plugins/pass-plugin.sh <<'PLUGIN'
#!/usr/bin/env bash
cat > /dev/null
echo '{"status":"pass","output":{"message":"ok"}}'
exit 0
PLUGIN
  chmod +x .claudekiq/plugins/pass-plugin.sh

  run bash -c 'echo "{}" | .claudekiq/plugins/pass-plugin.sh'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "pass" ]
}

@test "bash plugin exit 1 means fail" {
  mkdir -p .claudekiq/plugins
  cat > .claudekiq/plugins/fail-plugin.sh <<'PLUGIN'
#!/usr/bin/env bash
cat > /dev/null
echo '{"status":"fail","error":"something went wrong"}'
exit 1
PLUGIN
  chmod +x .claudekiq/plugins/fail-plugin.sh

  run bash -c 'echo "{}" | .claudekiq/plugins/fail-plugin.sh'
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.status')" = "fail" ]
}

# --- Workflow validation with custom types ---

@test "workflows validate warns on unknown step type" {
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
  [ "$status" -ne 0 ]
  [[ "$output" == *"nonexistent-type"* ]]
  [[ "$output" == *"not a built-in type"* ]]
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

@test "workflows validate passes with bash plugin custom type" {
  mkdir -p .claudekiq/plugins
  cp "$FIXTURES/mock-plugin.sh" .claudekiq/plugins/deploy.sh
  chmod +x .claudekiq/plugins/deploy.sh

  cat > .claudekiq/workflows/bash-plugin.yml <<'YAML'
name: bash-plugin-test
description: Test bash plugin type
steps:
  - id: step1
    type: deploy
    target: "deploy to staging"
    gate: auto
YAML

  run "$CQ" workflows validate .claudekiq/workflows/bash-plugin.yml
  [ "$status" -eq 0 ]
}
