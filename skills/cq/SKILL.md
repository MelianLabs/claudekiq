---
name: cq
description: "Claudekiq workflow engine — start, resume, monitor workflows, setup projects. Use /cq to list and run workflows, /cq <workflow> to start one, /cq status for dashboard, /cq init or /cq setup to initialize."
argument-hint: "[workflow|init|setup|status|approve] [--key=val...]"
allowed-tools: Bash, Read, Write, Glob, Grep, Skill, Agent, TaskCreate, TaskUpdate, TodoRead, TodoWrite, AskUserQuestion, CronCreate, CronDelete
---

# Claudekiq — Single Entry Point

## Prerequisites
If any required tool is unavailable, report the error clearly and suggest running via CLI instead.

You are the **sole user-facing entry point** for `cq` (claudekiq), a filesystem-backed workflow engine. You handle ALL user interactions: starting, resuming, monitoring workflows, project setup, and approval gates. Internal skills (`/cq-runner`, `/cq-approve`, `/cq-worker`, `/cq-setup`) are invoked programmatically by you — users never call them directly.

## Current State

Available workflows:
`!cq workflows list --json 2>/dev/null || echo "[]"`

Active runs:
`!cq list --json 2>/dev/null || echo "[]"`

## Invocation

Parse the arguments passed to this skill:

- **No arguments (`/cq`)**: Interactive mode
- **Status dashboard (`/cq status`)**: Show all running and pending jobs
- **Init (`/cq init`)**: Initialize cq in the current project
- **Setup (`/cq setup`)**: Smart project discovery and workflow creation
- **Approve (`/cq approve [run_id]`)**: Handle pending approval gates
- **With workflow name (`/cq feature`)**: Start that workflow directly
- **With workflow + params (`/cq feature --description="add export"`)**: Start with context variables

## Interactive Mode (no arguments)

1. Run: `Bash(command: "cq workflows list --json")` and `Bash(command: "cq list --json")`
2. If there are **active runs** (running, gated, paused): show them, ask "Resume or start new?"
3. If starting new: present workflow list, ask which to run
4. Proceed to **Start Workflow** or **Resume Workflow**

## Init Mode (`/cq init`)

1. Run: `Bash(command: "cq init --json")`
2. Report what was created/found
3. Suggest running `/cq setup` to discover the project and create workflows

## Setup Mode (`/cq setup`)

Delegate to `/cq-setup` skill internally:
```
Skill(name: "cq-setup")
```

The setup skill handles:
1. Auto-initialize if needed (`cq init`)
2. Scan project for agents, skills, stacks, commands
3. Present discovery report
4. Check for existing workflows committed by teammates — present them
5. If no workflows exist: guide creation of first workflow
6. After first workflow: ask if user wants to define more
7. Validate all created workflows

## Resume Workflow

1. Create/update Task (fire-and-forget):
   ```
   TaskCreate(name: "cq: <template> — resumed", description: "Resumed workflow (run: <run_id>)")
   ```
2. Hand off: `Skill(name: "cq-runner", args: "<run_id>")`
3. After runner returns: proceed to **Handle Completion**

## Start Workflow

1. Run: `Bash(command: "cq workflows show <name> --json")`
2. Check for `params` — for each required parameter not provided via arguments:
   ```
   AskUserQuestion(question: "Workflow '<name>' requires '<param>': <description>. What value?",
     options: [{label: "<default>", description: "Use default"}, {label: "Custom", description: "Enter value"}])
   ```
3. Run: `Bash(command: "cq start <name> --key=val... --json")` — capture the `run_id`
4. Create Task (fire-and-forget — do NOT store task_id):
   ```
   TaskCreate(name: "cq: <template> — <description>", description: "Running workflow <template> (run: <run_id>)")
   ```
5. Hand off: `Skill(name: "cq-runner", args: "<run_id>")`
6. After runner returns: proceed to **Handle Completion**

## Approve Mode (`/cq approve [run_id]`)

Delegate to `/cq-approve` skill internally:
```
Skill(name: "cq-approve", args: "<run_id>")
```

## Handle Completion

After `/cq-runner` returns, read final state:
```
Bash(command: "cq status <run_id> --json")
```

Based on `meta.status`:
- `completed` → `TaskUpdate` best-effort (fire-and-forget)
- `failed` → `TaskUpdate` best-effort
- `cancelled` → `TaskUpdate` best-effort
- `paused` → `TaskUpdate` best-effort

**Completion TODO Sync**: `TodoRead()` — for any lingering `[cq]` TODOs: `TodoWrite(todos: [{id: "<id>", status: "completed"}])`

Report final status to the user with a summary of what happened.

## Important Rules

- Always use `--json` when reading cq state
- Never modify run files directly — use `cq` commands
- Delegate execution to `/cq-runner` — do not run the loop yourself
- Delegate gate handling to `/cq-approve` (via `/cq-runner`)
- For agent steps: `/cq-runner` will dispatch to `/cq-worker`
- Task mirroring is fire-and-forget — do NOT store `_task_id` in context
- Only `/cq` is visible to users — internal skills are implementation details
