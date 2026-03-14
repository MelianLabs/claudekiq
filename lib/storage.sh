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
  echo "$data" | jq '.' > "$file" 2>/dev/null || cq_die "Failed to write JSON: ${file}"
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
  meta=$(echo "$meta" | jq --arg updated_at "$ts" "$@" "(${filter}) | .updated_at = \$updated_at")
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
  echo "$ctx" | jq -r --arg k "$key" '.[$k] // empty'
}

cq_ctx_set() {
  local run_id="$1" key="$2" value="$3"
  local run_dir
  run_dir=$(cq_run_dir "$run_id")
  local ctx
  ctx=$(cq_read_json "${run_dir}/ctx.json")
  ctx=$(echo "$ctx" | jq --arg k "$key" --arg v "$value" '.[$k] = $v')
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
  echo "$steps" | jq --arg id "$step_id" '.[] | select(.id == $id)'
}

cq_step_index() {
  local run_id="$1" step_id="$2"
  local steps
  steps=$(cq_read_steps "$run_id")
  echo "$steps" | jq --arg id "$step_id" 'to_entries[] | select(.value.id == $id) | .key'
}

cq_step_count() {
  local run_id="$1"
  local steps
  steps=$(cq_read_steps "$run_id")
  echo "$steps" | jq 'length'
}

cq_step_at_index() {
  local run_id="$1" index="$2"
  local steps
  steps=$(cq_read_steps "$run_id")
  echo "$steps" | jq --argjson i "$index" '.[$i]'
}

cq_step_ids() {
  local run_id="$1"
  local steps
  steps=$(cq_read_steps "$run_id")
  echo "$steps" | jq -r '.[].id'
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
  echo "$state" | jq --arg id "$step_id" '.[$id]'
}

cq_step_state_set() {
  local run_id="$1" step_id="$2" filter="$3"
  shift 3
  local run_dir
  run_dir=$(cq_run_dir "$run_id")
  local state
  state=$(cq_read_json "${run_dir}/state.json")
  state=$(echo "$state" | jq --arg id "$step_id" "$@" '.[$id] |= ('"$filter"')')
  cq_write_json "${run_dir}/state.json" "$state"
}

# Initialize state for a step
cq_init_step_state() {
  local run_id="$1" step_id="$2"
  local run_dir
  run_dir=$(cq_run_dir "$run_id")
  local state
  state=$(cq_read_json "${run_dir}/state.json")
  state=$(echo "$state" | jq --arg id "$step_id" \
    '.[$id] = {"status":"pending","visits":0,"attempt":0,"result":null,"started_at":null,"finished_at":null}')
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
    status=$(echo "$meta" | jq -r '.status')
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
  local step steps ctx_json

  step=$(cq_get_step "$run_id" "$step_id")
  steps=$(cq_read_steps "$run_id")
  ctx_json=$(cq_read_ctx "$run_id")

  # 1. Check outcome-specific routes
  if [[ "$outcome" == "pass" ]]; then
    local on_pass
    on_pass=$(echo "$step" | jq -r '.on_pass // empty')
    if [[ -n "$on_pass" ]]; then
      echo "$on_pass"
      return 0
    fi
  fi
  if [[ "$outcome" == "fail" ]]; then
    local on_fail
    on_fail=$(echo "$step" | jq -r '.on_fail // empty')
    if [[ -n "$on_fail" ]]; then
      echo "$on_fail"
      return 0
    fi
  fi
  if [[ "$outcome" == "timeout" ]]; then
    local on_timeout
    on_timeout=$(echo "$step" | jq -r '.on_timeout // empty')
    if [[ -n "$on_timeout" ]]; then
      # on_timeout can be "fail", "skip", or a step_id
      case "$on_timeout" in
        fail) ;; # fall through to treat as fail
        skip)
          echo "$(cq_resolve_next "$run_id" "$step_id" "pass")"
          return 0
          ;;
        *)
          echo "$on_timeout"
          return 0
          ;;
      esac
    fi
    # Default: treat timeout as fail
    local on_fail_fallback
    on_fail_fallback=$(echo "$step" | jq -r '.on_fail // empty')
    if [[ -n "$on_fail_fallback" ]]; then
      echo "$on_fail_fallback"
      return 0
    fi
  fi

  # 2. Check 'next' field
  local next_type
  next_type=$(echo "$step" | jq -r '.next | type')

  if [[ "$next_type" == "array" ]]; then
    # Conditional routing
    local rules_count i when_clause goto_target interpolated
    rules_count=$(echo "$step" | jq '.next | length')
    for ((i = 0; i < rules_count; i++)); do
      local rule
      rule=$(echo "$step" | jq --argjson i "$i" '.next[$i]')

      # Check for default rule
      local is_default
      is_default=$(echo "$rule" | jq -r '.default // empty')
      if [[ -n "$is_default" ]]; then
        echo "$is_default"
        return 0
      fi

      when_clause=$(echo "$rule" | jq -r '.when // empty')
      goto_target=$(echo "$rule" | jq -r '.goto // empty')

      if [[ -n "$when_clause" && -n "$goto_target" ]]; then
        interpolated=$(cq_interpolate "$when_clause" "$ctx_json")
        if cq_evaluate_condition "$interpolated"; then
          echo "$goto_target"
          return 0
        fi
      fi
    done
  elif [[ "$next_type" == "string" ]]; then
    local next_val
    next_val=$(echo "$step" | jq -r '.next')
    if [[ -n "$next_val" ]]; then
      echo "$next_val"
      return 0
    fi
  fi

  # 3. Implicit ordering: next step in array
  local index total
  index=$(echo "$steps" | jq --arg id "$step_id" '[.[] | .id] | to_entries[] | select(.value == $id) | .key')
  total=$(echo "$steps" | jq 'length')
  local next_index=$((index + 1))

  if [[ $next_index -lt $total ]]; then
    echo "$steps" | jq -r --argjson i "$next_index" '.[$i].id'
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
  priority=$(echo "$meta" | jq -r '.priority // "normal"')

  local step
  step=$(cq_get_step "$run_id" "$step_id")
  step_name=$(echo "$step" | jq -r '.name // .id')

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

  local todos_json="[]"

  for run_id in $(cq_run_ids); do
    [[ -n "$filter_run" && "$run_id" != "$filter_run" ]] && continue
    local todo_dir
    todo_dir="$(cq_run_dir "$run_id")/todos"
    [[ -d "$todo_dir" ]] || continue

    for todo_file in "$todo_dir"/*.json; do
      [[ -f "$todo_file" ]] || continue
      todo_json=$(cat "$todo_file")
      local status
      status=$(echo "$todo_json" | jq -r '.status')
      [[ "$status" != "pending" ]] && continue

      priority=$(echo "$todo_json" | jq -r '.priority // "normal"')
      weight=$(cq_priority_weight "$priority")
      # Use created_at timestamp for scoring
      local created_at
      created_at=$(echo "$todo_json" | jq -r '.created_at')
      # Convert ISO to epoch for scoring
      epoch_s=$(date -d "$created_at" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || echo "0")
      score=$((weight * 1000000000000 + epoch_s))

      todos_json=$(echo "$todos_json" | jq --argjson t "$todo_json" --argjson s "$score" \
        '. + [($t + {score: $s})]')
    done
  done

  # Sort by score (ascending = highest priority first)
  echo "$todos_json" | jq 'sort_by(.score)'
}

# Resolve a pending TODO by its index (1-based)
cq_find_todo_by_index() {
  local index="$1"
  local todos
  todos=$(cq_list_todos)
  local zero_idx=$((index - 1))
  echo "$todos" | jq --argjson i "$zero_idx" '.[$i] // empty'
}

cq_update_todo() {
  local run_id="$1" todo_id="$2" new_status="$3"
  local todo_file
  todo_file="$(cq_run_dir "$run_id")/todos/${todo_id}.json"
  [[ -f "$todo_file" ]] || cq_die "TODO not found: ${todo_id}"
  local todo
  todo=$(cat "$todo_file")
  todo=$(echo "$todo" | jq --arg s "$new_status" '.status = $s')
  cq_write_json "$todo_file" "$todo"
}
