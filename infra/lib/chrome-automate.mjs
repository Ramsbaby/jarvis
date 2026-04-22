#!/usr/bin/env node
/**
 * chrome-automate.mjs — Claude in Chrome 자동화 공통 라이브러리
 *
 * macOS 전용. 내부 의존성:
 *   - osascript (AppleScript) — Chrome 탭 제어
 *   - screencapture — macOS 내장 스크린샷
 *   - claude CLI (--chrome 모드) — Claude in Chrome 확장 필요
 *
 * 용도: job-apply, virtualoffice-audit 등 UI 자동화 스크립트가 공통으로 사용.
 *
 * API:
 *   openInChrome(url)           → boolean
 *   focusChrome()               → void  (Chrome 앞으로 가져오기)
 *   captureViewport(outPath)    → boolean
 *   runClaudeChrome(prompt, opt)→ { code, stdout, stderr, timedOut }
 *   sleep(ms)                   → Promise<void>
 */

import { execSync, spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

// ── Chrome 탭 열기 ────────────────────────────────────────────────────────
export function openInChrome(url) {
  try {
    execSync(`osascript -e '
tell application "Google Chrome"
    activate
    if (count of windows) = 0 then
        make new window
    end if
    set newTab to make new tab at end of tabs of window 1 with properties {URL:"${url}"}
end tell
'`, { stdio: 'pipe' });
    return true;
  } catch (e) {
    console.error(`[chrome-automate] openInChrome 실패: ${e.message}`);
    return false;
  }
}

// ── Chrome 앞으로 가져오기 (스크린샷 전 필수) ──────────────────────────
export function focusChrome() {
  try {
    execSync(`osascript -e 'tell application "Google Chrome" to activate'`, { stdio: 'pipe' });
  } catch (e) {
    // 실패해도 치명적 아님 — 로그만 남기고 진행
    console.error(`[chrome-automate] focusChrome 실패(무시): ${e.message}`);
  }
}

// ── URL 매칭 탭을 찾아 활성화 (없으면 새 탭으로 생성) ────────────────
/**
 * Chrome 모든 창·탭 순회하며 urlPrefix 로 시작하는 탭을 찾아 활성화.
 * 없으면 맨 앞 창에 새 탭으로 url 열기.
 * 43번 spawn 에서 같은 탭 재사용 → 인증·로드 중복 제거.
 */
export function focusChromeTab(url, urlPrefix = null) {
  const prefix = urlPrefix || url.split('?')[0].replace(/\/$/, '');
  const script = `
tell application "Google Chrome"
    activate
    set found to false
    set winIdx to 0
    repeat with w in windows
        set winIdx to winIdx + 1
        set tabIdx to 0
        repeat with t in tabs of w
            set tabIdx to tabIdx + 1
            try
                if (URL of t) starts with "${prefix}" then
                    set active tab index of w to tabIdx
                    set index of w to 1
                    set found to true
                    exit repeat
                end if
            end try
        end repeat
        if found then exit repeat
    end repeat
    if not found then
        if (count of windows) = 0 then
            make new window
        end if
        make new tab at end of tabs of window 1 with properties {URL:"${url}"}
    end if
end tell
`;
  try {
    execSync(`osascript -e '${script.replace(/'/g, "'\\''")}'`, { stdio: 'pipe' });
    return true;
  } catch (e) {
    console.error(`[chrome-automate] focusChromeTab 실패: ${e.message}`);
    return false;
  }
}

// ── 화면(혹은 활성 Chrome 창) 스크린샷 ─────────────────────────────────
/**
 * macOS 내장 screencapture 사용.
 *   -x : 사운드 무음
 *   -T 0 : 지연 없음
 *   기본은 전체 화면 캡처. Chrome 창만 캡처하려면 -l <window-id> 필요하나 안정성 낮아
 *   전체 화면 + 포커스 전환으로 처리.
 */
export function captureViewport(outPath) {
  mkdirSync(dirname(outPath), { recursive: true });
  // 2026-04-21: Chrome UI 조작 중 display 버퍼 state 일시 nil → "could not create image from display" 재시도로 흡수
  const maxAttempts = 3;
  let lastErr = null;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      execSync(`/usr/sbin/screencapture -x -T 0 "${outPath}"`, { stdio: 'pipe' });
      if (attempt > 1) console.error(`[chrome-automate] captureViewport 성공 (attempt ${attempt}/${maxAttempts})`);
      return true;
    } catch (e) {
      lastErr = e;
      if (attempt < maxAttempts) {
        // display 버퍼 복구 대기 — 100ms, 300ms backoff
        execSync(`sleep ${attempt * 0.1}`, { stdio: 'pipe' });
      }
    }
  }
  console.error(`[chrome-automate] captureViewport 실패 (${maxAttempts}회 시도): ${lastErr?.message}`);
  return false;
}

// ── Claude in Chrome 프로세스 실행 ──────────────────────────────────────
/**
 * @param {string} prompt  Claude에 전달할 프롬프트 본문
 * @param {object} [opt]
 * @param {number} [opt.timeoutMs=120000]  전체 타임아웃 (기본 2분)
 * @param {boolean}[opt.echoStdout=true]   stdout 실시간 출력 여부
 * @returns {Promise<{code:number, stdout:string, stderr:string, timedOut:boolean}>}
 */
export function runClaudeChrome(prompt, opt = {}) {
  const timeoutMs = opt.timeoutMs ?? 120000;
  const echo = opt.echoStdout ?? true;

  return new Promise((resolve) => {
    const proc = spawn('claude', ['--chrome', '-p', '--dangerously-skip-permissions'], {
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      try { proc.kill('SIGTERM'); } catch {}
      // grace
      setTimeout(() => { try { proc.kill('SIGKILL'); } catch {} }, 3000);
    }, timeoutMs);

    proc.stdout.on('data', (d) => {
      const chunk = d.toString();
      stdout += chunk;
      if (echo) process.stdout.write(chunk);
    });
    proc.stderr.on('data', (d) => { stderr += d.toString(); });

    proc.on('close', (code) => {
      clearTimeout(timer);
      resolve({ code: code ?? -1, stdout, stderr, timedOut });
    });
    proc.on('error', (err) => {
      clearTimeout(timer);
      resolve({ code: -1, stdout, stderr: err.message, timedOut });
    });

    try {
      proc.stdin.write(prompt);
      proc.stdin.end();
    } catch (e) {
      clearTimeout(timer);
      resolve({ code: -1, stdout, stderr: `stdin write failed: ${e.message}`, timedOut });
    }
  });
}

// ── Claude in Chrome 스트리밍 실행 ─────────────────────────────────────
/**
 * Claude CLI를 띄워 stdout 라인을 실시간 스트리밍으로 수신한다.
 * 단일 세션에서 여러 step을 순차 실행하는 메가 프롬프트에 적합.
 *
 * @param {string} prompt                                   전체 프롬프트
 * @param {object} opt
 * @param {(line:string)=>void} opt.onLine                  stdout 라인 1개 수신
 * @param {(err:string)=>void}  [opt.onStderr]              stderr 청크 수신
 * @param {number}              [opt.timeoutMs=2700000]     전체 타임아웃 (45분)
 * @param {boolean}             [opt.useStreamJson=false]   stream-json 출력 포맷 사용
 * @returns {Promise<{code:number,timedOut:boolean,stderr:string,lineCount:number}>}
 */
export function runClaudeChromeStream(prompt, opt = {}) {
  const timeoutMs = opt.timeoutMs ?? 2700000;
  const onLine    = opt.onLine   ?? (() => {});
  const onStderr  = opt.onStderr ?? (() => {});

  const args = ['--chrome', '-p', '--dangerously-skip-permissions'];
  if (opt.useStreamJson) args.push('--output-format', 'stream-json', '--include-partial-messages', '--verbose');

  return new Promise((resolve) => {
    const proc = spawn('claude', args, { stdio: ['pipe', 'pipe', 'pipe'] });
    let stderr = '';
    let timedOut = false;
    let lineCount = 0;

    const timer = setTimeout(() => {
      timedOut = true;
      try { proc.kill('SIGTERM'); } catch {}
      setTimeout(() => { try { proc.kill('SIGKILL'); } catch {} }, 3000);
    }, timeoutMs);

    // 라인 버퍼
    let buf = '';
    proc.stdout.on('data', (chunk) => {
      buf += chunk.toString();
      let nl;
      while ((nl = buf.indexOf('\n')) !== -1) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        lineCount++;
        try { onLine(line); } catch (e) { console.error('[onLine] error:', e.message); }
      }
    });
    proc.stderr.on('data', (chunk) => {
      const s = chunk.toString();
      stderr += s;
      try { onStderr(s); } catch {}
    });

    proc.on('close', (code) => {
      clearTimeout(timer);
      // 마지막 미완 라인 flush
      if (buf.length > 0) { lineCount++; try { onLine(buf); } catch {} }
      resolve({ code: code ?? -1, timedOut, stderr, lineCount });
    });
    proc.on('error', (err) => {
      clearTimeout(timer);
      resolve({ code: -1, timedOut, stderr: err.message, lineCount });
    });

    try {
      proc.stdin.write(prompt);
      proc.stdin.end();
    } catch (e) {
      clearTimeout(timer);
      resolve({ code: -1, timedOut, stderr: `stdin write failed: ${e.message}`, lineCount });
    }
  });
}

// ── 짧은 유틸 ─────────────────────────────────────────────────────────────
export function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}
