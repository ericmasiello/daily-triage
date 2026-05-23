#!/bin/bash
# Copies the repo's lean triage skill over the installed user-level skill.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/skills/triage/SKILL.md"
DEST="$HOME/.agents/skills/eric-triage/SKILL.md"

if [ ! -f "$SRC" ]; then
  echo "Error: source not found at $SRC" >&2
  exit 1
fi

cp "$SRC" "$DEST"
echo "Copied → $DEST"
