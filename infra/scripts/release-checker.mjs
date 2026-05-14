#!/usr/bin/env node
/**
 * release-checker.mjs — Jarvis 릴리즈 체크 & 업데이트 처리
 *
 * 매일 새벽 03:00에 LaunchAgent가 실행.
 * 1. GitHub API로 Ramsbaby/jarvis 최신 릴리즈 확인
 * 2. 현재 설치 버전과 비교
 * 3. 새 버전이면:
 *    - 자동 업데이트 모드: git pull + 봇 재시작 + Discord 알림
 *    - 수동 업데이트 모드: Discord 알림만 발송
 *
 * Usage:
 *   node release-checker.mjs          # 정상 실행
 *   node release-checker.mjs --dry-run # 실제 액션 없이 로그만
 */
import { readFileSync, writeFileSync, existsSync, mkdirSync, appendFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { execSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// ── 환경 설정 ────────────────────────────────────────────────────────────────

const HOME = homedir();
const BOT_HOME = process.env.BOT_HOME || join(HOME, '.local', 'share', 'jarvis');
const ENV_PATH = process.env.ENV_PATH || join(HOME, 'jarvis/runtime', '.env');
const UPDATE_CHANNEL_ID = process.env.UPDATE_CHANNEL_ID;
const DRY_RUN = process.argv.includes('--dry-run');

const VERSION_FILE = join(BOT_HOME, 'config', 'installed-version.json');
const POLICY_FILE  = join(HOME, 'jarvis/runtime', 'config', 'update-policy.json');
const LOG_FILE     = join(BOT_HOME, 'logs', 'release-checker.log');
const UPSTREAM_REPO = 'Ramsbaby/jarvis';
const GITHUB_API    = `https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest`;

mkdirSync(join(BOT_HOME, 'logs'), { recursive: true });
mkdirSync(join(BOT_HOME, 'config'), { recursive: true });

// ── 로거 ─────────────────────────────────────────────────────────────────────

function log(level, msg, data = {}) {
  const line = JSON.stringify({ ts: new Date().toISOString(), level, msg, ...data });
  console.log(line);
  try { appendFileSync(LOG_FILE, line + '\n'); } catch {}
}

// ── .env 파서 ────────────────────────────────────────────────────────────────

function loadEnv() {
  if (!existsSync(ENV_PATH)) return {};
  const lines = readFileSync(ENV_PATH, 'utf-8').split('\n');
  const env = {};
  for (const line of lines) {
    const t = line.trim();
    if (!t || t.startsWith('#')) continue;
    const idx = t.indexOf('=');
    if (idx === -1) continue;
    env[t.slice(0, idx).trim()] = t.slice(idx + 1).trim();
  }
  return env;
}

// ── GitHub API ───────────────────────────────────────────────────────────────

async function fetchLatestRelease() {
  const res = await fetch(GITHUB_API, {
    headers: {
      'User-Agent': 'jarvis-release-checker/1.0',
      'Accept': 'application/vnd.github.v3+json',
    },
  });
  if (!res.ok) throw new Error(`GitHub API ${res.status}: ${res.statusText}`);
  return res.json();
}

// ── 버전 관리 ────────────────────────────────────────────────────────────────

function getInstalledVersion() {
  if (!existsSync(VERSION_FILE)) return null;
  try {
    return JSON.parse(readFileSync(VERSION_FILE, 'utf-8'));
  } catch { return null; }
}

function saveInstalledVersion(tag, publishedAt) {
  writeFileSync(VERSION_FILE, JSON.stringify({ tag, publishedAt, updatedAt: new Date().toISOString() }, null, 2));
}

/**
 * semver 비교: upstream 태그가 installed 태그보다 크면 true.
 * v1.2.3 형식 가정 (v 접두어 optional). 파싱 실패 시 업데이트 시도.
 */
function isNewerVersion(latestTag, installedTag) {
  if (!installedTag) return true; // 설치 기록 없음 → 업데이트 필요
  const parse = (tag) => {
    const clean = tag.replace(/^v/i, '');
    const parts = clean.split('.').map(Number);
    return [parts[0] ?? 0, parts[1] ?? 0, parts[2] ?? 0];
  };
  const [lMaj, lMin, lPat] = parse(latestTag);
  const [iMaj, iMin, iPat] = parse(installedTag);
  if (isNaN(lMaj) || isNaN(iMaj)) return true; // 파싱 불가 → 업데이트 시도
  if (lMaj !== iMaj) return lMaj > iMaj;
  if (lMin !== iMin) return lMin > iMin;
  return lPat > iPat;
}

// ── 업데이트 정책 ─────────────────────────────────────────────────────────────

function getUpdatePolicy() {
  if (!existsSync(POLICY_FILE)) return { mode: 'manual' }; // 기본값: 수동
  try { return JSON.parse(readFileSync(POLICY_FILE, 'utf-8')); } catch { return { mode: 'manual' }; }
}

// ── Discord 알림 ─────────────────────────────────────────────────────────────

async function sendDiscordNotification(token, channelId, embed) {
  const res = await fetch(`https://discord.com/api/v10/channels/${channelId}/messages`, {
    method: 'POST',
    headers: {
      'Authorization': `Bot ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ embeds: [embed] }),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Discord API ${res.status}: ${text}`);
  }
  return res.json();
}

// ── 자동 업데이트 ─────────────────────────────────────────────────────────────

function performAutoUpdate(projectRoot) {
  log('info', 'auto-update: git pull 시작');
  execSync('git fetch origin && git merge --ff-only origin/main', {
    cwd: projectRoot, stdio: 'pipe',
  });
  log('info', 'auto-update: 파일 동기화');
  // live 경로 동기화
  const liveLib = join(BOT_HOME, 'discord', 'lib');
  const srcLib  = join(projectRoot, 'infra', 'discord', 'lib');
  mkdirSync(liveLib, { recursive: true });
  execSync(`cp -R "${srcLib}/." "${liveLib}/"`, { stdio: 'pipe' });
  // npm install (의존성 변경 있을 수 있음)
  execSync('npm install --omit=dev 2>/dev/null || true', { cwd: projectRoot, stdio: 'pipe' });
  log('info', 'auto-update: 봇 재시작 예약');
}

// ── 메인 ──────────────────────────────────────────────────────────────────────

async function main() {
  log('info', DRY_RUN ? '🔍 dry-run 모드 시작' : '🔍 릴리즈 체크 시작');

  // 환경변수 로드
  const env = loadEnv();
  const discordToken = env.DISCORD_TOKEN;
  const channelId = UPDATE_CHANNEL_ID || env.UPDATE_CHANNEL_ID;

  if (!discordToken) {
    log('error', 'DISCORD_TOKEN 없음 — .env 확인 필요');
    process.exit(1);
  }

  // 현재 설치 버전
  const installed = getInstalledVersion();
  log('info', '현재 버전', { installed: installed?.tag ?? 'unknown' });

  // 최신 릴리즈 조회
  let latest;
  try {
    latest = await fetchLatestRelease();
  } catch (err) {
    log('error', 'GitHub API 조회 실패', { error: err.message });
    return;
  }

  const latestTag     = latest.tag_name;
  const latestBody    = (latest.body || '').slice(0, 800);
  const latestUrl     = latest.html_url;
  const publishedAt   = latest.published_at;

  log('info', '최신 릴리즈', { tag: latestTag });

  // 버전 비교 — upstream이 installed보다 크면 업데이트
  if (!isNewerVersion(latestTag, installed?.tag)) {
    log('info', '최신 버전 사용 중 — 액션 없음', { installed: installed?.tag, latest: latestTag });
    return;
  }

  log('info', '새 버전 감지 (upstream > installed)', { from: installed?.tag ?? 'unknown', to: latestTag });

  const policy = getUpdatePolicy();
  log('info', '업데이트 정책', { mode: policy.mode });

  if (DRY_RUN) {
    log('info', `[dry-run] ${policy.mode === 'auto' ? '자동 업데이트 실행 예정' : 'Discord 알림 발송 예정'}`, { latestTag });
    return;
  }

  if (!channelId) {
    log('warn', 'UPDATE_CHANNEL_ID 없음 — Discord 알림 건너뜀');
  }

  // ── 자동 업데이트 ──
  if (policy.mode === 'auto') {
    try {
      // 프로젝트 루트 (이 스크립트: infra/scripts/release-checker.mjs)
      const __dirname = dirname(fileURLToPath(import.meta.url));
      const projectRoot = join(__dirname, '../..');
      performAutoUpdate(projectRoot);
      saveInstalledVersion(latestTag, publishedAt);

      if (channelId) {
        await sendDiscordNotification(discordToken, channelId, {
          title: `✅ Jarvis ${latestTag} 자동 업데이트 완료`,
          description: latestBody || '변경 내역 없음',
          color: 5763719, // 초록
          fields: [{ name: '📦 릴리즈', value: `[${latestTag}](${latestUrl})`, inline: true }],
          timestamp: new Date().toISOString(),
          footer: { text: 'Jarvis Auto-Updater' },
        });
      }

      // 봇 재시작 (setsid 분리)
      const restartScript = join(BOT_HOME, 'scripts', 'bot-self-restart.sh');
      if (existsSync(restartScript)) {
        spawn('bash', [restartScript, `자동 업데이트: ${latestTag}`], {
          detached: true, stdio: 'ignore',
        }).unref();
      }
      log('info', '자동 업데이트 완료', { tag: latestTag });

    } catch (err) {
      log('error', '자동 업데이트 실패', { error: err.message });
      // 실패해도 알림은 발송
      if (channelId) {
        await sendDiscordNotification(discordToken, channelId, {
          title: `⚠️ Jarvis ${latestTag} 자동 업데이트 실패`,
          description: `오류: ${err.message}\n\n수동으로 업데이트해 주세요.`,
          color: 15548997, // 빨강
          fields: [{ name: '📦 릴리즈', value: `[${latestTag}](${latestUrl})`, inline: true }],
          timestamp: new Date().toISOString(),
          footer: { text: 'Jarvis Auto-Updater' },
        });
      }
    }

  // ── 수동 알림 ──
  } else {
    if (channelId) {
      await sendDiscordNotification(discordToken, channelId, {
        title: `🆕 Jarvis ${latestTag} 새 릴리즈가 있습니다`,
        description: latestBody || '변경 내역 없음',
        color: 16705372, // 노랑
        fields: [
          { name: '📦 릴리즈', value: `[${latestTag}](${latestUrl})`, inline: true },
          { name: '🔧 수동 업데이트', value: '`git pull && npm install`', inline: true },
        ],
        timestamp: new Date().toISOString(),
        footer: { text: 'Jarvis Release Radar' },
      });
      log('info', '수동 알림 발송 완료', { tag: latestTag });
    }
    // 알림 발송 후 버전 기록 — 다음 실행 시 중복 알림 방지
    saveInstalledVersion(latestTag, publishedAt);
    log('info', '알림 버전 저장 완료 (중복 알림 방지)', { tag: latestTag });
  }
}

main().catch(err => {
  console.error(JSON.stringify({ ts: new Date().toISOString(), level: 'fatal', error: err.message }));
  process.exit(1);
});