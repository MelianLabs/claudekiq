#!/usr/bin/env bash
# storage.sh — Filesystem I/O for runs, steps, state, context

# --- Run directory ---

cq_run_dir() {
  local run_id="$1"
  echo "${CQ_PROJECT_ROOT}/.claudekiq/runs/${run_id}"
}

cq_run_exists() {
  local run_id="$1"
  [[ -d "$(cq_run_dir "$run_id")" ]]
}

# --- Generic JSON I/O ---

cq_read_json() {
  local file="$1"
  [[ -f "$file" ]] || cq_die "File not found: ${file}"
  cat "$file"
}

cq_write_json() {
  local file="$1"
  local data="$2"
  jq '.' <<< "$data" > "$file" 2>/dev/null || cq_die "Failed to write JSON: ${file}"
}

# --- Meta ---

cq_read_meta() {
  local run_id="$1"
  cq_read_json "$(cq_run_dir "$run_id")/meta.json"
}

cq_update_meta() {
  local run_id="$1"
  local filter="$2"
  shift 2
  local run_dir
  run_dir=$(cq_run_dir "$run_id")
  local meta
  meta=$(cq_read_json "${run_dir}/meta.json")
  local ts
  ts=$(cq_now)
  # Apply jq filter with optional --arg pairs
  meta=$(jq --arg updated_at "$ts" "$@" "(${filter}) | .updated_at = \$updated_at" <<< "$meta")
  cq_write_json "${run_dir}/meta.json" "$meta"
}

# --- Context ---

cq_read_ctx() {
  local run_id="$1"
  cq_read_json "$(cq_run_dir "$run_id")/ctx.json"
}

cq_ctx_get() {
  local run_id="$1" key="$2"
  local ctx
  ctx=$(cq_read_ctx "$run_id")
  jq -r --arg k "$key" '.[$k] // empty' <<< "$ctx"
}

cq_ctx_set() {
  local run_id="$1" key="$2" value="$3"
  local run_dir
  run_dir=$(cq_run_dir "$run_id")
  cq_with_lock "$run_dir" _cq_ctx_set_locked "$run_dir" "$key" "$value"
}

_cq_ctx_set_locked() {
  local run_dir="$1" key="$2" value="$3"
  local ctx
  ctx=$(cq_read_json "${run_dir}/ctx.json")
  ctx=$(jq --arg k "$key" --arg v "$value" '.[$k] = $v' <<< "$ctx")
  cq_write_json "${run_dir}/ctx.json" "$ctx"
}

# Batch-set multiple context keys in a single locked write.
# updates_json: array of {k: "key", v: "value"} objects
_cq_batch_ctx_set_locked() {
  local run_dir="$1" updates_json="$2"
  local ctx
  ctx=$(cq_read_json "${run_dir}/ctx.json")
  ctx=$(jq --argjson updates "$updates_json" '
    reduce ($updates[]) as $u (.; .[$u.k] = $u.v)
  ' <<< "$ctx")
  cq_write_json "${run_dir}/ctx.json" "$ctx"
}

# --- Steps ---

cq_read_steps() {
  local run_id="$1"
  cq_read_json "$(cq_run_dir "$run_id")/steps.json"
}

cq_write_steps() {
  local run_id="$1" data="$2"
  cq_write_json "$(cq_run_dir "$run_id")/steps.json" "$data"
}

cq_get_step() {
  local run_id="$1" step_id="$2"
  local steps
  steps=$(cq_read_steps "$run_id")
  jq --arg id "$step_id" '.[] | select(.id == $id)' <<< "$steps"
}

cq_step_index() {
  local run_id="$1" step_id="$2"
  local steps
  steps=$(cq_read_steps "$run_id")
  jq --arg id "$step_id" 'to_entries[] | select(.value.id == $id) | .key' <<< "$steps"
}

cq_step_count() {
  local run_id="$1"
  local steps
  steps=$(cq_read_steps "$run_id")
  jq 'length' <<< "$steps"
}

cq_step_at_index() {
  local run_id="$1" index="$2"
  local steps
  steps=$(cq_read_steps "$run_id")
  jq --argjson i "$index" '.[$i]' <<< "$steps"
}

cq_step_ids() {
  local run_id="$1"
  local steps
  steps=$(cq_read_steps "$run_id")
  jq -r '.[].id' <<< "$steps"
}

# --- State ---

cq_read_state() {
  local run_id="$1"
  cq_read_json "$(cq_run_dir "$run_id")/state.json"
}

cq_step_state_get() {
  local run_id="$1" step_id="$2"
  local state
  state=$(cq_read_state "$run_id")
  jq --arg id "$step_id" '.[$id]' <<< "$state"
}

cq_step_state_set() {
  local run_id="$1" step_id="$2" filter="$3"
  shift 3
  local run_dir
  run_dir=$(cq_run_dir "$run_id")
  local state
  state=$(cq_read_json "${run_dir}/state.json")
  state=$(jq --arg id "$step_id" "$@" '.[$id] |= ('"$filter"')' <<< "$state")
  cq_write_json "${run_dir}/state.json" "$state"
}

# Initialize state for a step
cq_init_step_state() {
  local run_id="$1" step_id="$2"
  local run_dir
  run_dir=$(cq_run_dir "$run_id")
  local state
  state=$(cq_read_json "${run_dir}/state.json")
  state=$(jq --arg id "$step_id" \
    '.[$id] = {"status":"pending","visits":0,"attempt":0,"result":null,"started_at":null,"finished_at":null,"files":[]}' <<< "$state")
  cq_write_json "${run_dir}/state.json" "$state"
}

# --- Parallel step state ---

# Initialize branch state for a parallel step
cq_parallel_init_state() {
  local run_id="$1" step_id="$2" branches_json="$3"
  local run_dir
  run_dir=$(cq_run_dir "$run_id")
  local state
  state=$(cq_read_json "${run_dir}/state.json")

  # Build branches state from branches definition array
  local branches_state
  branches_state=$(jq '[.[] | {key: .id, value: {"status":"pending","result":null}}] | from_entries' <<< "$branches_json")

  state=$(jq --arg id "$step_id" --argjson branches "$branches_state" \
    '.[$id].branches = $branches' <<< "$state")
  cq_write_json "${run_dir}/state.json" "$state"
}

# Bulk-update all branches from results (called after /batch completes)
# results_json: {"branch_id": {"status": "passed"|"failed", "result": "pass"|"fail"}, ...}
cq_parallel_complete() {
  local run_id="$1" step_id="$2" results_json="$3"
  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  cq_with_lock "$run_dir" _cq_parallel_complete_locked "$run_dir" "$step_id" "$results_json"
}

_cq_parallel_complete_locked() {
  local run_dir="$1" step_id="$2" results_json="$3"
  local state
  state=$(cq_read_json "${run_dir}/state.json")
  local ts
  ts=$(cq_now)

  # Update each branch from results
  state=$(jq --arg id "$step_id" --argjson results "$results_json" --arg ts "$ts" '
    .[$id].branches = (.[$id].branches // {} |
      reduce ($results | to_entries[]) as $r (
        .; .[$r.key] = (.[$r.key] // {}) + $r.value
      )
    )
  ' <<< "$state")

  # Determine overall outcome: pass only if ALL branches passed
  local all_passed
  all_passed=$(jq --arg id "$step_id" '
    [.[$id].branches | to_entries[] | .value.result] | all(. == "pass")
  ' <<< "$state")

  local overall_result="fail"
  local overall_status="failed"
  if [[ "$all_passed" == "true" ]]; then
    overall_result="pass"
    overall_status="passed"
  fi

  state=$(jq --arg id "$step_id" --arg status "$overall_status" --arg result "$overall_result" --arg ts "$ts" '
    .[$id].status = $status | .[$id].result = $result | .[$id].finished_at = $ts |
    .[$id].visits = ((.[$id].visits // 0) + 1)
  ' <<< "$state")

  cq_write_json "${run_dir}/state.json" "$state"
  echo "$overall_result"
}

# --- Sub-workflow linkage ---

# Get child run IDs for a parent run
cq_child_run_ids() {
  local parent_run_id="$1"
  local meta
  meta=$(cq_read_meta "$parent_run_id" 2>/dev/null) || return 0
  jq -r '.children // [] | .[].run_id' <<< "$meta"
}

# Get parent run info for a child run
# Returns JSON: {"parent_run_id": "...", "parent_step_id": "..."}
cq_parent_run() {
  local child_run_id="$1"
  local meta
  meta=$(cq_read_meta "$child_run_id" 2>/dev/null) || return 1
  local parent_run_id
  parent_run_id=$(jq -r '.parent_run_id // empty' <<< "$meta")
  [[ -z "$parent_run_id" ]] && return 1
  jq -c '{parent_run_id: .parent_run_id, parent_step_id: .parent_step_id}' <<< "$meta"
}

# Copy context from parent to child using context_map
cq_copy_context_map() {
  local parent_run_id="$1" child_run_id="$2" context_map_json="$3"
  local parent_ctx
  parent_ctx=$(cq_read_ctx "$parent_run_id")

  # Resolve each mapping: key -> expression (may contain {{}} interpolation)
  local child_ctx="{}"
  local key value resolved
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    value=$(jq -r --arg k "$key" '.[$k]' <<< "$context_map_json")
    resolved=$(cq_interpolate "$value" "$parent_ctx")
    child_ctx=$(jq --arg k "$key" --arg v "$resolved" '.[$k] = $v' <<< "$child_ctx")
  done <<< "$(jq -r 'keys[]' <<< "$context_map_json")"

  local child_run_dir
  child_run_dir=$(cq_run_dir "$child_run_id")
  cq_write_json "${child_run_dir}/ctx.json" "$child_ctx"
}

# Copy outputs from child back to parent context under namespace
# Batches all context updates into a single locked write.
cq_copy_outputs_back() {
  local parent_run_id="$1" child_run_id="$2" step_id="$3" outputs_json="$4"
  local child_ctx
  child_ctx=$(cq_read_ctx "$child_run_id")
  local parent_run_dir
  parent_run_dir=$(cq_run_dir "$parent_run_id")

  # Build updates as a single JSON object, then batch-write
  local updates
  if [[ "$outputs_json" != "null" && "$outputs_json" != "{}" && -n "$outputs_json" ]]; then
    # Explicit output mapping: {parent_key: child_key}
    updates=$(jq --arg prefix "sub_${step_id}" --argjson mapping "$outputs_json" '
      . as $ctx | $mapping | to_entries | map(
        {key: ($prefix + "." + .key), value: ($ctx[.value] // null)}
      ) | map(select(.value != null)) | from_entries
    ' <<< "$child_ctx")
  else
    # No explicit mapping: copy entire child context under sub_<step_id> (skip _internal keys)
    updates=$(jq --arg prefix "sub_${step_id}" '
      to_entries | map(select(.key | startswith("_") | not)) |
      map({key: ($prefix + "." + .key), value: .value}) |
      map(select(.value != null and .value != "")) | from_entries
    ' <<< "$child_ctx")
  fi

  # Merge updates into parent context in a single locked write
  if [[ -n "$updates" && "$updates" != "{}" ]]; then
    cq_with_lock "$parent_run_dir" _cq_merge_ctx_locked "$parent_run_dir" "$updates"
  fi
}

_cq_merge_ctx_locked() {
  local run_dir="$1" updates="$2"
  local ctx
  ctx=$(cq_read_json "${run_dir}/ctx.json")
  ctx=$(jq --argjson u "$updates" '. + $u' <<< "$ctx")
  cq_write_json "${run_dir}/ctx.json" "$ctx"
}

# --- Workflow inheritance ---

# Resolve workflow inheritance (extends).
# Takes a workflow JSON and returns the fully resolved workflow JSON.
# Usage: resolved=$(cq_resolve_workflow_inheritance "$wf_json")
cq_resolve_workflow_inheritance() {
  local wf_json="$1"

  local extends_name
  extends_name=$(jq -r '.extends // empty' <<< "$wf_json")
  [[ -z "$extends_name" ]] && { echo "$wf_json"; return 0; }

  # Find and load base workflow
  local base_file
  base_file=$(cq_find_workflow "$extends_name") || {
    cq_warn "Base workflow '${extends_name}' not found for extends"
    echo "$wf_json"
    return 0
  }

  local base_json
  base_json=$(cq_yaml_to_json "$base_file")

  # Recursively resolve base workflow if it also extends
  base_json=$(cq_resolve_workflow_inheritance "$base_json")

  # Start with base steps, defaults, params
  local base_steps base_defaults base_params
  base_steps=$(jq '.steps // []' <<< "$base_json")
  base_defaults=$(jq '.defaults // {}' <<< "$base_json")
  base_params=$(jq '.params // null' <<< "$base_json")

  # Apply remove list: filter out steps with those IDs
  local remove_list
  remove_list=$(jq -c '.remove // []' <<< "$wf_json")
  if [[ "$remove_list" != "[]" ]]; then
    base_steps=$(jq --argjson remove "$remove_list" '
      [.[] | select(.id as $id | $remove | index($id) | not)]
    ' <<< "$base_steps")
  fi

  # Apply override map: merge fields into matching step IDs
  local override_map
  override_map=$(jq -c '.override // {}' <<< "$wf_json")
  if [[ "$override_map" != "{}" ]]; then
    base_steps=$(jq --argjson overrides "$override_map" '
      [.[] | . as $step |
        if $overrides[$step.id] then ($step * $overrides[$step.id])
        else $step end]
    ' <<< "$base_steps")
  fi

  # Append new steps from child workflow
  local child_steps
  child_steps=$(jq '.steps // []' <<< "$wf_json")
  if [[ "$(jq 'length' <<< "$child_steps")" -gt 0 ]]; then
    base_steps=$(jq --argjson child "$child_steps" '. + $child' <<< "$base_steps")
  fi

  # Merge defaults (child overrides base)
  local child_defaults
  child_defaults=$(jq '.defaults // {}' <<< "$wf_json")
  local merged_defaults
  merged_defaults=$(jq -n --argjson base "$base_defaults" --argjson child "$child_defaults" '$base * $child')

  # Merge params (child overrides base)
  local child_params
  child_params=$(jq '.params // null' <<< "$wf_json")
  local merged_params
  if [[ "$child_params" != "null" && "$base_params" != "null" ]]; then
    merged_params=$(jq -n --argjson base "$base_params" --argjson child "$child_params" '$base * $child')
  elif [[ "$child_params" != "null" ]]; then
    merged_params="$child_params"
  else
    merged_params="$base_params"
  fi

  # Build resolved workflow: child metadata with resolved steps/defaults/params
  local resolved
  resolved=$(jq --argjson steps "$base_steps" --argjson defaults "$merged_defaults" --argjson params "$merged_params" '
    del(.extends, .override, .remove) |
    .steps = $steps |
    .defaults = $defaults |
    (if $params != null then .params = $params else . end)
  ' <<< "$wf_json")

  echo "$resolved"
}

# --- Run listing ---

cq_run_ids() {
  local runs_dir="${CQ_PROJECT_ROOT}/.claudekiq/runs"
  [[ -d "$runs_dir" ]] || return 0
  local d
  for d in "$runs_dir"/*/; do
    [[ -f "${d}meta.json" ]] && basename "$d"
  done
}

cq_active_run_ids() {
  local run_id meta status
  for run_id in $(cq_run_ids); do
    meta=$(cq_read_meta "$run_id" 2>/dev/null) || continue
    status=$(jq -r '.status' <<< "$meta")
    case "$status" in
      running|queued|paused|gated) echo "$run_id" ;;
    esac
  done
}

# --- Workflow discovery ---

cq_find_workflow() {
  local name="$1"
  local file

  # Project workflows
  file="${CQ_PROJECT_ROOT}/.claudekiq/workflows/${name}.yml"
  [[ -f "$file" ]] && { echo "$file"; return 0; }
  file="${CQ_PROJECT_ROOT}/.claudekiq/workflows/${name}.yaml"
  [[ -f "$file" ]] && { echo "$file"; return 0; }

  # Project private workflows
  file="${CQ_PROJECT_ROOT}/.claudekiq/workflows/private/${name}.yml"
  [[ -f "$file" ]] && { echo "$file"; return 0; }
  file="${CQ_PROJECT_ROOT}/.claudekiq/workflows/private/${name}.yaml"
  [[ -f "$file" ]] && { echo "$file"; return 0; }

  # Global workflows
  file="${HOME}/.cq/workflows/${name}.yml"
  [[ -f "$file" ]] && { echo "$file"; return 0; }
  file="${HOME}/.cq/workflows/${name}.yaml"
  [[ -f "$file" ]] && { echo "$file"; return 0; }

  return 1
}

cq_list_workflows() {
  local dirs=()
  [[ -d "${CQ_PROJECT_ROOT}/.claudekiq/workflows" ]] && dirs+=("${CQ_PROJECT_ROOT}/.claudekiq/workflows")
  [[ -d "${CQ_PROJECT_ROOT}/.claudekiq/workflows/private" ]] && dirs+=("${CQ_PROJECT_ROOT}/.claudekiq/workflows/private")
  [[ -d "${HOME}/.cq/workflows" ]] && dirs+=("${HOME}/.cq/workflows")

  local dir f name
  for dir in "${dirs[@]}"; do
    for f in "$dir"/*.yml "$dir"/*.yaml; do
      [[ -f "$f" ]] || continue
      name=$(basename "$f")
      name="${name%.*}"
      echo "$name"
    done
  done | sort -u
}

# --- Routing ---

# Resolve the next step after completing step_id with given outcome
# Returns step ID or "end"
cq_resolve_next() {
  local run_id="$1" step_id="$2" outcome="$3"
  local step steps ctx_json result

  step=$(cq_get_step "$run_id" "$step_id")
  steps=$(cq_read_steps "$run_id")
  ctx_json=$(cq_read_ctx "$run_id")

  # Try each routing strategy in order
  result=$(_resolve_outcome_route "$step" "$outcome" "$run_id" "$step_id") && { echo "$result"; return 0; }
  result=$(_resolve_next_field "$step" "$ctx_json") && { echo "$result"; return 0; }
  _resolve_implicit_next "$steps" "$step_id"
}

# Check outcome-specific routes (on_pass, on_fail, on_timeout)
_resolve_outcome_route() {
  local step="$1" outcome="$2" run_id="$3" step_id="$4"

  case "$outcome" in
    pass)
      local on_pass
      on_pass=$(jq -r '.on_pass // empty' <<< "$step")
      [[ -n "$on_pass" ]] && { echo "$on_pass"; return 0; }
      ;;
    fail)
      local on_fail
      on_fail=$(jq -r '.on_fail // empty' <<< "$step")
      [[ -n "$on_fail" ]] && { echo "$on_fail"; return 0; }
      ;;
    timeout)
      local on_timeout
      on_timeout=$(jq -r '.on_timeout // empty' <<< "$step")
      if [[ -n "$on_timeout" ]]; then
        case "$on_timeout" in
          fail) ;; # fall through
          skip) cq_resolve_next "$run_id" "$step_id" "pass"; return 0 ;;
          *)    echo "$on_timeout"; return 0 ;;
        esac
      fi
      # Default: treat timeout as fail
      local on_fail_fallback
      on_fail_fallback=$(jq -r '.on_fail // empty' <<< "$step")
      [[ -n "$on_fail_fallback" ]] && { echo "$on_fail_fallback"; return 0; }
      ;;
  esac
  return 1
}

# Check 'next' field (string or conditional array)
_resolve_next_field() {
  local step="$1" ctx_json="$2"
  local next_type
  next_type=$(jq -r '.next | type' <<< "$step")

  if [[ "$next_type" == "array" ]]; then
    # Conditional routing: evaluate each rule
    local rules_count i
    rules_count=$(jq '.next | length' <<< "$step")
    for ((i = 0; i < rules_count; i++)); do
      local rule
      rule=$(jq --argjson i "$i" '.next[$i]' <<< "$step")

      local is_default
      is_default=$(jq -r '.default // empty' <<< "$rule")
      if [[ -n "$is_default" ]]; then
        echo "$is_default"
        return 0
      fi

      local when_clause goto_target
      when_clause=$(jq -r '.when // empty' <<< "$rule")
      goto_target=$(jq -r '.goto // empty' <<< "$rule")

      if [[ -n "$when_clause" && -n "$goto_target" ]]; then
        local interpolated
        interpolated=$(cq_interpolate "$when_clause" "$ctx_json")
        if cq_evaluate_condition "$interpolated"; then
          echo "$goto_target"
          return 0
        fi
      fi
    done
  elif [[ "$next_type" == "string" ]]; then
    local next_val
    next_val=$(jq -r '.next' <<< "$step")
    [[ -n "$next_val" ]] && { echo "$next_val"; return 0; }
  fi
  return 1
}

# Fallback: next step in array order
_resolve_implicit_next() {
  local steps="$1" step_id="$2"
  local index total
  index=$(jq --arg id "$step_id" '[.[] | .id] | to_entries[] | select(.value == $id) | .key' <<< "$steps")
  total=$(jq 'length' <<< "$steps")
  local next_index=$((index + 1))

  if [[ $next_index -lt $total ]]; then
    jq -r --argjson i "$next_index" '.[$i].id' <<< "$steps"
  else
    echo "end"
  fi
}

# --- TODO storage ---

cq_todos_dir() {
  local run_id="$1"
  echo "$(cq_run_dir "$run_id")/todos"
}

cq_create_todo() {
  local run_id="$1" step_id="$2" action="$3" description="$4"
  local run_dir todo_dir todo_id ts priority step_name

  run_dir=$(cq_run_dir "$run_id")
  todo_dir="${run_dir}/todos"
  mkdir -p "$todo_dir"

  todo_id=$(cq_gen_id)
  ts=$(cq_now)

  local meta
  meta=$(cq_read_json "${run_dir}/meta.json")
  priority=$(jq -r '.priority // "normal"' <<< "$meta")

  local step
  step=$(cq_get_step "$run_id" "$step_id")
  step_name=$(jq -r '.name // .id' <<< "$step")

  local todo_json
  todo_json=$(jq -cn \
    --arg id "$todo_id" \
    --arg run_id "$run_id" \
    --arg step_id "$step_id" \
    --arg step_name "$step_name" \
    --arg action "$action" \
    --arg description "$description" \
    --arg status "pending" \
    --arg created_at "$ts" \
    --arg priority "$priority" \
    '{id:$id, run_id:$run_id, step_id:$step_id, step_name:$step_name,
      action:$action, description:$description, status:$status,
      created_at:$created_at, priority:$priority}')

  cq_write_json "${todo_dir}/${todo_id}.json" "$todo_json"
  cq_log_event "$run_dir" "todo_created" \
    "$(jq -cn --arg tid "$todo_id" --arg sid "$step_id" --arg action "$action" \
      '{todo_id:$tid, step_id:$sid, action:$action}')"

  # Fire on_gate hook
  cq_fire_hook "on_gate" "$run_dir"

  echo "$todo_id"
}

# List all pending TODOs across all runs, sorted by priority + timestamp
cq_list_todos() {
  local filter_run="${1:-}"
  local run_id todo_file todo_json priority weight epoch_s score

  local -a todo_items=()

  for run_id in $(cq_run_ids); do
    [[ -n "$filter_run" && "$run_id" != "$filter_run" ]] && continue
    local todo_dir
    todo_dir="$(cq_run_dir "$run_id")/todos"
    [[ -d "$todo_dir" ]] || continue

    for todo_file in "$todo_dir"/*.json; do
      [[ -f "$todo_file" ]] || continue
      todo_json=$(cat "$todo_file")
      local status
      status=$(jq -r '.status' <<< "$todo_json")
      [[ "$status" != "pending" ]] && continue

      priority=$(jq -r '.priority // "normal"' <<< "$todo_json")
      weight=$(cq_priority_weight "$priority")
      local created_at
      created_at=$(jq -r '.created_at' <<< "$todo_json")
      epoch_s=$(date -d "$created_at" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || echo "0")
      score=$((weight * 1000000000000 + epoch_s))

      todo_items+=("$(jq -c --argjson s "$score" '. + {score: $s}' <<< "$todo_json")")
    done
  done

  # Sort by score (ascending = highest priority first)
  if [[ ${#todo_items[@]} -gt 0 ]]; then
    printf '%s\n' "${todo_items[@]}" | jq -s 'sort_by(.score)'
  else
    echo "[]"
  fi
}

# Resolve a pending TODO by its index (1-based)
cq_find_todo_by_index() {
  local index="$1"
  local todos
  todos=$(cq_list_todos)
  local zero_idx=$((index - 1))
  jq --argjson i "$zero_idx" '.[$i] // empty' <<< "$todos"
}

cq_update_todo() {
  local run_id="$1" todo_id="$2" new_status="$3"
  local todo_file
  todo_file="$(cq_run_dir "$run_id")/todos/${todo_id}.json"
  [[ -f "$todo_file" ]] || cq_die "TODO not found: ${todo_id}"
  local todo
  todo=$(cat "$todo_file")
  todo=$(jq --arg s "$new_status" '.status = $s' <<< "$todo")
  cq_write_json "$todo_file" "$todo"
}

# --- TODO sync (bidirectional with Claude Code native TodoRead/TodoWrite) ---

# Read sync state for a run
cq_todo_sync_state() {
  local run_id="$1"
  local sync_file
  sync_file="$(cq_run_dir "$run_id")/todos/.sync_state.json"
  if [[ -f "$sync_file" ]]; then
    cat "$sync_file"
  else
    echo '{"last_sync":null,"synced_todos":{}}'
  fi
}

# Write sync state for a run
cq_todo_sync_state_set() {
  local run_id="$1" data="$2"
  local todo_dir
  todo_dir="$(cq_run_dir "$run_id")/todos"
  mkdir -p "$todo_dir"
  cq_write_json "${todo_dir}/.sync_state.json" "$data"
}

# Convert all pending TODOs to native TodoWrite-compatible format
# Returns JSON: {todos: [...], run_ids: [...]}
cq_todos_as_native_format() {
  local filter_run="${1:-}"
  local run_id todo_file todo_json
  local -a native_items=()
  local -a seen_runs=()

  for run_id in $(cq_run_ids); do
    [[ -n "$filter_run" && "$run_id" != "$filter_run" ]] && continue
    local todo_dir
    todo_dir="$(cq_run_dir "$run_id")/todos"
    [[ -d "$todo_dir" ]] || continue

    local has_todos=false
    for todo_file in "$todo_dir"/*.json; do
      [[ -f "$todo_file" ]] || continue
      [[ "$(basename "$todo_file")" == ".sync_state.json" ]] && continue
      todo_json=$(cat "$todo_file")
      local status
      status=$(jq -r '.status' <<< "$todo_json")
      [[ "$status" != "pending" ]] && continue

      has_todos=true
      local native
      native=$(jq -c '{
        id: .id,
        content: ("[cq] " + (.step_name // .step_id) + " — " + .action),
        status: "pending",
        priority: .priority,
        metadata: {run_id: .run_id, step_id: .step_id, todo_id: .id, action: .action, description: (.description // "")}
      }' <<< "$todo_json")
      native_items+=("$native")
    done
    [[ "$has_todos" == "true" ]] && seen_runs+=("\"${run_id}\"")
  done

  local todos_json="[]"
  if [[ ${#native_items[@]} -gt 0 ]]; then
    todos_json=$(printf '%s\n' "${native_items[@]}" | jq -s '.')
  fi

  local runs_json="[]"
  if [[ ${#seen_runs[@]} -gt 0 ]]; then
    runs_json=$(IFS=,; echo "[${seen_runs[*]}]")
  fi

  jq -cn --argjson todos "$todos_json" --argjson runs "$runs_json" \
    '{todos: $todos, run_ids: $runs}'
}

# Apply sync resolutions from native system back to filesystem
# Input JSON: {resolutions: [{todo_id: "...", run_id: "...", action: "approve|reject|dismiss"}]}
cq_todos_apply_sync() {
  local input="$1"
  local count applied=0

  count=$(jq '.resolutions | length' <<< "$input")
  [[ "$count" -eq 0 ]] && { echo '{"applied":0}'; return 0; }

  local i
  for ((i = 0; i < count; i++)); do
    local resolution
    resolution=$(jq --argjson i "$i" '.resolutions[$i]' <<< "$input")
    local todo_id run_id action
    todo_id=$(jq -r '.todo_id' <<< "$resolution")
    run_id=$(jq -r '.run_id' <<< "$resolution")
    action=$(jq -r '.action // "dismiss"' <<< "$resolution")

    local todo_file
    todo_file="$(cq_run_dir "$run_id")/todos/${todo_id}.json"
    [[ -f "$todo_file" ]] || continue

    local current_status
    current_status=$(jq -r '.status' < "$todo_file")
    [[ "$current_status" != "pending" ]] && continue

    case "$action" in
      approve|override)
        cq_update_todo "$run_id" "$todo_id" "done"
        applied=$((applied + 1))
        ;;
      reject)
        cq_update_todo "$run_id" "$todo_id" "done"
        applied=$((applied + 1))
        ;;
      dismiss)
        cq_update_todo "$run_id" "$todo_id" "dismissed"
        applied=$((applied + 1))
        ;;
    esac
  done

  jq -cn --argjson n "$applied" '{applied: $n}'
}

# Update sync state after a sync cycle
cq_todo_mark_synced() {
  local run_id="$1"
  local todos_json="$2"  # array of {id, native_id} pairs
  local ts
  ts=$(cq_now)

  local sync_state
  sync_state=$(cq_todo_sync_state "$run_id")
  sync_state=$(jq --arg ts "$ts" --argjson todos "$todos_json" '
    .last_sync = $ts |
    reduce ($todos[] | {key: .id, value: {status: "synced", native_id: (.native_id // ""), synced_at: $ts}}) as $item (
      .; .synced_todos[$item.key] = $item.value
    )
  ' <<< "$sync_state")
  cq_todo_sync_state_set "$run_id" "$sync_state"
}
