{-# OPTIONS --without-K #-}

-- `Resource` — an addressable content node with a generic tree (cxm-plan.md Phase 6, §4.12) — [ВХ].
-- The core knows "there is a hierarchy of resources" but NOT that a node is a lesson/video/
-- medical-record/post — that is the pack's specialization. `rVisibility` is an OPAQUE policy
-- (§7.4): the audience-scoping check is a pluggable hook, not core RBAC. `rPayload` is opaque JSON.
module Cxm.Resource where

open import Data.Nat using (ℕ)
open import Data.String using (String)
open import Data.Maybe using (Maybe; just; nothing)

open import Cxm.Tenant using (TenantId)

-- conversation context of a comment node (§10; ONE value ⇒ no partial/illegal anchor states)
record ConvCtx : Set where
  constructor mkConvCtx
  field
    ccAnchorKind : String     -- anchor entity table (реестр в CommandsV.anchorRegistry)
    ccAnchorId   : ℕ
    ccStreamRoot : ℕ          -- policy-stream root (§10.5)
    ccLocator    : Maybe String   -- §10-хвост (П4-треб.1): ПОД-локация якоря — символ в тексте,
                                  -- секунда видео, точка на картине; opaque, интерпретирует
                                  -- клиент; ядро НЕ индексирует. Tier-1 (хвостовая CMaybe).
open ConvCtx public

record Resource : Set where
  constructor mkResource
  field
    rId         : ℕ
    rTenant     : TenantId
    rParent     : Maybe ℕ         -- parent_ref (tree); nothing = root. Indexed via 0-sentinel.
    rKind       : ℕ               -- config-driven node kind
    rOrder      : ℕ               -- sibling ordering
    rVisibility : Maybe String    -- opaque visibility_policy (§7.4); nothing = default
    rPayload    : String          -- opaque JSON (core does not index, §8.1)
    rCreatedAt  : ℕ
    rDeletedAt  : Maybe ℕ         -- soft-delete; nothing = live
    rAuthor     : Maybe ℕ         -- authoring subject (social content, §7.3); nothing =
                                  -- operator/system content. Appended Tier-1 (CMaybe).
    rListing    : Maybe String    -- who may SEE the node EXIST (catalog/feed/thread listing;
                                  -- same policy vocabulary as rVisibility); nothing = same as
                                  -- rVisibility. Storefront teaser = explicit "public" here
                                  -- while rVisibility="entitled" (S7). Tier-1 (CMaybe).
    -- conversations-from-anything (§10): a comment is a Resource ANCHORED to any entity.
    -- CORRECT BY CONSTRUCTION (аудит-2): the anchor kind/id and the stream root live in ONE
    -- Maybe — a kind without an id, or a stream root without an anchor, is UNREPRESENTABLE
    -- (they were, as three parallel Maybes). nothing = plain content, just = a conversation node.
    rConv       : Maybe ConvCtx
    rUpdatedAt  : Maybe ℕ         -- last edit time (blog hygiene, П2); nothing = never edited.
                                  -- Stamped ONLY by updateResource. Tier-1 (CMaybe).

open Resource public

-- derived accessors keep the old field names/types, so downstream reads are unchanged
rAnchorKind : Resource → Maybe String
rAnchorKind r = mapᵐ ccAnchorKind (rConv r)
  where mapᵐ : ∀ {A B : Set} → (A → B) → Maybe A → Maybe B
        mapᵐ f (just x) = just (f x)
        mapᵐ _ nothing  = nothing

rAnchorId : Resource → Maybe ℕ
rAnchorId r = mapᵐ ccAnchorId (rConv r)
  where mapᵐ : ∀ {A B : Set} → (A → B) → Maybe A → Maybe B
        mapᵐ f (just x) = just (f x)
        mapᵐ _ nothing  = nothing

rStreamRoot : Resource → Maybe ℕ
rStreamRoot r = mapᵐ ccStreamRoot (rConv r)
  where mapᵐ : ∀ {A B : Set} → (A → B) → Maybe A → Maybe B
        mapᵐ f (just x) = just (f x)
        mapᵐ _ nothing  = nothing

rAnchorLocator : Resource → Maybe String
rAnchorLocator r = joinᵐ (rConv r)
  where joinᵐ : Maybe ConvCtx → Maybe String
        joinᵐ (just c) = ccLocator c
        joinᵐ nothing  = nothing

------------------------------------------------------------------------
-- ResourceLink — the CURATION/REFERENCE graph between content nodes (cxm-social-plan §8):
-- distinct from the composition tree (rParent). A showcase/front-page node PINS arbitrary
-- nodes (clips of larger videos, promoted posts) with a curated rank and a VALIDITY WINDOW —
-- a sold promo slot is simply a link whose validTo is the paid-through time (the ad-space
-- sale seam: payment → linkResource with validTo; no new billing machinery). rlKind is DATA
-- ("pin"/"promo"/"related"/… — vocabulary is the pack's, not an enum).
------------------------------------------------------------------------

record ResourceLink : Set where
  constructor mkResourceLink
  field
    rlId        : ℕ
    rlTenant    : TenantId
    rlFrom      : ℕ            -- FK → resource (the showcase/collection node)
    rlTo        : ℕ            -- FK → resource (the pinned content)
    rlKind      : String       -- opaque link kind (pin/promo/related/…)
    rlRank      : ℕ            -- curated order within the showcase (asc)
    rlValidFrom : ℕ
    rlValidTo   : Maybe ℕ      -- nothing = open-ended; just t = paid-through/expiry
    rlCreatedAt : ℕ

open ResourceLink public

------------------------------------------------------------------------
-- Mention — the ORDERED addressees of a comment (§10 F3: «ответить нескольким, кому-то
-- первому»). A child table (§8.1 lists-are-child-rows, like Evidence): mOrd = 0 is the PRIMARY
-- addressee (mirrored into the comment event's eeCounterpart); the subject index makes the
-- mentions inbox («все ответы мне») one indexed lookup. Also covers @-mentions in plain posts.
------------------------------------------------------------------------

record Mention : Set where
  constructor mkMention
  field
    mId       : ℕ
    mResource : ℕ            -- FK → the commenting/mentioning node
    mSubject  : ℕ            -- FK → the addressed subject
    mOrd      : ℕ            -- 0 = primary addressee
    mTenant   : TenantId

open Mention public
