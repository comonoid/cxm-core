{-# OPTIONS --without-K #-}

-- Query API (cxm-plan.md Phase 8, §4.17) — "who is the subject, what do we know, with what
-- confidence", plus the META-KPI: how WELL do we know them (coverage / freshness / share of
-- OBSERVED vs INFERRED — observed-vs-guessed). PURE over the knowledge snapshot (the store read
-- path passes `tscan knowledgeT`); testable and rebuildable. Pass the CANONICAL subject id
-- (resolve merge aliases via Cxm.Commands.canonicalOf) so pre/post-merge reads as one subject.
module Cxm.Query where

open import Data.Nat using (ℕ; zero; suc; _≡ᵇ_; _≤ᵇ_)
open import Data.Bool using (Bool; true; false; if_then_else_; _∧_)
open import Data.List using (List; []; _∷_; foldr; length)

open import Cxm.Knowledge
open import Cxm.Expectation using (Promise; pmSubject; pmDirection; pmStatus
                                  ; PromDirection; Ours; Theirs
                                  ; PromStatus; PromFulfilled; PromBroken)
open import Cxm.Appointment using (Appointment; apSubject; apStatus; ApptStatus; ApNoShow)
open import Cxm.Inference using (decayedConfidence)

private
  countᵇ : ∀ {A : Set} → (A → Bool) → List A → ℕ
  countᵇ p = foldr (λ x acc → if p x then suc acc else acc) zero

  filt : ∀ {A : Set} → (A → Bool) → List A → List A
  filt p = foldr (λ x acc → if p x then x ∷ acc else acc) []

  isActive : Knowledge → Bool          -- ACTIVE or CONFIRMED (live knowledge)
  isActive k with kStatus k
  ... | REFUTED    = false
  ... | SUPERSEDED = false
  ... | _          = true

  isObserved : Knowledge → Bool
  isObserved k with kSource k
  ... | OBSERVED = true
  ... | _        = false

  isInferred : Knowledge → Bool
  isInferred k with kSource k
  ... | INFERRED = true
  ... | _        = false

-- the live knowledge we hold about a subject
knownAbout : (subject : ℕ) → List Knowledge → List Knowledge
knownAbout subj = filt (λ k → (kSubject k ≡ᵇ subj) ∧ isActive k)

-- meta-KPI: how well do we know the subject (§4.17). NOTE (audit #B): `kpiObserved + kpiInferred
-- ≤ kpiTotal` — STATED and IMPORTED knowledge count toward coverage (total) but fall in NEITHER
-- the observed nor the inferred bucket; compute "observed share" against `kpiTotal` accordingly.
record MetaKPI : Set where
  constructor mkKPI
  field
    kpiTotal    : ℕ      -- coverage: live knowledge count
    kpiObserved : ℕ      -- items we OBSERVED (saw)
    kpiInferred : ℕ      -- items we INFERRED (guessed)
    kpiFresh    : ℕ      -- items still confident after decay (freshness): decayed-conf ≥ threshold

open MetaKPI public

metaKPI : (now threshold subject : ℕ) → List Knowledge → MetaKPI
metaKPI now thr subj ks =
  let mine = knownAbout subj ks in
  mkKPI (length mine)
        (countᵇ isObserved mine)
        (countᵇ isInferred mine)
        (countᵇ (λ k → thr ≤ᵇ decayedConfidence (kConfidence k) (kDecay k) now (kValidFrom k)) mine)

------------------------------------------------------------------------
-- Reliability scoring (Concept Ч.2 §3 п.3, upgrade-план A4): the TWO-SIDED "promised/kept"
-- account, first-class. Ours = how well WE keep promises to the subject; Theirs = how well the
-- subject keeps theirs (no-shows counted from Appointment statuses — the operational booking
-- record, решение 1). PURE over snapshots; the probability-of-default hypothesis (§3 п.3) is
-- inference-side policy over these counters, not schema.
------------------------------------------------------------------------

record Reliability : Set where
  constructor mkReliability
  field
    relOursKept     : ℕ    -- our promises to the subject, fulfilled
    relOursBroken   : ℕ    -- …broken (debits us on their trust account)
    relTheirsKept   : ℕ    -- the subject's promises, fulfilled
    relTheirsBroken : ℕ    -- …broken (late / non-payment)
    relNoShows      : ℕ    -- ApNoShow appointments (a broken client promise in booking form)

open Reliability public

private
  isOursᵇ isTheirsᵇ fulfilledᵇ brokenᵇ : Promise → Bool
  isOursᵇ p with pmDirection p
  ... | Ours = true
  ... | _    = false
  isTheirsᵇ p with pmDirection p
  ... | Theirs = true
  ... | _      = false
  fulfilledᵇ p with pmStatus p
  ... | PromFulfilled = true
  ... | _             = false
  brokenᵇ p with pmStatus p
  ... | PromBroken = true
  ... | _          = false

  isNoShowᵇ : Appointment → Bool
  isNoShowᵇ a with apStatus a
  ... | ApNoShow = true
  ... | _        = false

reliabilityOf : (subject : ℕ) → List Promise → List Appointment → Reliability
reliabilityOf subj ps as =
  mkReliability
    (countᵇ (λ p → (pmSubject p ≡ᵇ subj) ∧ isOursᵇ p ∧ fulfilledᵇ p) ps)
    (countᵇ (λ p → (pmSubject p ≡ᵇ subj) ∧ isOursᵇ p ∧ brokenᵇ p) ps)
    (countᵇ (λ p → (pmSubject p ≡ᵇ subj) ∧ isTheirsᵇ p ∧ fulfilledᵇ p) ps)
    (countᵇ (λ p → (pmSubject p ≡ᵇ subj) ∧ isTheirsᵇ p ∧ brokenᵇ p) ps)
    (countᵇ (λ a → (apSubject a ≡ᵇ subj) ∧ isNoShowᵇ a) as)
