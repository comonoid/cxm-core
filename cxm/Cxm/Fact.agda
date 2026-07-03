{-# OPTIONS --without-K #-}

-- `Fact` (cxm-plan.md Phase 7, §4.6) — an objective assertion, always in the Knowledge envelope
-- with epistemic_type = FACT, confidence = 1000 (§4.1). [ВХ] when stated/imported. Facts do not
-- decay (decay = 0). `kId 0` is a placeholder — the insert command assigns the real id via freshId.
module Cxm.Fact where

open import Data.Nat using (ℕ)
open import Data.Maybe using (Maybe; nothing)
open import Data.String using (String)

open import Cxm.Tenant using (TenantId)
open import Cxm.Knowledge

assertFact : (subject : ℕ) (tenant : TenantId) (src : FactSource) (claim : String)
             (validFrom : ℕ) (validTo : Maybe ℕ) → Knowledge
assertFact subj ten src claim vf vt = mkFact 0 subj ten src claim vf vt 0 nothing
