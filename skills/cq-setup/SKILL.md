---
name: cq-setup
description: "Smart project setup — scans agents/skills and generates customized workflows based on your project. Use /cq-setup after cq init."
allowed-tools: Bash, Read, Glob, Grep, Write, AskUserQuestion
---

# Claudekiq Smart Init

You generate customized cq workflows based on the project's actual agents, skills, and stack.

## Step 1: Gather Project Info

Run these commands to understand the project:

```bash
cq scan --json
```

This gives you the available agents, skills, and plugins.

Also examine the project structure to detect the stack:
- Check for `package.json` (Node.js), `Gemfile` (Ruby), `go.mod` (Go), `Cargo.toml` (Rust), `pyproject.toml` / `requirements.txt` (Python), `Makefile`, etc.
- Read the main config file to understand the test/build/lint commands
- Check `.claude/agents/*.md` for available agent definitions

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

For each requested workflow, generate a YAML file at `.claudekiq/workflows/<name>.yml` that:

1. **References actual project agents** — use `@agent-name` targets that match agents discovered by `cq scan`
2. **Uses real commands** — `npm test`, `cargo build`, `bats tests/`, etc. based on detected stack
3. **Sets appropriate gates** — `human` for risky steps (deploy, commit, push), `review` for tests with retry, `auto` for safe steps
4. **Includes sensible defaults** — context variables the workflow needs

### Workflow Template Structure

```yaml
name: <workflow-name>
description: <one-line description>
default_priority: normal

defaults:
  key: "default_value"
  required_param: ""  # empty = user must provide

steps:
  - id: <step-id>
    name: <Human-readable Name>
    type: bash|agent|skill|manual
    target: "<command or @agent-name>"
    args_template: "Template with {{variables}}"
    gate: auto|human|review
    max_visits: 3  # for review gates
    on_pass: <next-step-id>
    on_fail: <fix-step-id>
```

### Key Patterns

- **Test-fix loops**: Use `review` gate with `max_visits`, `on_fail` pointing to a fix step, fix step pointing back to test
- **Agent steps without @target**: The runner itself does the work (good for simple tasks)
- **Agent steps with @target**: A specialized agent handles it (e.g., `@code-review`, `@implementer`)
- **Background steps**: Add `background: true` for long-running agent tasks
- **Timeouts**: Add `timeout: 300` (seconds) for steps that might hang
- **Outputs**: Use `outputs: [key1, key2]` to extract results into context

## Step 4: Validate

After writing each workflow, run:
```bash
cq workflows validate .claudekiq/workflows/<name>.yml
```

Fix any issues.

## Step 5: Summary

Tell the user what was created and how to use it:
- List the generated workflows with descriptions
- Show example invocations: `/cq <workflow>` or `cq start <workflow>`
- Mention they can customize the YAML files directly
