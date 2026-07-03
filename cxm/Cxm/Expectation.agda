{-# OPTIONS --without-K #-}

-- `Expectation` ↔ `Promise` (cxm-plan.md Phase 6, §4.10) — [ВХ] (Expectation is [ПР] when inferred).
-- Implements "experience = perception − expectation": the pair gives continuous gap monitoring.
-- Internal SLAs (§4.14) are the same pair between INTERNAL subjects. Records only.
module Cxm.Expectation where

open import Data.Nat using (ℕ)
open import Data.Bool using (Bool)
open import Data.String using (String)
open import Data.Maybe using (Maybe)

open import Cxm.Tenant using (TenantId)

------------------------------------------------------------------------
-- Expectation
------------------------------------------------------------------------

data ExpSource : Set where
  ExpOurPromise   : ExpSource   -- our own promise set the bar
  ExpCompetitor   : ExpSource   -- a competitor set the bar
  ExpIndustryNorm : ExpSource   -- industry norm set the bar

data ExpStatus : Set where
  ExpMet     : ExpStatus
  ExpUnmet   : ExpStatus
  ExpUnknown : ExpStatus

record Expectation : Set where
  constructor mkExpectation
  field
    xpId        : ℕ
    xpSubject   : ℕ            -- FK → subject
    xpTenant    : TenantId
    xpTopic     : String       -- what is expected (opaque topic key)
    xpSource    : ExpSource
    xpLevel     : ℕ            -- config-driven expectation level
    xpStatus    : ExpStatus
    xpCreatedAt : ℕ

open Expectation public

------------------------------------------------------------------------
-- Promise (a commitment; deadline + fulfilment status). Carries `pmRemindedAt` for the
-- idempotent reminder mechanic (Cxm.Commands.Reminders), ported from CRM's activity reminders.
--
-- Promise economics (Concept Ч.2 §3, upgrade-план A1): promises are SYMMETRIC (§0.2 — the
-- client promises too: show up, pay on time; a no-show is THEIR broken promise) and may be
-- TRADEABLE instruments (futures): a transferable promise can change holder, carries collateral
-- (the margin requirement; its SIZE is Decision-side policy tied to the trust account, not
-- schema), and its lifecycle (listed → transferred → settled/defaulted) is logged as
-- ExperienceEvents — the append-only log doubles as the CLEARING JOURNAL. The exchange itself
-- (order book, matching, pricing) is an operational-loop adapter, NOT core.
------------------------------------------------------------------------

data PromStatus : Set where
  PromPending   : PromStatus
  PromFulfilled : PromStatus
  PromBroken    : PromStatus

-- whose commitment this is (§0.2 symmetry)
data PromDirection : Set where
  Ours   : PromDirection        -- our promise to the subject
  Theirs : PromDirection        -- the subject's promise to us (no-show/late = broken)

record Promise : Set where
  constructor mkPromise
  field
    pmId           : ℕ
    pmSubject      : ℕ            -- FK → subject (the ORIGINAL counterparty)
    pmTenant       : TenantId
    pmTopic        : String
    pmDeadline     : ℕ            -- unix seconds
    pmStatus       : PromStatus
    pmRemindedAt   : Maybe ℕ      -- when a reminder was enqueued; nothing = not yet
    pmCreatedAt    : ℕ
    pmDirection    : PromDirection
    pmHolder       : Maybe ℕ      -- current holder if transferred (FK subject); nothing = original
    pmTransferable : Bool         -- may change holder (futures readiness)
    pmCollateral   : ℕ            -- HELD stake in minor units (0 = none). The consequence routes it.
    -- Controllable-obligations model (платформа-план «Решение по промисам», П6): the promise carries
    -- its declared CONSEQUENCE-on-default as an internal-ledger settlement. Accounts are named
    -- EXPLICITLY (Account has no subject-FK; obligor-vs-bettor = whose account this is). Tier-1.
    pmStakeAccount : Maybe ℕ      -- account the stake was charged FROM at creation (bears the penalty);
                                  -- nothing = no monetary stake ⇒ consequence is reputation-only.
    pmPenaltyTo    : Maybe ℕ      -- account credited on default (the wronged party); nothing = forfeit
                                  -- (stake is burned — a pure deterrent).
    pmReferable    : Bool         -- П6/Inc1.2: may the OBLIGOR be reassigned (referral to a colleague)?
                                  -- Independent axis from pmTransferable (which gates RECIPIENT resale).
                                  -- Default false: a plain promise is bound to its obligor (the person
                                  -- promised, and does not consent to hand it off). Tier-1 (CMaybe CBool,
                                  -- nothing ⇒ false).

open Promise public
