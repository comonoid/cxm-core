{-# OPTIONS --without-K #-}

-- Tenant axis (cxm-plan.md Phase 1, §9.8, description §7.1). The owner/tenant axis is
-- baked into the schema of every relevant entity from day one (principle 8: "expensive to
-- retrofit"). `TenantId = ℕ`, an FK onto a `Tenant` record. A default tenant is seeded so
-- the single-operator case collapses by ABSENCE of extra tenants, not by a mode switch
-- (principle 7). Multi-tenant runtime isolation is NOT implemented here — only the axis.
module Cxm.Tenant where

open import Data.Nat using (ℕ)
open import Data.String using (String)

-- FK target for the tenant column on every [ВХ]/[СОБ] entity.
TenantId : Set
TenantId = ℕ

-- The seeded default tenant. Single-operator instances only ever see this one; the field
-- exists everywhere so scaling to multi-tenant is data, not a schema change (§7.1).
defaultTenant : TenantId
defaultTenant = 1

record Tenant : Set where
  constructor mkTenant
  field
    tId        : ℕ             -- internal primary key (= TenantId)
    tName      : String        -- display / owner name
    tCreatedAt : ℕ             -- unix seconds (supplied from IO, §1)

open Tenant public
