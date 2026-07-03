{-# OPTIONS --without-K #-}

-- `Appointment` — a bookable scheduled occurrence (Phase 11 / §4.9 / §9.6) — [ВХ]. The core
-- primitive that lets ANY appointment-based vertical work natively: a subject has a scheduled
-- slot on a resource with a mutable lifecycle status. This is where CRM's `Activity` (session
-- with time + status) reformulates to in CXM (§9.1) — a neutral core entity,
-- NOT a pack table. Slot-conflict uses Cxm.Schedule over a resource's scheduled appointments;
-- credits/packages are `Entitlement`s and an `Episode` is the case the appointment belongs to.
module Cxm.Appointment where

open import Data.Nat using (ℕ)
open import Data.Maybe using (Maybe)

open import Cxm.Tenant using (TenantId)

data ApptStatus : Set where
  ApScheduled : ApptStatus
  ApCompleted : ApptStatus
  ApCanceled  : ApptStatus          -- frees its credit (a free cancel)
  ApNoShow    : ApptStatus          -- forfeits its credit (late cancel / no-show)

record Appointment : Set where
  constructor mkAppointment
  field
    apId          : ℕ
    apSubject     : ℕ               -- FK → subject (the client)
    apResource    : ℕ               -- FK → resource (provider/room); 0 = the single operator
    apEpisode     : Maybe ℕ         -- FK → episode (the case/package); indexed via 0-sentinel
    apEntitlement : Maybe ℕ         -- FK → entitlement (the credit drawn); nothing = ad-hoc
    apStartsAt    : ℕ               -- scheduled start (unix seconds, from IO)
    apDurationMin : ℕ               -- duration in minutes
    apStatus      : ApptStatus
    apRemindedAt  : Maybe ℕ         -- when a reminder was enqueued; nothing = not yet (idempotent)
    apTenant      : TenantId
    apCreatedAt   : ℕ
    apPromise     : Maybe ℕ         -- optional link to the client's booking Promise (futures —
                                    -- upgrade-план решение 1: a booking IS a counter-promise
                                    -- pair conceptually; the operational record stays here,
                                    -- promise economics live on Promise). Booking commands do
                                    -- NOT fill it — wiring is a future edge increment.

open Appointment public
