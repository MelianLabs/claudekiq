# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claudekiq (`cq`) is a filesystem-backed workflow engine CLI for Claude Code. It orchestrates multi-step development workflows by coordinating AI agents, shell commands, and human approval gates. Written in Bash with `jq` and `yq` as dependencies. Designed as a **thin orchestration layer** that delegates everything possible to Claude Code.

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

### Skill Architecture

**`/cq` is the only user-facing skill.** All other skills are internal implementation details:
- `/cq` — Entry point: start, resume, monitor, init, setup, approve
- `/cq-runner` — Internal: step execution loop (called by `/cq`)
- `/cq-approve` — Internal: gate handling (called by `/cq-runner`)
- `/cq-worker` — Internal: agent step execution (called by `/cq-runner`)
- `/cq-setup` — Internal: project discovery and workflow creation (called by `/cq setup`)

Skills are registered as `.claude/commands/` symlinks pointing to `~/.cq/skills/`. Internal skills are invoked programmatically via `Skill()`.

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

Active runs index: `.claudekiq/.active_runs` — lightweight file listing active run IDs for fast hook lookups.

### Key Concepts

- **Step types**: `bash`, `agent`, `skill`, `batch`, `parallel` (built-in). Unknown step types are **errors** — convention-based custom types are no longer supported. All step types must be either built-in or resolve to a known agent file. `batch` delegates to Claude Code's `/batch` for parallel execution; `parallel` is a deprecated alias for `batch`.
- **Parallel strategies**: `batch` (structured, via `/batch` skill) or `managed` (Claude manages parallel execution directly)
- **Gates**: `auto` (continue), `human` (wait for approval via `AskUserQuestion`), `review` (retry loop with max_visits escalation)
- **Interpolation**: `{{expr}}` in bash targets only, resolved from context via jq. Agent steps receive raw prompt + context — Claude decides how to use it. Supports nested access (`{{config.timeout}}`), array indexing (`{{items[0].name}}`), and jq expressions (`{{results | length}}`).
- **Config resolution**: global (`~/.cq/config.json`) merged with project (`.claudekiq/settings.json`), project wins
- **Agent mappings**: stored in `.claudekiq/settings.json` under `agent_mappings` key
- **All commands support `--json`** for machine-readable output
- **Headless mode**: `--headless` flag auto-approves gates and forces JSON output

### Project Setup (`cq init`)

`cq init` creates `.claudekiq/` structure, installs hooks, scans project, and outputs context-aware discovery hints:
- `.claudekiq/` directory structure (workflows, runs, settings.json)
- `.claude/commands/` — relative symlinks to `~/.cq/skills/` for Claude Code command discovery
- `.claude-plugin/plugin.json` — plugin manifest with relative paths (version auto-synced from `$CQ_VERSION`)
- `.gitignore` entries
- Smart output: reports discovered agents, stacks, and available workflows
- JSON output includes `agents_found`, `stacks_found`, `workflows_found` counts

Hooks are auto-installed into `.claude/settings.json`.

`/cq setup` is the user-facing command for project discovery and workflow creation.

### Hooks System (`cq hooks`)

Hooks are auto-installed by `cq init`. Only hooks that Claude Code doesn't already handle:
- **PreToolUse**: Protect `.claudekiq/runs/` from direct edits, block `git checkout` during active workflows, protect `.claudekiq/` from deletion
- **PostToolUse**: Stage context for active workflow steps, capture agent output, desktop notifications
- **SessionEnd**: Check for stale runs
- **WorktreeCreate**: Auto-init cq in new worktrees

Safety hooks for git operations (force-push, reset --hard, rebase, commit) are delegated to Claude Code's built-in safety model.

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

### Step Type Resolution

Step types resolve via `cq_resolve_step_type()` in `lib/core.sh`:
1. Built-in types (`bash`, `agent`, `skill`, `batch`, `parallel`, `workflow`) → returns `"builtin"`
2. Agent-backed: `.claude/agents/<type>.md` file exists → returns `"agent"`
3. Scan results: `agents` array in settings.json → returns `"agent"`
4. Otherwise: returns `"unknown"` — **this is an error**. All step types must be explicitly defined.

### Step Output Capture

`cq step-done` supports `--output=<text>` and `--stderr=<text>` flags:
- Output is stored in `state.json` as `.output` and `.error_output` per step
- Truncated output (500 chars) is included in log events
- On retry, previous `error_output` is available via the `error_context` context builder
- Works for both pass and fail outcomes

### Context Builders

Agent steps can define `context_builders` to automatically gather context before dispatch. Each builder supports optional `max_lines` to override defaults:

```yaml
context_builders:
  - type: git_diff          # git diff HEAD output (default: 200 lines)
  - type: file_contents     # requires paths: ["file1", "file2"] (default: 100 lines per file)
    paths: ["src/app.ts"]
    max_lines: 50           # optional: override default
  - type: error_context     # previous step error_output (default: 100 lines)
  - type: test_output       # requires command (default: 50 lines)
    command: "npm test 2>&1 | tail -50"
  - type: command_output    # requires command (default: 50 lines)
    command: "echo hello"
```

Global override: `cq config set context_builder_max_lines 150`

Resolved via `cq _resolve-context <run_id> <step_id>`. Implementation in `cq_resolve_context_builders()` in `lib/core.sh`.

### Context File (`.claude/cq.md`)

`cq init` and `cq scan` generate `.claude/cq.md` with concise project context:
- Available workflows with descriptions and params
- Detected agents and stacks
- Usage patterns (`/cq`, `/cq setup`, `/cq status`)

Claude Code loads this automatically so it always knows the project's workflow capabilities.

### Safety Configuration

The `safety` config key controls hook behavior for cq-specific operations. Only operations Claude Code doesn't handle natively:

**Simple (backward-compatible):**
- `"strict"` (default) — hooks block dangerous operations (exit 2)
- `"relaxed"` — hooks warn but allow operations (exit 0)

**Per-operation policy map:**
```json
{
  "safety": {
    "git_checkout": "block",
    "rm_claudekiq": "block",
    "edit_run_files": "warn"
  }
}
```

Set via: `cq config set safety relaxed` or `cq config set safety.git_checkout warn`

Supported cq-specific operations: `rm_claudekiq`, `git_checkout`, `edit_run_files`

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
- **Unknown step types** — step types that are not built-in or known agents are errors
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

**Task mirroring is fire-and-forget**: TaskCreate/TaskUpdate calls are best-effort UI projections. `meta.json` is the source of truth. No `_task_id` is stored in context.

- **TODO sync**: Filesystem TODOs are the persistent source of truth (survives across sessions). Native TodoRead/TodoWrite is a session-scoped UI projection synced lazily.
- **Gates**: Exact AskUserQuestion patterns with options for approve/reject/override
- **Agent dispatch**: Exact Agent tool call with subagent_type, model, isolation parameters
- **Error recovery**: Log errors to context, mark step failed, continue runner loop

## Path Rules

Never use hardcoded absolute home directory paths (e.g., `/Users/someone/.cq/`). When generating symlinks, config files, or plugin.json entries that reference `~/.cq/`, always use **relative paths**. Use `python3 -c "import os; print(os.path.relpath(target, start))"` to compute them.

## Git Safety

Never run `git checkout` during active workflows. Commit `.claudekiq/` infrastructure files before any branch operations. Untracked files are destroyed by checkout.
