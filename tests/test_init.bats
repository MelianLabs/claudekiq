#!/usr/bin/env bats
load setup.bash

setup() {
  TEST_DIR=$(mktemp -d)
}

teardown() {
  cd /
  rm -rf "$TEST_DIR"
}

@test "init creates .claudekiq directory structure" {
  cd "$TEST_DIR"
  run "$CQ" init
  [ "$status" -eq 0 ]
  [ -d .claudekiq ]
  [ -d .claudekiq/workflows ]
  [ -d .claudekiq/workflows/private ]
  [ -d .claudekiq/runs ]
  [ -f .claudekiq/settings.json ]
}

@test "init creates .claude-plugin/plugin.json" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  [ -f .claude-plugin/plugin.json ]
  jq -e '.name == "claudekiq"' .claude-plugin/plugin.json
  jq -e '.version == "3.1.0"' .claude-plugin/plugin.json
  jq -e '.skills | length == 4' .claude-plugin/plugin.json
}

@test "init does not create .claude/skills" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  [ ! -d .claude/skills ]
}

@test "init does not create .claude/hooks" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  [ ! -d .claude/hooks ]
}

@test "init does not create .claude/settings.json" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  [ ! -f .claude/settings.json ]
}

@test "init re-run updates plugin.json" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  # Corrupt plugin.json
  echo '{}' > .claude-plugin/plugin.json
  "$CQ" init >/dev/null
  # Should be restored
  jq -e '.name == "claudekiq"' .claude-plugin/plugin.json
}

@test "init creates .gitignore entries" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  grep -qF '.claudekiq/workflows/private/' .gitignore
  grep -qF '.claudekiq/runs/' .gitignore
  grep -qF '.claudekiq/workers/' .gitignore
}

@test "init is idempotent" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  run "$CQ" init
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already initialized"* ]]
}

@test "init does not duplicate .gitignore entries" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  "$CQ" init >/dev/null
  local count
  count=$(grep -c '.claudekiq/runs/' .gitignore)
  [ "$count" -eq 1 ]
}

@test "init --json output" {
  cd "$TEST_DIR"
  run "$CQ" --json init
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "initialized"'
}

@test "init does not create .mcp.json by default" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  [ ! -f .mcp.json ]
}

@test "init --mcp creates .mcp.json" {
  cd "$TEST_DIR"
  "$CQ" init --mcp >/dev/null
  [ -f .mcp.json ]
  jq -e '.mcpServers.cq' .mcp.json
}

@test "init --mcp on re-run adds MCP config" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  [ ! -f .mcp.json ]
  "$CQ" init --mcp >/dev/null
  [ -f .mcp.json ]
  jq -e '.mcpServers.cq' .mcp.json
}

@test "init does not create .claudekiq/plugins" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  [ ! -d .claudekiq/plugins ]
}

@test "version shows version" {
  run "$CQ" version
  [ "$status" -eq 0 ]
  [[ "$output" == "cq "* ]]
}

@test "version --json" {
  run "$CQ" --json version
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.version'
}

@test "help shows usage" {
  run "$CQ" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: cq"* ]]
}

@test "unknown command exits with error" {
  run "$CQ" nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown command"* ]]
}

# --- Hooks tests ---

@test "hooks install creates .claude/settings.json with hooks" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  run "$CQ" hooks install
  [ "$status" -eq 0 ]
  [ -f .claude/settings.json ]
  jq -e '.hooks.SessionEnd | length > 0' .claude/settings.json
  jq -e '.hooks.PreToolUse | length > 0' .claude/settings.json
}

@test "hooks install merges with existing settings" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  mkdir -p .claude
  echo '{"customKey": true}' > .claude/settings.json
  run "$CQ" hooks install
  [ "$status" -eq 0 ]
  jq -e '.customKey == true' .claude/settings.json
  jq -e '.hooks.SessionEnd | length > 0' .claude/settings.json
}

@test "hooks uninstall removes cq hooks" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  "$CQ" hooks install >/dev/null
  jq -e '.hooks.SessionEnd | length > 0' .claude/settings.json
  run "$CQ" hooks uninstall
  [ "$status" -eq 0 ]
  # hooks should be removed (or empty)
  run jq -e '.hooks.SessionEnd' .claude/settings.json
  [ "$status" -ne 0 ]
}

@test "hooks uninstall preserves non-cq hooks" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  mkdir -p .claude
  cat > .claude/settings.json <<'JSON'
{
  "hooks": {
    "SessionEnd": [
      {"type": "command", "command": "echo custom hook"}
    ]
  }
}
JSON
  "$CQ" hooks install >/dev/null
  "$CQ" hooks uninstall >/dev/null
  # Custom hook should remain
  jq -e '.hooks.SessionEnd | length == 1' .claude/settings.json
  jq -e '.hooks.SessionEnd[0].command == "echo custom hook"' .claude/settings.json
}
