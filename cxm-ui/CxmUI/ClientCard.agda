{-# OPTIONS --without-K #-}

-- CxmUI.ClientCard — the operator's client-card widget (frontend layer 2, Ф2.1/2.2). A
-- self-contained reactive Model/update/view over CxmUI.Client: a subject roster on the left;
-- picking one loads its knowledge (with epistemic badges), episodes and appointments. Effects
-- go through the `cmd` hook (Client calls return `Cmd Msg`); DOM is agdelte-reactive (no VDOM).
-- Brand-neutral — a site supplies theme/layout and mounts `clientCardApp cfg`.
module CxmUI.ClientCard where

open import Agda.Builtin.Unit using (⊤)
open import Agda.Builtin.String using (primStringEquality)
open import Data.Bool using (Bool; true; false; not; _∨_; if_then_else_)
open import Data.Nat using (ℕ)
open import Data.Nat.Show using (show)
open import Data.String using (String; _++_; intersperse)
open import Data.List using (List; []; _∷_; [_]; mapMaybe; null)
open import Data.Maybe using (Maybe; just; nothing)
open import Data.Product using (_×_; _,_; proj₁)

open import Agdelte.Core.Result using (Result; ok; err)
open import Agdelte.Core.Cmd using (Cmd; ε; batch)
open import Agdelte.Core.Event using (never)
open import Agdelte.Reactive.Node

open import CxmUI.Contract
open import CxmUI.Client
open import CxmUI.Widget using (errText; emptyOr; toolbar)

------------------------------------------------------------------------
-- Model
------------------------------------------------------------------------

record Model : Set where
  constructor mkModel
  field
    cfg          : Cfg
    subjects     : List RosterView
    selected     : ℕ                    -- 0 = none picked
    knowledge    : List KnowledgeView
    episodes     : List EpisodeView
    appointments : List AppointmentView
    expectations : List ExpectationView
    status       : String               -- transient status / error line
open Model public

initModel : Cfg → Model
initModel c = mkModel c [] 0 [] [] [] [] "нажми «Загрузить» — список клиентов"

------------------------------------------------------------------------
-- Messages
------------------------------------------------------------------------

data Msg : Set where
  LoadRoster     : Msg
  GotRoster      : Result CallErr (List RosterView) → Msg
  Select         : ℕ → Msg
  GotKnowledge   : Result CallErr (List KnowledgeView) → Msg
  GotEpisodes    : Result CallErr (List EpisodeView) → Msg
  GotAppointments : Result CallErr (List AppointmentView) → Msg
  GotExpectations : Result CallErr (List ExpectationView) → Msg
  Rebuild        : Msg                                    -- rebuild inference for the selected subject
  GotRebuild     : Result CallErr ⊤ → Msg
  Revise         : ℕ → String → Msg                       -- (knowledge id, kind) — Ф2.3
  GotRevise      : Result CallErr ⊤ → Msg

------------------------------------------------------------------------
-- Update (pure) + the effect hook (cmd)
------------------------------------------------------------------------

updateModel : Msg → Model → Model
updateModel LoadRoster m = record m { status = "загрузка списка…" }
updateModel (GotRoster (ok rs)) m = record m { subjects = rs ; status = emptyOr "клиентов пока нет" rs }
updateModel (GotRoster (err e)) m = record m { status = errText e }
updateModel (Select sid) m =
  record m { selected = sid ; knowledge = [] ; episodes = [] ; appointments = [] ; expectations = []
           ; status = "загрузка карточки…" }
updateModel (GotKnowledge (ok ks)) m = record m { knowledge = ks ; status = emptyOr "знаний пока нет" ks }
updateModel (GotKnowledge (err e)) m = record m { status = errText e }
updateModel (GotEpisodes (ok es)) m = record m { episodes = es }
updateModel (GotEpisodes (err e)) m = record m { status = errText e }
updateModel (GotAppointments (ok as)) m = record m { appointments = as }
updateModel (GotAppointments (err e)) m = record m { status = errText e }
updateModel (GotExpectations (ok xs)) m = record m { expectations = xs }
updateModel (GotExpectations (err e)) m = record m { status = errText e }
updateModel Rebuild m = record m { status = "перестраиваю вывод…" }
updateModel (GotRebuild (ok _)) m = record m { status = "вывод перестроен, обновляю знания…" }
updateModel (GotRebuild (err e)) m = record m { status = errText e }
updateModel (Revise _ kind) m = record m { status = ("ревизия: " ++ kind ++ "…") }
updateModel (GotRevise (ok _)) m = record m { status = "ревизия применена, обновляю…" }
updateModel (GotRevise (err e)) m = record m { status = errText e }

cmdOf : Msg → Model → Cmd Msg
cmdOf LoadRoster    m = roster (cfg m) GotRoster
cmdOf (Select sid)  m = batch ( knowledgeOf    (cfg m) sid GotKnowledge
                              ∷ episodesOf     (cfg m) sid GotEpisodes
                              ∷ appointmentsOf (cfg m) sid GotAppointments
                              ∷ expectationsOf (cfg m) sid GotExpectations ∷ [] )
cmdOf Rebuild            m = rebuildInference (cfg m) (selected m) GotRebuild
cmdOf (GotRebuild (ok _)) m = knowledgeOf (cfg m) (selected m) GotKnowledge   -- reload after rebuild
cmdOf (Revise kid kind)  m = reviseKnowledge (cfg m) kid kind GotRevise
cmdOf (GotRevise (ok _)) m = knowledgeOf (cfg m) (selected m) GotKnowledge    -- reload after revision
cmdOf _                  _ = ε

------------------------------------------------------------------------
-- View
------------------------------------------------------------------------

private
  -- one roster entry → a clickable button
  rosterRow : RosterView → ℕ → Node Model Msg
  rosterRow r _ = li [ class "cxm-roster-row" ]
    [ button (onClick (Select (rvId r)) ∷ class "cxm-roster-btn" ∷ [])
        [ text (rvName r) ] ]

  -- one knowledge unit → epistemic badge (type + status) + confidence + opaque detail (Ф2.2)
  revBtn : ℕ → String → String → Node Model Msg
  revBtn kid kind label =
    button (onClick (Revise kid kind) ∷ class ("cxm-rev cxm-rev-" ++ kind) ∷ []) [ text label ]

  knowRow : KnowledgeView → ℕ → Node Model Msg
  knowRow k _ = li (class ("cxm-know cxm-know-" ++ kvType k) ∷ [])
    ( span (class ("cxm-badge cxm-badge-" ++ kvType k) ∷ []) [ text (kvType k) ]
    ∷ span (class ("cxm-badge cxm-status-" ++ kvStatus k) ∷ []) [ text (kvStatus k) ]
    ∷ span (class "cxm-conf" ∷ []) [ text ("‰" ++ show (kvConfidence k)) ]
    ∷ span (class "cxm-detail" ∷ []) [ text (kvDetail k) ]
    ∷ span (class "cxm-rev-actions" ∷ [])
        ( revBtn (kvId k) "confirm"   "✓ подтвердить"
        ∷ revBtn (kvId k) "refute"    "✗ опровергнуть"
        ∷ revBtn (kvId k) "supersede" "⤳ заменить" ∷ [] )
    ∷ [] )

  epRow : EpisodeView → ℕ → Node Model Msg
  epRow e _ = li (class "cxm-episode" ∷ [])
    [ text ("эпизод #" ++ show (epvId e) ++ " · состояние " ++ show (epvState e) ++ " · " ++ epvJtbd e) ]

  apRow : AppointmentView → ℕ → Node Model Msg
  apRow a _ = li (class ("cxm-appt cxm-appt-" ++ avStatus a) ∷ [])
    [ text ("бронь #" ++ show (avId a) ++ " · " ++ show (avDuration a) ++ " мин · " ++ avStatus a) ]

  -- Панель VIII.a (Ф2.5): «как достучаться» — work-strategy traits of the selected subject,
  -- decoded from opaque kvDetail by Contract.parseWorkStrategy and rendered as a human phrase.
  -- Refuted/superseded envelopes are history (the notebook shows them), not adaptation hints —
  -- the panel hides them. Progressive disclosure (Concept §VIII.a): no strategies → no panel.
  optTxt : ∀ {A : Set} → (A → String) → Maybe A → List String → List String
  optTxt f (just a) rest = f a ∷ rest
  optTxt f nothing  rest = rest

  syncTxt : Bool → String
  syncTxt true  = "синхронно"
  syncTxt false = "асинхронно"

  dfTxt : Bool → String
  dfTxt true  = "сначала детали"
  dfTxt false = "сначала общая картина"

  wsText : WorkStrategyView → String
  wsText w with optTxt syncTxt (wsSync w)
                 (optTxt dfTxt (wsDetailFirst w)
                   (optTxt (λ h → "хэндофф полон: " ++ h) (wsHandoff w) []))
  ... | [] = "стратегия без параметров"
  ... | bs = intersperse " · " bs

  liveWS : KnowledgeView → Maybe (KnowledgeView × WorkStrategyView)
  liveWS k with parseWorkStrategy (kvDetail k)
  ... | nothing = nothing
  ... | just w  =
    if primStringEquality (kvStatus k) "refuted" ∨ primStringEquality (kvStatus k) "superseded"
      then nothing else just (k , w)

  strategies : Model → List (KnowledgeView × WorkStrategyView)
  strategies m = mapMaybe liveWS (knowledge m)

  wsRow : KnowledgeView × WorkStrategyView → ℕ → Node Model Msg
  wsRow (k , w) _ = li (class "cxm-ws" ∷ [])
    ( span (class ("cxm-badge cxm-badge-" ++ kvType k) ∷ []) [ text (kvType k) ]
    ∷ span (class "cxm-ws-text" ∷ []) [ text (wsText w) ]
    ∷ span (class "cxm-conf" ∷ []) [ text ("‰" ++ show (kvConfidence k)) ]
    ∷ [] )

  -- expectation-gap (Ф2.6): topic + gap signal (met/unmet/unknown) + level; cxm-exp-<status> for CSS
  xpRow : ExpectationView → ℕ → Node Model Msg
  xpRow x _ = li (class ("cxm-exp cxm-exp-" ++ xvStatus x) ∷ [])
    ( span (class ("cxm-badge cxm-exp-" ++ xvStatus x) ∷ []) [ text (xvStatus x) ]
    ∷ span (class "cxm-exp-topic" ∷ []) [ text (xvTopic x) ]
    ∷ span (class "cxm-exp-level" ∷ []) [ text ("уровень " ++ show (xvLevel x)) ]
    ∷ [] )

cardTemplate : Node Model Msg
cardTemplate =
  div (class "cxm-client-card" ∷ [])
    ( toolbar "Загрузить" LoadRoster status
    ∷ div (class "cxm-cols" ∷ [])
        ( div (class "cxm-roster" ∷ [])
            ( h2 [] [ text "Клиенты" ]
            ∷ ul [] ( foreachKeyed subjects (λ r → show (rvId r)) rosterRow ∷ [] ) ∷ [] )
        ∷ div (class "cxm-card" ∷ [])
            ( div (class "cxm-section" ∷ [])
                ( div (class "cxm-section-head" ∷ [])
                    ( h2 [] [ text "Знания" ]
                    ∷ button (onClick Rebuild ∷ class "cxm-rebuild" ∷ []) [ text "↻ перестроить вывод" ] ∷ [] )
                ∷ ul [] ( foreachKeyed knowledge (λ k → show (kvId k)) knowRow ∷ [] ) ∷ [] )
            ∷ div (class "cxm-section" ∷ []) ( h2 [] [ text "Эпизоды" ]
                ∷ ul [] ( foreachKeyed episodes (λ e → show (epvId e)) epRow ∷ [] ) ∷ [] )
            ∷ div (class "cxm-section" ∷ []) ( h2 [] [ text "Брони" ]
                ∷ ul [] ( foreachKeyed appointments (λ a → show (avId a)) apRow ∷ [] ) ∷ [] )
            ∷ div (class "cxm-section" ∷ []) ( h2 [] [ text "Ожидания" ]
                ∷ ul [] ( foreachKeyed expectations (λ x → show (xvId x)) xpRow ∷ [] ) ∷ [] )
            ∷ when (λ m → not (null (strategies m)))
                (div (class "cxm-section cxm-ws-panel" ∷ [])
                  ( h2 [] [ text "Как достучаться" ]
                  ∷ ul [] ( foreachKeyed strategies (λ kw → show (kvId (proj₁ kw))) wsRow ∷ [] ) ∷ [] ))
            ∷ [] )
        ∷ [] )
    ∷ [] )

------------------------------------------------------------------------
-- App — a site mounts `clientCardApp cfg`
------------------------------------------------------------------------

clientCardApp : Cfg → ReactiveApp Model Msg
clientCardApp c = mkReactiveApp (initModel c) updateModel cardTemplate cmdOf (λ _ → never)
