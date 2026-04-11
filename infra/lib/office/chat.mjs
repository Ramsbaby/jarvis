#!/usr/bin/env node
// chat.mjs — 팀원과 대화 (claude -p)

import { spawn } from 'child_process';
import fs from 'fs';
import blessed from 'blessed';

export function openChat(screen, team, onClose) {
  // 채팅 컨테이너 (화면 하단 50%)
  const chatContainer = blessed.box({
    parent: screen,
    bottom: 0,
    left: 0,
    width: '100%',
    height: '50%',
    border: { type: 'line' },
    label: ` {bold}${team.name}{/bold} 팀과 대화 {gray-fg}(ESC: 종료){/gray-fg} `,
    tags: true,
    style: {
      border: { fg: 'magenta' },
      label: { fg: 'magenta' },
    },
  });

  // 대화 로그
  const chatLog = blessed.log({
    parent: chatContainer,
    top: 0,
    left: 0,
    width: '100%-2',
    height: '100%-4',
    tags: true,
    scrollable: true,
    alwaysScroll: true,
    scrollbar: { ch: '|', style: { fg: 'gray' } },
  });

  // 입력창
  const inputBox = blessed.textbox({
    parent: chatContainer,
    bottom: 0,
    left: 0,
    width: '100%-2',
    height: 3,
    border: { type: 'line' },
    label: ' > ',
    tags: true,
    inputOnFocus: true,
    style: {
      border: { fg: 'cyan' },
      focus: { border: { fg: 'yellow' } },
    },
  });

  chatLog.log('{gray-fg}팀원에게 질문하세요. ESC로 종료.{/gray-fg}');

  let claudeProcess = null;

  function sendMessage(text) {
    if (!text.trim()) return;
    chatLog.log(`{cyan-fg}{bold}나:{/bold}{/cyan-fg} ${text}`);
    chatLog.log('');

    // system prompt 로드
    let systemPrompt = `You are the ${team.name} team lead at Jarvis Company. Answer in Korean, concisely.`;
    if (team.hasSystemPrompt && fs.existsSync(team.systemPromptPath)) {
      try {
        systemPrompt = fs.readFileSync(team.systemPromptPath, 'utf8');
      } catch { /* fallback */ }
    }

    const args = ['-p', text, '--no-input', '--output-format', 'text'];
    if (systemPrompt) {
      args.push('--system-prompt', systemPrompt);
    }

    let response = '';
    claudeProcess = spawn('claude', args, {
      env: { ...process.env, TERM: 'dumb' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    claudeProcess.stdout.on('data', (chunk) => {
      const text = chunk.toString();
      response += text;
      // 줄 단위로 표시
      const lines = response.split('\n');
      if (lines.length > 1) {
        for (let i = 0; i < lines.length - 1; i++) {
          chatLog.log(`{magenta-fg}{bold}${team.name}:{/bold}{/magenta-fg} ${lines[i]}`);
        }
        response = lines[lines.length - 1];
      }
      screen.render();
    });

    claudeProcess.on('close', () => {
      if (response.trim()) {
        chatLog.log(`{magenta-fg}{bold}${team.name}:{/bold}{/magenta-fg} ${response}`);
      }
      chatLog.log('');
      claudeProcess = null;
      screen.render();
      // 다시 입력 대기
      inputBox.focus();
      inputBox.readInput();
    });

    claudeProcess.on('error', (err) => {
      chatLog.log(`{red-fg}오류: ${err.message}{/red-fg}`);
      claudeProcess = null;
      screen.render();
      inputBox.focus();
      inputBox.readInput();
    });
  }

  // 입력 이벤트
  inputBox.on('submit', (value) => {
    inputBox.clearValue();
    screen.render();
    sendMessage(value);
  });

  // ESC로 종료
  inputBox.key(['escape'], () => {
    if (claudeProcess) {
      claudeProcess.kill('SIGTERM');
      claudeProcess = null;
    }
    chatContainer.destroy();
    screen.render();
    onClose();
  });

  chatContainer.key(['escape'], () => {
    if (claudeProcess) {
      claudeProcess.kill('SIGTERM');
      claudeProcess = null;
    }
    chatContainer.destroy();
    screen.render();
    onClose();
  });

  screen.render();
  inputBox.focus();
  inputBox.readInput();
}
