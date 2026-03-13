#!/usr/bin/env bats
load setup.bash

@test "schema lists all commands" {
  run "$CQ" schema
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "array"'
  echo "$output" | jq -e '. | length > 10'
}

@test "schema start returns valid JSON" {
  run "$CQ" schema start
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.command == "start"'
  echo "$output" | jq -e '.parameters | length > 0'
}

@test "schema status" {
  run "$CQ" schema status
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.command == "status"'
}

@test "schema step-done" {
  run "$CQ" schema step-done
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.command == "step-done"'
}

@test "schema all commands return valid JSON" {
  local cmds
  cmds=$("$CQ" schema | jq -r '.[]')
  while IFS= read -r cmd; do
    run "$CQ" schema "$cmd"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.' >/dev/null
  done <<< "$cmds"
}

@test "schema unknown command fails" {
  run "$CQ" schema nonexistent
  [ "$status" -eq 1 ]
}
