# claudekiq

A filesystem-backed workflow engine for Claude Code. Think Sidekiq, but for orchestrating AI agents, shell commands, and human decisions across your development lifecycle.

## What It Does

Claudekiq (`cq`) lets you define multi-step workflows as YAML that coordinate Claude Code agents, shell commands, and human approvals. Workflows run with persistent filesystem state, automatic retries, priority queuing, and human-in-the-loop gates when decisions can't be automated.

It ships with a Claude Code skill (`/cq`) that acts as the workflow runner — reading state, executing steps, handling gates, and driving workflows to completion automatically. It also works as an MCP plugin, exposing all commands as native Claude Code tools.

## Requirements

- **Bash** (4.0+)
- **[jq](https://jqlang.github.io/jq/download/)** — JSON processor
- **[yq](https://github.com/mikefarah/yq#install)** — YAML processor
- **[bats](https://github.com/bats-core/bats-core)** — for running tests (optional)

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/MelianLabs/claudekiq/main/install.sh | bash
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
git clone https://github.com/MelianLabs/claudekiq.git
cd claudekiq
bash install.sh
```

### Verify

```bash
cq version
# cq 1.0.0
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
- `.claude/skills/cq/SKILL.md` — the Claude Code runner skill
- `.mcp.json` — MCP plugin config for Claude Code

It also adds run data to `.gitignore` so workflow state doesn't pollute your repo.

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
    target: "@dev"
    args_template: "Fix the failing tests. Run npm test to see what's broken."
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

There are two ways to run workflows:

#### Option A: Using the `/cq` skill (recommended)

In Claude Code, type `/cq` to get an interactive workflow picker, or start one directly:

```
/cq deploy
/cq deploy --environment=production
```

The skill handles everything — executing steps, handling gates, asking for approvals, and driving the workflow to completion.

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
| `type` | How to execute: `bash`, `agent`, `skill`, `manual`, `subflow` |
| `target` | What to execute (command, agent role, skill name) |
| `args_template` | Arguments with `{{variable}}` interpolation |
| `gate` | What happens after: `auto`, `human`, `review` |

### Step Types

- **`bash`** — Run a shell command. Pass on exit 0, fail otherwise.
- **`agent`** — AI task. The `args_template` becomes the prompt; Claude does the work.
- **`skill`** — Invoke a Claude Code skill (e.g., `/commit`, `/review`).
- **`manual`** — Human action. Displays instructions and waits for approval.
- **`subflow`** — Insert steps from another workflow inline.

### Gates

Gates control what happens after a step completes:

- **`auto`** — Advance immediately to the next step.
- **`human`** — Pause and create a TODO. Wait for human approval before continuing.
- **`review`** — On pass, advance automatically. On fail, retry (up to `max_visits`) then escalate to human.

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

You can also use conditional routing:

```yaml
on_pass:
  - when: "{{environment}} == production"
    goto: staging-first
  - default: deploy
```

Without explicit routing, steps execute in order.

### Context & Interpolation

Workflows have a context object (key-value pairs). Use `{{variable}}` in targets and args to interpolate values:

```yaml
target: "git checkout -b feature/{{branch_name}} main"
args_template: "Implement: {{description}} using the {{stack}} framework"
```

Context is populated from:
- Workflow `defaults`
- `--key=val` arguments passed to `cq start`
- Step `outputs` extracted from results
- Manual updates via `cq ctx set <run_id> key value`

## The `/cq` Skill

When you run `cq init`, it installs a Claude Code skill at `.claude/skills/cq/SKILL.md`. This skill has three modes:

### `/cq` — Interactive picker

Lists available workflows and any active runs. Lets you choose what to start or resume.

### `/cq <workflow>` — Direct start

Starts a workflow immediately. Asks for required parameters if not provided:

```
/cq feature --description="add export command" --branch_name=add-export
```

### `/cq status` — Jobs dashboard

Shows a live dashboard of all running, gated, queued, and recently completed jobs:

```
📋 Claudekiq Jobs Dashboard
═══════════════════════════

🔄 Running (1)
  └─ [9b16d0f2] release — Step: bump-version 🔄

⏸️ Gated (1)
  └─ [abc12345] feature — Step: implement ⏸️ (awaiting approval)

✅ Recently Completed
  └─ [e62f4aa3] release — completed

📝 Pending TODOs (1)
  └─ #1 [abc12345] feature/implement — review implementation
```

Supports auto-refresh (polls every minute) so you can monitor workflows running in other Claude Code sessions.

## Real-World Example: Releasing cq v1.0.0

We used cq to release itself. Here's the release workflow:

```yaml
name: release
description: Cut a new cq release
default_priority: urgent

steps:
  - id: check-tests
    name: Run Full Test Suite
    type: bash
    target: "bats tests/"
    gate: auto

  - id: shellcheck
    name: Run ShellCheck
    type: bash
    target: "shellcheck cq lib/*.sh || true"
    gate: human

  - id: bump-version
    name: Bump Version
    type: agent
    target: "@cq-dev"
    args_template: "Bump CQ_VERSION in cq from current to {{new_version}}."
    gate: human

  - id: verify
    name: Verify Version
    type: bash
    target: "./cq version"
    gate: auto

  - id: final-tests
    name: Final Test Run
    type: bash
    target: "bats tests/"
    gate: auto

  - id: commit-tag
    name: Commit and Tag
    type: bash
    target: "git add -A && git commit -m 'Release v{{new_version}}' && git tag v{{new_version}}"
    gate: human

  - id: push
    name: Push Release
    type: bash
    target: "git push origin main --tags"
    gate: human
```

Running it:

```
/cq release
```

The skill asked for `new_version`, ran the test suite, executed ShellCheck (paused for human review), had Claude bump the version, verified it, ran tests again, then paused for approval before committing, tagging, and pushing. Each `human` gate gave us a chance to review before proceeding.

Meanwhile, `/cq status` tracked progress from another session:

```
🔄 Running (1)
  └─ [9b16d0f2] release — Step: final-tests 🔄
```

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
| `cq todo <number> approve\|reject\|override\|dismiss` | Resolve a TODO |

### Context

| Command | Description |
|---------|-------------|
| `cq ctx <run_id>` | Show context for a run |
| `cq ctx get <run_id> <key>` | Get a context value |
| `cq ctx set <run_id> <key> <value>` | Set a context value |

### Dynamic Modification

| Command | Description |
|---------|-------------|
| `cq add-step <run_id> --id=X --type=bash --target="cmd"` | Add a step to a running workflow |
| `cq add-steps <run_id> --flow <workflow> --after <step_id>` | Insert steps from another workflow |
| `cq set-next <run_id> <step_id>` | Jump to a specific step |

### Templates

| Command | Description |
|---------|-------------|
| `cq workflows list` | List available workflows |
| `cq workflows show <name>` | Show workflow definition |
| `cq workflows validate <name>` | Validate workflow YAML |

### Setup & Configuration

| Command | Description |
|---------|-------------|
| `cq init` | Initialize cq in a project |
| `cq config` | Show resolved configuration |
| `cq config get <key>` | Get a config value |
| `cq config set <key> <value>` | Set a project config value |
| `cq schema [command]` | Show command schemas (for AI agents) |
| `cq cleanup [--max-age=N]` | Remove old run data |
| `cq version` | Show version |
| `cq help` | Show help |

All commands support `--json` for machine-readable output.

### Heartbeat & Stale Detection

| Command | Description |
|---------|-------------|
| `cq heartbeat <run_id>` | Write a heartbeat timestamp for a running workflow |
| `cq check-stale [--timeout=N] [--mark]` | Detect runs with stale heartbeats |

The `/cq` skill automatically writes heartbeats before and after each step. If a runner crashes, `cq check-stale --mark` sets the run to `blocked` status, and `cq retry` recovers it.

### MCP Server

| Command | Description |
|---------|-------------|
| `cq mcp` | Start MCP stdio server (exposes all commands as Claude Code plugin tools) |

### Headless Mode

For CI/CD pipelines, use `--headless` to auto-approve all gates and output JSON only:

```bash
cq --headless start deploy --environment=staging
```

## MCP Plugin Mode

`cq` can run as a Claude Code MCP plugin, exposing all commands as native tools that Claude discovers automatically. This works alongside the existing skill-based integration.

### Setup

Register `cq` as an MCP server:

```bash
claude mcp add --transport stdio cq -- cq mcp
```

Or use the per-project `.mcp.json` (created automatically by `cq init`):

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

Once registered, Claude Code discovers `cq` tools automatically — no skill invocation needed. Tools are named `cq_start`, `cq_status`, `cq_step_done`, etc.

### Skill vs MCP

Both modes coexist. Use whichever fits your workflow:

| | Skill (`/cq`) | MCP (plugin) |
|-|---------------|--------------|
| **How** | User invokes `/cq` | Claude sees tools automatically |
| **Runner loop** | Skill drives the orchestration | Claude calls tools directly |
| **Best for** | Full workflow execution | Ad-hoc commands, custom orchestration |

Best experience is both together — the skill provides the orchestration logic, MCP provides raw tool access.

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
- `notifications` — hook commands for events (on_gate, on_fail, on_complete, on_start)

## Project Structure

```
~/.cq/                     # Global installation
  bin/cq                   # CLI binary
  lib/*.sh                 # Library files
  config.json              # Global config
  workflows/               # Shared workflows

.claudekiq/                # Per-project (created by cq init)
  settings.json            # Project config overrides
  workflows/               # Workflow definitions (committed)
    private/               # Private workflows (gitignored)
  runs/                    # Run state (gitignored)
  workers/                 # Worker session coordination (gitignored)
  plugins/                 # Custom step type handlers

.mcp.json                  # MCP plugin config (committed)
.claude/skills/cq/         # Claude Code runner skill (committed)
  SKILL.md                 # Skill definition
.claude/skills/cq-workers/ # Parallel workers skill (committed)
  SKILL.md                 # Skill definition
```

## Parallel Workers (`/cq-workers`)

The `/cq-workers` skill spawns multiple Claude instances to process jobs concurrently — each in its own git worktree, each running a `cq` workflow independently.

### Usage

```
/cq-workers bugfix --jobs='[
  {"id":"BUG-101","description":"login fails on Safari"},
  {"id":"BUG-102","description":"crash on CSV export"},
  {"id":"BUG-103","description":"timeout on large queries"}
]'
```

Or load jobs from a file:

```
/cq-workers bugfix --jobs-from=bugs.json
```

### How It Works

1. The parent (your main Claude instance) creates a **worker session** via `cq workers init`
2. For each job, it spawns a **background Agent** with `isolation: "worktree"` — giving each worker its own git worktree
3. Each worker runs `cq init` + `cq start <workflow>` and executes the full workflow independently
4. Workers write status updates to a shared coordination directory: `.claudekiq/workers/<session_id>/`
5. The parent monitors all workers via `cq workers status <session_id>`

### Gate Escalation

When a child worker hits a **human gate** (needs approval):
- The worker writes gate details to its status file and polls for an answer
- The parent detects the gate, shows you the details, and asks for your decision
- You approve/reject, the parent writes an answer file via `cq workers answer`
- The child picks up the answer and continues

### Headless Mode

Add `--headless` for fully autonomous execution (auto-approves all gates):

```
/cq-workers bugfix --jobs='[...]' --headless
```

### Dashboard

While workers are running, the parent shows a live dashboard:

```
🏭 Claudekiq Workers — Session abc12345
════════════════════════════════════════

🔄 Running (2)
  ├─ [BUG-101] login fails on Safari — Step: fix 🔄
  └─ [BUG-103] timeout on large queries — Step: investigate 🔄

⏸️ Gated (1)
  └─ [BUG-102] crash on CSV export — Step: fix ⏸️ (needs review)

✅ Completed (0)

Workers: 3 spawned, 2 running, 1 gated, 0 done
```

### CLI Commands

| Command | Description |
|---------|-------------|
| `cq workers init` | Create a new worker session |
| `cq workers status <session_id>` | Show status of all workers in a session |
| `cq workers answer <sid> <job_id> <action> [data]` | Send answer to a gated worker |
| `cq workers cleanup [--max-age=N]` | Remove old worker sessions |

### Coordination Directory

```
.claudekiq/workers/                    # Gitignored
  <session_id>/
    manifest.json                      # Session metadata
    <job_id>.status.json               # Written by child (status updates)
    <job_id>.answer.json               # Written by parent (gate responses)
```

## Design Principles

- **Project agnostic** — works with any language, framework, or stack
- **Tool agnostic** — no lock-in to any project management tool
- **Filesystem-only** — no database, no external services, just files
- **AI-discoverable** — `cq schema` exposes command metadata for agents
- **Human-in-the-loop** — gates ensure humans stay in control of critical decisions
- **Minimal dependencies** — Bash + jq + yq

## Running Tests

```bash
bats tests/                              # All tests (170 tests)
bats tests/test_e2e.bats                 # End-to-end tests
bats tests/test_start.bats --filter "pattern"  # Filter by name
```

## Inspiration

- [Sidekiq](https://github.com/sidekiq/sidekiq) — background job processing model
- [Google Workspace CLI](https://github.com/googleworkspace/cli) — CLI structure and discoverability
