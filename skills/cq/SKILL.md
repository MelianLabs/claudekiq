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
- `model` — optional: which Claude model to use (haiku, sonnet, opus)
- `background` — optional: whether to run in background (default: false)

### Step 5: Interpolate Variables
Replace all `{{variable}}` references in `target` and `args_template` with values from `ctx`. Use the context JSON to resolve them.

### Step 5.5: Track Progress

Create a Claude Code Task for this step:

Use TaskCreate:
  - name: `"cq: <workflow> step <current>/<total> — <step_name>"`
  - description: `"Executing step <step_id> (type: <type>) of workflow <template>"`

Save the returned `task_id` for Step 7.

### Step 6: Execute Step

Based on the step `type`:

#### `bash`
Run the interpolated `target` as a shell command using the Bash tool.
- Exit code 0 → outcome is `pass`
- Non-zero exit → outcome is `fail`
- Capture stdout as the result

#### `agent`
Use the **Agent tool** to spawn a specialized agent:

1. **Determine subagent_type** from `target`:
   - If `target` is empty or doesn't start with `@`, execute inline as before (backward compat): do the work described in args_template yourself
   - Strip the `@` prefix (e.g., `@code-review` → `code-review`)
   - Look up the target in the mapping table below. If no match, use `general-purpose`

2. **Invoke the Agent tool:**
   - `description`: step name (max 5 words)
   - `subagent_type`: resolved from target (or `general-purpose`)
   - `model`: from the step's `model` field (if present)
   - `prompt`: the interpolated `args_template`
   - `run_in_background`: `true` if the step has `background: true` (see Background Execution below)

3. **Interpret results:**
   - Agent returns successfully → outcome is `pass`
   - Agent returns with error or cannot complete → outcome is `fail`
   - Extract result JSON from the agent's response for `outputs` processing

##### Target → subagent_type mapping

| Target | subagent_type |
|--------|--------------|
| `@rails-test` | `rails-test` |
| `@rails-lint` | `rails-lint` |
| `@webpack-test` | `webpack-test` |
| `@webpack-lint` | `webpack-lint` |
| `@code-review` | `code-reviewer` |
| `@security-reviewer` | `security-reviewer` |
| `@performance-reviewer` | `performance-reviewer` |
| `@design-patterns-reviewer` | `design-patterns-reviewer` |
| `@lt-story` | `lt-story` |
| `@lt-branch` | `lt-branch` |
| `@sentry-investigator` | `sentry-investigator` |
| `@helpcenter` | `helpcenter` |
| `@scheduler-v2-test` | `scheduler-v2-test` |
| `@scheduler-v2-feature` | `scheduler-v2-feature` |
| `@pos-v2-test` | `pos-v2-test` |
| `@pos-v2-feature` | `pos-v2-feature` |
| `@pos-v2-lint` | `pos-v2-lint` |
| `@marketplace-test` | `marketplace-test` |
| `@marketplace-lint` | `marketplace-lint` |
| `@marketplace-feature` | `marketplace-feature` |
| `@chat-widget-test` | `chat-widget-test` |
| `@chat-widget-lint` | `chat-widget-lint` |
| `@chat-widget-feature` | `chat-widget-feature` |
| `@rails-feature` | `rails-feature` |
| `@webpack-feature` | `webpack-feature` |
| (anything else with `@`) | `general-purpose` |

##### Background execution

If the step has `background: true`:
1. Add `run_in_background: true` to the Agent tool call
2. Do NOT wait for the result — immediately proceed to the next step
3. When a later step references an output from this background step (via `{{var}}`), the runner must wait for the background agent's completion notification before proceeding
4. After the background agent completes, mark the step done: `cq step-done <run_id> <step_id> pass|fail [result_json]`

If the step has `timeout` AND is NOT `background: true`, the runner should implicitly treat it as background so it can enforce the timeout:
1. Launch the agent with `run_in_background: true`
2. Track elapsed time
3. If the agent hasn't completed within `timeout` seconds, treat as timeout outcome (route via `on_timeout`)
4. If the agent completes within the timeout, proceed normally

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

1. Read fields:
   - `over` (interpolated) — the list string (e.g., `"rails,webpack,marketplace"`)
   - `delimiter` (default `","`) — split character
   - `item_var` — context variable name to set per iteration
   - `max_iterations` (default `100`) — safety limit
   - `step` — the sub-step definition

2. Split `over` by `delimiter` into items array

3. For each item (up to `max_iterations`):
   a. Set the context variable: `cq ctx set <run_id> <item_var> <item>`
   b. Determine how to execute the sub-step based on its `type`:
      - If `agent`: use the Agent tool (same rules as the `agent` type above)
      - If `bash`: use the Bash tool
      - If `skill`: use the Skill tool
   c. Track progress: "for_each 2/3: processing webpack"
   d. If sub-step fails and this for_each has no `on_fail`, stop iteration

4. Outcome: `pass` if ALL iterations pass, `fail` if any fails
5. Mark done: `cq step-done <run_id> <for_each_step_id> pass|fail`

#### `parallel`
Execute multiple sub-steps concurrently using the Agent tool:

1. Read `steps` array and `fail_strategy` (default: `wait_all`)
2. For EACH child step, invoke the Agent tool in a SINGLE message:
   - `description`: "parallel: <child_step_name>"
   - `subagent_type`: resolved from child's `target` (same mapping as agent steps)
   - `model`: from child's `model` field (if present)
   - `run_in_background: true`
   - `prompt`: interpolated child's `args_template`

3. ALL Agent tool calls go in ONE message (Claude Code runs them concurrently)

4. Wait for all background agents to complete (you'll be notified as each finishes)

5. Collect results:
   - Extract outputs from each child's result into context
   - Outcome: `pass` if ALL children pass, `fail` if any child fails
   - For `fail_fast`: if a child fails, note remaining children as skipped

6. Mark the parent parallel step done: `cq step-done <run_id> <parallel_step_id> pass|fail`

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
- For agent steps with a `@target`, use the Agent tool to spawn a subagent — do NOT do the work inline
- For agent steps WITHOUT a `@target`, YOU are the agent — do the work described in args_template
- For bash steps, run exactly the interpolated command — don't modify it
- If the user wants to pause, run: `cq pause <run_id>`
- If the user wants to cancel, run: `cq cancel <run_id>`
- If the user wants to skip a step, run: `cq skip <run_id>`
