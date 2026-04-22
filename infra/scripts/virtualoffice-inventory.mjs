#!/usr/bin/env node
/**
 * virtualoffice-inventory.mjs — Phase 1
 *
 * 자비스맵(VirtualOffice) 전수조사용 UI 요소 인벤토리를 생성한다.
 *
 * 출력: ~/.jarvis/ # ALLOW-DOTJARVISstate/virtualoffice-audit/inventory.json
 *
 * 전략:
 *   1) 수작업 시드(Canvas + 팝업별 핵심 인터랙션)를 하드코딩 — 가장 안정적
 *   2) 팝업 소스 파일을 정적 스캔해 onClick 개수 집계 → 시드 커버리지 검증
 *   3) 동일 라벨·동일 아이콘이 여러 컴포넌트에 중복 등장하면 overcook 후보 기록
 *
 * 완벽한 자동 추출이 아닌 "감사용 체크리스트의 씨앗"을 만드는 스크립트이다.
 *
 * Usage:
 *   node virtualoffice-inventory.mjs
 *   node virtualoffice-inventory.mjs --verbose
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { homedir } from 'node:os';

const VERBOSE = process.argv.includes('--verbose');

const BOARD_ROOT = process.env.JARVIS_BOARD_ROOT || join(homedir(), 'jarvis-board');
const STATE_DIR = join(homedir(), '.jarvis', 'state', 'virtualoffice-audit');
const OUT_PATH = join(STATE_DIR, 'inventory.json');
const ARCH_MD = join(BOARD_ROOT, 'docs', 'ARCHITECTURE.md');

mkdirSync(STATE_DIR, { recursive: true });

// ── 의도(Intent) SSoT 추출 ────────────────────────────────────────────────
// ARCHITECTURE.md 의 자비스맵 섹션을 감사 판정 기준으로 주입한다.
// 이 기준은 감사 프롬프트에 포함되어 각 step 의 intent_fit · justification 판정에 쓰인다.
function loadIntent() {
  // Fallback — ARCHITECTURE.md 없어도 최소 의도 유지
  const fallback = {
    source: 'hardcoded-fallback',
    pillars: [
      'CEO 브리지 — Jarvis 생태계의 단일 사령탑 화면',
      '크론 가시화 — cron jobs 의 상태·빈도·실패 파악',
      '팀 활동 가시화 — 팀 미션·구성원·담당 크론 파악',
      'LLM 에이전트 토론·시스템 건강 가시화 — 통합 조망',
    ],
    raw: '자비스맵 = Jarvis 생태계의 CEO 브리지. 크론·팀·에이전트·시스템 건강을 한 화면에 통합 조망하는 viz.',
  };

  if (!existsSync(ARCH_MD)) return fallback;

  const md = readFileSync(ARCH_MD, 'utf-8');
  // "### 자비스맵" 또는 "Virtual Office Map" 섹션 추출
  const match = md.match(/virtual office map[\s\S]*?(?=\n##\s|\n---\n|$)/i);
  if (!match) return fallback;

  const raw = match[0].slice(0, 2000); // 최대 2KB
  return {
    source: `jarvis-board/docs/ARCHITECTURE.md`,
    pillars: fallback.pillars, // 4기둥은 기존 파싱 결과 유지 (안정성)
    raw,
  };
}

// ── 소스 파일 레지스트리 ──────────────────────────────────────────────────
const SOURCE_FILES = {
  VirtualOffice: 'app/company/VirtualOffice.tsx',
  CronDetailPopup: 'components/map/CronDetailPopup.tsx',
  TeamBriefingPopup: 'components/map/TeamBriefingPopup.tsx',
  CronGridPopup: 'components/map/CronGridPopup.tsx',
  MetricDetailModal: 'components/map/MetricDetailModal.tsx',
  RightInfoPanels: 'components/map/RightInfoPanels.tsx',
  BoardBanner: 'components/map/BoardBanner.tsx',
  Statusline: 'components/map/Statusline.tsx',
};

// ── Canvas 시드 (수작업 체크리스트) ───────────────────────────────────────
const CANVAS_SEED = [
  {
    step_id: 'canvas.initial_load',
    description: '지도 초기 진입 확인 — 팀 섹션 3개 이상, 크론 타일 20개 이상 렌더',
    hint: '페이지 로드 직후 전체 캔버스',
    expected: '팀 섹션, 크론 타일, 캐릭터 아이콘, 상단/우측 패널이 정상 표시',
    destructive: false,
  },
  {
    step_id: 'canvas.character_move_keyboard',
    description: 'WASD 키로 캐릭터 이동',
    hint: 'W 키 1초 누르고 스크린샷, A 키 1초 누르고 스크린샷',
    expected: '캐릭터가 상·좌로 이동, 카메라 추적',
    destructive: false,
  },
  {
    step_id: 'canvas.zoom_in_out',
    description: '휠 줌 인/아웃',
    hint: '마우스 휠 상방 2회, 하방 2회',
    expected: '캔버스 확대/축소. 줌 인 시 타일 라벨 더 크게, 줌 아웃 시 미니맵 수준 조망',
    destructive: false,
  },
  {
    step_id: 'canvas.team_section_hover',
    description: '임의 팀 섹션에 호버 → 툴팁 표시',
    hint: '중앙 근처 팀 영역에 마우스 올리기',
    expected: '팀명·구성원 수·현황 툴팁 또는 안내 표시',
    destructive: false,
  },
  {
    step_id: 'canvas.team_section_click',
    description: '팀 섹션 클릭 → TeamBriefingPopup 열림',
    hint: '팀 헤더 영역 클릭',
    expected: 'TeamBriefingPopup 모달 표시 (팀명·브리핑·구성원)',
    destructive: false,
  },
  {
    step_id: 'canvas.cron_tile_success',
    description: '정상(녹색) 크론 타일 클릭 → CronDetailPopup',
    hint: '녹색 아이콘 크론 타일 1개 선택',
    expected: 'CronDetailPopup 모달에 성공 로그, 성공률 표시',
    destructive: false,
  },
  {
    step_id: 'canvas.cron_tile_failed',
    description: '실패(적색) 크론 타일 클릭 → CronDetailPopup',
    hint: '적색/경고 아이콘 크론 타일 1개 선택',
    expected: 'CronDetailPopup 모달에 실패 원인·AI 진단 버튼 노출',
    destructive: false,
  },
  {
    step_id: 'canvas.chat_panel_open',
    description: '채팅 패널 열기 (단축키 또는 버튼)',
    hint: '우하단 채팅 아이콘 또는 C 키',
    expected: '채팅 입력창과 메시지 리스트 표시',
    destructive: false,
  },
  {
    step_id: 'canvas.cron_search',
    description: '크론 검색 입력',
    hint: '상단 검색창에 "token" 같은 키워드 입력',
    expected: '일치하는 크론 타일 강조, 비일치 타일 흐리게',
    destructive: false,
  },
  {
    step_id: 'canvas.cron_filter',
    description: '크론 필터 토글 (성공만/실패만/전체)',
    hint: '필터 드롭다운 또는 칩 버튼',
    expected: '선택한 상태의 크론만 캔버스에 표시',
    destructive: false,
  },
  {
    step_id: 'canvas.cron_grid_open',
    description: '크론 그리드 전체 보기',
    hint: '그리드 아이콘/버튼 (있다면)',
    expected: 'CronGridPopup 열림 (전체 크론 테이블)',
    destructive: false,
  },
  {
    step_id: 'canvas.nearby_room_tooltip',
    description: '캐릭터가 특정 방에 근접 시 툴팁',
    hint: '캐릭터를 팀 섹션 근처로 이동',
    expected: 'nearbyRoom 툴팁 표시 (들어가기 안내)',
    destructive: false,
  },
];

// ── DOM 팝업 시드 (파일별 핵심 버튼) ─────────────────────────────────────
const POPUP_SEED = {
  CronDetailPopup: [
    { step_id: 'CronDetailPopup.open_logs',            description: '로그 열기/펼치기',            expected: 'stdout/stderr 영역 표시', destructive: false },
    { step_id: 'CronDetailPopup.toggle_stderr',        description: 'stderr 토글',                expected: 'stderr 본문 접힘/펼침', destructive: false },
    { step_id: 'CronDetailPopup.toggle_stdout',        description: 'stdout 토글',                expected: 'stdout 본문 접힘/펼침', destructive: false },
    { step_id: 'CronDetailPopup.copy_log',             description: '로그 복사',                  expected: '클립보드에 복사됨 토스트', destructive: false },
    { step_id: 'CronDetailPopup.ai_diagnose',          description: 'AI 진단 실행',               expected: 'AI 분석 로딩 후 원인/제안 표시', destructive: false },
    { step_id: 'CronDetailPopup.run_now',              description: '▶ 지금 실행',                expected: '실행 요청 → runs 목록 갱신', destructive: true },
    { step_id: 'CronDetailPopup.toggle_enabled',       description: '활성/비활성 토글',            expected: '상태 변경 확인 토스트', destructive: true },
    { step_id: 'CronDetailPopup.priority_change',      description: 'priority 변경',              expected: '우선순위 라벨 갱신', destructive: true },
    { step_id: 'CronDetailPopup.retry_failed',         description: '실패 재시도',                expected: 'RetryResultCard 표시', destructive: true },
    { step_id: 'CronDetailPopup.close',                description: '닫기 (X)',                   expected: '모달 닫힘 → 캔버스 복귀', destructive: false },
  ],
  TeamBriefingPopup: [
    { step_id: 'TeamBriefingPopup.tab_overview',       description: '개요 탭',                    expected: '팀 미션/상태 요약 표시', destructive: false },
    { step_id: 'TeamBriefingPopup.tab_members',        description: '구성원 탭',                  expected: '팀원 리스트 + 역할 표시', destructive: false },
    { step_id: 'TeamBriefingPopup.tab_crons',          description: '담당 크론 탭',               expected: '해당 팀이 소유한 크론 목록', destructive: false },
    { step_id: 'TeamBriefingPopup.tab_metrics',        description: '지표 탭',                    expected: '팀 KPI/차트', destructive: false },
    { step_id: 'TeamBriefingPopup.regenerate_briefing',description: '브리핑 재생성',              expected: 'LLM 호출 후 브리핑 갱신', destructive: true },
    { step_id: 'TeamBriefingPopup.member_click',       description: '팀원 클릭 → 상세',           expected: '팀원 상세 패널/툴팁', destructive: false },
    { step_id: 'TeamBriefingPopup.start_chat',         description: '팀 채팅 시작',               expected: '채팅 패널 활성 + 팀 컨텍스트 로드', destructive: false },
    { step_id: 'TeamBriefingPopup.close',              description: '닫기 (X)',                   expected: '모달 닫힘', destructive: false },
  ],
  CronGridPopup: [
    { step_id: 'CronGridPopup.sort_by_status',         description: '상태 기준 정렬',             expected: '실패 상단 정렬 변경', destructive: false },
    { step_id: 'CronGridPopup.filter_team',            description: '팀 필터 적용',               expected: '선택 팀 크론만 표시', destructive: false },
    { step_id: 'CronGridPopup.row_click',              description: '행 클릭 → CronDetailPopup',  expected: 'CronDetailPopup 열림 (그리드 위에)', destructive: false },
    { step_id: 'CronGridPopup.close',                  description: '닫기',                        expected: '그리드 닫힘', destructive: false },
  ],
  MetricDetailModal: [
    { step_id: 'MetricDetailModal.chart_type_switch',  description: '차트 타입 전환',             expected: 'Line/Bar 등 변경', destructive: false },
    { step_id: 'MetricDetailModal.period_select',      description: '기간 선택 (7d/30d)',         expected: '데이터 재로드', destructive: false },
    { step_id: 'MetricDetailModal.close',              description: '닫기',                        expected: '모달 닫힘', destructive: false },
  ],
  RightInfoPanels: [
    { step_id: 'RightInfoPanels.toggle_panel1',        description: '패널 1 접기/펼치기',          expected: '영역 토글', destructive: false },
    { step_id: 'RightInfoPanels.toggle_panel2',        description: '패널 2 접기/펼치기',          expected: '영역 토글', destructive: false },
    { step_id: 'RightInfoPanels.item_click',           description: '패널 내 아이템 클릭',         expected: '관련 팝업 또는 네비게이션', destructive: false },
  ],
  BoardBanner: [
    { step_id: 'BoardBanner.cta_click',                description: '배너 CTA 클릭',               expected: '해당 동작 수행 또는 링크 이동 (데이터 없으면 렌더 안 됨)', destructive: false, conditional_render: true, render_condition: 'banner 데이터 fetch 성공 시에만 표시' },
    { step_id: 'BoardBanner.dismiss',                  description: '배너 닫기',                   expected: '배너 사라짐 (데이터 없으면 렌더 안 됨)', destructive: false, conditional_render: true, render_condition: 'banner 데이터 fetch 성공 시에만 표시' },
  ],
  Statusline: [
    { step_id: 'Statusline.click',                     description: '상태라인 메트릭 버튼 클릭',     expected: 'MetricDetailModal 풀모달 오픈 (회의록 아님)', destructive: false, conditional_render: true, render_condition: 'statusline 데이터 fetch 성공 시에만 표시' },
  ],
};

// ── 정적 스캔 ────────────────────────────────────────────────────────────
function scanFile(relPath) {
  const full = join(BOARD_ROOT, relPath);
  if (!existsSync(full)) return null;
  const src = readFileSync(full, 'utf-8');
  const onClickCount = (src.match(/onClick=\{/g) || []).length;
  const buttonCount  = (src.match(/<button\b/g) || []).length;
  const roleButton   = (src.match(/role="button"/g) || []).length;
  // 버튼 내부 텍스트(한글 + 기호) 일부 추출 — 오버쿡 중복 감지용
  const labelRegex = />([^<>\n]{1,30})<\/button>/g;
  const labels = [];
  let m;
  while ((m = labelRegex.exec(src)) !== null) {
    const raw = m[1].trim();
    if (raw && !raw.startsWith('{')) labels.push(raw);
  }
  return { relPath, onClickCount, buttonCount, roleButton, labels, lineCount: src.split('\n').length };
}

function detectOvercooks(scans) {
  // 1) 동일 라벨이 서로 다른 파일에 다회 등장하면 후보
  const labelFiles = new Map(); // label → [file...]
  for (const s of scans) {
    if (!s) continue;
    for (const lbl of s.labels) {
      const key = lbl.toLowerCase().replace(/\s+/g, ' ');
      if (!labelFiles.has(key)) labelFiles.set(key, new Set());
      labelFiles.get(key).add(s.relPath);
    }
  }
  const suspects = [];
  for (const [label, files] of labelFiles) {
    if (files.size >= 2 && label.length >= 2 && !/^[A-Z×xX]$|^close$|^cancel$|^닫기$|^확인$|^저장$/i.test(label)) {
      suspects.push({
        pattern: `동일 버튼 라벨 "${label}" 이 ${files.size}개 파일에서 중복 정의`,
        files: [...files],
        severity: files.size >= 3 ? 'medium' : 'low',
      });
    }
  }
  return suspects;
}

// ── 메인 ────────────────────────────────────────────────────────────────
function main() {
  if (!existsSync(BOARD_ROOT)) {
    console.error(`❌ jarvis-board 루트가 없습니다: ${BOARD_ROOT}`);
    console.error(`   환경변수 JARVIS_BOARD_ROOT로 지정 가능.`);
    process.exit(1);
  }

  console.log(`📂 jarvis-board: ${BOARD_ROOT}`);
  console.log(`🎯 인벤토리 출력: ${OUT_PATH}\n`);

  const scans = [];
  for (const [name, rel] of Object.entries(SOURCE_FILES)) {
    const s = scanFile(rel);
    if (!s) {
      console.warn(`⚠️  ${name}: 파일 없음 (${rel})`);
      continue;
    }
    scans.push({ component: name, ...s });
    if (VERBOSE) {
      console.log(`  ${name.padEnd(22)} ${String(s.lineCount).padStart(5)}L  onClick=${String(s.onClickCount).padStart(3)}  <button>=${String(s.buttonCount).padStart(3)}  labels=${s.labels.length}`);
    }
  }

  // DOM 팝업 step 목록 평탄화
  const dom_popups = [];
  for (const [component, steps] of Object.entries(POPUP_SEED)) {
    const rel = SOURCE_FILES[component];
    for (const step of steps) {
      dom_popups.push({
        layer: 'dom',
        component,
        source_file: rel,
        ...step,
      });
    }
  }

  const canvas_elements = CANVAS_SEED.map((s) => ({ layer: 'canvas', component: 'VirtualOffice', source_file: SOURCE_FILES.VirtualOffice, ...s }));
  const overcook_suspects = [
    // 수작업 씨드 — 코드 탐색 중 발견한 의심 패턴
    { pattern: 'CronDetailPopup 내 ActionBar + CeoActionRow + CronControlBar 3개 행이 유사 기능 분산 가능성', files: [SOURCE_FILES.CronDetailPopup], severity: 'low' },
    ...detectOvercooks(scans),
  ];

  const intent = loadIntent();
  const inventory = {
    generated_at: new Date().toISOString(),
    board_root: BOARD_ROOT,
    source_files: SOURCE_FILES,
    project_intent: intent,
    scan_summary: scans.map(({ component, relPath, lineCount, onClickCount, buttonCount, roleButton }) => ({
      component, relPath, lineCount, onClickCount, buttonCount, roleButton,
    })),
    canvas_elements,
    dom_popups,
    overcook_suspects,
    totals: {
      canvas: canvas_elements.length,
      dom: dom_popups.length,
      overall: canvas_elements.length + dom_popups.length,
    },
  };

  writeFileSync(OUT_PATH, JSON.stringify(inventory, null, 2));

  console.log('📊 인벤토리 요약');
  console.log(`   Canvas step :  ${inventory.totals.canvas}`);
  console.log(`   DOM popup step: ${inventory.totals.dom}`);
  console.log(`   합계         : ${inventory.totals.overall}`);
  console.log(`   오버쿡 의심  : ${inventory.overcook_suspects.length}`);
  console.log(`\n✅ 저장: ${OUT_PATH}`);
}

main();
