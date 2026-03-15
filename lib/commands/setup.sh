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

  if [[ -d "${project_dir}/.claudekiq" ]]; then
    # Already initialized — update plugin.json and gitignore in case of upgrades
    _install_plugin_json "$project_dir"

    # Ensure .gitignore has workers entry
    local gitignore="${project_dir}/.gitignore"
    if [[ -f "$gitignore" ]]; then
      grep -qF '.claudekiq/workers/' "$gitignore" || echo '.claudekiq/workers/' >> "$gitignore"
    fi

    # Install MCP config only if explicitly requested
    if $install_mcp; then
      _install_mcp_config "$project_dir"
    fi

    # Auto-scan for agents and skills
    CQ_PROJECT_ROOT="$project_dir" cmd_scan >/dev/null 2>&1 || true

    # Auto-install hooks
    CQ_PROJECT_ROOT="$project_dir" _hooks_install >/dev/null 2>&1 || true

    cq_json_out --arg dir "$project_dir" '{status:"exists", directory:$dir}' || \
      cq_info "Already initialized in ${project_dir}"
    return 0
  fi

  mkdir -p "${project_dir}/.claudekiq/workflows/private"
  mkdir -p "${project_dir}/.claudekiq/runs"

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

  # Install .claude-plugin/plugin.json (points to ~/.cq/skills/)
  _install_plugin_json "$project_dir"

  # Install MCP config only if explicitly requested
  if $install_mcp; then
    _install_mcp_config "$project_dir"
  fi

  # Auto-scan for agents and skills
  CQ_PROJECT_ROOT="$project_dir" cmd_scan >/dev/null 2>&1 || true

  # Auto-install hooks
  CQ_PROJECT_ROOT="$project_dir" _hooks_install >/dev/null 2>&1 || true

  cq_json_out --arg dir "$project_dir" '{status:"initialized", directory:$dir}' || {
    cq_info "Initialized .claudekiq/ in ${project_dir}"
    cq_info "Run /cq-setup to generate customized workflows based on your project's agents and skills."
  }
}

_install_plugin_json() {
  local project_dir="$1"
  local cq_home="${HOME}/.cq"
  local plugin_dir="${project_dir}/.claude-plugin"
  mkdir -p "$plugin_dir"
  jq -cn --arg home "$cq_home" '{
    name:"claudekiq", version:"3.1.2",
    description:"Filesystem-backed workflow engine for Claude Code",
    skills:[($home+"/skills/cq"),($home+"/skills/cq-agent"),($home+"/skills/cq-workers"),($home+"/skills/cq-setup")]
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

_hooks_install() {
  local project_dir="${CQ_PROJECT_ROOT:-$PWD}"
  local settings_file="${project_dir}/.claude/settings.json"
  mkdir -p "${project_dir}/.claude"

  # Define cq hooks
  local cq_hooks
  cq_hooks=$(cat <<'HOOKS_JSON'
{
  "SessionEnd": [
    {
      "type": "command",
      "command": "cq check-stale --timeout=0 --mark 2>/dev/null || true",
      "async": true
    }
  ],
  "PreToolUse": [
    {
      "matcher": "Bash",
      "type": "command",
      "command": "bash -c 'input=$(cat); cmd=$(echo \"$input\" | jq -r \".tool_input.command // empty\"); case \"$cmd\" in *\"rm -rf .claudekiq\"*|*\"rm -rf .claudekiq/\"*|*\"rm -r .claudekiq\"*|*\"rm -r .claudekiq/\"*) echo \"Blocked: cannot delete .claudekiq directory — use cq cleanup instead\" >&2; exit 2;; *\"git checkout\"*|*\"git switch\"*) if ls .claudekiq/runs/*/meta.json 2>/dev/null | head -1 | grep -q .; then for f in .claudekiq/runs/*/meta.json; do status=$(jq -r .status \"$f\" 2>/dev/null); if [ \"$status\" = \"running\" ] || [ \"$status\" = \"gated\" ]; then echo \"Blocked: git checkout/switch while cq workflows are running/gated. Pause or cancel active runs first.\" >&2; exit 2; fi; done; fi;; *\"Edit\"*|*\"Write\"*) :;; esac; exit 0'"
    },
    {
      "matcher": "Edit",
      "type": "command",
      "command": "bash -c 'input=$(cat); path=$(echo \"$input\" | jq -r \".tool_input.file_path // empty\"); case \"$path\" in */.claudekiq/runs/*) echo \"Blocked: do not edit run files directly — use cq commands instead\" >&2; exit 2;; esac; exit 0'"
    },
    {
      "matcher": "Write",
      "type": "command",
      "command": "bash -c 'input=$(cat); path=$(echo \"$input\" | jq -r \".tool_input.file_path // empty\"); case \"$path\" in */.claudekiq/runs/*) echo \"Blocked: do not write to run files directly — use cq commands instead\" >&2; exit 2;; esac; exit 0'"
    }
  ],
  "SubagentStop": [
    {
      "type": "command",
      "command": "bash -c 'input=$(cat); desc=$(echo \"$input\" | jq -r \".description // empty\"); case \"$desc\" in Worker:*) if command -v osascript &>/dev/null; then osascript -e \"display notification \\\"$desc completed\\\" with title \\\"cq: Worker Done\\\" sound name \\\"Ping\\\"\" &>/dev/null; elif command -v notify-send &>/dev/null; then notify-send \"cq: Worker Done\" \"$desc completed\" &>/dev/null; fi;; esac; exit 0'",
      "async": true
    }
  ],
  "PostToolUse": [
    {
      "matcher": "Bash",
      "type": "command",
      "command": "bash -c 'input=$(cat); output=$(echo \"$input\" | jq -r \".stdout // empty\"); case \"$output\" in *\"step-done\"*|*\"completed\"*|*\"failed\"*|*\"gated\"*|*\"cq: \"*) if command -v osascript &>/dev/null; then msg=$(echo \"$output\" | head -1); osascript -e \"display notification \\\"$msg\\\" with title \\\"cq\\\" sound name \\\"Ping\\\"\" &>/dev/null; elif command -v notify-send &>/dev/null; then msg=$(echo \"$output\" | head -1); notify-send \"cq\" \"$msg\" &>/dev/null; fi;; esac; exit 0'",
      "async": true
    }
  ],
  "WorktreeCreate": [
    {
      "type": "command",
      "command": "bash -c 'input=$(cat); worktree_path=$(echo \"$input\" | jq -r \".worktree_path // empty\"); if [ -n \"$worktree_path\" ]; then cd \"$worktree_path\" && cq init 2>/dev/null; fi; exit 0'",
      "async": true
    }
  ]
}
HOOKS_JSON
)

  local existing='{}'
  if [[ -f "$settings_file" ]]; then
    existing=$(cat "$settings_file")
  fi

  # Merge: for each hook type, append cq hooks to existing hooks
  local updated
  updated=$(jq --argjson cq_hooks "$cq_hooks" '
    .hooks = (.hooks // {}) |
    .hooks.SessionEnd = ((.hooks.SessionEnd // []) + $cq_hooks.SessionEnd | unique_by(.command)) |
    .hooks.PreToolUse = ((.hooks.PreToolUse // []) + $cq_hooks.PreToolUse | unique_by(.command)) |
    .hooks.SubagentStop = ((.hooks.SubagentStop // []) + $cq_hooks.SubagentStop | unique_by(.command)) |
    .hooks.PostToolUse = ((.hooks.PostToolUse // []) + $cq_hooks.PostToolUse | unique_by(.command)) |
    .hooks.WorktreeCreate = ((.hooks.WorktreeCreate // []) + $cq_hooks.WorktreeCreate | unique_by(.command))
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

  # Remove cq-specific hook entries (identified by cq commands in them)
  local updated
  updated=$(jq '
    if .hooks then
      .hooks |= with_entries(
        .value |= map(select(
          (.command // "" | test("cq |cq$|\\.claudekiq")) | not
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
