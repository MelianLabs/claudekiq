#!/usr/bin/env bash
# setup.sh — Init, version, help, hooks, and plugin.json installation commands

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

  local init_status="initialized"
  if [[ -d "${project_dir}/.claudekiq" ]]; then
    init_status="exists"
  else
    mkdir -p "${project_dir}/.claudekiq/workflows/private"
    mkdir -p "${project_dir}/.claudekiq/runs"

    # Create default settings.json
    echo '{}' > "${project_dir}/.claudekiq/settings.json"

    # Append to .gitignore
    local gitignore="${project_dir}/.gitignore"
    local needs_private=true
    local needs_runs=true
    local needs_active_runs=true
    local needs_commands=true
    if [[ -f "$gitignore" ]]; then
      grep -qF '.claudekiq/workflows/private/' "$gitignore" && needs_private=false
      grep -qF '.claudekiq/runs/' "$gitignore" && needs_runs=false
      grep -qF '.claudekiq/.active_runs' "$gitignore" && needs_active_runs=false
      grep -qF '.claude/commands/cq*.md' "$gitignore" && needs_commands=false
    fi
    {
      $needs_private && echo '.claudekiq/workflows/private/'
      $needs_runs && echo '.claudekiq/runs/'
      $needs_active_runs && echo '.claudekiq/.active_runs'
      $needs_commands && echo '.claude/commands/cq*.md'
    } >> "$gitignore"
  fi

  # Common post-init: commands, plugin, MCP, scan, hooks, cq.md
  _install_commands "$project_dir"
  _install_plugin_json "$project_dir"

  if $install_mcp; then
    _install_mcp_config "$project_dir"
  fi

  CQ_PROJECT_ROOT="$project_dir" cmd_scan >/dev/null 2>&1 || true
  CQ_PROJECT_ROOT="$project_dir" _hooks_install >/dev/null 2>&1 || true
  CQ_PROJECT_ROOT="$project_dir" _generate_cq_md >/dev/null 2>&1 || true

  # Output with discovery context
  local _agents_found _workflows_found _stacks_found
  _agents_found=$(jq '.agents // [] | length' "${project_dir}/.claudekiq/settings.json" 2>/dev/null || echo "0")
  _workflows_found=$(find "${project_dir}/.claudekiq/workflows" -maxdepth 1 -name '*.yml' -o -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')
  _stacks_found=$(jq '.stacks // [] | length' "${project_dir}/.claudekiq/settings.json" 2>/dev/null || echo "0")

  cq_json_out --arg dir "$project_dir" --arg status "$init_status" --argjson agents "$_agents_found" --argjson workflows "$_workflows_found" --argjson stacks "$_stacks_found" \
    '{status:$status, directory:$dir, agents_found:$agents, workflows_found:$workflows, stacks_found:$stacks}' || {
    if [[ "$init_status" == "exists" ]]; then
      cq_info "Already initialized in ${project_dir}"
    else
      cq_info "Initialized .claudekiq/ in ${project_dir}"
    fi
    _init_discovery_hints "$_agents_found" "$_workflows_found" "$_stacks_found"
  }
  return 0
}

_init_discovery_hints() {
  local agents_found="$1" workflows_found="$2" stacks_found="$3"

  if [[ "$agents_found" -gt 0 ]]; then
    local agent_names
    agent_names=$(jq -r '.agents // [] | map("@" + .name) | join(", ")' "${CQ_PROJECT_ROOT:-$PWD}/.claudekiq/settings.json" 2>/dev/null || true)
    cq_info "Found ${agents_found} agent(s): ${agent_names}"
  else
    cq_hint "No agents found. Consider creating .claude/agents/<name>.md files."
  fi

  if [[ "$stacks_found" -gt 0 ]]; then
    local stack_names
    stack_names=$(jq -r '.stacks // [] | map(.language + (if .framework then "/" + .framework else "" end)) | join(", ")' "${CQ_PROJECT_ROOT:-$PWD}/.claudekiq/settings.json" 2>/dev/null || true)
    cq_info "Detected stacks: ${stack_names}"
  fi

  if [[ "$workflows_found" -gt 0 ]]; then
    cq_info "${workflows_found} workflow(s) available. Run /cq to start one."
  else
    cq_hint "Run /cq setup to discover your project and create customized workflows."
  fi
}

_install_commands() {
  local project_dir="$1"
  local cq_home="${HOME}/.cq"
  local commands_dir="${project_dir}/.claude/commands"
  mkdir -p "$commands_dir"

  # Symlink skill definitions as Claude Code custom commands
  local skill_name
  for skill_name in cq cq-runner cq-approve cq-worker cq-setup; do
    local src="${cq_home}/skills/${skill_name}/SKILL.md"
    local dest="${commands_dir}/${skill_name}.md"
    if [[ -f "$src" ]]; then
      ln -sf "$src" "$dest"
    fi
  done
}

_install_plugin_json() {
  local project_dir="$1"
  local cq_home="${HOME}/.cq"
  local plugin_dir="${project_dir}/.claude-plugin"
  mkdir -p "$plugin_dir"

  # Preserve user-added skills from existing plugin.json
  local user_skills="[]"
  if [[ -f "${plugin_dir}/plugin.json" ]]; then
    user_skills=$(jq -r --arg home "$cq_home" '
      [.skills // [] | .[] | select(startswith($home + "/skills/") | not)]
    ' "${plugin_dir}/plugin.json" 2>/dev/null || echo "[]")
  fi

  # Build new plugin.json with CQ_VERSION and merge user skills
  # Only /cq is user-facing; other skills are internal (invoked programmatically)
  jq -cn --arg home "$cq_home" --arg ver "$CQ_VERSION" --argjson user_skills "$user_skills" '{
    name:"claudekiq", version:$ver,
    description:"Filesystem-backed workflow engine for Claude Code",
    skills:([($home+"/skills/cq")] + $user_skills)
  }' > "${plugin_dir}/plugin.json"
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

# --- Hooks management ---

cmd_hooks() {
  local subcmd="${1:-help}"
  shift 2>/dev/null || true

  case "$subcmd" in
    install)   _hooks_install "$@" ;;
    uninstall) _hooks_uninstall "$@" ;;
    help|*)
      echo "Usage: cq hooks <install|uninstall>"
      echo ""
      echo "  Hooks are installed automatically by 'cq init'."
      echo "  install    Merge cq hooks into .claude/settings.json"
      echo "  uninstall  Remove cq hooks from .claude/settings.json"
      ;;
  esac
}

# Detect conflicts between existing non-cq hooks and cq hooks being installed
_hooks_detect_conflicts() {
  local existing="$1" cq_hooks="$2"

  # Get existing hooks that are NOT cq hooks (don't contain 'cq ' or '.claudekiq')
  local conflicts
  conflicts=$(jq -r --argjson cq_hooks "$cq_hooks" '
    .hooks // {} | to_entries[] |
    .key as $type |
    .value // [] | .[] |
    select((.hooks // [] | any((.command // "") | test("cq |cq$|\\.claudekiq"))) | not) |
    .matcher as $matcher |
    if ($cq_hooks[$type] // [] | any(.matcher == $matcher)) then
      "\($type)[\($matcher)]"
    else empty end
  ' <<< "$existing" 2>/dev/null)

  if [[ -n "$conflicts" ]]; then
    local conflict
    while IFS= read -r conflict; do
      [[ -z "$conflict" ]] && continue
      cq_warn "Existing hook for ${conflict} detected. cq hooks will run alongside it."
    done <<< "$conflicts"
  fi
}

_hooks_install() {
  local project_dir="${CQ_PROJECT_ROOT:-$PWD}"
  local settings_file="${project_dir}/.claude/settings.json"
  mkdir -p "${project_dir}/.claude"

  # Define cq hooks (matcher + hooks[] format)
  # Only hooks that Claude Code doesn't already handle:
  #   - Protect .claudekiq/runs/ from direct edits
  #   - Block git checkout during active workflows
  #   - Protect .claudekiq/ directory from deletion
  #   - Stage context for active workflow steps
  #   - Capture agent output
  #   - Auto-init in worktrees
  local cq_hooks
  cq_hooks=$(cat <<'HOOKS_JSON'
{
  "SessionEnd": [
    {
      "matcher": "",
      "hooks": [
        {
          "type": "command",
          "command": "cq check-stale --timeout=0 --mark 2>/dev/null || true",
          "async": true
        }
      ]
    }
  ],
  "PreToolUse": [
    {
      "matcher": "Bash",
      "hooks": [
        {
          "type": "command",
          "command": "bash -c 'input=$(cat); cmd=$(echo \"$input\" | jq -r \".tool_input.command // empty\"); rc=0; case \"$cmd\" in *\"rm -rf .claudekiq\"*|*\"rm -rf .claudekiq/\"*|*\"rm -r .claudekiq\"*|*\"rm -r .claudekiq/\"*) cq _safety-check rm_claudekiq; rc=$?;; *\"git checkout\"*|*\"git switch\"*) cq _safety-check git_checkout; rc=$?;; esac; exit $rc'"
        }
      ]
    },
    {
      "matcher": "Edit",
      "hooks": [
        {
          "type": "command",
          "command": "bash -c 'input=$(cat); path=$(echo \"$input\" | jq -r \".tool_input.file_path // empty\"); rc=0; case \"$path\" in */.claudekiq/runs/*) cq _safety-check edit_run_files; rc=$?;; esac; exit $rc'"
        }
      ]
    },
    {
      "matcher": "Write",
      "hooks": [
        {
          "type": "command",
          "command": "bash -c 'input=$(cat); path=$(echo \"$input\" | jq -r \".tool_input.file_path // empty\"); rc=0; case \"$path\" in */.claudekiq/runs/*) cq _safety-check edit_run_files; rc=$?;; esac; exit $rc'"
        }
      ]
    }
  ],
  "PostToolUse": [
    {
      "matcher": "Bash",
      "hooks": [
        {
          "type": "command",
          "command": "bash -c 'input=$(cat); output=$(echo \"$input\" | jq -r \".stdout // empty\"); case \"$output\" in *\"step-done\"*|*\"completed\"*|*\"failed\"*|*\"gated\"*|*\"cq: \"*) if command -v osascript &>/dev/null; then msg=$(echo \"$output\" | head -1); osascript -e \"display notification \\\"$msg\\\" with title \\\"cq\\\" sound name \\\"Ping\\\"\" &>/dev/null; elif command -v notify-send &>/dev/null; then msg=$(echo \"$output\" | head -1); notify-send \"cq\" \"$msg\" &>/dev/null; fi;; esac; exit 0'",
          "async": true
        },
        {
          "type": "command",
          "command": "cq _stage-context 2>/dev/null || true",
          "async": true
        }
      ]
    },
    {
      "matcher": "Edit",
      "hooks": [
        {
          "type": "command",
          "command": "cq _stage-context 2>/dev/null || true",
          "async": true
        }
      ]
    },
    {
      "matcher": "Write",
      "hooks": [
        {
          "type": "command",
          "command": "cq _stage-context 2>/dev/null || true",
          "async": true
        }
      ]
    },
    {
      "matcher": "Agent",
      "hooks": [
        {
          "type": "command",
          "command": "cq _capture-output 2>/dev/null || true",
          "async": true
        }
      ]
    }
  ],
  "WorktreeCreate": [
    {
      "matcher": "",
      "hooks": [
        {
          "type": "command",
          "command": "bash -c 'input=$(cat); worktree_path=$(echo \"$input\" | jq -r \".worktree_path // empty\"); if [ -n \"$worktree_path\" ]; then cd \"$worktree_path\" && cq init 2>/dev/null; fi; exit 0'",
          "async": true
        }
      ]
    }
  ]
}
HOOKS_JSON
)

  local existing='{}'
  if [[ -f "$settings_file" ]]; then
    existing=$(cat "$settings_file")
  fi

  # Detect conflicts with existing non-cq hooks
  _hooks_detect_conflicts "$existing" "$cq_hooks"

  # Merge: for each hook type, append cq hooks to existing hooks
  local updated
  updated=$(jq --argjson cq_hooks "$cq_hooks" '
    .hooks = (.hooks // {}) |
    .hooks.SessionEnd = ((.hooks.SessionEnd // []) + $cq_hooks.SessionEnd | unique_by(.hooks[0].command)) |
    .hooks.PreToolUse = ((.hooks.PreToolUse // []) + $cq_hooks.PreToolUse | unique_by(.matcher + (.hooks[0].command))) |
    .hooks.PostToolUse = ((.hooks.PostToolUse // []) + $cq_hooks.PostToolUse | unique_by(.matcher + (.hooks[0].command))) |
    .hooks.WorktreeCreate = ((.hooks.WorktreeCreate // []) + $cq_hooks.WorktreeCreate | unique_by(.hooks[0].command))
  ' <<< "$existing")

  echo "$updated" > "$settings_file"

  cq_json_out '{status:"installed"}' || \
    cq_info "Hooks installed in ${settings_file}"
}

_hooks_uninstall() {
  local project_dir="${CQ_PROJECT_ROOT:-$PWD}"
  local settings_file="${project_dir}/.claude/settings.json"

  if [[ ! -f "$settings_file" ]]; then
    cq_json_out '{status:"no_settings"}' || \
      cq_info "No .claude/settings.json found"
    return 0
  fi

  # Remove cq-specific hook entries (identified by cq commands in hooks[])
  local updated
  updated=$(jq '
    if .hooks then
      .hooks |= with_entries(
        .value |= map(select(
          (.hooks // [] | any((.command // "") | test("cq |cq$|\\.claudekiq"))) | not
        ))
      ) |
      .hooks |= with_entries(select(.value | length > 0))
    else . end |
    if .hooks == {} then del(.hooks) else . end
  ' "$settings_file")

  echo "$updated" > "$settings_file"

  cq_json_out '{status:"uninstalled"}' || \
    cq_info "Hooks removed from ${settings_file}"
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
  next <run_id>                     Show current step definition
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
  scan                              Discover agents and skills
  hooks install|uninstall           Manage cq hooks in .claude/settings.json
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
    next)    echo "Usage: cq next <run_id>" ;;
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
    hooks)   echo "Usage: cq hooks install|uninstall" ;;
    schema)  echo "Usage: cq schema [command]" ;;
    cleanup) echo "Usage: cq cleanup" ;;
    *)       echo "Unknown command: $cmd. Run 'cq help' for usage." ;;
  esac
}

# --- Generate .claude/cq.md context file ---

_generate_cq_md() {
  local project_dir="${CQ_PROJECT_ROOT:-$PWD}"
  local settings_file="${project_dir}/.claudekiq/settings.json"
  local cq_md="${project_dir}/.claude/cq.md"

  mkdir -p "${project_dir}/.claude"

  {
    echo '# Claudekiq (cq) — Project Workflows'
    echo '<!-- Auto-generated by cq. Regenerate with: cq scan -->'
    echo ''

    # Available workflows (compact: name + description + params only)
    echo '## Workflows'
    local workflows_dir="${project_dir}/.claudekiq/workflows"
    local found_workflow=false
    if [[ -d "$workflows_dir" ]]; then
      local wf
      for wf in "$workflows_dir"/*.yml "$workflows_dir"/*.yaml; do
        [[ -f "$wf" ]] || continue
        found_workflow=true
        local wf_name wf_desc wf_json params_list
        wf_name=$(basename "$wf" | sed 's/\.yml$//;s/\.yaml$//')
        wf_json=$(yq -o json "$wf" 2>/dev/null || true)
        wf_desc=$(echo "$wf_json" | jq -r '.description // ""' 2>/dev/null || true)
        params_list=$(echo "$wf_json" | jq -r '.params // {} | keys | join(", ")' 2>/dev/null || true)
        local line="- **${wf_name}**"
        [[ -n "$wf_desc" ]] && line="${line} — ${wf_desc}"
        [[ -n "$params_list" ]] && line="${line} (params: ${params_list})"
        echo "$line"
      done
    fi
    $found_workflow || echo '_No workflows defined yet. Run `/cq setup` to discover your project and create workflows._'
    echo ''

    # Detected stacks (compact)
    if [[ -f "$settings_file" ]]; then
      local stacks
      stacks=$(jq -r '.stacks // [] | .[] | "- " + .language + (if .framework then "/" + .framework else "" end)' "$settings_file" 2>/dev/null || true)
      if [[ -n "$stacks" ]]; then
        echo '## Stacks'
        echo "$stacks"
        echo ''
      fi

      # Available agents (compact)
      local agents
      agents=$(jq -r '.agents // [] | .[] | "- @" + .name' "$settings_file" 2>/dev/null || true)
      if [[ -n "$agents" ]]; then
        echo '## Agents'
        echo "$agents"
        echo ''
      fi
    fi

    # Usage
    echo '## Usage'
    echo '`/cq` — Interactive workflow picker | `/cq <name>` — Start workflow | `/cq status` — Dashboard'
    echo '`/cq init` — Initialize project | `/cq setup` — Discover project and create workflows'
    echo '`/cq approve` — Handle pending gates | `cq workflows show <name>` — View workflow details'
  } > "$cq_md"
}
