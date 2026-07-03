{-# OPTIONS --without-K #-}

-- Site-integration bookmarks — the PURE core (cxm-plan.md Phase 9, §7.7). The operator's own
-- site is a first-class channel + API consumer + webhook target. These are the reusable,
-- testable pieces of the four mandatory bookmarks; the IO wiring (routes, CORS, ingest endpoint,
-- webhook delivery, token crypto) lives in Cxm.Api. NB: we implement the BOOKMARKS, not UI.
--
--   * findIdentityIn      — identity bridge: (channel, external_id) → subject (session ↔ Identity).
--   * resolveVia / eventsForCanonical — merge alias (§4.4): pre-login events read as one subject.
--   * IntegrationToken / tokenAuthorizes — scoped site credential (not a staff-JWT), path-scoped.
--   * webhookPayload      — the canonical message an outbound webhook HMAC-signs.
module Cxm.Site where

open import Data.Nat using (ℕ; _≡ᵇ_)
open import Data.Bool using (Bool; true; false; if_then_else_; _∧_)
open import Data.Maybe using (Maybe; just; nothing; maybe′)
open import Data.List using (List; []; _∷_; foldr)
open import Data.Char using (Char)
open import Data.String using (String; toList) renaming (_++_ to _<>_)
open import Agda.Builtin.String using (primStringEquality)
open import Agda.Builtin.Char using (primCharEquality)

open import Cxm.Identity using (Identity; iChannel; iExternalId; iSubject)
open import Cxm.Subject using (Subject; sId; sCanonical)
open import Cxm.Event using (ExperienceEvent; eeSubject)

------------------------------------------------------------------------
-- Identity bridge: resolve a channel identifier to a subject (lookup by scan — both String)
------------------------------------------------------------------------

findIdentityIn : (channel externalId : String) → List Identity → Maybe ℕ
findIdentityIn ch ext []       = nothing
findIdentityIn ch ext (i ∷ is) =
  if primStringEquality (iChannel i) ch ∧ primStringEquality (iExternalId i) ext
  then just (iSubject i)
  else findIdentityIn ch ext is

------------------------------------------------------------------------
-- Merge alias (§4.4): resolve a subject id to its canonical (one hop over a subject list), and
-- gather a canonical subject's UNIFIED experience — events on aliased (provisional) ids too. This
-- is why pre-login events remain visible after merge WITHOUT rewriting the append-only log.
------------------------------------------------------------------------

resolveVia : List Subject → ℕ → ℕ
resolveVia subs id = go subs
  where go : List Subject → ℕ
        go []       = id
        go (s ∷ ss) = if sId s ≡ᵇ id then maybe′ (λ c → c) id (sCanonical s) else go ss

eventsForCanonical : (canonical : ℕ) → List Subject → List ExperienceEvent → List ExperienceEvent
eventsForCanonical canon subs =
  foldr (λ ev acc → if resolveVia subs (eeSubject ev) ≡ᵇ canon then ev ∷ acc else acc) []

------------------------------------------------------------------------
-- Scoped integration token (a site-origin credential, NOT a staff-JWT). The signing/verifying
-- crypto is agdelte-auth (Cxm.Api); this is the payload + the path-scope check.
------------------------------------------------------------------------

record IntegrationToken : Set where
  constructor mkIntegrationToken
  field
    itOrigin : String      -- the site origin this credential is bound to
    itScope  : String      -- "/"-path RBAC scope granted to it

open IntegrationToken public

-- The STORE row for a minted integration token (runtime-minted, store-backed — §7.7, so operators
-- self-serve site credentials). `itkToken` is a bearer secret (generated at the IO edge);
-- `itkRevokedAt = nothing` ⇒ active. `verifyTokenIn` scans (few per instance).
record IntTokenRow : Set where
  constructor mkIntTokenRow
  field
    itkId        : ℕ
    itkTenant    : ℕ
    itkToken     : String     -- the bearer secret presented in X-Integration-Token
    itkScope     : String     -- path scope granted (→ IntegrationToken.itScope)
    itkOrigin    : String     -- bound site origin (→ IntegrationToken.itOrigin)
    itkCreatedAt : ℕ
    itkRevokedAt : Maybe ℕ    -- nothing = active; just t = revoked at t

open IntTokenRow public

-- resolve a presented bearer value to its scoped credential view, iff a matching row is ACTIVE
verifyTokenIn : String → List IntTokenRow → Maybe IntegrationToken
verifyTokenIn _ []       = nothing
verifyTokenIn t (r ∷ rs) =
  if primStringEquality (itkToken r) t ∧ active (itkRevokedAt r)
  then just (mkIntegrationToken (itkOrigin r) (itkScope r))
  else verifyTokenIn t rs
  where active : Maybe ℕ → Bool
        active nothing  = true
        active (just _) = false

private
  isPrefixL : List Char → List Char → Bool
  isPrefixL []       _        = true
  isPrefixL (_ ∷ _)  []       = false
  isPrefixL (x ∷ xs) (y ∷ ys) = if primCharEquality x y then isPrefixL xs ys else false

-- the token's scope covers a required scope iff it is a "/"-path prefix (parent covers child)
tokenAuthorizes : (required : String) → IntegrationToken → Bool
tokenAuthorizes required tok = isPrefixL (toList (itScope tok)) (toList required)

------------------------------------------------------------------------
-- Outbound webhook: the canonical message to HMAC-sign (topic ⊕ body). Delivery is an edge IO
-- adapter (Cxm.Api); the signature is `hmacSHA256 secret (webhookPayload topic body)`.
------------------------------------------------------------------------

webhookPayload : (topic body : String) → String
webhookPayload topic body = topic <> "." <> body
