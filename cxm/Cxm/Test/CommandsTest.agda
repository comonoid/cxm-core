{-# OPTIONS --without-K #-}

-- Compile-time tests for Cxm.Commands (Phase 6). Only command paths that DON'T read the store
-- reduce under `refl` (freshId reads the plain `nextId` field, which reduces; requireT/byIndexT
-- use NatMap lookup, which does NOT — see the NOTE below). So we prove here: id allocation +
-- emit + apply for createSubject and the append-only ingest. The FK / cascade / merge / charge /
-- bookSession invariant tests need store reads and therefore run in the GHC runtime harness
-- (Phase 8/11), exactly as CRM's CrmCommandsTest does.
--
-- The money invariant is NOT tested here because it needs no test: `debit` is proof-gated, so
-- `charge` is correct BY CONSTRUCTION (it typechecks ⇒ balance can never go negative).
module Cxm.Test.CommandsTest where

open import Relation.Binary.PropositionalEquality using (_≡_; refl)
open import Data.Maybe using (nothing)
open import Data.List using ([]; _∷_)
open import Data.Sum using (inj₂)
open import Data.Product using (_,_)
open import Data.Bool using (false)

open import Cxm.Subject using (mkSubject; EXTERNAL; Person)
open import Cxm.Event using (mkExperienceEvent; Web; Client; View)
open import Cxm.Bus using (mkOutbox; OutPending)
open import Cxm.Store.Base
open import Cxm.Txn using (runTxn)
open import Cxm.Commands

-- createSubject allocates id 1 (nextId of emptyBase), emits SetSubject, returns 1
sExp : _
sExp = mkSubject 1 EXTERNAL Person "A" "UTC" 0 nothing 1 nothing nothing false

_ : runTxn (createSubject EXTERNAL Person "A" "UTC" 1 0) emptyBase
      ≡ inj₂ (apply (SetSubject sExp) emptyBase , SetSubject sExp ∷ [] , 1)
_ = refl

-- appendEvent assigns a fresh id (overriding the incoming eeId 0 → 1) and appends
evExp : _
evExp = mkExperienceEvent 1 5 1 Web Client 0 View 0 nothing nothing nothing nothing false false "{}" nothing

_ : runTxn (appendEvent (mkExperienceEvent 0 5 1 Web Client 0 View 0 nothing nothing nothing nothing false false "{}" nothing)) emptyBase
      ≡ inj₂ (apply (SetEvent evExp) emptyBase , SetEvent evExp ∷ [] , 1)
_ = refl

-- enqueueNotification allocates a fresh outbox id (1), emits SetOutbox (OutPending), returns 1
obExp : _
obExp = mkOutbox 1 "email" "to@x" "subj" "body" OutPending 1 0 0 nothing

_ : runTxn (enqueueNotification "email" "to@x" "subj" "body" 1 0) emptyBase
      ≡ inj₂ (apply (SetOutbox obExp) emptyBase , SetOutbox obExp ∷ [] , 1)
_ = refl

-- NOTE: reopenAppointment / markSent / dueAppointmentReminders / markApptReminded read the store
-- (requireT/scanT) → not `refl`-reducible; validated in the runtime harness, like other reads.

-- backoffSec (upgrade-план D2): quadratic with a 3600s cap
_ : backoffSec 0 ≡ 0
_ = refl
_ : backoffSec 1 ≡ 60
_ = refl
_ : backoffSec 5 ≡ 1500
_ = refl
_ : backoffSec 8 ≡ 3600      -- 8²·60 = 3840 → capped
_ = refl
