#!/usr/bin/env bats
load setup.bash

setup() {
  setup_test_project
}

teardown() {
  teardown_test_project
}

@test "config shows resolved config" {
  run "$CQ" config
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.prefix == "cq"'
}

@test "config get returns value" {
  run "$CQ" config get ttl
  [ "$status" -eq 0 ]
  [ "$output" = "2592000" ]
}

@test "config get default_priority" {
  run "$CQ" config get default_priority
  [ "$status" -eq 0 ]
  [ "$output" = "normal" ]
}

@test "config set writes to project settings" {
  "$CQ" config set concurrency 3 >/dev/null
  local val
  val=$(jq -r '.concurrency' .claudekiq/settings.json)
  [ "$val" = "3" ]
}

@test "config set --global writes to global config" {
  "$CQ" config set --global ttl 100 >/dev/null
  local val
  val=$(jq -r '.ttl' "$HOME/.cq/config.json")
  [ "$val" = "100" ]
  # Clean up
  jq 'del(.ttl)' "$HOME/.cq/config.json" > "$HOME/.cq/config.json.tmp" && mv "$HOME/.cq/config.json.tmp" "$HOME/.cq/config.json"
}

@test "config project overrides global" {
  "$CQ" config set concurrency 5 >/dev/null
  local val
  val=$("$CQ" config get concurrency)
  [ "$val" = "5" ]
}

@test "config --json" {
  run "$CQ" --json config get concurrency
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.concurrency'
}
