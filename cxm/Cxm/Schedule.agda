{-# OPTIONS --without-K #-}

-- Generic availability + slot-conflict (cxm-plan.md Phase 6, §4.9, §9.6). PURE math over
-- intervals — no store, no vertical. A pack supplies only the calendar config (working hours,
-- slot length); the core owns "is this slot free?" and "which grid slots are free?". This is
-- the §9.6 decision: schedule math lives in the CORE, not duplicated per pack. Generalized
-- from the existing vertical pack's schedule math, de-identified. Times ℕ (unix sec), IO (§1).
module Cxm.Schedule where

open import Data.Nat using (ℕ; zero; suc; _+_; _*_; _∸_; _/_; _%_; _<ᵇ_; _≤ᵇ_; _≡ᵇ_)
open import Data.Bool using (Bool; true; false; _∧_; _∨_; not; if_then_else_)
open import Data.List using (List; []; _∷_; foldr; applyUpTo; upTo; concatMap)
open import Data.Maybe using (Maybe; just; nothing)
open import Data.String using (String)
open import Data.Product using (_×_; _,_; proj₁; proj₂)

-- a half-open interval [start, end)
Interval : Set
Interval = ℕ × ℕ

-- do two half-open intervals overlap? (s1 < e2 ∧ s2 < e1)
overlapsᵇ : Interval → Interval → Bool
overlapsᵇ (s1 , e1) (s2 , e2) = (s1 <ᵇ e2) ∧ (s2 <ᵇ e1)

-- is the slot [start, start+dur) free of every busy interval?
slotFree : (start dur : ℕ) → List Interval → Bool
slotFree start dur = foldr (λ iv acc → not (overlapsᵇ (start , start + dur) iv) ∧ acc) true

-- candidate slot starts: `start`, `start+step`, … (`n` of them)
grid : (start step n : ℕ) → List ℕ
grid _     _    zero    = []
grid start step (suc n) = start ∷ grid (start + step) step n

-- the grid slot-starts whose [start, start+dur) is free of all busy intervals
freeSlots : (gridStart slotLen count dur : ℕ) → List Interval → List ℕ
freeSlots gridStart slotLen count dur busy = go (grid gridStart slotLen count)
  where
    go : List ℕ → List ℕ
    go []          = []
    go (st ∷ rest) = if slotFree st dur busy then st ∷ go rest else go rest

anyᵇ : ∀ {A : Set} → (A → Bool) → List A → Bool
anyᵇ p []       = false
anyᵇ p (x ∷ xs) = p x ∨ anyᵇ p xs

------------------------------------------------------------------------
-- Calendar layer (§9.6, neutral): a working grid over real days + availability + validation.
-- The DURATION is a parameter (a pack's slot kind supplies it) — the core knows nothing about
-- Intro/Session/visit kinds. Times are unix seconds; the local calendar is pure arithmetic with
-- a fixed tz offset (no FFI clock), so a given `startsAt` always decomposes the same way.
------------------------------------------------------------------------

record Settings : Set where
  constructor mkSettings
  field
    setDayStart     : ℕ    -- minutes from local midnight (e.g. 10:00 = 600)
    setDayEnd       : ℕ    -- e.g. 19:00 = 1140
    setBufferMin    : ℕ    -- gap between slots, minutes
    setMinNoticeH   : ℕ    -- cannot book closer than N hours
    setCancelNoticeH : ℕ   -- free-cancel window before start, hours
    setHorizonDays  : ℕ    -- booking window forward, days
    setTzOffsetMin  : ℕ    -- offset from UTC, minutes
open Settings public

secPerDay : ℕ
secPerDay = 86400

localSec : Settings → ℕ → ℕ
localSec cfg t = t + setTzOffsetMin cfg * 60

localDay : Settings → ℕ → ℕ
localDay cfg t = localSec cfg t / secPerDay

-- days since 1970-01-01 → weekday 1=Mon..7=Sun (1970-01-01 was Thursday = 4)
weekday : ℕ → ℕ
weekday day = ((day + 3) % 7) + 1

isWorkday : ℕ → Bool                      -- Mon(1)..Fri(5)
isWorkday d = (1 ≤ᵇ d) ∧ (d ≤ᵇ 5)

atMinute : Settings → (day minute : ℕ) → ℕ   -- inverse: unix sec of local (day, minute)
atMinute cfg day minute = (day * secPerDay + minute * 60) ∸ setTzOffsetMin cfg * 60

-- the working grid of one local day for a slot of `durMin` minutes (empty on non-workdays).
-- The ONLY source of valid (start,end). Matching the divisor on `suc` exposes NonZero for `/`.
gridSlotsFor : Settings → (durMin day : ℕ) → List Interval
gridSlotsFor cfg durMin day =
  if isWorkday (weekday day) then applyUpTo mkSlot (nSlots step) else []
  where
    step = durMin + setBufferMin cfg
    span = (setDayEnd cfg ∸ durMin) ∸ setDayStart cfg
    nSlots : ℕ → ℕ
    nSlots zero    = 0
    nSlots (suc s) = if (setDayStart cfg + durMin) ≤ᵇ setDayEnd cfg then suc (span / suc s) else 0
    mkSlot : ℕ → Interval
    mkSlot i = let m = setDayStart cfg + i * step in
               (atMinute cfg day m , atMinute cfg day (m + durMin))

private
  earliest : Settings → (now : ℕ) → ℕ
  earliest cfg now = now + setMinNoticeH cfg * 3600

  daySlots : Settings → (durMin now : ℕ) → List Interval → (day : ℕ) → List Interval
  daySlots cfg durMin now busy day = go (gridSlotsFor cfg durMin day)
    where go : List Interval → List Interval
          go []       = []
          go (s ∷ ss) = if (earliest cfg now ≤ᵇ proj₁ s) ∧ not (anyᵇ (overlapsᵇ s) busy)
                        then s ∷ go ss else go ss

-- free slots over `days` days from the local day of `from`, minus min-notice and busy intervals
availabilityFrom : Settings → (durMin now from days : ℕ) → List Interval → List Interval
availabilityFrom cfg durMin now from days busy =
  concatMap (λ i → daySlots cfg durMin now busy (localDay cfg from + i)) (upTo days)

onGrid : Settings → (durMin start : ℕ) → Bool
onGrid cfg durMin start = anyᵇ (λ s → proj₁ s ≡ᵇ start) (gridSlotsFor cfg durMin (localDay cfg start))

-- a cancel is "free" iff it lands ≥ cancelNoticeH hours before the start
freeCancelWindow : Settings → (now startsAt : ℕ) → Bool
freeCancelWindow cfg now startsAt = (now + setCancelNoticeH cfg * 3600) ≤ᵇ startsAt

-- server-side slot validation: nothing = valid; just msg = rejection
validateSlot : Settings → (durMin now start : ℕ) → Maybe String
validateSlot cfg durMin now start =
  if not (onGrid cfg durMin start)                          then just "slot not available"
  else if start <ᵇ earliest cfg now                          then just "too close to start time"
  else if (now + setHorizonDays cfg * secPerDay) <ᵇ start     then just "beyond the booking horizon"
  else nothing
