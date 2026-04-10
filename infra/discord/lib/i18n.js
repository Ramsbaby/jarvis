/**
 * Lightweight i18n — loads a flat JSON locale file at startup.
 *
 * Usage:
 *   import { t } from './i18n.js';
 *   t('cmd.clear.done')              // "Session cleared."
 *   t('cmd.stop.stopping', { botName: 'Jarvis' })  // "Stopping Jarvis process..."
 *
 * Set BOT_LOCALE env var to switch language (default: 'en').
 * Locale files live in discord/locales/{locale}.json.
 */

import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const locale = process.env.BOT_LOCALE || 'ko';
const localePath = join(__dirname, '..', 'locales', `${locale}.json`);

let messages;
try {
  messages = JSON.parse(readFileSync(localePath, 'utf-8'));
} catch (err) {
  console.error(`[i18n] Failed to load locale "${locale}" from ${localePath}: ${err.message}`);
  console.error('[i18n] Falling back to empty messages (keys will be shown as-is)');
  messages = {};
}

/**
 * Translate a message key, optionally interpolating {param} placeholders.
 * Returns the key itself if no translation is found (safe fallback).
 */
export function t(key, params = {}) {
  let msg = messages[key] ?? key;
  for (const [k, v] of Object.entries(params)) {
    msg = msg.replaceAll(`{${k}}`, String(v));
  }
  return msg;
}
