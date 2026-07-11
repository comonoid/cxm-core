{-# OPTIONS --without-K #-}

-- Cxm.Social — the social-content reads (cxm-social-plan S3; design §7.3/§7.4 закладки).
-- LAYER L5 (pure [ПР] projections over snapshots) — docs/MODULES.md.
--
-- НАЗНАЧЕНИЕ: the three deferred social seams, now real: (1) the follow graph read
-- (`followsᵇ` over generic `follow` SubjectEdges); (2) the ACCESS POLICY as one total
-- function (`canAccess`) over `Resource.rVisibility` DATA strings; (3) the FEED as a pure
-- projection (`feedOf`) — no materialized feed, rebuild-from-scratch by construction.
--
-- ПОЛИТИКИ ДОСТУПА (данные, не enum — differences are data): nothing/"public" = everyone;
-- "followers" = live followers of the author; "entitled" = holders of a live TResource
-- Entitlement on this resource (= SOLD access — the sell-your-content seam; granting is the
-- payments/operator side). UNKNOWN policy ⇒ deny (closed by default). The author always
-- sees their own. Authorless (operator) content follows the same policies, with
-- "followers" degenerating to deny (no author to follow).
--
-- ИНВАРИАНТЫ: total; pure over lists (store read path passes `tscan`); deleted resources
-- are invisible to the feed; feed is newest-first. Merge aliases: pass CANONICAL subject
-- ids (Cxm.Commands.canonicalOf), as everywhere in L5.
-- ЗАПРЕТЫ (Г4): no Cxm.Store.* / Cxm.Commands / FFI imports.
module Cxm.Social where

open import Data.Nat using (ℕ; _≡ᵇ_; _≤ᵇ_; _<ᵇ_)
open import Data.Bool using (Bool; true; false; if_then_else_; _∧_; _∨_; not)
open import Data.Maybe using (Maybe; just; nothing; maybe′)
open import Data.List using (List; []; _∷_; foldr)
open import Data.String using (String)
open import Agda.Builtin.String using (primStringEquality)

open import Cxm.Edge using (SubjectEdge; seFrom; seTo; seKind; seValidFrom; seValidTo
                           ; EdgeKind; follow)
open import Cxm.Entitlement using (Entitlement; enSubject; enTargetKind; enTarget
                                  ; enValidFrom; enValidTo; EntTarget; TResource)
open import Cxm.Resource using (Resource; rId; rParent; rAuthor; rVisibility; rListing; rAnchorKind; rCreatedAt; rDeletedAt; Mention; mSubject; mResource)
import Cxm.AccessPolicy as AP

private
  isFollow : EdgeKind → Bool
  isFollow follow = true
  isFollow _      = false

  isTResource : EntTarget → Bool
  isTResource TResource = true
  isTResource _         = false

  liveWindow : (now vf : ℕ) → Maybe ℕ → Bool           -- vf ≤ now ≤ vt (vt missing = open)
  liveWindow now vf vt = (vf ≤ᵇ now) ∧ maybe′ (λ t → now ≤ᵇ t) true vt

  anyᵇ : ∀ {A : Set} → (A → Bool) → List A → Bool
  anyᵇ p = foldr (λ x acc → p x ∨ acc) false

-- does `viewer` follow `author` right now? (a live follow edge viewer→author)
followsᵇ : (now viewer author : ℕ) → List SubjectEdge → Bool
followsᵇ now viewer author = anyᵇ ok
  where ok : SubjectEdge → Bool
        ok e = isFollow (seKind e) ∧ (seFrom e ≡ᵇ viewer) ∧ (seTo e ≡ᵇ author)
             ∧ liveWindow now (seValidFrom e) (seValidTo e)

-- does `viewer` hold a live TResource grant on resource `rid`? (the sold-access check)
entitledᵇ : (now viewer rid : ℕ) → List Entitlement → Bool
entitledᵇ now viewer rid = anyᵇ ok
  where ok : Entitlement → Bool
        ok en = isTResource (enTargetKind en) ∧ (enSubject en ≡ᵇ viewer) ∧ (enTarget en ≡ᵇ rid)
              ∧ liveWindow now (enValidFrom en) (enValidTo en)

private
  findRᵖ : ℕ → List Resource → Maybe Resource
  findRᵖ _ [] = nothing
  findRᵖ i (r ∷ rest) = if rId r ≡ᵇ i then just r else findRᵖ i rest

-- grant INHERITS down the tree (selling a SECTION/course/doc set with ONE grant on its root):
-- viewer is entitled to a node iff they hold a grant on it OR ANY ANCESTOR. Fuel-bounded walk
-- up rParent (snapshot size bounds the chain; a parent cycle just exhausts fuel → deny).
entitledUpᵇ : (now viewer : ℕ) → List Entitlement → List Resource → Resource → Bool
entitledUpᵇ now viewer ents rs r0 = go (lengthᵣ rs) r0
  where
    lengthᵣ : List Resource → ℕ
    lengthᵣ = foldr (λ _ n → ℕ.suc n) 0
    go : ℕ → Resource → Bool
    go 0 r = entitledᵇ now viewer (rId r) ents
    go (ℕ.suc fuel) r =
      entitledᵇ now viewer (rId r) ents
      ∨ maybe′ (λ pid → maybe′ (go fuel) false (findRᵖ pid rs)) false (rParent r)

-- THE access policy (закладка §7.4, one total function): see the module header for the
-- policy table. `viewer = nothing` is an anonymous read (public only). The snapshot `rs` is
-- needed for grant INHERITANCE ("entitled" checks the node and its ancestors — buying a tree
-- root sells the whole section/course/doc set).
-- Access = author-sees-own ∨ the owner's policy (advanced policy-as-data, RB2). `rVisibility`
-- nothing ⇒ default "public"; the presets are single-atom policies so behaviour is preserved.
-- `compilePolicy` FAIL-CLOSES: malformed/unsafe ⇒ nothing ⇒ deny (never expose on a typo).
canAccess : (now : ℕ) (viewer : Maybe ℕ) → List SubjectEdge → List Entitlement
          → List Resource → Resource → Bool
canAccess now viewer edges ents rs r = authorSeesOwn ∨ maybe′ (AP.eval (decider viewer)) false (AP.compilePolicy policyStr)
  where
    policyStr : String
    policyStr = maybe′ (λ p → p) "public" (rVisibility r)
    authorSeesOwn : Bool
    authorSeesOwn = maybe′ (λ a → maybe′ (λ v → a ≡ᵇ v) false viewer) false (rAuthor r)
    decider : Maybe ℕ → AP.Atom → Bool
    decider _        AP.aPublic    = true
    decider (just v) AP.aFollowers = maybe′ (λ a → followsᵇ now v a edges) false (rAuthor r)
    decider (just v) AP.aEntitled  = entitledUpᵇ now v ents rs r
    decider (just v) (AP.aSub n)   = v ≡ᵇ n
    decider (just v) (AP.aNode n)  = entitledᵇ now v n ents
    decider nothing  _             = false

-- the FEED projection (закладка: feed-as-projection): live resources authored by subjects the
-- viewer follows (plus their own), access-filtered, newest-first.
feedOf : (now viewer : ℕ) → List SubjectEdge → List Entitlement → List Resource → List Resource
feedOf now viewer edges ents rsAll = foldr step [] rsAll
  where
    liveᵇ : Resource → Bool
    liveᵇ r = maybe′ (λ _ → false) true (rDeletedAt r)
    fromFeedAuthor : Resource → Bool
    fromFeedAuthor r = maybe′ (λ a → (a ≡ᵇ viewer) ∨ followsᵇ now viewer a edges) false (rAuthor r)
    wanted : Resource → Bool
    wanted r = liveᵇ r ∧ fromFeedAuthor r ∧ canAccess now (just viewer) edges ents rsAll r
    insDesc : Resource → List Resource → List Resource      -- newest (max createdAt) first
    insDesc x [] = x ∷ []
    insDesc x (y ∷ ys) = if rCreatedAt y ≤ᵇ rCreatedAt x then x ∷ y ∷ ys else y ∷ insDesc x ys
    step : Resource → List Resource → List Resource
    step r acc = if wanted r then insDesc r acc else acc

------------------------------------------------------------------------
-- Thread tree (cxm-social-plan §2): a post's comment tree, REBUILT from the snapshot on every
-- read — there is no denormalized tree to go stale, which is what "the tree restructures
-- itself" means server-side (the reactive-island frontend re-renders it by keys). Children are
-- ordered oldest-first (a conversation reads top-down); depth-first flattening with depth tags
-- keeps the core JSON flat and lets any client rebuild indentation.
------------------------------------------------------------------------

record ThreadNode : Set where
  constructor mkThreadNode
  field
    tnDepth    : ℕ          -- 0 = the root post
    tnResource : Resource
open ThreadNode public

private
  childrenOf : (parent : ℕ) → List Resource → List Resource
  childrenOf pid rs = foldr step [] rs
    where
      isChild : Resource → Bool
      isChild r = maybe′ (λ p → p ≡ᵇ pid) false (rParentOf r)
        where rParentOf : Resource → Maybe ℕ
              rParentOf = Cxm.Resource.rParent
      insAsc : Resource → List Resource → List Resource    -- oldest-first
      insAsc x [] = x ∷ []
      insAsc x (y ∷ ys) = if rCreatedAt x ≤ᵇ rCreatedAt y then x ∷ y ∷ ys else y ∷ insAsc x ys
      step : Resource → List Resource → List Resource
      step r acc = if isChild r then insAsc r acc else acc

-- the thread under `root`, depth-first, access-filtered (a hidden node hides its subtree —
-- closed by default), fuel-bounded by the snapshot size (structural recursion for the checker)
threadOf : (now : ℕ) (viewer : Maybe ℕ) → List SubjectEdge → List Entitlement
         → (root : ℕ) → List Resource → List ThreadNode
threadOf now viewer edges ents root rs = go (lengthOf rs) 0 root
  where
    lengthOf : List Resource → ℕ
    lengthOf = foldr (λ _ n → ℕ.suc n) 0
    findR : ℕ → List Resource → Maybe Resource
    findR _ [] = nothing
    findR i (r ∷ rest) = if rId r ≡ᵇ i then just r else findR i rest
    okᵇ : Resource → Bool
    okᵇ r = maybe′ (λ _ → false) true (rDeletedAt r) ∧ canAccess now viewer edges ents rs r
    go : (fuel depth id : ℕ) → List ThreadNode
    go 0 _ _ = []
    go (ℕ.suc fuel) depth i = maybe′ node [] (findR i rs)
      where
        kids : Resource → List ThreadNode
        kids r = foldr (λ c acc → go fuel (ℕ.suc depth) (rId c) Data.List.++ acc) []
                       (childrenOf (rId r) rs)
        node : Resource → List ThreadNode
        node r = if okᵇ r then mkThreadNode depth r ∷ kids r else []

------------------------------------------------------------------------
-- S7 — listing ≠ reading (нюанс: «оглавление видно, текст заперт»). `rListing` (nothing =
-- same as rVisibility) gates EXISTENCE in feeds/threads/catalogs; `canAccess` still gates the
-- payload. listed ∧ ¬readable ⇒ a LOCKED teaser (the Api strips the payload). An unlisted node
-- hides its subtree; a listed-locked node still lists its children (their own policies rule).
------------------------------------------------------------------------

-- same policy machinery, applied to the LISTING policy (fallback: the content policy)
canList : (now : ℕ) (viewer : Maybe ℕ) → List SubjectEdge → List Entitlement
        → List Resource → Resource → Bool
canList now viewer edges ents rs r =
  canAccess now viewer edges ents rs (relabel r)
  where
    relabel : Resource → Resource
    relabel x = record x { rVisibility = maybe′ just (rVisibility x) (rListing x) }

record ContentView : Set where
  constructor mkContentView
  field
    cvLocked   : Bool        -- listed but NOT readable → teaser (payload must be stripped)
    cvResource : Resource
open ContentView public

-- feed with the storefront semantics: membership by LISTING, lockedness by READING
feedViews : (now viewer : ℕ) → List SubjectEdge → List Entitlement → List Resource → List ContentView
feedViews now viewer edges ents rsAll = foldr step [] rsAll
  where
    liveᵇ : Resource → Bool
    liveᵇ r = maybe′ (λ _ → false) true (rDeletedAt r)
    fromFeedAuthor : Resource → Bool
    fromFeedAuthor r = maybe′ (λ a → (a ≡ᵇ viewer) ∨ followsᵇ now viewer a edges) false (rAuthor r)
    -- аудит-фикс: the feed shows CONTENT, not conversation nodes (anchored comments excluded)
    isContentᵇ : Resource → Bool
    isContentᵇ r = maybe′ (λ _ → false) true (rAnchorKind r)
    wanted : Resource → Bool
    wanted r = liveᵇ r ∧ isContentᵇ r ∧ fromFeedAuthor r ∧ canList now (just viewer) edges ents rsAll r
    view : Resource → ContentView
    view r = mkContentView (not (canAccess now (just viewer) edges ents rsAll r)) r
    insDesc : ContentView → List ContentView → List ContentView
    insDesc x [] = x ∷ []
    insDesc x (y ∷ ys) = if rCreatedAt (cvResource y) ≤ᵇ rCreatedAt (cvResource x)
                         then x ∷ y ∷ ys else y ∷ insDesc x ys
    step : Resource → List ContentView → List ContentView
    step r acc = if wanted r then insDesc (view r) acc else acc

-- mentions inbox — «все ответы мне»: узлы, где viewer в addressees (child-таблица Mention,
-- §8.1). Feed-семантика S7: live + canList (listing), locked = ¬canAccess, newest-first.
-- (Долг слоистости 2026-07-12: переехало из серверного слоя — братья feedViews/threadViews
-- живут здесь.)
mentionViews : (now viewer : ℕ) → List Mention → List SubjectEdge → List Entitlement
             → List Resource → List ContentView
mentionViews now viewer ms edges ents rsAll = foldr step [] rsAll
  where
    liveᵇ : Resource → Bool
    liveᵇ r = maybe′ (λ _ → false) true (rDeletedAt r)
    mineᵇ : ℕ → Bool
    mineᵇ rid = foldr (λ mn acc → ((mSubject mn ≡ᵇ viewer) ∧ (mResource mn ≡ᵇ rid)) ∨ acc) false ms
    wanted : Resource → Bool
    wanted r = liveᵇ r ∧ mineᵇ (rId r) ∧ canList now (just viewer) edges ents rsAll r
    view : Resource → ContentView
    view r = mkContentView (not (canAccess now (just viewer) edges ents rsAll r)) r
    insDesc : ContentView → List ContentView → List ContentView
    insDesc x [] = x ∷ []
    insDesc x (y ∷ ys) = if rCreatedAt (cvResource y) ≤ᵇ rCreatedAt (cvResource x)
                         then x ∷ y ∷ ys else y ∷ insDesc x ys
    step : Resource → List ContentView → List ContentView
    step r acc = if wanted r then insDesc (view r) acc else acc

record ThreadView : Set where
  constructor mkThreadView
  field
    tvDepth  : ℕ
    tvLocked : Bool
    tvResource : Resource
open ThreadView public

threadViews : (now : ℕ) (viewer : Maybe ℕ) → List SubjectEdge → List Entitlement
            → (root : ℕ) → List Resource → List ThreadView
threadViews now viewer edges ents root rs = go (lengthᵗ rs) 0 root
  where
    lengthᵗ : List Resource → ℕ
    lengthᵗ = foldr (λ _ n → ℕ.suc n) 0
    childrenAsc : ℕ → List Resource
    childrenAsc pid = foldr step [] rs
      where
        insAsc : Resource → List Resource → List Resource
        insAsc x [] = x ∷ []
        insAsc x (y ∷ ys) = if rCreatedAt x ≤ᵇ rCreatedAt y then x ∷ y ∷ ys else y ∷ insAsc x ys
        step : Resource → List Resource → List Resource
        step r acc = if maybe′ (λ p → p ≡ᵇ pid) false (rParent r) then insAsc r acc else acc
    go : (fuel depth id : ℕ) → List ThreadView
    go 0 _ _ = []
    go (ℕ.suc fuel) depth i = maybe′ node [] (findRᵖ i rs)
      where
        listedᵇ okᵇ : Resource → Bool
        listedᵇ r = maybe′ (λ _ → false) true (rDeletedAt r) ∧ canList now viewer edges ents rs r
        okᵇ r = canAccess now viewer edges ents rs r
        kids : Resource → List ThreadView
        kids r = foldr (λ c acc → go fuel (ℕ.suc depth) (rId c) Data.List.++ acc) []
                       (childrenAsc (rId r))
        node : Resource → List ThreadView
        node r = if listedᵇ r then mkThreadView depth (not (okᵇ r)) r ∷ kids r else []

------------------------------------------------------------------------
-- Showcase (§8: главная/витрина/промо): the CURATED read over ResourceLinks from a showcase
-- node — live-window links (an expired paid slot vanishes by projection, no worker needed),
-- rank-ascending, each target rendered with the same listing/locked semantics as the feed.
------------------------------------------------------------------------

open import Cxm.Resource using (ResourceLink; rlFrom; rlTo; rlRank; rlValidFrom; rlValidTo)

showcaseViews : (now : ℕ) (viewer : Maybe ℕ) → List SubjectEdge → List Entitlement
              → List ResourceLink → (from : ℕ) → List Resource → List ContentView
showcaseViews now viewer edges ents links from rs = strip (sortR (gather links))
  where
    open import Data.Product using (_×_; _,_; proj₁; proj₂)
    liveᵇ : Resource → Bool
    liveᵇ r = maybe′ (λ _ → false) true (rDeletedAt r)
    viewOf : ResourceLink → Maybe ContentView
    viewOf l with (rlFrom l ≡ᵇ from) ∧ liveWindow now (rlValidFrom l) (rlValidTo l)
    ... | false = nothing
    ... | true with findRᵖ (rlTo l) rs
    ...   | nothing = nothing
    ...   | just r = if liveᵇ r ∧ canList now viewer edges ents rs r
                     then just (mkContentView (not (canAccess now viewer edges ents rs r)) r)
                     else nothing
    gather : List ResourceLink → List (ℕ × ContentView)
    gather = foldr (λ l acc → maybe′ (λ v → (rlRank l , v) ∷ acc) acc (viewOf l)) []
    insR : (ℕ × ContentView) → List (ℕ × ContentView) → List (ℕ × ContentView)
    insR x [] = x ∷ []
    insR x (y ∷ ys) = if proj₁ x ≤ᵇ proj₁ y then x ∷ y ∷ ys else y ∷ insR x ys
    sortR : List (ℕ × ContentView) → List (ℕ × ContentView)
    sortR = foldr insR []
    strip : List (ℕ × ContentView) → List ContentView
    strip = foldr (λ p acc → proj₂ p ∷ acc) []
