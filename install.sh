#!/usr/bin/env bash
# install.sh: load Claude Code's per-project memory into Droid, Codex,
# OpenCode, Pi, oh-my-pi (omp), and Antigravity (agy) sessions. Run ./install.sh --help for usage.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./install.sh [options] [harness...]

Harnesses: droid, codex, opencode (1 and 2), pi, omp, agy, all.
With no harness named, installs for every harness found on this machine.

Options:
  --uninstall     remove the hooks, adapters, and installed scripts
  --dry-run       print what would change and write nothing
  --prefix DIR    install scripts under DIR
                  (default: ${XDG_DATA_HOME:-~/.local/share}/claude-memory-hooks)
  -h, --help      show this help

Environment overrides: FACTORY_HOME, CODEX_HOME, XDG_CONFIG_HOME, PI_CODING_AGENT_DIR,
OMP_AGENT_DIR, ANTIGRAVITY_CONFIG_DIR.
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
    all) targets=(droid codex opencode pi omp agy) ;;
    droid|codex|opencode|pi|omp|agy) targets+=("$1") ;;
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
OMP_DIR="${OMP_AGENT_DIR:-$HOME/.omp/agent}"
AGY_DIR="${ANTIGRAVITY_CONFIG_DIR:-$HOME/.gemini/config}"
HOOK="$PREFIX/bin/memory-hook"
MARKER="claude-memory-hooks"
STAMP="$(date +%Y%m%d-%H%M%S)"

say() { printf '%s\n' "$*"; }
run() { if [ "$dry" = 1 ]; then say "  would run: $*"; else "$@"; fi; }

detect() {
  local found=()
  { [ -d "$FACTORY_DIR" ] || command -v droid >/dev/null 2>&1; } && found+=(droid)
  { [ -d "$CODEX_DIR" ] || command -v codex >/dev/null 2>&1; } && found+=(codex)
  { [ -d "$OPENCODE_DIR" ] || command -v opencode >/dev/null 2>&1 || command -v opencode2 >/dev/null 2>&1 \
    || command -v opencode-next >/dev/null 2>&1; } && found+=(opencode)
  { [ -d "$PI_DIR" ] || command -v pi >/dev/null 2>&1; } && found+=(pi)
  { [ -d "$OMP_DIR" ] || command -v omp >/dev/null 2>&1; } && found+=(omp)
  { [ -d "$AGY_DIR" ] || command -v agy >/dev/null 2>&1; } && found+=(agy)
  printf '%s\n' "${found[@]:-}"
}

if [ ${#targets[@]} -eq 0 ]; then
  while IFS= read -r t; do [ -n "$t" ] && targets+=("$t"); done < <(detect)
fi
if [ ${#targets[@]} -eq 0 ]; then
  say "No supported harness found (droid, codex, opencode, pi, omp, agy). Name one to install anyway."
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
  write_json "$file" "$before" "$after"
}

# Antigravity has no SessionStart event. Its hooks.json maps hook names to events,
# so own the "$MARKER" entry: a PreInvocation hook that memory-hook runs only once
# per conversation. Set it to command $2, or remove it when $2 is empty.
edit_agy_hooks() {
  local file="$1" command="${2:-}" original before after
  if [ -f "$file" ]; then
    original="$(jq . "$file")" || { say "  cannot parse $file as JSON; skipped"; return 1; }
  else
    [ -n "$command" ] || return 0
    original='{}'
  fi
  before="$(printf '%s' "$original" | jq -S .)"
  after="$(printf '%s' "$original" | jq --arg k "$MARKER" --arg c "$command" '
    if $c == "" then del(.[$k])
    else .[$k] = {PreInvocation: [{type: "command", command: $c, timeout: 10}]} end')"
  write_json "$file" "$before" "$after"
}

# Write JSON $3 to file $1 unless it matches the key-sorted original $2.
write_json() {
  local file="$1" before="$2" after="$3"
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
  run install -m 644 "$SRC/lib/memory-prompt.md" "$PREFIX/lib/memory-prompt.md"
}

uninstall_scripts() {
  say "scripts in $PREFIX"
  [ -d "$PREFIX" ] || { say "  not installed"; return 0; }
  run rm -f "$PREFIX/bin/memory-hook" "$PREFIX/lib/read-memory.sh" "$PREFIX/lib/memory-prompt.md"
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

setup_omp() {
  say "omp"
  place_adapter "$SRC/adapters/omp/project-memory.ts" "$OMP_DIR/extensions/project-memory.ts"
}

setup_agy() {
  say "agy"
  edit_agy_hooks "$AGY_DIR/hooks.json" "$(hook_command agy)"
}

[ "$dry" = 1 ] && say "(dry run: nothing will be written)"
[ "$action" = "install" ] && install_scripts

for t in "${targets[@]}"; do "setup_$t"; done

[ "$action" = "uninstall" ] && uninstall_scripts

say "claude: Claude Code loads project memory natively; nothing to do"
if [ "$action" = "install" ]; then
  say "Done. New sessions pick up the hooks; running sessions do not."
fi
