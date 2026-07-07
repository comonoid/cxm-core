{-# OPTIONS --without-K #-}

-- CxmUI.Showcase — the curated showcase widget (Ф3.3): the live-window, rank-ascending read
-- over resource links from a showcase node `from` (an expired paid slot vanishes by projection —
-- no worker involved). Rows are feed-shaped (ContentView, same locked/teaser semantics).
-- Curation writes are the OWNER's cabinet (`POST /resources/link|unlink`), not this widget.
--
-- Site hooks (аудит №10): payload renderer is a template parameter (`showcaseAppWith`), pieces
-- are PUBLIC; `showcaseApp` = verbatim default. Model.limit caps the read.
module CxmUI.Showcase where

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
open import CxmUI.Widget using (errText; emptyOr; toolbar; verbatimPayload; authorLabel)

record Model : Set where
  constructor mkModel
  field
    cfg    : V1Cfg
    from   : ℕ                    -- the showcase node (shelf) id
    limit  : ℕ                    -- page cap (0 = всё)
    items  : List ContentView
    status : String
open Model public

initModel : V1Cfg → ℕ → ℕ → Model
initModel c f lim = mkModel c f lim [] tShowcaseHint

data Msg : Set where
  Load : Msg
  Got  : Result CallErr (List ContentView) → Msg

updateModel : Msg → Model → Model
updateModel Load m = record m { status = tShowcaseLoading }
updateModel (Got (ok xs)) m = record m { items = xs ; status = emptyOr tShowcaseEmpty xs }
updateModel (Got (err e)) m = record m { status = errText e }

cmdOf : Msg → Model → Cmd Msg
cmdOf Load m = showcase (cfg m) (from m) (limit m) Got
cmdOf _    _ = ε

slotRowWith : (ContentView → Node Model Msg) → ContentView → ℕ → Node Model Msg
slotRowWith payloadView c _ =
  li (class ("cxm-post" ++ (if cnLocked c then " cxm-post-locked" else "")) ∷ [])
    ( span (class "cxm-post-author" ∷ []) [ text (authorLabel c) ]
    ∷ span (class "cxm-post-ts" ∷ []) [ text (tTs ++ show (cnCreatedAt c)) ]
    ∷ (if cnLocked c
        then span (class "cxm-post-teaser" ∷ []) [ text tLockedContent ]
        else payloadView c)
    ∷ [] )

showcaseTemplateWith : (ContentView → Node Model Msg) → Node Model Msg
showcaseTemplateWith payloadView =
  div (class "cxm-showcase" ∷ [])
    ( toolbar tReload Load status
    ∷ ul [] ( foreachKeyed items (λ c → show (cnId c)) (slotRowWith payloadView) ∷ [] )
    ∷ [] )

showcaseAppWith : (ContentView → Node Model Msg) → V1Cfg → (from limit : ℕ) → ReactiveApp Model Msg
showcaseAppWith payloadView c f lim =
  mkReactiveApp (initModel c f lim) updateModel (showcaseTemplateWith payloadView) cmdOf (λ _ → never)

showcaseApp : V1Cfg → ℕ → ReactiveApp Model Msg
showcaseApp c f = showcaseAppWith verbatimPayload c f 0
