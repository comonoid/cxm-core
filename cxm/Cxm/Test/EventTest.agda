{-# OPTIONS --without-K #-}

-- Compile-time tests for Cxm.Event (Phase 3 DoD): an event with and without the optional
-- experience annotations. `refl` IS the test.
module Cxm.Test.EventTest where

open import Relation.Binary.PropositionalEquality using (_≡_; refl)
open import Data.Maybe using (Maybe; just; nothing)
open import Data.Bool using (false; true)

open import Cxm.Event
open import Cxm.Num using (encodeSentiment; neutralSentiment)
open import Data.Integer.Base using (+_)

-- Bare event: no episode, no sentiment/emotion/effort, not a peak/end.
bare : ExperienceEvent
bare = mkExperienceEvent 1 10 1 Web Client 1700000000 View 0
         nothing nothing nothing nothing false false "{}" nothing

_ : eeSentiment bare ≡ nothing
_ = refl

_ : eeEpisode bare ≡ nothing
_ = refl

-- Fully annotated event: an episode, a positive sentiment, marked as a peak.
annotated : ExperienceEvent
annotated = mkExperienceEvent 2 10 1 Chat Client 1700000100 FeatureUse 3
              (just 99) (just (encodeSentiment (+ 800))) (just "delight") (just 2) true false "{\"f\":1}" nothing

_ : eeSentiment annotated ≡ just (encodeSentiment (+ 800))
_ = refl

_ : eeIsPeak annotated ≡ true
_ = refl

_ : eeEpisode annotated ≡ just 99
_ = refl
