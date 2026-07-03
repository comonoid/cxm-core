{-# OPTIONS --without-K #-}

-- Compile-time tests for Cxm.Num (Phase 1 DoD): sentiment offset round-trip + clamp,
-- Permille clamp. `refl` here IS the test — typechecking proves it.
module Cxm.Test.NumTest where

open import Relation.Binary.PropositionalEquality using (_≡_; refl)
open import Data.Integer.Base using (ℤ; +_; -[1+_])

open import Cxm.Num

-- Round-trip on the signed range [−1000, 1000]: decode ∘ encode = id.
_ : decodeSentiment (encodeSentiment (+ 500)) ≡ + 500
_ = refl

_ : decodeSentiment (encodeSentiment (-[1+ 299 ])) ≡ -[1+ 299 ]   -- −300
_ = refl

_ : decodeSentiment (encodeSentiment (+ 0)) ≡ + 0
_ = refl

-- Neutral is the offset itself.
_ : encodeSentiment (+ 0) ≡ neutralSentiment
_ = refl

-- Endpoints.
_ : encodeSentiment (+ 1000) ≡ 2000
_ = refl

_ : encodeSentiment (-[1+ 999 ]) ≡ 0                              -- −1000
_ = refl

-- Out-of-range saturates (total for any ℤ).
_ : encodeSentiment (+ 5000) ≡ sentimentMax
_ = refl

_ : encodeSentiment (-[1+ 4999 ]) ≡ 0                             -- −5000
_ = refl

-- Permille clamp.
_ : clampPermille 1500 ≡ permilleMax
_ = refl

_ : clampPermille 300 ≡ 300
_ = refl
