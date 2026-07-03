{-# OPTIONS --without-K #-}

-- Umbrella module for agdelte-cxm: imports every core module so a single `agda Cxm/All.agda`
-- typechecks the whole library. Populated phase by phase (see ~/cxm-core/docs/cxm-plan.md).
-- Compile-time tests live under Cxm.Test.* (see Cxm.Test.All).
module Cxm.All where

-- Phase 1 — foundation: numbers, config, tenant, epistemic envelope.
open import Cxm.Num
open import Cxm.Tenant
open import Cxm.Config
open import Cxm.Knowledge

-- Phase 2 — subject, generic edge, identity.
open import Cxm.Subject
open import Cxm.Edge
open import Cxm.Identity

-- Phase 3 — experience event ([СОБ]) + domain bus/outbox.
open import Cxm.Event
open import Cxm.Bus

-- Phase 4 — collection child-tables + schemas/codecs for every record.
open import Cxm.Collections
open import Cxm.Wire

-- Phase 5 — store (pure part): Base/CxmOp/apply, op codec, Txn monad, repository seam.
-- The WAL backend (Cxm.Store.Wal) is IO (--guardedness) and lives in Cxm.AllIO, not here.
open import Cxm.Store.Base
open import Cxm.Store.Codec
open import Cxm.Txn
open import Cxm.Store.Interface

-- Phase 6 — domain-truth [ВХ] records, the pure Schedule primitive, and the command layer.
open import Cxm.Offering
open import Cxm.Fulfilment
open import Cxm.Resource
open import Cxm.Entitlement
open import Cxm.Account
open import Cxm.Payment
open import Cxm.Expectation
open import Cxm.Protocol
open import Cxm.Episode
open import Cxm.Users
open import Cxm.Appointment
open import Cxm.Schedule
open import Cxm.Commands

-- Phase 7 — projections [ПР] + inference (all in the Knowledge envelope; rebuild-from-scratch).
open import Cxm.Fact
open import Cxm.Hypothesis
open import Cxm.Trait
open import Cxm.RelationshipState
open import Cxm.Inference
open import Cxm.Projection
open import Cxm.Social

-- Phase 8 — Query / Decision APIs (pure). The headless HTTP Cxm.Api is IO (--guardedness) and
-- lives in Cxm.AllIO, not here.
open import Cxm.Query
open import Cxm.Decision

-- Phase 9 — site-integration bookmarks (pure core; the /v1 HTTP surface is in Cxm.Api / Cxm.AllIO).
open import Cxm.Site

-- Phase 10 — schema versioning + event-upcasting (min migration bookmark).
open import Cxm.Version

-- Phase 12 — cloud/config seams (pure gating; run(core,config) IO is in Cxm.Api / Cxm.AllIO).
open import Cxm.Instance
