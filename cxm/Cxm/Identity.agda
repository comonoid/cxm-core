{-# OPTIONS --without-K #-}

-- `Identity` — binding of channel identifiers to a subject (cxm-plan.md Phase 2, §4.4).
-- Stitches e-mail / phone / user_id / cookie / messenger account into one `Subject`. This
-- is the heart of identity resolution and omnichannel: without it experience shatters into
-- per-channel fragments and peak/end/expectation cannot be computed.
--
-- The core STORES the identity links (first-class); the MATCHING STRATEGY is a hook, not
-- core — heuristics (email normalization, cookie↔user_id merge, fuzzy phone) are a
-- domain/channel-dependent swappable layer at the edge. The core accepts a ready decision
-- "these ids = one subject" (as a command); how that decision is made is pluggable (§4.4).
--
-- PERF NOTE (audit finding #3): lookup by (channel, external_id) — the per-event ingest hot
-- path (§7.7) — is a table scan, because both are String columns and `Schema` indexes only
-- ℕ-valued columns. Acceptable on the WAL+in-memory MVP (cf. CRM findUserByLogin, §8.7); a
-- Postgres backend needs a btree index on (channel, external_id). Only `subject` is indexed
-- here (the reverse "all identities of a subject" lookup).
module Cxm.Identity where

open import Data.Nat using (ℕ)
open import Data.String using (String)
open import Data.Bool using (Bool)

open import Cxm.Tenant using (TenantId)

record Identity : Set where
  constructor mkIdentity
  field
    iId         : ℕ                 -- internal primary key
    iSubject    : ℕ                 -- FK → subject
    iChannel    : String            -- "email" | "phone" | "cookie" | "user_id" | "telegram" | …
    iExternalId : String            -- the channel-specific identifier
    iVerified   : Bool              -- has the binding been verified (e.g. confirmed email)?
    iTenant     : TenantId          -- §7.1 tenant axis
    iCreatedAt  : ℕ

open Identity public
