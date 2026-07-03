{-# OPTIONS --without-K #-}

-- `RelationshipState` (cxm-plan.md Phase 7, §4.11) — the current state of the relationship as a
-- STATE with decay: trust ("trust score"), sentiment TRAJECTORY (direction, not a snapshot),
-- lifecycle stage. [ПР]. Trust is carried in the envelope's `confidence`; trajectory + stage in
-- `kDetail`. Relationship economics (switching costs, competitors, loyalty — §4.11) are NOT a
-- separate primitive: they live as Fact/Hypothesis and feed this state.
module Cxm.RelationshipState where

open import Data.Nat using (ℕ; _<?_)
open import Data.Nat.Show using (show)
open import Data.Maybe using (nothing)
open import Data.String using (String) renaming (_++_ to _<>_)
open import Relation.Nullary.Decidable using (True)

open import Cxm.Num using (Permille; permilleMax)
open import Cxm.Tenant using (TenantId)
open import Cxm.Knowledge

-- direction of the sentiment trajectory (early-warning of churn before the level is low, §4.11)
data Trajectory : Set where
  TrajUp TrajFlat TrajDown : Trajectory

trajCode : Trajectory → String
trajCode TrajUp = "up" ; trajCode TrajFlat = "flat" ; trajCode TrajDown = "down"

relDetail : Trajectory → ℕ → String
relDetail tr stage = "rel:" <> trajCode tr <> "/stage=" <> show stage

-- a STATE knowledge ([ПР]) with decay; `trust` is the confidence (proof-gated < 1000); kId 0.
relationshipState : (subject : ℕ) (tenant : TenantId) (trust : Permille) {pf : True (trust <? permilleMax)}
                    (traj : Trajectory) (stage decay validFrom : ℕ) → Knowledge
relationshipState subj ten trust {pf} traj stage dec vf =
  mkInferred 0 subj ten IState trust {pf} (relDetail traj stage) dec vf nothing nothing
