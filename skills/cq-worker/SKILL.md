---
name: cq-worker
description: "Execute a single agent step in a cq workflow. Handles prompt assembly, model selection, agent spawning, heartbeat, resume, and result extraction."
argument-hint: "<run_id> <step_id>"
allowed-tools: Bash, Read, Agent, Skill, CronCreate, CronDelete
---

# Claudekiq Agent Step Executor

## Prerequisites
If any required tool (Agent, Skill, etc.) is unavailable, report the error clearly and suggest running via CLI instead.

You handle a single agent step within a cq workflow. You are invoked by `/cq-runner` to execute agent-type steps autonomously.

## Arguments

Parse the arguments: `<run_id> <step_id>`

## Step 1: Load Step Definition

```
Bash(command: "cq status <run_id> --json")
```

From the JSON response, extract:
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
- `isolation` — if set to `worktree`, pass to Agent tool for isolated execution

## Step 2: Build Agent Prompt

Pass raw prompt + context to the agent. Claude decides how to execute.

1. Start with the step's `prompt` field as-is (no `{{variable}}` interpolation)
2. If `context` array is defined, append a "Context" section with each key's raw value from the run context
3. If no `prompt` field, fall back to `args_template` (backward compat)
4. If neither exists but `target` starts with `@`, use the step `name` as a minimal prompt

5. If the step has a `context_builders` array defined, resolve built-in context:
   `Bash(command: "cq _resolve-context <run_id> <step_id>")`
   Append the output to the assembled prompt.
6. If `state.<step_id>.visits > 0` and `state.<step_id>.error_output` exists (this is a retry):
   Include in the prompt: "Previous attempt failed with: <error_output>"

The assembled prompt gives the agent everything it needs to work autonomously.

## Step 3: Set Up Heartbeat

For non-background steps:
1. Write initial heartbeat: `Bash(command: "cq heartbeat <run_id>")`
2. Create heartbeat cron:
   ```
   CronCreate(schedule: "*/1 * * * *", command: "cq heartbeat <run_id>")
   ```
3. Save the returned `cron_id` for cleanup in Step 11

## Step 4: Resolve Agent Target

If `target` starts with `@`:
1. Strip the `@` prefix to get `<name>`
2. Check if agent file exists: `Bash(command: "test -f .claude/agents/<name>.md && echo found || echo missing")`
3. If missing, check for mapping: `Bash(command: "jq -r '.agent_mappings[\"<name>\"] // empty' .claudekiq/settings.json")`
4. If mapped, use the mapped name; otherwise use the stripped name
5. The resolved name becomes `subagent_type` for the Agent tool
6. If agent not found anywhere → report error, return fail outcome

If `target` is empty or doesn't start with `@`: use `general-purpose` as the agent type.

## Step 5: Check for Resume

If `resume: true` AND visit count > 1 (this is a retry):
1. Check for saved agentId: `Bash(command: "cq ctx get _agent_<step_id> <run_id>")`
2. If found, attempt resume:
   ```
   Agent(resume: "<saved_agentId>", prompt: "Continuing from previous attempt. <assembled_prompt>")
   ```
3. If resume fails (agent no longer available), clear the saved agentId: `Bash(command: "cq ctx set _agent_<step_id> '' <run_id>")` and fall through to fresh spawn with note about retry

## Step 6: Spawn Agent

Invoke the Agent tool with these exact parameters:
```
Agent(
  description: "<step name, max 5 words>",
  subagent_type: "<resolved agent name from Step 4>",
  model: "<model from step def, or project default from settings.json>",
  prompt: "<assembled prompt from Step 2>",
  run_in_background: <true if background: true or timeout is set, false otherwise>,
  isolation: "<'worktree' if step has isolation: worktree, omit otherwise>"
)
```

For model default: `Bash(command: "jq -r '.default_model // \"opus\"' .claudekiq/settings.json")`

## Step 7: Handle Timeout

If `timeout` is set and agent runs in background:
- Track start time
- If agent completes within timeout: proceed normally
- If timeout exceeded: treat as fail with `{"error": "timeout"}`

## Step 8: Evaluate Results

Read the agent's response and determine the outcome:

**Mark as PASS if:**
- Agent explicitly says "completed", "done", "implemented", "fixed", "succeeded"
- Agent produced the expected output artifacts (files created, tests passing, etc.)
- Agent's response directly addresses the prompt's goal

**Mark as FAIL if:**
- Agent says "unable", "cannot", "error", "failed", "could not"
- Agent's response is empty or truncated
- Agent explicitly reports an error condition
- The expected output was not produced

Use your best judgment when signals are mixed, but err toward `pass` if the core goal appears achieved.

## Step 9: Extract Results

If the step has `outputs` defined:
- Read the agent's response and extract values for each output key
- Store each in context:
  ```
  Bash(command: "cq ctx set <key> '<value>' <run_id>")
  ```

If no `outputs` defined:
- Store a freeform summary (first 200 chars of agent response):
  ```
  Bash(command: "cq ctx set _result_<step_id> '<summary>' <run_id>")
  ```

## Step 10: Save Agent ID

Save the agentId for potential future resume:
```
Bash(command: "cq ctx set _agent_<step_id> <agentId> <run_id>")
```

## Step 11: Clean Up

1. Delete heartbeat cron (if created): `CronDelete(id: "<cron_id>")`
2. Write final heartbeat: `Bash(command: "cq heartbeat <run_id>")`

## Step 12: Report

Return the outcome to the caller:
- State whether the step passed or failed
- Summarize what the agent accomplished
- List any context variables that were set
- Include the agentId for reference

The `/cq` runner will use your report to call `cq step-done` and advance the workflow.
