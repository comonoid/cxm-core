{-# OPTIONS --without-K #-}

-- `SubjectEdge` — a generic subject↔subject edge (cxm-plan.md Phase 2, description §4.3, §7).
-- ONE mechanism for every relation with a kind, generalizing both participation and the
-- social graph. Baked into the schema from day one (principle 8) even where unused.
--
-- Special cases of the one mechanism:
--   * participation      — participation in an episode with a role (subsumes CRM Participation)
--   * membership         — person ↔ account/community
--   * decision_consult   — an ordered edge in a DecisionUnit (§4.13; `seOrdinal` orders it).
--     CONVENTION (upgrade-план C3): `seRole` carries the decision role as a STRING from the
--     vertical's vocabulary (champion/blocker/economic_buyer/user/advisor — Concept I.e);
--     the core fixes NO enum — the vocabulary is pack/config data (differences are data, §9).
--   * owner / patient    — owner ↔ dependent (generic; e.g. owner ↔ pet)
--   * follow             — social graph (NOT implemented, but the edge is ready — §7.3)
module Cxm.Edge where

open import Data.Nat using (ℕ)
open import Data.String using (String)
open import Data.Maybe using (Maybe)

open import Cxm.Tenant using (TenantId)

data EdgeKind : Set where
  participation    : EdgeKind
  membership       : EdgeKind
  decision_consult : EdgeKind
  owner            : EdgeKind
  patient          : EdgeKind
  follow           : EdgeKind      -- social graph placeholder (§7.3)

record SubjectEdge : Set where
  constructor mkEdge
  field
    seId        : ℕ                 -- synthetic row id (primary key)
    seFrom      : ℕ                 -- FK → subject
    seTo        : ℕ                 -- FK → subject
    seKind      : EdgeKind
    seRole      : Maybe String      -- participation/decision role; nothing = none
    seOrdinal   : ℕ                 -- ordering within an ordered graph (decision_consult)
    seValidFrom : ℕ                 -- unix seconds
    seValidTo   : Maybe ℕ           -- nothing = open-ended
    seTenant    : TenantId          -- §7.1 tenant axis
    seCreatedAt : ℕ

open SubjectEdge public
