#!/usr/bin/env node
/**
 * weekly-roi-aggregator.mjs
 * 주간 태스크 ROI 집계 스크립트 (Enhanced)
 *
 * 메트릭:
 * 1. Insights 생성 건수 (태스크별)
 * 2. Decisions 연결 건수 (태스크별)
 * 3. Context-Bus 참조 횟수 (태스크별)
 *
 * ROI = 가치점수 / 실행횟수 (태스크별)
 */

import fs from "fs";
import path from "path";
import { execSync } from "child_process";

// 주차 계산 개선
function getWeekString(date = new Date()) {
  const year = date.getFullYear();
  const start = new Date(year, 0, 1);
  const days = Math.floor((date - start) / (24 * 60 * 60 * 1000));
  const week = Math.ceil((days + start.getDay() + 1) / 7);
  return `${year}-W${week.toString().padStart(2, '0')}`;
}

const week = process.argv[2] || getWeekString();
const homeDir = process.env.HOME;
const roiDir = path.join(homeDir, 'jarvis/runtime/rag/roi-reports');
const resultsDir = path.join(homeDir, 'jarvis/runtime/results');
const logsDir = path.join(homeDir, 'jarvis/runtime/logs');

// 유틸리티: 파일 읽기 (에러 무시)
function readFileIfExists(filePath) {
  try {
    return fs.readFileSync(filePath, 'utf8');
  } catch {
    return '';
  }
}

// 날짜 범위 확인 (해당 주차에 해당하는지)
function isInWeek(dateStr, targetWeek) {
  try {
    const date = new Date(dateStr);
    return getWeekString(date) === targetWeek;
  } catch {
    return false;
  }
}

// 1. 태스크별 insights 생성 건수 수집
function collectInsightsByTask() {
  const taskInsights = new Map();

  try {
    const insightsDir = path.join(homeDir, 'jarvis/runtime/rag/auto-insights');
    if (!fs.existsSync(insightsDir)) return taskInsights;

    const files = fs.readdirSync(insightsDir);

    for (const file of files) {
      if (!file.endsWith('.md')) continue;

      const filePath = path.join(insightsDir, file);
      const content = readFileIfExists(filePath);

      // frontmatter에서 source_task 추출 시도
      const frontmatterMatch = content.match(/^---\n([\s\S]*?)\n---/);
      if (frontmatterMatch) {
        const frontmatter = frontmatterMatch[1];
        const sourceTaskMatch = frontmatter.match(/source_task:\s*(.+)/);
        const dateMatch = frontmatter.match(/date:\s*(.+)/);

        if (sourceTaskMatch && dateMatch && isInWeek(dateMatch[1], week)) {
          const task = sourceTaskMatch[1].trim();
          taskInsights.set(task, (taskInsights.get(task) || 0) + 1);
        }
      } else {
        // 날짜가 파일명에 있는 경우 (legacy)
        const dateMatch = file.match(/(\d{4}-\d{2}-\d{2})/);
        if (dateMatch && isInWeek(dateMatch[1], week)) {
          taskInsights.set('unknown', (taskInsights.get('unknown') || 0) + 1);
        }
      }
    }
  } catch (e) {
    console.error('Error collecting insights:', e.message);
  }

  return taskInsights;
}

// 2. 태스크별 decisions 연결 건수 수집
function collectDecisionsByTask() {
  const taskDecisions = new Map();

  try {
    const decisionsFile = path.join(homeDir, `jarvis/runtime/rag/decisions-${week}.md`);
    if (!fs.existsSync(decisionsFile)) return taskDecisions;

    const content = readFileIfExists(decisionsFile);
    const lines = content.split('\n');

    for (const line of lines) {
      // 결정 라인 패턴: | 날짜 | [태스크] 결정내용 | 이유 |
      const decisionMatch = line.match(/^\|\s*\d{4}-\d{2}-\d{2}\s*\|\s*\[([^\]]+)\]/);
      if (decisionMatch) {
        const task = decisionMatch[1].trim();
        taskDecisions.set(task, (taskDecisions.get(task) || 0) + 1);
      }
    }
  } catch (e) {
    console.error('Error collecting decisions:', e.message);
  }

  return taskDecisions;
}

// 3. 태스크별 context-bus 참조 및 실행 횟수 수집
function collectTaskMetrics() {
  const taskRuns = new Map();
  const taskContextRefs = new Map();

  try {
    const cronLog = path.join(logsDir, 'cron.log');
    const content = readFileIfExists(cronLog);
    const lines = content.split('\n');

    for (const line of lines) {
      // 태스크 실행 패턴: [날짜 시간] [태스크명] SUCCESS
      const taskMatch = line.match(/^\[(\d{4}-\d{2}-\d{2})\s+[\d:]+\]\s+\[([^\]]+)\]\s+(SUCCESS|START)/);
      if (taskMatch) {
        const date = taskMatch[1];
        const task = taskMatch[2];
        const status = taskMatch[3];

        if (isInWeek(date, week)) {
          if (status === 'SUCCESS') {
            taskRuns.set(task, (taskRuns.get(task) || 0) + 1);
          }

          // context-bus 참조 체크 (간접적 - context 관련 태스크들)
          if (task.includes('context') || task.includes('sync') || task.includes('session')) {
            taskContextRefs.set(task, (taskContextRefs.get(task) || 0) + 1);
          }
        }
      }
    }
  } catch (e) {
    console.error('Error collecting task metrics:', e.message);
  }

  return { taskRuns, taskContextRefs };
}

// 태스크별 ROI 계산
function calculateTaskROI(insights, decisions, contextRefs, runs) {
  const valueScore = (insights * 3) + (decisions * 2) + (contextRefs * 1);
  const roi = runs > 0 ? Math.round((valueScore / runs) * 100) / 100 : 0;

  let grade = 'LOW';
  if (roi > 10) grade = 'HIGH';
  else if (roi >= 5) grade = 'MEDIUM';

  return { valueScore, roi, grade, runs, insights, decisions, contextRefs };
}

// 모든 태스크 통합
function getAllTasks(...maps) {
  const allTasks = new Set();
  for (const map of maps) {
    for (const task of map.keys()) {
      allTasks.add(task);
    }
  }
  return Array.from(allTasks).sort();
}

// 메인 실행
function main() {
  const taskInsights = collectInsightsByTask();
  const taskDecisions = collectDecisionsByTask();
  const { taskRuns, taskContextRefs } = collectTaskMetrics();

  // 모든 태스크 목록 수집
  const allTasks = getAllTasks(taskInsights, taskDecisions, taskRuns, taskContextRefs);

  // 태스크별 ROI 계산
  const taskROIData = [];
  let totalValueScore = 0;
  let totalRuns = 0;

  for (const task of allTasks) {
    const insights = taskInsights.get(task) || 0;
    const decisions = taskDecisions.get(task) || 0;
    const contextRefs = taskContextRefs.get(task) || 0;
    const runs = taskRuns.get(task) || 0;

    if (runs > 0 || insights > 0 || decisions > 0 || contextRefs > 0) {
      const roiData = calculateTaskROI(insights, decisions, contextRefs, runs);
      taskROIData.push({ task, ...roiData });
      totalValueScore += roiData.valueScore;
      totalRuns += runs;
    }
  }

  // ROI 순으로 정렬
  taskROIData.sort((a, b) => b.roi - a.roi);

  // 전체 ROI 계산
  const totalROI = totalRuns > 0 ? Math.round((totalValueScore / totalRuns) * 100) / 100 : 0;
  let totalGrade = 'LOW';
  if (totalROI > 10) totalGrade = 'HIGH';
  else if (totalROI >= 5) totalGrade = 'MEDIUM';

  // 리포트 생성
  let report = `# 주간 ROI 리포트 — ${week}

## 📊 전체 요약

| 메트릭 | 값 |
|--------|-----|
| 총 가치점수 | ${totalValueScore} |
| 총 실행횟수 | ${totalRuns}회 |
| **전체 ROI** | **${totalROI}** |
| **등급** | **${totalGrade}** |

## 🏆 태스크별 ROI 순위

| 순위 | 태스크 | ROI | 등급 | 가치점수 | 실행횟수 | 상세 |
|------|---------|-----|------|----------|-----------|------|
`;

  // 상위 태스크들 추가
  taskROIData.forEach((data, idx) => {
    const { task, roi, grade, valueScore, runs, insights, decisions, contextRefs } = data;
    const details = `I:${insights} D:${decisions} C:${contextRefs}`;
    report += `| ${idx + 1} | ${task} | ${roi} | ${grade} | ${valueScore} | ${runs} | ${details} |\n`;
  });

  report += `

## 📈 상세 분석

### 고가치 태스크 (ROI ≥ 10)
${taskROIData.filter(t => t.grade === 'HIGH').map(t => `- **${t.task}**: ROI ${t.roi} (가치점수 ${t.valueScore} / 실행 ${t.runs}회)`).join('\n') || '없음'}

### 중간 가치 태스크 (ROI 5-10)
${taskROIData.filter(t => t.grade === 'MEDIUM').map(t => `- **${t.task}**: ROI ${t.roi} (가치점수 ${t.valueScore} / 실행 ${t.runs}회)`).join('\n') || '없음'}

### 저가치 태스크 (ROI < 5)
${taskROIData.filter(t => t.grade === 'LOW').map(t => `- **${t.task}**: ROI ${t.roi} (가치점수 ${t.valueScore} / 실행 ${t.runs}회)`).join('\n') || '없음'}

## 💡 권장사항

${totalGrade === 'HIGH' ? '✅ **우수**: 전체적으로 높은 가치를 생성하고 있습니다. 현재 설정을 유지하세요.' :
  totalGrade === 'MEDIUM' ? '⚠️ **보통**: 일부 태스크의 최적화 여지가 있습니다. 저가치 태스크를 검토하세요.' :
  '❌ **개선필요**: 다수의 저가치 태스크가 발견되었습니다. 빈도 조정이나 비활성화를 검토하세요.'}

### 조치 후보
${taskROIData.filter(t => t.grade === 'LOW' && t.runs > 10).map(t => `- **${t.task}**: 실행 빈도 감소 고려 (현재 주 ${t.runs}회 → 권장 주 ${Math.max(1, Math.floor(t.runs / 2))}회)`).join('\n') || '조치가 필요한 태스크가 없습니다.'}

---
*생성: ${new Date().toISOString()} | 분석대상: ${allTasks.length}개 태스크*
`;

  // 디렉토리 생성
  if (!fs.existsSync(roiDir)) {
    fs.mkdirSync(roiDir, { recursive: true });
  }

  // 리포트 저장
  const reportPath = path.join(roiDir, `roi-report-${week}.md`);
  fs.writeFileSync(reportPath, report);

  console.log(report);
  console.log(`\n📁 리포트 저장: ${reportPath}`);
}

main();