{-# OPTIONS --without-K #-}

-- Cloud / config seams (cxm-plan.md Phase 12, §7.6, §9.9, §9.10, principle 12). This phase is
-- VERIFY, not implement: the pieces here are the pure config-driven gating, and the rest is
-- documented as a layer ABOVE the core.
--
-- Principle 12 — the core is a PURE FUNCTION of its config. An instance is `run(core, config)`:
-- the WAL path, active packs, tenant policy, default tenant and seeds all arrive via
-- `InstanceConfig` (Cxm.Config). There are NO module-level mutable globals/singletons anywhere
-- in the core (verified: no postulate/IORef/unsafePerform in Cxm/*, only pure defs + IO that
-- takes its handle/config as a parameter). The IO `run(core, config)` itself is `Cxm.Api.runInstance`.
--
-- §9.10 homogeneous vs heterogeneous cloud = ONE mechanism: ALL packs are compiled into the
-- single binary; the instance config picks a SUBSET (`cfgActivePacks`). An inactive pack's data
-- maps are simply EMPTY (absence of data), NOT a code branch — the unified `Base`/`CxmOp`
-- (principle 7) covers every compiled pack. Activation gates ROUTES/protocols, not the state type.
--
-- Documented, NOT implemented (a layer above the core, §7.6):
--   * control plane — provisioning / instance registry / orchestration;
--   * isolation (§9.9) — DB/WAL-per-instance is the default (esp. for regulated data); the core
--     only takes a storage handle from config, it does not know it is "one of many";
--   * custom domains — edge routing above the instance;
--   * cross-instance identity / SSO — deliberately OFF by default (each instance is its own
--     trust/data boundary); a cloud only makes optional linkage POSSIBLE later, it is not on.
module Cxm.Instance where

open import Data.Bool using (Bool; false; _∨_)
open import Data.List using (List; foldr)
open import Data.String using (String)
open import Agda.Builtin.String using (primStringEquality)

open import Cxm.Config using (InstanceConfig; cfgActivePacks)

-- is a pack activated for this instance? (membership in the config's active-packs subset, §9.10)
packActive : InstanceConfig → String → Bool
packActive cfg pid = foldr (λ p acc → primStringEquality pid p ∨ acc) false (cfgActivePacks cfg)
