#!/usr/bin/env bash
# steps.sh — Step control: step-done, skip, gate handling, output extraction, advance

cmd_step_done() {
  local run_id="${1:?Usage: cq step-done <run_id> <step_id> pass|fail [result_json]}"
  local step_id="${2:?Usage: cq step-done <run_id> <step_id> pass|fail}"
  local outcome="${3:?Usage: cq step-done <run_id> <step_id> pass|fail}"
  local result_json="${4:-null}"

  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"
  [[ "$outcome" == "pass" || "$outcome" == "fail" ]] || cq_die "Outcome must be 'pass' or 'fail'"

  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  cq_with_lock "$run_dir" _step_done_locked "$run_id" "$step_id" "$outcome" "$result_json"

  if [[ "$CQ_JSON" == "true" ]]; then
    local meta
    meta=$(cq_read_meta "$run_id")
    jq -cn --arg step "$step_id" --arg outcome "$outcome" --argjson meta "$meta" \
      '{step:$step, outcome:$outcome, meta:$meta}'
  fi
}

_step_done_locked() {
  local run_id="$1" step_id="$2" outcome="$3" result_json="$4"
  local run_dir
  run_dir=$(cq_run_dir "$run_id")

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

  cq_with_lock "$run_dir" _skip_locked "$run_id" "$step_id"

  cq_info "$(cq_marker "skipped") Skipped step '${step_id}'"

  if [[ "$CQ_JSON" == "true" ]]; then
    local meta
    meta=$(cq_read_meta "$run_id")
    jq -cn --arg step "$step_id" --argjson meta "$meta" '{skipped:$step, meta:$meta}'
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
  state=$(echo "$state" | jq --arg id "$step_id" --arg ts "$ts" \
    '.[$id].status = "skipped" | .[$id].finished_at = $ts')
  cq_write_json "${run_dir}/state.json" "$state"

  cq_log_event "$run_dir" "step_skipped" \
    "$(jq -cn --arg step "$step_id" '{step:$step}')"

  # Advance as if passed
  _advance_run "$run_id" "$step_id" "pass"
}
