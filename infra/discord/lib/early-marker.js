/**
 * early-marker.js — CHART_DATA / TABLE_DATA 마커를 스트리밍 중 조기 추출·전송.
 *
 * 기본: 비활성 (CHART_DATA_EARLY_SEND=1 로 opt-in).
 *
 * 원리:
 *   - StreamingMessage buffer에 `^MARKER_DATA:{...}` 단일 라인이 완성되면
 *     finalize 전에 이미지 렌더 + 채널 전송 착수.
 *   - 조기 전송된 마커는 streamer._markerEarlySent.add('chart') 등록 →
 *     finalize의 _extractAndSendMarkers는 해당 타입을 스킵.
 *
 * 마커 형식 가정:
 *   CHART_DATA:{"type":"...", ...}
 *   TABLE_DATA:{"title":"...", ...}
 *   마커는 줄 시작 + JSON 단일 라인 (본 모듈 범위 밖의 마커는 건드리지 않음).
 */

const MARKER_LINE_RE = /^([A-Z_]+_DATA):(\{[^\n]+\})\s*$/m;

/**
 * buffer에서 조기 전송 가능한 첫 번째 마커를 추출.
 * @param {string} buffer
 * @param {Set<string>} alreadySent 이미 조기 전송된 마커 이름 (예: 'CHART_DATA')
 * @returns {null | { name: string, json: object, raw: string }}
 */
export function peekCompleteMarker(buffer, alreadySent = new Set()) {
  if (!buffer || buffer.length < 30) return null;
  const m = buffer.match(MARKER_LINE_RE);
  if (!m) return null;
  const [raw, name, jsonRaw] = m;
  if (alreadySent.has(name)) return null;
  // 허용 마커만 (EMBED_DATA / CV2_DATA는 매우 짧아서 굳이 조기 렌더할 이득 낮음)
  if (name !== 'CHART_DATA' && name !== 'TABLE_DATA') return null;
  try {
    const json = JSON.parse(jsonRaw);
    return { name, json, raw };
  } catch {
    return null; // JSON 불완전 (아직 스트리밍 중일 가능성)
  }
}

/**
 * 활성화 여부 — env flag 또는 명시적 opts.
 */
export function isEarlySendEnabled() {
  return process.env.CHART_DATA_EARLY_SEND === '1';
}
