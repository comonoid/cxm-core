{-# OPTIONS --without-K #-}

-- CxmUI.Widget — the shared widget vocabulary (Ф4.2): ONE error formatter, ONE empty-state
-- convention, ONE toolbar shape, so every cxm-ui widget speaks the same status language and a
-- site styles it once (`cxm-toolbar`/`cxm-load`/`cxm-status`). Status line carries all three
-- transient states: "загрузка …" while a request is in flight, `errText` on failure, and the
-- widget's empty-message when a load returns [] (via `emptyOr`) — "" otherwise.
module CxmUI.Widget where

open import Data.String using (String; _++_)
open import Data.List using (List; []; _∷_; [_])

open import Agdelte.Reactive.Node

open import CxmUI.Client using (CallErr; httpErr; serverErr; decodeErr; aeCode)

-- uniform user-facing error line (was copy-pasted per widget)
errText : CallErr → String
errText (httpErr s)   = "сеть: " ++ s
errText (serverErr e) = "сервер: " ++ aeCode e
errText (decodeErr s) = "разбор: " ++ s

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
