#!/usr/bin/env node
/**
 * ajqe-dispatch.mjs — Active Jarvis Question Engine: 발송기
 *
 * 역할: question-queue.jsonl에서 우선순위 + 쿨다운 통과한 질문 N개를
 *       Discord webhook으로 발송하고 sent.jsonl에 기록한다.
 *
 * 정책 (ajqe-policy.json):
 *   - dailyLimit: 하루 발송 한도 (기본 2)
 *   - perDomainCooldownDays: 동일 도메인 재발송 쿨다운 (기본 3)
 *   - domainPriority: 우선순위 순서
 *   - domainChannel: 도메인 → Discord 채널 매핑
 *   - quietHours: 발송 금지 시간대 (KST 기준, "HH-HH" 또는 빈 문자열)
 *
 * 사용:
 *   node ajqe-dispatch.mjs              # 정책에 따라 발송
 *   node ajqe-dispatch.mjs --dry-run    # 발송 안 하고 선택만 출력
 *   node ajqe-dispatch.mjs --force      # 일일 한도/쿨다운 무시 (수동 테스트용)
 */
import { readFileSync, existsSync, appendFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { spawnSync } from 'node:child_process';

const HOME = homedir();
const QUEUE_PATH = join(HOME, 'jarvis/runtime/state/ajqe-question-queue.jsonl');
const SENT_PATH = join(HOME, 'jarvis/runtime/state/ajqe-sent.jsonl');
const POLICY_PATH = join(HOME, 'jarvis/runtime/config/ajqe-policy.json');
const MONITORING_PATH = join(HOME, 'jarvis/runtime/config/monitoring.json');

const DRY_RUN = process.argv.includes('--dry-run');
const FORCE = process.argv.includes('--force');

const DEFAULT_POLICY = {
  dailyLimit: 2,
  perDomainCooldownDays: 3,
  domainPriority: ['owner', 'career', 'knowledge'],
  domainChannel: {
    owner: 'jarvis',
    career: process.env.CAREER_DOMAIN_CHANNEL || 'jarvis-career',
    knowledge: 'jarvis',
    meta: 'jarvis-system',
  },
  quietHours: '23-07', // 23시~07시 KST 발송 금지
  prefixEmoji: '🤔',
  llmRefiner: {
    enabled: true,
    model: 'claude-sonnet-4-6',  // 주인님 지정 (2026-05-07): 친절한 자연어 정제는 sonnet
    contextRadius: 5,             // SSoT 라인 ±N줄 컨텍스트
    timeoutMs: 90000,             // sonnet은 haiku보다 느림 → 90초로 여유
    fallbackToTemplate: true,
  },
};

const EMPTY_MCP = join(HOME, 'jarvis/runtime/config/empty-mcp.json');
// claude CLI 절대 경로 — PATH 의존 제거 + 최신 버전 보장.
// Homebrew claude(/opt/homebrew/bin/claude)는 구버전 (2.1.37)이라 신규 옵션 미지원.
// ~/.local/bin/claude (2.1.131+) 사용. 부재 시 PATH의 claude로 fallback.
const CLAUDE_BIN = existsSync(join(HOME, '.local/bin/claude'))
  ? join(HOME, '.local/bin/claude')
  : 'claude';

const SYSTEM_PROMPT = `당신은 JARVIS — 토니 스타크의 한국어 AI 집사. 주인님께 질문을 만든다.

🔴 절대 금지 (2026-05-07 주인님 정정):
- **시스템 메타 질문 금지**: "health.json에 어떤 필드 추가할까요?", "스키마 어떻게 설계할까요?", "이 항목에 무슨 값 넣을까요?" 같은 자비스 내부 구조·운영 질문. 베스트 프랙티스로 자비스가 알아서 처리할 영역.
- **추상적 메타 질문 금지**: "이 파일의 목적이 뭡니까?", "어디에 가까운지 명시해 주십시오" 같은 자비스 자신이 컨텍스트로 판단할 영역.

✅ 주인님께 물어볼 가치 있는 3 카테고리만:
1. **일상 질문** — "오늘 점심 뭐 드셨어요?", "면접 어떠셨어요?"
2. **일정 후속** — "내일 미팅 자료 준비할까요?", "면접 끝났는데 회고 필요하세요?"
3. **장애 + 조치 옵션** — "X가 멈췄습니다. 재시작 / 끄기 / 조사 중?"

질문 작성 원칙:
1. 첫 줄에 **무엇이 일어났는지 / 무엇이 궁금한지** 한 문장. 일상 언어.
2. 본 질문은 구체적·짧게. 옵션 제시할 때는 한 단어 답변 가능하게 (재시작/조사/무시 등).
3. 자비스 기술 용어(SSoT, schema, indexer 등) 그대로 쓰지 말고 풀어서 (자비스 뇌 / 기록장 / 검색 도구).

말투:
- "주인님" 호칭, "~입니다/~드립니다" 존댓말
- 친절·정중·간결
- 출력은 질문 본문만. 인사·메타 설명 금지
- 600자 이하`;

function readContext(ssotPath, lineNumber, radius) {
  if (!existsSync(ssotPath)) return { text: '(파일 없음)', range: '' };
  const lines = readFileSync(ssotPath, 'utf-8').split('\n');
  const start = Math.max(0, lineNumber - 1 - radius);
  const end = Math.min(lines.length, lineNumber - 1 + radius + 1);
  const slice = lines.slice(start, end);
  return {
    text: slice.map((l, i) => `L${start + i + 1}${(start + i + 1 === lineNumber) ? ' ◀' : '  '} ${l}`).join('\n'),
    range: `L${start + 1}-L${end}`,
  };
}

// claude CLI subprocess로 호출 — 주인님 구독제 인증 사용 (ANTHROPIC_API_KEY 미사용).
// 자비스 다른 스크립트(context-extractor.mjs 등)와 동일 패턴:
//   ANTHROPIC_API_KEY='', CLAUDECODE='' 비워서 키체인/구독제 인증 우선.
//   --strict-mcp-config + empty-mcp.json으로 MCP 비활성화 (가벼운 호출).
//   --exclude-dynamic-system-prompt-sections로 cwd/git 등 제거 (캐시 효율 ↑).
function refineWithLLM(q, refinerCfg) {
  if (!existsSync(EMPTY_MCP)) {
    throw new Error(`empty-mcp.json 없음: ${EMPTY_MCP}`);
  }
  const ctx = readContext(q.ssotPath, q.lineNumber, refinerCfg.contextRadius || 5);
  const userPrompt = `다음 SSoT 약한 표현을 채울 질문을 만들어 주십시오.

SSoT 파일: ${q.ssotPath.replace(HOME, '~')}
SSoT 목적: ${q.purpose || '(미명시)'}
약한 표현 라인 (L${q.lineNumber}, 패턴 '${q.weakPattern}'): "${q.excerpt}"

컨텍스트 (${ctx.range}):
\`\`\`
${ctx.text}
\`\`\`

위 컨텍스트를 보고 어떤 정보가 비어 있는지 파악한 뒤, 주인님이 1~2분 안에 답변할 수 있는 구체적 질문 1개를 만들어 주십시오.`;

  const args = [
    '-p',
    '--model', refinerCfg.model || 'claude-haiku-4-5-20251001',
    '--system-prompt', SYSTEM_PROMPT,
    '--permission-mode', 'bypassPermissions',
    '--strict-mcp-config', '--mcp-config', EMPTY_MCP,
    userPrompt,
  ];

  const result = spawnSync(CLAUDE_BIN, args, {
    env: { ...process.env, ANTHROPIC_API_KEY: '', CLAUDECODE: '' },
    timeout: refinerCfg.timeoutMs || 60_000,
    maxBuffer: 4 * 1024 * 1024,
    encoding: 'utf-8',
  });

  if (result.error) throw new Error(`claude spawn 실패: ${result.error.message}`);
  if (result.status !== 0) {
    throw new Error(`claude exit ${result.status}: ${(result.stderr || '').slice(0, 200)}`);
  }
  const text = (result.stdout || '').trim();
  if (!text) throw new Error('claude 빈 응답');
  return text;
}

function loadJSON(path, fallback) {
  if (!existsSync(path)) return fallback;
  try { return JSON.parse(readFileSync(path, 'utf-8')); }
  catch { return fallback; }
}

function loadJSONL(path) {
  if (!existsSync(path)) return [];
  return readFileSync(path, 'utf-8')
    .split('\n')
    .filter(l => l.trim())
    .map(l => { try { return JSON.parse(l); } catch { return null; } })
    .filter(Boolean);
}

// KST = UTC + 9. Date.now()는 항상 UTC ms epoch이라 +9시간 더하면 KST.
// getTimezoneOffset 사용 금지 — process timezone에 따라 이중 적용 버그 발생.
function nowKSTDate() {
  return new Date(Date.now() + 9 * 60 * 60 * 1000);
}

function isQuietHour(quietHours) {
  if (!quietHours) return false;
  const [start, end] = quietHours.split('-').map(Number);
  if (Number.isNaN(start) || Number.isNaN(end)) return false;
  const h = nowKSTDate().getUTCHours(); // +9 적용된 시각의 UTC hour = KST hour
  if (start < end) return h >= start && h < end;
  return h >= start || h < end; // 23-07 같은 wrap
}

function todaySentCount(sentRecords) {
  const todayStr = nowKSTDate().toISOString().slice(0, 10); // YYYY-MM-DD KST
  return sentRecords.filter(r => (r.sentAt || '').slice(0, 10) === todayStr).length;
}

function lastSentByDomain(sentRecords) {
  const map = {};
  for (const r of sentRecords) {
    if (!r.domain || !r.sentAt) continue;
    if (!map[r.domain] || r.sentAt > map[r.domain]) map[r.domain] = r.sentAt;
  }
  return map;
}

function daysSince(iso) {
  if (!iso) return Infinity;
  const diff = Date.now() - new Date(iso).getTime();
  return diff / (24 * 60 * 60 * 1000);
}

function loadWebhook(channel) {
  if (!existsSync(MONITORING_PATH)) return null;
  const cfg = loadJSON(MONITORING_PATH, {});
  return cfg.webhooks?.[channel] || null;
}

async function postDiscord(webhookUrl, content) {
  const body = JSON.stringify({ content: content.slice(0, 1990) });
  const res = await fetch(webhookUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body,
  });
  if (!res.ok) {
    const t = await res.text();
    throw new Error(`Discord ${res.status}: ${t.slice(0, 200)}`);
  }
}

function selectQuestions(queue, sent, policy) {
  const sentIds = new Set(sent.map(s => s.id));
  const lastByDomain = lastSentByDomain(sent);
  const cooldownDays = policy.perDomainCooldownDays ?? 3;
  const priority = policy.domainPriority || [];

  const available = queue
    .filter(q => q.status === 'pending')
    .filter(q => !sentIds.has(q.id))
    .filter(q => {
      if (FORCE) return true;
      const last = lastByDomain[q.domain];
      return daysSince(last) >= cooldownDays;
    })
    .sort((a, b) => {
      const pa = priority.indexOf(a.domain);
      const pb = priority.indexOf(b.domain);
      const pra = pa === -1 ? 99 : pa;
      const prb = pb === -1 ? 99 : pb;
      if (pra !== prb) return pra - prb;
      return (a.createdAt || '').localeCompare(b.createdAt || '');
    });

  // 도메인 분산: 같은 도메인이 연속으로 N개 안 나오게 한 번씩 라운드로빈
  const byDomain = {};
  for (const q of available) {
    (byDomain[q.domain] = byDomain[q.domain] || []).push(q);
  }
  // priority 도메인 먼저, 그 다음 priority에 없는 도메인 (등장 순)
  const priorityDomains = priority.filter(d => byDomain[d]?.length > 0);
  const extraDomains = Object.keys(byDomain).filter(d => !priority.includes(d));
  const domainOrder = [...priorityDomains, ...extraDomains];
  const result = [];
  while (domainOrder.some(d => byDomain[d]?.length > 0)) {
    for (const d of domainOrder) {
      if (byDomain[d]?.length > 0) result.push(byDomain[d].shift());
    }
  }
  return result;
}

function rewriteQueue(queue, sentNow) {
  const sentIds = new Set(sentNow.map(s => s.id));
  const remaining = queue.filter(q => !sentIds.has(q.id));
  const lines = remaining.map(q => JSON.stringify(q)).join('\n');
  writeFileSync(QUEUE_PATH, lines + (lines ? '\n' : ''));
}

async function main() {
  const policy = { ...DEFAULT_POLICY, ...loadJSON(POLICY_PATH, {}) };
  policy.domainChannel = { ...DEFAULT_POLICY.domainChannel, ...(policy.domainChannel || {}) };

  const queue = loadJSONL(QUEUE_PATH);
  const sent = loadJSONL(SENT_PATH);

  console.log(`# AJQE Dispatch (${new Date().toISOString()})`);
  console.log(`큐: ${queue.length}건 / 발송 이력: ${sent.length}건`);
  console.log(`정책: dailyLimit=${policy.dailyLimit}, cooldown=${policy.perDomainCooldownDays}일, quiet=${policy.quietHours || '없음'}`);

  if (!FORCE && isQuietHour(policy.quietHours)) {
    const h = nowKST().getUTCHours();
    console.log(`🌙 조용한 시간 (KST ${h}시) — 발송 건너뜀`);
    return;
  }

  const sentToday = FORCE ? 0 : todaySentCount(sent);
  const remainingBudget = Math.max(0, (policy.dailyLimit ?? 2) - sentToday);
  console.log(`오늘 발송: ${sentToday}건 / 남은 예산: ${remainingBudget}건`);

  if (remainingBudget === 0) {
    console.log(`✅ 일일 한도 도달 — 발송 건너뜀`);
    return;
  }

  const selected = selectQuestions(queue, sent, policy).slice(0, remainingBudget);
  console.log(`선택: ${selected.length}건`);

  if (selected.length === 0) {
    console.log(`✅ 발송 대상 없음 (큐 비었거나 모두 쿨다운 중)`);
    return;
  }

  for (const q of selected) {
    const channel = policy.domainChannel[q.domain] || 'jarvis';
    const webhook = loadWebhook(channel);
    if (!webhook) {
      console.error(`❌ webhook 없음: channel=${channel} (q=${q.id}) — 건너뜀`);
      continue;
    }

    // LLM 정제 (실패 시 템플릿 fallback)
    // skipLlmRefine=true: trigger가 이미 명확한 액션 메시지를 작성한 경우 LLM 우회 (메타 변형 방지).
    let questionBody = q.questionText;
    let refinedBy = 'template';
    if (q.skipLlmRefine) {
      refinedBy = 'trigger-direct';
    } else if (policy.llmRefiner?.enabled) {
      try {
        questionBody = refineWithLLM(q, policy.llmRefiner);
        refinedBy = `llm:${policy.llmRefiner.model}`;
      } catch (e) {
        console.error(`⚠️ LLM 정제 실패 (${q.id}): ${e.message}`);
        if (!policy.llmRefiner.fallbackToTemplate) {
          console.error(`   fallbackToTemplate=false → 발송 건너뜀`);
          continue;
        }
        console.error(`   템플릿으로 fallback`);
      }
    }

    const content = `${policy.prefixEmoji} **자비스 질문** _(${q.domain}/${q.ssot} · ${refinedBy})_\n\n${questionBody}\n\n_답변은 \`/remember\` 또는 이 채널에 자유롭게 적어주십시오._\n_id: \`${q.id}\`_`;
    console.log(`  → [${channel}] ${q.id} (${refinedBy})`);
    if (DRY_RUN) {
      console.log(`    (dry-run, 내용 미리보기 ↓)`);
      console.log(content.split('\n').map(l => `    | ${l}`).join('\n'));
      continue;
    }
    try {
      await postDiscord(webhook, content);
      const record = {
        id: q.id,
        domain: q.domain,
        ssot: q.ssot,
        channel,
        refinedBy,
        sentAt: new Date().toISOString(),
      };
      mkdirSync(dirname(SENT_PATH), { recursive: true });
      appendFileSync(SENT_PATH, JSON.stringify(record) + '\n');
    } catch (e) {
      console.error(`❌ 발송 실패: ${q.id} — ${e.message}`);
    }
  }

  if (!DRY_RUN) {
    // 큐에서 발송된 항목 제거 (sent.jsonl에는 영구 보관)
    const sentNowIds = new Set(loadJSONL(SENT_PATH).slice(-selected.length).map(s => s.id));
    const sentNow = selected.filter(s => sentNowIds.has(s.id));
    if (sentNow.length > 0) {
      rewriteQueue(queue, sentNow);
      console.log(`✅ 큐에서 ${sentNow.length}건 제거 (sent.jsonl에 보관)`);
    }
  }
}

main().catch(e => { console.error(e); process.exit(1); });
