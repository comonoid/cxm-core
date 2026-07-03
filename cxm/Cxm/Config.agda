{-# OPTIONS --without-K #-}

-- Instance configuration (cxm-plan.md Phase 1, §9.9, §9.10, principle 12). The core is a
-- pure function of its config: an instance is `run(core, config)`. Storage handle, active
-- packs, tenant policy and seed data all arrive as a parameter at startup — there are NO
-- module-level mutable globals/singletons (principle 12). This module is a SKETCH: types +
-- constructors only. It reads no globals; gating of active packs is Phase 12.
module Cxm.Config where

open import Data.Nat using (ℕ)
open import Data.String using (String)
open import Data.List using (List)

open import Cxm.Tenant using (TenantId; Tenant)

------------------------------------------------------------------------
-- Tenant policy — how the instance uses the tenant axis (§7.1, §7.6)
------------------------------------------------------------------------

-- Soft isolation within one instance. SingleOperator collapses the axis to the default
-- tenant; MultiTenant keeps many operators on one core+store. (Instance-level isolation —
-- DB/WAL-per-instance, §9.9 — is a layer ABOVE the core, not modelled here.)
data TenantPolicy : Set where
  SingleOperator : TenantPolicy
  MultiTenant    : TenantPolicy

------------------------------------------------------------------------
-- Storage handle parameters (backend-agnostic; the repository-seam picks the backend)
------------------------------------------------------------------------

-- Just the parameters the core needs to hand to a storage backend. The WAL backend uses
-- `shWalPath`; a future Postgres backend would read its own fields here (§8.7). Kept as a
-- record so backends can grow fields without touching the core signature.
record StorageHandle : Set where
  constructor mkStorageHandle
  field
    shWalPath : String         -- path to the WAL file (WAL+memory backend, §9.3)

open StorageHandle public

------------------------------------------------------------------------
-- Instance config (principle 12)
------------------------------------------------------------------------

record InstanceConfig : Set where
  constructor mkInstanceConfig
  field
    cfgStorage       : StorageHandle
    cfgActivePacks   : List String      -- pack ids compiled in but activated per instance (§9.10)
    cfgTenantPolicy  : TenantPolicy
    cfgDefaultTenant : TenantId         -- which seeded tenant is the default (§9.8)
    -- seed data (§9.8: "the default tenant is seeded"). Phase-1 sketch: the tenants to seed
    -- into an empty Base at startup. `cfgDefaultTenant` names the default among them. Seeds of
    -- Protocol definitions / Offering catalogs (data-not-code, §9) are appended here in Phase 6,
    -- once those types exist — kept minimal now to avoid a forward dependency.
    cfgSeedTenants   : List Tenant
    -- API bearer-gate token ("" = open, loopback-only). In config so `run(core,config)` is fully
    -- config-driven (Phase-12 audit #A). Integration-token/JWT VERIFICATION stays an app hook
    -- (crypto lives at the edge). NB: `cfgTenantPolicy` is a forward placeholder — not yet
    -- consulted (multi-tenant runtime deferred, §9.8/§10) — audit #B.
    cfgApiToken      : String
    -- JWT signing secret for operator auth (/auth/login, /auth/me). In config so run(core,config)
    -- is complete. "" = a deploy without operator login (public/loopback only).
    cfgJwtSecret     : String

open InstanceConfig public
