{-# OPTIONS --without-K #-}

-- `Cxm.Fulfilment` — the PURE interpreter of an Offering's fulfilment plan (платформа-план П3,
-- «fulfilment-as-data») — L2 (pure, no Store/FFI). An `Offering.oMetadata` carries a data plan
-- of what a purchase GRANTS; on payment success the command layer (`Cxm.Commands.fulfillOffering`)
-- reads THIS offering's stored plan and issues the declared Entitlements — so a buyer unlocks a
-- node WITHOUT an operator, and no privilege can be forged from the request (the plan is
-- server-side data, not client input).
--
-- ФОРМАТ (пример из плана): `{"grants":[{"kind":"resource","id":12},{"kind":"offering","id":3}]}`.
-- The parser is a TOLERANT tokenizer, NOT a JSON parser (the core has no pure JSON parser and L4
-- cannot import the FFI one): it splits on non-alphanumeric separators, then pairs each recognised
-- kind keyword (`resource`/`offering`/`membership`) with the NEXT number token. So the JSON above
-- and a compact `resource:12 offering:3` both yield the same grant list. Unknown words (`kind`,
-- `id`, `grants`, …) are skipped; a number with no pending kind is ignored. Total by construction.
--
-- ГРАНИЦА: promises-в-плане (план упоминает `"promises":[…]`) — ЗАКЛАДКА (промис несёт
-- topic/deadline — строки/числа за пределами kind:id-грамматики); П3 DoD = покупка УЗЛА, поэтому
-- реализованы гранты (resource/offering/membership). Промисы добавляются отдельной грамматикой.
-- ЗАПРЕТЫ (Г4): no Cxm.Store.* / Cxm.Commands / FFI imports.
module Cxm.Fulfilment where

open import Data.Nat using (ℕ; _+_; _*_; _∸_; _≤ᵇ_)
open import Data.Bool using (Bool; true; false; if_then_else_; _∧_; _∨_)
open import Data.List using (List; []; _∷_; reverse)
open import Data.Char using (Char)
open import Agda.Builtin.Char using (primCharToNat)
open import Data.Maybe using (Maybe; just; nothing; maybe′)
open import Data.String using (String; toList; fromList)
open import Agda.Builtin.String using (primStringEquality)

open import Cxm.Entitlement using (EntTarget; TOffering; TResource; TMembership)

-- one declared grant: a target kind + the id of the offering/resource/membership it unlocks
record Grant : Set where
  constructor mkGrant
  field
    gKind   : EntTarget
    gTarget : ℕ
open Grant public

private
  isDigitᶜ : Char → Bool
  isDigitᶜ c = let n = primCharToNat c in (48 ≤ᵇ n) ∧ (n ≤ᵇ 57)

  isAlphaᶜ : Char → Bool
  isAlphaᶜ c = let n = primCharToNat c in
    ((65 ≤ᵇ n) ∧ (n ≤ᵇ 90)) ∨ ((97 ≤ᵇ n) ∧ (n ≤ᵇ 122))

  wordCharᶜ : Char → Bool
  wordCharᶜ c = isDigitᶜ c ∨ isAlphaᶜ c

  -- split into maximal alphanumeric tokens, in order (separators dropped; no empty tokens)
  tokenize : List Char → List String
  tokenize cs = go cs []
    where
      emit : List Char → List String → List String        -- cur is reversed
      emit []  ts = ts
      emit cur ts = fromList (reverse cur) ∷ ts
      go : List Char → List Char → List String
      go []       cur = emit cur []
      go (c ∷ rest) cur =
        if wordCharᶜ c then go rest (c ∷ cur)
        else emit cur (go rest [])

  kindOf : String → Maybe EntTarget
  kindOf s = if primStringEquality s "resource"   then just TResource
             else if primStringEquality s "offering"   then just TOffering
             else if primStringEquality s "membership" then just TMembership
             else nothing

  -- a token is a nat iff it is all digits (tokens are alphanumeric, so validate)
  parseNat : String → Maybe ℕ
  parseNat s = go (toList s) 0 false
    where go : List Char → ℕ → Bool → Maybe ℕ
          go []       acc seen = if seen then just acc else nothing
          go (c ∷ cs) acc seen =
            if isDigitᶜ c then go cs (acc * 10 + (primCharToNat c ∸ 48)) true
            else nothing

  -- pair each pending kind keyword with the NEXT number token
  scanGrants : Maybe EntTarget → List String → List Grant
  scanGrants _    []       = []
  scanGrants pend (t ∷ ts) with kindOf t
  ... | just k  = scanGrants (just k) ts                   -- new kind (overrides a dangling one)
  ... | nothing with parseNat t
  ...   | just n  = maybe′ (λ k → mkGrant k n ∷ scanGrants nothing ts) (scanGrants nothing ts) pend
  ...   | nothing = scanGrants pend ts                     -- skip "kind"/"id"/"grants"/…

parseFulfilment : String → List Grant
parseFulfilment s = scanGrants nothing (tokenize (toList s))
