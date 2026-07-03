{-# OPTIONS --without-K --guardedness #-}

-- Cxm.Worker — the ORCHESTRATION side of the closed loop (Concept Ч.2 §6 «ORCH», upgrade-план
-- D3): deliver Outbox intents back to channels + run the core's periodic maintenance. HEADLESS
-- BY CONSTRUCTION (решение 8): the core knows NO transport — delivery is a caller-supplied
-- `deliver : OutboxEntry → IO Bool` adapter (webhook HTTP / e-mail / …, wired in the entry,
-- e.g. server/CxmServer.agda). This module only sequences store reads/writes around it:
--   dueOutbox → deliver → markSent (true) / markAttempt→OutFailed-at-cap (false).
-- Concurrency: every commitTxn serializes through the WalHandle (agdelte-store), so a worker
-- thread and the HTTP listener threads share the store safely with NO extra locking here.
module Cxm.Worker where

open import Agda.Builtin.IO using (IO)
open import Agda.Builtin.Unit using (⊤; tt)
open import Data.Nat using (ℕ; suc; _+_; _*_)
open import Data.Bool using (Bool; true; false)
open import Data.Maybe using (Maybe; just; nothing)
open import Data.List using (List; []; _∷_)

open import Agdelte.FFI.Server using (_>>=_; _>>_; pure)

open import Cxm.Bus using (OutboxEntry)
open import Cxm.Store.Base using (Base; CxmOp)
open import Cxm.Store.Wal using (WalHandle; commitTxn; readBase; committed; rejected; ioFailed)
open import Cxm.Store.Interface using (outboxT; tget)
open import Cxm.Commands using (dueOutbox; markSent; markAttempt; remindDueAppointments; dispatchBus)

-- one delivery pass: read the due pending entries, push each through the adapter, record the
-- outcome. Returns the number DELIVERED this pass. A rejected/failed store write is skipped
-- (the entry stays pending and is retried next tick — at-least-once semantics; receivers must
-- be idempotent, which the signed-webhook contract requires anyway).
runOutboxOnce : WalHandle Base CxmOp → (deliver : OutboxEntry → IO Bool)
              → (now maxAttempts : ℕ) → IO ℕ
runOutboxOnce h deliver now maxAtt =
  commitTxn h (dueOutbox now) >>= λ where
    (committed ids) → go ids 0
    _               → pure 0
  where
    -- fetch the entry from a FRESH snapshot (it may have changed since dueOutbox)
    tryOne : ℕ → IO Bool
    tryOne oid = readBase h >>= λ b → pick (tget outboxT oid b)
      where
        record- : Bool → IO Bool
        record- true  = commitTxn h (markSent oid) >> pure true
        record- false = commitTxn h (markAttempt oid now maxAtt) >> pure false
        pick : Maybe OutboxEntry → IO Bool
        pick nothing  = pure false
        pick (just o) = deliver o >>= record-
    go : List ℕ → ℕ → IO ℕ
    go []         acc = pure acc
    go (i ∷ rest) acc = tryOne i >>= λ ok →
                        go rest (if′ ok (suc acc) acc)
      where
        if′ : Bool → ℕ → ℕ → ℕ
        if′ true  a _ = a
        if′ false _ b = b

-- the core's periodic maintenance in one tick: appointment reminders (enqueue to Outbox —
-- delivered by the NEXT runOutboxOnce) + domain-bus dispatch. Errors are swallowed per-part
-- (a failed reminder pass must not stop bus dispatch).
runMaintenance : WalHandle Base CxmOp → (now leadSec : ℕ) → IO ⊤
runMaintenance h now lead =
  commitTxn h (remindDueAppointments now lead) >>= λ _ →
  commitTxn h dispatchBus >>= λ _ →
  pure tt
