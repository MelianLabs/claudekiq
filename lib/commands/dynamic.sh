#!/usr/bin/env bash
# dynamic.sh — Dynamic modification: add-step, add-steps, set-next

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

  cq_with_lock "$run_dir" _add_step_locked "$run_id" "$step_json" "$new_step_id" "$after_step"

  cq_info "Added step '${new_step_id}'"
  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg id "$new_step_id" --arg run_id "$run_id" '{step_id:$id, run_id:$run_id}'
  fi
}

_add_step_locked() {
  local run_id="$1" step_json="$2" new_step_id="$3" after_step="$4"
  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  local steps
  steps=$(cq_read_steps "$run_id")

  if [[ -n "$after_step" ]]; then
    # Insert after the specified step
    local index
    index=$(echo "$steps" | jq --arg id "$after_step" '[.[] | .id] | to_entries[] | select(.value == $id) | .key')
    [[ -z "$index" ]] && cq_die "Step not found: ${after_step}"
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

  cq_with_lock "$run_dir" _add_steps_locked "$run_id" "$sub_steps" "$after_step" "$flow_template"

  local added_count
  added_count=$(echo "$sub_steps" | jq 'length')
  cq_info "Added ${added_count} steps from '${flow_template}'"

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg flow "$flow_template" --argjson count "$added_count" --arg run_id "$run_id" \
      '{flow:$flow, steps_added:$count, run_id:$run_id}'
  fi
}

_add_steps_locked() {
  local run_id="$1" sub_steps="$2" after_step="$3" flow_template="$4"
  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  local steps
  steps=$(cq_read_steps "$run_id")

  if [[ -n "$after_step" ]]; then
    local index
    index=$(echo "$steps" | jq --arg id "$after_step" '[.[] | .id] | to_entries[] | select(.value == $id) | .key')
    [[ -z "$index" ]] && cq_die "Step not found: ${after_step}"
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
}

cmd_set_next() {
  local run_id="${1:?Usage: cq set-next <run_id> <step_id> <target>}"
  local step_id="${2:?Usage: cq set-next <run_id> <step_id> <target>}"
  local target="${3:?Usage: cq set-next <run_id> <step_id> <target>}"

  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"

  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  cq_with_lock "$run_dir" _set_next_locked "$run_id" "$step_id" "$target"

  cq_info "Set next for '${step_id}' → '${target}'"

  if [[ "$CQ_JSON" == "true" ]]; then
    jq -cn --arg step "$step_id" --arg target "$target" --arg run_id "$run_id" \
      '{step_id:$step, target:$target, run_id:$run_id}'
  fi
}

_set_next_locked() {
  local run_id="$1" step_id="$2" target="$3"
  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  local steps
  steps=$(cq_read_steps "$run_id")
  steps=$(echo "$steps" | jq --arg id "$step_id" --arg target "$target" \
    '[.[] | if .id == $id then .next = $target else . end]')
  cq_write_steps "$run_id" "$steps"

  cq_log_event "$run_dir" "set_next" \
    "$(jq -cn --arg step "$step_id" --arg target "$target" '{step:$step, target:$target}')"
}
