{-# OPTIONS --without-K #-}

-- Compile-time test for Phase 12 (§9.10 / principle 12): ONE binary (this same code) serves
-- different pack subsets purely by config — the pack-activation gate reads `cfgActivePacks`.
-- Demonstrates the DoD "one binary starts with two different configs without code change".
module Cxm.Test.InstanceTest where

open import Relation.Binary.PropositionalEquality using (_≡_; refl)
open import Data.Bool using (true; false)
open import Data.List using ([]; _∷_)

open import Cxm.Tenant using (mkTenant)
open import Cxm.Config
open import Cxm.Instance using (packActive)

-- two configs that differ ONLY in the active-packs subset (same code path). Pack ids are opaque
-- strings ("packA"/"packB") — the neutral core never names a real vertical.
cfgA cfgEmpty : InstanceConfig
cfgA     = mkInstanceConfig (mkStorageHandle "/wal") ("packA" ∷ []) SingleOperator 1 (mkTenant 1 "op" 0 ∷ []) "" ""
cfgEmpty = mkInstanceConfig (mkStorageHandle "/wal") []             SingleOperator 1 (mkTenant 1 "op" 0 ∷ []) "" ""

_ : packActive cfgA "packA" ≡ true          -- active here
_ = refl
_ : packActive cfgEmpty "packA" ≡ false     -- inactive under the empty config — same code
_ = refl
_ : packActive cfgA "packB"   ≡ false        -- a pack not in the subset is inactive
_ = refl
