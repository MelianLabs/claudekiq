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

# Output a natural language hint for Claude to pick up on next actions.
# Only in non-JSON mode; hints go to stderr to not pollute machine output.
cq_hint() {
  [[ "$CQ_JSON" == "true" ]] && return
  echo "  → $*" >&2
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

# --- Array helper ---

# Convert a bash array of JSON objects into a JSON array.
# Usage: local -a items=(...); cq_items_to_json "${items[@]}"
# Returns "[]" if no arguments passed.
cq_items_to_json() {
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$@" | jq -s '.'
  else
    echo '[]'
  fi
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

# Replace {{expr}} references with values from a JSON context object.
# Supports nested access ({{config.timeout}}), array indexing ({{items[0].name}}),
# and jq expressions ({{results | length}}). Backward compatible with flat keys.
# Usage: cq_interpolate "template string" '{"key":"value"}'
cq_interpolate() {
  local template="$1"
  local ctx_json="$2"
  local result="$template"

  # Extract all {{expr}} patterns using grep (handles special chars better than bash regex)
  local -a exprs=()
  local expr
  while IFS= read -r expr; do
    [[ -z "$expr" ]] && continue
    # Deduplicate
    local found=false e
    for e in "${exprs[@]+"${exprs[@]}"}"; do
      [[ "$e" == "$expr" ]] && { found=true; break; }
    done
    $found || exprs+=("$expr")
  done < <(printf '%s' "$template" | grep -o '{{[^}]*}}' | sed 's/^{{//;s/}}$//')

  [[ ${#exprs[@]} -eq 0 ]] && { echo "$template"; return; }

  # Resolve each expression individually via jq
  for expr in "${exprs[@]}"; do
    local val
    val=$(jq -r "try (.${expr} // empty | tostring) catch empty" <<< "$ctx_json" 2>/dev/null) || val=""
    # Use awk index() for literal string matching (no regex interpretation)
    local pattern="{{${expr}}}"
    result=$(awk -v pat="$pattern" -v rep="$val" '
      { while ((i = index($0, pat)) > 0) {
          $0 = substr($0, 1, i-1) rep substr($0, i + length(pat))
        }
        print
      }' <<< "$result")
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
  "step_fields": ["name", "type", "target", "prompt", "context", "args_template", "gate", "model", "background", "resume", "outputs"],
  "models": ["opus", "sonnet", "haiku"],
  "default_model": "opus",
  "edge_keys": ["next", "on_pass", "on_fail"],
  "notifications": {
    "on_gate": null,
    "on_fail": null,
    "on_complete": null,
    "on_start": null
  },
  "safety": "strict",
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

  local current_step="" template="" run_status=""
  if [[ -f "${run_dir}/meta.json" ]]; then
    local _meta
    _meta=$(cat "${run_dir}/meta.json" 2>/dev/null)
    if [[ -n "$_meta" ]]; then
      current_step=$(jq -r '.current_step // ""' <<< "$_meta")
      template=$(jq -r '.template // ""' <<< "$_meta")
      run_status=$(jq -r '.status // ""' <<< "$_meta")
    fi
  fi

  # Emit structured JSON event to stderr for Claude Code hooks to parse
  jq -cn --arg hook "$hook_name" --arg run_id "$run_id" \
    --arg step "$current_step" --arg template "$template" \
    --arg status "$run_status" --arg version "$CQ_VERSION" \
    --arg timestamp "$(cq_now)" \
    '{event: "cq_hook", version: $version, hook: $hook, run_id: $run_id, step: $step, template: $template, status: $status, timestamp: $timestamp}' >&2

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

# --- Safety policy ---

# Read the safety policy for a specific operation.
# Returns "block" or "warn". Handles both string and map formats.
# Usage: policy=$(cq_safety_policy "git_commit")
cq_safety_policy() {
  local operation="$1"
  local settings_file="${CQ_PROJECT_ROOT}/.claudekiq/settings.json"
  local safety_val

  if [[ -f "$settings_file" ]]; then
    safety_val=$(jq -r '.safety // "strict"' "$settings_file" 2>/dev/null || echo "strict")
  else
    safety_val="strict"
  fi

  # If safety is a string (backward compat), expand to default policy
  case "$safety_val" in
    strict)  echo "block"; return ;;
    relaxed) echo "warn"; return ;;
  esac

  # If safety is an object, look up the specific operation from the already-read value
  local policy
  policy=$(jq -r --arg op "$operation" '.[$op] // empty' <<< "$safety_val" 2>/dev/null)
  if [[ -n "$policy" ]]; then
    echo "$policy"
  else
    # Default to block for unknown operations
    echo "block"
  fi
}

# --- Context builders ---

# Resolve context_builders for a step and return assembled markdown context.
# Usage: cq_resolve_context_builders <run_id> <step_id>
cq_resolve_context_builders() {
  local run_id="$1" step_id="$2"
  local step builders_json result=""
  step=$(cq_get_step "$run_id" "$step_id")
  builders_json=$(jq -r '.context_builders // []' <<< "$step")
  [[ "$builders_json" == "[]" ]] && return 0

  local count i builder_type
  count=$(jq 'length' <<< "$builders_json")
  for ((i=0; i<count; i++)); do
    local builder
    builder=$(jq --argjson i "$i" '.[$i]' <<< "$builders_json")
    builder_type=$(jq -r '.type' <<< "$builder")

    case "$builder_type" in
      git_diff)
        local diff
        diff=$(git diff HEAD 2>/dev/null | head -200 || true)
        [[ -n "$diff" ]] && result="${result}"$'\n\n'"## Git Diff"$'\n'"\`\`\`"$'\n'"${diff}"$'\n'"\`\`\`"
        ;;
      error_context)
        local prev_error
        prev_error=$(jq -r --arg id "$step_id" '.[$id].error_output // empty' "$(cq_run_dir "$run_id")/state.json" 2>/dev/null)
        [[ -n "$prev_error" ]] && result="${result}"$'\n\n'"## Previous Error"$'\n'"\`\`\`"$'\n'"${prev_error}"$'\n'"\`\`\`"
        ;;
      file_contents)
        local paths
        paths=$(jq -r '.paths // [] | .[]' <<< "$builder")
        while IFS= read -r path; do
          [[ -z "$path" ]] && continue
          if [[ -f "$path" ]]; then
            local content
            content=$(head -100 "$path")
            result="${result}"$'\n\n'"## File: ${path}"$'\n'"\`\`\`"$'\n'"${content}"$'\n'"\`\`\`"
          fi
        done <<< "$paths"
        ;;
      test_output|command_output)
        local cmd
        cmd=$(jq -r '.command // empty' <<< "$builder")
        if [[ -n "$cmd" ]]; then
          local output
          output=$(eval "$cmd" 2>&1 | tail -50 || true)
          [[ -n "$output" ]] && result="${result}"$'\n\n'"## Output: ${cmd}"$'\n'"\`\`\`"$'\n'"${output}"$'\n'"\`\`\`"
        fi
        ;;
    esac
  done

  printf '%s' "$result"
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

# --- Model validation ---

# Check if a model name is valid (known model or configured in settings)
cq_valid_model() {
  local model="$1"
  [[ -z "$model" ]] && return 1

  # Check against built-in models
  local config models
  config=$(cq_resolve_config)
  models=$(jq -r '.models // [] | .[]' <<< "$config")
  while IFS= read -r m; do
    [[ "$model" == "$m" ]] && return 0
  done <<< "$models"

  return 1
}

# Build a complete prompt for an agent step by assembling the step's raw prompt
# field with raw context values. No interpolation — Claude decides how to use context.
# Usage: cq_build_step_prompt <step_json> <ctx_json>
cq_build_step_prompt() {
  local step_json="$1" ctx_json="$2"

  local prompt context_keys
  prompt=$(jq -r '.prompt // empty' <<< "$step_json")
  context_keys=$(jq -r '.context // [] | .[]' <<< "$step_json")

  # Start with the raw step prompt (no interpolation for agent steps)
  local result=""
  if [[ -n "$prompt" ]]; then
    result="$prompt"
  fi

  # Append raw context key values if specified
  if [[ -n "$context_keys" ]]; then
    local ctx_section=""
    local key
    while IFS= read -r key; do
      [[ -z "$key" ]] && continue
      local val
      val=$(jq -r --arg k "$key" '.[$k] // empty' <<< "$ctx_json" 2>/dev/null)
      if [[ -n "$val" ]]; then
        ctx_section="${ctx_section}\n${key}: ${val}"
      fi
    done <<< "$context_keys"
    if [[ -n "$ctx_section" ]]; then
      result="${result}\n\nContext:${ctx_section}"
    fi
  fi

  printf '%b' "$result"
}

# --- Step type resolution ---

# Resolve a step type to its handler kind.
# Returns: "builtin", "agent", or "unknown"
# Usage: kind=$(cq_resolve_step_type "deploy")
cq_resolve_step_type() {
  local step_type="$1"

  # 1. Built-in types
  case "$step_type" in
    bash|agent|skill|parallel|batch|workflow) echo "builtin"; return ;;
  esac

  # 2. Agent-backed: .claude/agents/<type>.md
  if [[ -f "${CQ_PROJECT_ROOT}/.claude/agents/${step_type}.md" ]]; then
    echo "agent"; return
  fi

  # 3. Check scan results for agents
  local settings="${CQ_PROJECT_ROOT}/.claudekiq/settings.json"
  if [[ -f "$settings" ]]; then
    local found
    found=$(jq -r --arg t "$step_type" '
      if (.agents // [] | map(.name) | index($t)) then "agent"
      else empty end' "$settings" 2>/dev/null)
    if [[ -n "$found" ]]; then echo "$found"; return; fi
  fi

  echo "convention"
}

# --- Agent target mapping ---

# Resolve an agent target name through agent_mappings in settings.json.
# Usage: mapped=$(cq_resolve_agent_target "code-review")
# Returns the mapped name if found, or the original name if no mapping exists.
cq_resolve_agent_target() {
  local name="$1"
  local settings_file="${CQ_PROJECT_ROOT}/.claudekiq/settings.json"

  if [[ -f "$settings_file" ]]; then
    local mapped
    mapped=$(jq -r --arg n "$name" '.agent_mappings[$n] // empty' "$settings_file" 2>/dev/null)
    if [[ -n "$mapped" ]]; then
      echo "$mapped"
      return
    fi
  fi
  echo "$name"
}
