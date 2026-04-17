/**
 * Session summary — persist recent conversation turns for context recovery
 * when session resume fails.
 *
 * Exports:
 *   saveSessionSummary(sessionKey, userText, assistantText)
 *   loadSessionSummary(sessionKey) — returns formatted summary or ''
 */

import { writeFileSync, readFileSync, existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { log } from './claude-runner.js';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const SESSION_SUMMARY_DIR = join(BOT_HOME, 'state', 'session-summaries');
const MAX_SUMMARY_TURNS = 10;

// Ensure session-summaries directory exists on module load
mkdirSync(SESSION_SUMMARY_DIR, { recursive: true });

/**
 * Save a conversation turn to the session summary file.
 * Keeps at most MAX_SUMMARY_TURNS recent turns.
 */
// 저장/로드 모두 위험 패턴 필터링 — 오염된 명령이 세션에 영속되지 않도록
// 실행 가능한 위험 명령만 차단 — 단순 언급/설명은 허용
const DANGER_PATTERNS = [
  // 서비스 영구 제거/비활성화만 차단 — stop/load/start는 가역적이므로 허용
  /launchctl\s+(bootout|unload|disable)\s/i,
  /systemctl\s+(stop|disable)\s/i,
  /rm\s+-rf/i,
  /kill\s+-9/i,
];
function _hasDanger(text) {
  return DANGER_PATTERNS.some(p => p.test(text));
}

export function saveSessionSummary(sessionKey, userText, assistantText) {
  // 위험 명령 포함 시 저장 건너뜀 — 오염 차단
  if (_hasDanger(assistantText)) {
    log('warn', 'saveSessionSummary: skipped (dangerous pattern in assistant response)');
    return;
  }
  try {
    mkdirSync(SESSION_SUMMARY_DIR, { recursive: true });
    const filePath = join(SESSION_SUMMARY_DIR, `${sessionKey.replace(/[^a-zA-Z0-9_-]/g, '_')}.md`);
    const ts = new Date().toISOString().slice(0, 19).replace('T', ' ');
    const userSnippet = userText.length > 600 ? userText.slice(0, 600) + '...' : userText;
    const assistSnippet = assistantText.length > 2500 ? assistantText.slice(0, 2500) + '...' : assistantText;
    const entry = `[${ts}] User: ${userSnippet}\n[${ts}] Jarvis: ${assistSnippet}\n---\n`;

    let existing = '';
    try { existing = readFileSync(filePath, 'utf-8'); } catch { /* new file */ }

    // Keep last N turns
    const turns = existing.split('---\n').filter(t => t.trim());
    while (turns.length >= MAX_SUMMARY_TURNS) turns.shift();
    turns.push(entry.replace('---\n', ''));

    writeFileSync(filePath, turns.join('---\n') + '---\n');
  } catch (err) {
    log('warn', 'saveSessionSummary failed', { error: err.message });
  }
}

/**
 * Load session summary for context recovery.
 * @returns {string} Formatted summary block or empty string
 */
export function loadSessionSummary(sessionKey) {
  try {
    const filePath = join(SESSION_SUMMARY_DIR, `${sessionKey.replace(/[^a-zA-Z0-9_-]/g, '_')}.md`);
    if (!existsSync(filePath)) return '';
    const content = readFileSync(filePath, 'utf-8').trim();
    if (!content) return '';
    // 위험 패턴 포함 시 요약 폐기 — 오염된 파일이 남아있어도 주입 차단
    if (_hasDanger(content)) {
      log('warn', 'loadSessionSummary: discarded (dangerous pattern detected)', { sessionKey });
      return '';
    }
    // compaction summary vs raw transcript 구분
    const isCompacted = content.startsWith('<!-- compacted');
    const header = isCompacted
      ? '## 이전 세션 (AI 컴팩트 요약)'
      : '## 이전 세션 요약 (최근 대화)';
    return `${header}\n${content}\n\n`;
  } catch {
    return '';
  }
}

/**
 * Load only the most recent topic for "계속" (continue) command.
 * Instead of injecting the entire session summary, returns only the last 2 turns
 * and relevant compacted sections to prevent topic confusion.
 */
export function loadSessionSummaryRecent(sessionKey) {
  try {
    const filePath = join(SESSION_SUMMARY_DIR, `${sessionKey.replace(/[^a-zA-Z0-9_-]/g, '_')}.md`);
    if (!existsSync(filePath)) return '';
    const content = readFileSync(filePath, 'utf-8').trim();
    if (!content || _hasDanger(content)) return '';

    const isCompacted = content.startsWith('<!-- compacted');
    if (isCompacted) {
      // compacted 요약: "### 마지막 진행 주제" + "### 미완 작업" 섹션만 추출
      // + compacted 뒤에 raw 턴이 붙어있으면 마지막 2턴만 포함
      const sections = [];
      for (const hdr of ['### 마지막 진행 주제', '### 미완 작업']) {
        const idx = content.indexOf(hdr);
        if (idx >= 0) {
          const nextHdr = content.indexOf('\n###', idx + hdr.length);
          const nextSep = content.indexOf('\n---', idx);
          const end = Math.min(
            nextHdr >= 0 ? nextHdr : Infinity,
            nextSep >= 0 ? nextSep : Infinity,
            content.length,
          );
          const sec = content.slice(idx, end).trim();
          if (sec && !sec.endsWith('없음')) sections.push(sec);
        }
      }
      // compacted 뒤에 붙은 raw 턴 (timestamp로 시작)이 있으면 마지막 2턴
      const rawMatch = content.lastIndexOf('---\n[');
      if (rawMatch >= 0) {
        const rawTurns = content.slice(rawMatch).split('---\n').filter(t => t.trim());
        sections.push(...rawTurns.slice(-3));
      }
      if (sections.length === 0) return ''; // fallback → 호출부에서 전체 요약 사용
      return `## 직전 대화 맥락 (최근 주제만)\n${sections.join('\n---\n')}\n\n`;
    }

    // raw transcript: 마지막 3턴만 슬라이스
    const turns = content.split('---\n').filter(t => t.trim());
    const recent = turns.slice(-3);
    if (recent.length === 0) return '';
    return `## 직전 대화 맥락 (최근 주제만)\n${recent.join('---\n')}\n\n`;
  } catch {
    return '';
  }
}

/**
 * AI가 생성한 구조화 컴팩션 요약 저장.
 * haiku가 5-섹션 형식으로 생성한 요약을 session-summary 파일에 덮어씀.
 * 다음 세션에서 loadSessionSummary()로 주입됨.
 */
export function saveCompactionSummary(sessionKey, structuredMarkdown) {
  if (_hasDanger(structuredMarkdown)) {
    log('warn', 'saveCompactionSummary: skipped (dangerous pattern)');
    return;
  }
  try {
    mkdirSync(SESSION_SUMMARY_DIR, { recursive: true });
    const filePath = join(SESSION_SUMMARY_DIR, `${sessionKey.replace(/[^a-zA-Z0-9_-]/g, '_')}.md`);
    const ts = new Date().toISOString().slice(0, 19).replace('T', ' ');
    const content = `<!-- compacted at ${ts} -->\n${structuredMarkdown}\n`;
    writeFileSync(filePath, content);
    log('info', 'saveCompactionSummary: written', { sessionKey, bytes: content.length });
  } catch (err) {
    log('warn', 'saveCompactionSummary failed', { error: err.message });
  }
}

/**
 * AI 시맨틱 컴팩션 — haiku로 세션 대화 전체를 5-섹션 구조로 압축.
 * compact 트리거 시 백그라운드로 호출 (non-blocking).
 * 성공 시 saveCompactionSummary()로 저장, 실패 시 기존 요약 유지.
 *
 * @param {string} sessionKey
 * @returns {Promise<void>}
 */
export async function compactSessionWithAI(sessionKey) {
  let rawContent = '';
  try {
    const filePath = join(SESSION_SUMMARY_DIR, `${sessionKey.replace(/[^a-zA-Z0-9_-]/g, '_')}.md`);
    if (!existsSync(filePath)) return;
    rawContent = readFileSync(filePath, 'utf-8').trim();
    if (!rawContent || rawContent.length < 200) return; // 내용 없으면 스킵
  } catch {
    return;
  }

  const summarizePrompt = [
    '다음은 AI 봇과 사용자의 대화 기록이다.',
    '이 대화를 아래 6-섹션 형식으로 핵심만 한국어로 요약해라.',
    '각 섹션은 중요한 정보만 포함하고, 없으면 "없음"으로 표기해라.',
    '전체 요약은 2000자 이내로 작성해라.',
    '',
    '형식:',
    '### 사용자 의도',
    '(이 세션에서 사용자가 하려 했던 것)',
    '### 완료된 작업',
    '(실제로 처리/완료된 내용)',
    '### 오류 및 수정',
    '(발생한 오류, 수정 사항)',
    '### 미완 작업',
    '(아직 처리 안 된 것, 있다면)',
    '### 핵심 참조',
    '(중요한 파일명, 에러 메시지, 설정값 등)',
    '### 마지막 진행 주제',
    '(대화 기록의 마지막 1-2턴에서 다루던 구체적 주제 한 줄. 사용자가 "계속"이라고 하면 이 주제를 이어감)',
    '',
    '---대화 기록---',
    rawContent,
  ].join('\n');

  try {
    // SDK query()는 내부에서 streamInput(undefined) 호출하는 버그 있음 → spawn+stdin으로 직접 호출
    // -p 인자 대신 stdin 파이프: ARG_MAX 초과 없이 긴 세션 내용도 안전하게 전달
    const { spawn } = await import('node:child_process');
    const { join: pathJoin } = await import('node:path');
    const { homedir: hd } = await import('node:os');

    const claudeBinary = process.env.CLAUDE_BINARY || pathJoin(hd(), '.local/bin/claude');
    const compactModel = rawContent.length > 5000
      ? 'claude-sonnet-4-5'
      : 'claude-haiku-4-5-20251001';

    const stdout = await new Promise((resolve, reject) => {
      const proc = spawn(
        claudeBinary,
        ['--model', compactModel, '--output-format', 'text', '--dangerously-skip-permissions'],
        {
          timeout: 60_000,
          stdio: ['pipe', 'pipe', 'pipe'],
          env: { ...process.env, ANTHROPIC_API_KEY: '', CLAUDECODE: '' },
        },
      );
      let out = '';
      proc.stdout.on('data', (d) => { out += d; });
      proc.stdin.write(summarizePrompt, 'utf-8');
      proc.stdin.end();
      proc.on('close', (code) => {
        if (code === 0) resolve(out);
        else reject(new Error(`claude exited ${code}`));
      });
      proc.on('error', reject);
    });

    const summary = (stdout || '').trim();
    if (summary && summary.length > 50) {
      saveCompactionSummary(sessionKey, summary);
      log('info', 'compactSessionWithAI: AI summary saved', { sessionKey, bytes: summary.length });
    }
  } catch (err) {
    log('warn', 'compactSessionWithAI: failed (fallback to existing summary)', { sessionKey, error: err.message });
  }
}