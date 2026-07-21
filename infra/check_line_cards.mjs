import { chromium } from 'playwright';
import path from 'path';

const file = '/Users/ramsbaby/jarvis/runtime/preply-materials/한국어자료_가사문법_전곡_never_love.html';
const url = 'file://' + encodeURI(file);

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 900, height: 1200 } });
await page.goto(url);

// count time-badges and word-cards
const badgeCount = await page.locator('.time-badge').count();
const wordCardCount = await page.locator('.word-card').count();
console.log('time-badge count:', badgeCount);
console.log('word-card count:', wordCardCount);

// scroll to first L1 card (near top) and screenshot
const l1 = page.locator('.time-badge', { hasText: 'L1 ·' }).first();
await l1.scrollIntoViewIfNeeded();
await page.screenshot({ path: '/tmp/l1_before.png', clip: await l1.boundingBox().then(b => ({x: Math.max(0,b.x-20), y: Math.max(0,b.y-20), width: 860, height: 700})) });

// click first word-card near L1
const firstCard = page.locator('.word-card').first();
await firstCard.click();
await page.waitForTimeout(200);
const flippedClass = await firstCard.getAttribute('class');
console.log('after click class:', flippedClass);
await page.screenshot({ path: '/tmp/l1_after.png', clip: await l1.boundingBox().then(b => ({x: Math.max(0,b.x-20), y: Math.max(0,b.y-20), width: 860, height: 700})) });

// check a repeat card (L29) exists and shows warning-box
const l29 = page.locator('.time-badge', { hasText: 'L29 ·' }).first();
await l29.scrollIntoViewIfNeeded();
await page.screenshot({ path: '/tmp/l29_repeat.png', clip: await l29.boundingBox().then(b => ({x: Math.max(0,b.x-20), y: Math.max(0,b.y-20), width: 860, height: 300})) });

// check quiz still works - click a quiz option
const quizBtn = page.locator('.quiz-opt').first();
await quizBtn.scrollIntoViewIfNeeded();
await quizBtn.click();
await page.waitForTimeout(200);
const quizClass = await quizBtn.getAttribute('class');
console.log('quiz after click class:', quizClass);

await browser.close();
