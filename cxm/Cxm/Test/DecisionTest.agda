{-# OPTIONS --without-K #-}

-- Compile-time tests for Cxm.Decision (Phase 8): triggers, priority, next-best-action ordering,
-- and internal-loop arbitration (external wins).
module Cxm.Test.DecisionTest where

open import Relation.Binary.PropositionalEquality using (_≡_; refl)
open import Data.Bool using (true; false)
open import Data.Maybe using (nothing)
open import Data.List using ([]; _∷_)

open import Cxm.Expectation
open import Cxm.Decision

-- triggers
_ : expectationUnmet (mkExpectation 1 10 1 "t" ExpCompetitor 0 ExpUnmet 0) ≡ true
_ = refl
_ : expectationUnmet (mkExpectation 2 10 1 "t" ExpCompetitor 0 ExpMet 0) ≡ false
_ = refl

-- pending promise past its deadline (100 < 200) is overdue; before it, or fulfilled, is not
_ : overduePromise 200 (mkPromise 1 10 1 "t" 100 PromPending nothing 0 Ours nothing false 0 nothing nothing false) ≡ true
_ = refl
_ : overduePromise 50  (mkPromise 2 10 1 "t" 100 PromPending nothing 0 Ours nothing false 0 nothing nothing false) ≡ false
_ = refl
_ : overduePromise 200 (mkPromise 3 10 1 "t" 100 PromFulfilled nothing 0 Ours nothing false 0 nothing nothing false) ≡ false
_ = refl

-- sentiment drift: two below-neutral samples (500,400 < 1000; 1500 is positive)
_ : sentimentDriftDown 2 (500 ∷ 400 ∷ 1500 ∷ []) ≡ true
_ = refl
_ : sentimentDriftDown 3 (500 ∷ 400 ∷ 1500 ∷ []) ≡ false
_ = refl

-- priority = confidence × leverage × risk
_ : priority 2 3 4 ≡ 24
_ = refl

-- next-best-action ordering (recovery > proactive > intervene > explore > exploit)
_ : decide true  false false 900 500 ≡ Recovery
_ = refl
_ : decide false true  false 900 500 ≡ ProactiveContact
_ = refl
_ : decide false false true  900 500 ≡ Intervene
_ = refl
_ : decide false false false 300 500 ≡ Explore        -- low confidence → go learn
_ = refl
_ : decide false false false 900 500 ≡ Exploit        -- confident → act
_ = refl

-- internal-loop arbitration: the external action wins when it fires
_ : arbitrate true  Recovery Intervene ≡ Recovery
_ = refl
_ : arbitrate false Recovery Intervene ≡ Intervene
_ = refl

-- gatherer (audit #A): next-best-action assembled from a subject's signals
unmet10 : Expectation
unmet10 = mkExpectation 1 10 1 "t" ExpCompetitor 0 ExpUnmet 0
overdue10 : Promise
overdue10 = mkPromise 1 10 1 "t" 100 PromPending nothing 0 Ours nothing false 0 nothing nothing false

-- an unmet expectation for subject 10 ⇒ Recovery (highest leverage)
_ : nextBestAction 200 10 900 500 2 (unmet10 ∷ []) [] [] ≡ Recovery
_ = refl
-- no expectation, but an overdue promise ⇒ ProactiveContact
_ : nextBestAction 200 10 900 500 2 [] (overdue10 ∷ []) [] ≡ ProactiveContact
_ = refl
-- signals for a DIFFERENT subject don't fire; low confidence ⇒ Explore
_ : nextBestAction 200 20 300 500 2 (unmet10 ∷ []) (overdue10 ∷ []) [] ≡ Explore
_ = refl
-- nothing firing, confident ⇒ Exploit
_ : nextBestAction 200 10 900 500 2 [] [] [] ≡ Exploit
_ = refl
