#!/usr/bin/env node
/**
 * plist-env-audit.mjs — plist 환경변수 무결성 자동 감사 (Harness R3 가드)
 *
 * 사고 사례 (2026-04-27): ai.jarvis.discord-bot.plist의 INTERVIEW_CHANNEL이
 * '[일반 채널]'로 오타 설정되어 일반 채널이 모의면접 채널로 둔갑.
 * #[일반 채널]의 모든 turn에서 saveSessionSummary + 학습 hook 차단됨.
 * 그동안 디스코드 자비스가 #[일반 채널]에서 멍청해 보인 진짜 root cause.
 *
 * 본 audit는 plist 환경변수가 코드 하드코딩 채널명과 일치하는지 검증.
 * 불일치 발견 시 exit 1 + Discord 알림 (--notify).
 *
 * 사용:
 *   node infra/scripts/plist-env-audit.mjs           # 보고만
 *   node infra/scripts/plist-env-audit.mjs --notify  # 불일치 시 Discord 알림
 */

import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { spawnSync } from 'node:child_process';

const HOME = homedir();
const NOTIFY = process.argv.includes('--notify');

// 검증 매트릭스: plist env key → 매칭되어야 할 코드 위치
const RULES = [
  {
    plistFile: join(HOME, 'Library/LaunchAgents/ai.jarvis.discord-bot.plist'),
    envKey: 'INTERVIEW_CHANNEL',
    expectedSources: [
      { file: join(HOME, 'jarvis/infra/discord/lib/interview-fast-path.js'), pattern: /CHANNEL_NAME\s*=\s*['"]([^'"]+)['"]/ },
      { file: join(HOME, 'jarvis/infra/discord/lib/handlers.js'), pattern: /chName\s*===\s*['"]([a-z-]+)['"]/ },
    ],
  },
  {
    // R4: 채널 ID 정합성 — slash-proxy.js의 INTERVIEW_CHANNEL_ID와 plist LITE_CHANNEL_ID는 다른 채널이지만,
    // INTERVIEW_CHANNEL_ID 자체가 코드 내부에서 일관된지 검증.
    plistFile: join(HOME, 'jarvis/infra/discord/lib/slash-proxy.js'),
    envKey: 'INTERVIEW_CHANNEL_ID',
    customExtractor: (file) => {
      if (!existsSync(file)) return { found: false, value: null };
      const content = readFileSync(file, 'utf-8');
      const m = content.match(/INTERVIEW_CHANNEL_ID\s*=\s*['"]([0-9]+)['"]/);
      return m ? { found: true, value: m[1] } : { found: false, value: null };
    },
    expectedSources: [
      // personas.json에 같은 채널 ID 키로 페르소나 정의 존재해야 함
      { file: join(HOME, 'jarvis/infra/discord/personas.json'), pattern: /"(149[0-9]{16})"\s*:/ },
    ],
  },
];

function extractPlistEnv(plistPath, envKey) {
  if (!existsSync(plistPath)) return { found: false, value: null };
  const content = readFileSync(plistPath, 'utf-8');
  // <key>INTERVIEW_CHANNEL</key>\n\t\t<string>jarvis-interview</string>
  const re = new RegExp(`<key>${envKey}</key>\\s*<string>([^<]+)</string>`);
  const m = content.match(re);
  return m ? { found: true, value: m[1] } : { found: false, value: null };
}

function extractCodeValue(filePath, pattern) {
  if (!existsSync(filePath)) return null;
  const content = readFileSync(filePath, 'utf-8');
  const m = content.match(pattern);
  return m ? m[1] : null;
}

const violations = [];
const checks = [];

for (const rule of RULES) {
  const plistVal = rule.customExtractor
    ? rule.customExtractor(rule.plistFile)
    : extractPlistEnv(rule.plistFile, rule.envKey);
  if (!plistVal.found) {
    violations.push({
      key: rule.envKey,
      reason: 'plist 환경변수 부재',
      plist: rule.plistFile,
    });
    continue;
  }
  for (const src of rule.expectedSources) {
    const codeVal = extractCodeValue(src.file, src.pattern);
    if (!codeVal) {
      // P0-3: unknown은 silent fallback 금지 — 정규식 미매칭이 진짜 부재인지 패턴 결함인지 모름
      checks.push({ ok: 'unknown', key: rule.envKey, file: src.file, plistVal: plistVal.value, codeVal: null });
      violations.push({
        key: rule.envKey,
        reason: `code 패턴 미매칭 (file 부재 또는 정규식 결함) — silent fallback 차단`,
        plist: rule.plistFile,
        codeFile: src.file,
      });
      continue;
    }
    const match = plistVal.value === codeVal;
    checks.push({ ok: match ? 'pass' : 'fail', key: rule.envKey, file: src.file, plistVal: plistVal.value, codeVal });
    if (!match) {
      violations.push({
        key: rule.envKey,
        reason: `plist=${plistVal.value} ≠ code=${codeVal}`,
        plist: rule.plistFile,
        codeFile: src.file,
      });
    }
  }
}

console.log('# 🔍 plist 환경변수 무결성 audit\n');
for (const c of checks) {
  const icon = c.ok === 'pass' ? '✅' : c.ok === 'fail' ? '❌' : '⚠️';
  console.log(`${icon} ${c.key}: plist="${c.plistVal}" / code="${c.codeVal ?? 'NOT_FOUND'}" (${c.file.replace(HOME, '~')})`);
}
console.log('');
if (violations.length === 0) {
  console.log('🎉 모든 plist 환경변수와 코드 하드코딩 일치.');
  process.exit(0);
}

console.log(`🚨 위반 ${violations.length}건:`);
for (const v of violations) {
  console.log(`  - ${v.key}: ${v.reason}`);
  console.log(`    plist: ${v.plist}`);
  if (v.codeFile) console.log(`    code:  ${v.codeFile}`);
}

if (NOTIFY) {
  const notifyScript = join(HOME, '.jarvis/scripts/discord-visual.mjs');
  if (existsSync(notifyScript)) {
    const data = JSON.stringify({
      title: '🚨 plist 환경변수 불일치 감지',
      data: Object.fromEntries(violations.slice(0, 5).map((v, i) => [`위반${i + 1}`, `${v.key}: ${v.reason}`])),
      timestamp: new Date().toISOString().slice(0, 16).replace('T', ' '),
    });
    spawnSync('node', [notifyScript, '--type', 'stats', '--data', data, '--channel', 'jarvis-system'], {
      timeout: 10_000, stdio: 'inherit',
    });
  }
}

process.exit(1);
