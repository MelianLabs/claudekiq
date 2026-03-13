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
  local run_dir="$1" event="$2" data="$3"
  local ts
  ts=$(cq_now)
  local log_file="${run_dir}/log.jsonl"
  if [[ -n "$data" ]]; then
    printf '%s\n' "$(jq -cn --arg ts "$ts" --arg event "$event" --argjson data "$data" \
      '{ts:$ts, event:$event, data:$data}')" >> "$log_file"
  else
    printf '%s\n' "$(jq -cn --arg ts "$ts" --arg event "$event" \
      '{ts:$ts, event:$event, data:{}}')" >> "$log_file"
  fi
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
    val=$(echo "$ctx_json" | jq -r --arg k "$var" '.[$k] // ""')
    # Replace all occurrences of this specific variable
    result="${result//\{\{${var}\}\}/${val}}"
  done
  echo "$result"
}

# --- Condition evaluation ---

# Evaluate a condition string like "value1 == value2"
# Returns 0 (true) or 1 (false)
cq_evaluate_condition() {
  local condition="$1"
  local lhs op rhs

  # Trim whitespace
  condition=$(echo "$condition" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  # Parse operator
  if [[ "$condition" =~ ^(.+)[[:space:]]+(==|!=|contains|empty|not_empty)[[:space:]]*(.*)?$ ]]; then
    lhs=$(echo "${BASH_REMATCH[1]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    op="${BASH_REMATCH[2]}"
    rhs=$(echo "${BASH_REMATCH[3]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
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
    "contains")
      [[ "$lhs" == *"$rhs"* ]]
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
    "completed": "✅"
  },
  "step_fields": ["name", "type", "target", "args_template", "gate"],
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

cq_resolve_config() {
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
  echo "$result"
}

cq_config_get() {
  local key="$1"
  local config
  config=$(cq_resolve_config)
  echo "$config" | jq -r --arg k "$key" '.[$k] // empty'
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
  local -a a=($v1) b=($v2)
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
  hook_cmd=$(echo "$config" | jq -r --arg h "$hook_name" '.notifications[$h] // empty')
  [[ -z "$hook_cmd" ]] && return 0

  local ctx_json
  if [[ -f "${run_dir}/ctx.json" ]]; then
    ctx_json=$(cat "${run_dir}/ctx.json")
  else
    ctx_json='{}'
  fi

  # Add run_id and step_id to context for interpolation
  local run_id
  run_id=$(basename "$run_dir")
  ctx_json=$(echo "$ctx_json" | jq --arg rid "$run_id" '. + {run_id: $rid}')

  if [[ -f "${run_dir}/meta.json" ]]; then
    local current_step
    current_step=$(jq -r '.current_step // ""' "${run_dir}/meta.json")
    ctx_json=$(echo "$ctx_json" | jq --arg sid "$current_step" '. + {step_id: $sid}')
  fi

  local interpolated
  interpolated=$(cq_interpolate "$hook_cmd" "$ctx_json")

  # Run in background, ignore failures
  (eval "$interpolated" &>/dev/null &)
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
  echo "$config" | jq -r --arg s "$status" '.markers[$s] // "?"'
}
