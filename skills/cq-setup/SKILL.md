---
name: cq-setup
description: "Smart project setup — discovers agents, skills, stacks, and commands. Helps define workflows. Called internally by /cq setup."
allowed-tools: Bash, Read, Glob, Grep, Write, AskUserQuestion
---

# Claudekiq Smart Setup

## Prerequisites
If any required tool is unavailable, report the error clearly and suggest running via CLI instead.

You discover what's available in a project and help users set up cq workflows. You are called internally by `/cq setup` — users don't invoke you directly.

## Step 0: Ensure Initialized

```
Bash(command: "cq init --json")
```
If status is `"initialized"` (fresh) or `"exists"` (re-init), proceed. If error, report to user.

## Step 1: Scan the Project

```bash
cq scan --json
```

This returns:
- `.agents[]` — available Claude agents (name, model, tools, description)
- `.skills[]` — available skills (name, description, tools)
- `.stacks[]` — detected stacks (language, framework, test_command, build_command, lint_command)
- `.commands[]` — custom slash commands

## Step 2: Present Discovery Report

Show the user a comprehensive summary of what was found:

**Agents**: List all detected agents with their names, models, and descriptions. Note which agents match the `@<stack>-dev` naming convention.

**Skills**: List all project skills (local and plugin-provided).

**Stacks**: List detected stacks with their language, framework, and available commands (test, build, lint).

**Custom Commands**: List any slash commands found.

## Step 3: Check for Existing Workflows

Run `cq workflows list --json` to find workflows already defined (possibly committed by teammates).

**If workflows exist**: Present the list to the user with descriptions. Ask if they want to define additional workflows or if they're good with what exists.

**If no workflows exist**: Proceed to Step 4.

## Step 4: Suggest Agent Mappings

Compare detected stacks against available agents:
1. For each stack (e.g., `rails`), check if `@rails-dev` agent exists
2. If missing, suggest creating an agent mapping or agent file
3. Write any agreed mappings to `.claudekiq/settings.json` under `agent_mappings`

## Step 5: Guide First Workflow Creation

Ask what kind of workflow to create first:

```
AskUserQuestion(
  question: "What workflow would you like to create first?",
  options: [
    {label: "feature", description: "Plan, implement, test, review, commit"},
    {label: "bugfix", description: "Investigate, fix, test, commit"},
    {label: "deploy", description: "Build, test, deploy with approval gates"},
    {label: "ci", description: "Lint, test, build pipeline"},
    {label: "custom", description: "I'll describe what I need"}
  ]
)
```

### Workflow Generation Rules

1. **Use detected stack commands** — If `stacks[0].test_command` is "npm test", use that in bash steps
2. **Name agents after their stack** — `@rails-dev`, `@react-dev`, `@go-dev`
3. **Multi-stack**: Use `batch` step type for parallel testing across stacks:
   ```yaml
   - id: test-all
     type: batch
     branches:
       - id: test-rails
         type: bash
         target: "bundle exec rspec"
       - id: test-react
         type: bash
         target: "npm test"
   ```
4. **Use `prompt` for agent steps** — raw prompts, no interpolation
5. **Set appropriate gates** — `human` for risky steps (deploy, commit, push), `review` for tests with retry, `auto` for safe steps
6. **Test-fix loops** — `review` gate with `max_visits: 3`, `on_fail` → fix step → back to test
7. **Use `extends`** for related workflows sharing common steps
8. **All step types must be explicit** — use only built-in types (`bash`, `agent`, `skill`, `batch`, `workflow`) or agents that exist in `.claude/agents/`. Do NOT use convention-based custom type names.

## Step 6: Ask About More Workflows

After the first workflow is created and validated:

```
AskUserQuestion(
  question: "Workflow created! Would you like to define another workflow?",
  options: [
    {label: "Yes", description: "Create another workflow"},
    {label: "No", description: "I'm done for now"}
  ]
)
```

If yes, go back to Step 5. If no, proceed to Step 7.

## Step 7: Validate All Workflows

```
Bash(command: "cq workflows validate .claudekiq/workflows/<name>.yml")
```

## Step 8: Summary

Tell the user:
- What was discovered (agents, stacks, skills, commands)
- Any workflows created
- How to start: `/cq <workflow>` or `/cq` for interactive
- How to customize: edit YAML files in `.claudekiq/workflows/`
