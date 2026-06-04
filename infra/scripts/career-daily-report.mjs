#!/usr/bin/env node

/**
 * career-daily-report.mjs
 *
 * 채용공고 일일 현황 보고서를 생성하여 #jarvis-career 채널에 전송
 *
 * 사용: node career-daily-report.mjs
 */

import { readFileSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
import { discordSend } from '../lib/discord-notify.mjs';

const STATE_FILE = join(homedir(), 'jarvis/runtime/state/career-jobs.json');

function getDayOfWeek(date) {
  const days = ['일', '월', '화', '수', '목', '금', '토'];
  return days[date.getDay()];
}

function getDaysFromToday(dateStr) {
  if (!dateStr) return null;
  const deadline = new Date(dateStr);
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  deadline.setHours(0, 0, 0, 0);
  const diff = Math.floor((deadline - today) / (1000 * 60 * 60 * 24));
  return diff;
}

function formatDeadline(daysLeft) {
  if (daysLeft === null) return '미확인';
  if (daysLeft < 0) return `D${daysLeft}`;
  if (daysLeft === 0) return 'D-Day';
  return `D-${daysLeft}`;
}

function generateReport(state) {
  const today = new Date();
  const dateStr = today.toISOString().split('T')[0]; // YYYY-MM-DD
  const dow = getDayOfWeek(today);

  const jobs = state.jobs || [];

  // 상태별 분류
  const appliedJobs = jobs.filter(j => j.status === 'applied');
  const monitoringJobs = jobs.filter(j => j.status === 'monitoring');
  const newJobs = jobs.filter(j => j.status === 'new');
  const urgentJobs = monitoringJobs.filter(j => {
    if (!j.deadline) return false;
    const daysLeft = getDaysFromToday(j.deadline);
    return daysLeft !== null && daysLeft >= 0 && daysLeft <= 7;
  });

  let report = `📋 채용 일일 현황 — ${dateStr} (${dow})\n\n`;

  // 🚨 마감임박
  report += `🚨 마감임박 (D-7 이내)\n`;
  if (urgentJobs.length === 0) {
    report += `없음\n\n`;
  } else {
    urgentJobs.forEach(job => {
      const daysLeft = getDaysFromToday(job.deadline);
      report += `- ${job.company} | ${job.title} | D-${daysLeft}\n`;
    });
    report += `\n`;
  }

  // ✅ 지원완료
  report += `✅ 지원완료 — 결과 대기\n`;
  if (appliedJobs.length === 0) {
    report += `없음\n\n`;
  } else {
    appliedJobs.forEach(job => {
      const appliedDate = new Date(job.appliedAt);
      const today = new Date();
      const daysAgo = Math.floor((today - appliedDate) / (1000 * 60 * 60 * 24));
      report += `- ${job.company} | ${job.title} | 지원 D+${daysAgo}일\n`;
    });
    report += `\n`;
  }

  // 👁️ 모니터링 중 (긴급 제외)
  const normalMonitoring = monitoringJobs.filter(j => {
    if (!j.deadline) return true;
    const daysLeft = getDaysFromToday(j.deadline);
    return daysLeft === null || daysLeft < 0 || daysLeft > 7;
  });

  report += `👁️ 모니터링 중\n`;
  if (normalMonitoring.length === 0) {
    report += `없음\n\n`;
  } else {
    normalMonitoring.forEach(job => {
      const firstSeen = new Date(job.firstSeen);
      const today = new Date();
      const daysAgo = Math.floor((today - firstSeen) / (1000 * 60 * 60 * 24));
      const deadline = job.deadline ? formatDeadline(getDaysFromToday(job.deadline)) : '미확인';
      report += `- ${job.company} | ${job.title} | 발견 D+${daysAgo}일 | 마감: ${deadline}\n`;
    });
    report += `\n`;
  }

  // 🆕 오늘 신규 감지
  report += `🆕 오늘 신규 감지\n`;
  if (newJobs.length === 0) {
    report += `없음\n\n`;
  } else {
    newJobs.forEach(job => {
      report += `- ${job.company} | ${job.title} | ${job.url}\n`;
    });
    report += `\n`;
  }

  // ⚠️ 직접 확인 필요
  const needsManualCheck = monitoringJobs.filter(j =>
    j.note && j.note.includes('크롤링')
  );

  report += `⚠️ 직접 확인 필요 (크롤링 불가)\n`;
  if (needsManualCheck.length === 0) {
    report += `없음\n\n`;
  } else {
    needsManualCheck.forEach(job => {
      report += `- ${job.company}: ${job.note}\n`;
    });
    report += `\n`;
  }

  // 푸터
  report += `---\n`;
  report += `🔍 ${process.env.OWNER_NAME || '오너'}님 타겟 스택: Java/Spring/Kafka/gRPC/MSA/AWS | 경력 9년+\n`;

  return report;
}

async function main() {
  try {
    const state = JSON.parse(readFileSync(STATE_FILE, 'utf-8'));
    const report = generateReport(state);

    console.log('📤 보고서 전송 중...\n');
    console.log(report);

    await discordSend(report, 'jarvis-career', { username: 'Career Daily' });

    console.log('\n✅ Discord 전송 완료');
  } catch (err) {
    console.error('❌ 오류:', err.message);
    process.exit(1);
  }
}

main();
