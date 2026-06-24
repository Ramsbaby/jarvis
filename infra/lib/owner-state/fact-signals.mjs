// fact-signals.mjs — 1층 "값싼 눈": LLM 없이 코드로 '놓치면 안 되는 사실'을 100% 보장.
//
// LLM 통찰(2층)은 비결정적이라 명백한 것도 가끔 놓친다. 그래서 확실한 사실은 여기서
// 결정론적으로 잡는다 → 비결정성 하한선. 동시에 이 신호의 유무가 능동 트리거의 근거.

import { daysUntilKST } from './fact-guard.mjs';

export function detectFactSignals(snapshot) {
  const out = [];
  const cal = snapshot.calendar || [];
  const decisions = (snapshot.recent_decisions || []).join(' ');

  // 신호 1: D-3 이내 "준비가 필요한" 일정만 (시험·면접·발표·제출).
  // 월급·환전·정기 일정은 챙길 거리가 아니므로 제외 — 노이즈 방지(우아함의 핵심).
  const PREP_NEEDED = /시험|면접|코테|코딩테스트|발표|제출|마감|deadline|DOP|라이브|인터뷰|평가|에세이|과제|지원마감/i;
  for (const ev of cal) {
    if (ev.dday !== null && ev.dday >= 0 && ev.dday <= 3 && PREP_NEEDED.test(ev.summary)) {
      out.push({
        type: '리스크', domain: 'career',
        insight: `${ev.summary} 일정이 ${ev.date}(${ev.weekday}), D-${ev.dday}로 임박했습니다. 준비 상태를 점검할 때입니다.`,
        evidence: `캘린더 실측: ${ev.summary} D-${ev.dday}`,
        action: `${ev.summary} 준비 상태를 지금 점검하세요.`,
        question: '', certainty: 'high', source: 'fact',
      });
    }
  }

  // 신호 2: 거절/취소 의향 발화 + 캘린더에 해당 유형 일정 잔존 → 노쇼 위험
  if (/거절|안\s*볼|안볼|취소|포기|안\s*가/.test(decisions)) {
    for (const ev of cal) {
      if (ev.dday >= 0 && ev.dday <= 14 && /면접|1차|2차|코테|시험|라이브/.test(ev.summary)) {
        out.push({
          type: '모순', domain: 'career',
          insight: `최근 거절/취소 의향을 밝히셨는데 캘린더에 "${ev.summary}"(${ev.date} ${ev.weekday})가 남아 있습니다. 안 지우면 노쇼가 됩니다.`,
          evidence: `발화 거절 의향 + 캘린더 ${ev.summary} 잔존 (코드 실측)`,
          action: `거절이 맞다면 캘린더에서 ${ev.date} 일정을 삭제하세요.`,
          question: '', certainty: 'medium', source: 'fact',
        });
        break;
      }
    }
  }

  // 신호 3: 주인님이 답 안 한 통찰 7일+ 방치
  for (const oi of (snapshot.open_insights || [])) {
    if (oi.owner_answer) continue;
    const age = oi.sent ? -daysUntilKST(oi.sent) : 0;
    if (age >= 7) {
      out.push({
        type: '맹점', domain: oi.domain || 'life',
        insight: `"${(oi.insight || '').slice(0, 45)}…" 통찰을 ${age}일째 답 없이 두셨습니다.`,
        evidence: `통찰 ${oi.sent} 발송 후 ${age}일 미응답 (코드 실측)`,
        action: '한 줄이라도 답을 주시거나, 무시할 거면 그렇다고 말씀해 주세요.',
        question: '', certainty: 'high', source: 'fact',
      });
    }
  }

  return out;
}

// CLI: snapshot-latest.json → fact-signals.json
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
if (process.argv[1] && process.argv[1].endsWith('fact-signals.mjs')) {
  const BOT_HOME = process.env.BOT_HOME || join(process.env.HOME, 'jarvis/runtime');
  const DIR = join(BOT_HOME, 'state/owner-state');
  try {
    const snap = JSON.parse(readFileSync(join(DIR, 'snapshot-latest.json'), 'utf-8'));
    const sig = detectFactSignals(snap);
    writeFileSync(join(DIR, 'fact-signals.json'), JSON.stringify(sig, null, 2));
    console.log(`[fact-signals] ${sig.length}개 결정론적 신호 (LLM 0원)`);
    sig.forEach(s => console.log(`  • [${s.certainty}] ${s.insight.slice(0, 52)}`));
  } catch (e) { console.error('[fact-signals]', e.message); }
}
