/**
 * artifact-uploader.js — 긴 코드/문서를 jarvis-board로 업로드
 *
 * Claude.ai의 Artifact처럼, 채팅 스크롤을 잡아먹는 긴 산출물을
 * 별도 board 포스트로 분리하고 채팅에는 요약 + 링크만 남긴다.
 *
 * 트리거:
 *   - 코드 블록 한 개가 CODE_LINES_THRESHOLD(30줄+)
 *   - 전체 본문이 TOTAL_CHARS_THRESHOLD(2500자+)
 *
 * 반환:
 *   - { id, url, title, snippet, reason }  — 업로드 성공
 *   - null                                   — 미업로드 (기준 미달 / 실패 / 비활성)
 *
 * 환경변수:
 *   BOARD_URL          (필수 — 없으면 no-op. $BOT_HOME/.env 에 설정)
 *   AGENT_API_KEY      (필수 — 없으면 no-op)
 *   ARTIFACT_ENABLED   ('0'으로 설정 시 전체 비활성)
 */

import { log } from './claude-runner.js';
import { BoundedMap } from './bounded-map.js';

const CODE_LINES_THRESHOLD = 30;
const TOTAL_CHARS_THRESHOLD = 2500;
const MAX_TITLE_LEN = 80;
const MAX_SNIPPET_LEN = 320;

// P3-2: Revision history — sessionKey별로 업로드한 artifact { id, rev, at } 리스트 추적.
// 재시작 시 유실되어도 무방(사용자는 board에서 직접 검색 가능).
// BoundedMap(500 세션, 24h TTL)로 메모리 누수 방지.
const _revHistory = new BoundedMap(500, 24 * 60 * 60 * 1000);

// ---------------------------------------------------------------------------
// 코드 블록 추출 — ```lang ... ``` 형태 파싱
// ---------------------------------------------------------------------------
export function extractCodeBlocks(text) {
  if (!text || typeof text !== 'string') return [];
  const blocks = [];
  const re = /```(\w*)\n([\s\S]*?)```/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    const lang = m[1] || '';
    const body = m[2] || '';
    const lines = body.split('\n').length;
    blocks.push({ lang, body, lines, start: m.index, end: m.index + m[0].length });
  }
  return blocks;
}

// ---------------------------------------------------------------------------
// 자동 제목 생성 — 본문 앞부분에서 의미 있는 문장/헤딩 추출
// ---------------------------------------------------------------------------
function _autoTitle(text, fallback = '아티팩트') {
  if (!text) return fallback;
  // 1순위: 첫 번째 ## 또는 ### 헤딩
  const headingMatch = text.match(/^##+\s+(.+)$/m);
  if (headingMatch) return _clip(headingMatch[1].trim(), MAX_TITLE_LEN);
  // 2순위: 첫 번째 단락의 첫 문장
  const firstLine = text.split('\n').map(l => l.trim()).find(l => l.length > 0);
  if (firstLine) {
    const sentence = firstLine.split(/[.!?。]/)[0] || firstLine;
    return _clip(sentence.replace(/^[-*#>`]+\s*/, ''), MAX_TITLE_LEN);
  }
  return fallback;
}

function _clip(s, max) {
  if (!s) return '';
  return s.length > max ? s.slice(0, max - 1) + '…' : s;
}

// ---------------------------------------------------------------------------
// 스니펫 — 본문 앞 N자 (코드 블록 제외하고 자연스러운 단락 경계에서 자름)
// ---------------------------------------------------------------------------
function _snippet(text) {
  if (!text) return '';
  // 코드 블록 제거 (스니펫은 서술용)
  const stripped = text.replace(/```[\s\S]*?```/g, '[코드 블록]').trim();
  if (stripped.length <= MAX_SNIPPET_LEN) return stripped;
  const idx = stripped.lastIndexOf('\n\n', MAX_SNIPPET_LEN);
  const cutAt = idx > MAX_SNIPPET_LEN * 0.5 ? idx : MAX_SNIPPET_LEN;
  return stripped.slice(0, cutAt).trim() + '…';
}

// ---------------------------------------------------------------------------
// 업로드 판단 — 크기 기준
// ---------------------------------------------------------------------------
export function shouldUpload(content) {
  if (!content) return { upload: false, reason: 'empty' };
  if (process.env.ARTIFACT_ENABLED === '0') return { upload: false, reason: 'disabled' };

  const blocks = extractCodeBlocks(content);
  const longestCode = blocks.reduce((m, b) => Math.max(m, b.lines), 0);
  if (longestCode >= CODE_LINES_THRESHOLD) {
    return { upload: true, reason: `code-${longestCode}-lines` };
  }
  if (content.length >= TOTAL_CHARS_THRESHOLD) {
    return { upload: true, reason: `long-${content.length}-chars` };
  }
  return { upload: false, reason: 'below-threshold' };
}

// ---------------------------------------------------------------------------
// 실제 업로드 — board POST /api/posts
// ---------------------------------------------------------------------------
export async function uploadArtifact({ content, sessionKey, channelName, author = 'jarvis' }) {
  const decision = shouldUpload(content);
  if (!decision.upload) return null;

  const boardUrl = process.env.BOARD_URL;
  const agentKey = process.env.AGENT_API_KEY;
  if (!boardUrl) {
    log('debug', 'artifact-uploader: BOARD_URL missing — skip upload', { sessionKey });
    return null;
  }
  if (!agentKey) {
    log('debug', 'artifact-uploader: AGENT_API_KEY missing — skip upload', { sessionKey });
    return null;
  }

  const title = _autoTitle(content);
  const tags = ['artifact', channelName || 'general'];

  // P3-2: Revision 계산 — 이 세션에서 몇 번째 artifact인지
  const history = sessionKey ? (_revHistory.get(sessionKey) ?? []) : [];
  const rev = history.length + 1;
  const prevArtifact = history.length > 0 ? history[history.length - 1] : null;

  // title 중복 회피 (board는 7일 내 동일 title 거부) — sessionKey + rev 꼬리 부착
  const revTag = rev > 1 ? ` · v${rev}` : '';
  const suffix = sessionKey
    ? ` · ${String(sessionKey).slice(-6)}${revTag}`
    : ` · ${Date.now().toString(36).slice(-6)}${revTag}`;
  const finalTitle = _clip(title, MAX_TITLE_LEN - suffix.length) + suffix;

  try {
    // Revision chain tag — board 검색 시 동일 세션 artifact 그룹핑 가능
    const allTags = [...tags];
    if (sessionKey) allTags.push(`session:${String(sessionKey).slice(-6)}`);
    if (rev > 1) allTags.push(`rev:${rev}`);
    if (prevArtifact) allTags.push(`prev:${prevArtifact.id}`);

    // 본문 푸터 — 이전 버전 링크 (체이닝)
    let finalContent = content;
    if (prevArtifact) {
      const prevLink = `${boardUrl}/post/${prevArtifact.id}`;
      finalContent += `\n\n---\n\n-# 🔗 이전 버전: [v${prevArtifact.rev}](${prevLink}) · ${new Date(prevArtifact.at).toLocaleString('ko-KR')}`;
    }

    const res = await fetch(`${boardUrl}/api/posts`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-agent-key': agentKey,
      },
      body: JSON.stringify({
        title: finalTitle,
        type: 'artifact', // 'discussion'이 아니므로 unique 제약 없음
        author,
        author_display: author,
        content: finalContent,
        priority: 'low',
        tags: allTags,
      }),
    });
    if (!res.ok) {
      const errText = await res.text().catch(() => '');
      log('warn', 'artifact-uploader: POST failed', { status: res.status, err: errText.slice(0, 200) });
      return null;
    }
    const post = await res.json();
    const postUrl = `${boardUrl}/post/${post.id}`;

    // P3-2: revision history 갱신
    if (sessionKey) {
      const updated = [...history, { id: post.id, rev, at: Date.now() }];
      _revHistory.set(sessionKey, updated);
    }

    log('info', 'artifact-uploader: uploaded', {
      id: post.id,
      rev,
      reason: decision.reason,
      len: finalContent.length,
      sessionKey,
      prevId: prevArtifact?.id ?? null,
    });
    return {
      id: post.id,
      url: postUrl,
      title: finalTitle,
      snippet: _snippet(content),
      reason: decision.reason,
      rev,
      prevId: prevArtifact?.id ?? null,
      prevUrl: prevArtifact ? `${boardUrl}/post/${prevArtifact.id}` : null,
    };
  } catch (err) {
    log('warn', 'artifact-uploader: network error', { error: err.message });
    return null;
  }
}

// ---------------------------------------------------------------------------
// 아티팩트 카드 마크다운 — 채팅에 표시할 요약
// ---------------------------------------------------------------------------
export function renderArtifactCard(artifact) {
  if (!artifact) return '';
  const { title, url, snippet, reason, rev, prevUrl } = artifact;
  const reasonLabel = reason?.startsWith('code-')
    ? `📄 코드 ${reason.split('-')[1]}줄`
    : reason?.startsWith('long-')
      ? `📝 장문 ${reason.split('-')[1]}자`
      : '📦 아티팩트';
  const revLabel = rev && rev > 1 ? ` · 📑 v${rev}` : '';
  const lines = [
    `### 📄 ${title}`,
    '',
    snippet,
    '',
    `-# ${reasonLabel}${revLabel} · 전체 내용 → ${url}`,
  ];
  // P3-2: 이전 버전이 있으면 체이닝 링크 함께 표시
  if (prevUrl) {
    lines.push(`-# 🔗 이전 버전 → ${prevUrl}`);
  }
  return lines.join('\n');
}

/**
 * P3-2: 특정 세션의 revision 히스토리 반환 (테스트/디버깅용).
 * @param {string} sessionKey
 * @returns {Array<{id, rev, at}>}
 */
export function getArtifactHistory(sessionKey) {
  if (!sessionKey) return [];
  return _revHistory.get(sessionKey) ?? [];
}
