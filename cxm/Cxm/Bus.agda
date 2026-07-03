{-# OPTIONS --without-K #-}

-- The domain bus + outbox (cxm-plan.md Phase 3, description §4.15, §8.2). Ported from CRM
-- as-is, with the `tenant` axis added. These are the SECOND and THIRD narrow logs, not the
-- experience log:
--   * `Event` (topic/payload/processed) — a transactional outbox for external consumers,
--     at-least-once delivery. Written in the SAME Txn as the domain change it describes.
--   * `OutboxEntry` — a durable notification INTENT, written atomically with the change; a
--     worker delivers it (external IO, never inside a Txn) and marks it Sent.
-- Neither is the `ExperienceEvent` source of truth (§8.2) — do not conflate.
module Cxm.Bus where

open import Data.Nat using (ℕ)
open import Data.Maybe using (Maybe)
open import Data.String using (String)
open import Data.Bool using (Bool)

open import Cxm.Tenant using (TenantId)

------------------------------------------------------------------------
-- Domain bus event (§4.15). Topic from a catalogue; payload = JSON.
------------------------------------------------------------------------

record Event : Set where
  constructor mkEvent
  field
    evId        : ℕ
    evTopic     : String           -- e.g. "episode.transitioned", "payment.succeeded"
    evPayload   : String           -- JSON (entity ids, ts, …)
    evProcessed : Bool             -- delivered to consumers?
    evTenant    : TenantId         -- §7.1 tenant axis
    evCreatedAt : ℕ

open Event public

------------------------------------------------------------------------
-- Outbox (durable notification intent, §4.15)
------------------------------------------------------------------------

data OutStatus : Set where
  OutPending : OutStatus           -- queued, not yet delivered
  OutSent    : OutStatus           -- delivered (marked by the worker)
  OutFailed  : OutStatus           -- gave up after max attempts (D2; kept as an audit row)

record OutboxEntry : Set where
  constructor mkOutbox
  field
    obId        : ℕ
    obChannel   : String           -- "email" | "sms" | …
    obTo        : String           -- recipient address
    obSubject   : String
    obBody      : String
    obStatus    : OutStatus
    obTenant    : TenantId         -- §7.1 tenant axis
    obCreatedAt : ℕ
    obAttempts    : ℕ            -- delivery attempts so far (D2 retry accounting)
    obLastAttempt : Maybe ℕ      -- unix seconds of the last attempt; nothing = never tried

open OutboxEntry public
