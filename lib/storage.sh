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
  local ctx
  ctx=$(cq_read_json "${run_dir}/ctx.json")
  ctx=$(jq --arg k "$key" --arg v "$value" '.[$k] = $v' <<< "$ctx")
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
    '.[$id] = {"status":"pending","visits":0,"attempt":0,"result":null,"started_at":null,"finished_at":null}' <<< "$state")
  cq_write_json "${run_dir}/state.json" "$state"
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
