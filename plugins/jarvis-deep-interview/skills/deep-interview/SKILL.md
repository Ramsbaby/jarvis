---
name: jarvis-deep-interview
description: Convergent Socratic interview that turns vague requirements into a production-grade specification via 8-15 narrowing rounds with mathematical ambiguity gating. Inspired by Sorbh/interview-me, adds Contrarian/Simplifier Challenge Mode and JSONL decision log. Use when an idea exists but implementation decisions are still undefined.
license: MIT
---

# /deep-interview — Convergent Requirements Interview

Acts as a senior architect. 8-15 rounds of Socratic questions narrow a vague idea into a production-grade spec. Blocks contradictions, edge-case gaps, and security gaps before any code is written.

## How it differs from /brainstorm

- **/brainstorm** (divergent): expand possibilities. 15-20 questions + UI mockup variants. Exits when ideation feels saturated.
- **/deep-interview** (convergent): spec gating. 8-15 narrowing rounds + decision log. Exits when ambiguity score ≤ threshold.

When to use which:
- Idea itself is undefined → `/brainstorm`
- Idea exists, implementation decisions are undefined → `/deep-interview`

## Mechanism (4 stages)

### 1. Mathematical ambiguity gating

After each round, score across:
- Undefined behavior areas
- Contradiction risk (conflicting requirements)
- Uncovered edge cases
- Security gaps (secrets, PII, permissions)
- Unidentified irreversible decisions

Refuse autonomous implementation until score ≤ 0.2 (default threshold).

### 2. Socratic question patterns

Examples the agent will ask:
- "What happens when X scenario triggers Y?"
- "What evidence would prove this decision wrong (falsifiability condition)?"
- "What assumptions are you carrying that aren't yet stated?"
- "What technical debt will this create one year out?"

### 3. Contrarian / Simplifier Challenge Mode

For each major decision, automatically run two checks:
- **Contrarian**: deliberately raise the counter-hypothesis (debiasing — never confirm a single hypothesis without testing its opposite)
- **Simplifier**: check whether a much smaller version exists (Karpathy "Simplicity First" — 200 lines vs 50 lines)

### 4. Decision log auto-write

All decisions, rationale, falsifiability conditions, and challenge results are recorded in JSONL for later audit.

## Iron rules integration

- **No fix without root cause**: 5-why on each decision
- **Never lie about status**: "don't know" is explicitly marked, not papered over
- **User sovereignty**: agent questions are strong signals, not commands — user's answer is final

## Self-check (per round — BLOCKING)

1. Did I compute the ambiguity score with concrete evidence?
2. Did I avoid confirming a single hypothesis without contrarian check?
3. Did I run the simplifier challenge?
4. Did I write the decision and its rationale to the log?

All must pass to advance to the next round.

## Limitations

- Too-divergent input → recommend `/brainstorm` first
- Rounds > 15 → auto-pause with "convergence failed, recommend re-divergence"
- Ambiguity score is a heuristic, not a precise measurement — user judgment is final

## Related skills

- `/brainstorm` — divergent ideation (predecessor stage)
- `/plan-review` — rigorous spec review after this skill completes
- `/verify` — implementation verification after spec is built
- `/office-hours` — trade-off matrix when a single decision needs explicit user approval

## Source attribution

Inspired by Sorbh/interview-me (github.com/Sorbh/interview-me). Convergent gating concept and Contrarian Mode adapted with permission from the open-source pattern.
