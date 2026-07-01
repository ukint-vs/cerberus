#!/usr/bin/env bash
# Cerberus — install script
# Creates ~/.cerberus/, symlinks scripts, seeds learned index.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CERBERUS_DIR="$HOME/.cerberus"
HERMES_SCRIPTS="$HOME/.hermes/scripts"

echo "📁 Installing Cerberus to $CERBERUS_DIR"

# Create directories
mkdir -p "$CERBERUS_DIR/projects"
mkdir -p "$CERBERUS_DIR/learned"
mkdir -p "$CERBERUS_DIR/lib"
mkdir -p "$HERMES_SCRIPTS"

# Copy library
echo "  → lib/context.sh"
cp "$REPO_DIR/lib/context.sh" "$CERBERUS_DIR/lib/context.sh"
chmod 644 "$CERBERUS_DIR/lib/context.sh"

# Symlink scripts
for script in van-review-check.sh van-reviewer-check.sh; do
  echo "  → symlink ~/.hermes/scripts/$script"
  if [ -f "$HERMES_SCRIPTS/$script" ]; then
    echo "    ⚠️  $script already exists — backing up to ${script}.bak"
    mv "$HERMES_SCRIPTS/$script" "$HERMES_SCRIPTS/${script}.bak"
  fi
  ln -sf "$REPO_DIR/scripts/$script" "$HERMES_SCRIPTS/$script"
  chmod +x "$REPO_DIR/scripts/$script"
done

# Copy learned skills
if [ -z "$(ls -A "$CERBERUS_DIR/learned" 2>/dev/null)" ]; then
  echo "  → seed learned skills"
  cp "$REPO_DIR"/learned/*.md "$CERBERUS_DIR/learned/" 2>/dev/null || true
  chmod 644 "$CERBERUS_DIR"/learned/*.md 2>/dev/null || true
else
  echo "  → learned/ already has content — skipping seed (merge manually if needed)"
fi

# Generate indices
echo "  → generate indices"
source "$CERBERUS_DIR/lib/context.sh"
learned_index_refresh 2>/dev/null || true
# Project index will be generated on first cron run

echo ""
echo "✅ Cerberus installed."
echo ""
echo "Next steps:"
echo "  1. Configure Hermes cronjobs (see README.md)"
echo "  2. Verify: bash -n $HERMES_SCRIPTS/van-review-check.sh"
echo "  3. Verify: source $CERBERUS_DIR/lib/context.sh && learned_list"
echo ""
echo "Learned skills index: $CERBERUS_DIR/learned/index.json"
