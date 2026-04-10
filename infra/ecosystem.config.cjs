/**
 * PM2 Ecosystem Config — Jarvis
 * Replaces all macOS .plist launchd agents.
 * Works on macOS / Linux / Windows (WSL2 or Docker).
 *
 * Usage:
 *   pm2 start ecosystem.config.cjs
 *   pm2 startup && pm2 save
 */

const JARVIS_HOME = process.env.JARVIS_HOME || require('os').homedir() + '/.jarvis'

module.exports = {
  apps: [
    {
      name: 'jarvis-bot',
      script: 'discord-bot.js',
      cwd: `${JARVIS_HOME}/discord`,
      watch: false,
      autorestart: true,
      restart_delay: 10000,
      max_restarts: 20,
      env: {
        NODE_ENV: 'production',
        BOT_HOME: JARVIS_HOME
      },
      out_file: `${JARVIS_HOME}/logs/discord-bot.out.log`,
      error_file: `${JARVIS_HOME}/logs/discord-bot.err.log`,
      log_date_format: 'YYYY-MM-DD HH:mm:ss'
    },
    {
      name: 'jarvis-rag-watcher',
      script: 'lib/rag-watch.mjs',
      cwd: JARVIS_HOME,
      interpreter: 'node',
      interpreter_args: '--max-old-space-size=150',
      watch: false,
      autorestart: true,
      restart_delay: 5000,
      env: {
        BOT_HOME: JARVIS_HOME
      },
      out_file: `${JARVIS_HOME}/logs/rag-watch.log`,
      error_file: `${JARVIS_HOME}/logs/rag-watch.log`,
      log_date_format: 'YYYY-MM-DD HH:mm:ss'
    },
    {
      name: 'jarvis-watchdog',
      script: 'scripts/watchdog.sh',
      cwd: JARVIS_HOME,
      interpreter: 'bash',
      watch: false,
      autorestart: true,
      restart_delay: 5000,
      env: {
        HOME: require('os').homedir(),
        BOT_HOME: JARVIS_HOME
      },
      out_file: `${JARVIS_HOME}/logs/watchdog.out.log`,
      error_file: `${JARVIS_HOME}/logs/watchdog.err.log`,
      log_date_format: 'YYYY-MM-DD HH:mm:ss'
    },
    {
      name: 'jarvis-event-watcher',
      script: 'scripts/event-watcher.sh',
      cwd: JARVIS_HOME,
      interpreter: 'bash',
      watch: false,
      autorestart: true,
      restart_delay: 5000,
      env: {
        HOME: require('os').homedir(),
        BOT_HOME: JARVIS_HOME
      },
      out_file: `${JARVIS_HOME}/logs/event-watcher.out.log`,
      error_file: `${JARVIS_HOME}/logs/event-watcher.err.log`,
      log_date_format: 'YYYY-MM-DD HH:mm:ss'
    },
    {
      name: 'jarvis-boot-auth-check',
      script: 'scripts/boot-auth-check.sh',
      cwd: JARVIS_HOME,
      interpreter: 'bash',
      watch: false,
      autorestart: false,      // RunAtLoad only, no KeepAlive
      env: {
        HOME: require('os').homedir(),
        BOT_HOME: JARVIS_HOME
      },
      out_file: `${JARVIS_HOME}/logs/boot-auth-check.log`,
      error_file: `${JARVIS_HOME}/logs/boot-auth-check.log`,
      log_date_format: 'YYYY-MM-DD HH:mm:ss'
    }
  ]
}
