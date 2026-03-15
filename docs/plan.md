# Plan: Claudekiq v3 — Orchestration Platform for Claude Code

## Context

Claudekiq v2 treats Claude like a dumb executor: the SKILL.md runner micromanages every step with 430 lines of instructions telling the AI exactly what to do. This limits Claude Code's power — it can't reason about failures, adapt strategies, or use its full toolset autonomously.

**The v3 vision**: cq becomes a **workflow orchestration platform** that provides structure (sequencing, state, gates, context) while letting Claude Code do the actual work with full autonomy. Agent steps define **goals/outcomes**, not commands. The runner is a thin state machine, not an execution engine.

**Key architectural shift**: Steps describe WHAT needs to happen. Claude decides HOW.

---

## Phase 1: Workflow YAML v3 Format + Core CLI

**Goal**: New step format, params section, model validation, resume field.

### New workflow format

```yaml
name: example
description: Example v3 workflow
params:
  description: "What to build"      # documented parameter
  branch_name: "Feature branch"     # /cq skill enforces interactively

defaults:
  description: ""
  branch_name: ""

steps:
  - id: plan
    name: Plan Implementation
    type: agent
    prompt: "Plan implementation for: {{description}}. Identify files, approach, and risks."
    context: [description]           # context keys injected into agent prompt
    gate: human
    model: sonnet

  - id: create-branch
    name: Create Branch
    type: bash
    target: "git checkout -b feature/{{branch_name}} main"
    gate: auto

  - id: implement
    name: Implement
    type: agent
    target: "@rails-dev"              # spawns stack-specific agent
    prompt: "Implement the plan. All tests must pass."
    context: [description, plan_output]
    gate: review
    max_visits: 3
    model: opus
    resume: true                     # opt-in agent resume on retry

  - id: commit
    name: Commit
    type: bash
    target: "git add -A && git commit -m '{{commit_message}}'"
    gate: human
```

**Key changes from v2**:
- `prompt:` replaces `args_template:` — freeform goal description for agent steps
- `context:` — list of context keys to inject into the agent's prompt (auto-assembled)
- `params:` — top-level section documenting workflow parameters (/cq skill reads this to prompt users; CLI does NOT validate)
- `resume: true` — opt-in agent resume on retry (stores agentId in context)
- `model:` — validated against known models + settings.json defaults
- `target:` — kept for bash steps (explicit commands) and agent steps with `@name` (specific agent)
- `args_template:` — removed (clean v3 break, no backward compat)

### Files to modify

| File | Changes |
|------|---------|
| `lib/core.sh` | Add `cq_valid_model()`, `cq_build_step_prompt()`, add `models`/`default_model` to `cq_default_config()`, update `step_fields` |
| `lib/commands/lifecycle.sh` | `cmd_start()` stores `params` in meta.json, validates model fields (warn), accepts `prompt:`-only agent steps |
| `lib/commands/workflows.sh` | `cmd_workflows_validate()` accepts `prompt:`, validates `model:`, warns on `args_template` |
| `lib/schema.sh` | Update `start` and `workflows` schemas for new fields |
| `tests/fixtures/v3-minimal.yml` | CREATE — v3 format test fixture |
| `tests/fixtures/v3-routing.yml` | CREATE — v3 format with routing |

### Preserve
- All of `lib/storage.sh` — format-agnostic, no changes needed
- `lib/yaml.sh` — unchanged
- Interpolation engine (`cq_interpolate`) — unchanged, works with any `{{expr}}`
- All routing logic (`cq_resolve_next`) — unchanged
- All gate logic in `steps.sh` — unchanged

---

## Phase 2: Runner Rewrite (Split Sub-Skills)

**Goal**: Replace monolithic 430-line SKILL.md with slim state machine + dedicated `/cq-agent` sub-skill.

### `/cq` skill (rewrite) — ~120 lines

The runner becomes a simple state machine:

```
READ STATE → CHECK TERMINAL → CHECK GATES → DISPATCH STEP → EXTRACT RESULTS → ADVANCE → LOOP
```

**Dispatch by step type**:
- `bash` → Run command via Bash tool. Exit code = outcome.
- `agent` → Invoke `/cq-agent` sub-skill with step JSON. AI evaluates results.
- `skill` → Invoke Skill tool with target name.
- `manual` → Display description, gate system creates TODO.
- `subflow` → `cq add-steps`.
- `for_each`/`parallel`/`batch` → CLI for bash children, `/cq-agent` for agent children.
- Custom type → Resolve via `cq_resolve_step_type`, dispatch accordingly.

**What the runner does NOT do anymore**:
- No inline agent execution (everything goes through `/cq-agent`)
- No heartbeat/cron management (delegated to `/cq-agent`)
- No complex timeout enforcement (delegated to `/cq-agent`)
- No structured output extraction — uses AI judgment to read agent responses

**Result extraction**: After `/cq-agent` returns, the runner reads the agent's response and uses its own judgment to extract relevant outputs into workflow context. No rigid JSON format required.

### `/cq-agent` sub-skill (new)

Handles a single agent step:

1. Receive step definition (prompt, context keys, model, target, resume flag)
2. Build agent prompt: assemble `prompt:` + resolved `context:` variables from run context
3. Set up heartbeat cron (only for non-background steps with expected long duration)
4. Spawn Agent tool:
   - `prompt`: assembled goal + project context
   - `model`: from step definition (or default)
   - `subagent_type`: from `@target` if specified
   - `run_in_background`: if `background: true` or `timeout` set
5. If `resume: true` and saved agentId exists, try `Agent(resume: <id>)`. On failure, spawn fresh agent with accumulated context.
6. **Evaluate completion**: AI judges whether the agent achieved the goal described in `prompt:`
7. **Structured summarization**: Ask the agent to summarize results as JSON matching the step's `outputs:` keys. Store in context.
8. Clean up heartbeat cron
9. Return outcome (pass/fail) + result JSON + agentId (for future resume)

### Files

| File | Action |
|------|--------|
| `skills/cq/SKILL.md` | REWRITE — slim state machine (~120 lines) |
| `skills/cq-agent/SKILL.md` | CREATE — agent step execution sub-skill |
| `lib/commands/setup.sh` | Add `_install_agent_skill()`, call from `cmd_init()` |
| `install.sh` | Add cq-agent to remote install file list |
| `.claude-plugin/plugin.json` | Add cq-agent to skills array |

### Depends on: Phase 1

---

## Phase 3: Stack Detection in `cq scan`

**Goal**: Scan detects project language, framework, test/build/lint commands. Stored in `settings.json .stacks`. `/cq-setup` uses this.

### Stack detection logic (`_scan_stacks()`)

| File detected | Language | Framework hint |
|--------------|----------|----------------|
| `package.json` | javascript/typescript | Check for next, react, express, etc. |
| `Gemfile` | ruby | Check for rails, sinatra |
| `go.mod` | go | — |
| `Cargo.toml` | rust | — |
| `pyproject.toml` / `requirements.txt` | python | Check for django, flask, fastapi |
| `pom.xml` / `build.gradle` | java | Check for spring |
| `mix.exs` | elixir | Check for phoenix |
| `Makefile` | (generic) | — |

**Command detection**: Read package.json scripts, Makefile targets, common patterns to identify test/build/lint commands.

**Output** in `settings.json`:
```json
{
  "stacks": [
    {
      "language": "ruby",
      "framework": "rails",
      "test_command": "bundle exec rspec",
      "build_command": "bundle exec rails assets:precompile",
      "lint_command": "bundle exec rubocop"
    },
    {
      "language": "javascript",
      "framework": "react",
      "test_command": "npm test",
      "build_command": "npm run build"
    }
  ],
  "agents": [...],
  "skills": [...]
}
```

### `/cq-setup` update

Rewrite to use stack detection results when generating v3-format workflows. Generated workflows use real detected commands and reference project's actual agents.

### Files

| File | Action |
|------|--------|
| `lib/commands/scan.sh` | Add `_scan_stacks()`, update `cmd_scan()` and `_merge_scan_results()` |
| `lib/schema.sh` | Update `scan` schema output description |
| `skills/cq-setup/SKILL.md` | REWRITE — use stack data, generate v3 format |
| `tests/test_scan_stack.bats` | CREATE — stack detection tests |

### Depends on: Phase 1

---

## Phase 4: Auto-Generated MCP Dispatch

**Goal**: Replace manually maintained 320-line `_mcp_dispatch_tool()` with schema-driven auto-generation.

### Approach

Add `"positional"` field to command schemas listing ordered positional arg names:
```json
{
  "command": "step-done",
  "positional": ["run_id", "step_id", "outcome"],
  "parameters": [...]
}
```

New generic `_mcp_dispatch_tool()`:
1. Strip `cq_` prefix, convert `_` to `-` → command name
2. Read schema: `cmd_schema <command>`
3. Extract positional args in order from schema
4. Extract `--flag=value` args from remaining parameters
5. Call `cmd_<command>` with constructed args

Small override table for subcommand-style commands (ctx, workflows, workers) — tells the dispatcher which parameter is the subcommand. ~50 lines total vs current ~250 lines of manual dispatch.

### Files

| File | Action |
|------|--------|
| `lib/mcp.sh` | REWRITE `_mcp_dispatch_tool()` as generic dispatcher. Keep protocol layer unchanged. |
| `lib/schema.sh` | Add `"positional"` field to all command schemas |
| `tests/test_mcp.bats` | Update to verify auto-dispatch matches expected behavior |

### Depends on: Phase 1 (schemas reflect new fields)

---

## Phase 5: Event-Driven Workers

**Goal**: Foreman pushes gate answers via `Agent(resume: workerId)` instead of workers polling for answer files.

### New flow

1. Foreman spawns workers as background agents, saves agentIds
2. Workers execute workflow steps normally
3. **When a worker hits a gate**: writes gate info to status file and **returns** (agent exits)
4. Foreman receives completion notification, reads status file, sees "gated"
5. Foreman asks user for approval
6. Foreman uses `Agent(resume: workerId)` with gate answer in prompt
7. Worker resumes, applies the answer, continues workflow

**Eliminates**: `sleep 5` polling loop, `.answer.json` files, 5-30s gate latency.

### Files

| File | Action |
|------|--------|
| `skills/cq-workers/SKILL.md` | REWRITE — event-driven monitoring with Agent(resume:) for gates |
| `.claude/agents/cq-worker.md` | REWRITE — stop on gate (don't poll), expect resume with answer |
| `lib/commands/workers.sh` | Keep CLI commands, add comments noting v3 push model |

### Depends on: Phase 2 (runner rewrite pattern)

---

## Phase 6: Notifications, Cleanup, Documentation

### 6a: Replace PostToolUse.sh with `cq_fire_hook` notifications

Add `cq_desktop_notify()` to `lib/core.sh`:
```bash
cq_desktop_notify() {
  local title="$1" message="$2" sound="${3:-Ping}"
  if [[ "$CQ_PLATFORM" == "macos" ]]; then
    osascript -e "display notification \"$message\" with title \"$title\" sound name \"$sound\"" &>/dev/null &
  elif command -v notify-send &>/dev/null; then
    notify-send "$title" "$message" &>/dev/null &
  fi
}
```

Update `cq_fire_hook()` to call `cq_desktop_notify()` when `desktop_notifications` is enabled, with hook-specific title/sound mapping.

**Delete**: `.claude/hooks/PostToolUse.sh`
**Update**: `.claude/settings.json` — remove PostToolUse hook entry
**Update**: `lib/commands/setup.sh` — remove `_install_hooks()` or simplify

### 6b: Remove bundled workflows

**Delete**: `docs/examples/feature.yml`, `docs/examples/bugfix.yml`, `tests/fixtures/feature.yml`, `tests/fixtures/bugfix.yml`
**Create**: `docs/examples/release.yml` — v3 format reference
**Update**: Tests that depend on removed fixtures → use `minimal.yml` or v3 fixtures

### 6c: Documentation

| File | Changes |
|------|---------|
| `CLAUDE.md` | Full rewrite: v3 architecture, new step format, split skills, stack detection, MCP auto-gen |
| `README.md` | Update examples to v3 format, update CLI reference, remove `args_template` references |
| `cq` | Version bump |
| `.claude-plugin/plugin.json` | Version bump, add cq-agent to skills |
| `install.sh` | Add cq-agent skill to install list |

### Depends on: All previous phases

---

## Sequencing

```
Phase 1 (YAML format + core)          ← foundation, no dependencies
  │
  ├──→ Phase 2 (Runner rewrite)       ← depends on Phase 1
  │      │
  │      └──→ Phase 5 (Workers)       ← depends on Phase 2
  │
  ├──→ Phase 3 (Stack detection)      ← depends on Phase 1
  │
  └──→ Phase 4 (MCP auto-dispatch)    ← depends on Phase 1

All ──→ Phase 6 (Cleanup + docs)      ← depends on all
```

Phases 2, 3, 4 can run in parallel after Phase 1.

---

## Verification

### Per-phase testing
- `bats tests/` — all existing + new tests pass after each phase
- Phase 1: `cq start v3-minimal --json` works with new format fields
- Phase 2: `/cq <workflow>` runs with new split-skill architecture
- Phase 3: `cq scan --json | jq '.stacks'` returns detected stacks array
- Phase 4: MCP auto-dispatch handles all commands (test every command via MCP)
- Phase 5: Worker gate resolution via Agent resume (manual integration test)
- Phase 6: Desktop notifications fire from `cq_fire_hook`, no PostToolUse.sh

### End-to-end
- Fresh project: `cq init` → `cq scan --json` shows agents + stacks → `/cq-setup` generates v3 workflows → `/cq <workflow>` runs to completion
- Agent steps spawn autonomous sub-agents that work independently
- Gates create TODOs + Tasks, resolve via user interaction
- `cq validate <workflow>` catches invalid model names, missing step IDs

---

## Risk Mitigations

### 1. Agent autonomy scope — layered constraints

Autonomous agents need guardrails without micromanagement. Three layers:

- **Budget**: Steps can set `timeout:` (seconds). Agent works freely within bounds. Exceeded → fail, gate handles it.
- **Scope via `context:`**: The context field defines what the agent sees AND implicitly what it should focus on. `context: [affected_files, root_cause]` scopes the agent to those files/issues.
- **Success criteria in `prompt:`**: Workflow authors write clear criteria. e.g., `"Fix the login bug. Success: all auth tests pass, no regressions in user_spec.rb."` Agent self-evaluates against this.

Implementation: `/cq-agent` sub-skill includes these constraints in the assembled agent prompt. No system-level enforcement — the agent is told its bounds, not forced into them. This preserves Claude's full power while giving direction.

### 2. Result extraction — structured agent summarization

After an agent step completes, the runner doesn't try to infer results from the agent's raw response. Instead:

1. `/cq-agent` prompts the completing agent: *"Summarize your results as JSON with these keys: [keys from step's `outputs:` field]. Include any additional context the next step needs."*
2. Agent returns structured JSON summary
3. Runner stores summarized keys in workflow context via `cq ctx set`

If no `outputs:` field is defined, `/cq-agent` still asks for a freeform summary and the runner stores it as `_result_<step_id>` in context.

This is more reliable than pure AI inference because the agent that did the work summarizes its own results.

### 3. MCP auto-dispatch — generic + override table

Generic auto-dispatch handles ~80% of commands cleanly. For the remaining complex ones:

```bash
# Override table for subcommand-style commands
_MCP_SUBCOMMAND_MAP='{"ctx":"subcommand","workflows":"subcommand","workers":"subcommand"}'
```

The override table tells the auto-dispatcher which parameter is the subcommand. Everything else uses the generic `positional` field from schemas. This keeps the code small (~50 lines) vs the current ~250 lines of manual dispatch.

### 4. Agent resume — critical path with graceful fallback

Resume is important for long-running agent steps where partial work should be preserved. Implementation:

1. `/cq-agent` tries `Agent(resume: <saved_agentId>)` with context about what happened since
2. **If resume succeeds**: agent continues with full prior context
3. **If resume fails** (stale ID, session ended): `/cq-agent` detects the failure and spawns a **fresh agent** with:
   - The original step prompt
   - All accumulated context (previous step outputs, attempt history)
   - A note: "This is retry attempt N. Previous attempt results: [summary from context]"
4. The fresh agent has everything it needs to continue, even without the prior session

This makes resume a performance optimization (preserving agent memory) rather than a correctness requirement (context carries the essential state regardless).
