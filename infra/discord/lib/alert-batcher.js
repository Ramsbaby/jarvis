import discordPkg from 'discord.js';
const { EmbedBuilder } = discordPkg;
import { t } from './i18n.js';

class AlertBatcher {
  constructor({ windowMs = 30_000 } = {}) {
    this.windowMs = windowMs;
    this.channel = null;
    this.queue = [];
    this.timer = null;
  }

  init(channel) {
    this.channel = channel;
  }

  push({ title, message, level = 'default' }) {
    this.queue.push({ title, message, level });

    if (this.queue.length === 1) {
      this.timer = setTimeout(() => this.flush(), this.windowMs);
    }
  }

  async flush() {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }

    if (this.queue.length === 0) {
      return;
    }

    const alerts = this.queue.splice(0);

    const hasHighLevel = alerts.some(a => a.level === 'high' || a.level === 'urgent');
    const color = hasHighLevel ? 0xe74c3c : 0xf39c12; // red : yellow

    const description = alerts
      .map(a => `• **${a.title}**: ${a.message}`)
      .join('\n');

    const embed = new EmbedBuilder()
      .setColor(color)
      .setTitle(t('alert.batch.title', { count: alerts.length }))
      .setDescription(description)
      .setTimestamp();

    if (this.channel) {
      await this.channel.send({ embeds: [embed] });
    }
  }

  async shutdown() {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    await this.flush();
  }
}

export default AlertBatcher;
export const botAlerts = new AlertBatcher();
export function initAlertBatcher(channel) {
  botAlerts.init(channel);
}
