#!/usr/bin/env bash
# install.sh — Install cq CLI
set -euo pipefail

CQ_HOME="${HOME}/.cq"
REPO_URL="${CQ_REPO_URL:-https://raw.githubusercontent.com/MelianLabs/claudekiq/main}"

echo "Installing cq..."

# Create directory structure
mkdir -p "${CQ_HOME}/bin"
mkdir -p "${CQ_HOME}/lib"
mkdir -p "${CQ_HOME}/workflows"

# Detect if running from a local repo checkout (not piped from curl)
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "bash" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [[ -n "$SCRIPT_DIR" && -d "${SCRIPT_DIR}/lib" ]]; then
  # Local install (from repo checkout)
  echo "Installing from local checkout..."
  cp "${SCRIPT_DIR}/cq" "${CQ_HOME}/bin/cq"
  cp "${SCRIPT_DIR}"/lib/*.sh "${CQ_HOME}/lib/"
  if [[ -d "${SCRIPT_DIR}/lib/commands" ]]; then
    mkdir -p "${CQ_HOME}/lib/commands"
    cp "${SCRIPT_DIR}"/lib/commands/*.sh "${CQ_HOME}/lib/commands/"
  fi
  if [[ -d "${SCRIPT_DIR}/skills" ]]; then
    mkdir -p "${CQ_HOME}/skills"
    cp -r "${SCRIPT_DIR}"/skills/* "${CQ_HOME}/skills/"
  fi
else
  # Remote install (curl pipe or no local files)
  echo "Downloading from ${REPO_URL}..."
  curl -fsSL "${REPO_URL}/cq" -o "${CQ_HOME}/bin/cq"
  for lib in core.sh yaml.sh storage.sh schema.sh mcp.sh; do
    curl -fsSL "${REPO_URL}/lib/${lib}" -o "${CQ_HOME}/lib/${lib}"
  done
  mkdir -p "${CQ_HOME}/lib/commands"
  for cmd_lib in setup.sh scan.sh lifecycle.sh flow.sh steps.sh todos.sh ctx.sh dynamic.sh workflows.sh config.sh maintenance.sh; do
    curl -fsSL "${REPO_URL}/lib/commands/${cmd_lib}" -o "${CQ_HOME}/lib/commands/${cmd_lib}"
  done
  mkdir -p "${CQ_HOME}/skills/cq"
  curl -fsSL "${REPO_URL}/skills/cq/SKILL.md" -o "${CQ_HOME}/skills/cq/SKILL.md"
  mkdir -p "${CQ_HOME}/skills/cq-agent"
  curl -fsSL "${REPO_URL}/skills/cq-agent/SKILL.md" -o "${CQ_HOME}/skills/cq-agent/SKILL.md"
  mkdir -p "${CQ_HOME}/skills/cq-workers"
  curl -fsSL "${REPO_URL}/skills/cq-workers/SKILL.md" -o "${CQ_HOME}/skills/cq-workers/SKILL.md"
  mkdir -p "${CQ_HOME}/skills/cq-setup"
  curl -fsSL "${REPO_URL}/skills/cq-setup/SKILL.md" -o "${CQ_HOME}/skills/cq-setup/SKILL.md"
fi

chmod +x "${CQ_HOME}/bin/cq"

# Create default config if not exists
if [[ ! -f "${CQ_HOME}/config.json" ]]; then
  cat > "${CQ_HOME}/config.json" <<'JSON'
{
  "prefix": "cq",
  "ttl": 2592000,
  "default_priority": "normal",
  "concurrency": 1
}
JSON
fi

echo ""
echo "cq installed to ${CQ_HOME}/bin/cq"
echo ""

# Detect shell and print PATH instructions
SHELL_NAME=$(basename "${SHELL:-/bin/bash}")
case "$SHELL_NAME" in
  bash)
    echo "Add to your ~/.bashrc or ~/.bash_profile:"
    echo "  export PATH=\"${CQ_HOME}/bin:\$PATH\""
    ;;
  zsh)
    echo "Add to your ~/.zshrc:"
    echo "  export PATH=\"${CQ_HOME}/bin:\$PATH\""
    ;;
  fish)
    echo "Run:"
    echo "  fish_add_path ${CQ_HOME}/bin"
    ;;
  *)
    echo "Add ${CQ_HOME}/bin to your PATH"
    ;;
esac

echo ""

# Verify installation
"${CQ_HOME}/bin/cq" version
