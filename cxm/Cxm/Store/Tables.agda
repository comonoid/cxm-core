{-# OPTIONS --without-K #-}

-- TableCode-indexed schema wiring for the PG Exec (pg-store-plan): SQL name, schema, row codecs
-- per table. The Registry (name-keyed, drives the seeder + migration watch) and THIS module
-- (code-keyed, drives the Exec) are pinned against each other by the bridge proof at the bottom —
-- the (name, schema) pairing cannot drift between them.
module Cxm.Store.Tables where

open import Agda.Builtin.String using (String)
open import Data.List using (List; []; _∷_; map; replicate)
open import Data.Maybe using (Maybe; just; nothing)
open import Data.Bool using (Bool; true; false)
open import Data.Nat using (ℕ)
open import Data.Product using (_×_; _,_)
open import Relation.Binary.PropositionalEquality using (_≡_; refl)

open import Agdelte.Storage.Schema using (Schema; Row; ColTy; cname; cty; cindexed)

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
open import Cxm.Store.Verbs using (TableCode; Val; _≟_
  ; tcTenant; tcSubject; tcEdge; tcIdentity; tcEvent; tcBusEvent; tcOutbox; tcKnowledge
  ; tcEvidence; tcTransition; tcDeviation; tcProtocolState; tcProtocolTransition; tcOffering
  ; tcResource; tcEntitlement; tcAccount; tcPayment; tcExpectation; tcPromise; tcProtocol
  ; tcEpisode; tcUser; tcAssignment; tcAppointment; tcIntToken; tcResourceLink; tcMention )
open import Cxm.Store.Registry using (dumps; dName; dSchema)

allCodes : List TableCode
allCodes =
    tcTenant ∷ tcSubject ∷ tcEdge ∷ tcIdentity ∷ tcEvent ∷ tcBusEvent ∷ tcOutbox ∷ tcKnowledge
  ∷ tcEvidence ∷ tcTransition ∷ tcDeviation ∷ tcProtocolState ∷ tcProtocolTransition ∷ tcOffering
  ∷ tcResource ∷ tcEntitlement ∷ tcAccount ∷ tcPayment ∷ tcExpectation ∷ tcPromise ∷ tcProtocol
  ∷ tcEpisode ∷ tcUser ∷ tcAssignment ∷ tcAppointment ∷ tcIntToken ∷ tcResourceLink ∷ tcMention ∷ []

tableName : TableCode → String
tableName tcTenant             = "tenant"
tableName tcSubject            = "subject"
tableName tcEdge               = "subject_edge"
tableName tcIdentity           = "identity"
tableName tcEvent              = "experience_event"
tableName tcBusEvent           = "bus_event"
tableName tcOutbox             = "outbox"
tableName tcKnowledge          = "knowledge"
tableName tcEvidence           = "evidence"
tableName tcTransition         = "transition"
tableName tcDeviation          = "deviation"
tableName tcProtocolState      = "protocol_state"
tableName tcProtocolTransition = "protocol_transition"
tableName tcOffering           = "offering"
tableName tcResource           = "resource"
tableName tcEntitlement        = "entitlement"
tableName tcAccount            = "account"
tableName tcPayment            = "payment"
tableName tcExpectation        = "expectation"
tableName tcPromise            = "promise"
tableName tcProtocol           = "protocol"
tableName tcEpisode            = "episode"
tableName tcUser               = "user"
tableName tcAssignment         = "role_assignment"
tableName tcAppointment        = "appointment"
tableName tcIntToken           = "integration_token"
tableName tcResourceLink       = "resource_link"
tableName tcMention            = "mention"

schemaOf : TableCode → Schema
schemaOf tcTenant             = tenantSchema
schemaOf tcSubject            = subjectSchema
schemaOf tcEdge               = edgeSchema
schemaOf tcIdentity           = identitySchema
schemaOf tcEvent              = experienceEventSchema
schemaOf tcBusEvent           = busEventSchema
schemaOf tcOutbox             = outboxSchema
schemaOf tcKnowledge          = knowledgeSchema
schemaOf tcEvidence           = evidenceSchema
schemaOf tcTransition         = transitionSchema
schemaOf tcDeviation          = deviationSchema
schemaOf tcProtocolState      = protocolStateSchema
schemaOf tcProtocolTransition = protocolTransitionSchema
schemaOf tcOffering           = offeringSchema
schemaOf tcResource           = resourceSchema
schemaOf tcEntitlement        = entitlementSchema
schemaOf tcAccount            = accountSchema
schemaOf tcPayment            = paymentSchema
schemaOf tcExpectation        = expectationSchema
schemaOf tcPromise            = promiseSchema
schemaOf tcProtocol           = protocolSchema
schemaOf tcEpisode            = episodeSchema
schemaOf tcUser               = userSchema
schemaOf tcAssignment         = assignmentSchema
schemaOf tcAppointment        = appointmentSchema
schemaOf tcIntToken           = intTokenSchema
schemaOf tcResourceLink       = resourceLinkSchema
schemaOf tcMention            = mentionSchema

toRowOf : (t : TableCode) → Val t → Row (schemaOf t)
toRowOf tcTenant             = tenantToRow
toRowOf tcSubject            = subjectToRow
toRowOf tcEdge               = edgeToRow
toRowOf tcIdentity           = identityToRow
toRowOf tcEvent              = eeToRow
toRowOf tcBusEvent           = evToRow
toRowOf tcOutbox             = obToRow
toRowOf tcKnowledge          = knowledgeToRow
toRowOf tcEvidence           = evidenceToRow
toRowOf tcTransition         = transitionToRow
toRowOf tcDeviation          = deviationToRow
toRowOf tcProtocolState      = protocolStateToRow
toRowOf tcProtocolTransition = protocolTransitionToRow
toRowOf tcOffering           = offeringToRow
toRowOf tcResource           = resourceToRow
toRowOf tcEntitlement        = entitlementToRow
toRowOf tcAccount            = accountToRow
toRowOf tcPayment            = paymentToRow
toRowOf tcExpectation        = expectationToRow
toRowOf tcPromise            = promiseToRow
toRowOf tcProtocol           = protocolToRow
toRowOf tcEpisode            = episodeToRow
toRowOf tcUser               = userToRow
toRowOf tcAssignment         = assignmentToRow
toRowOf tcAppointment        = appointmentToRow
toRowOf tcIntToken           = intTokenToRow
toRowOf tcResourceLink       = resourceLinkToRow
toRowOf tcMention            = mentionToRow

-- strict decode: enum ordinals may be unknown → Maybe (total fromRows are wrapped in just)
fromRowOf : (t : TableCode) → Row (schemaOf t) → Maybe (Val t)
fromRowOf tcTenant             r = just (tenantFromRow r)
fromRowOf tcSubject            r = subjectFromRow r
fromRowOf tcEdge               r = edgeFromRow r
fromRowOf tcIdentity           r = just (identityFromRow r)
fromRowOf tcEvent              r = eeFromRow r
fromRowOf tcBusEvent           r = just (evFromRow r)
fromRowOf tcOutbox             r = obFromRow r
fromRowOf tcKnowledge          r = knowledgeFromRow r
fromRowOf tcEvidence           r = just (evidenceFromRow r)
fromRowOf tcTransition         r = just (transitionFromRow r)
fromRowOf tcDeviation          r = deviationFromRow r
fromRowOf tcProtocolState      r = just (protocolStateFromRow r)
fromRowOf tcProtocolTransition r = just (protocolTransitionFromRow r)
fromRowOf tcOffering           r = just (offeringFromRow r)
fromRowOf tcResource           r = just (resourceFromRow r)
fromRowOf tcEntitlement        r = entitlementFromRow r
fromRowOf tcAccount            r = just (accountFromRow r)
fromRowOf tcPayment            r = paymentFromRow r
fromRowOf tcExpectation        r = expectationFromRow r
fromRowOf tcPromise            r = promiseFromRow r
fromRowOf tcProtocol           r = just (protocolFromRow r)
fromRowOf tcEpisode            r = just (episodeFromRow r)
fromRowOf tcUser               r = just (userFromRow r)
fromRowOf tcAssignment         r = just (assignmentFromRow r)
fromRowOf tcAppointment        r = appointmentFromRow r
fromRowOf tcIntToken           r = just (intTokenFromRow r)
fromRowOf tcResourceLink       r = just (resourceLinkFromRow r)
fromRowOf tcMention            r = just (mentionFromRow r)

-- the p-th indexed column of a schema: BY CONSTRUCTION the same position order IndexedMap uses
-- (idxCol order in the schema) — the Exec compiles rByIndex through this
idxCols : Schema → List String
idxCols [] = []
idxCols (c ∷ cs) = if cindexed c then cname c ∷ idxCols cs else idxCols cs
  where open import Data.Bool using (if_then_else_)

-- …and their column TYPES (audit G2: a CBool index column needs TRUE/FALSE literals in SQL,
-- not a number — PG refuses boolean = integer)
idxColTys : Schema → List ColTy
idxColTys [] = []
idxColTys (c ∷ cs) = if cindexed c then cty c ∷ idxColTys cs else idxColTys cs
  where open import Data.Bool using (if_then_else_)
-- (Bool imported at top)

------------------------------------------------------------------------
-- Bridge proofs (audit 2026-07-06): the three index/name registries cannot drift — refl or bust
------------------------------------------------------------------------

-- 1) this wiring ≡ the Registry on (name, schema)
_ : map (λ t → tableName t , schemaOf t) allCodes ≡ map (λ d → dName d , dSchema d) dumps
_ = refl

-- 2) index-position pins for every multi-index table: schema idxCol order ≡ the Base position
--    constants' meaning (subjByTenant=0/subjByCanonical=1, edgeByFrom=0/byTo=1/byKind=2, …).
--    A reordered idxCol in Wire breaks these lines instead of silently remapping rByIndex.
_ : idxCols (schemaOf tcSubject) ≡ "tenant" ∷ "canonical" ∷ []
_ = refl
_ : idxCols (schemaOf tcEdge) ≡ "from_subject" ∷ "to_subject" ∷ "kind" ∷ []
_ = refl
_ : idxCols (schemaOf tcIdentity) ≡ "subject" ∷ "tenant" ∷ []
_ = refl
_ : idxCols (schemaOf tcEvent) ≡ "subject" ∷ "episode" ∷ []
_ = refl
_ : idxCols (schemaOf tcEvidence) ≡ "knowledge_id" ∷ "event_id" ∷ []
_ = refl
_ : idxCols (schemaOf tcPromise) ≡ "subject" ∷ "status" ∷ []
_ = refl
_ : idxCols (schemaOf tcEpisode) ≡ "subject" ∷ "protocol" ∷ []
_ = refl
_ : idxCols (schemaOf tcAppointment) ≡ "subject" ∷ "resource" ∷ "episode" ∷ []
_ = refl
_ : idxCols (schemaOf tcMention) ≡ "resource" ∷ "subject" ∷ []
_ = refl

-- 3) audit C1: `_≟_` is REFLEXIVE for every table. The 28 diagonal clauses end in a catch-all,
--    so a 29th TableCode with a forgotten diagonal would make the pure handler's override
--    silently stop writing that table — this pin turns that into a compile error instead.
private
  isJust : ∀ {A : Set} → Maybe A → Bool
  isJust (just _) = true
  isJust nothing  = false

  pkOf : Schema → String
  pkOf []      = ""
  pkOf (c ∷ _) = cname c

_ : map (λ t → isJust (t ≟ t)) allCodes ≡ replicate 28 true
_ = refl

-- 4) audit C3: every table's pk is literally "id" — the Exec HARDCODES "id" in the lock,
--    byIndex and nextval SQL; a table with a differently-named first column would break here.
_ : map (λ t → pkOf (schemaOf t)) allCodes ≡ replicate 28 "id"
_ = refl