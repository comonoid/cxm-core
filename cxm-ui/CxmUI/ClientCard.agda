{-# OPTIONS --without-K #-}

-- CxmUI.ClientCard — the operator's client-card widget (frontend layer 2, Ф2.1/2.2). A
-- self-contained reactive Model/update/view over CxmUI.Client: a subject roster on the left;
-- picking one loads its knowledge (with epistemic badges), episodes and appointments. Effects
-- go through the `cmd` hook (Client calls return `Cmd Msg`); DOM is agdelte-reactive (no VDOM).
-- Brand-neutral — a site supplies theme/layout and mounts `clientCardApp cfg`, or composes its
-- own: `Model`/`Msg`/`updateModel`/`cmdOf` and the row builders are PUBLIC, so a custom template
-- can reuse the pieces (`mkReactiveApp (initModel cfg) updateModel myTemplate cmdOf (λ _ → never)`).
--
-- Consistency contracts (аудит 2026-07-07):
--   * batch responses carry their subject and are DROPPED if the operator switched away
--     (stale-response race) — `Got*` msgs are tagged, update checks against `selected`;
--   * `Select` resets ALL per-subject state incl. the redetail form (no cross-subject writes);
--   * write actions set `busy` until their response lands — buttons are disabled meanwhile
--     (no double submits).
module CxmUI.ClientCard where

open import Agda.Builtin.Unit using (⊤)
open import Agda.Builtin.String using (primStringEquality)
open import Data.Bool using (Bool; true; false; not; _∨_; _∧_; if_then_else_)
open import Data.Nat using (ℕ; _≡ᵇ_)
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
open import CxmUI.Text
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
    editing      : ℕ                    -- knowledge id под redetail-формой (0 = закрыта)
    editText     : String               -- текст формы
    busy         : Bool                 -- write in flight → кнопки записи выключены
    evidenceFor  : ℕ                    -- knowledge id раскрытой evidence-панели (0 = скрыта)
    evidence     : List EvidenceView
    obsText      : String               -- поле «добавить наблюдение» (create STATED)
open Model public

initModel : Cfg → Model
initModel c = mkModel c [] 0 [] [] [] [] tCardHint 0 "" false 0 [] ""

-- единый источник шага amount-ревизий (подпись кнопки строится из него же — аудит-2 №11)
revStep : ℕ
revStep = 50

------------------------------------------------------------------------
-- Messages. Got* carry the subject they were requested FOR — update drops
-- late responses of a subject the operator already switched away from.
------------------------------------------------------------------------

data Msg : Set where
  LoadRoster     : Msg
  GotRoster      : Result CallErr (List RosterView) → Msg
  Select         : ℕ → Msg
  GotKnowledge   : ℕ → Result CallErr (List KnowledgeView) → Msg
  GotEpisodes    : ℕ → Result CallErr (List EpisodeView) → Msg
  GotAppointments : ℕ → Result CallErr (List AppointmentView) → Msg
  GotExpectations : ℕ → Result CallErr (List ExpectationView) → Msg
  Rebuild        : Msg                                    -- rebuild inference for the selected subject
  GotRebuild     : ℕ → Result CallErr ⊤ → Msg             -- write-ответы ТОЖЕ тегированы (аудит-5 №1):
  Revise         : ℕ → String → Msg                       -- (knowledge id, kind) — Ф2.3
  ReviseBy       : ℕ → String → ℕ → Msg                   -- + amount (strengthen/weaken, шаг UI)
  EditDetail     : ℕ → String → Msg                       -- открыть redetail-форму (kid, текущий kDetail)
  EditInput      : String → Msg
  SaveDetail     : Msg                                    --   стейл-ответ от прежнего клиента не
  CancelEdit     : Msg                                    --   должен снимать busy нового write
  GotRevise      : ℕ → Result CallErr ⊤ → Msg
  LoadEvidence   : ℕ → Msg                                -- «🔎 почему» (toggle: повторный клик закрывает)
  GotEvidence    : ℕ → Result CallErr (List EvidenceView) → Msg
  CloseEvidence  : Msg
  ObsInput       : String → Msg                           -- «добавить наблюдение» (create STATED)
  AddObs         : Msg
  GotObs         : ℕ → Result CallErr ℕ → Msg

------------------------------------------------------------------------
-- Update (pure) + the effect hook (cmd)
------------------------------------------------------------------------

private
  -- accept a tagged response only if it is still about the selected subject
  ifCurrent : ℕ → Model → Model → Model
  ifCurrent sid m m' = if sid ≡ᵇ selected m then m' else m

updateModel : Msg → Model → Model
updateModel LoadRoster m = record m { status = tCardLoadingRoster }
updateModel (GotRoster (ok rs)) m = record m { subjects = rs ; status = emptyOr tCardNoClients rs }
updateModel (GotRoster (err e)) m = record m { status = errText e }
updateModel (Select sid) m =
  record m { selected = sid ; knowledge = [] ; episodes = [] ; appointments = [] ; expectations = []
           ; status = tCardLoadingCard ; editing = 0 ; editText = "" ; evidenceFor = 0 ; evidence = []
           ; busy = false ; obsText = "" }   -- busy-фейлсейф: смена клиента не наследует зависший write
updateModel (GotKnowledge sid (ok ks)) m =
  ifCurrent sid m (record m { knowledge = ks ; status = emptyOr tCardNoKnowledge ks })
updateModel (GotKnowledge sid (err e)) m = ifCurrent sid m (record m { status = errText e })
updateModel (GotEpisodes sid (ok es)) m = ifCurrent sid m (record m { episodes = es })
updateModel (GotEpisodes sid (err e)) m = ifCurrent sid m (record m { status = errText e })
updateModel (GotAppointments sid (ok as)) m = ifCurrent sid m (record m { appointments = as })
updateModel (GotAppointments sid (err e)) m = ifCurrent sid m (record m { status = errText e })
updateModel (GotExpectations sid (ok xs)) m = ifCurrent sid m (record m { expectations = xs })
updateModel (GotExpectations sid (err e)) m = ifCurrent sid m (record m { status = errText e })
updateModel Rebuild m = record m { status = tCardRebuilding ; busy = true }
updateModel (GotRebuild sid (ok _)) m = ifCurrent sid m (record m { status = tCardRebuilt ; busy = false })
updateModel (GotRebuild sid (err e)) m = ifCurrent sid m (record m { status = errText e ; busy = false })
updateModel (Revise _ kind) m = record m { status = tCardRevising ++ tKindRu kind ++ tEllipsis ; busy = true }
updateModel (ReviseBy _ kind _) m = record m { status = tCardRevising ++ tKindRu kind ++ tEllipsis ; busy = true }
updateModel (EditDetail kid cur) m = record m { editing = kid ; editText = cur }
updateModel (EditInput s) m = record m { editText = s }
updateModel SaveDetail m = record m { status = tCardSavingDetail ; busy = true }
updateModel CancelEdit m = record m { editing = 0 ; editText = "" }
updateModel (GotRevise sid (ok _)) m =
  ifCurrent sid m (record m { status = tCardRevised ; editing = 0 ; busy = false })
updateModel (GotRevise sid (err e)) m = ifCurrent sid m (record m { status = errText e ; busy = false })
updateModel (LoadEvidence kid) m =
  if kid ≡ᵇ evidenceFor m
    then record m { evidenceFor = 0 ; evidence = [] }     -- toggle: повторный клик закрывает
    else record m { evidenceFor = kid ; evidence = [] ; status = tCardLoadingEvidence }
updateModel (GotEvidence kid (ok es)) m =
  if kid ≡ᵇ evidenceFor m then record m { evidence = es ; status = "" } else m
updateModel (GotEvidence _ (err e)) m =
  record m { status = errText e ; evidenceFor = 0 ; evidence = [] }   -- не показывать «пусто» при ошибке
updateModel CloseEvidence m = record m { evidenceFor = 0 ; evidence = [] }
updateModel (ObsInput s) m = record m { obsText = s }
-- guard пустого сабмита (аудит-3 №1): пустое наблюдение — мусор, no-op
updateModel AddObs m =
  if primStringEquality (obsText m) "" then m
  else record m { status = tCardAddingObs ; busy = true ; obsText = "" }
updateModel (GotObs sid (ok _)) m = ifCurrent sid m (record m { busy = false })
updateModel (GotObs sid (err e)) m = ifCurrent sid m (record m { status = errText e ; busy = false })

cmdOf : Msg → Model → Cmd Msg
cmdOf LoadRoster    m = roster (cfg m) GotRoster
cmdOf (Select sid)  m = batch ( knowledgeOf    (cfg m) sid (GotKnowledge sid)
                              ∷ episodesOf     (cfg m) sid (GotEpisodes sid)
                              ∷ appointmentsOf (cfg m) sid (GotAppointments sid)
                              ∷ expectationsOf (cfg m) sid (GotExpectations sid) ∷ [] )
cmdOf Rebuild            m = rebuildInference (cfg m) (selected m) (GotRebuild (selected m))
cmdOf (GotRebuild sid (ok _)) m =
  if sid ≡ᵇ selected m then knowledgeOf (cfg m) sid (GotKnowledge sid) else ε
cmdOf (Revise kid kind)  m = reviseKnowledge (cfg m) kid kind (GotRevise (selected m))
cmdOf (ReviseBy kid kind amt) m = reviseKnowledgeBy (cfg m) kid kind amt (GotRevise (selected m))
cmdOf SaveDetail         m = reviseDetail (cfg m) (editing m) (editText m) (GotRevise (selected m))
cmdOf (GotRevise sid (ok _)) m =
  if sid ≡ᵇ selected m then knowledgeOf (cfg m) sid (GotKnowledge sid) else ε
-- cmd видит PRE-update модель: клик по уже открытому kid = закрытие → НЕ фетчить
cmdOf (LoadEvidence kid) m = if kid ≡ᵇ evidenceFor m then ε else evidenceOf (cfg m) kid (GotEvidence kid)
cmdOf AddObs             m = if primStringEquality (obsText m) "" then ε
                             else createKnowledge (cfg m) (selected m) (obsText m) (GotObs (selected m))
cmdOf (GotObs sid (ok _)) m =
  if sid ≡ᵇ selected m then knowledgeOf (cfg m) sid (GotKnowledge sid) else ε
cmdOf _                  _ = ε

------------------------------------------------------------------------
-- View (row builders are PUBLIC — sites compose custom templates from them)
------------------------------------------------------------------------

-- one roster entry → a clickable button
rosterRow : RosterView → ℕ → Node Model Msg
rosterRow r _ = li [ class "cxm-roster-row" ]
  [ button (onClick (Select (rvId r)) ∷ class "cxm-roster-btn" ∷ [])
      [ text (rvName r) ] ]

revBtn : ℕ → String → String → Node Model Msg
revBtn kid kind label =
  button (onClick (Revise kid kind) ∷ disabledBind busy ∷ class ("cxm-rev cxm-rev-" ++ kind) ∷ [])
    [ text label ]

private
  -- revision moves apply to LIVE envelopes; refuted/superseded are history (server would 409)
  liveStatus : KnowledgeView → Bool
  liveStatus k = not (primStringEquality (kvStatus k) "refuted"
                      ∨ primStringEquality (kvStatus k) "superseded")

-- one knowledge unit → epistemic badge (type + status) + confidence + opaque detail (Ф2.2)
knowRow : KnowledgeView → ℕ → Node Model Msg
knowRow k _ = li (class ("cxm-know cxm-know-" ++ kvType k) ∷ [])
  ( span (class ("cxm-badge cxm-badge-" ++ kvType k) ∷ []) [ text (kvType k) ]
  ∷ span (class ("cxm-badge cxm-status-" ++ kvStatus k) ∷ []) [ text (kvStatus k) ]
  ∷ span (class "cxm-conf" ∷ []) [ text ("‰" ++ show (kvConfidence k)) ]
  ∷ span (class "cxm-detail" ∷ []) [ text (kvDetail k) ]
  ∷ (if liveStatus k
      then span (class "cxm-rev-actions" ∷ [])
        ( revBtn (kvId k) "confirm"   tCardConfirm
        ∷ revBtn (kvId k) "refute"    tCardRefute
        ∷ revBtn (kvId k) "supersede" tCardSupersede
        ∷ button (onClick (ReviseBy (kvId k) "strengthen" revStep) ∷ disabledBind busy
                  ∷ class "cxm-rev cxm-rev-strengthen" ∷ []) [ text (tCardStrengthenPfx ++ show revStep) ]
        ∷ button (onClick (ReviseBy (kvId k) "weaken" revStep) ∷ disabledBind busy
                  ∷ class "cxm-rev cxm-rev-weaken" ∷ []) [ text (tCardWeakenPfx ++ show revStep) ]
        ∷ button (onClick (EditDetail (kvId k) (kvDetail k)) ∷ disabledBind busy
                  ∷ class "cxm-rev cxm-rev-redetail" ∷ []) [ text tCardRedetail ]
        ∷ button (onClick (LoadEvidence (kvId k)) ∷ class "cxm-rev cxm-rev-why" ∷ [])
            [ text tCardWhy ] ∷ [] )
      else span (class "cxm-rev-actions" ∷ [])
        [ button (onClick (LoadEvidence (kvId k)) ∷ class "cxm-rev cxm-rev-why" ∷ [])
            [ text tCardWhy ] ])
  ∷ [] )

-- Ф2.3-хвост: redetail-форма (одна на карточку; editing = kid). Текст уходит JSON-экранированным.
editPanel : Node Model Msg
editPanel = div (class "cxm-edit-detail" ∷ [])
  ( input (valueBind editText ∷ onInput EditInput ∷ class "cxm-edit-input" ∷ [])
  ∷ button (onClick SaveDetail ∷ disabledBind busy ∷ class "cxm-edit-save" ∷ [])
      [ text tCardSaveDetail ]
  ∷ button (onClick CancelEdit ∷ class "cxm-edit-cancel" ∷ []) [ text tCardCancel ]
  ∷ [] )

-- explainability (аудит №8): the evidence chain behind the opened knowledge unit —
-- each row carries the backing event's payload + timestamp (server joins them, аудит-2 №4)
evRow : EvidenceView → ℕ → Node Model Msg
evRow e _ = li (class "cxm-evidence" ∷ [])
  ( span (class "cxm-evidence-ref" ∷ []) [ text (tCardEvidenceRow ++ show (edvEvent e)) ]
  ∷ span (class "cxm-post-ts" ∷ []) [ text (tTs ++ show (edvEventAt e)) ]
  ∷ span (class "cxm-evidence-payload" ∷ []) [ text (edvEventPayload e) ]
  ∷ [] )

evidencePanel : Node Model Msg
evidencePanel = div (class "cxm-evidence-panel" ∷ [])
  ( div (class "cxm-section-head" ∷ [])
      ( h3 [] [ text tCardWhyHead ]
      ∷ button (onClick CloseEvidence ∷ class "cxm-evidence-close" ∷ []) [ text tClose ] ∷ [] )
  ∷ bindF (λ m → emptyOr tCardNoEvidence (evidence m))
  ∷ ul [] ( foreachKeyed evidence (λ e → show (edvId e)) evRow ∷ [] )
  ∷ [] )

-- create STATED (аудит-2 №1): оператор добавляет наблюдение прямо из блокнота
obsPanel : Node Model Msg
obsPanel = div (class "cxm-add-obs" ∷ [])
  ( input (valueBind obsText ∷ onInput ObsInput ∷ attr "placeholder" tCardObsPlaceholder
           ∷ class "cxm-obs-input" ∷ [])
  ∷ button (onClick AddObs ∷ disabledBind busy ∷ class "cxm-obs-add" ∷ []) [ text tCardAddObs ]
  ∷ [] )

epRow : EpisodeView → ℕ → Node Model Msg
epRow e _ = li (class "cxm-episode" ∷ [])
  [ text (tCardEpisode ++ show (epvId e) ++ tCardEpState ++ show (epvState e) ++ " · " ++ epvJtbd e) ]

apRow : AppointmentView → ℕ → Node Model Msg
apRow a _ = li (class ("cxm-appt cxm-appt-" ++ avStatus a) ∷ [])
  [ text (tCardBooking ++ show (avId a) ++ " · " ++ show (avDuration a) ++ tCardMin ++ avStatus a) ]

------------------------------------------------------------------------
-- Панель VIII.a (Ф2.5): «как достучаться» — work-strategy traits of the selected subject,
-- decoded from opaque kvDetail by Contract.parseWorkStrategy and rendered as a human phrase.
-- Refuted/superseded envelopes are history (the notebook shows them), not adaptation hints —
-- the panel hides them. Progressive disclosure (Concept §VIII.a): no strategies → no panel.
------------------------------------------------------------------------

private
  optTxt : ∀ {A : Set} → (A → String) → Maybe A → List String → List String
  optTxt f (just a) rest = f a ∷ rest
  optTxt f nothing  rest = rest

  syncTxt : Bool → String
  syncTxt true  = tWsSync
  syncTxt false = tWsAsync

  dfTxt : Bool → String
  dfTxt true  = tWsDetailFirst
  dfTxt false = tWsPictureFirst

wsText : WorkStrategyView → String
wsText w with optTxt syncTxt (wsSync w)
               (optTxt dfTxt (wsDetailFirst w)
                 (optTxt (λ h → tWsHandoff ++ h) (wsHandoff w) []))
... | [] = tWsBare
... | bs = intersperse " · " bs

private
  liveWS : KnowledgeView → Maybe (KnowledgeView × WorkStrategyView)
  liveWS k with parseWorkStrategy (kvDetail k)
  ... | nothing = nothing
  ... | just w  = if liveStatus k then just (k , w) else nothing

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
  ∷ span (class "cxm-exp-level" ∷ []) [ text (tCardLevel ++ show (xvLevel x)) ]
  ∷ [] )

cardTemplate : Node Model Msg
cardTemplate =
  div (class "cxm-client-card" ∷ [])
    ( toolbar tLoad LoadRoster status
    ∷ div (class "cxm-cols" ∷ [])
        ( div (class "cxm-roster" ∷ [])
            ( h2 [] [ text tCardClients ]
            ∷ ul [] ( foreachKeyed subjects (λ r → show (rvId r)) rosterRow ∷ [] ) ∷ [] )
        ∷ div (class "cxm-card" ∷ [])
            ( div (class "cxm-section" ∷ [])
                ( div (class "cxm-section-head" ∷ [])
                    ( h2 [] [ text tCardKnowledge ]
                    ∷ when (λ m → not (selected m ≡ᵇ 0))
                        (button (onClick Rebuild ∷ disabledBind busy ∷ class "cxm-rebuild" ∷ [])
                          [ text tCardRebuild ]) ∷ [] )
                ∷ ul [] ( foreachKeyed knowledge (λ k → show (kvId k)) knowRow ∷ [] )
                ∷ when (λ m → not (selected m ≡ᵇ 0)) obsPanel
                ∷ when (λ m → not (editing m ≡ᵇ 0)) editPanel
                ∷ when (λ m → not (evidenceFor m ≡ᵇ 0)) evidencePanel ∷ [] )
            ∷ div (class "cxm-section" ∷ []) ( h2 [] [ text tCardEpisodes ]
                ∷ ul [] ( foreachKeyed episodes (λ e → show (epvId e)) epRow ∷ [] ) ∷ [] )
            ∷ div (class "cxm-section" ∷ []) ( h2 [] [ text tCardAppointments ]
                ∷ ul [] ( foreachKeyed appointments (λ a → show (avId a)) apRow ∷ [] ) ∷ [] )
            ∷ div (class "cxm-section" ∷ []) ( h2 [] [ text tCardExpectations ]
                ∷ ul [] ( foreachKeyed expectations (λ x → show (xvId x)) xpRow ∷ [] ) ∷ [] )
            ∷ when (λ m → not (null (strategies m)))
                (div (class "cxm-section cxm-ws-panel" ∷ [])
                  ( h2 [] [ text tWsHead ]
                  ∷ ul [] ( foreachKeyed strategies (λ kw → show (kvId (proj₁ kw))) wsRow ∷ [] ) ∷ [] ))
            ∷ [] )
        ∷ [] )
    ∷ [] )

------------------------------------------------------------------------
-- App — a site mounts `clientCardApp cfg`
------------------------------------------------------------------------

clientCardApp : Cfg → ReactiveApp Model Msg
clientCardApp c = mkReactiveApp (initModel c) updateModel cardTemplate cmdOf (λ _ → never)
