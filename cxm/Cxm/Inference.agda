{-# OPTIONS --without-K #-}

-- Inference + revision (cxm-plan.md Phase 7, §4.16). Turns events into hypotheses and revises
-- them. The CORE is PURE functions of the event log (deterministic ⇒ rebuild-from-scratch is
-- correct by construction); a thin Txn command materializes the rebuild into the store.
--
--   * decayedConfidence / applyDecay — STATE/knowledge decays from the injected `now` (§1).
--   * strengthen / weaken / confirm / refute / supersede — confidence & status revision;
--     refutation is a move to REFUTED (retained, never deleted — §4.1). Confidence stays < 1000.
--   * conflictSignal — a STATED↔OBSERVED conflict is recorded as a SIGNAL (0.4 = 400‰), not an
--     overwrite (§4.16).
--   * inferHypotheses — rule-driven hypothesis generation over the event stream.
module Cxm.Inference where

open import Data.Nat using (ℕ; _+_; _∸_; _*_; _⊓_; _<ᵇ_; _≡ᵇ_)
open import Data.Bool using (Bool; true; false; if_then_else_; _∧_)
open import Data.Maybe using (maybe′)
open import Data.List using (List; []; _∷_; _++_; foldr; map)
open import Data.Product using (_×_; proj₁; proj₂)
open import Agda.Builtin.Unit using (⊤; tt)
open import Agda.Builtin.String using (primStringEquality)

open import Cxm.Num using (Permille; neutralSentiment)
open import Cxm.Knowledge
open import Cxm.Event
open import Cxm.Hypothesis using (hypothesize)

------------------------------------------------------------------------
-- Decay (pure; from `now`)
------------------------------------------------------------------------

-- confidence lost to staleness = decay‰ per elapsed time-unit; ℕ ∸ floors at 0 (total).
-- (`now`/`validFrom` are in the caller's chosen decay unit — the caller scales, §1.)
decayedConfidence : (conf decay now validFrom : ℕ) → Permille
decayedConfidence conf decay now vf = conf ∸ (decay * (now ∸ vf))

applyDecay : (now : ℕ) → Knowledge → Knowledge
applyDecay now k = record k { kConfidence = decayedConfidence (kConfidence k) (kDecay k) now (kValidFrom k) }

------------------------------------------------------------------------
-- Revision (pure Knowledge → Knowledge). Confidence stays < 1000 (INFERRED invariant, §4.1).
--
-- CONTRACT (audit #A): apply ONLY to INFERRED knowledge (hypotheses / inferred traits / states).
-- These operators do not inspect the epistemic type, so revising a FACT would break §4.1
-- (FACT ⇒ confidence = 1000) — e.g. `strengthen` caps at 999. Facts are not revised; they are
-- superseded by new facts. (Same discipline as Cxm.Knowledge's raw mkKnowledge.)
------------------------------------------------------------------------

strengthen : Permille → Knowledge → Knowledge          -- confirming evidence
strengthen d k = record k { kConfidence = (kConfidence k + d) ⊓ 999 }

weaken : Permille → Knowledge → Knowledge               -- disconfirming evidence
weaken d k = record k { kConfidence = kConfidence k ∸ d }

confirm : Knowledge → Knowledge                          -- promote status (still refutable)
confirm k = record k { kStatus = CONFIRMED }

refute : Knowledge → Knowledge                           -- refuted, RETAINED (not deleted, §4.1)
refute k = record k { kStatus = REFUTED ; kConfidence = 0 }

supersede : Knowledge → Knowledge
supersede k = record k { kStatus = SUPERSEDED }

------------------------------------------------------------------------
-- Conflict resolution: STATED ↔ OBSERVED (§4.16) — a signal, not an overwrite
------------------------------------------------------------------------

conflictSignal : Permille        -- the 0.4 signal recorded when stated and observed disagree
conflictSignal = 400

------------------------------------------------------------------------
-- Hypothesis generation (rule-driven; pure ⇒ deterministic rebuild)
------------------------------------------------------------------------

private
  -- a below-neutral sentiment annotation ⇒ an "at-risk" hypothesis
  atRisk : ExperienceEvent → List Knowledge
  atRisk e = maybe′ (λ s → if s <ᵇ neutralSentiment
                            then hypothesize (eeSubject e) (eeTenant e) 400 "at-risk" 50 (eeTimestamp e) ∷ []
                            else [])
                    [] (eeSentiment e)

-- rules for one event (0 or 1 hypothesis). A FEATURE_REQUEST ⇒ "unmet-need"; else a negative
-- sentiment ⇒ "at-risk". Hypotheses carry kId 0 (assigned on insert) and confidence < 1000.
ruleOf : ExperienceEvent → List Knowledge
ruleOf ev with eeType ev
... | FeatureRequest = hypothesize (eeSubject ev) (eeTenant ev) 500 "unmet-need" 10 (eeTimestamp ev) ∷ []
... | _              = atRisk ev

-- a hypothesis's IDENTITY is (subject, claim) — the same claim about the same subject is ONE
-- hypothesis, not one-per-triggering-event (audit #B). Dedup keeps the first, preserves order.
private
  sameClaim : Knowledge → Knowledge → Bool
  sameClaim a b = (kSubject a ≡ᵇ kSubject b) ∧ primStringEquality (kDetail a) (kDetail b)

  seenClaim : Knowledge → List Knowledge → Bool
  seenClaim _ []       = false
  seenClaim k (x ∷ xs) = if sameClaim k x then true else seenClaim k xs

  dedupBy : List Knowledge → List Knowledge → List Knowledge     -- seen → input → deduped
  dedupBy _    []       = []
  dedupBy seen (k ∷ ks) = if seenClaim k seen then dedupBy seen ks else k ∷ dedupBy (k ∷ seen) ks

inferHypotheses : List ExperienceEvent → List Knowledge
inferHypotheses evs = dedupBy [] (foldr (λ ev acc → ruleOf ev ++ acc) [] evs)

-- NB: this module stays PURE — its whole point is that inference is a deterministic function of
-- the event log, so the projection rebuilds from scratch (§4.16, §8.3). The WAL Txn wrapper
-- `rebuildHypotheses` was removed with the WAL backend (Postgres-only, 2026-07-07); a verb-world
-- port (`rebuildInferenceV` over Cxm.Store.Verbs: scan+del ACTIVE hyps → re-derive via
-- `inferHypotheses`) is a KNOWN post-cutover gap — the PG cabinet never carried it.
