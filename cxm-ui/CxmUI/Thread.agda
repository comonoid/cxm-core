{-# OPTIONS --without-K #-}

-- CxmUI.Thread — the conversation widget (Ф3.2): the pre-ordered node list under a root
-- (server: depth 0 = root, children createdAt-asc). Depth renders as `cxm-depth-<n>` — the
-- site turns it into indent/rail; locked nodes are stripped teasers with a teaser strip
-- (`cxm-node-locked`/`cxm-node-teaser`). Payload opaque, verbatim (see CxmUI.Feed).
-- Brand-neutral; a site mounts `threadApp v1cfg root`.
module CxmUI.Thread where

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
    root   : ℕ                     -- the thread anchor (resource id)
    nodes  : List ThreadNodeView
    status : String
open Model public

initModel : V1Cfg → ℕ → Model
initModel c r = mkModel c r [] "нажми «Обновить» — разговор"

data Msg : Set where
  Load : Msg
  Got  : Result CallErr (List ThreadNodeView) → Msg

updateModel : Msg → Model → Model
updateModel Load m = record m { status = "загрузка разговора…" }
updateModel (Got (ok ns)) m = record m { nodes = ns ; status = emptyOr "разговор пуст" ns }
updateModel (Got (err e)) m = record m { status = errText e }

cmdOf : Msg → Model → Cmd Msg
cmdOf Load m = thread (cfg m) (root m) Got
cmdOf _    _ = ε

private
  nodeRow : ThreadNodeView → ℕ → Node Model Msg
  nodeRow n _ =
    li (class ("cxm-thread-node cxm-depth-" ++ show (tnDepth n)
               ++ (if cnLocked c then " cxm-node-locked" else "")) ∷ [])
      ( span (class "cxm-post-author" ∷ []) [ text ("автор #" ++ show (cnAuthor c)) ]
      ∷ span (class "cxm-post-ts" ∷ []) [ text ("t=" ++ show (cnCreatedAt c)) ]
      ∷ (if cnLocked c
          then span (class "cxm-node-teaser" ∷ []) [ text "🔒 закрытая реплика" ]
          else span (class "cxm-post-payload" ∷ []) [ text (cnPayload c) ])
      ∷ [] )
    where c = tnContent n

threadTemplate : Node Model Msg
threadTemplate =
  div (class "cxm-thread" ∷ [])
    ( toolbar "Обновить" Load status
    ∷ ul [] ( foreachKeyed nodes (λ n → show (cnId (tnContent n))) nodeRow ∷ [] )
    ∷ [] )

threadApp : V1Cfg → ℕ → ReactiveApp Model Msg
threadApp c r = mkReactiveApp (initModel c r) updateModel threadTemplate cmdOf (λ _ → never)
