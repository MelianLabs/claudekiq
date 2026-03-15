#!/usr/bin/env bats
load setup.bash

setup() {
  setup_test_project
  cp "$FIXTURES"/with-foreach.yml .claudekiq/workflows/
}

teardown() {
  teardown_test_project
}

@test "for_each: step definition preserved in steps.json" {
  local run_id
  run_id=$("$CQ" start with-foreach --json 2>/dev/null | jq -r '.run_id')
  local steps
  steps=$("$CQ" status "$run_id" --json 2>/dev/null | jq '.steps')

  # Check for_each fields are in the step definition
  local step_type over delimiter item_var max_iterations
  step_type=$(echo "$steps" | jq -r '.[] | select(.id == "iterate") | .type')
  over=$(echo "$steps" | jq -r '.[] | select(.id == "iterate") | .over')
  delimiter=$(echo "$steps" | jq -r '.[] | select(.id == "iterate") | .delimiter')
  item_var=$(echo "$steps" | jq -r '.[] | select(.id == "iterate") | .item_var')
  max_iterations=$(echo "$steps" | jq -r '.[] | select(.id == "iterate") | .max_iterations')

  [ "$step_type" = "for_each" ]
  [ "$over" = "{{stacks}}" ]
  [ "$delimiter" = "," ]
  [ "$item_var" = "current_stack" ]
  [ "$max_iterations" = "10" ]
}

@test "for_each: has nested step definition" {
  local run_id
  run_id=$("$CQ" start with-foreach --json 2>/dev/null | jq -r '.run_id')
  local steps
  steps=$("$CQ" status "$run_id" --json 2>/dev/null | jq '.steps')

  local nested_id nested_type nested_target
  nested_id=$(echo "$steps" | jq -r '.[] | select(.id == "iterate") | .step.id')
  nested_type=$(echo "$steps" | jq -r '.[] | select(.id == "iterate") | .step.type')
  nested_target=$(echo "$steps" | jq -r '.[] | select(.id == "iterate") | .step.target')

  [ "$nested_id" = "process-one" ]
  [ "$nested_type" = "bash" ]
  [ "$nested_target" = "echo {{current_stack}}" ]
}

@test "for_each: context has stacks variable" {
  local run_id
  run_id=$("$CQ" start with-foreach --json 2>/dev/null | jq -r '.run_id')
  local ctx
  ctx=$("$CQ" status "$run_id" --json 2>/dev/null | jq '.ctx')
  local stacks
  stacks=$(echo "$ctx" | jq -r '.stacks')
  [ "$stacks" = "a,b,c" ]
}

@test "for_each: step-done pass advances past for_each" {
  local run_id
  run_id=$("$CQ" start with-foreach --json 2>/dev/null | jq -r '.run_id')
  # The runner would iterate and then mark iterate as pass
  "$CQ" step-done "$run_id" iterate pass >/dev/null 2>&1
  [ "$(run_meta "$run_id" current_step)" = "done" ]
}

@test "for_each: validates workflow" {
  run "$CQ" workflows validate "$FIXTURES/with-foreach.yml"
  [ "$status" -eq 0 ]
}

@test "for_each: standalone mode --json" {
  local result
  result=$("$CQ" --json for-each --over="a,b,c" --var=x --command="echo {{x}}" 2>/dev/null)
  [ "$(echo "$result" | jq -r '.outcome')" = "pass" ]
  [ "$(echo "$result" | jq '.results | length')" = "3" ]
  [ "$(echo "$result" | jq -r '.results[0].item')" = "a" ]
  [ "$(echo "$result" | jq -r '.results[1].item')" = "b" ]
  [ "$(echo "$result" | jq -r '.results[2].item')" = "c" ]
}

@test "for_each: standalone stops on failure" {
  local result
  result=$("$CQ" --json for-each --over="ok,bad,skip" --var=x --command='[ "{{x}}" != "bad" ]' 2>/dev/null) || true
  [ "$(echo "$result" | jq -r '.outcome')" = "fail" ]
  # Should stop at "bad", so only 2 results
  [ "$(echo "$result" | jq '.results | length')" = "2" ]
}

@test "for_each: standalone custom delimiter" {
  local result
  result=$("$CQ" --json for-each --over="a:b:c" --delimiter=":" --var=item --command="echo {{item}}" 2>/dev/null)
  [ "$(echo "$result" | jq -r '.outcome')" = "pass" ]
  [ "$(echo "$result" | jq '.results | length')" = "3" ]
}

@test "for_each: workflow mode --json" {
  local run_id
  run_id=$("$CQ" start with-foreach --json 2>/dev/null | jq -r '.run_id')
  local result
  result=$("$CQ" --json for-each "$run_id" iterate 2>/dev/null)
  [ "$(echo "$result" | jq -r '.outcome')" = "pass" ]
  [ "$(echo "$result" | jq -r '.run_id')" = "$run_id" ]
  [ "$(echo "$result" | jq '.results | length')" = "3" ]
}
