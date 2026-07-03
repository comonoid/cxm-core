{-# OPTIONS --without-K #-}

-- Child-table records for the model's COLLECTION fields (cxm-plan.md Phase 4, §8.1).
-- `Schema` is atomic-columnar — no list/array column — so every collection field becomes a
-- separate child record/table with an FK back to its parent (exactly as CRM's Participation,
-- generalized in SubjectEdge). This gives them secondary indexes and SQL joins for free.
--
--   * Evidence            — `Knowledge.evidence[]` (§4.1): knowledge ↔ ExperienceEvent link.
--   * Transition          — `Episode.transition_log` (§4.9): one state change.
--   * Deviation           — `Episode.deviations` (§4.9): a deviation from the protocol norm.
--   * ProtocolState       — a `Protocol.states` entry (§4.9).
--   * ProtocolTransition  — an allowed `Protocol.transitions` entry (§4.9).
--
-- Parents (Knowledge exists; Episode/Protocol arrive in Phase 6) are referenced by FK id
-- only, so these records are definable now (an FK is just a ℕ + a table name).
module Cxm.Collections where

open import Data.Nat using (ℕ)
open import Data.String using (String)

open import Cxm.Tenant using (TenantId)

------------------------------------------------------------------------
-- Evidence — Knowledge.evidence[] (§4.1). The INFERRED ⇒ evidence ≠ ∅ invariant is
-- checked at command level (Phase 8/9), since it spans this child table.
------------------------------------------------------------------------

record Evidence : Set where
  constructor mkEvidence
  field
    evdId        : ℕ
    evdKnowledge : ℕ            -- FK → knowledge
    evdEvent     : ℕ            -- FK → experience_event
    evdTenant    : TenantId
    evdCreatedAt : ℕ

open Evidence public

------------------------------------------------------------------------
-- Transition — one entry of Episode.transition_log (§4.9)
------------------------------------------------------------------------

record Transition : Set where
  constructor mkTransition
  field
    trId        : ℕ
    trEpisode   : ℕ            -- FK → episode
    trFromState : ℕ            -- state code
    trToState   : ℕ            -- state code
    trAt        : ℕ            -- unix seconds (from IO)
    trOrdinal   : ℕ            -- order within the episode's log
    trTenant    : TenantId

open Transition public

------------------------------------------------------------------------
-- Deviation — a deviation from the protocol norm (§4.9): stuck / rollback / overdue
------------------------------------------------------------------------

data DeviationKind : Set where
  Stuck    : DeviationKind      -- exceeded expected duration in a state
  Rollback : DeviationKind      -- moved backwards
  Overdue  : DeviationKind      -- an SLA/deadline passed

record Deviation : Set where
  constructor mkDeviation
  field
    dvId      : ℕ
    dvEpisode : ℕ              -- FK → episode
    dvKind    : DeviationKind
    dvAt      : ℕ              -- unix seconds
    dvTenant  : TenantId

open Deviation public

------------------------------------------------------------------------
-- Protocol structure (states/transitions are children of a Protocol, §4.9)
------------------------------------------------------------------------

record ProtocolState : Set where
  constructor mkProtocolState
  field
    psId       : ℕ
    psProtocol : ℕ             -- FK → protocol
    psState    : ℕ             -- state code (config-driven)
    psName     : String        -- display name
    psTenant   : TenantId

open ProtocolState public

record ProtocolTransition : Set where
  constructor mkProtocolTransition
  field
    ptId        : ℕ
    ptProtocol  : ℕ            -- FK → protocol
    ptFromState : ℕ           -- state code
    ptToState   : ℕ           -- state code
    ptTenant    : TenantId

open ProtocolTransition public
