#!/usr/bin/env bash
# Offline tests: install into a throwaway HOME, check every harness config,
# run the hook and both adapters, reinstall, then uninstall.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
unset FACTORY_HOME CODEX_HOME XDG_CONFIG_HOME XDG_DATA_HOME PI_CODING_AGENT_DIR CLAUDE_CONFIG_DIR
mkdir -p "$HOME/.factory" "$HOME/.codex" "$HOME/.config/opencode" "$HOME/.pi/agent"

pass=0
fail=0
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); echo "ok   $name"
  else fail=$((fail + 1)); echo "FAIL $name"; fi
}

# Existing user hooks that must survive install and uninstall.
cat > "$HOME/.factory/settings.json" <<'EOF'
{"model": "x", "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "other-tool start"}]}],
 "Stop": [{"hooks": [{"type": "command", "command": "other-tool stop"}]}]}}
EOF
chmod 600 "$HOME/.factory/settings.json"
printf '[features]\nhooks = true\n' > "$HOME/.codex/config.toml"

# A project with one memory file.
PROJ="$TMP/proj"
mkdir -p "$PROJ/sub"
git -C "$PROJ" init -q
PROJ="$(cd "$PROJ" && pwd -P)"
MEM="$HOME/.claude/projects/$(printf '%s' "$PROJ" | sed 's/[^A-Za-z0-9]/-/g')/memory"
mkdir -p "$MEM"
printf -- '- [Deploy host](deploy.md) — prod runs on box-7\n' > "$MEM/MEMORY.md"
printf -- '---\nname: deploy\n---\nprod runs on box-7\n' > "$MEM/deploy.md"

HOOK="$HOME/.local/share/claude-memory-hooks/bin/memory-hook"
count_hooks() { jq "[$2 | .[]?.hooks[]? | select(.command | test(\"memory-hook\"))] | length" "$1"; }

"$ROOT/install.sh" --dry-run all > "$TMP/dry.txt"
check "dry run writes nothing" test ! -e "$HOOK" -a ! -e "$HOME/.codex/hooks.json"

"$ROOT/install.sh" all > /dev/null
check "hook installed" test -x "$HOOK"
check "droid hook added" test "$(count_hooks "$HOME/.factory/settings.json" .hooks.SessionStart)" = 1
check "droid keeps other hooks" jq -e '.model == "x" and (.hooks.Stop | length) == 1 and .hooks.SessionStart[0].hooks[0].command == "other-tool start"' "$HOME/.factory/settings.json"
check "droid keeps key order" test "$(jq -c 'keys_unsorted' "$HOME/.factory/settings.json")" = '["model","hooks"]'
check "droid keeps file mode" test "$(stat -f %Lp "$HOME/.factory/settings.json" 2>/dev/null || stat -c %a "$HOME/.factory/settings.json")" = 600
check "codex hooks.json created" test "$(count_hooks "$HOME/.codex/hooks.json" .hooks.SessionStart)" = 1
check "opencode plugin path filled" grep -qF "\"$HOOK\"" "$HOME/.config/opencode/plugins/project-memory.js"
check "pi extension path filled" grep -qF "\"$HOOK\"" "$HOME/.pi/agent/extensions/project-memory.ts"

"$ROOT/install.sh" all > /dev/null
check "reinstall keeps one droid hook" test "$(count_hooks "$HOME/.factory/settings.json" .hooks.SessionStart)" = 1
check "reinstall keeps one codex hook" test "$(count_hooks "$HOME/.codex/hooks.json" .hooks.SessionStart)" = 1

out="$(printf '{"cwd":"%s"}' "$PROJ/sub" | "$HOOK" droid)"
check "droid output is SessionStart JSON" jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' <<<"$out"
check "output has memory index" grep -q "prod runs on box-7" <<<"$out"
check "output has upkeep instructions" grep -q "Keep this project's memory current" <<<"$out"
check "codex output has no suppressOutput" jq -e '(has("suppressOutput") | not)' <<<"$(printf '{"cwd":"%s"}' "$PROJ" | "$HOOK" codex)"
none="$(mkdir -p "$TMP/empty" && printf '{"cwd":"%s"}' "$TMP/empty" | "$HOOK" text)"
check "no-memory project still gets write target" grep -q "No project memory exists yet" <<<"$none"
check "missing cwd falls back to PWD" grep -q "box-7" <<<"$(cd "$PROJ" && echo '{}' | "$HOOK" text)"

if command -v node >/dev/null 2>&1; then
  cat > "$TMP/oc.mjs" <<EOF
import { ProjectMemoryPlugin } from "$HOME/.config/opencode/plugins/project-memory.js";
const p = await ProjectMemoryPlugin({ directory: "$PROJ" });
const send = async (id) => { const o = { parts: [{ type: "text", text: "hi" }] }; await p["chat.message"]({ sessionID: id }, o); return o.parts[0].text; };
await p.event({ event: { type: "session.created", properties: { info: { id: "child", parentID: "s1" } } } });
const r = [await send("s1"), await send("s1"), await send("child")];
await p.event({ event: { type: "session.compacted", properties: { sessionID: "s1" } } });
r.push(await send("s1"));
console.log(JSON.stringify(r.map((t) => t.includes("box-7"))));
EOF
  check "opencode: first, not repeat, not child, after compact" test "$(node "$TMP/oc.mjs" 2>/dev/null)" = '[true,false,false,true]'
  cat > "$TMP/oc2.mjs" <<EOF
import plugin, { ProjectMemoryPlugin } from "$HOME/.config/opencode/plugins/project-memory.js";
const sessions = { s1: { location: { directory: "$PROJ" } }, child: { parentID: "s1", location: { directory: "$PROJ" } } };
let hook, gets = 0, disposed = false;
const ctx = { location: { directory: "$TMP" }, session: {
  get: async ({ sessionID }) => { gets++; return sessions[sessionID]; },
  hook: async (name, fn) => { if (name === "context") hook = fn; return { dispose: async () => { disposed = true; } }; },
} };
const cleanup = await plugin.setup(ctx);
const ask = async (id) => { const i = { sessionID: id, system: [] }; await hook(i); return i.system.some((p) => p.type === "text" && p.text.includes("box-7")); };
const r = [plugin.server === ProjectMemoryPlugin, await ask("s1"), await ask("s1"), await ask("child"), gets === 2];
await cleanup(); r.push(disposed);
console.log(JSON.stringify(r));
EOF
  check "opencode 2: every request, session dir, not child, one lookup, disposes" test "$(node "$TMP/oc2.mjs" 2>/dev/null)" = '[true,true,true,false,true,true]'
fi

if command -v bun >/dev/null 2>&1; then
  cat > "$TMP/pi.ts" <<EOF
import ext from "$HOME/.pi/agent/extensions/project-memory.ts";
const h: Record<string, Function> = {};
ext({ on: (e: string, f: Function) => (h[e] = f) } as any);
const turn = async () => Boolean((await h.before_agent_start({}, { cwd: "$PROJ" }))?.message?.content?.includes("box-7"));
const r: boolean[] = [];
await h.session_start({ reason: "startup" }); r.push(await turn(), await turn());
await h.session_compact({}); r.push(await turn());
await h.session_start({ reason: "reload" }); r.push(await turn());
console.log(JSON.stringify(r));
EOF
  check "pi: startup, not repeat, after compact, not reload" test "$(bun "$TMP/pi.ts" 2>/dev/null)" = '[true,false,true,false]'
fi

"$ROOT/install.sh" --uninstall all > /dev/null
check "uninstall removes droid hook" test "$(count_hooks "$HOME/.factory/settings.json" .hooks.SessionStart)" = 0
check "uninstall keeps other droid hooks" jq -e '.hooks.SessionStart[0].hooks[0].command == "other-tool start" and (.hooks.Stop | length) == 1' "$HOME/.factory/settings.json"
check "uninstall drops empty codex SessionStart" jq -e '.hooks | has("SessionStart") | not' "$HOME/.codex/hooks.json"
check "uninstall removes adapters" test ! -e "$HOME/.config/opencode/plugins/project-memory.js" -a ! -e "$HOME/.pi/agent/extensions/project-memory.ts"
check "uninstall removes scripts" test ! -e "$HOME/.local/share/claude-memory-hooks"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
