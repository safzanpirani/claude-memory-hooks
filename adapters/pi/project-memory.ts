// Installed by claude-memory-hooks; reinstalling overwrites this file.
// Adds the project's Claude Code auto-memory and upkeep instructions before
// the first agent turn of a session, and again after the session compacts.

import { spawnSync } from "node:child_process";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const BIN = "__MEMORY_HOOK__";

function memory(cwd: string): string {
  try {
    const r = spawnSync(BIN, ["text"], { input: JSON.stringify({ cwd }), encoding: "utf8", timeout: 8000 });
    return (r.stdout || "").trim();
  } catch {
    return "";
  }
}

export default function projectMemory(pi: ExtensionAPI) {
  let pending = false;

  pi.on("session_start", async (event: any) => {
    // An extension reload keeps the conversation, which already holds the memory.
    if (event?.reason !== "reload") pending = true;
  });

  pi.on("session_compact", async () => {
    pending = true;
  });

  pi.on("before_agent_start", async (_event, ctx: any) => {
    if (!pending) return;
    pending = false;
    const text = memory(ctx?.cwd ?? process.cwd());
    if (!text) return;
    return { message: { customType: "project-memory", content: text, display: false } };
  });
}
