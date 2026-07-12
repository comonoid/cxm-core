{-# OPTIONS --without-K #-}

-- Ф2 FULL ROLLOUT (pg-store-plan): the complete CXM verb signature over the freer Tx — all 28
-- tables. This module is PURE surface: TableCode/Val/Req/Ans + the Free instantiation + the
-- ergonomic verb layer (audit U1: commands read like the old Txn — `require`, `put`, `byCol`,
-- `lockRoots` with canonical ordering inside). Interpreters live next door:
-- Cxm.Store.VerbsBase (native, over Base — runtime) and the pure test handler (VerbsTest).
--
-- Lock discipline (pg-store-plan «Конкурентность»): `rootOf` maps every row to its aggregate
-- root — subject-centric where the domain is (identity/knowledge/episode/… root at their
-- subject; evidence at its knowledge; transitions at their episode; system rows at themselves).
-- Creates of self-rooted rows need `lockKey` (advisory), enforced by the A3 rule (lockRoot of
-- an absent row is refused). `rDel tcEvent` does not exist semantically: events are append-only.
module Cxm.Store.Verbs where

open import Agda.Builtin.String using (String; primStringEquality)
open import Agda.Builtin.Unit using (⊤; tt)
open import Data.Bool using (Bool; true; false; if_then_else_; _∨_; _∧_)
open import Data.List using (List; []; _∷_)
open import Data.Maybe using (Maybe; just; nothing)
open import Data.Nat using (ℕ; _≡ᵇ_; _<ᵇ_; _+_; _*_)
open import Data.Product using (_×_; _,_; proj₁; proj₂)
open import Relation.Binary.PropositionalEquality using (_≡_; refl)

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
open import Cxm.Users using (User; uId; uLogin; RoleAssignment; raId; raSubject)
open import Cxm.Site using (IntTokenRow; itkId; itkToken)
open import Cxm.Appointment
open import Cxm.Store.Base using (Err; NotFound; Invariant)

------------------------------------------------------------------------
-- Tables
------------------------------------------------------------------------

data TableCode : Set where
  tcTenant tcSubject tcEdge tcIdentity tcEvent tcBusEvent tcOutbox tcKnowledge
    tcEvidence tcTransition tcDeviation tcProtocolState tcProtocolTransition tcOffering
    tcResource tcEntitlement tcAccount tcPayment tcExpectation tcPromise tcProtocol
    tcEpisode tcUser tcAssignment tcAppointment tcIntToken tcResourceLink tcMention : TableCode

Val : TableCode → Set
Val tcTenant             = Tenant
Val tcSubject            = Subject
Val tcEdge               = SubjectEdge
Val tcIdentity           = Identity
Val tcEvent              = ExperienceEvent
Val tcBusEvent           = Event
Val tcOutbox             = OutboxEntry
Val tcKnowledge          = Knowledge
Val tcEvidence           = Evidence
Val tcTransition         = Transition
Val tcDeviation          = Deviation
Val tcProtocolState      = ProtocolState
Val tcProtocolTransition = ProtocolTransition
Val tcOffering           = Offering
Val tcResource           = Resource
Val tcEntitlement        = Entitlement
Val tcAccount            = Account
Val tcPayment            = Payment
Val tcExpectation        = Expectation
Val tcPromise            = Promise
Val tcProtocol           = Protocol
Val tcEpisode            = Episode
Val tcUser               = User
Val tcAssignment         = RoleAssignment
Val tcAppointment        = Appointment
Val tcIntToken           = IntTokenRow
Val tcResourceLink       = ResourceLink
Val tcMention            = Mention

code : TableCode → ℕ
code tcTenant             = 0
code tcSubject            = 1
code tcEdge               = 2
code tcIdentity           = 3
code tcEvent              = 4
code tcBusEvent           = 5
code tcOutbox             = 6
code tcKnowledge          = 7
code tcEvidence           = 8
code tcTransition         = 9
code tcDeviation          = 10
code tcProtocolState      = 11
code tcProtocolTransition = 12
code tcOffering           = 13
code tcResource           = 14
code tcEntitlement        = 15
code tcAccount            = 16
code tcPayment            = 17
code tcExpectation        = 18
code tcPromise            = 19
code tcProtocol           = 20
code tcEpisode            = 21
code tcUser               = 22
code tcAssignment         = 23
code tcAppointment        = 24
code tcIntToken           = 25
code tcResourceLink       = 26
code tcMention            = 27

-- decidable equality WITH the proof (the pure test handler's function-state override needs it)
_≟_ : (a b : TableCode) → Maybe (a ≡ b)
tcTenant             ≟ tcTenant             = just refl
tcSubject            ≟ tcSubject            = just refl
tcEdge               ≟ tcEdge               = just refl
tcIdentity           ≟ tcIdentity           = just refl
tcEvent              ≟ tcEvent              = just refl
tcBusEvent           ≟ tcBusEvent           = just refl
tcOutbox             ≟ tcOutbox             = just refl
tcKnowledge          ≟ tcKnowledge          = just refl
tcEvidence           ≟ tcEvidence           = just refl
tcTransition         ≟ tcTransition         = just refl
tcDeviation          ≟ tcDeviation          = just refl
tcProtocolState      ≟ tcProtocolState      = just refl
tcProtocolTransition ≟ tcProtocolTransition = just refl
tcOffering           ≟ tcOffering           = just refl
tcResource           ≟ tcResource           = just refl
tcEntitlement        ≟ tcEntitlement        = just refl
tcAccount            ≟ tcAccount            = just refl
tcPayment            ≟ tcPayment            = just refl
tcExpectation        ≟ tcExpectation        = just refl
tcPromise            ≟ tcPromise            = just refl
tcProtocol           ≟ tcProtocol           = just refl
tcEpisode            ≟ tcEpisode            = just refl
tcUser               ≟ tcUser               = just refl
tcAssignment         ≟ tcAssignment         = just refl
tcAppointment        ≟ tcAppointment        = just refl
tcIntToken           ≟ tcIntToken           = just refl
tcResourceLink       ≟ tcResourceLink       = just refl
tcMention            ≟ tcMention            = just refl
_                    ≟ _                    = nothing

------------------------------------------------------------------------
-- The verb signature
------------------------------------------------------------------------

data Req : Set where
  rLockRoot : TableCode → ℕ → Req                    -- PG: SELECT … FOR UPDATE (row must exist, A3)
  rLockKey  : (classid objid : ℕ) → Req              -- PG: pg_advisory_xact_lock (creates)
  rTryLockKey : (classid objid : ℕ) → Req            -- PG: pg_TRY_advisory_xact_lock (лидер-гейт)
  rGet      : (t : TableCode) → ℕ → Req
  rByIndex  : (t : TableCode) (pos key : ℕ) → Req    -- ℕ-key secondary index
  rByCol    : (t : TableCode) (col key : String) → Req   -- audit U2: string lookup (login/token/…)
  rScan     : (t : TableCode) → Req                  -- full scan — PG-expensive; hot → query-EDSL
  rPut      : (t : TableCode) → Val t → Req          -- UPSERT; requires the row's root lock
  rDel      : (t : TableCode) → ℕ → Req              -- events: rejected (append-only)
  rFresh    : Req                                    -- PG: nextval('cxm_id_seq') (global counter)

Ans : Req → Set
Ans (rLockRoot _ _)  = ⊤
Ans (rLockKey _ _)   = ⊤
Ans (rTryLockKey _ _) = Bool
Ans (rGet t _)       = Maybe (Val t)
Ans (rByIndex _ _ _) = List ℕ
Ans (rByCol t _ _)   = List (ℕ × Val t)
Ans (rScan t)        = List (ℕ × Val t)
Ans (rPut _ _)       = ⊤
Ans (rDel _ _)       = ⊤
Ans rFresh           = ℕ

open import Agdelte.Storage.Free Req Ans Err public

------------------------------------------------------------------------
-- Ergonomic verb layer (audit U1: commands read like the old Txn)
------------------------------------------------------------------------

get : (t : TableCode) → ℕ → Tx (Maybe (Val t))
get t k = opT (rGet t k)

require : (t : TableCode) → ℕ → Err → Tx (Val t)
require t k e = get t k >>=T λ where
  nothing  → abortT e
  (just v) → returnT v

-- КОНТРАКТ (audit F1): the result is a SET — its ORDER is unspecified and DIFFERS between
-- interpreters (PG: ORDER BY id; pure: ascending; Base: reverse-insertion buckets). Sort it
-- yourself if order matters; never first-match over it.
byIx : (t : TableCode) (pos key : ℕ) → Tx (List ℕ)
byIx t p k = opT (rByIndex t p k)

byCol : (t : TableCode) (col key : String) → Tx (List (ℕ × Val t))
byCol t c k = opT (rByCol t c k)

scan : (t : TableCode) → Tx (List (ℕ × Val t))
scan t = opT (rScan t)

put : (t : TableCode) → Val t → Tx ⊤
put t v = opT (rPut t v)

del : (t : TableCode) → ℕ → Tx ⊤
del t k = opT (rDel t k)

-- КОНТРАКТ (audit E1): every `fresh` MUST be immediately materialized by a `put` of a row with
-- that id, before any further `fresh`. The interpreters agree ONLY on such programs:
--   * native handlers PEEK the counter (fresh;fresh without a put ⇒ the SAME id — the old Txn
--     convention), while PG `nextval` ALWAYS increments (⇒ DIFFERENT ids);
--   * an aborted transaction reuses the id natively but leaves a GAP on PG (ids are surrogate —
--     gaps are harmless, but the live diff harness must compare id-INSENSITIVELY across aborts).
-- All ported commands comply (swept 2026-07-07). Mechanical enforcement lands with the PHOAS
-- layer, where the fresh→put pairing is statically visible.
fresh : Tx ℕ
fresh = opT rFresh

lockKey : (classid objid : ℕ) → Tx ⊤
lockKey c o = opT (rLockKey c o)

tryLockKey : (classid objid : ℕ) → Tx Bool          -- лидер-гейт: false = лок у другого инстанса
tryLockKey c o = opT (rTryLockKey c o)

lockRoot : TableCode → ℕ → Tx ⊤
lockRoot t k = opT (rLockRoot t k)

-- multi-root commands: list roots in ANY order — canonical (code, id) ordering happens HERE,
-- so deadlock-freedom rests on the combinator, not on author care (pg-store-plan discipline).
-- КОНТРАКТ (audit E3): SEQUENTIAL lock acquisitions across a command must also ascend by
-- (code, id) — e.g. subject (1) before episode (21) before its children; deep-deletes comply
-- because parents precede children in the code order. Swept 2026-07-07: all commands ascend.
lockRoots : List (TableCode × ℕ) → Tx ⊤
lockRoots rs = go (sortRoots rs)
  where
    lt : (TableCode × ℕ) → (TableCode × ℕ) → Bool
    lt (a , i) (b , j) = (code a <ᵇ code b) ∨ ((code a ≡ᵇ code b) ∧ (i <ᵇ j))
    insert : (TableCode × ℕ) → List (TableCode × ℕ) → List (TableCode × ℕ)
    insert x [] = x ∷ []
    insert x (y ∷ ys) = if lt x y then x ∷ y ∷ ys else y ∷ insert x ys
    sortRoots : List (TableCode × ℕ) → List (TableCode × ℕ)
    sortRoots [] = []
    sortRoots (x ∷ xs) = insert x (sortRoots xs)
    go : List (TableCode × ℕ) → Tx ⊤
    go [] = returnT tt
    go ((t , k) ∷ rest) = lockRoot t k >>T go rest

------------------------------------------------------------------------
-- The aggregate-root map (the lock discipline's domain knowledge, in ONE place)
------------------------------------------------------------------------

rootOf : (t : TableCode) → Val t → TableCode × ℕ
rootOf tcTenant             v = tcTenant , tId v
rootOf tcSubject            v = tcSubject , sId v
rootOf tcEdge               v = tcSubject , seFrom v
rootOf tcIdentity           v = tcSubject , iSubject v
rootOf tcEvent              v = tcSubject , eeSubject v
rootOf tcBusEvent           v = tcBusEvent , evId v            -- system row (worker-owned)
rootOf tcOutbox             v = tcOutbox , obId v              -- system row (worker-owned)
rootOf tcKnowledge          v = tcSubject , kSubject v
rootOf tcEvidence           v = tcKnowledge , evdKnowledge v
rootOf tcTransition         v = tcEpisode , trEpisode v
rootOf tcDeviation          v = tcEpisode , dvEpisode v
rootOf tcProtocolState      v = tcProtocol , psProtocol v
rootOf tcProtocolTransition v = tcProtocol , ptProtocol v
rootOf tcOffering           v = tcOffering , oId v
rootOf tcResource           v = tcResource , rId v             -- community content roots itself
rootOf tcEntitlement        v = tcSubject , enSubject v
rootOf tcAccount            v = tcAccount , acId v
rootOf tcPayment            v = if paySubject v ≡ᵇ 0 then (tcPayment , payId v)   -- orphan payment (pre-login buyer §4.4) roots itself
                                else (tcSubject , paySubject v)
rootOf tcExpectation        v = tcSubject , xpSubject v
rootOf tcPromise            v = tcSubject , pmSubject v
rootOf tcProtocol           v = tcProtocol , prId v
rootOf tcEpisode            v = tcSubject , epSubject v
rootOf tcUser               v = tcUser , uId v
rootOf tcAssignment         v = tcAssignment , raId v          -- raSubject is a String (login)
rootOf tcAppointment        v = tcSubject , apSubject v
rootOf tcIntToken           v = tcIntToken , itkId v
rootOf tcResourceLink       v = tcResource , rlFrom v
rootOf tcMention            v = tcResource , mResource v

-- ALTERNATE acceptable roots: an edge is a RELATIONSHIP — either endpoint's owner may sever
-- (or create) it, so its seTo-subject is a valid root too (the cascade deletes incoming edges
-- under the deleted subject's own lock). Handlers accept ANY of rootOf ∷ altRoots.
altRoots : (t : TableCode) → Val t → List (TableCode × ℕ)
altRoots tcEdge v = (tcSubject , seTo v) ∷ []
altRoots _      _ = []

-- iterate a Tx action over a list (the cascade primitive; the old Txn's forEachT)
forEachTx : ∀ {A : Set} → List A → (A → Tx ⊤) → Tx ⊤
forEachTx []       _ = returnT tt
forEachTx (x ∷ xs) f = f x >>T forEachTx xs f

-- append-only tables: rDel is semantically absent (mirrors Interface's tdel = nothing)
appendOnly : TableCode → Bool
appendOnly tcEvent = true
appendOnly _       = false

-- queue tables are EXEMPT from the root discipline for puts: their rows are fresh-id appends
-- with a single consumer (the worker) — there is no check-then-write to protect. Everything
-- else still demands its aggregate-root lock.
queueTable : TableCode → Bool
queueTable tcOutbox   = true
queueTable tcBusEvent = true
queueTable _          = false

-- advisory-key namespaces (classid per create-if-absent use case; objid = hashKey of the natural key)
nsIdentityCreate : ℕ
nsIdentityCreate = 1

nsBooking : ℕ                      -- per-resource booking serialization (busy-check → insert)
nsBooking = 2

nsOwnerRegister : ℕ                -- owner registration (tenant+user+assignment creates)
nsOwnerRegister = 3

nsTokenMint : ℕ                    -- integration-token minting (self-rooted create)
nsTokenMint = 4

nsSelfCreate : ℕ                   -- generic self-rooted creates (account/offering/resource/payment),
nsSelfCreate = 5                   -- objid = tenant: per-tenant serialization (throughput → PHOAS)

nsWorker : ℕ                       -- лидер-гейт воркера (бесшовный reload: два сервера, один тикает)
nsWorker = 6

-- deterministic string hash (djb2) for advisory objids. REDUCED mod 2^31-1 at every step:
-- pg_advisory_xact_lock takes int4, so the objid MUST fit 31 bits (and the accumulator must
-- not grow into silly bignums). classid values (our ns* constants) are tiny — fine as int4.
hashKey : String → ℕ
hashKey s = go 5381 (primStringToList s)
  where
    open import Agda.Builtin.String using (primStringToList)
    open import Agda.Builtin.Char using (primCharToNat)
    open import Data.Nat.DivMod using (_%_)
    go : ℕ → List _ → ℕ
    go h []       = h
    go h (c ∷ cs) = go ((h * 33 + primCharToNat c) % 2147483647) cs

------------------------------------------------------------------------
-- byCol's native meaning: which string columns are searchable per table (must match the
-- Wire column names — the PG side runs `WHERE "<col>" = <key>` against the same schema)
------------------------------------------------------------------------

-- the byCol REGISTRY: which (table, column) pairs byCol may target. ALL interpreters (pure,
-- Base, PG-Exec) refuse an unregistered pair LOUDLY — otherwise the native handlers would
-- silently return [] while PG runs real SQL, and a future byCol over an unlisted column would
-- pass its tests vacuously yet behave differently in production (audit C2).
byColSupported : TableCode → String → Bool
byColSupported tcIdentity c = primStringEquality c "channel" ∨ primStringEquality c "external_id"
byColSupported tcUser     c = primStringEquality c "login"
byColSupported tcPayment  c = primStringEquality c "ext_id"
byColSupported tcProtocol c = primStringEquality c "name"
byColSupported tcIntToken c = primStringEquality c "token"
byColSupported tcAssignment c = primStringEquality c "subject"
byColSupported _          _ = false

-- keep in sync with byColSupported (same pairs, the extractor side)
strField : (t : TableCode) → String → Val t → Maybe String
strField tcIdentity col v =
  if primStringEquality col "channel"     then just (iChannel v)
  else if primStringEquality col "external_id" then just (iExternalId v)
  else nothing
strField tcUser col v =
  if primStringEquality col "login" then just (uLogin v) else nothing
strField tcPayment col v =
  if primStringEquality col "ext_id" then just (payExtId v) else nothing
strField tcProtocol col v =
  if primStringEquality col "name" then just (prName v) else nothing
strField tcIntToken col v =
  if primStringEquality col "token" then just (itkToken v) else nothing
strField tcAssignment col v =
  if primStringEquality col "subject" then just (raSubject v) else nothing
strField _ _ _ = nothing