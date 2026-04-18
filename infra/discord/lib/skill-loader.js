// skill-loader.js — 공통 스킬 저장소 (~/.jarvis/skills/) 로더
// SSoT: ~/.jarvis/skills/<name>.md
// CLI, Discord, Mac 앱이 동일한 스킬 정의를 공유하기 위한 경계 모듈.
//
// 스킬 파일 형식:
//   ---
//   name: <이름>
//   description: <요약>
//   triggers: ["키워드1", "키워드2"]   # 메시지 본문 부분일치로 활성화
//   channels: ["jarvis-career"]        # 해당 채널에서 자동 활성화
//   ---
//   <본문 — 시스템 프롬프트로 주입될 내용>

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const SKILLS_DIR = join(homedir(), '.jarvis', 'skills');

function parseFrontmatter(content) {
  const match = content.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!match) return { frontmatter: {}, body: content };
  const fmText = match[1];
  const body = match[2];
  const fm = {};
  let currentKey = null;
  for (const line of fmText.split('\n')) {
    const keyOnly = line.match(/^(\w+):\s*$/); // 빈 값 (아래에 리스트 올 때)
    const keyVal = line.match(/^(\w+):\s+(.+)$/); // 값 있음
    const listItem = line.match(/^\s+-\s+(.+)$/); // 리스트 항목
    if (keyOnly) {
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
  return { frontmatter: fm, body: body.trim() };
}

let _skillsCache = null;

export function loadSkills() {
  if (_skillsCache) return _skillsCache;
  if (!existsSync(SKILLS_DIR)) {
    _skillsCache = [];
    return _skillsCache;
  }
  const files = readdirSync(SKILLS_DIR).filter((f) => f.endsWith('.md'));
  const skills = [];
  for (const f of files) {
    try {
      const raw = readFileSync(join(SKILLS_DIR, f), 'utf-8');
      const { frontmatter, body } = parseFrontmatter(raw);
      if (!frontmatter.name) continue;
      skills.push({
        name: frontmatter.name,
        description: frontmatter.description || '',
        triggers: Array.isArray(frontmatter.triggers) ? frontmatter.triggers : [],
        channels: Array.isArray(frontmatter.channels) ? frontmatter.channels : [],
        body,
      });
    } catch {
      // skip invalid skill files
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
    const byTrigger = s.triggers.some((t) => text.includes(t.toLowerCase()));
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
