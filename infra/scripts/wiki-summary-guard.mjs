/**
 * wiki-summary-guard.mjs — LLM 이 낸 _summary.md 후보를 저장 전에 거른다.
 *
 * 왜(2026-10-06 당직): "50자 이상"만 보던 탓에 "경로를 알려주시면 저장하겠습니다" 같은
 * 권한 요청·작업 보고문이 career·trading 요약을 덮었고, 그 쓰레기가 다음 날 "기존 요약(참고용)"으로
 * 다시 프롬프트에 들어가 같은 형태를 되풀이했다.
 *
 * 규칙: YAML 머리말(--- … type: summary … ---)이 있어야 하고, 머리말 앞 서문은 잘라 낸다.
 * 본문에 권한 요청·되묻기 문장이 있으면 통째로 버린다(null) — 옛 요약을 그대로 두는 편이 낫다.
 */

const FRONTMATTER = /---[ \t]*\n([\s\S]*?)\n---[ \t]*(?:\n|$)/y;
const RULE_LINE = /^---[ \t]*$/gm;
const META_TALK = [
  /알려\s*주시면/,
  /지시해\s*주시면/,
  /지정(?:해\s*주시면|하면)/,
  /저장하겠습니다/,
  /저장할\s*(?:디렉토리|위치|경로)/,
  /경로를\s*(?:먼저\s*)?찾아/,
  /권한(?:을|이)\s*(?:허용|승인|필요)/,
  /^```(?:bash|sh|zsh)\b/m,
  // 10-07 03:30: 머리말은 멀쩡한데 끝에 작업 메모("**진행:** 요약 갱신 완료 ✅")와
  // 도구 상태 추측("디렉토리가 현재 없는 상태")이 섞여 career 요약을 덮었다.
  /^\s*(?:\*\*)?진행:(?:\*\*)?/m,
  /요약\s*(?:갱신|작성|업데이트)\s*(?:을\s*)?완료/,
  /(?:디렉토리|폴더|경로)가\s*(?:현재\s*)?(?:없|삭제)/,
];

export function cleanSummary(raw) {
  if (typeof raw !== 'string') return null;
  let s = raw.replace(/^```(?:markdown|md|yaml)?\s*\n/gm, '').replace(/\n```\s*$/gm, '');
  // 서문 뒤 빈 구분선(---\n\n---)이 진짜 머리말의 여는 줄을 먹으므로, '---' 줄마다 머리말 시작인지 따로 본다.
  let m = null;
  for (const r of s.matchAll(RULE_LINE)) {
    FRONTMATTER.lastIndex = r.index;
    const x = FRONTMATTER.exec(s);
    if (x && /^type:\s*["']?summary["']?\s*$/m.test(x[1])) { m = x; break; }
  }
  if (!m) return null;
  s = s.slice(m.index);
  if (META_TALK.some(re => re.test(s))) return null;
  const body = s.slice(m[0].length).trim();
  if (body.length < 50) return null;
  return s.trimEnd() + '\n';
}
