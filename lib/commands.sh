#!/usr/bin/env bash
# commands.sh — All cq command implementations

# ============================================================
# Setup commands
# ============================================================

cmd_init() {
  local project_dir="${1:-$PWD}"

  if [[ -d "${project_dir}/.claudekiq" ]]; then
    # Already initialized — still update the skill in case of upgrades
    _install_skill "$project_dir"
    cq_info "Already initialized in ${project_dir}"
    if [[ "$CQ_JSON" == "true" ]]; then
      jq -cn --arg dir "$project_dir" '{status:"exists", directory:$dir}'
    fi
    return 0
  fi

  mkdir -p "${project_dir}/.claudekiq/workflows/private"
  mkdir -p "${project_dir}/.claudekiq/runs"
  mkdir -p "${project_dir}/.claudekiq/plugins"

  # Create default settings.json
  echo '{}' > "${project_dir}/.claudekiq/settings.json"

  # Append to .gitignore
  local gitignore="${project_dir}/.gitignore"
  local needs_private=true
  local needs_runs=true
  if [[ -f "$gitignore" ]]; then
    grep -qF '.claudekiq/workflows/private/' "$gitignore" && needs_private=false
    grep -qF '.claudekiq/runs/' "$gitignore" && needs_runs=false
  fi
  {
    $needs_private && echo '.claudekiq/workflows/private/'
    $needs_runs && echo '.claudekiq/runs/'
  } >> "$gitignore"

  # Install Claude Code skill (/cq)
  _install_skill "$project_dir"

  cq_info "Initialized .claudekiq/ in ${project_dir}"
  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg dir "$project_dir" '{status:"initialized", directory:$dir}'
  fi
}

_install_skill() {
  local project_dir="$1"
  local skill_dir="${project_dir}/.claude/skills/cq"
  mkdir -p "$skill_dir"

  # Try to copy from the cq installation directory first
  local src="${CQ_SCRIPT_DIR}/skills/cq/SKILL.md"
  if [[ -f "$src" ]]; then
    cp "$src" "${skill_dir}/SKILL.md"
    return
  fi

  # Otherwise embed the skill inline
  cat > "${skill_dir}/SKILL.md" <<'SKILL_EOF'
---
name: cq
description: "Claudekiq workflow runner — orchestrates multi-step development workflows. Use /cq to list and run workflows, /cq <workflow> to start a specific one, or /cq status to monitor all jobs."
---

# Claudekiq Workflow Runner

You are the runner for `cq` (claudekiq), a filesystem-backed workflow engine. Your job is to execute workflow steps, handle gates, and drive workflows to completion.

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

When the user wants auto-refresh, invoke the `/loop` skill with a 10-second interval:
- Skill: `loop`, Args: `10s /cq status`
- This will re-run `/cq status` every 10 seconds until the user stops it
- The user can stop it at any time by pressing the interrupt key

## Start Workflow

1. Run: `cq workflows show <name> --json`
2. Extract the `defaults` object from the workflow definition
3. Merge any `--key=val` arguments already provided
4. For each default that has an **empty string value** and was NOT provided via arguments, ask the user for a value. Skip defaults that already have non-empty values (those are true defaults, not required params).
5. Run: `cq start <name> --key=val...` with all collected parameters. Use `--json` to capture the run_id.
6. Extract `run_id` from the JSON response
7. Enter the **Runner Loop**

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

### Step 3: Check for Pending TODOs
If `meta.status` is `gated`:
```bash
cq todos --json
```
For each pending TODO:
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

### Step 5: Interpolate Variables
Replace all `{{variable}}` references in `target` and `args_template` with values from `ctx`. Use the context JSON to resolve them.

### Step 6: Execute Step

Based on the step `type`:

#### `bash`
Run the interpolated `target` as a shell command using the Bash tool.
- Exit code 0 → outcome is `pass`
- Non-zero exit → outcome is `fail`
- Capture stdout as the result

#### `agent`
The `args_template` (interpolated) is your task prompt. Execute it as an AI task:
- Do the work described in the interpolated args_template
- When done, the outcome is `pass`
- If you cannot complete the task, the outcome is `fail`
- The `target` field (e.g. `@rails-dev`) is informational context about the intended agent role

#### `skill`
The `target` contains a skill name (e.g. `/review`). Invoke it:
- Use the Skill tool with the target skill name and the interpolated args_template as arguments
- Pass if successful, fail if not

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

### Step 7: Mark Step Complete
```bash
cq step-done <run_id> <step_id> pass|fail [result_json]
```
If the step produced JSON output (e.g. from a bash command), pass it as `result_json` so outputs can be extracted into context.

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
- For agent steps, YOU are the agent — do the work described in args_template
- For bash steps, run exactly the interpolated command — don't modify it
- If the user wants to pause, run: `cq pause <run_id>`
- If the user wants to cancel, run: `cq cancel <run_id>`
- If the user wants to skip a step, run: `cq skip <run_id>`
SKILL_EOF
}

cmd_version() {
  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg v "$CQ_VERSION" '{version:$v}'
  else
    echo "cq ${CQ_VERSION}"
  fi
}

cmd_help() {
  local command="${1:-}"

  if [[ -n "$command" ]]; then
    _help_for_command "$command"
    return
  fi

  cat <<'HELP'
Usage: cq <command> [subcommand] [args] [flags]

Workflow lifecycle:
  start <template> [--key=val]...   Start a new workflow run
  status [run_id]                   Dashboard (no args) or run detail
  list                              List all active runs
  log <run_id>                      Show event log for a run

Flow control:
  pause <run_id>                    Pause a running workflow
  resume <run_id>                   Resume a paused workflow
  cancel <run_id>                   Cancel a workflow
  retry <run_id>                    Retry a failed workflow

Step control:
  step-done <run_id> <step_id> pass|fail   Mark step complete
  skip <run_id> [step_id]                  Skip current/named step

Human actions:
  todos [--flow <run_id>]           List pending human actions
  todo <#> approve|reject|override|dismiss  Resolve a human action

Context:
  ctx <run_id>                      Show all context variables
  ctx get <key> <run_id>            Get a context variable
  ctx set <key> <value> <run_id>    Set a context variable

Dynamic modification:
  add-step <run_id> <step_json> [--after <step_id>]
  add-steps <run_id> --flow <template> [--after <step_id>]
  set-next <run_id> <step_id> <target>    Force next step

Template management:
  workflows list                    List available templates
  workflows show <name>             Show template details
  workflows validate <file>         Validate a workflow YAML

Configuration:
  config                            Show resolved config
  config get <key>                  Get config value
  config set <key> <value>          Set project config value
  config set --global <key> <value> Set global config value

Setup:
  init                              Initialize .claudekiq/ in current project
  version                           Show version
  help [command]                    Show help
  schema [command]                  Show command schema (JSON)

Maintenance:
  cleanup                           Remove expired runs

Flags:
  --json        Machine-readable JSON output
  --headless    CI mode (auto-approve gates, JSON output)
HELP
}

_help_for_command() {
  local cmd="$1"
  case "$cmd" in
    start)   echo "Usage: cq start <template> [--key=val]... [--priority=<level>]" ;;
    status)  echo "Usage: cq status [run_id]" ;;
    list)    echo "Usage: cq list" ;;
    log)     echo "Usage: cq log <run_id> [--tail N]" ;;
    pause)   echo "Usage: cq pause <run_id>" ;;
    resume)  echo "Usage: cq resume <run_id>" ;;
    cancel)  echo "Usage: cq cancel <run_id>" ;;
    retry)   echo "Usage: cq retry <run_id>" ;;
    step-done) echo "Usage: cq step-done <run_id> <step_id> pass|fail [result_json]" ;;
    skip)    echo "Usage: cq skip <run_id> [step_id]" ;;
    todos)   echo "Usage: cq todos [--flow <run_id>]" ;;
    todo)    echo "Usage: cq todo <#> approve|reject|override|dismiss [--note \"...\"]" ;;
    ctx)     echo "Usage: cq ctx <run_id> | cq ctx get <key> <run_id> | cq ctx set <key> <value> <run_id>" ;;
    add-step)  echo "Usage: cq add-step <run_id> <step_json> [--after <step_id>]" ;;
    add-steps) echo "Usage: cq add-steps <run_id> --flow <template> [--after <step_id>]" ;;
    set-next)  echo "Usage: cq set-next <run_id> <step_id> <target>" ;;
    workflows) echo "Usage: cq workflows list|show|validate" ;;
    config)    echo "Usage: cq config | cq config get <key> | cq config set [--global] <key> <value>" ;;
    init)    echo "Usage: cq init" ;;
    schema)  echo "Usage: cq schema [command]" ;;
    cleanup) echo "Usage: cq cleanup" ;;
    *)       echo "Unknown command: $cmd. Run 'cq help' for usage." ;;
  esac
}

# ============================================================
# Workflow template commands
# ============================================================

cmd_workflows() {
  local subcmd="${1:-list}"
  shift 2>/dev/null || true

  case "$subcmd" in
    list)     cmd_workflows_list "$@" ;;
    show)     cmd_workflows_show "$@" ;;
    validate) cmd_workflows_validate "$@" ;;
    *)        cq_die "Unknown workflows subcommand: $subcmd" ;;
  esac
}

cmd_workflows_list() {
  local workflows
  workflows=$(cq_list_workflows)

  if [[ "$CQ_JSON" == "true" ]]; then
    local json="[]"
    local name
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      local file desc=""
      file=$(cq_find_workflow "$name") || continue
      local wf_json
      wf_json=$(cq_yaml_to_json "$file")
      desc=$(echo "$wf_json" | jq -r '.description // ""')
      json=$(echo "$json" | jq --arg n "$name" --arg d "$desc" '. + [{name:$n, description:$d}]')
    done <<< "$workflows"
    echo "$json" | jq '.'
  else
    if [[ -z "$workflows" ]]; then
      echo "No workflows found."
      return
    fi
    local name
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      local file desc=""
      file=$(cq_find_workflow "$name") || continue
      local wf_json
      wf_json=$(cq_yaml_to_json "$file")
      desc=$(echo "$wf_json" | jq -r '.description // ""')
      printf "  %-20s %s\n" "$name" "$desc"
    done <<< "$workflows"
  fi
}

cmd_workflows_show() {
  local name="${1:?Usage: cq workflows show <name>}"
  local file
  file=$(cq_find_workflow "$name") || cq_die "Workflow not found: ${name}"

  local wf_json
  wf_json=$(cq_yaml_to_json "$file")

  if [[ "$CQ_JSON" == "true" ]]; then
    echo "$wf_json" | jq '.'
  else
    local wf_name desc default_priority
    wf_name=$(echo "$wf_json" | jq -r '.name // ""')
    desc=$(echo "$wf_json" | jq -r '.description // ""')
    default_priority=$(echo "$wf_json" | jq -r '.default_priority // "normal"')

    echo "Workflow: ${wf_name:-$name}"
    [[ -n "$desc" ]] && echo "Description: $desc"
    echo "Priority: $default_priority"
    echo ""
    echo "Steps:"
    echo "$wf_json" | jq -r '.steps[] | "  \(.id)\t\(.type)\t\(.name // "")\tgate=\(.gate // "auto")"'
  fi
}

cmd_workflows_validate() {
  local file="${1:?Usage: cq workflows validate <file>}"
  [[ -f "$file" ]] || cq_die "File not found: ${file}"

  local wf_json errors=()
  wf_json=$(cq_yaml_to_json "$file") || cq_die "Invalid YAML: ${file}"

  # Check required fields
  local wf_name
  wf_name=$(echo "$wf_json" | jq -r '.name // empty')
  [[ -z "$wf_name" ]] && errors+=("Missing 'name' field")

  # Check steps exist and are non-empty
  local step_count
  step_count=$(echo "$wf_json" | jq '.steps | length')
  [[ "$step_count" -eq 0 ]] && errors+=("Steps must be non-empty")

  # Validate each step
  local i step_id step_type
  for ((i = 0; i < step_count; i++)); do
    step_id=$(echo "$wf_json" | jq -r --argjson i "$i" '.steps[$i].id // empty')
    step_type=$(echo "$wf_json" | jq -r --argjson i "$i" '.steps[$i].type // empty')

    [[ -z "$step_id" ]] && errors+=("Step $i: missing 'id'")
    [[ -z "$step_type" ]] && errors+=("Step $i: missing 'type'")

    # Validate ID format
    if [[ -n "$step_id" && ! "$step_id" =~ ^[a-z0-9_-]+$ ]]; then
      errors+=("Step '${step_id}': ID must match [a-z0-9_-]+")
    fi
  done

  # Check for duplicate step IDs
  local dupes
  dupes=$(echo "$wf_json" | jq -r '[.steps[].id] | group_by(.) | map(select(length > 1)) | .[0][0] // empty')
  [[ -n "$dupes" ]] && errors+=("Duplicate step ID: ${dupes}")

  if [[ ${#errors[@]} -gt 0 ]]; then
    if [[ "$CQ_JSON" == "true" ]]; then
      printf '%s\n' "${errors[@]}" | jq -Rcs 'split("\n") | map(select(. != "")) | {valid:false, errors:.}'
    else
      echo "Validation FAILED for ${file}:"
      printf '  - %s\n' "${errors[@]}"
    fi
    return 1
  fi

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn '{valid:true, errors:[]}'
  else
    echo "Valid: ${file}"
  fi
}

# ============================================================
# Workflow lifecycle commands
# ============================================================

cmd_start() {
  local template="" priority="" ctx_vars=()

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --priority=*) priority="${1#*=}" ;;
      --headless)   CQ_HEADLESS="true"; CQ_JSON="true" ;;
      --*)
        local key="${1#--}"
        local val="${key#*=}"
        key="${key%%=*}"
        ctx_vars+=("$key" "$val")
        ;;
      *)
        if [[ -z "$template" ]]; then
          template="$1"
        fi
        ;;
    esac
    shift
  done

  [[ -z "$template" ]] && cq_die "Usage: cq start <template> [--key=val]..."

  # Find and parse workflow
  local wf_file
  wf_file=$(cq_find_workflow "$template") || cq_die "Workflow not found: ${template}"
  local wf_json
  wf_json=$(cq_yaml_to_json "$wf_file")

  # Determine priority
  if [[ -z "$priority" ]]; then
    priority=$(echo "$wf_json" | jq -r '.default_priority // empty')
    [[ -z "$priority" ]] && priority=$(cq_config_get "default_priority")
    [[ -z "$priority" ]] && priority="normal"
  fi
  cq_valid_priority "$priority" || cq_die "Invalid priority: ${priority}"

  # Check concurrency
  local config max_concurrency running_count
  config=$(cq_resolve_config)
  max_concurrency=$(echo "$config" | jq -r '.concurrency // 1')
  running_count=$(_count_running_runs)
  local initial_status="running"
  if [[ "$running_count" -ge "$max_concurrency" ]]; then
    initial_status="queued"
  fi

  # Generate run ID
  local run_id
  run_id=$(cq_gen_id)
  local run_dir
  run_dir=$(cq_run_dir "$run_id")
  mkdir -p "$run_dir"

  local ts
  ts=$(cq_now)

  # Build context from defaults + CLI args
  local ctx
  local defaults
  defaults=$(echo "$wf_json" | jq '.defaults // {}')
  ctx=$(echo "$defaults" | jq '.')

  # Apply CLI context variables
  local idx=0
  while [[ $idx -lt ${#ctx_vars[@]} ]]; do
    local k="${ctx_vars[$idx]}"
    local v="${ctx_vars[$((idx + 1))]}"
    ctx=$(echo "$ctx" | jq --arg k "$k" --arg v "$v" '.[$k] = $v')
    idx=$((idx + 2))
  done

  # Write meta.json
  local first_step
  first_step=$(echo "$wf_json" | jq -r '.steps[0].id')
  local meta
  meta=$(jq -cn \
    --arg id "$run_id" \
    --arg template "$template" \
    --arg status "$initial_status" \
    --arg priority "$priority" \
    --arg created_at "$ts" \
    --arg updated_at "$ts" \
    --arg current_step "$first_step" \
    --arg started_by "user" \
    '{id:$id, template:$template, status:$status, priority:$priority,
      created_at:$created_at, updated_at:$updated_at,
      current_step:$current_step, started_by:$started_by}')
  cq_write_json "${run_dir}/meta.json" "$meta"

  # Write ctx.json
  cq_write_json "${run_dir}/ctx.json" "$ctx"

  # Write steps.json (copy step definitions)
  local steps
  steps=$(echo "$wf_json" | jq '.steps')
  cq_write_json "${run_dir}/steps.json" "$steps"

  # Write state.json (initialize all steps as pending)
  local state='{}'
  local step_id
  for step_id in $(echo "$steps" | jq -r '.[].id'); do
    state=$(echo "$state" | jq --arg id "$step_id" \
      '.[$id] = {"status":"pending","visits":0,"attempt":0,"result":null,"started_at":null,"finished_at":null}')
  done
  cq_write_json "${run_dir}/state.json" "$state"

  # Initialize log
  touch "${run_dir}/log.jsonl"
  cq_log_event "$run_dir" "run_started" \
    "$(jq -cn --arg tpl "$template" --arg priority "$priority" '{template:$tpl, priority:$priority}')"

  # Fire on_start hook
  cq_fire_hook "on_start" "$run_dir"

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg id "$run_id" --arg status "$initial_status" --arg template "$template" \
      '{run_id:$id, status:$status, template:$template}'
  else
    local marker
    marker=$(cq_marker "$initial_status")
    echo "${marker} Started workflow '${template}' — run ${run_id} (${initial_status})"
  fi
}

_count_running_runs() {
  local count=0
  local run_id
  for run_id in $(cq_run_ids); do
    local status
    status=$(jq -r '.status' "$(cq_run_dir "$run_id")/meta.json" 2>/dev/null)
    [[ "$status" == "running" ]] && count=$((count + 1))
  done
  echo "$count"
}

cmd_status() {
  local run_id="${1:-}"

  if [[ -n "$run_id" ]]; then
    _status_detail "$run_id"
  else
    _status_dashboard
  fi
}

_status_dashboard() {
  local all_runs=()
  local run_id
  for run_id in $(cq_run_ids); do
    all_runs+=("$run_id")
  done

  if [[ ${#all_runs[@]} -eq 0 ]]; then
    if [[ "$CQ_JSON" == "true" ]]; then
      echo '{"runs":[],"todos":[]}'
    else
      echo "No active workflow runs."
    fi
    return
  fi

  if [[ "$CQ_JSON" == "true" ]]; then
    local runs_json="[]"
    for run_id in "${all_runs[@]}"; do
      local meta
      meta=$(cq_read_meta "$run_id" 2>/dev/null) || continue
      runs_json=$(echo "$runs_json" | jq --argjson m "$meta" '. + [$m]')
    done
    local todos
    todos=$(cq_list_todos)
    jq -cn --argjson runs "$runs_json" --argjson todos "$todos" \
      '{runs:$runs, todos:$todos}'
  else
    echo "=== Workflow Dashboard ==="
    echo ""
    for run_id in "${all_runs[@]}"; do
      local meta status template priority current_step
      meta=$(cq_read_meta "$run_id" 2>/dev/null) || continue
      status=$(echo "$meta" | jq -r '.status')
      template=$(echo "$meta" | jq -r '.template')
      priority=$(echo "$meta" | jq -r '.priority')
      current_step=$(echo "$meta" | jq -r '.current_step // "-"')
      local marker
      marker=$(cq_marker "$status")
      printf "  %s %-8s %-15s %-8s step: %s\n" "$marker" "$run_id" "$template" "[$priority]" "$current_step"
    done

    # Show pending TODOs
    local todos
    todos=$(cq_list_todos)
    local todo_count
    todo_count=$(echo "$todos" | jq 'length')
    if [[ "$todo_count" -gt 0 ]]; then
      echo ""
      echo "Pending actions (${todo_count}):"
      local i
      for ((i = 0; i < todo_count; i++)); do
        local todo step_name action run
        todo=$(echo "$todos" | jq --argjson i "$i" '.[$i]')
        step_name=$(echo "$todo" | jq -r '.step_name')
        action=$(echo "$todo" | jq -r '.action')
        run=$(echo "$todo" | jq -r '.run_id')
        printf "  #%d  %s — %s (run %s)\n" "$((i + 1))" "$step_name" "$action" "$run"
      done
    fi
  fi
}

_status_detail() {
  local run_id="$1"
  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"

  local meta ctx steps state
  meta=$(cq_read_meta "$run_id")
  ctx=$(cq_read_ctx "$run_id")
  steps=$(cq_read_steps "$run_id")
  state=$(cq_read_state "$run_id")

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --argjson meta "$meta" --argjson ctx "$ctx" \
      --argjson steps "$steps" --argjson state "$state" \
      '{meta:$meta, ctx:$ctx, steps:$steps, state:$state}'
  else
    local status template priority current_step created_at
    status=$(echo "$meta" | jq -r '.status')
    template=$(echo "$meta" | jq -r '.template')
    priority=$(echo "$meta" | jq -r '.priority')
    current_step=$(echo "$meta" | jq -r '.current_step // "-"')
    created_at=$(echo "$meta" | jq -r '.created_at')

    local marker
    marker=$(cq_marker "$status")

    echo "Run: ${run_id}  ${marker} ${status}"
    echo "Template: ${template}  Priority: ${priority}"
    echo "Started: ${created_at}"
    echo "Current step: ${current_step}"
    echo ""
    echo "Steps:"
    local step_count i
    step_count=$(echo "$steps" | jq 'length')
    for ((i = 0; i < step_count; i++)); do
      local sid stype
      sid=$(echo "$steps" | jq -r --argjson i "$i" '.[$i].id')
      stype=$(echo "$steps" | jq -r --argjson i "$i" '.[$i].type')
      local sstatus svisits
      sstatus=$(echo "$state" | jq -r --arg id "$sid" '.[$id].status // "pending"')
      svisits=$(echo "$state" | jq -r --arg id "$sid" '.[$id].visits // 0')
      local sm
      sm=$(cq_marker "$sstatus")
      printf "  %s %-20s %-8s %-10s visits:%s\n" "$sm" "$sid" "$stype" "$sstatus" "$svisits"
    done
  fi
}

cmd_list() {
  local runs_json="[]"
  local run_id

  for run_id in $(cq_run_ids); do
    local meta
    meta=$(cq_read_meta "$run_id" 2>/dev/null) || continue
    runs_json=$(echo "$runs_json" | jq --argjson m "$meta" '. + [$m]')
  done

  if [[ "$CQ_JSON" == "true" ]]; then
    echo "$runs_json" | jq '.'
  else
    if [[ $(echo "$runs_json" | jq 'length') -eq 0 ]]; then
      echo "No workflow runs."
      return
    fi
    echo "$runs_json" | jq -r '.[] | "\(.id)\t\(.status)\t\(.template)\t\(.priority)"' | \
      while IFS=$'\t' read -r id status template priority; do
        local marker
        marker=$(cq_marker "$status")
        printf "  %s %-8s %-12s %-15s\n" "$marker" "$id" "$status" "$template"
      done
  fi
}

cmd_log() {
  local run_id="" tail_n=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tail=*) tail_n="${1#*=}" ;;
      --tail) shift; tail_n="$1" ;;
      *) [[ -z "$run_id" ]] && run_id="$1" ;;
    esac
    shift
  done

  [[ -z "$run_id" ]] && cq_die "Usage: cq log <run_id> [--tail N]"
  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"

  local log_file
  log_file="$(cq_run_dir "$run_id")/log.jsonl"
  [[ -f "$log_file" ]] || { echo "No log entries."; return; }

  if [[ "$CQ_JSON" == "true" ]]; then
    if [[ -n "$tail_n" ]]; then
      tail -n "$tail_n" "$log_file" | jq -s '.'
    else
      jq -s '.' "$log_file"
    fi
  else
    local line
    if [[ -n "$tail_n" ]]; then
      tail -n "$tail_n" "$log_file"
    else
      cat "$log_file"
    fi | while IFS= read -r line; do
      local ts event data_str
      ts=$(echo "$line" | jq -r '.ts')
      event=$(echo "$line" | jq -r '.event')
      data_str=$(echo "$line" | jq -c '.data // {}')
      printf "  %s  %-20s %s\n" "$ts" "$event" "$data_str"
    done
  fi
}

# ============================================================
# Step control commands
# ============================================================

cmd_step_done() {
  local run_id="${1:?Usage: cq step-done <run_id> <step_id> pass|fail [result_json]}"
  local step_id="${2:?Usage: cq step-done <run_id> <step_id> pass|fail}"
  local outcome="${3:?Usage: cq step-done <run_id> <step_id> pass|fail}"
  local result_json="${4:-null}"

  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"
  [[ "$outcome" == "pass" || "$outcome" == "fail" ]] || cq_die "Outcome must be 'pass' or 'fail'"

  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  cq_acquire_lock "$run_dir"
  trap 'cq_release_lock' EXIT

  local ts
  ts=$(cq_now)

  # Update step state
  local state step_state visits
  state=$(cq_read_state "$run_id")
  step_state=$(echo "$state" | jq --arg id "$step_id" '.[$id]')
  visits=$(echo "$step_state" | jq '.visits // 0')
  visits=$((visits + 1))

  local new_status
  [[ "$outcome" == "pass" ]] && new_status="passed" || new_status="failed"

  # Validate result_json
  if [[ "$result_json" != "null" ]]; then
    echo "$result_json" | jq '.' >/dev/null 2>&1 || result_json="null"
  fi

  state=$(echo "$state" | jq \
    --arg id "$step_id" \
    --arg status "$new_status" \
    --argjson visits "$visits" \
    --arg result "$outcome" \
    --arg finished_at "$ts" \
    --argjson result_json "$result_json" \
    '.[$id].status = $status | .[$id].visits = $visits | .[$id].result = $result |
     .[$id].finished_at = $finished_at | .[$id].result_data = $result_json')
  cq_write_json "${run_dir}/state.json" "$state"

  # Log step completion
  cq_log_event "$run_dir" "step_done" \
    "$(jq -cn --arg step "$step_id" --arg result "$outcome" --argjson visits "$visits" \
      '{step:$step, result:$result, visits:$visits}')"

  # Extract outputs if step defines them
  _extract_outputs "$run_id" "$step_id" "$result_json"

  # Handle gate logic
  local step
  step=$(cq_get_step "$run_id" "$step_id")
  local gate
  gate=$(echo "$step" | jq -r '.gate // "auto"')

  _handle_gate "$run_id" "$step_id" "$outcome" "$gate" "$visits"

  cq_release_lock
  trap - EXIT

  if [[ "$CQ_JSON" == "true" ]]; then
    local meta
    meta=$(cq_read_meta "$run_id")
    jq -cn --arg step "$step_id" --arg outcome "$outcome" --argjson meta "$meta" \
      '{step:$step, outcome:$outcome, meta:$meta}'
  fi
}

_extract_outputs() {
  local run_id="$1" step_id="$2" result_json="$3"
  [[ "$result_json" == "null" ]] && return

  local step
  step=$(cq_get_step "$run_id" "$step_id")
  local outputs_type
  outputs_type=$(echo "$step" | jq -r '.outputs | type')

  if [[ "$outputs_type" == "object" ]]; then
    # outputs is a map of ctx_key -> jq_filter
    local keys
    keys=$(echo "$step" | jq -r '.outputs | keys[]')
    local key filter value
    while IFS= read -r key; do
      [[ -z "$key" ]] && continue
      filter=$(echo "$step" | jq -r --arg k "$key" '.outputs[$k]')
      value=$(echo "$result_json" | jq -r "$filter" 2>/dev/null || echo "")
      if [[ -n "$value" && "$value" != "null" ]]; then
        cq_ctx_set "$run_id" "$key" "$value"
      fi
    done <<< "$keys"
  elif [[ "$outputs_type" == "array" ]]; then
    # outputs is a list of keys to extract from result (top-level)
    local key value
    for key in $(echo "$step" | jq -r '.outputs[]'); do
      value=$(echo "$result_json" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null)
      if [[ -n "$value" ]]; then
        cq_ctx_set "$run_id" "$key" "$value"
      fi
    done
  fi
}

_handle_gate() {
  local run_id="$1" step_id="$2" outcome="$3" gate="$4" visits="$5"
  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  case "$gate" in
    auto)
      _advance_run "$run_id" "$step_id" "$outcome"
      ;;
    human)
      if [[ "$CQ_HEADLESS" == "true" ]]; then
        # Headless: auto-approve
        _advance_run "$run_id" "$step_id" "pass"
      else
        # Create TODO and set run to gated
        local desc
        desc=$(cq_get_step "$run_id" "$step_id" | jq -r '.description // .name // .id')
        cq_create_todo "$run_id" "$step_id" "review" "$desc"
        cq_update_meta "$run_id" '.status = "gated"'
        cq_log_event "$run_dir" "gate_human" \
          "$(jq -cn --arg step "$step_id" '{step:$step}')"
        cq_info "$(cq_marker "gated") Waiting for human approval at step '${step_id}'"
      fi
      ;;
    review)
      if [[ "$outcome" == "pass" ]]; then
        _advance_run "$run_id" "$step_id" "pass"
      else
        # Check max_visits
        local step max_visits
        step=$(cq_get_step "$run_id" "$step_id")
        max_visits=$(echo "$step" | jq -r '.max_visits // 0')
        max_visits=${max_visits:-0}

        if [[ "$max_visits" -gt 0 && "$visits" -ge "$max_visits" ]]; then
          if [[ "$CQ_HEADLESS" == "true" ]]; then
            # Headless: fail the run
            cq_update_meta "$run_id" '.status = "failed"'
            cq_log_event "$run_dir" "run_failed" \
              "$(jq -cn --arg step "$step_id" '{step:$step, reason:"max_visits_exceeded_headless"}')"
            cq_fire_hook "on_fail" "$run_dir"
          else
            # Create TODO for override
            local desc
            desc="Max visits (${max_visits}) reached for step '${step_id}'"
            cq_create_todo "$run_id" "$step_id" "override" "$desc"
            cq_update_meta "$run_id" '.status = "gated"'
            cq_log_event "$run_dir" "gate_review_escalated" \
              "$(jq -cn --arg step "$step_id" --argjson visits "$visits" --argjson max "$max_visits" \
                '{step:$step, visits:$visits, max_visits:$max}')"
            cq_info "$(cq_marker "gated") Step '${step_id}' exceeded max visits — escalated to human"
          fi
        else
          # Retry via on_fail route
          _advance_run "$run_id" "$step_id" "fail"
        fi
      fi
      ;;
    *)
      # Unknown gate, treat as auto
      _advance_run "$run_id" "$step_id" "$outcome"
      ;;
  esac
}

_advance_run() {
  local run_id="$1" step_id="$2" outcome="$3"
  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  # Resolve next step
  local next_step
  next_step=$(cq_resolve_next "$run_id" "$step_id" "$outcome")

  cq_log_event "$run_dir" "gate_auto" \
    "$(jq -cn --arg step "$step_id" --arg next "$next_step" '{step:$step, next:$next}')"

  if [[ "$next_step" == "end" || -z "$next_step" ]]; then
    # Workflow complete
    cq_update_meta "$run_id" '.status = "completed" | .current_step = null'
    cq_log_event "$run_dir" "run_completed" '{}'
    cq_fire_hook "on_complete" "$run_dir"
    cq_info "$(cq_marker "passed") Workflow completed (run ${run_id})"
  else
    # Advance to next step
    local ts
    ts=$(cq_now)
    # shellcheck disable=SC2016
    cq_update_meta "$run_id" '.status = "running" | .current_step = $cs' \
      --arg cs "$next_step"

    # Mark next step as running
    local state
    state=$(cq_read_state "$run_id")
    state=$(echo "$state" | jq --arg id "$next_step" --arg ts "$ts" \
      '.[$id].status = "running" | .[$id].started_at = $ts | .[$id].attempt = ((.[$id].attempt // 0) + 1)')
    cq_write_json "${run_dir}/state.json" "$state"

    cq_log_event "$run_dir" "step_started" \
      "$(jq -cn --arg step "$next_step" '{step:$step}')"
  fi
}

cmd_skip() {
  local run_id="${1:?Usage: cq skip <run_id> [step_id]}"
  local step_id="${2:-}"

  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"

  # Default to current step
  if [[ -z "$step_id" ]]; then
    step_id=$(jq -r '.current_step' "$(cq_run_dir "$run_id")/meta.json")
  fi
  [[ -z "$step_id" || "$step_id" == "null" ]] && cq_die "No current step to skip"

  local run_dir
  run_dir=$(cq_run_dir "$run_id")
  local ts
  ts=$(cq_now)

  cq_acquire_lock "$run_dir"
  trap 'cq_release_lock' EXIT

  # Mark step as skipped
  local state
  state=$(cq_read_state "$run_id")
  state=$(echo "$state" | jq --arg id "$step_id" --arg ts "$ts" \
    '.[$id].status = "skipped" | .[$id].finished_at = $ts')
  cq_write_json "${run_dir}/state.json" "$state"

  cq_log_event "$run_dir" "step_skipped" \
    "$(jq -cn --arg step "$step_id" '{step:$step}')"

  # Advance as if passed
  _advance_run "$run_id" "$step_id" "pass"

  cq_release_lock
  trap - EXIT

  cq_info "$(cq_marker "skipped") Skipped step '${step_id}'"

  if [[ "$CQ_JSON" == "true" ]]; then
    local meta
    meta=$(cq_read_meta "$run_id")
    jq -cn --arg step "$step_id" --argjson meta "$meta" '{skipped:$step, meta:$meta}'
  fi
}

# ============================================================
# Flow control commands
# ============================================================

cmd_pause() {
  local run_id="${1:?Usage: cq pause <run_id>}"
  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"

  local meta status
  meta=$(cq_read_meta "$run_id")
  status=$(echo "$meta" | jq -r '.status')

  case "$status" in
    running|queued|gated)
      cq_update_meta "$run_id" '.status = "paused"'
      local run_dir
      run_dir=$(cq_run_dir "$run_id")
      cq_log_event "$run_dir" "run_paused" '{}'
      cq_info "$(cq_marker "paused") Paused run ${run_id}"
      if [[ "$CQ_JSON" == "true" ]]; then
        jq -cn --arg id "$run_id" '{run_id:$id, status:"paused"}'
      fi
      ;;
    *)
      cq_die "Cannot pause run in '${status}' status"
      ;;
  esac
}

cmd_resume() {
  local run_id="${1:?Usage: cq resume <run_id>}"
  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"

  local meta status
  meta=$(cq_read_meta "$run_id")
  status=$(echo "$meta" | jq -r '.status')

  [[ "$status" == "paused" ]] || cq_die "Cannot resume run in '${status}' status (must be paused)"

  cq_update_meta "$run_id" '.status = "running"'
  local run_dir
  run_dir=$(cq_run_dir "$run_id")
  cq_log_event "$run_dir" "run_resumed" '{}'
  cq_info "$(cq_marker "running") Resumed run ${run_id}"

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg id "$run_id" '{run_id:$id, status:"running"}'
  fi
}

cmd_cancel() {
  local run_id="${1:?Usage: cq cancel <run_id>}"
  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"

  local meta status
  meta=$(cq_read_meta "$run_id")
  status=$(echo "$meta" | jq -r '.status')

  case "$status" in
    completed|cancelled)
      cq_die "Cannot cancel run in '${status}' status"
      ;;
    *)
      cq_update_meta "$run_id" '.status = "cancelled"'
      local run_dir
      run_dir=$(cq_run_dir "$run_id")
      cq_log_event "$run_dir" "run_cancelled" '{}'
      cq_info "$(cq_marker "cancelled") Cancelled run ${run_id}"
      if [[ "$CQ_JSON" == "true" ]]; then
        jq -cn --arg id "$run_id" '{run_id:$id, status:"cancelled"}'
      fi
      ;;
  esac
}

cmd_retry() {
  local run_id="${1:?Usage: cq retry <run_id>}"
  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"

  local meta status
  meta=$(cq_read_meta "$run_id")
  status=$(echo "$meta" | jq -r '.status')

  [[ "$status" == "failed" ]] || cq_die "Cannot retry run in '${status}' status (must be failed)"

  local run_dir current_step
  run_dir=$(cq_run_dir "$run_id")
  current_step=$(echo "$meta" | jq -r '.current_step')

  # Reset the failed step to pending
  if [[ -n "$current_step" && "$current_step" != "null" ]]; then
    local state ts
    ts=$(cq_now)
    state=$(cq_read_state "$run_id")
    state=$(echo "$state" | jq --arg id "$current_step" \
      '.[$id].status = "pending" | .[$id].result = null | .[$id].finished_at = null')
    cq_write_json "${run_dir}/state.json" "$state"
  fi

  cq_update_meta "$run_id" '.status = "running"'
  cq_log_event "$run_dir" "run_retried" \
    "$(jq -cn --arg step "$current_step" '{step:$step}')"
  cq_info "$(cq_marker "running") Retrying run ${run_id} from step '${current_step}'"

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg id "$run_id" --arg step "$current_step" '{run_id:$id, status:"running", retry_step:$step}'
  fi
}

# ============================================================
# Human action commands
# ============================================================

cmd_todos() {
  local filter_run=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --flow=*) filter_run="${1#*=}" ;;
      --flow) shift; filter_run="$1" ;;
    esac
    shift
  done

  local todos
  todos=$(cq_list_todos "$filter_run")
  local count
  count=$(echo "$todos" | jq 'length')

  if [[ "$CQ_JSON" == "true" ]]; then
    echo "$todos" | jq '.'
  else
    if [[ "$count" -eq 0 ]]; then
      echo "No pending actions."
      return
    fi
    echo "Pending actions:"
    local i
    for ((i = 0; i < count; i++)); do
      local todo step_name action run_id description priority
      todo=$(echo "$todos" | jq --argjson i "$i" '.[$i]')
      step_name=$(echo "$todo" | jq -r '.step_name')
      action=$(echo "$todo" | jq -r '.action')
      run_id=$(echo "$todo" | jq -r '.run_id')
      description=$(echo "$todo" | jq -r '.description // ""')
      priority=$(echo "$todo" | jq -r '.priority')
      printf "  #%d  [%s] %s — %s\n" "$((i + 1))" "$priority" "$step_name" "$action"
      [[ -n "$description" ]] && printf "       %s\n" "$description"
      printf "       run: %s\n" "$run_id"
    done
  fi
}

cmd_todo() {
  local index="${1:?Usage: cq todo <#> approve|reject|override|dismiss}"
  local action="${2:?Usage: cq todo <#> approve|reject|override|dismiss}"
  shift 2
  # --note is accepted but currently informational only
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note=*) ;; # accepted, not used yet
      --note) shift ;;
    esac
    shift
  done

  case "$action" in
    approve|reject|override|dismiss) ;;
    *) cq_die "Invalid action: ${action}. Must be approve|reject|override|dismiss" ;;
  esac

  # Find the TODO
  local todo
  todo=$(cq_find_todo_by_index "$index")
  [[ -z "$todo" || "$todo" == "null" ]] && cq_die "No pending action at #${index}"

  local todo_id run_id step_id
  todo_id=$(echo "$todo" | jq -r '.id')
  run_id=$(echo "$todo" | jq -r '.run_id')
  step_id=$(echo "$todo" | jq -r '.step_id')

  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"

  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  case "$action" in
    approve|override)
      cq_update_todo "$run_id" "$todo_id" "done"

      # Mark step as passed
      local state ts
      ts=$(cq_now)
      state=$(cq_read_state "$run_id")
      state=$(echo "$state" | jq --arg id "$step_id" --arg ts "$ts" \
        '.[$id].status = "passed" | .[$id].result = "pass" | .[$id].finished_at = $ts')
      cq_write_json "${run_dir}/state.json" "$state"

      cq_log_event "$run_dir" "todo_${action}" \
        "$(jq -cn --arg tid "$todo_id" --arg sid "$step_id" '{todo_id:$tid, step_id:$sid}')"

      # Advance the run
      _advance_run "$run_id" "$step_id" "pass"

      cq_info "$(cq_marker "passed") Action #${index} ${action}d — advancing run ${run_id}"
      ;;

    reject)
      cq_update_todo "$run_id" "$todo_id" "done"
      cq_update_meta "$run_id" '.status = "failed"'
      cq_log_event "$run_dir" "todo_rejected" \
        "$(jq -cn --arg tid "$todo_id" --arg sid "$step_id" '{todo_id:$tid, step_id:$sid}')"
      cq_fire_hook "on_fail" "$run_dir"
      cq_info "$(cq_marker "failed") Action #${index} rejected — run ${run_id} failed"
      ;;

    dismiss)
      cq_update_todo "$run_id" "$todo_id" "dismissed"
      cq_log_event "$run_dir" "todo_dismissed" \
        "$(jq -cn --arg tid "$todo_id" '{todo_id:$tid}')"
      cq_info "Action #${index} dismissed"
      ;;
  esac

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg todo_id "$todo_id" --arg action "$action" --arg run_id "$run_id" \
      '{todo_id:$todo_id, action:$action, run_id:$run_id}'
  fi
}

# ============================================================
# Context commands
# ============================================================

cmd_ctx() {
  local subcmd="${1:-}"

  case "$subcmd" in
    get)
      shift
      local key="${1:?Usage: cq ctx get <key> <run_id>}"
      local run_id="${2:?Usage: cq ctx get <key> <run_id>}"
      cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"
      local val
      val=$(cq_ctx_get "$run_id" "$key")
      if [[ "$CQ_JSON" == "true" ]]; then
        jq -cn --arg k "$key" --arg v "$val" '{($k):$v}'
      else
        echo "$val"
      fi
      ;;
    set)
      shift
      local key="${1:?Usage: cq ctx set <key> <value> <run_id>}"
      local value="${2:?Usage: cq ctx set <key> <value> <run_id>}"
      local run_id="${3:?Usage: cq ctx set <key> <value> <run_id>}"
      cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"
      cq_ctx_set "$run_id" "$key" "$value"
      cq_info "Set ${key}=${value} for run ${run_id}"
      if [[ "$CQ_JSON" == "true" ]]; then
        jq -cn --arg k "$key" --arg v "$value" --arg id "$run_id" '{key:$k, value:$v, run_id:$id}'
      fi
      ;;
    *)
      # Show all context for a run
      local run_id="${subcmd:?Usage: cq ctx <run_id>}"
      cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"
      local ctx
      ctx=$(cq_read_ctx "$run_id")
      if [[ "$CQ_JSON" == "true" ]]; then
        echo "$ctx" | jq '.'
      else
        echo "$ctx" | jq -r 'to_entries[] | "  \(.key) = \(.value)"'
      fi
      ;;
  esac
}

# ============================================================
# Dynamic modification commands
# ============================================================

cmd_add_step() {
  local run_id="" step_json="" after_step=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --after=*) after_step="${1#*=}" ;;
      --after) shift; after_step="$1" ;;
      *)
        if [[ -z "$run_id" ]]; then
          run_id="$1"
        elif [[ -z "$step_json" ]]; then
          step_json="$1"
        fi
        ;;
    esac
    shift
  done

  [[ -z "$run_id" ]] && cq_die "Usage: cq add-step <run_id> <step_json> [--after <step_id>]"
  [[ -z "$step_json" ]] && cq_die "Usage: cq add-step <run_id> <step_json> [--after <step_id>]"
  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"

  # Validate step JSON
  echo "$step_json" | jq '.' >/dev/null 2>&1 || cq_die "Invalid step JSON"
  local new_step_id
  new_step_id=$(echo "$step_json" | jq -r '.id // empty')
  [[ -z "$new_step_id" ]] && cq_die "Step must have an 'id' field"

  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  cq_acquire_lock "$run_dir"
  trap 'cq_release_lock' EXIT

  local steps
  steps=$(cq_read_steps "$run_id")

  if [[ -n "$after_step" ]]; then
    # Insert after the specified step
    local index
    index=$(echo "$steps" | jq --arg id "$after_step" '[.[] | .id] | to_entries[] | select(.value == $id) | .key')
    [[ -z "$index" ]] && { cq_release_lock; cq_die "Step not found: ${after_step}"; }
    local insert_at=$((index + 1))
    steps=$(echo "$steps" | jq --argjson i "$insert_at" --argjson s "$step_json" \
      '.[:$i] + [$s] + .[$i:]')
  else
    # Append to end
    steps=$(echo "$steps" | jq --argjson s "$step_json" '. + [$s]')
  fi

  cq_write_steps "$run_id" "$steps"

  # Initialize state for new step
  cq_init_step_state "$run_id" "$new_step_id"

  cq_log_event "$run_dir" "step_added" \
    "$(jq -cn --arg id "$new_step_id" --arg after "${after_step:-end}" '{step_id:$id, after:$after}')"

  cq_release_lock
  trap - EXIT

  cq_info "Added step '${new_step_id}'"
  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg id "$new_step_id" --arg run_id "$run_id" '{step_id:$id, run_id:$run_id}'
  fi
}

cmd_add_steps() {
  local run_id="" flow_template="" after_step=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --flow=*) flow_template="${1#*=}" ;;
      --flow) shift; flow_template="$1" ;;
      --after=*) after_step="${1#*=}" ;;
      --after) shift; after_step="$1" ;;
      *)
        [[ -z "$run_id" ]] && run_id="$1"
        ;;
    esac
    shift
  done

  [[ -z "$run_id" ]] && cq_die "Usage: cq add-steps <run_id> --flow <template> [--after <step_id>]"
  [[ -z "$flow_template" ]] && cq_die "Usage: cq add-steps <run_id> --flow <template>"
  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"

  # Find and parse subflow template
  local wf_file
  wf_file=$(cq_find_workflow "$flow_template") || cq_die "Workflow not found: ${flow_template}"
  local wf_json
  wf_json=$(cq_yaml_to_json "$wf_file")

  local sub_steps
  sub_steps=$(echo "$wf_json" | jq '.steps')

  # Prefix step IDs with after_step (or "sub") prefix
  local prefix="${after_step:-sub}"
  sub_steps=$(echo "$sub_steps" | jq --arg p "$prefix" '
    [.[] | .id = ($p + "." + .id) |
     if .on_pass then (if .on_pass != "end" then .on_pass = ($p + "." + .on_pass) else . end) else . end |
     if .on_fail then (if .on_fail != "end" then .on_fail = ($p + "." + .on_fail) else . end) else . end |
     if (.next | type) == "string" then (if .next != "end" then .next = ($p + "." + .next) else . end) else . end |
     if (.next | type) == "array" then .next = [.next[] |
       if .goto then (if .goto != "end" then .goto = ($p + "." + .goto) else . end) else . end |
       if .default then (if .default != "end" then .default = ($p + "." + .default) else . end) else . end
     ] else . end
    ]')

  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  cq_acquire_lock "$run_dir"
  trap 'cq_release_lock' EXIT

  local steps
  steps=$(cq_read_steps "$run_id")

  if [[ -n "$after_step" ]]; then
    local index
    index=$(echo "$steps" | jq --arg id "$after_step" '[.[] | .id] | to_entries[] | select(.value == $id) | .key')
    [[ -z "$index" ]] && { cq_release_lock; cq_die "Step not found: ${after_step}"; }
    local insert_at=$((index + 1))
    steps=$(echo "$steps" | jq --argjson i "$insert_at" --argjson s "$sub_steps" \
      '.[:$i] + $s + .[$i:]')
  else
    steps=$(echo "$steps" | jq --argjson s "$sub_steps" '. + $s')
  fi

  cq_write_steps "$run_id" "$steps"

  # Initialize state for all new steps
  local sid
  for sid in $(echo "$sub_steps" | jq -r '.[].id'); do
    cq_init_step_state "$run_id" "$sid"
  done

  cq_log_event "$run_dir" "steps_added" \
    "$(jq -cn --arg flow "$flow_template" --arg after "${after_step:-end}" '{flow:$flow, after:$after}')"

  cq_release_lock
  trap - EXIT

  local added_count
  added_count=$(echo "$sub_steps" | jq 'length')
  cq_info "Added ${added_count} steps from '${flow_template}'"

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg flow "$flow_template" --argjson count "$added_count" --arg run_id "$run_id" \
      '{flow:$flow, steps_added:$count, run_id:$run_id}'
  fi
}

cmd_set_next() {
  local run_id="${1:?Usage: cq set-next <run_id> <step_id> <target>}"
  local step_id="${2:?Usage: cq set-next <run_id> <step_id> <target>}"
  local target="${3:?Usage: cq set-next <run_id> <step_id> <target>}"

  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"

  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  cq_acquire_lock "$run_dir"
  trap 'cq_release_lock' EXIT

  local steps
  steps=$(cq_read_steps "$run_id")
  steps=$(echo "$steps" | jq --arg id "$step_id" --arg target "$target" \
    '[.[] | if .id == $id then .next = $target else . end]')
  cq_write_steps "$run_id" "$steps"

  cq_log_event "$run_dir" "set_next" \
    "$(jq -cn --arg step "$step_id" --arg target "$target" '{step:$step, target:$target}')"

  cq_release_lock
  trap - EXIT

  cq_info "Set next for '${step_id}' → '${target}'"

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg step "$step_id" --arg target "$target" --arg run_id "$run_id" \
      '{step_id:$step, target:$target, run_id:$run_id}'
  fi
}

# ============================================================
# Configuration commands
# ============================================================

cmd_config() {
  local subcmd="${1:-}"

  case "$subcmd" in
    get)
      shift
      local key="${1:?Usage: cq config get <key>}"
      local val
      val=$(cq_config_get "$key")
      if [[ "$CQ_JSON" == "true" ]]; then
        jq -cn --arg k "$key" --arg v "$val" '{($k):$v}'
      else
        echo "$val"
      fi
      ;;
    set)
      shift
      local is_global=false
      if [[ "$1" == "--global" ]]; then
        is_global=true
        shift
      fi
      local key="${1:?Usage: cq config set [--global] <key> <value>}"
      local value="${2:?Usage: cq config set [--global] <key> <value>}"

      local config_file
      if $is_global; then
        config_file="${HOME}/.cq/config.json"
        mkdir -p "${HOME}/.cq"
      else
        config_file="${CQ_PROJECT_ROOT}/.claudekiq/settings.json"
      fi

      # Ensure file exists
      [[ -f "$config_file" ]] || echo '{}' > "$config_file"

      local config
      config=$(cat "$config_file")
      # Try to parse value as JSON, fall back to string
      if echo "$value" | jq '.' >/dev/null 2>&1; then
        config=$(echo "$config" | jq --arg k "$key" --argjson v "$value" '.[$k] = $v')
      else
        config=$(echo "$config" | jq --arg k "$key" --arg v "$value" '.[$k] = $v')
      fi
      echo "$config" | jq '.' > "$config_file"

      cq_info "Set ${key}=${value}"
      if [[ "$CQ_JSON" == "true" ]]; then
        jq -cn --arg k "$key" --arg v "$value" '{key:$k, value:$v}'
      fi
      ;;
    "")
      # Show resolved config
      local config
      config=$(cq_resolve_config)
      echo "$config" | jq '.'
      ;;
    *)
      cq_die "Unknown config subcommand: ${subcmd}"
      ;;
  esac
}

# ============================================================
# Maintenance commands
# ============================================================

cmd_cleanup() {
  local config ttl removed=0
  config=$(cq_resolve_config)
  ttl=$(echo "$config" | jq -r '.ttl // 2592000')

  local run_id
  for run_id in $(cq_run_ids); do
    local run_dir meta status
    run_dir=$(cq_run_dir "$run_id")
    meta=$(cq_read_meta "$run_id" 2>/dev/null) || continue
    status=$(echo "$meta" | jq -r '.status')

    # Only clean up completed, failed, or cancelled runs
    case "$status" in
      completed|failed|cancelled) ;;
      *) continue ;;
    esac

    local age
    age=$(cq_file_age "${run_dir}/meta.json")
    if [[ "$age" -ge "$ttl" ]]; then
      rm -rf "$run_dir"
      removed=$((removed + 1))
    fi
  done

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --argjson n "$removed" '{removed:$n}'
  else
    echo "Removed ${removed} expired run(s)."
  fi
}
