---
name: cq-agent
description: "Execute a single agent step in a cq workflow. Handles prompt assembly, model selection, agent spawning, heartbeat, resume, and result extraction."
argument-hint: "<run_id> <step_id>"
allowed-tools: Bash, Read, Agent, Skill, CronCreate, CronDelete
---

# Claudekiq Agent Step Executor

## Prerequisites
If any required tool (Agent, Skill, etc.) is unavailable, report the error clearly and suggest running via CLI instead.

You handle a single agent step within a cq workflow. You are invoked by the `/cq` runner to execute agent-type steps autonomously.

## Arguments

Parse the arguments: `<run_id> <step_id>`

## Step 1: Load Step Definition

```bash
cq status <run_id> --json
```

Extract:
- The step definition from `steps` array where `id == <step_id>`
- The full context from `ctx`
- The step's state from `state.<step_id>` (visit count, attempt)

From the step definition, extract:
- `prompt` — the goal description (primary)
- `target` — agent name (`@name`) or empty
- `context` — list of context keys to include
- `model` — model override (opus, sonnet, haiku)
- `resume` — whether to attempt agent resume on retry
- `outputs` — expected output keys
- `background` — whether to run in background
- `timeout` — timeout in seconds

## Step 2: Build Agent Prompt

Pass raw prompt + context to the agent. Claude decides how to execute.

1. Start with the step's `prompt` field as-is (no `{{variable}}` interpolation)
2. If the step type is not `agent` but a convention name (e.g., `review`, `deploy`, `migrate`), prepend semantic context: "You are performing a <type>." to guide the agent's behavior
3. If `context` array is defined, append a "Context" section with each key's raw value from the run context
4. If no `prompt` field, fall back to `args_template` (backward compat)
5. If neither exists but `target` starts with `@`, use the step `name` as a minimal prompt

The assembled prompt gives the agent everything it needs to work autonomously.

## Step 3: Set Up Heartbeat

For non-background steps:
1. Write initial heartbeat: `cq heartbeat <run_id>`
2. Create heartbeat cron: `CronCreate(schedule: "*/1 * * * *", command: "cq heartbeat <run_id>")`
3. Save the `cron_id` for cleanup

## Step 4: Resolve Agent Target

If `target` starts with `@`:
1. Strip the `@` prefix
2. Check if agent file exists directly: `.claude/agents/<name>.md`
3. If not found, check for agent mapping: `jq -r '.agent_mappings["<name>"] // empty' .claudekiq/settings.json`
4. If mapped, use the mapped name; otherwise use the stripped name
5. Verify the agent exists: `.claude/agents/<name>.md` file OR in scan results
6. If not found → report error, return fail outcome

If `target` is empty or doesn't start with `@`: use `general-purpose` as the agent type.

## Step 5: Check for Resume

If `resume: true` AND visit count > 1 (this is a retry):
1. Check for saved agentId: `cq ctx get _agent_<step_id> <run_id>`
2. If found, attempt resume:
   ```
   Agent(resume: <saved_agentId>, prompt: "Continuing from previous attempt. <assembled_prompt>")
   ```
3. If resume fails (agent no longer available), fall through to fresh spawn with note about retry

## Step 6: Spawn Agent

Invoke the Agent tool:
- `description`: step name (max 5 words)
- `subagent_type`: resolved agent name (from step 4)
- `model`: from step definition, or project default from `jq -r '.default_model // "opus"' .claudekiq/settings.json`
- `prompt`: assembled prompt from step 2
- `run_in_background`: true if `background: true` or `timeout` is set
- `isolation`: from step definition (e.g., `isolation: worktree`). If set, pass to Agent tool for isolated execution.

## Step 7: Handle Timeout

If `timeout` is set and agent runs in background:
- Track start time
- If agent completes within timeout: proceed normally
- If timeout exceeded: treat as fail with `{"error": "timeout"}`

## Step 8: Evaluate Results

Read the agent's response and determine:
1. **Did the agent achieve the goal?** Use your judgment based on the prompt and the response.
2. **Outcome**: `pass` if goal achieved, `fail` if not

## Step 9: Extract Results

If the step has `outputs` defined:
- Read the agent's response and extract values for each output key
- Store each in context: `cq ctx set <key> <value> <run_id>`

If no `outputs` defined:
- Store a freeform summary as `_result_<step_id>` in context

## Step 10: Save Agent ID

Save the agentId for potential future resume:
```bash
cq ctx set _agent_<step_id> <agentId> <run_id>
```

## Step 11: Clean Up

1. Delete heartbeat cron: `CronDelete(id: <cron_id>)` (if created)
2. Write final heartbeat: `cq heartbeat <run_id>`

## Step 12: Report

Return the outcome to the caller:
- State whether the step passed or failed
- Summarize what the agent accomplished
- List any context variables that were set
- Include the agentId for reference

The `/cq` runner will use your report to call `cq step-done` and advance the workflow.
