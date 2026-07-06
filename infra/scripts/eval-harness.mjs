#!/usr/bin/env node
/**
 * eval-harness.mjs — Jarvis 봇 응답 품질 평가 하네스 (Phase A: 골든셋 + LLM 채점)
 *
 * 왜: 페르소나·프롬프트를 고칠 때마다 "좋아졌나?"를 감으로 판단하던 것을
 *     고정 골든셋 + LLM-as-judge 채점으로 수치화한다. (yozm 3833 / google agents-cli 평가 루프 이식)
 *
 * 흐름: 골든셋 질문 → [응답 생성: 봇 시스템 프롬프트 스냅샷 + 봇과 동일 모델]
 *       → [채점: 루브릭 기반 LLM judge, JSON] → results-*.jsonl 적재 + 요약 출력
 *
 * 사용:
 *   node eval-harness.mjs                 # 전체 실행
 *   node eval-harness.mjs --limit 2       # 앞 2문항만 (스모크)
 *   node eval-harness.mjs --only dev-01   # 특정 문항만
 *
 * OAuth 격리 (2026-06-11 사고 재발 방지): 배치 claude 호출은 격리 장수명 토큰 사용 — llm-gateway.sh 패턴.
 */
import { readFileSync, existsSync, appendFileSync, mkdirSync } from 'node:fs';
import { execFile } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const HOME = homedir();
const EVAL_DIR = join(HOME, 'jarvis/runtime/eval');
const GOLDEN = join(EVAL_DIR, 'golden-set.jsonl');
const SNAPSHOT = join(HOME, 'jarvis/runtime/state/system-prompt-snapshot.md');
const MODELS_JSON = join(HOME, 'jarvis/infra/config/models.json');
const CLAUDE_BIN = process.env.CLAUDE_BINARY || join(HOME, '.local/bin/claude');
const TOKEN_FILE = join(HOME, '.claude-bot/.long-lived-token');

// ── 인자 파싱 ──
const argv = process.argv.slice(2);
const getArg = (k) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : null; };
const LIMIT = Number(getArg('--limit')) || Infinity;
const ONLY = getArg('--only');
const IDS = getArg('--ids')?.split(',').map((s) => s.trim()); // 복수 문항 선택
const PERSONA_FILE = getArg('--persona-file'); // 스냅샷 대신 페르소나 파일 직접 사용 (A/B 비교용 — 채널 변수 제거)
const TAG = getArg('--tag') || ''; // 결과 파일 라벨 (예: v1/v2)
const MODEL = getArg('--model') || JSON.parse(readFileSync(MODELS_JSON, 'utf8')).sonnet;

// ── 격리 토큰 환경 (llm-gateway 패턴) ──
function isoEnv() {
  const env = { ...process.env, ANTHROPIC_API_KEY: '' };
  if (!env.CLAUDE_CODE_OAUTH_TOKEN && existsSync(TOKEN_FILE)) {
    env.CLAUDE_CODE_OAUTH_TOKEN = readFileSync(TOKEN_FILE, 'utf8').trim();
  }
  return env;
}

// ── claude -p 호출 (질문은 stdin — 따옴표 이슈 회피) ──
function claudeCall(args, stdinText, timeoutMs = 480000) {
  return new Promise((resolve, reject) => {
    const p = execFile(CLAUDE_BIN, args, { env: isoEnv(), timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024 },
      (err, stdout, stderr) => err ? reject(new Error((stderr || err.message).slice(0, 500))) : resolve(stdout.trim()));
    p.stdin.write(stdinText); p.stdin.end();
  });
}

// ── judge 응답에서 JSON 추출 ──
function extractJson(text) {
  const s = text.indexOf('{'), e = text.lastIndexOf('}');
  if (s < 0 || e <= s) throw new Error('judge 응답에 JSON 없음: ' + text.slice(0, 120));
  return JSON.parse(text.slice(s, e + 1));
}

// ── 공통(전역) 루브릭 — 모든 문항에 추가 적용 ──
const GLOBAL_RUBRIC = [
  '주인님 호칭·존댓말(집사 어투)을 일관되게 유지한다 (반말·"사용자님" 금지)',
  '"죄송합니다" 류 빈 사과로 시작하지 않는다',
];

async function main() {
  const sysSource = PERSONA_FILE || SNAPSHOT;
  if (!existsSync(sysSource)) throw new Error('시스템 프롬프트 소스 없음: ' + sysSource);
  const systemPrompt = readFileSync(sysSource, 'utf8');
  let items = readFileSync(GOLDEN, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  if (ONLY) items = items.filter((it) => it.id === ONLY);
  if (IDS) items = items.filter((it) => IDS.includes(it.id));
  items = items.slice(0, LIMIT);
  if (!items.length) { console.error('실행할 문항 없음'); process.exit(1); }

  mkdirSync(EVAL_DIR, { recursive: true });
  const stamp = new Date(Date.now() + 9 * 3600 * 1000).toISOString().replace(/[-:]/g, '').slice(0, 13); // KST
  const outFile = join(EVAL_DIR, `results-${stamp}${TAG ? '-' + TAG : ''}.jsonl`);
  const meta = { model: MODEL, snapshotBytes: systemPrompt.length, items: items.length,
    sysSource: PERSONA_FILE ? PERSONA_FILE.split('/').pop() : 'snapshot', tag: TAG };
  console.log(`▶ 평가 시작 — 모델=${MODEL} 문항=${items.length} 프롬프트=${meta.sysSource}(${(systemPrompt.length / 1024).toFixed(1)}KB)${TAG ? ' tag=' + TAG : ''}`);

  const results = [];
  for (const it of items) {
    const t0 = Date.now();
    let answer = '', judge = null, error = null;
    try {
      // 1) 봇 응답 생성 (봇 시스템 프롬프트 + 봇과 동일 모델)
      answer = await claudeCall(
        ['-p', '--model', MODEL, '--append-system-prompt', systemPrompt],
        `(Discord 채널 ${it.channel}에서 주인님 메시지) ${it.question}`);

      // 2) LLM-as-judge 채점
      const rubric = [...it.rubric, ...GLOBAL_RUBRIC];
      const judgePrompt = [
        '당신은 AI 비서 응답 품질 채점관입니다. 아래 [질문]에 대한 [응답]을 [루브릭] 항목별로 엄격히 채점하십시오.',
        '응답 외 다른 정보를 가정하지 말고, 루브릭에 실제로 부합하는지만 판단하십시오. 애매하면 fail입니다.',
        '반드시 순수 JSON만 출력: {"criteria":[{"c":"루브릭 요약(10자)","pass":true|false,"note":"근거 한줄"}],"overall":1~5 정수,"violations":["치명 위반들"],"summary":"한 줄 총평"}',
        '', `[질문] ${it.question}`, '', `[응답]\n${answer}`, '',
        `[루브릭]\n${rubric.map((r, i) => `${i + 1}. ${r}`).join('\n')}`,
      ].join('\n');
      judge = extractJson(await claudeCall(['-p', '--model', MODEL], judgePrompt));
    } catch (e) { error = e.message; }

    const rec = { id: it.id, channel: it.channel, category: it.category, question: it.question,
      answer, judge, error, elapsedMs: Date.now() - t0, ...meta, ts: new Date().toISOString() };
    appendFileSync(outFile, JSON.stringify(rec) + '\n');
    results.push(rec);
    const score = judge?.overall ?? 'ERR';
    const fails = judge ? judge.criteria.filter((c) => !c.pass).length : '-';
    console.log(`  ${it.id}: ${score}/5 (fail ${fails}) ${error ? '⚠ ' + error.slice(0, 80) : ''} [${((Date.now() - t0) / 1000).toFixed(0)}s]`);
  }

  // ── 요약 ──
  const scored = results.filter((r) => r.judge);
  const avg = scored.length ? (scored.reduce((s, r) => s + r.judge.overall, 0) / scored.length).toFixed(2) : 'N/A';
  const allViolations = scored.flatMap((r) => (r.judge.violations || []).map((v) => `${r.id}: ${v}`));
  console.log(`\n■ 결과: 평균 ${avg}/5 (채점 ${scored.length}/${results.length}) → ${outFile}`);
  if (allViolations.length) console.log('■ 치명 위반:\n' + allViolations.map((v) => '  - ' + v).join('\n'));
  const low = scored.filter((r) => r.judge.overall <= 2).map((r) => r.id);
  if (low.length) console.log('■ 낙제(≤2점): ' + low.join(', ') + ' → 오답노트 검토 대상');
}

main().catch((e) => { console.error('FATAL:', e.message); process.exit(1); });
