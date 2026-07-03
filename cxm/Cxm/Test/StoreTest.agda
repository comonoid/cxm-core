{-# OPTIONS --without-K #-}

-- Store tests (Phase 5 DoD), all compile-time `refl` — no IO needed (the IO walTxn wiring
-- is exercised in the GHC app layer later, like CRM). Covered:
--   * op codec round-trip for EVERY CxmOp kind (all 13 Set + all 12 Del) — proves each tag
--     is paired with the RIGHT decoder (audit #B: a mis-pairing on an untested op would slip);
--   * append-only enforcement: delT on the events handle aborts (no DelEvent exists, audit #A);
--   * runTxn round-trip: a Txn emits exactly its ops and yields state = replay(ops);
--   * "replay the log restores Base": encode ops → strings → decode+apply ≡ live Base;
--   * nextId advances past the largest id.
module Cxm.Test.StoreTest where

open import Relation.Binary.PropositionalEquality using (_≡_; refl)
open import Data.Maybe using (just; nothing; maybe)
open import Data.List using (List; []; _∷_; foldl)
open import Data.Sum using (inj₁; inj₂)
open import Data.Product using (_,_)
open import Agda.Builtin.Unit using (⊤; tt)
open import Data.Bool using (true; false)

open import Cxm.Tenant using (mkTenant)
open import Cxm.Subject using (mkSubject; EXTERNAL; Person)
open import Cxm.Edge using (mkEdge; participation)
open import Cxm.Identity using (mkIdentity)
open import Cxm.Event using (mkExperienceEvent; Web; Client; View)
open import Cxm.Bus using (mkEvent; mkOutbox; OutPending)
open import Cxm.Knowledge using (mkKnowledge; FACT; OBSERVED; ACTIVE)
open import Cxm.Collections using
  ( mkEvidence; mkTransition; mkDeviation; Stuck; mkProtocolState; mkProtocolTransition )
open import Cxm.Offering using (mkOffering)
open import Cxm.Resource using (mkResource)
open import Cxm.Entitlement using (mkEntitlement; TOffering; SPayment)
open import Cxm.Account using (mkAccount)
open import Cxm.Payment using (mkPayment; PayPending)
open import Cxm.Expectation using (mkExpectation; ExpOurPromise; ExpUnknown; mkPromise; PromPending; Ours)
open import Cxm.Protocol using (mkProtocol)
open import Cxm.Episode using (mkEpisode)
open import Cxm.Users using (mkUser; mkAssignment)
open import Cxm.Appointment using (mkAppointment; ApScheduled)
open import Cxm.Store.Base
open import Cxm.Store.Codec
open import Cxm.Txn
open import Cxm.Store.Interface

------------------------------------------------------------------------
-- Fixtures — one value per entity (ids 1..13)
------------------------------------------------------------------------

t1  = mkTenant 1 "Acme:|" 0
s1  = mkSubject 2 EXTERNAL Person "Ann" "UTC" 0 nothing 1 nothing nothing false
e1  = mkEdge 3 2 2 participation nothing 0 0 nothing 1 0
id1 = mkIdentity 4 2 "email" "a@b:|" true 1 0
ee1 = mkExperienceEvent 5 2 1 Web Client 0 View 0 nothing nothing nothing nothing false false "{}" nothing
bus1 = mkEvent 6 "t.topic" "{}" false 1 0
ob1 = mkOutbox 7 "email" "to@x" "subj:|" "body|:" OutPending 1 0 0 nothing
k1  = mkKnowledge 8 2 1 FACT OBSERVED 1000 0 nothing 0 ACTIVE "claim:|" nothing
evd1 = mkEvidence 9 8 5 1 0
tr1 = mkTransition 10 20 0 1 0 0 1
dv1 = mkDeviation 11 20 Stuck 0 1
ps1 = mkProtocolState 12 30 0 "s:|" 1
pt1 = mkProtocolTransition 13 30 0 1 1

------------------------------------------------------------------------
-- Op codec round-trip — every Set op (13)
------------------------------------------------------------------------

_ : decodeOp (encodeOp (SetTenant t1))     ≡ just (SetTenant t1)
_ = refl
_ : decodeOp (encodeOp (SetSubject s1))    ≡ just (SetSubject s1)
_ = refl
_ : decodeOp (encodeOp (SetEdge e1))       ≡ just (SetEdge e1)
_ = refl
_ : decodeOp (encodeOp (SetIdentity id1))  ≡ just (SetIdentity id1)
_ = refl
_ : decodeOp (encodeOp (SetEvent ee1))     ≡ just (SetEvent ee1)
_ = refl
_ : decodeOp (encodeOp (SetBusEvent bus1)) ≡ just (SetBusEvent bus1)
_ = refl
_ : decodeOp (encodeOp (SetOutbox ob1))    ≡ just (SetOutbox ob1)
_ = refl
_ : decodeOp (encodeOp (SetKnowledge k1))  ≡ just (SetKnowledge k1)
_ = refl
_ : decodeOp (encodeOp (SetEvidence evd1)) ≡ just (SetEvidence evd1)
_ = refl
_ : decodeOp (encodeOp (SetTransition tr1))≡ just (SetTransition tr1)
_ = refl
_ : decodeOp (encodeOp (SetDeviation dv1)) ≡ just (SetDeviation dv1)
_ = refl
_ : decodeOp (encodeOp (SetProtState ps1)) ≡ just (SetProtState ps1)
_ = refl
_ : decodeOp (encodeOp (SetProtTrans pt1)) ≡ just (SetProtTrans pt1)
_ = refl

------------------------------------------------------------------------
-- Op codec round-trip — every Del op (12; there is NO DelEvent, audit #A)
------------------------------------------------------------------------

_ : decodeOp (encodeOp (DelTenant 1))     ≡ just (DelTenant 1)
_ = refl
_ : decodeOp (encodeOp (DelSubject 2))    ≡ just (DelSubject 2)
_ = refl
_ : decodeOp (encodeOp (DelEdge 3))       ≡ just (DelEdge 3)
_ = refl
_ : decodeOp (encodeOp (DelIdentity 4))   ≡ just (DelIdentity 4)
_ = refl
_ : decodeOp (encodeOp (DelBusEvent 6))   ≡ just (DelBusEvent 6)
_ = refl
_ : decodeOp (encodeOp (DelOutbox 7))     ≡ just (DelOutbox 7)
_ = refl
_ : decodeOp (encodeOp (DelKnowledge 8))  ≡ just (DelKnowledge 8)
_ = refl
_ : decodeOp (encodeOp (DelEvidence 9))   ≡ just (DelEvidence 9)
_ = refl
_ : decodeOp (encodeOp (DelTransition 10))≡ just (DelTransition 10)
_ = refl
_ : decodeOp (encodeOp (DelDeviation 11)) ≡ just (DelDeviation 11)
_ = refl
_ : decodeOp (encodeOp (DelProtState 12)) ≡ just (DelProtState 12)
_ = refl
_ : decodeOp (encodeOp (DelProtTrans 13)) ≡ just (DelProtTrans 13)
_ = refl

------------------------------------------------------------------------
-- Op codec round-trip — every Phase-6 op (11 Set + 11 Del), audit #C
------------------------------------------------------------------------

o6  = mkOffering 20 1 3 5000 "RUB" "{}" 0 nothing
rs6 = mkResource 21 1 nothing 2 0 nothing "{}" 0 nothing nothing nothing nothing nothing
en6 = mkEntitlement 22 2 1 TOffering 20 0 nothing SPayment 0
ac6 = mkAccount 23 1 1000 0
py6 = mkPayment 24 1 "ext:|" 20 2 "N" "e@x" 5000 PayPending 0 0
xp6 = mkExpectation 25 2 1 "t:|" ExpOurPromise 0 ExpUnknown 0
pm6 = mkPromise 26 2 1 "t" 100 PromPending nothing 0 Ours nothing false 0 nothing nothing false
pr6 = mkProtocol 27 1 "p:|" 0 0
ep6 = mkEpisode 28 2 27 1 0 "j:|" nothing nothing 0 nothing
us6 = mkUser 29 1 "login:|" "hash" 0
ra6 = mkAssignment 30 1 "login:|" "admin" "/t" 0

_ : decodeOp (encodeOp (SetOffering o6))    ≡ just (SetOffering o6)
_ = refl
_ : decodeOp (encodeOp (SetResource rs6))   ≡ just (SetResource rs6)
_ = refl
_ : decodeOp (encodeOp (SetEntitlement en6))≡ just (SetEntitlement en6)
_ = refl
_ : decodeOp (encodeOp (SetAccount ac6))    ≡ just (SetAccount ac6)
_ = refl
_ : decodeOp (encodeOp (SetPayment py6))    ≡ just (SetPayment py6)
_ = refl
_ : decodeOp (encodeOp (SetExpectation xp6))≡ just (SetExpectation xp6)
_ = refl
_ : decodeOp (encodeOp (SetPromise pm6))    ≡ just (SetPromise pm6)
_ = refl
_ : decodeOp (encodeOp (SetProtocol pr6))   ≡ just (SetProtocol pr6)
_ = refl
_ : decodeOp (encodeOp (SetEpisode ep6))    ≡ just (SetEpisode ep6)
_ = refl
_ : decodeOp (encodeOp (SetUser us6))       ≡ just (SetUser us6)
_ = refl
_ : decodeOp (encodeOp (SetAssignment ra6)) ≡ just (SetAssignment ra6)
_ = refl

_ : decodeOp (encodeOp (DelOffering 20))    ≡ just (DelOffering 20)
_ = refl
_ : decodeOp (encodeOp (DelResource 21))    ≡ just (DelResource 21)
_ = refl
_ : decodeOp (encodeOp (DelEntitlement 22)) ≡ just (DelEntitlement 22)
_ = refl
_ : decodeOp (encodeOp (DelAccount 23))     ≡ just (DelAccount 23)
_ = refl
_ : decodeOp (encodeOp (DelPayment 24))     ≡ just (DelPayment 24)
_ = refl
_ : decodeOp (encodeOp (DelExpectation 25)) ≡ just (DelExpectation 25)
_ = refl
_ : decodeOp (encodeOp (DelPromise 26))     ≡ just (DelPromise 26)
_ = refl
_ : decodeOp (encodeOp (DelProtocol 27))    ≡ just (DelProtocol 27)
_ = refl
_ : decodeOp (encodeOp (DelEpisode 28))     ≡ just (DelEpisode 28)
_ = refl
_ : decodeOp (encodeOp (DelUser 29))        ≡ just (DelUser 29)
_ = refl
_ : decodeOp (encodeOp (DelAssignment 30))  ≡ just (DelAssignment 30)
_ = refl
_ : decodeOp (encodeOp (SetAppointment (mkAppointment 31 10 0 (just 5) nothing 1700 90 ApScheduled nothing 1 0 nothing)))
      ≡ just (SetAppointment (mkAppointment 31 10 0 (just 5) nothing 1700 90 ApScheduled nothing 1 0 nothing))
_ = refl
_ : decodeOp (encodeOp (DelAppointment 31))  ≡ just (DelAppointment 31)
_ = refl

------------------------------------------------------------------------
-- Append-only enforcement: delT on events aborts the txn (audit #A)
------------------------------------------------------------------------

_ : runTxn (delT eventsT 5) emptyBase
      ≡ inj₁ (Invariant "append-only entity: hard delete not permitted (§7.5 erasure = crypto-shred)")
_ = refl

------------------------------------------------------------------------
-- runTxn round-trip + log replay + nextId (built via the repository seam)
------------------------------------------------------------------------

demoTxn : Txn ⊤
demoTxn = putT tenantsT t1 >>T putT subjectsT s1 >>T putT edgesT e1

ops : List CxmOp
ops = SetTenant t1 ∷ SetSubject s1 ∷ SetEdge e1 ∷ []

replay : List CxmOp → Base → Base
replay xs b = foldl (λ acc op → apply op acc) b xs

live : Base
live = replay ops emptyBase

-- the Txn emits exactly `ops` and yields state = replay(ops)
_ : runTxn demoTxn emptyBase ≡ inj₂ (live , ops , tt)
_ = refl

-- serialize ops to WAL strings, then decode+apply back from empty → reproduces live (live ≡ replay)
replayLog : List CxmOp → Base
replayLog xs = foldl (λ b op → maybe (λ o → apply o b) b (decodeOp (encodeOp op))) emptyBase xs

_ : replayLog ops ≡ live
_ = refl

-- nextId advanced past the largest id (3) → 4 (bump = max(nextId, id+1); reduces on literals)
_ : nextId live ≡ 4
_ = refl

-- NOTE: read-level assertions (tget/tbyIndex through the seam) are NOT compile-time `refl`
-- tests: NatMap.lookup/byIndex don't reduce definitionally on a concrete inserted structure
-- (Agda gets stuck), which is exactly why CRM validates reads at RUNTIME in the GHC app layer.
-- Those read/index-maintenance checks land there (Phase 8/11), not here.

-- integration token (tags V/v) + curation link (tags @/x) — аудит-доукладка
private
  open import Cxm.Site using (mkIntTokenRow)
  open import Cxm.Resource using (mkResourceLink)

  _ : decodeOp (encodeOp (SetIntToken (mkIntTokenRow 32 1 "tok:|" "/v1" "org" 0 nothing)))
        ≡ just (SetIntToken (mkIntTokenRow 32 1 "tok:|" "/v1" "org" 0 nothing))
  _ = refl
  _ : decodeOp (encodeOp (DelIntToken 32))  ≡ just (DelIntToken 32)
  _ = refl
  _ : decodeOp (encodeOp (SetResourceLink (mkResourceLink 33 1 500 120 "pin" 2 0 (just 99) 0)))
        ≡ just (SetResourceLink (mkResourceLink 33 1 500 120 "pin" 2 0 (just 99) 0))
  _ = refl
  _ : decodeOp (encodeOp (DelResourceLink 33))  ≡ just (DelResourceLink 33)
  _ = refl
