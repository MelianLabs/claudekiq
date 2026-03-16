#!/usr/bin/env bash
# scan.sh — Scan project for agents, skills, and stack info

cmd_scan() {
  [[ -d "${CQ_PROJECT_ROOT}/.claudekiq" ]] || cq_die "Not a cq project. Run 'cq init' first."

  local agents skills plugin_skills stacks commands
  agents=$(_scan_agents)
  skills=$(_scan_skills)
  plugin_skills=$(_scan_plugin_skills)
  stacks=$(_scan_stacks)
  commands=$(_scan_commands)

  # Merge plugin skills into skills (deduplicate by name, plugin wins)
  skills=$(jq -n --argjson local "$skills" --argjson plugin "$plugin_skills" '
    ($local + $plugin) | group_by(.name) | map(
      if length > 1 then (map(select(.source == "plugin")) | first) // first
      else first end
    )
  ')

  _merge_scan_results "$stacks"

  # Validate workflows and collect warnings
  local workflow_warnings
  workflow_warnings=$(_scan_validate_workflows)

  # Regenerate .claude/cq.md context file
  _generate_cq_md >/dev/null 2>&1 || true

  local ts
  ts=$(cq_now)
  local agent_count skill_count stack_count command_count
  agent_count=$(jq 'length' <<< "$agents")
  skill_count=$(jq 'length' <<< "$skills")
  stack_count=$(jq 'length' <<< "$stacks")
  command_count=$(jq 'length' <<< "$commands")

  cq_json_out \
    --argjson agents "$agents" \
    --argjson skills "$skills" \
    --argjson stacks "$stacks" \
    --argjson commands "$commands" \
    --argjson workflow_warnings "$workflow_warnings" \
    --arg scanned_at "$ts" \
    '{agents:$agents, skills:$skills, stacks:$stacks, commands:$commands, workflow_warnings:$workflow_warnings, scanned_at:$scanned_at}' || {
    cq_info "Scanned: ${agent_count} agent(s), ${skill_count} skill(s), ${command_count} command(s), ${stack_count} stack(s)"
    if [[ "$(jq 'length' <<< "$workflow_warnings")" -gt 0 ]]; then
      local wf_warn
      while IFS= read -r wf_warn; do
        [[ -n "$wf_warn" ]] && cq_warn "Workflow validation issue: ${wf_warn}"
      done <<< "$(jq -r '.[]' <<< "$workflow_warnings")"
    fi
  }
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

  cq_items_to_json "${items[@]+"${items[@]}"}"
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

  cq_items_to_json "${items[@]+"${items[@]}"}"
}

_scan_plugin_skills() {
  local plugin_file="${CQ_PROJECT_ROOT}/.claude-plugin/plugin.json"
  local -a items=()

  if [[ -f "$plugin_file" ]]; then
    local plugin_dir
    plugin_dir=$(dirname "$plugin_file")
    local skill_paths
    skill_paths=$(jq -r '.skills // [] | .[]' "$plugin_file" 2>/dev/null)

    local spath
    while IFS= read -r spath; do
      [[ -z "$spath" ]] && continue
      # Resolve relative to plugin dir
      local resolved
      if [[ "$spath" == /* ]]; then
        resolved="$spath"
      else
        resolved="${plugin_dir}/${spath}"
      fi
      local skill_md="${resolved}/SKILL.md"
      [[ -f "$skill_md" ]] || continue

      local frontmatter
      frontmatter=$(_extract_frontmatter "$skill_md") || continue
      [[ -z "$frontmatter" || "$frontmatter" == "null" ]] && continue

      local dir_name
      dir_name=$(basename "$resolved")

      local item
      item=$(jq -cn \
        --arg fallback_name "$dir_name" \
        --argjson fm "$frontmatter" \
        '{
          name: ($fm.name // $fallback_name),
          description: ($fm.description // null),
          tools: (if $fm["allowed-tools"] then ($fm["allowed-tools"] | split(",") | map(gsub("^\\s+|\\s+$"; ""))) else null end),
          source: "plugin"
        } | with_entries(select(.value != null))') || continue
      items+=("$item")
    done <<< "$skill_paths"
  fi

  cq_items_to_json "${items[@]+"${items[@]}"}"
}

# Detect all stacks in the project. Returns a JSON array of stack objects.
# A project can have multiple stacks (e.g., Rails backend + React frontend).
_scan_stacks() {
  local root="$CQ_PROJECT_ROOT"
  local -a items=()

  # --- JavaScript / TypeScript ---
  if [[ -f "$root/package.json" ]]; then
    local language="javascript"
    local framework="" test_command="" build_command="" lint_command=""
    local pkg_json
    pkg_json=$(cat "$root/package.json" 2>/dev/null)

    if [[ -f "$root/tsconfig.json" ]]; then
      language="typescript"
    fi
    # Detect framework from dependencies
    local deps
    deps=$(jq -r '(.dependencies // {}) + (.devDependencies // {}) | keys[]' <<< "$pkg_json" 2>/dev/null || true)
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
    elif echo "$deps" | grep -q '^preact$'; then
      framework="preact"
    fi
    # Detect commands from package.json scripts
    local scripts test_script
    scripts=$(jq -r '.scripts // {} | keys[]' <<< "$pkg_json" 2>/dev/null || true)
    if echo "$scripts" | grep -q '^test$'; then
      test_script=$(jq -r '.scripts.test' <<< "$pkg_json" 2>/dev/null)
      if [[ "$test_script" != *"no test specified"* ]]; then
        test_command="npm test"
      fi
    fi
    if echo "$scripts" | grep -q '^build$'; then
      build_command="npm run build"
    fi
    if echo "$scripts" | grep -q '^lint$'; then
      lint_command="npm run lint"
    fi
    items+=("$(_build_stack_json "$language" "$framework" "$test_command" "$build_command" "$lint_command")")
  fi

  # --- Ruby ---
  if [[ -f "$root/Gemfile" ]]; then
    local language="ruby" framework="" test_command="" build_command="" lint_command=""
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
    items+=("$(_build_stack_json "$language" "$framework" "$test_command" "$build_command" "$lint_command")")
  fi

  # --- Go ---
  if [[ -f "$root/go.mod" ]]; then
    items+=("$(_build_stack_json "go" "" "go test ./..." "go build ./..." "golangci-lint run")")
  fi

  # --- Rust ---
  if [[ -f "$root/Cargo.toml" ]]; then
    items+=("$(_build_stack_json "rust" "" "cargo test" "cargo build" "cargo clippy")")
  fi

  # --- Python ---
  if [[ -f "$root/pyproject.toml" ]] || [[ -f "$root/requirements.txt" ]]; then
    local language="python" framework="" test_command="" build_command="" lint_command=""
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
    items+=("$(_build_stack_json "$language" "$framework" "$test_command" "$build_command" "$lint_command")")
  fi

  # --- Java ---
  if [[ -f "$root/pom.xml" ]] || [[ -f "$root/build.gradle" ]]; then
    local language="java" framework="" test_command="" build_command="" lint_command=""
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
    items+=("$(_build_stack_json "$language" "$framework" "$test_command" "$build_command" "$lint_command")")
  fi

  # --- Elixir ---
  if [[ -f "$root/mix.exs" ]]; then
    local language="elixir" framework=""
    local mix_content
    mix_content=$(cat "$root/mix.exs" 2>/dev/null || true)
    if echo "$mix_content" | grep -qi 'phoenix'; then
      framework="phoenix"
    fi
    items+=("$(_build_stack_json "$language" "$framework" "mix test" "mix compile" "")")
  fi

  # --- Makefile fallback (only if no other stacks detected) ---
  if [[ ${#items[@]} -eq 0 && -f "$root/Makefile" ]]; then
    local test_command="" build_command="" lint_command=""
    if grep -q '^test:' "$root/Makefile" 2>/dev/null; then test_command="make test"; fi
    if grep -q '^build:' "$root/Makefile" 2>/dev/null; then build_command="make build"; fi
    if grep -q '^lint:' "$root/Makefile" 2>/dev/null; then lint_command="make lint"; fi
    items+=("$(_build_stack_json "makefile" "" "$test_command" "$build_command" "$lint_command")")
  fi

  # --- Supplement stacks with Makefile targets ---
  if [[ ${#items[@]} -gt 0 && -f "$root/Makefile" ]]; then
    # Check each stack — if missing build_command, supplement from Makefile
    local -a supplemented=()
    local item
    for item in "${items[@]}"; do
      local has_build has_test has_lint
      has_build=$(jq -r '.build_command // empty' <<< "$item")
      has_test=$(jq -r '.test_command // empty' <<< "$item")
      has_lint=$(jq -r '.lint_command // empty' <<< "$item")
      local updates='{}'
      if [[ -z "$has_build" ]] && grep -q '^build:' "$root/Makefile" 2>/dev/null; then
        updates=$(jq -cn --arg v "make build" '{build_command:$v}')
      fi
      if [[ -z "$has_test" ]] && grep -q '^test:' "$root/Makefile" 2>/dev/null; then
        updates=$(jq -cn --argjson u "$updates" --arg v "make test" '$u + {test_command:$v}')
      fi
      if [[ -z "$has_lint" ]] && grep -q '^lint:' "$root/Makefile" 2>/dev/null; then
        updates=$(jq -cn --argjson u "$updates" --arg v "make lint" '$u + {lint_command:$v}')
      fi
      if [[ "$updates" != '{}' ]]; then
        item=$(jq --argjson u "$updates" '. + $u' <<< "$item")
      fi
      supplemented+=("$item")
    done
    items=("${supplemented[@]}")
  fi

  cq_items_to_json "${items[@]+"${items[@]}"}"
}

# Helper: build a stack JSON object, omitting empty fields
_build_stack_json() {
  local language="$1" framework="$2" test_command="$3" build_command="$4" lint_command="$5"
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

_scan_commands() {
  local commands_dir="${CQ_PROJECT_ROOT}/.claude/commands"
  local -a items=()

  if [[ -d "$commands_dir" ]]; then
    local file
    for file in "$commands_dir"/*.md; do
      [[ -f "$file" ]] || continue
      local basename_no_ext
      basename_no_ext=$(basename "$file" .md)

      local frontmatter
      frontmatter=$(_extract_frontmatter "$file" 2>/dev/null) || frontmatter=""

      local item
      if [[ -n "$frontmatter" && "$frontmatter" != "null" ]]; then
        item=$(jq -cn \
          --arg fn "$basename_no_ext" \
          --argjson fm "$frontmatter" \
          '{name: ($fm.name // $fn), description: ($fm.description // null)} | with_entries(select(.value != null))') || continue
      else
        item=$(jq -cn --arg fn "$basename_no_ext" '{name: $fn}')
      fi
      items+=("$item")
    done
  fi

  cq_items_to_json "${items[@]+"${items[@]}"}"
}

_scan_validate_workflows() {
  local workflows_dir="${CQ_PROJECT_ROOT}/.claudekiq/workflows"
  local -a warnings=()

  if [[ -d "$workflows_dir" ]]; then
    local wf
    for wf in "$workflows_dir"/*.yml "$workflows_dir"/*.yaml; do
      [[ -f "$wf" ]] || continue
      # Run validation in non-JSON mode to get predictable output
      local exit_code=0
      CQ_JSON=false cmd_workflows_validate "$wf" >/dev/null 2>&1 || exit_code=$?
      if [[ "$exit_code" -ne 0 ]]; then
        warnings+=("$(basename "$wf")")
      fi
    done
  fi

  if [[ ${#warnings[@]} -gt 0 ]]; then
    printf '%s\n' "${warnings[@]}" | jq -Rcs 'split("\n") | map(select(. != ""))'
  else
    echo '[]'
  fi
}

_merge_scan_results() {
  local stacks="${1:-"[]"}"
  local settings_file="${CQ_PROJECT_ROOT}/.claudekiq/settings.json"
  local ts
  ts=$(cq_now)

  local existing='{}'
  if [[ -f "$settings_file" ]]; then
    existing=$(cat "$settings_file")
  fi

  # Only cache stacks (detected from project files, not dynamic directories)
  # Agents, skills, and commands are always discovered dynamically
  local updated
  updated=$(jq \
    --argjson stacks "$stacks" \
    --arg ts "$ts" \
    '. + {stacks: $stacks, scanned_at: $ts} | del(.plugins) | del(.stack) | del(.agents) | del(.skills) | del(.commands)' \
    <<< "$existing")

  echo "$updated" > "$settings_file"
}
