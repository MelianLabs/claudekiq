#!/usr/bin/env bats
load setup.bash

setup() {
  setup_test_project
}

teardown() {
  teardown_test_project
}

@test "workflows list shows available templates" {
  run "$CQ" workflows list
  [ "$status" -eq 0 ]
  [[ "$output" == *"minimal"* ]]
}

@test "workflows list --json" {
  run "$CQ" --json workflows list
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].name == "minimal"'
}

@test "workflows show displays step details" {
  run "$CQ" workflows show minimal
  [ "$status" -eq 0 ]
  [[ "$output" == *"step-a"* ]]
  [[ "$output" == *"step-b"* ]]
  [[ "$output" == *"step-c"* ]]
}

@test "workflows show --json" {
  run "$CQ" --json workflows show minimal
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.steps | length == 3'
}

@test "workflows show nonexistent fails" {
  run "$CQ" workflows show nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "workflows validate valid file" {
  run "$CQ" workflows validate "$FIXTURES/minimal.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Valid"* ]]
}

@test "workflows validate invalid YAML" {
  local bad="$TEST_DIR/bad.yml"
  echo "name: bad" > "$bad"
  echo "steps: []" >> "$bad"
  run "$CQ" workflows validate "$bad"
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-empty"* ]]
}

@test "workflows validate detects missing step id" {
  local bad="$TEST_DIR/noid.yml"
  cat > "$bad" <<'EOF'
name: noid
steps:
  - type: bash
    target: echo hi
EOF
  run "$CQ" workflows validate "$bad"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing 'id'"* ]]
}

@test "workflows validate detects invalid step id format" {
  local bad="$TEST_DIR/badid.yml"
  cat > "$bad" <<'EOF'
name: badid
steps:
  - id: "Step One"
    type: bash
    target: echo hi
EOF
  run "$CQ" workflows validate "$bad"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must match"* ]]
}

@test "workflows validate accepts valid context_builders" {
  local wf="$TEST_DIR/cb-valid.yml"
  cat > "$wf" <<'EOF'
name: cb-valid
steps:
  - id: fix-tests
    type: agent
    prompt: "Fix the failing tests."
    context_builders:
      - type: git_diff
      - type: error_context
      - type: command_output
        command: "echo hello"
EOF
  run "$CQ" workflows validate "$wf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Valid"* ]]
}

@test "workflows validate rejects unknown context_builder type" {
  local wf="$TEST_DIR/cb-bad.yml"
  cat > "$wf" <<'EOF'
name: cb-bad
steps:
  - id: fix-tests
    type: agent
    prompt: "Fix the failing tests."
    context_builders:
      - type: nonexistent_type
EOF
  run "$CQ" workflows validate "$wf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown context_builder type"* ]]
}

@test "workflows validate rejects file_contents without paths" {
  local wf="$TEST_DIR/cb-nopath.yml"
  cat > "$wf" <<'EOF'
name: cb-nopath
steps:
  - id: fix-tests
    type: agent
    prompt: "Fix the failing tests."
    context_builders:
      - type: file_contents
EOF
  run "$CQ" workflows validate "$wf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires 'paths' array"* ]]
}

@test "workflows validate rejects command_output without command" {
  local wf="$TEST_DIR/cb-nocmd.yml"
  cat > "$wf" <<'EOF'
name: cb-nocmd
steps:
  - id: fix-tests
    type: agent
    prompt: "Fix the failing tests."
    context_builders:
      - type: command_output
EOF
  run "$CQ" workflows validate "$wf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires 'command' string"* ]]
}
