#!/usr/bin/env node
// jarvis-office.mjs — Jarvis Company 가상 오피스 (게더타운 스타일 TUI)
//
// 사용법: node infra/bin/jarvis-office.mjs
//
// WASD/화살표: 이동 | E: 대화 | I: 현황 | Q: 종료

import blessed from 'blessed';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const libDir = path.join(__dirname, '..', 'lib', 'office');

const { getOfficeSnapshot, getTeamBoardSummary } = await import(path.join(libDir, 'team-desk.mjs'));
const { createOffice } = await import(path.join(libDir, 'map.mjs'));
const { openChat } = await import(path.join(libDir, 'chat.mjs'));

// blessed 스크린 생성
const screen = blessed.screen({
  smartCSR: true,
  title: 'Jarvis Company',
  fullUnicode: true,
});

// 팀 데이터 로드
let teams = getOfficeSnapshot();

if (teams.length === 0) {
  console.error('팀 데이터를 찾을 수 없습니다. (~/jarvis/runtime/teams/ 확인)');
  process.exit(1);
}

// 맵 생성
let chatMode = false;

const office = createOffice(screen, teams, {
  onInteract: (team) => {
    if (chatMode) return;
    chatMode = true;
    openChat(screen, team, () => {
      chatMode = false;
      screen.render();
    });
  },

  onInfo: (team) => {
    if (chatMode) return;
    showTeamInfo(team);
  },

  onQuit: () => {
    if (refreshTimer) clearInterval(refreshTimer);
    screen.destroy();
    process.exit(0);
  },
});

// [I] 현황 팝업
function showTeamInfo(team) {
  const boardSummary = getTeamBoardSummary(team.name);

  let content = '';
  content += `{bold}{cyan-fg}${team.name}{/cyan-fg}{/bold}\n`;
  content += `\n`;
  content += `{gray-fg}ID:{/gray-fg}       ${team.id}\n`;
  content += `{gray-fg}Task:{/gray-fg}     ${team.taskId}\n`;
  content += `{gray-fg}Model:{/gray-fg}    ${team.model}\n`;
  content += `{gray-fg}Discord:{/gray-fg}  ${team.discord || 'N/A'}\n`;
  content += `{gray-fg}Status:{/gray-fg}   ${team.status}`;
  if (team.activity) content += ` (${team.activity})`;
  content += '\n';

  if (boardSummary) {
    content += `\n{bold}Latest Board ({gray-fg}${boardSummary.date}{/gray-fg}):{/bold}\n`;
    for (const excerpt of boardSummary.excerpts) {
      content += `{gray-fg}${excerpt.slice(0, 200)}{/gray-fg}\n`;
    }
  }

  content += `\n{gray-fg}[ESC/Enter] 닫기{/gray-fg}`;

  const popup = blessed.box({
    parent: screen,
    top: 'center',
    left: 'center',
    width: '60%',
    height: '60%',
    border: { type: 'line' },
    label: ` {bold}${team.name} 현황{/bold} `,
    tags: true,
    content,
    scrollable: true,
    alwaysScroll: true,
    scrollbar: { ch: '|' },
    style: {
      border: { fg: 'cyan' },
      label: { fg: 'cyan' },
    },
    keys: true,
    vi: true,
  });

  popup.key(['escape', 'enter', 'q'], () => {
    popup.destroy();
    screen.render();
  });

  popup.focus();
  screen.render();
}

// 5초마다 팀 상태 자동 갱신
const refreshTimer = setInterval(() => {
  if (chatMode) return;
  try {
    teams = getOfficeSnapshot();
    office.updateDesks(teams);
  } catch { /* silent */ }
}, 5000);

screen.render();