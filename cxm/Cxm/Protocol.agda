{-# OPTIONS --without-K #-}

-- `Protocol` — a line type as DATA (cxm-plan.md Phase 6, §4.9) — [ВХ]. The vertical's line
-- definition: its `states` and allowed `transitions` are child tables (ProtocolState /
-- ProtocolTransition, Cxm.Collections). Norms (expected duration, SLA, alarming transitions)
-- ride on the transition rows in later work; the Protocol row carries identity + the initial
-- state. Examples (as data, never named in core): booking, treatment, course consumption, ticket.
module Cxm.Protocol where

open import Data.Nat using (ℕ)
open import Data.String using (String)

open import Cxm.Tenant using (TenantId)

record Protocol : Set where
  constructor mkProtocol
  field
    prId           : ℕ
    prTenant       : TenantId
    prName         : String
    prInitialState : ℕ            -- state code an Episode starts in
    prCreatedAt    : ℕ

open Protocol public
