#!/usr/bin/env node
/**
 * interview-compress-batch.mjs
 *
 * SSoT 시나리오 파일의 approvedAnswer.content 중 600자 초과 항목을
 * verifier /compress 엔드포인트로 압축 후 SSoT에 직접 업데이트.
 *
 * 0점 처리 대신 Claude 압축으로 대체하는 배치 작업 (v4.84, 2026-05-03).
 *
 * Usage:
 *   node interview-compress-batch.mjs [--dry-run] [--scenario samsung-cnt] [--limit 5]
 *
 *   --dry-run: 압축 결과만 출력, 파일 저장 안 함
 *   --scenario: 파일명 prefix (기본: samsung-cnt,samsung-cnt-bset 모두)
 *   --limit N: N개만 처리 (테스트용)
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { request as httpRequest } from 'node:http';

const SCENARIOS_DIR = join(homedir(), 'jarvis/runtime/state/scenarios');
const USER_PROFILE_PATH = join(homedir(), 'jarvis/runtime/context/user-profile.md');
const COMPRESS_URL = process.env.INTERVIEW_COMPRESS_URL || 'http://127.0.0.1:7779/compress';
const MAX_CHARS = 650;

const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const limitIdx = args.indexOf('--limit');
const limit = limitIdx >= 0 ? Number(args[limitIdx + 1]) : Infinity;
const scenarioIdx = args.indexOf('--scenario');
const scenarioFilter = scenarioIdx >= 0 ? args[scenarioIdx + 1] : null;

function loadUserProfile() {
  if (!existsSync(USER_PROFILE_PATH)) { console.error('❌ user-profile.md 없음'); process.exit(1); }
  return readFileSync(USER_PROFILE_PATH, 'utf-8');
}

async function callCompress(detailText, userProfile, question) {
  const body = JSON.stringify({ detailText, userProfile, question, maxChars: MAX_CHARS });
  return new Promise((resolve, reject) => {
    const parsedUrl = new URL(COMPRESS_URL);
    const req = httpRequest({
      hostname: parsedUrl.hostname,
      port: Number(parsedUrl.port) || 7779,
      path: parsedUrl.pathname,
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, (res) => {
      let data = '';
      res.on('data', chunk => { data += chunk; });
      res.on('end', () => {
        if (res.statusCode !== 200) { reject(new Error(`compress HTTP ${res.statusCode}: ${data}`)); return; }
        try { resolve(JSON.parse(data)); } catch (e) { reject(e); }
      });
      res.on('error', reject);
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

async function processScenario(filePath) {
  const fileName = filePath.split('/').pop();
  console.log(`\n📂 처리 중: ${fileName}`);

  const data = JSON.parse(readFileSync(filePath, 'utf-8'));
  const questions = data.qnaQuestions || [];

  const targets = questions.filter(q => {
    const content = q.approvedAnswer?.content;
    if (!content) return false;
    const body = content
      .replace(/^[^]*?💬[^\n]*\n/, '')
      .replace(/\n\n---\n[\s\S]*$/, '')
      .replace(/\*\*/g, '')
      .trim();
    return body.length > MAX_CHARS;
  });

  console.log(`   📊 전체 ${questions.length}개 중 ${MAX_CHARS}자 초과: ${targets.length}개`);

  if (targets.length === 0) {
    console.log('   ✅ 압축 대상 없음');
    return { fileName, processed: 0, compressed: 0, failed: 0 };
  }

  const userProfile = loadUserProfile();
  let processed = 0, compressed = 0, failed = 0;
  const toProcess = targets.slice(0, limit - processed < 0 ? 0 : Math.min(targets.length, limit));

  for (const q of toProcess) {
    if (processed >= limit) break;
    processed++;

    const content = q.approvedAnswer.content;
    const body = content
      .replace(/^[^]*?💬[^\n]*\n/, '')
      .replace(/\n\n---\n[\s\S]*$/, '')
      .replace(/\*\*/g, '')
      .trim();

    console.log(`   🔄 [${processed}/${toProcess.length}] ${q.id} — 원본 ${body.length}자`);

    try {
      const result = await callCompress(body, userProfile, q.text);
      if (result.compressedChars <= MAX_CHARS && result.compressed) {
        console.log(`   ✅ ${q.id}: ${body.length}자 → ${result.compressedChars}자 (${result.elapsedMs}ms)`);
        if (!dryRun) {
          // 헤더/푸터 복원 — 압축된 본문만 교체
          const header = content.match(/^(.*💬.*\n)/)?.[1] || '';
          const footer = content.match(/(\n\n---\n[\s\S]*)$/)?.[1] || '';
          q.approvedAnswer.content = header + result.compressed + footer;
          q.approvedAnswer.compressedAt = new Date().toISOString();
          q.approvedAnswer.originalChars = body.length;
        }
        compressed++;
      } else {
        console.warn(`   ⚠️ ${q.id}: 압축 실패 또는 여전히 초과 (${result.compressedChars}자)`);
        failed++;
      }
    } catch (err) {
      console.error(`   ❌ ${q.id}: ${err.message}`);
      failed++;
    }

    // rate limit 방지 — 연속 요청 간 짧은 대기
    if (processed < toProcess.length) await new Promise(r => setTimeout(r, 500));
  }

  if (!dryRun && compressed > 0) {
    // 백업 먼저
    const backupPath = `${filePath}.bak-compress-${Date.now()}`;
    writeFileSync(backupPath, readFileSync(filePath, 'utf-8'));
    console.log(`   💾 백업: ${backupPath.split('/').pop()}`);
    writeFileSync(filePath, JSON.stringify(data, null, 2), 'utf-8');
    console.log(`   💾 저장 완료 — ${compressed}개 업데이트`);
  }

  return { fileName, processed, compressed, failed };
}

async function main() {
  console.log(`🚀 interview-compress-batch 시작 (${dryRun ? 'DRY-RUN' : '실제 저장'}, maxChars=${MAX_CHARS}, limit=${limit === Infinity ? '∞' : limit})`);

  // verifier 상태 확인
  try {
    await new Promise((resolve, reject) => {
      const req = httpRequest({ hostname: '127.0.0.1', port: 7779, path: '/health', method: 'GET' }, (res) => {
        let d = ''; res.on('data', c => d += c); res.on('end', () => {
          const h = JSON.parse(d);
          if (h.ok) { console.log(`✅ verifier 가동 중 (v${h.version}, uptime ${h.uptimeSec}s)`); resolve(); }
          else reject(new Error('health not ok'));
        });
      });
      req.on('error', reject);
      req.end();
    });
  } catch (err) {
    console.error(`❌ verifier-server 미가동 — 먼저 기동하십시오: bash ~/jarvis/runtime/scripts/interview-ralph-start.sh`);
    process.exit(1);
  }

  const files = ['samsung-cnt.json', 'samsung-cnt-bset.json']
    .filter(f => !scenarioFilter || f.startsWith(scenarioFilter))
    .map(f => join(SCENARIOS_DIR, f))
    .filter(f => existsSync(f));

  if (files.length === 0) {
    console.error('❌ 처리할 시나리오 파일 없음');
    process.exit(1);
  }

  const results = [];
  for (const f of files) {
    const r = await processScenario(f);
    results.push(r);
  }

  console.log('\n📊 전체 결과:');
  let totalCompressed = 0, totalFailed = 0;
  for (const r of results) {
    console.log(`   ${r.fileName}: 처리 ${r.processed} / 압축성공 ${r.compressed} / 실패 ${r.failed}`);
    totalCompressed += r.compressed;
    totalFailed += r.failed;
  }
  console.log(`\n   총 압축 성공: ${totalCompressed} / 실패: ${totalFailed}`);
  if (dryRun) console.log('\n⚠️ --dry-run 모드 — 파일 저장 안 함. 실제 적용: --dry-run 제거 후 재실행');
}

main().catch(err => { console.error('fatal:', err); process.exit(1); });
