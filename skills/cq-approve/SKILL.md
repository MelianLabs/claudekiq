---
name: cq-approve
description: "Handle workflow approval gates — presents human gates and review escalations to the user for approval. Called by /cq-runner."
argument-hint: "<run_id>"
allowed-tools: Bash, Read, AskUserQuestion, TodoRead, TodoWrite
---

# Claudekiq Gate Handler

## Prerequisites
If any required tool (AskUserQuestion, etc.) is unavailable, report the error clearly.

You handle approval gates for cq workflows. You are invoked by `/cq-runner` when a workflow reaches a `gated` state.

## Arguments

Parse: `<run_id>`

## Step 1: Read Gate Info

```
Bash(command: "cq status <run_id> --json")
Bash(command: "cq todos --json")
```

From status: extract `meta.current_step`, find the step definition, get `gate` type and `state.<step_id>.visits`.
From todos: find the pending action for this run.

## Step 2: Gate Event TODO Sync

Create native TODO for the pending gate:
```
TodoWrite(todos: [{id: "<todo_id>", content: "[cq] <step_name> — <action>", status: "in_progress", priority: "<priority>"}])
```

## Step 3: Present Gate to User

### Human Gate (approval required)
```
AskUserQuestion(
  question: "Step '<step_name>' needs approval.\n\nResult: <brief summary>\n\nApprove to continue or reject to fail the workflow?",
  options: [
    {label: "Approve", description: "Continue to next step"},
    {label: "Reject", description: "Fail the workflow"}
  ]
)
```

### Review Escalation (max_visits reached)
```
AskUserQuestion(
  question: "Step '<step_name>' has failed <visits> times (max: <max_visits>).\n\n<result_summary>\n\nOverride to force-pass, or reject?",
  options: [
    {label: "Override", description: "Force-pass and continue"},
    {label: "Reject", description: "Fail the workflow"}
  ]
)
```

### Headless Mode
If `--headless` was used (check `meta.started_by` or context): auto-approve all gates.

## Step 4: Resolve Gate

Based on user response:
```
Bash(command: "cq todo <number> approve|reject|override --json")
```

Then mark the native TODO as completed:
```
TodoWrite(todos: [{id: "<todo_id>", status: "completed"}])
```

## Step 5: Return

Return the resolution (approved/rejected/overridden) so `/cq-runner` can continue the loop.
