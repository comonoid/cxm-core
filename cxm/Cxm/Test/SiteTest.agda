{-# OPTIONS --without-K #-}

-- Compile-time tests for the site-integration bookmarks' pure core (Phase 9, §7.7). The full
-- HTTP end-to-end (anon event → provisional → login → merge → unified query) and the HMAC
-- webhook run in the runtime harness; here we prove the pure logic those endpoints stand on:
-- identity resolution, the merge-alias unified-experience read, and token scoping.
module Cxm.Test.SiteTest where

open import Relation.Binary.PropositionalEquality using (_≡_; refl)
open import Data.Maybe using (just; nothing)
open import Data.Bool using (true; false)
open import Data.List using (List; []; _∷_)
open import Data.String using () renaming (_++_ to _<>_)

open import Cxm.Identity using (Identity; mkIdentity)
open import Cxm.Subject using (Subject; mkSubject; EXTERNAL; Person)
open import Cxm.Event using (ExperienceEvent; mkExperienceEvent; Web; Client; View)
open import Cxm.Site

-- identity bridge: (channel, external_id) → subject
id1 id2 : Identity
id1 = mkIdentity 1 10 "cookie" "abc" false 1 0     -- cookie abc → subject 10 (provisional session)
id2 = mkIdentity 2 20 "user_id" "u42" true 1 0     -- user_id u42 → subject 20 (canonical account)

_ : findIdentityIn "cookie" "abc" (id1 ∷ id2 ∷ []) ≡ just 10
_ = refl
_ : findIdentityIn "user_id" "u42" (id1 ∷ id2 ∷ []) ≡ just 20
_ = refl
_ : findIdentityIn "cookie" "zzz" (id1 ∷ id2 ∷ []) ≡ nothing
_ = refl

-- merge alias (§4.4): provisional subject 10 is merged into canonical 20
prov canon : Subject
prov  = mkSubject 10 EXTERNAL Person "anon" "UTC" 0 nothing 1 nothing (just 20) true
canon = mkSubject 20 EXTERNAL Person "acct" "UTC" 0 nothing 1 nothing nothing false

_ : resolveVia (prov ∷ canon ∷ []) 10 ≡ 20     -- provisional resolves to canonical
_ = refl
_ : resolveVia (prov ∷ canon ∷ []) 20 ≡ 20     -- canonical resolves to itself
_ = refl
_ : resolveVia (prov ∷ canon ∷ []) 99 ≡ 99     -- unknown resolves to itself

_ = refl

-- pre-login events (on provisional 10) are visible when querying the canonical 20 — WITHOUT
-- rewriting the append-only log. This is the whole point of the identity bridge.
evP evC evX : ExperienceEvent
evP = mkExperienceEvent 1 10 1 Web Client 100 View 0 nothing nothing nothing nothing false false "{}" nothing
evC = mkExperienceEvent 2 20 1 Web Client 200 View 0 nothing nothing nothing nothing false false "{}" nothing
evX = mkExperienceEvent 3 99 1 Web Client 300 View 0 nothing nothing nothing nothing false false "{}" nothing

_ : eventsForCanonical 20 (prov ∷ canon ∷ []) (evP ∷ evC ∷ evX ∷ []) ≡ evP ∷ evC ∷ []
_ = refl

-- scoped integration token: scope "/v1" covers "/v1" and "/v1/events", not "/admin"
tok : IntegrationToken
tok = mkIntegrationToken "site.example" "/v1"

_ : tokenAuthorizes "/v1" tok ≡ true
_ = refl
_ : tokenAuthorizes "/v1/events" tok ≡ true
_ = refl
_ : tokenAuthorizes "/admin" tok ≡ false
_ = refl

-- webhook canonical payload
_ : webhookPayload "payment.succeeded" "{\"id\":1}" ≡ "payment.succeeded" <> "." <> "{\"id\":1}"
_ = refl
