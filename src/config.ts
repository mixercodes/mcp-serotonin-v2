import path from "path";

// Root of Serotonin's sandboxed file system
export const SEROTONIN_FILES = "C:\\Serotonin\\files";

// Agent IPC directory — all communication files live here
export const AGENT_DIR   = path.join(SEROTONIN_FILES, "agent");
export const CMD_FILE    = path.join(AGENT_DIR, "cmd.lua");      // Node writes, Lua reads
export const RESULT_FILE = path.join(AGENT_DIR, "result.json");  // Lua writes, Node reads
export const STATUS_FILE = path.join(AGENT_DIR, "status.json");  // Lua writes during async ops

// Dump output directory
export const DUMPS_DIR = path.join(SEROTONIN_FILES, "dumps");

// Polling intervals (ms)
export const POLL_FAST   = 100;   // sync commands
export const POLL_SLOW   = 500;   // async ops (dump)

// Timeouts (ms)
export const TIMEOUT_SYNC  = 10_000;   // eval, ping, inspect
export const TIMEOUT_DUMP  = 120_000;  // workspace dump (large games can take ~60s)
