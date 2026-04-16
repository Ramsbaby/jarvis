import { t } from './i18n.js';
import { appendFeed } from './channel-feed.js';
import { reportFormat, kstFooter } from './formatters.js';

class AlertBatcher {
  constructor({ windowMs = 30_000 } = {}) {
    this.windowMs = windowMs;
    this.channel = null;
    this.channelName = null;
    this.queue = [];
    this.timer = null;
  }

  init(channel) {
    this.channel = channel;
    this.channelName = channel?.name ?? null;
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

    const items = alerts.map(a => ({
      state: a.level === 'high' || a.level === 'urgent' ? 'error' : 'warn',
      label: a.title,
      value: a.message,
    }));

    const text = reportFormat({
      title: t('alert.batch.title', { count: alerts.length }),
      items,
      footer: kstFooter(),
    });

    const description = alerts
      .map(a => `• **${a.title}**: ${a.message}`)
      .join('\n');

    if (this.channel) {
      await this.channel.send(text);
      if (this.channelName) {
        appendFeed(this.channelName, 'alert', description);
      }
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
