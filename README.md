# claude-memory-hooks

Claude Code keeps per-project memory under `~/.claude/projects/<slug>/memory/`:
a `MEMORY.md` index plus one markdown file per fact. Claude Code loads it every
session. Other coding agents do not.

This repo makes Factory Droid, OpenAI Codex, OpenCode, and Pi load the same
memory when a session starts. Each agent also gets instructions to keep that
memory current, so every agent reads and writes one shared store.

## Install

```sh
git clone <this repo> && cd claude-memory-hooks
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
| OpenCode | A plugin at `~/.config/opencode/plugins/project-memory.js` | First message of each top-level session, and after compaction |
| Pi | An extension at `~/.pi/agent/extensions/project-memory.ts` | First turn of each session, and after compaction |
| Claude Code | Nothing | Claude Code loads its own memory |

Running the installer again is safe. It replaces its own hook entry and keeps
every other hook. Before it edits a JSON config, it writes a backup next to it
named `*.bak-claude-memory-hooks-<timestamp>`.

Hooks load when an agent starts, so already running sessions do not pick them
up. Codex asks you to trust a new hook the first time an interactive session
sees it. Until you trust it, `codex exec` skips the hook without a warning.
Codex also
needs `hooks = true` under `[features]` in `~/.codex/config.toml`; the
installer reminds you when that line is missing.

Overrides: `FACTORY_HOME`, `CODEX_HOME`, `XDG_CONFIG_HOME`,
`PI_CODING_AGENT_DIR`, `XDG_DATA_HOME`, and `CLAUDE_CONFIG_DIR` (when the
Claude home is not `~/.claude`).

## What the agent sees

`memory-hook` resolves the project from the session's working directory. It
uses the main checkout's git root, so subdirectories and worktrees share one
memory. When the project has no memory of its own, it falls back to the
nearest ancestor that has one and labels it as background. Then it prints:

- the `MEMORY.md` index and the paths of the fact files,
- any drift between the index and the files,
- a reminder to verify named files, hosts, and flags before acting on them,
- the directory where new memory for this project belongs, and the rules for
  writing it: one fact per file, the frontmatter format, the index line, no
  secrets, and absolute dates.

A project without memory still gets the directory and the rules, so the first
agent to learn something durable can start the memory. When anything fails,
the hook prints nothing and exits 0, so it never blocks a session.

Try it by hand:

```sh
echo '{"cwd":"'"$PWD"'"}' | ~/.local/share/claude-memory-hooks/bin/memory-hook text
```

The first argument picks the output format: `droid` and `codex` print
`SessionStart` hook JSON; `text` prints plain text for the OpenCode and Pi
adapters.

## Layout

```
bin/memory-hook                    prints memory + upkeep rules
lib/read-memory.sh                 finds and reads a project's memory directory
adapters/opencode/project-memory.js
adapters/pi/project-memory.ts
install.sh
tests/test.sh                      offline tests in a throwaway HOME
```

## Tests

```sh
tests/test.sh
```

The tests install into a temporary `HOME`. They check each config edit,
reinstall, the hook output, both adapters (when `node` and `bun` exist), and
uninstall. They make no network calls.
