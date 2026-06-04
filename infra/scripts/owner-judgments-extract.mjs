#!/usr/bin/env node
/**
 * owner-judgments-extract.mjs — 오너 판단 패턴 증류 파이프라인
 *
 * 영상 핵심 개념(CareerCarex Alex):
 *   "진짜 무기는 나만 가진 맥락. 8년치 생각, 실패, 관점, 취향을 먹였다."
 *   → 사실(what happened)과 달리, 판단 원칙(how to think)을 별도로 증류.
 *
 * 동작:
 *   1. 최근 7일 discord-history 파일 + wiki/owner/_facts.md 수집
 *   2. Claude Haiku로 판단 패턴 추출 (원칙·기준·태도가 드러난 발화)
 *   3. wiki/owner/_facts.md에 source:judgment-extract로 적재
 *   4. 중복 방지: 텍스트 기반 dedup (addFactToWiki 내부 처리)
 *
 * 크론: 매주 일요일 02:30 KST (주간 증류)
 * 로그: ~/jarvis/runtime/logs/owner-judgments-extract.log
 *
 * Usage:
 *   node owner-judgments-extract.mjs [--dry-run] [--days <n>]
 */

import { readFileSync, readdirSync, existsSync, mkdirSync, appendFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { addFactToWiki } from '../discord/lib/wiki-engine.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const HOME     = homedir();
const BOT_HOME = process.env.BOT_HOME || join(HOME, 'jarvis/runtime');

const DISCORD_HISTORY_DIR = join(HOME, '.jarvis/context/discord-history');
const WIKI_OWNER_FACTS    = join(HOME, '.jarvis/wiki/owner/_facts.md');
const LOG_PATH            = join(BOT_HOME, 'logs', 'owner-judgments-extract.log');
const CLAUDE_BIN          = process.env.CLAUDE_BINARY || join(HOME, '.local/bin/claude');

const MAX_INPUT_CHARS    = 10_000;  // Haiku 컨텍스트 절약
const MAX_FACTS_PER_RUN  = 10;      // 주당 최대 판단 패턴 수
const HAIKU_TIMEOUT_MS   = 90_000;

// ── CLI 파싱 ─────────────────────────────────────────────────────────────────

const args = process.argv.slice(2);
const dryRun  = args.includes('--dry-run');
const daysArg = (() => { const i = args.indexOf('--days'); return i >= 0 ? Number(args[i+1]) : 7; })();

// ── 로거 ─────────────────────────────────────────────────────────────────────

function kstNow() {
  return new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Seoul' }).slice(0, 19);
}

function log(level, msg, meta = {}) {
  const ts = kstNow();
  const metaStr = Object.keys(meta).length ? ' ' + JSON.stringify(meta) : '';
  const line = `[${ts} KST] [judgments-extract] [${level.toUpperCase()}] ${msg}${metaStr}\n`;
  process.stderr.write(line);
  try { mkdirSync(dirname(LOG_PATH), { recursive: true }); appendFileSync(LOG_PATH, line); } catch {}
}

// ── 소스 수집 ─────────────────────────────────────────────────────────────────

/**
 * 최근 N일의 discord-history 파일 내용을 수집.
 * 파일명 형식: YYYY-MM-DD-HHMMSS.md (날짜 기반 필터)
 */
function collectDiscordHistory(days) {
  if (!existsSync(DISCORD_HISTORY_DIR)) return '';
  const cutoff = Date.now() - days * 24 * 3600 * 1000;
  const files = readdirSync(DISCORD_HISTORY_DIR)
    .filter(f => f.endsWith('.md'))
    .filter(f => {
      const dateMatch = f.match(/^(\d{4}-\d{2}-\d{2})/);
      if (!dateMatch) return false;
      return new Date(dateMatch[1]).getTime() >= cutoff;
    })
    .sort();

  if (!files.length) {
    log('info', `discord-history: 최근 ${days}일 파일 없음`);
    return '';
  }

  log('info', `discord-history: ${files.length}개 파일 수집`);
  const chunks = [];
  let total = 0;
  for (const f of files.reverse()) { // 최신 먼저
    if (total >= MAX_INPUT_CHARS / 2) break;
    const content = readFileSync(join(DISCORD_HISTORY_DIR, f), 'utf-8');
    // 오너 발화 포함 라인 추출 — discord-history 포맷: **<오너>**: ... (이름은 OWNER_NAME env)
    const _onm = process.env.OWNER_NAME || '';
    const _ore = new RegExp(_onm ? `\\*{0,2}${_onm}\\*{0,2}\\s*:|${_onm}\\s*:|User\\s*:` : `User\\s*:`);
    const ownerLines = content.split('\n')
      .filter(l => _ore.test(l))
      .map(l => l.replace(/\*\*/g, '').slice(0, 200)) // bold 마크다운 제거, 길이 제한
      .slice(0, 60)
      .join('\n');
    if (ownerLines.trim()) {
      chunks.push(`=== ${f} ===\n${ownerLines}`);
      total += ownerLines.length;
    }
  }
  return chunks.join('\n\n');
}

/**
 * wiki/owner/_facts.md 최근 항목 수집.
 */
function collectOwnerFacts() {
  if (!existsSync(WIKI_OWNER_FACTS)) return '';
  const content = readFileSync(WIKI_OWNER_FACTS, 'utf-8');
  // 최근 50개 항목만
  const lines = content.split('\n').filter(l => l.startsWith('- [')).slice(-50);
  return lines.join('\n');
}

// ── LLM 판단 패턴 추출 ───────────────────────────────────────────────────────

function callHaiku(prompt, timeoutMs = HAIKU_TIMEOUT_MS) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const proc = spawn(
      CLAUDE_BIN,
      ['--model', 'claude-haiku-4-5-20251001', '--output-format', 'text',
       '--max-turns', '1', '--tools', '', '--dangerously-skip-permissions'],
      { stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env } },
    );
    let out = '', err = '';
    proc.stdout.on('data', d => { out += d; });
    proc.stderr.on('data', d => { err += d; });
    proc.stdin.write(prompt, 'utf-8');
    proc.stdin.end();

    const timer = setTimeout(() => {
      if (!settled) { settled = true; proc.kill('SIGTERM'); reject(new Error(`timeout (${timeoutMs}ms)`)); }
    }, timeoutMs);

    proc.on('close', code => {
      clearTimeout(timer);
      if (settled) return;
      settled = true;
      if (code === 0) resolve(out.trim());
      else reject(new Error(`exit ${code}: ${err.slice(0, 200)}`));
    });
    proc.on('error', e => { clearTimeout(timer); if (!settled) { settled = true; reject(e); } });
  });
}

/**
 * 수집된 원문에서 오너의 판단 원칙을 추출.
 * Returns: string[] — 각 항목이 wiki 적재용 판단 패턴 문장
 */
async function extractJudgmentPatterns(historyText, factsText) {
  const sourceText = [
    historyText && `## Discord 발화 (최근 ${daysArg}일)\n${historyText.slice(0, MAX_INPUT_CHARS * 0.6)}`,
    factsText && `## 기존 wiki 기록\n${factsText.slice(0, MAX_INPUT_CHARS * 0.4)}`,
  ].filter(Boolean).join('\n\n');

  if (!sourceText.trim()) {
    log('warn', '추출 소스 없음');
    return [];
  }

  const prompt = `당신은 Jarvis 지식 증류 전문가입니다.
오너(8년차 백엔드 개발자)의 발화·기록에서 **판단 패턴**을 추출하세요.

판단 패턴 = "어떤 상황에서 어떻게 생각하고 판단하는가"의 원칙·기준·태도
(단순 사실이나 일어난 일이 아니라, 생각의 방식·우선순위·가치관)

예시:
✅ 판단 패턴: "아키텍처 확인 없이 구현 착수하는 것을 싫어한다 — 먼저 실증 후 코딩"
✅ 판단 패턴: "짧은 질문이어도 분석 요청이면 깊이 있는 답변을 기대한다"
✅ 판단 패턴: "기술 선택 시 현재 팀 규모와 스케일 가능성을 동시에 고려한다"
❌ 단순 사실: "2026-05-07에 디스크 용량이 36%였다"

소스 데이터:
${sourceText}

JSON 배열만 응답 (다른 텍스트 없이):
["판단 패턴 1 (1~2문장, 구체적)", "판단 패턴 2", ...]

규칙:
- ${MAX_FACTS_PER_RUN}개 이내
- 이미 일반적으로 알려진 내용 제외, 이 오너만의 특성 중심
- 모두 한국어
- 재발 방지·원칙 설계 관련 판단 최우선 포함`;

  try {
    const raw = await callHaiku(prompt);
    const jsonMatch = raw.match(/\[[\s\S]*\]/);
    if (!jsonMatch) {
      log('warn', 'LLM 응답에 JSON 없음', { raw: raw.slice(0, 200) });
      return [];
    }
    const patterns = JSON.parse(jsonMatch[0]);
    return Array.isArray(patterns) ? patterns.filter(p => typeof p === 'string' && p.length > 10) : [];
  } catch (e) {
    log('warn', `LLM 추출 실패: ${e.message}`);
    return [];
  }
}

// ── 메인 ─────────────────────────────────────────────────────────────────────

async function main() {
  log('info', `판단 패턴 증류 시작`, { dryRun, days: daysArg });

  // 1. 소스 수집
  const historyText = collectDiscordHistory(daysArg);
  const factsText   = collectOwnerFacts();
  log('info', '소스 수집 완료', {
    historyChars: historyText.length,
    factsChars: factsText.length,
  });

  if (!historyText && !factsText) {
    log('warn', '처리할 소스 없음 — 종료');
    process.exit(0);
  }

  // 2. LLM 판단 패턴 추출
  log('info', 'LLM 판단 패턴 추출 중...');
  const patterns = await extractJudgmentPatterns(historyText, factsText);
  log('info', `추출 결과: ${patterns.length}개 패턴`);

  if (!patterns.length) {
    log('info', '추출된 판단 패턴 없음 — 종료');
    process.exit(0);
  }

  // 3. wiki 적재
  const added = [];
  for (const pattern of patterns.slice(0, MAX_FACTS_PER_RUN)) {
    if (dryRun) {
      console.log(`[DRY-RUN] [owner] ${pattern}`);
      added.push(pattern);
    } else {
      addFactToWiki(null, `[판단 패턴] ${pattern}`, {
        domainOverride: 'owner',
        source: 'judgment-extract',
      });
      added.push(pattern);
      log('info', `wiki 적재: ${pattern.slice(0, 60)}...`);
    }
  }

  // 4. 결과 출력
  log('info', `완료: ${added.length}개 판단 패턴 적재`, { dryRun });
  console.log(JSON.stringify({ patternsExtracted: patterns.length, patternsAdded: added.length, dryRun }, null, 2));
}

main().catch(e => {
  log('error', `예상치 못한 오류: ${e.message}`, { stack: e.stack?.slice(0, 300) });
  process.exit(1);
});
