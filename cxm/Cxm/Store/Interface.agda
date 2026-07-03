{-# OPTIONS --without-K #-}

-- The repository seam (cxm-plan.md Phase 5, description §8.7, principle 11). Domain commands
-- and projections (Phases 6–8) address the store ONLY through this backend-agnostic
-- vocabulary — get / byIndex / scan / put / del — and NEVER reach into `IndexedMap` or a
-- concrete `Base` field. That is the "cheap now / expensive later" bet of §8.7: swapping the
-- WAL backend for Postgres becomes a SECOND implementation of this seam, not a rewrite of
-- every query site.
--
-- A `Table V` is the per-entity handle (the "parameterized module" the plan mentions): it
-- bundles the abstract reads/writes for one entity. Crucially its FIELD TYPES never mention
-- `IndexedMap`, so domain code sees only `Table`/`Txn`. The read helpers run in `Txn` over
-- the working `Base` (the WAL+in-memory backend, §9.3); a Postgres backend would re-implement
-- the same handles/helpers against its own state (reads lifted to IO). `commitTxn` — the IO
-- write path — lives in Cxm.Store.Wal, the concrete backend.
module Cxm.Store.Interface where

open import Data.Nat using (ℕ)
open import Data.String using (String)
open import Data.Maybe using (Maybe; just; nothing)
open import Data.List using (List)
open import Data.Product using (_×_)
open import Agda.Builtin.Unit using (⊤)

open import Agdelte.Storage.IndexedMap as IM using (IndexedMap)

open import Cxm.Tenant using (Tenant)
open import Cxm.Subject using (Subject)
open import Cxm.Edge using (SubjectEdge)
open import Cxm.Identity using (Identity)
open import Cxm.Event using (ExperienceEvent)
open import Cxm.Bus using (Event; OutboxEntry)
open import Cxm.Knowledge using (Knowledge)
open import Cxm.Collections using (Evidence; Transition; Deviation; ProtocolState; ProtocolTransition)
open import Cxm.Offering using (Offering)
open import Cxm.Resource using (Resource)
open import Cxm.Entitlement using (Entitlement)
open import Cxm.Account using (Account)
open import Cxm.Payment using (Payment)
open import Cxm.Expectation using (Expectation; Promise)
open import Cxm.Protocol using (Protocol)
open import Cxm.Episode using (Episode)
open import Cxm.Users using (User; RoleAssignment)
open import Cxm.Appointment using (Appointment)
open import Cxm.Site using (IntTokenRow)
open import Cxm.Resource using (ResourceLink; Mention)

open import Cxm.Store.Base
open import Cxm.Txn

------------------------------------------------------------------------
-- Table handle — the seam for one entity. No IndexedMap in the field TYPES.
------------------------------------------------------------------------

record Table (V : Set) : Set where
  constructor mkTable
  field
    tName    : String                     -- table name (DDL / diagnostics)
    tget     : ℕ → Base → Maybe V         -- read by primary id
    tbyIndex : ℕ → ℕ → Base → List ℕ      -- secondary lookup: index-position → key → ids
    tscan    : Base → List (ℕ × V)        -- full scan (id-ordered)
    tset     : V → CxmOp                  -- write op
    tdel     : Maybe (ℕ → CxmOp)          -- hard-delete op; `nothing` = append-only (§9.2)
open Table public

------------------------------------------------------------------------
-- Concrete handles (the ONLY place that names IndexedMap / Base fields / CxmOp ctors)
------------------------------------------------------------------------

tenantsT : Table Tenant
tenantsT = mkTable "tenant"
  (λ id b → IM.lookup id (tenants b)) (λ p k b → IM.byIndex p k (tenants b))
  (λ b → IM.toList (tenants b)) SetTenant (just DelTenant)

subjectsT : Table Subject
subjectsT = mkTable "subject"
  (λ id b → IM.lookup id (subjects b)) (λ p k b → IM.byIndex p k (subjects b))
  (λ b → IM.toList (subjects b)) SetSubject (just DelSubject)

edgesT : Table SubjectEdge
edgesT = mkTable "subject_edge"
  (λ id b → IM.lookup id (edges b)) (λ p k b → IM.byIndex p k (edges b))
  (λ b → IM.toList (edges b)) SetEdge (just DelEdge)

identitiesT : Table Identity
identitiesT = mkTable "identity"
  (λ id b → IM.lookup id (identities b)) (λ p k b → IM.byIndex p k (identities b))
  (λ b → IM.toList (identities b)) SetIdentity (just DelIdentity)

eventsT : Table ExperienceEvent
eventsT = mkTable "experience_event"
  (λ id b → IM.lookup id (events b)) (λ p k b → IM.byIndex p k (events b))
  (λ b → IM.toList (events b)) SetEvent nothing              -- append-only [СОБ]: no delete

busEventsT : Table Event
busEventsT = mkTable "bus_event"
  (λ id b → IM.lookup id (busEvents b)) (λ p k b → IM.byIndex p k (busEvents b))
  (λ b → IM.toList (busEvents b)) SetBusEvent (just DelBusEvent)

outboxT : Table OutboxEntry
outboxT = mkTable "outbox"
  (λ id b → IM.lookup id (outbox b)) (λ p k b → IM.byIndex p k (outbox b))
  (λ b → IM.toList (outbox b)) SetOutbox (just DelOutbox)

knowledgeT : Table Knowledge
knowledgeT = mkTable "knowledge"
  (λ id b → IM.lookup id (knowledge b)) (λ p k b → IM.byIndex p k (knowledge b))
  (λ b → IM.toList (knowledge b)) SetKnowledge (just DelKnowledge)

evidenceT : Table Evidence
evidenceT = mkTable "evidence"
  (λ id b → IM.lookup id (evidence b)) (λ p k b → IM.byIndex p k (evidence b))
  (λ b → IM.toList (evidence b)) SetEvidence (just DelEvidence)

transitionsT : Table Transition
transitionsT = mkTable "transition"
  (λ id b → IM.lookup id (transitions b)) (λ p k b → IM.byIndex p k (transitions b))
  (λ b → IM.toList (transitions b)) SetTransition (just DelTransition)

deviationsT : Table Deviation
deviationsT = mkTable "deviation"
  (λ id b → IM.lookup id (deviations b)) (λ p k b → IM.byIndex p k (deviations b))
  (λ b → IM.toList (deviations b)) SetDeviation (just DelDeviation)

protocolStatesT : Table ProtocolState
protocolStatesT = mkTable "protocol_state"
  (λ id b → IM.lookup id (protocolStates b)) (λ p k b → IM.byIndex p k (protocolStates b))
  (λ b → IM.toList (protocolStates b)) SetProtState (just DelProtState)

protocolTransitionsT : Table ProtocolTransition
protocolTransitionsT = mkTable "protocol_transition"
  (λ id b → IM.lookup id (protocolTransitions b)) (λ p k b → IM.byIndex p k (protocolTransitions b))
  (λ b → IM.toList (protocolTransitions b)) SetProtTrans (just DelProtTrans)

offeringsT : Table Offering
offeringsT = mkTable "offering"
  (λ id b → IM.lookup id (offerings b)) (λ p k b → IM.byIndex p k (offerings b))
  (λ b → IM.toList (offerings b)) SetOffering (just DelOffering)

resourcesT : Table Resource
resourcesT = mkTable "resource"
  (λ id b → IM.lookup id (resources b)) (λ p k b → IM.byIndex p k (resources b))
  (λ b → IM.toList (resources b)) SetResource (just DelResource)

entitlementsT : Table Entitlement
entitlementsT = mkTable "entitlement"
  (λ id b → IM.lookup id (entitlements b)) (λ p k b → IM.byIndex p k (entitlements b))
  (λ b → IM.toList (entitlements b)) SetEntitlement (just DelEntitlement)

accountsT : Table Account
accountsT = mkTable "account"
  (λ id b → IM.lookup id (accounts b)) (λ p k b → IM.byIndex p k (accounts b))
  (λ b → IM.toList (accounts b)) SetAccount (just DelAccount)

paymentsT : Table Payment
paymentsT = mkTable "payment"
  (λ id b → IM.lookup id (payments b)) (λ p k b → IM.byIndex p k (payments b))
  (λ b → IM.toList (payments b)) SetPayment (just DelPayment)

expectationsT : Table Expectation
expectationsT = mkTable "expectation"
  (λ id b → IM.lookup id (expectations b)) (λ p k b → IM.byIndex p k (expectations b))
  (λ b → IM.toList (expectations b)) SetExpectation (just DelExpectation)

promisesT : Table Promise
promisesT = mkTable "promise"
  (λ id b → IM.lookup id (promises b)) (λ p k b → IM.byIndex p k (promises b))
  (λ b → IM.toList (promises b)) SetPromise (just DelPromise)

protocolsT : Table Protocol
protocolsT = mkTable "protocol"
  (λ id b → IM.lookup id (protocols b)) (λ p k b → IM.byIndex p k (protocols b))
  (λ b → IM.toList (protocols b)) SetProtocol (just DelProtocol)

episodesT : Table Episode
episodesT = mkTable "episode"
  (λ id b → IM.lookup id (episodes b)) (λ p k b → IM.byIndex p k (episodes b))
  (λ b → IM.toList (episodes b)) SetEpisode (just DelEpisode)

usersT : Table User
usersT = mkTable "user"
  (λ id b → IM.lookup id (users b)) (λ p k b → IM.byIndex p k (users b))
  (λ b → IM.toList (users b)) SetUser (just DelUser)

assignmentsT : Table RoleAssignment
assignmentsT = mkTable "role_assignment"
  (λ id b → IM.lookup id (assignments b)) (λ p k b → IM.byIndex p k (assignments b))
  (λ b → IM.toList (assignments b)) SetAssignment (just DelAssignment)

appointmentsT : Table Appointment
appointmentsT = mkTable "appointment"
  (λ id b → IM.lookup id (appointments b)) (λ p k b → IM.byIndex p k (appointments b))
  (λ b → IM.toList (appointments b)) SetAppointment (just DelAppointment)

integrationTokensT : Table IntTokenRow
integrationTokensT = mkTable "integration_token"
  (λ id b → IM.lookup id (integrationTokens b)) (λ p k b → IM.byIndex p k (integrationTokens b))
  (λ b → IM.toList (integrationTokens b)) SetIntToken (just DelIntToken)

------------------------------------------------------------------------
-- Txn-level operations over a handle — the vocabulary domain commands use
------------------------------------------------------------------------

-- read by id (reflects ops emitted earlier in this txn — reads the working Base)
getT : ∀ {V} → Table V → ℕ → Txn (Maybe V)
getT tbl id = getBase >>=T λ b → returnT (tget tbl id b)

-- read by id or abort (FK / existence checks)
requireT : ∀ {V} → Table V → Err → ℕ → Txn V
requireT tbl e id = getT tbl id >>=T requireJust e

-- secondary lookup: index-position → key → primary ids
byIndexT : ∀ {V} → Table V → ℕ → ℕ → Txn (List ℕ)
byIndexT tbl pos key = getBase >>=T λ b → returnT (tbyIndex tbl pos key b)

-- full scan (id-ordered); prefer byIndexT where an index exists
scanT : ∀ {V} → Table V → Txn (List (ℕ × V))
scanT tbl = getBase >>=T λ b → returnT (tscan tbl b)

-- write (insert/replace); maintains indexes + advances nextId via apply
putT : ∀ {V} → Table V → V → Txn ⊤
putT tbl v = emit (tset tbl v)

-- hard delete by id. Append-only tables (tdel = nothing, e.g. events — §9.2) reject it by
-- aborting the whole txn, so no code path can silently delete a source-of-truth row.
delT : ∀ {V} → Table V → ℕ → Txn ⊤
delT tbl id with tdel tbl
... | just mk = emit (mk id)
... | nothing = abort (Invariant "append-only entity: hard delete not permitted (§7.5 erasure = crypto-shred)")

-- the next free surrogate id (≥ 1; see Base nextId invariant). NOTE: reflects ops emitted
-- EARLIER in this txn — `emit`/`putT` bump nextId — so allocate sequentially
-- (freshId → putT → freshId → putT …); reading two freshIds before any putT yields the SAME id.
freshId : Txn ℕ
freshId = getBase >>=T λ b → returnT (nextId b)

resourceLinksT : Table ResourceLink
resourceLinksT = mkTable "resource_link"
  (λ id b → IM.lookup id (resourceLinks b)) (λ p k b → IM.byIndex p k (resourceLinks b))
  (λ b → IM.toList (resourceLinks b)) SetResourceLink (just DelResourceLink)

mentionsT : Table Mention
mentionsT = mkTable "mention"
  (λ id b → IM.lookup id (mentions b)) (λ p k b → IM.byIndex p k (mentions b))
  (λ b → IM.toList (mentions b)) SetMention (just DelMention)
