// skill-runner.js — Discord 스킬 실행 파이프
//
// 역할: 스킬 이름 수신 → 스킬 MD SSoT Read → Anthropic API 호출 → 응답 텍스트 반환.
//
// 재사용: claude-runner.js fetch 경로와 동일 API / 동일 인증.
// 한계: Discord 봇 환경은 Bash tool 직접 실행 불가 — 텍스트 응답 중심.
//       실제 시스템 점검 필요 시 주인님께 Claude Code CLI 재호출 안내.

import fs from 'node:fs/promises';
import fsSync from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const SKILL_DIR = path.join(os.homedir(), '.claude', 'commands');

// 스킬별 일일 호출 한도 (비용 캡 — 오탐으로 인한 남발 방지).
// 봇 재시작 간 persistence를 위해 파일 기반 저장소 사용.
const DAILY_LIMIT_PER_SKILL = parseInt(process.env.DISCORD_SKILL_DAILY_CAP || '50', 10);
const QUOTA_FILE = path.join(
  process.env.BOT_HOME || path.join(os.homedir(), '.jarvis'),
  'state',
  'discord-skill-quota.json',
);

function loadQuota() {
  try {
    const raw = fsSync.readFileSync(QUOTA_FILE, 'utf-8');
    return JSON.parse(raw);
  } catch { return {}; }
}
function saveQuota(data) {
  try {
    fsSync.mkdirSync(path.dirname(QUOTA_FILE), { recursive: true });
    fsSync.writeFileSync(QUOTA_FILE, JSON.stringify(data), 'utf-8');
  } catch {}
}
function getTodayKey(skill) {
  const d = new Date().toISOString().slice(0, 10);
  return `${d}:${skill}`;
}
function checkAndIncrementQuota(skill) {
  const quota = loadQuota();
  const key = getTodayKey(skill);
  const current = quota[key] ?? 0;
  if (current >= DAILY_LIMIT_PER_SKILL) {
    return { ok: false, current, limit: DAILY_LIMIT_PER_SKILL };
  }
  quota[key] = current + 1;
  // 3일 이전 키 자동 청소 (quota 파일 비대화 방지)
  const cutoff = new Date(Date.now() - 3 * 24 * 3600 * 1000).toISOString().slice(0, 10);
  for (const k of Object.keys(quota)) {
    const dk = k.split(':')[0];
    if (dk < cutoff) delete quota[k];
  }
  saveQuota(quota);
  return { ok: true, current: current + 1, limit: DAILY_LIMIT_PER_SKILL };
}

/**
 * 스킬 MD SSoT 파일 로드.
 */
export async function loadSkillPrompt(skillName) {
  const skillPath = path.join(SKILL_DIR, `${skillName}.md`);
  try {
    return await fs.readFile(skillPath, 'utf-8');
  } catch (e) {
    throw new Error(`Skill '${skillName}' not found at ${skillPath}`);
  }
}

/**
 * Discord 표면에서 스킬을 실행하고 응답 텍스트를 반환.
 *
 * @param {string} skillName — doctor·status·brief·tqqq·retro·oops·autoplan·crisis·deploy
 * @param {string} userMessage — 주인님 자연어 발화
 * @param {object} options
 * @param {string} [options.model] — 기본 claude-sonnet-4-6
 * @param {number} [options.maxTokens] — 기본 4096
 * @param {object} [options.context] — 추가 context (channelId, userId 등)
 * @returns {Promise<{text:string, skill:string, model:string, usage:object}>}
 */
export async function runSkill(skillName, userMessage, options = {}) {
  // 1) 비용 캡 체크
  const quota = checkAndIncrementQuota(skillName);
  if (!quota.ok) {
    return {
      text: `⚠️ 주인님, 스킬 \`/${skillName}\`의 오늘 호출 한도(${quota.limit}회)를 초과하였습니다. 내일 다시 시도하여 주십시오.`,
      skill: skillName,
      model: null,
      usage: null,
      quotaExceeded: true,
    };
  }

  // 2) 스킬 MD 로드
  const skillPrompt = await loadSkillPrompt(skillName);

  // 3) Discord 표면 context 주입
  const systemPrompt = `${skillPrompt}

---
# Discord 표면 호출 컨텍스트 (2026-04-24 신설)

현재 이 스킬은 **Discord 봇 환경**에서 자연어 트리거로 호출되었습니다.

## 🚨 할루시네이션 금지 (Iron Law 2 — 거짓 상태 보고 금지)

**당신은 Bash / Read / Write / Grep / 파일 시스템 접근이 불가합니다.**
따라서 다음은 **절대 생성 금지**:
- PID 번호 (예: "PID 56097")
- 프로세스 수치 (예: "크론 113개 실행 중")
- 파일 크기·디스크 사용률·메모리·CPU 수치
- 특정 파일의 존재 여부·줄 수·내용
- launchctl / 시스템 명령 실행 결과 요약
- "XX 점검 완료" / "XX 확인됨" 같은 **검증을 전제로 한 완료 선언**

위 항목이 필요한 질문이면 반드시 다음처럼 답변:
> "주인님, 해당 수치는 실측이 필요합니다. Claude Code CLI 세션에서 \`/${skillName}\`을 실행해 주시면 실제 값을 확인 가능합니다."

**지식만으로 답 가능한 범위**:
- 스킬의 목적·사용법·설계 개념
- 장애 대응 체크리스트 안내 (구체 수치 없이 원칙만)
- 주인님 발화 해석 + 다음 행동 제안
- 일반 원리·아키텍처 설명

## 환경 참조 표기 정정

일부 스킬 MD에 \`openclaw\` / \`~/.openclaw/\` 경로 참조가 있으나, 이는 레거시 오염입니다.
Jarvis 환경에서는 다음으로 해석:
- \`openclaw status\` → (Discord에선 실행 불가, CLI 세션에서 \`/doctor\` 안내)
- \`~/.openclaw/logs/\` → \`~/jarvis/runtime/logs/\`
- \`ai.openclaw.*\` → \`ai.jarvis.*\`

## Discord 응답 형식

- 2000자 이내 기본 (초과 시 요약 + "CLI에서 전체 실행" 안내)
- 🎯 첫 줄 한 줄 요약
- 📋 핵심 1~3개 bullet
- 👉 다음 액션 제안
- ⚠️ 주의/한계 명시

## 페르소나 (절대 준수)

- 존댓말 + "주인님" 호칭
- KST 시간 표기
- "~입니다", "~하겠습니다"
- 사과 대신 정정 ("정정합니다: X → Y")
`;

  const userPrompt = `주인님 발화: "${userMessage}"

위 발화에 대해 \`/${skillName}\` 스킬 지침대로 Discord 응답을 작성하십시오.`;

  // 4) Claude 호출 — API 키 있으면 fetch, 없으면 SDK query (구독제 Claude Max 지원).
  //    claude-runner.js:522-544 autoExtractMemory 패턴 재사용.
  const apiKey = process.env.ANTHROPIC_API_KEY;
  const model = options.model || (apiKey ? 'claude-sonnet-4-6' : 'claude-sonnet-4-5');
  const maxTokens = options.maxTokens || 4096;

  try {
    if (apiKey) {
      // 경로 A: Anthropic API 직접 호출 (빠름·명시적)
      const resp = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        },
        body: JSON.stringify({
          model,
          max_tokens: maxTokens,
          system: systemPrompt,
          messages: [{ role: 'user', content: userPrompt }],
        }),
      });
      if (!resp.ok) {
        const errBody = await resp.text().catch(() => '');
        return {
          text: `❌ Anthropic API 오류 (${resp.status}): ${errBody.slice(0, 200)}`,
          skill: skillName, model, usage: null, error: `api-${resp.status}`,
        };
      }
      const data = await resp.json();
      const text = data.content?.map((c) => c.text).filter(Boolean).join('\n') ?? '';
      return { text: text || '(빈 응답)', skill: skillName, model, usage: data.usage ?? null, quota };
    }

    // 경로 B: SDK query (Claude Code CLI 구독제 인증 재사용)
    const { query } = await import('@anthropic-ai/claude-agent-sdk');
    let text = '';
    const sdkOpts = {
      cwd: process.env.BOT_HOME || path.join(os.homedir(), '.jarvis'),
      allowedTools: [], // Discord 표면 — tool 없이 순수 텍스트 응답
      permissionMode: 'bypassPermissions',
      maxTurns: options.maxTurns || 10, // 2026-04-24 1→10: /doctor·/deploy exit 버그 수정
      model,
      systemPrompt,
    };
    try {
      for await (const msg of query({ prompt: userPrompt, options: sdkOpts })) {
        if ('result' in msg && msg.result) { text = msg.result; break; }
        if (msg.type === 'assistant') {
          const blk = msg.message?.content?.find?.((c) => c.type === 'text');
          if (blk?.text) text = blk.text;
        }
      }
    } catch (sdkErr) {
      return {
        text: `⚠️ SDK 호출 예외: ${sdkErr.message?.slice(0, 200) ?? sdkErr}. 주인님, Claude Code CLI에서 \`/${skillName}\`을 재시도해 주십시오.`,
        skill: skillName, model, usage: null, error: 'sdk-exception',
      };
    }
    return {
      text: text || `⚠️ 빈 응답. 주인님, Claude Code CLI 세션에서 \`/${skillName}\`을 실행해 주십시오.`,
      skill: skillName, model, usage: null, quota, via: 'sdk-query',
    };
  } catch (e) {
    return {
      text: `❌ Claude 호출 실패: ${e.message}`,
      skill: skillName, model, usage: null, error: 'exception',
    };
  }
}

// 테스트·관측용 — persistent quota 파일 기반
export function _resetQuota() {
  try { fsSync.unlinkSync(QUOTA_FILE); } catch {}
}
export function _getQuotaState() {
  return loadQuota();
}
