// plugin-loader.js — Jarvis Plugin System
//
// 플러그인은 $BOT_HOME/plugins/<name>/index.js 에 위치하며,
// upstream 업데이트와 완전히 분리된 영역에서 관리된다.
//
// 플러그인 인터페이스:
// export default {
//   name: 'my-plugin',          // 필수
//   version: '1.0.0',           // 선택
//   slashCommands: [],          // SlashCommandBuilder[] — registerSlashCommands에서 병합
//   async onReady(client, ctx) {},      // 봇 시작 시 호출
//   async onInteraction(i, ctx) {},     // interaction 처리 → true 반환 시 이후 핸들러 건너뜀
//   async onMessage(msg, ctx) {},       // messageCreate 시 호출 (선택)
// }
//
// ctx = { log, env: process.env, BOT_HOME }

import { existsSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

/**
 * $BOT_HOME/plugins/ 아래의 플러그인을 로드한다.
 * config/plugins.json 의 enabled 목록만 활성화.
 * 파일이 없거나 enabled 없으면 플러그인 없이 조용히 통과.
 *
 * @param {string} botHome
 * @param {{ log: Function, env: NodeJS.ProcessEnv, BOT_HOME: string }} ctx
 * @returns {Promise<Array>}
 */
export async function loadPlugins(botHome, ctx) {
  const { log } = ctx;
  const pluginsDir = join(botHome, 'plugins');
  const configPath = join(botHome, 'config', 'plugins.json');

  // plugins.json 없으면 플러그인 없이 시작
  if (!existsSync(configPath)) {
    log('info', '[PluginLoader] config/plugins.json 없음 — 플러그인 비활성화');
    return [];
  }

  let enabledNames;
  try {
    const raw = readFileSync(configPath, 'utf-8');
    const cfg = JSON.parse(raw);
    enabledNames = Array.isArray(cfg.enabled) ? cfg.enabled : [];
  } catch (e) {
    log('warn', '[PluginLoader] plugins.json 파싱 실패', { error: e.message });
    return [];
  }

  if (enabledNames.length === 0) {
    log('info', '[PluginLoader] 활성화된 플러그인 없음');
    return [];
  }

  const loaded = [];

  for (const name of enabledNames) {
    const pluginPath = join(pluginsDir, name, 'index.js');
    if (!existsSync(pluginPath)) {
      log('warn', `[PluginLoader] 플러그인 파일 없음 — 건너뜀: ${name}`, { path: pluginPath });
      continue;
    }

    try {
      // fileURL 변환 (ESM dynamic import는 절대경로 file:// 필요)
      const fileUrl = `file://${resolve(pluginPath)}`;
      const mod = await import(fileUrl);
      const plugin = mod.default ?? mod;

      if (!plugin?.name) {
        log('warn', `[PluginLoader] name 필드 없음 — 건너뜀: ${name}`);
        continue;
      }

      loaded.push(plugin);
      log('info', `[PluginLoader] 로드 완료: ${plugin.name}${plugin.version ? ` v${plugin.version}` : ''}`);
    } catch (e) {
      log('error', `[PluginLoader] 로드 실패: ${name}`, { error: e.message, stack: e.stack?.slice(0, 300) });
    }
  }

  log('info', `[PluginLoader] ${loaded.length}/${enabledNames.length}개 플러그인 활성화`);
  return loaded;
}
