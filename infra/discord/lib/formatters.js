// formatters.js — Discord 응답 포맷터 3종 (plain text markdown)
//
// 목적: 봇 응답을 embed 카드가 아닌 "평문 markdown"으로 통일. 신규 크론이
// 또 custom embed를 만드는 재발을 구조적으로 차단한다.
//
// 설계 근거 (웹 리서치 + 검증팀 2명 병렬 투입 결과):
//   - AnIdiotsGuide: "embed는 권한/설정으로 비활성화 가능, 모바일에서 다르게
//     보이므로 text-only fallback 없으면 쓰지 말 것"
//   - Discord 공식 Safety: embed는 "정적·미학 콘텐츠"용이지 모니터링용 아님
//   - 모바일 사용자 비중 > 60%, embed는 폭이 절반 이하로 압축됨
//   - ANSI 컬러 코드블록은 모바일 미지원 → 색에 의미 싣지 말 것
//   - 모니터링 봇 튜토리얼 표준은 `{"content": "..."}` 평문
//
// 장점:
//   - 모바일/데스크톱 렌더 동일
//   - 복사/붙여넣기 가능 (embed는 불가)
//   - URL unfurl은 평문에서도 동작, mentions 트리거 동작
//   - 메인터넌스 감소 (EmbedBuilder 트리 없음)
//
// 푸시 알림 프리뷰 보호:
//   첫 줄에 핵심 정보 배치. alertFormat은 `{icon} **{title}**` 1줄로 시작해
//   프리뷰에 제목이 온전히 노출되도록 한다.
//
// ── API ──
//   alertFormat({ title, state, summary, detail, footer })  → string
//   reportFormat({ title, state, items[], context, footer }) → string
//   tableFormat({ title, headers, rows, state, note, footer }) → string
//
// 채널 전송: channel.send(text)
// Webhook:  JSON.stringify({ content: text })

// ── 상태 사전 ─────────────────────────────────────────────────────────────
// 이모지는 모바일/데스크톱/스크린리더/복붙 전 환경에서 의미 유지.
const STATE_ICON = {
  ok:       '🟢',
  good:     '🟢',
  success:  '✅',
  warn:     '🟡',
  warning:  '🟡',
  at_risk:  '🟡',
  error:    '🔴',
  critical: '🔴',
  failed:   '❌',
  info:     '🔵',
  neutral:  '⚪',
};

const STATE_RANK = {
  ok: 0, good: 0, success: 0,
  info: 1, neutral: 1,
  warn: 2, warning: 2, at_risk: 2,
  error: 3, critical: 3, failed: 3,
};

function iconOf(state) {
  return STATE_ICON[String(state || 'info').toLowerCase()] || STATE_ICON.info;
}

function worstOf(items) {
  let max = -1;
  let maxState = 'info';
  for (const it of items || []) {
    const s = String(it?.state || 'info').toLowerCase();
    const rank = STATE_RANK[s] ?? 1;
    if (rank > max) { max = rank; maxState = s; }
  }
  return maxState;
}

// ── CJK 폭 보정 ───────────────────────────────────────────────────────────
// Discord monospace 폰트에서 한글/한자/이모지는 ASCII 2배 폭을 차지한다.
// String#length는 코드포인트 기준이라 표 정렬이 깨짐 → displayWidth로 대체.
function charWidth(ch) {
  const c = ch.codePointAt(0);
  if (
    (c >= 0x1100 && c <= 0x115F) ||   // Hangul Jamo
    (c >= 0x2E80 && c <= 0x9FFF) ||   // CJK
    (c >= 0xA960 && c <= 0xA97F) ||   // Hangul Jamo Ext-A
    (c >= 0xAC00 && c <= 0xD7A3) ||   // Hangul Syllables
    (c >= 0xF900 && c <= 0xFAFF) ||   // CJK Compatibility Ideographs
    (c >= 0xFE30 && c <= 0xFE4F) ||
    (c >= 0xFF00 && c <= 0xFF60) ||   // Fullwidth
    (c >= 0xFFE0 && c <= 0xFFE6)
  ) return 2;
  if (c >= 0x1F300 && c <= 0x1FAFF) return 2;  // Emoji Presentation
  return 1;
}

function displayWidth(s) {
  let w = 0;
  for (const ch of String(s ?? '')) w += charWidth(ch);
  return w;
}

function padCell(s, targetWidth) {
  const cur = displayWidth(s);
  if (cur >= targetWidth) return String(s ?? '');
  return String(s ?? '') + ' '.repeat(targetWidth - cur);
}

// Discord 메시지 content 한도 = 2000자. 여유 있게 1900에서 자름.
const MSG_LIMIT = 1900;
function clampMsg(s) {
  if (!s) return '';
  if (s.length <= MSG_LIMIT) return s;
  return s.slice(0, MSG_LIMIT - 40) + '\n\n… (잘림, 상세는 로그 참조)';
}

// ── 1. alertFormat ────────────────────────────────────────────────────────
// 1~2줄 상태 알림. 첫 줄이 푸시 프리뷰 → 짧고 구체적으로.
// detail이 1줄이면 summary 바로 아래 붙이고, 2줄 이상이면 빈 줄로 분리.
//
// 출력 예:
//   🔴 **브랜드 태스크 에스컬레이션**
//   미처리 태스크 4건이 기한 초과
//   대상: brand-visibility-check · 최근 발생 14:00
//   -# Bot Monitor · 22:53 KST
export function alertFormat({ title, state = 'info', summary = '', detail, footer }) {
  if (!title) throw new Error('alertFormat: title 필수');
  const icon = iconOf(state);
  const lines = [`${icon} **${title}**`];
  if (summary) lines.push(summary);
  if (detail) {
    // 1줄짜리 detail은 summary와 붙여 읽기, 다줄이면 빈 줄로 시각 분리
    if (detail.includes('\n')) lines.push('', detail);
    else lines.push(detail);
  }
  if (footer) lines.push(`-# ${footer}`);
  return clampMsg(lines.join('\n'));
}

// ── 항목 렌더 헬퍼 ─────────────────────────────────────────────────────────
function renderItem(it) {
  const sub = iconOf(it.state);
  const label = it.label || '';
  const value = it.value != null && it.value !== '' ? ` — **${it.value}**` : '';
  const note  = it.note ? ` _(${it.note})_` : '';
  return `${sub} ${label}${value}${note}`;
}

// ── 2. reportFormat ───────────────────────────────────────────────────────
// 다항목 상태 보고. 두 가지 입력 모드:
//
//   (a) flat items — 단순 목록
//       reportFormat({ title, items: [{state,label,value,note}] })
//
//   (b) sections — 카테고리별 그룹핑 (실패/경고/정상 등)
//       reportFormat({ title, sections: [{heading, state?, items: [...]}] })
//
// 섹션 모드는 `### {icon} {heading} ({count})` markdown heading으로 렌더돼
// 영역 구분이 확실해진다. Discord ###는 굵고 크게 표시되며 위에 자동 간격.
//
// 출력 예 (섹션 모드):
//   🔴 **일일 시스템 진단**
//   전체 80개 크론 중 6개 이상 경고
//
//   ### ❌ 실패 (3)
//   ❌ security-scan — 타임아웃
//   ❌ memory-cleanup — FATAL: permission denied
//
//   ### 🟡 경고 (2)
//   🟡 career-extractor — 실행 58초
//
//   ### 🟢 정상
//   🟢 나머지 74개 — 정상
//   -# 2026-04-14 23:05 KST
export function reportFormat({ title, state, items = [], sections, context, footer }) {
  if (!title) throw new Error('reportFormat: title 필수');

  // 전체 최악 상태 산출 (flat + sections 모두 고려)
  const allStates = sections
    ? sections.flatMap((s) => [{ state: s.state }, ...(s.items || [])])
    : items;
  const worst = state || worstOf(allStates);
  const icon = iconOf(worst);

  const parts = [`${icon} **${title}**`];
  if (context) parts.push('', context);

  if (sections && sections.length) {
    for (const sec of sections) {
      const secItems = sec.items || [];
      const secState = sec.state || worstOf(secItems);
      const secIcon = iconOf(secState);
      const count = secItems.length;
      const countSuffix = count > 0 ? ` (${count})` : '';
      parts.push('', `### ${secIcon} ${sec.heading}${countSuffix}`);
      if (secItems.length) parts.push(secItems.map(renderItem).join('\n'));
    }
  } else if (items.length) {
    parts.push('', items.map(renderItem).join('\n'));
  }

  if (footer) parts.push(`-# ${footer}`);
  return clampMsg(parts.join('\n'));
}

// ── 3. tableFormat ────────────────────────────────────────────────────────
// monospace 정렬표. 숫자 비교·벤치마크용. 모바일 폭 한계로 3열까지만.
// code block은 가로 스크롤 없음 → 헤더 4자 이내 권장.
//
// 출력 예:
//   **포트폴리오 현재가**
//   ```
//   종목      평가액   상태
//   ────────  ───────  ────
//   TQQQ      $39.28   🔴
//   총자산    3,508만  🟢
//   ```
//   -# 2026-04-14 22:53 KST
export function tableFormat({
  title,
  headers = [],
  rows = [],
  state = 'info',
  note,
  footer,
}) {
  if (!headers.length) throw new Error('tableFormat: headers 필수');
  if (headers.length > 3) {
    throw new Error(
      `tableFormat: 모바일 폭 한계로 헤더 최대 3개 (받음: ${headers.length}). ` +
      `reportFormat 사용을 고려하세요.`
    );
  }

  const widths = headers.map((h, i) => {
    let w = displayWidth(h);
    for (const r of rows) {
      const cw = displayWidth(r?.[i]);
      if (cw > w) w = cw;
    }
    return w;
  });

  const headerLine = headers.map((h, i) => padCell(h, widths[i])).join('  ');
  const sepLine    = widths.map((w) => '─'.repeat(w)).join('  ');
  const bodyLines  = rows.map((r) => r.map((c, i) => padCell(c, widths[i])).join('  '));
  const block = '```\n' + [headerLine, sepLine, ...bodyLines].join('\n') + '\n```';

  const parts = [];
  if (title) parts.push(`${iconOf(state)} **${title}**`);
  if (note) parts.push(note);
  parts.push(block);
  if (footer) parts.push(`-# ${footer}`);

  return clampMsg(parts.join('\n'));
}

// ── 편의 ──────────────────────────────────────────────────────────────────
// Webhook POST용 payload 래퍼. { content: text } 기본.
export function toWebhookPayload(text, { username, avatarUrl } = {}) {
  const payload = { content: text };
  if (username) payload.username = username;
  if (avatarUrl) payload.avatar_url = avatarUrl;
  return payload;
}

// 한국 시간 footer 헬퍼.
export function kstFooter(extra) {
  const now = new Date();
  const kst = new Intl.DateTimeFormat('ko-KR', {
    timeZone: 'Asia/Seoul',
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: false,
  }).format(now).replace(/\.$/, '');
  return extra ? `${kst} KST · ${extra}` : `${kst} KST`;
}
