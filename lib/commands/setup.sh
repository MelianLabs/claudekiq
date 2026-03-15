#!/usr/bin/env bash
# setup.sh — Init, version, help, and skill installation commands

cmd_init() {
  local project_dir="$PWD"
  local install_mcp=false

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mcp) install_mcp=true; shift ;;
      *)
        # Treat non-flag arg as project_dir
        if [[ -d "$1" ]]; then
          project_dir="$1"
        fi
        shift
        ;;
    esac
  done

  if [[ -d "${project_dir}/.claudekiq" ]]; then
    # Already initialized — still update skills, hooks, and gitignore in case of upgrades
    _install_skill "$project_dir"
    _install_workers_skill "$project_dir"
    _install_agents "$project_dir"
    _install_hooks "$project_dir"
    _install_settings "$project_dir"

    # Ensure .gitignore has workers entry (added in v2.0.0)
    local gitignore="${project_dir}/.gitignore"
    if [[ -f "$gitignore" ]]; then
      grep -qF '.claudekiq/workers/' "$gitignore" || echo '.claudekiq/workers/' >> "$gitignore"
    fi

    # Install MCP config only if explicitly requested
    if $install_mcp; then
      _install_mcp_config "$project_dir"
    fi

    # Auto-scan for agents, skills, and plugins
    CQ_PROJECT_ROOT="$project_dir" cmd_scan >/dev/null 2>&1 || true

    cq_json_out --arg dir "$project_dir" '{status:"exists", directory:$dir}' || \
      cq_info "Already initialized in ${project_dir}"
    return 0
  fi

  mkdir -p "${project_dir}/.claudekiq/workflows/private"
  mkdir -p "${project_dir}/.claudekiq/runs"
  mkdir -p "${project_dir}/.claudekiq/plugins"

  # Create default settings.json
  echo '{}' > "${project_dir}/.claudekiq/settings.json"

  # Append to .gitignore
  local gitignore="${project_dir}/.gitignore"
  local needs_private=true
  local needs_runs=true
  local needs_workers=true
  if [[ -f "$gitignore" ]]; then
    grep -qF '.claudekiq/workflows/private/' "$gitignore" && needs_private=false
    grep -qF '.claudekiq/runs/' "$gitignore" && needs_runs=false
    grep -qF '.claudekiq/workers/' "$gitignore" && needs_workers=false
  fi
  {
    $needs_private && echo '.claudekiq/workflows/private/'
    $needs_runs && echo '.claudekiq/runs/'
    $needs_workers && echo '.claudekiq/workers/'
  } >> "$gitignore"

  # Install Claude Code skills, agents, hooks, and settings
  _install_skill "$project_dir"
  _install_workers_skill "$project_dir"
  _install_agents "$project_dir"
  _install_hooks "$project_dir"
  _install_settings "$project_dir"

  # Install MCP config only if explicitly requested
  if $install_mcp; then
    _install_mcp_config "$project_dir"
  fi

  # Auto-scan for agents, skills, and plugins
  CQ_PROJECT_ROOT="$project_dir" cmd_scan >/dev/null 2>&1 || true

  cq_json_out --arg dir "$project_dir" '{status:"initialized", directory:$dir}' || \
    cq_info "Initialized .claudekiq/ in ${project_dir}"
}

_install_skill() {
  local project_dir="$1"
  local skill_dir="${project_dir}/.claude/skills/cq"
  mkdir -p "$skill_dir"

  # Try to copy from the cq installation directory first
  local src="${CQ_SCRIPT_DIR}/skills/cq/SKILL.md"
  # When installed to ~/.cq/bin/, skills are at ~/.cq/skills/
  [[ ! -f "$src" ]] && src="${CQ_SCRIPT_DIR}/../skills/cq/SKILL.md"
  if [[ -f "$src" ]]; then
    cp "$src" "${skill_dir}/SKILL.md"
    return
  fi

  cq_die "Cannot find skills/cq/SKILL.md — please reinstall cq"
}

_install_workers_skill() {
  local project_dir="$1"
  local skill_dir="${project_dir}/.claude/skills/cq-workers"
  mkdir -p "$skill_dir"

  # Try to copy from the cq installation directory first
  local src="${CQ_SCRIPT_DIR}/skills/cq-workers/SKILL.md"
  # When installed to ~/.cq/bin/, skills are at ~/.cq/skills/
  [[ ! -f "$src" ]] && src="${CQ_SCRIPT_DIR}/../skills/cq-workers/SKILL.md"
  if [[ -f "$src" ]]; then
    cp "$src" "${skill_dir}/SKILL.md"
    return
  fi

  cq_die "Cannot find skills/cq-workers/SKILL.md — please reinstall cq"
}

_install_agents() {
  local project_dir="$1"
  local agents_dir="${project_dir}/.claude/agents"
  mkdir -p "$agents_dir"

  # Install all agent definitions from cq distribution
  local agents_src="${CQ_SCRIPT_DIR}/.claude/agents"
  [[ ! -d "$agents_src" ]] && agents_src="${CQ_SCRIPT_DIR}/../.claude/agents"
  if [[ -d "$agents_src" ]]; then
    cp "$agents_src"/*.md "$agents_dir/" 2>/dev/null || true
  fi

  # Migrate legacy agent-mapping.json into settings.json agent_mappings key
  local mapping_file="${project_dir}/.claudekiq/agent-mapping.json"
  if [[ -f "$mapping_file" ]]; then
    local settings_file="${project_dir}/.claudekiq/settings.json"
    local mappings
    mappings=$(cat "$mapping_file")
    # Only migrate if mappings is non-empty object
    if [[ "$(jq 'length' <<< "$mappings" 2>/dev/null)" -gt 0 ]]; then
      local existing='{}'
      [[ -f "$settings_file" ]] && existing=$(cat "$settings_file")
      existing=$(jq --argjson m "$mappings" '.agent_mappings = (.agent_mappings // {} | . * $m)' <<< "$existing")
      echo "$existing" > "$settings_file"
    fi
    rm -f "$mapping_file"
  fi
}

_install_hooks() {
  local project_dir="$1"
  local hooks_dir="${project_dir}/.claude/hooks"
  mkdir -p "$hooks_dir"

  # Install PostToolUse hook
  local src="${CQ_SCRIPT_DIR}/.claude/hooks/PostToolUse.sh"
  [[ ! -f "$src" ]] && src="${CQ_SCRIPT_DIR}/../.claude/hooks/PostToolUse.sh"
  if [[ -f "$src" ]]; then
    cp "$src" "${hooks_dir}/PostToolUse.sh"
    chmod +x "${hooks_dir}/PostToolUse.sh"
  fi
}

_install_settings() {
  local project_dir="$1"
  local settings_file="${project_dir}/.claude/settings.json"

  # Install project-scoped Claude Code settings (hooks config)
  # Only install if no settings.json exists yet — don't overwrite user customizations
  if [[ ! -f "$settings_file" ]]; then
    local src="${CQ_SCRIPT_DIR}/.claude/settings.json"
    [[ ! -f "$src" ]] && src="${CQ_SCRIPT_DIR}/../.claude/settings.json"
    if [[ -f "$src" ]]; then
      cp "$src" "$settings_file"
    fi
  fi
}

_install_mcp_config() {
  local project_dir="$1"
  local mcp_file="${project_dir}/.mcp.json"

  if [[ -f "$mcp_file" ]]; then
    # Check if cq entry already exists
    if jq -e '.mcpServers.cq' "$mcp_file" >/dev/null 2>&1; then
      return
    fi
    # Add cq entry to existing config
    local tmp
    tmp=$(jq '.mcpServers.cq = {"type":"stdio","command":"cq","args":["mcp"]}' "$mcp_file")
    echo "$tmp" > "$mcp_file"
  else
    cat > "$mcp_file" <<'MCP_EOF'
{
  "mcpServers": {
    "cq": {
      "type": "stdio",
      "command": "cq",
      "args": ["mcp"]
    }
  }
}
MCP_EOF
  fi
}

cmd_version() {
  cq_json_out --arg v "$CQ_VERSION" '{version:$v}' || \
    echo "cq ${CQ_VERSION}"
}

cmd_help() {
  local command="${1:-}"

  if [[ -n "$command" ]]; then
    _help_for_command "$command"
    return
  fi

  cat <<'HELP'
Usage: cq <command> [subcommand] [args] [flags]

Workflow lifecycle:
  start <template> [--key=val]...   Start a new workflow run
  status [run_id]                   Dashboard (no args) or run detail
  list                              List all active runs
  log <run_id>                      Show event log for a run

Flow control:
  pause <run_id>                    Pause a running workflow
  resume <run_id>                   Resume a paused workflow
  cancel <run_id>                   Cancel a workflow
  retry <run_id>                    Retry a failed workflow

Step control:
  step-done <run_id> <step_id> pass|fail   Mark step complete
  skip <run_id> [step_id]                  Skip current/named step

Human actions:
  todos [--flow <run_id>]           List pending human actions
  todo <#> approve|reject|override|dismiss  Resolve a human action

Context:
  ctx <run_id>                      Show all context variables
  ctx get <key> <run_id>            Get a context variable
  ctx set <key> <value> <run_id>    Set a context variable

Dynamic modification:
  add-step <run_id> <step_json> [--after <step_id>]
  add-steps <run_id> --flow <template> [--after <step_id>]
  set-next <run_id> <step_id> <target>    Force next step

Template management:
  workflows list                    List available templates
  workflows show <name>             Show template details
  workflows validate <file>         Validate a workflow YAML

Configuration:
  config                            Show resolved config
  config get <key>                  Get config value
  config set <key> <value>          Set project config value
  config set --global <key> <value> Set global config value

Setup:
  init [--mcp]                      Initialize .claudekiq/ in current project
  scan                              Discover agents, skills, and plugins
  version                           Show version
  help [command]                    Show help
  schema [command]                  Show command schema (JSON)

Maintenance:
  cleanup                           Remove expired runs

Flags:
  --json        Machine-readable JSON output
  --headless    CI mode (auto-approve gates, JSON output)
HELP
}

_help_for_command() {
  local cmd="$1"
  case "$cmd" in
    start)   echo "Usage: cq start <template> [--key=val]... [--priority=<level>]" ;;
    status)  echo "Usage: cq status [run_id]" ;;
    list)    echo "Usage: cq list" ;;
    log)     echo "Usage: cq log <run_id> [--tail N]" ;;
    pause)   echo "Usage: cq pause <run_id>" ;;
    resume)  echo "Usage: cq resume <run_id>" ;;
    cancel)  echo "Usage: cq cancel <run_id>" ;;
    retry)   echo "Usage: cq retry <run_id>" ;;
    step-done) echo "Usage: cq step-done <run_id> <step_id> pass|fail [result_json]" ;;
    skip)    echo "Usage: cq skip <run_id> [step_id]" ;;
    todos)   echo "Usage: cq todos [--flow <run_id>]" ;;
    todo)    echo "Usage: cq todo <#> approve|reject|override|dismiss [--note \"...\"]" ;;
    ctx)     echo "Usage: cq ctx <run_id> | cq ctx get <key> <run_id> | cq ctx set <key> <value> <run_id>" ;;
    add-step)  echo "Usage: cq add-step <run_id> <step_json> [--after <step_id>]" ;;
    add-steps) echo "Usage: cq add-steps <run_id> --flow <template> [--after <step_id>]" ;;
    set-next)  echo "Usage: cq set-next <run_id> <step_id> <target>" ;;
    workflows) echo "Usage: cq workflows list|show|validate" ;;
    config)    echo "Usage: cq config | cq config get <key> | cq config set [--global] <key> <value>" ;;
    init)    echo "Usage: cq init [--mcp]" ;;
    scan)    echo "Usage: cq scan [--json]" ;;
    schema)  echo "Usage: cq schema [command]" ;;
    cleanup) echo "Usage: cq cleanup" ;;
    *)       echo "Unknown command: $cmd. Run 'cq help' for usage." ;;
  esac
}
