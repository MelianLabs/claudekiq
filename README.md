# claudekiq

A filesystem-backed workflow engine for Claude Code. Think Sidekiq, but for orchestrating AI agents, shell commands, and human decisions across your development lifecycle.

## What It Does

Claudekiq (`cq`) lets you define multi-step workflows as YAML that coordinate Claude Code agents, shell commands, and human approvals. Workflows run with persistent filesystem state, automatic retries, priority queuing, and human-in-the-loop gates when decisions can't be automated.

It ships with five Claude Code skills:
- **`/cq`** — Entry point: start, resume, and monitor workflows
- **`/cq-runner`** — Execution loop: dispatches steps, manages flow
- **`/cq-approve`** — Gate handler: presents approvals and escalations to users
- **`/cq-worker`** — Agent step executor with heartbeat, resume, and result extraction
- **`/cq-setup`** — Smart project discovery and optional workflow generation

It also works as an MCP plugin, exposing all commands as native Claude Code tools.

## Requirements

- **Bash** (4.0+)
- **[jq](https://jqlang.github.io/jq/download/)** — JSON processor
- **[yq](https://github.com/mikefarah/yq#install)** — YAML processor
- **[bats](https://github.com/bats-core/bats-core)** — for running tests (optional)

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/robertgrig/claudekiq/main/install.sh | bash
```

This installs `cq` to `~/.cq/bin/`. Add it to your PATH:

```bash
# bash
echo 'export PATH="$HOME/.cq/bin:$PATH"' >> ~/.bashrc

# zsh
echo 'export PATH="$HOME/.cq/bin:$PATH"' >> ~/.zshrc

# fish
fish_add_path ~/.cq/bin
```

### From Source

```bash
git clone https://github.com/robertgrig/claudekiq.git
cd claudekiq
bash install.sh
```

### Verify

```bash
cq version
# cq 3.2.9
```

## Getting Started

### 1. Initialize in your project

```bash
cd your-project
cq init
```

This creates:
- `.claudekiq/` — project directory (workflows, settings, runs)
- `.claudekiq/workflows/` — where you put workflow YAML files
- `.claude-plugin/plugin.json` — plugin manifest (version auto-synced, user skills preserved on re-init)
- `.claude/settings.json` — hooks for safety checks and context staging
- `.claude/cq.md` — auto-generated context file with workflows, agents, stacks, and usage patterns

Init is smart — it auto-scans for agents, skills, and stacks, reports what it found, and suggests next steps. Run `/cq-setup` inside Claude Code to generate customized workflows, or just start with `/cq-setup` directly (it self-initializes if needed).

### 2. Create a workflow

Create `.claudekiq/workflows/deploy.yml`:

```yaml
name: deploy
description: Build, test, and deploy the app

defaults:
  environment: staging

steps:
  - id: build
    name: Build
    type: bash
    target: "npm run build"
    gate: auto

  - id: test
    name: Run Tests
    type: bash
    target: "npm test"
    gate: review
    max_visits: 3
    on_pass: deploy
    on_fail: fix-tests

  - id: fix-tests
    name: Fix Failing Tests
    type: agent
    target: "@node-dev"
    prompt: "Fix the failing tests. Run npm test to see what's broken."
    gate: auto
    next: test

  - id: deploy
    name: Deploy to Environment
    type: bash
    target: "npm run deploy -- --env={{environment}}"
    gate: human
    next: end
```

### 3. Run it

#### Option A: Using the `/cq` skill (recommended)

In Claude Code, type `/cq` for an interactive workflow picker, or start one directly:

```
/cq deploy
/cq deploy --environment=production
```

The skill handles everything — executing steps, handling gates, asking for approvals via `AskUserQuestion`, tracking progress with `TaskCreate`/`TaskUpdate`, and syncing TODOs with `TodoWrite`.

#### Option B: Using the CLI directly

```bash
# Start
cq start deploy --environment=production

# Check status
cq status <run_id>

# Mark steps done
cq step-done <run_id> <step_id> pass

# Handle approvals
cq todos
cq todo 1 approve
```

## How It Works

### Workflow Anatomy

A workflow is a YAML file with **steps**. Each step has:

| Field | Description |
|-------|-------------|
| `id` | Unique identifier |
| `type` | How to execute: `bash`, `agent`, `skill`, `parallel`, `workflow`, or convention-based custom name |
| `target` | What to execute (command, agent role, skill name) |
| `prompt` | Goal description for agent steps |
| `gate` | What happens after: `auto`, `human`, `review` |

### Step Types

- **`bash`** — Run a shell command. Pass on exit 0, fail otherwise. Supports `{{variable}}` interpolation.
- **`agent`** — AI task. Use `@agent-name` to target a specific agent, or leave empty for inline execution. Supports `isolation: worktree`.
- **`skill`** — Invoke a Claude Code skill (e.g., `/commit`, `/review`).
- **`parallel`** — Run multiple branches concurrently via Claude Code's `/batch` skill.
- **`workflow`** — Start a sub-workflow with context mapping and output propagation.
- **Convention-based** — Any custom type name (e.g., `review`, `deploy`, `migrate`) is treated as an agent step with semantic context.

### Gates

Gates control what happens after a step completes:

- **`auto`** — Advance immediately to the next step.
- **`human`** — Pause and create a TODO. The `/cq` skill uses `AskUserQuestion` for inline approval.
- **`review`** — On pass, advance. On fail, retry up to `max_visits`, then escalate to human.

### Routing

Steps can define explicit routing:

```yaml
- id: test
  type: bash
  target: "npm test"
  gate: review
  max_visits: 5
  on_pass: deploy        # Go here on success
  on_fail: fix-tests     # Go here on failure
```

Conditional routing:

```yaml
next:
  - when: "{{environment}} == production"
    goto: staging-first
  - default: deploy
```

Without explicit routing, steps execute in order.

### Workflow Inheritance

Workflows can inherit from a base workflow using `extends`:

```yaml
name: feature
extends: base
description: Feature workflow extending base

steps:
  - id: plan
    name: Plan Feature
    type: agent
    prompt: "Plan the feature implementation."
    gate: human

override:
  run-tests:
    gate: review
    max_visits: 5

remove:
  - code-review
```

### Context & Interpolation

Workflows have a context object (key-value pairs). Use `{{expression}}` in bash targets to interpolate values via jq:

```yaml
target: "git checkout -b feature/{{branch_name}} main"
# Nested access:
target: "echo {{config.timeout}}"
# Array indexing:
target: "deploy {{servers[0].host}}"
# jq expressions:
target: "echo {{items | length}} items"
```

Context is populated from workflow `defaults`, `--key=val` arguments, step `outputs`, and `cq ctx set`.

## The `/cq` Skill

The `/cq` skill integrates deeply with Claude Code's built-in tools:

- **TaskCreate/TaskUpdate** — Mirrors workflow progress in the session UI
- **TodoWrite/TodoRead** — Lazy sync of filesystem TODOs at session start, gate events, and completion
- **AskUserQuestion** — Inline approval prompts with exact option patterns for gates
- **Agent** — Dispatches to named agents with model selection and isolation support
- **CronCreate/CronDelete** — Heartbeat management for long-running agents

### `/cq` — Interactive picker

Lists available workflows and active runs. Lets you choose what to start or resume.

### `/cq <workflow>` — Direct start

Starts a workflow immediately. Asks for required parameters:

```
/cq feature --description="add export command" --branch_name=add-export
```

### `/cq status` — Jobs dashboard

Shows all running, gated, queued, and recently completed jobs.

## CLI Reference

### Workflow Lifecycle

| Command | Description |
|---------|-------------|
| `cq start <workflow> [--key=val...]` | Start a workflow run |
| `cq status [run_id]` | Show run status (or all runs) |
| `cq list` | List all runs |
| `cq log <run_id>` | Show event log for a run |

### Flow Control

| Command | Description |
|---------|-------------|
| `cq pause <run_id>` | Pause a running workflow |
| `cq resume <run_id>` | Resume a paused workflow |
| `cq cancel <run_id>` | Cancel a workflow |
| `cq retry <run_id>` | Retry a failed workflow |

### Step Control

| Command | Description |
|---------|-------------|
| `cq step-done <run_id> <step_id> pass\|fail [result]` | Mark a step complete |
| `cq skip <run_id>` | Skip the current step |

### Human Actions

| Command | Description |
|---------|-------------|
| `cq todos` | List pending TODOs across all runs |
| `cq todos sync` | Export TODOs in native TodoWrite format |
| `cq todo <number> approve\|reject\|override\|dismiss` | Resolve a TODO |

### Context

| Command | Description |
|---------|-------------|
| `cq ctx <run_id>` | Show context for a run |
| `cq ctx get <key> <run_id>` | Get a context value |
| `cq ctx set <key> <value> <run_id>` | Set a context value |

### Dynamic Modification

| Command | Description |
|---------|-------------|
| `cq add-step <run_id> <step_json> [--after <step_id>]` | Add a step to a running workflow |
| `cq add-steps <run_id> --flow <workflow> [--after <step_id>]` | Insert steps from another workflow |
| `cq set-next <run_id> <step_id> <target>` | Force next step routing |

### Templates

| Command | Description |
|---------|-------------|
| `cq workflows list` | List available workflows |
| `cq workflows show <name>` | Show workflow definition |
| `cq workflows validate <name>` | Validate workflow YAML |
| `cq validate <name>` | Validate a workflow (shorthand) |

### Setup & Configuration

| Command | Description |
|---------|-------------|
| `cq init` | Initialize cq in a project (smart: scans, hooks, hints) |
| `cq scan` | Discover agents, skills, and stacks |
| `cq hooks install\|uninstall` | Manage hooks in .claude/settings.json |
| `cq config` | Show resolved configuration |
| `cq config get <key>` | Get a config value |
| `cq config set <key> <value>` | Set a project config value (supports dot-notation: `safety.git_commit`) |
| `cq config set --global <key> <value>` | Set a global config value |
| `cq schema [command]` | Show command schemas (for AI agents) |
| `cq cleanup` | Remove old run data |
| `cq version` | Show version |
| `cq help` | Show help |

All commands support `--json` for machine-readable output.

### Safety & Hooks

| Command | Description |
|---------|-------------|
| `cq _safety-check <operation>` | Check per-operation safety policy (used by hooks) |
| `cq heartbeat <run_id>` | Write a heartbeat timestamp |
| `cq check-stale [--timeout=N] [--mark]` | Detect runs with stale heartbeats |

Safety supports both simple (`strict`/`relaxed`) and per-operation policy maps:

```bash
cq config set safety relaxed                    # all operations warn
cq config set safety.git_commit warn            # specific operation
cq config set safety.rm_claudekiq block         # specific operation
```

### MCP Server

| Command | Description |
|---------|-------------|
| `cq mcp` | Start MCP stdio server (exposes all commands as Claude Code tools) |

### Headless Mode

For CI/CD pipelines, use `--headless` to auto-approve all gates and output JSON only:

```bash
cq --headless start deploy --environment=staging
```

## Configuration

### Global config (`~/.cq/config.json`)

```json
{
  "prefix": "cq",
  "ttl": 2592000,
  "default_priority": "normal",
  "concurrency": 1
}
```

### Project config (`.claudekiq/settings.json`)

Project settings override global. You can set:

- `concurrency` — max simultaneous runs (default: 1)
- `default_priority` — for new runs (urgent, high, normal, low)
- `ttl` — seconds before old runs are cleaned up
- `min_cq_version` — warn if installed cq is too old
- `safety` — per-operation safety policy (`strict`, `relaxed`, or operation map)
- `notifications` — hook commands for events (on_gate, on_fail, on_complete, on_start)
- `agent_mappings` — map agent names to alternative targets

## Project Structure

```
~/.cq/                     # Global installation
  bin/cq                   # CLI binary
  lib/*.sh                 # Library files
  skills/                  # Skill definitions (cq, cq-runner, cq-approve, cq-worker, cq-setup)
  config.json              # Global config
  workflows/               # Shared workflows

.claudekiq/                # Per-project (created by cq init)
  settings.json            # Project config overrides
  workflows/               # Workflow definitions (committed)
    private/               # Private workflows (gitignored)
  runs/                    # Run state (gitignored)
.claude-plugin/
  plugin.json              # Plugin manifest (points to ~/.cq/skills/)
.claude/
  settings.json            # Hooks (auto-installed by cq init)
  cq.md                    # Auto-generated project context
```

## Discovery & Scanning

`cq scan` discovers available agents, skills, and project stacks:

```bash
cq scan --json
# {"agents":[...],"skills":[...],"stacks":[...],"scanned_at":"..."}
```

### Multi-Stack Detection

Projects with multiple stacks (e.g., Rails + React) are fully supported:

```json
{
  "stacks": [
    {"language": "ruby", "framework": "rails", "test_command": "bundle exec rspec"},
    {"language": "javascript", "framework": "react", "test_command": "npm test"}
  ]
}
```

### Agent Naming Convention

Name agents after their stack: `@rails-dev`, `@react-dev`, `@go-dev`:

```yaml
- id: fix-backend
  type: agent
  target: "@rails-dev"
  prompt: "Fix the failing API tests."
```

## Enhanced Validation

`cq workflows validate` checks beyond basic schema:

- **Circular routing** — cycles without gates (infinite loop risk)
- **Missing context variables** — `{{var}}` in bash steps not declared
- **Unreachable steps** — steps not reachable from the first step
- **Extends validation** — base exists, no circular extends

## Running Tests

```bash
bats tests/                              # All tests (341 tests)
bats tests/test_e2e.bats                 # End-to-end tests
bats tests/test_start.bats --filter "pattern"  # Filter by name
```

## Design Principles

- **Extend Claude Code, don't reinvent it** — uses built-in Agent, Task, Todo, AskUserQuestion tools
- **Project agnostic** — works with any language, framework, or stack
- **Filesystem-only** — no database, no external services, just files
- **AI-discoverable** — `cq schema` exposes command metadata for agents
- **Human-in-the-loop** — gates ensure humans stay in control of critical decisions
- **Minimal dependencies** — Bash + jq + yq

## Inspiration

- [Sidekiq](https://github.com/sidekiq/sidekiq) — background job processing model
- [Google Workspace CLI](https://github.com/googleworkspace/cli) — CLI structure and discoverability
