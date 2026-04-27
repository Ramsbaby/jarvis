#!/usr/bin/env node
/**
 * dump-system-prompt.mjs — 시스템 프롬프트 실측 도구 (Harness P1)
 *
 * Discord 봇이 매 turn마다 ~/jarvis/runtime/state/system-prompt-snapshot.md 에
 * 실제 LLM 입력을 덮어쓰기 저장한다 (claude-runner.js:1311 직후 hook).
 *
 * 이 도구는 그 스냅샷을 읽어 다음을 보고:
 * - 총 char / 추정 토큰 수
 * - 섹션별 char 분포 (헤더 기반 split)
 * - learned-mistakes top5 실제 주입 여부 + 잘림 위치
 * - 분노 신호 주입 여부 (Harness P2)
 * - 다른 표면(추정값) vs 실측 비교
 *
 * 사용:
 *   node infra/scripts/dump-system-prompt.mjs            # 보고
 *   node infra/scripts/dump-system-prompt.mjs --raw      # 원본 출력
 *   node infra/scripts/dump-system-prompt.mjs --sections # 섹션별 분해만
 */

import { readFileSync, existsSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const SNAPSHOT_FILE = join(BOT_HOME, 'state', 'system-prompt-snapshot.md');

const RAW = process.argv.includes('--raw');
const SECTIONS_ONLY = process.argv.includes('--sections');

if (!existsSync(SNAPSHOT_FILE)) {
  console.error(`❌ 스냅샷 파일 부재: ${SNAPSHOT_FILE}`);
  console.error(`   디스코드 봇이 turn 1회 처리하면 자동 생성됩니다.`);
  console.error(`   봇 동작 확인: launchctl list | grep ai.jarvis.discord-bot`);
  process.exit(1);
}

const stat = statSync(SNAPSHOT_FILE);
const ageMin = Math.round((Date.now() - stat.mtimeMs) / 60000);
const raw = readFileSync(SNAPSHOT_FILE, 'utf-8');

if (RAW) {
  process.stdout.write(raw);
  process.exit(0);
}

// 헤더 메타 / 본문 분리
const sepIdx = raw.indexOf('\n---\n\n');
const meta = sepIdx >= 0 ? raw.slice(0, sepIdx) : '';
const body = sepIdx >= 0 ? raw.slice(sepIdx + 6) : raw;

// 메타 파싱
const metaMap = {};
for (const line of meta.split('\n')) {
  const m = line.match(/^([\w_]+):\s*(.+)$/);
  if (m) metaMap[m[1]] = m[2].trim();
}

const totalChars = body.length;
const estTokens = Math.round(totalChars / 4); // Anthropic 대략 4 chars/token

// 섹션 분해 (헤더 기반)
const sections = [];
const sectionRegex = /^(#{1,3}\s+.+|---\s+위키\s+컨텍스트\s+---|🚨\s+직전\s+정정.*)$/gm;
const splits = body.split(/\n(?=#{1,3}\s|---\s+위키|🚨\s+직전)/);
for (const seg of splits) {
  if (!seg.trim()) continue;
  const firstLine = seg.split('\n')[0].trim();
  sections.push({ title: firstLine.slice(0, 80), chars: seg.length });
}
sections.sort((a, b) => b.chars - a.chars);

// 핵심 신호 검출
const checks = {
  '🚨 분노 신호 주입': body.includes('🚨 직전 정정'),
  'meta/오답노트 주입': body.includes('### [meta/오답노트]'),
  'persona 환각 면책 룰': /환각|hallucination|면책/i.test(body),
  'jarvis-ethos Iron Law': body.includes('Iron Law'),
  'user-profile 주입': /user-profile|career|커리어|경력/i.test(body),
  '편향 제거 5원칙': body.includes('편향 제거 5원칙') || body.includes('단일 가설'),
  'SSoT cross-search 룰': body.includes('cross-search') || body.includes('Cross-Search'),
};

if (SECTIONS_ONLY) {
  console.log(`# 섹션별 분포 (총 ${totalChars} chars, ${sections.length}개)\n`);
  for (const s of sections) {
    const pct = ((s.chars / totalChars) * 100).toFixed(1);
    console.log(`${pct.padStart(5)}% (${String(s.chars).padStart(5)}c) — ${s.title}`);
  }
  process.exit(0);
}

// 메인 보고
console.log(`# 🔍 System Prompt Snapshot 실측 보고
스냅샷: ${SNAPSHOT_FILE}
나이: ${ageMin}분 전 (${metaMap.ts || 'unknown'})
세션: ${metaMap.session_key || 'n/a'} | 채널: ${metaMap.channel_id || 'n/a'}

## 📊 크기
- 총 char: ${totalChars.toLocaleString()}
- 추정 토큰: ${estTokens.toLocaleString()} (4 chars/token 기준)
- 섹션 수: ${sections.length}
- 사용자 프롬프트 char: ${metaMap.prompt_chars || 'n/a'}

## ✅ 핵심 룰 주입 검증`);

for (const [k, v] of Object.entries(checks)) {
  console.log(`- ${v ? '✅' : '❌'} ${k}`);
}

console.log(`
## 📦 섹션별 상위 10개 (char 내림차순)`);
for (const s of sections.slice(0, 10)) {
  const pct = ((s.chars / totalChars) * 100).toFixed(1);
  console.log(`  ${pct.padStart(5)}% (${String(s.chars).padStart(5)}c) — ${s.title}`);
}

console.log(`
## 🎯 권고
- 추정 토큰 > 5000: 컨텍스트 압박 가능 → 섹션 캡 재검토
- 분노 신호 주입 ❌: anger-detector 동작 검증 (anger-signals.jsonl 확인)
- 오답노트 주입 ❌: prompt-sections.js:359 헤더 split 회귀 의심

## 🛠️ 추가 옵션
- 원본 출력: --raw
- 섹션 분포만: --sections
`);
