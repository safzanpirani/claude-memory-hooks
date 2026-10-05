#!/usr/bin/env bash
# read-memory.sh — print (and locate for writing) Claude Code's auto-memory for a project.
#
# Claude Code stores per-project memory under:
#   ~/.claude/projects/<slug>/memory/
# The project root is the canonical git root (the main checkout, so every
# worktree shares one memory), or the directory itself outside git. <slug> is
# that absolute path with every non-alphanumeric character replaced by "-"
# (e.g. /Users/x/Development/linuxsync -> -Users-x-Development-linuxsync).
#
# When the project has no memory yet, the script falls back to the nearest
# ancestor project's memory and labels it as an ancestor. New memory for the
# project still belongs in the project's own directory (see --dir).
#
# Usage:
#   read-memory.sh [DIR]          # index + file list + drift check (default)
#   read-memory.sh --all [DIR]    # index + the full text of every memory file
#   read-memory.sh --index [DIR]  # only MEMORY.md
#   read-memory.sh --list [DIR]   # only the file paths, no contents
#   read-memory.sh --dir [DIR]    # print the project's own memory dir (write target)
# DIR defaults to $PWD.

set -euo pipefail

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

mode="default"
case "${1:-}" in
  --all|--full) mode="all";   shift ;;
  --index)      mode="index"; shift ;;
  --list)       mode="list";  shift ;;
  --dir)        mode="dir";   shift ;;
  --help|-h)
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  -*) echo "Unknown flag: $1 (see --help)" >&2; exit 2 ;;
esac

target="${1:-$PWD}"
if [ ! -d "$target" ]; then
  echo "Not a directory: $target" >&2
  exit 2
fi
target="$(cd "$target" && pwd -P)"

# Canonical git root: the main worktree's top level, so worktrees share memory.
root="$target"
if common="$(git -C "$target" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
  case "$common" in
    */.git) root="$(dirname "$common")" ;;
    *) root="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null || echo "$target")" ;;
  esac
fi
# Git Bash/Cygwin on Windows: Claude Code slugs the native path (C:/x -> C--x).
if command -v cygpath >/dev/null 2>&1; then
  root="$(cygpath -m "$root")"
fi

slugify() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
memdir_for() { printf '%s/projects/%s/memory' "$CLAUDE_HOME" "$(slugify "$1")"; }
has_memory() { [ -n "$(find "$1" -maxdepth 1 -type f -name '*.md' 2>/dev/null | head -1)" ]; }

own="$(memdir_for "$root")"
if [ "${#own}" -gt $(( ${#CLAUDE_HOME} + 10 + 200 + 7 )) ]; then
  echo "Warning: project path slug exceeds 200 chars; Claude Code hashes it, so this path may be wrong." >&2
fi

if [ "$mode" = "dir" ]; then
  echo "$own"
  exit 0
fi

memdir=""
source_dir="$root"
if has_memory "$own"; then
  memdir="$own"
else
  dir="$(dirname "$root")"
  while :; do
    if has_memory "$(memdir_for "$dir")"; then
      memdir="$(memdir_for "$dir")"; source_dir="$dir"; break
    fi
    parent="$(dirname "$dir")"
    [ "$parent" = "$dir" ] && break
    dir="$parent"
  done
fi

if [ -z "$memdir" ]; then
  echo "No Claude project memory for '$root' or any ancestor." >&2
  echo "Write new memory to: $own" >&2
  exit 1
fi

index="$memdir/MEMORY.md"
facts() { find "$memdir" -maxdepth 1 -type f -name '*.md' ! -name 'MEMORY.md' | sort; }

if [ "$mode" = "list" ]; then
  [ -f "$index" ] && echo "$index"
  facts
  exit 0
fi

echo "# Project memory: $memdir"
if [ "$memdir" != "$own" ]; then
  echo "# NOTE: no memory exists for $root. This is the nearest ancestor's memory"
  echo "# ($source_dir). Treat it as background. Write new memory for this project to:"
  echo "#   $own"
fi
echo

if [ -f "$index" ]; then
  echo "===== MEMORY.md (index) ====="
  cat "$index"
  echo
else
  echo "(no MEMORY.md index in this directory)"
  echo
fi

[ "$mode" = "index" ] && exit 0

if [ "$mode" = "all" ]; then
  while IFS= read -r f; do
    echo "===== $(basename "$f") ====="
    cat "$f"
    echo
  done < <(facts)
else
  echo "===== memory files (read the ones relevant to the task) ====="
  facts
  echo
fi

# Drift check: index links to missing files, and files the index never mentions.
drift=""
if [ -f "$index" ]; then
  while IFS= read -r link; do
    case "$link" in http*|/*|../*) continue ;; esac
    [ -f "$memdir/$link" ] || drift+="  index links missing file: $link"$'\n'
  done < <(grep -oE '\]\([^)#]+\.md\)' "$index" | sed -E 's/^\]\(//; s/\)$//' | sort -u)
  while IFS= read -r f; do
    grep -qF "$(basename "$f")" "$index" || drift+="  not in index: $(basename "$f")"$'\n'
  done < <(facts)
fi
if [ -n "$drift" ]; then
  echo "===== index drift (fix while you are here) ====="
  printf '%s' "$drift"
fi
