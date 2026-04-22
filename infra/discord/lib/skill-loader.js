// skill-loader.js — 다중 스킬 저장소 통합 로더 (SSoT 정합화)
// 통합 스코프:
//   1) ~/.jarvis/skills/*.md            — Discord 봇 전용 (override 가능) # ALLOW-DOTJARVIS
//   2) ~/.claude/commands/*/SKILL.md    — Claude Code CLI SSoT (CLI/Discord 공유)
// 같은 `name` 중복 시 SKILLS_DIRS 배열 순서 우선 (앞쪽이 이김 → Discord override).
// 2026-04-22 옵션 B 적용: CLI verify 본체를 SSoT로 사용하기 위함.
//
// 스킬 파일 형식:
//   ---
//   name: <이름>                        # 생략 시 디렉토리/파일명 사용
//   description: <요약>
//   triggers: ["키워드1", "키워드2"]   # 메시지 본문 부분일치로 활성화
//   channels: ["jarvis-inbox"]         # 해당 채널에서 자동 활성화
//   ---
//   <본문 — 시스템 프롬프트로 주입될 내용>

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

// 우선순위 순서 (앞쪽 디렉토리에서 같은 name 발견 시 이김)
// pattern:
//   'flat'   = <dir>/*.md          (파일명을 fallback name으로 사용)
//   'nested' = <dir>/*/SKILL.md    (디렉토리명을 fallback name으로 사용)
//   'mixed'  = 위 둘 모두 동시 스캔 (CLI commands 디렉토리는 *.md + */SKILL.md 혼재)
const SKILLS_DIRS = [
  { path: join(homedir(), '.jarvis', 'skills'), pattern: 'flat' },
  { path: join(homedir(), '.claude', 'commands'), pattern: 'mixed' },
];

function parseFrontmatter(content) {
  const match = content.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!match) return { frontmatter: {}, body: content };
  const fmText = match[1];
  const body = match[2];
  const fm = {};
  let currentKey = null;
  let pipeMode = false;       // YAML `|` (literal block) 누적 중
  let pipeIndent = 0;          // pipe 시작 시 기준 들여쓰기
  let pipeBuffer = [];

  const flushPipe = () => {
    if (pipeMode && currentKey) {
      fm[currentKey] = pipeBuffer.join('\n').trim();
    }
    pipeMode = false;
    pipeBuffer = [];
  };

  const lines = fmText.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (pipeMode) {
      // pipe 누적: 빈 줄 또는 들여쓰기 유지된 줄 → 본문으로
      if (line.trim() === '' || /^\s/.test(line)) {
        // pipeIndent 만큼 제거 후 누적
        const stripped = line.length >= pipeIndent ? line.slice(pipeIndent) : line.trimStart();
        pipeBuffer.push(stripped);
        continue;
      }
      // 들여쓰기 빠지면 pipe 종료
      flushPipe();
    }
    const keyPipe = line.match(/^(\w+):\s*\|\s*$/); // YAML pipe 시작
    const keyOnly = line.match(/^(\w+):\s*$/); // 빈 값 (아래에 리스트 올 때)
    const keyVal = line.match(/^(\w+):\s+(.+)$/); // 값 있음
    const listItem = line.match(/^\s+-\s+(.+)$/); // 리스트 항목
    if (keyPipe) {
      currentKey = keyPipe[1];
      // 다음 non-empty 줄의 들여쓰기를 기준으로 잡기 위해 lookahead
      pipeIndent = 2; // 기본
      for (let j = i + 1; j < lines.length; j++) {
        if (lines[j].trim() === '') continue;
        const m = lines[j].match(/^(\s+)/);
        if (m) pipeIndent = m[1].length;
        break;
      }
      pipeMode = true;
      pipeBuffer = [];
    } else if (keyOnly) {
      currentKey = keyOnly[1];
      fm[currentKey] = [];
    } else if (keyVal) {
      currentKey = keyVal[1];
      fm[currentKey] = keyVal[2].replace(/^["']|["']$/g, '');
    } else if (listItem && currentKey) {
      const value = listItem[1].replace(/^["']|["']$/g, '');
      if (!Array.isArray(fm[currentKey])) fm[currentKey] = [];
      fm[currentKey].push(value);
    }
  }
  flushPipe(); // 끝까지 pipe였으면 마무리

  return { frontmatter: fm, body: body.trim() };
}

// frontmatter 없는 마크다운에서 H1 + 첫 단락을 description fallback으로 추출
// 예: "# cycling-log\n\n자전거 라이딩을 카카오 캘린더에 기록합니다.\n주황색 ..."
//   → name="cycling-log", description="자전거 라이딩을 카카오 캘린더에 기록합니다. 주황색 ..."
function _extractFromMarkdown(rawText) {
  const lines = rawText.split('\n');
  let h1 = null;
  let descLines = [];
  let foundH1 = false;
  for (const line of lines) {
    if (!foundH1) {
      const m = line.match(/^#\s+\/?(.+?)\s*$/); // "/cmd" 의 슬래시도 제거
      if (m) {
        h1 = m[1].trim();
        foundH1 = true;
      }
      continue;
    }
    if (line.trim() === '') {
      if (descLines.length > 0) break; // 첫 단락 끝
      continue;
    }
    if (line.startsWith('#')) break;   // 다음 헤더 만나면 종료
    if (line.startsWith('```')) break; // 코드 블록 만나면 종료
    descLines.push(line.trim());
    if (descLines.join(' ').length > 300) break; // 너무 길면 끊기
  }
  return {
    name: h1,
    description: descLines.join(' ').trim(),
  };
}

// description/본문 안의 인용부호 키워드 추출 (작은따옴표 + 큰따옴표)
// 예: "...'회고', 'retro', '회고록' 요청 시 사용." → ['회고', 'retro', '회고록']
// 예: '"자비스맵 전수조사", "UI 감사" 등으로 트리거' → ['자비스맵 전수조사', 'UI 감사']
// 길이 2~30자, 한글/영문/숫자/공백/하이픈/슬래시/물음표 등 일반 문자만 허용
function _extractTriggersFromDescription(description) {
  if (!description || typeof description !== 'string') return [];
  const out = [];
  const seen = new Set();

  const pushIfValid = (raw) => {
    const kw = raw.trim();
    if (kw.length < 2 || kw.length > 30) return;
    if (!/[가-힣A-Za-z0-9]/.test(kw)) return;       // 100% 특수문자 차단
    if (/\n|\r/.test(kw)) return;                    // 줄바꿈 포함 차단
    const key = kw.toLowerCase();
    if (seen.has(key)) return;
    seen.add(key);
    out.push(kw);
  };

  // 작은따옴표
  for (const m of description.match(/'([^'\n]{2,30})'/g) || []) {
    pushIfValid(m.slice(1, -1));
  }
  // 큰따옴표
  for (const m of description.match(/"([^"\n]{2,30})"/g) || []) {
    pushIfValid(m.slice(1, -1));
  }
  // bullet 슬래시 패턴: "- 자전거 탔다 / 자전거 기록해줘 / 사이클 기록 → ..."
  // 줄 단위로 보고, "-"로 시작하고 "/"로 분리되는 좌측을 추출 (→ 또는 줄끝까지)
  for (const line of description.split('\n')) {
    const m = line.match(/^\s*[-*]\s+([^\n→]+?)(?:\s*→.*)?$/);
    if (!m) continue;
    const segment = m[1];
    if (!segment.includes('/')) continue;        // 슬래시 구분만 trigger 후보
    if (segment.length < 6 || segment.length > 200) continue;
    for (const part of segment.split('/')) {
      pushIfValid(part.trim());
    }
  }
  return out;
}

function _buildSkillEntry(rawText, sourcePath, fallbackName) {
  const { frontmatter, body } = parseFrontmatter(rawText);

  // frontmatter 없으면 마크다운 H1 + 첫 단락에서 fallback 추출
  const hasFrontmatter = Object.keys(frontmatter).length > 0;
  const mdFallback = hasFrontmatter ? null : _extractFromMarkdown(rawText);

  const name = frontmatter.name || (mdFallback && mdFallback.name) || fallbackName;
  if (!name) return null;
  const description = frontmatter.description || (mdFallback && mdFallback.description) || '';

  // Layer 1: frontmatter triggers 명시 (있으면 최우선)
  // Layer 2: description 안 인용부호/bullet 키워드 자동 추출
  // Layer 3: description 추출이 빈약(<3개)하면 body(첫 2000자)도 합쳐서 추출
  const explicitTriggers = Array.isArray(frontmatter.triggers) ? frontmatter.triggers : [];
  let derivedTriggers = [];
  let triggersSource = 'none';
  if (explicitTriggers.length > 0) {
    triggersSource = 'explicit';
  } else {
    const descTriggers = _extractTriggersFromDescription(description);
    let bodyTriggers = [];
    if (descTriggers.length < 3) {
      bodyTriggers = _extractTriggersFromDescription((body || '').slice(0, 2000));
    }
    // 중복 제거 합집합
    const seen = new Set();
    for (const kw of [...descTriggers, ...bodyTriggers]) {
      const key = kw.toLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      derivedTriggers.push(kw);
    }
    if (derivedTriggers.length > 0) {
      triggersSource = descTriggers.length > 0 && bodyTriggers.length > 0 ? 'derived-merged'
                     : descTriggers.length > 0 ? 'derived-description'
                     : 'derived-body';
    }
  }
  return {
    name,
    description,
    triggers: explicitTriggers.length > 0 ? explicitTriggers : derivedTriggers,
    triggersSource,
    channels: Array.isArray(frontmatter.channels) ? frontmatter.channels : [],
    body,
    source: sourcePath,
  };
}

function _loadFromFlat(dir) {
  if (!existsSync(dir)) return [];
  const out = [];
  for (const f of readdirSync(dir)) {
    if (!f.endsWith('.md')) continue;
    const full = join(dir, f);
    try {
      const raw = readFileSync(full, 'utf-8');
      const entry = _buildSkillEntry(raw, full, f.replace(/\.md$/, ''));
      if (entry) out.push(entry);
    } catch {
      // skip invalid
    }
  }
  return out;
}

function _loadFromNested(dir) {
  if (!existsSync(dir)) return [];
  const out = [];
  for (const sub of readdirSync(dir)) {
    const subPath = join(dir, sub);
    let isDir = false;
    try {
      isDir = statSync(subPath).isDirectory();
    } catch {
      continue;
    }
    if (!isDir) continue;
    const skillFile = join(subPath, 'SKILL.md');
    if (!existsSync(skillFile)) continue;
    try {
      const raw = readFileSync(skillFile, 'utf-8');
      const entry = _buildSkillEntry(raw, skillFile, sub);
      if (entry) out.push(entry);
    } catch {
      // skip invalid
    }
  }
  return out;
}

let _skillsCache = null;

function _loadByPattern(path, pattern) {
  if (pattern === 'nested') return _loadFromNested(path);
  if (pattern === 'mixed') return [..._loadFromFlat(path), ..._loadFromNested(path)];
  return _loadFromFlat(path); // 'flat' (기본)
}

export function loadSkills() {
  if (_skillsCache) return _skillsCache;
  const seen = new Set();
  const skills = [];
  for (const { path, pattern } of SKILLS_DIRS) {
    const loaded = _loadByPattern(path, pattern);
    for (const s of loaded) {
      if (seen.has(s.name)) continue; // 우선순위로 인해 이미 등록됨
      seen.add(s.name);
      skills.push(s);
    }
  }
  _skillsCache = skills;
  return skills;
}

// Match skill by channel name and/or message content.
// Channel match activates skill without requiring keyword.
// Trigger keyword match activates skill anywhere.
export function matchSkills({ channelName, messageText }) {
  const skills = loadSkills();
  const matched = [];
  const text = (messageText || '').toLowerCase();
  for (const s of skills) {
    const byChannel = channelName && s.channels.includes(channelName);
    const byTrigger = s.triggers.some((t) => {
      const tl = t.toLowerCase();
      // 정상 방향: 메시지가 트리거를 포함
      if (text.includes(tl)) return true;
      // 역방향(안전 조건): 트리거가 메시지를 포함 — 짧은 단일 키워드 입력 시
      //   text 길이 ≥ 3자(false positive 차단), trigger가 사실상 그 키워드의 확장형일 때
      if (text.length >= 3 && text.length <= 12 && tl.includes(text)) return true;
      return false;
    });
    if (byChannel || byTrigger) {
      matched.push({ skill: s, byChannel, byTrigger });
    }
  }
  return matched;
}

// Slash command interceptor — `/skill-name args...` 형태 메시지를 스킬 호출로 해석
// CLI의 `/mock-interview 삼성물산` 과 동일한 경험을 디스코드에 제공.
// 매칭 성공 시 { skill, args } 반환, 실패 시 null.
export function matchSkillByCommand(messageText) {
  const text = (messageText || '').trim();
  const m = text.match(/^\/([a-zA-Z0-9_-]+)(?:\s+([\s\S]*))?$/);
  if (!m) return null;
  const [, name, args] = m;
  const skills = loadSkills();
  const skill = skills.find((s) => s.name === name);
  if (!skill) return null;
  return { skill, args: (args || '').trim() };
}

// For unit testing / manual refresh
export function _clearSkillsCache() {
  _skillsCache = null;
}
