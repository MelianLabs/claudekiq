---
name: cq-setup
description: "Smart project setup — scans agents/skills/stack and generates customized workflows based on your project. Use /cq-setup after cq init."
allowed-tools: Bash, Read, Glob, Grep, Write, AskUserQuestion
---

# Claudekiq Smart Setup

You generate customized cq workflows based on the project's actual agents, skills, and detected stack.

## Step 1: Scan the Project

Run a single command to gather everything:

```bash
cq scan --json
```

This returns:
- `.agents[]` — available Claude agents (name, model, tools, description)
- `.skills[]` — available skills (name, description, tools)
- `.plugins[]` — available bash plugins
- `.stack` — detected language, framework, and commands:
  - `.stack.language` — e.g. javascript, typescript, ruby, python, go, rust, java, elixir
  - `.stack.framework` — e.g. next, react, rails, django, fastapi, spring, phoenix
  - `.stack.test_command` — e.g. "npm test", "bundle exec rspec", "pytest"
  - `.stack.build_command` — e.g. "npm run build", "cargo build"
  - `.stack.lint_command` — e.g. "npm run lint", "bundle exec rubocop"

Use the stack data to generate workflows with real commands rather than placeholders.

## Step 2: Ask the User

Use AskUserQuestion to ask:

> What workflows would you like to generate? Common options:
> - **feature** — Plan, implement, test, review, commit
> - **bugfix** — Investigate, fix, test, commit
> - **deploy** — Build, test, deploy with approval gates
> - **ci** — Lint, test, build pipeline
> - **release** — Version bump, test, tag, push
>
> You can choose multiple (comma-separated), or describe a custom workflow.

## Step 3: Generate Workflows

For each requested workflow, generate a YAML file at `.claudekiq/workflows/<name>.yml`.

### Workflow Format

```yaml
name: <workflow-name>
description: <one-line description>
default_priority: normal

params:
  branch_name:
    description: "Branch to work on"
    required: true
  commit_message:
    description: "Commit message"
    default: "Update from workflow"

defaults:
  key: "default_value"

steps:
  - id: <step-id>
    name: <Human-readable Name>
    type: bash
    target: "<shell command>"
    gate: auto

  - id: <agent-step-id>
    name: <Human-readable Name>
    type: agent
    target: "@agent-name"
    prompt: "Describe what the agent should do. Reference {{params.branch_name}} or {{context.key}}."
    context:
      some_input: "{{previous_step.output}}"
    model: sonnet
    gate: auto
    on_pass: <next-step-id>
    on_fail: <fix-step-id>

  - id: <skill-step-id>
    name: <Human-readable Name>
    type: skill
    target: "/skill-name"
    prompt: "What the skill should accomplish."
    gate: auto

  - id: <manual-step-id>
    name: <Human-readable Name>
    type: manual
    prompt: "Instructions for the human reviewer."
    gate: human
```

### Rules for Generation

1. **Use detected stack commands** — If `stack.test_command` is "npm test", use that in bash steps instead of a generic placeholder. Same for build and lint commands.
2. **Reference actual agents** — Use `@agent-name` targets matching agents from scan results. If no specialized agent exists, omit `target` so the runner itself handles it.
3. **Use `prompt` for agent/skill steps** — The `prompt` field describes what the agent should do. Use `{{variable}}` interpolation to inject context.
4. **Use `params` for workflow parameters** — Document required inputs at the top level. Reference them as `{{params.name}}` in prompts and targets.
5. **Set appropriate gates** — `human` for risky steps (deploy, commit, push), `review` for tests with retry, `auto` for safe steps.
6. **Test-fix loops** — Use `review` gate with `max_visits: 3`, `on_fail` pointing to a fix step, fix step pointing back to test.
7. **Timeouts** — Add `timeout: 300` (seconds) for steps that might hang.

## Step 4: Validate

After writing each workflow, run:
```bash
cq workflows validate .claudekiq/workflows/<name>.yml
```

Fix any issues.

## Step 5: Summary

Tell the user what was created and how to use it:
- List the generated workflows with descriptions
- Mention the detected stack (language, framework, commands) that was used
- Show example invocations: `/cq <workflow>` or `cq start <workflow>`
- Mention they can customize the YAML files directly
