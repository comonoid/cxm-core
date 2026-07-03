{-# OPTIONS --without-K #-}

-- Decision API (cxm-plan.md Phase 8, §4.17) — "what to do next". PURE trigger/priority logic
-- over the projected state (the store read path supplies the signals). Triggers/thresholds:
-- expectation gap → recovery; overdue promise → proactive contact; sentiment drift → intervene;
-- low confidence → explore ("go learn"); else exploit. Prioritization = f(confidence × leverage
-- × risk). Internal-loop arbitration: the EXTERNAL action WINS (§4.17, Ч2 §8.4).
module Cxm.Decision where

open import Data.Nat using (ℕ; zero; suc; _*_; _<ᵇ_; _≤ᵇ_; _≡ᵇ_)
open import Data.Bool using (Bool; true; false; if_then_else_; _∧_; _∨_)
open import Data.List using (List; []; _∷_; foldr)

open import Cxm.Num using (neutralSentiment)
open import Cxm.Expectation using (Expectation; xpSubject; xpStatus; ExpStatus; ExpUnmet
                                  ; Promise; pmSubject; pmStatus; pmDeadline; PromStatus; PromPending)

------------------------------------------------------------------------
-- Next-best-action
------------------------------------------------------------------------

data Action : Set where
  Recovery         : Action   -- expectation gap — the highest-leverage move (deliberately shapes memory, 0.3)
  ProactiveContact : Action   -- an overdue promise
  Intervene        : Action   -- sentiment drifting down
  Explore          : Action   -- low confidence → collect evidence ("go learn", explore/exploit)
  Exploit          : Action   -- confident → act
  NoAction         : Action

------------------------------------------------------------------------
-- Triggers (pure predicates)
------------------------------------------------------------------------

expectationUnmet : Expectation → Bool                 -- gap: an unmet expectation
expectationUnmet x with xpStatus x
... | ExpUnmet = true
... | _        = false

private
  isPending : PromStatus → Bool
  isPending PromPending = true
  isPending _           = false

overduePromise : (now : ℕ) → Promise → Bool           -- pending AND past its deadline
overduePromise now p = isPending (pmStatus p) ∧ (pmDeadline p <ᵇ now)

-- sentiment drift: at least `n` below-neutral samples in the recent window (offset sentiments)
sentimentDriftDown : (n : ℕ) → List ℕ → Bool
sentimentDriftDown n samples =
  n ≤ᵇ foldr (λ s acc → if s <ᵇ neutralSentiment then suc acc else acc) zero samples

------------------------------------------------------------------------
-- Prioritization + decision + arbitration
------------------------------------------------------------------------

-- attention = f(confidence × leverage × risk-of-churn) (§4.17). Caller normalizes the scale.
priority : (confidence leverage risk : ℕ) → ℕ
priority c l r = c * l * r

-- next-best-action by descending leverage: recovery > proactive > intervene > explore > exploit
decide : (gapUnmet overdueP driftDown : Bool) (confidence threshold : ℕ) → Action
decide gapUnmet overdueP driftDown conf thr =
  if gapUnmet then Recovery
  else if overdueP then ProactiveContact
  else if driftDown then Intervene
  else if conf <ᵇ thr then Explore
  else Exploit

-- internal loop under arbitration: when an external action fires it WINS over the internal one
arbitrate : (externalFires : Bool) (external internal : Action) → Action
arbitrate true  ext _   = ext
arbitrate false _   int = int

------------------------------------------------------------------------
-- Gatherer: next-best-action for a subject from its projected signals (audit #A). PURE over
-- lists (the store read path supplies them via scans), so the Decision API is reachable AND
-- testable. `sentiments` are the subject's recent offset sentiments (Cxm.Num).
------------------------------------------------------------------------

anyExpUnmet : (subject : ℕ) → List Expectation → Bool
anyExpUnmet subj = foldr (λ x acc → ((xpSubject x ≡ᵇ subj) ∧ expectationUnmet x) ∨ acc) false

anyOverduePromise : (now subject : ℕ) → List Promise → Bool
anyOverduePromise now subj = foldr (λ p acc → ((pmSubject p ≡ᵇ subj) ∧ overduePromise now p) ∨ acc) false

nextBestAction : (now subject confidence threshold driftN : ℕ)
               → List Expectation → List Promise → List ℕ → Action
nextBestAction now subj conf thr driftN xps proms sentiments =
  decide (anyExpUnmet subj xps) (anyOverduePromise now subj proms)
         (sentimentDriftDown driftN sentiments) conf thr
