#!/usr/bin/env bash
# steps.sh — Step control: step-done, skip, gate handling, output extraction, advance

cmd_step_done() {
  local run_id="${1:?Usage: cq step-done <run_id> <step_id> pass|fail [result_json]}"
  local step_id="${2:?Usage: cq step-done <run_id> <step_id> pass|fail}"
  local outcome="${3:?Usage: cq step-done <run_id> <step_id> pass|fail}"
  local result_json="${4:-null}"
  local branches_json=""
  local step_output="" step_stderr=""

  # Check for flags (--branches, --output, --stderr)
  shift 3 2>/dev/null || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branches=*) branches_json="${1#*=}" ;;
      --branches) shift; branches_json="$1" ;;
      --output=*) step_output="${1#*=}" ;;
      --output) shift; step_output="$1" ;;
      --stderr=*) step_stderr="${1#*=}" ;;
      --stderr) shift; step_stderr="$1" ;;
      *) [[ -z "$result_json" || "$result_json" == "null" ]] && result_json="$1" ;;
    esac
    shift
  done

  local run_dir
  run_dir=$(cq_require_run "$run_id" "cq step-done <run_id> <step_id> pass|fail [result_json]")
  [[ "$outcome" == "pass" || "$outcome" == "fail" ]] || cq_die "Outcome must be 'pass' or 'fail'"

  # Handle parallel step completion with branch results
  if [[ -n "$branches_json" ]]; then
    local parallel_result
    parallel_result=$(cq_parallel_complete "$run_id" "$step_id" "$branches_json")
    outcome="$parallel_result"
    cq_log_event "$run_dir" "step_done" \
      "$(jq -cn --arg step "$step_id" --arg result "$outcome" --argjson branches "$branches_json" \
        '{step:$step, result:$result, type:"parallel", branches:$branches}')"
    local step gate
    step=$(cq_get_step "$run_id" "$step_id")
    gate=$(jq -r '.gate // "auto"' <<< "$step")
    local visits
    visits=$(jq --arg id "$step_id" '.[$id].visits // 1' "$(cq_run_dir "$run_id")/state.json")
    _handle_gate "$run_id" "$step_id" "$outcome" "$gate" "$visits"
  else
    cq_with_lock "$run_dir" _step_done_locked "$run_id" "$step_id" "$outcome" "$result_json" "$step_output" "$step_stderr"
  fi

  # Propagate to parent if this is a sub-workflow completing
  _propagate_to_parent "$run_id"

  if [[ "$CQ_JSON" == "true" ]]; then
    local meta
    meta=$(cq_read_meta "$run_id")
    jq -cn --arg step "$step_id" --arg outcome "$outcome" --argjson meta "$meta" \
      '{step:$step, outcome:$outcome, meta:$meta}'
  fi
}

# Propagate sub-workflow completion to parent run
_propagate_to_parent() {
  local child_run_id="$1"
  local meta
  meta=$(cq_read_meta "$child_run_id" 2>/dev/null) || return 0
  local status
  status=$(jq -r '.status' <<< "$meta")

  # Only propagate on terminal states
  case "$status" in
    completed|failed|cancelled) ;;
    *) return 0 ;;
  esac

  local parent_run_id parent_step_id
  parent_run_id=$(jq -r '.parent_run_id // empty' <<< "$meta")
  [[ -z "$parent_run_id" ]] && return 0
  parent_step_id=$(jq -r '.parent_step_id // empty' <<< "$meta")
  [[ -z "$parent_step_id" ]] && return 0

  # Verify parent exists
  cq_run_exists "$parent_run_id" || return 0

  # Copy outputs back
  local step
  step=$(cq_get_step "$parent_run_id" "$parent_step_id" 2>/dev/null) || return 0
  local outputs
  outputs=$(jq -r '.outputs // null' <<< "$step")
  cq_copy_outputs_back "$parent_run_id" "$child_run_id" "$parent_step_id" "$outputs"

  # Mark parent step as done
  local outcome="pass"
  [[ "$status" == "failed" || "$status" == "cancelled" ]] && outcome="fail"
  cmd_step_done "$parent_run_id" "$parent_step_id" "$outcome" 2>/dev/null || true
}

_step_done_locked() {
  local run_id="$1" step_id="$2" outcome="$3" result_json="$4"
  local step_output="${5:-}" step_stderr="${6:-}"
  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  local ts
  ts=$(cq_now)

  # Update step state
  local state step_state visits
  state=$(cq_read_state "$run_id")
  step_state=$(jq --arg id "$step_id" '.[$id]' <<< "$state")
  visits=$(jq '.visits // 0' <<< "$step_state")
  visits=$((visits + 1))

  local new_status
  [[ "$outcome" == "pass" ]] && new_status="passed" || new_status="failed"

  # Validate result_json
  if [[ "$result_json" != "null" ]]; then
    jq '.' <<< "$result_json" >/dev/null 2>&1 || result_json="null"
  fi

  state=$(jq \
    --arg id "$step_id" \
    --arg status "$new_status" \
    --argjson visits "$visits" \
    --arg result "$outcome" \
    --arg finished_at "$ts" \
    --argjson result_json "$result_json" \
    '.[$id].status = $status | .[$id].visits = $visits | .[$id].result = $result |
     .[$id].finished_at = $finished_at | .[$id].result_data = $result_json' <<< "$state")

  # Store output/stderr in state if provided
  if [[ -n "$step_output" ]]; then
    state=$(jq --arg id "$step_id" --arg out "$step_output" \
      '.[$id].output = $out' <<< "$state")
  fi
  if [[ -n "$step_stderr" ]]; then
    state=$(jq --arg id "$step_id" --arg err "$step_stderr" \
      '.[$id].error_output = $err' <<< "$state")
  fi

  cq_write_json "${run_dir}/state.json" "$state"

  # Log step completion (include file tracking and truncated output if available)
  local step_files
  step_files=$(jq --arg id "$step_id" '.[$id].files // []' <<< "$state")
  local log_output="${step_output:0:500}"
  cq_log_event "$run_dir" "step_done" \
    "$(jq -cn --arg step "$step_id" --arg result "$outcome" --argjson visits "$visits" --argjson files "$step_files" --arg output "$log_output" \
      '{step:$step, result:$result, visits:$visits, files:$files} + (if $output != "" then {output:$output} else {} end)')"

  # Load step definition once for outputs + gate handling
  local step
  step=$(cq_get_step "$run_id" "$step_id")

  # Extract outputs if step defines them
  _extract_outputs_from_step "$step" "$run_id" "$step_id" "$result_json"

  # Handle gate logic
  local gate
  gate=$(jq -r '.gate // "auto"' <<< "$step")

  _handle_gate "$run_id" "$step_id" "$outcome" "$gate" "$visits" "$step"
}

_extract_outputs_from_step() {
  local step="$1" run_id="$2" step_id="$3" result_json="$4"
  [[ "$result_json" == "null" ]] && return

  local outputs_type
  outputs_type=$(jq -r '.outputs | type' <<< "$step")

  # Build all output key-value pairs, then batch-write to context
  local -a ctx_updates=()

  if [[ "$outputs_type" == "object" ]]; then
    # outputs is a map of ctx_key -> jq_filter
    local keys
    keys=$(jq -r '.outputs | keys[]' <<< "$step")
    local key filter value
    while IFS= read -r key; do
      [[ -z "$key" ]] && continue
      filter=$(jq -r --arg k "$key" '.outputs[$k]' <<< "$step")
      value=$(jq -r "$filter" <<< "$result_json" 2>/dev/null || echo "")
      if [[ -n "$value" && "$value" != "null" ]]; then
        ctx_updates+=("$(jq -cn --arg k "$key" --arg v "$value" '{k:$k, v:$v}')")
      fi
    done <<< "$keys"
  elif [[ "$outputs_type" == "array" ]]; then
    # outputs is a list of keys to extract from result (top-level)
    local key value
    for key in $(jq -r '.outputs[]' <<< "$step"); do
      value=$(jq -r --arg k "$key" '.[$k] // empty' <<< "$result_json" 2>/dev/null)
      if [[ -n "$value" ]]; then
        ctx_updates+=("$(jq -cn --arg k "$key" --arg v "$value" '{k:$k, v:$v}')")
      fi
    done
  fi

  # Batch-write all context updates in a single locked operation
  if [[ ${#ctx_updates[@]} -gt 0 ]]; then
    local updates_json
    updates_json=$(printf '%s\n' "${ctx_updates[@]}" | jq -s '.')
    local run_dir
    run_dir=$(cq_run_dir "$run_id")
    cq_with_lock "$run_dir" _cq_batch_ctx_set_locked "$run_dir" "$updates_json"
  fi
}

_handle_gate() {
  local run_id="$1" step_id="$2" outcome="$3" gate="$4" visits="$5" step="${6:-}"
  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  case "$gate" in
    auto)
      _advance_run "$run_id" "$step_id" "$outcome"
      ;;
    human)
      if [[ "$CQ_HEADLESS" == "true" ]]; then
        _advance_run "$run_id" "$step_id" "pass"
      else
        local desc
        if [[ -n "$step" ]]; then
          desc=$(jq -r '.description // .name // .id' <<< "$step")
        else
          desc=$(cq_get_step "$run_id" "$step_id" | jq -r '.description // .name // .id')
        fi
        cq_create_todo "$run_id" "$step_id" "review" "$desc"
        cq_update_meta "$run_id" '.status = "gated"'
        cq_log_event "$run_dir" "gate_human" \
          "$(jq -cn --arg step "$step_id" '{step:$step}')"
        cq_update_active_runs_index
        cq_info "$(cq_marker "gated") Waiting for human approval at step '${step_id}'"
        cq_hint "Workflow gated at step '${step_id}'. Use AskUserQuestion to prompt the user for approval."
      fi
      ;;
    review)
      if [[ "$outcome" == "pass" ]]; then
        _advance_run "$run_id" "$step_id" "pass"
      else
        _handle_review_failure "$run_id" "$step_id" "$visits" "$step"
      fi
      ;;
    *)
      _advance_run "$run_id" "$step_id" "$outcome"
      ;;
  esac
}

_handle_review_failure() {
  local run_id="$1" step_id="$2" visits="$3" step="${4:-}"
  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  local max_visits
  if [[ -z "$step" ]]; then
    step=$(cq_get_step "$run_id" "$step_id")
  fi
  max_visits=$(jq -r '.max_visits // 0' <<< "$step")
  max_visits=${max_visits:-0}

  if [[ "$max_visits" -gt 0 && "$visits" -ge "$max_visits" ]]; then
    if [[ "$CQ_HEADLESS" == "true" ]]; then
      cq_update_meta "$run_id" '.status = "failed"'
      cq_update_active_runs_index
      cq_log_event "$run_dir" "run_failed" \
        "$(jq -cn --arg step "$step_id" '{step:$step, reason:"max_visits_exceeded_headless"}')"
      cq_fire_hook "on_fail" "$run_dir"
    else
      local desc="Max visits (${max_visits}) reached for step '${step_id}'"
      cq_create_todo "$run_id" "$step_id" "override" "$desc"
      cq_update_meta "$run_id" '.status = "gated"'
      cq_log_event "$run_dir" "gate_review_escalated" \
        "$(jq -cn --arg step "$step_id" --argjson visits "$visits" --argjson max "$max_visits" \
          '{step:$step, visits:$visits, max_visits:$max}')"
      cq_info "$(cq_marker "gated") Step '${step_id}' exceeded max visits — escalated to human"
      cq_hint "Step exceeded max visits. Use AskUserQuestion to ask user: override or reject?"
    fi
  else
    _advance_run "$run_id" "$step_id" "fail"
  fi
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
    cq_update_active_runs_index
    cq_info "$(cq_marker "passed") Workflow completed (run ${run_id})"
    cq_hint "Workflow completed. Update the workflow Task to completed via TaskUpdate."
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
    state=$(jq --arg id "$next_step" --arg ts "$ts" \
      '.[$id].status = "running" | .[$id].started_at = $ts | .[$id].attempt = ((.[$id].attempt // 0) + 1)' <<< "$state")
    cq_write_json "${run_dir}/state.json" "$state"

    cq_log_event "$run_dir" "step_started" \
      "$(jq -cn --arg step "$next_step" '{step:$step}')"
    cq_hint "Next step: '${next_step}'. Read status and dispatch."
  fi
}

cmd_skip() {
  local run_id="${1:?Usage: cq skip <run_id> [step_id]}"
  local step_id="${2:-}"

  local run_dir
  run_dir=$(cq_require_run "$run_id" "cq skip <run_id> [step_id]")

  # Default to current step
  if [[ -z "$step_id" ]]; then
    step_id=$(jq -r '.current_step' "${run_dir}/meta.json")
  fi
  [[ -z "$step_id" || "$step_id" == "null" ]] && cq_die "No current step to skip"

  cq_with_lock "$run_dir" _skip_locked "$run_id" "$step_id"

  if [[ "$CQ_JSON" == "true" ]]; then
    local meta
    meta=$(cq_read_meta "$run_id")
    jq -cn --arg step "$step_id" --argjson meta "$meta" '{skipped:$step, meta:$meta}'
  else
    cq_info "$(cq_marker "skipped") Skipped step '${step_id}'"
  fi
}

_skip_locked() {
  local run_id="$1" step_id="$2"
  local run_dir
  run_dir=$(cq_run_dir "$run_id")
  local ts
  ts=$(cq_now)

  # Mark step as skipped
  local state
  state=$(cq_read_state "$run_id")
  state=$(jq --arg id "$step_id" --arg ts "$ts" \
    '.[$id].status = "skipped" | .[$id].finished_at = $ts' <<< "$state")
  cq_write_json "${run_dir}/state.json" "$state"

  cq_log_event "$run_dir" "step_skipped" \
    "$(jq -cn --arg step "$step_id" '{step:$step}')"

  # Advance as if passed
  _advance_run "$run_id" "$step_id" "pass"
}
