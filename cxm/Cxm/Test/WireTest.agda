{-# OPTIONS --without-K #-}

-- Round-trip tests for Cxm.Wire (Phase 4 DoD): decode (encode x) ≡ just x for EVERY record.
-- `refl` IS the test — the codecs reduce on concrete values. Tricky values exercised:
-- ':'/'|' in strings (length-prefix robustness), nothing/just, and a non-first enum variant
-- (so the CEnumS ordinal mapping is checked, not just the zero case).
module Cxm.Test.WireTest where

open import Relation.Binary.PropositionalEquality using (_≡_; refl)
open import Data.Maybe using (just; nothing)
open import Data.Bool using (true; false)

open import Cxm.Tenant
open import Cxm.Subject
open import Cxm.Edge
open import Cxm.Identity
open import Cxm.Event
open import Cxm.Bus
open import Cxm.Knowledge
open import Cxm.Collections
open import Cxm.Offering
open import Cxm.Resource
open import Cxm.Entitlement
open import Cxm.Account
open import Cxm.Payment
open import Cxm.Expectation
open import Cxm.Protocol
open import Cxm.Episode
open import Cxm.Users
open import Cxm.Appointment
open import Cxm.Wire

-- Tenant
_ : decTenant (encTenant (mkTenant 1 "Acme: with|delims" 1700000000))
      ≡ just (mkTenant 1 "Acme: with|delims" 1700000000)
_ = refl

-- Subject (INTERNAL/Person, provisional, serves just, canonical nothing)
subjV : Subject
subjV = mkSubject 5 INTERNAL Person "Ann:|team" "UTC" 1700000000 (just 1700009999) 2 (just 9) nothing true
_ : decSubject (encSubject subjV) ≡ just subjV
_ = refl

-- Subject merged into a canonical one (canonical = just, exercises the indexed optional-FK
-- 0-sentinel codec: just 42 → 42 → just 42, not collapsed to nothing).
subjMerged : Subject
subjMerged = mkSubject 6 EXTERNAL Org "Prov:|" "UTC" 1700000000 nothing 1 nothing (just 42) true
_ : decSubject (encSubject subjMerged) ≡ just subjMerged
_ = refl

-- SubjectEdge (decision_consult, role just, valid_to just)
edgeV : SubjectEdge
edgeV = mkEdge 7 5 6 decision_consult (just "champion") 3 1700000000 (just 1700100000) 1 1700000001
_ : decEdge (encEdge edgeV) ≡ just edgeV
_ = refl

-- Identity
idV : Identity
idV = mkIdentity 3 5 "cookie" "abc:123|x" false 1 1700000000
_ : decIdentity (encIdentity idV) ≡ just idV
_ = refl

-- ExperienceEvent (Chat/InternalSubject/FeatureRequest, all Maybes just, peak+end)
eeV : ExperienceEvent
eeV = mkExperienceEvent 11 5 1 Chat InternalSubject 1700000000 FeatureRequest 4
        (just 88) (just 1800) (just "hope:|") (just 3) true true "{\"k\":\"v:|\"}" (just 6)
_ : decExperienceEvent (encExperienceEvent eeV) ≡ just eeV
_ = refl

-- ExperienceEvent (bare, all Maybes nothing)
eeBare : ExperienceEvent
eeBare = mkExperienceEvent 12 5 1 Web Client 1700000000 View 0 nothing nothing nothing nothing false false "{}" nothing
_ : decExperienceEvent (encExperienceEvent eeBare) ≡ just eeBare
_ = refl

-- Bus Event
evV : Event
evV = mkEvent 2 "episode.transitioned" "{\"id\":1}" true 1 1700000000
_ : decEvent (encEvent evV) ≡ just evV
_ = refl

-- OutboxEntry (OutSent)
obV : OutboxEntry
obV = mkOutbox 4 "email" "a@b.co" "Subj:|" "Body|:" OutSent 1 1700000000 3 (just 1700000100)
_ : decOutbox (encOutbox obV) ≡ just obV
_ = refl

-- Knowledge (TRAIT/STATED/CONFIRMED, valid_to just, episode just)
kV : Knowledge
kV = mkKnowledge 9 5 1 TRAIT STATED 800 1700000000 (just 1700100000) 5 CONFIRMED "{\"claim\":\"x:|\"}" (just 3)
_ : decKnowledge (encKnowledge kV) ≡ just kV
_ = refl

-- Tier-1 evolution (upgrade-план C1): a row in the OLD wire format — encoded WITHOUT the trailing
-- `episode` column — still decodes: decodeRowTolerant defaults the trailing CMaybe to nothing.
-- The "old schema" reproduces the byte-for-byte pre-C1 column list locally.
private
  open import Data.List using (_∷_; [])
  open import Data.Product using (_,_)
  open import Data.String using (String)
  open import Agda.Builtin.Unit using (tt)
  open import Agdelte.Storage.Schema using
    ( Schema; mkCol; idxCol; CNat; CStr; CBool; CMaybe; CEnumS; CFK; encodeRow )
  open import Cxm.Wire using (epCode; srCode; ksCode)

  oldKnowledgeSchema : Schema
  oldKnowledgeSchema = mkCol "id" CNat ∷ idxCol "subject" (CFK "subject") ∷ mkCol "tenant" (CFK "tenant")
                     ∷ mkCol "type" (CEnumS epCodes) ∷ mkCol "source" (CEnumS srCodes)
                     ∷ mkCol "confidence" CNat ∷ mkCol "valid_from" CNat ∷ mkCol "valid_to" (CMaybe CNat)
                     ∷ mkCol "decay" CNat ∷ mkCol "status" (CEnumS ksCodes) ∷ mkCol "detail" CStr ∷ []

  oldRow : String
  oldRow = encodeRow oldKnowledgeSchema
             (9 , 5 , 1 , epCode TRAIT , srCode STATED , 800 , 1700000000 , just 1700100000
                , 5 , ksCode CONFIRMED , "{\"claim\":\"x:|\"}" , tt)

  tier1-knowledge : decKnowledge oldRow
        ≡ just (mkKnowledge 9 5 1 TRAIT STATED 800 1700000000 (just 1700100000) 5 CONFIRMED
                            "{\"claim\":\"x:|\"}" nothing)
  tier1-knowledge = refl

-- Evidence
evdV : Evidence
evdV = mkEvidence 1 9 11 1 1700000000
_ : decEvidence (encEvidence evdV) ≡ just evdV
_ = refl

-- Transition
trV : Transition
trV = mkTransition 1 20 0 1 1700000000 0 1
_ : decTransition (encTransition trV) ≡ just trV
_ = refl

-- Deviation (Overdue)
dvV : Deviation
dvV = mkDeviation 1 20 Overdue 1700000000 1
_ : decDeviation (encDeviation dvV) ≡ just dvV
_ = refl

-- ProtocolState
psV : ProtocolState
psV = mkProtocolState 1 30 2 "In progress:|" 1
_ : decProtocolState (encProtocolState psV) ≡ just psV
_ = refl

-- ProtocolTransition
ptV : ProtocolTransition
ptV = mkProtocolTransition 1 30 0 2 1
_ : decProtocolTransition (encProtocolTransition ptV) ≡ just ptV
_ = refl

-- Offering
offV : Offering
offV = mkOffering 1 1 3 5000 "RUB" "{\"m\":\"v:|\"}" 0 (just 999)
_ : decOffering (encOffering offV) ≡ just offV
_ = refl

-- Resource (parent just — 0-sentinel keeps a real parent id; updated_at just — П2)
resV : Resource
resV = mkResource 2 1 (just 5) 2 7 (just "public:|") "{}" 0 nothing (just 10) (just "followers") nothing (just 42)
_ : decResource (encResource resV) ≡ just resV
_ = refl

-- Resource (root — parent nothing round-trips through the 0-sentinel)
resRoot : Resource
resRoot = mkResource 3 1 nothing 2 0 nothing "{}" 0 nothing nothing nothing nothing nothing
_ : decResource (encResource resRoot) ≡ just resRoot
_ = refl

-- Entitlement (TResource / SGrant, valid_to just)
entV : Entitlement
entV = mkEntitlement 4 10 1 TResource 2 0 (just 100) SGrant 0
_ : decEntitlement (encEntitlement entV) ≡ just entV
_ = refl

-- Account
accV : Account
accV = mkAccount 5 1 1000 0
_ : decAccount (encAccount accV) ≡ just accV
_ = refl

-- Payment (PaySucceeded)
payV : Payment
payV = mkPayment 6 1 "ext:|id" 1 10 "Name:|" "e@x" 5000 PaySucceeded 4 0
_ : decPayment (encPayment payV) ≡ just payV
_ = refl

-- Expectation (ExpCompetitor / ExpUnmet)
expV : Expectation
expV = mkExpectation 7 10 1 "topic:|" ExpCompetitor 3 ExpUnmet 0
_ : decExpectation (encExpectation expV) ≡ just expV
_ = refl

-- Promise (PromPending, reminded_at just, staked: collateral + explicit accounts — П6)
promV : Promise
promV = mkPromise 8 10 1 "t:|" 1700 PromPending (just 1699) 0 Theirs (just 20) true 5000 (just 3) (just 7) true
_ : decPromise (encPromise promV) ≡ just promV
_ = refl

-- Tier-1 (П6): a promise row in the PRE-stake format (through collateral) decodes with
-- stake_account / penalty_to defaulted to nothing
private
  preStakePromiseSchema : Schema
  preStakePromiseSchema = mkCol "id" CNat ∷ idxCol "subject" (CFK "subject") ∷ mkCol "tenant" (CFK "tenant")
                        ∷ mkCol "topic" CStr ∷ mkCol "deadline" CNat ∷ idxCol "status" (CEnumS promCodes)
                        ∷ mkCol "reminded_at" (CMaybe CNat) ∷ mkCol "created_at" CNat
                        ∷ mkCol "direction" (CEnumS pdCodes) ∷ mkCol "holder" (CMaybe CNat)
                        ∷ mkCol "transferable" CBool ∷ mkCol "collateral" CNat ∷ []
  preStakePromRow : String
  preStakePromRow = encodeRow preStakePromiseSchema
    (9 , 10 , 1 , "t" , 100 , promCode PromPending , nothing , 0 , pdCode Ours , nothing , false , 0 , tt)
  tier1-promise-stake : decPromise preStakePromRow
      ≡ just (mkPromise 9 10 1 "t" 100 PromPending nothing 0 Ours nothing false 0 nothing nothing false)
  tier1-promise-stake = refl

-- Protocol
protoV : Protocol
protoV = mkProtocol 9 1 "booking:|" 0 0
_ : decProtocol (encProtocol protoV) ≡ just protoV
_ = refl

-- Episode (peak just, end nothing)
epiV : Episode
epiV = mkEpisode 10 10 9 1 0 "jtbd:|" (just 5) nothing 0 nothing
_ : decEpisode (encEpisode epiV) ≡ just epiV
_ = refl

-- User
usrV : User
usrV = mkUser 11 1 "login:|" "hash:|" 0
_ : decUser (encUser usrV) ≡ just usrV
_ = refl

-- RoleAssignment
raV : RoleAssignment
raV = mkAssignment 12 1 "login:|" "admin" "/t1:|" 0
_ : decAssignment (encAssignment raV) ≡ just raV
_ = refl

-- Appointment (episode just, entitlement just, ApScheduled)
apV : Appointment
apV = mkAppointment 13 10 0 (just 5) (just 7) 1700000000 90 ApScheduled (just 1699999999) 1 0 (just 8)
_ : decAppointment (encAppointment apV) ≡ just apV
_ = refl

-- Appointment (ad-hoc: no episode, no entitlement — 0-sentinel/nothing round-trips)
apAdhoc : Appointment
apAdhoc = mkAppointment 14 10 0 nothing nothing 1700000000 30 ApCompleted nothing 1 0 nothing
_ : decAppointment (encAppointment apAdhoc) ≡ just apAdhoc
_ = refl

-- Tier-1 evolution (upgrade-план B1): an ExperienceEvent row in the OLD wire format (encoded
-- WITHOUT the trailing `counterpart` column) still decodes with eeCounterpart = nothing.
private
  oldEventSchema : Schema
  oldEventSchema = mkCol "id" CNat ∷ idxCol "subject" (CFK "subject") ∷ mkCol "tenant" (CFK "tenant")
                 ∷ mkCol "channel" (CEnumS chCodes) ∷ mkCol "actor" (CEnumS acCodes)
                 ∷ mkCol "timestamp" CNat ∷ mkCol "type" (CEnumS etCodes)
                 ∷ mkCol "lifecycle_stage" CNat ∷ idxCol "episode" (CFK "episode")
                 ∷ mkCol "sentiment" (CMaybe CNat) ∷ mkCol "emotion" (CMaybe CStr)
                 ∷ mkCol "effort" (CMaybe CNat) ∷ mkCol "is_peak" CBool ∷ mkCol "is_end" CBool
                 ∷ mkCol "payload" CStr ∷ []

  oldEvRow : String
  oldEvRow = encodeRow oldEventSchema
               (12 , 5 , 1 , chCode Web , acCode Client , 1700000000 , etCode View , 0 , 0
                  , nothing , nothing , nothing , false , false , "{}" , tt)

  tier1-event : decExperienceEvent oldEvRow ≡ just eeBare
  tier1-event = refl

-- IntTokenRow (integration credential; cloud-Фаза 1 — аудит-доукладка)
open import Cxm.Site using (IntTokenRow; mkIntTokenRow)
itkV : IntTokenRow
itkV = mkIntTokenRow 15 1 "sec:|ret" "/v1" "https://a.example" 1700000000 (just 17009)
_ : decIntToken (encIntToken itkV) ≡ just itkV
_ = refl

-- ResourceLink (curation graph, S8)
rlV : ResourceLink
rlV = mkResourceLink 16 1 500 120 "promo:|" 3 1700000000 (just 1700005) 1700000001
_ : decResourceLink (encResourceLink rlV) ≡ just rlV
_ = refl

-- Tier-1 (S1+S7): a resource row in the PRE-social format (no author, no listing) decodes
-- with both defaulted to nothing
private
  oldResourceSchema : Schema
  oldResourceSchema = mkCol "id" CNat ∷ mkCol "tenant" (CFK "tenant") ∷ idxCol "parent" (CFK "resource")
                    ∷ mkCol "kind" CNat ∷ mkCol "ord" CNat ∷ mkCol "visibility" (CMaybe CStr)
                    ∷ mkCol "payload" CStr ∷ mkCol "created_at" CNat ∷ mkCol "deleted_at" (CMaybe CNat) ∷ []
  oldResRow : String
  oldResRow = encodeRow oldResourceSchema (3 , 1 , 0 , 2 , 0 , nothing , "{}" , 0 , nothing , tt)
  tier1-resource : decResource oldResRow
      ≡ just (mkResource 3 1 nothing 2 0 nothing "{}" 0 nothing nothing nothing nothing nothing)
  tier1-resource = refl

-- Tier-1 (П2): a resource row in the PRE-updated_at format (through anchor/stream_root) decodes
-- with rUpdatedAt defaulted to nothing
private
  preUpdResourceSchema : Schema
  preUpdResourceSchema = mkCol "id" CNat ∷ mkCol "tenant" (CFK "tenant") ∷ idxCol "parent" (CFK "resource")
                       ∷ mkCol "kind" CNat ∷ mkCol "ord" CNat ∷ mkCol "visibility" (CMaybe CStr)
                       ∷ mkCol "payload" CStr ∷ mkCol "created_at" CNat ∷ mkCol "deleted_at" (CMaybe CNat)
                       ∷ mkCol "author" (CMaybe CNat) ∷ mkCol "listing" (CMaybe CStr)
                       ∷ mkCol "anchor_kind" (CMaybe CStr) ∷ mkCol "anchor_id" (CMaybe CNat)
                       ∷ mkCol "stream_root" (CMaybe CNat) ∷ []
  preUpdResRow : String
  preUpdResRow = encodeRow preUpdResourceSchema
    (7 , 1 , 0 , 1 , 0 , just "public" , "{}" , 5 , nothing , just 10 , nothing
       , just "resource" , just 3 , just 7 , tt)
  tier1-resource-upd : decResource preUpdResRow
      ≡ just (mkResource 7 1 nothing 1 0 (just "public") "{}" 5 nothing (just 10) nothing
                (just (mkConvCtx "resource" 3 7 nothing)) nothing)
  tier1-resource-upd = refl

-- Tier-1 (§10 под-локация): a resource row in the PRE-anchor_locator format (through
-- updated_at) decodes with ccLocator defaulted to nothing
private
  preLocResourceSchema : Schema
  preLocResourceSchema = mkCol "id" CNat ∷ mkCol "tenant" (CFK "tenant") ∷ idxCol "parent" (CFK "resource")
                       ∷ mkCol "kind" CNat ∷ mkCol "ord" CNat ∷ mkCol "visibility" (CMaybe CStr)
                       ∷ mkCol "payload" CStr ∷ mkCol "created_at" CNat ∷ mkCol "deleted_at" (CMaybe CNat)
                       ∷ mkCol "author" (CMaybe CNat) ∷ mkCol "listing" (CMaybe CStr)
                       ∷ mkCol "anchor_kind" (CMaybe CStr) ∷ mkCol "anchor_id" (CMaybe CNat)
                       ∷ mkCol "stream_root" (CMaybe CNat)
                       ∷ mkCol "updated_at" (CMaybe CNat) ∷ []
  preLocResRow : String
  preLocResRow = encodeRow preLocResourceSchema
    (8 , 1 , 0 , 1 , 0 , just "public" , "{}" , 6 , nothing , just 10 , nothing
       , just "appointment" , just 4 , just 8 , just 9 , tt)
  tier1-resource-loc : decResource preLocResRow
      ≡ just (mkResource 8 1 nothing 1 0 (just "public") "{}" 6 nothing (just 10) nothing
                (just (mkConvCtx "appointment" 4 8 nothing)) (just 9))
  tier1-resource-loc = refl

-- §10 под-локация: round-trip строки С локатором
private
  locRes : Resource
  locRes = mkResource 9 1 nothing 1 0 (just "public") "{}" 6 nothing (just 10) nothing
             (just (mkConvCtx "resource" 4 9 (just "t=73"))) nothing
  roundtrip-locator : decResource (encResource locRes) ≡ just locRes
  roundtrip-locator = refl
