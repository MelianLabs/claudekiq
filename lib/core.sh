#!/usr/bin/env bash
# core.sh — Utility functions for cq

# --- Output helpers ---

cq_die() {
  echo "cq: error: $*" >&2
  exit 1
}

cq_warn() {
  echo "cq: warning: $*" >&2
}

cq_info() {
  [[ "$CQ_JSON" == "true" ]] && return
  echo "$@"
}

# Output JSON if --json mode is active. Returns 1 (false) when not in JSON mode,
# allowing: cq_json_out ... || cq_info "text"
cq_json_out() {
  [[ "$CQ_JSON" != "true" ]] && return 1
  jq -cn "$@"
}

# Trim leading/trailing whitespace using pure Bash (no subprocess)
cq_trim() {
  local var="$1"
  var="${var#"${var%%[![:space:]]*}"}"
  var="${var%"${var##*[![:space:]]}"}"
  echo "$var"
}

# --- ID and time ---

cq_gen_id() {
  local uuid
  if command -v uuidgen >/dev/null 2>&1; then
    uuid=$(uuidgen 2>/dev/null)
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    uuid=$(cat /proc/sys/kernel/random/uuid)
  else
    # fallback: random hex
    uuid=$(printf '%04x%04x-%04x-%04x-%04x-%04x%04x%04x' \
      $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM)
  fi
  echo "${uuid:0:8}" | tr '[:upper:]' '[:lower:]'
}

cq_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

cq_epoch() {
  date +%s
}

# --- Logging ---

cq_log_event() {
  local run_dir="$1" event="$2" data="${3:-"{}"}"
  local ts
  ts=$(cq_now)
  printf '%s\n' "$(jq -cn --arg ts "$ts" --arg event "$event" --argjson data "$data" \
    '{ts:$ts, event:$event, data:$data}')" >> "${run_dir}/log.jsonl"
}

# --- Interpolation ---

# Replace {{var}} references with values from a JSON context object
# Usage: cq_interpolate "template string" '{"key":"value"}'
cq_interpolate() {
  local template="$1"
  local ctx_json="$2"
  local result="$template"
  local var val

  # Extract all {{var}} references
  while [[ "$result" =~ \{\{([a-zA-Z_][a-zA-Z0-9_]*)\}\} ]]; do
    var="${BASH_REMATCH[1]}"
    val=$(jq -r --arg k "$var" '.[$k] // ""' <<< "$ctx_json")
    # Replace all occurrences of this specific variable
    result="${result//\{\{${var}\}\}/${val}}"
  done
  echo "$result"
}

# --- Condition evaluation ---

# Evaluate a single condition expression like "value1 == value2"
# Returns 0 (true) or 1 (false)
_cq_evaluate_single() {
  local condition="$1"
  local lhs op rhs

  # Trim whitespace
  condition=$(cq_trim "$condition")

  # Handle bare unary operators (just "empty" or "not_empty" after trimming)
  if [[ "$condition" == "empty" || "$condition" == "not_empty" ]]; then
    lhs=""
    op="$condition"
    rhs=""
  # Handle unary operators with lhs (e.g., "some_value empty")
  elif [[ "$condition" =~ ^(.*)[[:space:]]+(empty|not_empty)[[:space:]]*$ ]]; then
    lhs=$(cq_trim "${BASH_REMATCH[1]}")
    op="${BASH_REMATCH[2]}"
    rhs=""
  # Parse binary operators (order matters: >= before >, <= before <)
  elif [[ "$condition" =~ ^(.+)[[:space:]]+(==|!=|>=|<=|>|<|contains|matches)[[:space:]]+(.*)?$ ]]; then
    lhs=$(cq_trim "${BASH_REMATCH[1]}")
    op="${BASH_REMATCH[2]}"
    rhs=$(cq_trim "${BASH_REMATCH[3]}")
  else
    return 1
  fi

  case "$op" in
    "==")
      [[ "$lhs" == "$rhs" ]]
      ;;
    "!=")
      [[ "$lhs" != "$rhs" ]]
      ;;
    ">")
      [[ "$lhs" -gt "$rhs" ]] 2>/dev/null || return 1
      ;;
    "<")
      [[ "$lhs" -lt "$rhs" ]] 2>/dev/null || return 1
      ;;
    ">=")
      [[ "$lhs" -ge "$rhs" ]] 2>/dev/null || return 1
      ;;
    "<=")
      [[ "$lhs" -le "$rhs" ]] 2>/dev/null || return 1
      ;;
    "contains")
      [[ "$lhs" == *"$rhs"* ]]
      ;;
    "matches")
      [[ "$lhs" =~ $rhs ]]
      ;;
    "empty")
      [[ -z "$lhs" || "$lhs" =~ ^[[:space:]]*$ ]]
      ;;
    "not_empty")
      [[ -n "$lhs" && ! "$lhs" =~ ^[[:space:]]*$ ]]
      ;;
    *)
      return 1
      ;;
  esac
}

# Evaluate a condition string, supporting compound AND/OR expressions.
# Examples:
#   "value1 == value2"
#   "count > 0"
#   "name matches ^feat"
#   "a == true AND b == true"
#   "x == 1 OR y == 2"
# Note: AND/OR cannot be mixed — use one or the other.
# Returns 0 (true) or 1 (false)
cq_evaluate_condition() {
  local condition="$1"

  # Trim whitespace
  condition=$(cq_trim "$condition")

  # Check for AND compound (split on " AND ")
  if [[ "$condition" == *" AND "* ]]; then
    local part
    while IFS= read -r part; do
      [[ -z "$part" ]] && continue
      _cq_evaluate_single "$part" || return 1
    done <<< "$(echo "$condition" | sed 's/ AND /\n/g')"
    return 0
  fi

  # Check for OR compound (split on " OR ")
  if [[ "$condition" == *" OR "* ]]; then
    local part
    while IFS= read -r part; do
      [[ -z "$part" ]] && continue
      _cq_evaluate_single "$part" && return 0
    done <<< "$(echo "$condition" | sed 's/ OR /\n/g')"
    return 1
  fi

  # Simple condition
  _cq_evaluate_single "$condition"
}

# --- Configuration ---

cq_default_config() {
  cat <<'DEFAULTS'
{
  "prefix": "cq",
  "ttl": 2592000,
  "priorities": ["urgent", "high", "normal", "low"],
  "default_priority": "normal",
  "concurrency": 1,
  "markers": {
    "passed": "✅", "failed": "❌", "running": "🔄",
    "gated": "⏸️", "skipped": "⏭️", "pending": "⬚",
    "queued": "📋", "paused": "⏯️", "cancelled": "🚫",
    "completed": "✅", "blocked": "⏳"
  },
  "step_fields": ["name", "type", "target", "args_template", "gate", "model", "background"],
  "edge_keys": ["next", "on_pass", "on_fail"],
  "notifications": {
    "on_gate": null,
    "on_fail": null,
    "on_complete": null,
    "on_start": null
  },
  "min_cq_version": null
}
DEFAULTS
}

_CQ_CONFIG_CACHE=""

cq_resolve_config() {
  if [[ -n "$_CQ_CONFIG_CACHE" ]]; then
    echo "$_CQ_CONFIG_CACHE"
    return
  fi

  local defaults global_cfg project_cfg
  defaults=$(cq_default_config)
  global_cfg="${HOME}/.cq/config.json"
  project_cfg="${CQ_PROJECT_ROOT}/.claudekiq/settings.json"

  local result="$defaults"
  if [[ -f "$global_cfg" ]]; then
    local gc
    gc=$(cat "$global_cfg")
    result=$(jq -n --argjson a "$result" --argjson b "$gc" '$a * $b' 2>/dev/null || echo "$result")
  fi
  if [[ -f "$project_cfg" ]]; then
    local pc
    pc=$(cat "$project_cfg")
    result=$(jq -n --argjson a "$result" --argjson b "$pc" '$a * $b' 2>/dev/null || echo "$result")
  fi
  _CQ_CONFIG_CACHE="$result"
  echo "$result"
}

cq_config_get() {
  local key="$1"
  local config
  config=$(cq_resolve_config)
  jq -r --arg k "$key" '.[$k] // empty' <<< "$config"
}

# --- Locking ---

cq_acquire_lock() {
  local run_dir="$1"
  local lockdir="${run_dir}/.lock"
  local timeout=5
  local elapsed=0

  while ! mkdir "$lockdir" 2>/dev/null; do
    sleep 0.2
    elapsed=$((elapsed + 1))
    if [[ $elapsed -ge 25 ]]; then
      cq_die "Cannot acquire lock on ${run_dir} (timeout after ${timeout}s)"
    fi
  done
  # Store lockdir for release
  CQ_CURRENT_LOCK="$lockdir"
}

cq_release_lock() {
  if [[ -n "$CQ_CURRENT_LOCK" && -d "$CQ_CURRENT_LOCK" ]]; then
    rmdir "$CQ_CURRENT_LOCK" 2>/dev/null
    CQ_CURRENT_LOCK=""
  fi
}

# Execute a function while holding a lock on the run directory.
# Acquires the lock, runs the command, and releases on exit (including errors).
# Usage: cq_with_lock "$run_dir" some_function arg1 arg2
cq_with_lock() {
  local run_dir="$1"; shift
  cq_acquire_lock "$run_dir"
  trap 'cq_release_lock' EXIT
  "$@"
  cq_release_lock
  trap - EXIT
}

# --- Run validation ---

# Validate a run_id exists, die with usage if missing or not found.
# Returns the run directory path via stdout.
# Usage: run_dir=$(cq_require_run "$run_id" "cq command <run_id>")
cq_require_run() {
  local run_id="$1" usage="$2"
  [[ -z "$run_id" ]] && cq_die "Usage: $usage"
  cq_run_exists "$run_id" || cq_die "Run not found: ${run_id}"
  cq_run_dir "$run_id"
}

# --- Project root ---

cq_find_project_root() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -d "${dir}/.claudekiq" ]]; then
      echo "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

# --- Priority ---

cq_priority_weight() {
  case "$1" in
    urgent) echo 1 ;;
    high)   echo 2 ;;
    normal) echo 3 ;;
    low)    echo 4 ;;
    *)      echo 3 ;;
  esac
}

cq_valid_priority() {
  local p="$1"
  [[ "$p" == "urgent" || "$p" == "high" || "$p" == "normal" || "$p" == "low" ]]
}

# --- Version comparison ---

# Returns 0 if v1 >= v2 (semver)
cq_version_gte() {
  local v1="$1" v2="$2"
  local IFS='.'
  read -ra a <<< "$v1"
  read -ra b <<< "$v2"
  local i
  for i in 0 1 2; do
    local av="${a[$i]:-0}" bv="${b[$i]:-0}"
    if [[ "$av" -gt "$bv" ]]; then return 0; fi
    if [[ "$av" -lt "$bv" ]]; then return 1; fi
  done
  return 0
}

cq_check_version() {
  local min_version
  min_version=$(cq_config_get "min_cq_version" 2>/dev/null)
  if [[ -n "$min_version" && "$min_version" != "null" ]]; then
    if ! cq_version_gte "$CQ_VERSION" "$min_version"; then
      cq_warn "Installed cq version ${CQ_VERSION} is below project minimum ${min_version}"
    fi
  fi
}

# --- Notification hooks ---

cq_fire_hook() {
  local hook_name="$1"
  local run_dir="$2"

  local config hook_cmd
  config=$(cq_resolve_config)
  hook_cmd=$(jq -r --arg h "$hook_name" '.notifications[$h] // empty' <<< "$config")

  local run_id
  run_id=$(basename "$run_dir")

  local current_step=""
  if [[ -f "${run_dir}/meta.json" ]]; then
    current_step=$(jq -r '.current_step // ""' "${run_dir}/meta.json")
  fi

  local template=""
  if [[ -f "${run_dir}/meta.json" ]]; then
    template=$(jq -r '.template // ""' "${run_dir}/meta.json")
  fi

  # Emit structured JSON event to stderr for Claude Code hooks to parse
  jq -cn --arg hook "$hook_name" --arg run_id "$run_id" \
    --arg step "$current_step" --arg template "$template" \
    '{event: "cq_hook", hook: $hook, run_id: $run_id, step: $step, template: $template}' >&2

  # If a notification command is configured, pass context via environment variables
  # instead of interpolating into the command string (prevents shell injection)
  if [[ -n "$hook_cmd" ]]; then
    (
      export CQ_HOOK="$hook_name"
      export CQ_RUN_ID="$run_id"
      export CQ_STEP_ID="$current_step"
      export CQ_TEMPLATE="$template"
      export CQ_RUN_DIR="$run_dir"
      bash -c "$hook_cmd" &>/dev/null
    ) &
  fi
}

# --- Platform detection ---

cq_detect_platform() {
  case "$OSTYPE" in
    linux*)  CQ_PLATFORM="linux" ;;
    darwin*) CQ_PLATFORM="macos" ;;
    *)       CQ_PLATFORM="unknown" ;;
  esac
}

# --- File age (seconds since modification) ---

cq_file_age() {
  local file="$1"
  local mtime now
  now=$(cq_epoch)
  if [[ "$CQ_PLATFORM" == "macos" ]]; then
    mtime=$(stat -f %m "$file" 2>/dev/null || echo "$now")
  else
    mtime=$(stat -c %Y "$file" 2>/dev/null || echo "$now")
  fi
  echo $((now - mtime))
}

# --- Marker display ---

cq_marker() {
  local status="$1"
  local config
  config=$(cq_resolve_config)
  jq -r --arg s "$status" '.markers[$s] // "?"' <<< "$config"
}

# --- Agent target mapping ---

# Resolve an agent target name through the optional mapping file.
# Usage: mapped=$(cq_resolve_agent_target "code-review")
# Returns the mapped name if found, or the original name if no mapping exists.
cq_resolve_agent_target() {
  local name="$1"
  local mapping_file="${CQ_PROJECT_ROOT}/.claudekiq/agent-mapping.json"

  if [[ -f "$mapping_file" ]]; then
    local mapped
    mapped=$(jq -r --arg n "$name" '.[$n] // empty' "$mapping_file" 2>/dev/null)
    if [[ -n "$mapped" ]]; then
      echo "$mapped"
      return
    fi
  fi
  echo "$name"
}
