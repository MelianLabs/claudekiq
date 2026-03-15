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
  jq -e '.skills | length == 3' .claude-plugin/plugin.json
}

@test "plugin.json version matches CQ_VERSION" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  local plugin_ver cq_ver
  plugin_ver=$(jq -r '.version' .claude-plugin/plugin.json)
  cq_ver=$("$CQ" --json version | jq -r '.version')
  [ "$plugin_ver" = "$cq_ver" ]
}

@test "re-init preserves user-added plugin skills" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  # Add a user skill to plugin.json
  jq '.skills += ["/custom/my-skill"]' .claude-plugin/plugin.json > .claude-plugin/plugin.json.tmp
  mv .claude-plugin/plugin.json.tmp .claude-plugin/plugin.json
  local count_before
  count_before=$(jq '.skills | length' .claude-plugin/plugin.json)
  [ "$count_before" -eq 4 ]
  # Re-init
  "$CQ" init >/dev/null
  # User skill should be preserved
  jq -e '.skills | any(. == "/custom/my-skill")' .claude-plugin/plugin.json
  local count_after
  count_after=$(jq '.skills | length' .claude-plugin/plugin.json)
  [ "$count_after" -eq 4 ]
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

@test "init auto-installs hooks in .claude/settings.json" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  [ -f .claude/settings.json ]
  jq -e '.hooks.SessionEnd | length > 0' .claude/settings.json
  jq -e '.hooks.PreToolUse | length > 0' .claude/settings.json
  jq -e '.hooks.PostToolUse | length > 0' .claude/settings.json
}

@test "init re-run does not duplicate hooks" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  local count1
  count1=$(jq '.hooks.SessionEnd | length' .claude/settings.json)
  "$CQ" init >/dev/null
  local count2
  count2=$(jq '.hooks.SessionEnd | length' .claude/settings.json)
  [ "$count1" -eq "$count2" ]
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

@test "init generates .claude/cq.md" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  [ -f .claude/cq.md ]
  grep -q 'Claudekiq' .claude/cq.md
}

@test "init re-run regenerates .claude/cq.md" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  [ -f .claude/cq.md ]
  echo "corrupted" > .claude/cq.md
  "$CQ" init >/dev/null
  grep -q 'Claudekiq' .claude/cq.md
}

@test "hooks with safety=strict block operations" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  # Default is strict — the _safety-check command should exit 2
  local exit_code=0
  "$CQ" _safety-check rm_claudekiq 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 2 ]
}

@test "hooks with safety=relaxed allow otherwise-blocked operations" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  # Set safety to relaxed
  jq '. + {"safety":"relaxed"}' .claudekiq/settings.json > .claudekiq/settings.json.tmp
  mv .claudekiq/settings.json.tmp .claudekiq/settings.json
  local exit_code=0
  "$CQ" _safety-check rm_claudekiq 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 0 ]
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
      {"matcher": "", "hooks": [{"type": "command", "command": "echo custom hook"}]}
    ]
  }
}
JSON
  "$CQ" hooks install >/dev/null
  "$CQ" hooks uninstall >/dev/null
  # Custom hook should remain
  jq -e '.hooks.SessionEnd | length == 1' .claude/settings.json
  jq -e '.hooks.SessionEnd[0].hooks[0].command == "echo custom hook"' .claude/settings.json
}
