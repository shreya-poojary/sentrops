# SentrOps — Status Tracker

> Live project status. Update at the start and end of every build session.

---

## Current sprint: **Sprint 0 — Pre-flight**

**Phase:** ~75% complete
**Target completion:** Weekend of April 26
**Next deliverable:** ADR-001 (architecture principles) and ADR-002 (scope and non-goals)
**Blocked by:** Nothing — ready to execute when fresh

---

## Progress dashboard

| Sprint | Status | Hours used / budget | Deliverable |
|---|---|---|---|
| 0 — Pre-flight | 🟡 In progress (75%) | 3 / 4 | Repo + ADRs + Claude Code setup |
| 1 — Terraform landing zone | ⚪ Not started | 0 / 15 | Working EKS + ArgoCD via one command |
| 2 — Observability + chaos | ⚪ Not started | 0 / 15 | ShipPay workload + 4 chaos scenarios |
| 3 — MCP servers | ⚪ Not started | 0 / 15 | 3 PyPI packages (sentrops-*) published |
| 4 — Agent + evals | ⚪ Not started | 0 / 15 | Working agent with 10-scenario eval |
| 5 — Polish + launch | ⚪ Not started | 0 / 12 | Loom walkthrough + LinkedIn post |
| **Total** | — | **3 / 76** | — |

Legend: ⚪ Not started · 🟡 In progress · 🟢 Complete · 🔴 Blocked

---

## What's shipped so far (Sprint 0)

- [x] Public GitHub repo created
- [x] Architecture diagram (PNG, SVG, Eraser DSL) committed to `docs/`
- [x] README.md with thesis and tech stack
- [x] CLAUDE.md with full guardrails (sprint discipline, learn-don't-generate, scope, cost discipline, session start ritual)
- [x] PLAN.md with 6-sprint breakdown
- [x] STATUS.md (this file) live tracker
- [x] Claude Code installed locally

## What's left for Sprint 0

- [ ] Create `docs/adr/` directory
- [ ] Write ADR-001 — Architecture principles
- [ ] Write ADR-002 — Scope and non-goals
- [ ] First Claude Code session: read-only tour
- [ ] AWS Budgets configured ($50/mo cap, alerts at $25/$40)
- [ ] AWS Cost Explorer enabled on account
- [ ] `.pre-commit-config.yaml` added
- [ ] Placeholder `scripts/bootstrap.sh` and `scripts/teardown.sh`
- [ ] Final Sprint 0 commit + push

---

## Session log

### Session 1 — April 23, 2026 (planning)
- **Hours worked:** ~10 (planning + diagram iteration)
- **Shipped:** Project plan, locked architecture, 9.5/10 architecture diagram (PNG + SVG + DSL)
- **Blockers:** None
- **Tomorrow:** Execute Sprint 0 tasks (15-min repo creation), write ADRs

### Session 2 — April 24, 2026
- **Hours worked:** ~3
- **Shipped:** Public repo, README, CLAUDE.md, PLAN.md, STATUS.md, architecture diagrams committed, Claude Code installed
- **Blockers:** None
- **Next session:** Write ADR-001 and ADR-002, configure AWS Budgets, finish Sprint 0

<!-- Template for future sessions — copy and fill in

### Session N — [DATE]
- **Sprint:** [current sprint]
- **Hours worked:** [X]
- **Shipped:** [what got committed / merged]
- **Blockers:** [anything stuck, or "none"]
- **Next session:** [specific next action]

-->

---

## Weekly retrospectives

<!-- After each sprint, answer these three questions

### Sprint N retro — [DATE]
1. What worked?
2. What didn't?
3. What changes for next sprint?

-->

---

## Blockers & risks currently active

- None. Energy management is the only constraint — late-night sessions producing diminishing returns.

---

## Decisions made

- **2026-04-23:** Project named **SentrOps**; renaming considered and rejected.
- **2026-04-23:** Architecture locked as 5-layer vertical structure with ShipPay as the demo workload.
- **2026-04-23:** Tiered Bedrock model strategy (Haiku 4.5 → Sonnet 4.5 → Opus 4.7) chosen over Opus-only.
- **2026-04-23:** Single-region (us-east-1), single-account scope locked. Multi-region explicitly out per ADR-002.
- **2026-04-23:** GitHub Pages hosting on `shreya-poojary.github.io` confirmed; no separate `sentrops.dev` domain.
- **2026-04-23:** MCP server namespace pivoted to `sentrops-*` after discovering AWS Labs published `awslabs.cloudwatch-mcp-server` etc. in March 2026. Pivot improves positioning (purpose-built for remediation, not generic querying). Decision rationale becomes part of ADR-007.

## Decisions still to make

- [ ] AWS Secrets Manager vs SOPS+age for secrets (leaning Secrets Manager; decide in Sprint 1)
- [ ] Sloth vs Pyrra for SLO definitions (decide in Sprint 2)
- [ ] moto vs localstack for MCP server integration tests (decide in Sprint 3)

---

## Cost tracker

| Month | Target | Actual | Notes |
|---|---|---|---|
| April 2026 (partial) | $15 | $0 | No AWS resources provisioned yet |
| May 2026 | $50 | — | Sprint 1–5 active |

Update weekly from AWS Cost Explorer. If `Actual > Target × 0.8`, stop and investigate.

---

## Interview-readiness checklist (track as you go)

- [ ] 25-second project opener rehearsed and timed
- [ ] Can whiteboard 5-layer architecture from memory
- [ ] Have 20-second answers to 6 standard follow-ups
- [ ] Loom walkthrough recorded and linked
- [ ] LinkedIn post published
- [ ] 3 OSS packages live on PyPI (sentrops-*)
- [ ] Threat model document committed
- [ ] Eval accuracy number published in README
