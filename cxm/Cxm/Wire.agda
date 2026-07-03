{-# OPTIONS --without-K #-}

-- Wire codecs for every CXM record (cxm-plan.md Phase 4, §8.1). One `Schema` per record
-- yields ALL THREE interpretations at once (§8.1): the WAL codec (encodeRow/decodeRow),
-- the secondary indexes (idxCol → imIndexes), and the SQL DDL (ddlOf). We never hand-write
-- index extractors. Enums are stored as CEnumS ordinals (indexable + SQL SMALLINT); a
-- `xCode`/`xOfOrd` pair per enum maps to/from the ordinal.
--
-- Round-trip is the contract: decode (encode x) ≡ just x (per-record test, Phase 4 DoD).
-- Indexed columns are marked with `idxCol` per the queries of Phases 6–8; the index
-- POSITION is the order of idxCol columns in the schema (see the per-record notes).
--
-- Grows with Phase 6: schemas for Offering/Resource/Entitlement/… are appended here when
-- those records land (plan's Phase 4/6 note).
module Cxm.Wire where

open import Data.Nat using (ℕ; zero; suc)
open import Data.Bool using (Bool; false)
open import Data.String using (String)
open import Data.Maybe using (Maybe; just; nothing) renaming (map to mapMaybe)
open import Data.List using (List; []; _∷_)
open import Data.Product using (_,_)
open import Agda.Builtin.Unit using (tt)

open import Agdelte.Storage.Schema using
  ( ColTy; CNat; CStr; CBool; CEnumS; CMaybe; CFK
  ; mkCol; idxCol; Schema; Row; encodeRow; decodeRow; decodeRowTolerant )

open import Cxm.Tenant
open import Cxm.Subject
open import Cxm.Edge
open import Cxm.Identity
open import Cxm.Event
open import Cxm.Bus
open import Cxm.Knowledge
open import Cxm.Collections
-- Phase 6 domain-truth entities
open import Cxm.Offering
open import Cxm.Resource
open import Cxm.Entitlement
open import Cxm.Account
open import Cxm.Payment
open import Cxm.Expectation
open import Cxm.Protocol
open import Cxm.Episode
open import Cxm.Users
open import Cxm.Site using
  ( IntTokenRow; mkIntTokenRow; itkId; itkTenant; itkToken; itkScope; itkOrigin
  ; itkCreatedAt; itkRevokedAt )
open import Cxm.Appointment

-- Maybe-bind for fromRow steps that may fail on an unknown enum ordinal (strict decode).
infixl 1 _>>=ᵐ_
_>>=ᵐ_ : ∀ {A B : Set} → Maybe A → (A → Maybe B) → Maybe B
nothing >>=ᵐ _ = nothing
just x  >>=ᵐ f = f x

-- Optional-FK codec via a 0 sentinel (audit finding #2). A nullable FK stored as `CMaybe`
-- is NOT indexable (Schema indexes ℕ-valued columns only), yet some optional FKs are read
-- HOT (all events of an episode; all subjects merged into a canonical one). Since surrogate
-- ids start at 1 (nextId), 0 is a safe "none" sentinel: we keep the domain type `Maybe ℕ`
-- but store an indexable `CFK` column. `fkOrZero`/`zeroToNothing` are round-trip inverses
-- for ids ≥ 1 and for `nothing`.
fkOrZero : Maybe ℕ → ℕ
fkOrZero nothing  = 0
fkOrZero (just n) = n

zeroToNothing : ℕ → Maybe ℕ
zeroToNothing zero    = nothing
zeroToNothing (suc n) = just (suc n)

------------------------------------------------------------------------
-- Enum codecs: code list (wire strings) + ordinal ↔ enum. Ordinal = list position.
------------------------------------------------------------------------

-- SubjectKind
skCodes : List String
skCodes = "E" ∷ "I" ∷ []
skCode : SubjectKind → ℕ
skCode EXTERNAL = 0
skCode INTERNAL = 1
skOfOrd : ℕ → Maybe SubjectKind
skOfOrd 0 = just EXTERNAL
skOfOrd 1 = just INTERNAL
skOfOrd _ = nothing

-- SubjectStructure
ssCodes : List String
ssCodes = "P" ∷ "A" ∷ []
ssCode : SubjectStructure → ℕ
ssCode Person = 0
ssCode Org    = 1
ssOfOrd : ℕ → Maybe SubjectStructure
ssOfOrd 0 = just Person
ssOfOrd 1 = just Org
ssOfOrd _ = nothing

-- EdgeKind
ekCodes : List String
ekCodes = "par" ∷ "mem" ∷ "dec" ∷ "own" ∷ "pat" ∷ "fol" ∷ []
ekCode : EdgeKind → ℕ
ekCode participation    = 0
ekCode membership       = 1
ekCode decision_consult = 2
ekCode owner            = 3
ekCode patient          = 4
ekCode follow           = 5
ekOfOrd : ℕ → Maybe EdgeKind
ekOfOrd 0 = just participation
ekOfOrd 1 = just membership
ekOfOrd 2 = just decision_consult
ekOfOrd 3 = just owner
ekOfOrd 4 = just patient
ekOfOrd 5 = just follow
ekOfOrd _ = nothing

-- Channel
chCodes : List String
chCodes = "web" ∷ "mob" ∷ "cht" ∷ "eml" ∷ "phn" ∷ "prd" ∷ "int" ∷ "itg" ∷ "com" ∷ []
chCode : Channel → ℕ
chCode Web         = 0
chCode Mobile      = 1
chCode Chat        = 2
chCode Email       = 3
chCode Phone       = 4
chCode Product     = 5
chCode Internal    = 6
chCode Integration = 7
chCode Community   = 8
chOfOrd : ℕ → Maybe Channel
chOfOrd 0 = just Web
chOfOrd 1 = just Mobile
chOfOrd 2 = just Chat
chOfOrd 3 = just Email
chOfOrd 4 = just Phone
chOfOrd 5 = just Product
chOfOrd 6 = just Internal
chOfOrd 7 = just Integration
chOfOrd 8 = just Community
chOfOrd _ = nothing

-- Actor
acCodes : List String
acCodes = "cli" ∷ "stf" ∷ "sys" ∷ "ins" ∷ "per" ∷ []
acCode : Actor → ℕ
acCode Client          = 0
acCode Staff           = 1
acCode System          = 2
acCode InternalSubject = 3
acCode Peer            = 4
acOfOrd : ℕ → Maybe Actor
acOfOrd 0 = just Client
acOfOrd 1 = just Staff
acOfOrd 2 = just System
acOfOrd 3 = just InternalSubject
acOfOrd 4 = just Peer
acOfOrd _ = nothing

-- EventType
etCodes : List String
etCodes = "viw" ∷ "pur" ∷ "tko" ∷ "ftu" ∷ "ftr" ∷ "hnd" ∷ "lcc"
        ∷ "pls" ∷ "ptr" ∷ "pst" ∷ "pdf" ∷ "pub" ∷ "rct" ∷ "pdc" ∷ []
etCode : EventType → ℕ
etCode View               = 0
etCode Purchase           = 1
etCode TicketOpen         = 2
etCode FeatureUse         = 3
etCode FeatureRequest     = 4
etCode InternalHandoff    = 5
etCode LifecycleChange    = 6
etCode PromiseListed      = 7
etCode PromiseTransferred = 8
etCode PromiseSettled     = 9
etCode PromiseDefaulted   = 10
etCode Publish            = 11
etCode Reaction           = 12
etCode PromiseDeclared    = 13   -- appended at END: existing event codes stay stable (Tier-1)
etOfOrd : ℕ → Maybe EventType
etOfOrd 0 = just View
etOfOrd 1 = just Purchase
etOfOrd 2 = just TicketOpen
etOfOrd 3 = just FeatureUse
etOfOrd 4 = just FeatureRequest
etOfOrd 5 = just InternalHandoff
etOfOrd 6 = just LifecycleChange
etOfOrd 7 = just PromiseListed
etOfOrd 8 = just PromiseTransferred
etOfOrd 9 = just PromiseSettled
etOfOrd 10 = just PromiseDefaulted
etOfOrd 11 = just Publish
etOfOrd 12 = just Reaction
etOfOrd 13 = just PromiseDeclared
etOfOrd _ = nothing

-- OutStatus
osCodes : List String
osCodes = "P" ∷ "S" ∷ "F" ∷ []
osCode : OutStatus → ℕ
osCode OutPending = 0
osCode OutSent    = 1
osCode OutFailed  = 2
osOfOrd : ℕ → Maybe OutStatus
osOfOrd 0 = just OutPending
osOfOrd 1 = just OutSent
osOfOrd 2 = just OutFailed
osOfOrd _ = nothing

-- EpistemicType
epCodes : List String
epCodes = "F" ∷ "H" ∷ "S" ∷ "T" ∷ []
epCode : EpistemicType → ℕ
epCode FACT       = 0
epCode HYPOTHESIS = 1
epCode STATE      = 2
epCode TRAIT      = 3
epOfOrd : ℕ → Maybe EpistemicType
epOfOrd 0 = just FACT
epOfOrd 1 = just HYPOTHESIS
epOfOrd 2 = just STATE
epOfOrd 3 = just TRAIT
epOfOrd _ = nothing

-- Source
srCodes : List String
srCodes = "O" ∷ "I" ∷ "S" ∷ "M" ∷ []
srCode : Source → ℕ
srCode OBSERVED = 0
srCode INFERRED = 1
srCode STATED   = 2
srCode IMPORTED = 3
srOfOrd : ℕ → Maybe Source
srOfOrd 0 = just OBSERVED
srOfOrd 1 = just INFERRED
srOfOrd 2 = just STATED
srOfOrd 3 = just IMPORTED
srOfOrd _ = nothing

-- KStatus
ksCodes : List String
ksCodes = "A" ∷ "C" ∷ "R" ∷ "U" ∷ []
ksCode : KStatus → ℕ
ksCode ACTIVE     = 0
ksCode CONFIRMED  = 1
ksCode REFUTED    = 2
ksCode SUPERSEDED = 3
ksOfOrd : ℕ → Maybe KStatus
ksOfOrd 0 = just ACTIVE
ksOfOrd 1 = just CONFIRMED
ksOfOrd 2 = just REFUTED
ksOfOrd 3 = just SUPERSEDED
ksOfOrd _ = nothing

-- DeviationKind
dkCodes : List String
dkCodes = "stk" ∷ "rbk" ∷ "ovd" ∷ []
dkCode : DeviationKind → ℕ
dkCode Stuck    = 0
dkCode Rollback = 1
dkCode Overdue  = 2
dkOfOrd : ℕ → Maybe DeviationKind
dkOfOrd 0 = just Stuck
dkOfOrd 1 = just Rollback
dkOfOrd 2 = just Overdue
dkOfOrd _ = nothing

------------------------------------------------------------------------
-- Tenant
------------------------------------------------------------------------

tenantSchema : Schema
tenantSchema = mkCol "id" CNat ∷ mkCol "name" CStr ∷ mkCol "created_at" CNat ∷ []

tenantToRow : Tenant → Row tenantSchema
tenantToRow t = tId t , tName t , tCreatedAt t , tt

tenantFromRow : Row tenantSchema → Tenant
tenantFromRow (i , nm , ca , tt) = mkTenant i nm ca

encTenant : Tenant → String
encTenant t = encodeRow tenantSchema (tenantToRow t)
decTenant : String → Maybe Tenant
decTenant s = mapMaybe tenantFromRow (decodeRow tenantSchema s)

------------------------------------------------------------------------
-- Subject — index 0: byTenant, 1: byCanonical
--
-- Tenant-index policy (audit finding #4): `tenant` is indexed HERE because listing a
-- tenant's subjects is the natural first multi-tenant read; on other entities the tenant
-- column is present but UNindexed while the multi-tenant runtime is deferred (§9.8). This
-- is a deliberate choice, not an omission — add byTenant elsewhere when those reads land.
--
-- `canonical` is an indexed optional-FK (0 = "is itself canonical", via fkOrZero) so merge
-- reverse-resolution — "which subjects are aliased into canonical X" (§4.4) — is an index
-- lookup, not a scan. This is the "record" arm of §4.4's "edge/record" alias; an `alias`
-- EdgeKind is intentionally NOT added (it would be unused branch complexity — principle 7).
------------------------------------------------------------------------

subjectSchema : Schema
subjectSchema = mkCol "id" CNat ∷ mkCol "kind" (CEnumS skCodes) ∷ mkCol "structure" (CEnumS ssCodes)
              ∷ mkCol "display_name" CStr ∷ mkCol "tz" CStr ∷ mkCol "created_at" CNat
              ∷ mkCol "deleted_at" (CMaybe CNat) ∷ idxCol "tenant" (CFK "tenant")
              ∷ mkCol "serves" (CMaybe CNat) ∷ idxCol "canonical" (CFK "subject")
              ∷ mkCol "provisional" CBool ∷ []

subjectToRow : Subject → Row subjectSchema
subjectToRow s = sId s , skCode (sKind s) , ssCode (sStructure s) , sDisplayName s , sTz s
               , sCreatedAt s , sDeletedAt s , sTenant s , sServes s , fkOrZero (sCanonical s)
               , sProvisional s , tt

subjectFromRow : Row subjectSchema → Maybe Subject
subjectFromRow (i , k , st , dn , tz , ca , dd , ten , srv , can , prov , tt) =
  skOfOrd k >>=ᵐ λ kk → ssOfOrd st >>=ᵐ λ ss →
  just (mkSubject i kk ss dn tz ca dd ten srv (zeroToNothing can) prov)

encSubject : Subject → String
encSubject s = encodeRow subjectSchema (subjectToRow s)
decSubject : String → Maybe Subject
decSubject s = decodeRow subjectSchema s >>=ᵐ subjectFromRow

------------------------------------------------------------------------
-- SubjectEdge — index 0: byFrom, 1: byTo, 2: byKind
------------------------------------------------------------------------

edgeSchema : Schema
edgeSchema = mkCol "id" CNat ∷ idxCol "from_subject" (CFK "subject") ∷ idxCol "to_subject" (CFK "subject")
           ∷ idxCol "kind" (CEnumS ekCodes) ∷ mkCol "role" (CMaybe CStr) ∷ mkCol "ordinal" CNat
           ∷ mkCol "valid_from" CNat ∷ mkCol "valid_to" (CMaybe CNat) ∷ mkCol "tenant" (CFK "tenant")
           ∷ mkCol "created_at" CNat ∷ []

edgeToRow : SubjectEdge → Row edgeSchema
edgeToRow e = seId e , seFrom e , seTo e , ekCode (seKind e) , seRole e , seOrdinal e
            , seValidFrom e , seValidTo e , seTenant e , seCreatedAt e , tt

edgeFromRow : Row edgeSchema → Maybe SubjectEdge
edgeFromRow (i , fr , to , k , role , ord , vf , vt , ten , ca , tt) =
  ekOfOrd k >>=ᵐ λ kk → just (mkEdge i fr to kk role ord vf vt ten ca)

encEdge : SubjectEdge → String
encEdge e = encodeRow edgeSchema (edgeToRow e)
decEdge : String → Maybe SubjectEdge
decEdge s = decodeRow edgeSchema s >>=ᵐ edgeFromRow

------------------------------------------------------------------------
-- Identity — index 0: bySubject
------------------------------------------------------------------------

identitySchema : Schema
identitySchema = mkCol "id" CNat ∷ idxCol "subject" (CFK "subject") ∷ mkCol "channel" CStr
               ∷ mkCol "external_id" CStr ∷ mkCol "verified" CBool ∷ mkCol "tenant" (CFK "tenant")
               ∷ mkCol "created_at" CNat ∷ []

identityToRow : Identity → Row identitySchema
identityToRow x = iId x , iSubject x , iChannel x , iExternalId x , iVerified x , iTenant x , iCreatedAt x , tt

identityFromRow : Row identitySchema → Identity
identityFromRow (i , subj , ch , ext , v , ten , ca , tt) = mkIdentity i subj ch ext v ten ca

encIdentity : Identity → String
encIdentity x = encodeRow identitySchema (identityToRow x)
decIdentity : String → Maybe Identity
decIdentity s = mapMaybe identityFromRow (decodeRow identitySchema s)

------------------------------------------------------------------------
-- ExperienceEvent — index 0: bySubject, 1: byEpisode (append-only source of truth, §8.3)
--
-- `episode` is an indexed optional-FK (0 = "no episode", via fkOrZero) so "all events of an
-- episode" — the hot read behind episode-state projection (Phase 7) — is an index lookup,
-- not a scan over the whole event log (audit finding #2).
------------------------------------------------------------------------

-- `counterpart` appended LAST as CMaybe (peer events §0.6; Tier-1 auto-defaultable — B1)
experienceEventSchema : Schema
experienceEventSchema = mkCol "id" CNat ∷ idxCol "subject" (CFK "subject") ∷ mkCol "tenant" (CFK "tenant")
                      ∷ mkCol "channel" (CEnumS chCodes) ∷ mkCol "actor" (CEnumS acCodes)
                      ∷ mkCol "timestamp" CNat ∷ mkCol "type" (CEnumS etCodes)
                      ∷ mkCol "lifecycle_stage" CNat ∷ idxCol "episode" (CFK "episode")
                      ∷ mkCol "sentiment" (CMaybe CNat) ∷ mkCol "emotion" (CMaybe CStr)
                      ∷ mkCol "effort" (CMaybe CNat) ∷ mkCol "is_peak" CBool ∷ mkCol "is_end" CBool
                      ∷ mkCol "payload" CStr ∷ mkCol "counterpart" (CMaybe CNat) ∷ []

eeToRow : ExperienceEvent → Row experienceEventSchema
eeToRow e = eeId e , eeSubject e , eeTenant e , chCode (eeChannel e) , acCode (eeActor e)
          , eeTimestamp e , etCode (eeType e) , eeLifecycleStage e , fkOrZero (eeEpisode e)
          , eeSentiment e , eeEmotion e , eeEffort e , eeIsPeak e , eeIsEnd e , eePayload e
          , eeCounterpart e , tt

eeFromRow : Row experienceEventSchema → Maybe ExperienceEvent
eeFromRow (i , subj , ten , ch , ac , ts , ty , ls , ep , se , em , ef , pk , en , pl , cp , tt) =
  chOfOrd ch >>=ᵐ λ cc → acOfOrd ac >>=ᵐ λ aa → etOfOrd ty >>=ᵐ λ tt′ →
  just (mkExperienceEvent i subj ten cc aa ts tt′ ls (zeroToNothing ep) se em ef pk en pl cp)

encExperienceEvent : ExperienceEvent → String
encExperienceEvent e = encodeRow experienceEventSchema (eeToRow e)
decExperienceEvent : String → Maybe ExperienceEvent
decExperienceEvent s = decodeRowTolerant experienceEventSchema s >>=ᵐ eeFromRow

------------------------------------------------------------------------
-- Bus Event — index 0: byProcessed (0 = unprocessed)
------------------------------------------------------------------------

busEventSchema : Schema
busEventSchema = mkCol "id" CNat ∷ mkCol "topic" CStr ∷ mkCol "payload" CStr
               ∷ idxCol "processed" CBool ∷ mkCol "tenant" (CFK "tenant") ∷ mkCol "created_at" CNat ∷ []

evToRow : Event → Row busEventSchema
evToRow e = evId e , evTopic e , evPayload e , evProcessed e , evTenant e , evCreatedAt e , tt

evFromRow : Row busEventSchema → Event
evFromRow (i , tp , pl , pr , ten , ca , tt) = mkEvent i tp pl pr ten ca

encEvent : Event → String
encEvent e = encodeRow busEventSchema (evToRow e)
decEvent : String → Maybe Event
decEvent s = mapMaybe evFromRow (decodeRow busEventSchema s)

------------------------------------------------------------------------
-- OutboxEntry — index 0: byStatus
------------------------------------------------------------------------

-- retry columns appended LAST (D2); attempts is non-Maybe — acceptable pre-prod (решение 3в)
outboxSchema : Schema
outboxSchema = mkCol "id" CNat ∷ mkCol "channel" CStr ∷ mkCol "to_addr" CStr
             ∷ mkCol "subject" CStr ∷ mkCol "body" CStr ∷ idxCol "status" (CEnumS osCodes)
             ∷ mkCol "tenant" (CFK "tenant") ∷ mkCol "created_at" CNat
             ∷ mkCol "attempts" CNat ∷ mkCol "last_attempt" (CMaybe CNat) ∷ []

obToRow : OutboxEntry → Row outboxSchema
obToRow o = obId o , obChannel o , obTo o , obSubject o , obBody o , osCode (obStatus o)
          , obTenant o , obCreatedAt o , obAttempts o , obLastAttempt o , tt

obFromRow : Row outboxSchema → Maybe OutboxEntry
obFromRow (i , ch , to , subj , body , sto , ten , ca , att , la , tt) =
  osOfOrd sto >>=ᵐ λ st → just (mkOutbox i ch to subj body st ten ca att la)

encOutbox : OutboxEntry → String
encOutbox o = encodeRow outboxSchema (obToRow o)
decOutbox : String → Maybe OutboxEntry
decOutbox s = decodeRowTolerant outboxSchema s >>=ᵐ obFromRow

------------------------------------------------------------------------
-- Knowledge — index 0: bySubject
------------------------------------------------------------------------

-- `episode` appended LAST as CMaybe (Tier-1: auto-defaultable → old rows still decode
-- tolerantly as nothing; upgrade-план C1).
knowledgeSchema : Schema
knowledgeSchema = mkCol "id" CNat ∷ idxCol "subject" (CFK "subject") ∷ mkCol "tenant" (CFK "tenant")
                ∷ mkCol "type" (CEnumS epCodes) ∷ mkCol "source" (CEnumS srCodes)
                ∷ mkCol "confidence" CNat ∷ mkCol "valid_from" CNat ∷ mkCol "valid_to" (CMaybe CNat)
                ∷ mkCol "decay" CNat ∷ mkCol "status" (CEnumS ksCodes) ∷ mkCol "detail" CStr
                ∷ mkCol "episode" (CMaybe CNat) ∷ []

knowledgeToRow : Knowledge → Row knowledgeSchema
knowledgeToRow k = kId k , kSubject k , kTenant k , epCode (kType k) , srCode (kSource k)
                 , kConfidence k , kValidFrom k , kValidTo k , kDecay k , ksCode (kStatus k)
                 , kDetail k , kEpisode k , tt

knowledgeFromRow : Row knowledgeSchema → Maybe Knowledge
knowledgeFromRow (i , subj , ten , ty , src , cf , vf , vt , dec , st , dt , ep , tt) =
  epOfOrd ty >>=ᵐ λ tt′ → srOfOrd src >>=ᵐ λ ss → ksOfOrd st >>=ᵐ λ kk →
  just (mkKnowledge i subj ten tt′ ss cf vf vt dec kk dt ep)

encKnowledge : Knowledge → String
encKnowledge k = encodeRow knowledgeSchema (knowledgeToRow k)
decKnowledge : String → Maybe Knowledge
decKnowledge s = decodeRowTolerant knowledgeSchema s >>=ᵐ knowledgeFromRow

------------------------------------------------------------------------
-- Evidence (child) — index 0: byKnowledge, 1: byEvent
------------------------------------------------------------------------

evidenceSchema : Schema
evidenceSchema = mkCol "id" CNat ∷ idxCol "knowledge_id" (CFK "knowledge")
               ∷ idxCol "event_id" (CFK "experience_event") ∷ mkCol "tenant" (CFK "tenant")
               ∷ mkCol "created_at" CNat ∷ []

evidenceToRow : Evidence → Row evidenceSchema
evidenceToRow e = evdId e , evdKnowledge e , evdEvent e , evdTenant e , evdCreatedAt e , tt

evidenceFromRow : Row evidenceSchema → Evidence
evidenceFromRow (i , kn , ev , ten , ca , tt) = mkEvidence i kn ev ten ca

encEvidence : Evidence → String
encEvidence e = encodeRow evidenceSchema (evidenceToRow e)
decEvidence : String → Maybe Evidence
decEvidence s = mapMaybe evidenceFromRow (decodeRow evidenceSchema s)

------------------------------------------------------------------------
-- Transition (child) — index 0: byEpisode
------------------------------------------------------------------------

transitionSchema : Schema
transitionSchema = mkCol "id" CNat ∷ idxCol "episode_id" (CFK "episode") ∷ mkCol "from_state" CNat
                 ∷ mkCol "to_state" CNat ∷ mkCol "at" CNat ∷ mkCol "ordinal" CNat
                 ∷ mkCol "tenant" (CFK "tenant") ∷ []

transitionToRow : Transition → Row transitionSchema
transitionToRow t = trId t , trEpisode t , trFromState t , trToState t , trAt t , trOrdinal t , trTenant t , tt

transitionFromRow : Row transitionSchema → Transition
transitionFromRow (i , ep , fs , ts , at , ord , ten , tt) = mkTransition i ep fs ts at ord ten

encTransition : Transition → String
encTransition t = encodeRow transitionSchema (transitionToRow t)
decTransition : String → Maybe Transition
decTransition s = mapMaybe transitionFromRow (decodeRow transitionSchema s)

------------------------------------------------------------------------
-- Deviation (child) — index 0: byEpisode
------------------------------------------------------------------------

deviationSchema : Schema
deviationSchema = mkCol "id" CNat ∷ idxCol "episode_id" (CFK "episode") ∷ mkCol "kind" (CEnumS dkCodes)
                ∷ mkCol "at" CNat ∷ mkCol "tenant" (CFK "tenant") ∷ []

deviationToRow : Deviation → Row deviationSchema
deviationToRow d = dvId d , dvEpisode d , dkCode (dvKind d) , dvAt d , dvTenant d , tt

deviationFromRow : Row deviationSchema → Maybe Deviation
deviationFromRow (i , ep , k , at , ten , tt) =
  dkOfOrd k >>=ᵐ λ kk → just (mkDeviation i ep kk at ten)

encDeviation : Deviation → String
encDeviation d = encodeRow deviationSchema (deviationToRow d)
decDeviation : String → Maybe Deviation
decDeviation s = decodeRow deviationSchema s >>=ᵐ deviationFromRow

------------------------------------------------------------------------
-- ProtocolState (child) — index 0: byProtocol
------------------------------------------------------------------------

protocolStateSchema : Schema
protocolStateSchema = mkCol "id" CNat ∷ idxCol "protocol_id" (CFK "protocol") ∷ mkCol "state" CNat
                    ∷ mkCol "name" CStr ∷ mkCol "tenant" (CFK "tenant") ∷ []

protocolStateToRow : ProtocolState → Row protocolStateSchema
protocolStateToRow p = psId p , psProtocol p , psState p , psName p , psTenant p , tt

protocolStateFromRow : Row protocolStateSchema → ProtocolState
protocolStateFromRow (i , pr , st , nm , ten , tt) = mkProtocolState i pr st nm ten

encProtocolState : ProtocolState → String
encProtocolState p = encodeRow protocolStateSchema (protocolStateToRow p)
decProtocolState : String → Maybe ProtocolState
decProtocolState s = mapMaybe protocolStateFromRow (decodeRow protocolStateSchema s)

------------------------------------------------------------------------
-- ProtocolTransition (child) — index 0: byProtocol
------------------------------------------------------------------------

protocolTransitionSchema : Schema
protocolTransitionSchema = mkCol "id" CNat ∷ idxCol "protocol_id" (CFK "protocol") ∷ mkCol "from_state" CNat
                         ∷ mkCol "to_state" CNat ∷ mkCol "tenant" (CFK "tenant") ∷ []

protocolTransitionToRow : ProtocolTransition → Row protocolTransitionSchema
protocolTransitionToRow p = ptId p , ptProtocol p , ptFromState p , ptToState p , ptTenant p , tt

protocolTransitionFromRow : Row protocolTransitionSchema → ProtocolTransition
protocolTransitionFromRow (i , pr , fs , ts , ten , tt) = mkProtocolTransition i pr fs ts ten

encProtocolTransition : ProtocolTransition → String
encProtocolTransition p = encodeRow protocolTransitionSchema (protocolTransitionToRow p)
decProtocolTransition : String → Maybe ProtocolTransition
decProtocolTransition s = mapMaybe protocolTransitionFromRow (decodeRow protocolTransitionSchema s)

------------------------------------------------------------------------
-- Phase 6 enum codecs (names disjoint from the Phase 1–4 ones)
------------------------------------------------------------------------

-- EntTarget
entCodes : List String
entCodes = "off" ∷ "res" ∷ "mem" ∷ []
entCode : EntTarget → ℕ
entCode TOffering   = 0
entCode TResource   = 1
entCode TMembership = 2
entOfOrd : ℕ → Maybe EntTarget
entOfOrd 0 = just TOffering
entOfOrd 1 = just TResource
entOfOrd 2 = just TMembership
entOfOrd _ = nothing

-- EntSource
ensCodes : List String
ensCodes = "pay" ∷ "grt" ∷ []
ensCode : EntSource → ℕ
ensCode SPayment = 0
ensCode SGrant   = 1
ensOfOrd : ℕ → Maybe EntSource
ensOfOrd 0 = just SPayment
ensOfOrd 1 = just SGrant
ensOfOrd _ = nothing

-- PayStatus
payCodes : List String
payCodes = "P" ∷ "S" ∷ "F" ∷ []
payCode : PayStatus → ℕ
payCode PayPending   = 0
payCode PaySucceeded = 1
payCode PayFailed    = 2
payOfOrd : ℕ → Maybe PayStatus
payOfOrd 0 = just PayPending
payOfOrd 1 = just PaySucceeded
payOfOrd 2 = just PayFailed
payOfOrd _ = nothing

-- ExpSource
xsCodes : List String
xsCodes = "our" ∷ "cmp" ∷ "ind" ∷ []
xsCode : ExpSource → ℕ
xsCode ExpOurPromise   = 0
xsCode ExpCompetitor   = 1
xsCode ExpIndustryNorm = 2
xsOfOrd : ℕ → Maybe ExpSource
xsOfOrd 0 = just ExpOurPromise
xsOfOrd 1 = just ExpCompetitor
xsOfOrd 2 = just ExpIndustryNorm
xsOfOrd _ = nothing

-- ExpStatus
xstCodes : List String
xstCodes = "met" ∷ "unm" ∷ "unk" ∷ []
xstCode : ExpStatus → ℕ
xstCode ExpMet     = 0
xstCode ExpUnmet   = 1
xstCode ExpUnknown = 2
xstOfOrd : ℕ → Maybe ExpStatus
xstOfOrd 0 = just ExpMet
xstOfOrd 1 = just ExpUnmet
xstOfOrd 2 = just ExpUnknown
xstOfOrd _ = nothing

-- PromStatus
promCodes : List String
promCodes = "P" ∷ "F" ∷ "B" ∷ []
promCode : PromStatus → ℕ
promCode PromPending   = 0
promCode PromFulfilled = 1
promCode PromBroken    = 2
promOfOrd : ℕ → Maybe PromStatus
promOfOrd 0 = just PromPending
promOfOrd 1 = just PromFulfilled
promOfOrd 2 = just PromBroken
promOfOrd _ = nothing

pdCodes : List String
pdCodes = "our" ∷ "thr" ∷ []
pdCode : PromDirection → ℕ
pdCode Ours   = 0
pdCode Theirs = 1
pdOfOrd : ℕ → Maybe PromDirection
pdOfOrd 0 = just Ours
pdOfOrd 1 = just Theirs
pdOfOrd _ = nothing

------------------------------------------------------------------------
-- Offering — index 0: byTenant
------------------------------------------------------------------------

offeringSchema : Schema
offeringSchema = mkCol "id" CNat ∷ idxCol "tenant" (CFK "tenant") ∷ mkCol "kind" CNat
               ∷ mkCol "price" CNat ∷ mkCol "currency" CStr ∷ mkCol "metadata" CStr
               ∷ mkCol "created_at" CNat ∷ mkCol "deleted_at" (CMaybe CNat) ∷ []

offeringToRow : Offering → Row offeringSchema
offeringToRow o = oId o , oTenant o , oKind o , oPrice o , oCurrency o , oMetadata o
                , oCreatedAt o , oDeletedAt o , tt

offeringFromRow : Row offeringSchema → Offering
offeringFromRow (i , ten , k , pr , cur , md , ca , dd , tt) = mkOffering i ten k pr cur md ca dd

encOffering : Offering → String
encOffering o = encodeRow offeringSchema (offeringToRow o)
decOffering : String → Maybe Offering
decOffering s = mapMaybe offeringFromRow (decodeRow offeringSchema s)

------------------------------------------------------------------------
-- Resource — index 0: byParent (tree; parent stored as 0-sentinel optional-FK)
------------------------------------------------------------------------

resourceSchema : Schema
resourceSchema = mkCol "id" CNat ∷ mkCol "tenant" (CFK "tenant") ∷ idxCol "parent" (CFK "resource")
               ∷ mkCol "kind" CNat ∷ mkCol "ord" CNat ∷ mkCol "visibility" (CMaybe CStr)
               ∷ mkCol "payload" CStr ∷ mkCol "created_at" CNat ∷ mkCol "deleted_at" (CMaybe CNat)
               ∷ mkCol "author" (CMaybe CNat) ∷ mkCol "listing" (CMaybe CStr)
               ∷ mkCol "anchor_kind" (CMaybe CStr) ∷ mkCol "anchor_id" (CMaybe CNat)
               ∷ mkCol "stream_root" (CMaybe CNat)
               ∷ mkCol "updated_at" (CMaybe CNat) ∷ []

resourceToRow : Resource → Row resourceSchema
resourceToRow r = rId r , rTenant r , fkOrZero (rParent r) , rKind r , rOrder r , rVisibility r
                , rPayload r , rCreatedAt r , rDeletedAt r , rAuthor r , rListing r
                , rAnchorKind r , rAnchorId r , rStreamRoot r , rUpdatedAt r , tt

resourceFromRow : Row resourceSchema → Resource
resourceFromRow (i , ten , par , k , ord , vis , pl , ca , dd , au , li , ak , ai , sr , ua , tt) =
  mkResource i ten (zeroToNothing par) k ord vis pl ca dd au li (joinConv ak ai sr) ua
  where joinConv : Maybe String → Maybe ℕ → Maybe ℕ → Maybe ConvCtx
        joinConv (just k′) (just a′) (just s′) = just (mkConvCtx k′ a′ s′)
        joinConv _ _ _ = nothing

encResource : Resource → String
encResource r = encodeRow resourceSchema (resourceToRow r)
decResource : String → Maybe Resource
decResource s = mapMaybe resourceFromRow (decodeRowTolerant resourceSchema s)

------------------------------------------------------------------------
-- Entitlement — index 0: bySubject
------------------------------------------------------------------------

entitlementSchema : Schema
entitlementSchema = mkCol "id" CNat ∷ idxCol "subject" (CFK "subject") ∷ mkCol "tenant" (CFK "tenant")
                  ∷ mkCol "target_kind" (CEnumS entCodes) ∷ mkCol "target" CNat
                  ∷ mkCol "valid_from" CNat ∷ mkCol "valid_to" (CMaybe CNat)
                  ∷ mkCol "source" (CEnumS ensCodes) ∷ mkCol "created_at" CNat ∷ []

entitlementToRow : Entitlement → Row entitlementSchema
entitlementToRow e = enId e , enSubject e , enTenant e , entCode (enTargetKind e) , enTarget e
                   , enValidFrom e , enValidTo e , ensCode (enSource e) , enCreatedAt e , tt

entitlementFromRow : Row entitlementSchema → Maybe Entitlement
entitlementFromRow (i , subj , ten , tk , tgt , vf , vt , src , ca , tt) =
  entOfOrd tk >>=ᵐ λ kk → ensOfOrd src >>=ᵐ λ ss →
  just (mkEntitlement i subj ten kk tgt vf vt ss ca)

encEntitlement : Entitlement → String
encEntitlement e = encodeRow entitlementSchema (entitlementToRow e)
decEntitlement : String → Maybe Entitlement
decEntitlement s = decodeRow entitlementSchema s >>=ᵐ entitlementFromRow

------------------------------------------------------------------------
-- Account
------------------------------------------------------------------------

accountSchema : Schema
accountSchema = mkCol "id" CNat ∷ mkCol "tenant" (CFK "tenant") ∷ mkCol "balance" CNat
              ∷ mkCol "created_at" CNat ∷ []

accountToRow : Account → Row accountSchema
accountToRow a = acId a , acTenant a , acBalance a , acCreatedAt a , tt

accountFromRow : Row accountSchema → Account
accountFromRow (i , ten , bal , ca , tt) = mkAccount i ten bal ca

encAccount : Account → String
encAccount a = encodeRow accountSchema (accountToRow a)
decAccount : String → Maybe Account
decAccount s = mapMaybe accountFromRow (decodeRow accountSchema s)

------------------------------------------------------------------------
-- Payment — index 0: bySubject (lookup by ext_id is a scan, §8.7)
------------------------------------------------------------------------

paymentSchema : Schema
paymentSchema = mkCol "id" CNat ∷ mkCol "tenant" (CFK "tenant") ∷ mkCol "ext_id" CStr
              ∷ mkCol "offering" (CFK "offering") ∷ idxCol "subject" (CFK "subject")
              ∷ mkCol "name" CStr ∷ mkCol "email" CStr ∷ mkCol "amount" CNat
              ∷ mkCol "status" (CEnumS payCodes) ∷ mkCol "entitlement" CNat ∷ mkCol "created_at" CNat ∷ []

paymentToRow : Payment → Row paymentSchema
paymentToRow p = payId p , payTenant p , payExtId p , payOffering p , paySubject p , payName p
               , payEmail p , payAmount p , payCode (payStatus p) , payEntitlement p , payCreatedAt p , tt

paymentFromRow : Row paymentSchema → Maybe Payment
paymentFromRow (i , ten , ext , off , subj , nm , em , amt , st , ent , ca , tt) =
  payOfOrd st >>=ᵐ λ ss → just (mkPayment i ten ext off subj nm em amt ss ent ca)

encPayment : Payment → String
encPayment p = encodeRow paymentSchema (paymentToRow p)
decPayment : String → Maybe Payment
decPayment s = decodeRow paymentSchema s >>=ᵐ paymentFromRow

------------------------------------------------------------------------
-- Expectation — index 0: bySubject
------------------------------------------------------------------------

expectationSchema : Schema
expectationSchema = mkCol "id" CNat ∷ idxCol "subject" (CFK "subject") ∷ mkCol "tenant" (CFK "tenant")
                  ∷ mkCol "topic" CStr ∷ mkCol "source" (CEnumS xsCodes) ∷ mkCol "level" CNat
                  ∷ mkCol "status" (CEnumS xstCodes) ∷ mkCol "created_at" CNat ∷ []

expectationToRow : Expectation → Row expectationSchema
expectationToRow x = xpId x , xpSubject x , xpTenant x , xpTopic x , xsCode (xpSource x) , xpLevel x
                   , xstCode (xpStatus x) , xpCreatedAt x , tt

expectationFromRow : Row expectationSchema → Maybe Expectation
expectationFromRow (i , subj , ten , tp , src , lv , st , ca , tt) =
  xsOfOrd src >>=ᵐ λ ss → xstOfOrd st >>=ᵐ λ st′ →
  just (mkExpectation i subj ten tp ss lv st′ ca)

encExpectation : Expectation → String
encExpectation x = encodeRow expectationSchema (expectationToRow x)
decExpectation : String → Maybe Expectation
decExpectation s = decodeRow expectationSchema s >>=ᵐ expectationFromRow

------------------------------------------------------------------------
-- Promise — index 0: bySubject, 1: byStatus (for dueReminders)
------------------------------------------------------------------------

-- futures columns (upgrade-план A1) appended LAST; direction/transferable/collateral are
-- non-Maybe (no tolerant default) — acceptable pre-prod (решение 3в: old dev WALs reset).
promiseSchema : Schema
promiseSchema = mkCol "id" CNat ∷ idxCol "subject" (CFK "subject") ∷ mkCol "tenant" (CFK "tenant")
              ∷ mkCol "topic" CStr ∷ mkCol "deadline" CNat ∷ idxCol "status" (CEnumS promCodes)
              ∷ mkCol "reminded_at" (CMaybe CNat) ∷ mkCol "created_at" CNat
              ∷ mkCol "direction" (CEnumS pdCodes) ∷ mkCol "holder" (CMaybe CNat)
              ∷ mkCol "transferable" CBool ∷ mkCol "collateral" CNat
              ∷ mkCol "stake_account" (CMaybe CNat) ∷ mkCol "penalty_to" (CMaybe CNat)
              ∷ mkCol "referable" (CMaybe CBool) ∷ []

promiseToRow : Promise → Row promiseSchema
promiseToRow p = pmId p , pmSubject p , pmTenant p , pmTopic p , pmDeadline p , promCode (pmStatus p)
               , pmRemindedAt p , pmCreatedAt p , pdCode (pmDirection p) , pmHolder p
               , pmTransferable p , pmCollateral p , pmStakeAccount p , pmPenaltyTo p
               , just (pmReferable p) , tt

promiseFromRow : Row promiseSchema → Maybe Promise
promiseFromRow (i , subj , ten , tp , dl , st , rm , ca , dir , hold , tr , col , stk , pen , ref , tt) =
  promOfOrd st >>=ᵐ λ ss → pdOfOrd dir >>=ᵐ λ dd →
  just (mkPromise i subj ten tp dl ss rm ca dd hold tr col stk pen (orFalse ref))
  where orFalse : Maybe Bool → Bool
        orFalse (just b) = b
        orFalse nothing  = false

encPromise : Promise → String
encPromise p = encodeRow promiseSchema (promiseToRow p)
decPromise : String → Maybe Promise
decPromise s = decodeRowTolerant promiseSchema s >>=ᵐ promiseFromRow

------------------------------------------------------------------------
-- Protocol — index 0: byTenant
------------------------------------------------------------------------

protocolSchema : Schema
protocolSchema = mkCol "id" CNat ∷ idxCol "tenant" (CFK "tenant") ∷ mkCol "name" CStr
               ∷ mkCol "initial_state" CNat ∷ mkCol "created_at" CNat ∷ []

protocolToRow : Protocol → Row protocolSchema
protocolToRow p = prId p , prTenant p , prName p , prInitialState p , prCreatedAt p , tt

protocolFromRow : Row protocolSchema → Protocol
protocolFromRow (i , ten , nm , ini , ca , tt) = mkProtocol i ten nm ini ca

encProtocol : Protocol → String
encProtocol p = encodeRow protocolSchema (protocolToRow p)
decProtocol : String → Maybe Protocol
decProtocol s = mapMaybe protocolFromRow (decodeRow protocolSchema s)

------------------------------------------------------------------------
-- Episode — index 0: bySubject, 1: byProtocol
------------------------------------------------------------------------

episodeSchema : Schema
episodeSchema = mkCol "id" CNat ∷ idxCol "subject" (CFK "subject") ∷ idxCol "protocol" (CFK "protocol")
              ∷ mkCol "tenant" (CFK "tenant") ∷ mkCol "current_state" CNat ∷ mkCol "jtbd" CStr
              ∷ mkCol "peak" (CMaybe CNat) ∷ mkCol "end_ev" (CMaybe CNat) ∷ mkCol "created_at" CNat
              ∷ mkCol "deleted_at" (CMaybe CNat) ∷ []

episodeToRow : Episode → Row episodeSchema
episodeToRow e = epId e , epSubject e , epProtocol e , epTenant e , epCurrentState e , epJtbd e
               , epPeak e , epEnd e , epCreatedAt e , epDeletedAt e , tt

episodeFromRow : Row episodeSchema → Episode
episodeFromRow (i , subj , proto , ten , cs , jt , pk , en , ca , dd , tt) =
  mkEpisode i subj proto ten cs jt pk en ca dd

encEpisode : Episode → String
encEpisode e = encodeRow episodeSchema (episodeToRow e)
decEpisode : String → Maybe Episode
decEpisode s = mapMaybe episodeFromRow (decodeRow episodeSchema s)

------------------------------------------------------------------------
-- User (lookup by login is a scan, §8.7)
------------------------------------------------------------------------

userSchema : Schema
userSchema = mkCol "id" CNat ∷ mkCol "tenant" (CFK "tenant") ∷ mkCol "login" CStr
           ∷ mkCol "pass_hash" CStr ∷ mkCol "created_at" CNat ∷ []

userToRow : User → Row userSchema
userToRow u = uId u , uTenant u , uLogin u , uPassHash u , uCreatedAt u , tt

userFromRow : Row userSchema → User
userFromRow (i , ten , lo , ph , ca , tt) = mkUser i ten lo ph ca

encUser : User → String
encUser u = encodeRow userSchema (userToRow u)
decUser : String → Maybe User
decUser s = mapMaybe userFromRow (decodeRow userSchema s)

------------------------------------------------------------------------
-- IntegrationToken row (lookup by token value is a scan; revoked_at as 0-sentinel Maybe ℕ)
------------------------------------------------------------------------

intTokenSchema : Schema
intTokenSchema = mkCol "id" CNat ∷ mkCol "tenant" (CFK "tenant") ∷ mkCol "token" CStr
               ∷ mkCol "scope" CStr ∷ mkCol "origin" CStr ∷ mkCol "created_at" CNat
               ∷ mkCol "revoked_at" CNat ∷ []

intTokenToRow : IntTokenRow → Row intTokenSchema
intTokenToRow r = itkId r , itkTenant r , itkToken r , itkScope r , itkOrigin r
                , itkCreatedAt r , fkOrZero (itkRevokedAt r) , tt

intTokenFromRow : Row intTokenSchema → IntTokenRow
intTokenFromRow (i , ten , tok , sc , org , ca , rv , _) =
  mkIntTokenRow i ten tok sc org ca (zeroToNothing rv)

encIntToken : IntTokenRow → String
encIntToken r = encodeRow intTokenSchema (intTokenToRow r)
decIntToken : String → Maybe IntTokenRow
decIntToken s = mapMaybe intTokenFromRow (decodeRow intTokenSchema s)

------------------------------------------------------------------------
-- RoleAssignment (lookup by subject is a scan)
------------------------------------------------------------------------

assignmentSchema : Schema
assignmentSchema = mkCol "id" CNat ∷ mkCol "tenant" (CFK "tenant") ∷ mkCol "subject" CStr
                 ∷ mkCol "role_id" CStr ∷ mkCol "scope" CStr ∷ mkCol "created_at" CNat ∷ []

assignmentToRow : RoleAssignment → Row assignmentSchema
assignmentToRow a = raId a , raTenant a , raSubject a , raRoleId a , raScope a , raCreatedAt a , tt

assignmentFromRow : Row assignmentSchema → RoleAssignment
assignmentFromRow (i , ten , su , ro , sc , ca , tt) = mkAssignment i ten su ro sc ca

encAssignment : RoleAssignment → String
encAssignment a = encodeRow assignmentSchema (assignmentToRow a)
decAssignment : String → Maybe RoleAssignment
decAssignment s = mapMaybe assignmentFromRow (decodeRow assignmentSchema s)

------------------------------------------------------------------------
-- Appointment — index 0: bySubject, 1: byResource (busy-slot conflict), 2: byEpisode (credits)
------------------------------------------------------------------------

apCodes : List String
apCodes = "sch" ∷ "cmp" ∷ "cnc" ∷ "nsh" ∷ []
apCode : ApptStatus → ℕ
apCode ApScheduled = 0
apCode ApCompleted = 1
apCode ApCanceled  = 2
apCode ApNoShow    = 3
apOfOrd : ℕ → Maybe ApptStatus
apOfOrd 0 = just ApScheduled
apOfOrd 1 = just ApCompleted
apOfOrd 2 = just ApCanceled
apOfOrd 3 = just ApNoShow
apOfOrd _ = nothing

-- `promise` appended LAST as CMaybe (Tier-1 auto-defaultable; upgrade-план A5)
appointmentSchema : Schema
appointmentSchema = mkCol "id" CNat ∷ idxCol "subject" (CFK "subject") ∷ idxCol "resource" (CFK "resource")
                  ∷ idxCol "episode" (CFK "episode") ∷ mkCol "entitlement" (CMaybe CNat)
                  ∷ mkCol "starts_at" CNat ∷ mkCol "duration" CNat ∷ mkCol "status" (CEnumS apCodes)
                  ∷ mkCol "reminded_at" (CMaybe CNat) ∷ mkCol "tenant" (CFK "tenant") ∷ mkCol "created_at" CNat
                  ∷ mkCol "promise" (CMaybe CNat) ∷ []

appointmentToRow : Appointment → Row appointmentSchema
appointmentToRow a = apId a , apSubject a , apResource a , fkOrZero (apEpisode a) , apEntitlement a
                   , apStartsAt a , apDurationMin a , apCode (apStatus a) , apRemindedAt a , apTenant a
                   , apCreatedAt a , apPromise a , tt

appointmentFromRow : Row appointmentSchema → Maybe Appointment
appointmentFromRow (i , subj , res , ep , ent , st , dur , stat , rm , ten , ca , pr , tt) =
  apOfOrd stat >>=ᵐ λ ss → just (mkAppointment i subj res (zeroToNothing ep) ent st dur ss rm ten ca pr)

encAppointment : Appointment → String
encAppointment a = encodeRow appointmentSchema (appointmentToRow a)
decAppointment : String → Maybe Appointment
decAppointment s = decodeRowTolerant appointmentSchema s >>=ᵐ appointmentFromRow

------------------------------------------------------------------------
-- ResourceLink (curation graph; §8 cxm-social-plan) — index 0: byFrom (showcase reads)
------------------------------------------------------------------------

resourceLinkSchema : Schema
resourceLinkSchema = mkCol "id" CNat ∷ mkCol "tenant" (CFK "tenant") ∷ idxCol "from_res" (CFK "resource")
                   ∷ mkCol "to_res" (CFK "resource") ∷ mkCol "kind" CStr ∷ mkCol "rank" CNat
                   ∷ mkCol "valid_from" CNat ∷ mkCol "valid_to" (CMaybe CNat) ∷ mkCol "created_at" CNat ∷ []

resourceLinkToRow : ResourceLink → Row resourceLinkSchema
resourceLinkToRow l = rlId l , rlTenant l , rlFrom l , rlTo l , rlKind l , rlRank l
                    , rlValidFrom l , rlValidTo l , rlCreatedAt l , tt

resourceLinkFromRow : Row resourceLinkSchema → ResourceLink
resourceLinkFromRow (i , ten , fr , to , k , rk , vf , vt , ca , tt) =
  mkResourceLink i ten fr to k rk vf vt ca

encResourceLink : ResourceLink → String
encResourceLink l = encodeRow resourceLinkSchema (resourceLinkToRow l)
decResourceLink : String → Maybe ResourceLink
decResourceLink s = mapMaybe resourceLinkFromRow (decodeRowTolerant resourceLinkSchema s)

------------------------------------------------------------------------
-- Mention (§10 F3) — index 0: byResource, 1: bySubject (inbox!)
------------------------------------------------------------------------

mentionSchema : Schema
mentionSchema = mkCol "id" CNat ∷ idxCol "resource" (CFK "resource") ∷ idxCol "subject" (CFK "subject")
              ∷ mkCol "ord" CNat ∷ mkCol "tenant" (CFK "tenant") ∷ []

mentionToRow : Mention → Row mentionSchema
mentionToRow m = mId m , mResource m , mSubject m , mOrd m , mTenant m , tt

mentionFromRow : Row mentionSchema → Mention
mentionFromRow (i , r , s , o , ten , tt) = mkMention i r s o ten

encMention : Mention → String
encMention m = encodeRow mentionSchema (mentionToRow m)
decMention : String → Maybe Mention
decMention s = mapMaybe mentionFromRow (decodeRow mentionSchema s)
