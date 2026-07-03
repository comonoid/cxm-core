{-# OPTIONS --without-K #-}

-- PsychCxm.Client — the reusable frontend SDK for the /psych/* + /payments/* API on agdelte-cxm
-- (the WIRE PROTOCOL, no UI): request-body builders + response decoders for the {data}/{error}
-- envelope + Slot/BookOutcome/SessionAction + endpoint paths. The contract is identical to the
-- legacy Psych.Client (CXM kept the paths+JSON), so a site's booking widget reuses this verbatim;
-- the only difference is SlotType comes from PsychCxm.Catalog. Pure / JS-safe.
module PsychCxm.Client where

open import Data.Nat using (ℕ)
open import Data.Nat.Show using (show)
open import Data.String using (String) renaming (_++_ to _<>_)
open import Data.List using (List; []; _∷_)
open import Data.Product using (_×_; _,_)

open import Agdelte.Json using
  ( Decoder; field′; nat; string; list; map2; mapDecoder; oneOf
  ; encodeToString; encodeString )

open import PsychCxm.Catalog using (SlotType; Intro; Session)

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

Slot : Set
Slot = ℕ × ℕ                       -- (startUnix , endUnix)

data BookOutcome : Set where
  BookOk  : ℕ → BookOutcome         -- booking id
  BookErr : String → BookOutcome    -- API error message

------------------------------------------------------------------------
-- Endpoint paths
------------------------------------------------------------------------

availPath : String
availPath = "/psych/availability"

bookPath : String
bookPath = "/psych/book"

------------------------------------------------------------------------
-- Request bodies (q = JSON-quoted+escaped via the Json encoder)
------------------------------------------------------------------------

q : String → String
q s = encodeToString encodeString s

typeStr : SlotType → String
typeStr Intro   = "intro"
typeStr Session = "session"

availBody : SlotType → String
availBody ty = "{\"type\":" <> q (typeStr ty) <> "}"

bookBody : SlotType → (start : ℕ) → (name email : String) → String
bookBody ty start name email =
  "{\"type\":"    <> q (typeStr ty)
  <> ",\"start\":" <> show start
  <> ",\"name\":"  <> q name
  <> ",\"email\":" <> q email <> "}"

sessionPath : String
sessionPath = "/psych/session"

sessionBody : (eng start : ℕ) → String
sessionBody eng start = "{\"eng\":" <> show eng <> ",\"start\":" <> show start <> "}"

purchasePath : String
purchasePath = "/psych/purchase"

purchaseBody : (offering : ℕ) → (name email : String) → String
purchaseBody offering name email =
  "{\"offering\":" <> show offering <> ",\"name\":" <> q name <> ",\"email\":" <> q email <> "}"

packagePath : String
packagePath = "/psych/package"

packageBody : (eng : ℕ) → String
packageBody eng = "{\"eng\":" <> show eng <> "}"

-- (sessionsTotal , sessionsLeft)
pkgStatusDec : Decoder (ℕ × ℕ)
pkgStatusDec = field′ "data" (map2 (λ t l → t , l) (field′ "sessionsTotal" nat) (field′ "sessionsLeft" nat))

paymentCreatePath : String
paymentCreatePath = "/payments/create"

payUrlDec : Decoder String
payUrlDec = field′ "data" (field′ "confirmationUrl" string)

------------------------------------------------------------------------
-- Session close-out actions (operator side): cancel / complete / no-show / reopen.
------------------------------------------------------------------------

data SessionAction : Set where
  Complete : SessionAction
  NoShow   : SessionAction
  Cancel   : SessionAction
  Reopen   : SessionAction

actionPath : SessionAction → String
actionPath Complete = "/psych/complete"
actionPath NoShow   = "/psych/no-show"
actionPath Cancel   = "/psych/cancel"
actionPath Reopen   = "/psych/reopen"

actBody : (activityId : ℕ) → String
actBody act = "{\"act\":" <> show act <> "}"

------------------------------------------------------------------------
-- Response decoders ({data}/{error} envelope)
------------------------------------------------------------------------

slotDec : Decoder Slot
slotDec = map2 (λ s e → s , e) (field′ "start" nat) (field′ "end" nat)

slotsDec : Decoder (List Slot)
slotsDec = field′ "data" (list slotDec)

bookDec : Decoder BookOutcome
bookDec = oneOf
  ( mapDecoder BookOk  (field′ "data"  (field′ "id"      nat))
  ∷ mapDecoder BookErr (field′ "error" (field′ "message" string))
  ∷ [] )
