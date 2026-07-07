{-# OPTIONS --without-K #-}

-- CxmUI.Thread — the conversation widget (Ф3.2): the pre-ordered node list under a root
-- (server: depth 0 = root, children createdAt-asc). Depth renders as `cxm-depth-<n>` — the
-- site turns it into indent/rail; locked nodes are stripped teasers with a teaser strip
-- (`cxm-node-locked`/`cxm-node-teaser`).
--
-- Site hooks (аудит №10): payload renderer is a template parameter (`threadAppWith`), pieces
-- are PUBLIC for custom composition; `threadApp` = verbatim default. Model.limit caps the read.
-- Reply box (аудит-2 №2): a top-level reply posts a comment anchored+parented to the root
-- (busy-guarded, reloads the thread on success); per-node replies are site composition.
module CxmUI.Thread where

open import Agda.Builtin.String using (primStringEquality)
open import Data.Bool using (Bool; true; false; if_then_else_)
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
    cfg       : V1Cfg
    root      : ℕ                     -- the thread anchor (resource id)
    limit     : ℕ                     -- page cap (0 = всё)
    nodes     : List ThreadNodeView
    status    : String
    replyText : String
    busy      : Bool                  -- reply in flight
open Model public

initModel : V1Cfg → ℕ → ℕ → Model
initModel c r lim = mkModel c r lim [] tThreadHint "" false

data Msg : Set where
  Load       : Msg
  Got        : Result CallErr (List ThreadNodeView) → Msg
  ReplyInput : String → Msg
  Reply      : Msg
  GotReply   : Result CallErr ℕ → Msg

updateModel : Msg → Model → Model
updateModel Load m = record m { status = tThreadLoading }
updateModel (Got (ok ns)) m = record m { nodes = ns ; status = emptyOr tThreadEmpty ns }
updateModel (Got (err e)) m = record m { status = errText e }
updateModel (ReplyInput s) m = record m { replyText = s }
-- guard пустого сабмита (аудит-3 №1): пустой коммент виден всем — no-op
updateModel Reply m =
  if primStringEquality (replyText m) "" then m
  else record m { status = tReplying ; busy = true ; replyText = "" }
updateModel (GotReply (ok _)) m = record m { busy = false }
updateModel (GotReply (err e)) m = record m { status = errText e ; busy = false }

cmdOf : Msg → Model → Cmd Msg
cmdOf Load  m = thread (cfg m) (root m) (limit m) Got
-- cmd видит PRE-update модель — replyText ещё не очищен; пустой сабмит = ε
cmdOf Reply m = if primStringEquality (replyText m) "" then ε
                else commentV1 (cfg m) (root m) (root m) "" "" (replyText m) GotReply
cmdOf (GotReply (ok _)) m = thread (cfg m) (root m) (limit m) Got   -- reload after reply
cmdOf _     _ = ε

nodeRowWith : (ContentView → Node Model Msg) → ThreadNodeView → ℕ → Node Model Msg
nodeRowWith payloadView n _ =
  li (class ("cxm-thread-node cxm-depth-" ++ show (tnDepth n)
             ++ (if cnLocked c then " cxm-node-locked" else "")) ∷ [])
    ( span (class "cxm-post-author" ∷ []) [ text (tAuthor ++ show (cnAuthor c)) ]
    ∷ span (class "cxm-post-ts" ∷ []) [ text (tTs ++ show (cnCreatedAt c)) ]
    ∷ (if cnLocked c
        then span (class "cxm-node-teaser" ∷ []) [ text tLockedReply ]
        else payloadView c)
    ∷ [] )
  where c = tnContent n

replyBox : Node Model Msg
replyBox = div (class "cxm-reply" ∷ [])
  ( input (valueBind replyText ∷ onInput ReplyInput ∷ attr "placeholder" tReplyPlaceholder
           ∷ class "cxm-reply-input" ∷ [])
  ∷ button (onClick Reply ∷ disabledBind busy ∷ class "cxm-reply-send" ∷ []) [ text tReply ]
  ∷ [] )

threadTemplateWith : (ContentView → Node Model Msg) → Node Model Msg
threadTemplateWith payloadView =
  div (class "cxm-thread" ∷ [])
    ( toolbar tReload Load status
    ∷ ul [] ( foreachKeyed nodes (λ n → show (cnId (tnContent n))) (nodeRowWith payloadView) ∷ [] )
    ∷ replyBox
    ∷ [] )

threadAppWith : (ContentView → Node Model Msg) → V1Cfg → (root limit : ℕ) → ReactiveApp Model Msg
threadAppWith payloadView c r lim =
  mkReactiveApp (initModel c r lim) updateModel (threadTemplateWith payloadView) cmdOf (λ _ → never)

threadApp : V1Cfg → ℕ → ReactiveApp Model Msg
threadApp c r = threadAppWith verbatimPayload c r 0
