{-# OPTIONS --without-K #-}

-- Compile-time tests for Cxm.Projection (Phase 7). Pure projections over the source tables
-- reduce under `refl`; being pure functions they are rebuildable-from-scratch by construction.
module Cxm.Test.ProjectionTest where

open import Relation.Binary.PropositionalEquality using (_≡_; refl)
open import Data.Maybe using (just; nothing)
open import Data.List using (List; []; _∷_)
open import Data.Bool using (false)

open import Cxm.Edge
open import Cxm.Event
open import Cxm.Episode
open import Cxm.Projection

-- fixtures: two episodes for subject 10 (one deleted) + one for subject 20
ep1 ep2 ep3 : Episode
ep1 = mkEpisode 1 10 9 1 0 "j" nothing nothing 0 nothing            -- subj 10, live
ep2 = mkEpisode 2 10 9 1 0 "j" nothing nothing 0 (just 100)          -- subj 10, deleted
ep3 = mkEpisode 3 20 9 1 0 "j" nothing nothing 0 nothing            -- subj 20, live

_ : activeLines 10 (ep1 ∷ ep2 ∷ ep3 ∷ []) ≡ ep1 ∷ []
_ = refl

-- edges: a decision_consult touching 10, a participation touching 10, a decision_consult not
e1 e2 e3 : SubjectEdge
e1 = mkEdge 1 5 10 decision_consult nothing 0 0 nothing 1 0          -- to 10, consult ✓
e2 = mkEdge 2 10 6 participation nothing 0 0 nothing 1 0             -- from 10, but not consult
e3 = mkEdge 3 7 8 decision_consult nothing 0 0 nothing 1 0          -- consult, not touching 10

_ : decisionUnit 10 (e1 ∷ e2 ∷ e3 ∷ []) ≡ e1 ∷ []
_ = refl

-- event type sequence for subject 10 (log order), skipping other subjects
v1 v2 v3 : ExperienceEvent
v1 = mkExperienceEvent 1 10 1 Web Client 100 View 0 nothing nothing nothing nothing false false "{}" nothing
v2 = mkExperienceEvent 2 20 1 Web Client 200 Purchase 0 nothing nothing nothing nothing false false "{}" nothing
v3 = mkExperienceEvent 3 10 1 Web Client 300 Purchase 0 nothing nothing nothing nothing false false "{}" nothing

_ : eventTypeSequence 10 (v1 ∷ v2 ∷ v3 ∷ []) ≡ View ∷ Purchase ∷ []
_ = refl

-- profile aggregates: subject 10 has 2 events, 1 active episode, 0 knowledge
_ : subjectProfile 10 [] (ep1 ∷ ep2 ∷ ep3 ∷ []) (v1 ∷ v2 ∷ v3 ∷ [])
      ≡ mkProfile 10 0 1 2
_ = refl

------------------------------------------------------------------------
-- Peer loop (upgrade-план B4): contribution / co-support / status-drop peaks
------------------------------------------------------------------------

open import Cxm.Event using (Peer; System; Community; Chat; TicketOpen)
open import Data.Product using (_,_)
open import Data.Bool using (Bool; true; false)

pe1 pe2 peSelf sysDrop ordinary : ExperienceEvent
pe1     = mkExperienceEvent 11 10 1 Community Peer 100 TicketOpen 0 nothing nothing nothing nothing false false "{}" (just 20)
pe2     = mkExperienceEvent 12 10 1 Community Peer 200 View 0 nothing nothing nothing nothing false false "{}" (just 30)
peSelf  = mkExperienceEvent 13 10 1 Community Peer 300 View 0 nothing nothing nothing nothing false false "{}" nothing        -- no counterpart → not counted
sysDrop = mkExperienceEvent 14 10 1 Community System 400 View 0 nothing nothing nothing nothing true false "{\"drop\":1}" nothing  -- peak by the mechanic
ordinary = mkExperienceEvent 15 10 1 Chat Client 500 TicketOpen 0 nothing nothing nothing nothing false false "{}" nothing

peerEvs : List ExperienceEvent
peerEvs = pe1 ∷ pe2 ∷ peSelf ∷ sysDrop ∷ ordinary ∷ []

-- authored peer events with a counterpart: pe1 + pe2
_ : contributionOf 10 peerEvs ≡ 2
_ = refl

-- of the TicketOpen events, one is peer-answered of two total
isTicket : ExperienceEvent → Bool
isTicket ev with eeType ev
... | TicketOpen = true
... | _          = false
_ : coSupportShare isTicket peerEvs ≡ (1 , 2)
_ = refl

-- the mechanic-made negative peak is caught; the peer post is not
_ : statusDropPeaks 10 peerEvs ≡ sysDrop ∷ []
_ = refl
