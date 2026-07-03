{-# OPTIONS --without-K #-}

-- PsychCxm.Catalog — the «В точку» service catalogue + calendar config as DATA (config-not-code,
-- §9). Slot kinds (Intro/Session) map to a duration; the working grid reuses Cxm.Schedule.Settings.
-- Everything domain here is pack config — the neutral core (Cxm.Schedule/Appointment) does the math.
module PsychCxm.Catalog where

open import Data.Nat using (ℕ; _*_)
open import Data.Nat.Show using (show; readMaybe)
open import Agda.Builtin.Nat using (_==_)
open import Data.String using (String)
open import Data.Maybe using (Maybe; just; nothing)
open import Data.List using (List; []; _∷_)
open import Data.Bool using (if_then_else_)

open import Cxm.Schedule using (Settings; mkSettings)

------------------------------------------------------------------------
-- Slot kinds (pack-specific; the core takes a duration in minutes, not a kind)
------------------------------------------------------------------------

data SlotType : Set where
  Intro   : SlotType
  Session : SlotType

durationMin : SlotType → ℕ
durationMin Intro   = 30
durationMin Session = 90

parseSlotType : String → Maybe SlotType
parseSlotType "intro"   = just Intro
parseSlotType "session" = just Session
parseSlotType _         = nothing

------------------------------------------------------------------------
-- Catalogue («В точку» brief): intro (free) / single / path-5 / path-10
------------------------------------------------------------------------

record Offering : Set where
  constructor mkOffering
  field
    oCode     : ℕ        -- offering code (= the episode's protocol, for packages)
    oLabel    : String
    oSlot     : SlotType  -- the session kind this offering grants
    oSessions : ℕ         -- prepaid sessions (1 / 5 / 10)
    oPriceKop : ℕ         -- price, kopecks

open Offering public

offerings : List Offering
offerings =
  mkOffering 0 "Разговор «осмотреться»"   Intro    1        0 ∷
  mkOffering 1 "Сессия «в точку»"         Session  1  1500000 ∷
  mkOffering 2 "Путь в точку — 5 встреч"  Session  5  6750000 ∷
  mkOffering 3 "Путь в точку — 10 встреч" Session 10 12000000 ∷
  []

offeringOf : ℕ → Maybe Offering
offeringOf code = go offerings
  where go : List Offering → Maybe Offering
        go []       = nothing
        go (o ∷ os) = if oCode o == code then just o else go os

------------------------------------------------------------------------
-- Package episodes: name of the (idempotently-seeded) package Protocol, and the offering-code
-- ↔ Episode.epJtbd codec so /psych/{session,package} recover the offering from a package episode.
------------------------------------------------------------------------

packageProtocol : String
packageProtocol = "psych.package"

jtbdFor : ℕ → String              -- store the offering code in the episode's jtbd
jtbdFor code = show code

offeringFromJtbd : String → Maybe Offering
offeringFromJtbd s with readMaybe 10 s
... | just code = offeringOf code
... | nothing   = nothing

------------------------------------------------------------------------
-- Calendar config: Пн–Пт 10:00–19:00 МСК, notice 12h, cancel 24h, horizon 35d, tz +180
------------------------------------------------------------------------

settings : Settings
settings = mkSettings (10 * 60) (19 * 60) 0 12 24 35 180
