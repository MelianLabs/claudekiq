#!/usr/bin/env bash
# PostToolUse hook — detect cq gate events and fire desktop notifications.
# Claude Code passes hook input as JSON on stdin.
# Fields: tool_name, tool_input, tool_response, tool_use_id

set -euo pipefail

# Read JSON input from stdin
input_json=$(cat)

tool_name=$(echo "$input_json" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[[ "$tool_name" == "Bash" ]] || exit 0

command_str=$(echo "$input_json" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
tool_output=$(echo "$input_json" | jq -r '.tool_response // empty' 2>/dev/null) || exit 0

# Helper: send desktop notification (macOS or Linux)
notify() {
  local title="$1" message="$2" sound="${3:-Ping}"
  if command -v osascript &>/dev/null; then
    osascript -e "display notification \"$message\" with title \"$title\" sound name \"$sound\"" &>/dev/null &
  elif command -v notify-send &>/dev/null; then
    notify-send "$title" "$message" &>/dev/null &
  fi
}

# Only care about cq step-done and cq todos commands
case "$command_str" in
  *"cq step-done"*)
    # Parse the status from step-done JSON output
    status=$(echo "$tool_output" | jq -r '.meta.status // empty' 2>/dev/null) || status=""
    step=$(echo "$tool_output" | jq -r '.step // "unknown"' 2>/dev/null) || step="unknown"

    case "$status" in
      gated)
        notify "cq: Gate Reached" "Step '$step' needs approval" "Ping"
        ;;
      completed)
        notify "cq: Workflow Complete" "Workflow finished successfully" "Glass"
        ;;
      failed)
        notify "cq: Workflow Failed" "Failed at step '$step'" "Basso"
        ;;
    esac
    ;;
  *"cq todos"*)
    todo_count=$(echo "$tool_output" | jq -r 'if type == "array" then [.[] | select(.status == "pending")] | length else 0 end' 2>/dev/null) || todo_count=0
    if [[ "$todo_count" -gt 0 ]]; then
      notify "cq: TODOs Pending" "$todo_count pending TODO(s) need attention" "Ping"
    fi
    ;;
esac

exit 0
