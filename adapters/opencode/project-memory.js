// Installed by claude-memory-hooks; reinstalling overwrites this file.
// Adds the project's Claude Code auto-memory and upkeep instructions to the
// first user message of each top-level session, and again after the session
// compacts.

import { spawnSync } from "node:child_process";

const BIN = "__MEMORY_HOOK__";

function memory(cwd) {
  try {
    const r = spawnSync(BIN, ["text"], {
      input: JSON.stringify({ cwd }),
      encoding: "utf8",
      timeout: 8000,
    });
    return (r.stdout || "").trim();
  } catch {
    return "";
  }
}

export const ProjectMemoryPlugin = async ({ directory }) => {
  const cwd = directory || process.cwd();
  const injected = new Set();
  const childSessions = new Set();

  return {
    "chat.message": async (input, output) => {
      const id = input?.sessionID;
      if (!id || injected.has(id) || childSessions.has(id)) return;
      injected.add(id);
      const text = memory(cwd);
      if (!text) return;
      const part = output?.parts?.find((p) => p.type === "text" && typeof p.text === "string");
      if (part) part.text = `${part.text}\n\n${text}`;
    },
    event: async ({ event }) => {
      const props = event?.properties ?? {};
      const info = props.info;
      if (event?.type === "session.created" && info?.id && info.parentID) {
        childSessions.add(info.id);
        return;
      }
      if (event?.type === "session.compacted" && typeof props.sessionID === "string") {
        injected.delete(props.sessionID);
      }
    },
  };
};
