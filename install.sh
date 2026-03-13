#!/usr/bin/env bash
# install.sh — Install cq CLI
set -euo pipefail

CQ_HOME="${HOME}/.cq"
REPO_URL="${CQ_REPO_URL:-https://raw.githubusercontent.com/claudekiq/claudekiq/main}"

echo "Installing cq..."

# Create directory structure
mkdir -p "${CQ_HOME}/bin"
mkdir -p "${CQ_HOME}/lib"
mkdir -p "${CQ_HOME}/workflows"

# Download or copy files
if [[ -d "$(dirname "$0")/lib" ]]; then
  # Local install (from repo checkout)
  cp "$(dirname "$0")/cq" "${CQ_HOME}/bin/cq"
  cp "$(dirname "$0")"/lib/*.sh "${CQ_HOME}/lib/"
else
  # Remote install
  curl -sSL "${REPO_URL}/cq" -o "${CQ_HOME}/bin/cq"
  for lib in core.sh yaml.sh storage.sh commands.sh schema.sh; do
    curl -sSL "${REPO_URL}/lib/${lib}" -o "${CQ_HOME}/lib/${lib}"
  done
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
