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
  [ -d .claudekiq/plugins ]
  [ -f .claudekiq/settings.json ]
}

@test "init creates Claude Code skill" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  [ -f .claude/skills/cq/SKILL.md ]
}

@test "init skill has correct frontmatter" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  grep -q '^name: cq' .claude/skills/cq/SKILL.md
}

@test "init re-run updates skill" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  # Corrupt the skill
  echo "old" > .claude/skills/cq/SKILL.md
  "$CQ" init >/dev/null
  # Should be restored
  grep -q 'Claudekiq Workflow Runner' .claude/skills/cq/SKILL.md
}

@test "init creates .gitignore entries" {
  cd "$TEST_DIR"
  "$CQ" init >/dev/null
  grep -qF '.claudekiq/workflows/private/' .gitignore
  grep -qF '.claudekiq/runs/' .gitignore
  grep -qF '.claude/worktrees/' .gitignore
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
