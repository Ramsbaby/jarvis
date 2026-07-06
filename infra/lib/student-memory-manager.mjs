#!/usr/bin/env node
// student-memory-manager.mjs — 학생별 세션 이력 SSoT 메모리 관리 (cl-a3200445ee1623e8)
//
// 목적: 세션 간 학생별 요청·이력을 자동 저장하고 세션 시작 시 자동 주입
//       - 학생 메타데이터 (이름, 레벨, 선호도 등)
//       - 세션별 상호작용 이력 (요청 내용, 응답, 피드백)
//       - 특정 조건/규칙/제약 (자격증 난이도, 학습 모드 등)
//
// 사용법:
//   node student-memory-manager.mjs --action save --student-id <id> --data <json>
//   node student-memory-manager.mjs --action load --student-id <id>
//   node student-memory-manager.mjs --action list
//   node student-memory-manager.mjs --action init-template --student-id <id>
//
// SSoT 경로:
//   ~/jarvis/runtime/state/student-memory/{student-id}.json
//
// 스키마:
//   {
//     "student_id": "marco|boram|...",
//     "name": "사용자명",
//     "level": "beginner|intermediate|advanced",
//     "language": "ko|en",
//     "created_at": "ISO8601",
//     "updated_at": "ISO8601",
//     "metadata": { ... },
//     "sessions": [ { timestamp, interactions: [...] } ],
//     "preferences": { "certification_min_level": "intermediate", ... },
//     "constraints": [ "rule_id_1", "rule_id_2", ... ],
//     "last_session_summary": "string"
//   }

import {
  readFileSync, writeFileSync, existsSync,
  mkdirSync, readdirSync,
} from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';

const HOME = homedir();
const BOT_HOME = process.env.BOT_HOME || join(HOME, 'jarvis', 'runtime');
const MEMORY_DIR = join(BOT_HOME, 'state', 'student-memory');

function nowKST() {
  return new Date(Date.now() + 9 * 3600e3).toISOString().replace(/\.\d+Z$/, '+09:00');
}

function log(msg) {
  console.error(`[${nowKST()}] [student-memory] ${msg}`);
}

// SSoT 파일 경로
function memoryFilePath(studentId) {
  return join(MEMORY_DIR, `${studentId}.json`);
}

// 메모리 파일 로드 또는 빈 템플릿 반환
function loadMemory(studentId) {
  mkdirSync(MEMORY_DIR, { recursive: true });
  const path = memoryFilePath(studentId);
  if (existsSync(path)) {
    try {
      return JSON.parse(readFileSync(path, 'utf-8'));
    } catch (e) {
      log(`WARN: 메모리 파일 파싱 실패 (${studentId}): ${e.message}`);
      return null;
    }
  }
  return null;
}

// 메모리 파일 저장
function saveMemory(studentId, data) {
  mkdirSync(MEMORY_DIR, { recursive: true });
  data.updated_at = nowKST();
  const path = memoryFilePath(studentId);
  writeFileSync(path, JSON.stringify(data, null, 2), 'utf-8');
  log(`메모리 저장 완료: ${studentId}`);
}

// 초기 템플릿 생성
function initTemplate(studentId) {
  mkdirSync(MEMORY_DIR, { recursive: true });
  const template = {
    student_id: studentId,
    name: '',
    level: 'beginner',
    language: 'ko',
    created_at: nowKST(),
    updated_at: nowKST(),
    metadata: {
      timezone: 'Asia/Seoul',
      learning_style: 'interactive',
    },
    sessions: [],
    preferences: {
      certification_min_level: 'intermediate',
      format_rules_strict: true,
      max_argument_order_errors: 0,
    },
    constraints: [],
    last_session_summary: '',
  };
  const path = memoryFilePath(studentId);
  writeFileSync(path, JSON.stringify(template, null, 2), 'utf-8');
  log(`템플릿 생성 완료: ${studentId}`);
  return template;
}

// 세션 추가
function addSession(studentId, interaction) {
  let memory = loadMemory(studentId);
  if (!memory) {
    log(`WARN: ${studentId} 메모리 없음 — 템플릿 생성 후 재시도`);
    memory = initTemplate(studentId);
  }
  if (!memory.sessions) memory.sessions = [];
  memory.sessions.push({
    timestamp: nowKST(),
    interactions: Array.isArray(interaction) ? interaction : [interaction],
  });
  // 최근 100개 세션만 유지 (메모리 최적화)
  if (memory.sessions.length > 100) {
    memory.sessions = memory.sessions.slice(-100);
  }
  saveMemory(studentId, memory);
}

// 메모리 조회
function getMemory(studentId) {
  const memory = loadMemory(studentId);
  if (!memory) {
    console.error(`학생 메모리 없음: ${studentId}`);
    process.exit(1);
  }
  console.log(JSON.stringify(memory, null, 2));
}

// 전체 목록
function listMemories() {
  mkdirSync(MEMORY_DIR, { recursive: true });
  const files = readdirSync(MEMORY_DIR).filter((f) => f.endsWith('.json'));
  const list = files.map((f) => {
    const id = f.replace('.json', '');
    const mem = loadMemory(id);
    return {
      student_id: id,
      name: mem?.name || '(미설정)',
      level: mem?.level || 'unknown',
      sessions: mem?.sessions?.length || 0,
      updated_at: mem?.updated_at || 'unknown',
    };
  });
  console.log(JSON.stringify(list, null, 2));
}

// 메모리 갱신 (메타데이터 업데이트)
function updateMetadata(studentId, metadata) {
  let memory = loadMemory(studentId);
  if (!memory) {
    log(`WARN: ${studentId} 메모리 없음 — 템플릿 생성`);
    memory = initTemplate(studentId);
  }
  memory.metadata = { ...memory.metadata, ...metadata };
  saveMemory(studentId, memory);
}

// 제약 추가
function addConstraint(studentId, constraintId) {
  let memory = loadMemory(studentId);
  if (!memory) memory = initTemplate(studentId);
  if (!memory.constraints) memory.constraints = [];
  if (!memory.constraints.includes(constraintId)) {
    memory.constraints.push(constraintId);
    saveMemory(studentId, memory);
    log(`제약 추가: ${studentId} += ${constraintId}`);
  }
}

// CLI 파싱
const args = process.argv.slice(2);
const action = args[0];
const studentIdIdx = args.indexOf('--student-id');
const studentId = args.find((a) => a.startsWith('--student-id='))?.split('=')[1] ||
                  (studentIdIdx >= 0 ? args[studentIdIdx + 1] : undefined);

switch (action) {
  case 'save':
    {
      const dataIdx = args.indexOf('--data');
      const jsonStr = args[dataIdx + 1] || args.find((a) => a.startsWith('--data='))?.split('=')[1];
      if (!studentId || !jsonStr) {
        console.error('필수: --student-id <id> --data <json>');
        process.exit(1);
      }
      const data = JSON.parse(jsonStr);
      let memory = loadMemory(studentId) || initTemplate(studentId);
      memory = { ...memory, ...data };
      saveMemory(studentId, memory);
    }
    break;
  case 'load':
    if (!studentId) {
      console.error('필수: --student-id <id>');
      process.exit(1);
    }
    getMemory(studentId);
    break;
  case 'list':
    listMemories();
    break;
  case 'init-template':
    if (!studentId) {
      console.error('필수: --student-id <id>');
      process.exit(1);
    }
    initTemplate(studentId);
    break;
  case 'add-session':
    {
      if (!studentId) {
        console.error('필수: --student-id <id>');
        process.exit(1);
      }
      const dataIdx = args.indexOf('--interaction');
      const interaction = args[dataIdx + 1] || args.find((a) => a.startsWith('--interaction='))?.split('=')[1];
      if (!interaction) {
        console.error('필수: --interaction <json>');
        process.exit(1);
      }
      addSession(studentId, JSON.parse(interaction));
    }
    break;
  case 'add-constraint':
    {
      if (!studentId) {
        console.error('필수: --student-id <id>');
        process.exit(1);
      }
      const ruleId = args.find((a) => a.startsWith('--rule-id'))?.split('=')[1] ||
                     args[args.indexOf('--rule-id') + 1];
      if (!ruleId) {
        console.error('필수: --rule-id <id>');
        process.exit(1);
      }
      addConstraint(studentId, ruleId);
    }
    break;
  case 'update-metadata':
    {
      if (!studentId) {
        console.error('필수: --student-id <id>');
        process.exit(1);
      }
      const dataIdx = args.indexOf('--metadata');
      const metaStr = args[dataIdx + 1] || args.find((a) => a.startsWith('--metadata='))?.split('=')[1];
      if (!metaStr) {
        console.error('필수: --metadata <json>');
        process.exit(1);
      }
      updateMetadata(studentId, JSON.parse(metaStr));
    }
    break;
  default:
    console.error(`미지원 action: ${action}`);
    console.error('사용법: node student-memory-manager.mjs [save|load|list|init-template|add-session|add-constraint|update-metadata] --student-id <id> [--data|--interaction|--rule-id|--metadata <json>]');
    process.exit(1);
}
