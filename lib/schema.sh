#!/usr/bin/env bash
# schema.sh — AI-discoverable command schemas (compact data-driven registry)

# Single source of truth for MCP-exposed commands (used by mcp.sh too)
cq_command_list() {
  echo "start status list log pause resume cancel retry step-done skip todos todo ctx add-step add-steps set-next workflows heartbeat check-stale cleanup scan hooks"
}

# Compact schema data for all commands.
# Keys: d=description, u=usage, p=positional, a=args (tuples: [name,type,required,desc]),
#        f=flags, e=examples, s=subcommands
_cq_schema_data() {
  cat <<'SCHEMA'
{
  "start":{"d":"Start a new workflow run from a template. Workflows support prompt/context fields on agent steps, params section, and model validation.","u":"cq start <template> [--key=val]...","p":["template"],"a":[["template","string",true,"Workflow template name"],["--key=val","string",false,"Context variables (repeatable)"],["--priority","string",false,"Priority level (urgent|high|normal|low)"]],"f":["--json","--headless"],"e":["cq start feature --story_id=12345 --stack=rails","cq start bugfix --story_id=67890 --json"],"n":{"step_fields":"Steps support: prompt (agent goal), context (list of context keys), model (opus|sonnet|haiku), resume (boolean), outputs (expected output keys)","params":"Top-level params section documents workflow parameters for interactive prompting"}},
  "status":{"d":"Show dashboard (no args) or detailed run status","u":"cq status [run_id]","p":["run_id"],"a":[["run_id","string",false,"Run ID for detailed status"]],"f":["--json"],"e":["cq status","cq status a1b2c3d4 --json"]},
  "list":{"d":"List all workflow runs","u":"cq list","p":[],"a":[],"f":["--json"],"e":["cq list","cq list --json"]},
  "log":{"d":"Show event log for a run","u":"cq log <run_id> [--tail N]","p":["run_id"],"a":[["run_id","string",true,"Run ID"],["--tail","integer",false,"Show last N entries"]],"f":["--json"],"e":["cq log a1b2c3d4","cq log a1b2c3d4 --tail 5"]},
  "pause":{"d":"Pause a running or queued workflow","u":"cq pause <run_id>","p":["run_id"],"a":[["run_id","string",true,"Run ID"]],"f":["--json"],"e":["cq pause a1b2c3d4"]},
  "resume":{"d":"Resume a paused workflow","u":"cq resume <run_id>","p":["run_id"],"a":[["run_id","string",true,"Run ID"]],"f":["--json"],"e":["cq resume a1b2c3d4"]},
  "cancel":{"d":"Cancel a workflow","u":"cq cancel <run_id>","p":["run_id"],"a":[["run_id","string",true,"Run ID"]],"f":["--json"],"e":["cq cancel a1b2c3d4"]},
  "retry":{"d":"Retry a failed workflow from the failed step","u":"cq retry <run_id>","p":["run_id"],"a":[["run_id","string",true,"Run ID (must be in failed status)"]],"f":["--json"],"e":["cq retry a1b2c3d4"]},
  "step-done":{"d":"Mark a step as complete with pass or fail outcome","u":"cq step-done <run_id> <step_id> pass|fail [result_json]","p":["run_id","step_id","outcome","result_json"],"a":[["run_id","string",true,"Run ID"],["step_id","string",true,"Step ID"],["outcome","string",true,"pass or fail"],["result_json","json",false,"JSON result data from step execution"]],"f":["--json"],"e":["cq step-done a1b2c3d4 run-tests pass","cq step-done a1b2c3d4 run-tests fail '{\"error\":\"timeout\"}'"]},
  "skip":{"d":"Skip the current or named step","u":"cq skip <run_id> [step_id]","p":["run_id","step_id"],"a":[["run_id","string",true,"Run ID"],["step_id","string",false,"Step ID (defaults to current step)"]],"f":["--json"],"e":["cq skip a1b2c3d4","cq skip a1b2c3d4 code-review"]},
  "todos":{"d":"List pending human actions across all runs. Subcommands: sync (output in native TodoWrite format), apply-sync (accept resolutions from stdin)","u":"cq todos [sync|apply-sync] [--flow <run_id>]","p":["subcommand"],"sc":"subcommand","s":[{"name":"sync","description":"Output pending TODOs in Claude Code TodoWrite-compatible format for bidirectional sync"},{"name":"apply-sync","description":"Accept JSON resolutions from stdin and apply to filesystem TODOs"}],"a":[["subcommand","string",false,"sync or apply-sync"],["--flow","string",false,"Filter by run ID"]],"f":["--json"],"e":["cq todos","cq todos --flow a1b2c3d4","cq todos sync --json","echo '{\"resolutions\":[...]}' | cq todos apply-sync"]},
  "todo":{"d":"Resolve a pending human action","u":"cq todo <#> approve|reject|override|dismiss [--note \"...\"]","p":["index","action"],"a":[["index","integer",true,"TODO number from 'cq todos' list"],["action","string",true,"approve, reject, override, or dismiss"],["--note","string",false,"Optional note"]],"f":["--json"],"e":["cq todo 1 approve","cq todo 2 reject --note 'needs rework'"]},
  "ctx":{"d":"Show, get, or set context variables for a run","u":"cq ctx <run_id> | cq ctx get <key> <run_id> | cq ctx set <key> <value> <run_id>","p":["subcommand","key","value","run_id"],"sc":"subcommand","a":[["subcommand","string",false,"get or set"],["key","string",false,"Variable name"],["value","string",false,"Variable value (for set)"],["run_id","string",true,"Run ID"]],"f":["--json"],"e":["cq ctx a1b2c3d4","cq ctx get stack a1b2c3d4","cq ctx set stack rails a1b2c3d4"]},
  "add-step":{"d":"Add a step to a running workflow","u":"cq add-step <run_id> <step_json> [--after <step_id>]","p":["run_id","step_json"],"a":[["run_id","string",true,"Run ID"],["step_json","json",true,"Step definition as JSON"],["--after","string",false,"Insert after this step ID"]],"f":["--json"],"e":["cq add-step a1b2c3d4 '{\"id\":\"lint\",\"type\":\"bash\",\"target\":\"npm run lint\"}' --after run-tests"]},
  "add-steps":{"d":"Insert steps from another workflow template","u":"cq add-steps <run_id> --flow <template> [--after <step_id>]","p":["run_id"],"a":[["run_id","string",true,"Run ID"],["--flow","string",true,"Template name to insert from"],["--after","string",false,"Insert after this step ID"]],"f":["--json"],"e":["cq add-steps a1b2c3d4 --flow deploy --after code-review"]},
  "set-next":{"d":"Force the next step for a given step","u":"cq set-next <run_id> <step_id> <target>","p":["run_id","step_id","target"],"a":[["run_id","string",true,"Run ID"],["step_id","string",true,"Step to modify"],["target","string",true,"Target step ID or 'end'"]],"f":["--json"],"e":["cq set-next a1b2c3d4 run-tests deploy"]},
  "workflows":{"d":"Manage workflow templates","u":"cq workflows list|show|validate","p":["subcommand","name"],"sc":"subcommand","s":[{"name":"list","description":"List available workflow templates"},{"name":"show","description":"Show template details","args":["name"]},{"name":"validate","description":"Validate a workflow YAML file","args":["file"]}],"a":[["subcommand","string",false,"list, show, or validate"],["name","string",false,"Workflow name or file path"]],"f":["--json"],"e":["cq workflows list","cq workflows show feature","cq workflows validate my-workflow.yml"]},
  "config":{"d":"View or modify configuration","u":"cq config | cq config get <key> | cq config set [--global] <key> <value>","p":[],"s":[{"name":"get","description":"Get a config value","args":["key"]},{"name":"set","description":"Set a config value","args":["key","value"]}],"a":[],"f":["--json","--global"],"e":["cq config","cq config get concurrency","cq config set concurrency 3"]},
  "init":{"d":"Initialize .claudekiq/ in the current project","u":"cq init [--mcp]","p":[],"a":[["--mcp","boolean",false,"Also install MCP server config into .mcp.json"]],"f":["--json","--mcp"],"e":["cq init","cq init --mcp"]},
  "schema":{"d":"Show command schema for AI discoverability","u":"cq schema [command]","p":["command"],"a":[["command","string",false,"Command name (omit for list)"]],"f":[],"e":["cq schema","cq schema start"]},
  "cleanup":{"d":"Remove expired workflow runs","u":"cq cleanup","p":[],"a":[],"f":["--json"],"e":["cq cleanup"]},
  "version":{"d":"Show cq version","u":"cq version","p":[],"a":[],"f":["--json"],"e":["cq version"]},
  "help":{"d":"Show help text","u":"cq help [command]","p":["command"],"a":[["command","string",false,"Command name for specific help"]],"f":[],"e":["cq help","cq help start"]},
  "heartbeat":{"d":"Write a heartbeat timestamp for a running workflow","u":"cq heartbeat <run_id>","p":["run_id"],"a":[["run_id","string",true,"Run ID"]],"f":["--json"],"e":["cq heartbeat a1b2c3d4"]},
  "check-stale":{"d":"Detect running workflows with stale heartbeats","u":"cq check-stale [--timeout=N] [--mark]","p":[],"a":[["--timeout","integer",false,"Seconds before a heartbeat is considered stale (default: 120)"],["--mark","boolean",false,"Mark stale runs as blocked"]],"f":["--json","--mark"],"e":["cq check-stale","cq check-stale --timeout=60 --mark --json"]},
  "mcp":{"d":"Start MCP (Model Context Protocol) stdio server — exposes all cq commands as Claude Code plugin tools","u":"cq mcp","p":[],"a":[],"f":[],"e":["cq mcp","claude mcp add --transport stdio cq -- cq mcp"]},
  "scan":{"d":"Scan project for available agents, skills (including plugin.json-discovered skills), and stacks. Writes results to .claudekiq/settings.json","u":"cq scan","p":[],"a":[],"f":["--json"],"e":["cq scan","cq scan --json"]},
  "hooks":{"d":"Manage cq hooks in .claude/settings.json","u":"cq hooks <install|uninstall>","p":["subcommand"],"sc":"subcommand","s":[{"name":"install","description":"Merge cq hooks into .claude/settings.json"},{"name":"uninstall","description":"Remove cq hooks from .claude/settings.json"}],"a":[["subcommand","string",true,"install or uninstall"]],"f":["--json"],"e":["cq hooks install","cq hooks uninstall"]}
}
SCHEMA
}

cmd_schema() {
  local command="${1:-}"

  if [[ -z "$command" ]]; then
    # List all commands (MCP + meta commands)
    local mcp_cmds
    mcp_cmds=$(cq_command_list)
    local all_cmds="$mcp_cmds config init version help schema mcp"
    echo "$all_cmds" | tr ' ' '\n' | jq -Rcs 'split("\n") | map(select(. != ""))'
    return
  fi

  local data
  data=$(_cq_schema_data)

  # Expand compact format to full JSON (backward compatible)
  jq -e --arg cmd "$command" '.[$cmd]' <<< "$data" >/dev/null 2>&1 || cq_die "Unknown command: ${command}"

  jq --arg cmd "$command" '
    .[$cmd] | {
      command: $cmd,
      description: .d,
      usage: .u,
      positional: .p
    }
    + (if .sc then {subcommand_param: .sc} else {} end)
    + (if .s then {subcommands: .s} else {} end)
    + {
      parameters: [.a[] | {name: .[0], type: .[1], required: .[2], description: .[3]}]
    }
    + (if .n then {notes: .n} else {} end)
    + (if .f and (.f | length > 0) then {flags: .f} else {} end)
    + {examples: .e}
  ' <<< "$data"
}
