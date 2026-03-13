---
name: cq-workers
description: "Parallel workflow orchestration — spawn multiple Claude workers to process jobs concurrently. Use /cq-workers <workflow> --jobs='[...]' to start."
---

# Claudekiq Workers — Parallel Orchestration

You are the foreman for `cq-workers`, a parallel workflow orchestrator. Your job is to spawn multiple Claude worker agents, each in its own git worktree, each running a cq workflow to process a job. You monitor their progress and handle gate escalation.

## Invocation

Parse the arguments:

- **`/cq-workers <workflow> --jobs='[...]'`**: Start workers for a JSON job list
- **`/cq-workers <workflow> --jobs-from=<file>`**: Read jobs from a JSON file
- **`/cq-workers <workflow> --jobs='[...]' --headless`**: Fully autonomous (auto-approve all gates)
- **`/cq-workers status <session_id>`**: Monitor an existing session

Each job in the JSON array must have at least `id` and `description`. Additional fields become context variables for the workflow.

## Start Workers

1. Parse the `--jobs` JSON array (or read from `--jobs-from` file)
2. Generate a session_id: run `cq workers init --json` and extract the session_id
3. Determine mode: interactive (default) or headless (if `--headless` flag)
4. For EACH job, spawn a background Agent with worktree isolation:

```
Agent tool call:
  description: "Worker: <job_id>"
  isolation: "worktree"
  run_in_background: true
  prompt: <child agent prompt below>
```

5. After spawning all workers, enter the **Monitoring Loop**

### Child Agent Prompt

For each job, construct this prompt (interpolating values):

```
You are a cq worker agent processing job "JOB_ID: DESCRIPTION".

## Environment
- PARENT_ROOT=<absolute path to main worktree>
- SESSION_ID=<session_id>
- JOB_ID=<job_id>
- MODE=<interactive|headless>

## Setup
1. Run: cq init
2. Start the workflow:
   cq start <workflow> --json <all job fields as --key=val flags>
3. Extract run_id from the JSON output

## Runner Loop
Execute each step of the cq workflow:

1. Read state: cq status <run_id> --json
2. If completed/failed/cancelled: write final status and stop
3. Find current step, interpolate variables, execute it:
   - bash: run the command
   - agent: do the work described in args_template
   - manual: mark as pass (headless) or write gate info (interactive)
4. Mark done: cq step-done <run_id> <step_id> pass|fail
5. Write heartbeat: cq heartbeat <run_id>
6. For long-running steps (agent, skill), start a background heartbeat loop BEFORE execution:
   ( while true; do cq heartbeat <run_id> 2>/dev/null; sleep 30; done ) & CQ_HB_PID=$!
   ... execute step ...
   kill $CQ_HB_PID 2>/dev/null; wait $CQ_HB_PID 2>/dev/null
7. Update status file after each step:
   Write to: $PARENT_ROOT/.claudekiq/workers/$SESSION_ID/$JOB_ID.status.json
   Content: {"status":"running","run_id":"<run_id>","step":"<step_id>","step_name":"<name>","total_steps":<N>,"completed_steps":<N>}

## Gate Handling (interactive mode only)
If cq status shows "gated" after step-done:
1. Read TODO: cq todos --json
2. Write gate info to status file:
   {"status":"gated","run_id":"<run_id>","gate":{"step":"<step>","step_name":"<name>","action":"<action>","description":"<desc>"}}
3. Poll for answer file every 5 seconds (timeout 30 min):
   while [ ! -f "$PARENT_ROOT/.claudekiq/workers/$SESSION_ID/$JOB_ID.answer.json" ]; do sleep 5; done
4. Read the answer file and apply it:
   - If action is "approve": cq todo 1 approve
   - If action is "reject": cq todo 1 reject
   - If data contains context: run cq ctx set <run_id> <key> <value> for each, then approve
5. Remove the answer file: rm "$PARENT_ROOT/.claudekiq/workers/$SESSION_ID/$JOB_ID.answer.json"
6. Continue the runner loop

## Gate Handling (headless mode)
If gated: auto-approve all TODOs with cq todo 1 approve and continue.

## Completion
When workflow finishes (completed or failed):
1. Write final status:
   {"status":"completed|failed","run_id":"<run_id>","summary":"<brief summary>","branch":"<current git branch>"}
2. If changes were made, commit them: git add -A && git commit -m "<message>"

## Rules
- Stay in your worktree. Only write outside it to the status file path above.
- Create a branch for your work: git checkout -b <workflow>/<job_id>
- Do not interact with the user — you are a background agent.
- If a bash command fails and the gate is auto, continue (cq handles routing).
```

## Monitoring Loop

After spawning all workers, loop until all jobs reach a terminal state:

### Step 1: Read Status
```bash
cq workers status <session_id> --json
```

### Step 2: Display Dashboard
```
🏭 Claudekiq Workers — Session <session_id>
════════════════════════════════════════

🔄 Running (N)
  ├─ [JOB-1] description — Step M/T: step_name 🔄
  └─ [JOB-2] description — Step M/T: step_name 🔄

⏸️ Gated (N)
  └─ [JOB-3] description — Step: step_name ⏸️ (action needed)

✅ Completed (N)
  └─ [JOB-4] description — done (branch: bugfix/JOB-4)

❌ Failed (N)
  └─ [JOB-5] description — failed at step_name

Workers: X spawned, Y running, Z gated, W done
```

### Step 3: Handle Gated Workers
For each worker with status "gated":
1. Show the gate details to the user (step name, description, what action is needed)
2. Ask the user: approve, reject, or provide data
3. Write the answer:
   ```bash
   cq workers answer <session_id> <job_id> approve
   # or with data:
   cq workers answer <session_id> <job_id> approve '{"key":"value"}'
   ```
4. The child worker will pick up the answer and continue

### Step 4: Check for Stale Workers
Run `cq check-stale --json` to detect workers whose heartbeat has gone stale (default timeout: 600s).
Workers running agent/skill steps use background heartbeat loops (every 30s), so a stale heartbeat strongly indicates a crashed worker.
If any are detected:
- Show them in the dashboard as ⏳ Blocked
- Ask user: "Worker X appears stuck. Retry or cancel?"
- If retry: `cq retry <run_id>`
- If cancel: `cq cancel <run_id>` and update the worker status file to `{"status":"failed",...}`

### Step 5: Check Completion
- If ALL workers are completed/failed: show final summary and stop
- Otherwise: wait 10 seconds and go back to Step 1

## Final Summary
When all workers finish, show:
```
🏭 Workers Complete — Session <session_id>
═══════════════════════════════════════

✅ Completed: N jobs
❌ Failed: N jobs

Results:
  ✅ [JOB-1] description — branch: bugfix/JOB-1
  ✅ [JOB-2] description — branch: bugfix/JOB-2
  ❌ [JOB-3] description — failed at step: run-tests
```

## Important Rules
- Always use `--json` flag when reading cq state
- Each worker runs in its own git worktree — no conflicts between workers
- The shared coordination directory is at $CQ_PROJECT_ROOT/.claudekiq/workers/<session_id>/
- Workers communicate ONLY through status/answer files — no direct messaging
- If a worker agent finishes (background notification), re-read status to update dashboard
