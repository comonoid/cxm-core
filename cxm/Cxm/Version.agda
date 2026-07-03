{-# OPTIONS --without-K #-}

-- Schema versioning + event-upcasting (cxm-plan.md Phase 10, §8.5, §9.4). The MINIMAL bookmark:
--   * a schema version PER ENTITY (`schemaVersion`), the place a codec/migration consults;
--   * an event-UPCASTING hook (`Upcast : Version → RawPayload → RawPayload`) applied to an old
--     event's payload BEFORE decoding — the standard event-sourcing move for non-additive change;
--   * Tier-1 tolerant decode reused (`decodeRowTolerant`) for additive nullable-tail evolution.
-- Deferred (§9.4): schema-diff → ALTER, and a version field in the WAL header (agdelte-store
-- territory, Phase 11+). The upcast takes the source version as a parameter — known at migration
-- time (transform-on-replay, §8.6) — so per-row version storage is not required for the bookmark.
module Cxm.Version where

open import Data.Nat using (ℕ)
open import Data.Maybe using (Maybe; just; nothing)
open import Data.String using (String) renaming (_++_ to _<>_)

open import Cxm.Event using (ExperienceEvent; eePayload)
open import Agdelte.Storage.Schema using (decodeRowTolerant)
open import Cxm.Wire using (experienceEventSchema; eeFromRow; _>>=ᵐ_)

------------------------------------------------------------------------
-- Versions
------------------------------------------------------------------------

Version : Set
Version = ℕ

-- the current schema version of the core. Bump on any schema change.
currentVersion : Version
currentVersion = 1

-- schema version PER ENTITY (keyed by the Interface table name). All entities are v1 today;
-- bump a specific entity here when its schema evolves — the register a migration consults.
-- (audit #C: structurally per-entity, but every entity currently maps to `currentVersion`.)
schemaVersion : String → Version
schemaVersion _ = currentVersion

------------------------------------------------------------------------
-- Event upcasting (§8.5): transform an old raw payload (written under `from`) to the current
-- shape before decoding. Payload is the versioned, type-specific part; the envelope is stable.
------------------------------------------------------------------------

RawPayload : Set
RawPayload = String

Upcast : Set
Upcast = Version → RawPayload → RawPayload

-- no-op upcast (current version, or a payload that needs no transform)
idUpcast : Upcast
idUpcast _ p = p

-- example registered upcast: v0 payloads were a bare string; v1 wraps them as {"legacy":…}.
-- (Illustrates the hook; real upcasts are registered here as the schema evolves.)
demoUpcast : Upcast
demoUpcast 0       p = "{\"legacy\":\"" <> p <> "\"}"
demoUpcast _       p = p

-- apply an upcast to an event's payload (leaving the stable envelope untouched) — a convenience
-- for evolution WITHIN the opaque payload, when the envelope shape is unchanged.
upcastEventPayload : Upcast → Version → ExperienceEvent → ExperienceEvent
upcastEventPayload up from ev = record ev { eePayload = up from (eePayload ev) }

-- NOTE (audit #B): an `Upcast` must take `from` all the way to the current shape directly — there
-- is no incremental v0→v1→v2 chaining yet (min bookmark; add a composition step when needed).

------------------------------------------------------------------------
-- Tier-1 tolerant decode (retained, §8.5): reads an OLD ExperienceEvent row that is missing a
-- LATER-appended nullable trailing column (filled with `nothing`). For a full row it is
-- byte-identical to the strict decoder.
------------------------------------------------------------------------

decExperienceEventTolerant : String → Maybe ExperienceEvent
decExperienceEventTolerant s = decodeRowTolerant experienceEventSchema s >>=ᵐ eeFromRow

-- The plan's hook applied "перед декодом" (§8.5, audit #A): transform the raw encoded row written
-- under `from` to the current shape FIRST, then tolerant-decode. This is the order that lets an
-- old, otherwise-undecodable row be read. `from` is known at migration time (transform-on-replay,
-- §8.6). With `idUpcast` it is exactly `decExperienceEventTolerant`.
decodeEventUpcast : Upcast → Version → String → Maybe ExperienceEvent
decodeEventUpcast up from s = decExperienceEventTolerant (up from s)
