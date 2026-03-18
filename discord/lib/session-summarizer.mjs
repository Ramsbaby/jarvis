/**
 * session-summarizer.mjs — Phase 3-B: 자동 기억 추출 크론
 *
 * ANTHROPIC_API_KEY 없는 Claude Max 환경에서 패턴 매칭으로
 * 오늘 세션 요약 파일을 분석해 facts를 추출, userMemory에 저장.
 *
 * 실행: /opt/homebrew/bin/node ~/.jarvis/discord/lib/session-summarizer.mjs
 * 크론: 0 3 * * * (매일 새벽 3시)
 */

import { readFileSync, writeFileSync, readdirSync, mkdirSync, existsSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const SESSION_SUMMARY_DIR = join(BOT_HOME, 'state', 'session-summaries');
const USERS_DIR = join(BOT_HOME, 'state', 'users');
const LOGS_DIR = join(BOT_HOME, 'logs');
const STATE_FILE = join(BOT_HOME, 'state', 'session-summarizer-state.json');
const USER_PROFILES_FILE = join(BOT_HOME, 'config', 'user_profiles.json');

// ── user_profiles.json 기반 discordId → userId 매핑 로드 ─────────────────
// 파일명 형식: 채널ID-discordId.md → discordId로 userId 결정 (100% 정확)
function loadDiscordIdMap() {
  try {
    const profiles = JSON.parse(readFileSync(USER_PROFILES_FILE, 'utf-8'));
    const map = {};
    for (const [userId, profile] of Object.entries(profiles)) {
      if (profile.discordId) map[profile.discordId] = userId;
    }
    return map;
  } catch {
    return {};
  }
}
const DISCORD_ID_MAP = loadDiscordIdMap();

// ── 로그 헬퍼 ──────────────────────────────────────────────────────────────
function log(level, msg) {
  const ts = new Date().toISOString().slice(0, 19).replace('T', ' ');
  process.stdout.write(`[${ts}] [${level.toUpperCase()}] ${msg}\n`);
}

// ── 상태 관리: 오늘 이미 처리했으면 재실행 방지 ────────────────────────────
function loadState() {
  try {
    return JSON.parse(readFileSync(STATE_FILE, 'utf-8'));
  } catch {
    return { lastRun: null, processedDates: [] };
  }
}

function saveState(state) {
  try {
    mkdirSync(join(BOT_HOME, 'state'), { recursive: true });
    writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
  } catch (err) {
    log('warn', `상태 저장 실패: ${err.message}`);
  }
}

function getTodayStr() {
  return new Date().toISOString().slice(0, 10); // YYYY-MM-DD
}

// ── userId 목록 수집 ────────────────────────────────────────────────────────
function getOwnerUserIds() {
  try {
    const files = readdirSync(USERS_DIR).filter(f => f.endsWith('.json'));
    return files.map(f => f.replace('.json', ''));
  } catch {
    return [];
  }
}

// ── 오늘 날짜 기준 세션 요약 파일 수집 ──────────────────────────────────────
function getTodaySummaryFiles() {
  try {
    const today = getTodayStr();
    const files = readdirSync(SESSION_SUMMARY_DIR).filter(f => f.endsWith('.md'));
    const result = [];
    for (const fname of files) {
      const fpath = join(SESSION_SUMMARY_DIR, fname);
      try {
        // 파일 수정 시간으로 오늘 파일 판별
        const { mtimeMs } = statSync(fpath);
        const mdate = new Date(mtimeMs).toISOString().slice(0, 10);
        if (mdate === today) result.push(fpath);
      } catch {
        // stat 실패 시 내용 날짜 검사로 폴백
        const content = readFileSync(fpath, 'utf-8');
        if (content.includes(today)) result.push(fpath);
      }
    }
    // 오늘 파일이 없으면 전체 반환 (첫 실행 or 날짜 기반 판별 실패 대비)
    return result.length > 0 ? result : files.map(f => join(SESSION_SUMMARY_DIR, f));
  } catch (err) {
    log('warn', `세션 파일 목록 수집 실패: ${err.message}`);
    return [];
  }
}

// ── 패턴 매칭 기반 사실 후보 추출 ─────────────────────────────────────────
const PATTERNS = [
  // 금액 (달러)
  { re: /\$[\d,]+(?:\.\d+)?/g, label: '금액' },
  // 금액 (원화)
  { re: /₩[\d,]+/g, label: '금액' },
  { re: /\d+만원/g, label: '금액' },
  { re: /\d+달러/g, label: '금액' },
  // 기술명
  { re: /\b(?:Java|Spring(?:Boot)?|Kafka|Redis|AWS|gRPC|Python|JavaScript|TypeScript|Docker|Kubernetes|k8s|React|Vue|Node\.?js|PostgreSQL|MySQL|MongoDB)\b/g, label: '기술' },
  // 날짜
  { re: /\d{4}-\d{2}-\d{2}/g, label: '날짜' },
  // 요일
  { re: /(?:월요일|화요일|수요일|목요일|금요일|토요일|일요일)/g, label: '일정' },
  // 이름 (님 호칭)
  { re: /(?:대표님|[가-힣]{2,3}님)/g, label: '이름' },
  // 수업 일정 패턴
  { re: /\d{2}:\d{2}\s+\w+\s+\$[\d.]+/g, label: '수업' },
  // 총 수입/지출
  { re: /총\s*(?:수입|지출|금액)[^\n]{0,30}/g, label: '금액' },
];

const CONTEXT_WINDOW = 50; // 패턴 주변 50자 슬라이싱

function extractFacts(content) {
  const candidates = new Set();

  for (const { re } of PATTERNS) {
    // 플래그 리셋을 위해 새 RegExp 생성
    const regex = new RegExp(re.source, re.flags);
    let match;
    while ((match = regex.exec(content)) !== null) {
      const start = Math.max(0, match.index - CONTEXT_WINDOW);
      const end = Math.min(content.length, match.index + match[0].length + CONTEXT_WINDOW);
      let snippet = content.slice(start, end).trim().replace(/\n+/g, ' ').replace(/\s{2,}/g, ' ');
      // 너무 짧거나 무의미한 조각 제외
      if (snippet.length < 8) continue;
      // 마크다운 헤더/구분선만 있는 라인 제외
      if (/^[-#=]{3,}$/.test(snippet)) continue;
      candidates.add(snippet);
    }
  }

  return [...candidates];
}

// ── userMemory addFact (직접 구현 — ESM 동적 import 호환) ──────────────────
function addFactDirect(userId, factText) {
  const fpath = join(USERS_DIR, `${userId}.json`);
  const defaults = { userId, facts: [], preferences: [], corrections: [], plans: [], updatedAt: null };
  let data;
  try {
    data = JSON.parse(readFileSync(fpath, 'utf-8'));
    const merged = { ...defaults, ...data };
    merged.facts = Array.isArray(merged.facts) ? merged.facts : [];
    merged.preferences = Array.isArray(merged.preferences) ? merged.preferences : [];
    merged.corrections = Array.isArray(merged.corrections) ? merged.corrections : [];
    merged.plans = Array.isArray(merged.plans) ? merged.plans : [];
    data = merged;
  } catch {
    data = { ...defaults };
  }

  const normalize = (f) => (typeof f === 'string' ? f : f?.text ?? '');
  const exists = data.facts.some(f => normalize(f) === factText);
  if (!exists) {
    data.facts.push({ text: factText, addedAt: new Date().toISOString() });
    data.updatedAt = new Date().toISOString();
    mkdirSync(USERS_DIR, { recursive: true });
    writeFileSync(fpath, JSON.stringify(data, null, 2));
    return true; // 신규 추가
  }
  return false; // 중복 스킵
}

// ── 메인 ──────────────────────────────────────────────────────────────────
async function main() {
  mkdirSync(LOGS_DIR, { recursive: true });

  const today = getTodayStr();
  log('info', `=== session-summarizer 시작 (날짜: ${today}) ===`);

  // 오늘 이미 실행했으면 종료
  const state = loadState();
  if (state.processedDates && state.processedDates.includes(today)) {
    log('info', `오늘(${today}) 이미 처리 완료 — 재추출 건너뜀`);
    return;
  }

  const userIds = getOwnerUserIds();
  if (userIds.length === 0) {
    log('warn', `users 디렉토리에 userId 파일 없음: ${USERS_DIR}`);
    return;
  }
  log('info', `오너 userId: ${userIds.join(', ')}`);

  const summaryFiles = getTodaySummaryFiles();
  if (summaryFiles.length === 0) {
    log('info', '처리할 세션 요약 파일 없음');
    return;
  }
  log('info', `세션 파일 ${summaryFiles.length}개 처리 시작`);

  let totalExtracted = 0;
  let totalAdded = 0;

  for (const fpath of summaryFiles) {
    try {
      const rawContent = readFileSync(fpath, 'utf-8');

      // 파일명: 채널ID-discordId.md → discordId로 userId 결정 (user_profiles.json 매핑)
      // fallback: contentHead 키워드 매칭 (구형 파일명 또는 매핑 미등록 사용자)
      const fname = fpath.split('/').pop().replace(/\.md$/, '');
      const discordId = fname.split('-').pop();
      let userId_tag = DISCORD_ID_MAP[discordId] || null;
      if (!userId_tag) {
        // fallback: 내용 기반 추론
        const contentHead = rawContent.slice(0, 2000).toLowerCase();
        const FAMILY_NAME = (process.env.FAMILY_MEMBER_NAME || '').toLowerCase();
        const isFamilyMember = FAMILY_NAME && (contentHead.includes(FAMILY_NAME) && contentHead.includes('수업'))
          || contentHead.includes('preply 수업')
          || (contentHead.includes('약 복용') && !contentHead.includes('jarvis-dev'));
        userId_tag = isFamilyMember ? 'family' : 'owner';
      }

      // 파일 맨 위에 userId 메타 라인이 없으면 삽입
      let content;
      if (rawContent.startsWith('userId:')) {
        content = rawContent;
      } else {
        content = `userId: ${userId_tag}\n---\n${rawContent}`;
        writeFileSync(fpath, content);
        log('info', `  [tag] ${fpath.split('/').pop()} → userId: ${userId_tag}`);
      }

      const candidates = extractFacts(content);
      log('info', `  ${fpath.split('/').pop()} → 후보 ${candidates.length}개`);

      for (const fact of candidates) {
        totalExtracted++;
        for (const userId of userIds) {
          try {
            const added = addFactDirect(userId, fact);
            if (added) {
              totalAdded++;
              log('info', `    [+] userId=${userId} fact: ${fact.slice(0, 80)}`);
            }
          } catch (err) {
            log('warn', `    addFact 실패 userId=${userId}: ${err.message}`);
          }
        }
      }
    } catch (err) {
      log('warn', `파일 처리 실패 (${fpath}): ${err.message}`);
    }
  }

  // 상태 업데이트
  state.lastRun = new Date().toISOString();
  state.processedDates = [...(state.processedDates || []), today].slice(-30); // 최근 30일만 유지
  saveState(state);

  log('info', `=== 완료: 후보 ${totalExtracted}개 추출, 신규 facts ${totalAdded}개 저장 ===`);
}

main().catch(err => {
  log('error', `치명적 오류: ${err.message}`);
  process.exit(1);
});
