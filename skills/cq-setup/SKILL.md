---
name: cq-setup
description: "Smart project setup — discovers agents, skills, stacks, and commands in your project. Helps you understand what's available and optionally create workflows."
allowed-tools: Bash, Read, Glob, Grep, Write, AskUserQuestion
---

# Claudekiq Smart Setup

## Prerequisites
If any required tool is unavailable, report the error clearly and suggest running via CLI instead.

You discover what's available in a project and help users set up cq workflows.

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

**Existing Workflows**: Run `cq workflows list --json` and show any already-defined workflows.

## Step 3: Suggest Agent Mappings

Compare detected stacks against available agents:
1. For each stack (e.g., `rails`), check if `@rails-dev` agent exists
2. If missing, suggest creating an agent mapping or agent file
3. Write any agreed mappings to `.claudekiq/settings.json` under `agent_mappings`

## Step 4: Offer Workflow Creation (Optional)

Ask if the user wants help creating workflows:

```
AskUserQuestion(
  question: "Would you like to create workflows for this project?",
  options: [
    {label: "Yes", description: "I'll help you create customized workflows based on your project"},
    {label: "No", description: "Skip — I'll create workflows manually later"}
  ]
)
```

If yes, ask what kinds of workflows they need:
```
AskUserQuestion(
  question: "What workflows would you like to create?",
  options: [
    {label: "feature", description: "Plan, implement, test, review, commit"},
    {label: "bugfix", description: "Investigate, fix, test, commit"},
    {label: "deploy", description: "Build, test, deploy with approval gates"},
    {label: "ci", description: "Lint, test, build pipeline"}
  ],
  multiSelect: true
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
4. **Use `prompt` for agent/skill steps** — raw prompts, no interpolation
5. **Set appropriate gates** — `human` for risky steps (deploy, commit, push), `review` for tests with retry, `auto` for safe steps
6. **Test-fix loops** — `review` gate with `max_visits: 3`, `on_fail` → fix step → back to test
7. **Use `extends`** for related workflows sharing common steps

## Step 5: Validate

After writing each workflow:
```
Bash(command: "cq workflows validate .claudekiq/workflows/<name>.yml")
```

## Step 6: Summary

Tell the user:
- What was discovered (agents, stacks, skills, commands)
- Any workflows created
- How to start: `/cq <workflow>` or `/cq` for interactive
- How to customize: edit YAML files in `.claudekiq/workflows/`
