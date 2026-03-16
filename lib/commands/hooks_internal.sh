#!/usr/bin/env bash
# hooks_internal.sh — Internal hook handler commands (underscore-prefixed, not in help/schema)
# These are called by Claude Code hooks and should be fast — early exit if no active run.

# Find the most recent active run (running or gated) for hook context
_cq_active_run_for_hook() {
  local runs_dir="${CQ_PROJECT_ROOT}/.claudekiq/runs"
  [[ -d "$runs_dir" ]] || return 1

  local newest_run="" newest_ts="0"
  local d meta status updated_at
  for d in "$runs_dir"/*/; do
    [[ -f "${d}meta.json" ]] || continue
    meta=$(cat "${d}meta.json" 2>/dev/null) || continue
    status=$(jq -r '.status' <<< "$meta")
    case "$status" in
      running|gated)
        updated_at=$(jq -r '.updated_at // "0"' <<< "$meta")
        if [[ "$updated_at" > "$newest_ts" ]]; then
          newest_ts="$updated_at"
          newest_run=$(basename "$d")
        fi
        ;;
    esac
  done

  [[ -n "$newest_run" ]] && { echo "$newest_run"; return 0; }
  return 1
}

# Stage context: capture git diff summary and modified files into active run context
# Called by PostToolUse hooks for Bash, Edit, Write
# Reads hook input JSON from stdin
cmd__stage_context() {
  local run_id
  run_id=$(_cq_active_run_for_hook 2>/dev/null) || exit 0

  local meta current_step
  meta=$(cq_read_meta "$run_id" 2>/dev/null) || exit 0
  current_step=$(jq -r '.current_step // empty' <<< "$meta")
  [[ -z "$current_step" ]] && exit 0

  # Read hook input (may contain file paths from Edit/Write)
  local input=""
  if [[ ! -t 0 ]]; then
    input=$(cat 2>/dev/null || true)
  fi

  # Extract file path from hook input if available (Edit/Write hooks)
  local hook_file=""
  if [[ -n "$input" ]]; then
    hook_file=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
  fi

  # Get git diff summary (fast: --stat --name-only)
  local diff_files="" diff_summary=""
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    diff_files=$(git diff --name-only HEAD 2>/dev/null | head -100 || true)
    diff_summary=$(git diff --stat HEAD 2>/dev/null | tail -1 || true)
  fi

  # Build modified files list (combine hook file + git diff)
  local all_files="$diff_files"
  if [[ -n "$hook_file" && "$hook_file" != *".claudekiq/runs/"* ]]; then
    # Add the hook file if not already in the list
    if [[ -n "$all_files" ]]; then
      if ! echo "$all_files" | grep -qF "$hook_file"; then
        all_files="${hook_file}"$'\n'"${all_files}"
      fi
    else
      all_files="$hook_file"
    fi
  fi

  [[ -z "$all_files" && -z "$diff_summary" ]] && exit 0

  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  # Update context: _modified_files and _diff_summary
  if [[ -n "$all_files" ]]; then
    local files_csv
    files_csv=$(echo "$all_files" | tr '\n' ',' | sed 's/,$//')
    cq_with_lock "$run_dir" _cq_ctx_set_locked "$run_dir" "_modified_files" "$files_csv"
  fi

  if [[ -n "$diff_summary" ]]; then
    cq_with_lock "$run_dir" _cq_ctx_set_locked "$run_dir" "_diff_summary" "$diff_summary"
  fi

  # Update step state: append to files array (under lock to avoid racing with step-done)
  if [[ -n "$all_files" ]]; then
    local files_json
    files_json=$(echo "$all_files" | jq -R -s 'split("\n") | map(select(. != ""))')
    cq_with_lock "$run_dir" _cq_stage_files_locked "$run_dir" "$current_step" "$files_json"
  fi

  exit 0
}

_cq_stage_files_locked() {
  local run_dir="$1" step_id="$2" files_json="$3"
  local state
  state=$(cq_read_json "${run_dir}/state.json")
  state=$(jq --arg id "$step_id" --argjson files "$files_json" '
    .[$id].files = ((.[$id].files // []) + $files | unique)
  ' <<< "$state")
  cq_write_json "${run_dir}/state.json" "$state"
}

# Safety check: read per-operation policy and exit accordingly
# Called by hook commands: cq _safety-check <operation>
# Reads optional context from stdin
cmd__safety_check() {
  local operation="${1:?Usage: cq _safety-check <operation>}"

  # For git_checkout, also check for active runs
  if [[ "$operation" == "git_checkout" ]]; then
    local has_active=false
    if ls "${CQ_PROJECT_ROOT}/.claudekiq/runs"/*/meta.json 2>/dev/null | head -1 | grep -q .; then
      local f status
      for f in "${CQ_PROJECT_ROOT}/.claudekiq/runs"/*/meta.json; do
        status=$(jq -r '.status' "$f" 2>/dev/null)
        if [[ "$status" == "running" || "$status" == "gated" ]]; then
          has_active=true
          break
        fi
      done
    fi
    # No active runs → always allow
    [[ "$has_active" == "false" ]] && exit 0
  fi

  # For git_commit, delegate to pre-commit validate
  if [[ "$operation" == "git_commit" ]]; then
    cmd__pre_commit_validate "$@"
    return $?
  fi

  local policy
  policy=$(cq_safety_policy "$operation")

  case "$policy" in
    warn)
      local messages
      case "$operation" in
        rm_claudekiq) messages="Warning: deleting .claudekiq directory — use cq cleanup instead" ;;
        git_checkout) messages="Warning: git checkout/switch while cq workflows are running/gated." ;;
        edit_run_files) messages="Warning: editing run files directly — use cq commands instead" ;;
        git_force_push) messages="Warning: git force-push can overwrite remote history" ;;
        git_reset_hard) messages="Warning: git reset --hard discards uncommitted changes" ;;
        git_rebase) messages="Warning: git rebase during active workflow can cause conflicts" ;;
        *) messages="Warning: operation '${operation}' flagged by safety policy" ;;
      esac
      echo "$messages" >&2
      exit 0
      ;;
    block)
      local messages
      case "$operation" in
        rm_claudekiq) messages="Blocked: cannot delete .claudekiq directory — use cq cleanup instead" ;;
        git_checkout) messages="Blocked: git checkout/switch while cq workflows are running/gated. Pause or cancel active runs first." ;;
        edit_run_files) messages="Blocked: do not edit run files directly — use cq commands instead" ;;
        git_force_push) messages="Blocked: git force-push can overwrite remote history. Use regular push instead." ;;
        git_reset_hard) messages="Blocked: git reset --hard discards uncommitted changes. Stash or commit first." ;;
        git_rebase) messages="Blocked: git rebase during active workflow can cause conflicts. Pause or cancel active runs first." ;;
        *) messages="Blocked: operation '${operation}' blocked by safety policy" ;;
      esac
      echo "$messages" >&2
      exit 2
      ;;
    *)
      # Unknown policy value → allow
      exit 0
      ;;
  esac
}

# Pre-commit validation: check if current workflow step allows commits
# Called by PreToolUse[Bash] when git commit is detected
# Reads hook input JSON from stdin
cmd__pre_commit_validate() {
  local run_id
  run_id=$(_cq_active_run_for_hook 2>/dev/null) || exit 0

  local meta current_step
  meta=$(cq_read_meta "$run_id" 2>/dev/null) || exit 0
  current_step=$(jq -r '.current_step // empty' <<< "$meta")
  [[ -z "$current_step" ]] && exit 0

  # Check if step allows commits
  local step allows_commit step_name
  step=$(cq_get_step "$run_id" "$current_step" 2>/dev/null) || exit 0
  allows_commit=$(jq -r '.allows_commit // false' <<< "$step")
  step_name=$(jq -r '.name // .id' <<< "$step")

  # Also allow if step name/id contains "commit"
  if [[ "$allows_commit" == "true" || "$current_step" == *"commit"* || "$step_name" == *"ommit"* ]]; then
    exit 0
  fi

  local policy
  policy=$(cq_safety_policy "git_commit")

  if [[ "$policy" == "warn" ]]; then
    echo "Warning: git commit during step '${current_step}' (allows_commit not set)" >&2
    exit 0
  else
    echo "Blocked: git commit during step '${current_step}'. Set allows_commit: true in step definition to allow." >&2
    exit 2
  fi
}

# Capture agent output: extract structured data from agent response into context
# Called by PostToolUse[Agent]
# Reads hook input JSON from stdin
cmd__capture_output() {
  local run_id
  run_id=$(_cq_active_run_for_hook 2>/dev/null) || exit 0

  local meta current_step
  meta=$(cq_read_meta "$run_id" 2>/dev/null) || exit 0
  current_step=$(jq -r '.current_step // empty' <<< "$meta")
  [[ -z "$current_step" ]] && exit 0

  # Read hook input
  local input=""
  if [[ ! -t 0 ]]; then
    input=$(cat 2>/dev/null || true)
  fi
  [[ -z "$input" ]] && exit 0

  # Try to extract agent response content
  local response
  response=$(echo "$input" | jq -r '.response.content // .stdout // empty' 2>/dev/null || true)
  [[ -z "$response" ]] && exit 0

  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  # Store raw agent result summary in context
  local summary
  summary=$(echo "$response" | head -50)
  cq_with_lock "$run_dir" _cq_ctx_set_locked "$run_dir" "_result_${current_step}" "$summary"

  # Try to extract JSON blocks from the response
  local json_block
  json_block=$(echo "$response" | grep -Pzo '```json\n[\s\S]*?\n```' 2>/dev/null | sed '1d;$d' || true)
  if [[ -n "$json_block" ]] && jq '.' <<< "$json_block" >/dev/null 2>&1; then
    # Store extracted JSON in context under _output_<step_id>
    cq_with_lock "$run_dir" _cq_ctx_set_locked "$run_dir" "_output_${current_step}" "$json_block"
  fi

  exit 0
}

# Resolve context builders for a step and output assembled context
# Called via: cq _resolve-context <run_id> <step_id>
cmd__resolve_context() {
  local run_id="${1:?Usage: cq _resolve-context <run_id> <step_id>}"
  local step_id="${2:?Usage: cq _resolve-context <run_id> <step_id>}"
  cq_resolve_context_builders "$run_id" "$step_id"
}
