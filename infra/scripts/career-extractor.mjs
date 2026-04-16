#!/usr/bin/env node
/**
 * career-extractor.mjs
 *
 * jarvis-blog 채널 대화에서 커리어 인사이트를 자동 추출해
 * Jarvis-Vault/05-career/에 구조화 파일로 저장.
 *
 * 실행: node career-extractor.mjs [YYYY-MM-DD]  (기본: 어제)
 * 크론: launchd com.jarvis.career-extractor (매일 00:30)
 *
 * 출력:
 *   Vault/05-career/YYYY-MM-DD-career.md   ← 일별 추출본
 *   Vault/05-career/job-tracker.md          ← 누적 지원 현황
 */

import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, appendFileSync, existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

// ── 경로 설정 ───────────────────────────────────────────────────────────────
const HOME          = homedir();
const VAULT_DIR     = join(HOME, 'Jarvis-Vault');
const DISCORD_DIR   = join(VAULT_DIR, '02-daily', 'discord');
const CAREER_DIR    = join(VAULT_DIR, '05-career');
const BOT_HOME      = join(HOME, '.jarvis');
const LOG_FILE      = join(BOT_HOME, 'logs', 'career-extractor.log');
const TRACKER_FILE  = join(CAREER_DIR, 'job-tracker.md');
const MCP_CONFIG    = join(BOT_HOME, 'config', 'empty-mcp.json');

// ── 날짜 결정 ───────────────────────────────────────────────────────────────
const targetDate = process.argv[2] ?? (() => {
  const d = new Date();
  d.setDate(d.getDate() - 1);
  return d.toISOString().slice(0, 10);
})();

const historyFile = join(DISCORD_DIR, `${targetDate}.md`);
const outputFile  = join(CAREER_DIR,  `${targetDate}-career.md`);

// ── 로깅 ────────────────────────────────────────────────────────────────────
function log(msg) {
  const line = `[${new Date().toISOString()}] career-extractor: ${msg}\n`;
  process.stdout.write(line);
  try {
    appendFileSync(LOG_FILE, line, 'utf-8');
  } catch (e) {
    process.stderr.write(`[log write failed] ${e.message}\n`);
  }
}

// ── discord history 파싱: jarvis-blog 섹션만 추출 ───────────────────────────
function extractBlogSections(content) {
  const lines = content.split('\n');
  const sections = [];
  let inBlog = false;
  let buf = [];

  for (const line of lines) {
    // 섹션 헤더: ## [시간] #채널명
    const headerMatch = line.match(/^## \[.+?\] #(.+)/);
    if (headerMatch) {
      if (inBlog && buf.length > 0) {
        sections.push(buf.join('\n'));
        buf = [];
      }
      inBlog = headerMatch[1].trim() === 'jarvis-blog';
      if (inBlog) buf.push(line);
    } else if (inBlog) {
      buf.push(line);
    }
  }
  if (inBlog && buf.length > 0) sections.push(buf.join('\n'));
  return sections.join('\n\n---\n\n');
}

// ── claude -p 호출로 커리어 데이터 추출 ─────────────────────────────────────
function extractWithClaude(blogContent) {
  const prompt = `아래는 ${targetDate}의 jarvis-blog Discord 채널 대화 기록입니다.

다음 항목들을 추출해 마크다운 형식으로 정리해줘. 없으면 해당 섹션 생략.

## 추출 항목
1. **지원 현황** — 새로 서류 합격/불합격/지원한 회사와 포지션
2. **면접 정보** — 면접 일정, 전형 단계, 노트 (라이브코딩 여부 등)
3. **회사 분석** — 특정 회사/팀/포지션에 대해 조사한 내용 (기술스택, 팀 역할 등)
4. **이력서 변경** — 이력서 수정 사항, 버전, 주요 변경 이유
5. **면접 Q&A** — 준비한 예상 질문과 답변 방향
6. **커리어 인사이트** — 이직 전략, 포지셔닝, 주목할 관찰사항

## 출력 형식
각 항목은 H2 헤더로. 날짜 ${targetDate}를 파일 상단에. 없는 항목은 생략.
핵심만 간결하게 (각 항목 3~5줄 이내). 원문 대화 그대로 복붙 금지.

---
${blogContent}`;

  const tmpOut = `/tmp/career-extract-${targetDate}.json`;

  const result = spawnSync(
    '/opt/homebrew/bin/claude',
    [
      '-p', prompt,
      '--output-format', 'json',
      '--permission-mode', 'bypassPermissions',
      '--strict-mcp-config',
      '--mcp-config', MCP_CONFIG,
    ],
    {
      env: { ...process.env, ANTHROPIC_API_KEY: '', CLAUDECODE: '' },
      timeout: 180_000,
      maxBuffer: 4 * 1024 * 1024,
    }
  );

  if (result.status !== 0) {
    const err = result.stderr?.toString().slice(0, 300) ?? 'unknown';
    throw new Error(`claude 실패 (exit ${result.status}): ${err}`);
  }

  const raw = result.stdout.toString();
  const json = JSON.parse(raw);
  if (json.is_error) throw new Error(`claude is_error: ${json.subtype}`);
  return json.result ?? '';
}

// ── job-tracker.md 업데이트 ──────────────────────────────────────────────────
function updateTracker(extracted) {
  // 지원 현황 섹션만 추출
  const match = extracted.match(/## 지원 현황\n([\s\S]*?)(?=\n## |\n$|$)/);
  if (!match) return;

  const entry = `\n### ${targetDate}\n${match[1].trim()}\n`;

  if (!existsSync(TRACKER_FILE)) {
    const header = `---
title: "채용 지원 현황 트래커"
tags: [area/career, type/tracker]
created: ${targetDate}
---

# 채용 지원 현황 트래커

> career-extractor.mjs 자동 생성 · 매일 00:30 갱신
`;
    writeFileSync(TRACKER_FILE, header + entry, 'utf-8');
  } else {
    const current = readFileSync(TRACKER_FILE, 'utf-8');
    // 이미 같은 날짜가 있으면 덮어쓰기
    if (current.includes(`### ${targetDate}`)) {
      const updated = current.replace(
        new RegExp(`### ${targetDate}\\n[\\s\\S]*?(?=\\n### |$)`),
        `### ${targetDate}\n${match[1].trim()}\n`
      );
      writeFileSync(TRACKER_FILE, updated, 'utf-8');
    } else {
      writeFileSync(TRACKER_FILE, current + entry, 'utf-8');
    }
  }
}

// ── main ────────────────────────────────────────────────────────────────────
async function main() {
  log(`시작 — 대상 날짜: ${targetDate}`);

  // 출력 디렉토리 보장
  mkdirSync(CAREER_DIR, { recursive: true });

  // 히스토리 파일 존재 확인
  if (!existsSync(historyFile)) {
    log(`히스토리 파일 없음: ${historyFile} — 스킵`);
    process.exit(0);
  }

  // jarvis-blog 섹션 추출
  const content = readFileSync(historyFile, 'utf-8');
  const blogContent = extractBlogSections(content);

  if (!blogContent.trim()) {
    log(`${targetDate} jarvis-blog 대화 없음 — 스킵`);
    process.exit(0);
  }

  log(`jarvis-blog 섹션 추출 완료 (${blogContent.length}자) → Claude 추출 시작`);

  // Claude로 구조화 추출
  const extracted = extractWithClaude(blogContent);

  if (!extracted.trim()) {
    log('Claude 추출 결과 비어있음 — 스킵');
    process.exit(0);
  }

  // 일별 파일 저장
  const fileContent = `---
title: "커리어 추출 — ${targetDate}"
tags: [area/career, type/extract]
source: jarvis-blog
created: ${targetDate}
generated: ${new Date().toISOString()}
---

${extracted}
`;
  writeFileSync(outputFile, fileContent, 'utf-8');
  log(`저장 완료: ${outputFile}`);

  // 누적 트래커 업데이트
  updateTracker(extracted);
  log('job-tracker.md 업데이트 완료');

  log('완료');
}

main().catch(err => {
  console.error(`[career-extractor] 오류: ${err.message}`);
  process.exit(1);
});
