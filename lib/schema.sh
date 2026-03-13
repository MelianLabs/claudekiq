#!/usr/bin/env bash
# schema.sh — AI-discoverable command schemas

cmd_schema() {
  local command="${1:-}"

  if [[ -z "$command" ]]; then
    # List all commands
    cat <<'JSON'
["start","status","list","log","pause","resume","cancel","retry","step-done","skip","todos","todo","ctx","add-step","add-steps","set-next","workflows","config","init","version","help","schema","cleanup"]
JSON
    return
  fi

  case "$command" in
    start)
      cat <<'JSON'
{
  "command": "start",
  "description": "Start a new workflow run from a template",
  "usage": "cq start <template> [--key=val]...",
  "parameters": [
    {"name": "template", "type": "string", "required": true, "description": "Workflow template name"},
    {"name": "--key=val", "type": "string", "required": false, "description": "Context variables (repeatable)"},
    {"name": "--priority", "type": "string", "required": false, "description": "Priority level (urgent|high|normal|low)"}
  ],
  "output": {"run_id": "string", "status": "string", "template": "string"},
  "flags": ["--json", "--headless"],
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
  "subcommands": [
    {"name": "list", "description": "List available workflow templates"},
    {"name": "show", "description": "Show template details", "args": ["name"]},
    {"name": "validate", "description": "Validate a workflow YAML file", "args": ["file"]}
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
  "usage": "cq init",
  "parameters": [],
  "flags": ["--json"],
  "examples": ["cq init"]
}
JSON
      ;;
    schema)
      cat <<'JSON'
{
  "command": "schema",
  "description": "Show command schema for AI discoverability",
  "usage": "cq schema [command]",
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
  "parameters": [
    {"name": "command", "type": "string", "required": false, "description": "Command name for specific help"}
  ],
  "examples": ["cq help", "cq help start"]
}
JSON
      ;;
    *)
      cq_die "Unknown command: ${command}"
      ;;
  esac
}
