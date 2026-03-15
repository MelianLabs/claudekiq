# Technical Details — claudekiq (`cq`)

## 1. Overview

`cq` is a single-file Bash CLI that orchestrates multi-step development workflows for Claude Code. It stores all state on the filesystem (no Redis, no database). It is installed globally and configured per-project.

Dependencies: `bash`, `jq`, `date`, `uuidgen` (or `/proc/sys/kernel/random/uuid` fallback on Linux).

---

## 2. Installation

Single curl command installs the `cq` script to `~/.cq/bin/cq` and creates the global config directory:

```bash
curl -fsSL https://raw.githubusercontent.com/MelianLabs/claudekiq/main/install.sh | bash
```

The install script:
1. Creates `~/.cq/bin/`, `~/.cq/workflows/`, `~/.cq/config.json`
2. Downloads the `cq` script to `~/.cq/bin/cq`, makes it executable
3. Prints instructions to add `~/.cq/bin` to `$PATH` (detects bash/zsh/fish)
4. Runs `cq version` to confirm

Uninstall: `rm -rf ~/.cq` and remove the PATH entry.

### Versioning

`cq` is versioned independently (semver). The version is embedded in the script as `CQ_VERSION="x.y.z"`. Projects pin a minimum version in `.claudekiq/settings.json` via `"min_cq_version": "1.2.0"`. On every invocation, `cq` checks and warns if the installed version is below the project minimum.

---

## 3. Directory Layout

### Global (`~/.cq/`)

```
~/.cq/
  bin/cq                    # The CLI script
  config.json               # Global defaults (TTL, priorities, etc.)
  workflows/                # Shared workflow templates available to all projects
    deploy-staging.yml
    hotfix.yml
```

### Per-project (`.claudekiq/`)

```
.claudekiq/
  settings.json             # Project config (overrides global)
  workflows/                # Project workflows (committed to repo)
    feature.yml
    bugfix.yml
    private/                # Private workflows (gitignored)
      my-experiment.yml
  runs/                     # Active and completed workflow runs (gitignored)
    <run_id>/
      meta.json             # Run metadata (template, status, timestamps, priority)
      ctx.json              # Context variables (key-value)
      steps.json            # Step definitions (ordered array)
      state.json            # Step states (status, visits, attempt, result per step)
      log.jsonl             # Event log (append-only, one JSON object per line)
  workers/                  # Worker session coordination (gitignored)
    <session_id>/
      manifest.json         # Session metadata
      <job_id>.status.json  # Written by child worker
      <job_id>.answer.json  # Written by parent (gate responses)
  plugins/                  # Custom step type handlers (optional)
    docker.sh
```

### Gitignore

`cq init` appends to `.gitignore`:

```
.claudekiq/workflows/private/
.claudekiq/runs/
.claudekiq/workers/
```

---

## 4. Configuration

### `config.json` schema (global and project-level)

```jsonc
{
  // Namespace prefix for display and log messages
  "prefix": "cq",

  // How long completed runs are kept before cleanup (seconds)
  "ttl": 2592000,

  // Priority levels (ordered highest to lowest)
  "priorities": ["urgent", "high", "normal", "low"],

  // Default priority for new runs
  "default_priority": "normal",

  // Max concurrent workflow runs
  "concurrency": 1,

  // Status display markers
  "markers": {
    "passed": "✅", "failed": "❌", "running": "🔄",
    "gated": "⏸️", "skipped": "⏭️", "pending": "⬚",
    "queued": "📋", "paused": "⏯️", "cancelled": "🚫"
  },

  // Step fields recognized in workflow YAML
  "step_fields": ["name", "type", "target", "prompt", "context", "args_template", "gate", "model", "background", "resume", "outputs"],

  // Known AI models for validation
  "models": ["opus", "sonnet", "haiku"],

  // Default model for agent steps without explicit model
  "default_model": "opus",

  // Edge keys for routing
  "edge_keys": ["next", "on_pass", "on_fail"],

  // Notification hooks (bash commands, executed on events)
  "notifications": {
    "on_gate": null,
    "on_fail": null,
    "on_complete": null
  },

  // Minimum cq version required (project-level only)
  "min_cq_version": null
}
```

### Resolution order

1. Built-in defaults (hardcoded in `cq`)
2. Global config (`~/.cq/config.json`)
3. Project config (`.claudekiq/settings.json`)

Project values override global values. Arrays and objects are **replaced**, not merged (keep it simple).

### `cq config` command

```bash
cq config                      # Show resolved config (merged)
cq config get <key>            # Get a single value
cq config set <key> <value>    # Set in project config
cq config set --global <key> <value>  # Set in global config
```

---

## 5. Workflow Definition Format

Workflows are YAML files with support for `prompt:`, `context:`, `params:`, `model:`, and `resume:` fields for goal-oriented agent orchestration.

```yaml
name: example
description: Example workflow

# Documented workflow parameters (used by /cq skill for interactive prompting)
params:
  description: "What to build"
  branch_name: "Feature branch name"

# Context variable defaults (overridable at start time via --key=val)
defaults:
  description: ""
  branch_name: ""

steps:
  - id: plan
    name: Plan Implementation
    type: agent
    prompt: "Plan implementation for: {{description}}. Identify files, approach, and risks."
    context: [description]           # context keys injected into agent prompt
    gate: human
    model: sonnet                    # validated against known models

  - id: create-branch
    name: Create Branch
    type: bash
    target: "git checkout -b feature/{{branch_name}} main"
    gate: auto

  - id: implement
    name: Implement
    type: agent
    target: "@implementer"           # spawns specific agent
    prompt: "Implement the plan. All tests must pass."
    context: [description, plan_output]
    gate: review
    max_visits: 3
    model: opus
    resume: true                     # opt-in agent resume on retry

  - id: run-tests
    name: Run Tests
    type: bash
    target: "{{test_command}}"
    gate: review
    max_visits: 5
    on_pass: code-review
    on_fail: implement

  - id: code-review
    name: Code Review
    type: manual
    description: "Review changes"
    gate: human

# Conditional routing (evaluated after step completion)
routing:
  plan:
    - when: "{{issue_type}} == bug"
      goto: investigate
    - when: "{{issue_type}} == feature"
      goto: create-branch
```

### Step Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique step identifier (required) |
| `name` | string | Human-readable name |
| `type` | string | Step type: `agent`, `bash`, `skill`, `manual`, `subflow`, `for_each`, `parallel`, `batch`, or custom |
| `prompt` | string | Goal description for agent steps. Supports `{{interpolation}}` |
| `context` | array | List of context keys to inject into agent prompt |
| `target` | string | Command (bash), agent name (`@name`), skill name, or workflow name |
| `args_template` | string | **Deprecated** — use `prompt` instead |
| `gate` | string | `auto`, `human`, or `review` |
| `model` | string | AI model: `opus`, `sonnet`, `haiku` |
| `resume` | boolean | If true, agent can be resumed on retry (stores agentId) |
| `outputs` | object | Expected output keys for structured result extraction |
| `max_visits` | integer | Max retry visits for `review` gate |
| `background` | boolean | Run step in background |
| `on_pass` / `on_fail` / `next` | string | Routing edges |

### Step types

| Type | `target` is | Execution |
|------|-------------|-----------|
| `agent` | Agent name (e.g., `@rails-dev`) or omitted | Claude Code Agent tool. Uses `prompt:` for goals. |
| `skill` | Skill name (e.g., `/lt`) | Claude Code Skill tool |
| `bash` | Shell command | Bash execution |
| `manual` | — (uses `description`) | Creates human action, waits |
| `subflow` | Workflow name | Inserts steps from another workflow |
| custom | Defined by plugin | Runs `.claudekiq/plugins/<type>.sh` |

### Custom step type plugins

A plugin is a bash script in `.claudekiq/plugins/<type>.sh` that receives step data as JSON on stdin and must exit 0 (pass) or non-zero (fail). Stdout is captured as step output.

```bash
#!/usr/bin/env bash
# .claudekiq/plugins/docker.sh
step=$(cat)
image=$(echo "$step" | jq -r '.target')
args=$(echo "$step" | jq -r '.args')
docker run --rm "$image" $args
```

---

## 6. Filesystem State Storage

### Run directory: `.claudekiq/runs/<run_id>/`

Each run gets a directory named with an 8-character short UUID (e.g., `a1b2c3d4`).

#### `meta.json`

```json
{
  "id": "a1b2c3d4",
  "template": "feature",
  "status": "running",
  "priority": "normal",
  "created_at": "2026-03-13T10:00:00Z",
  "updated_at": "2026-03-13T10:05:00Z",
  "current_step": "implement",
  "started_by": "user",
  "params": {
    "description": "What to build",
    "branch_name": "Feature branch name"
  }
}
```

The `params` field is present when the workflow defines a `params:` section. It documents workflow parameters for interactive prompting by the `/cq` skill.

Status values: `queued`, `running`, `paused`, `completed`, `failed`, `cancelled`.

#### `ctx.json`

```json
{
  "story_id": "12345",
  "project_id": "67",
  "stack": "rails",
  "story_type": "feature",
  "branch_name": "feature/add-login"
}
```

#### `steps.json`

Array of step definitions copied from the workflow template at start time (plus any dynamically added steps). This is the ordered list — position determines default execution order.

#### `state.json`

```json
{
  "read-story": { "status": "passed", "visits": 1, "attempt": 1, "result": "pass", "started_at": "...", "finished_at": "..." },
  "implement": { "status": "running", "visits": 2, "attempt": 2, "result": null, "started_at": "...", "finished_at": null }
}
```

#### `log.jsonl`

Append-only event log. One JSON object per line:

```jsonl
{"ts":"2026-03-13T10:00:00Z","event":"run_started","data":{"template":"feature"}}
{"ts":"2026-03-13T10:00:01Z","event":"step_started","data":{"step":"read-story"}}
{"ts":"2026-03-13T10:00:05Z","event":"step_done","data":{"step":"read-story","result":"pass"}}
{"ts":"2026-03-13T10:00:05Z","event":"gate_auto","data":{"step":"read-story","next":"implement"}}
```

### Locking

File-based locking to prevent concurrent modifications:

```
.claudekiq/runs/<run_id>/.lock
```

Use `flock` (Linux) or `shlock` (macOS) with a timeout. If lock can't be acquired in 5 seconds, abort with error.

### Cleanup

`cq cleanup` removes run directories older than the configured TTL. Can be run manually or via cron. `cq` does NOT auto-cleanup on every invocation (avoid filesystem scanning overhead).

---

## 7. CLI Commands

### Invocation

```
cq <command> [subcommand] [args] [flags]
```

All commands support `--json` flag for machine-readable JSON output (default is human-friendly with markers/tables).

### Command Reference

```
Workflow lifecycle:
  cq start <template> [--key=val]...   Start a new workflow run
  cq status [run_id]                   Dashboard (no args) or run detail
  cq list                              List all active runs
  cq log <run_id>                      Show event log for a run

Flow control:
  cq pause <run_id>                    Pause a running workflow
  cq resume <run_id>                   Resume a paused workflow
  cq cancel <run_id>                   Cancel a workflow

Step control:
  cq step-done <run_id> <step_id> pass|fail    Mark step complete
  cq skip <run_id> [step_id]                   Skip current/named step
  cq retry <run_id> [step_id]                  Retry current/named step

Human actions:
  cq todos                             List pending human actions
  cq todo <#> approve|reject|override|dismiss   Resolve a human action

Context:
  cq ctx <run_id>                      Show all context variables
  cq ctx get <key> <run_id>            Get a context variable
  cq ctx set <key> <value> <run_id>    Set a context variable

Dynamic modification:
  cq add-step <run_id> <step_json> [--after <step_id>]
  cq add-steps <run_id> --flow <template> [--after <step_id>]
  cq set-next <run_id> <step_id>       Force next step

Template management:
  cq workflows list                    List available templates
  cq workflows show <name>             Show template details
  cq workflows validate <file>         Validate a workflow YAML

Configuration:
  cq config                            Show resolved config
  cq config get <key>                  Get config value
  cq config set <key> <value>          Set project config value
  cq config set --global <key> <value> Set global config value

Setup:
  cq init                              Initialize .claudekiq/ in current project
  cq version                           Show version
  cq help [command]                    Show help
  cq schema [command]                  Show command schema (JSON, for AI agents)

Workers (parallel orchestration):
  cq workers init                      Create a new worker session
  cq workers status <session_id>       Show status of all workers in a session
  cq workers answer <sid> <jid> <action> [data]  Answer a gated worker
  cq workers cleanup [--max-age=N]     Remove old worker sessions

Maintenance:
  cq cleanup                           Remove expired runs
```

### Queuing

When `concurrency` is set and there are more runs than slots:

- `cq start` creates the run in `queued` status
- The runner picks up queued runs by priority order (urgent first)
- `cq status` shows both running and queued workflows

Queue is implemented by reading all `meta.json` files, filtering by status, and sorting by priority + creation time. No separate queue data structure needed — the filesystem IS the queue.

---

## 8. Schema / AI Discoverability

Following the `lt schema` pattern, `cq schema` provides self-describing command metadata:

```bash
$ cq schema
["start","status","list","log","pause","resume","cancel","step-done","skip",
 "retry","todos","todo","ctx","add-step","workflows","config","init","schema"]

$ cq schema start
{
  "command": "start",
  "description": "Start a new workflow run from a template",
  "usage": "cq start <template> [--key=val]...",
  "parameters": [
    {"name": "template", "type": "string", "required": true, "description": "Workflow template name"},
    {"name": "--key=val", "type": "string", "required": false, "description": "Context variables (repeatable)"}
  ],
  "output": {
    "run_id": "string",
    "status": "string",
    "template": "string"
  },
  "flags": ["--json"],
  "examples": [
    "cq start feature --story_id=12345 --stack=rails",
    "cq start bugfix --story_id=67890 --json"
  ]
}
```

This lets Claude Code agents call `cq schema` to discover available commands and `cq schema <cmd>` to learn exact parameters before invoking.

---

## 9. Runner Loop (Claude Code Integration)

The runner is the bridge between `cq` (state management) and Claude Code (execution). It is split into two skills:

### `/cq` skill — Slim State Machine (~120 lines)

```
READ STATE → CHECK TERMINAL → CHECK GATES → DISPATCH STEP → EXTRACT RESULTS → ADVANCE → LOOP
```

Dispatch by step type:
- `bash` → Run command via Bash tool. Exit code = outcome.
- `agent` → Invoke `/cq-agent` sub-skill with step JSON. AI evaluates results.
- `skill` → Invoke Skill tool with target name.
- `manual` → Display description, gate system creates TODO.
- `subflow` → `cq add-steps`.
- `for_each`/`parallel`/`batch` → CLI for bash children, `/cq-agent` for agent children.
- Custom type → Resolve via `cq_resolve_step_type`, dispatch accordingly.

### `/cq-agent` sub-skill — Agent Step Handler

Handles a single agent step autonomously:

1. Receive step definition (prompt, context keys, model, target, resume flag)
2. Build agent prompt via `cq_build_step_prompt`: assemble `prompt:` + resolved `context:` variables
3. Spawn Agent tool with model, target, and assembled prompt
4. If `resume: true` and saved agentId exists, try `Agent(resume: <id>)` first
5. Evaluate completion: AI judges whether agent achieved the goal
6. Structured summarization: extract results into workflow context
7. Return outcome (pass/fail) + result JSON + agentId

### Design principle

The runner does NOT micromanage agent execution. Agent steps define goals via `prompt:` — Claude decides how to achieve them. The `/cq-agent` sub-skill provides structure (heartbeat, resume, result extraction) without limiting autonomy.

### Headless mode (CI)

```bash
cq start feature --story_id=123 --headless
```

In headless mode:
- `human` gates are auto-approved
- `manual` steps are skipped
- `review` gates follow max_visits logic only (no human escalation — fail the run instead)
- All output is JSON

---

## 10. Notification Hooks

Configured in `settings.json` under `notifications`. Each hook is a bash command template with `{{variable}}` interpolation from the run context:

```json
{
  "notifications": {
    "on_gate": "echo 'Workflow {{run_id}} waiting at {{step_id}}' | slack-cli send '#dev'",
    "on_fail": "gh issue comment {{pr_number}} --body 'Workflow failed at {{step_id}}'",
    "on_complete": null
  }
}
```

Events: `on_gate` (human action needed), `on_fail` (step or workflow failed), `on_complete` (workflow finished successfully), `on_start` (workflow started).

Hooks run asynchronously (backgrounded) and their failure does not affect workflow execution.

---

## 11. Parallel Workers

The `/cq-workers` skill enables parallel workflow execution by spawning multiple Claude Code agents, each in its own git worktree.

### Architecture

```
Parent (main Claude instance)
  │
  ├─ cq workers init → creates session directory
  │
  ├─ Spawns Agent (worktree, background) → Worker 1: cq start bugfix --description="BUG-1"
  ├─ Spawns Agent (worktree, background) → Worker 2: cq start bugfix --description="BUG-2"
  └─ Spawns Agent (worktree, background) → Worker 3: cq start bugfix --description="BUG-3"
  │
  └─ Monitoring loop: polls cq workers status <session_id>
      └─ On gate: asks user → cq workers answer → child picks it up
```

### Key Design Decisions

**Git worktree isolation**: Each worker gets its own worktree via Claude Code's `isolation: "worktree"` parameter. This means `.claudekiq/runs/` in a child worktree is NOT visible from the parent. Workers need a shared coordination directory at an absolute path.

**Shared coordination directory**: `.claudekiq/workers/<session_id>/` lives in the main worktree and is accessible to all workers via absolute path. The parent passes `PARENT_ROOT` to each worker agent's prompt.

**Filesystem-based IPC**: Workers communicate with the parent through JSON files:
- `<job_id>.status.json` — written by child after each step (status, current step, gate info)
- `<job_id>.answer.json` — written by parent when answering a gate
- Children poll for answer files when gated (every 5 seconds, 30 minute timeout)

**Background agents**: Claude Code background agents auto-deny permission prompts. This means:
- Workers cannot ask the user questions directly
- All human interaction is funneled through the parent via coordination files
- `--headless` mode auto-approves all gates, eliminating the need for coordination

### Worker Session Lifecycle

1. **Init**: `cq workers init` creates a session directory with `manifest.json`
2. **Spawn**: Parent spawns one background Agent per job, each in its own worktree
3. **Execute**: Each worker runs `cq init` → `cq start <workflow>` → runner loop
4. **Report**: After each step, workers write status to `<job_id>.status.json`
5. **Gate**: When gated, workers write gate info to status file and poll for `<job_id>.answer.json`
6. **Answer**: Parent detects gate via `cq workers status`, asks user, writes answer via `cq workers answer`
7. **Resume**: Worker reads answer file, applies it (approve/reject), continues workflow
8. **Complete**: Worker writes final status, commits work in its worktree

### Status File Format

Written by workers to `<session_id>/<job_id>.status.json`:

```json
{
  "status": "running|gated|completed|failed",
  "run_id": "a1b2c3d4",
  "step": "current-step-id",
  "gate": {
    "step": "code-review",
    "description": "Review changes for BUG-101",
    "action_needed": "approve or reject"
  }
}
```

### Answer File Format

Written by parent to `<session_id>/<job_id>.answer.json`:

```json
{
  "action": "approve",
  "data": {"message": "looks good"},
  "answered_at": "2026-03-13T10:00:00Z"
}
```

### CLI Commands

**`cq workers init`**
- Creates `.claudekiq/workers/<session_id>/` with a `manifest.json`
- Returns session ID (used for all subsequent commands)

**`cq workers status <session_id>`**
- Reads all `*.status.json` files in the session directory
- Returns aggregate counts (running, gated, completed, failed) and per-job details
- JSON output includes `jobs` array with `job_id`, `status`, and step info

**`cq workers answer <session_id> <job_id> <action> [data_json]`**
- Writes `<job_id>.answer.json` to the session directory
- `action` is typically `approve` or `reject`
- Optional `data_json` can be a JSON object or plain string (wrapped as `{message: "..."}`)

**`cq workers cleanup [--max-age=N]`**
- Removes session directories older than N seconds (default: 30 days)
- Scans all sessions, checks `manifest.json` creation timestamp

### Integration with `cq init`

Running `cq init` (or re-running it on an existing project) will:
- Add `.claudekiq/workers/` to `.gitignore`
- Install the `cq-workers` skill to `.claude/skills/cq-workers/SKILL.md`

---

## 12. MCP Server Mode

`cq` can run as a Claude Code MCP (Model Context Protocol) plugin, exposing all commands as native tools that Claude discovers automatically. This works alongside the existing skill-based integration — both modes coexist.

### Architecture

```
Claude Code ←→ stdio ←→ cq mcp (long-running process)
                         ├─ initialize → returns server info + capabilities
                         ├─ tools/list → returns all cq commands as MCP tools
                         └─ tools/call → dispatches to cmd_* functions, returns JSON
```

### Protocol

MCP uses JSON-RPC 2.0 over stdio. The server reads newline-delimited JSON messages from stdin and writes responses to stdout. Stderr is used for logging.

Supported methods:
- `initialize` — handshake, returns server info and capabilities
- `tools/list` — returns all cq commands as MCP tools with JSON Schema `inputSchema`
- `tools/call` — executes a cq command, returns structured JSON output
- `notifications/*` — acknowledged silently (no response)

### Tool Discovery

Tools are generated dynamically from `cq schema`. Each command becomes an MCP tool with:
- Name prefixed with `cq_` and hyphens converted to underscores (e.g., `step-done` → `cq_step_done`)
- Description from the schema
- `inputSchema` as JSON Schema derived from parameter definitions

### Exposed Tools

| MCP Tool | cq Command | Description |
|----------|------------|-------------|
| `cq_start` | `cq start` | Start a workflow run |
| `cq_status` | `cq status` | Show run status |
| `cq_list` | `cq list` | List all runs |
| `cq_log` | `cq log` | Show event log |
| `cq_pause` | `cq pause` | Pause a workflow |
| `cq_resume` | `cq resume` | Resume a workflow |
| `cq_cancel` | `cq cancel` | Cancel a workflow |
| `cq_retry` | `cq retry` | Retry a failed/blocked workflow |
| `cq_step_done` | `cq step-done` | Mark a step complete |
| `cq_skip` | `cq skip` | Skip a step |
| `cq_todos` | `cq todos` | List pending TODOs |
| `cq_todo` | `cq todo` | Resolve a TODO |
| `cq_ctx` | `cq ctx` | Show/get/set context |
| `cq_add_step` | `cq add-step` | Add a step dynamically |
| `cq_add_steps` | `cq add-steps` | Insert subflow steps |
| `cq_set_next` | `cq set-next` | Force next step routing |
| `cq_workflows` | `cq workflows` | Manage templates |
| `cq_heartbeat` | `cq heartbeat` | Write heartbeat |
| `cq_check_stale` | `cq check-stale` | Detect stale runs |
| `cq_cleanup` | `cq cleanup` | Remove expired runs |
| `cq_workers` | `cq workers` | Worker orchestration |

### Setup

**Option A: Register globally**

```bash
claude mcp add --transport stdio cq -- cq mcp
```

**Option B: Per-project `.mcp.json`**

`cq init` creates a `.mcp.json` in the project root:

```json
{
  "mcpServers": {
    "cq": {
      "type": "stdio",
      "command": "cq",
      "args": ["mcp"]
    }
  }
}
```

Claude Code auto-discovers this file and registers the server.

### Dual-Mode Design

Skills and MCP serve different purposes and work together:

| Capability | Skill mode (`/cq`) | MCP mode (plugin) |
|-----------|--------------------|--------------------|
| Installation | `cq init` → installs SKILL.md | `claude mcp add` or `.mcp.json` |
| Discovery | User invokes `/cq` | Claude sees tools automatically |
| Runner loop | Skill drives the loop | Claude calls tools directly |
| Gate handling | Skill asks user, calls `cq todo` | Claude calls `cq_todos` + `cq_todo` |
| JSON output | Skill parses `--json` CLI output | MCP returns structured JSON natively |

**Skills teach Claude HOW to orchestrate** (the runner loop logic). **MCP gives Claude the TOOLS to do it.** Best experience is both together.

### Implementation

The MCP server is in `lib/mcp.sh` (~280 lines). Key functions:
- `cq_mcp_serve()` — main loop: read stdin, dispatch, write stdout
- `_mcp_build_tools()` — converts `cq schema` to MCP tool definitions
- `_mcp_dispatch_tool()` — maps tool name + JSON args to `cmd_*` function calls
- All tool calls internally set `CQ_JSON=true` for structured output

---

## 13. Interpolation Engine

All `{{variable}}` references in targets, args_template, routing conditions, and notification hooks are resolved from the run's `ctx.json`.

```
Input:  "Run tests for {{story_title}} on {{stack}}"
Context: {"story_title": "Add login", "stack": "rails"}
Output: "Run tests for Add login on rails"
```

Undefined variables are left as-is (`{{undefined}}`) and logged as a warning.

### Conditional routing

```yaml
routing:
  read-story:
    - when: "{{story_type}} == bug"
      goto: investigate
    - when: "{{story_type}} == feature"
      goto: create-branch
```

Conditions support: `==`, `!=`, `contains`, `empty`, `not_empty`. Evaluated top-to-bottom, first match wins. If no match, falls through to default step order.

---

## 14. Cross-platform Notes

| Concern | Linux | macOS |
|---------|-------|-------|
| UUID generation | `uuidgen` or read `/proc/sys/kernel/random/uuid` | `uuidgen` |
| File locking | `flock` | `shlock` or `flock` (if installed via brew) |
| Date formatting | `date -u +%Y-%m-%dT%H:%M:%SZ` | `date -u +%Y-%m-%dT%H:%M:%SZ` |
| JSON processing | `jq` (required) | `jq` (required) |
| Temp files | `mktemp` | `mktemp` |

The script should detect the platform once at startup and set helper functions accordingly.

---

## 15. Migration Path from Proof-of-Concept

The `code_idea/` directory contains the Redis-based Ruby proof-of-concept. Migration plan:

1. **Phase 1**: Build `cq` CLI in Bash with filesystem storage, matching the command surface of the PoC
2. **Phase 2**: Build `cq init`, config system, workflow validation
3. **Phase 3**: Build the schema system (`cq schema`)
4. **Phase 4**: Build the Claude Code skill (SKILL.md + runner loop)
5. **Phase 5**: Build installer (`install.sh`), global workflow sharing
6. **Phase 6**: Headless mode, notification hooks, plugin system
7. **Phase 7**: Documentation, examples for different stacks (Rails, Node, Go, etc.)

The PoC's test suite (`code_idea/scripts/specs/myflow-cli.rb`) serves as a functional specification — every test describes a behavior that `cq` must replicate.

---

## 16. Example: Tool Integration Patterns

Since claudekiq is tool-agnostic, integrations happen through `bash` steps and context variables.

### Litetracker

```yaml
- id: read-story
  type: bash
  target: "lt story show {{project_id}} {{story_id}} --json"
  outputs:
    story_type: ".story_type"
    story_title: ".name"
```

### GitHub Issues

```yaml
- id: read-issue
  type: bash
  target: "gh issue view {{issue_number}} --json title,labels,body"
  outputs:
    story_title: ".title"
    story_type: ".labels[0].name"
```

### JIRA

```yaml
- id: read-ticket
  type: bash
  target: "jira issue view {{ticket_id}} --template json"
  outputs:
    story_title: ".fields.summary"
    story_type: ".fields.issuetype.name"
```

### Slack notifications

```json
{
  "notifications": {
    "on_gate": "curl -X POST -H 'Content-Type: application/json' -d '{\"text\":\"⏸️ {{run_id}} waiting at {{step_id}}\"}' $SLACK_WEBHOOK_URL"
  }
}
```

The `outputs` field uses jq filter syntax to extract values from the step's JSON stdout into context variables.
