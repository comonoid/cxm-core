{-# OPTIONS --without-K #-}

-- `Trait` (cxm-plan.md Phase 7, §4.8) — slow-changing profile knowledge, in the Knowledge
-- envelope (type TRAIT). [ВХ] if STATED / [ПР] if INFERRED. The structural subvariants — the
-- most important practical layer of CXM — are modelled here as data and serialized into the
-- envelope's opaque `kDetail`:
--   * Metaprogram — toward/away, internal/external ref, options/procedures, general/specific,
--     proactive/reactive, sameness/difference;
--   * Convincer — {channel: see|hear|read|do, mode: auto|n-times|period|every-time, n};
--   * (reality-strategy / decision-micro / working-strategies ride on the generic detail string).
-- The Decision MACRO-model is NOT a Trait — it is a projection over events (§4.8, Cxm.Projection).
module Cxm.Trait where

open import Data.Nat using (ℕ; _<?_)
open import Data.Nat.Show using (show)
open import Data.Maybe using (nothing)
open import Data.String using (String) renaming (_++_ to _<>_)
open import Relation.Nullary.Decidable using (True)

open import Cxm.Num using (Permille; permilleMax; clampPermille)
open import Cxm.Tenant using (TenantId)
open import Cxm.Knowledge

------------------------------------------------------------------------
-- Subvariant data
------------------------------------------------------------------------

data Metaprogram : Set where
  Toward Away         : Metaprogram   -- motivation direction
  IntRef ExtRef       : Metaprogram   -- reference (internal/external)
  Options Procedures  : Metaprogram
  GeneralMP SpecificMP : Metaprogram
  Proactive Reactive  : Metaprogram
  Sameness Difference : Metaprogram

data ConvChannel : Set where
  CvSee CvHear CvRead CvDo : ConvChannel

data ConvMode : Set where
  CvAuto CvNTimes CvPeriod CvEvery : ConvMode

record Convincer : Set where
  constructor mkConvincer
  field
    cvChannel : ConvChannel
    cvMode    : ConvMode
    cvN       : ℕ

open Convincer public

------------------------------------------------------------------------
-- Detail serializers (into the opaque kDetail; core does not decode — packs/AI do)
------------------------------------------------------------------------

metaCode : Metaprogram → String
metaCode Toward = "toward"     ; metaCode Away = "away"
metaCode IntRef = "int-ref"    ; metaCode ExtRef = "ext-ref"
metaCode Options = "options"   ; metaCode Procedures = "procedures"
metaCode GeneralMP = "general" ; metaCode SpecificMP = "specific"
metaCode Proactive = "proactive" ; metaCode Reactive = "reactive"
metaCode Sameness = "sameness" ; metaCode Difference = "difference"

metaDetail : Metaprogram → String
metaDetail m = "metaprogram:" <> metaCode m

chanCode : ConvChannel → String
chanCode CvSee = "see" ; chanCode CvHear = "hear" ; chanCode CvRead = "read" ; chanCode CvDo = "do"

modeCode : ConvMode → String
modeCode CvAuto = "auto" ; modeCode CvNTimes = "n-times" ; modeCode CvPeriod = "period" ; modeCode CvEvery = "every"

convincerDetail : Convincer → String
convincerDetail c = "convincer:" <> chanCode (cvChannel c) <> "/" <> modeCode (cvMode c) <> "/" <> show (cvN c)

------------------------------------------------------------------------
-- Constructors (kId 0 = assigned on insert)
------------------------------------------------------------------------

-- an INFERRED trait ([ПР]); conf < 1000 proof-gated
inferredTrait : (subject : ℕ) (tenant : TenantId) (conf : Permille) {pf : True (conf <? permilleMax)}
                (detail : String) (decay validFrom : ℕ) → Knowledge
inferredTrait subj ten conf {pf} detail dec vf = mkInferred 0 subj ten ITrait conf {pf} detail dec vf nothing nothing

-- a STATED trait ([ВХ]): the subject asserted it. Uses the raw envelope (source STATED); the
-- confidence is clamped to ≤ 1000. (Not proof-gated: STATED traits are not bound by INFERRED<1.)
statedTrait : (subject : ℕ) (tenant : TenantId) (conf : Permille) (detail : String)
              (decay validFrom : ℕ) → Knowledge
statedTrait subj ten conf detail dec vf =
  mkKnowledge 0 subj ten TRAIT STATED (clampPermille conf) vf nothing dec ACTIVE detail nothing

convincerTrait : (subject : ℕ) (tenant : TenantId) (conf : Permille) {pf : True (conf <? permilleMax)}
                 (c : Convincer) (decay validFrom : ℕ) → Knowledge
convincerTrait subj ten conf {pf} c dec vf = inferredTrait subj ten conf {pf} (convincerDetail c) dec vf

metaprogramTrait : (subject : ℕ) (tenant : TenantId) (conf : Permille) {pf : True (conf <? permilleMax)}
                   (m : Metaprogram) (decay validFrom : ℕ) → Knowledge
metaprogramTrait subj ten conf {pf} m dec vf = inferredTrait subj ten conf {pf} (metaDetail m) dec vf
