{-# OPTIONS --without-K #-}

-- Compile-time tests for Cxm.Knowledge smart constructors (Phase 1 DoD): the §4.1
-- invariants hold by construction. `refl` IS the test.
module Cxm.Test.KnowledgeTest where

open import Relation.Binary.PropositionalEquality using (_≡_; refl)
open import Data.Maybe using (nothing)

open import Cxm.Num using (fullConfidence)
open import Cxm.Knowledge

-- FACT ⇒ confidence = 1000, source ∈ {OBSERVED, IMPORTED}, type = FACT.
factK : Knowledge
factK = mkFact 1 10 1 FObserved "claim" 1700000000 nothing 0 nothing

_ : kConfidence factK ≡ fullConfidence
_ = refl

_ : kType factK ≡ FACT
_ = refl

_ : kSource factK ≡ OBSERVED
_ = refl

_ : kSource (mkFact 2 10 1 FImported "claim" 1700000000 nothing 0 nothing) ≡ IMPORTED
_ = refl

-- INFERRED ⇒ source = INFERRED, confidence < 1000 (the `700 <? 1000` witness is solved
-- automatically). type comes from the InferredType (never FACT).
hypK : Knowledge
hypK = mkInferred 3 10 1 IHypothesis 700 "claim" 5 1700000000 nothing nothing

_ : kSource hypK ≡ INFERRED
_ = refl

_ : kType hypK ≡ HYPOTHESIS
_ = refl

_ : kConfidence hypK ≡ 700
_ = refl

-- A confidence of 1000 would make `True (1000 <? 1000)` reduce to ⊥, so `mkInferred … 1000 …`
-- does NOT typecheck — the invariant is enforced by construction, not by a runtime guard.
