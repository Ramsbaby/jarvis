/**
 * wiki-ingester.mjs — LLM 기반 위키 인제스터
 *
 * 세션 요약/facts를 Claude Haiku로 소화해 위키 페이지를 업데이트.
 * 기존 session-summarizer.mjs의 패턴 매칭 방식을 LLM 소화 방식으로 보강.
 *
 * LLM Wiki 핵심 원칙:
 *   1. 원본 그대로 저장 (RAG) 대신, LLM이 읽고 통합해 위키로 변환
 *   2. 새 정보는 기존 페이지를 업데이트 (append-only가 아님)
 *   3. 관련 페이지 동시 업데이트 (크로스 레퍼런스)
 *
 * 실행 방식:
 *   - session-summarizer.mjs에서 호출 (facts 추출 후 위키 인제스트)
 *   - claude-runner.js에서 세션 종료 시 호출
 *   - 직접 실행: node wiki-ingester.mjs --session <sessionKey>
 */

import { spawn } from 'node:child_process';
import { readFileSync, existsSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import {
  getPage, savePage, addFactToWiki, detectPageKey,
  getSchema, getWikiStats, WIKI_ROOT,
} from './wiki-engine.mjs';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const CLAUDE_BINARY = process.env.CLAUDE_BINARY || join(homedir(), '.local/bin/claude');

function log(level, msg, meta = {}) {
  const ts = new Date().toISOString().slice(0, 19).replace('T', ' ');
  const metaStr = Object.keys(meta).length ? ' ' + JSON.stringify(meta) : '';
  process.stdout.write(`[${ts}] [wiki-ingester] [${level.toUpperCase()}] ${msg}${metaStr}\n`);
}

// ── Claude Haiku 호출 ─────────────────────────────────────────────────────────

async function callHaiku(prompt, timeoutMs = 60_000) {
  return new Promise((resolve, reject) => {
    const proc = spawn(
      CLAUDE_BINARY,
      ['--model', 'claude-haiku-4-5-20251001', '--output-format', 'text', '--dangerously-skip-permissions'],
      {
        timeout: timeoutMs,
        stdio: ['pipe', 'pipe', 'pipe'],
        env: { ...process.env },
      },
    );
    let out = '';
    let err = '';
    proc.stdout.on('data', (d) => { out += d; });
    proc.stderr.on('data', (d) => { err += d; });
    proc.stdin.write(prompt, 'utf-8');
    proc.stdin.end();
    proc.on('close', (code) => {
      if (code === 0) resolve(out.trim());
      else reject(new Error(`haiku exit ${code}: ${err.slice(0, 200)}`));
    });
    proc.on('error', reject);
  });
}

// ── 단일 Fact → 위키 인제스트 ─────────────────────────────────────────────────

/**
 * 단일 fact를 위키에 인제스트.
 * 단순 추가 (LLM 없이 키워드 기반) — 빠른 경로.
 */
export function ingestFactDirect(userId, fact) {
  const pageKey = addFactToWiki(userId, fact);
  log('debug', `direct ingest → ${pageKey}`, { userId, fact: fact.slice(0, 60) });
  return pageKey;
}

// ── 세션 → 위키 LLM 인제스트 ─────────────────────────────────────────────────

/**
 * 세션 요약 텍스트를 LLM으로 소화해 위키 페이지들을 업데이트.
 * 이 함수가 LLM Wiki의 핵심 — "소화(Digest)" 단계.
 *
 * @param {string} userId
 * @param {string} sessionContent - 세션 요약 전체 텍스트
 * @returns {Object} 업데이트된 페이지 목록
 */
export async function ingestSessionToWiki(userId, sessionContent) {
  if (!sessionContent || sessionContent.length < 50) return {};

  const schema = getSchema();
  const pageKeys = Object.keys(schema.pages);

  // 기존 위키 페이지 컨텍스트 수집
  const existingWiki = {};
  for (const pk of pageKeys) {
    const content = getPage(userId, pk);
    if (content) existingWiki[pk] = content.slice(0, 800); // 요약본만 사용
  }

  const existingWikiStr = Object.entries(existingWiki)
    .map(([k, v]) => `### [${k}]\n${v}`)
    .join('\n\n');

  // LLM 소화 프롬프트
  const prompt = `당신은 개인 지식 관리 시스템입니다. 아래 대화 세션에서 중요한 정보를 추출해 위키 페이지를 업데이트해야 합니다.

## 위키 페이지 정의
${pageKeys.map(k => `- **${k}**: ${schema.pages[k].description}`).join('\n')}

## 현재 위키 내용 (기존 지식)
${existingWikiStr || '(아직 없음)'}

## 오늘 세션 내용
${sessionContent.slice(0, 3000)}

## 작업 지시
위 세션에서 각 위키 페이지에 추가할 새로운 정보를 JSON으로 반환하세요.
- 이미 위키에 있는 정보는 포함하지 마세요
- 중요하지 않은 일상 대화는 제외하세요
- 각 항목은 1-2줄로 간결하게
- 업데이트가 필요 없는 페이지는 빈 배열로

형식:
\`\`\`json
{
  "profile": ["항목1", "항목2"],
  "work": ["항목1"],
  "trading": [],
  "projects": ["항목1"],
  "preferences": [],
  "health": [],
  "travel": []
}
\`\`\`

JSON 코드 블록만 반환. 설명 없이.`;

  let parsed = null;
  try {
    const raw = await callHaiku(prompt);
    const jsonMatch = raw.match(/```json\s*([\s\S]+?)\s*```/) || raw.match(/\{[\s\S]+\}/);
    const jsonStr = jsonMatch ? (jsonMatch[1] || jsonMatch[0]) : raw;
    parsed = JSON.parse(jsonStr);
  } catch (err) {
    log('warn', 'LLM 파싱 실패 — fallback to direct ingest', { error: err.message });
    return {};
  }

  const updated = {};
  for (const [pageKey, items] of Object.entries(parsed)) {
    if (!Array.isArray(items) || items.length === 0) continue;
    for (const item of items) {
      if (typeof item === 'string' && item.trim()) {
        addFactToWiki(userId, item.trim(), pageKey);
        updated[pageKey] = (updated[pageKey] || 0) + 1;
      }
    }
  }

  log('info', '세션 인제스트 완료', { userId, updated });
  return updated;
}

// ── 페이지 병합 (LLM 기반) ───────────────────────────────────────────────────

/**
 * 특정 페이지의 중복/오래된 정보를 LLM으로 정리.
 * 위키가 너무 커지면 자동 호출.
 */
export async function compactWikiPage(userId, pageKey) {
  const content = getPage(userId, pageKey);
  if (!content || content.length < 2000) return false; // 작으면 불필요

  const schema = getSchema();
  const pageDef = schema.pages[pageKey];

  const prompt = `다음은 개인 AI 위키의 "${pageDef?.title || pageKey}" 페이지입니다.

${content}

## 작업
위 내용을 정리해주세요:
1. 중복 항목 통합
2. 오래된 정보는 최신 정보로 대체
3. 서로 관련된 항목들을 논리적으로 묶기
4. 마크다운 형식 유지 (## 섹션, - 불릿 사용)
5. 핵심 정보 보존, 불필요한 내용 제거

정리된 전체 페이지 내용만 반환.`;

  try {
    const result = await callHaiku(prompt, 90_000);
    if (result && result.length > 100) {
      savePage(userId, pageKey, result);
      log('info', `페이지 컴팩션 완료: ${pageKey}`, { userId, before: content.length, after: result.length });
      return true;
    }
  } catch (err) {
    log('warn', `페이지 컴팩션 실패: ${pageKey}`, { error: err.message });
  }
  return false;
}

// ── 독립 실행 ────────────────────────────────────────────────────────────────

if (process.argv[1] && process.argv[1].endsWith('wiki-ingester.mjs')) {
  const args = process.argv.slice(2);
  const sessionFlag = args.indexOf('--session');
  const userFlag = args.indexOf('--user');

  if (sessionFlag === -1) {
    console.log('Usage: node wiki-ingester.mjs --session <sessionKey> [--user <userId>]');
    process.exit(0);
  }

  const sessionKey = args[sessionFlag + 1];
  const userId = userFlag !== -1 ? args[userFlag + 1] : 'owner';
  const SESSION_SUMMARY_DIR = join(BOT_HOME, 'state', 'session-summaries');
  const filePath = join(SESSION_SUMMARY_DIR, `${sessionKey.replace(/[^a-zA-Z0-9_-]/g, '_')}.md`);

  if (!existsSync(filePath)) {
    console.error(`세션 파일 없음: ${filePath}`);
    process.exit(1);
  }

  const content = readFileSync(filePath, 'utf-8');
  log('info', `인제스트 시작: ${sessionKey} → userId=${userId}`);

  ingestSessionToWiki(userId, content)
    .then(updated => {
      log('info', '완료', { updated });
      console.log('\n📚 위키 현황:');
      const stats = getWikiStats(userId);
      for (const [pk, stat] of Object.entries(stats.pages)) {
        console.log(`  ${pk}: ${stat.sizeKb}KB (${stat.lastModified})`);
      }
    })
    .catch(err => {
      log('error', `실패: ${err.message}`);
      process.exit(1);
    });
}
