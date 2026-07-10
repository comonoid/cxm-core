{-# OPTIONS --without-K #-}

-- CxmUI.Inbox — the mentions-inbox widget (site-plan Ф4): «все ответы мне» — the nodes where
-- the viewer is an addressee (/v1/mentions), feed-shaped. Deliberately a REUSE of the PUBLIC
-- Feed pieces (Model/Msg/updateModel/template) — the ONLY difference is the read source, so
-- only cmdOf is overridden here (аудит №10 style: pieces are public, compose don't fork).
-- Embedding site: держит Feed.Model, шлёт Feed.Msg, template = Feed.feedTemplateWith, но
-- cmd — Inbox.cmdOf.
module CxmUI.Inbox where

open import Data.Nat using (ℕ)
open import Agdelte.Core.Cmd using (Cmd; ε)
open import Agdelte.Core.Event using (never)
open import Agdelte.Reactive.Node

open import CxmUI.Contract using (ContentView)
open import CxmUI.Client using (V1Cfg; mentionsV1)
open import CxmUI.Feed using
  (Model; initModel; cfg; limit; Msg; Load; Got; updateModel; feedTemplateWith)

cmdOf : Msg → Model → Cmd Msg
cmdOf Load m = mentionsV1 (cfg m) (limit m) Got
cmdOf _    _ = ε

inboxAppWith : (ContentView → Node Model Msg) → V1Cfg → (lim : ℕ) → ReactiveApp Model Msg
inboxAppWith payloadView c lim =
  mkReactiveApp (initModel c lim) updateModel (feedTemplateWith payloadView) cmdOf (λ _ → never)
