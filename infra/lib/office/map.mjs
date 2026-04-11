#!/usr/bin/env node
// map.mjs — 2D 오피스 맵 렌더링 + 캐릭터 이동 (blessed)

import blessed from 'blessed';

// 맵 상수
const DESK_W = 12;
const DESK_H = 4;
const COLS = 4;
const GAP_X = 2;
const GAP_Y = 2;
const MARGIN_LEFT = 3;
const MARGIN_TOP = 2;

const STATUS_ICON = {
  running: '{yellow-fg}\u26A1{/yellow-fg}',
  idle: '{green-fg}\u25CF{/green-fg}',
  off: '{red-fg}\u25CF{/red-fg}',
};

const STATUS_LABEL = {
  running: '{yellow-fg}run{/yellow-fg}',
  idle: '{green-fg}idle{/green-fg}',
  off: '{red-fg}off{/red-fg}',
};

export function createOffice(screen, teams, { onInteract, onInfo, onQuit }) {
  // 메인 맵 박스
  const mapBox = blessed.box({
    parent: screen,
    top: 0,
    left: 0,
    width: '100%',
    height: '100%-3',
    border: { type: 'line' },
    label: ' {bold}Jarvis Company{/bold} ',
    tags: true,
    style: {
      border: { fg: 'cyan' },
      label: { fg: 'cyan', bold: true },
    },
  });

  // 하단 상태바
  const statusBar = blessed.box({
    parent: screen,
    bottom: 0,
    left: 0,
    width: '100%',
    height: 3,
    border: { type: 'line' },
    tags: true,
    style: { border: { fg: 'gray' } },
  });

  // 데스크 배치 계산
  const desks = [];
  teams.forEach((team, i) => {
    const col = i % COLS;
    const row = Math.floor(i / COLS);
    const x = MARGIN_LEFT + col * (DESK_W + GAP_X);
    const y = MARGIN_TOP + row * (DESK_H + GAP_Y);

    const icon = STATUS_ICON[team.status] || STATUS_ICON.idle;
    const label = STATUS_LABEL[team.status] || STATUS_LABEL.idle;
    const nameStr = team.name.length > DESK_W - 4
      ? team.name.slice(0, DESK_W - 5) + '..'
      : team.name;

    const deskBox = blessed.box({
      parent: mapBox,
      top: y,
      left: x,
      width: DESK_W,
      height: DESK_H,
      border: { type: 'line' },
      tags: true,
      content: ` {bold}${nameStr}{/bold}\n ${icon} ${label}`,
      style: {
        border: { fg: team.status === 'running' ? 'yellow' : team.status === 'idle' ? 'green' : 'red' },
      },
    });

    desks.push({
      team,
      box: deskBox,
      x, y,
      w: DESK_W,
      h: DESK_H,
    });
  });

  // 플레이어 캐릭터
  const totalRows = Math.ceil(teams.length / COLS);
  let playerX = MARGIN_LEFT + Math.floor(COLS / 2) * (DESK_W + GAP_X) + DESK_W / 2;
  let playerY = MARGIN_TOP + Math.floor(totalRows / 2) * (DESK_H + GAP_Y) - 1;

  const player = blessed.text({
    parent: mapBox,
    top: playerY,
    left: playerX,
    content: '{bold}{cyan-fg}@{/cyan-fg}{/bold}',
    tags: true,
  });

  // 충돌 검사 (데스크 안으로 이동 방지)
  function isBlocked(nx, ny) {
    for (const d of desks) {
      if (nx >= d.x && nx < d.x + d.w && ny >= d.y && ny < d.y + d.h) {
        return true;
      }
    }
    // 맵 경계
    const mapW = (mapBox.width || 60) - 2;
    const mapH = (mapBox.height || 30) - 2;
    if (nx < 1 || nx >= mapW || ny < 1 || ny >= mapH) return true;
    return false;
  }

  // 근처 데스크 감지 (1칸 이내)
  function nearbyDesk() {
    for (const d of desks) {
      if (
        playerX >= d.x - 1 && playerX <= d.x + d.w &&
        playerY >= d.y - 1 && playerY <= d.y + d.h
      ) {
        return d;
      }
    }
    return null;
  }

  function updateStatusBar() {
    const nearby = nearbyDesk();
    if (nearby) {
      const t = nearby.team;
      const actText = t.activity ? ` | ${t.activity}` : '';
      statusBar.setContent(
        ` {cyan-fg}{bold}${t.name}{/bold}{/cyan-fg}${actText}  |  {gray-fg}[E] 대화  [I] 현황  [Q] 종료{/gray-fg}`
      );
    } else {
      statusBar.setContent(
        ' {gray-fg}[WASD] 이동  |  팀 책상 근처에서 [E] 대화  [I] 현황  |  [Q] 종료{/gray-fg}'
      );
    }
    screen.render();
  }

  function movePlayer(dx, dy) {
    const nx = playerX + dx;
    const ny = playerY + dy;
    if (!isBlocked(nx, ny)) {
      playerX = nx;
      playerY = ny;
      player.top = playerY;
      player.left = playerX;
      updateStatusBar();
    }
  }

  // 키 바인딩
  screen.key(['w', 'up'], () => movePlayer(0, -1));
  screen.key(['s', 'down'], () => movePlayer(0, 1));
  screen.key(['a', 'left'], () => movePlayer(-1, 0));
  screen.key(['d', 'right'], () => movePlayer(1, 0));

  screen.key(['e'], () => {
    const desk = nearbyDesk();
    if (desk) onInteract(desk.team);
  });

  screen.key(['i'], () => {
    const desk = nearbyDesk();
    if (desk) onInfo(desk.team);
  });

  screen.key(['q', 'C-c'], () => onQuit());

  // 데스크 상태 업데이트
  function updateDesks(newTeams) {
    newTeams.forEach((team, i) => {
      if (i >= desks.length) return;
      const icon = STATUS_ICON[team.status] || STATUS_ICON.idle;
      const label = STATUS_LABEL[team.status] || STATUS_LABEL.idle;
      const nameStr = team.name.length > DESK_W - 4
        ? team.name.slice(0, DESK_W - 5) + '..'
        : team.name;
      desks[i].team = team;
      desks[i].box.setContent(` {bold}${nameStr}{/bold}\n ${icon} ${label}`);
      desks[i].box.style.border.fg =
        team.status === 'running' ? 'yellow' : team.status === 'idle' ? 'green' : 'red';
    });
    updateStatusBar();
  }

  updateStatusBar();
  return { mapBox, statusBar, updateDesks, nearbyDesk };
}
