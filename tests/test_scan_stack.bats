#!/usr/bin/env bats
# test_scan_stack.bats — Tests for multi-stack detection in cq scan

load setup.bash

setup() { setup_test_project; }
teardown() { teardown_test_project; }

@test "scan detects javascript from package.json" {
  cat > package.json <<'EOF'
{
  "name": "test-project",
  "scripts": { "test": "jest", "build": "webpack", "lint": "eslint ." }
}
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stacks[0].language')" = "javascript" ]
  [ "$(echo "$output" | jq -r '.stacks[0].test_command')" = "npm test" ]
  [ "$(echo "$output" | jq -r '.stacks[0].build_command')" = "npm run build" ]
  [ "$(echo "$output" | jq -r '.stacks[0].lint_command')" = "npm run lint" ]
}

@test "scan detects typescript when tsconfig.json present" {
  cat > package.json <<'EOF'
{"name": "ts-project", "scripts": {"test": "jest"}}
EOF
  echo '{}' > tsconfig.json

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stacks[0].language')" = "typescript" ]
}

@test "scan detects next framework from package.json" {
  cat > package.json <<'EOF'
{"name": "next-app", "dependencies": {"next": "14.0.0", "react": "18.0.0"}}
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stacks[0].framework')" = "next" ]
}

@test "scan detects preact framework from package.json" {
  cat > package.json <<'EOF'
{"name": "preact-app", "dependencies": {"preact": "10.0.0"}}
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stacks[0].framework')" = "preact" ]
}

@test "scan detects ruby from Gemfile" {
  cat > Gemfile <<'EOF'
source "https://rubygems.org"
gem "rspec"
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stacks[0].language')" = "ruby" ]
  [ "$(echo "$output" | jq -r '.stacks[0].test_command')" = "bundle exec rspec" ]
}

@test "scan detects rails framework from Gemfile" {
  cat > Gemfile <<'EOF'
source "https://rubygems.org"
gem "rails"
gem "rspec-rails"
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stacks[0].language')" = "ruby" ]
  [ "$(echo "$output" | jq -r '.stacks[0].framework')" = "rails" ]
  [ "$(echo "$output" | jq -r '.stacks[0].lint_command')" = "bundle exec rubocop" ]
}

@test "scan detects go from go.mod" {
  cat > go.mod <<'EOF'
module example.com/test
go 1.21
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stacks[0].language')" = "go" ]
  [ "$(echo "$output" | jq -r '.stacks[0].test_command')" = "go test ./..." ]
}

@test "scan detects rust from Cargo.toml" {
  cat > Cargo.toml <<'EOF'
[package]
name = "test"
version = "0.1.0"
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stacks[0].language')" = "rust" ]
  [ "$(echo "$output" | jq -r '.stacks[0].test_command')" = "cargo test" ]
}

@test "scan detects python from pyproject.toml" {
  cat > pyproject.toml <<'EOF'
[project]
name = "test"
dependencies = ["fastapi"]
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stacks[0].language')" = "python" ]
  [ "$(echo "$output" | jq -r '.stacks[0].framework')" = "fastapi" ]
  [ "$(echo "$output" | jq -r '.stacks[0].test_command')" = "pytest" ]
}

@test "scan detects python from requirements.txt" {
  cat > requirements.txt <<'EOF'
django>=4.0
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stacks[0].language')" = "python" ]
  [ "$(echo "$output" | jq -r '.stacks[0].framework')" = "django" ]
}

@test "scan detects java from pom.xml" {
  cat > pom.xml <<'EOF'
<project>
  <groupId>com.example</groupId>
  <artifactId>test</artifactId>
  <dependencies>
    <dependency>
      <groupId>org.springframework</groupId>
    </dependency>
  </dependencies>
</project>
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stacks[0].language')" = "java" ]
  [ "$(echo "$output" | jq -r '.stacks[0].framework')" = "spring" ]
  [ "$(echo "$output" | jq -r '.stacks[0].test_command')" = "mvn test" ]
}

@test "scan detects elixir from mix.exs" {
  cat > mix.exs <<'EOF'
defmodule Test.MixProject do
  use Mix.Project
  defp deps do [{:phoenix, "~> 1.7"}] end
end
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stacks[0].language')" = "elixir" ]
  [ "$(echo "$output" | jq -r '.stacks[0].framework')" = "phoenix" ]
  [ "$(echo "$output" | jq -r '.stacks[0].test_command')" = "mix test" ]
}

@test "scan detects Makefile targets" {
  cat > Makefile <<'EOF'
test:
	echo "running tests"

build:
	echo "building"

lint:
	echo "linting"
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stacks[0].language')" = "makefile" ]
  [ "$(echo "$output" | jq -r '.stacks[0].test_command')" = "make test" ]
  [ "$(echo "$output" | jq -r '.stacks[0].build_command')" = "make build" ]
  [ "$(echo "$output" | jq -r '.stacks[0].lint_command')" = "make lint" ]
}

@test "scan returns stacks array in JSON output" {
  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  # stacks key should exist even with no detected language
  echo "$output" | jq -e '.stacks | type == "array"' >/dev/null
}

@test "scan stores stacks in settings.json" {
  cat > package.json <<'EOF'
{"name": "test", "scripts": {"test": "jest"}}
EOF

  run "$CQ" scan
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stacks[0].language' .claudekiq/settings.json)" = "javascript" ]
  [ "$(jq -r '.stacks[0].test_command' .claudekiq/settings.json)" = "npm test" ]
}

@test "scan stacks includes test_command when detectable" {
  cat > Gemfile <<'EOF'
source "https://rubygems.org"
gem "sinatra"
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stacks[0].test_command')" = "bundle exec rspec" ]
}

@test "scan skips placeholder test scripts in package.json" {
  cat > package.json <<'EOF'
{"name": "test", "scripts": {"test": "echo \"Error: no test specified\" && exit 1"}}
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stacks[0].test_command // empty')" = "" ]
}

@test "scan Makefile supplements language-specific detection" {
  cat > Gemfile <<'EOF'
source "https://rubygems.org"
gem "rspec"
EOF
  cat > Makefile <<'EOF'
build:
	echo "building"
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  # Language comes from Gemfile, not Makefile
  [ "$(echo "$output" | jq -r '.stacks[0].language')" = "ruby" ]
  # Build command comes from Makefile since Ruby didn't set one
  [ "$(echo "$output" | jq -r '.stacks[0].build_command')" = "make build" ]
}

# --- Multi-stack detection ---

@test "scan detects multiple stacks: rails + react" {
  cat > Gemfile <<'EOF'
source "https://rubygems.org"
gem "rails"
EOF
  cat > package.json <<'EOF'
{"name": "frontend", "dependencies": {"react": "18.0.0"}, "scripts": {"test": "jest", "build": "webpack"}}
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.stacks | length')" -eq 2 ]

  # JavaScript/React stack
  local js_stack
  js_stack=$(echo "$output" | jq '.stacks[] | select(.language == "javascript")')
  [ "$(echo "$js_stack" | jq -r '.framework')" = "react" ]
  [ "$(echo "$js_stack" | jq -r '.test_command')" = "npm test" ]

  # Ruby/Rails stack
  local rb_stack
  rb_stack=$(echo "$output" | jq '.stacks[] | select(.language == "ruby")')
  [ "$(echo "$rb_stack" | jq -r '.framework')" = "rails" ]
  [ "$(echo "$rb_stack" | jq -r '.test_command')" = "bundle exec rspec" ]
}

@test "scan detects multiple stacks: python + typescript" {
  cat > requirements.txt <<'EOF'
django>=4.0
EOF
  cat > package.json <<'EOF'
{"name": "frontend", "scripts": {"test": "vitest"}}
EOF
  echo '{}' > tsconfig.json

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.stacks | length')" -eq 2 ]

  [ "$(echo "$output" | jq -r '.stacks[] | select(.language == "typescript") | .language')" = "typescript" ]
  [ "$(echo "$output" | jq -r '.stacks[] | select(.language == "python") | .framework')" = "django" ]
}

@test "scan detects three stacks: go + ruby + javascript" {
  cat > go.mod <<'EOF'
module example.com/test
go 1.21
EOF
  cat > Gemfile <<'EOF'
source "https://rubygems.org"
gem "sinatra"
EOF
  cat > package.json <<'EOF'
{"name": "admin", "dependencies": {"vue": "3.0.0"}}
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.stacks | length')" -eq 3 ]
}

@test "scan removes stale stack key on re-scan" {
  # Write a stale singular "stack" key
  jq '. + {"stack":{"language":"old"}}' .claudekiq/settings.json > .claudekiq/settings.json.tmp
  mv .claudekiq/settings.json.tmp .claudekiq/settings.json

  run "$CQ" scan
  [ "$status" -eq 0 ]

  # singular "stack" key should be removed
  run jq -e '.stack' .claudekiq/settings.json
  [ "$status" -ne 0 ]
  # stacks array should exist
  jq -e '.stacks | type == "array"' .claudekiq/settings.json
}
