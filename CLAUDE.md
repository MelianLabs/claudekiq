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
- `workers.sh` — `workers` (parallel orchestration)
- `iteration.sh` — `for-each`, `parallel`, `batch` (iteration CLI commands)

MCP server mode is in `lib/mcp.sh`, loaded on-demand.

### Storage Layout

All run state lives in `.claudekiq/runs/<run_id>/` (gitignored):
- `meta.json` — run metadata (workflow, status, priority, timestamps)
- `state.json` — per-step state (status, visit count, results)
- `context.json` — interpolation variables
- `steps.json` — resolved step definitions
- `log.jsonl` — append-only event log

### Key Concepts

- **Step types**: `bash`, `agent`, `skill`, `manual`, `subflow`, `for_each`, `parallel`, `batch`, plus custom types via agent-backed definitions (`.claude/agents/<type>.md`)
- **Gates**: `auto` (continue), `human` (wait for approval via `AskUserQuestion`), `review` (retry loop with max_visits escalation)
- **Interpolation**: `{{expr}}` in bash targets only, resolved from context via jq. Agent steps receive raw prompt + context — Claude decides how to use it. Supports nested access (`{{config.timeout}}`), array indexing (`{{items[0].name}}`), and jq expressions (`{{results | length}}`).
- **Config resolution**: global (`~/.cq/config.json`) merged with project (`.claudekiq/settings.json`), project wins
- **Agent mappings**: stored in `.claudekiq/settings.json` under `agent_mappings` key
- **All commands support `--json`** for machine-readable output
- **Headless mode**: `--headless` flag auto-approves gates and forces JSON output

### Project Setup (`cq init`)

`cq init` creates only:
- `.claudekiq/` directory structure (workflows, runs, settings.json)
- `.claude-plugin/plugin.json` pointing to `~/.cq/skills/`
- `.gitignore` entries

It does **not** touch `.claude/` (no skills, hooks, agents, or settings.json installed). Skills are served via the `.claude-plugin/plugin.json` plugin system from `~/.cq/skills/`.

### Hooks System (`cq hooks`)

Hooks are opt-in via `cq hooks install`:
- Merges cq-specific hooks into `.claude/settings.json` (SessionEnd, PreToolUse, SubagentStop, WorktreeCreate)
- `cq hooks uninstall` cleanly removes only cq hooks
- Configurable notification commands in `.claudekiq/settings.json` → `notifications`: `on_start`, `on_gate`, `on_fail`, `on_complete`
- `cq_fire_hook()` emits structured JSON events with version, status, and timestamp to stderr

### Project Discovery (`cq scan`)

`cq scan` discovers agents, skills, and stacks available in the project:
- Scans `.claude/agents/*.md` — parses YAML frontmatter for name, model, tools, description
- Scans `.claude/skills/*/SKILL.md` — parses frontmatter for name, description, allowed-tools
- Detects project stacks — returns `stacks` as an array (multi-stack support: e.g., Rails + React)
- Each stack object has: `language`, `framework`, `test_command`, `build_command`, `lint_command`
- Writes results to `.claudekiq/settings.json` as `agents`, `skills`, `stacks` arrays
- Preserves existing user config keys (including `agent_mappings`) during merge
- Auto-runs on `cq init` (both fresh and re-init)

### Agent Naming Convention

Agents are named after their stack: `@rails-dev`, `@react-dev`, `@go-dev`, etc. This convention replaces the generic `@implementer` pattern and makes agent purpose clear in workflows.

### Custom Step Types

Custom step types resolve via `cq_resolve_step_type()` in `lib/core.sh`:
1. Built-in types (`bash`, `agent`, `skill`, etc.)
2. Agent-backed: `.claude/agents/<type>.md` file exists
3. Scan results: `agents` array in settings.json
4. Otherwise: `"unknown"`

### Iteration Commands

CLI commands for executing `for_each`, `parallel`, and `batch` step types:

- `cq for-each` — standalone (`--over`, `--var`, `--command`) or workflow mode (`<run_id> <step_id>`)
- `cq parallel` — standalone (`--steps` JSON array) or workflow mode
- `cq batch` — standalone (`--workflow`, `--jobs`) or workflow mode; creates worker sessions

These handle bash sub-steps directly. Agent/skill sub-steps are deferred to the SKILL.md runner.

## Git Safety

Never run `git checkout` during active workflows. Commit `.claudekiq/` infrastructure files before any branch operations. Untracked files are destroyed by checkout.
