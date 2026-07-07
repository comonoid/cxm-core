{-# OPTIONS --without-K #-}

-- CxmUI.Showcase — the curated showcase widget (Ф3.3): the live-window, rank-ascending read
-- over resource links from a showcase node `from` (an expired paid slot vanishes by projection —
-- no worker involved). Rows are feed-shaped (ContentView, same locked/teaser semantics), so the
-- markup mirrors CxmUI.Feed (`cxm-post*` classes) inside a `cxm-showcase` container.
-- Brand-neutral; a site mounts `showcaseApp v1cfg shelfId`. Curation writes are the OWNER's
-- cabinet (`POST /resources/link` / `/resources/unlink`), not this viewer widget.
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
open import CxmUI.Widget using (errText; emptyOr; toolbar)

record Model : Set where
  constructor mkModel
  field
    cfg    : V1Cfg
    from   : ℕ                    -- the showcase node (shelf) id
    items  : List ContentView
    status : String
open Model public

initModel : V1Cfg → ℕ → Model
initModel c f = mkModel c f [] "нажми «Обновить» — витрина"

data Msg : Set where
  Load : Msg
  Got  : Result CallErr (List ContentView) → Msg

updateModel : Msg → Model → Model
updateModel Load m = record m { status = "загрузка витрины…" }
updateModel (Got (ok xs)) m = record m { items = xs ; status = emptyOr "витрина пуста" xs }
updateModel (Got (err e)) m = record m { status = errText e }

cmdOf : Msg → Model → Cmd Msg
cmdOf Load m = showcase (cfg m) (from m) Got
cmdOf _    _ = ε

private
  slotRow : ContentView → ℕ → Node Model Msg
  slotRow c _ = li (class ("cxm-post" ++ (if cnLocked c then " cxm-post-locked" else "")) ∷ [])
    ( span (class "cxm-post-author" ∷ []) [ text ("автор #" ++ show (cnAuthor c)) ]
    ∷ (if cnLocked c
        then span (class "cxm-post-teaser" ∷ []) [ text "🔒 закрытый контент" ]
        else span (class "cxm-post-payload" ∷ []) [ text (cnPayload c) ])
    ∷ [] )

showcaseTemplate : Node Model Msg
showcaseTemplate =
  div (class "cxm-showcase" ∷ [])
    ( toolbar "Обновить" Load status
    ∷ ul [] ( foreachKeyed items (λ c → show (cnId c)) slotRow ∷ [] )
    ∷ [] )

showcaseApp : V1Cfg → ℕ → ReactiveApp Model Msg
showcaseApp c f = mkReactiveApp (initModel c f) updateModel showcaseTemplate cmdOf (λ _ → never)
