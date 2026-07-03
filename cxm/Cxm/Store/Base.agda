{-# OPTIONS --without-K #-}

-- CXM store assembly (cxm-plan.md Phase 5, §8.1, §9.5). Base = one self-indexing
-- `IndexedMap` per entity (incl. the Phase-4 collection child tables) + `nextId`; a typed
-- `CxmOp` (per-entity Set/Del, §9.5, grouped by module); a pure `apply` that maintains the
-- indexes via IndexedMap and advances `nextId`; `Err`; and `emptyBase` seeded from each
-- entity's schema (`imIndexes schema toRow`) so index maintenance is DERIVED, never
-- hand-written (§8.1). No separate Indexes record — indexes live inside each IndexedMap.
--
-- INVARIANT (audit #2): `nextId` starts at 1. Id 0 is reserved as the "none" sentinel for
-- optional FKs (Wire.fkOrZero: episode / canonical), so no live entity may have id 0.
--
-- `CxmOp` is an INTERNAL detail of the WAL backend (§9.5): domain commands write through
-- the repository seam (Cxm.Store.Interface, principle 11), not by constructing ops here.
-- Base GROWS in Phase 6 as the domain-truth entities (Offering/Resource/… ) land.
module Cxm.Store.Base where

open import Data.Nat using (ℕ; suc; _⊔_)
open import Data.String using (String)

open import Agdelte.Storage.IndexedMap as IM using (IndexedMap)
open import Agdelte.Storage.Schema using (imIndexes)

open import Cxm.Tenant using (Tenant; tId)
open import Cxm.Subject using (Subject; sId)
open import Cxm.Edge using (SubjectEdge; seId)
open import Cxm.Identity using (Identity; iId)
open import Cxm.Event using (ExperienceEvent; eeId)
open import Cxm.Bus using (Event; evId; OutboxEntry; obId)
open import Cxm.Knowledge using (Knowledge; kId)
open import Cxm.Collections using
  ( Evidence; evdId; Transition; trId; Deviation; dvId
  ; ProtocolState; psId; ProtocolTransition; ptId )
open import Cxm.Offering using (Offering; oId)
open import Cxm.Resource using (Resource; rId)
open import Cxm.Entitlement using (Entitlement; enId)
open import Cxm.Account using (Account; acId)
open import Cxm.Payment using (Payment; payId)
open import Cxm.Expectation using (Expectation; xpId; Promise; pmId)
open import Cxm.Protocol using (Protocol; prId)
open import Cxm.Episode using (Episode; epId)
open import Cxm.Users using (User; uId; RoleAssignment; raId)
open import Cxm.Appointment using (Appointment; apId)
open import Cxm.Site using (IntTokenRow; itkId)
open import Cxm.Resource using (ResourceLink; rlId; Mention; mId)
open import Cxm.Wire using
  ( tenantSchema; tenantToRow; subjectSchema; subjectToRow; edgeSchema; edgeToRow
  ; identitySchema; identityToRow; experienceEventSchema; eeToRow; busEventSchema; evToRow
  ; outboxSchema; obToRow; knowledgeSchema; knowledgeToRow; evidenceSchema; evidenceToRow
  ; transitionSchema; transitionToRow; deviationSchema; deviationToRow
  ; protocolStateSchema; protocolStateToRow; protocolTransitionSchema; protocolTransitionToRow
  ; offeringSchema; offeringToRow; resourceSchema; resourceToRow; entitlementSchema; entitlementToRow
  ; accountSchema; accountToRow; paymentSchema; paymentToRow; expectationSchema; expectationToRow
  ; promiseSchema; promiseToRow; protocolSchema; protocolToRow; episodeSchema; episodeToRow
  ; userSchema; userToRow; assignmentSchema; assignmentToRow
  ; appointmentSchema; appointmentToRow ; intTokenSchema; intTokenToRow
  ; resourceLinkSchema; resourceLinkToRow; mentionSchema; mentionToRow )

------------------------------------------------------------------------
-- Secondary-index positions (typed-name layer over IndexedMap's ℕ positions). These MUST
-- match the order of idxCol columns in each Wire schema (see the per-record notes there).
------------------------------------------------------------------------

subjByTenant    : ℕ
subjByTenant    = 0
subjByCanonical : ℕ
subjByCanonical = 1
edgeByFrom      : ℕ
edgeByFrom      = 0
edgeByTo        : ℕ
edgeByTo        = 1
edgeByKind      : ℕ
edgeByKind      = 2
identBySubject  : ℕ
identBySubject  = 0
eventBySubject  : ℕ
eventBySubject  = 0
eventByEpisode  : ℕ
eventByEpisode  = 1
busByProcessed  : ℕ
busByProcessed  = 0
outByStatus     : ℕ
outByStatus     = 0
knowBySubject   : ℕ
knowBySubject   = 0
evdByKnowledge  : ℕ
evdByKnowledge  = 0
evdByEvent      : ℕ
evdByEvent      = 1
trByEpisode     : ℕ
trByEpisode     = 0
dvByEpisode     : ℕ
dvByEpisode     = 0
psByProtocol    : ℕ
psByProtocol    = 0
ptByProtocol    : ℕ
ptByProtocol    = 0
offeringByTenant : ℕ
offeringByTenant = 0
resByParent     : ℕ
resByParent     = 0
entBySubject    : ℕ
entBySubject    = 0
paymentBySubject : ℕ
paymentBySubject = 0
expBySubject    : ℕ
expBySubject    = 0
promBySubject   : ℕ
promBySubject   = 0
promByStatus    : ℕ
promByStatus    = 1
protoByTenant   : ℕ
protoByTenant   = 0
epBySubject     : ℕ
epBySubject     = 0
epByProtocol    : ℕ
epByProtocol    = 1
apptBySubject   : ℕ
apptBySubject   = 0
apptByResource  : ℕ
apptByResource  = 1
apptByEpisode   : ℕ
apptByEpisode   = 2
rlByFrom        : ℕ
rlByFrom        = 0
mByResource     : ℕ
mByResource     = 0
mBySubject      : ℕ
mBySubject      = 1

------------------------------------------------------------------------
-- Base
------------------------------------------------------------------------

record Base : Set where
  constructor mkBase
  field
    tenants             : IndexedMap Tenant
    subjects            : IndexedMap Subject              -- 0: byTenant, 1: byCanonical
    edges               : IndexedMap SubjectEdge          -- 0: byFrom, 1: byTo, 2: byKind
    identities          : IndexedMap Identity             -- 0: bySubject
    events              : IndexedMap ExperienceEvent      -- [СОБ] 0: bySubject, 1: byEpisode
    busEvents           : IndexedMap Event                -- 0: byProcessed
    outbox              : IndexedMap OutboxEntry           -- 0: byStatus
    knowledge           : IndexedMap Knowledge             -- 0: bySubject
    evidence            : IndexedMap Evidence              -- 0: byKnowledge, 1: byEvent
    transitions         : IndexedMap Transition            -- 0: byEpisode
    deviations          : IndexedMap Deviation             -- 0: byEpisode
    protocolStates      : IndexedMap ProtocolState         -- 0: byProtocol
    protocolTransitions : IndexedMap ProtocolTransition    -- 0: byProtocol
    -- Phase 6 domain-truth entities
    offerings           : IndexedMap Offering              -- 0: byTenant
    resources           : IndexedMap Resource              -- 0: byParent
    entitlements        : IndexedMap Entitlement           -- 0: bySubject
    accounts            : IndexedMap Account               -- (lookup by id)
    payments            : IndexedMap Payment               -- 0: bySubject (byExtId: scan)
    expectations        : IndexedMap Expectation           -- 0: bySubject
    promises            : IndexedMap Promise                -- 0: bySubject, 1: byStatus
    protocols           : IndexedMap Protocol               -- 0: byTenant
    episodes            : IndexedMap Episode                -- 0: bySubject, 1: byProtocol
    users               : IndexedMap User                   -- (lookup by login: scan)
    assignments         : IndexedMap RoleAssignment         -- (lookup by subject: scan)
    appointments        : IndexedMap Appointment            -- 0: bySubject, 1: byResource, 2: byEpisode
    integrationTokens   : IndexedMap IntTokenRow            -- (lookup by token value: scan)
    resourceLinks       : IndexedMap ResourceLink           -- 0: byFrom (showcase reads)
    mentions            : IndexedMap Mention                -- 0: byResource, 1: bySubject
    nextId              : ℕ
open Base public

emptyBase : Base
emptyBase = mkBase
  (IM.empty (imIndexes tenantSchema             tenantToRow))
  (IM.empty (imIndexes subjectSchema            subjectToRow))              -- byTenant, byCanonical
  (IM.empty (imIndexes edgeSchema               edgeToRow))                 -- byFrom, byTo, byKind
  (IM.empty (imIndexes identitySchema           identityToRow))             -- bySubject
  (IM.empty (imIndexes experienceEventSchema    eeToRow))                   -- bySubject, byEpisode
  (IM.empty (imIndexes busEventSchema           evToRow))                   -- byProcessed
  (IM.empty (imIndexes outboxSchema             obToRow))                   -- byStatus
  (IM.empty (imIndexes knowledgeSchema          knowledgeToRow))            -- bySubject
  (IM.empty (imIndexes evidenceSchema           evidenceToRow))             -- byKnowledge, byEvent
  (IM.empty (imIndexes transitionSchema         transitionToRow))           -- byEpisode
  (IM.empty (imIndexes deviationSchema          deviationToRow))            -- byEpisode
  (IM.empty (imIndexes protocolStateSchema      protocolStateToRow))        -- byProtocol
  (IM.empty (imIndexes protocolTransitionSchema protocolTransitionToRow))   -- byProtocol
  (IM.empty (imIndexes offeringSchema           offeringToRow))             -- byTenant
  (IM.empty (imIndexes resourceSchema           resourceToRow))             -- byParent
  (IM.empty (imIndexes entitlementSchema        entitlementToRow))          -- bySubject
  (IM.empty (imIndexes accountSchema            accountToRow))
  (IM.empty (imIndexes paymentSchema            paymentToRow))              -- bySubject
  (IM.empty (imIndexes expectationSchema        expectationToRow))          -- bySubject
  (IM.empty (imIndexes promiseSchema            promiseToRow))              -- bySubject, byStatus
  (IM.empty (imIndexes protocolSchema           protocolToRow))             -- byTenant
  (IM.empty (imIndexes episodeSchema            episodeToRow))              -- bySubject, byProtocol
  (IM.empty (imIndexes userSchema               userToRow))
  (IM.empty (imIndexes assignmentSchema         assignmentToRow))
  (IM.empty (imIndexes appointmentSchema        appointmentToRow))          -- bySubject, byResource, byEpisode
  (IM.empty (imIndexes intTokenSchema           intTokenToRow))
  (IM.empty (imIndexes resourceLinkSchema       resourceLinkToRow))         -- byFrom
  (IM.empty (imIndexes mentionSchema            mentionToRow))              -- byResource, bySubject
  1

------------------------------------------------------------------------
-- Operations (typed per entity, §9.5) + errors
------------------------------------------------------------------------

data CxmOp : Set where
  -- Phase 1–3 truth entities
  SetTenant     : Tenant             → CxmOp
  SetSubject    : Subject            → CxmOp
  SetEdge       : SubjectEdge        → CxmOp
  SetIdentity   : Identity           → CxmOp
  SetEvent      : ExperienceEvent    → CxmOp    -- [СОБ] append-only: there is deliberately NO
                                                --   DelEvent (§9.2 truth log; §7.5 erasure =
                                                --   crypto-shred, not a log delete)
  SetBusEvent   : Event              → CxmOp
  SetOutbox     : OutboxEntry        → CxmOp
  SetKnowledge  : Knowledge          → CxmOp
  -- Phase 4 collection child tables
  SetEvidence   : Evidence           → CxmOp
  SetTransition : Transition         → CxmOp
  SetDeviation  : Deviation          → CxmOp
  SetProtState  : ProtocolState      → CxmOp
  SetProtTrans  : ProtocolTransition → CxmOp
  -- Phase 6 domain-truth entities
  SetOffering    : Offering       → CxmOp
  SetResource    : Resource       → CxmOp
  SetEntitlement : Entitlement    → CxmOp
  SetAccount     : Account        → CxmOp
  SetPayment     : Payment        → CxmOp
  SetExpectation : Expectation    → CxmOp
  SetPromise     : Promise        → CxmOp
  SetProtocol    : Protocol       → CxmOp
  SetEpisode     : Episode        → CxmOp
  SetUser        : User           → CxmOp
  SetAssignment  : RoleAssignment → CxmOp
  SetAppointment : Appointment    → CxmOp
  SetIntToken    : IntTokenRow    → CxmOp
  SetResourceLink : ResourceLink  → CxmOp
  SetMention      : Mention       → CxmOp
  DelTenant     : ℕ → CxmOp
  DelSubject    : ℕ → CxmOp
  DelEdge       : ℕ → CxmOp
  DelIdentity   : ℕ → CxmOp
  -- (no DelEvent: ExperienceEvent is append-only, §9.2/§7.5)
  DelBusEvent   : ℕ → CxmOp
  DelOutbox     : ℕ → CxmOp
  DelKnowledge  : ℕ → CxmOp
  DelEvidence   : ℕ → CxmOp
  DelTransition : ℕ → CxmOp
  DelDeviation  : ℕ → CxmOp
  DelProtState  : ℕ → CxmOp
  DelProtTrans  : ℕ → CxmOp
  DelOffering    : ℕ → CxmOp
  DelResource    : ℕ → CxmOp
  DelEntitlement : ℕ → CxmOp
  DelAccount     : ℕ → CxmOp
  DelPayment     : ℕ → CxmOp
  DelExpectation : ℕ → CxmOp
  DelPromise     : ℕ → CxmOp
  DelProtocol    : ℕ → CxmOp
  DelEpisode     : ℕ → CxmOp
  DelUser        : ℕ → CxmOp
  DelAssignment  : ℕ → CxmOp
  DelAppointment : ℕ → CxmOp
  DelIntToken    : ℕ → CxmOp
  DelResourceLink : ℕ → CxmOp
  DelMention      : ℕ → CxmOp

data Err : Set where
  NotFound          : Err
  Conflict          : Err
  Insufficient      : Err
  InvalidTransition : Err
  Forbidden         : Err
  Invariant         : String → Err

------------------------------------------------------------------------
-- Apply (pure; maintains indexes via IndexedMap, advances nextId)
------------------------------------------------------------------------

private
  bump : ℕ → ℕ → ℕ
  bump id n = suc id ⊔ n           -- nextId := max(nextId, id+1)

apply : CxmOp → Base → Base
apply (SetTenant t) b =
  record b { tenants = IM.insert (tId t) t (tenants b) ; nextId = bump (tId t) (nextId b) }
apply (SetSubject s) b =
  record b { subjects = IM.insert (sId s) s (subjects b) ; nextId = bump (sId s) (nextId b) }
apply (SetEdge e) b =
  record b { edges = IM.insert (seId e) e (edges b) ; nextId = bump (seId e) (nextId b) }
apply (SetIdentity x) b =
  record b { identities = IM.insert (iId x) x (identities b) ; nextId = bump (iId x) (nextId b) }
apply (SetEvent e) b =
  record b { events = IM.insert (eeId e) e (events b) ; nextId = bump (eeId e) (nextId b) }
apply (SetBusEvent e) b =
  record b { busEvents = IM.insert (evId e) e (busEvents b) ; nextId = bump (evId e) (nextId b) }
apply (SetOutbox o) b =
  record b { outbox = IM.insert (obId o) o (outbox b) ; nextId = bump (obId o) (nextId b) }
apply (SetKnowledge k) b =
  record b { knowledge = IM.insert (kId k) k (knowledge b) ; nextId = bump (kId k) (nextId b) }
apply (SetEvidence e) b =
  record b { evidence = IM.insert (evdId e) e (evidence b) ; nextId = bump (evdId e) (nextId b) }
apply (SetTransition t) b =
  record b { transitions = IM.insert (trId t) t (transitions b) ; nextId = bump (trId t) (nextId b) }
apply (SetDeviation d) b =
  record b { deviations = IM.insert (dvId d) d (deviations b) ; nextId = bump (dvId d) (nextId b) }
apply (SetProtState p) b =
  record b { protocolStates = IM.insert (psId p) p (protocolStates b) ; nextId = bump (psId p) (nextId b) }
apply (SetProtTrans p) b =
  record b { protocolTransitions = IM.insert (ptId p) p (protocolTransitions b) ; nextId = bump (ptId p) (nextId b) }
apply (SetOffering o) b =
  record b { offerings = IM.insert (oId o) o (offerings b) ; nextId = bump (oId o) (nextId b) }
apply (SetResource r) b =
  record b { resources = IM.insert (rId r) r (resources b) ; nextId = bump (rId r) (nextId b) }
apply (SetEntitlement e) b =
  record b { entitlements = IM.insert (enId e) e (entitlements b) ; nextId = bump (enId e) (nextId b) }
apply (SetAccount a) b =
  record b { accounts = IM.insert (acId a) a (accounts b) ; nextId = bump (acId a) (nextId b) }
apply (SetPayment p) b =
  record b { payments = IM.insert (payId p) p (payments b) ; nextId = bump (payId p) (nextId b) }
apply (SetExpectation x) b =
  record b { expectations = IM.insert (xpId x) x (expectations b) ; nextId = bump (xpId x) (nextId b) }
apply (SetPromise p) b =
  record b { promises = IM.insert (pmId p) p (promises b) ; nextId = bump (pmId p) (nextId b) }
apply (SetProtocol p) b =
  record b { protocols = IM.insert (prId p) p (protocols b) ; nextId = bump (prId p) (nextId b) }
apply (SetEpisode e) b =
  record b { episodes = IM.insert (epId e) e (episodes b) ; nextId = bump (epId e) (nextId b) }
apply (SetUser u) b =
  record b { users = IM.insert (uId u) u (users b) ; nextId = bump (uId u) (nextId b) }
apply (SetAssignment a) b =
  record b { assignments = IM.insert (raId a) a (assignments b) ; nextId = bump (raId a) (nextId b) }
apply (SetAppointment a) b =
  record b { appointments = IM.insert (apId a) a (appointments b) ; nextId = bump (apId a) (nextId b) }
apply (SetIntToken r) b =
  record b { integrationTokens = IM.insert (itkId r) r (integrationTokens b) ; nextId = bump (itkId r) (nextId b) }
apply (DelTenant id) b     = record b { tenants             = IM.delete id (tenants b) }
apply (DelSubject id) b    = record b { subjects            = IM.delete id (subjects b) }
apply (DelEdge id) b       = record b { edges               = IM.delete id (edges b) }
apply (DelIdentity id) b   = record b { identities          = IM.delete id (identities b) }
apply (DelBusEvent id) b   = record b { busEvents           = IM.delete id (busEvents b) }
apply (DelOutbox id) b     = record b { outbox              = IM.delete id (outbox b) }
apply (DelKnowledge id) b  = record b { knowledge           = IM.delete id (knowledge b) }
apply (DelEvidence id) b   = record b { evidence            = IM.delete id (evidence b) }
apply (DelTransition id) b = record b { transitions         = IM.delete id (transitions b) }
apply (DelDeviation id) b  = record b { deviations          = IM.delete id (deviations b) }
apply (DelProtState id) b  = record b { protocolStates      = IM.delete id (protocolStates b) }
apply (DelProtTrans id) b  = record b { protocolTransitions = IM.delete id (protocolTransitions b) }
apply (DelOffering id) b    = record b { offerings    = IM.delete id (offerings b) }
apply (DelResource id) b    = record b { resources    = IM.delete id (resources b) }
apply (DelEntitlement id) b = record b { entitlements = IM.delete id (entitlements b) }
apply (DelAccount id) b     = record b { accounts     = IM.delete id (accounts b) }
apply (DelPayment id) b     = record b { payments     = IM.delete id (payments b) }
apply (DelExpectation id) b = record b { expectations = IM.delete id (expectations b) }
apply (DelPromise id) b     = record b { promises     = IM.delete id (promises b) }
apply (DelProtocol id) b    = record b { protocols    = IM.delete id (protocols b) }
apply (DelEpisode id) b     = record b { episodes     = IM.delete id (episodes b) }
apply (DelUser id) b        = record b { users        = IM.delete id (users b) }
apply (DelAssignment id) b  = record b { assignments  = IM.delete id (assignments b) }
apply (DelIntToken id) b    = record b { integrationTokens = IM.delete id (integrationTokens b) }
apply (SetResourceLink l) b =
  record b { resourceLinks = IM.insert (rlId l) l (resourceLinks b) ; nextId = bump (rlId l) (nextId b) }
apply (DelResourceLink id) b = record b { resourceLinks = IM.delete id (resourceLinks b) }
apply (SetMention m) b =
  record b { mentions = IM.insert (mId m) m (mentions b) ; nextId = bump (mId m) (nextId b) }
apply (DelMention id) b = record b { mentions = IM.delete id (mentions b) }
apply (DelAppointment id) b = record b { appointments = IM.delete id (appointments b) }
