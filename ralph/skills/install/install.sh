#!/usr/bin/env bash
# ralph/skills/install/install.sh
# Copy Ralph into a target project repository.
#
# Usage: install.sh <target-project-path>
set -euo pipefail

RALPH_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  echo "Usage: $(basename "$0") <target-project-path>"
  echo ""
  echo "Copies the ralph/ directory into <target-project-path>/ralph/."
  echo "Safe: will not overwrite an existing ralph/ralph.yaml."
  exit 1
}

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  echo "ERROR: target path is required." >&2
  usage
fi

# Validate target is an absolute path
if [[ "$TARGET" != /* ]]; then
  echo "ERROR: target path must be absolute: $TARGET" >&2
  exit 1
fi

# Validate target exists and is a directory
if [[ ! -d "$TARGET" ]]; then
  echo "ERROR: target directory does not exist: $TARGET" >&2
  exit 1
fi

# Validate target is a git repo
if ! git -C "$TARGET" rev-parse --git-dir > /dev/null 2>&1; then
  echo "ERROR: target is not a git repository: $TARGET" >&2
  exit 1
fi

DEST="$TARGET/ralph"
YAML_DEST="$DEST/ralph.yaml"

echo "Installing Ralph from: $RALPH_SOURCE_DIR"
echo "Target:                $DEST"

RSYNC_EXCLUDES=(--exclude="skills/install/install.sh")

# Preserve existing ralph.yaml (user may have customized it)
if [[ -f "$YAML_DEST" ]]; then
  echo "NOTE: $YAML_DEST already exists — preserving it."
  RSYNC_EXCLUDES+=(--exclude="ralph.yaml")
fi

mkdir -p "$DEST"
rsync -a "${RSYNC_EXCLUDES[@]}" "$RALPH_SOURCE_DIR/" "$DEST/"

echo ""
echo "Ralph installed to: $DEST"
echo ""
echo "Next steps:"
echo "  1. Edit $DEST/ralph.yaml  — set project name, prd filename, test command"
echo "  2. Edit $DEST/AGENTS.md   — add project-specific context for agents"
echo "  3. Write your PRD:          cp $DEST/templates/PRD_template.md $TARGET/PRD.md"
echo "  4. Generate a plan:         ralph/ralph.sh --mode plan"
echo "  5. Run the build:           ralph/ralph.sh --iterations 3"
