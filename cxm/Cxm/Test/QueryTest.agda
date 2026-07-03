{-# OPTIONS --without-K #-}

-- Compile-time tests for Cxm.Query (Phase 8): knownAbout filters live knowledge of a subject;
-- metaKPI counts coverage / observed / inferred / fresh (decayed-confidence ≥ threshold).
module Cxm.Test.QueryTest where

open import Relation.Binary.PropositionalEquality using (_≡_; refl)
open import Data.Maybe using (nothing)
open import Data.Bool using (true; false)
open import Data.List using ([]; _∷_)

open import Cxm.Knowledge
open import Cxm.Query

k1 k2 k3 k4 : Knowledge
k1 = mkFact 1 10 1 FObserved "c1" 0 nothing 0 nothing                         -- subj 10, OBSERVED, ACTIVE, 1000
k2 = mkInferred 2 10 1 IHypothesis 600 "c2" 0 0 nothing nothing              -- subj 10, INFERRED, ACTIVE, 600
k3 = mkKnowledge 3 10 1 HYPOTHESIS INFERRED 400 0 nothing 0 REFUTED "c3" nothing  -- refuted → excluded
k4 = mkFact 4 20 1 FObserved "c4" 0 nothing 0 nothing                        -- other subject → excluded

-- live knowledge about subject 10 = the two active rows, in order
_ : knownAbout 10 (k1 ∷ k2 ∷ k3 ∷ k4 ∷ []) ≡ k1 ∷ k2 ∷ []
_ = refl

-- KPI (no decay): total 2, observed 1, inferred 1, both fresh at threshold 500
_ : metaKPI 0 500 10 (k1 ∷ k2 ∷ k3 ∷ k4 ∷ []) ≡ mkKPI 2 1 1 2
_ = refl

-- freshness drops with decay: a 600‰ hypothesis, decay 100/unit, at now 10 → 600 − 1000 = 0 < 500
kDecaying : Knowledge
kDecaying = mkInferred 5 10 1 IHypothesis 600 "c5" 100 0 nothing nothing
_ : metaKPI 10 500 10 (kDecaying ∷ []) ≡ mkKPI 1 0 1 0
_ = refl

------------------------------------------------------------------------
-- Reliability (upgrade-план A4): the two-sided promised/kept account + no-shows
------------------------------------------------------------------------

open import Cxm.Expectation using (Promise; mkPromise; PromPending; PromFulfilled; PromBroken; Ours; Theirs)
open import Cxm.Appointment using (Appointment; mkAppointment; ApScheduled; ApNoShow)

pOursKept pOursBroken pTheirsKept pTheirsBroken pPending pOther : Promise
pOursKept     = mkPromise 1 10 1 "t" 0 PromFulfilled nothing 0 Ours   nothing false 0 nothing nothing false
pOursBroken   = mkPromise 2 10 1 "t" 0 PromBroken    nothing 0 Ours   nothing false 0 nothing nothing false
pTheirsKept   = mkPromise 3 10 1 "t" 0 PromFulfilled nothing 0 Theirs nothing true  500 nothing nothing false
pTheirsBroken = mkPromise 4 10 1 "t" 0 PromBroken    nothing 0 Theirs nothing true  500 nothing nothing false
pPending      = mkPromise 5 10 1 "t" 0 PromPending   nothing 0 Theirs nothing false 0 nothing nothing false   -- pending → uncounted
pOther        = mkPromise 6 20 1 "t" 0 PromBroken    nothing 0 Theirs nothing false 0 nothing nothing false   -- other subject

aNoShow aSched aOther : Appointment
aNoShow = mkAppointment 7 10 0 nothing nothing 0 90 ApNoShow    nothing 1 0 nothing
aSched  = mkAppointment 8 10 0 nothing nothing 0 90 ApScheduled nothing 1 0 nothing
aOther  = mkAppointment 9 20 0 nothing nothing 0 90 ApNoShow    nothing 1 0 nothing

_ : reliabilityOf 10 (pOursKept ∷ pOursBroken ∷ pTheirsKept ∷ pTheirsBroken ∷ pPending ∷ pOther ∷ [])
                     (aNoShow ∷ aSched ∷ aOther ∷ [])
      ≡ mkReliability 1 1 1 1 1
_ = refl
