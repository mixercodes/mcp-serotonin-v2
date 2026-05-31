import fs from "fs";
import path from "path";
import { randomBytes } from "crypto";
import {
  AGENT_DIR, CMD_FILE, RESULT_FILE, STATUS_FILE, DUMPS_DIR,
  POLL_FAST, POLL_SLOW, TIMEOUT_SYNC, TIMEOUT_DUMP,
} from "./config.js";

export interface AgentResult {
  id: string;
  ok: boolean;
  value?: unknown;
  error?: string;
  elapsed?: number;
}

export interface AgentStatus {
  state: "idle" | "busy" | "running" | "done" | "error" | "offline";
  progress?: string;
  output?: string;
}

// ── Helpers ───────────────────────────────────────────────────────────────

function newId(): string {
  return randomBytes(4).toString("hex");
}

function sleep(ms: number): Promise<void> {
  return new Promise(r => setTimeout(r, ms));
}

function ensureAgentDir(): void {
  if (!fs.existsSync(AGENT_DIR)) fs.mkdirSync(AGENT_DIR, { recursive: true });
}

/** Serialize a value to a Lua literal (for embedding in cmd.lua payloads) */
export function toLua(v: unknown, depth = 0): string {
  if (v === null || v === undefined) return "nil";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") return String(v);
  if (typeof v === "string") return JSON.stringify(v); // JSON strings are valid Lua strings
  if (typeof v === "object" && !Array.isArray(v)) {
    const entries = Object.entries(v as Record<string, unknown>)
      .map(([k, val]) => `${k}=${toLua(val, depth + 1)}`);
    return `{${entries.join(",")}}`;
  }
  if (Array.isArray(v)) {
    return `{${v.map(x => toLua(x, depth + 1)).join(",")}}`;
  }
  return "nil";
}

// ── Core IPC ──────────────────────────────────────────────────────────────

/**
 * Write a command for the Lua agent.
 * The file is a Lua table literal that agent.lua reads with loadstring().
 */
export function writeCommand(type: string, payload: Record<string, unknown>, id = newId()): string {
  ensureAgentDir();

  // Build Lua table fields
  const payloadStr = Object.entries(payload)
    .map(([k, v]) => `${k}=${toLua(v)}`)
    .join(",");

  const lua = `return {id=${toLua(id)},type=${toLua(type)},payload={${payloadStr}}}`;
  fs.writeFileSync(CMD_FILE, lua, "utf8");
  return id;
}

/** Poll for result.json, returning parsed content or throwing on timeout */
export async function waitForResult(id: string, timeout = TIMEOUT_SYNC, interval = POLL_FAST): Promise<AgentResult> {
  const deadline = Date.now() + timeout;

  while (Date.now() < deadline) {
    await sleep(interval);

    if (!fs.existsSync(RESULT_FILE)) continue;

    let raw: string;
    try { raw = fs.readFileSync(RESULT_FILE, "utf8"); } catch { continue; }

    let result: AgentResult;
    try { result = JSON.parse(raw); } catch { continue; }

    // Only consume if this result is for our request
    if (result.id !== id) continue;

    // Clean up
    try { fs.unlinkSync(RESULT_FILE); } catch { /* already gone */ }

    return result;
  }

  // Clean up stale cmd.lua on timeout so agent doesn't process a dead request
  try { fs.unlinkSync(CMD_FILE); } catch { /* already gone */ }
  throw new Error(`Agent timeout after ${timeout}ms`);
}

/** Poll status.json during async operations (dump etc.) */
export async function waitForAsync(id: string, timeout = TIMEOUT_DUMP): Promise<AgentResult> {
  const deadline = Date.now() + timeout;

  while (Date.now() < deadline) {
    await sleep(POLL_SLOW);

    // Check for completion first
    if (fs.existsSync(RESULT_FILE)) {
      let raw: string;
      try { raw = fs.readFileSync(RESULT_FILE, "utf8"); } catch { continue; }
      let result: AgentResult;
      try { result = JSON.parse(raw); } catch { continue; }
      if (result.id === id) {
        try { fs.unlinkSync(RESULT_FILE); } catch { /* gone */ }
        return result;
      }
    }
  }

  try { fs.unlinkSync(CMD_FILE); } catch { /* gone */ }
  throw new Error(`Async operation timeout after ${timeout}ms`);
}

/** Read the current agent status without blocking */
export function readStatus(): AgentStatus | null {
  if (!fs.existsSync(STATUS_FILE)) return null;
  try {
    return JSON.parse(fs.readFileSync(STATUS_FILE, "utf8")) as AgentStatus;
  } catch {
    return null;
  }
}

/** High-level: send a sync command and wait for its result */
export async function call(type: string, payload: Record<string, unknown> = {}, timeout?: number): Promise<AgentResult> {
  const id = writeCommand(type, payload);
  return waitForResult(id, timeout ?? TIMEOUT_SYNC);
}

/** High-level: send an async command and wait for completion */
export async function callAsync(type: string, payload: Record<string, unknown> = {}, timeout?: number): Promise<AgentResult> {
  const id = writeCommand(type, payload);
  return waitForAsync(id, timeout ?? TIMEOUT_DUMP);
}

// ── Dump file utilities ───────────────────────────────────────────────────

export function listDumpFiles(): { name: string; path: string; size: number; modified: Date }[] {
  if (!fs.existsSync(DUMPS_DIR)) return [];
  return fs.readdirSync(DUMPS_DIR)
    .filter(f => f.endsWith(".txt"))
    .map(name => {
      const full = path.join(DUMPS_DIR, name);
      const stat = fs.statSync(full);
      return { name, path: full, size: stat.size, modified: stat.mtime };
    })
    .sort((a, b) => b.modified.getTime() - a.modified.getTime());
}

export function readDumpLines(filePath: string, offset = 0, limit = 500): string[] {
  if (!fs.existsSync(filePath)) throw new Error(`Dump not found: ${filePath}`);
  const all = fs.readFileSync(filePath, "utf8").split("\n");
  return all.slice(offset, offset + limit);
}

export function grepDump(filePath: string, pattern: string): string[] {
  if (!fs.existsSync(filePath)) throw new Error(`Dump not found: ${filePath}`);
  const re = new RegExp(pattern, "i");
  return fs.readFileSync(filePath, "utf8")
    .split("\n")
    .filter(line => re.test(line));
}
