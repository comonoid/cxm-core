{-# OPTIONS --without-K #-}

-- `Payment` — an online purchase record (cxm-plan.md Phase 6, §4.15, CRM §7) — [ВХ]. pending →
-- succeeded/failed; the AUTHORITATIVE status comes from the provider (re-fetch / signed webhook),
-- not trust. On success it feeds an `Entitlement` (the grant), created by the command layer.
module Cxm.Payment where

open import Data.Nat using (ℕ)
open import Data.String using (String)

open import Cxm.Tenant using (TenantId)

data PayStatus : Set where
  PayPending   : PayStatus
  PaySucceeded : PayStatus
  PayFailed    : PayStatus

record Payment : Set where
  constructor mkPayment
  field
    payId          : ℕ
    payTenant      : TenantId
    payExtId       : String       -- provider payment id (lookup by extId: scan, §8.7)
    payOffering    : ℕ            -- offering purchased (FK → offering)
    paySubject     : ℕ            -- buyer (FK → subject; 0 = not yet linked/provisional)
    payName        : String
    payEmail       : String
    payAmount      : ℕ            -- minor units
    payStatus      : PayStatus
    payEntitlement : ℕ            -- granted entitlement id (0 = not granted yet)
    payCreatedAt   : ℕ

open Payment public
