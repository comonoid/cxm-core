{-# OPTIONS --without-K #-}

-- THE single registry of cxm tables (pg-store-plan «Миграции»): one entry per table pairing its
-- SQL name, schema, row encoder and Base projection. Everything that needs "all tables" derives
-- from THIS list — the WAL→PG seeder folds it, `cxmSchemas` (the migration-model target) maps
-- it — so the name↔schema pairing can no longer drift between tools.
--
-- MIGRATION WATCH: the refl proof below pins `migrate cxmHistory [] ≡ cxmSchemas`.
-- Today cxmHistory = `genesis` (one mCreateTable per table, DERIVED from the registry) — the
-- check is intentionally vacuous while no production PG exists. **At the first prod deploy,
-- FREEZE the history**: replace `genesis` with a literal copy and stop deriving. From that
-- moment any Wire schema change without an appended MigStep breaks this module's compilation.
module Cxm.Store.Registry where

open import Agda.Builtin.String using (String)
open import Data.List using (List; []; _∷_; map)
open import Data.Nat using (ℕ)
open import Data.Product using (_×_; _,_)
open import Relation.Binary.PropositionalEquality using (_≡_; refl)

open import Agdelte.Storage.Schema using (Schema; Row)
open import Agdelte.Storage.Migration using (MigStep; mCreateTable; mCreateSequence; migrate; SchemaSet)

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
open import Cxm.Site using (IntTokenRow)
open import Cxm.Appointment

open import Cxm.Wire

------------------------------------------------------------------------
-- One table, packaged: name + schema + row encoder. (The Base-projection column used by the
-- WAL→PG seeder was dropped with the WAL backend — Postgres-only, 2026-07-07; the seeder is
-- retired, and everything live here needs only name + schema.)
------------------------------------------------------------------------

record Dump : Set₁ where
  constructor mkDump
  field
    dName   : String
    dV      : Set
    dSchema : Schema
    dToRow  : dV → Row dSchema
open Dump public

dumps : List Dump
dumps =
    mkDump "tenant"              Tenant             tenantSchema             tenantToRow
  ∷ mkDump "subject"             Subject            subjectSchema            subjectToRow
  ∷ mkDump "subject_edge"        SubjectEdge        edgeSchema               edgeToRow
  ∷ mkDump "identity"            Identity           identitySchema           identityToRow
  ∷ mkDump "experience_event"    ExperienceEvent    experienceEventSchema    eeToRow
  ∷ mkDump "bus_event"           Event              busEventSchema           evToRow
  ∷ mkDump "outbox"              OutboxEntry        outboxSchema             obToRow
  ∷ mkDump "knowledge"           Knowledge          knowledgeSchema          knowledgeToRow
  ∷ mkDump "evidence"            Evidence           evidenceSchema           evidenceToRow
  ∷ mkDump "transition"          Transition         transitionSchema         transitionToRow
  ∷ mkDump "deviation"           Deviation          deviationSchema          deviationToRow
  ∷ mkDump "protocol_state"      ProtocolState      protocolStateSchema      protocolStateToRow
  ∷ mkDump "protocol_transition" ProtocolTransition protocolTransitionSchema protocolTransitionToRow
  ∷ mkDump "offering"            Offering           offeringSchema           offeringToRow
  ∷ mkDump "resource"            Resource           resourceSchema           resourceToRow
  ∷ mkDump "entitlement"         Entitlement        entitlementSchema        entitlementToRow
  ∷ mkDump "account"             Account            accountSchema            accountToRow
  ∷ mkDump "payment"             Payment            paymentSchema            paymentToRow
  ∷ mkDump "expectation"         Expectation        expectationSchema        expectationToRow
  ∷ mkDump "promise"             Promise            promiseSchema            promiseToRow
  ∷ mkDump "protocol"            Protocol           protocolSchema           protocolToRow
  ∷ mkDump "episode"             Episode            episodeSchema            episodeToRow
  ∷ mkDump "user"                User               userSchema               userToRow
  ∷ mkDump "role_assignment"     RoleAssignment     assignmentSchema         assignmentToRow
  ∷ mkDump "appointment"         Appointment        appointmentSchema        appointmentToRow
  ∷ mkDump "integration_token"   IntTokenRow        intTokenSchema           intTokenToRow
  ∷ mkDump "resource_link"       ResourceLink       resourceLinkSchema       resourceLinkToRow
  ∷ mkDump "mention"             Mention            mentionSchema            mentionToRow
  ∷ []

------------------------------------------------------------------------
-- Derived views + the migration watch
------------------------------------------------------------------------

cxmSchemas : SchemaSet
cxmSchemas = map (λ d → dName d , dSchema d) dumps

-- day-0 history: the GLOBAL id sequence (rFresh would crash on a fresh deploy without it —
-- audit D1) + one CREATE per table. FREEZE (replace with a literal) at the first prod deploy.
genesis : List MigStep
genesis = mCreateSequence "cxm_id_seq" ∷ map (λ d → mCreateTable (dName d) (dSchema d)) dumps

cxmHistory : List MigStep
cxmHistory = genesis

-- ★ the watch: replaying the history through the pure model must yield the code's schemas
_ : migrate cxmHistory [] ≡ cxmSchemas
_ = refl
