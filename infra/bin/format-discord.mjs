#!/usr/bin/env node
/**
 * format-discord.mjs — Pipe filter: applies formatForDiscord to stdin.
 * Usage: echo "text" | node format-discord.mjs [channelId]
 */
import { formatForDiscord } from '../discord/lib/format-pipeline.js';

const channelId = process.argv[2] || undefined;
const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
const input = Buffer.concat(chunks).toString('utf-8');
process.stdout.write(formatForDiscord(input, { channelId }));
