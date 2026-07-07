{-# OPTIONS --without-K #-}

-- CxmUI.Widget — the shared widget vocabulary (Ф4.2): ONE error formatter, ONE empty-state
-- convention, ONE toolbar shape, so every cxm-ui widget speaks the same status language and a
-- site styles it once (`cxm-toolbar`/`cxm-load`/`cxm-status`). Status line carries all three
-- transient states: "загрузка …" while a request is in flight, `errText` on failure, and the
-- widget's empty-message when a load returns [] (via `emptyOr`) — "" otherwise.
module CxmUI.Widget where

open import Data.Bool using (if_then_else_)
open import Data.Nat using (ℕ; _<ᵇ_)
open import Data.Nat.DivMod using (_/_; _%_)
open import Data.Nat.Show using (show)
open import Data.String using (String; _++_)
open import Data.List using (List; []; _∷_; [_])

open import Agdelte.Reactive.Node

open import Agda.Builtin.String using (primStringEquality)
open import CxmUI.Contract using (ContentView; cnPayload; cnAuthor; cnAuthorName)
open import CxmUI.Client using (CallErr; httpErr; serverErr; decodeErr; aeCode)
open import CxmUI.Text

-- uniform user-facing error line (was copy-pasted per widget)
errText : CallErr → String
errText (httpErr s)   = tErrNet ++ s
errText (serverErr e) = tErrServer ++ aeCode e
errText (decodeErr s) = tErrDecode ++ s

-- kopecks → "500.00" — money formatting is shared vocabulary. ⚠ Предполагает валюту со 100
-- minor units (RUB/USD/EUR); JPY (0 знаков) / KWD (3) потребуют параметризации по exponent —
-- сделать при первой не-2-значной валюте (аудит-5 №6).
showAmount : ℕ → String
showAmount p = show (p / 100) ++ "." ++ (if (p % 100) <ᵇ 10 then "0" else "") ++ show (p % 100)

-- empty-state convention: the given message when the loaded list is empty, "" otherwise
emptyOr : ∀ {A : Set} → String → List A → String
emptyOr msg [] = msg
emptyOr _   (_ ∷ _) = ""

-- the standard widget toolbar: one action button + the status line
toolbar : ∀ {Model Msg : Set} → String → Msg → (Model → String) → Node Model Msg
toolbar label msg status =
  div (class "cxm-toolbar" ∷ [])
    ( button (onClick msg ∷ class "cxm-load" ∷ []) [ text label ]
    ∷ span (class "cxm-status" ∷ []) [ bindF status ] ∷ [] )

-- the default payload renderer of the social widgets: verbatim opaque JSON. Model/Msg-agnostic
-- (a text node dispatches nothing), so ONE definition serves Feed/Thread/Showcase (аудит-2 №13);
-- a site swaps it via the `*AppWith` builders.
verbatimPayload : ∀ {Model Msg : Set} → ContentView → Node Model Msg
verbatimPayload c = span (class "cxm-post-payload" ∷ []) [ text (cnPayload c) ]

-- author line of a social row: the server-joined display name, «автор #id» as the fallback
-- (no author resolved / erased subject) — аудит-4 №2
authorLabel : ContentView → String
authorLabel c = if primStringEquality (cnAuthorName c) ""
                  then tAuthor ++ show (cnAuthor c)
                  else cnAuthorName c
