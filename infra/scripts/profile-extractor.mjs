#!/usr/bin/env node
/**
 * profile-extractor.mjs
 *
 * jarvis-blog 채널 대화에서 주요 주제를 자동 추출해
 * Jarvis-Vault/05-topics/에 구조화 파일로 저장.
 *
 * 실행: node profile-extractor.mjs [YYYY-MM-DD]  (기본: 어제)
 * 크론: launchd com.jarvis.profile-extractor (매일 00:30)
 *
 * 출력:
 *   Vault/05-topics/YYYY-MM-DD-topics.md   ← 일별 추출본
 *   Vault/05-topics/inbox-tracker.md       ← 누적 트래커
 *
 * 프롬프트 템플릿 (개인화):
 *   ~/jarvis/private/prompts/profile-extract.md (gitignored)
 *   - 파일 있으면 해당 내용으로 추출
 *   - 없으면 generic fallback 프롬프트 사용 (주요 주제 요약)
 */

import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, appendFileSync, existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

// ── 경로 설정 ───────────────────────────────────────────────────────────────
const HOME          = homedir();
const VAULT_DIR     = join(HOME, 'Jarvis-Vault');
const DISCORD_DIR   = join(VAULT_DIR, '02-daily', 'discord');
const TOPIC_DIR     = join(VAULT_DIR, '05-topics');
const BOT_HOME      = join(HOME, 'jarvis/runtime');
const LOG_FILE      = join(BOT_HOME, 'logs', 'profile-extractor.log');
const TRACKER_FILE  = join(TOPIC_DIR, 'inbox-tracker.md');
const MCP_CONFIG    = join(BOT_HOME, 'config', 'empty-mcp.json');
const PROMPT_PATH   = join(HOME, 'jarvis', 'private', 'prompts', 'profile-extract.md');

// ── 날짜 결정 ───────────────────────────────────────────────────────────────
const targetDate = process.argv[2] ?? (() => {
  const d = new Date();
  d.setDate(d.getDate() - 1);
  return d.toISOString().slice(0, 10);
})();

const historyFile = join(DISCORD_DIR, `${targetDate}.md`);
const outputFile  = join(TOPIC_DIR,   `${targetDate}-topics.md`);

// ── 로깅 ────────────────────────────────────────────────────────────────────
function log(msg) {
  const line = `[${new Date().toISOString()}] profile-extractor: ${msg}\n`;
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

// ── 프롬프트 빌드 (private 템플릿 → fallback) ──────────────────────────────
function buildPrompt(blogContent) {
  // 1) 사용자 정의 프롬프트 우선
  if (existsSync(PROMPT_PATH)) {
    try {
      const template = readFileSync(PROMPT_PATH, 'utf-8');
      return template
        .replace(/\{\{date\}\}/g, targetDate)
        .replace(/\{\{content\}\}/g, blogContent);
    } catch (e) {
      log(`⚠️ 사용자 프롬프트 로드 실패 (${e.message}) — fallback 사용`);
    }
  }

  // 2) Generic fallback: 주제 요약만 수행
  return `아래는 ${targetDate}의 jarvis-blog Discord 채널 대화 기록입니다.

대화에서 논의된 주요 주제들을 추출해 마크다운 형식으로 정리해줘.
각 주제는 H2 헤더로. 핵심 3~5줄 요약. 원문 그대로 복붙 금지.

사용자 정의 추출 항목은 ~/jarvis/private/prompts/profile-extract.md 파일로 설정 가능.

---
${blogContent}`;
}

// ── claude -p 호출로 주제 추출 ──────────────────────────────────────────────
function extractWithClaude(blogContent) {
  const prompt = buildPrompt(blogContent);

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

// ── inbox-tracker.md 업데이트 (사용자 정의 프롬프트 사용 시 "지원 현황" 섹션 추적) ──
function updateTracker(extracted) {
  // "지원 현황" 섹션이 있으면 누적 (generic fallback 프롬프트에는 없음)
  const match = extracted.match(/## 지원 현황\n([\s\S]*?)(?=\n## |\n$|$)/);
  if (!match) return;

  const entry = `\n### ${targetDate}\n${match[1].trim()}\n`;

  if (!existsSync(TRACKER_FILE)) {
    const header = `---
title: "Inbox 트래커"
tags: [area/topics, type/tracker]
created: ${targetDate}
---

# Inbox 트래커

> profile-extractor.mjs 자동 생성 · 매일 00:30 갱신
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
  mkdirSync(TOPIC_DIR, { recursive: true });

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
title: "주제 추출 — ${targetDate}"
tags: [area/topics, type/extract]
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
  log('inbox-tracker.md 업데이트 완료');

  log('완료');
}

main().catch(err => {
  console.error(`[profile-extractor] 오류: ${err.message}`);
  process.exit(1);
});
