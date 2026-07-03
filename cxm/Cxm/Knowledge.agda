{-# OPTIONS --without-K #-}

-- The epistemic envelope `Knowledge` (cxm-plan.md Phase 1, description §4.1, principle 3).
-- Every unit of knowledge about a subject is wrapped so its epistemic status is FIRST-CLASS
-- in the types, not a comment: FACT / HYPOTHESIS / STATE / TRAIT, its source, confidence,
-- validity window, decay and lifecycle status.
--
-- CONVENTION — work strategies (Concept VIII.a, upgrade-план C2): a key colleague's/client's
-- working preferences (sync vs async, big-picture-first vs details-first, what makes a handoff
-- "complete" for them) are an ordinary TRAIT envelope with
--   kDetail = {"kind":"work_strategy","sync":…,"detail_first":…,"handoff_complete_when":…}
-- (opaque JSON, core does not index it — §8.1). Applies to INTERNAL subjects too (the key-
-- colleague profile): one model, two payoffs — client experience / chain efficiency.
--
-- Invariants (§4.1), enforced BY CONSTRUCTION via smart constructors:
--   * FACT ⇒ confidence = 1000 (full) ∧ source ∈ {OBSERVED, IMPORTED}.
--   * INFERRED ⇒ confidence < 1000 (evidence ≠ ∅ is checked at COMMAND level, Phase 8/9,
--     since `evidence` is a child table, not a field — §8.1).
-- Refutation is a move to REFUTED, never a delete (knowledge is retained).
module Cxm.Knowledge where

open import Data.Nat using (ℕ; _<?_)
open import Data.Maybe using (Maybe; nothing)
open import Data.String using (String)
open import Relation.Nullary.Decidable using (True)

open import Cxm.Num using (Permille; fullConfidence; permilleMax)
open import Cxm.Tenant using (TenantId)

------------------------------------------------------------------------
-- Epistemic dimensions (§4.1). The stability/observability axes of the Concept
-- (Ч1 §2) are folded into these two enums, not separate fields (§4.19).
------------------------------------------------------------------------

data EpistemicType : Set where
  FACT       : EpistemicType   -- objective assertion (confidence = 1)
  HYPOTHESIS : EpistemicType   -- inferred, refutable
  STATE      : EpistemicType   -- fast-decaying situational knowledge
  TRAIT      : EpistemicType   -- slow-changing profile knowledge

data Source : Set where
  OBSERVED : Source            -- seen in an event
  INFERRED : Source            -- derived by inference (⇒ confidence < 1)
  STATED   : Source            -- asserted by the subject/operator
  IMPORTED : Source            -- brought in from an external system

data KStatus : Set where
  ACTIVE     : KStatus
  CONFIRMED  : KStatus
  REFUTED    : KStatus         -- refuted, but retained (not deleted)
  SUPERSEDED : KStatus

------------------------------------------------------------------------
-- The envelope. `evidence` is NOT a field — it is a child table (Evidence, Phase 4),
-- because Schema is atomic-columnar (§8.1). Time is from IO: `kValidFrom`/`kValidTo`
-- and decay are interpreted against a `now` passed at the boundary (§1), never read here.
--
-- CONTRACT — construct via the smart constructors, not the raw one (audit finding #1). The
-- §4.1 invariants are enforced by `mkFact`/`mkInferred` below, NOT by the type: `mkKnowledge`
-- is the unchecked record constructor and can build an inconsistent envelope (e.g. FACT with
-- source INFERRED and confidence 500). It is public ONLY because the codec (Cxm.Wire.
-- knowledgeFromRow) must faithfully reconstruct any stored row; a proof-carrying record would
-- make round-trip decode intractable. Domain writes (commands, Phase 8/9) MUST route through
-- the smart constructors; `mkKnowledge` is for the codec and internal use only.
------------------------------------------------------------------------

record Knowledge : Set where
  constructor mkKnowledge
  field
    kId         : ℕ              -- internal primary key
    kSubject    : ℕ              -- subject_id this knowledge is about
    kTenant     : TenantId       -- §7.1 tenant axis
    kType       : EpistemicType
    kSource     : Source
    kConfidence : Permille       -- 0..1000 (FACT = 1000)
    kValidFrom  : ℕ              -- unix seconds
    kValidTo    : Maybe ℕ        -- nothing = open-ended
    kDecay      : Permille       -- staleness rate (STATE fast / TRAIT slow)
    kStatus     : KStatus
    kDetail     : String         -- opaque claim/subvariant detail (JSON; "" = none). Carries WHAT
                                 -- the knowledge asserts — e.g. a Trait's convincer params
                                 -- (Cxm.Trait) or a hypothesis claim. Core does not index it (§8.1).
    kEpisode    : Maybe ℕ        -- optional episode binding (envelope §2 of the Concept: a fact
                                 -- may live at the EPISODE level — JTBD, a line's peak/end);
                                 -- nothing = subject-level. The binding level is a conscious
                                 -- per-fact decision (Ч.2 §3), not a mode.

open Knowledge public

------------------------------------------------------------------------
-- Smart constructors carrying the §4.1 invariants
------------------------------------------------------------------------

-- FACT source is restricted to {OBSERVED, IMPORTED} by type (not runtime check).
data FactSource : Set where
  FObserved : FactSource
  FImported : FactSource

factSource→Source : FactSource → Source
factSource→Source FObserved = OBSERVED
factSource→Source FImported = IMPORTED

-- A FACT: confidence is forced to 1000 and source restricted — the invariant cannot be
-- violated by any FACT that typechecks.
mkFact : (kId subject : ℕ) (tenant : TenantId) (src : FactSource) (detail : String)
         (validFrom : ℕ) (validTo : Maybe ℕ) (decay : Permille) (episode : Maybe ℕ) → Knowledge
mkFact i subj ten src detail vf vt dec ep =
  mkKnowledge i subj ten FACT (factSource→Source src) fullConfidence vf vt dec ACTIVE detail ep

-- Inferred knowledge: source = INFERRED and confidence < 1000, the latter proof-gated.
-- `True (conf <? permilleMax)` reduces to ⊤ exactly when conf < 1000, so the witness is
-- solved automatically for literal confidences and rejected otherwise. FACT is excluded
-- by taking a restricted epistemic type (an inferred value is never a FACT — §4.1).
data InferredType : Set where
  IHypothesis : InferredType
  IState      : InferredType
  ITrait      : InferredType

inferredType→Epistemic : InferredType → EpistemicType
inferredType→Epistemic IHypothesis = HYPOTHESIS
inferredType→Epistemic IState      = STATE
inferredType→Epistemic ITrait      = TRAIT

mkInferred : (kId subject : ℕ) (tenant : TenantId) (ty : InferredType)
             (conf : Permille) {pf : True (conf <? permilleMax)} (detail : String)
             (decay validFrom : ℕ) (validTo : Maybe ℕ) (episode : Maybe ℕ) → Knowledge
mkInferred i subj ten ty conf detail dec vf vt ep =
  mkKnowledge i subj ten (inferredType→Epistemic ty) INFERRED conf vf vt dec ACTIVE detail ep
