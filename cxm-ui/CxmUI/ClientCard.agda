{-# OPTIONS --without-K #-}

-- CxmUI.ClientCard — the operator's client-card widget (frontend layer 2, Ф2.1/2.2). A
-- self-contained reactive Model/update/view over CxmUI.Client: a subject roster on the left;
-- picking one loads its knowledge (with epistemic badges), episodes and appointments. Effects
-- go through the `cmd` hook (Client calls return `Cmd Msg`); DOM is agdelte-reactive (no VDOM).
-- Brand-neutral — a site supplies theme/layout and mounts `clientCardApp cfg`.
module CxmUI.ClientCard where

open import Data.Nat using (ℕ)
open import Data.Nat.Show using (show)
open import Data.String using (String; _++_)
open import Data.List using (List; []; _∷_; [_])

open import Agdelte.Core.Result using (Result; ok; err)
open import Agdelte.Core.Cmd using (Cmd; ε; batch)
open import Agdelte.Core.Event using (never)
open import Agdelte.Reactive.Node

open import CxmUI.Contract
open import CxmUI.Client

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
    status       : String               -- transient status / error line
open Model public

initModel : Cfg → Model
initModel c = mkModel c [] 0 [] [] [] "нажми «Загрузить» — список клиентов"

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

------------------------------------------------------------------------
-- Update (pure) + the effect hook (cmd)
------------------------------------------------------------------------

private
  errStr : CallErr → String
  errStr (httpErr s)   = "сеть: " ++ s
  errStr (serverErr e) = "сервер: " ++ aeCode e
  errStr (decodeErr s) = "разбор: " ++ s

updateModel : Msg → Model → Model
updateModel LoadRoster m = record m { status = "загрузка списка…" }
updateModel (GotRoster (ok rs)) m = record m { subjects = rs ; status = "" }
updateModel (GotRoster (err e)) m = record m { status = errStr e }
updateModel (Select sid) m =
  record m { selected = sid ; knowledge = [] ; episodes = [] ; appointments = [] ; status = "загрузка карточки…" }
updateModel (GotKnowledge (ok ks)) m = record m { knowledge = ks ; status = "" }
updateModel (GotKnowledge (err e)) m = record m { status = errStr e }
updateModel (GotEpisodes (ok es)) m = record m { episodes = es }
updateModel (GotEpisodes (err e)) m = record m { status = errStr e }
updateModel (GotAppointments (ok as)) m = record m { appointments = as ; status = "" }
updateModel (GotAppointments (err e)) m = record m { status = errStr e }

cmdOf : Msg → Model → Cmd Msg
cmdOf LoadRoster    m = roster (cfg m) GotRoster
cmdOf (Select sid)  m = batch ( knowledgeOf    (cfg m) sid GotKnowledge
                              ∷ episodesOf     (cfg m) sid GotEpisodes
                              ∷ appointmentsOf (cfg m) sid GotAppointments ∷ [] )
cmdOf _             _ = ε

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
  knowRow : KnowledgeView → ℕ → Node Model Msg
  knowRow k _ = li (class ("cxm-know cxm-know-" ++ kvType k) ∷ [])
    ( span (class ("cxm-badge cxm-badge-" ++ kvType k) ∷ []) [ text (kvType k) ]
    ∷ span (class ("cxm-badge cxm-status-" ++ kvStatus k) ∷ []) [ text (kvStatus k) ]
    ∷ span (class "cxm-conf" ∷ []) [ text ("‰" ++ show (kvConfidence k)) ]
    ∷ span (class "cxm-detail" ∷ []) [ text (kvDetail k) ]
    ∷ [] )

  epRow : EpisodeView → ℕ → Node Model Msg
  epRow e _ = li (class "cxm-episode" ∷ [])
    [ text ("эпизод #" ++ show (epvId e) ++ " · состояние " ++ show (epvState e) ++ " · " ++ epvJtbd e) ]

  apRow : AppointmentView → ℕ → Node Model Msg
  apRow a _ = li (class ("cxm-appt cxm-appt-" ++ avStatus a) ∷ [])
    [ text ("бронь #" ++ show (avId a) ++ " · " ++ show (avDuration a) ++ " мин · " ++ avStatus a) ]

cardTemplate : Node Model Msg
cardTemplate =
  div (class "cxm-client-card" ∷ [])
    ( div (class "cxm-toolbar" ∷ [])
        ( button (onClick LoadRoster ∷ class "cxm-load" ∷ []) [ text "Загрузить" ]
        ∷ span (class "cxm-status" ∷ []) [ bindF status ] ∷ [] )
    ∷ div (class "cxm-cols" ∷ [])
        ( div (class "cxm-roster" ∷ [])
            ( h2 [] [ text "Клиенты" ]
            ∷ ul [] ( foreachKeyed subjects (λ r → show (rvId r)) rosterRow ∷ [] ) ∷ [] )
        ∷ div (class "cxm-card" ∷ [])
            ( div (class "cxm-section" ∷ []) ( h2 [] [ text "Знания" ]
                ∷ ul [] ( foreachKeyed knowledge (λ k → show (kvId k)) knowRow ∷ [] ) ∷ [] )
            ∷ div (class "cxm-section" ∷ []) ( h2 [] [ text "Эпизоды" ]
                ∷ ul [] ( foreachKeyed episodes (λ e → show (epvId e)) epRow ∷ [] ) ∷ [] )
            ∷ div (class "cxm-section" ∷ []) ( h2 [] [ text "Брони" ]
                ∷ ul [] ( foreachKeyed appointments (λ a → show (avId a)) apRow ∷ [] ) ∷ [] )
            ∷ [] )
        ∷ [] )
    ∷ [] )

------------------------------------------------------------------------
-- App — a site mounts `clientCardApp cfg`
------------------------------------------------------------------------

clientCardApp : Cfg → ReactiveApp Model Msg
clientCardApp c = mkReactiveApp (initModel c) updateModel cardTemplate cmdOf (λ _ → never)
