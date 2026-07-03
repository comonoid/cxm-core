{-# OPTIONS --without-K #-}

-- Compile-time tests for Cxm.Inference (Phase 7 DoD): decay from different `now`, hypothesis
-- revision (confidence ↑/↓, REFUTED), and deterministic hypothesis generation. Because inference
-- is a PURE function of the event log, rebuild-from-scratch is deterministic by construction —
-- the concrete cases below pin that determinism; store-level rebuildHypotheses idempotence is a
-- runtime-harness check (it reads the store). `refl` IS the test.
module Cxm.Test.InferenceTest where

open import Relation.Binary.PropositionalEquality using (_≡_; refl)
open import Data.Maybe using (just; nothing)
open import Data.List using ([]; _∷_)
open import Data.Bool using (false)

open import Cxm.Knowledge
open import Cxm.Hypothesis using (hypothesize)
open import Cxm.Event
open import Cxm.Inference

------------------------------------------------------------------------
-- Decay from `now` (elapsed = now − validFrom; decay‰ per unit; floors at 0)
------------------------------------------------------------------------

_ : decayedConfidence 800 10 5 5 ≡ 800     -- no elapsed time → unchanged
_ = refl
_ : decayedConfidence 800 10 55 5 ≡ 300    -- elapsed 50 × decay 10 = 500 lost
_ = refl
_ : decayedConfidence 800 10 205 5 ≡ 0     -- fully decayed (floors at 0)
_ = refl

------------------------------------------------------------------------
-- Revision (confidence ↑/↓, status)
------------------------------------------------------------------------

hyp : Knowledge
hyp = hypothesize 10 1 700 "claim" 5 0

_ : kConfidence (strengthen 100 hyp) ≡ 800
_ = refl
_ : kConfidence (strengthen 500 hyp) ≡ 999      -- capped below 1000 (INFERRED invariant)
_ = refl
_ : kConfidence (weaken 300 hyp) ≡ 400
_ = refl
_ : kStatus (confirm hyp) ≡ CONFIRMED
_ = refl
_ : kStatus (refute hyp) ≡ REFUTED
_ = refl
_ : kConfidence (refute hyp) ≡ 0                 -- refuted → 0 but RETAINED (status REFUTED)
_ = refl

-- the STATED↔OBSERVED conflict signal is 0.4 (§4.16)
_ : conflictSignal ≡ 400
_ = refl

------------------------------------------------------------------------
-- Hypothesis generation (deterministic rules over the event stream)
------------------------------------------------------------------------

featReq : ExperienceEvent
featReq = mkExperienceEvent 1 10 1 Web Client 1700 FeatureRequest 0 nothing nothing nothing nothing false false "{}" nothing

-- a FEATURE_REQUEST ⇒ exactly one "unmet-need" hypothesis (conf 500) on the subject
_ : inferHypotheses (featReq ∷ []) ≡ hypothesize 10 1 500 "unmet-need" 10 1700 ∷ []
_ = refl

negEv : ExperienceEvent
negEv = mkExperienceEvent 2 10 1 Chat Client 1800 View 0 nothing (just 500) nothing nothing false false "{}" nothing

-- a below-neutral sentiment (500 < 1000) ⇒ one "at-risk" hypothesis (conf 400)
_ : inferHypotheses (negEv ∷ []) ≡ hypothesize 10 1 400 "at-risk" 50 1800 ∷ []
_ = refl

neutralEv : ExperienceEvent
neutralEv = mkExperienceEvent 3 10 1 Web Client 1900 View 0 nothing nothing nothing nothing false false "{}" nothing

-- a plain view with no annotation ⇒ no hypothesis
_ : inferHypotheses (neutralEv ∷ []) ≡ []
_ = refl

-- dedup (audit #B): two FEATURE_REQUESTs from the SAME subject ⇒ ONE hypothesis (first kept)
featReq2 : ExperienceEvent
featReq2 = mkExperienceEvent 4 10 1 Web Client 1701 FeatureRequest 0 nothing nothing nothing nothing false false "{}" nothing

_ : inferHypotheses (featReq ∷ featReq2 ∷ []) ≡ hypothesize 10 1 500 "unmet-need" 10 1700 ∷ []
_ = refl

-- but the SAME claim about a DIFFERENT subject is a distinct hypothesis (not deduped)
featReqOther : ExperienceEvent
featReqOther = mkExperienceEvent 5 20 1 Web Client 1702 FeatureRequest 0 nothing nothing nothing nothing false false "{}" nothing

_ : inferHypotheses (featReq ∷ featReqOther ∷ [])
      ≡ hypothesize 10 1 500 "unmet-need" 10 1700 ∷ hypothesize 20 1 500 "unmet-need" 10 1702 ∷ []
_ = refl
