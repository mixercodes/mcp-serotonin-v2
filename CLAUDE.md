# CLAUDE.md

Instructions for Claude Code when working in this repository.

## What this is

A Node/TypeScript MCP server that bridges Claude to a live Roblox game via file-based IPC. The README covers setup and the tools list. This file covers how to work in the codebase.

## File responsibilities

| File | Role |
|---|---|
| `src/index.ts` | MCP tool definitions — all `server.tool(...)` calls |
| `src/ipc.ts` | File-based IPC layer — `call()`, `callAsync()`, `waitForResult()` |
| `src/config.ts` | All paths and timeouts — edit here, not inline |
| `lua/agent.lua` | Lua-side agent running in Serotonin — handles command types and writes results |
| `dist/` | Compiled output — gitignored, never commit |

## Adding a tool

Every new tool touches **two files**:

1. **`src/index.ts`** — define the MCP tool with `server.tool(name, description, schema, handler)`
2. **`lua/agent.lua`** — add an `elseif cmd.type == "your_type" then` branch before the final `else` catch-all

Tools that only need a Lua expression can skip the agent.lua step by using `call("eval", { code: "..." })` directly in the handler. Use this for simple one-liners; use a dedicated command type for anything with complex logic or multiple return values.

## Build and reload lifecycle

```bash
npm run build          # compile once
npx tsc --watch        # recompile on save (terminal 1)
node --watch dist/index.js  # restart on change (terminal 2)
```

Do not use `npm run dev` on Windows PowerShell — it uses `&` to run both in parallel, which is not valid PS syntax. Run them in two separate terminals.

- **`src/` changes** — require `npm run build` and an MCP server restart (Claude Code reconnects automatically)
- **`lua/agent.lua` changes** — require reloading the script in Serotonin's Scripting tab only; no server restart needed

## IPC design

Node writes `agent/cmd.lua` as a Lua table literal. The Lua agent polls it on `onUpdate`, executes it, and writes `agent/result.json`. Node polls for a result matching the command ID.

- **Sync commands**: `call(type, payload, timeout?)` — writes cmd, polls result.json at 100ms intervals
- **Async commands**: `callAsync(type, payload, timeout?)` — same but polls at 500ms, used for dump (which chunks across frames)
- **Stale file cleanup**: on server startup, `cmd.lua`, `result.json`, and `status.json` are deleted to prevent cold-start timeouts from a previous session

If a tool times out, the stale `cmd.lua` is deleted so the agent doesn't process a dead request on the next tick.

All paths and timeouts live in `config.ts`. `TIMEOUT_SYNC = 10s`, `TIMEOUT_DUMP = 120s`.

## Serotonin sandbox gotchas

These affect how you write Lua code in eval payloads and agent.lua handlers:

- `game.GetService("Players").LocalPlayer` is **nil** — use `entity.GetLocalPlayer()` instead
- `entity.GetPlayers(false)` excludes the local player — local player only accessible via `entity.GetLocalPlayer()`
- `game.GetService` uses dot syntax: `game.GetService("Players")`, not `game:GetService(...)`
- `GetBonePosition` can return `nil` for bones that don't exist in the rig — always guard with `if not b then`. Also filter zero-vector results for bones that exist but have no valid position
- R15 characters use `UpperTorso`/`LowerTorso`/`LeftUpperArm` etc. Detect rig type by checking `char:FindFirstChild("UpperTorso")`
- `GetAttributes()` returns an array of `{Name, TypeName, Value}` tables — iterate with `pairs`, not as a flat dict

## What not to do

- Do not commit `dist/` — it is gitignored for good reason
- Do not use `npm run dev` on Windows PowerShell
- Do not add inline path strings — all paths go in `config.ts`
- Do not use `eval` for heavy recursive Lua work — it blocks the agent's `onUpdate` tick and produces oversized output. Use `dump_workspace` or `dump_subtree` for tree traversal
