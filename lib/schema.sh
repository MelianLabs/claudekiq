#!/usr/bin/env bash
# schema.sh — AI-discoverable command schemas

# Single source of truth for MCP-exposed commands (used by mcp.sh too)
cq_command_list() {
  echo "start status list log pause resume cancel retry step-done skip todos todo ctx add-step add-steps set-next workflows heartbeat check-stale cleanup workers scan for-each parallel batch"
}

cmd_schema() {
  local command="${1:-}"

  if [[ -z "$command" ]]; then
    # List all commands (MCP + meta commands)
    local mcp_cmds
    mcp_cmds=$(cq_command_list)
    local all_cmds="$mcp_cmds config init version help schema mcp"
    # Output as JSON array
    echo "$all_cmds" | tr ' ' '\n' | jq -Rcs 'split("\n") | map(select(. != ""))'
    return
  fi

  case "$command" in
    start)
      cat <<'JSON'
{
  "command": "start",
  "description": "Start a new workflow run from a template. Workflows support prompt/context fields on agent steps, params section, and model validation.",
  "usage": "cq start <template> [--key=val]...",
  "positional": ["template"],
  "parameters": [
    {"name": "template", "type": "string", "required": true, "description": "Workflow template name"},
    {"name": "--key=val", "type": "string", "required": false, "description": "Context variables (repeatable)"},
    {"name": "--priority", "type": "string", "required": false, "description": "Priority level (urgent|high|normal|low)"}
  ],
  "output": {"run_id": "string", "status": "string", "template": "string"},
  "flags": ["--json", "--headless"],
  "notes": {
    "step_fields": "Steps support: prompt (agent goal), context (list of context keys), model (opus|sonnet|haiku), resume (boolean), outputs (expected output keys)",
    "params": "Top-level params section documents workflow parameters for interactive prompting"
  },
  "examples": ["cq start feature --story_id=12345 --stack=rails", "cq start bugfix --story_id=67890 --json"]
}
JSON
      ;;
    status)
      cat <<'JSON'
{
  "command": "status",
  "description": "Show dashboard (no args) or detailed run status",
  "usage": "cq status [run_id]",
  "positional": ["run_id"],
  "parameters": [
    {"name": "run_id", "type": "string", "required": false, "description": "Run ID for detailed status"}
  ],
  "output": {"runs": "array", "todos": "array"},
  "flags": ["--json"],
  "examples": ["cq status", "cq status a1b2c3d4 --json"]
}
JSON
      ;;
    list)
      cat <<'JSON'
{
  "command": "list",
  "description": "List all workflow runs",
  "usage": "cq list",
  "positional": [],
  "parameters": [],
  "output": "array of run objects",
  "flags": ["--json"],
  "examples": ["cq list", "cq list --json"]
}
JSON
      ;;
    log)
      cat <<'JSON'
{
  "command": "log",
  "description": "Show event log for a run",
  "usage": "cq log <run_id> [--tail N]",
  "positional": ["run_id"],
  "parameters": [
    {"name": "run_id", "type": "string", "required": true, "description": "Run ID"},
    {"name": "--tail", "type": "integer", "required": false, "description": "Show last N entries"}
  ],
  "flags": ["--json"],
  "examples": ["cq log a1b2c3d4", "cq log a1b2c3d4 --tail 5"]
}
JSON
      ;;
    pause)
      cat <<'JSON'
{
  "command": "pause",
  "description": "Pause a running or queued workflow",
  "usage": "cq pause <run_id>",
  "positional": ["run_id"],
  "parameters": [
    {"name": "run_id", "type": "string", "required": true, "description": "Run ID"}
  ],
  "flags": ["--json"],
  "examples": ["cq pause a1b2c3d4"]
}
JSON
      ;;
    resume)
      cat <<'JSON'
{
  "command": "resume",
  "description": "Resume a paused workflow",
  "usage": "cq resume <run_id>",
  "positional": ["run_id"],
  "parameters": [
    {"name": "run_id", "type": "string", "required": true, "description": "Run ID"}
  ],
  "flags": ["--json"],
  "examples": ["cq resume a1b2c3d4"]
}
JSON
      ;;
    cancel)
      cat <<'JSON'
{
  "command": "cancel",
  "description": "Cancel a workflow",
  "usage": "cq cancel <run_id>",
  "positional": ["run_id"],
  "parameters": [
    {"name": "run_id", "type": "string", "required": true, "description": "Run ID"}
  ],
  "flags": ["--json"],
  "examples": ["cq cancel a1b2c3d4"]
}
JSON
      ;;
    retry)
      cat <<'JSON'
{
  "command": "retry",
  "description": "Retry a failed workflow from the failed step",
  "usage": "cq retry <run_id>",
  "positional": ["run_id"],
  "parameters": [
    {"name": "run_id", "type": "string", "required": true, "description": "Run ID (must be in failed status)"}
  ],
  "flags": ["--json"],
  "examples": ["cq retry a1b2c3d4"]
}
JSON
      ;;
    step-done)
      cat <<'JSON'
{
  "command": "step-done",
  "description": "Mark a step as complete with pass or fail outcome",
  "usage": "cq step-done <run_id> <step_id> pass|fail [result_json]",
  "positional": ["run_id", "step_id", "outcome", "result_json"],
  "parameters": [
    {"name": "run_id", "type": "string", "required": true, "description": "Run ID"},
    {"name": "step_id", "type": "string", "required": true, "description": "Step ID"},
    {"name": "outcome", "type": "string", "required": true, "description": "pass or fail"},
    {"name": "result_json", "type": "json", "required": false, "description": "JSON result data from step execution"}
  ],
  "flags": ["--json"],
  "examples": ["cq step-done a1b2c3d4 run-tests pass", "cq step-done a1b2c3d4 run-tests fail '{\"error\":\"timeout\"}'"]
}
JSON
      ;;
    skip)
      cat <<'JSON'
{
  "command": "skip",
  "description": "Skip the current or named step",
  "usage": "cq skip <run_id> [step_id]",
  "positional": ["run_id", "step_id"],
  "parameters": [
    {"name": "run_id", "type": "string", "required": true, "description": "Run ID"},
    {"name": "step_id", "type": "string", "required": false, "description": "Step ID (defaults to current step)"}
  ],
  "flags": ["--json"],
  "examples": ["cq skip a1b2c3d4", "cq skip a1b2c3d4 code-review"]
}
JSON
      ;;
    todos)
      cat <<'JSON'
{
  "command": "todos",
  "description": "List pending human actions across all runs",
  "usage": "cq todos [--flow <run_id>]",
  "positional": [],
  "parameters": [
    {"name": "--flow", "type": "string", "required": false, "description": "Filter by run ID"}
  ],
  "flags": ["--json"],
  "examples": ["cq todos", "cq todos --flow a1b2c3d4"]
}
JSON
      ;;
    todo)
      cat <<'JSON'
{
  "command": "todo",
  "description": "Resolve a pending human action",
  "usage": "cq todo <#> approve|reject|override|dismiss [--note \"...\"]",
  "positional": ["index", "action"],
  "parameters": [
    {"name": "index", "type": "integer", "required": true, "description": "TODO number from 'cq todos' list"},
    {"name": "action", "type": "string", "required": true, "description": "approve, reject, override, or dismiss"},
    {"name": "--note", "type": "string", "required": false, "description": "Optional note"}
  ],
  "flags": ["--json"],
  "examples": ["cq todo 1 approve", "cq todo 2 reject --note 'needs rework'"]
}
JSON
      ;;
    ctx)
      cat <<'JSON'
{
  "command": "ctx",
  "description": "Show, get, or set context variables for a run",
  "usage": "cq ctx <run_id> | cq ctx get <key> <run_id> | cq ctx set <key> <value> <run_id>",
  "positional": ["subcommand", "key", "value", "run_id"],
  "subcommand_param": "subcommand",
  "parameters": [
    {"name": "subcommand", "type": "string", "required": false, "description": "get or set"},
    {"name": "key", "type": "string", "required": false, "description": "Variable name"},
    {"name": "value", "type": "string", "required": false, "description": "Variable value (for set)"},
    {"name": "run_id", "type": "string", "required": true, "description": "Run ID"}
  ],
  "flags": ["--json"],
  "examples": ["cq ctx a1b2c3d4", "cq ctx get stack a1b2c3d4", "cq ctx set stack rails a1b2c3d4"]
}
JSON
      ;;
    add-step)
      cat <<'JSON'
{
  "command": "add-step",
  "description": "Add a step to a running workflow",
  "usage": "cq add-step <run_id> <step_json> [--after <step_id>]",
  "positional": ["run_id", "step_json"],
  "parameters": [
    {"name": "run_id", "type": "string", "required": true, "description": "Run ID"},
    {"name": "step_json", "type": "json", "required": true, "description": "Step definition as JSON"},
    {"name": "--after", "type": "string", "required": false, "description": "Insert after this step ID"}
  ],
  "flags": ["--json"],
  "examples": ["cq add-step a1b2c3d4 '{\"id\":\"lint\",\"type\":\"bash\",\"target\":\"npm run lint\"}' --after run-tests"]
}
JSON
      ;;
    add-steps)
      cat <<'JSON'
{
  "command": "add-steps",
  "description": "Insert steps from another workflow template",
  "usage": "cq add-steps <run_id> --flow <template> [--after <step_id>]",
  "positional": ["run_id"],
  "parameters": [
    {"name": "run_id", "type": "string", "required": true, "description": "Run ID"},
    {"name": "--flow", "type": "string", "required": true, "description": "Template name to insert from"},
    {"name": "--after", "type": "string", "required": false, "description": "Insert after this step ID"}
  ],
  "flags": ["--json"],
  "examples": ["cq add-steps a1b2c3d4 --flow deploy --after code-review"]
}
JSON
      ;;
    set-next)
      cat <<'JSON'
{
  "command": "set-next",
  "description": "Force the next step for a given step",
  "usage": "cq set-next <run_id> <step_id> <target>",
  "positional": ["run_id", "step_id", "target"],
  "parameters": [
    {"name": "run_id", "type": "string", "required": true, "description": "Run ID"},
    {"name": "step_id", "type": "string", "required": true, "description": "Step to modify"},
    {"name": "target", "type": "string", "required": true, "description": "Target step ID or 'end'"}
  ],
  "flags": ["--json"],
  "examples": ["cq set-next a1b2c3d4 run-tests deploy"]
}
JSON
      ;;
    workflows)
      cat <<'JSON'
{
  "command": "workflows",
  "description": "Manage workflow templates",
  "usage": "cq workflows list|show|validate",
  "positional": ["subcommand", "name"],
  "subcommand_param": "subcommand",
  "subcommands": [
    {"name": "list", "description": "List available workflow templates"},
    {"name": "show", "description": "Show template details", "args": ["name"]},
    {"name": "validate", "description": "Validate a workflow YAML file", "args": ["file"]}
  ],
  "parameters": [
    {"name": "subcommand", "type": "string", "required": false, "description": "list, show, or validate"},
    {"name": "name", "type": "string", "required": false, "description": "Workflow name or file path"}
  ],
  "flags": ["--json"],
  "examples": ["cq workflows list", "cq workflows show feature", "cq workflows validate my-workflow.yml"]
}
JSON
      ;;
    config)
      cat <<'JSON'
{
  "command": "config",
  "description": "View or modify configuration",
  "usage": "cq config | cq config get <key> | cq config set [--global] <key> <value>",
  "subcommands": [
    {"name": "get", "description": "Get a config value", "args": ["key"]},
    {"name": "set", "description": "Set a config value", "args": ["key", "value"]}
  ],
  "flags": ["--json", "--global"],
  "examples": ["cq config", "cq config get concurrency", "cq config set concurrency 3"]
}
JSON
      ;;
    init)
      cat <<'JSON'
{
  "command": "init",
  "description": "Initialize .claudekiq/ in the current project",
  "usage": "cq init [--mcp]",
  "positional": [],
  "parameters": [
    {"name": "--mcp", "type": "boolean", "required": false, "description": "Also install MCP server config into .mcp.json"}
  ],
  "flags": ["--json", "--mcp"],
  "examples": ["cq init", "cq init --mcp"]
}
JSON
      ;;
    schema)
      cat <<'JSON'
{
  "command": "schema",
  "description": "Show command schema for AI discoverability",
  "usage": "cq schema [command]",
  "positional": ["command"],
  "parameters": [
    {"name": "command", "type": "string", "required": false, "description": "Command name (omit for list)"}
  ],
  "examples": ["cq schema", "cq schema start"]
}
JSON
      ;;
    cleanup)
      cat <<'JSON'
{
  "command": "cleanup",
  "description": "Remove expired workflow runs",
  "usage": "cq cleanup",
  "positional": [],
  "parameters": [],
  "flags": ["--json"],
  "examples": ["cq cleanup"]
}
JSON
      ;;
    version)
      cat <<'JSON'
{
  "command": "version",
  "description": "Show cq version",
  "usage": "cq version",
  "positional": [],
  "parameters": [],
  "flags": ["--json"],
  "examples": ["cq version"]
}
JSON
      ;;
    help)
      cat <<'JSON'
{
  "command": "help",
  "description": "Show help text",
  "usage": "cq help [command]",
  "positional": ["command"],
  "parameters": [
    {"name": "command", "type": "string", "required": false, "description": "Command name for specific help"}
  ],
  "examples": ["cq help", "cq help start"]
}
JSON
      ;;
    heartbeat)
      cat <<'JSON'
{
  "command": "heartbeat",
  "description": "Write a heartbeat timestamp for a running workflow",
  "usage": "cq heartbeat <run_id>",
  "positional": ["run_id"],
  "parameters": [
    {"name": "run_id", "type": "string", "required": true, "description": "Run ID"}
  ],
  "flags": ["--json"],
  "examples": ["cq heartbeat a1b2c3d4"]
}
JSON
      ;;
    check-stale)
      cat <<'JSON'
{
  "command": "check-stale",
  "description": "Detect running workflows with stale heartbeats",
  "usage": "cq check-stale [--timeout=N] [--mark]",
  "positional": [],
  "parameters": [
    {"name": "--timeout", "type": "integer", "required": false, "description": "Seconds before a heartbeat is considered stale (default: 120)"},
    {"name": "--mark", "type": "boolean", "required": false, "description": "Mark stale runs as blocked"}
  ],
  "flags": ["--json", "--mark"],
  "examples": ["cq check-stale", "cq check-stale --timeout=60 --mark --json"]
}
JSON
      ;;
    mcp)
      cat <<'JSON'
{
  "command": "mcp",
  "description": "Start MCP (Model Context Protocol) stdio server — exposes all cq commands as Claude Code plugin tools",
  "usage": "cq mcp",
  "positional": [],
  "parameters": [],
  "examples": ["cq mcp", "claude mcp add --transport stdio cq -- cq mcp"]
}
JSON
      ;;
    scan)
      cat <<'JSON'
{
  "command": "scan",
  "description": "Scan project for available agents, skills, plugins, and stack info. Writes results to .claudekiq/settings.json",
  "usage": "cq scan",
  "positional": [],
  "parameters": [],
  "output": {"agents": "array", "skills": "array", "plugins": "array", "stack": "object", "scanned_at": "string"},
  "flags": ["--json"],
  "examples": ["cq scan", "cq scan --json"]
}
JSON
      ;;
    workers)
      cat <<'JSON'
{
  "command": "workers",
  "description": "Parallel worker orchestration — manage worker sessions for concurrent workflow execution",
  "usage": "cq workers <init|status|answer|cleanup>",
  "positional": ["subcommand", "session_id", "job_id", "action", "data"],
  "subcommand_param": "subcommand",
  "parameters": [
    {"name": "subcommand", "type": "string", "required": false, "description": "init, status, answer, or cleanup"},
    {"name": "session_id", "type": "string", "required": false, "description": "Worker session ID"},
    {"name": "job_id", "type": "string", "required": false, "description": "Job ID"},
    {"name": "action", "type": "string", "required": false, "description": "Action: approve or reject"},
    {"name": "data", "type": "json", "required": false, "description": "Optional JSON data"}
  ],
  "flags": ["--json"],
  "examples": [
    "cq workers init --json",
    "cq workers status abc12345 --json",
    "cq workers answer abc12345 BUG-1 approve",
    "cq workers cleanup --max-age=86400"
  ]
}
JSON
      ;;
    for-each)
      cat <<'JSON'
{
  "command": "for-each",
  "description": "Iterate over a list, executing a command or sub-step for each item",
  "usage": "cq for-each --over=<list> --var=<name> --command=<cmd> | cq for-each <run_id> <step_id>",
  "positional": ["run_id", "step_id"],
  "parameters": [
    {"name": "--over", "type": "string", "required": false, "description": "Comma-separated list to iterate over"},
    {"name": "--delimiter", "type": "string", "required": false, "description": "List delimiter (default: ,)"},
    {"name": "--var", "type": "string", "required": false, "description": "Variable name for each item (default: item)"},
    {"name": "--command", "type": "string", "required": false, "description": "Command to run with {{var}} interpolation"},
    {"name": "run_id", "type": "string", "required": false, "description": "Run ID (workflow mode)"},
    {"name": "step_id", "type": "string", "required": false, "description": "Step ID (workflow mode)"}
  ],
  "flags": ["--json"],
  "examples": ["cq for-each --over='a,b,c' --var=x --command='echo {{x}}'", "cq for-each abc12345 iterate"]
}
JSON
      ;;
    parallel)
      cat <<'JSON'
{
  "command": "parallel",
  "description": "Execute multiple sub-steps concurrently",
  "usage": "cq parallel --steps=<json_array> | cq parallel <run_id> <step_id>",
  "positional": ["run_id", "step_id"],
  "parameters": [
    {"name": "--steps", "type": "json", "required": false, "description": "JSON array of step definitions"},
    {"name": "--fail-strategy", "type": "string", "required": false, "description": "wait_all or fail_fast (default: wait_all)"},
    {"name": "run_id", "type": "string", "required": false, "description": "Run ID (workflow mode)"},
    {"name": "step_id", "type": "string", "required": false, "description": "Step ID (workflow mode)"}
  ],
  "flags": ["--json"],
  "examples": ["cq parallel --steps='[{\"type\":\"bash\",\"target\":\"echo a\"},{\"type\":\"bash\",\"target\":\"echo b\"}]'"]
}
JSON
      ;;
    batch)
      cat <<'JSON'
{
  "command": "batch",
  "description": "Create a worker session for batch processing jobs",
  "usage": "cq batch --workflow=<name> --jobs=<json_array> | cq batch <run_id> <step_id>",
  "positional": ["run_id", "step_id"],
  "parameters": [
    {"name": "--workflow", "type": "string", "required": false, "description": "Workflow template name"},
    {"name": "--jobs", "type": "json", "required": false, "description": "JSON array of job definitions"},
    {"name": "run_id", "type": "string", "required": false, "description": "Run ID (workflow mode)"},
    {"name": "step_id", "type": "string", "required": false, "description": "Step ID (workflow mode)"}
  ],
  "flags": ["--json"],
  "examples": ["cq batch --workflow=bugfix --jobs='[{\"id\":\"BUG-1\",\"description\":\"fix login\"}]'"]
}
JSON
      ;;
    *)
      cq_die "Unknown command: ${command}"
      ;;
  esac
}
