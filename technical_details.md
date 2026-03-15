# Technical Details — claudekiq (`cq`)

## 1. Overview

`cq` is a modular Bash CLI that orchestrates multi-step development workflows for Claude Code. It stores all state on the filesystem (no Redis, no database). It is installed globally and configured per-project.

Dependencies: `bash` (4.0+), `jq`, `yq`, `date`, `uuidgen` (or `/proc/sys/kernel/random/uuid` fallback on Linux).

Architecture: Entry point (`cq`) sources libraries in order — `lib/core.sh`, `lib/yaml.sh`, `lib/storage.sh`, `lib/commands/*.sh`, `lib/schema.sh` — then dispatches commands via a case statement.

---

## 2. Installation

Single curl command installs the `cq` script to `~/.cq/bin/cq` and creates the global config directory:

```bash
curl -fsSL https://raw.githubusercontent.com/MelianLabs/claudekiq/main/install.sh | bash
```

The install script:
1. Creates `~/.cq/bin/`, `~/.cq/lib/`, `~/.cq/skills/`, `~/.cq/workflows/`, `~/.cq/config.json`
2. Downloads `cq` and library files, makes them executable
3. Copies skill definitions (`cq`, `cq-agent`, `cq-setup`) to `~/.cq/skills/`
4. Prints instructions to add `~/.cq/bin` to `$PATH`
5. Runs `cq version` to confirm

Uninstall: `rm -rf ~/.cq` and remove the PATH entry.

### Versioning

`cq` is versioned independently (semver). The version is embedded as `CQ_VERSION="x.y.z"`. Projects pin a minimum version in `.claudekiq/settings.json` via `"min_cq_version": "3.2.0"`. On every invocation, `cq` checks and warns if the installed version is below the project minimum.

---

## 3. Directory Layout

### Global (`~/.cq/`)

```
~/.cq/
  bin/cq                    # The CLI entry point
  lib/                      # Library files (core.sh, yaml.sh, storage.sh, etc.)
    commands/               # Command modules (setup.sh, lifecycle.sh, steps.sh, etc.)
  skills/                   # Skill definitions
    cq/SKILL.md             # Workflow runner skill
    cq-agent/SKILL.md       # Agent step executor skill
    cq-setup/SKILL.md       # Smart project setup skill
  config.json               # Global defaults
  workflows/                # Shared workflow templates
```

### Per-project (`.claudekiq/`)

```
.claudekiq/
  settings.json             # Project config (overrides global)
  workflows/                # Project workflows (committed to repo)
    feature.yml
    bugfix.yml
    private/                # Private workflows (gitignored)
  runs/                     # Active and completed workflow runs (gitignored)
    <run_id>/
      meta.json             # Run metadata (template, status, timestamps, priority, parent linkage)
      ctx.json              # Context variables (key-value)
      steps.json            # Step definitions (resolved, ordered array)
      state.json            # Step states (status, visits, attempt, result, files per step)
      log.jsonl             # Event log (append-only, one JSON object per line)
      todos/                # TODO files for human gates
        <todo_id>.json
        .sync_state.json    # TODO sync state for native integration
```

### Claude Code Integration Files

```
.claude-plugin/
  plugin.json               # Plugin manifest (points to ~/.cq/skills/, version auto-synced)
.claude/
  settings.json             # Hooks (auto-installed by cq init, conflict-aware)
  cq.md                     # Auto-generated project context (workflows, agents, stacks, usage)
```

### Gitignore

`cq init` appends to `.gitignore`:

```
.claudekiq/workflows/private/
.claudekiq/runs/
```

---

## 4. Configuration

### `config.json` schema (global and project-level)

```jsonc
{
  "prefix": "cq",
  "ttl": 2592000,
  "priorities": ["urgent", "high", "normal", "low"],
  "default_priority": "normal",
  "concurrency": 1,
  "markers": {
    "passed": "✅", "failed": "❌", "running": "🔄",
    "gated": "⏸️", "skipped": "⏭️", "pending": "⬚",
    "queued": "📋", "paused": "⏯️", "cancelled": "🚫",
    "completed": "✅", "blocked": "⏳"
  },
  "step_fields": ["name", "type", "target", "prompt", "context", "args_template", "gate", "model", "background", "resume", "outputs"],
  "models": ["opus", "sonnet", "haiku"],
  "default_model": "opus",
  "edge_keys": ["next", "on_pass", "on_fail"],
  "notifications": {
    "on_gate": null,
    "on_fail": null,
    "on_complete": null,
    "on_start": null
  },
  "safety": "strict",
  "min_cq_version": null
}
```

### Safety configuration

Supports both simple string and per-operation policy map:

```jsonc
// Simple (backward-compatible)
"safety": "strict"    // all operations block
"safety": "relaxed"   // all operations warn

// Per-operation map
"safety": {
  "git_commit": "block",
  "git_checkout": "block",
  "rm_claudekiq": "block",
  "edit_run_files": "warn"
}
```

Set via: `cq config set safety relaxed` or `cq config set safety.git_commit warn`

### Resolution order

1. Built-in defaults (hardcoded in `cq_default_config()`)
2. Global config (`~/.cq/config.json`)
3. Project config (`.claudekiq/settings.json`)

Project values override global values. Arrays and objects are **replaced**, not merged.

---

## 5. Workflow Definition Format

Workflows are YAML files supporting `prompt:`, `context:`, `params:`, `model:`, `resume:`, `isolation:`, `extends:`, `parallel`, and `workflow` step types.

```yaml
name: example
description: Example workflow
extends: base               # optional: inherit from base workflow

params:
  description:
    description: "What to build"
    required: true
  branch_name:
    description: "Feature branch name"
    default: ""

defaults:
  description: ""
  branch_name: ""

steps:
  - id: plan
    name: Plan Implementation
    type: agent
    prompt: "Plan implementation for the given description."
    context: [description]
    gate: human
    model: sonnet

  - id: test-all
    name: Run All Tests
    type: parallel
    branches:
      - id: test-backend
        type: bash
        target: "bundle exec rspec"
      - id: test-frontend
        type: bash
        target: "npm test"
    gate: review
    max_visits: 3
    on_fail: fix

  - id: fix
    name: Fix Issues
    type: agent
    target: "@rails-dev"
    prompt: "Fix the failing tests."
    isolation: worktree       # optional: run in isolated worktree
    gate: auto
    next: test-all

  - id: deploy
    name: Deploy
    type: workflow
    template: deploy
    context_map:
      environment: "staging"
    outputs:
      deploy_url: "url"
    gate: human

# Override inherited steps
override:
  lint:
    gate: review
    max_visits: 5

# Remove inherited steps
remove:
  - code-review
```

### Step Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique step identifier (required, `[a-z0-9_-]+`) |
| `name` | string | Human-readable name |
| `type` | string | `bash`, `agent`, `skill`, `parallel`, `workflow`, or convention-based |
| `prompt` | string | Goal description for agent steps (raw, no interpolation) |
| `context` | array | Context keys to inject into agent prompt |
| `target` | string | Command (bash), agent name (`@name`), skill name, or workflow template |
| `gate` | string | `auto`, `human`, or `review` |
| `model` | string | AI model: `opus`, `sonnet`, `haiku` |
| `resume` | boolean | If true, agent can be resumed on retry (stores agentId) |
| `isolation` | string | `worktree` for isolated execution |
| `outputs` | object/array | Expected output keys for structured result extraction |
| `branches` | array | Branch definitions for `parallel` steps |
| `template` | string | Workflow name for `workflow` steps |
| `context_map` | object | Context variable mapping for sub-workflows |
| `max_visits` | integer | Max retry visits for `review` gate |
| `background` | boolean | Run step in background |
| `timeout` | integer | Timeout in seconds |
| `on_pass` / `on_fail` / `on_timeout` / `next` | string/array | Routing edges |
| `allows_commit` | boolean | Allow git commits during this step (safety) |

### Step Types

| Type | `target` | Execution |
|------|----------|-----------|
| `bash` | Shell command with `{{interpolation}}` | Bash tool. Exit 0 = pass. |
| `agent` | Agent name (`@rails-dev`) or empty | Agent tool via `/cq-agent` skill |
| `skill` | Skill name (e.g., `/commit`) | Skill tool with interpolated args |
| `parallel` | N/A (uses `branches`) | `/batch` skill for concurrent execution |
| `workflow` | N/A (uses `template`) | Starts child workflow run |
| convention | Any custom name | Agent step with type name as semantic context |

### Workflow Inheritance (`extends`)

Child workflow inherits from base:
1. Base steps are loaded
2. `remove` list filters out base steps by ID
3. `override` map merges fields into matching base step IDs
4. Child `steps` are appended after base steps
5. `defaults` and `params` merge (child overrides base)
6. Recursive resolution for chained inheritance

---

## 6. Filesystem State Storage

### Run directory: `.claudekiq/runs/<run_id>/`

Each run gets a directory named with an 8-character short UUID.

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
  "params": { "description": "What to build" },
  "parent_run_id": null,
  "parent_step_id": null,
  "children": []
}
```

Status values: `queued`, `running`, `paused`, `gated`, `completed`, `failed`, `cancelled`, `blocked`.

#### `state.json`

```json
{
  "build": { "status": "passed", "visits": 1, "attempt": 1, "result": "pass", "started_at": "...", "finished_at": "...", "files": ["src/app.ts"] },
  "test": { "status": "running", "visits": 2, "attempt": 2, "result": null, "started_at": "...", "finished_at": null, "files": [] }
}
```

For parallel steps, state includes `branches`:
```json
{
  "test-all": { "status": "passed", "visits": 1, "result": "pass", "branches": {
    "test-backend": { "status": "passed", "result": "pass" },
    "test-frontend": { "status": "passed", "result": "pass" }
  }}
}
```

#### `log.jsonl`

```jsonl
{"ts":"2026-03-13T10:00:00Z","event":"run_started","data":{"template":"feature","priority":"normal"}}
{"ts":"2026-03-13T10:00:01Z","event":"step_started","data":{"step":"build"}}
{"ts":"2026-03-13T10:00:05Z","event":"step_done","data":{"step":"build","result":"pass","visits":1,"files":["src/app.ts"]}}
{"ts":"2026-03-13T10:00:05Z","event":"gate_auto","data":{"step":"build","next":"test"}}
```

### Locking

Directory-based locking (`mkdir` atomic operation) to prevent concurrent modifications. Timeout after 5 seconds. Helper: `cq_with_lock()`.

### TODO Storage

Each gated step creates a TODO file in `.claudekiq/runs/<run_id>/todos/<todo_id>.json`:
```json
{
  "id": "todo_id",
  "run_id": "run_id",
  "step_id": "step_id",
  "step_name": "Deploy",
  "action": "review",
  "description": "Review deployment",
  "status": "pending",
  "priority": "normal",
  "created_at": "..."
}
```

TODOs sync lazily with Claude Code's native TodoWrite/TodoRead system via `cq todos sync`.

---

## 7. Command Modules

Commands are split into domain-specific files in `lib/commands/`:

| Module | Commands | Responsibility |
|--------|----------|----------------|
| `setup.sh` | `init`, `version`, `help`, `hooks` | Project setup, hooks, cq.md generation |
| `scan.sh` | `scan` | Agent, skill, stack discovery |
| `lifecycle.sh` | `start`, `status`, `list`, `log` | Workflow lifecycle, agent target validation |
| `flow.sh` | `pause`, `resume`, `cancel`, `retry` | Flow control with child cascade |
| `steps.sh` | `step-done`, `skip` | Gate handling, step advancement, output extraction |
| `todos.sh` | `todos`, `todo` | Human actions, TODO sync |
| `ctx.sh` | `ctx` | Context get/set |
| `dynamic.sh` | `add-step`, `add-steps`, `set-next` | Dynamic workflow modification |
| `workflows.sh` | `workflows`, `validate` | Template management, enhanced validation |
| `config.sh` | `config` | Configuration (supports dot-notation) |
| `maintenance.sh` | `cleanup`, `heartbeat`, `check-stale` | Run maintenance |
| `hooks_internal.sh` | `_stage-context`, `_pre-commit-validate`, `_capture-output`, `_safety-check` | Internal hook handlers |

---

## 8. Hooks System

Hooks are auto-installed into `.claude/settings.json` by `cq init`. Smart conflict detection warns when existing non-cq hooks use the same matcher.

### Hook Events

| Event | Matcher | Purpose |
|-------|---------|---------|
| **SessionEnd** | (all) | Mark stale runs on session exit |
| **PreToolUse** | Bash | Safety checks: `cq _safety-check` for rm, git checkout, git commit |
| **PreToolUse** | Edit, Write | Safety checks: block direct run file edits |
| **PostToolUse** | Bash, Edit, Write | Context staging: capture git diffs and modified files |
| **PostToolUse** | Agent | Capture agent output into context |
| **WorktreeCreate** | (all) | Auto-run `cq init` in new worktrees |

### Safety Checks

Centralized in `cq _safety-check <operation>`:
- Reads per-operation policy from `cq_safety_policy()` in `lib/core.sh`
- Returns exit 0 (allow/warn) or exit 2 (block)
- Operations: `git_commit`, `git_checkout`, `rm_claudekiq`, `edit_run_files`

### Notification Hooks

Configured in `settings.json` under `notifications`. Fire asynchronously via `cq_fire_hook()`:

```json
{
  "notifications": {
    "on_gate": "echo 'Waiting at step' | slack-send '#dev'",
    "on_fail": "gh issue comment --body 'Workflow failed'",
    "on_complete": null,
    "on_start": null
  }
}
```

Each hook also emits a structured JSON event to stderr for Claude Code hook parsing.

---

## 9. Enhanced Validation

`cq workflows validate` performs:

1. **Schema checks** — required fields (name, steps), step ID format, type/model validation
2. **Agent target validation** — `@target` references checked against scan results
3. **Parallel validation** — branches array required, each branch needs id + type
4. **Workflow step validation** — template field required
5. **Circular routing detection** — warns on cycles without gates (infinite loop risk)
6. **Missing context variables** — `{{var}}` in bash steps not in defaults/params
7. **Unreachable step detection** — steps not reachable via any route from first step
8. **Extends validation** — base exists, no circular extends, valid override/remove IDs

---

## 10. Claude Code Skill Integration

### `/cq` Runner Skill

The runner uses precise tool call patterns for reliable integration:

- **TaskCreate/TaskUpdate** — MANDATORY at workflow start, step progress, and completion
- **TodoWrite/TodoRead** — Lazy sync at session start, gate events, and workflow completion
- **AskUserQuestion** — Exact patterns with options for approve/reject/override at gates
- **Skill** — Dispatches agent steps to `/cq-agent`, parallel to `/batch`

### `/cq-agent` Agent Executor

Handles single agent steps with:
- Exact `Agent()` tool call with subagent_type, model, isolation parameters
- Heartbeat via `CronCreate`/`CronDelete`
- Agent resume via saved agentId
- Result evaluation heuristics (pass/fail criteria)
- Output extraction to workflow context

### `/cq-setup` Smart Setup

Self-contained project setup:
- Step 0: Auto-initializes if needed (`cq init`)
- Scans agents, skills, stacks
- Checks existing workflows before generating
- Suggests agent mappings for missing stack agents
- Uses `AskUserQuestion` with exact multi-select patterns
- Generates workflows with parallel, sub-workflow, and extends support

### CLI Output Hints

Commands emit natural language hints (stderr) guiding Claude:
- `cq_hint()` helper in `lib/core.sh`
- Hints for: task creation, gate approval, completion, next step, resume
- Suppressed in `--json` mode

---

## 11. MCP Server Mode

`cq mcp` starts an MCP stdio server exposing all commands as tools.

### Architecture

```
Claude Code ←→ stdio ←→ cq mcp (long-running process)
                         ├─ initialize → server info + capabilities
                         ├─ tools/list → all cq commands as MCP tools
                         └─ tools/call → dispatches to cmd_* functions
```

Protocol: JSON-RPC 2.0 over stdio (MCP 2024-11-05). Implementation in `lib/mcp.sh`.

Tools are named `cq_<command>` with hyphens as underscores. Schema generated from `cq schema`.

### Dual-Mode Design

Skills and MCP coexist. Skills teach Claude HOW to orchestrate. MCP gives Claude the TOOLS. Best experience is both together.

---

## 12. Interpolation Engine

`{{expression}}` references in bash targets resolved from `ctx.json` via jq:

```
Input:  "Run tests for {{project}} on {{stack}}"
Context: {"project": "myapp", "stack": "rails"}
Output: "Run tests for myapp on rails"
```

Supports: nested access (`{{config.timeout}}`), array indexing (`{{servers[0].host}}`), jq expressions (`{{items | length}}`).

**Only bash step targets are interpolated.** Agent steps receive raw prompts + context section.

### Conditional Routing

```yaml
next:
  - when: "{{mode}} == bug"
    goto: investigate
  - when: "{{mode}} == feature"
    goto: create-branch
  - default: implement
```

Conditions support: `==`, `!=`, `>`, `<`, `>=`, `<=`, `contains`, `matches`, `empty`, `not_empty`. Compound: `AND`, `OR`. Evaluated top-to-bottom, first match wins.

---

## 13. Cross-platform Notes

| Concern | Linux | macOS |
|---------|-------|-------|
| UUID generation | `uuidgen` or `/proc/sys/kernel/random/uuid` | `uuidgen` |
| File locking | `mkdir`-based (atomic) | `mkdir`-based (atomic) |
| Date formatting | `date -u +%Y-%m-%dT%H:%M:%SZ` | `date -u +%Y-%m-%dT%H:%M:%SZ` |
| File age | `stat -c %Y` | `stat -f %m` |
| JSON processing | `jq` (required) | `jq` (required) |
| YAML processing | `yq` (required) | `yq` (required) |

Platform detected at startup via `cq_detect_platform()`.

---

## 14. Tool Integration Patterns

Claudekiq is tool-agnostic. Integrations happen through `bash` steps, `outputs`, and context variables.

### GitHub Issues

```yaml
- id: read-issue
  type: bash
  target: "gh issue view {{issue_number}} --json title,labels,body"
  outputs:
    story_title: ".title"
    story_type: ".labels[0].name"
```

### Slack Notifications

```json
{
  "notifications": {
    "on_gate": "curl -X POST -d '{\"text\":\"Waiting at step\"}' $SLACK_WEBHOOK_URL"
  }
}
```

### Multi-Stack Testing

```yaml
- id: test-all
  type: parallel
  branches:
    - id: test-backend
      type: bash
      target: "bundle exec rspec"
    - id: test-frontend
      type: bash
      target: "npm test"
```

The `outputs` field uses jq filter syntax to extract values from step JSON stdout into context variables.
