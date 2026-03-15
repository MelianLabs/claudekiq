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

  # Verify test-agent is in the agents array (cq-worker is also present from init)
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
  # cq init already installs cq and cq-workers skills
  run "$CQ" scan
  [ "$status" -eq 0 ]

  local skill_count
  skill_count=$(jq '.skills | length' .claudekiq/settings.json)
  [ "$skill_count" -ge 2 ]

  # Verify cq skill is found
  local cq_skill
  cq_skill=$(jq -r '.skills[] | select(.name == "cq") | .name' .claudekiq/settings.json)
  [ "$cq_skill" = "cq" ]
}

@test "scan discovers plugins" {
  mkdir -p .claudekiq/plugins
  cp "$FIXTURES/mock-plugin.sh" .claudekiq/plugins/deploy.sh
  chmod +x .claudekiq/plugins/deploy.sh

  run "$CQ" scan
  [ "$status" -eq 0 ]

  local plugins
  plugins=$(jq '.plugins' .claudekiq/settings.json)
  [ "$(echo "$plugins" | jq 'length')" -eq 1 ]
  [ "$(echo "$plugins" | jq -r '.[0].name')" = "deploy" ]
  [ "$(echo "$plugins" | jq -r '.[0].type')" = "bash" ]
  [ "$(echo "$plugins" | jq -r '.[0].executable')" = "true" ]
}

@test "scan detects non-executable plugins" {
  mkdir -p .claudekiq/plugins
  cp "$FIXTURES/mock-plugin.sh" .claudekiq/plugins/broken.sh
  chmod -x .claudekiq/plugins/broken.sh

  run "$CQ" scan
  [ "$status" -eq 0 ]

  [ "$(jq -r '.plugins[0].executable' .claudekiq/settings.json)" = "false" ]
}

@test "scan preserves user config" {
  "$CQ" config set concurrency 3

  mkdir -p .claude/agents
  cp "$FIXTURES/mock-agent.md" .claude/agents/test-agent.md

  run "$CQ" scan
  [ "$status" -eq 0 ]

  # User config preserved
  [ "$(jq -r '.concurrency' .claudekiq/settings.json)" = "3" ]
  # Scan results present — includes both test-agent and cq-worker from init
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
  # Remove the cq-worker agent installed by init to isolate this test
  rm -f .claude/agents/cq-worker.md

  mkdir -p .claude/agents
  # File without frontmatter
  echo "Just a plain markdown file without frontmatter" > .claude/agents/broken.md

  run "$CQ" scan
  [ "$status" -eq 0 ]

  # Broken file should be skipped, not cause failure
  [ "$(jq '.agents | length' .claudekiq/settings.json)" -eq 0 ]
}

@test "scan handles empty project gracefully" {
  # Remove agents installed by init to test empty state
  rm -rf .claude/agents

  run "$CQ" scan
  [ "$status" -eq 0 ]

  [ "$(jq '.agents | length' .claudekiq/settings.json)" -eq 0 ]
  [ "$(jq '.plugins | length' .claudekiq/settings.json)" -eq 0 ]
}

@test "scan multiple agents" {
  # Remove cq-worker to count only our test agents
  rm -f .claude/agents/cq-worker.md

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

  [ "$(jq '.agents | length' .claudekiq/settings.json)" -eq 2 ]
}

@test "scan fails outside cq project" {
  rm -rf .claudekiq

  run "$CQ" scan
  [ "$status" -ne 0 ]
  [[ "$output" == *"Not a cq project"* ]]
}

@test "schema scan returns valid JSON" {
  run "$CQ" schema scan
  [ "$status" -eq 0 ]
  echo "$output" | jq '.' >/dev/null
  [ "$(echo "$output" | jq -r '.command')" = "scan" ]
}
