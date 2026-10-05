#!/usr/bin/env bash
# install.sh: load Claude Code's per-project memory into Droid, Codex,
# OpenCode, and Pi sessions. Run ./install.sh --help for usage.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./install.sh [options] [harness...]

Harnesses: droid, codex, opencode, pi, all.
With no harness named, installs for every harness found on this machine.

Options:
  --uninstall     remove the hooks, adapters, and installed scripts
  --dry-run       print what would change and write nothing
  --prefix DIR    install scripts under DIR
                  (default: ${XDG_DATA_HOME:-~/.local/share}/claude-memory-hooks)
  -h, --help      show this help

Environment overrides: FACTORY_HOME, CODEX_HOME, XDG_CONFIG_HOME, PI_CODING_AGENT_DIR.
EOF
}

SRC="$(cd "$(dirname "$0")" && pwd -P)"
PREFIX="${XDG_DATA_HOME:-$HOME/.local/share}/claude-memory-hooks"
action="install"
dry=0
targets=()

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) action="uninstall" ;;
    --dry-run) dry=1 ;;
    --prefix) [ $# -ge 2 ] || { echo "--prefix needs a directory" >&2; exit 2; }; PREFIX="$2"; shift ;;
    --prefix=*) PREFIX="${1#--prefix=}" ;;
    -h|--help) usage; exit 0 ;;
    all) targets=(droid codex opencode pi) ;;
    droid|codex|opencode|pi) targets+=("$1") ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq / apt install jq)." >&2; exit 1; }
case "$PREFIX" in /*) ;; *) PREFIX="$PWD/$PREFIX" ;; esac

FACTORY_DIR="${FACTORY_HOME:-$HOME/.factory}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
OPENCODE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
PI_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
HOOK="$PREFIX/bin/memory-hook"
MARKER="claude-memory-hooks"
STAMP="$(date +%Y%m%d-%H%M%S)"

say() { printf '%s\n' "$*"; }
run() { if [ "$dry" = 1 ]; then say "  would run: $*"; else "$@"; fi; }

detect() {
  local found=()
  { [ -d "$FACTORY_DIR" ] || command -v droid >/dev/null 2>&1; } && found+=(droid)
  { [ -d "$CODEX_DIR" ] || command -v codex >/dev/null 2>&1; } && found+=(codex)
  { [ -d "$OPENCODE_DIR" ] || command -v opencode >/dev/null 2>&1; } && found+=(opencode)
  { [ -d "$PI_DIR" ] || command -v pi >/dev/null 2>&1; } && found+=(pi)
  printf '%s\n' "${found[@]:-}"
}

if [ ${#targets[@]} -eq 0 ]; then
  while IFS= read -r t; do [ -n "$t" ] && targets+=("$t"); done < <(detect)
fi
if [ ${#targets[@]} -eq 0 ]; then
  say "No supported harness found (droid, codex, opencode, pi). Name one to install anyway."
  exit 1
fi

# Rewrite the SessionStart list at JSON path $2 (a jq path array) in file $1:
# drop every existing memory-hook command, then append $3 when it is non-empty.
edit_hooks() {
  local file="$1" path="$2" command="${3:-}" add='[]' original before after
  if [ -n "$command" ]; then
    add="$(jq -n --arg c "$command" '[{hooks: [{type: "command", command: $c, timeout: 10}]}]')"
  fi
  if [ -f "$file" ]; then
    original="$(jq . "$file")" || { say "  cannot parse $file as JSON; skipped"; return 1; }
  else
    [ -n "$command" ] || return 0
    original='{}'
  fi
  # Compare key-sorted copies, but write the edit of the original so key order survives.
  before="$(printf '%s' "$original" | jq -S .)"
  after="$(printf '%s' "$original" | jq --argjson p "$path" --argjson add "$add" '
    def strip: map(.hooks |= map(select((.command // "") | test("memory-hook[\"'"'"' ]|memory-hook$") | not)))
               | map(select(.hooks | length > 0));
    (getpath($p) // {}) as $events
    | ((($events.SessionStart // []) | strip) + $add) as $list
    | setpath($p; if ($list | length) > 0 then $events + {SessionStart: $list} else $events | del(.SessionStart) end)')"
  if [ "$(printf '%s' "$after" | jq -S .)" = "$before" ]; then
    say "  $file already up to date"
    return 0
  fi
  if [ "$dry" = 1 ]; then
    say "  would update $file:"
    diff <(printf '%s\n' "$before") <(printf '%s' "$after" | jq -S .) | sed 's/^/    /' || true
    return 0
  fi
  if [ -f "$file" ]; then
    cp -p "$file" "$file.bak-$MARKER-$STAMP"
    printf '%s\n' "$after" | jq . > "$file.tmp-$MARKER"
    cat "$file.tmp-$MARKER" > "$file"
    rm -f "$file.tmp-$MARKER"
    say "  updated $file (backup: $file.bak-$MARKER-$STAMP)"
  else
    mkdir -p "$(dirname "$file")"
    (umask 077; printf '%s\n' "$after" | jq . > "$file")
    say "  created $file"
  fi
}

install_scripts() {
  say "scripts -> $PREFIX"
  run mkdir -p "$PREFIX/bin" "$PREFIX/lib"
  run install -m 755 "$SRC/bin/memory-hook" "$PREFIX/bin/memory-hook"
  run install -m 755 "$SRC/lib/read-memory.sh" "$PREFIX/lib/read-memory.sh"
}

uninstall_scripts() {
  say "scripts in $PREFIX"
  [ -d "$PREFIX" ] || { say "  not installed"; return 0; }
  run rm -f "$PREFIX/bin/memory-hook" "$PREFIX/lib/read-memory.sh"
  run rmdir "$PREFIX/bin" "$PREFIX/lib" "$PREFIX" 2>/dev/null || true
}

# Copy adapter $1 to $2 with the hook path filled in, or remove it on uninstall.
place_adapter() {
  local src="$1" dest="$2"
  if [ "$action" = "uninstall" ]; then
    if [ -f "$dest" ] && grep -q "$MARKER" "$dest"; then run rm -f "$dest"; say "  removed $dest"; else say "  $dest not installed"; fi
    return 0
  fi
  local hook_escaped
  hook_escaped="$(printf '%s' "$HOOK" | sed 's/[\\&|]/\\&/g')"
  if [ "$dry" = 1 ]; then say "  would write $dest"; return 0; fi
  mkdir -p "$(dirname "$dest")"
  sed "s|__MEMORY_HOOK__|$hook_escaped|" "$src" > "$dest"
  say "  wrote $dest"
}

hook_command() { [ "$action" = "install" ] && printf "'%s' %s" "$HOOK" "$1"; return 0; }

setup_droid() {
  say "droid"
  # Droid reads hooks from hooks.json when it exists, otherwise from settings.json.
  if [ -f "$FACTORY_DIR/hooks.json" ]; then
    edit_hooks "$FACTORY_DIR/hooks.json" '[]' "$(hook_command droid)"
  else
    edit_hooks "$FACTORY_DIR/settings.json" '["hooks"]' "$(hook_command droid)"
  fi
}

setup_codex() {
  say "codex"
  edit_hooks "$CODEX_DIR/hooks.json" '["hooks"]' "$(hook_command codex)"
  if [ "$action" = "install" ]; then
    if ! grep -Eq '^[[:space:]]*hooks[[:space:]]*=[[:space:]]*true' "$CODEX_DIR/config.toml" 2>/dev/null; then
      say "  note: add 'hooks = true' under [features] in $CODEX_DIR/config.toml if Codex does not run hooks"
    fi
    say "  note: Codex asks you to trust the new hook the next time it starts"
  fi
}

setup_opencode() {
  say "opencode"
  place_adapter "$SRC/adapters/opencode/project-memory.js" "$OPENCODE_DIR/plugins/project-memory.js"
}

setup_pi() {
  say "pi"
  place_adapter "$SRC/adapters/pi/project-memory.ts" "$PI_DIR/extensions/project-memory.ts"
}

[ "$dry" = 1 ] && say "(dry run: nothing will be written)"
[ "$action" = "install" ] && install_scripts

for t in "${targets[@]}"; do "setup_$t"; done

[ "$action" = "uninstall" ] && uninstall_scripts

say "claude: Claude Code loads project memory natively; nothing to do"
if [ "$action" = "install" ]; then
  say "Done. New sessions pick up the hooks; running sessions do not."
fi
