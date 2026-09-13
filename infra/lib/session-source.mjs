/**
 * session-source.mjs — 자기개선 파이프라인 입력 소스 해석기
 *
 * 2026-09-13 재배선. 배경:
 *   오답노트/인사이트 추출기는 `state/session-summaries/*.md` 를 유일 입력으로 삼았다.
 *   그 파일의 생산자는 크론이 아니라 **자비스 디스코드 봇의 부산물**이었고,
 *   봇이 2026-09-10 에 정지되면서 입력이 말라붙었다. 추출기는 실패하지 않고
 *   "신규 세션 요약 없음"을 찍으며 rc=0 으로 끝나 4일간 아무도 눈치채지 못했다.
 *
 * 살아 있는 대체 입력은 `jarvis-cli-rag-sync`(10분 주기)가 쓰는
 *   `inbox/claude-cli-YYYY-MM-DD-<hash>.md`  — Claude CLI 원본 대화다.
 *
 * 두 소스는 형식이 다르다:
 *   - 디스코드 요약: `[2026-09-09 12:49:02] User: …` / `… Jarvis: …`, 파일명 `{channelId}-{userId}.md`
 *   - CLI 인박스:   `## **[사용자]** 09:49` / `## **[Jarvis CLI]** 09:50`, 파일명에 userId 없음
 *
 * 이 모듈이 그 차이를 흡수한다. 호출자는 `{path, body, label}` 만 본다.
 * 두 소스를 모두 읽으므로 디스코드 요약이 되살아나도 코드 변경 없이 다시 흘러든다.
 *
 * 소스가 0건이면 그것은 **정상이 아니라 경보**다 — `sources.length === 0` 을
 * 조용한 성공으로 처리하지 말 것. (위 4일 무감지의 직접 원인)
 */

import { readdirSync, statSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

export const DEFAULT_BOT_HOME = process.env.BOT_HOME
  || join(homedir(), '.openclaw-data', 'runtime');

// CLI 인박스 파일명: claude-cli-2026-09-13-1fa408b5.md
const CLI_INBOX_RE = /^claude-cli-(\d{4}-\d{2}-\d{2})-([0-9a-f]+)\.md$/;

/**
 * 입력 소스 목록을 수집한다.
 *
 * @param {object}   opts
 * @param {string}  [opts.botHome]    기본 BOT_HOME
 * @param {number}  [opts.sinceMs]    이 시각 이후 mtime 만 (미지정 시 전체)
 * @param {number}  [opts.maxFiles]   상한 (최신순). 0/미지정이면 무제한
 * @param {number}  [opts.minBytes]   이보다 작은 파일 제외 (기본 300)
 * @param {string[]}[opts.ownerIds]   디스코드 요약 전용 owner userId 화이트리스트.
 *                                    비면 디스코드 요약은 필터하지 않는다.
 *                                    (CLI 인박스는 주인님 전용이라 항상 통과)
 * @returns {Array<{path,mtime,size,kind,label,channelId,date}>}
 */
export function collectSessionSources(opts = {}) {
  const botHome  = opts.botHome  || DEFAULT_BOT_HOME;
  const sinceMs  = Number.isFinite(opts.sinceMs) ? opts.sinceMs : -Infinity;
  const minBytes = Number.isFinite(opts.minBytes) ? opts.minBytes : 300;
  const ownerIds = Array.isArray(opts.ownerIds) ? opts.ownerIds.filter(Boolean) : [];

  const out = [];

  // ── 소스 1: Claude CLI 인박스 (현행 · jarvis-cli-rag-sync 가 10분마다 갱신) ──
  const inboxDir = join(botHome, 'inbox');
  if (existsSync(inboxDir)) {
    for (const name of safeReaddir(inboxDir)) {
      const m = CLI_INBOX_RE.exec(name);
      if (!m) continue;
      const st = safeStat(join(inboxDir, name));
      if (!st || st.mtimeMs <= sinceMs || st.size < minBytes) continue;
      out.push({
        path: join(inboxDir, name),
        mtime: st.mtimeMs,
        size: st.size,
        kind: 'cli-inbox',
        label: `Claude CLI ${m[1]} [${m[2]}]`,
        channelId: `cli:${m[2]}`,
        date: m[1],
      });
    }
  }

  // ── 소스 2: 디스코드 세션 요약 (레거시 · 봇 정지로 2026-09-10 이후 동결) ──
  const summaryDir = join(botHome, 'state', 'session-summaries');
  if (existsSync(summaryDir)) {
    for (const name of safeReaddir(summaryDir)) {
      if (!name.endsWith('.md') || name.endsWith('.bak')) continue;
      const parts = name.slice(0, -3).split('-');
      const userId = parts[parts.length - 1];
      // ownerIds 가 주어졌을 때만 화이트리스트를 건다. 비어 있으면 거르지 않는다 —
      // 2026-09-10 이관에서 잡 env 의 OWNER_USER_IDS 가 유실돼 필터가 전량 차단으로
      // 동작한 전례가 있다(빈 배열 .includes() 는 항상 false). 기본값은 통과다.
      if (ownerIds.length && !ownerIds.includes(userId)) continue;
      const st = safeStat(join(summaryDir, name));
      if (!st || st.mtimeMs <= sinceMs || st.size < minBytes) continue;
      out.push({
        path: join(summaryDir, name),
        mtime: st.mtimeMs,
        size: st.size,
        kind: 'discord-summary',
        label: `Discord ${name.slice(0, -3)}`,
        channelId: parts.slice(0, -1).join('-'),
        date: new Date(st.mtimeMs).toLocaleDateString('sv-SE', { timeZone: 'Asia/Seoul' }),
      });
    }
  }

  out.sort((a, b) => b.mtime - a.mtime);
  return opts.maxFiles > 0 ? out.slice(0, opts.maxFiles) : out;
}

/**
 * 본문을 LLM 프롬프트용으로 줄인다.
 *
 * 통짜 `slice(0, N)` 을 쓰지 않는 이유: 주인님의 지적은 대화 **후반**에 몰린다
 * (자비스가 먼저 틀린 답을 내고 그 뒤에 정정이 온다). 앞에서 자르면 정확히
 * 추출 대상만 버린다. CLI 인박스 파일은 최대 160KB 라 이 차이가 결정적이다.
 *
 * 그래서 앞(맥락)과 뒤(정정)를 함께 남기고 가운데를 생략한다.
 */
export function excerptForPrompt(body, maxChars = 12000, headRatio = 0.25) {
  if (body.length <= maxChars) return body;
  const head = Math.floor(maxChars * headRatio);
  const tail = maxChars - head;
  const omitted = body.length - maxChars;
  return `${body.slice(0, head)}\n\n…(중략 ${omitted.toLocaleString()}자)…\n\n${body.slice(-tail)}`;
}

/** 소스 목록을 읽어 프롬프트에 넣을 형태로 만든다. */
export function readSourceBodies(sources, maxCharsPerFile = 12000) {
  return sources.map(s => ({
    ...s,
    body: excerptForPrompt(readFileSync(s.path, 'utf-8'), maxCharsPerFile),
  }));
}

function safeReaddir(dir) { try { return readdirSync(dir); } catch { return []; } }
function safeStat(p)      { try { return statSync(p);    } catch { return null; } }
