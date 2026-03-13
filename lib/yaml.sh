#!/usr/bin/env bash
# yaml.sh — YAML-to-JSON conversion via yq

cq_yaml_to_json() {
  local file="$1"
  [[ -f "$file" ]] || cq_die "YAML file not found: ${file}"
  yq -o json "$file" 2>/dev/null || cq_die "Failed to parse YAML: ${file}"
}
