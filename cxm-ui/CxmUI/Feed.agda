{-# OPTIONS --without-K #-}

-- CxmUI.Feed — the community feed widget (Ф3.1): content of authors the viewer follows,
-- newest-first (server-ordered). Locked rows are stripped teasers (payload = "") — the widget
-- renders lock chrome (`cxm-post-locked`/`cxm-post-teaser`); purchase flow is Ф3.4. Payload is
-- the author's OPAQUE JSON — rendered verbatim; a site restyles/parses it (brand side).
-- Brand-neutral; a site mounts `feedApp v1cfg` (V1Cfg = integration token + viewer identity).
module CxmUI.Feed where

open import Data.Bool using (if_then_else_)
open import Data.Nat using (ℕ)
open import Data.Nat.Show using (show)
open import Data.String using (String; _++_)
open import Data.List using (List; []; _∷_; [_])

open import Agdelte.Core.Result using (Result; ok; err)
open import Agdelte.Core.Cmd using (Cmd; ε)
open import Agdelte.Core.Event using (never)
open import Agdelte.Reactive.Node

open import CxmUI.Contract
open import CxmUI.Client

record Model : Set where
  constructor mkModel
  field
    cfg    : V1Cfg
    items  : List ContentView
    status : String
open Model public

initModel : V1Cfg → Model
initModel c = mkModel c [] "нажми «Обновить» — лента подписок"

data Msg : Set where
  Load : Msg
  Got  : Result CallErr (List ContentView) → Msg

private
  errStr : CallErr → String
  errStr (httpErr s)   = "сеть: " ++ s
  errStr (serverErr e) = "сервер: " ++ aeCode e
  errStr (decodeErr s) = "разбор: " ++ s

updateModel : Msg → Model → Model
updateModel Load m = record m { status = "загрузка ленты…" }
updateModel (Got (ok xs)) m = record m { items = xs ; status = "" }
updateModel (Got (err e)) m = record m { status = errStr e }

cmdOf : Msg → Model → Cmd Msg
cmdOf Load m = feed (cfg m) Got
cmdOf _    _ = ε

private
  postRow : ContentView → ℕ → Node Model Msg
  postRow c _ = li (class ("cxm-post" ++ (if cnLocked c then " cxm-post-locked" else "")) ∷ [])
    ( span (class "cxm-post-author" ∷ []) [ text ("автор #" ++ show (cnAuthor c)) ]
    ∷ span (class "cxm-post-ts" ∷ []) [ text ("t=" ++ show (cnCreatedAt c)) ]
    ∷ (if cnLocked c
        then span (class "cxm-post-teaser" ∷ []) [ text "🔒 закрытый контент" ]
        else span (class "cxm-post-payload" ∷ []) [ text (cnPayload c) ])
    ∷ [] )

feedTemplate : Node Model Msg
feedTemplate =
  div (class "cxm-feed" ∷ [])
    ( div (class "cxm-toolbar" ∷ [])
        ( button (onClick Load ∷ class "cxm-load" ∷ []) [ text "Обновить" ]
        ∷ span (class "cxm-status" ∷ []) [ bindF status ] ∷ [] )
    ∷ ul [] ( foreachKeyed items (λ c → show (cnId c)) postRow ∷ [] )
    ∷ [] )

feedApp : V1Cfg → ReactiveApp Model Msg
feedApp c = mkReactiveApp (initModel c) updateModel feedTemplate cmdOf (λ _ → never)
