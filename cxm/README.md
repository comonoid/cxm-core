# agdelte-cxm

Headless **Customer Experience Management** core. Strictly subsumes the classic CRM as
a degenerate case: the domain core knows nothing about channels or verticals — channels
and domains are swappable adapters and packs behind a stable contract.

**Design source of truth:** `~/cxm-core/docs/cxm-description.md` (design description; concept in
`~/cxm-core/docs/CXM-концепция-и-ядро.md`). **Implementation plan (by phases):** `~/cxm-core/docs/cxm-plan.md`.

## What the core does

Accumulates normalized facts about customer experience in an append-only event log
(`ExperienceEvent`), builds projections from them (profile, state, episodes), infers and
revises hypotheses, answers "what do we know about a subject" (Query API) and "what to do
next" (Decision API) — closing the loop perceive → model → decide → act → learn.

## What the core does NOT do

Nothing about concrete channels (web/chat/phone/telemetry), concrete content
(lesson/video/medical-record/post), AI meaning-extraction, rendering, or delivery — all of
that is the "edge" (adapters) and packs.

## Layout

- `Cxm/*` — records-only identity modules, `Wire` (schema/codecs), `Store/*`
  (repository-seam + WAL backend), `Txn`, domain commands, projections/inference,
  `Query`/`Decision`/`Api`.
- `Cxm/All.agda` — umbrella module importing everything; the typecheck target.
- `scripts/check-neutrality.sh` — CI guard: the core must not name any vertical.

## Foundations

Sits **down only** on `agdelte-store` (IndexedMap/WAL/Schema), `agdelte` (HTTP/JSON FFI),
`agdelte-auth` (JWT/RBAC), `agdelte-payments` (provider clients). Never depends on packs.
