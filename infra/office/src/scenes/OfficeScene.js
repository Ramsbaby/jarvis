import Phaser from 'phaser';

const TILE = 32;
const MAP_COLS = 20;
const MAP_ROWS = 24;
const PLAYER_SPEED = 160;

// 방 정의: { id, name, emoji, x, y, w, h } (타일 단위)
const ROOMS = [
  // Row 1: 임원실
  { id: 'council', name: 'CEO실', emoji: '👔', x: 1, y: 1, w: 4, h: 4 },
  { id: 'infra', name: '인프라팀', emoji: '🖥️', x: 6, y: 1, w: 4, h: 4 },
  { id: 'trend', name: '정보팀', emoji: '📰', x: 11, y: 1, w: 4, h: 4 },
  { id: 'finance', name: '재무팀', emoji: '📊', x: 16, y: 1, w: 4, h: 4 },
  // Row 2: 팀 오피스
  { id: 'record', name: '기록팀', emoji: '📁', x: 1, y: 8, w: 4, h: 4 },
  { id: 'security', name: '감사팀', emoji: '🔒', x: 6, y: 8, w: 4, h: 4 },
  { id: 'academy', name: '학습팀', emoji: '📚', x: 11, y: 8, w: 4, h: 4 },
  { id: 'brand', name: '브랜드팀', emoji: '🎨', x: 16, y: 8, w: 4, h: 4 },
  // Row 3: 특수실
  { id: 'standup', name: '스탠드업', emoji: '🎤', x: 1, y: 15, w: 4, h: 4 },
  { id: 'career', name: '커리어팀', emoji: '💼', x: 6, y: 15, w: 4, h: 4 },
  { id: 'recon', name: '정찰팀', emoji: '🔍', x: 11, y: 15, w: 4, h: 4 },
  { id: 'ceo-digest', name: 'CEO Digest', emoji: '🏢', x: 16, y: 15, w: 4, h: 4 },
];

const STATUS_COLORS = { GREEN: 0x3fb950, YELLOW: 0xd29922, RED: 0xf85149 };

export class OfficeScene extends Phaser.Scene {
  constructor() {
    super({ key: 'OfficeScene' });
    this.player = null;
    this.cursors = null;
    this.wasd = null;
    this.npcs = [];
    this.nearbyNpc = null;
    this.panelOpen = false;
    this.teamData = {};
    this.interactPrompt = null;
    this.isMoving = false;
    this.gridX = 10;
    this.gridY = 6;
  }

  create() {
    const mapW = MAP_COLS * TILE;
    const mapH = MAP_ROWS * TILE;

    // 배경
    this.add.rectangle(mapW / 2, mapH / 2, mapW, mapH, 0x161b22).setOrigin(0.5);

    // 복도 (밝은 바닥)
    this.add.rectangle(mapW / 2, 6.5 * TILE, mapW - TILE * 2, TILE * 2, 0x21262d).setOrigin(0.5);
    this.add.rectangle(mapW / 2, 13.5 * TILE, mapW - TILE * 2, TILE * 2, 0x21262d).setOrigin(0.5);
    this.add.rectangle(mapW / 2, 20.5 * TILE, mapW - TILE * 2, TILE * 2, 0x21262d).setOrigin(0.5);

    // 방 그리기 + NPC 배치
    ROOMS.forEach(room => {
      this.drawRoom(room);
      this.spawnNPC(room);
    });

    // 타이틀
    this.add.text(mapW / 2, TILE * 0.3, '🏢 JARVIS COMPANY HQ', {
      fontSize: '16px', fontFamily: 'monospace', color: '#58a6ff',
    }).setOrigin(0.5);

    // 플레이어
    this.player = this.add.circle(this.gridX * TILE + TILE / 2, this.gridY * TILE + TILE / 2, 10, 0x58a6ff);
    this.add.text(0, 0, '👤', { fontSize: '20px' }).setOrigin(0.5).setName('playerEmoji');

    // 상호작용 프롬프트
    this.interactPrompt = this.add.text(0, 0, '', {
      fontSize: '12px', fontFamily: 'monospace', color: '#ffffff',
      backgroundColor: '#30363d', padding: { x: 8, y: 4 },
    }).setOrigin(0.5).setVisible(false).setDepth(100);

    // HUD
    this.createHUD();

    // 입력
    this.cursors = this.input.keyboard.createCursorKeys();
    this.wasd = this.input.keyboard.addKeys('W,A,S,D');
    this.input.keyboard.on('keydown-E', () => this.interact());
    this.input.keyboard.on('keydown-SPACE', () => this.interact());

    // 카메라
    this.cameras.main.startFollow(this.player, true, 0.1, 0.1);
    this.cameras.main.setBounds(0, 0, mapW, mapH);

    // 데이터 로드
    this.loadTeamData();
    this.time.addEvent({ delay: 15000, callback: () => this.loadTeamData(), loop: true });

    // DOM 패널
    this.createPanel();
  }

  drawRoom(room) {
    const x = room.x * TILE;
    const y = room.y * TILE;
    const w = room.w * TILE;
    const h = room.h * TILE;

    // 바닥
    this.add.rectangle(x + w / 2, y + h / 2, w, h, 0x0d1117).setOrigin(0.5);

    // 벽
    const gfx = this.add.graphics();
    gfx.lineStyle(2, 0x30363d);
    gfx.strokeRect(x, y, w, h);

    // 방 이름
    this.add.text(x + w / 2, y + 8, `${room.emoji} ${room.name}`, {
      fontSize: '11px', fontFamily: 'monospace', color: '#8b949e',
    }).setOrigin(0.5, 0);
  }

  spawnNPC(room) {
    const cx = (room.x + room.w / 2) * TILE;
    const cy = (room.y + room.h / 2 + 0.5) * TILE;

    // NPC 원
    const npc = this.add.circle(cx, cy, 12, 0x8b949e).setInteractive();

    // 이모지
    const emoji = this.add.text(cx, cy, room.emoji, { fontSize: '18px' }).setOrigin(0.5);

    // 상태 LED
    const led = this.add.circle(cx + 14, cy - 14, 4, STATUS_COLORS.GREEN);

    // 상태 텍스트
    const statusText = this.add.text(cx, cy + 20, '...', {
      fontSize: '9px', fontFamily: 'monospace', color: '#8b949e',
    }).setOrigin(0.5);

    npc.on('pointerdown', () => this.openBriefing(room.id));

    this.npcs.push({ room, npc, emoji, led, statusText, cx, cy });
  }

  createHUD() {
    const cam = this.cameras.main;
    // 하단 바
    this.hudBg = this.add.rectangle(0, 0, 400, 32, 0x0d1117, 0.9)
      .setScrollFactor(0).setOrigin(0, 1).setDepth(200);
    this.hudText = this.add.text(8, -8, '[←↑↓→/WASD] 이동  [E/Space] 대화  [ESC] 닫기', {
      fontSize: '11px', fontFamily: 'monospace', color: '#8b949e',
    }).setScrollFactor(0).setOrigin(0, 1).setDepth(201);

    this.updateHUDPosition();
    this.scale.on('resize', () => this.updateHUDPosition());
  }

  updateHUDPosition() {
    const h = this.scale.height;
    const w = this.scale.width;
    if (this.hudBg) {
      this.hudBg.setPosition(0, h);
      this.hudBg.width = w;
    }
    if (this.hudText) this.hudText.setPosition(8, h - 8);
  }

  update() {
    this.handleMovement();
    this.updatePlayerSprite();
    this.checkProximity();
  }

  handleMovement() {
    if (this.isMoving || this.panelOpen) return;

    let dx = 0, dy = 0;
    if (this.cursors.left.isDown || this.wasd.A.isDown) dx = -1;
    else if (this.cursors.right.isDown || this.wasd.D.isDown) dx = 1;
    else if (this.cursors.up.isDown || this.wasd.W.isDown) dy = -1;
    else if (this.cursors.down.isDown || this.wasd.S.isDown) dy = 1;

    if (dx === 0 && dy === 0) return;

    const nx = this.gridX + dx;
    const ny = this.gridY + dy;

    // 경계 체크
    if (nx < 0 || nx >= MAP_COLS || ny < 0 || ny >= MAP_ROWS) return;

    // 방 내부 충돌 (벽만 — 방 안은 들어갈 수 있음, 입구가 있는 쪽)
    // 간단화: 복도와 방 내부 모두 이동 가능
    this.gridX = nx;
    this.gridY = ny;

    const targetX = nx * TILE + TILE / 2;
    const targetY = ny * TILE + TILE / 2;

    this.isMoving = true;
    this.tweens.add({
      targets: this.player,
      x: targetX,
      y: targetY,
      duration: 120,
      ease: 'Linear',
      onComplete: () => { this.isMoving = false; },
    });
  }

  updatePlayerSprite() {
    const pe = this.children.getByName('playerEmoji');
    if (pe) {
      pe.x = this.player.x;
      pe.y = this.player.y;
    }
  }

  checkProximity() {
    let closest = null;
    let minDist = Infinity;

    for (const npc of this.npcs) {
      const dist = Phaser.Math.Distance.Between(this.player.x, this.player.y, npc.cx, npc.cy);
      if (dist < TILE * 3 && dist < minDist) {
        closest = npc;
        minDist = dist;
      }
    }

    this.nearbyNpc = closest;
    if (closest) {
      this.interactPrompt.setText(`[E] ${closest.room.name}에 말걸기`);
      this.interactPrompt.setPosition(closest.cx, closest.cy - 30);
      this.interactPrompt.setVisible(true);
    } else {
      this.interactPrompt.setVisible(false);
    }
  }

  interact() {
    if (this.nearbyNpc) {
      this.openBriefing(this.nearbyNpc.room.id);
    }
  }

  // ── 데이터 로드 ────────────────────────────────────────────────────────────
  async loadTeamData() {
    try {
      const res = await fetch('/api/teams');
      if (!res.ok) return;
      const data = await res.json();
      this.teamData = {};
      for (const team of data.teams) {
        this.teamData[team.id] = team;
      }
      this.updateNPCStatuses();
    } catch { /* retry next interval */ }
  }

  updateNPCStatuses() {
    for (const npc of this.npcs) {
      const data = this.teamData[npc.room.id];
      if (!data) continue;

      const color = STATUS_COLORS[data.status] || STATUS_COLORS.GREEN;
      npc.led.setFillStyle(color);
      npc.npc.setFillStyle(color, 0.3);

      let statusLabel = data.currentTask || data.lastActivity?.task || 'idle';
      if (statusLabel.length > 15) statusLabel = statusLabel.slice(0, 14) + '…';
      npc.statusText.setText(statusLabel);
    }
  }

  // ── 브리핑 패널 (DOM) ──────────────────────────────────────────────────────
  createPanel() {
    if (document.getElementById('briefing-panel')) return;

    const panel = document.createElement('div');
    panel.id = 'briefing-panel';
    panel.style.cssText = `
      position: fixed; right: -420px; top: 0; width: 400px; height: 100vh;
      background: #161b22; border-left: 1px solid #30363d;
      transition: right 0.3s ease; z-index: 1000;
      overflow-y: auto; font-family: -apple-system, sans-serif; color: #e6edf3;
      padding: 20px; font-size: 14px;
    `;
    document.body.appendChild(panel);

    // ESC로 닫기
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && this.panelOpen) this.closePanel();
    });
  }

  async openBriefing(teamId) {
    const panel = document.getElementById('briefing-panel');
    if (!panel) return;

    this.panelOpen = true;
    panel.style.right = '0';
    panel.innerHTML = '<div style="text-align:center;padding:40px;color:#8b949e">로딩 중...</div>';

    try {
      const res = await fetch(`/api/team/${teamId}/briefing`);
      if (!res.ok) throw new Error();
      const data = await res.json();
      this.renderBriefing(panel, data);
    } catch {
      panel.innerHTML = '<div style="padding:40px;color:#f85149">데이터 로드 실패</div>';
    }
  }

  renderBriefing(panel, data) {
    const stColor = STATUS_COLORS[data.status] ? '#' + STATUS_COLORS[data.status].toString(16).padStart(6, '0') : '#3fb950';
    const stLabel = data.status === 'GREEN' ? '정상' : data.status === 'YELLOW' ? '주의' : '이상';

    panel.innerHTML = `
      <button onclick="document.getElementById('briefing-panel').style.right='-420px'" style="
        position:absolute;top:12px;right:12px;background:none;border:none;color:#8b949e;cursor:pointer;font-size:18px;
      ">✕</button>

      <div style="display:flex;align-items:center;gap:12px;margin-bottom:20px;">
        <span style="font-size:40px">${data.emoji}</span>
        <div>
          <div style="font-size:18px;font-weight:700">${data.name}</div>
          <div style="font-size:13px;color:#8b949e">${data.role}</div>
          <div style="font-size:12px;color:#8b949e">📅 ${data.schedule}</div>
        </div>
      </div>

      <div style="display:inline-flex;align-items:center;gap:6px;padding:4px 12px;border-radius:20px;
        background:${stColor}15;border:1px solid ${stColor};margin-bottom:20px;">
        <div style="width:8px;height:8px;border-radius:50%;background:${stColor}"></div>
        <span style="font-size:13px;font-weight:600;color:${stColor}">${stLabel}</span>
      </div>

      <div style="margin-bottom:20px">
        <h3 style="font-size:14px;color:#8b949e;margin:0 0 8px">📌 현재 상태</h3>
        <p style="margin:0;line-height:1.6">${data.summary}</p>
      </div>

      ${data.stats ? `
      <div style="margin-bottom:20px">
        <h3 style="font-size:14px;color:#8b949e;margin:0 0 8px">📊 24시간 지표</h3>
        <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px">
          <div style="background:#0d1117;border:1px solid #21262d;border-radius:8px;padding:8px;text-align:center">
            <div style="font-size:11px;color:#8b949e">성공률</div>
            <div style="font-size:20px;font-weight:700">${data.stats.rate}%</div>
          </div>
          <div style="background:#0d1117;border:1px solid #21262d;border-radius:8px;padding:8px;text-align:center">
            <div style="font-size:11px;color:#8b949e">성공</div>
            <div style="font-size:20px;font-weight:700;color:#3fb950">${data.stats.success}</div>
          </div>
          <div style="background:#0d1117;border:1px solid #21262d;border-radius:8px;padding:8px;text-align:center">
            <div style="font-size:11px;color:#8b949e">실패</div>
            <div style="font-size:20px;font-weight:700;color:#f85149">${data.stats.failed}</div>
          </div>
        </div>
      </div>
      ` : ''}

      ${data.recentActivity?.length ? `
      <div style="margin-bottom:20px">
        <h3 style="font-size:14px;color:#8b949e;margin:0 0 8px">📋 최근 활동</h3>
        <div style="max-height:200px;overflow-y:auto">
          ${data.recentActivity.slice(0, 10).map(a => `
            <div style="display:flex;gap:8px;padding:4px 0;border-bottom:1px solid #21262d;font-size:12px">
              <span style="color:#8b949e;min-width:40px">${a.time.slice(11, 16)}</span>
              <span style="color:${a.result === 'SUCCESS' ? '#3fb950' : a.result === 'FAILED' ? '#f85149' : '#d29922'};min-width:55px;font-weight:600">${a.result}</span>
              <span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${a.task}</span>
            </div>
          `).join('')}
        </div>
      </div>
      ` : ''}

      ${data.boardMinutes ? `
      <div style="margin-bottom:20px">
        <h3 style="font-size:14px;color:#8b949e;margin:0 0 8px">📝 최근 보고 (${data.boardMinutes.date})</h3>
        <pre style="background:#0d1117;border:1px solid #21262d;border-radius:8px;padding:12px;
          font-size:11px;color:#8b949e;white-space:pre-wrap;max-height:150px;overflow-y:auto">${this.escapeHtml(data.boardMinutes.content)}</pre>
      </div>
      ` : ''}

      <div style="margin-bottom:20px">
        <h3 style="font-size:14px;color:#8b949e;margin:0 0 8px">💬 /btw 말걸기</h3>
        <div style="display:flex;gap:8px">
          <input id="btw-input" placeholder="${data.name}에게 메시지..." style="
            flex:1;background:#0d1117;border:1px solid #21262d;border-radius:8px;
            padding:8px 12px;color:#e6edf3;font-size:13px;outline:none;
          " />
          <button onclick="window._sendBtw('${data.id}')" style="
            background:#238636;border:none;border-radius:8px;padding:8px 16px;
            color:#fff;font-size:13px;cursor:pointer;
          ">전송</button>
        </div>
        <div id="btw-response" style="margin-top:8px;font-size:13px"></div>
      </div>
    `;

    // /btw 전송 핸들러
    window._sendBtw = async (teamId) => {
      const input = document.getElementById('btw-input');
      const respDiv = document.getElementById('btw-response');
      if (!input?.value.trim()) return;
      const msg = input.value;
      input.value = '';
      respDiv.innerHTML = '<span style="color:#8b949e">응답 대기 중...</span>';

      try {
        const res = await fetch('/api/chat', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ teamId, message: msg }),
        });
        if (!res.ok) throw new Error();
        const data = await res.json();
        respDiv.innerHTML = `<div style="background:#0d1117;border:1px solid #21262d;border-radius:8px;padding:12px;white-space:pre-wrap">${this.escapeHtml(data.response)}</div>`;
      } catch {
        respDiv.innerHTML = '<span style="color:#f85149">응답 실패</span>';
      }
    };

    // Enter 키로 전송
    const input = document.getElementById('btw-input');
    if (input) {
      input.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') window._sendBtw(data.id);
      });
      input.focus();
    }

    // 닫기 버튼 이벤트
    panel.querySelector('button').addEventListener('click', () => this.closePanel());
  }

  closePanel() {
    const panel = document.getElementById('briefing-panel');
    if (panel) panel.style.right = '-420px';
    this.panelOpen = false;
  }

  escapeHtml(str) {
    return (str || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
}
