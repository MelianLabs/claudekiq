---
name: cq-setup
description: "Smart project setup — scans agents/skills/stacks and generates customized workflows based on your project. Use /cq-setup after cq init."
allowed-tools: Bash, Read, Glob, Grep, Write, AskUserQuestion
---

# Claudekiq Smart Setup

You generate customized cq workflows based on the project's actual agents, skills, and detected stacks.

## Step 1: Scan the Project

Run a single command to gather everything:

```bash
cq scan --json
```

This returns:
- `.agents[]` — available Claude agents (name, model, tools, description)
- `.skills[]` — available skills (name, description, tools)
- `.stacks[]` — detected stacks (a project can have multiple):
  - `.stacks[].language` — e.g. javascript, typescript, ruby, python, go, rust, java, elixir
  - `.stacks[].framework` — e.g. next, react, preact, rails, django, fastapi, spring, phoenix
  - `.stacks[].test_command` — e.g. "npm test", "bundle exec rspec", "pytest"
  - `.stacks[].build_command` — e.g. "npm run build", "cargo build"
  - `.stacks[].lint_command` — e.g. "npm run lint", "bundle exec rubocop"

Use the stacks data to generate workflows with real commands rather than placeholders.

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

If the project has multiple stacks, also ask which stack(s) the workflows should target, or generate workflows that cover all detected stacks.

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
    target: "@<stack>-dev"
    prompt: "Describe what the agent should do."
    context: [description]
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

```

Any step can have `gate: human` to pause for approval (replaces old `manual` type).
Convention-based custom types (e.g., `review`, `deploy`, `migrate`) are also supported — they are treated as agent steps with the type name providing semantic context.

### Rules for Generation

1. **Use detected stack commands** — If `stacks[0].test_command` is "npm test", use that in bash steps instead of a generic placeholder. Same for build and lint commands.
2. **Name agents after their stack** — Use `@<framework>-dev` or `@<language>-dev` targets (e.g., `@rails-dev`, `@react-dev`, `@go-dev`). This naming convention makes agent purpose clear. If no specialized agent exists, omit `target` so the runner itself handles it.
3. **Multi-stack workflows** — If the project has multiple stacks (e.g., Rails + React), generate steps that test/build each stack. Use the specific stack's commands for each step.
4. **Use `prompt` for agent/skill steps** — The `prompt` field describes what the agent should do. Agent steps receive raw prompts (no interpolation).
5. **Use `params` for workflow parameters** — Document required inputs at the top level.
6. **Set appropriate gates** — `human` for risky steps (deploy, commit, push) and for steps that need human review (replaces old `manual` type), `review` for tests with retry, `auto` for safe steps.
7. **Test-fix loops** — Use `review` gate with `max_visits: 3`, `on_fail` pointing to a fix step, fix step pointing back to test.
8. **Timeouts** — Add `timeout: 300` (seconds) for steps that might hang.
9. **Parallel/batch processing** — For parallel or batch processing needs, direct users to Claude Code's built-in `/batch` skill instead of building parallelism into workflows.

## Step 4: Validate

After writing each workflow, run:
```bash
cq workflows validate .claudekiq/workflows/<name>.yml
```

Fix any issues.

## Step 5: Summary

Tell the user what was created and how to use it:
- List the generated workflows with descriptions
- Mention the detected stacks (languages, frameworks, commands) that were used
- Show example invocations: `/cq <workflow>` or `cq start <workflow>`
- Mention they can customize the YAML files directly
