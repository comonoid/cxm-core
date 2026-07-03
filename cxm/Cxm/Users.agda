{-# OPTIONS --without-K #-}

-- `User` (auth principal) + `RoleAssignment` (RBAC data) — cxm-plan.md Phase 6, §4.15 — [ВХ].
-- Ported from CRM with the tenant axis added. IMPORTANT (§4.15): `User` (operator) ≠ `Subject`
-- (client) — the staff that RUN the system vs the clients whose experience is managed.
-- `RoleAssignment.raScope` is already the per-tenant delegation mechanism (align scope with the
-- tenant axis; the `canAssign` gate is at the Api level, Phase 8). Records only; the policy +
-- checks live in agdelte-auth (RBAC.Scoped). `uPassHash` is opaque (hashing at the IO boundary).
module Cxm.Users where

open import Data.Nat using (ℕ)
open import Data.String using (String)

open import Cxm.Tenant using (TenantId)

record User : Set where
  constructor mkUser
  field
    uId        : ℕ
    uTenant    : TenantId
    uLogin     : String          -- the RBAC subject (ties to RoleAssignment.raSubject)
    uPassHash  : String          -- bcrypt hash (opaque; hashed at the IO boundary)
    uCreatedAt : ℕ

open User public

record RoleAssignment : Set where
  constructor mkAssignment
  field
    raId        : ℕ
    raTenant    : TenantId
    raSubject   : String          -- principal id (= uLogin)
    raRoleId    : String          -- RBAC role
    raScope     : String          -- "/"-path scope ("" = global; align with tenant, §4.15)
    raCreatedAt : ℕ

open RoleAssignment public
