#!/usr/bin/env node
// rule-proposal-ctl.mjs — 규칙 승격 제안서 CLI (SELF-HEAL-PLAN 4b)
//
//   rule-proposal-ctl.mjs list [--all|--pending|--promoted|--rejected] [--json]
//   rule-proposal-ctl.mjs show <id|prefix>
//   rule-proposal-ctl.mjs promote <id|prefix> [--to <규칙파일>] [--note "<수동 반영 메모>"]
//   rule-proposal-ctl.mjs reject <id|prefix> --reason "<사유>"
//   rule-proposal-ctl.mjs reopen <id|prefix> [--note ".."]
//   rule-proposal-ctl.mjs render          # JSON → wiki/meta/rule-proposals.md 재생성
//   rule-proposal-ctl.mjs summary         # 한 줄 (주간 회고 첫 줄용)
//   rule-proposal-ctl.mjs count [--all]
//
// promote --to 는 사람이 지정한 파일에만 블록을 붙인다. 자동 크론은 이 명령을 부르지 않는다.
import {
  loadState, promoteProposal, rejectProposal, reopenProposal, renderMarkdown,
  summaryLine, summarize, findProposal, STATE_FILE, MD_FILE,
} from '../lib/rule-proposals.mjs';

const argv = process.argv.slice(2);
const cmd = argv.shift();
const opt = { filter: 'pending', json: false, to: null, note: '', reason: '', all: false };
const pos = [];
for (let i = 0; i < argv.length; i += 1) {
  const a = argv[i];
  switch (a) {
    case '--all': opt.filter = 'all'; opt.all = true; break;
    case '--pending': case '--promoted': case '--rejected': opt.filter = a.slice(2); break;
    case '--json': opt.json = true; break;
    case '--to': opt.to = argv[++i] || ''; break;
    case '--note': opt.note = argv[++i] || ''; break;
    case '--reason': opt.reason = argv[++i] || ''; break;
    case '-h': case '--help': usage(0); break;
    default:
      if (a.startsWith('--')) { console.error(`알 수 없는 옵션: ${a}`); usage(1); }
      pos.push(a);
  }
}

function usage(code) {
  console.log(`사용법:
  rule-proposal-ctl.mjs list [--all|--pending|--promoted|--rejected] [--json]
  rule-proposal-ctl.mjs show <id|prefix>
  rule-proposal-ctl.mjs promote <id|prefix> [--to <규칙파일>] [--note "<메모>"]
  rule-proposal-ctl.mjs reject <id|prefix> --reason "<사유>"
  rule-proposal-ctl.mjs reopen <id|prefix> [--note ".."]
  rule-proposal-ctl.mjs render | summary | count [--all]
정본: ${STATE_FILE}
렌더: ${MD_FILE}`);
  process.exit(code);
}
function d10(ts) { return ts ? String(ts).slice(0, 10) : '-'; }

try {
  switch (cmd) {
    case 'list': {
      const st = loadState();
      const rows = st.proposals.filter((p) => opt.filter === 'all' || p.status === opt.filter)
        .sort((a, b) => b.evidence_count - a.evidence_count);
      if (opt.json) { console.log(JSON.stringify(rows, null, 2)); break; }
      console.log(`규칙 제안 ${opt.filter}: ${rows.length}건`);
      for (const p of rows) {
        const tail = p.status === 'promoted' ? `  ✔ 승격 ${d10(p.promoted_at)} → ${p.promoted_to}`
          : p.status === 'rejected' ? `  ✖ 기각 ${d10(p.rejected_at)} ${p.reject_reason}` : '';
        const rec = p.recurrence_after_decision ? `  (결정 후 재발 ${p.recurrence_after_decision}회)` : '';
        console.log(`${p.id}  근거 ${String(p.evidence_count).padStart(3)}건  ${d10(p.first_seen)}~${d10(p.last_seen)}  ${p.title}${tail}${rec}`);
      }
      break;
    }
    case 'show': {
      if (!pos[0]) usage(1);
      const p = findProposal(loadState(), pos[0]);
      if (!p) { console.error(`제안 없음: ${pos[0]}`); process.exit(1); }
      console.log(JSON.stringify(p, null, 2));
      break;
    }
    case 'promote': {
      if (!pos[0]) usage(1);
      const r = promoteProposal(pos[0], { to: opt.to, note: opt.note });
      if (r.action === 'already') console.log(`already-promoted ${r.id} → ${r.promoted_to}`);
      else console.log(`promoted ${r.id}${r.written ? ` → ${r.written}` : ' (파일 미기재 — 수동 반영으로 기록)'}`);
      break;
    }
    case 'reject': {
      if (!pos[0]) usage(1);
      const r = rejectProposal(pos[0], { reason: opt.reason });
      console.log(r.action === 'already' ? `already-rejected ${r.id}` : `rejected ${r.id}`);
      break;
    }
    case 'reopen': {
      if (!pos[0]) usage(1);
      const r = reopenProposal(pos[0], { note: opt.note });
      console.log(r.action === 'already' ? `already-pending ${r.id}` : `reopened ${r.id}`);
      break;
    }
    case 'render': {
      console.log(`rendered ${renderMarkdown(loadState())}`);
      break;
    }
    case 'summary': console.log(summaryLine(loadState())); break;
    case 'count': {
      const s = summarize(loadState());
      console.log(opt.all ? s.total : s.pending);
      break;
    }
    default: usage(cmd ? 1 : 1);
  }
} catch (e) {
  console.error(`ERROR: ${e.message}`);
  process.exit(2);
}
