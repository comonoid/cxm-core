{-# OPTIONS --without-K #-}

-- Cxm.Social refl tests (cxm-social-plan S3): the access matrix, the feed order/filters and
-- the thread assembly — all pure, so `refl` IS the test.
module Cxm.Test.SocialTest where

open import Relation.Binary.PropositionalEquality using (_≡_; refl)
open import Data.Maybe using (just; nothing)
open import Data.Bool using (true; false)
open import Data.List using (List; []; _∷_)
open import Data.Product using (_,_)

open import Cxm.Edge using (mkEdge; follow; participation)
open import Cxm.Entitlement using (mkEntitlement; TResource; TOffering; SGrant)
open import Cxm.Resource using (Resource; mkResource; rId; mkConvCtx)
open import Cxm.Social

-- graph: viewer 10 follows author 20 (live); 30 follows nobody
edges = mkEdge 1 10 20 follow nothing 0 0 nothing 1 0
      ∷ mkEdge 2 10 20 participation nothing 0 0 nothing 1 0   -- not a follow
      ∷ []

-- grants: subject 30 holds a live TResource grant on resource 102
ents = mkEntitlement 1 30 1 TResource 102 0 nothing SGrant 0
     ∷ mkEntitlement 2 30 1 TOffering 102 0 nothing SGrant 0   -- wrong kind
     ∷ []

-- content by author 20: public (100), followers (101), entitled (102), unknown policy (103)
rPub rFol rEnt rBad : Resource
rPub = mkResource 100 1 nothing 1 0 (just "public")    "{}" 50 nothing (just 20) nothing nothing nothing
rFol = mkResource 101 1 nothing 1 0 (just "followers") "{}" 60 nothing (just 20) nothing nothing nothing
rEnt = mkResource 102 1 nothing 1 0 (just "entitled")  "{}" 70 nothing (just 20) nothing nothing nothing
rBad = mkResource 103 1 nothing 1 0 (just "secret??")  "{}" 80 nothing (just 20) nothing nothing nothing

rEntChild : Resource
rEntChild = mkResource 110 1 (just 102) 1 0 (just "entitled") "{}" 75 nothing (just 20) nothing nothing nothing

allRs : List Resource
allRs = rPub ∷ rFol ∷ rEnt ∷ rBad ∷ rEntChild ∷ []

-- access matrix
_ : canAccess 99 nothing edges ents allRs rPub ≡ true          -- anonymous sees public
_ = refl
_ : canAccess 99 nothing edges ents allRs rFol ≡ false
_ = refl
_ : canAccess 99 (just 10) edges ents allRs rFol ≡ true        -- follower sees followers-only
_ = refl
_ : canAccess 99 (just 30) edges ents allRs rFol ≡ false       -- non-follower doesn't
_ = refl
_ : canAccess 99 (just 30) edges ents allRs rEnt ≡ true        -- grant-holder sees entitled
_ = refl
_ : canAccess 99 (just 10) edges ents allRs rEnt ≡ false       -- follower ≠ grant
_ = refl
_ : canAccess 99 (just 10) edges ents allRs rBad ≡ false       -- unknown policy = deny
_ = refl
_ : canAccess 99 (just 20) edges ents allRs rBad ≡ true        -- the author always sees their own
_ = refl

-- feed of viewer 10: follows 20 ⇒ public+followers, newest first; entitled/unknown hidden
_ : feedOf 99 10 edges ents (rPub ∷ rFol ∷ rEnt ∷ rBad ∷ []) ≡ rFol ∷ rPub ∷ []
_ = refl

-- feed of 30: follows nobody ⇒ empty (even the granted node — it's access, not feed membership)
_ : feedOf 99 30 edges ents (rPub ∷ rFol ∷ rEnt ∷ rBad ∷ []) ≡ []
_ = refl

-- thread: root post 200 with replies 201 (t=10) and 202 (t=5) → root, older reply first;
-- a followers-only reply is hidden from a non-follower WITH its subtree
post reply1 reply2 hidden subreply : Resource
post     = mkResource 200 1 nothing    1 0 (just "public") "{}" 1  nothing (just 20) nothing nothing nothing
reply1   = mkResource 201 1 (just 200) 1 0 (just "public") "{}" 10 nothing (just 30) nothing nothing nothing
reply2   = mkResource 202 1 (just 200) 1 0 (just "public") "{}" 5  nothing (just 10) nothing nothing nothing
hidden   = mkResource 203 1 (just 200) 1 0 (just "followers") "{}" 7 nothing (just 20) nothing nothing nothing
subreply = mkResource 204 1 (just 203) 1 0 (just "public") "{}" 8  nothing (just 30) nothing nothing nothing

thread = post ∷ reply1 ∷ reply2 ∷ hidden ∷ subreply ∷ []

_ : threadOf 99 (just 30) edges ents 200 thread
      ≡ mkThreadNode 0 post ∷ mkThreadNode 1 reply2 ∷ mkThreadNode 1 reply1 ∷ []
_ = refl

_ : threadOf 99 (just 10) edges ents 200 thread   -- follower sees the hidden branch + subtree
      ≡ mkThreadNode 0 post ∷ mkThreadNode 1 reply2 ∷ mkThreadNode 1 hidden
      ∷ mkThreadNode 2 subreply ∷ mkThreadNode 1 reply1 ∷ []
_ = refl

-- TREE SALE (продажа контента деревом): grant on the ROOT (102) unlocks the CHILD (110) —
-- documentation section / course sold with one entitlement (grant inheritance down the tree)
_ : canAccess 99 (just 30) edges ents allRs rEntChild ≡ true
_ = refl
_ : canAccess 99 (just 10) edges ents allRs rEntChild ≡ false   -- follower still can't
_ = refl

------------------------------------------------------------------------
-- S7 (аудит): listing ≠ reading — canList / feedViews / threadViews
------------------------------------------------------------------------

-- shop-window node: content entitled, but LISTED publicly
rShop : Resource
rShop = mkResource 120 1 nothing 1 0 (just "entitled") "{\"paid\":1}" 90 nothing (just 20) (just "public") nothing nothing

allRs2 : List Resource
allRs2 = rShop ∷ allRs

-- stranger 30 has no grant on 120: cannot READ, but CAN LIST (teaser)
_ : canAccess 99 (just 30) edges ents allRs2 rShop ≡ false
_ = refl
_ : canList 99 (just 30) edges ents allRs2 rShop ≡ true
_ = refl
-- node WITHOUT listing (rEnt): fallback to content policy ⇒ not listed for stranger 10
_ : canList 99 (just 10) edges ents allRs2 rEnt ≡ false
_ = refl

-- feedViews of follower 10: rShop enters LOCKED (listed, unreadable), rFol readable
_ : feedViews 99 10 edges ents (rShop ∷ rFol ∷ [])
      ≡ mkContentView true rShop ∷ mkContentView false rFol ∷ []
_ = refl

-- threadViews: a listed-locked node SHOWS (locked) and its children are evaluated
shopReply : Resource
shopReply = mkResource 121 1 (just 120) 1 0 (just "public") "{}" 95 nothing (just 30) nothing nothing nothing
_ : threadViews 99 (just 30) edges ents 120 (rShop ∷ shopReply ∷ [])
      ≡ mkThreadView 0 true rShop ∷ mkThreadView 1 false shopReply ∷ []
_ = refl

------------------------------------------------------------------------
-- S8 (аудит): showcaseViews — ранги, окно validTo, тизер
------------------------------------------------------------------------

open import Cxm.Resource using (ResourceLink; mkResourceLink)

links : List ResourceLink
links = mkResourceLink 1 1 500 100 "pin"   2 0 nothing   0     -- rank 2 → public post
      ∷ mkResourceLink 2 1 500 120 "pin"   1 0 nothing   0     -- rank 1 → locked shop node
      ∷ mkResourceLink 3 1 500 101 "promo" 0 0 (just 50) 0     -- rank 0, EXPIRES at t=50
      ∷ mkResourceLink 4 1 999 103 "pin"   0 0 nothing   0     -- другой узел-витрина — не наш
      ∷ []

-- at t=40 the promo is still live: promo(0) → shop(1, locked) → post(2)
_ : showcaseViews 40 (just 10) edges ents links 500 allRs2
      ≡ mkContentView false rFol ∷ mkContentView true rShop ∷ mkContentView false rPub ∷ []
_ = refl

-- at t=99 the paid slot EXPIRED: only shop + post remain, rank order kept
_ : showcaseViews 99 (just 10) edges ents links 500 allRs2
      ≡ mkContentView true rShop ∷ mkContentView false rPub ∷ []
_ = refl

-- аудит-фикс: anchored узел (коммент) НЕ попадает в ленту как контент
rComment : Resource
rComment = mkResource 130 1 nothing 1 0 (just "public") "{}" 91 nothing (just 20) nothing (just (mkConvCtx "appointment" 7 130)) nothing
_ : feedViews 99 10 edges ents (rComment ∷ rPub ∷ []) ≡ mkContentView false rPub ∷ []
_ = refl
