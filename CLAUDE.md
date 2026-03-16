# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claudekiq (`cq`) is a filesystem-backed workflow engine CLI for Claude Code. It orchestrates multi-step development workflows by coordinating AI agents, shell commands, and human approval gates. Written in Bash with `jq` and `yq` as dependencies.

## Running Tests

```bash
bats tests/               # Run all tests
bats tests/test_e2e.bats  # Run a single test file
bats tests/test_start.bats --filter "pattern"  # Filter by name
```

Requires: `bash` (4.0+), `jq`, `yq`, `bats`

Tests use a shared `tests/setup.bash` that creates a temp directory, runs `cq init`, and copies fixtures from `tests/fixtures/`. Each test file sources this setup and uses `setup_test_project`/`teardown_test_project` for isolation.

## Architecture

### Entry Point & Command Dispatch

`cq` is the main entry point. It sources libraries in order:
1. `lib/core.sh` — utilities (UUID, timestamps, interpolation, conditions, config, locking, hooks)
2. `lib/yaml.sh` — YAML-to-JSON conversion via yq
3. `lib/storage.sh` — filesystem I/O for runs, steps, state, context, todos, routing
4. `lib/commands/*.sh` — command implementations (one file per domain)
5. `lib/schema.sh` — AI-discoverable JSON schemas for every command

Command dispatch is a case statement in `cq` that maps command names to `cmd_*` functions.

### Command Modules (`lib/commands/`)

Commands were split from a monolithic `commands.sh` into domain-specific files:

- `setup.sh` — `init`, `version`, `help`, `hooks`
- `scan.sh` — `scan` (discover agents, skills)
- `lifecycle.sh` — `start`, `status`, `list`, `log` (includes agent target validation)
- `flow.sh` — `pause`, `resume`, `cancel`, `retry`
- `steps.sh` — `step-done`, `skip`
- `todos.sh` — `todos`, `todo`
- `ctx.sh` — `ctx` (get/set context)
- `dynamic.sh` — `add-step`, `add-steps`, `set-next`
- `workflows.sh` — `workflows` (list/show/validate), `validate`
- `config.sh` — `config` (get/set)
- `maintenance.sh` — `cleanup`, `heartbeat`, `check-stale`
MCP server mode is in `lib/mcp.sh`, loaded on-demand.

### Storage Layout

All run state lives in `.claudekiq/runs/<run_id>/` (gitignored):
- `meta.json` — run metadata (workflow, status, priority, timestamps)
- `state.json` — per-step state (status, visit count, results, output, error_output)
- `context.json` — interpolation variables
- `steps.json` — resolved step definitions
- `log.jsonl` — append-only event log

### Key Concepts

- **Step types**: `bash`, `agent`, `skill` (built-in), plus convention-based custom types (any unrecognized type name is treated as an agent step with semantic context)
- **Gates**: `auto` (continue), `human` (wait for approval via `AskUserQuestion` — replaces old `manual` type), `review` (retry loop with max_visits escalation)
- **Interpolation**: `{{expr}}` in bash targets only, resolved from context via jq. Agent steps receive raw prompt + context — Claude decides how to use it. Supports nested access (`{{config.timeout}}`), array indexing (`{{items[0].name}}`), and jq expressions (`{{results | length}}`).
- **Config resolution**: global (`~/.cq/config.json`) merged with project (`.claudekiq/settings.json`), project wins
- **Agent mappings**: stored in `.claudekiq/settings.json` under `agent_mappings` key
- **All commands support `--json`** for machine-readable output
- **Headless mode**: `--headless` flag auto-approves gates and forces JSON output

### Project Setup (`cq init`)

`cq init` creates `.claudekiq/` structure, installs hooks, scans project, and outputs context-aware discovery hints:
- `.claudekiq/` directory structure (workflows, runs, settings.json)
- `.claude-plugin/plugin.json` pointing to `~/.cq/skills/` (version auto-synced from `$CQ_VERSION`, user-added skills preserved on re-init)
- `.gitignore` entries
- Smart output: reports discovered agents, stacks, and available workflows
- JSON output includes `agents_found`, `stacks_found`, `workflows_found` counts

Hooks are auto-installed into `.claude/settings.json`. Skills are served via the `.claude-plugin/plugin.json` plugin system from `~/.cq/skills/`.

`/cq-setup` is self-contained: it auto-initializes if `cq init` hasn't been run yet.

### Hooks System (`cq hooks`)

Hooks are auto-installed by `cq init`:
- Merges cq-specific hooks into `.claude/settings.json` (SessionEnd, PreToolUse, PostToolUse, WorktreeCreate)
- Smart conflict detection: warns when existing non-cq hooks use the same matcher
- `cq hooks uninstall` cleanly removes only cq hooks
- Configurable notification commands in `.claudekiq/settings.json` → `notifications`: `on_start`, `on_gate`, `on_fail`, `on_complete`
- `cq_fire_hook()` emits structured JSON events with version, status, and timestamp to stderr

### Project Discovery (`cq scan`)

`cq scan` discovers agents, skills, commands, and stacks available in the project:
- Scans `.claude/agents/*.md` — parses YAML frontmatter for name, model, tools, description
- Scans `.claude/skills/*/SKILL.md` — parses frontmatter for name, description, allowed-tools
- Scans `.claude/commands/*.md` — discovers custom slash commands (name, description from frontmatter or filename)
- Scans `.claude-plugin/plugin.json` — discovers plugin-provided skills (marked with `source: "plugin"`)
- Detects project stacks — returns `stacks` as an array (multi-stack support: e.g., Rails + React)
- Each stack object has: `language`, `framework`, `test_command`, `build_command`, `lint_command`
- Validates all workflows after scan — reports warnings for invalid ones
- Writes results to `.claudekiq/settings.json` as `agents`, `skills`, `commands`, `stacks` arrays
- Preserves existing user config keys (including `agent_mappings`) during merge
- Auto-runs on `cq init` (both fresh and re-init)

### Agent Naming Convention

Agents are named after their stack: `@rails-dev`, `@react-dev`, `@go-dev`, etc. This convention replaces the generic `@implementer` pattern and makes agent purpose clear in workflows.

### Custom Step Types

Custom step types resolve via `cq_resolve_step_type()` in `lib/core.sh`:
1. Built-in types (`bash`, `agent`, `skill`) → returns `"builtin"`
2. Agent-backed: `.claude/agents/<type>.md` file exists → returns `"agent"`
3. Scan results: `agents` array in settings.json → returns `"agent"`
4. Otherwise: returns `"convention"` (treated as agent step with type name as semantic context)

### Step Output Capture

`cq step-done` supports `--output=<text>` and `--stderr=<text>` flags:
- Output is stored in `state.json` as `.output` and `.error_output` per step
- Truncated output (500 chars) is included in log events
- On retry, previous `error_output` is available via the `error_context` context builder
- Works for both pass and fail outcomes

### Context Builders

Agent steps can define `context_builders` to automatically gather context before dispatch:

```yaml
context_builders:
  - type: git_diff          # git diff HEAD output (200 lines max)
  - type: file_contents     # requires paths: ["file1", "file2"]
    paths: ["src/app.ts"]
  - type: error_context     # previous step error_output from state.json
  - type: test_output       # requires command: "npm test"
    command: "npm test 2>&1 | tail -50"
  - type: command_output    # requires command: "some command"
    command: "echo hello"
```

Resolved via `cq _resolve-context <run_id> <step_id>`. Implementation in `cq_resolve_context_builders()` in `lib/core.sh`.

### Context File (`.claude/cq.md`)

`cq init` and `cq scan` generate `.claude/cq.md` with comprehensive project context:
- Available workflows with step summaries (step names, gate types, params)
- Detected agents, stacks, skills, and custom commands
- Usage patterns (start, monitor, approve, skip, cancel)
- Team workflow notes (concurrency, agents)
- Notification config visibility

Claude Code loads this automatically so it always knows the project's workflow capabilities.

### Safety Configuration

The `safety` config key controls hook behavior. Supports both simple string and per-operation policy map:

**Simple (backward-compatible):**
- `"strict"` (default) — hooks block dangerous operations (exit 2)
- `"relaxed"` — hooks warn but allow operations (exit 0)

**Per-operation policy map:**
```json
{
  "safety": {
    "git_commit": "block",
    "git_checkout": "block",
    "rm_claudekiq": "block",
    "edit_run_files": "warn"
  }
}
```

Set via: `cq config set safety relaxed` or `cq config set safety.git_commit warn`

Safety checks are centralized in `cq _safety-check <operation>` (called by hooks).

Supported operations: `rm_claudekiq`, `git_checkout`, `git_commit`, `edit_run_files`, `git_force_push`, `git_reset_hard`, `git_rebase`

For parallel batch processing, use Claude Code's built-in `/batch` skill.

### Workflow Inheritance (`extends`)

Workflows can inherit from a base workflow using `extends: <base-name>`:
- `steps` from child are appended after base steps
- `override` map merges fields into matching base step IDs
- `remove` list filters out base steps by ID
- `defaults` and `params` are merged (child overrides base)
- Resolved in `cq_resolve_workflow_inheritance()` in `lib/storage.sh`
- Validated for circular extends, nonexistent base, invalid override/remove IDs

### Enhanced Validation (`cq workflows validate`)

Beyond basic schema checks, validation detects:
- **Circular routing** — cycles without gates (infinite loop risk); gated cycles allowed
- **Missing context variables** — `{{var}}` in bash steps not declared in defaults/params
- **Unreachable steps** — steps not reachable from the first step via any route
- **Extends validation** — base exists, no circular extends, valid override/remove IDs

### CLI Output Hints

Commands emit natural language hints (to stderr) guiding Claude's next action:
- `cq start` → "Create a Task with TaskCreate to track this workflow run."
- `cq step-done` (gated) → "Use AskUserQuestion to prompt the user for approval."
- `cq step-done` (completed) → "Update the workflow Task to completed via TaskUpdate."
- `cq todos` → "Use AskUserQuestion to present these pending actions to the user."
- `cq resume` → "Enter the runner loop to continue from step '<step>'."

Hints are suppressed in `--json` mode. Helper: `cq_hint()` in `lib/core.sh`.

### Skill Integration with Claude Code

Skills (`/cq`, `/cq-worker`, `/cq-setup`) use precise tool call patterns for reliable Claude Code integration:
- **Task mirroring**: MANDATORY TaskCreate on workflow start, TaskUpdate on step progress/completion
- **TODO sync**: Lazy sync at explicit points — session start, gate events, workflow completion
- **Gates**: Exact AskUserQuestion patterns with options for approve/reject/override
- **Agent dispatch**: Exact Agent tool call with subagent_type, model, isolation parameters
- **Error recovery**: Log errors to context, mark step failed, continue runner loop

## Git Safety

Never run `git checkout` during active workflows. Commit `.claudekiq/` infrastructure files before any branch operations. Untracked files are destroyed by checkout.
