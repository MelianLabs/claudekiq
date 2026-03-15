#!/usr/bin/env bats
# test_scan_stack.bats — Tests for stack detection in cq scan

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
  [ "$(echo "$output" | jq -r '.stack.language')" = "javascript" ]
  [ "$(echo "$output" | jq -r '.stack.test_command')" = "npm test" ]
  [ "$(echo "$output" | jq -r '.stack.build_command')" = "npm run build" ]
  [ "$(echo "$output" | jq -r '.stack.lint_command')" = "npm run lint" ]
}

@test "scan detects typescript when tsconfig.json present" {
  cat > package.json <<'EOF'
{"name": "ts-project", "scripts": {"test": "jest"}}
EOF
  echo '{}' > tsconfig.json

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stack.language')" = "typescript" ]
}

@test "scan detects next framework from package.json" {
  cat > package.json <<'EOF'
{"name": "next-app", "dependencies": {"next": "14.0.0", "react": "18.0.0"}}
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stack.framework')" = "next" ]
}

@test "scan detects ruby from Gemfile" {
  cat > Gemfile <<'EOF'
source "https://rubygems.org"
gem "rspec"
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stack.language')" = "ruby" ]
  [ "$(echo "$output" | jq -r '.stack.test_command')" = "bundle exec rspec" ]
}

@test "scan detects rails framework from Gemfile" {
  cat > Gemfile <<'EOF'
source "https://rubygems.org"
gem "rails"
gem "rspec-rails"
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stack.language')" = "ruby" ]
  [ "$(echo "$output" | jq -r '.stack.framework')" = "rails" ]
  [ "$(echo "$output" | jq -r '.stack.lint_command')" = "bundle exec rubocop" ]
}

@test "scan detects go from go.mod" {
  cat > go.mod <<'EOF'
module example.com/test
go 1.21
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stack.language')" = "go" ]
  [ "$(echo "$output" | jq -r '.stack.test_command')" = "go test ./..." ]
}

@test "scan detects rust from Cargo.toml" {
  cat > Cargo.toml <<'EOF'
[package]
name = "test"
version = "0.1.0"
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stack.language')" = "rust" ]
  [ "$(echo "$output" | jq -r '.stack.test_command')" = "cargo test" ]
}

@test "scan detects python from pyproject.toml" {
  cat > pyproject.toml <<'EOF'
[project]
name = "test"
dependencies = ["fastapi"]
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stack.language')" = "python" ]
  [ "$(echo "$output" | jq -r '.stack.framework')" = "fastapi" ]
  [ "$(echo "$output" | jq -r '.stack.test_command')" = "pytest" ]
}

@test "scan detects python from requirements.txt" {
  cat > requirements.txt <<'EOF'
django>=4.0
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stack.language')" = "python" ]
  [ "$(echo "$output" | jq -r '.stack.framework')" = "django" ]
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
  [ "$(echo "$output" | jq -r '.stack.language')" = "java" ]
  [ "$(echo "$output" | jq -r '.stack.framework')" = "spring" ]
  [ "$(echo "$output" | jq -r '.stack.test_command')" = "mvn test" ]
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
  [ "$(echo "$output" | jq -r '.stack.language')" = "elixir" ]
  [ "$(echo "$output" | jq -r '.stack.framework')" = "phoenix" ]
  [ "$(echo "$output" | jq -r '.stack.test_command')" = "mix test" ]
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
  [ "$(echo "$output" | jq -r '.stack.language')" = "makefile" ]
  [ "$(echo "$output" | jq -r '.stack.test_command')" = "make test" ]
  [ "$(echo "$output" | jq -r '.stack.build_command')" = "make build" ]
  [ "$(echo "$output" | jq -r '.stack.lint_command')" = "make lint" ]
}

@test "scan returns stack object in JSON output" {
  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  # stack key should exist even with no detected language
  echo "$output" | jq -e '.stack' >/dev/null
}

@test "scan stores stack in settings.json" {
  cat > package.json <<'EOF'
{"name": "test", "scripts": {"test": "jest"}}
EOF

  run "$CQ" scan
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stack.language' .claudekiq/settings.json)" = "javascript" ]
  [ "$(jq -r '.stack.test_command' .claudekiq/settings.json)" = "npm test" ]
}

@test "scan stack includes test_command when detectable" {
  cat > Gemfile <<'EOF'
source "https://rubygems.org"
gem "sinatra"
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stack.test_command')" = "bundle exec rspec" ]
}

@test "scan skips placeholder test scripts in package.json" {
  cat > package.json <<'EOF'
{"name": "test", "scripts": {"test": "echo \"Error: no test specified\" && exit 1"}}
EOF

  run "$CQ" scan --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.stack.test_command // empty')" = "" ]
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
  [ "$(echo "$output" | jq -r '.stack.language')" = "ruby" ]
  # Build command comes from Makefile since Ruby didn't set one
  [ "$(echo "$output" | jq -r '.stack.build_command')" = "make build" ]
}
