# claudekiq

A workflow engine for automating development processes with Claude Code. Think Sidekiq, but for orchestrating AI agents, skills, and human decisions across your development lifecycle.

## What It Does

Claudekiq lets you define multi-step workflows (as YAML) that coordinate Claude Code agents, shell commands, and human approvals. Workflows run with persistent filesystem state, automatic retries, priority queuing, and human-in-the-loop gates when decisions can't be automated.

## Use Cases

- **Feature development**: Story intake → RFC → branch → implement → test → lint → code review → PR → deploy
- **Bug fixes**: Triage → investigate → branch → fix → test → review → PR → deploy
- **DevOps automation**: Infrastructure changes with approval gates and rollback steps
- **CI/CD orchestration**: Run workflows on integration servers via headless mode
- **Cross-project consistency**: Same workflow engine across web, mobile, and infrastructure projects

## Quick Start

```bash
# Install
bash install.sh

# Initialize in your project
cq init

# Create a workflow (.claudekiq/workflows/my-flow.yml)
# Start it
cq start my-flow --story_id=123 --stack=rails

# Check status
cq status

# Step through the workflow
cq step-done <run_id> <step_id> pass

# Handle human approvals
cq todos
cq todo 1 approve
```

## Workflow Example

```yaml
name: feature
description: Feature development workflow

defaults:
  stack: rails

steps:
  - id: implement
    name: Implement Changes
    type: agent
    target: "@{{stack}}-dev"
    args_template: "Implement: {{story_title}}"
    gate: human

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
    description: "Review changes for {{story_title}}"
    gate: human
```

## Commands

```
Workflow lifecycle:    start, status, list, log
Flow control:         pause, resume, cancel, retry
Step control:         step-done, skip
Human actions:        todos, todo
Context:              ctx, ctx get, ctx set
Dynamic modification: add-step, add-steps, set-next
Templates:            workflows list|show|validate
Configuration:        config, config get, config set
Setup:                init, version, help, schema
Maintenance:          cleanup
```

All commands support `--json` for machine-readable output.

## Design Goals

- **Project agnostic**: Works with any language, framework, or stack
- **Tool agnostic**: No lock-in to any project management tool — use with GitHub Issues, JIRA, Linear, or anything with a CLI
- **Configurable per project**: Global config (`~/.cq/config.json`) with per-project overrides (`.claudekiq/settings.json`)
- **Cross-platform**: macOS and Linux
- **AI-discoverable**: Built-in `cq schema` command so Claude Code agents can discover and invoke commands programmatically
- **Minimal dependencies**: Bash + `jq` + `yq`. Filesystem-only storage — no database required
- **Simple installation**: Single script to install globally, `cq init` to configure per project

## Project Structure

```
cq                         # CLI entry point
lib/
  core.sh                  # Utilities (config, interpolation, locking, hooks)
  storage.sh               # Filesystem I/O (runs, steps, state, context)
  commands.sh              # Command implementations
  schema.sh                # AI-discoverable command schemas
  yaml.sh                  # YAML parsing
install.sh                 # Installer
tests/                     # BATS test suite (111 tests)

.claudekiq/                # Per-project (created by cq init)
  settings.json            # Project config
  workflows/               # Workflow definitions (committed)
    private/               # Private workflows (gitignored)
  runs/                    # Run state (gitignored)
  plugins/                 # Custom step type handlers
```

## Inspiration

- [Sidekiq](https://github.com/sidekiq/sidekiq) — background job processing model
- [Google Workspace CLI](https://github.com/googleworkspace/cli) — CLI structure and discoverability
