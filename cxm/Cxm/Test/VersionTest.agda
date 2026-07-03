{-# OPTIONS --without-K #-}

-- Compile-time tests for Cxm.Version (Phase 10 DoD): an old-version payload is upcast and reads;
-- Tier-1 tolerant decode equals strict decode on a full row; schema version register.
module Cxm.Test.VersionTest where

open import Relation.Binary.PropositionalEquality using (_≡_; refl)
open import Data.Maybe using (just; nothing)
open import Data.Bool using (true; false)

open import Cxm.Event using (ExperienceEvent; mkExperienceEvent; Web; Client; View; eePayload)
open import Cxm.Wire using (encExperienceEvent)
open import Cxm.Version

-- schema version register (per entity; all v1 today)
_ : currentVersion ≡ 1
_ = refl
_ : schemaVersion "experience_event" ≡ 1
_ = refl

-- event upcasting: a v0 payload (bare string) is rewritten to the current shape; v1 is untouched
_ : demoUpcast 0 "abc" ≡ "{\"legacy\":\"abc\"}"
_ = refl
_ : demoUpcast 1 "abc" ≡ "abc"
_ = refl

-- DoD: an OLD event's payload upcasts before decode (envelope untouched)
evOld : ExperienceEvent
evOld = mkExperienceEvent 1 10 1 Web Client 100 View 0 nothing nothing nothing nothing false false "raw:|" nothing

_ : eePayload (upcastEventPayload demoUpcast 0 evOld) ≡ "{\"legacy\":\"raw:|\"}"
_ = refl
_ : eePayload (upcastEventPayload idUpcast 0 evOld) ≡ "raw:|"      -- id upcast leaves it be
_ = refl

-- Tier-1 tolerant decode is byte-identical to strict decode on a FULL row (round-trips)
evFull : ExperienceEvent
evFull = mkExperienceEvent 7 10 1 Web Client 1700 View 3 (just 9) (just 1800) (just "e:|") (just 2) true false "{\"k\":1}" nothing

_ : decExperienceEventTolerant (encExperienceEvent evFull) ≡ just evFull
_ = refl

-- the "перед декодом" hook (audit #A): upcast the raw row, then decode. With idUpcast it is the
-- identity round-trip; the ordering (raw → upcast → decode) is what matters for real migrations.
_ : decodeEventUpcast idUpcast 1 (encExperienceEvent evFull) ≡ just evFull
_ = refl
