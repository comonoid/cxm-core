{-# OPTIONS --without-K #-}

-- Fixed-point numbers for the CXM core (cxm-plan.md Phase 1, §9.7). Everything is ℕ so
-- values stay indexable (secondary-index keys via `keyOf` are ℕ-only, §8.1).
--
--   * Permille — a 0..1000 fixed-point fraction, used for `confidence` and `decay`.
--     (1000 = 1.0 = full confidence; 0 = 0.0.)
--   * Sentiment — the signed range −1..1 is stored OFFSET into ℕ 0..2000 (offset 1000),
--     so it is indexable while still representing a sign. The domain value is a ℤ in
--     [−1000, 1000] permille; `encodeSentiment`/`decodeSentiment` are round-trip inverses
--     on that range (clamped outside it).
--
-- No postulate / primTrustMe / TERMINATING (a core convention). Arithmetic is total.
module Cxm.Num where

open import Data.Nat using (ℕ; _⊓_)
open import Data.Integer.Base using (ℤ; +_; _+_; _-_; ∣_∣) renaming (_⊓_ to _⊓ℤ_; _⊔_ to _⊔ℤ_)

------------------------------------------------------------------------
-- Permille (0..1000 fixed-point fraction) — confidence / decay
------------------------------------------------------------------------

Permille : Set
Permille = ℕ

-- The upper bound. Full confidence (= 1.0). A FACT carries exactly this (§4.1).
permilleMax : Permille
permilleMax = 1000

fullConfidence : Permille
fullConfidence = permilleMax

zeroConfidence : Permille
zeroConfidence = 0

-- Clamp an arbitrary ℕ into 0..1000 (the low end is free — ℕ ≥ 0). Total.
clampPermille : ℕ → Permille
clampPermille n = n ⊓ permilleMax

------------------------------------------------------------------------
-- Sentiment: signed −1..1 permille, stored offset into ℕ 0..2000
------------------------------------------------------------------------

-- The stored, index-friendly form: ℕ in 0..2000. 1000 = neutral, 0 = −1.0, 2000 = +1.0.
Sentiment : Set
Sentiment = ℕ

sentimentOffset : ℕ
sentimentOffset = 1000

sentimentMax : ℕ
sentimentMax = 2000

-- Neutral sentiment (signed 0). Stored as the offset itself.
neutralSentiment : Sentiment
neutralSentiment = sentimentOffset

-- Signed permille value z ∈ [−1000, 1000] → stored ℕ. Clamped to [0, 2000] so it is
-- total for any ℤ (out-of-range inputs saturate at the ends).
encodeSentiment : ℤ → Sentiment
encodeSentiment z = ∣ (+ 0) ⊔ℤ ((+ sentimentMax) ⊓ℤ (z + (+ sentimentOffset))) ∣

-- Stored ℕ → signed permille value. Inverse of `encodeSentiment` on [−1000, 1000].
decodeSentiment : Sentiment → ℤ
decodeSentiment n = (+ n) - (+ sentimentOffset)
