#!/usr/bin/env bats
# test_scan.bats — Tests for cq scan command

load setup.bash

setup() { setup_test_project; }
teardown() { teardown_test_project; }

@test "scan discovers agents" {
  mkdir -p .claude/agents
  cp "$FIXTURES/mock-agent.md" .claude/agents/test-agent.md

  run "$CQ" scan
  [ "$status" -eq 0 ]

  local agent
  agent=$(jq '.agents[] | select(.name == "test-agent")' .claudekiq/settings.json)
  [ "$(echo "$agent" | jq -r '.name')" = "test-agent" ]
  [ "$(echo "$agent" | jq -r '.model')" = "sonnet" ]
  [ "$(echo "$agent" | jq -r '.description')" = "A mock agent for testing scan discovery" ]
}

@test "scan parses agent tools as array" {
  mkdir -p .claude/agents
  cp "$FIXTURES/mock-agent.md" .claude/agents/test-agent.md

  run "$CQ" scan
  [ "$status" -eq 0 ]

  local tools
  tools=$(jq -r '.agents[0].tools | join(",")' .claudekiq/settings.json)
  [[ "$tools" == *"Read"* ]]
  [[ "$tools" == *"Edit"* ]]
}

@test "scan derives agent name from filename when no name in frontmatter" {
  mkdir -p .claude/agents
  cat > .claude/agents/my-custom-agent.md <<'EOF'
---
description: "Agent without name field"
model: haiku
---

No name in frontmatter.
EOF

  run "$CQ" scan
  [ "$status" -eq 0 ]

  local agent
  agent=$(jq '.agents[] | select(.name == "my-custom-agent")' .claudekiq/settings.json)
  [ "$(echo "$agent" | jq -r '.name')" = "my-custom-agent" ]
}

@test "scan discovers skills" {
  # Skills may be in .claude/skills/ if any exist
  run "$CQ" scan
  [ "$status" -eq 0 ]

  # Verify scan completed without error
  [ "$(jq -r '.scanned_at' .claudekiq/settings.json)" != "null" ]
}

@test "scan preserves user config" {
  "$CQ" config set concurrency 3

  mkdir -p .claude/agents
  cp "$FIXTURES/mock-agent.md" .claude/agents/test-agent.md

  run "$CQ" scan
  [ "$status" -eq 0 ]

  # User config preserved
  [ "$(jq -r '.concurrency' .claudekiq/settings.json)" = "3" ]
  # Scan results present
  [ "$(jq '.agents | length' .claudekiq/settings.json)" -ge 1 ]
  local found
  found=$(jq -r '.agents[] | select(.name == "test-agent") | .name' .claudekiq/settings.json)
  [ "$found" = "test-agent" ]
}

@test "scan --json output" {
  mkdir -p .claude/agents
  cp "$FIXTURES/mock-agent.md" .claude/agents/test-agent.md

  run "$CQ" scan --json
  [ "$status" -eq 0 ]

  # Output should be valid JSON with agents array
  echo "$output" | jq '.' >/dev/null
  [ "$(echo "$output" | jq '.agents | length')" -ge 1 ]
  [ "$(echo "$output" | jq -r '.scanned_at')" != "null" ]
  # Verify test-agent is in the output
  [ "$(echo "$output" | jq -r '.agents[] | select(.name == "test-agent") | .name')" = "test-agent" ]
}

@test "scan updates scanned_at" {
  run "$CQ" scan
  [ "$status" -eq 0 ]

  local ts1
  ts1=$(jq -r '.scanned_at' .claudekiq/settings.json)
  [ "$ts1" != "null" ]

  sleep 1
  run "$CQ" scan
  [ "$status" -eq 0 ]

  local ts2
  ts2=$(jq -r '.scanned_at' .claudekiq/settings.json)
  [ "$ts2" != "$ts1" ]
}

@test "scan handles missing agents dir" {
  rm -rf .claude/agents

  run "$CQ" scan
  [ "$status" -eq 0 ]

  [ "$(jq '.agents | length' .claudekiq/settings.json)" -eq 0 ]
}

@test "scan handles malformed frontmatter" {
  mkdir -p .claude/agents
  # File without frontmatter
  echo "Just a plain markdown file without frontmatter" > .claude/agents/broken.md

  run "$CQ" scan
  [ "$status" -eq 0 ]

  # Broken file should be skipped, not cause failure
}

@test "scan handles empty project gracefully" {
  # Remove agents to test empty state
  rm -rf .claude/agents

  run "$CQ" scan
  [ "$status" -eq 0 ]

  [ "$(jq '.agents | length' .claudekiq/settings.json)" -eq 0 ]
}

@test "scan multiple agents" {
  mkdir -p .claude/agents
  cp "$FIXTURES/mock-agent.md" .claude/agents/agent-a.md
  cat > .claude/agents/agent-b.md <<'EOF'
---
name: agent-b
description: "Second test agent"
model: opus
---

Second agent.
EOF

  run "$CQ" scan
  [ "$status" -eq 0 ]

  [ "$(jq '.agents | length' .claudekiq/settings.json)" -ge 2 ]
}

@test "scan fails outside cq project" {
  rm -rf .claudekiq

  run "$CQ" scan
  [ "$status" -ne 0 ]
  [[ "$output" == *"Not a cq project"* ]]
}

@test "scan removes stale plugins key" {
  # Write a stale plugins key
  jq '. + {"plugins":[{"name":"old"}]}' .claudekiq/settings.json > .claudekiq/settings.json.tmp
  mv .claudekiq/settings.json.tmp .claudekiq/settings.json

  run "$CQ" scan
  [ "$status" -eq 0 ]

  # plugins key should be removed
  run jq -e '.plugins' .claudekiq/settings.json
  [ "$status" -ne 0 ]
}

@test "scan removes stale singular stack key" {
  # Write a stale singular "stack" key
  jq '. + {"stack":{"language":"old"}}' .claudekiq/settings.json > .claudekiq/settings.json.tmp
  mv .claudekiq/settings.json.tmp .claudekiq/settings.json

  run "$CQ" scan
  [ "$status" -eq 0 ]

  # singular "stack" key should be removed, "stacks" array should exist
  run jq -e '.stack' .claudekiq/settings.json
  [ "$status" -ne 0 ]
  jq -e '.stacks | type == "array"' .claudekiq/settings.json
}

@test "scan discovers plugin skills from plugin.json" {
  # Create a mock plugin skill
  mkdir -p .mock-skills/test-skill
  cat > .mock-skills/test-skill/SKILL.md <<'EOF'
---
name: test-skill
description: "A plugin-discovered skill"
allowed-tools: Bash, Read
---

Test skill content.
EOF

  # Create plugin.json pointing to the mock skill
  mkdir -p .claude-plugin
  jq -cn '{name:"test", version:"1.0", skills:["../.mock-skills/test-skill"]}' > .claude-plugin/plugin.json

  run "$CQ" scan --json
  [ "$status" -eq 0 ]

  # Verify plugin skill appears in results
  local skill_name
  skill_name=$(echo "$output" | jq -r '.skills[] | select(.name == "test-skill") | .name')
  [ "$skill_name" = "test-skill" ]

  # Verify source is "plugin"
  local source
  source=$(echo "$output" | jq -r '.skills[] | select(.name == "test-skill") | .source')
  [ "$source" = "plugin" ]

  # Verify it's persisted in settings.json
  local stored
  stored=$(jq -r '.skills[] | select(.name == "test-skill") | .source' .claudekiq/settings.json)
  [ "$stored" = "plugin" ]
}

@test "scan updates .claude/cq.md" {
  mkdir -p .claude/agents
  cp "$FIXTURES/mock-agent.md" .claude/agents/test-agent.md

  run "$CQ" scan
  [ "$status" -eq 0 ]
  [ -f .claude/cq.md ]
  grep -q 'Claudekiq' .claude/cq.md
  grep -q 'test-agent' .claude/cq.md
}

@test "schema scan returns valid JSON" {
  run "$CQ" schema scan
  [ "$status" -eq 0 ]
  echo "$output" | jq '.' >/dev/null
  [ "$(echo "$output" | jq -r '.command')" = "scan" ]
}
