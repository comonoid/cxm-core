{-# OPTIONS --without-K #-}

-- Compile-time tests for Cxm.Schedule (Phase 6, §9.6). Pure interval math reduces under `refl`.
module Cxm.Test.ScheduleTest where

open import Relation.Binary.PropositionalEquality using (_≡_; refl)
open import Data.Bool using (true; false)
open import Data.List using (List; []; _∷_)
open import Data.Product using (_,_)

open import Cxm.Schedule

-- overlap of half-open intervals (touching endpoints do NOT overlap)
_ : overlapsᵇ (0 , 10) (5 , 15) ≡ true
_ = refl
_ : overlapsᵇ (0 , 10) (10 , 20) ≡ false
_ = refl

-- slotFree
_ : slotFree 0 10 [] ≡ true
_ = refl
_ : slotFree 0 10 ((5 , 15) ∷ []) ≡ false
_ = refl
_ : slotFree 20 5 ((5 , 15) ∷ []) ≡ true
_ = refl

-- grid of candidate starts
_ : grid 0 10 3 ≡ 0 ∷ 10 ∷ 20 ∷ []
_ = refl

-- freeSlots: [0,10) free, [10,20) collides with busy (10,20), [20,30) free
_ : freeSlots 0 10 3 10 ((10 , 20) ∷ []) ≡ 0 ∷ 20 ∷ []
_ = refl

------------------------------------------------------------------------
-- Calendar layer (neutral): weekday / workday / free-cancel window / non-workday grid
------------------------------------------------------------------------

cfg : Settings
cfg = mkSettings 600 1140 0 12 24 35 180     -- 10:00–19:00, notice 12h, cancel 24h, horizon 35d, МСК

_ : weekday 0 ≡ 4                              -- 1970-01-01 was Thursday
_ = refl
_ : weekday 4 ≡ 1                              -- day 4 = Monday
_ = refl
_ : isWorkday (weekday 4) ≡ true               -- Monday is a workday
_ = refl
_ : isWorkday (weekday 3) ≡ false              -- day 3 = Sunday, not a workday
_ = refl
_ : gridSlotsFor cfg 30 3 ≡ []                 -- no slots on a non-workday
_ = refl
_ : freeCancelWindow cfg 0 90000 ≡ true        -- 25h ahead ≥ 24h cancel notice
_ = refl
_ : freeCancelWindow cfg 0 36000 ≡ false       -- 10h ahead < 24h
_ = refl
