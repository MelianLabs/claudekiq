---
name: cq
description: "Claudekiq workflow runner — orchestrates multi-step development workflows. Use /cq to list and run workflows, /cq <workflow> to start a specific one, or /cq status to monitor all jobs."
argument-hint: "[workflow] [--key=val...]"
allowed-tools: Bash, Read, Agent, Skill, TaskCreate, TaskUpdate, TodoRead, TodoWrite, CronCreate, CronDelete, AskUserQuestion
---

# Claudekiq Workflow Runner

## Prerequisites
If any required tool (Agent, Skill, etc.) is unavailable, report the error clearly and suggest running via CLI instead.

You are the runner for `cq` (claudekiq), a filesystem-backed workflow engine. You are a **slim state machine** that drives workflows by dispatching steps to the right executor and managing transitions.

## Current State

Available workflows:
`!cq workflows list --json 2>/dev/null || echo "[]"`

Active runs:
`!cq list --json 2>/dev/null || echo "[]"`

Project inventory (agents, skills, stacks):
`!jq '{agents: (.agents // []) | map(.name), skills: (.skills // []) | map(.name), stacks: (.stacks // []) | map({language, framework})}' .claudekiq/settings.json 2>/dev/null || echo "{}"`

## Invocation

Parse the arguments passed to this skill:

- **No arguments (`/cq`)**: Interactive mode — list workflows and let the user pick one
- **Status dashboard (`/cq status`)**: Show all running and pending jobs
- **With workflow name (`/cq feature`)**: Start that workflow directly
- **With workflow + params (`/cq feature --description="add export"`)**: Start with those context variables

## Interactive Mode (no arguments)

1. Run: `cq workflows list --json` and `cq status --json`
2. If there are **active runs** (running, gated, paused): show them, ask "Resume or start new?"
3. If starting new: present workflow list, ask which to run
4. Proceed to **Start Workflow**

## Start Workflow

1. Run: `cq workflows show <name> --json`
2. Check for `params` section — for each parameter with an **empty default** not provided via arguments, ask the user for a value using `AskUserQuestion`
3. Run: `cq start <name> --key=val... --json` — capture the `run_id`
4. Create a workflow-level Task: `TaskCreate(name: "cq: <workflow> — <description>", description: "Running workflow <workflow> (run: <run_id>)")`
5. Enter the **Runner Loop**

## Runner Loop

Repeat until terminal state:

### 1. Read State
```bash
cq status <run_id> --json
```
Extract: `meta.status`, `meta.current_step`, `steps`, `state`, `ctx`

### 2. Check Terminal States
- `completed` → Report success. Stop.
- `failed` → Report failure. Stop.
- `cancelled` → Report cancellation. Stop.
- `blocked` → Ask user: retry or cancel.

### 3. Handle Gates
If `meta.status` is `gated`:

**Default: Use `AskUserQuestion`** for all interactive gates. This provides immediate inline user interaction and is the primary gate mechanism.

**Simple gate** (single approval, interactive session):
- Use `AskUserQuestion` inline: "Step '<name>' needs approval. Approve or reject?"
- Based on response: `cq todo <number> approve|reject`

**Complex gate** (multi-field, review escalation at max_visits):
- Run `cq todos --json` to list pending actions
- Present the TODO details to the user
- Use `AskUserQuestion` for each decision
- Apply: `cq todo <number> <action>`

**Headless mode** (`--headless`):
- Auto-approve all gates (existing behavior)

> **Note:** The `cq todos`/`cq todo` CLI exists for programmatic and cross-session gate handling, but in interactive sessions always prefer `AskUserQuestion` for immediate user interaction.

Return to step 1.

### 4. Dispatch Step

Find current step definition. Based on `type`:

#### `bash`
Run **interpolated** target via Bash tool. Exit 0 = pass, non-zero = fail.
Use `cq_interpolate` for `{{variable}}` substitution in the target command.

#### `agent`
Invoke `/cq-agent` sub-skill with **raw** prompt + context (no interpolation):
```
Skill: "cq-agent"
Args: "<run_id> <step_id>"
```
The sub-skill handles prompt assembly, model selection, agent spawning, heartbeat, resume, and result extraction autonomously. Read its response to determine outcome and extract results into context.

#### `skill`
Invoke the Skill tool with the target skill name and interpolated arguments.

#### `parallel`
Delegates to Claude Code's built-in `/batch` skill for concurrent execution:
1. Read `branches` array from step definition
2. Convert each branch into a batch item prompt describing its type + target/prompt
3. Invoke: `Skill("batch", "<description of all branches to run>")`
4. When `/batch` completes, map results back to branch outcomes
5. Build branches result JSON: `{"branch_id": {"status": "passed"|"failed", "result": "pass"|"fail"}, ...}`
6. Call: `cq step-done <run_id> <step_id> pass|fail --branches='<branches_json>'`
7. Wait-all semantics: step passes only if ALL branches passed

Store branch results in context under `<parallel_step_id>.<branch_id>` namespace.

#### `workflow` (sub-workflow)
Starts a child workflow with inherited context:
1. Read `template`, `context_map`, and `outputs` from step definition
2. Build context args from `context_map` (interpolated from parent context)
3. Start child: `cq start <template> --parent=<run_id> --parent-step=<step_id> --key=val... --json`
4. Enter a nested runner loop for the child workflow (same logic as main runner)
5. On child completion, outputs are auto-copied back to parent context under `sub_<step_id>.<key>`
6. The parent step is auto-completed when the child finishes

#### Convention-based type (any custom name)
For any type not listed above (e.g., `review`, `deploy`, `migrate`), treat it as an agent step. The type name provides semantic context for the agent. Dispatch to `/cq-agent` with the type name included in the prompt context.

### 5. Handle Timeouts
If step has `timeout:`:
- **bash**: wrap with `timeout <seconds> <command>`
- **agent/skill**: `/cq-agent` handles timeout internally

### 6. Mark Step Complete
```bash
cq step-done <run_id> <step_id> pass|fail [result_json]
```

After marking complete:
- Update per-step Task status
- Update workflow Task with progress: `"Step <n>/<total>: <next_step>"`

### 7. Re-read and Loop
Re-read status. The `cq step-done` command handles gate logic internally:
- **auto** → advances automatically
- **human** → creates TODO, sets `gated`
- **review (pass)** → advances
- **review (fail)** → under max_visits routes via `on_fail`; at max_visits creates TODO

Return to step 1.

## TODO Sync (Bidirectional with Native System)

The filesystem is the **source of truth** for TODOs. Sync with Claude Code's native `TodoRead`/`TodoWrite` for in-session visibility.

### On Session Start (before entering runner loop)
1. Run: `cq todos sync --json` — get all pending TODOs in native format
2. For each TODO in the response, call `TodoWrite` to create/update it in the native system:
   - `TodoWrite(todos: [{id: "<todo_id>", content: "<content>", status: "in_progress", priority: "<priority>"}])`
3. This ensures any cross-session TODOs from previous runs are visible immediately

### On Gate Event (when run becomes `gated`)
1. After `cq todos --json` lists the new TODO:
   - Call `TodoWrite` to push the new TODO to native: `TodoWrite(todos: [{id: "<todo_id>", content: "[cq] <step_name> — <action>", status: "in_progress", priority: "<priority>"}])`
2. After user resolves via `AskUserQuestion` and `cq todo <#> approve|reject`:
   - Call `TodoWrite` to mark native TODO as completed: `TodoWrite(todos: [{id: "<todo_id>", status: "completed"}])`

### On Workflow Completion
1. Call `TodoRead` to check for any lingering native TODOs for this workflow
2. Mark all as completed via `TodoWrite`

### Conflict Resolution
- Filesystem always wins. If a TODO was resolved in the filesystem (via CLI or another session), the native TODO is updated to match on next sync.

## Task Mirroring

Use Tasks as a session-scoped UI mirror of filesystem state:
- On workflow start: `TaskCreate` with workflow name and description
- On each step start: `TaskCreate` with step name
- On step done: `TaskUpdate` to completed
- On session restart: rebuild Tasks from `cq status --json`

## Display Guidelines

- Show progress: "Step 3/8: Running Tests"
- Use markers: pass, fail, running, gated, skipped, pending
- One-line summary per completed step
- Clear explanation at human gates
- Full summary when workflow completes

## Important Rules

- Always use `--json` when reading cq state
- Never modify run files directly — use `cq` commands
- The `cq` CLI handles routing, gates, and state — trust it
- For agent steps: always dispatch to `/cq-agent`, never execute inline
- For bash steps: run exactly the interpolated command
- Pause: `cq pause <run_id>` | Cancel: `cq cancel <run_id>` | Skip: `cq skip <run_id>`
