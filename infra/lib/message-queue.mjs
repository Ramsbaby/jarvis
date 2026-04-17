/**
 * SQLite Event Bus - Agent-to-agent async message queue
 *
 * ACID-guaranteed message passing via SQLite WAL mode.
 * No external services (Redis/NATS) required.
 *
 * Usage:
 *   import { init, send, receive, ack, fail, cleanup, stats } from './message-queue.mjs';
 *   init();
 *   send('cron-agent', 'system', { task: 'health-check' });
 *   const msgs = receive('discord-bot', { channel: 'system' });
 *   ack(msgs[0].id);
 */

import Database from 'better-sqlite3';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { mkdirSync } from 'node:fs';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const DB_PATH = join(BOT_HOME, 'state', 'messages.db');

const PRIORITY_ORDER = { urgent: 0, high: 1, normal: 2 };

let db = null;

function getDb() {
  if (!db) {
    throw new Error('Message queue not initialized. Call init() first.');
  }
  return db;
}

/**
 * Initialize the database: create schema, enable WAL mode.
 */
export function init() {
  mkdirSync(join(BOT_HOME, 'state'), { recursive: true });

  db = new Database(DB_PATH);
  db.pragma('journal_mode = WAL');
  db.pragma('synchronous = NORMAL');

  db.exec(`
    CREATE TABLE IF NOT EXISTS messages (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      sender       TEXT NOT NULL,
      recipient    TEXT,
      channel      TEXT NOT NULL,
      priority     TEXT NOT NULL DEFAULT 'normal',
      payload      TEXT NOT NULL,
      reply_to     INTEGER,
      status       TEXT NOT NULL DEFAULT 'pending',
      created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      processed_at TEXT,
      ttl_seconds  INTEGER NOT NULL DEFAULT 3600
    );
    CREATE INDEX IF NOT EXISTS idx_rcpt_status ON messages(recipient, status);
    CREATE INDEX IF NOT EXISTS idx_channel     ON messages(channel, status);
    CREATE INDEX IF NOT EXISTS idx_created     ON messages(created_at);
  `);

  return db;
}

/**
 * Send a message to a channel.
 *
 * @param {string} sender - Who sends the message
 * @param {string} channel - Target channel (e.g. 'system', 'discord', 'cron')
 * @param {object|string} payload - Message content (objects are JSON-stringified)
 * @param {object} [opts]
 * @param {string} [opts.recipient] - Specific recipient (null = broadcast to channel)
 * @param {string} [opts.priority='normal'] - 'urgent' | 'high' | 'normal'
 * @param {number} [opts.replyTo] - ID of the message being replied to
 * @param {number} [opts.ttl=3600] - Time-to-live in seconds
 * @returns {{ id: number, changes: number }}
 */
export function send(sender, channel, payload, opts = {}) {
  const {
    recipient = null,
    priority = 'normal',
    replyTo = null,
    ttl = 3600,
  } = opts;

  const payloadStr = typeof payload === 'string' ? payload : JSON.stringify(payload);

  const stmt = getDb().prepare(`
    INSERT INTO messages (sender, recipient, channel, priority, payload, reply_to, ttl_seconds)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  `);

  const result = stmt.run(sender, recipient, channel, priority, payloadStr, replyTo, ttl);
  return { id: Number(result.lastInsertRowid), changes: result.changes };
}

/**
 * Receive pending messages for a recipient.
 * TTL-expired messages are auto-failed.
 *
 * @param {string} recipient - Who is receiving
 * @param {object} [opts]
 * @param {string} [opts.channel] - Filter by channel
 * @param {number} [opts.limit=10] - Max messages to return
 * @param {boolean} [opts.markProcessing=true] - Mark returned messages as 'processing'
 * @returns {Array<object>} Messages sorted by priority (urgent first), then creation time
 */
export function receive(recipient, opts = {}) {
  const {
    channel = null,
    limit = 10,
    markProcessing = true,
  } = opts;

  const d = getDb();

  // Auto-fail TTL-expired pending messages for this recipient
  d.prepare(`
    UPDATE messages
    SET status = 'failed', processed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
    WHERE status = 'pending'
      AND (recipient = ? OR recipient IS NULL)
      AND cast((julianday('now') - julianday(created_at)) * 86400 as integer) > ttl_seconds
  `).run(recipient);

  // Build query with optional channel filter
  let query = `
    SELECT * FROM messages
    WHERE status = 'pending'
      AND (recipient = ? OR recipient IS NULL)
  `;
  const params = [recipient];

  if (channel) {
    query += ' AND channel = ?';
    params.push(channel);
  }

  query += `
    ORDER BY
      CASE priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 ELSE 2 END,
      created_at ASC
    LIMIT ?
  `;
  params.push(limit);

  const rows = d.prepare(query).all(...params);

  // Parse payload JSON and mark as processing
  const markStmt = markProcessing
    ? d.prepare(`UPDATE messages SET status = 'processing', processed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`)
    : null;

  const markAll = markProcessing
    ? d.transaction((ids) => { for (const id of ids) markStmt.run(id); })
    : null;

  if (markProcessing && rows.length > 0) {
    markAll(rows.map(r => r.id));
  }

  return rows.map(row => {
    let parsed = row.payload;
    try { parsed = JSON.parse(row.payload); } catch { /* keep as string */ }
    return { ...row, payload: parsed };
  });
}

/**
 * Acknowledge a message as successfully processed.
 * @param {number} id - Message ID
 * @returns {{ changes: number }}
 */
export function ack(id) {
  const result = getDb().prepare(`
    UPDATE messages
    SET status = 'done', processed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
    WHERE id = ?
  `).run(id);
  return { changes: result.changes };
}

/**
 * Mark a message as failed.
 * @param {number} id - Message ID
 * @param {string} [reason] - Failure reason (stored in payload as JSON wrapper)
 * @returns {{ changes: number }}
 */
export function fail(id, reason) {
  const d = getDb();
  if (reason) {
    const row = d.prepare('SELECT payload FROM messages WHERE id = ?').get(id);
    if (row) {
      const wrapped = JSON.stringify({ _original: row.payload, _error: reason });
      d.prepare('UPDATE messages SET payload = ? WHERE id = ?').run(wrapped, id);
    }
  }
  const result = d.prepare(`
    UPDATE messages
    SET status = 'failed', processed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
    WHERE id = ?
  `).run(id);
  return { changes: result.changes };
}

/**
 * Delete messages older than 7 days that are done or failed.
 * @returns {{ changes: number }}
 */
export function cleanup() {
  const result = getDb().prepare(`
    DELETE FROM messages
    WHERE status IN ('done', 'failed')
      AND created_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-7 days')
  `).run();
  return { changes: result.changes };
}

/**
 * Get queue statistics.
 * @returns {{ pending: number, processing: number, done: number, failed: number }}
 */
export function stats() {
  const rows = getDb().prepare(`
    SELECT status, COUNT(*) as count FROM messages GROUP BY status
  `).all();

  const result = { pending: 0, processing: 0, done: 0, failed: 0 };
  for (const row of rows) {
    if (row.status in result) {
      result[row.status] = row.count;
    }
  }
  return result;
}

/**
 * Close the database connection.
 */
export function close() {
  if (db) {
    db.close();
    db = null;
  }
}