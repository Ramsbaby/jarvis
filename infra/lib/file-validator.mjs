#!/usr/bin/env node
/**
 * file-validator.mjs — Node.js 환경용 파일 검증 라이브러리
 *
 * 역할: Node.js 스크립트(mistake-extractor.mjs, artifact-uploader.js 등)에서
 *       파일 저장 후 경로, 크기, 내용을 자동으로 검증
 *
 * 사용 예:
 *   import { validateFile } from './file-validator.mjs';
 *   await validateFile('/path/to/file.md', 'ko');
 *   // or
 *   import { execSync } from 'child_process';
 *   execSync(`node /path/to/file-validator.mjs /path/to/file.md ko`);
 *
 * Exit codes:
 *   0   검증 성공
 *   1   검증 실패
 */

import { existsSync, statSync, readFileSync } from 'node:fs';
import { basename } from 'node:path';
import { spawnSync } from 'node:child_process';

// ────────────────────────────────────────────────────────────────────────────
// 설정
// ────────────────────────────────────────────────────────────────────────────

const MIN_FILE_SIZE = 10;  // bytes
const DEBUG = process.env.JARVIS_VALIDATOR_DEBUG === '1';

// 색상 (ANSI escape codes)
const RED = '\x1b[0;31m';
const GREEN = '\x1b[0;32m';
const YELLOW = '\x1b[1;33m';
const BLUE = '\x1b[0;34m';
const NC = '\x1b[0m';

// ────────────────────────────────────────────────────────────────────────────
// 로깅 함수
// ────────────────────────────────────────────────────────────────────────────

function log(level, msg) {
  const time = new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Seoul' });
  const prefix = `[${time}]`;

  switch (level) {
    case 'ERROR':
      console.error(`${RED}[ERROR]${NC} ${msg}`);
      break;
    case 'WARN':
      console.error(`${YELLOW}[WARN]${NC} ${msg}`);
      break;
    case 'INFO':
      console.error(`${GREEN}[INFO]${NC} ${msg}`);
      break;
    case 'DEBUG':
      if (DEBUG) {
        console.error(`${BLUE}[DEBUG]${NC} ${msg}`);
      }
      break;
  }
}

// ────────────────────────────────────────────────────────────────────────────
// 파일 검증 함수들
// ────────────────────────────────────────────────────────────────────────────

function validatePathExists(filePath) {
  log('DEBUG', `Checking if path exists: ${filePath}`);

  if (!existsSync(filePath)) {
    log('ERROR', `File path does not exist: ${filePath}`);
    return false;
  }

  const stat = statSync(filePath);
  if (!stat.isFile()) {
    log('ERROR', `Path exists but is not a regular file: ${filePath}`);
    return false;
  }

  log('INFO', `✓ File path exists: ${filePath}`);
  return true;
}

function validateFileSize(filePath) {
  const stat = statSync(filePath);
  const size = stat.size;

  log('DEBUG', `File size: ${size} bytes`);

  if (size < MIN_FILE_SIZE) {
    log('ERROR', `File size too small (${size} bytes, minimum: ${MIN_FILE_SIZE} bytes): ${filePath}`);
    return false;
  }

  log('INFO', `✓ File size valid: ${size} bytes`);
  return true;
}

function calculateLangRatio(filePath, content) {
  // 한글 범위: AC00-D7A3 (완성형 한글)
  const koPattern = /[\uac00-\ud7a3]/g;
  const enPattern = /[a-zA-Z]/g;
  const digitPattern = /[0-9]/g;

  const koCount = (content.match(koPattern) || []).length;
  const enCount = (content.match(enPattern) || []).length;
  const digitCount = (content.match(digitPattern) || []).length;
  const total = content.length;

  if (total === 0) {
    return { koRatio: 0, enRatio: 0, koCount: 0, enCount: 0, total: 0 };
  }

  const koRatio = Math.round(koCount * 100 / total);
  const enRatio = Math.round(enCount * 100 / total);

  return { koRatio, enRatio, koCount, enCount, total };
}

function validateLangRatio(filePath, expectLang, content) {
  if (!expectLang) {
    log('DEBUG', 'No language expectation specified, skipping language validation');
    return true;
  }

  const ratio = calculateLangRatio(filePath, content);
  const { koRatio, enRatio } = ratio;

  log('DEBUG', `Language ratio - Korean: ${koRatio}%, English: ${enRatio}%`);

  if (expectLang === 'ko') {
    if (koRatio < 50) {
      log('ERROR', `Expected Korean-dominant content but got: Korean ${koRatio}%, English ${enRatio}%`);
      return false;
    }
    log('INFO', `✓ Language validation: Korean dominant (${koRatio}%)`);
    return true;
  }

  if (expectLang === 'en') {
    if (enRatio < 50) {
      log('ERROR', `Expected English-dominant content but got: Korean ${koRatio}%, English ${enRatio}%`);
      return false;
    }
    log('INFO', `✓ Language validation: English dominant (${enRatio}%)`);
    return true;
  }

  // 범위 검증 (예: "ko:50", "en:70")
  const match = expectLang.match(/^(ko|en):(\d+)$/);
  if (match) {
    const lang = match[1];
    const minRatio = parseInt(match[2], 10);

    if (lang === 'ko' && koRatio < minRatio) {
      log('ERROR', `Expected Korean ratio >= ${minRatio}%, but got ${koRatio}%`);
      return false;
    }

    if (lang === 'en' && enRatio < minRatio) {
      log('ERROR', `Expected English ratio >= ${minRatio}%, but got ${enRatio}%`);
      return false;
    }

    log('INFO', `✓ Language validation: ${lang} >= ${minRatio}% (actual: ${lang === 'ko' ? koRatio : enRatio}%)`);
    return true;
  }

  log('WARN', `Unknown language expectation format: ${expectLang} (supported: ko, en, ko:N, en:N)`);
  return true;
}

function validateFile(filePath, expectLang = '') {
  log('INFO', `Starting file validation for: ${filePath}`);

  // 경로 존재 확인
  if (!validatePathExists(filePath)) {
    return false;
  }

  // 파일 크기 검증
  if (!validateFileSize(filePath)) {
    return false;
  }

  // 언어 비율 검증 (있으면)
  if (expectLang) {
    try {
      const content = readFileSync(filePath, 'utf-8');
      if (!validateLangRatio(filePath, expectLang, content)) {
        return false;
      }
    } catch (e) {
      log('WARN', `Could not read file content for language validation: ${e.message}`);
      // 읽기 오류는 warning만 하고 통과
    }
  }

  log('INFO', '✅ All validations passed for: ' + filePath);
  return true;
}

// ────────────────────────────────────────────────────────────────────────────
// 모듈 내보내기
// ────────────────────────────────────────────────────────────────────────────

export { validateFile, validatePathExists, validateFileSize, validateLangRatio };

// ────────────────────────────────────────────────────────────────────────────
// CLI 엔트리포인트
// ────────────────────────────────────────────────────────────────────────────

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2);

  if (args.length === 0) {
    console.error(`Usage: file-validator.mjs <file_path> [expect_lang]

Options:
  expect_lang   Validate language ratio (ko, en, ko:50, en:70, etc.)

Examples:
  node file-validator.mjs /path/to/file.pdf
  node file-validator.mjs /path/to/file.pdf ko
  node file-validator.mjs /path/to/file.pdf en

Exit codes:
  0   All validations passed
  1   Validation failed`);
    process.exit(1);
  }

  const filePath = args[0];
  const expectLang = args[1] || '';

  const success = validateFile(filePath, expectLang);
  process.exit(success ? 0 : 1);
}
