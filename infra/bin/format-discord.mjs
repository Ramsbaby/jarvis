#!/usr/bin/env node
/**
 * format-discord.mjs — Pipe filter: applies formatForDiscord to stdin.
 * Usage: echo "text" | node format-discord.mjs [channelId]
 *
 * Pre-send validation:
 *   Set DISCORD_VALIDATION_FILE env var to a writable path.
 *   Issues JSON will be written there for the caller to inspect.
 *   Validation failure is non-fatal — message always passes through stdout.
 */
import { formatForDiscord, validateForDiscord } from '../discord/lib/format-pipeline.js';
import { writeFileSync } from 'fs';

const channelId = process.argv[2] || undefined;
const validationFile = process.env.DISCORD_VALIDATION_FILE || '';

const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
const input = Buffer.concat(chunks).toString('utf-8');

const formatted = formatForDiscord(input, { channelId });
process.stdout.write(formatted);

// Pre-send validation — write issues JSON to temp file if caller requested
if (validationFile) {
  try {
    const issues = validateForDiscord(formatted);
    writeFileSync(validationFile, JSON.stringify(issues), 'utf8');
  } catch {
    // Swallow — validation failure must not block message delivery
  }
}
