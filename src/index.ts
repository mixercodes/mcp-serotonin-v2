import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import path from "path";
import {
  call, callAsync, readStatus, listDumpFiles, readDumpLines, grepDump,
} from "./ipc.js";
import { DUMPS_DIR, TIMEOUT_DUMP } from "./config.js";

const server = new McpServer({
  name: "serotonin",
  version: "0.1.0",
  description: "File-based bridge to the Serotonin Roblox scripting runtime",
});

// ── ping ──────────────────────────────────────────────────────────────────

server.tool(
  "ping",
  "Check if agent.lua is loaded and responding in Serotonin.",
  {},
  async () => {
    try {
      const r = await call("ping", {}, 5_000);
      if (!r.ok) return text(`Agent error: ${r.error}`);
      return text("pong — agent is live");
    } catch (e) {
      return text(`No response: ${(e as Error).message}\nLoad agent.lua in Serotonin Scripting tab.`);
    }
  }
);

// ── eval ──────────────────────────────────────────────────────────────────

server.tool(
  "eval",
  "Run a lightweight Lua expression in Serotonin and return the result. " +
  "Do NOT use for heavy recursive work — use dump_workspace for tree traversal.",
  { code: z.string().describe("Lua expression to evaluate. Use `return` to return a value.") },
  async ({ code }) => {
    const r = await call("eval", { code }, 10_000);
    if (!r.ok) return text(`Lua error: ${r.error}`);
    return text(JSON.stringify(r.value, null, 2));
  }
);

// ── dump_workspace ────────────────────────────────────────────────────────

server.tool(
  "dump_workspace",
  "Trigger a full Workspace tree dump. Runs asynchronously in Serotonin " +
  "(chunked across frames to avoid crashes). Returns the path to the dump file when done. " +
  "Use read_dump or grep_dump to inspect the result.",
  {
    depth: z.number().int().min(2).max(12).default(6)
      .describe("Maximum tree depth (default 6)"),
  },
  async ({ depth }) => {
    const status = readStatus();
    if (status?.state === "running") {
      return text("A dump is already in progress. Wait for it to complete.");
    }

    const r = await callAsync("dump", { depth }, TIMEOUT_DUMP);
    if (!r.ok) return text(`Dump failed: ${r.error}`);

    const dumpPath = r.value as string;
    const dumps = listDumpFiles();
    const info = dumps.find(d => dumpPath.endsWith(d.name));
    const size = info ? `${(info.size / 1024).toFixed(0)} KB` : "unknown size";

    return text(
      `Dump complete.\nFile: ${dumpPath}\nSize: ${size}\nTime: ${r.elapsed}ms\n\n` +
      `Use read_dump or grep_dump to inspect the result.`
    );
  }
);

// ── list_dumps ────────────────────────────────────────────────────────────

server.tool(
  "list_dumps",
  "List all saved workspace dump files, newest first.",
  {},
  async () => {
    const dumps = listDumpFiles();
    if (dumps.length === 0) return text("No dumps found. Run dump_workspace first.");
    const lines = dumps.map(d =>
      `${d.name}  (${(d.size / 1024).toFixed(0)} KB, ${d.modified.toISOString().slice(0, 19).replace("T", " ")})`
    );
    return text(lines.join("\n"));
  }
);

// ── read_dump ─────────────────────────────────────────────────────────────

server.tool(
  "read_dump",
  "Read a section of a dump file. Use offset + limit to page through large files.",
  {
    file:   z.string().describe("Dump filename (from list_dumps) or full path"),
    offset: z.number().int().min(0).default(0).describe("Line offset to start from"),
    limit:  z.number().int().min(1).max(1000).default(400).describe("Number of lines to return"),
  },
  async ({ file, offset, limit }) => {
    const fullPath = file.includes("\\") || file.includes("/")
      ? file
      : path.join(DUMPS_DIR, file);

    const lines = readDumpLines(fullPath, offset, limit);
    return text(lines.join("\n"));
  }
);

// ── grep_dump ─────────────────────────────────────────────────────────────

server.tool(
  "grep_dump",
  "Search a dump file for lines matching a pattern. Useful for finding specific " +
  "instance names, classes, or value flags without reading the whole file.",
  {
    file:    z.string().describe("Dump filename (from list_dumps) or full path"),
    pattern: z.string().describe("Regex pattern to search for (case-insensitive)"),
    limit:   z.number().int().min(1).max(500).default(100).describe("Max matching lines to return"),
  },
  async ({ file, pattern, limit }) => {
    const fullPath = file.includes("\\") || file.includes("/")
      ? file
      : path.join(DUMPS_DIR, file);

    const matches = grepDump(fullPath, pattern).slice(0, limit);
    if (matches.length === 0) return text(`No matches for: ${pattern}`);
    return text(`${matches.length} match(es):\n\n${matches.join("\n")}`);
  }
);

// ── get_ui ────────────────────────────────────────────────────────────────

server.tool(
  "get_ui",
  "Get the current value of a Serotonin UI widget.",
  {
    tab:       z.string().describe("Tab identifier (e.g. 'blr_tab')"),
    container: z.string().describe("Container identifier (e.g. 'blr_feat')"),
    label:     z.string().describe("Widget label"),
  },
  async ({ tab, container, label }) => {
    const code = `return ui.getValue(${JSON.stringify(tab)}, ${JSON.stringify(container)}, ${JSON.stringify(label)})`;
    const r = await call("eval", { code });
    if (!r.ok) return text(`Error: ${r.error}`);
    return text(JSON.stringify(r.value));
  }
);

// ── set_ui ────────────────────────────────────────────────────────────────

server.tool(
  "set_ui",
  "Set the value of a Serotonin UI widget.",
  {
    tab:       z.string().describe("Tab identifier"),
    container: z.string().describe("Container identifier"),
    label:     z.string().describe("Widget label"),
    value:     z.union([z.string(), z.number(), z.boolean()])
                 .describe("New value to set"),
  },
  async ({ tab, container, label, value }) => {
    const valStr = typeof value === "string" ? JSON.stringify(value) : String(value);
    const code = `ui.setValue(${JSON.stringify(tab)}, ${JSON.stringify(container)}, ${JSON.stringify(label)}, ${valStr}); return true`;
    const r = await call("eval", { code });
    if (!r.ok) return text(`Error: ${r.error}`);
    return text("ok");
  }
);

// ── inspect ───────────────────────────────────────────────────────────────

server.tool(
  "inspect",
  "Inspect a specific instance in the game by its Lua path, returning its " +
  "ClassName, children names, and key properties.",
  {
    path: z.string().describe(
      "Lua path to the instance, e.g. 'game.Workspace:FindFirstChild(\"Ball\")' " +
      "or 'game.Workspace.Football'"
    ),
  },
  async ({ path: luaPath }) => {
    const code = `
      local inst = ${luaPath}
      if not inst then return {error="nil"} end
      local ok, name, cn = pcall(function() return inst.Name, inst.ClassName end)
      if not ok then return {error="access denied"} end
      local ok2, children = pcall(function() return inst:GetChildren() end)
      local child_names = {}
      if ok2 and children then
        for i, c in ipairs(children) do
          local ok3, cn2, ccn = pcall(function() return c.Name, c.ClassName end)
          if ok3 then child_names[i] = "[" .. ccn .. "] " .. cn2 end
          if i >= 50 then child_names[i+1] = "... (truncated)"; break end
        end
      end
      local props = {}
      local p_ok, pos = pcall(function() return inst.Position end)
      if p_ok and pos then props.Position = {pos.X, pos.Y, pos.Z} end
      local s_ok, sz = pcall(function() return inst.Size end)
      if s_ok and sz then props.Size = {sz.X, sz.Y, sz.Z} end
      local h_ok, hp = pcall(function() return inst.Health end)
      if h_ok and type(hp) == "number" then props.Health = hp end
      return {Name=name, ClassName=cn, Children=child_names, Properties=props}
    `;
    const r = await call("eval", { code }, 10_000);
    if (!r.ok) return text(`Error: ${r.error}`);
    return text(JSON.stringify(r.value, null, 2));
  }
);

// ── players ───────────────────────────────────────────────────────────────

server.tool(
  "players",
  "Get the current list of players in the game with their positions and key state.",
  {
    enemies_only: z.boolean().default(false).describe("Only return enemy players"),
  },
  async ({ enemies_only }) => {
    const code = `
      local ok, players = pcall(function() return entity.GetPlayers(${enemies_only}) end)
      if not ok or not players then return {error="entity.GetPlayers failed"} end
      local result = {}
      for i, p in ipairs(players) do
        local entry = {Name = p.Name}
        local ok2, hrp = pcall(function() return p:GetBonePosition("HumanoidRootPart") end)
        if ok2 and hrp then entry.Position = {hrp.X, hrp.Y, hrp.Z} end
        result[i] = entry
      end
      if not ${enemies_only} then
        local lp = entity.GetLocalPlayer()
        if lp then
          local lp_entry = {Name = lp.Name, is_local = true}
          local ok2, hrp = pcall(function() return lp:GetBonePosition("HumanoidRootPart") end)
          if ok2 and hrp then lp_entry.Position = {hrp.X, hrp.Y, hrp.Z} end
          result[#result+1] = lp_entry
        end
      end
      return result
    `;
    const r = await call("eval", { code }, 10_000);
    if (!r.ok) return text(`Error: ${r.error}`);
    return text(JSON.stringify(r.value, null, 2));
  }
);

// ── inspect_service ───────────────────────────────────────────────────────

server.tool(
  "inspect_service",
  "Inspect a Roblox service (Players, ReplicatedStorage, StarterGui, Lighting, etc.) " +
  "and list its top-level children. Essential for universal scripts that need to understand " +
  "what's available outside Workspace.",
  {
    name: z.string().describe("Service name, e.g. 'Players', 'ReplicatedStorage', 'StarterGui'"),
  },
  async ({ name }) => {
    const r = await call("inspect_service", { name }, 10_000);
    if (!r.ok) return text(`Error: ${r.error}`);
    return text(JSON.stringify(r.value, null, 2));
  }
);

// ── screen_info ───────────────────────────────────────────────────────────

server.tool(
  "screen_info",
  "Get current window dimensions, camera world position, and mouse position. " +
  "Required context for writing any ESP or screen-space rendering code.",
  {},
  async () => {
    const r = await call("screen_info", {}, 5_000);
    if (!r.ok) return text(`Error: ${r.error}`);
    return text(JSON.stringify(r.value, null, 2));
  }
);

// ── world_to_screen ───────────────────────────────────────────────────────

server.tool(
  "world_to_screen",
  "Project a world-space Vector3 position to screen coordinates using " +
  "utility.WorldToScreen(). Returns screen x/y and whether the point is on screen.",
  {
    x: z.number().describe("World X"),
    y: z.number().describe("World Y"),
    z: z.number().describe("World Z"),
  },
  async ({ x, y, z: wz }) => {
    const r = await call("world_to_screen", { x, y, z: wz }, 5_000);
    if (!r.ok) return text(`Error: ${r.error}`);
    return text(JSON.stringify(r.value, null, 2));
  }
);

// ── get_bones ─────────────────────────────────────────────────────────────

server.tool(
  "get_bones",
  "Get world positions (and screen projections) for all R6 bones of a specific player " +
  "via entity:GetBonePosition(). Use this when writing or debugging ESP/aimbot scripts.",
  {
    player_name: z.string().describe("Exact player name as shown in the player list"),
  },
  async ({ player_name }) => {
    const r = await call("get_bones", { player_name }, 10_000);
    if (!r.ok) return text(`Error: ${r.error}`);
    return text(JSON.stringify(r.value, null, 2));
  }
);

// ── find_by_class ─────────────────────────────────────────────────────────

server.tool(
  "find_by_class",
  "Find all instances of a given ClassName within a root (default: Workspace). " +
  "Faster than a full dump when you just need instances of one type. " +
  "Capped at 100 results. If a dump already exists, prefer grep_dump instead.",
  {
    class_name: z.string().describe("ClassName to search for, e.g. 'Part', 'Model', 'Humanoid'"),
    root:  z.string().default("game.Workspace")
             .describe("Lua path to search root (default: game.Workspace)"),
    depth: z.number().int().min(1).max(6).default(4)
             .describe("Max search depth (default 4)"),
  },
  async ({ class_name, root, depth }) => {
    const r = await call("find_by_class", { class_name, root, depth }, 15_000);
    if (!r.ok) return text(`Error: ${r.error}`);
    const v = r.value as { count: number; results: unknown[] };
    return text(`Found ${v.count} instance(s):\n\n${JSON.stringify(v.results, null, 2)}`);
  }
);

// ── dump_subtree ──────────────────────────────────────────────────────────

server.tool(
  "dump_subtree",
  "Dump just one branch of the instance tree instead of the full Workspace. " +
  "Runs synchronously — fast for small subtrees, capped at 500 instances. " +
  "Use dump_workspace for larger trees.",
  {
    root:  z.string().describe(
             "Lua path to the subtree root, e.g. 'game.Workspace.AI' or " +
             "'game.Workspace:FindFirstChild(\"Goals\")'"
           ),
    depth: z.number().int().min(1).max(6).default(4)
             .describe("Max tree depth (default 4)"),
  },
  async ({ root, depth }) => {
    const r = await call("dump_subtree", { root, depth }, 15_000);
    if (!r.ok) return text(`Error: ${r.error}`);
    const v = r.value as { root: string; count: number; truncated: boolean; tree: string };
    const note = v.truncated ? "\n[truncated at 500 instances — use dump_workspace for the full tree]" : "";
    return text(`${v.root}  (${v.count} instances)\n\n${v.tree}${note}`);
  }
);

// ── get_attributes ────────────────────────────────────────────────────────

server.tool(
  "get_attributes",
  "Get all attributes on a specific instance. Attributes are invisible to dumps — " +
  "use this when grep_dump finds nothing and you suspect the data is stored as attributes.",
  {
    path: z.string().describe(
      "Lua path to the instance, e.g. 'game.Workspace:FindFirstChild(\"Player1\")'"
    ),
  },
  async ({ path: luaPath }) => {
    const r = await call("get_attributes", { path: luaPath }, 10_000);
    if (!r.ok) return text(`Error: ${r.error}`);
    const attrs = r.value as { name: string; type: string; value: unknown }[];
    if (!Array.isArray(attrs) || attrs.length === 0) return text("No attributes found.");
    return text(JSON.stringify(attrs, null, 2));
  }
);

// ── Utilities ─────────────────────────────────────────────────────────────

function text(s: string) {
  return { content: [{ type: "text" as const, text: s }] };
}

// ── Start ─────────────────────────────────────────────────────────────────

const transport = new StdioServerTransport();
await server.connect(transport);
