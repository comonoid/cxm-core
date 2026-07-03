{-# OPTIONS --without-K #-}

-- Projections [ПР] (cxm-plan.md Phase 7, §4.13, §4.16, §8.3). PURE functions of the source
-- tables ([СОБ] events + [ВХ] write-model) — so every projection is rebuildable from scratch by
-- definition (there is no hidden state). Materialization into the store is a separate concern
-- (a projector/Txn); the truth is these functions.
--
--   * activeLines       — a subject's open (non-deleted) episodes (§4.9: N concurrent lines).
--   * decisionUnit      — the DecisionUnit projection: decision_consult edges touching the
--                          subject (§4.13); `seOrdinal` carries the consultation order.
--   * eventTypeSequence — the decision MACRO-model's raw sequence: a subject's event types in
--                          log order (§4.8 sequential analysis).
--   * subjectProfile    — an aggregate profile (§4.2 profile lens).
--
-- Merge aliases (§4.4): pass the CANONICAL subject id (resolve via Cxm.Commands.canonicalOf) so
-- pre-merge and post-merge experience read as one subject.
module Cxm.Projection where

open import Data.Nat using (ℕ; zero; suc; _≡ᵇ_)
open import Data.Bool using (Bool; true; false; if_then_else_; _∧_; _∨_)
open import Data.Maybe using (just; nothing)
open import Data.List using (List; []; _∷_; foldr)

open import Cxm.Knowledge
open import Cxm.Edge
open import Cxm.Event
open import Cxm.Episode

private
  countᵇ : ∀ {A : Set} → (A → Bool) → List A → ℕ
  countᵇ p = foldr (λ x acc → if p x then suc acc else acc) zero

  filt : ∀ {A : Set} → (A → Bool) → List A → List A
  filt p = foldr (λ x acc → if p x then x ∷ acc else acc) []

  isActiveK : Knowledge → Bool          -- ACTIVE or CONFIRMED (not REFUTED/SUPERSEDED)
  isActiveK k with kStatus k
  ... | REFUTED    = false
  ... | SUPERSEDED = false
  ... | _          = true

  liveEp : Episode → Bool
  liveEp e with epDeletedAt e
  ... | nothing = true
  ... | just _  = false

  isDecisionConsult : EdgeKind → Bool
  isDecisionConsult decision_consult = true
  isDecisionConsult _                = false

------------------------------------------------------------------------
-- Projections
------------------------------------------------------------------------

activeLines : (subject : ℕ) → List Episode → List Episode
activeLines subj = filt (λ e → (epSubject e ≡ᵇ subj) ∧ liveEp e)

decisionUnit : (subject : ℕ) → List SubjectEdge → List SubjectEdge
decisionUnit subj = filt (λ e → isDecisionConsult (seKind e) ∧ ((seFrom e ≡ᵇ subj) ∨ (seTo e ≡ᵇ subj)))

eventTypeSequence : (subject : ℕ) → List ExperienceEvent → List EventType
eventTypeSequence subj = foldr (λ ev acc → if eeSubject ev ≡ᵇ subj then eeType ev ∷ acc else acc) []

record Profile : Set where
  constructor mkProfile
  field
    pfSubject         : ℕ
    pfActiveKnowledge : ℕ      -- ACTIVE/CONFIRMED knowledge about the subject
    pfActiveEpisodes  : ℕ
    pfEventCount      : ℕ
open Profile public

subjectProfile : (subject : ℕ) → List Knowledge → List Episode → List ExperienceEvent → Profile
subjectProfile subj ks eps evs = mkProfile subj
  (countᵇ (λ k  → (kSubject k ≡ᵇ subj) ∧ isActiveK k) ks)
  (countᵇ (λ e  → (epSubject e ≡ᵇ subj) ∧ liveEp e) eps)
  (countᵇ (λ ev → eeSubject ev ≡ᵇ subj) evs)

------------------------------------------------------------------------
-- Peer loop / слой IX projections (upgrade-план B4). Pure, rebuild-from-scratch over the
-- append-only log. The REPUTATION/status of a participant is a PUBLIC fold of their peer
-- contribution (решение 2: a projection, not a stored entity); self-facing progress (§слой IX)
-- is the same fold served to the subject themself (Api /v1/me/progress).
------------------------------------------------------------------------

private
  isPeerEv : ExperienceEvent → Bool
  isPeerEv ev with eeActor ev
  ... | Peer = true
  ... | _    = false

  hasCounterpart : ExperienceEvent → Bool
  hasCounterpart ev with eeCounterpart ev
  ... | just _  = true
  ... | nothing = false

-- public contribution fold: peer events AUTHORED by the subject toward another client
contributionOf : (subject : ℕ) → List ExperienceEvent → ℕ
contributionOf subj = countᵇ (λ ev → (eeSubject ev ≡ᵇ subj) ∧ isPeerEv ev ∧ hasCounterpart ev)

-- co-support share (слой IX): of the events selected by `support?` (the caller's notion of a
-- support interaction — kept a PREDICATE so the core hardcodes no vertical semantics), how many
-- were peer-answered vs total. Returns (peer , total).
open import Data.Product using (_×_; _,_)
coSupportShare : (support? : ExperienceEvent → Bool) → List ExperienceEvent → ℕ × ℕ
coSupportShare support? evs =
  countᵇ (λ ev → support? ev ∧ isPeerEv ev) evs , countᵇ support? evs

-- negative peaks CREATED BY THE MECHANIC itself (status loss, слой IX): System-actor events on
-- the Community channel marked as peaks — the mechanic's cost side, weighed like incidents.
statusDropPeaks : (subject : ℕ) → List ExperienceEvent → List ExperienceEvent
statusDropPeaks subj = filt (λ ev → (eeSubject ev ≡ᵇ subj) ∧ eeIsPeak ev ∧ isSystem ev ∧ isCommunity ev)
  where
    isSystem : ExperienceEvent → Bool
    isSystem ev with eeActor ev
    ... | System = true
    ... | _      = false
    isCommunity : ExperienceEvent → Bool
    isCommunity ev with eeChannel ev
    ... | Community = true
    ... | _         = false
