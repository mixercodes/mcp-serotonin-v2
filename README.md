# mcp-serotonin-v2

A file-based [Model Context Protocol](https://modelcontextprotocol.io/) server that connects Claude Code to the [Serotonin](https://serotonin.win/) Roblox scripting runtime. It replaces the original WebSocket bridge with a crash-safe filesystem IPC design.

## How it works

```
Claude Code  ←→  MCP Server (Node/TypeScript)  ←→  agent.lua (Serotonin)
                        writes cmd.lua                  polls cmd.lua
                        reads  result.json              writes result.json
```

Node writes a Lua table literal to `agent/cmd.lua`. The Lua agent polls for it on `onUpdate`, executes it, and writes the result to `agent/result.json`. For heavy operations like workspace dumps, the agent chunks the work across frames and writes progress to `agent/status.json` while Node polls for completion.

This eliminates the crash-under-load issues of the original WebSocket eval bridge.

## Requirements

- Node.js 18+
- Serotonin (with `agent.lua` loaded)
- Claude Code with MCP support

## Setup

**1. Install and build:**

```bash
cd mcp-serotonin-v2
npm install
npm run build
```

**2. Configure Claude Code** — add to your `.mcp.json`:

```json
{
  "mcpServers": {
    "serotonin": {
      "command": "node",
      "args": ["C:/Serotonin/mcp-serotonin-v2/dist/index.js"]
    }
  }
}
```

**3. Load the Lua agent** — open `lua/agent.lua` in Serotonin's Scripting tab and run it. The HUD in the bottom-right corner will show `Agent: idle` when ready.

**4. Verify the connection** — in Claude Code, run the `ping` tool. You should get `pong — agent is live`.

## Tools

| Tool | Description |
|---|---|
| `ping` | Check if `agent.lua` is loaded and responding |
| `eval` | Run a Lua expression and return the result |
| `dump_workspace` | Trigger a full Workspace tree dump (chunked, async) |
| `list_dumps` | List saved dump files, newest first |
| `read_dump` | Page through a dump file by line offset |
| `grep_dump` | Regex-search a dump file for instance names or classes |
| `inspect` | Inspect a specific instance by its Lua path |
| `players` | List players with positions from `entity.GetPlayers` |
| `get_ui` | Read a Serotonin UI widget value |
| `set_ui` | Write a Serotonin UI widget value |

## File layout

```
mcp-serotonin-v2/
├── lua/
│   └── agent.lua          Lua-side agent (load this in Serotonin)
├── src/
│   ├── index.ts           MCP tool definitions
│   ├── ipc.ts             File-based IPC layer
│   └── config.ts          Paths, timeouts, poll intervals
├── dist/                  Compiled output (after npm run build)
├── package.json
└── tsconfig.json
```

The agent reads/writes under the Serotonin file sandbox root:

```
agent/
├── cmd.lua                Pending command (Lua table literal)
├── result.json            Command result
└── status.json            Async operation progress
dumps/
└── place_<id>_<date>.txt  Workspace tree dumps
```

## IPC protocol

Commands are Lua table literals so `agent.lua` can deserialize them with `loadstring()` — no JSON parser needed on the Lua side:

```lua
-- cmd.lua written by Node:
return {id="a1b2c3d4", type="eval", payload={code="return game.PlaceId"}}
```

Results are JSON written by Lua:

```json
{"id":"a1b2c3d4","ok":true,"value":12345,"error":null,"elapsed":2}
```

## Development

```bash
npx tsc --watch          # terminal 1 — recompile on save
node --watch dist/index.js  # terminal 2 — restart on change
```

> The `npm run dev` script uses `&` to run both in parallel, which works on Unix but not in Windows PowerShell. Run them in two separate terminals instead.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
