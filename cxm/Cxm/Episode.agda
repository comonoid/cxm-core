{-# OPTIONS --without-K #-}

-- `Episode` — an instance of a Protocol (cxm-plan.md Phase 6, §4.9) — [ВХ] skeleton + [ПР] state.
-- Subsumes the CRM `Engagement`. Its `transition_log` and `deviations` are child tables
-- (Transition / Deviation, Cxm.Collections). `epCurrentState` is a MATERIALIZED projection cache
-- ([ПР]) advanced by the transition command and rebuildable from the log. A subject has N
-- concurrent episodes on different lines (§4.9) — "average stage" is meaningless. Records only.
module Cxm.Episode where

open import Data.Nat using (ℕ)
open import Data.String using (String)
open import Data.Maybe using (Maybe)

open import Cxm.Tenant using (TenantId)

record Episode : Set where
  constructor mkEpisode
  field
    epId           : ℕ
    epSubject      : ℕ            -- FK → subject
    epProtocol     : ℕ            -- FK → protocol
    epTenant       : TenantId
    epCurrentState : ℕ            -- [ПР] materialized current state code
    epJtbd         : String       -- job-to-be-done (opaque)
    epPeak         : Maybe ℕ      -- peak marker (event id); nothing = none yet (§4.5 memory)
    epEnd          : Maybe ℕ      -- end marker (event id); nothing = not ended
    epCreatedAt    : ℕ
    epDeletedAt    : Maybe ℕ      -- soft-delete; nothing = live

open Episode public
