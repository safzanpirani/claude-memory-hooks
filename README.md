# claude-memory-hooks

Claude Code keeps per-project memory under `~/.claude/projects/<slug>/memory/`:
a `MEMORY.md` index plus one markdown file per fact. Claude Code loads it every
session. Other coding agents do not.

This repo makes Factory Droid, OpenAI Codex, OpenCode (1 and 2), Pi, oh-my-pi
(`omp`), and Antigravity (`agy`) load
the same memory when a session starts. Each agent also gets instructions to keep that
memory current, so every agent reads and writes one shared store.

## Install

```sh
git clone https://github.com/safzanpirani/claude-memory-hooks && cd claude-memory-hooks
./install.sh              # every harness found on this machine
./install.sh droid pi     # only the named harnesses
./install.sh --dry-run    # show what would change
./install.sh --uninstall  # remove everything it installed
```

Requirements: bash, git, and `jq`. Supported on macOS and Linux. Windows is
not supported.

The installer copies `bin/memory-hook` and `lib/read-memory.sh` to
`~/.local/share/claude-memory-hooks` (change it with `--prefix`). Then it
registers the hook with each harness:

| Harness | What the installer changes | When memory loads |
|---|---|---|
| Droid | A `SessionStart` hook in `~/.factory/hooks.json` if that file exists, otherwise in `~/.factory/settings.json` | Startup, resume, clear, and after compaction |
| Codex | A `SessionStart` hook in `~/.codex/hooks.json` | Session start |
| OpenCode 1 | A plugin at `~/.config/opencode/plugins/project-memory.js` | First message of each top-level session, and after compaction |
| OpenCode 2 | The same plugin file | System prompt of every model request in a top-level session |
| Pi | An extension at `~/.pi/agent/extensions/project-memory.ts` | First turn of each session, and after compaction |
| oh-my-pi | An extension at `~/.omp/agent/extensions/project-memory.ts` | First turn of each top-level session, and after compaction |
| Antigravity | A `PreInvocation` hook under the `claude-memory-hooks` key in `~/.gemini/config/hooks.json` | First model call of each conversation |
| Claude Code | Nothing | Claude Code loads its own memory |

### OpenCode 1 and 2

OpenCode 1 and OpenCode 2 (`opencode2`, `opencode-next`) share
`~/.config/opencode` and both load every file in its `plugins/` directory, so
one plugin file serves both. Its default export carries a `server` function for
OpenCode 1 (1.18.29 and later) and a `setup` function for OpenCode 2. The named
`ProjectMemoryPlugin` export covers older OpenCode 1 releases.

OpenCode 2 runs one background service for every project. The plugin looks up
each session's own directory, reads that project's memory once per session,
and adds it to the system prompt through the session `context` hook. Because
the system prompt is rebuilt for every request, the memory survives compaction
without a reload. Subagent sessions (those with a parent) get nothing. The
service watches the plugin file and reloads it after an install, so you do not
need to restart it. Verified against OpenCode 1.18.34 and OpenCode 2.0.22.

### oh-my-pi

omp loads extensions from `~/.omp/agent/extensions`, not from Pi's directory,
so it gets its own copy of the adapter. Before each turn the adapter walks the
current session branch back from the leaf. It injects the memory when that
walk finds no earlier `project-memory` message, and it stops at the latest
compaction's first kept entry. One check covers startup, `/new`, resume, fork,
and compaction. Subagents (`ctx.agent.kind === "sub"`) get nothing. omp's own
memory backend (`memory.backend`) defaults to `off`; leave it off to keep one
memory store. Verified against omp 18.6.1.

### Antigravity

Antigravity has no session-start event. Its `PreInvocation` hook runs before
every model call, so the hook checks the conversation transcript and injects
the memory as a user message only when no earlier message carries the
`<project-memory>` block. Later calls in the same conversation get `{}`. The
project comes from the first entry in `workspacePaths`.

Running the installer again is safe. It replaces its own hook entry and keeps
every other hook. Before it edits a JSON config, it writes a backup next to it
named `*.bak-claude-memory-hooks-<timestamp>`.

Hooks load when an agent starts, so already running sessions do not pick them
up.

### Codex

Codex needs `hooks = true` under `[features]` in `~/.codex/config.toml`; the
installer reminds you when that line is missing. Codex asks you to trust a new
hook the first time an interactive session sees it. Until you trust it, Codex
skips the hook without a warning.

`codex exec` (tested with Codex 0.160.0) skipped the hook even after the hook
showed as trusted and enabled under `[hooks.state]`. With
`--dangerously-bypass-hook-trust`, the hook ran, and the model saved a new
memory in the Claude memory directory in the right format. When a run
answers without project memory, check for a `hook: SessionStart` line in its
output.

Codex also has its own memory feature (`[memories] use_memories = true`),
which tells the model to save notes under `~/.codex/memories`. When the hook
does not run, the model follows those instructions instead. Set
`use_memories = false` and `generate_memories = false` to keep one memory
store.

Overrides: `FACTORY_HOME`, `CODEX_HOME`, `XDG_CONFIG_HOME`,
`PI_CODING_AGENT_DIR`, `OMP_AGENT_DIR`, `ANTIGRAVITY_CONFIG_DIR`, `XDG_DATA_HOME`, and `CLAUDE_CONFIG_DIR` (when the
Claude home is not `~/.claude`).

## What the agent sees

`memory-hook` resolves the project from the session's working directory. It
uses the main checkout's git root, so subdirectories and worktrees share one
memory. Then it prints what Claude Code itself puts in context:

- Claude Code's `# Memory` system prompt section, from
  `lib/memory-prompt.md`, with the project's memory directory filled in. It
  tells the agent where memory lives, the frontmatter format, the four memory
  types, the `MEMORY.md` index line, what not to save, and to verify a
  remembered file or flag before relying on it.
- The `MEMORY.md` index inside a `<project-memory>` block, under the same
  `Contents of …/MEMORY.md (user's auto-memory, persists across
  conversations):` header Claude Code uses. Like Claude Code, it cuts the
  index at 200 lines or 25,000 bytes and appends Claude Code's warning.

`lib/memory-prompt.md` is copied from Claude Code 2.1.287, rendered for a
single private memory directory. Three phrases differ so they apply outside
Claude Code: "the Write tool" becomes "your file tools", the list of what the
repo already records names `AGENTS.md` beside `CLAUDE.md`, and recalled
memories are said to arrive in the `<project-memory>` block instead of
`<system-reminder>` blocks. To resync after a Claude Code update, compare the
file with the `# Memory` section of a Claude Code session's system prompt.

The hook adds two things Claude Code does not do. When the project has no
memory of its own, it shows the nearest ancestor project's index and labels it
as background. When the index and the memory files disagree, it lists the
drift and asks the agent to fix it.

A project without memory still gets the instructions and its memory directory,
so the first agent to learn something durable can start the memory. When
anything fails, the hook prints nothing and exits 0, so it never blocks a
session.

Try it by hand:

```sh
echo '{"cwd":"'"$PWD"'"}' | ~/.local/share/claude-memory-hooks/bin/memory-hook text
```

The first argument picks the output format: `droid` and `codex` print
`SessionStart` hook JSON; `agy` prints `PreInvocation` JSON; `text` prints plain text for the OpenCode, Pi, and omp
adapters.

## Layout

```
bin/memory-hook                    prints the memory instructions and index
lib/memory-prompt.md               Claude Code's memory instructions
lib/read-memory.sh                 finds and reads a project's memory directory
adapters/opencode/project-memory.js
adapters/pi/project-memory.ts
adapters/omp/project-memory.ts
install.sh
tests/test.sh                      offline tests in a throwaway HOME
```

## Tests

```sh
tests/test.sh
```

The tests install into a temporary `HOME`. They check each config edit,
reinstall, the hook output, the OpenCode 1, OpenCode 2, Pi, and omp adapters (when
`node` and `bun` exist), and uninstall. They make no network calls.
