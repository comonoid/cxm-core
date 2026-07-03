{-# OPTIONS --without-K #-}

-- `Subject` — the subject of experience (cxm-plan.md Phase 2, description §4.2, §4.4).
-- Deliberately abstract so B2C / B2B / pet / child / team / author all live in ONE core
-- (principle 7: rich general form degenerating to the simple case by ABSENCE of data).
--
-- Two orthogonal axes:
--   * structural: individual (Person) ↔ collective (Account/Org)
--   * relational: external (EXTERNAL) ↔ internal (INTERNAL, a dept/team, §4.14)
-- B2C is a degenerate B2B (an Account with n=1 and an empty DecisionUnit) — no "mode".
--
-- ADR — merge is an ALIAS, not a rewrite (§4.4). ExperienceEvents [СОБ] are immutable, so
-- merging a provisional subject into a canonical one MUST NOT rewrite events. Instead:
--   * a provisional subject (`sProvisional = true`) is created when an event arrives with an
--     unresolved channel id (new cookie, first contact) so the fact is never lost/blocked;
--   * `merge` sets `sCanonical = just <canonicalId>` on the provisional subject — the events
--     keep their original `subject_id`, and projections/queries RESOLVE the provisional id to
--     its canonical one. `sCanonical = nothing` means the subject IS canonical.
-- This is why the alias field is here from day one: without it omnichannel + the site
-- identity bridge (§7.7) shatter into per-channel fragments.
module Cxm.Subject where

open import Data.Nat using (ℕ)
open import Data.String using (String)
open import Data.Maybe using (Maybe)
open import Data.Bool using (Bool)

open import Cxm.Tenant using (TenantId)

------------------------------------------------------------------------
-- Axes (§4.2)
------------------------------------------------------------------------

data SubjectKind : Set where
  EXTERNAL : SubjectKind          -- a client whose experience we manage
  INTERNAL : SubjectKind          -- a dept/team as a subject (internal loop, §4.14)

data SubjectStructure : Set where
  Person : SubjectStructure       -- an individual
  Org    : SubjectStructure       -- a collective/account/org (§4.2; B2C = Org with n=1).
                                  -- Named Org (not Account) to avoid clashing with the money
                                  -- `Account` (Cxm.Account); §4.2 uses "Account/Org" for this axis.

------------------------------------------------------------------------
-- Subject — [ВХ] core + [ПР] profile (profile fields are projections, Phase 7)
------------------------------------------------------------------------

record Subject : Set where
  constructor mkSubject
  field
    sId          : ℕ                -- internal primary key
    sKind        : SubjectKind
    sStructure   : SubjectStructure
    sDisplayName : String
    sTz          : String           -- IANA tz
    sCreatedAt   : ℕ                -- unix seconds (from IO, §1)
    sDeletedAt   : Maybe ℕ          -- soft-delete; nothing = live
    sTenant      : TenantId         -- §7.1 tenant axis
    sServes      : Maybe ℕ          -- INTERNAL: FK to the external outcome it serves (§4.14)
    sCanonical   : Maybe ℕ          -- merge alias target; nothing = this subject IS canonical
    sProvisional : Bool             -- true = provisional (unresolved identity, §4.4)

open Subject public
