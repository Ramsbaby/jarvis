/**
 * L3 Approval Workflow — Discord button-based approval for autonomous actions.
 *
 * Exports:
 *   requestApproval(channel, opts)          — send Approve/Reject buttons
 *   handleApprovalInteraction(interaction)   — process button clicks
 *   pollL3Requests(client)                  — pick up bash-originated .json requests
 */

// discord.js is CJS — use default import to avoid ESM named-export errors
import discordPkg from 'discord.js';
const { ActionRowBuilder, ButtonBuilder, ButtonStyle, MessageFlags } = discordPkg;
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { t } from './i18n.js';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const PENDING_FILE = join(BOT_HOME, 'state', 'pending-approvals.json');
const L3_REQUESTS_DIR = join(BOT_HOME, 'state', 'l3-requests');

// ---------------------------------------------------------------------------
// Persistence helpers
// ---------------------------------------------------------------------------

function loadPending() {
  if (!existsSync(PENDING_FILE)) return {};
  try { return JSON.parse(readFileSync(PENDING_FILE, 'utf8')); } catch { return {}; }
}

function savePending(data) {
  mkdirSync(join(BOT_HOME, 'state'), { recursive: true });
  writeFileSync(PENDING_FILE, JSON.stringify(data, null, 2));
}

function cleanExpired() {
  const pending = loadPending();
  const now = Date.now();
  let changed = false;
  for (const [id, entry] of Object.entries(pending)) {
    if (entry.expiresAt && new Date(entry.expiresAt).getTime() < now) {
      delete pending[id];
      changed = true;
    }
  }
  if (changed) savePending(pending);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Send an approval request to a Discord channel with Approve/Reject buttons.
 * @param {import('discord.js').TextChannel} channel
 * @param {{ label: string, description: string, script: string, args?: string[] }} opts
 * @returns {Promise<string>} actionId
 */
export async function requestApproval(channel, { label, description, script, args = [] }) {
  cleanExpired();

  const actionId = randomUUID();
  const now = new Date();
  const expiresAt = new Date(now.getTime() + 24 * 60 * 60 * 1000).toISOString();

  const row = new ActionRowBuilder().addComponents(
    new ButtonBuilder()
      .setCustomId(`l3approve:${actionId}`)
      .setLabel(t('l3.button.approve'))
      .setStyle(ButtonStyle.Success),
    new ButtonBuilder()
      .setCustomId(`l3reject:${actionId}`)
      .setLabel(t('l3.button.reject'))
      .setStyle(ButtonStyle.Danger),
  );

  const msg = await channel.send({
    content: `${t('l3.request.title')}\n**${label}**\n${description}`,
    components: [row],
  });

  const pending = loadPending();
  pending[actionId] = {
    label,
    description,
    script,
    args,
    requestedAt: now.toISOString(),
    expiresAt,
    channelId: channel.id,
    messageId: msg.id,
  };
  savePending(pending);

  return actionId;
}

/**
 * Handle a button interaction from interactionCreate.
 * @returns {Promise<boolean>} true if this interaction was an L3 approval button
 */
export async function handleApprovalInteraction(interaction) {
  if (!interaction.isButton()) return false;

  const { customId } = interaction;

  // --- LanceDB compact 버튼 ---
  if (customId === 'lancedb_compact') {
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    try {
      const compactScript = join(BOT_HOME, 'scripts', 'rag-compact-wrapper.sh');
      execFileSync('/bin/bash', [compactScript], { timeout: 120000 });
      await interaction.editReply('✅ Compact 완료됐습니다.');
    } catch (err) {
      await interaction.editReply(`❌ Compact 실패: ${err.message?.slice(0, 200)}`);
    }
    // 버튼 제거 (best effort)
    try { await interaction.message.edit({ components: [] }); } catch { /* ignore */ }
    return true;
  }

  if (!customId.startsWith('l3approve:') && !customId.startsWith('l3reject:')) return false;

  const [action, actionId] = customId.split(':');
  cleanExpired();
  const pending = loadPending();
  const entry = pending[actionId];

  if (!entry) {
    await interaction.reply({ content: t('l3.error.expired'), flags: MessageFlags.Ephemeral });
    return true;
  }

  delete pending[actionId];
  savePending(pending);

  if (action === 'l3reject') {
    // Update original message to show rejection, remove buttons
    await interaction.update({
      content: t('l3.result.rejected', { label: entry.label }),
      components: [],
    });
    return true;
  }

  // Approve: defer, execute, report result
  await interaction.deferReply();
  const result = execApprovedAction(entry);
  await interaction.editReply({ content: `${t('l3.result.approved', { label: entry.label })}\n\`\`\`\n${result}\n\`\`\`` });

  // Remove buttons from original message
  try {
    const channel = interaction.channel;
    if (channel && entry.messageId) {
      const origMsg = await channel.messages.fetch(entry.messageId).catch(() => null);
      if (origMsg) {
        await origMsg.edit({ components: [] });
      }
    }
  } catch { /* best effort */ }

  return true;
}

/**
 * Execute an approved L3 action script.
 * Uses execFileSync (no shell) for safety.
 * @returns {string} stdout (truncated to 1500 chars)
 */
function execApprovedAction({ script, args = [] }) {
  // Resolve script path: bare name → l3-actions dir, absolute path → as-is
  const scriptPath = script.startsWith('/')
    ? script
    : join(BOT_HOME, 'scripts', 'l3-actions', script);
  try {
    const output = execFileSync(scriptPath, args, {
      timeout: 30_000,
      encoding: 'utf8',
      env: { ...process.env, BOT_HOME },
    });
    return (output || '').trim().slice(0, 1500) || '(no output)';
  } catch (err) {
    const stderr = err.stderr ? String(err.stderr).trim() : '';
    const msg = stderr || err.message || 'Unknown error';
    return `ERROR: ${msg.slice(0, 500)}`;
  }
}

/**
 * Read l3_channel_id from monitoring.json (fallback for bash requests without channelId).
 */
function getL3ChannelId() {
  try {
    const cfg = JSON.parse(readFileSync(join(BOT_HOME, 'config', 'monitoring.json'), 'utf8'));
    return cfg.l3_channel_id || '';
  } catch { return ''; }
}

/**
 * Poll l3-requests directory for bash-originated approval requests.
 * Called on a 10s interval from the bot.
 */
export async function pollL3Requests(client) {
  if (!existsSync(L3_REQUESTS_DIR)) return;

  const files = readdirSync(L3_REQUESTS_DIR).filter(f => f.endsWith('.json'));
  for (const file of files) {
    const filePath = join(L3_REQUESTS_DIR, file);
    try {
      const req = JSON.parse(readFileSync(filePath, 'utf8'));
      unlinkSync(filePath); // consume immediately

      // channelId: from JSON if present, else from monitoring.json l3_channel_id
      const channelId = req.channelId || getL3ChannelId();
      if (!channelId) {
        console.error(`[approval] pollL3Requests: no channelId for ${file}, skipping`);
        continue;
      }

      const channel = client.channels.cache.get(channelId) ||
        await client.channels.fetch(channelId).catch(() => null);
      if (!channel) continue;

      await requestApproval(channel, req);
    } catch (err) {
      console.error(`[approval] pollL3Requests error: ${err.message}`);
    }
  }
}