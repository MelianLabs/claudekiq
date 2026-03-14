---
name: cq
description: "Claudekiq workflow runner — orchestrates multi-step development workflows. Use /cq to list and run workflows, /cq <workflow> to start a specific one, or /cq status to monitor all jobs."
---

# Claudekiq Workflow Runner

You are the runner for `cq` (claudekiq), a filesystem-backed workflow engine. Your job is to execute workflow steps, handle gates, and drive workflows to completion.

## Invocation

Parse the arguments passed to this skill:

- **No arguments (`/cq`)**: Interactive mode — list workflows and let the user pick one
- **Status dashboard (`/cq status`)**: Show all running and pending jobs with auto-refresh
- **With workflow name (`/cq feature`)**: Start that workflow directly
- **With workflow + params (`/cq feature --description="add export" --branch_name=export`)**: Start with those context variables

## Interactive Mode (no arguments)

1. Run: `cq workflows list --json`
2. Also check: `cq status --json` for any active runs
3. If there are **active runs** (status is running, gated, or paused):
   - Show them first with their current step and status
   - Ask the user: "Resume an active workflow or start a new one?"
   - If resuming, get the run_id and jump to the **Runner Loop**
4. If starting new: present the workflow list with descriptions
5. Ask which workflow to run
6. Proceed to **Start Workflow**

## Status Dashboard (`/cq status`)

This mode shows a live dashboard of all running, pending, and gated jobs with auto-refresh.

### How it works

1. Run: `cq list --json` to get all active runs
2. Run: `cq todos --json` to get all pending TODOs across runs
3. Display a formatted dashboard:

```
📋 Claudekiq Jobs Dashboard
═══════════════════════════

🔄 Running (2)
  ├─ [abc12345] feature "add export command" — Step 3/6: run-tests 🔄
  └─ [def67890] bugfix "fix login" — Step 1/4: create-branch 🔄

⏸️ Gated (1)
  └─ [ghi11111] release "v2.0.0" — Step 5/7: push-to-origin ⏸️ (awaiting approval)

📋 Queued (1)
  └─ [jkl22222] feature "add import" — pending (waiting for concurrency slot)

✅ Recently Completed (last 24h)
  └─ [mno33333] release "v1.0.0" — completed 2h ago

📝 Pending TODOs (1)
  └─ #1 [ghi11111] release/push-to-origin — approve push to origin/main
```

4. For each run, show:
   - Run ID (short)
   - Workflow name
   - Description from context (if available)
   - Current step and position (e.g., "Step 3/6")
   - Status marker
   - For gated runs: what TODO is pending
5. After displaying, ask the user:
   - **"Auto-refresh every 10s? (y/n)"** — if yes, use the `/loop` skill: `/loop 10s /cq status`
   - **"Resume a run?"** — if yes, get the run_id and jump to the **Runner Loop**
   - **"Resolve a TODO?"** — if yes, show TODO details and handle approve/reject

### Auto-refresh

When the user wants auto-refresh, invoke the `/loop` skill with a 10-second interval:
- Skill: `loop`, Args: `10s /cq status`
- This will re-run `/cq status` every 10 seconds until the user stops it
- The user can stop it at any time by pressing the interrupt key

## Start Workflow

1. Run: `cq workflows show <name> --json`
2. Extract the `defaults` object from the workflow definition
3. Merge any `--key=val` arguments already provided
4. For each default that has an **empty string value** and was NOT provided via arguments, ask the user for a value. Skip defaults that already have non-empty values (those are true defaults, not required params).
5. Run: `cq start <name> --key=val...` with all collected parameters. Use `--json` to capture the run_id.
6. Extract `run_id` from the JSON response
7. Enter the **Runner Loop**

## Runner Loop

This is the core execution loop. Repeat until the workflow completes, fails, or is cancelled:

### Step 1: Read State
```bash
cq status <run_id> --json
```
Extract:
- `meta.status` — the run status
- `meta.current_step` — the step to execute
- `steps` — array of step definitions
- `state` — per-step state (visits, status)
- `ctx` — context variables

### Step 2: Check Terminal States
If `meta.status` is:
- `completed` → Report success with a summary of what was done. Stop.
- `failed` → Report failure, show which step failed and why. Stop.
- `cancelled` → Report cancellation. Stop.
- `blocked` → The previous runner crashed. Report the blocked step and ask the user: retry (`cq retry <run_id>`) or cancel.

### Step 3: Check for Pending TODOs
If `meta.status` is `gated`:
```bash
cq todos --json
```
For each pending TODO:
- Show the step name, action type, and description to the user
- Ask: approve, reject, override, or dismiss
- Run: `cq todo <number> <action>`
- After resolving, go back to **Step 1**

### Step 4: Find Current Step
Find the step definition in `steps` where `id == meta.current_step`. Extract:
- `type` — how to execute (bash, agent, skill, manual, subflow)
- `target` — what to execute
- `args_template` — arguments template
- `gate` — what happens after (auto, human, review)
- `description` — for manual steps
- `outputs` — what to extract from results

### Step 5: Interpolate Variables
Replace all `{{variable}}` references in `target` and `args_template` with values from `ctx`. Use the context JSON to resolve them.

### Step 5.5: Track Progress with Tasks

Before executing the step, create a Claude Code Task for progress tracking and write a heartbeat:

1. **Create a Task** using `TaskCreate`:
   - `name`: `"cq: <workflow> step <current>/<total> — <step_name>"`
   - `description`: `"Executing step <step_id> of workflow <template>"`
   - Save the returned `task_id` for later update

2. **Write heartbeat** (still needed for `check-stale` backward compat):
```bash
cq heartbeat <run_id>
```

This replaces the background heartbeat loop. Claude Code's task system provides built-in progress tracking visible in the status bar, and each step becomes a trackable task with metrics.

### Step 6: Execute Step

Based on the step `type`:

#### `bash`
Run the interpolated `target` as a shell command using the Bash tool.
- Exit code 0 → outcome is `pass`
- Non-zero exit → outcome is `fail`
- Capture stdout as the result

#### `agent`
The `args_template` (interpolated) is your task prompt. Execute it as an AI task:
- Do the work described in the interpolated args_template
- When done, the outcome is `pass`
- If you cannot complete the task, the outcome is `fail`
- The `target` field (e.g. `@rails-dev`) is informational context about the intended agent role

#### `skill`
The `target` contains a skill name (e.g. `/review`). Invoke it:
- Use the Skill tool with the target skill name and the interpolated args_template as arguments
- Pass if successful, fail if not

#### `manual`
This is a human action step:
- Display the step `description` (interpolated) to the user
- Tell the user what they need to do
- The outcome depends on what happens after — the gate system will create a TODO

#### `subflow`
Insert steps from another workflow:
```bash
cq add-steps <run_id> --flow <target> --after <current_step_id>
```
Then mark the current step as pass and continue.

#### `for_each`
Iterate over a delimited list, executing a sub-step for each item:
- Read `over` (interpolated) — the list to iterate over (e.g., `"rails,webpack,marketplace"`)
- Read `delimiter` (default `","`) — how to split the list
- Read `item_var` — the variable name to set in context for each iteration
- Read `max_iterations` (default `100`) — safety limit
- Read `step` — the sub-step definition to execute per item
- For each item in the split list:
  1. Set the item_var in context: `cq ctx set <run_id> <item_var> <item>`
  2. Execute the sub-step as if it were the current step (interpolate, execute by type, check outcome)
  3. If the sub-step fails and gate is not `auto`, handle accordingly
- After all iterations complete, the outcome is `pass` if ALL iterations passed, `fail` if any failed
- Track iteration progress: "for_each 2/3: testing webpack"

#### `parallel`
Execute multiple sub-steps concurrently:
- Read `steps` — array of sub-step definitions
- Read `fail_strategy` (default `"wait_all"`) — `"wait_all"` waits for all children before determining outcome, `"fail_fast"` cancels remaining children when one fails
- Launch ALL child steps simultaneously using parallel Agent tool calls (with `run_in_background: true` for background execution)
- Monitor completion of all children
- Outcome: `pass` if ALL children pass, `fail` if any child fails
- Each child step's outputs are merged into the parent context
- Track parallel progress: "parallel 2/3 done: ✅ run-tests, 🔄 run-lint, ⬚ code-review"

#### `batch`
Spawn multiple isolated worker agents, each processing one item from a list:
- Read `jobs_from` (interpolated) — a JSON array in context, or a context key containing a JSON array
- Read `worker_prompt` (interpolated per item) — the prompt template for each worker. Use `{{item.field}}` to reference job fields
- Read `max_workers` (default `5`) — maximum concurrent workers
- Invoke the `/cq-workers` skill internally:
  1. Transform `jobs_from` into the `--jobs` JSON format expected by `/cq-workers`
  2. For each job item, interpolate the `worker_prompt` as the task description
  3. Use the Skill tool: `skill: "cq-workers"`, `args: "<workflow> --jobs='[...]'"`
- Outcome: `pass` if all workers complete successfully, `fail` if any worker fails
- Worker results are aggregated into the context under the `outputs` key

### Step 5.6: Handle Timeouts

If the step has a `timeout` field (in seconds):
- For `bash` steps: wrap the command with a timeout: `timeout <seconds> <command>`. If it times out, the outcome is determined by `on_timeout` (default: `fail`)
- For `agent`/`skill` steps: track elapsed time. If execution exceeds the timeout, stop and use the `on_timeout` outcome
- `on_timeout` values:
  - `"fail"` (default) — treat as a failed step
  - `"skip"` — skip this step and advance as if passed
  - `"<step_id>"` — jump to a specific step

### Step 7: Mark Step Complete
```bash
cq step-done <run_id> <step_id> pass|fail [result_json]
```
If the step produced JSON output (e.g. from a bash command), pass it as `result_json` so outputs can be extracted into context.

After marking the step complete:
1. **Update the Task** created in Step 5.5 using `TaskUpdate`:
   - Set status to `completed` (if pass) or `failed` (if fail)
   - Include a brief result summary
2. **Refresh heartbeat**: `cq heartbeat <run_id>`

### Step 8: Handle Post-Step State
Re-read status: `cq status <run_id> --json`

The `cq step-done` command already handles gate logic internally:
- **auto gate**: Step advances automatically. Continue the loop.
- **human gate**: Run is now `gated` with a pending TODO. Go to **Step 3**.
- **review gate (pass)**: Advances automatically. Continue the loop.
- **review gate (fail)**: If under max_visits, routes via `on_fail` automatically. If at max_visits, creates a TODO and sets `gated`. Go to **Step 3**.

Go back to **Step 1**.

## Display Guidelines

- Show progress as you go: "Step 3/8: Running Tests 🔄"
- Use the status markers: ✅ passed, ❌ failed, 🔄 running, ⏸️ gated, ⏭️ skipped, ⬚ pending
- When a step completes, show a one-line summary
- When hitting a human gate, clearly explain what decision is needed
- When a workflow completes, show a summary of all steps and their outcomes

## Error Handling

- If `cq` commands fail (non-zero exit), report the error and ask the user how to proceed
- If a bash step fails and the gate is `auto`, the workflow advances (routing handles it)
- If you can't execute an agent step, mark it as `fail` and let the gate logic handle retry/escalation
- Never silently swallow errors — always report what happened

## Important Rules

- Always use `--json` flag when reading cq state (parsing is more reliable)
- Never modify run files directly — always use `cq` commands
- The `cq` CLI handles all routing, gate logic, and state transitions — trust it
- For agent steps, YOU are the agent — do the work described in args_template
- For bash steps, run exactly the interpolated command — don't modify it
- If the user wants to pause, run: `cq pause <run_id>`
- If the user wants to cancel, run: `cq cancel <run_id>`
- If the user wants to skip a step, run: `cq skip <run_id>`
