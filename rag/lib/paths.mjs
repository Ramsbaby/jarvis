/**
 * paths.mjs — Central path resolution for the RAG module
 *
 * Priority: JARVIS_RAG_HOME > BOT_HOME/rag > ~/.local/share/jarvis/rag
 *
 * - Owner (BOT_HOME=~/.jarvis set): uses existing ~/.jarvis/rag/
 * - New user (nothing set): uses XDG-compliant ~/.local/share/jarvis/rag/
 */

import { join } from 'node:path';
import { homedir } from 'node:os';
import { mkdirSync } from 'node:fs';

// ── Data directory (LanceDB, index-state, access-log) ──
export const RAG_HOME = process.env.JARVIS_RAG_HOME
  || (process.env.BOT_HOME && join(process.env.BOT_HOME, 'rag'))
  || join(homedir(), '.local', 'share', 'jarvis', 'rag');

// ── Infrastructure home (logs, state, config — NOT rag data) ──
export const INFRA_HOME = process.env.BOT_HOME
  || join(homedir(), '.local', 'share', 'jarvis');

// ── Derived paths ──
export const LANCEDB_PATH    = join(RAG_HOME, 'lancedb');
export const INDEX_STATE_PATH = join(RAG_HOME, 'index-state.json');
export const ACCESS_LOG_PATH  = join(RAG_HOME, 'access-log.json');
export const INCIDENTS_PATH   = join(RAG_HOME, 'incidents.md');
export const ENTITY_GRAPH_PATH = join(RAG_HOME, 'entity-graph.json');

// ── Write lock (in RAG_HOME, not /tmp — multi-user safe) ──
export const RAG_WRITE_LOCK  = join(RAG_HOME, 'write.lock');

// ── Logs & state ──
export const LOG_DIR   = join(INFRA_HOME, 'logs');
export const STATE_DIR = join(INFRA_HOME, 'state');
export const RAG_LOG_FILE = join(LOG_DIR, 'rag-index.log');
export const RAG_LOCK_DIR = join(STATE_DIR, 'rag-locks');

/**
 * Ensure essential directories exist (safe to call multiple times).
 */
export function ensureDirs() {
  for (const dir of [RAG_HOME, LOG_DIR, STATE_DIR, RAG_LOCK_DIR]) {
    mkdirSync(dir, { recursive: true });
  }
}
