// Installed by claude-memory-hooks; reinstalling overwrites this file.
// Adds the project's Claude Code auto-memory and upkeep instructions before an
// agent turn whenever the model's context does not already hold them: the first
// turn of a session (startup, /new) and the first turn after a compaction.
// Subagents get nothing.

import { spawnSync } from "node:child_process";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

const BIN = "__MEMORY_HOOK__";
const TYPE = "project-memory";

function memory(cwd: string): string {
  try {
    const r = spawnSync(BIN, ["text"], { input: JSON.stringify({ cwd }), encoding: "utf8", timeout: 8000 });
    return (r.stdout || "").trim();
  } catch {
    return "";
  }
}

// Walk the current branch back from the leaf. A compaction drops everything
// before its firstKeptEntryId, so the search stops there.
function inContext(entries: any[]): boolean {
  let stopAt: string | undefined;
  for (let i = entries.length - 1; i >= 0; i--) {
    const e = entries[i];
    if (e?.type === "custom_message" && e.customType === TYPE) return true;
    if (stopAt !== undefined && e?.id === stopAt) return false;
    if (e?.type === "compaction") {
      if (!e.firstKeptEntryId) return false;
      stopAt ??= e.firstKeptEntryId;
    }
  }
  return false;
}

export default function projectMemory(pi: ExtensionAPI) {
  pi.on("before_agent_start", async (_event, ctx: any) => {
    if (ctx?.agent?.kind === "sub") return;
    let entries: any[] = [];
    try {
      entries = ctx?.sessionManager?.getBranch?.() ?? [];
    } catch {}
    if (inContext(entries)) return;
    const text = memory(ctx?.cwd ?? process.cwd());
    if (!text) return;
    return { message: { customType: TYPE, content: text, display: false } };
  });
}
