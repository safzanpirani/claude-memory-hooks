// Installed by claude-memory-hooks; reinstalling overwrites this file.
// Adds the project's Claude Code auto-memory and upkeep instructions to each
// top-level session. OpenCode 1 appends it to the first user message and again
// after the session compacts. OpenCode 2 adds it to the system prompt of every
// model request, so it survives compaction on its own.

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

// OpenCode 2 runs one server for every directory, so it reads the memory once
// per session, from that session's own directory, and skips subagent sessions.
function setup(ctx) {
  const sessions = new Map();
  const memoryFor = async (sessionID) => {
    if (!sessions.has(sessionID)) {
      sessions.set(
        sessionID,
        ctx.session
          .get({ sessionID })
          .then((s) => (s && !s.parentID ? memory(s.location?.directory || ctx.location?.directory || process.cwd()) : ""))
          .catch(() => ""),
      );
    }
    return sessions.get(sessionID);
  };
  return ctx.session
    .hook("context", async (input) => {
      const text = await memoryFor(input.sessionID);
      if (text) input.system.push({ type: "text", text });
    })
    .then((registration) => () => registration.dispose());
}

// OpenCode 1 (1.18.29+) calls server() and ignores the named export; older
// releases call the named export. OpenCode 2 loads this file from the same
// plugins directory and calls setup().
export default { id: "claude-memory-hooks", server: ProjectMemoryPlugin, setup };
