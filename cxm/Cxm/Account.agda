{-# OPTIONS --without-K #-}

-- `Account` — a balance in minor units (cxm-plan.md Phase 6, §4.15, §9.7) — [ВХ]. Single-currency
-- ℕ on the MVP (currency deferred, §9.7). The "balance ≥ 0" invariant is enforced BY CONSTRUCTION
-- in the charge command (Cxm.Commands.Money, proof-gated debit) — record only here.
module Cxm.Account where

open import Data.Nat using (ℕ)

open import Cxm.Tenant using (TenantId)

record Account : Set where
  constructor mkAccount
  field
    acId        : ℕ
    acTenant    : TenantId
    acBalance   : ℕ            -- minor units; guarded ≥ 0 by construction (proof-gated charge)
    acCreatedAt : ℕ

open Account public
