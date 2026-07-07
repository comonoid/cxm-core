{-# OPTIONS --without-K #-}

-- CxmUI.Feed — the community feed widget (Ф3.1): content of authors the viewer follows,
-- newest-first (server-ordered). Locked rows are stripped teasers (payload = "") — the widget
-- renders lock chrome (`cxm-post-locked`/`cxm-post-teaser`); purchase flow is Ф3.4.
--
-- Site hooks (аудит №10): payload is the author's OPAQUE JSON — the default renders it
-- verbatim, but a real site parses its own payload format, so the template takes the payload
-- renderer as a parameter: mount `feedAppWith myPayloadView cfg`, or go further and compose a
-- custom template from the PUBLIC pieces (`Model`/`Msg`/`updateModel`/`cmdOf`/`postRowWith`).
-- `feedApp` = `feedAppWith` with the verbatim default. Model.limit (0 = всё) caps the read.
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
open import CxmUI.Text
open import CxmUI.Widget using (errText; emptyOr; toolbar; verbatimPayload)

record Model : Set where
  constructor mkModel
  field
    cfg    : V1Cfg
    limit  : ℕ                  -- page cap (0 = всё); сайт задаёт при маунте
    items  : List ContentView
    status : String
open Model public

initModel : V1Cfg → ℕ → Model
initModel c lim = mkModel c lim [] tFeedHint

data Msg : Set where
  Load : Msg
  Got  : Result CallErr (List ContentView) → Msg

updateModel : Msg → Model → Model
updateModel Load m = record m { status = tFeedLoading }
updateModel (Got (ok xs)) m = record m { items = xs ; status = emptyOr tFeedEmpty xs }
updateModel (Got (err e)) m = record m { status = errText e }

cmdOf : Msg → Model → Cmd Msg
cmdOf Load m = feed (cfg m) (limit m) Got
cmdOf _    _ = ε

-- one post row, payload rendering supplied by the site (default: verbatim text)
postRowWith : (ContentView → Node Model Msg) → ContentView → ℕ → Node Model Msg
postRowWith payloadView c _ =
  li (class ("cxm-post" ++ (if cnLocked c then " cxm-post-locked" else "")) ∷ [])
    ( span (class "cxm-post-author" ∷ []) [ text (tAuthor ++ show (cnAuthor c)) ]
    ∷ span (class "cxm-post-ts" ∷ []) [ text (tTs ++ show (cnCreatedAt c)) ]
    ∷ (if cnLocked c
        then span (class "cxm-post-teaser" ∷ []) [ text tLockedContent ]
        else payloadView c)
    ∷ [] )

feedTemplateWith : (ContentView → Node Model Msg) → Node Model Msg
feedTemplateWith payloadView =
  div (class "cxm-feed" ∷ [])
    ( toolbar tReload Load status
    ∷ ul [] ( foreachKeyed items (λ c → show (cnId c)) (postRowWith payloadView) ∷ [] )
    ∷ [] )

feedAppWith : (ContentView → Node Model Msg) → V1Cfg → (limit : ℕ) → ReactiveApp Model Msg
feedAppWith payloadView c lim =
  mkReactiveApp (initModel c lim) updateModel (feedTemplateWith payloadView) cmdOf (λ _ → never)

feedApp : V1Cfg → ReactiveApp Model Msg
feedApp c = feedAppWith verbatimPayload c 0
