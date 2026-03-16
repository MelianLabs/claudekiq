---
name: cq
description: "Claudekiq workflow runner — start, resume, and monitor workflows. Use /cq to list and run workflows, /cq <workflow> to start one, or /cq status for dashboard."
argument-hint: "[workflow] [--key=val...]"
allowed-tools: Bash, Read, Skill, TaskCreate, TaskUpdate, TodoRead, TodoWrite, AskUserQuestion
---

# Claudekiq — Entry Point

## Prerequisites
If any required tool (Skill, TaskCreate, etc.) is unavailable, report the error clearly and suggest running via CLI instead.

You are the entry point for `cq` (claudekiq), a filesystem-backed workflow engine. You handle starting, resuming, and monitoring workflows, then delegate execution to `/cq-runner`.

## Current State

Available workflows:
`!cq workflows list --json 2>/dev/null || echo "[]"`

Active runs:
`!cq list --json 2>/dev/null || echo "[]"`

## Invocation

Parse the arguments passed to this skill:

- **No arguments (`/cq`)**: Interactive mode
- **Status dashboard (`/cq status`)**: Show all running and pending jobs
- **With workflow name (`/cq feature`)**: Start that workflow directly
- **With workflow + params (`/cq feature --description="add export"`)**: Start with context variables

## Interactive Mode (no arguments)

1. Run: `Bash(command: "cq workflows list --json")` and `Bash(command: "cq list --json")`
2. If there are **active runs** (running, gated, paused): show them, ask "Resume or start new?"
3. If starting new: present workflow list, ask which to run
4. Proceed to **Start Workflow** or **Resume Workflow**

## Resume Workflow

1. Check if `_task_id` exists: `Bash(command: "cq ctx get _task_id <run_id>")`
2. If exists: `TaskUpdate(id: <task_id>, status: "in_progress", description: "Resuming workflow")`
3. If missing: `TaskCreate(name: "cq: <template> — resumed", description: "Resumed workflow (run: <run_id>)")`, then `Bash(command: "cq ctx set _task_id '<task_id>' <run_id>")`
4. Hand off: `Skill(name: "cq-runner", args: "<run_id>")`
5. After runner returns: proceed to **Handle Completion**

## Start Workflow

1. Run: `Bash(command: "cq workflows show <name> --json")`
2. Check for `params` — for each required parameter not provided via arguments:
   ```
   AskUserQuestion(question: "Workflow '<name>' requires '<param>': <description>. What value?",
     options: [{label: "<default>", description: "Use default"}, {label: "Custom", description: "Enter value"}])
   ```
3. Run: `Bash(command: "cq start <name> --key=val... --json")` — capture the `run_id`
4. **MANDATORY** — Create workflow Task:
   ```
   TaskCreate(name: "cq: <template> — <description>", description: "Running workflow <template> (run: <run_id>)")
   ```
5. Store task_id: `Bash(command: "cq ctx set _task_id '<task_id>' <run_id>")`
6. Hand off: `Skill(name: "cq-runner", args: "<run_id>")`
7. After runner returns: proceed to **Handle Completion**

## Handle Completion

After `/cq-runner` returns, read final state:
```
Bash(command: "cq status <run_id> --json")
```

Based on `meta.status`:
- `completed` → `TaskUpdate(id: <task_id>, status: "completed", description: "Workflow completed successfully")`
- `failed` → `TaskUpdate(id: <task_id>, status: "completed", description: "Failed at step '<current_step>'")`
- `cancelled` → `TaskUpdate(id: <task_id>, status: "completed", description: "Cancelled")`
- `paused` → `TaskUpdate(id: <task_id>, status: "in_progress", description: "Paused at step '<current_step>'")`

**Completion TODO Sync**: `TodoRead()` — for any lingering `[cq]` TODOs: `TodoWrite(todos: [{id: "<id>", status: "completed"}])`

Report final status to the user with a summary of what happened.

## Important Rules

- Always use `--json` when reading cq state
- Never modify run files directly — use `cq` commands
- Delegate execution to `/cq-runner` — do not run the loop yourself
- Delegate gate handling to `/cq-approve` (via `/cq-runner`)
- For agent steps: `/cq-runner` will dispatch to `/cq-worker`
