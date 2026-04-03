#!/usr/bin/env bash
# tracker.sh — Automatic issue tracker commenting on workflow events
#
# Supports: github (via gh CLI), litetracker (via lt CLI), custom (shell command)
#
# Configuration (in workflow YAML or settings.json):
#
#   tracker:
#     type: github                # github | litetracker | custom
#     repo: owner/repo            # github: repository
#     issue: "{{issue_number}}"   # interpolated issue reference
#     project: "{{project_id}}"   # litetracker: project ID
#     story: "{{story_id}}"       # litetracker: story ID
#     events:                     # which events trigger comments (default: all)
#       - step_done
#       - complete
#       - fail
#     command: "..."              # custom: shell command template
#
# Per-step opt-out: add `tracker: false` to any step definition.
#
# The tracker is disabled by default. It only activates when a `tracker`
# block with an explicit `type` is present in the workflow or settings.

# --- Tracker resolution ---

# Resolve tracker config: workflow-level overrides settings-level
# Returns JSON tracker config or empty string if none configured
cq_resolve_tracker() {
  local run_id="$1"
  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  # Try workflow-level tracker config first
  local template
  template=$(jq -r '.template // ""' "${run_dir}/meta.json")
  local workflow_tracker=""

  if [[ -n "$template" ]]; then
    local wf_file
    wf_file=$(cq_find_workflow "$template" 2>/dev/null || true)
    if [[ -n "$wf_file" && -f "$wf_file" ]]; then
      workflow_tracker=$(yq -o=json '.tracker' "$wf_file" 2>/dev/null || true)
    fi
  fi

  if [[ -n "$workflow_tracker" && "$workflow_tracker" != "null" ]]; then
    echo "$workflow_tracker"
    return
  fi

  # Fall back to settings-level tracker config
  local config
  config=$(cq_resolve_config)
  local settings_tracker
  settings_tracker=$(echo "$config" | jq '.tracker // empty')

  if [[ -n "$settings_tracker" && "$settings_tracker" != "null" ]]; then
    echo "$settings_tracker"
    return
  fi
}

# Check if a specific event is enabled for this tracker config
# Usage: cq_tracker_event_enabled "$tracker_json" "step_done"
_tracker_event_enabled() {
  local tracker_json="$1"
  local event="$2"

  local events_type
  events_type=$(echo "$tracker_json" | jq -r '.events | type')

  # If no events field, all events are enabled by default
  if [[ "$events_type" != "array" ]]; then
    return 0
  fi

  # Check if event is in the array
  echo "$tracker_json" | jq -e --arg e "$event" '.events | index($e) != null' >/dev/null 2>&1
}

# Check if a step has opted out of tracker comments
# Usage: _step_tracker_enabled "$run_id" "$step_id"
_step_tracker_enabled() {
  local run_id="$1" step_id="$2"

  local step
  step=$(cq_get_step "$run_id" "$step_id" 2>/dev/null || echo '{}')
  local val
  val=$(echo "$step" | jq -r 'if has("tracker") then .tracker else "true" end')

  [[ "$val" != "false" ]]
}

# --- Comment formatting ---

_tracker_step_done_body() {
  local run_id="$1" step_id="$2" step_name="$3" outcome="$4" visits="$5"
  local marker

  if [[ "$outcome" == "pass" ]]; then
    marker="$(cq_marker "passed")"
  else
    marker="$(cq_marker "failed")"
  fi

  local template
  template=$(jq -r '.template // ""' "$(cq_run_dir "$run_id")/meta.json")

  cat <<EOF
${marker} **${step_name}** — ${outcome} (visit #${visits})
> Workflow: \`${template}\` · Run: \`${run_id}\` · Step: \`${step_id}\`
EOF
}

_tracker_complete_body() {
  local run_id="$1"
  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  local template
  template=$(jq -r '.template // ""' "${run_dir}/meta.json")

  # Build step summary
  local state summary=""
  state=$(cq_read_state "$run_id")
  local step_ids
  step_ids=$(echo "$state" | jq -r 'keys[]')

  while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue
    local st
    st=$(echo "$state" | jq -r --arg id "$sid" '.[$id].status // "pending"')
    local m
    m=$(cq_marker "$st")
    summary="${summary}${m} \`${sid}\`  "
  done <<< "$step_ids"

  cat <<EOF
$(cq_marker "completed") **Workflow completed**
> Workflow: \`${template}\` · Run: \`${run_id}\`

${summary}
EOF
}

_tracker_fail_body() {
  local run_id="$1" step_id="$2" reason="${3:-}"
  local run_dir
  run_dir=$(cq_run_dir "$run_id")

  local template
  template=$(jq -r '.template // ""' "${run_dir}/meta.json")

  local body
  body="$(cq_marker "failed") **Workflow failed** at step \`${step_id}\`"
  body="${body}
> Workflow: \`${template}\` · Run: \`${run_id}\`"

  if [[ -n "$reason" ]]; then
    body="${body}
> Reason: ${reason}"
  fi

  echo "$body"
}

# --- Tracker dispatch ---

# Post a comment to the configured tracker
# Usage: _tracker_post "$tracker_json" "$ctx_json" "$body"
_tracker_post() {
  local tracker_json="$1"
  local ctx_json="$2"
  local body="$3"

  local tracker_type
  tracker_type=$(echo "$tracker_json" | jq -r '.type // empty')

  case "$tracker_type" in
    github)
      _tracker_post_github "$tracker_json" "$ctx_json" "$body"
      ;;
    litetracker)
      _tracker_post_litetracker "$tracker_json" "$ctx_json" "$body"
      ;;
    custom)
      _tracker_post_custom "$tracker_json" "$ctx_json" "$body"
      ;;
    *)
      cq_warn "Unknown tracker type: ${tracker_type}"
      ;;
  esac
}

_tracker_post_github() {
  local tracker_json="$1"
  local ctx_json="$2"
  local body="$3"

  local repo issue_template issue

  repo=$(echo "$tracker_json" | jq -r '.repo // empty')
  issue_template=$(echo "$tracker_json" | jq -r '.issue // "{{issue_number}}"')
  issue=$(cq_interpolate "$issue_template" "$ctx_json")

  if [[ -z "$issue" || "$issue" == "null" ]]; then
    return 0  # No issue to comment on
  fi

  local cmd="gh issue comment ${issue} --body $(printf '%q' "$body")"
  if [[ -n "$repo" ]]; then
    cmd="${cmd} --repo ${repo}"
  fi

  eval "$cmd" >/dev/null 2>&1 || true
}

_tracker_post_litetracker() {
  local tracker_json="$1"
  local ctx_json="$2"
  local body="$3"

  local project_template story_template project_id story_id

  project_template=$(echo "$tracker_json" | jq -r '.project // "{{project_id}}"')
  story_template=$(echo "$tracker_json" | jq -r '.story // "{{story_id}}"')

  project_id=$(cq_interpolate "$project_template" "$ctx_json")
  story_id=$(cq_interpolate "$story_template" "$ctx_json")

  if [[ -z "$project_id" || "$project_id" == "null" ]]; then
    return 0
  fi
  if [[ -z "$story_id" || "$story_id" == "null" ]]; then
    return 0
  fi

  lt story comment "$project_id" "$story_id" --text "$body" >/dev/null 2>&1 || true
}

_tracker_post_custom() {
  local tracker_json="$1"
  local ctx_json="$2"
  local body="$3"

  local cmd_template
  cmd_template=$(echo "$tracker_json" | jq -r '.command // empty')
  if [[ -z "$cmd_template" ]]; then
    cq_warn "Custom tracker: no command configured"
    return 0
  fi

  # Add body to context for interpolation
  local enriched_ctx
  enriched_ctx=$(echo "$ctx_json" | jq --arg tracker_body "$body" '. + {tracker_body: $tracker_body}')

  local interpolated
  interpolated=$(cq_interpolate "$cmd_template" "$enriched_ctx")

  eval "$interpolated" >/dev/null 2>&1 || true
}

# --- Public API ---

# Fire tracker comment for an event
# Usage: cq_fire_tracker "step_done" "$run_id" "$step_id" "$step_name" "$outcome" "$visits"
#        cq_fire_tracker "complete" "$run_id"
#        cq_fire_tracker "fail" "$run_id" "$step_id" "$reason"
cq_fire_tracker() {
  local event="$1"
  local run_id="$2"
  shift 2

  # Resolve tracker config — tracker is disabled unless explicitly configured with a type
  local tracker_json
  tracker_json=$(cq_resolve_tracker "$run_id")
  [[ -z "$tracker_json" ]] && return 0

  # Require an explicit type to activate — prevents accidental firing from empty config
  local tracker_type
  tracker_type=$(echo "$tracker_json" | jq -r '.type // empty')
  [[ -z "$tracker_type" ]] && return 0

  # Check if event is enabled
  _tracker_event_enabled "$tracker_json" "$event" || return 0

  # Build context for interpolation
  local run_dir ctx_json
  run_dir=$(cq_run_dir "$run_id")
  if [[ -f "${run_dir}/ctx.json" ]]; then
    ctx_json=$(cat "${run_dir}/ctx.json")
  else
    ctx_json='{}'
  fi
  ctx_json=$(echo "$ctx_json" | jq --arg rid "$run_id" '. + {run_id: $rid}')

  local body=""

  case "$event" in
    step_done)
      local step_id="$1" step_name="$2" outcome="$3" visits="$4"

      # Check per-step opt-out
      _step_tracker_enabled "$run_id" "$step_id" || return 0

      body=$(_tracker_step_done_body "$run_id" "$step_id" "$step_name" "$outcome" "$visits")
      ;;
    complete)
      body=$(_tracker_complete_body "$run_id")
      ;;
    fail)
      local step_id="${1:-}" reason="${2:-}"
      body=$(_tracker_fail_body "$run_id" "$step_id" "$reason")
      ;;
    *)
      return 0
      ;;
  esac

  [[ -z "$body" ]] && return 0

  _tracker_post "$tracker_json" "$ctx_json" "$body"
}
