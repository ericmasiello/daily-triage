#!/bin/bash
#
# generate-compile-commands.sh
#
# Generates a compile_commands.json at the project root so that sourcekit-lsp
# (used by Zed, VS Code, Neovim, etc.) can resolve cross-file Swift symbols.
#
# WHY THIS EXISTS:
#   This project compiles with bare `swiftc Sources/*.swift` — no SPM
#   Package.swift, no Xcode project. Without build-system metadata,
#   sourcekit-lsp treats each .swift file in isolation and cannot resolve
#   types/functions defined in other files (red squiggles everywhere).
#   compile_commands.json tells the LSP that all Sources/*.swift files
#   belong to the same compilation unit.
#
# USAGE:
#   ./generate-compile-commands.sh
#
# WHEN TO RE-RUN:
#   After adding or removing any .swift file in Sources/.
#   Then restart the editor's LSP server (or reopen the project).
#
# OUTPUT:
#   compile_commands.json  (gitignored — contains machine-specific absolute paths)
#

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$PROJECT_DIR/Sources"
OUTPUT="$PROJECT_DIR/compile_commands.json"

swift_files=()
for f in "$SOURCE_DIR"/*.swift; do
  [ -f "$f" ] && swift_files+=("$f")
done

if [ ${#swift_files[@]} -eq 0 ]; then
  echo "No .swift files found in $SOURCE_DIR" >&2
  exit 1
fi

args_json=""
for f in "${swift_files[@]}"; do
  args_json+="      \"$f\","$'\n'
done
args_json="${args_json%,$'\n'}"

echo "[" > "$OUTPUT"
for i in "${!swift_files[@]}"; do
  file="${swift_files[$i]}"
  relative="${file#$PROJECT_DIR/}"

  cat >> "$OUTPUT" <<EOF
  {
    "directory": "$PROJECT_DIR",
    "arguments": [
      "swiftc",
      "-parse-as-library",
$args_json
    ],
    "file": "$relative",
    "output": "$PROJECT_DIR/triage-cache"
  }
EOF

  if [ "$i" -lt $(( ${#swift_files[@]} - 1 )) ]; then
    sed -i '' -e '$ s/$/,/' "$OUTPUT"
  fi
done
echo "]" >> "$OUTPUT"

echo "Generated $OUTPUT with ${#swift_files[@]} entries"
