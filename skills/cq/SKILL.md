---
name: cq
description: "Claudekiq workflow runner — orchestrates multi-step development workflows. Use /cq to list and run workflows, /cq <workflow> to start a specific one, or /cq status to monitor all jobs."
argument-hint: "[workflow] [--key=val...]"
allowed-tools: Bash, Read, Agent, Skill, TaskCreate, TaskUpdate, CronCreate, CronDelete, AskUserQuestion
---

# Claudekiq Workflow Runner

You are the runner for `cq` (claudekiq), a filesystem-backed workflow engine. Your job is to execute workflow steps, handle gates, and drive workflows to completion.

## Current State

Available workflows:
`!cq workflows list --json 2>/dev/null || echo "[]"`

Active runs:
`!cq list --json 2>/dev/null || echo "[]"`

Project inventory (agents, skills, plugins):
`!jq '{agents: (.agents // []) | map(.name), skills: (.skills // []) | map(.name), plugins: (.plugins // []) | map(.name)}' .claudekiq/settings.json 2>/dev/null || echo "{}"`

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

When the user wants auto-refresh, invoke the `/loop` skill:
- Skill: `loop`, Args: `1m /cq status`
- This will re-run `/cq status` every minute until the user stops it (1m is the minimum interval supported by `/loop`)
- The user can stop it at any time by pressing the interrupt key

## Start Workflow

1. Run: `cq workflows show <name> --json`
2. Extract the `defaults` object from the workflow definition
3. Merge any `--key=val` arguments already provided
4. For each default that has an **empty string value** and was NOT provided via arguments, ask the user for a value. Skip defaults that already have non-empty values (those are true defaults, not required params).
5. Run: `cq start <name> --key=val...` with all collected parameters. Use `--json` to capture the run_id.
6. Extract `run_id` from the JSON response
7. **Create a workflow-level Task** for persistent progress tracking:
   - Use `TaskCreate` with name: `"cq: <workflow> — <description>"` and description: `"Running workflow <workflow> (run: <run_id>)"`
   - Save the returned `task_id` — you'll update it after each step in the Runner Loop
8. Enter the **Runner Loop**

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

**Simple gates (single TODO, direct user session — not a worker or headless):**
- Use `AskUserQuestion` to ask the user inline:
  - Question: "Step '<step_name>' needs approval. <description>"
  - Options: Approve, Reject, Skip
- Apply the user's choice: `cq todo <number> <action>`
- Continue the runner loop immediately (go back to **Step 1**)

**Complex gates (multiple TODOs, review gate escalation, or worker/headless context):**
- Fall back to the standard TODO flow:
- For each pending TODO:
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
   - Check for agent mapping in `.claudekiq/settings.json` under the `agent_mappings` key: `jq -r '.agent_mappings["<stripped_name>"] // empty' .claudekiq/settings.json`. If a mapping exists, use the mapped value as `subagent_type`
   - If no mapping found, use the stripped name directly as `subagent_type` — Claude Code resolves it against `.claude/agents/<name>.md` definitions
   - **IMPORTANT**: If the agent name is not found in scan results (`.claudekiq/settings.json .agents[].name`) AND no `.claude/agents/<name>.md` file exists → **fail the step** with error: `"Agent '<name>' not found. Define it at .claude/agents/<name>.md or update agent_mappings in settings.json"`. Do NOT silently fall back to general-purpose.

2. **Set up heartbeat cron** (for non-background steps):
   - Write initial heartbeat: `cq heartbeat <run_id>`
   - Create heartbeat cron: `CronCreate(schedule: "*/1 * * * *", command: "cq heartbeat <run_id>")`
   - Save the returned `cron_id` for cleanup after step completes

3. **Check for agent resume** (retry/pause recovery):
   - Check context for a saved agentId: `cq ctx get _agent_<step_id> <run_id>`
   - If an agentId is found AND this step is being re-visited (visit count > 1), use `Agent(resume: <agentId>)` to resume the previous agent with updated context (e.g., failure details, new instructions)
   - If no agentId found, or this is the first visit, spawn a fresh agent:

4. **Invoke the Agent tool:**
   - `description`: step name (max 5 words)
   - `subagent_type`: the stripped `@target` name (e.g., `code-review`, `rails-test`)
   - `model`: from the step's `model` field (if present)
   - `prompt`: the interpolated `args_template`
   - `run_in_background`: `true` if the step has `background: true` (see Background Execution below)

5. **Interpret results and save agentId:**
   - Agent returns successfully → outcome is `pass`
   - Agent returns with error or cannot complete → outcome is `fail`
   - Extract result JSON from the agent's response for `outputs` processing
   - **Save the `agentId`** to context for future resume: `cq ctx set <run_id> _agent_<step_id> <agentId>`

6. **Clean up heartbeat cron** (for non-background steps):
   - Delete heartbeat cron: `CronDelete(id: <cron_id>)`
   - Write final heartbeat: `cq heartbeat <run_id>`

##### Background execution

If the step has `background: true`:
1. Add `run_in_background: true` to the Agent tool call
2. Save the `agentId` to context immediately: `cq ctx set <run_id> _agent_<step_id> <agentId>`
3. Do NOT wait for the result — immediately proceed to the next step
4. When a later step references an output from this background step (via `{{var}}`), the runner must wait for the background agent's completion notification before proceeding
5. After the background agent completes:
   - Use `Agent(resume: <agentId>)` to retrieve the detailed results
   - Extract outputs and mark the step done: `cq step-done <run_id> <step_id> pass|fail [result_json]`

If the step has `timeout` AND is NOT `background: true`, the runner should implicitly treat it as background so it can enforce the timeout:
1. Launch the agent with `run_in_background: true`
2. Track elapsed time
3. If the agent hasn't completed within `timeout` seconds, treat as timeout outcome (route via `on_timeout`)
4. If the agent completes within the timeout, proceed normally

#### `skill`
The `target` contains a skill name (e.g. `/review`). Invoke it:
1. **Set up heartbeat cron**: same as agent steps — `CronCreate(schedule: "*/1 * * * *", command: "cq heartbeat <run_id>")`
2. Use the Skill tool with the target skill name and the interpolated args_template as arguments
3. Pass if successful, fail if not
4. **Clean up heartbeat cron**: `CronDelete(id: <cron_id>)`

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

**For bash sub-steps**, use the CLI command:
```bash
cq for-each <run_id> <step_id> --json
```
This handles splitting, iteration, context updates, and returns a JSON result with per-item outcomes. Mark the step done based on the aggregate outcome.

**For agent/skill sub-steps**, iterate manually:

1. Read fields:
   - `over` (interpolated) — the list string (e.g., `"rails,webpack,marketplace"`)
   - `delimiter` (default `","`) — split character
   - `item_var` — context variable name to set per iteration
   - `max_iterations` (default `100`) — safety limit
   - `step` — the sub-step definition

2. Split `over` by `delimiter` into items array

3. For each item (up to `max_iterations`):
   a. Set the context variable: `cq ctx set <run_id> <item_var> <item>`
   b. Execute the sub-step:
      - If `agent`: use the Agent tool (same rules as the `agent` type above)
      - If `skill`: use the Skill tool
   c. Track progress: "for_each 2/3: processing webpack"
   d. If sub-step fails and this for_each has no `on_fail`, stop iteration

4. Outcome: `pass` if ALL iterations pass, `fail` if any fails
5. Mark done: `cq step-done <run_id> <for_each_step_id> pass|fail`

#### `parallel`
Execute multiple sub-steps concurrently:

**For bash sub-steps**, use the CLI command:
```bash
cq parallel <run_id> <step_id> --json
```
This runs all bash children concurrently and returns aggregate results.

**For agent/skill sub-steps**, use the Agent tool directly:

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

**Use the CLI command to create a worker session**:
```bash
cq batch <run_id> <step_id> --json
```
This creates a worker session and returns the `session_id`. Then invoke the `/cq-workers` skill:

- Use the Skill tool: `skill: "cq-workers"`, `args: "<workflow> --jobs='[...]'"`
- The workers skill handles spawning, monitoring, and gate escalation
- Outcome: `pass` if all workers complete successfully, `fail` if any worker fails
- Worker results are aggregated into the context under the `outputs` key

#### `<custom type>` (plugin resolution)
If the step `type` is not one of the built-in types above (bash, agent, skill, manual, subflow, for_each, parallel, batch), it may be a **custom plugin type**. Resolve it in this order:

1. **Agent-backed plugin**: Check if `.claude/agents/<type>.md` exists.
   - If found, treat this as an agent step: use the **Agent tool** with `subagent_type` set to `<type>`
   - The interpolated `args_template` becomes the prompt
   - Use `model` from the step definition if present
   - Interpret results same as a regular agent step (pass/fail)

2. **Bash plugin**: Check if `.claudekiq/plugins/<type>.sh` exists and is executable.
   - If found, execute via the Bash tool:
     ```bash
     echo '<interpolated_step_json>' | CQ_RUN_ID=<run_id> CQ_STEP_ID=<step_id> CQ_PROJECT_ROOT=<root> .claudekiq/plugins/<type>.sh
     ```
   - Parse stdout as JSON: `{"status":"pass"|"fail", "output":{...}, "error":"..."}`
   - Exit code 0 → pass, non-zero → fail
   - If the result has `output`, use it for step `outputs` extraction

3. **Scan results fallback**: Check the project inventory (from `.claudekiq/settings.json` shown in Current State above):
   - If the type name appears in the `agents` list → treat as agent-backed plugin (step 1)
   - If the type name appears in the `plugins` list → treat as bash plugin (step 2)

4. **Not found**: If no matching agent or plugin exists, mark the step as `fail` with error "Unknown step type: `<type>`. Run `cq scan` to discover plugins."

### Step 5.6: Handle Timeouts

If the step has a `timeout` field (in seconds):

- **For `bash` steps**: wrap the command with a timeout: `timeout <seconds> <command>`. If it times out, the outcome is determined by `on_timeout` (default: `fail`)

- **For `agent`/`skill` steps** with a `timeout` AND NOT `background: true`:
  1. Create heartbeat cron as in Step 6 (agent section, step 2)
  2. Launch the agent with `run_in_background: true` (implicit background for timeout enforcement)
  3. Save the `agentId` to context: `cq ctx set <run_id> _agent_<step_id> <agentId>`
  4. Track the start time
  5. Wait for the agent's completion notification
  6. **If agent completes within timeout**: process results normally, delete heartbeat cron
  7. **If timeout exceeded** (no completion notification within `timeout` seconds):
     - Mark step done: `cq step-done <run_id> <step_id> fail '{"error":"timeout"}'`
     - Delete heartbeat cron
     - Route via `on_timeout` (see below)

- **`on_timeout` values**:
  - `"fail"` (default) — treat as a failed step, use normal `on_fail` routing
  - `"skip"` — skip this step and advance as if passed
  - `"<step_id>"` — jump to a specific step

### Step 7: Mark Step Complete
```bash
cq step-done <run_id> <step_id> pass|fail [result_json]
```
If the step produced JSON output (e.g. from a bash command), pass it as `result_json` so outputs can be extracted into context.

After marking the step complete:
1. **Update the per-step Task** created in Step 5.5 using `TaskUpdate`:
   - Set status to `completed` (if pass) or `failed` (if fail)
   - Include a brief result summary
2. **Update the workflow-level Task** (created during Start Workflow) using `TaskUpdate`:
   - Set `activeForm` to `"Step <completed>/<total>: <next_step_name>"` so progress is visible in Claude Code's status bar
   - If the workflow is now `completed`: set status to `completed`
   - If the workflow is now `failed`: set status to `failed`

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
