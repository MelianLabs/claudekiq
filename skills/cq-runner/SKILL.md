---
name: cq-runner
description: "Execute workflow steps in a loop — dispatches bash, agent, skill, batch, and sub-workflow steps. Called by /cq with a run_id."
argument-hint: "<run_id>"
allowed-tools: Bash, Read, Skill, TaskUpdate, TodoRead, TodoWrite
---

# Claudekiq Runner

## Prerequisites
If any required tool (Skill, TaskUpdate, etc.) is unavailable, report the error clearly and suggest running via CLI instead.

You execute the runner loop for a cq workflow. You are invoked by `/cq` with a `run_id`.

## Arguments

Parse: `<run_id>`

## Session Start TODO Sync

Before entering the loop, sync any pending TODOs from previous sessions:
1. `Bash(command: "cq todos sync --json")`
2. For each `.todos[]`: `TodoWrite(todos: [{id: "<todo_id>", content: "<content>", status: "in_progress", priority: "<priority>"}])`

## Runner Loop

Repeat until terminal state or gate:

### 1. Read State
```
Bash(command: "cq status <run_id> --json")
```
Key fields: `meta.status`, `meta.current_step`, `steps[]`, `state{}`, `ctx{}`

### 2. Check Terminal States
- `completed`, `failed`, `cancelled` → **Return** to caller (`/cq` handles TaskUpdate and final reporting)
- `blocked` → Report to caller and return
- `queued` → Report queued status and return
- `paused` → Report paused status and return

### 3. Handle Gates
If `meta.status` is `gated`:
1. Invoke: `Skill(name: "cq-approve", args: "<run_id>")`
2. After `/cq-approve` returns, re-read state and continue loop

### 4. Dispatch Step

Find current step from `steps[]` where `id == meta.current_step`. Based on `type`:

#### `bash`
Interpolate `{{variable}}` in `target` using `ctx` values. Then:
```
Bash(command: "<interpolated_target>")
```
- Exit 0 → `pass`, non-0 → `fail`
- Capture stdout/stderr for step-done

#### `agent` (or convention-based custom type)
```
Skill(name: "cq-worker", args: "<run_id> <step_id>")
```
Read the response to determine `pass` or `fail`.

#### `skill`
Invoke the target skill directly (native skill chaining):
```
Skill(name: "<target>", args: "<prompt>")
```
Determine outcome from the skill's response.

#### `parallel` or `batch`
Delegate to Claude Code's built-in `/batch`:
1. Read `branches[]` from step definition
2. Format each branch as a task description including its type, target/prompt
3. `Skill(name: "batch", args: "<formatted branch descriptions>")`
4. Map results to branch outcomes JSON: `{"branch_id": {"status":"passed","result":"pass"}, ...}`
5. `Bash(command: "cq step-done <run_id> <step_id> pass|fail --branches='<json>' --json")`
6. Skip to step 6 (Re-read)

#### `workflow` (sub-workflow)
1. Read `template`, `context_map` from step definition
2. Build context args from `context_map`
3. `Bash(command: "cq start <template> --parent=<run_id> --parent-step=<step_id> --key=val... --json")`
4. Recursive: `Skill(name: "cq-runner", args: "<child_run_id>")`
5. Parent step auto-completes when child finishes

### 5. Mark Step Complete

For non-parallel, non-workflow steps:
```
Bash(command: "cq step-done <run_id> <step_id> <pass|fail> --json")
```
For bash steps, include captured output:
- Pass: `--output='<last 50 lines>'`
- Fail: `--output='<stdout>' --stderr='<stderr>'`

**MANDATORY** — Update Task progress:
```
TaskUpdate(id: <task_id>, status: "in_progress", description: "Step <n>/<total>: <next_step_name>")
```
Get `task_id` via: `Bash(command: "cq ctx get _task_id <run_id>")`

### 6. Re-read and Loop
The `cq step-done` command handles gate logic:
- **auto** → advances automatically
- **human** → creates TODO, sets `gated`
- **review (pass)** → advances
- **review (fail)** → under max_visits uses `on_fail` route; at max_visits creates TODO

Return to step 1.

## Timeouts
If step has `timeout:`:
- **bash**: `Bash(command: "timeout <seconds> <command>")`
- **agent/skill**: `/cq-worker` handles timeout

## Error Recovery
When a tool call fails during step execution:
1. Log: `Bash(command: "cq ctx set _error_<step_id> '<error>' <run_id>")`
2. Mark failed: `Bash(command: "cq step-done <run_id> <step_id> fail --json")`
3. Continue the loop — do not crash

## Important Rules

- Always use `--json` when reading cq state
- Never modify run files directly — use `cq` commands
- Never talk to the user directly — delegate gates to `/cq-approve`
- For agent steps: always dispatch to `/cq-worker`
- For bash steps: run exactly the interpolated command
