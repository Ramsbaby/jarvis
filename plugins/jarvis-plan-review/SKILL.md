---
name: jarvis-plan-review
description: 11-section rigorous design plan review covering problem framing, scope, architecture, security, observability, deployment, performance, reliability, testing, maintainability, and migration. Korean adaptation of gstack /plan-ceo-review, tuned for sole-developer + AI-pair-programming workflows. Not a rubber stamp — pushes plans toward best-in-class.
license: MIT
---

# /plan-review — 11-Section Rigorous Design Review

Reviews a feature plan, RFC, or architecture doc across 11 independent dimensions. Goal: push the plan to "best-in-class" — not to rubber-stamp it.

## When to invoke

- After writing a feature design doc or RFC
- "Is this approach OK?" / "What did I miss?" / "Is there a better way?"
- Before kicking off any nontrivial implementation

## 11 sections

1. **Problem definition** — Is the problem stated precisely? What evidence supports it being worth solving?
2. **Scope boundaries** — What is explicitly in scope, out of scope, and deferred?
3. **Architecture** — Data flow, dependencies, blast radius of failure
4. **Security** — Authentication, authorization, secrets handling, PII boundaries, threat model
5. **Observability** — Logs, metrics, alerts, on-call playbook
6. **Deployment** — Rollback strategy, gradual rollout, feature flags, dark launches
7. **Performance** — Latency, throughput, cost budget, scaling assumptions
8. **Reliability** — Failure modes, recovery paths, SLO targets
9. **Testing** — Unit, integration, regression, chaos, load
10. **Maintainability** — Code patterns, documentation, onboarding cost for new contributors
11. **Migration** — Backward compatibility, data migration, rollout/rollback ordering

## Output format

For each section, the review returns:
- `Pass` — meets bar
- `Risk` — works but has identifiable risk → suggested mitigation
- `Block` — critical gap → must address before implementation

## Recommended environment

For deep analysis, run with `--effort xhigh` (Opus 4.7 only) to maximize reasoning depth:
```bash
claude --effort xhigh
> /plan-review <plan-doc-path>
```
Cost approximately 2x baseline, but materially improves gap detection — especially in security and reliability sections.

## Self-check (before issuing review — BLOCKING)

1. Did I read the actual plan document (not assume from title)?
2. For each section, do I cite specific lines or claims, not generic feedback?
3. For each `Block`, do I have a concrete falsification — what evidence shows this would actually fail?
4. Did I avoid groupthink with the plan author (contrarian challenge for at least 3 decisions)?

## Limitations

- Cannot detect domain-specific failure modes the author understands but didn't document — surface this gap by asking "what would an expert in domain X say?"
- Cannot replace formal threat modeling for security-critical systems
- 11 sections is a checklist, not a substitute for judgment

## Source attribution

Adapted from gstack (paretofilm/superpowers-gstack) `/plan-ceo-review`. Section list refined for sole-developer + AI-pair-programming workflows where the "CEO review" framing isn't directly applicable.

## Related skills

- `/brainstorm` — earlier ideation stage
- `/deep-interview` — convergent requirement gating (predecessor)
- `/verify` — implementation verification (successor)
- `/security-review` — focused security audit (deeper than section 4 alone)
