{-# OPTIONS --without-K #-}

-- `Entitlement` — a generic access grant (cxm-plan.md Phase 6, §4.12) — [ВХ]. Generalizes the
-- CRM "payment→engagement": a target is an offering | resource | membership, granted by a
-- payment or an operator grant, valid over a window. Creating an Episode from a payment is ONE
-- kind of grant, not the only one (§4.12).
module Cxm.Entitlement where

open import Data.Nat using (ℕ)
open import Data.Maybe using (Maybe)

open import Cxm.Tenant using (TenantId)

-- what the entitlement grants access to (the target's table is implied by the kind)
data EntTarget : Set where
  TOffering   : EntTarget
  TResource   : EntTarget
  TMembership : EntTarget

-- how the grant arose
data EntSource : Set where
  SPayment : EntSource
  SGrant   : EntSource        -- operator-granted (comp, trial, migration)

record Entitlement : Set where
  constructor mkEntitlement
  field
    enId         : ℕ
    enSubject    : ℕ            -- who holds the grant (FK → subject)
    enTenant     : TenantId
    enTargetKind : EntTarget
    enTarget     : ℕ            -- id of the offering / resource / membership
    enValidFrom  : ℕ
    enValidTo    : Maybe ℕ      -- nothing = open-ended
    enSource     : EntSource
    enCreatedAt  : ℕ

open Entitlement public
