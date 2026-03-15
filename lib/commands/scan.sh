#!/usr/bin/env bash
# scan.sh — Scan project for agents, skills, and plugins

cmd_scan() {
  [[ -d "${CQ_PROJECT_ROOT}/.claudekiq" ]] || cq_die "Not a cq project. Run 'cq init' first."

  local agents skills plugins
  agents=$(_scan_agents)
  skills=$(_scan_skills)
  plugins=$(_scan_plugins)

  _merge_scan_results "$agents" "$skills" "$plugins"

  local ts
  ts=$(cq_now)
  local agent_count skill_count plugin_count
  agent_count=$(jq 'length' <<< "$agents")
  skill_count=$(jq 'length' <<< "$skills")
  plugin_count=$(jq 'length' <<< "$plugins")

  cq_json_out \
    --argjson agents "$agents" \
    --argjson skills "$skills" \
    --argjson plugins "$plugins" \
    --arg scanned_at "$ts" \
    '{agents:$agents, skills:$skills, plugins:$plugins, scanned_at:$scanned_at}' || \
    cq_info "Scanned: ${agent_count} agent(s), ${skill_count} skill(s), ${plugin_count} plugin(s)"
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

_scan_plugins() {
  local plugins_dir="${CQ_PROJECT_ROOT}/.claudekiq/plugins"
  local -a items=()

  if [[ -d "$plugins_dir" ]]; then
    local file
    for file in "$plugins_dir"/*.sh; do
      [[ -f "$file" ]] || continue
      local plugin_name
      plugin_name=$(basename "$file" .sh)
      local is_exec="false"
      [[ -x "$file" ]] && is_exec="true"
      items+=("$(jq -cn \
        --arg name "$plugin_name" \
        --arg path ".claudekiq/plugins/${plugin_name}.sh" \
        --argjson executable "$is_exec" \
        '{name:$name, type:"bash", path:$path, executable:$executable}')")
    done
  fi

  if [[ ${#items[@]} -gt 0 ]]; then
    printf '%s\n' "${items[@]}" | jq -s '.'
  else
    echo '[]'
  fi
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
  local agents="$1" skills="$2" plugins="$3"
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
    --argjson plugins "$plugins" \
    --arg ts "$ts" \
    '.agents = $agents | .skills = $skills | .plugins = $plugins | .scanned_at = $ts' \
    <<< "$existing")

  echo "$updated" > "$settings_file"
}
