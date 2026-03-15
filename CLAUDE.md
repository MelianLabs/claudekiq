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

- `setup.sh` — `init`, `version`, `help`
- `scan.sh` — `scan` (discover agents, skills, plugins)
- `lifecycle.sh` — `start`, `status`, `list`, `log`
- `flow.sh` — `pause`, `resume`, `cancel`, `retry`
- `steps.sh` — `step-done`, `skip`
- `todos.sh` — `todos`, `todo`
- `ctx.sh` — `ctx` (get/set context)
- `dynamic.sh` — `add-step`, `add-steps`, `set-next`
- `workflows.sh` — `workflows` (list/show/validate)
- `config.sh` — `config` (get/set)
- `maintenance.sh` — `cleanup`, `heartbeat`, `check-stale`
- `workers.sh` — `workers` (parallel orchestration)

MCP server mode is in `lib/mcp.sh`, loaded on-demand.

### Storage Layout

All run state lives in `.claudekiq/runs/<run_id>/` (gitignored):
- `meta.json` — run metadata (workflow, status, priority, timestamps)
- `state.json` — per-step state (status, visit count, results)
- `context.json` — interpolation variables
- `steps.json` — resolved step definitions
- `log.jsonl` — append-only event log

### Key Concepts

- **Step types**: `bash`, `agent`, `skill`, `manual`, `subflow`, `for_each`, `parallel`, `batch`, plus custom types via agent-backed plugins (`.claude/agents/<type>.md`) or bash plugins (`.claudekiq/plugins/<type>.sh`)
- **Gates**: `auto` (continue), `human` (wait for approval), `review` (retry loop with max_visits escalation)
- **Interpolation**: `{{variable}}` in targets/args, resolved from context
- **Config resolution**: global (`~/.cq/config.json`) merged with project (`.claudekiq/settings.json`), project wins
- **All commands support `--json`** for machine-readable output
- **Headless mode**: `--headless` flag auto-approves gates and forces JSON output

### Project Discovery (`cq scan`)

`cq scan` discovers agents, skills, and plugins available in the project:
- Scans `.claude/agents/*.md` — parses YAML frontmatter for name, model, tools, description
- Scans `.claude/skills/*/SKILL.md` — parses frontmatter for name, description, allowed-tools
- Scans `.claudekiq/plugins/*.sh` — detects bash plugin scripts
- Writes results to `.claudekiq/settings.json` as `agents`, `skills`, `plugins` arrays
- Preserves existing user config keys during merge

### Plugin System

Custom step types resolve in order: agent-backed (`.claude/agents/<type>.md`) → bash plugin (`.claudekiq/plugins/<type>.sh`) → scan results fallback.

Bash plugin JSON protocol:
- **stdin**: Step JSON (interpolated)
- **stdout**: `{"status":"pass"|"fail", "output":{...}, "error":"..."}`
- **exit code**: 0 = pass, non-zero = fail
- **Environment**: `CQ_RUN_ID`, `CQ_STEP_ID`, `CQ_PROJECT_ROOT`

The `cq_resolve_step_type()` function in `lib/core.sh` handles resolution.

## Git Safety

Never run `git checkout` during active workflows. Commit `.claudekiq/` infrastructure files before any branch operations. Untracked files are destroyed by checkout.
