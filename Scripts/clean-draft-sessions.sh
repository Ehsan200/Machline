#!/bin/bash
# Removes commit-draft transcripts the CLI recorded as sessions.
#
# Machline now runs those drafts in a scratch directory and deletes them, but builds before that
# filed them under whatever repository was being committed to. They are hidden from the session
# list either way; this deletes them.
#
# Prints what it would remove and asks first. `--yes` skips the prompt.
set -euo pipefail

STORE="${CLAUDE_PROJECTS:-$HOME/.claude/projects}"
ASSUME_YES="${1:-}"

if [ ! -d "$STORE" ]; then
    echo "No transcript store at $STORE"
    exit 0
fi

# The prompt the app sends is the only marker these carry.
MARKER="Write a Conventional Commits message"
FOUND=()
while IFS= read -r file; do
    # Only the head: the marker is in the first user message.
    if head -c 65536 "$file" | grep -q "$MARKER"; then
        FOUND+=("$file")
    fi
done < <(find "$STORE" -name '*.jsonl' -type f)

if [ ${#FOUND[@]} -eq 0 ]; then
    echo "No commit-draft transcripts found."
    exit 0
fi

echo "Found ${#FOUND[@]} commit-draft transcript(s):"
for file in "${FOUND[@]}"; do
    echo "  $(basename "$(dirname "$file")")/$(basename "$file")"
done

if [ "$ASSUME_YES" != "--yes" ]; then
    printf '\nDelete these permanently? [y/N] '
    read -r reply
    case "$reply" in
        [yY]*) ;;
        *) echo "Left alone."; exit 0 ;;
    esac
fi

for file in "${FOUND[@]}"; do
    rm -f "$file"
done
echo "Removed ${#FOUND[@]} transcript(s)."
