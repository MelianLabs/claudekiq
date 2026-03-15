#!/usr/bin/env bash
# scan.sh — Scan project for agents, skills, and stack info

cmd_scan() {
  [[ -d "${CQ_PROJECT_ROOT}/.claudekiq" ]] || cq_die "Not a cq project. Run 'cq init' first."

  local agents skills stack
  agents=$(_scan_agents)
  skills=$(_scan_skills)
  stack=$(_scan_stack)

  _merge_scan_results "$agents" "$skills" "$stack"

  local ts
  ts=$(cq_now)
  local agent_count skill_count
  agent_count=$(jq 'length' <<< "$agents")
  skill_count=$(jq 'length' <<< "$skills")

  cq_json_out \
    --argjson agents "$agents" \
    --argjson skills "$skills" \
    --argjson stack "$stack" \
    --arg scanned_at "$ts" \
    '{agents:$agents, skills:$skills, stack:$stack, scanned_at:$scanned_at}' || \
    cq_info "Scanned: ${agent_count} agent(s), ${skill_count} skill(s)"
}

_scan_agents() {
  local agents_dir="${CQ_PROJECT_ROOT}/.claude/agents"
  local -a items=()

  if [[ -d "$agents_dir" ]]; then
    local file
    for file in "$agents_dir"/*.md; do
      [[ -f "$file" ]] || continue
      local frontmatter
      frontmatter=$(_extract_frontmatter "$file") || continue
      [[ -z "$frontmatter" || "$frontmatter" == "null" ]] && continue

      local basename_no_ext
      basename_no_ext=$(basename "$file" .md)

      local item
      item=$(jq -cn \
        --arg fallback_name "$basename_no_ext" \
        --argjson fm "$frontmatter" \
        '{
          name: ($fm.name // $fallback_name),
          model: ($fm.model // null),
          tools: (if $fm.tools then ($fm.tools | split(",") | map(gsub("^\\s+|\\s+$"; ""))) else null end),
          description: ($fm.description // null)
        } | with_entries(select(.value != null))') || continue
      items+=("$item")
    done
  fi

  if [[ ${#items[@]} -gt 0 ]]; then
    printf '%s\n' "${items[@]}" | jq -s '.'
  else
    echo '[]'
  fi
}

_scan_skills() {
  local skills_dir="${CQ_PROJECT_ROOT}/.claude/skills"
  local -a items=()

  if [[ -d "$skills_dir" ]]; then
    local file
    for file in "$skills_dir"/*/SKILL.md; do
      [[ -f "$file" ]] || continue
      local frontmatter
      frontmatter=$(_extract_frontmatter "$file") || continue
      [[ -z "$frontmatter" || "$frontmatter" == "null" ]] && continue

      local dir_name
      dir_name=$(basename "$(dirname "$file")")

      local item
      item=$(jq -cn \
        --arg fallback_name "$dir_name" \
        --argjson fm "$frontmatter" \
        '{
          name: ($fm.name // $fallback_name),
          description: ($fm.description // null),
          tools: (if $fm["allowed-tools"] then ($fm["allowed-tools"] | split(",") | map(gsub("^\\s+|\\s+$"; ""))) else null end)
        } | with_entries(select(.value != null))') || continue
      items+=("$item")
    done
  fi

  if [[ ${#items[@]} -gt 0 ]]; then
    printf '%s\n' "${items[@]}" | jq -s '.'
  else
    echo '[]'
  fi
}

_scan_stack() {
  local root="$CQ_PROJECT_ROOT"
  local language="" framework="" test_command="" build_command="" lint_command=""

  # Detect language and framework from project files
  if [[ -f "$root/package.json" ]]; then
    language="javascript"
    # Check if TypeScript
    if [[ -f "$root/tsconfig.json" ]]; then
      language="typescript"
    fi
    # Detect framework from dependencies
    local deps
    deps=$(jq -r '(.dependencies // {}) + (.devDependencies // {}) | keys[]' "$root/package.json" 2>/dev/null || true)
    if echo "$deps" | grep -q '^next$'; then
      framework="next"
    elif echo "$deps" | grep -q '^react$'; then
      framework="react"
    elif echo "$deps" | grep -q '^express$'; then
      framework="express"
    elif echo "$deps" | grep -q '^vue$'; then
      framework="vue"
    elif echo "$deps" | grep -q '^@angular/core$'; then
      framework="angular"
    elif echo "$deps" | grep -q '^svelte$'; then
      framework="svelte"
    fi
    # Detect commands from package.json scripts
    local scripts
    scripts=$(jq -r '.scripts // {} | keys[]' "$root/package.json" 2>/dev/null || true)
    if echo "$scripts" | grep -q '^test$'; then
      test_command=$(jq -r '.scripts.test' "$root/package.json" 2>/dev/null)
      # Skip placeholder test commands
      if [[ "$test_command" == *"no test specified"* ]]; then
        test_command=""
      else
        test_command="npm test"
      fi
    fi
    if echo "$scripts" | grep -q '^build$'; then
      build_command="npm run build"
    fi
    if echo "$scripts" | grep -q '^lint$'; then
      lint_command="npm run lint"
    fi
  elif [[ -f "$root/Gemfile" ]]; then
    language="ruby"
    local gemfile_content
    gemfile_content=$(cat "$root/Gemfile" 2>/dev/null || true)
    if echo "$gemfile_content" | grep -q "gem ['\"]rails['\"]"; then
      framework="rails"
      test_command="bundle exec rspec"
      build_command="bundle exec rails assets:precompile"
      lint_command="bundle exec rubocop"
    elif echo "$gemfile_content" | grep -q "gem ['\"]sinatra['\"]"; then
      framework="sinatra"
      test_command="bundle exec rspec"
    fi
    [[ -z "$test_command" ]] && test_command="bundle exec rspec"
  elif [[ -f "$root/go.mod" ]]; then
    language="go"
    test_command="go test ./..."
    build_command="go build ./..."
    lint_command="golangci-lint run"
  elif [[ -f "$root/Cargo.toml" ]]; then
    language="rust"
    test_command="cargo test"
    build_command="cargo build"
    lint_command="cargo clippy"
  elif [[ -f "$root/pyproject.toml" ]] || [[ -f "$root/requirements.txt" ]]; then
    language="python"
    # Detect framework
    local py_content=""
    if [[ -f "$root/pyproject.toml" ]]; then
      py_content=$(cat "$root/pyproject.toml" 2>/dev/null || true)
    fi
    if [[ -f "$root/requirements.txt" ]]; then
      py_content="$py_content"$'\n'$(cat "$root/requirements.txt" 2>/dev/null || true)
    fi
    if echo "$py_content" | grep -qi 'django'; then
      framework="django"
      test_command="python manage.py test"
      lint_command="flake8"
    elif echo "$py_content" | grep -qi 'fastapi'; then
      framework="fastapi"
      test_command="pytest"
      lint_command="flake8"
    elif echo "$py_content" | grep -qi 'flask'; then
      framework="flask"
      test_command="pytest"
      lint_command="flake8"
    fi
    [[ -z "$test_command" ]] && test_command="pytest"
  elif [[ -f "$root/pom.xml" ]] || [[ -f "$root/build.gradle" ]]; then
    language="java"
    local java_content=""
    if [[ -f "$root/pom.xml" ]]; then
      java_content=$(cat "$root/pom.xml" 2>/dev/null || true)
      test_command="mvn test"
      build_command="mvn package"
    elif [[ -f "$root/build.gradle" ]]; then
      java_content=$(cat "$root/build.gradle" 2>/dev/null || true)
      test_command="gradle test"
      build_command="gradle build"
    fi
    if echo "$java_content" | grep -qi 'spring'; then
      framework="spring"
    fi
  elif [[ -f "$root/mix.exs" ]]; then
    language="elixir"
    local mix_content
    mix_content=$(cat "$root/mix.exs" 2>/dev/null || true)
    if echo "$mix_content" | grep -qi 'phoenix'; then
      framework="phoenix"
    fi
    test_command="mix test"
    build_command="mix compile"
  fi

  # Fallback: detect Makefile targets if no language-specific commands found
  if [[ -f "$root/Makefile" ]]; then
    [[ -z "$language" ]] && language="makefile"
    if [[ -z "$test_command" ]]; then
      if grep -q '^test:' "$root/Makefile" 2>/dev/null; then
        test_command="make test"
      fi
    fi
    if [[ -z "$build_command" ]]; then
      if grep -q '^build:' "$root/Makefile" 2>/dev/null; then
        build_command="make build"
      fi
    fi
    if [[ -z "$lint_command" ]]; then
      if grep -q '^lint:' "$root/Makefile" 2>/dev/null; then
        lint_command="make lint"
      fi
    fi
  fi

  # Build JSON output, omitting empty fields
  jq -cn \
    --arg language "$language" \
    --arg framework "$framework" \
    --arg test_command "$test_command" \
    --arg build_command "$build_command" \
    --arg lint_command "$lint_command" \
    '{
      language: $language,
      framework: $framework,
      test_command: $test_command,
      build_command: $build_command,
      lint_command: $lint_command
    } | with_entries(select(.value != ""))'
}

# Extract YAML frontmatter from a markdown file (between --- markers)
# Returns JSON via yq, or empty on failure
_extract_frontmatter() {
  local file="$1"

  # Check that file starts with ---
  local first_line
  first_line=$(head -1 "$file" 2>/dev/null)
  [[ "$first_line" != "---" ]] && return 1

  local content
  content=$(sed -n '/^---$/,/^---$/p' "$file" 2>/dev/null | sed '1d;$d')
  [[ -z "$content" ]] && return 1
  echo "$content" | yq -o json '.' 2>/dev/null || return 1
}

_merge_scan_results() {
  local agents="$1" skills="$2" stack="${3:-"{}"}"
  local settings_file="${CQ_PROJECT_ROOT}/.claudekiq/settings.json"
  local ts
  ts=$(cq_now)

  local existing='{}'
  if [[ -f "$settings_file" ]]; then
    existing=$(cat "$settings_file")
  fi

  local updated
  updated=$(jq \
    --argjson agents "$agents" \
    --argjson skills "$skills" \
    --argjson stack "$stack" \
    --arg ts "$ts" \
    '. + {agents: $agents, skills: $skills, stack: $stack, scanned_at: $ts} | del(.plugins)' \
    <<< "$existing")

  echo "$updated" > "$settings_file"
}
