{-# OPTIONS --without-K #-}

-- `Offering` — the catalog/sellable primitive (cxm-plan.md Phase 6, description §4.12) — [ВХ].
-- Records only (commands live in the command layer, to keep the store DAG acyclic: Wire→record,
-- Base→Wire, command→Base). Generic: a service, a course, a package, a paid subscription — the
-- `kind` is a config-driven code (differences are data, §9). Money is single-currency ℕ minor
-- units on the MVP (§9.7); `oCurrency` is carried but the Account stays currency-less.
module Cxm.Offering where

open import Data.Nat using (ℕ)
open import Data.String using (String)
open import Data.Maybe using (Maybe)

open import Cxm.Tenant using (TenantId)

record Offering : Set where
  constructor mkOffering
  field
    oId        : ℕ
    oTenant    : TenantId
    oKind      : ℕ            -- config-driven kind code (service/course/subscription/…)
    oPrice     : ℕ            -- minor units (kopecks)
    oCurrency  : String       -- ISO code; carried for later multi-currency (§4.15/§9.7)
    oMetadata  : String       -- opaque JSON (core does not index)
    oCreatedAt : ℕ
    oDeletedAt : Maybe ℕ      -- soft-delete; nothing = live

open Offering public
