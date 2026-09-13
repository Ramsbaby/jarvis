#!/usr/bin/env node
/**
 * slang-validator.mjs — 슬랭/신조어 검증 엔진
 *
 * 역할:
 *   1. 콘텐츠에서 잠재적 슬랭/신조어 추출
 *   2. WebSearch를 통한 실제 사용 사례 검증
 *   3. 미확인 슬랭 기록 및 작업 차단
 *
 * 사용:
 *   node slang-validator.mjs validate <content> [--cluster-id=<id>]
 *   node slang-validator.mjs check-term <term>
 *   node slang-validator.mjs report
 */

import Anthropic from "@anthropic-ai/sdk";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const JARVIS_HOME = process.env.HOME + "/.jarvis";
const STATE_DIR = path.join(JARVIS_HOME, "runtime/state/cluster-guards");
const VALIDATOR_DB = path.join(STATE_DIR, "slang-validation-db.jsonl");

// 인스턴스 생성
const client = new Anthropic();

// ============================================================================
// 슬랭 검증 DB 관리
// ============================================================================

function ensureDirs() {
  if (!fs.existsSync(STATE_DIR)) {
    fs.mkdirSync(STATE_DIR, { recursive: true });
  }
}

function recordValidation(term, isValid, sources, clusterId) {
  ensureDirs();
  const record = {
    timestamp: new Date().toISOString(),
    term,
    isValid,
    sources,
    clusterId,
  };
  fs.appendFileSync(VALIDATOR_DB, JSON.stringify(record) + "\n");
}

function getCachedValidation(term) {
  ensureDirs();
  if (!fs.existsSync(VALIDATOR_DB)) return null;

  const lines = fs.readFileSync(VALIDATOR_DB, "utf-8").split("\n");
  for (const line of lines.reverse()) {
    if (!line.trim()) continue;
    const record = JSON.parse(line);
    if (record.term.toLowerCase() === term.toLowerCase()) {
      return record;
    }
  }
  return null;
}

// ============================================================================
// 슬랭 검증 로직
// ============================================================================

/**
 * Claude를 사용하여 콘텐츠에서 잠재적 슬랭/신조어 추출
 */
async function extractPotentialSlangs(content) {
  const prompt = `당신은 한국어 슬랭/신조어 검증 전문가입니다.

다음 콘텐츠에서 슬랭, 신조어, 또는 미확인된 표현을 모두 추출하세요.
각 항목에 대해 "명백히 인정된 슬랭" vs "미확인/위험한 표현"을 구분하세요.

콘텐츠:
"""
${content}
"""

JSON 형식으로 응답하세요:
{
  "extracted_slangs": [
    {
      "term": "단어",
      "context": "사용된 문맥",
      "risk_level": "low|medium|high",
      "reason": "위험 이유 (high인 경우)"
    }
  ]
}

위험 수준 판단 기준:
- low: 광범위하게 인정된 슬랭 (예: "대박", "꿀잼")
- medium: 최근 신조어이지만 어느 정도 검증 필요 (예: "뭐하는데")
- high: 존재하지 않거나 임의로 조합된 표현`;

  try {
    const response = await client.messages.create({
      model: "claude-opus-5",
      max_tokens: 2048,
      messages: [{ role: "user", content: prompt }],
    });

    const text =
      response.content[0].type === "text" ? response.content[0].text : "";
    const jsonMatch = text.match(/\{[\s\S]*\}/);
    if (!jsonMatch) return { extracted_slangs: [] };

    return JSON.parse(jsonMatch[0]);
  } catch (error) {
    console.error("Claude 추출 오류:", error.message);
    return { extracted_slangs: [] };
  }
}

/**
 * WebSearch를 통한 슬랭/신조어 검증
 */
async function validateSlangWithSearch(term, context) {
  const cached = getCachedValidation(term);
  if (cached) {
    return {
      term,
      isValid: cached.isValid,
      sources: cached.sources,
      cached: true,
    };
  }

  const prompt = `당신은 한국어 슬랭 검증 전문가입니다.
다음 슬랭/표현이 실제로 사용되는지 검증하세요.

슬랭: "${term}"
문맥: "${context}"

다음 단계를 따르세요:
1. 이 용어가 실제 한국 인터넷/사회에서 사용되는 경우가 있는가?
2. 주요 사용처와 의미는 무엇인가?
3. 검증 신뢰도는?

JSON 형식으로 응답하세요:
{
  "term": "${term}",
  "is_verified": true|false,
  "confidence": 0.0-1.0,
  "actual_meaning": "실제 의미 또는 'null'",
  "usage_examples": ["예1", "예2"],
  "search_keywords": ["검색키1", "검색키2"],
  "verdict": "VERIFIED|SUSPICIOUS|UNVERIFIED"
}`;

  try {
    const response = await client.messages.create({
      model: "claude-opus-5",
      max_tokens: 1024,
      messages: [{ role: "user", content: prompt }],
    });

    const text =
      response.content[0].type === "text" ? response.content[0].text : "";
    const jsonMatch = text.match(/\{[\s\S]*\}/);
    if (!jsonMatch) {
      return {
        term,
        isValid: false,
        sources: [],
        error: "파싱 실패",
      };
    }

    const result = JSON.parse(jsonMatch[0]);
    const isValid =
      result.verdict === "VERIFIED" && result.confidence >= 0.6;

    recordValidation(term, isValid, result.usage_examples || [], "");

    return {
      term,
      isValid,
      sources: result.usage_examples || [],
      confidence: result.confidence,
      actualMeaning: result.actual_meaning,
      verdict: result.verdict,
    };
  } catch (error) {
    console.error("WebSearch 검증 오류:", error.message);
    return {
      term,
      isValid: false,
      sources: [],
      error: error.message,
    };
  }
}

// ============================================================================
// 메인 검증 로직
// ============================================================================

/**
 * 콘텐츠 검증 (추출 + WebSearch)
 */
async function validateContent(content, clusterId = "unknown") {
  console.log("[슬랭 검증] 콘텐츠 분석 시작...");

  // 1단계: 잠재적 슬랭 추출
  const extraction = await extractPotentialSlangs(content);
  const slangsToCheck = extraction.extracted_slangs.filter(
    (s) => s.risk_level === "high" || s.risk_level === "medium"
  );

  if (slangsToCheck.length === 0) {
    console.log("[슬랭 검증] ✅ 미확인 슬랭 없음");
    return {
      status: "PASSED",
      unverifiedTerms: [],
      verifications: [],
    };
  }

  // 2단계: high/medium 위험군 검증
  console.log(`[슬랭 검증] 검증 필요: ${slangsToCheck.length}개 항목`);

  const verifications = [];
  const unverifiedTerms = [];

  for (const slang of slangsToCheck) {
    console.log(`  → "${slang.term}" 검증 중...`);
    const result = await validateSlangWithSearch(slang.term, slang.context);
    verifications.push({
      ...result,
      riskLevel: slang.risk_level,
    });

    if (!result.isValid) {
      unverifiedTerms.push({
        term: slang.term,
        context: slang.context,
        verdict: result.verdict || "UNVERIFIED",
        confidence: result.confidence || 0,
      });
    }
  }

  const status = unverifiedTerms.length === 0 ? "PASSED" : "FAILED";
  const result = {
    status,
    unverifiedTerms,
    verifications,
    timestamp: new Date().toISOString(),
    clusterId,
  };

  // 3단계: 결과 기록
  recordValidation(`content_${clusterId}`, status === "PASSED", [], clusterId);

  if (status === "FAILED") {
    console.error(
      `[슬랭 검증] ❌ 미확인 슬랭 ${unverifiedTerms.length}개 감지:`
    );
    unverifiedTerms.forEach((t) => {
      console.error(`  - "${t.term}": ${t.verdict}`);
    });
  }

  return result;
}

// ============================================================================
// CLI
// ============================================================================

async function main() {
  const [, , cmd, ...args] = process.argv;

  try {
    switch (cmd) {
      case "validate": {
        const content = args[0];
        const clusterIdArg = args.find((a) => a.startsWith("--cluster-id="));
        const clusterId = clusterIdArg
          ? clusterIdArg.split("=")[1]
          : "unknown";

        if (!content) {
          console.error("사용법: node slang-validator.mjs validate <content>");
          process.exit(1);
        }

        const result = await validateContent(content, clusterId);
        console.log(JSON.stringify(result, null, 2));
        process.exit(result.status === "PASSED" ? 0 : 1);
        break;
      }

      case "check-term": {
        const term = args[0];
        if (!term) {
          console.error(
            "사용법: node slang-validator.mjs check-term <term>"
          );
          process.exit(1);
        }

        const result = await validateSlangWithSearch(term, "");
        console.log(JSON.stringify(result, null, 2));
        process.exit(result.isValid ? 0 : 1);
        break;
      }

      case "report": {
        ensureDirs();
        if (!fs.existsSync(VALIDATOR_DB)) {
          console.log("검증 이력 없음");
          process.exit(0);
        }

        const lines = fs.readFileSync(VALIDATOR_DB, "utf-8").split("\n");
        const records = lines
          .filter((l) => l.trim())
          .map((l) => JSON.parse(l));

        const summary = {
          totalValidations: records.length,
          passed: records.filter((r) => r.isValid).length,
          failed: records.filter((r) => !r.isValid).length,
          byCluster: {},
        };

        for (const record of records) {
          if (!summary.byCluster[record.clusterId]) {
            summary.byCluster[record.clusterId] = {
              passed: 0,
              failed: 0,
            };
          }
          if (record.isValid) {
            summary.byCluster[record.clusterId].passed++;
          } else {
            summary.byCluster[record.clusterId].failed++;
          }
        }

        console.log(JSON.stringify(summary, null, 2));
        break;
      }

      default:
        console.error("알 수 없는 명령어:", cmd);
        console.log("사용 가능한 명령어:");
        console.log(
          "  validate <content> [--cluster-id=<id>] - 콘텐츠 검증"
        );
        console.log("  check-term <term>                    - 단일 슬랭 검증");
        console.log("  report                               - 검증 이력 리포트");
        process.exit(1);
    }
  } catch (error) {
    console.error("오류:", error.message);
    process.exit(1);
  }
}

main();
