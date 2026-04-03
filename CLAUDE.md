# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claudekiq (`cq`) is a filesystem-backed workflow engine CLI for Claude Code. It orchestrates multi-step development workflows by coordinating AI agents, shell commands, and human approval gates. The CLI is written in Bash with `jq` and `yq` as dependencies.

## Key Files

- `cq` — Main CLI entry point (sources lib/*.sh)
- `lib/core.sh` — Utilities: UUID, timestamps, interpolation, conditions, config resolution, locking, hooks
- `lib/storage.sh` — Filesystem I/O for runs, steps, state, context, todos, routing
- `lib/commands.sh` — All command implementations
- `lib/schema.sh` — AI-discoverable JSON schemas for every command
- `lib/tracker.sh` — Issue tracker commenting (github, litetracker, custom)
- `lib/yaml.sh` — YAML-to-JSON conversion via yq
- `install.sh` — Installer script (local or remote)
- `technical_details.md` — Full technical design document

## Running Tests

```bash
bats tests/               # Run all tests (178 tests)
bats tests/test_e2e.bats  # Run only end-to-end tests
bats tests/test_start.bats --filter "pattern"  # Filter by name
```

Requires: `bash`, `jq`, `yq`, `bats`

## Architecture

- **CLI name**: `cq`
- **Language**: Bash + jq + yq
- **Storage**: Filesystem only — runs stored in `.claudekiq/runs/<run_id>/` (gitignored)
- **Config**: Global (`~/.cq/config.json`) + per-project (`.claudekiq/settings.json`), project overrides global
- **Workflows**: YAML files in `.claudekiq/workflows/` (committed) and `.claudekiq/workflows/private/` (gitignored). Global shared workflows in `~/.cq/workflows/`
- **AI discoverability**: `cq schema [command]` returns JSON command metadata
- **Step types**: `agent`, `skill`, `bash`, `manual`, `subflow`, plus custom plugins via `.claudekiq/plugins/<type>.sh`
- **Gates**: `auto` (continue), `human` (wait for approval), `review` (retry loop with max_visits escalation)
- **All commands support `--json`** for machine-readable output
- **Headless mode**: `--headless` flag for CI (auto-approves gates, JSON-only output)

## Git Safety

Never run `git checkout` during active workflows. Commit `.claudekiq/` infrastructure files before any branch operations. Untracked files are destroyed by checkout.
