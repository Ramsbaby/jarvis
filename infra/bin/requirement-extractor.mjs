#!/usr/bin/env node
/**
 * requirement-extractor.mjs
 * Cluster cl-28e5202af0584c23: 사용자 프롬프트에서 명시된 조건 항목 추출
 *
 * 사용법:
 *   node requirement-extractor.mjs "프롬프트 텍스트"
 *   → JSON 출력 (stdout): {format, sections, bilingual, scope, ...}
 *
 * 추출 대상:
 *   - format: pdf, html, markdown, text 등
 *   - sections: 요약본, 숙제, 정답지, 교재 등
 *   - bilingual: 병기(한글_영어) 여부
 *   - scope: 전체, 부분, 선별적 등
 */

function extractRequirements(prompt) {
  const requirements = {};

  // Format detection
  const formatMatch = prompt.match(/(?:pdf|html|markdown|md|excel|xlsx?|docx?|pptx?|text|txt|json)(?:\s|,|$|형식|로|으로)/gi);
  if (formatMatch) {
    const m = formatMatch[0].toLowerCase();
    if (m.includes('pdf')) requirements.format = 'pdf';
    else if (m.includes('html')) requirements.format = 'html';
    else if (m.includes('markdown') || m.includes('md')) requirements.format = 'markdown';
    else if (m.includes('text') || m.includes('txt')) requirements.format = 'text';
    else if (m.includes('excel') || m.includes('xlsx') || m.includes('xls')) requirements.format = 'xlsx';
    else if (m.includes('docx') || m.includes('doc')) requirements.format = 'docx';
    else if (m.includes('json')) requirements.format = 'json';
  }

  // Sections detection
  const sectionKeywords = ['요약본', '숙제', '정답지', '교재', '문제집', '해설', '문법', '영단어',
                          'summary', 'assignment', 'answer', 'solution', 'question', '문제'];
  const sections = [];
  for (const keyword of sectionKeywords) {
    const regex = new RegExp(keyword, 'gi');
    if (regex.test(prompt) && !sections.includes(keyword)) {
      sections.push(keyword);
    }
  }
  if (sections.length > 0) {
    requirements.sections = sections;
  }

  // Bilingual detection
  const bilingualPattern = /(?:병기|이중언어|한글.*영어|영어.*한글|dual\s?lang|bilingual)/gi;
  if (bilingualPattern.test(prompt)) {
    requirements.bilingual = true;
  }

  // Scope detection
  const scopeMatch = prompt.match(/(?:범위|scope)[\s:]*(?:(전체|부분|선별적|모든|일부|all|partial|selective))/i);
  if (scopeMatch) {
    const m = scopeMatch[1].toLowerCase();
    if (m.includes('전체') || m === 'all') requirements.scope = 'all';
    else if (m.includes('부분') || m === 'partial') requirements.scope = 'partial';
    else if (m.includes('선별') || m === 'selective') requirements.scope = 'selective';
  }

  // Output format detection
  const outputMatch = prompt.match(/(?:형식|방식)[\s:]*(?:(제출용|임시|모니터링|최종|draft|submission|final))/i);
  if (outputMatch) {
    const m = outputMatch[1].toLowerCase();
    if (m.includes('제출') || m === 'submission' || m === 'final') requirements.output_format = 'submission';
    else if (m.includes('임시') || m === 'draft') requirements.output_format = 'draft';
    else if (m.includes('모니터링')) requirements.output_format = 'monitoring';
  }

  // Verification requirement detection
  const verifyPattern = /(?:검증|검사|확인|verification|validation)[\s:]*(?:필수|필요|엄격|required|mandatory)/gi;
  if (verifyPattern.test(prompt)) {
    requirements.verification_required = true;
  }

  return requirements;
}

// Main
const prompt = process.argv[2] || '';
if (!prompt) {
  console.error('Usage: requirement-extractor.mjs "prompt text"');
  process.exit(1);
}

const requirements = extractRequirements(prompt);
console.log(JSON.stringify(requirements, null, 2));
