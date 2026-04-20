#!/usr/bin/env node
/**
 * context-extractor.mjs
 *
 * Discord + Claude Code 대화 기록에서 도메인별 컨텍스트를 추출해
 * ~/jarvis/runtime/context/claude-memory/ 에 domain-full.md / domain-summary.md 저장.
 *
 * 실행: node context-extractor.mjs [YYYY-MM-DD] [--domain career|tech|jarvis|finance|personal|all]
 * 크론: launchd com.jarvis.context-extractor (매일 01:00)
 *
 * 출력 per domain:
 *   claude-memory/{domain}-full.md    ← 누적 상세 (RAG + Claude Code 심층 참조용)
 *   claude-memory/{domain}-summary.md ← 합성 요약 (Claude Code 세션 시작 시 자동 로드)
 */

import { spawnSync } from 'node:child_process';
import {
  readFileSync, writeFileSync, appendFileSync,
  existsSync, mkdirSync, readdirSync, statSync,
} from 'node:fs';
import { join, extname } from 'node:path';
import { homedir } from 'node:os';

// ── 경로 설정 ────────────────────────────────────────────────────────────────
const HOME         = homedir();
const VAULT_DIR    = process.env.VAULT_DIR || join(HOME, 'vault');
const DISCORD_DIR  = join(VAULT_DIR, '02-daily', 'discord');
const SESSIONS_DIR = join(HOME, 'jarvis/runtime', 'context', 'claude-code-sessions');
const OUTPUT_DIR   = join(HOME, 'jarvis/runtime', 'context', 'claude-memory');
const BOT_HOME     = join(HOME, 'jarvis/runtime');
const LOG_FILE     = join(BOT_HOME, 'logs', 'context-extractor.log');
const MCP_CONFIG   = join(BOT_HOME, 'config', 'empty-mcp.json');

// ── 도메인 정의 ──────────────────────────────────────────────────────────────
const DOMAINS = {
  career: {
    // 도메인 id 'career' 는 기존 파일·인덱스 호환을 위해 유지.
    // 내용은 일반 활동 추적으로 추상화 — 공개 OSS 노출 최소화.
    // 실사용 키워드·프롬프트는 private/config/domain-overrides.json 에서 로드.
    label: '활동',
    channels: [process.env.CAREER_DOMAIN_CHANNEL || 'jarvis-blog'],
    keywords: ['목표', '로드맵', '계획', '오퍼', '피드백', '마일스톤'],
    prompt: `Discord 대화에서 개인 활동·목표 관련 내용만 추출해 마크다운으로 정리해줘.

## 추출 항목 (없으면 섹션 생략)
1. **진행 현황** — 새로 진입/전환한 단계
2. **주요 일정** — 예정된 이벤트/노트/질문
3. **산출물 변경** — 버전 변경, 주요 수정 사항
4. **인사이트** — 전략, 포지셔닝, 관찰
5. **대상 분석** — 특정 도메인·팀·기술스택 조사 내용

핵심만 간결하게 (각 항목 5줄 이내). 수치 반드시 보존. 원문 복붙 금지.`,
  },
  tech: {
    label: '기술',
    channels: ['jarvis-dev', 'jarvis-blog'],
    keywords: ['Spring', 'Java', 'Kotlin', 'Kafka', 'AWS', 'Redis', 'Docker', 'Kubernetes',
               '코드', '구현', '설계', '아키텍처', '버그', '디버깅', '성능', '최적화',
               'API', 'DB', 'MySQL', 'JPA', 'gRPC', 'WebFlux', 'Batch', '트랜잭션'],
    prompt: `Discord 대화에서 기술적 내용만 추출해 마크다운으로 정리해줘.

## 추출 항목 (없으면 섹션 생략)
1. **기술 결정** — 선택한 기술/패턴과 근거
2. **문제 해결** — 발생한 버그/이슈와 해결 방법 (수치 포함)
3. **학습 내용** — 새로 알게 된 기술 개념, 트레이드오프
4. **코드 패턴** — 재사용할 만한 구현 패턴

핵심만 간결하게. 수치와 기술 용어 정확히 보존.`,
  },
  jarvis: {
    label: 'Jarvis 시스템',
    channels: ['jarvis-system', 'jarvis-dev', 'jarvis'],
    keywords: ['자비스', 'Jarvis', '크론', 'RAG', '자동화', '봇', 'Discord', '인덱싱',
               'LaunchAgent', '훅', 'hook', 'MCP', '모니터링', '배포', 'deploy',
               'context-extractor', 'rag-index'],
    prompt: `Discord 대화에서 Jarvis 시스템 관련 내용만 추출해 마크다운으로 정리해줘.

## 추출 항목 (없으면 섹션 생략)
1. **시스템 변경** — 추가/수정/삭제된 기능, 스크립트, 크론
2. **장애 및 해결** — 발생한 오류와 해결 방법
3. **개선 아이디어** — 논의된 개선 방향
4. **설정 변경** — config, LaunchAgent, 훅 변경사항

간결하게. 파일 경로와 명령어는 정확히 보존.`,
  },
  finance: {
    label: '재무/투자',
    channels: ['jarvis-ceo', 'jarvis'],
    keywords: ['SOXL', 'SCHD', 'QQQ', '주식', '레버리지', '투자', '매수', '매도',
               '수익', '손실', '포트폴리오', '자산', '시장', 'ETF', '나스닥'],
    prompt: `Discord 대화에서 투자/재무 관련 내용만 추출해 마크다운으로 정리해줘.

## 추출 항목 (없으면 섹션 생략)
1. **거래 내역** — 매수/매도 내역, 수량, 가격
2. **시장 판단** — 시장 상황 분석, 근거
3. **전략 변경** — 투자 전략 업데이트

수치 정확히 보존. 날짜 반드시 포함.`,
  },
  personal: {
    label: '개인/일상',
    channels: ['jarvis-family'],
    keywords: ['일상', '건강', '가족', '여행', '식사', '운동', '취미', '피곤', '스트레스'],
    prompt: `Discord 대화에서 개인/일상 관련 내용만 추출해 마크다운으로 정리해줘.

## 추출 항목 (없으면 섹션 생략)
1. **주요 일정/이벤트** — 중요한 개인 일정
2. **컨디션/상태** — 건강, 피로, 감정 상태
3. **가족** — 가족 관련 중요 내용

매우 간결하게. 개인정보에 준하는 내용이므로 핵심만.`,
  },
};

// ── CLI 인자 파싱 ─────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const domainArg = args.find(a => a.startsWith('--domain='))?.split('=')[1]
  || (args.find(a => a === '--domain') ? args[args.indexOf('--domain') + 1] : null)
  || 'all';

const targetDate = args.find(a => /^\d{4}-\d{2}-\d{2}$/.test(a)) ?? (() => {
  const d = new Date();
  d.setDate(d.getDate() - 1);
  return d.toISOString().slice(0, 10);
})();

const activeDomains = domainArg === 'all'
  ? Object.keys(DOMAINS)
  : domainArg.split(',').filter(d => DOMAINS[d]);

// ── 로깅 ─────────────────────────────────────────────────────────────────────
function log(msg) {
  const line = `[${new Date().toISOString()}] [context-extractor] ${msg}\n`;
  process.stdout.write(line);
  try { appendFileSync(LOG_FILE, line, 'utf-8'); } catch {}
}

// ── Discord 히스토리 파일 탐색 (구형식 YYYY-MM-DD.md + 신형식 YYYY-MM-DD-HHMMSS.md) ──
function findHistoryFiles(date) {
  const exact = join(DISCORD_DIR, `${date}.md`);
  if (existsSync(exact)) return [exact];
  try {
    return readdirSync(DISCORD_DIR)
      .filter(f => f.startsWith(`${date}-`) && f.endsWith('.md') && !f.includes('user-memory'))
      .sort()
      .map(f => join(DISCORD_DIR, f));
  } catch { return []; }
}

// ── Claude Code 세션 파일 탐색 ────────────────────────────────────────────────
function findSessionFiles(date) {
  const files = [];
  try {
    const projDirs = readdirSync(SESSIONS_DIR, { withFileTypes: true });
    for (const pd of projDirs) {
      if (!pd.isDirectory()) continue;
      const projPath = join(SESSIONS_DIR, pd.name);
      try {
        readdirSync(projPath)
          .filter(f => f.startsWith(date) && f.endsWith('.md'))
          .forEach(f => files.push(join(projPath, f)));
      } catch {}
    }
  } catch {}
  return files.sort();
}

// ── 채널 섹션 추출 ────────────────────────────────────────────────────────────
function extractChannelSections(content, channels) {
  const lines = content.split('\n');
  const sections = [];
  let active = false;
  let buf = [];

  for (const line of lines) {
    const m = line.match(/^## \[.+?\] #(.+)/);
    if (m) {
      if (active && buf.length > 0) { sections.push(buf.join('\n')); buf = []; }
      active = channels.includes(m[1].trim());
      if (active) buf.push(line);
    } else if (active) {
      buf.push(line);
    }
  }
  if (active && buf.length > 0) sections.push(buf.join('\n'));
  return sections.join('\n\n---\n\n');
}

// ── 키워드 필터링 ─────────────────────────────────────────────────────────────
function hasKeywords(text, keywords) {
  return keywords.some(k => text.includes(k));
}

// ── Claude API 호출 ───────────────────────────────────────────────────────────
function callClaude(prompt, content) {
  const fullPrompt = `${prompt}\n\n---\n${content}`;
  const result = spawnSync(
    '/opt/homebrew/bin/claude',
    ['-p', fullPrompt, '--output-format', 'json',
     '--permission-mode', 'bypassPermissions',
     '--strict-mcp-config', '--mcp-config', MCP_CONFIG],
    { env: { ...process.env, ANTHROPIC_API_KEY: '', CLAUDECODE: '' },
      timeout: 180_000, maxBuffer: 4 * 1024 * 1024 }
  );
  if (result.status !== 0) {
    throw new Error(`claude 실패 (exit ${result.status}): ${result.stderr?.toString().slice(0, 200)}`);
  }
  const json = JSON.parse(result.stdout.toString());
  if (json.is_error) throw new Error(`claude is_error: ${json.subtype}`);
  return json.result ?? '';
}

// ── domain-full.md 에 날짜별 엔트리 추가 ─────────────────────────────────────
function appendToFull(domainId, date, extracted) {
  const fullFile = join(OUTPUT_DIR, `${domainId}-full.md`);
  const entry = `\n## ${date}\n\n${extracted.trim()}\n`;

  if (!existsSync(fullFile)) {
    const header = `---
name: ${DOMAINS[domainId].label} — 누적 상세 로그
description: ${DOMAINS[domainId].label} 도메인 대화 내용 누적 기록. RAG 검색 및 심층 참조용.
type: user
---\n`;
    writeFileSync(fullFile, header + entry, 'utf-8');
  } else {
    const current = readFileSync(fullFile, 'utf-8');
    if (current.includes(`## ${date}`)) {
      // 같은 날짜 업데이트
      writeFileSync(fullFile,
        current.replace(new RegExp(`## ${date}\\n[\\s\\S]*?(?=\\n## |$)`), `## ${date}\n\n${extracted.trim()}\n`),
        'utf-8');
    } else {
      // 최신 항목을 앞에 추가 (헤더 다음 줄)
      const headerEnd = current.indexOf('\n---\n') !== -1
        ? current.indexOf('\n---\n') + 5
        : current.indexOf('\n\n') + 2;
      writeFileSync(fullFile,
        current.slice(0, headerEnd) + entry + current.slice(headerEnd),
        'utf-8');
    }
  }
  return fullFile;
}

// ── domain-summary.md 재합성 (full.md가 길어졌을 때 or 주 1회) ───────────────
function shouldRegenerateSummary(domainId) {
  const summaryFile = join(OUTPUT_DIR, `${domainId}-summary.md`);
  if (!existsSync(summaryFile)) return true;

  const stat = statSync(summaryFile);
  const ageDays = (Date.now() - stat.mtimeMs) / (1000 * 60 * 60 * 24);
  // career 도메인(활동 추적)은 매일 재생성, 그 외 도메인은 주 1회
  return domainId === 'career' ? ageDays >= 1 : ageDays >= 7;
}

function regenerateSummary(domainId) {
  const fullFile = join(OUTPUT_DIR, `${domainId}-full.md`);
  if (!existsSync(fullFile)) return;

  const content = readFileSync(fullFile, 'utf-8');
  // 최근 30일치만 요약에 사용
  const recentThreshold = Date.now() - 30 * 24 * 60 * 60 * 1000;

  const summaryPrompt = `아래는 최근 ${DOMAINS[domainId].label} 관련 대화 로그야.
핵심 정보만 뽑아서 간결한 요약 문서를 만들어줘.

## 요약 형식 (전체 500자 이내, 섹션별 bullet 3개 이내)
- 현재 상태/현황 (가장 최신 상태 기준)
- 진행 중인 것들
- 중요 결정/인사이트 (수치 보존)

날짜 정보 포함. 오래된 내용보다 최신 내용 우선.

---
${content.slice(-8000)}`; // 너무 길면 최근 것만

  const summary = callClaude(summaryPrompt, '');
  const summaryFile = join(OUTPUT_DIR, `${domainId}-summary.md`);
  writeFileSync(summaryFile, `---
name: ${DOMAINS[domainId].label} — 요약
description: ${DOMAINS[domainId].label} 도메인 최신 상태 요약. Claude Code 세션 시작 시 자동 로드.
type: user
updated: ${new Date().toISOString().slice(0, 10)}
---

${summary.trim()}
`, 'utf-8');

  log(`${domainId}-summary.md 재합성 완료`);
}

// ── 도메인별 처리 ─────────────────────────────────────────────────────────────
async function processDomain(domainId, date, discordContent, sessionContent) {
  const domain = DOMAINS[domainId];
  const combined = [discordContent, sessionContent].filter(Boolean).join('\n\n');

  if (!combined.trim()) return false;

  // 채널 필터링
  const channelContent = extractChannelSections(discordContent || '', domain.channels);

  // 키워드 필터: 채널 내용 또는 전체에서 키워드 히트
  const searchTarget = channelContent || combined;
  if (!hasKeywords(searchTarget, domain.keywords)) {
    // 세션 파일도 체크
    if (!sessionContent || !hasKeywords(sessionContent, domain.keywords)) {
      return false;
    }
  }

  const contentToExtract = channelContent
    ? channelContent + (sessionContent ? `\n\n[Claude Code 세션]\n${sessionContent}` : '')
    : combined;

  if (!contentToExtract.trim()) return false;

  log(`${domainId}: 관련 내용 발견 (${contentToExtract.length}자) → 추출 시작`);

  const extracted = callClaude(domain.prompt, contentToExtract);
  if (!extracted.trim()) { log(`${domainId}: 추출 결과 없음 — 스킵`); return false; }

  appendToFull(domainId, date, extracted);
  log(`${domainId}-full.md 업데이트 완료`);

  if (shouldRegenerateSummary(domainId)) {
    regenerateSummary(domainId);
  }

  return true;
}

// ── main ──────────────────────────────────────────────────────────────────────
async function main() {
  log(`시작 — 날짜: ${targetDate}, 도메인: ${activeDomains.join(', ')}`);
  mkdirSync(OUTPUT_DIR, { recursive: true });

  // Discord 히스토리 로드
  const historyFiles = findHistoryFiles(targetDate);
  let discordContent = '';
  if (historyFiles.length > 0) {
    log(`Discord 히스토리 ${historyFiles.length}개 로드: ${historyFiles.map(f => f.split('/').pop()).join(', ')}`);
    discordContent = historyFiles.map(f => readFileSync(f, 'utf-8')).join('\n\n');
  } else {
    log('Discord 히스토리 없음');
  }

  // Claude Code 세션 로드
  const sessionFiles = findSessionFiles(targetDate);
  let sessionContent = '';
  if (sessionFiles.length > 0) {
    log(`Claude Code 세션 ${sessionFiles.length}개 로드`);
    sessionContent = sessionFiles.map(f => readFileSync(f, 'utf-8')).join('\n\n');
  }

  if (!discordContent && !sessionContent) {
    log('처리할 내용 없음 — 종료');
    process.exit(0);
  }

  // 도메인별 처리
  let processed = 0;
  for (const domainId of activeDomains) {
    try {
      const updated = await processDomain(domainId, targetDate, discordContent, sessionContent);
      if (updated) processed++;
    } catch (err) {
      log(`${domainId} 오류: ${err.message.slice(0, 200)}`);
    }
  }

  log(`완료 — ${processed}/${activeDomains.length} 도메인 업데이트`);
}

main().catch(err => {
  log(`오류: ${err.message}`);
  process.exit(1);
});