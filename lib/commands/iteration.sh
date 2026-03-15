#!/usr/bin/env bash
# iteration.sh — for-each, parallel, batch CLI commands

# --- for-each ---

cmd_for_each() {
  local run_id="" step_id="" over="" delimiter="," var="item" command=""

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --over=*)      over="${1#*=}" ;;
      --delimiter=*) delimiter="${1#*=}" ;;
      --var=*)       var="${1#*=}" ;;
      --command=*)   command="${1#*=}" ;;
      *)
        if [[ -z "$run_id" ]]; then
          run_id="$1"
        elif [[ -z "$step_id" ]]; then
          step_id="$1"
        fi
        ;;
    esac
    shift
  done

  if [[ -n "$run_id" && -n "$step_id" ]]; then
    _for_each_workflow "$run_id" "$step_id"
  elif [[ -n "$over" && -n "$command" ]]; then
    _for_each_standalone "$over" "$delimiter" "$var" "$command"
  else
    cq_die "Usage: cq for-each --over=<list> --var=<name> --command=<cmd>\n       cq for-each <run_id> <step_id>"
  fi
}

_for_each_standalone() {
  local over="$1" delimiter="$2" var="$3" command="$4"

  # Split over by delimiter
  local -a items=()
  IFS="$delimiter" read -ra items <<< "$over"

  local -a results=()
  local all_pass=true
  local i=0

  for item in "${items[@]}"; do
    item=$(cq_trim "$item")
    [[ -z "$item" ]] && continue

    # Interpolate command with item variable
    local ctx_json
    ctx_json=$(jq -cn --arg k "$var" --arg v "$item" '{($k): $v}')
    local interpolated
    interpolated=$(cq_interpolate "$command" "$ctx_json")

    # Execute
    local output exit_code
    output=$(bash -c "$interpolated" 2>&1) && exit_code=0 || exit_code=$?

    local outcome="pass"
    [[ $exit_code -ne 0 ]] && { outcome="fail"; all_pass=false; }

    results+=("$(jq -cn --arg item "$item" --arg outcome "$outcome" --argjson idx "$i" --arg output "$output" \
      '{index:$idx, item:$item, outcome:$outcome, output:$output}')")

    i=$((i + 1))

    if [[ "$outcome" == "fail" ]]; then
      break
    fi
  done

  local results_json
  if [[ ${#results[@]} -gt 0 ]]; then
    results_json=$(printf '%s\n' "${results[@]}" | jq -s '.')
  else
    results_json="[]"
  fi

  if [[ "$CQ_JSON" == "true" ]]; then
    local outcome_str="pass"
    $all_pass || outcome_str="fail"
    jq -cn --arg outcome "$outcome_str" --argjson results "$results_json" \
      '{outcome:$outcome, results:$results}'
  else
    for item in "${items[@]}"; do
      item=$(cq_trim "$item")
      [[ -z "$item" ]] && continue
      cq_info "  ${item}"
    done
  fi

  $all_pass
}

_for_each_workflow() {
  local run_id="$1" step_id="$2"
  local run_dir
  run_dir=$(cq_require_run "$run_id" "cq for-each <run_id> <step_id>")

  local step
  step=$(cq_get_step "$run_id" "$step_id")
  local ctx_json
  ctx_json=$(cq_read_ctx "$run_id")

  # Read for_each fields from step definition
  local over delimiter item_var max_iterations sub_step
  over=$(jq -r '.over // ""' <<< "$step")
  delimiter=$(jq -r '.delimiter // ","' <<< "$step")
  item_var=$(jq -r '.item_var // "item"' <<< "$step")
  max_iterations=$(jq -r '.max_iterations // 100' <<< "$step")
  sub_step=$(jq -c '.step // null' <<< "$step")

  # Interpolate the 'over' value
  over=$(cq_interpolate "$over" "$ctx_json")

  [[ -z "$over" ]] && cq_die "for-each: 'over' is empty after interpolation"
  [[ "$sub_step" == "null" ]] && cq_die "for-each: no 'step' definition found"

  local sub_type
  sub_type=$(jq -r '.type // "bash"' <<< "$sub_step")

  # Split by delimiter
  local -a items=()
  IFS="$delimiter" read -ra items <<< "$over"

  local -a results=()
  local all_pass=true
  local i=0

  for item in "${items[@]}"; do
    item=$(cq_trim "$item")
    [[ -z "$item" ]] && continue
    [[ $i -ge $max_iterations ]] && break

    # Set context variable
    cq_ctx_set "$run_id" "$item_var" "$item"
    # Re-read context after update
    ctx_json=$(cq_read_ctx "$run_id")

    local outcome="pass" output=""
    case "$sub_type" in
      bash)
        local target
        target=$(jq -r '.target // ""' <<< "$sub_step")
        target=$(cq_interpolate "$target" "$ctx_json")
        output=$(bash -c "$target" 2>&1) && true || { outcome="fail"; all_pass=false; }
        ;;
      *)
        # Non-bash sub-steps (agent, skill) can't be executed by CLI — record as pending
        outcome="pending"
        ;;
    esac

    results+=("$(jq -cn --arg item "$item" --arg outcome "$outcome" --argjson idx "$i" --arg output "$output" \
      '{index:$idx, item:$item, outcome:$outcome, output:$output}')")
    i=$((i + 1))

    if [[ "$outcome" == "fail" ]]; then
      local on_fail
      on_fail=$(jq -r '.on_fail // empty' <<< "$step")
      [[ -z "$on_fail" ]] && break
    fi
  done

  local results_json
  if [[ ${#results[@]} -gt 0 ]]; then
    results_json=$(printf '%s\n' "${results[@]}" | jq -s '.')
  else
    results_json="[]"
  fi

  local outcome_str="pass"
  $all_pass || outcome_str="fail"

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg outcome "$outcome_str" --argjson results "$results_json" \
      --arg run_id "$run_id" --arg step_id "$step_id" \
      '{run_id:$run_id, step_id:$step_id, outcome:$outcome, results:$results}'
  else
    cq_info "for-each: ${i} iteration(s), outcome: ${outcome_str}"
  fi

  $all_pass
}

# --- parallel ---

cmd_parallel() {
  local run_id="" step_id="" steps_json="" fail_strategy="wait_all"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --steps=*)         steps_json="${1#*=}" ;;
      --fail-strategy=*) fail_strategy="${1#*=}" ;;
      *)
        if [[ -z "$run_id" ]]; then
          run_id="$1"
        elif [[ -z "$step_id" ]]; then
          step_id="$1"
        fi
        ;;
    esac
    shift
  done

  if [[ -n "$run_id" && -n "$step_id" ]]; then
    _parallel_workflow "$run_id" "$step_id"
  elif [[ -n "$steps_json" ]]; then
    _parallel_standalone "$steps_json" "$fail_strategy"
  else
    cq_die "Usage: cq parallel --steps=<json_array> [--fail-strategy=wait_all|fail_fast]\n       cq parallel <run_id> <step_id>"
  fi
}

_parallel_standalone() {
  local steps_json="$1" fail_strategy="$2"

  # Validate JSON
  jq '.' <<< "$steps_json" >/dev/null 2>&1 || cq_die "parallel: invalid JSON in --steps"

  local step_count
  step_count=$(jq 'length' <<< "$steps_json")
  [[ "$step_count" -eq 0 ]] && cq_die "parallel: --steps array is empty"

  local -a pids=() outputs=() exit_codes=()
  local i

  # Launch each bash step in background
  for ((i = 0; i < step_count; i++)); do
    local sub_step target
    sub_step=$(jq --argjson i "$i" '.[$i]' <<< "$steps_json")
    target=$(jq -r '.target // ""' <<< "$sub_step")

    if [[ -z "$target" ]]; then
      outputs+=("")
      exit_codes+=(1)
      pids+=(0)
      continue
    fi

    # Run in background, capture output to temp file
    local tmpfile
    tmpfile=$(mktemp)
    (bash -c "$target" > "$tmpfile" 2>&1) &
    pids+=($!)
    outputs+=("$tmpfile")
    exit_codes+=(0)
  done

  # Wait for all
  local all_pass=true
  local -a results=()
  for ((i = 0; i < step_count; i++)); do
    local sub_step_id outcome output_content
    sub_step_id=$(jq -r --argjson i "$i" '.[$i].id // "step-\($i)"' <<< "$steps_json")

    if [[ "${pids[$i]}" -ne 0 ]]; then
      wait "${pids[$i]}" && true || exit_codes[$i]=$?
      output_content=$(cat "${outputs[$i]}" 2>/dev/null)
      rm -f "${outputs[$i]}"
    else
      output_content=""
    fi

    local outcome="pass"
    [[ "${exit_codes[$i]}" -ne 0 ]] && { outcome="fail"; all_pass=false; }

    results+=("$(jq -cn --arg id "$sub_step_id" --arg outcome "$outcome" --arg output "$output_content" \
      '{id:$id, outcome:$outcome, output:$output}')")
  done

  local results_json
  results_json=$(printf '%s\n' "${results[@]}" | jq -s '.')

  local outcome_str="pass"
  $all_pass || outcome_str="fail"

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg outcome "$outcome_str" --argjson results "$results_json" \
      '{outcome:$outcome, results:$results}'
  else
    for ((i = 0; i < step_count; i++)); do
      local sub_id sub_outcome
      sub_id=$(jq -r --argjson i "$i" '.[$i].id // "step-\($i)"' <<< "$steps_json")
      sub_outcome=$(jq -r --argjson i "$i" '.[$i].outcome' <<< "$results_json")
      local marker
      marker=$(cq_marker "$sub_outcome")
      cq_info "  ${marker} ${sub_id}: ${sub_outcome}"
    done
  fi

  $all_pass
}

_parallel_workflow() {
  local run_id="$1" step_id="$2"
  local run_dir
  run_dir=$(cq_require_run "$run_id" "cq parallel <run_id> <step_id>")

  local step
  step=$(cq_get_step "$run_id" "$step_id")
  local ctx_json
  ctx_json=$(cq_read_ctx "$run_id")

  local sub_steps fail_strategy
  sub_steps=$(jq -c '.steps // []' <<< "$step")
  fail_strategy=$(jq -r '.fail_strategy // "wait_all"' <<< "$step")

  local step_count
  step_count=$(jq 'length' <<< "$sub_steps")
  [[ "$step_count" -eq 0 ]] && cq_die "parallel: no child steps defined"

  local -a pids=() tmpfiles=() exit_codes=()
  local i

  # Launch bash sub-steps concurrently
  for ((i = 0; i < step_count; i++)); do
    local sub_step sub_type target
    sub_step=$(jq --argjson i "$i" '.[$i]' <<< "$sub_steps")
    sub_type=$(jq -r '.type // "bash"' <<< "$sub_step")

    if [[ "$sub_type" == "bash" ]]; then
      target=$(jq -r '.target // ""' <<< "$sub_step")
      target=$(cq_interpolate "$target" "$ctx_json")
      local tmpfile
      tmpfile=$(mktemp)
      (bash -c "$target" > "$tmpfile" 2>&1) &
      pids+=($!)
      tmpfiles+=("$tmpfile")
      exit_codes+=(0)
    else
      # Non-bash sub-steps can't run in CLI — mark pending for SKILL.md runner
      pids+=(0)
      tmpfiles+=("")
      exit_codes+=(0)
    fi
  done

  # Wait for all background jobs
  local all_pass=true
  local -a results=()
  for ((i = 0; i < step_count; i++)); do
    local sub_id outcome output_content=""
    sub_id=$(jq -r --argjson i "$i" '.[$i].id // "child-\($i)"' <<< "$sub_steps")

    if [[ "${pids[$i]}" -ne 0 ]]; then
      wait "${pids[$i]}" && true || exit_codes[$i]=$?
      output_content=$(cat "${tmpfiles[$i]}" 2>/dev/null)
      rm -f "${tmpfiles[$i]}"
    fi

    outcome="pass"
    [[ "${exit_codes[$i]}" -ne 0 ]] && { outcome="fail"; all_pass=false; }

    results+=("$(jq -cn --arg id "$sub_id" --arg outcome "$outcome" --arg output "$output_content" \
      '{id:$id, outcome:$outcome, output:$output}')")
  done

  local results_json
  results_json=$(printf '%s\n' "${results[@]}" | jq -s '.')

  local outcome_str="pass"
  $all_pass || outcome_str="fail"

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg outcome "$outcome_str" --argjson results "$results_json" \
      --arg run_id "$run_id" --arg step_id "$step_id" \
      '{run_id:$run_id, step_id:$step_id, outcome:$outcome, results:$results}'
  else
    cq_info "parallel: ${step_count} child step(s), outcome: ${outcome_str}"
  fi

  $all_pass
}

# --- batch ---

cmd_batch() {
  local run_id="" step_id="" workflow="" jobs_json=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workflow=*) workflow="${1#*=}" ;;
      --jobs=*)     jobs_json="${1#*=}" ;;
      *)
        if [[ -z "$run_id" ]]; then
          run_id="$1"
        elif [[ -z "$step_id" ]]; then
          step_id="$1"
        fi
        ;;
    esac
    shift
  done

  if [[ -n "$run_id" && -n "$step_id" ]]; then
    _batch_workflow "$run_id" "$step_id"
  elif [[ -n "$workflow" && -n "$jobs_json" ]]; then
    _batch_standalone "$workflow" "$jobs_json"
  else
    cq_die "Usage: cq batch --workflow=<name> --jobs=<json_array>\n       cq batch <run_id> <step_id>"
  fi
}

_batch_standalone() {
  local workflow="$1" jobs_json="$2"

  # Validate JSON
  jq '.' <<< "$jobs_json" >/dev/null 2>&1 || cq_die "batch: invalid JSON in --jobs"

  # Create worker session
  local session_json
  session_json=$(CQ_JSON=true cmd_workers init 2>/dev/null)
  local session_id
  session_id=$(jq -r '.session_id' <<< "$session_json")

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg session_id "$session_id" --arg workflow "$workflow" --argjson jobs "$jobs_json" \
      '{session_id:$session_id, workflow:$workflow, jobs:$jobs, status:"created"}'
  else
    local job_count
    job_count=$(jq 'length' <<< "$jobs_json")
    cq_info "Batch session ${session_id}: ${job_count} job(s) for workflow '${workflow}'"
    cq_info "Use /cq-workers to spawn worker agents"
  fi
}

_batch_workflow() {
  local run_id="$1" step_id="$2"
  local run_dir
  run_dir=$(cq_require_run "$run_id" "cq batch <run_id> <step_id>")

  local step
  step=$(cq_get_step "$run_id" "$step_id")
  local ctx_json
  ctx_json=$(cq_read_ctx "$run_id")

  # Read batch fields
  local jobs_from max_workers
  jobs_from=$(jq -r '.jobs_from // ""' <<< "$step")
  max_workers=$(jq -r '.max_workers // 5' <<< "$step")

  # Resolve jobs_from — it's either a context key or an inline JSON array
  local jobs_json
  if [[ -n "$jobs_from" ]]; then
    jobs_from=$(cq_interpolate "$jobs_from" "$ctx_json")
    # Try as context key first
    local ctx_val
    ctx_val=$(jq -r --arg k "$jobs_from" '.[$k] // empty' <<< "$ctx_json" 2>/dev/null)
    if [[ -n "$ctx_val" ]]; then
      jobs_json="$ctx_val"
    else
      jobs_json="$jobs_from"
    fi
  else
    jobs_json="[]"
  fi

  # Create worker session
  local session_json
  session_json=$(CQ_JSON=true cmd_workers init 2>/dev/null)
  local session_id
  session_id=$(jq -r '.session_id' <<< "$session_json")

  # Store session_id in step state
  cq_ctx_set "$run_id" "_batch_session_${step_id}" "$session_id"

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg session_id "$session_id" --arg run_id "$run_id" --arg step_id "$step_id" \
      --argjson max_workers "$max_workers" \
      '{run_id:$run_id, step_id:$step_id, session_id:$session_id, max_workers:$max_workers, status:"created"}'
  else
    cq_info "batch: session ${session_id} created for step '${step_id}'"
  fi
}
