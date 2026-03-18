/**
 * Tests for prompt-sections.js
 *
 * All functions are pure (no I/O), so no mocking is required.
 */

import { describe, it, expect } from 'vitest';

import {
  buildIdentitySection,
  buildLanguageSection,
  buildPersonaSection,
  buildPrinciplesSection,
  buildFormatSection,
  buildToolsSection,
  buildSafetySection,
  buildUserContextSection,
  isPreplyQuery,
  buildPreplySection,
} from '../prompt-sections.js';

// ---------------------------------------------------------------------------
// buildIdentitySection
// ---------------------------------------------------------------------------

describe('buildIdentitySection', () => {
  it('contains botName from param', () => {
    const result = buildIdentitySection({ botName: 'TestBot', ownerName: 'testUser' });
    expect(result).toContain('TestBot');
  });

  it('contains ownerName from param', () => {
    const result = buildIdentitySection({ botName: 'Jarvis', ownerName: 'testUser' });
    expect(result).toContain('testUser');
  });

  it('contains "Jarvis" branding', () => {
    const result = buildIdentitySection({ botName: 'Jarvis', ownerName: 'testUser' });
    expect(result).toContain('Jarvis');
  });

  it('does NOT contain "Claude" as self-identification', () => {
    const result = buildIdentitySection({ botName: 'Jarvis', ownerName: 'testUser' });
    // The section should instruct NOT to use Claude, and the bot name itself should not be Claude
    expect(result).toContain('"Claude"라고 절대 자칭하지 마세요');
  });

  it('falls back to "Jarvis" when botName is omitted', () => {
    const result = buildIdentitySection({ ownerName: 'testUser' });
    expect(result).toContain('Jarvis');
  });

  it('falls back to "Owner" when ownerName is omitted', () => {
    const result = buildIdentitySection({ botName: 'Jarvis' });
    expect(result).toContain('Owner');
  });
});

// ---------------------------------------------------------------------------
// buildLanguageSection
// ---------------------------------------------------------------------------

describe('buildLanguageSection', () => {
  it('contains "한국어 존댓말"', () => {
    const result = buildLanguageSection();
    expect(result).toContain('한국어 존댓말');
  });

  it('is a non-empty string', () => {
    const result = buildLanguageSection();
    expect(typeof result).toBe('string');
    expect(result.length).toBeGreaterThan(0);
  });
});

// ---------------------------------------------------------------------------
// buildPersonaSection
// ---------------------------------------------------------------------------

describe('buildPersonaSection', () => {
  it('contains ownerName', () => {
    const result = buildPersonaSection({ ownerName: 'testUser' });
    expect(result).toContain('testUser');
  });

  it('contains "토니 스타크"', () => {
    const result = buildPersonaSection({ ownerName: 'testUser' });
    expect(result).toContain('토니 스타크');
  });

  it('falls back to "Owner" when ownerName is omitted', () => {
    const result = buildPersonaSection({});
    expect(result).toContain('Owner');
  });
});

// ---------------------------------------------------------------------------
// buildPrinciplesSection
// ---------------------------------------------------------------------------

describe('buildPrinciplesSection', () => {
  it('contains "즉시 실행" (immediate execution without approval)', () => {
    const result = buildPrinciplesSection();
    expect(result).toContain('즉시 실행');
  });

  it('contains "삭제·배포·서버 재시작만 사전 확인" (only deletions/deployments/restarts need confirmation)', () => {
    const result = buildPrinciplesSection();
    expect(result).toContain('삭제·배포·서버 재시작만 사전 확인');
  });

  it('is a non-empty string', () => {
    const result = buildPrinciplesSection();
    expect(typeof result).toBe('string');
    expect(result.length).toBeGreaterThan(0);
  });
});

// ---------------------------------------------------------------------------
// buildFormatSection
// ---------------------------------------------------------------------------

describe('buildFormatSection', () => {
  it('contains "테이블" and "금지" (table prohibition)', () => {
    const result = buildFormatSection();
    expect(result).toContain('테이블');
    expect(result).toContain('금지');
  });

  it('contains "진행할까요?" prohibition', () => {
    const result = buildFormatSection();
    expect(result).toContain('"진행할까요?"');
  });

  it('is a non-empty string', () => {
    const result = buildFormatSection();
    expect(typeof result).toBe('string');
    expect(result.length).toBeGreaterThan(0);
  });
});

// ---------------------------------------------------------------------------
// buildToolsSection
// ---------------------------------------------------------------------------

describe('buildToolsSection', () => {
  const BOT_HOME = '/home/user/.jarvis';

  it('contains botHome path in output', () => {
    const result = buildToolsSection({ botHome: BOT_HOME });
    expect(result).toContain(BOT_HOME);
  });

  it('contains "Serena"', () => {
    const result = buildToolsSection({ botHome: BOT_HOME });
    expect(result).toContain('Serena');
  });

  it('contains "Nexus"', () => {
    const result = buildToolsSection({ botHome: BOT_HOME });
    expect(result).toContain('Nexus');
  });

  it('contains "정보탐험" (recon keyword)', () => {
    const result = buildToolsSection({ botHome: BOT_HOME });
    expect(result).toContain('정보탐험');
  });
});

// ---------------------------------------------------------------------------
// buildSafetySection
// ---------------------------------------------------------------------------

describe('buildSafetySection', () => {
  it('contains "rm -rf"', () => {
    const result = buildSafetySection();
    expect(result).toContain('rm -rf');
  });

  it('contains "launchctl"', () => {
    const result = buildSafetySection();
    expect(result).toContain('launchctl');
  });

  it('contains "Discord 봇"', () => {
    const result = buildSafetySection();
    expect(result).toContain('Discord 봇');
  });

  it('is a non-empty string', () => {
    const result = buildSafetySection();
    expect(typeof result).toBe('string');
    expect(result.length).toBeGreaterThan(0);
  });
});

// ---------------------------------------------------------------------------
// buildUserContextSection
// ---------------------------------------------------------------------------

describe('buildUserContextSection', () => {
  const ownerArgs = {
    ownerName: 'testUser',
    ownerTitle: '대표',
    githubUsername: 'testuser',
    profileCache: '프로필 캐시 내용',
  };

  it('owner profile → contains "Owner Context"', () => {
    const parts = buildUserContextSection({
      activeUserProfile: { type: 'owner' },
      ...ownerArgs,
    });
    expect(parts.join('\n')).toContain('Owner Context');
  });

  it('owner profile → contains ownerName', () => {
    const parts = buildUserContextSection({
      activeUserProfile: { type: 'owner' },
      ...ownerArgs,
    });
    expect(parts.join('\n')).toContain('testUser');
  });

  it('owner profile → contains githubUsername', () => {
    const parts = buildUserContextSection({
      activeUserProfile: { type: 'owner' },
      ...ownerArgs,
    });
    expect(parts.join('\n')).toContain('testuser');
  });

  it('owner profile → contains profileCache', () => {
    const parts = buildUserContextSection({
      activeUserProfile: { type: 'owner' },
      ...ownerArgs,
    });
    expect(parts.join('\n')).toContain('프로필 캐시 내용');
  });

  it('owner profile with null profileCache → filters null out (no "null" in output)', () => {
    const parts = buildUserContextSection({
      activeUserProfile: { type: 'owner' },
      ...ownerArgs,
      profileCache: null,
    });
    // filter(Boolean) should remove null, so array should not contain null/undefined
    expect(parts.every(p => p != null)).toBe(true);
    expect(parts.join('\n')).not.toContain('null');
  });

  it('guest (null profile) → contains "게스트"', () => {
    const parts = buildUserContextSection({
      activeUserProfile: null,
      ...ownerArgs,
    });
    expect(parts.join('\n')).toContain('게스트');
  });

  it('guest (null profile) → does not contain personal info (ownerName, github)', () => {
    const parts = buildUserContextSection({
      activeUserProfile: null,
      ...ownerArgs,
    });
    const joined = parts.join('\n');
    expect(joined).not.toContain('testUser');
    expect(joined).not.toContain('testuser');
  });

  it('regular user → contains name and title', () => {
    const parts = buildUserContextSection({
      activeUserProfile: {
        type: 'user',
        name: '홍길동',
        title: '개발자',
        bio: '',
        persona: null,
      },
      ...ownerArgs,
    });
    const joined = parts.join('\n');
    expect(joined).toContain('홍길동');
    expect(joined).toContain('개발자');
  });

  it('regular user with persona → contains persona text', () => {
    const parts = buildUserContextSection({
      activeUserProfile: {
        type: 'user',
        name: '이영희',
        title: '디자이너',
        bio: '',
        persona: '친근하게 반말로 대화',
      },
      ...ownerArgs,
    });
    const joined = parts.join('\n');
    expect(joined).toContain('친근하게 반말로 대화');
    expect(joined).toContain('응답 가이드');
  });

  it('regular user without persona → no empty persona string in parts', () => {
    const parts = buildUserContextSection({
      activeUserProfile: {
        type: 'user',
        name: '이영희',
        title: '디자이너',
        bio: '',
        persona: null,
      },
      ...ownerArgs,
    });
    // filter(Boolean) removes empty strings — no empty elements expected
    expect(parts.every(p => p.length > 0)).toBe(true);
  });

  it('returns an array', () => {
    const parts = buildUserContextSection({
      activeUserProfile: null,
      ...ownerArgs,
    });
    expect(Array.isArray(parts)).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// isPreplyQuery
// ---------------------------------------------------------------------------

describe('isPreplyQuery', () => {
  it('true for "오늘 수입"', () => {
    expect(isPreplyQuery('오늘 수입 얼마야?')).toBe(true);
  });

  it('true for "레슨 얼마야"', () => {
    expect(isPreplyQuery('레슨 얼마야?')).toBe(true);
  });

  it('true for "preply 수업"', () => {
    expect(isPreplyQuery('preply 수업 일정')).toBe(true);
  });

  it('true for "이번 주 수업"', () => {
    expect(isPreplyQuery('이번 주 수업 알려줘')).toBe(true);
  });

  it('false for "오늘 날씨"', () => {
    expect(isPreplyQuery('오늘 날씨 어때?')).toBe(false);
  });

  it('false for "코드 짜줘"', () => {
    expect(isPreplyQuery('코드 짜줘')).toBe(false);
  });

  it('false for empty string', () => {
    expect(isPreplyQuery('')).toBe(false);
  });

  it('false for null (coerced to empty string)', () => {
    expect(isPreplyQuery(null)).toBe(false);
  });

  it('false for undefined (coerced to empty string)', () => {
    expect(isPreplyQuery(undefined)).toBe(false);
  });

  it('case insensitive: "PREPLY 수업" is true', () => {
    expect(isPreplyQuery('PREPLY 수업 일정')).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// buildPreplySection
// ---------------------------------------------------------------------------

describe('buildPreplySection', () => {
  const BOT_HOME = '/home/user/.jarvis';

  it('contains botHome path in output', () => {
    const result = buildPreplySection({ botHome: BOT_HOME });
    expect(result).toContain(BOT_HOME);
  });

  it('contains "cal-preply.sh"', () => {
    const result = buildPreplySection({ botHome: BOT_HOME });
    expect(result).toContain('cal-preply.sh');
  });

  it('contains "preply-today.sh"', () => {
    const result = buildPreplySection({ botHome: BOT_HOME });
    expect(result).toContain('preply-today.sh');
  });

  it('contains MCP/Claude Code restart prohibition ("MCP 설정·Claude Code 재시작 언급 절대 금지")', () => {
    const result = buildPreplySection({ botHome: BOT_HOME });
    expect(result).toContain('MCP 설정·Claude Code 재시작 언급 절대 금지');
  });

  it('is a non-empty string', () => {
    const result = buildPreplySection({ botHome: BOT_HOME });
    expect(typeof result).toBe('string');
    expect(result.length).toBeGreaterThan(0);
  });
});
