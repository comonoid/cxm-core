{-# OPTIONS --without-K #-}

-- Compile-time reference handler for the FULL verb layer + refl smoke of its laws.
-- State = a FUNCTION (t : TableCode) → assoc list of Val t (dependent override via _≟_), so one
-- small handler covers all 28 tables. Pinned here: find-or-create through the ergonomic layer,
-- the lock discipline (breach ⇒ abort; lockRoot of absent row ⇒ abort, audit A3), and the
-- lockRoots combinator producing the SAME canonical lock order for ANY argument order.
module Cxm.Store.VerbsTest where

open import Agda.Builtin.String using (String; primStringEquality)
open import Agda.Builtin.Unit using (⊤; tt)
open import Data.Bool using (Bool; true; false; if_then_else_; _∨_; _∧_)
open import Data.List using (List; []; _∷_)
open import Data.Maybe using (Maybe; just; nothing)
open import Data.Nat using (ℕ; _≡ᵇ_; _≤ᵇ_; _<ᵇ_; _+_; suc)
open import Data.Product using (_×_; _,_)
open import Data.Sum using (_⊎_; inj₁; inj₂)
open import Relation.Binary.PropositionalEquality using (_≡_; refl)

open import Data.Nat.Show using (show)
open import Data.String using () renaming (_++_ to _<>_)
open import Cxm.Subject using (Subject; mkSubject; sId; sTenant; sCanonical; sProvisional; EXTERNAL; Person)
open import Cxm.Edge using (SubjectEdge; mkEdge; seId; seFrom; seTo; participation)
open import Cxm.Resource using (Resource; mkResource; rId; ResourceLink; rlId; Mention; mId)
open import Cxm.Payment using (paySubject)
open import Cxm.Expectation using (xpSubject; pmSubject)
open import Cxm.Event using (ExperienceEvent; eeId; eeSubject; eePayload)
open import Cxm.Identity using (Identity; mkIdentity; iId; iSubject; iChannel; iExternalId; iVerified)
open import Cxm.Bus using (OutboxEntry; mkOutbox; obId; obBody; obStatus; OutStatus; OutPending; OutSent; OutFailed; Event; evId; evProcessed)
open import Cxm.Knowledge using (Knowledge; kId; kSubject; kDetail; statedK; mkFact; IState; FObserved; STATE; STATED)
open import Cxm.Collections using (Evidence; mkEvidence; evdId; evdKnowledge; Transition; mkTransition; trId; trEpisode; dvEpisode; ProtocolTransition; mkProtocolTransition; ptProtocol)
open import Cxm.Episode using (Episode; mkEpisode; epId; epSubject; epCurrentState)
open import Cxm.Protocol using (Protocol; mkProtocol; prId)
open import Cxm.Tenant using (Tenant; tId)
open import Cxm.Users using (User; uId; uLogin; RoleAssignment; raId)
open import Cxm.Tenant using (Tenant; tId)
open import Cxm.Expectation using (Expectation; mkExpectation; xpId; xpStatus; ExpOurPromise; ExpUnknown; ExpMet; Promise; pmId; mkPromise; pmStatus; PromStatus; PromPending; PromFulfilled; PromBroken; Ours)
open import Cxm.Site using (IntTokenRow; mkIntTokenRow; itkId; itkRevokedAt)
open import Cxm.Event using (mkExperienceEvent; Web; Client; View)
open import Cxm.Appointment using
  ( Appointment; mkAppointment; apId; apSubject; apStatus; ApptStatus; ApScheduled; ApCanceled; ApCompleted )
open import Cxm.Account using (Account; mkAccount; acId; acBalance)
open import Cxm.Payment using (Payment; mkPayment; payId; payStatus; PayStatus; PayPending; PaySucceeded)
open import Cxm.Entitlement using (Entitlement; enId; enSubject; TOffering; SGrant)
open import Cxm.Store.Base using (Err; NotFound; Invariant; Conflict; InvalidTransition; Insufficient; Forbidden)
open import Cxm.Store.Verbs
open import Cxm.CommandsV
open import Cxm.Knowledge using (KRedetail; KStrengthen)

------------------------------------------------------------------------
-- Pure state: one dependent function covers every table
------------------------------------------------------------------------

Tbls : Set
Tbls = (t : TableCode) → List (ℕ × Val t)

record PSt : Set where
  constructor mkP
  field tbls : Tbls ; pNext : ℕ ; pLocks : List (ℕ × ℕ)
open PSt public

private
  lookA : ∀ {V : Set} → ℕ → List (ℕ × V) → Maybe V
  lookA k [] = nothing
  lookA k ((k′ , v) ∷ xs) = if k ≡ᵇ k′ then just v else lookA k xs

  insA : ∀ {V : Set} → ℕ → V → List (ℕ × V) → List (ℕ × V)
  insA k v [] = (k , v) ∷ []
  insA k v ((k′ , w) ∷ xs) = if k ≡ᵇ k′ then (k , v) ∷ xs else (k′ , w) ∷ insA k v xs

  remA : ∀ {V : Set} → ℕ → List (ℕ × V) → List (ℕ × V)
  remA k [] = []
  remA k ((k′ , w) ∷ xs) = if k ≡ᵇ k′ then xs else (k′ , w) ∷ remA k xs

  -- dependent override: replace ONE table's rows, leave the rest (types align via the ≟ proof)
  override : (t : TableCode) → (List (ℕ × Val t) → List (ℕ × Val t)) → Tbls → Tbls
  override t f st t′ with t ≟ t′
  ... | just refl = f (st t)
  ... | nothing   = st t′

  held : (ℕ × ℕ) → List (ℕ × ℕ) → Bool
  held _ [] = false
  held (a , b) ((c , d) ∷ ls) = ((a ≡ᵇ c) ∧ (b ≡ᵇ d)) ∨ held (a , b) ls

  anyAdvisory : List (ℕ × ℕ) → Bool
  anyAdvisory [] = false
  anyAdvisory ((a , _) ∷ ls) = (999 <ᵇ a) ∨ anyAdvisory ls

  rootPair : TableCode × ℕ → ℕ × ℕ
  rootPair (t , i) = code t , i

  heldAny : List (TableCode × ℕ) → List (ℕ × ℕ) → Bool
  heldAny []       _  = false
  heldAny (r ∷ rs) ls = held (rootPair r) ls ∨ heldAny rs ls

  -- ℕ-index semantics for the pure handler: position → EXTRACTOR-or-unsupported (audit E2:
  -- an unregistered position must fail LOUDLY, not silently return [] while Base/PG see rows)
  ixExtract : (t : TableCode) (pos : ℕ) → Maybe (Val t → ℕ)
  ixExtract tcEdge        0 = just seFrom
  ixExtract tcEdge        1 = just seTo
  ixExtract tcIdentity    0 = just iSubject
  ixExtract tcKnowledge   0 = just kSubject
  ixExtract tcEvidence    0 = just evdKnowledge
  ixExtract tcEpisode     0 = just epSubject
  ixExtract tcTransition  0 = just trEpisode
  ixExtract tcDeviation   0 = just dvEpisode
  ixExtract tcAppointment 0 = just apSubject
  ixExtract tcEntitlement 0 = just enSubject
  ixExtract tcExpectation 0 = just xpSubject
  ixExtract tcPromise     0 = just pmSubject
  ixExtract tcPayment     0 = just paySubject
  ixExtract tcProtocolTransition 0 = just ptProtocol
  ixExtract tcEvent       0 = just eeSubject
  ixExtract tcBusEvent    0 = just (λ e → if evProcessed e then 1 else 0)
  ixExtract tcOutbox      0 = just (λ o → statusOrd (obStatus o))
    where statusOrd : OutStatus → ℕ
          statusOrd OutPending = 0        -- mirrors Wire osCodes "P","S","F"
          statusOrd OutSent    = 1
          statusOrd _          = 2
  ixExtract _             _ = nothing

  bump : ℕ → ℕ → ℕ
  bump id n = if n ≤ᵇ id then suc id else n

  matchCol : Maybe String → String → Bool
  matchCol (just s) k = primStringEquality s k
  matchCol nothing  _ = false

  filterCol : ∀ {V : Set} → (V → Maybe String) → String → List (ℕ × V) → List (ℕ × V)
  filterCol f k [] = []
  filterCol f k ((i , v) ∷ xs) =
    if matchCol (f v) k then (i , v) ∷ filterCol f k xs else filterCol f k xs

handlerP : Handler PSt
handlerP (rLockRoot t id) st with lookA id (tbls st t)
... | just _  = inj₂ (tt , record st { pLocks = (code t , id) ∷ pLocks st })
... | nothing = inj₁ NotFound   -- domain shape (existence-hidden 404); also catches lock-fresh-id (A3)
handlerP (rLockKey c o) st = inj₂ (tt , record st { pLocks = (1000 + c , o) ∷ pLocks st })
handlerP (rTryLockKey c o) st = inj₂ (true , record st { pLocks = (1000 + c , o) ∷ pLocks st })   -- pure: один актор — лок всегда наш
handlerP (rGet t k)       st = inj₂ (lookA k (tbls st t) , st)
handlerP (rByIndex t p k) st with ixExtract t p
... | nothing = inj₁ (Invariant "byIx: position not in the ixExtract registry")
... | just f  = inj₂ (ids (tbls st t) , st)
  where ids : List (ℕ × Val t) → List ℕ
        ids [] = []
        ids ((i , v) ∷ xs) = if f v ≡ᵇ k then i ∷ ids xs else ids xs
handlerP (rByCol t c k)   st =
  if byColSupported t c
  then inj₂ (filterCol (strField t c) k (tbls st t) , st)
  else inj₁ (Invariant "byCol: column not in the strField registry")
handlerP (rScan t)        st = inj₂ (tbls st t , st)
handlerP (rPut t v) st =
  if queueTable t ∨ heldAny (rootOf t v ∷ altRoots t v) (pLocks st) ∨ anyAdvisory (pLocks st)
  then inj₂ (tt , record st { tbls = override t (insA (keyOf t v) v) (tbls st)
                            ; pNext = bump (keyOf t v) (pNext st) })
  else inj₁ (Invariant "lock discipline: root not held")
  where
    keyOf : (t : TableCode) → Val t → ℕ         -- pk for the tables the tests touch
    keyOf tcSubject   v = sId v
    keyOf tcIdentity  v = iId v
    keyOf tcOutbox    v = obId v
    keyOf tcKnowledge   v = kId v
    keyOf tcEvidence    v = evdId v
    keyOf tcEpisode     v = epId v
    keyOf tcAppointment v = apId v
    keyOf tcAccount     v = acId v
    keyOf tcEntitlement v = enId v
    keyOf tcEvent       v = eeId v
    keyOf tcTenant      v = tId v
    keyOf tcUser        v = uId v
    keyOf tcAssignment  v = raId v
    keyOf tcEdge        v = seId v
    keyOf tcExpectation v = xpId v
    keyOf tcPromise     v = pmId v
    keyOf tcTransition  v = trId v
    keyOf tcProtocol    v = prId v
    keyOf tcIntToken    v = itkId v
    keyOf tcBusEvent    v = evId v
    keyOf tcPayment     v = payId v
    keyOf tcResource    v = rId v
    keyOf tcResourceLink v = rlId v
    keyOf tcMention     v = mId v
    keyOf _             _ = 0                    -- extend as ported commands need it
handlerP (rDel t k) st with lookA k (tbls st t)
... | nothing = inj₁ NotFound
... | just v  = if appendOnly t then inj₁ (Invariant "append-only entity: hard delete not permitted (§7.5 erasure = crypto-shred)")
                else if heldAny (rootOf t v ∷ altRoots t v) (pLocks st)
                then inj₂ (tt , record st { tbls = override t (remA k) (tbls st) })
                else inj₁ (Invariant "lock discipline: root not held")
handlerP rFresh st = inj₂ (pNext st , st)

------------------------------------------------------------------------
-- refl smoke (commands come from Cxm.CommandsV — the real ported pack #1)
------------------------------------------------------------------------

private
  s1 s2 : Subject
  s1 = mkSubject 1 EXTERNAL Person "A" "UTC" 0 nothing 2 nothing nothing false
  s2 = mkSubject 2 EXTERNAL Person "B" "UTC" 0 nothing 2 nothing nothing false

  seed : Tbls
  seed = override tcSubject (λ _ → (1 , s1) ∷ (2 , s2) ∷ []) (λ _ → [])

  st0 : PSt
  st0 = mkP seed 3 []

  outId : Err ⊎ (ℕ × PSt) → Maybe ℕ
  outId (inj₂ (n , _)) = just n
  outId (inj₁ _)       = nothing

  errOf : ∀ {A : Set} → Err ⊎ A → Maybe Err
  errOf (inj₁ e) = just e
  errOf (inj₂ _) = nothing

  locksOf : ∀ {A : Set} → Err ⊎ (A × PSt) → Maybe (List (ℕ × ℕ))
  locksOf (inj₂ (_ , st)) = just (pLocks st)
  locksOf (inj₁ _)        = nothing

-- find-or-create through the ergonomic layer: fresh id, byCol lookup, discipline satisfied
_ : outId (runTx handlerP (bindIdentityV 1 "email" "a@x" false 2 77) st0) ≡ just 3
_ = refl

-- idempotence via the bounded byCol lookup
_ : outId (runTx handlerP
      (bindIdentityV 1 "email" "a@x" false 2 77 >>=T λ _ → bindIdentityV 1 "email" "a@x" false 2 99) st0)
  ≡ just 3
_ = refl

-- cross-tenant → NotFound; unlocked put → discipline abort
_ : errOf (runTx handlerP (bindIdentityV 1 "email" "a@x" false 999 77) st0) ≡ just NotFound
_ = refl
_ : errOf (runTx handlerP (put tcIdentity (mkIdentity 9 1 "e" "b@x" false 2 0)) st0)
  ≡ just (Invariant "lock discipline: root not held")
_ = refl

-- ★ lockRoots: canonical order regardless of the argument order (deadlock-freedom by combinator)
_ : locksOf (runTx handlerP (lockRoots ((tcSubject , 2) ∷ (tcSubject , 1) ∷ [])) st0)
  ≡ just ((1 , 2) ∷ (1 , 1) ∷ [])
_ = refl
_ : locksOf (runTx handlerP (lockRoots ((tcSubject , 1) ∷ (tcSubject , 2) ∷ [])) st0)
  ≡ just ((1 , 2) ∷ (1 , 1) ∷ [])
_ = refl

-- events are append-only at the verb level
_ : appendOnly tcEvent ≡ true
_ = refl

------------------------------------------------------------------------
-- pack #1 commands (Cxm.CommandsV)
------------------------------------------------------------------------

private
  -- a state that already has one identity (3 → subject 1)
  st1 : PSt
  st1 = mkP (override tcIdentity (λ _ → (3 , mkIdentity 3 1 "email" "a@x" false 2 77) ∷ []) seed) 4 []

  identAt : ∀ {A : Set} → ℕ → Err ⊎ (A × PSt) → Maybe Identity
  identAt k (inj₂ (_ , st)) = lookA k (tbls st tcIdentity)
  identAt k (inj₁ _)        = nothing

  outboxBody : ∀ {A : Set} → ℕ → Err ⊎ (A × PSt) → Maybe String
  outboxBody k (inj₂ (_ , st)) = body (lookA k (tbls st tcOutbox))
    where body : Maybe OutboxEntry → Maybe String
          body (just o) = just (obBody o)
          body nothing  = nothing
  outboxBody k (inj₁ _) = nothing

-- verifyIdentity: peek → lockRoot → re-read → flip; the flag lands
_ : identAt 3 (runTx handlerP (verifyIdentityV 3 99) st1)
  ≡ just (mkIdentity 3 1 "email" "a@x" true 2 77)
_ = refl

-- resolveOrCreate, FIND path: the advisory key + byCol find the existing subject
_ : outId (runTx handlerP (resolveOrCreateSubjectV "email" "a@x" "N" "UTC" 2 88) st1) ≡ just 1
_ = refl

-- resolveOrCreate, CREATE path: new subject 4 under the advisory key (self-rooted create)
_ : outId (runTx handlerP (resolveOrCreateSubjectV "email" "new@x" "N" "UTC" 2 88) st1) ≡ just 4
_ = refl

-- ★ the one-atom revision: bind + verification mail in ONE transaction — the mail body closes
-- over the fresh identity id (3), and both rows exist after a single run
_ : outboxBody 4 (runTx handlerP
      (bindIdentityNotifyV 1 "email" "a@x" 2 77 "Confirm" (λ n → "verify:" <> show n)) st0)
  ≡ just "verify:3"
_ = refl
_ : identAt 3 (runTx handlerP
      (bindIdentityNotifyV 1 "email" "a@x" 2 77 "Confirm" (λ n → "verify:" <> show n)) st0)
  ≡ just (mkIdentity 3 1 "email" "a@x" false 2 77)
_ = refl

-- queue exemption: an outbox enqueue needs NO locks (fresh-id append, single consumer)
_ : outId (runTx handlerP (enqueueNotificationV "email" "x@y" "s" "b" 2 7) st0) ≡ just 3
_ = refl

------------------------------------------------------------------------
-- pack #2: knowledge/episode
------------------------------------------------------------------------

private
  stK : PSt
  stK = mkP
    ( override tcProtocol (λ _ → (7 , mkProtocol 7 2 "care" 100 0) ∷ [])
    ( override tcEvent    (λ _ → (8 , mkExperienceEvent 8 1 2 Web Client 0 View 0 nothing
                                        nothing nothing nothing false false "p" nothing) ∷ [])
    ( override tcKnowledge (λ _ → (5 , statedK 5 1 2 IState 500 "old" 0 0 nothing nothing)
                                ∷ (6 , mkFact 6 1 2 FObserved "f" 0 nothing 0 nothing) ∷ [])
      seed ))) 9 []

  kDetailAt : ∀ {A : Set} → ℕ → Err ⊎ (A × PSt) → Maybe String
  kDetailAt k (inj₂ (_ , st)) = det (lookA k (tbls st tcKnowledge))
    where det : Maybe Knowledge → Maybe String
          det (just x) = just (kDetail x)
          det nothing  = nothing
  kDetailAt k (inj₁ _) = nothing

  epStateAt : ∀ {A : Set} → ℕ → Err ⊎ (A × PSt) → Maybe ℕ
  epStateAt k (inj₂ (_ , st)) = cur (lookA k (tbls st tcEpisode))
    where cur : Maybe Episode → Maybe ℕ
          cur (just e) = just (epCurrentState e)
          cur nothing  = nothing
  epStateAt k (inj₁ _) = nothing

-- createKnowledge: lockRoot → guard → builder; row lands with the detail
_ : outId (runTx handlerP (createKnowledgeV 1 STATE STATED 500 "d" 0 0 nothing nothing 2) st0) ≡ just 3
_ = refl
_ : kDetailAt 3 (runTx handlerP (createKnowledgeV 1 STATE STATED 500 "d" 0 0 nothing nothing 2) st0)
  ≡ just "d"
_ = refl
_ : errOf (runTx handlerP (createKnowledgeV 1 STATE STATED 500 "d" 0 0 nothing nothing 999) st0)
  ≡ just NotFound
_ = refl

-- updateKnowledge (re-read под локом): redetail lands; FACT re-grade is refused
_ : kDetailAt 5 (runTx handlerP (updateKnowledgeV 5 (KRedetail "new") 2) stK) ≡ just "new"
_ = refl
_ : errOf (runTx handlerP (updateKnowledgeV 6 (KStrengthen 10) 2) stK)
  ≡ just (Invariant "cannot re-grade a FACT (use supersede)")
_ = refl

-- attachEvidence: knowledge-rooted insert; missing event → NotFound
_ : outId (runTx handlerP (attachEvidenceV 5 8 2 77) stK) ≡ just 9
_ = refl
_ : errOf (runTx handlerP (attachEvidenceV 5 99 2 77) stK) ≡ just NotFound
_ = refl

-- createEpisode: initial state is copied from the protocol
_ : outId (runTx handlerP (createEpisodeV 1 7 "j" 2 77) stK) ≡ just 9
_ = refl
_ : epStateAt 9 (runTx handlerP (createEpisodeV 1 7 "j" 2 77) stK) ≡ just 100
_ = refl

------------------------------------------------------------------------
-- pack #3: appointments / payments
------------------------------------------------------------------------

private
  stA : PSt
  stA = mkP
    ( override tcAccount (λ _ → (10 , mkAccount 10 2 100 0) ∷ [])
    ( override tcAppointment
        (λ _ → (11 , mkAppointment 11 1 0 nothing nothing 1000 60 ApScheduled nothing 2 0 nothing)
             ∷ (12 , mkAppointment 12 1 0 nothing nothing 9000 60 ApCompleted nothing 2 0 nothing) ∷ [])
      seed )) 13 []

  apStatusAt : ∀ {A : Set} → ℕ → Err ⊎ (A × PSt) → Maybe ApptStatus
  apStatusAt k (inj₂ (_ , st)) = go (lookA k (tbls st tcAppointment))
    where go : Maybe Appointment → Maybe ApptStatus
          go (just a) = just (apStatus a)
          go nothing  = nothing
  apStatusAt k (inj₁ _) = nothing

  acBalAt : ∀ {A : Set} → ℕ → Err ⊎ (A × PSt) → Maybe ℕ
  acBalAt k (inj₂ (_ , st)) = go (lookA k (tbls st tcAccount))
    where go : Maybe Account → Maybe ℕ
          go (just a) = just (acBalance a)
          go nothing  = nothing
  acBalAt k (inj₁ _) = nothing

-- booking: free slot → booked (advisory nsBooking + subject root)
_ : outId (runTx handlerP (bookAppointmentV 1 0 nothing nothing 5000 60 2 77) stA) ≡ just 13
_ = refl

-- booking: overlap with the scheduled appointment (1000..4600) → Conflict; the COMPLETED
-- appointment does not count as busy
_ : errOf (runTx handlerP (bookAppointmentV 1 0 nothing nothing 2000 60 2 77) stA) ≡ just Conflict
_ = refl

-- transitions: Scheduled cancels; a Completed one refuses (InvalidTransition)
_ : apStatusAt 11 (runTx handlerP (cancelAppointmentV 11) stA) ≡ just ApCanceled
_ = refl
_ : errOf (runTx handlerP (cancelAppointmentV 12) stA) ≡ just InvalidTransition
_ = refl

-- credit: root-locked read-modify-write on the balance
_ : acBalAt 10 (runTx handlerP (creditV 10 50) stA) ≡ just 150
_ = refl

-- grantEntitlement (internal): subject-rooted insert
_ : outId (runTx handlerP (grantEntitlementV 1 TOffering 3 0 nothing SGrant 2 77) stA) ≡ just 13
_ = refl

------------------------------------------------------------------------
-- pack #4: cascades / GDPR — a small world, one run, many projections
------------------------------------------------------------------------

private
  -- subjects 1,2 (seed); identity 3→1; knowledge 5→1 + evidence 30→5; episode 40→1 +
  -- transition 50→40; appointment 11→1; edges 20 (1→2) and 21 (2→1); event 8→1 (append-only)
  stW : PSt
  stW = mkP
    ( override tcEdge (λ _ → (20 , mkEdge 20 1 2 participation nothing 0 0 nothing 2 0)
                           ∷ (21 , mkEdge 21 2 1 participation nothing 0 0 nothing 2 0) ∷ [])
    ( override tcTransition (λ _ → (50 , mkTransition 50 40 0 1 0 0 2) ∷ [])
    ( override tcEpisode (λ _ → (40 , mkEpisode 40 1 7 2 100 "j" nothing nothing 0 nothing) ∷ [])
    ( override tcEvidence (λ _ → (30 , mkEvidence 30 5 8 2 0) ∷ [])
    ( override tcKnowledge (λ _ → (5 , statedK 5 1 2 IState 500 "secret" 0 0 nothing nothing) ∷ [])
    ( override tcIdentity (λ _ → (3 , mkIdentity 3 1 "email" "a@x" false 2 77) ∷ [])
    ( override tcAppointment
        (λ _ → (11 , mkAppointment 11 1 0 nothing nothing 1000 60 ApScheduled nothing 2 0 nothing) ∷ [])
    ( override tcEvent
        (λ _ → (8 , mkExperienceEvent 8 1 2 Web Client 0 View 0 nothing nothing nothing nothing
                      false false "PII" nothing) ∷ [])
      seed )))))))) 60 []

  cascRun : Err ⊎ (⊤ × PSt)
  cascRun = runTx handlerP (cascadeDeleteSubjectV 1 2) stW

  gdprRun : Err ⊎ (⊤ × PSt)
  gdprRun = runTx handlerP (gdprEraseSubjectV 1 2 99) stW

  gone : ∀ {A : Set} → (t : TableCode) → ℕ → Err ⊎ (A × PSt) → Maybe Bool
  gone t k (inj₂ (_ , st)) = just (isN (lookA k (tbls st t)))
    where isN : ∀ {V : Set} → Maybe V → Bool
          isN nothing  = true
          isN (just _) = false
  gone t k (inj₁ _) = nothing

  eePayloadAt : ∀ {A : Set} → ℕ → Err ⊎ (A × PSt) → Maybe String
  eePayloadAt k (inj₂ (_ , st)) = go (lookA k (tbls st tcEvent))
    where go : Maybe ExperienceEvent → Maybe String
          go (just e) = just (eePayload e)
          go nothing  = nothing
  eePayloadAt k (inj₁ _) = nothing

-- the cascade wipes the whole subject-1 tree…
_ : gone tcSubject 1 cascRun ≡ just true
_ = refl
_ : gone tcIdentity 3 cascRun ≡ just true
_ = refl
_ : gone tcKnowledge 5 cascRun ≡ just true
_ = refl
_ : gone tcEvidence 30 cascRun ≡ just true          -- deep: via its knowledge root
_ = refl
_ : gone tcEpisode 40 cascRun ≡ just true
_ = refl
_ : gone tcTransition 50 cascRun ≡ just true        -- deep: via its episode root
_ = refl
_ : gone tcAppointment 11 cascRun ≡ just true       -- audit fix carried over (session times = PII)
_ = refl
_ : gone tcEdge 20 cascRun ≡ just true              -- outgoing edge (primary root)
_ = refl
_ : gone tcEdge 21 cascRun ≡ just true              -- ★ INCOMING edge: deleted via altRoots (seTo)
_ = refl

-- …but NOT the bystanders: subject 2 and the append-only event survive
_ : gone tcSubject 2 cascRun ≡ just false
_ = refl
_ : gone tcEvent 8 cascRun ≡ just false
_ = refl

-- cross-tenant cascade → NotFound (existence-hidden)
_ : errOf (runTx handlerP (cascadeDeleteSubjectV 1 999) stW) ≡ just NotFound
_ = refl

-- GDPR: the event row SURVIVES but its PII is redacted; the deletable tree is gone
_ : eePayloadAt 8 gdprRun ≡ just "[erased]"
_ = refl
_ : gone tcSubject 1 gdprRun ≡ just true
_ = refl


------------------------------------------------------------------------
-- pack #5: social / owner / protocol / expectations / tokens
------------------------------------------------------------------------

private
  stP : PSt
  stP = mkP
    ( override tcIntToken (λ _ → (80 , mkIntTokenRow 80 2 "tok" "/v1" "" 0 nothing) ∷ [])
    ( override tcExpectation (λ _ → (60 , mkExpectation 60 1 2 "t" ExpOurPromise 500 ExpUnknown 0) ∷ [])
    ( override tcProtocolTransition (λ _ → (70 , mkProtocolTransition 70 7 100 200 2) ∷ [])
    ( override tcEpisode (λ _ → (40 , mkEpisode 40 1 7 2 100 "j" nothing nothing 0 nothing) ∷ [])
      seed )))) 90 []

  xpStatusAt : ∀ {A : Set} → ℕ → Err ⊎ (A × PSt) → Maybe _
  xpStatusAt k (inj₂ (_ , st)) = go (lookA k (tbls st tcExpectation))
    where go : Maybe Expectation → Maybe _
          go (just x) = just (xpStatus x)
          go nothing  = nothing
  xpStatusAt k (inj₁ _) = nothing

  epStateAt′ : ∀ {A : Set} → ℕ → Err ⊎ (A × PSt) → Maybe ℕ
  epStateAt′ = epStateAt

  tokRevokedAt : ∀ {A : Set} → ℕ → Err ⊎ (A × PSt) → Maybe (Maybe ℕ)
  tokRevokedAt k (inj₂ (_ , st)) = go (lookA k (tbls st tcIntToken))
    where go : Maybe IntTokenRow → Maybe (Maybe ℕ)
          go (just r) = just (itkRevokedAt r)
          go nothing  = nothing
  tokRevokedAt k (inj₁ _) = nothing

-- addEdge: both endpoints locked, canonical order regardless of… anything; edge lands
_ : outId (runTx handlerP (addEdgeV 2 1 participation nothing 0 0 nothing 2 7) st0) ≡ just 3
_ = refl
_ : locksOf (runTx handlerP (addEdgeV 2 1 participation nothing 0 0 nothing 2 7) st0)
  ≡ just ((1 , 2) ∷ (1 , 1) ∷ [])
_ = refl

-- registerOwner: ONE advisory key covers tenant+user+assignment creates; all three land
_ : outId (runTx handlerP (registerOwnerV "drA" "ph" "A-tenant" 7) st0) ≡ just 3
_ = refl
_ : gone tcUser 4 (runTx handlerP (registerOwnerV "drA" "ph" "A-tenant" 7) st0) ≡ just false
_ = refl
_ : gone tcAssignment 5 (runTx handlerP (registerOwnerV "drA" "ph" "A-tenant" 7) st0) ≡ just false
_ = refl

-- expectation status: peek → lockRoot(subject) → re-read → flip
_ : xpStatusAt 60 (runTx handlerP (setExpectationStatusV 60 ExpMet 2) stP) ≡ just ExpMet
_ = refl

-- episode state machine: legal per the protocol graph → state flips + transition journalled
_ : epStateAt′ 40 (runTx handlerP (transitionEpisodeV 40 200 2 7) stP) ≡ just 200
_ = refl
_ : errOf (runTx handlerP (transitionEpisodeV 40 999 2 7) stP) ≡ just InvalidTransition
_ = refl

-- token revoke: owner-guarded; cross-tenant → NotFound (existence-hidden)
_ : tokRevokedAt 80 (runTx handlerP (revokeIntegrationTokenV 80 2 99) stP) ≡ just (just 99)
_ = refl
_ : errOf (runTx handlerP (revokeIntegrationTokenV 80 999 99) stP) ≡ just NotFound
_ = refl


------------------------------------------------------------------------
-- audit 2026-07-06 (A4): the previously-untested pack-5 commands
------------------------------------------------------------------------

-- createPromise: promise row + its PromiseDeclared birth-event in ONE atom
_ : outId (runTx handlerP (createPromiseV 1 "call back" 500 2 7) st0) ≡ just 3
_ = refl
_ : eePayloadAt 4 (runTx handlerP (createPromiseV 1 "call back" 500 2 7) st0)
  ≡ just "{\"promise\":3}"
_ = refl

-- createProtocol: advisory-keyed self-rooted create
_ : outId (runTx handlerP (createProtocolV "care" 100 2 7) st0) ≡ just 3
_ = refl

-- createIntegrationToken: advisory-keyed mint
_ : outId (runTx handlerP (createIntegrationTokenV "tok" "/v1" "" 2 7) st0) ≡ just 3
_ = refl


-- audit C2: byCol over an UNREGISTERED column fails loudly (native≡PG parity guard — otherwise
-- the native handlers would return [] while PG runs real SQL, and tests would pass vacuously)
_ : errOf (runTx handlerP (byCol tcIdentity "created_at" "7") st0)
  ≡ just (Invariant "byCol: column not in the strField registry")
_ = refl


-- audit E2 (symmetric to C2): byIx over an UNREGISTERED position fails loudly in the pure
-- handler (Base/PG serve every real index — silence here would make such tests vacuous)
_ : errOf (runTx handlerP (byIx tcEdge 2 0) st0)
  ≡ just (Invariant "byIx: position not in the ixExtract registry")
_ = refl


------------------------------------------------------------------------
-- pack #6a/6b: accounts / payments / the promise market
------------------------------------------------------------------------

private
  stM : PSt
  stM = mkP
    ( override tcPayment (λ _ → (80 , mkPayment 80 2 "ext80" 3 1 "N" "e@x" 500 PayPending 0 0)
                              ∷ (81 , mkPayment 81 2 "ext81" 3 0 "N" "e@x" 500 PayPending 0 0) ∷ [])
    ( override tcPromise (λ _ → (70 , mkPromise 70 1 2 "t" 500 PromPending nothing 0 Ours
                                        nothing true 30 (just 10) (just 11) true) ∷ [])
    ( override tcAccount (λ _ → (10 , mkAccount 10 2 100 0) ∷ (11 , mkAccount 11 2 0 0) ∷ [])
      seed ))) 90 []

  pmStatusAt : ∀ {A : Set} → ℕ → Err ⊎ (A × PSt) → Maybe PromStatus
  pmStatusAt k (inj₂ (_ , st)) = go (lookA k (tbls st tcPromise))
    where go : Maybe Promise → Maybe PromStatus
          go (just p) = just (pmStatus p)
          go nothing  = nothing
  pmStatusAt k (inj₁ _) = nothing

  payStatusAt : ∀ {A : Set} → ℕ → Err ⊎ (A × PSt) → Maybe PayStatus
  payStatusAt k (inj₂ (_ , st)) = go (lookA k (tbls st tcPayment))
    where go : Maybe Payment → Maybe PayStatus
          go (just p) = just (payStatus p)
          go nothing  = nothing
  payStatusAt k (inj₁ _) = nothing

-- proof-gated charge: sufficient debits exactly; insufficient ABORTS (the ≤-proof gate)
_ : acBalAt 10 (runTx handlerP (chargeV 10 30) stM) ≡ just 70
_ = refl
_ : errOf (runTx handlerP (chargeV 10 999) stM) ≡ just Insufficient
_ = refl

-- settle: the held stake is RELEASED back to the staker, status flips, clearing journalled
_ : acBalAt 10 (runTx handlerP (settlePromiseV 70 2 9) stM) ≡ just 130
_ = refl
_ : pmStatusAt 70 (runTx handlerP (settlePromiseV 70 2 9) stM) ≡ just PromFulfilled
_ = refl
_ : eePayloadAt 90 (runTx handlerP (settlePromiseV 70 2 9) stM) ≡ just "{\"promise\":70}"
_ = refl

-- default: the stake is routed to the penaltyTo account, atomically with the status + journal
_ : acBalAt 11 (runTx handlerP (defaultPromiseV 70 2 9) stM) ≡ just 30
_ = refl
_ : pmStatusAt 70 (runTx handlerP (defaultPromiseV 70 2 9) stM) ≡ just PromBroken
_ = refl

-- ★ referral is PROOF-GATED: the new obligor (account 11, balance 0) cannot post the 30 stake →
-- Insufficient, and the WHOLE atom rolls back (nothing moved — atomicity by construction)
_ : errOf (runTx handlerP (referPromiseV 70 11 2 9) stM) ≡ just Insufficient
_ = refl

-- payment success is idempotent: run twice in one atom — ONE entitlement (90), no second (92)
_ : payStatusAt 80 (runTx handlerP
      (markPaymentSucceededV 80 9 >>T markPaymentSucceededV 80 9) stM) ≡ just PaySucceeded
_ = refl
_ : gone tcEntitlement 90 (runTx handlerP
      (markPaymentSucceededV 80 9 >>T markPaymentSucceededV 80 9) stM) ≡ just false
_ = refl
_ : gone tcEntitlement 92 (runTx handlerP
      (markPaymentSucceededV 80 9 >>T markPaymentSucceededV 80 9) stM) ≡ just true
_ = refl

-- orphan payment (subject 0): marked succeeded, NO entitlement dangles on subject 0
_ : payStatusAt 81 (runTx handlerP (markPaymentSucceededV 81 9) stM) ≡ just PaySucceeded
_ = refl
_ : gone tcEntitlement 90 (runTx handlerP (markPaymentSucceededV 81 9) stM) ≡ just true
_ = refl


------------------------------------------------------------------------
-- pack #6c/6d: conversations / worker queues
------------------------------------------------------------------------

private
  stC : PSt
  stC = mkP
    ( override tcResource (λ _ → (95 , mkResource 95 2 nothing 1 0 nothing "post" 0 nothing
                                         (just 1) nothing nothing nothing) ∷ [])
    ( override tcOutbox (λ _ → (85 , mkOutbox 85 "email" "a@x" "s" "b" OutPending 2 0 0 nothing)
                             ∷ (86 , mkOutbox 86 "email" "b@x" "s" "b" OutPending 2 0 0 nothing) ∷ [])
    ( override tcAppointment
        (λ _ → (11 , mkAppointment 11 1 0 nothing nothing 1000 60 ApScheduled nothing 2 0 nothing) ∷ [])
      seed ))) 100 []

  obStatusAt : ∀ {A : Set} → ℕ → Err ⊎ (A × PSt) → Maybe OutStatus
  obStatusAt k (inj₂ (_ , st)) = go (lookA k (tbls st tcOutbox))
    where go : Maybe OutboxEntry → Maybe OutStatus
          go (just o) = just (obStatus o)
          go nothing  = nothing
  obStatusAt k (inj₁ _) = nothing

-- drainOutbox: both pending rows flip to Sent, count = 2 (queue puts need no locks)
_ : outId (runTx handlerP drainOutboxV stC) ≡ just 2
_ = refl
_ : obStatusAt 85 (runTx handlerP drainOutboxV stC) ≡ just OutSent
_ = refl

-- F4: a STRANGER (subject 2) cannot start a conversation on subject 1's appointment…
_ : errOf (runTx handlerP
      (commentOnV 2 "appointment" 11 nothing nothing nothing "hi" [] nothing 2 7) stC)
  ≡ just Forbidden
_ = refl

-- …but the participant (subject 1) can; the comment node lands
_ : outId (runTx handlerP
      (commentOnV 1 "appointment" 11 nothing nothing nothing "hi" [] nothing 2 7) stC) ≡ just 100
_ = refl

-- /v1 owner-guard: only the author edits their post
_ : errOf (runTx handlerP (updateOwnResourceV 2 95 (just "x") nothing nothing 7) stC)
  ≡ just Forbidden
_ = refl


------------------------------------------------------------------------
-- pack #6e/6f: lifecycle / admin
------------------------------------------------------------------------

private
  canonAt : ∀ {A : Set} → ℕ → Err ⊎ (A × PSt) → Maybe (Maybe ℕ)
  canonAt k (inj₂ (_ , st)) = go (lookA k (tbls st tcSubject))
    where go : Maybe Subject → Maybe (Maybe ℕ)
          go (just s) = just (sCanonical s)
          go nothing  = nothing
  canonAt k (inj₁ _) = nothing

  provAt : ∀ {A : Set} → ℕ → Err ⊎ (A × PSt) → Maybe Bool
  provAt k (inj₂ (_ , st)) = go (lookA k (tbls st tcSubject))
    where go : Maybe Subject → Maybe Bool
          go (just s) = just (sProvisional s)
          go nothing  = nothing
  provAt k (inj₁ _) = nothing

  eeSubjAt : ∀ {A : Set} → ℕ → Err ⊎ (A × PSt) → Maybe ℕ
  eeSubjAt k (inj₂ (_ , st)) = go (lookA k (tbls st tcEvent))
    where go : Maybe _ → Maybe ℕ
          go (just e) = just (eeSubject e)
          go nothing  = nothing
  eeSubjAt k (inj₁ _) = nothing

  evTpl : _
  evTpl = mkExperienceEvent 0 0 2 Web Client 7 View 0 nothing nothing nothing nothing false false "p" nothing

-- merge: the provisional subject gets its canonical alias, both roots locked
_ : canonAt 2 (runTx handlerP (mergeV 2 1) st0) ≡ just (just 1)
_ = refl

-- ingest, RESOLVE path: known identity (a@x → subject 1) — the event lands on subject 1
_ : eeSubjAt 4 (runTx handlerP (ingestSiteEventV "email" "a@x" 2 7 evTpl) st1) ≡ just 1
_ = refl

-- ingest, PROVISION path: unknown identity — a fresh provisional subject (4) + binding + event (6)
_ : eeSubjAt 6 (runTx handlerP (ingestSiteEventV "email" "new@x" 2 7 evTpl) st1) ≡ just 4
_ = refl
_ : provAt 4 (runTx handlerP (ingestSiteEventV "email" "new@x" 2 7 evTpl) st1) ≡ just true
_ = refl

-- mergeSession, PROMOTE path: first login clears the provisional flag and binds the login id
_ : provAt 2 (runTx handlerP (mergeSessionV 2 "email" "login@x" 2 7) stP) ≡ just false
_ = refl

-- mergeSession, ALIAS path: the login id resolves (a@x → subject 1) — session subject 2 merges
_ : canonAt 2 (runTx handlerP (mergeSessionV 2 "email" "a@x" 2 7) st1) ≡ just (just 1)
_ = refl

-- ensureAdmin is idempotent within one atom: one user (3), one assignment (4), no second user (5)
_ : gone tcUser 3 (runTx handlerP
      (ensureAdminV "root" "ph" "" 1 7 >>T ensureAdminV "root" "ph" "" 1 7) st0) ≡ just false
_ = refl
_ : gone tcUser 5 (runTx handlerP
      (ensureAdminV "root" "ph" "" 1 7 >>T ensureAdminV "root" "ph" "" 1 7) st0) ≡ just true
_ = refl

-- audit F2: the login-bound identity is VERIFIED (login proves channel control — original semantics)
_ : identAt 90 (runTx handlerP (mergeSessionV 2 "email" "login@x" 2 7) stP)
  ≡ just (mkIdentity 90 2 "email" "login@x" true 2 7)
_ = refl

-- аудит-2 zero-downtime: claimOutboxV — атомарный claim письма (бесшовный reload)
private
  claimTwice : Tx (Bool × Bool)
  claimTwice = claimOutboxV 85 7 8 >>=T λ a → claimOutboxV 85 7 8 >>=T λ b → returnT (a , b)
  pairOf : Err ⊎ ((Bool × Bool) × PSt) → Maybe (Bool × Bool)
  pairOf (inj₂ (p , _)) = just p
  pairOf (inj₁ _)       = nothing

-- первый claim берёт (attempts 0→1, lastAttempt=now), НЕМЕДЛЕННЫЙ повторный отбит backoff'ом
_ : pairOf (runTx handlerP claimTwice stC) ≡ just (true , false)
_ = refl

private
  -- строка с исчерпанными попытками (attempts=8, давно due): claim помечает Failed и НЕ шлёт
  stO : PSt
  stO = mkP (override tcOutbox
              (λ _ → (87 , mkOutbox 87 "email" "c@x" "s" "b" OutPending 2 0 8 (just 0)) ∷ [])
              (tbls stC)) (pNext stC) []
  boolOf : Err ⊎ (Bool × PSt) → Maybe Bool
  boolOf (inj₂ (b , _)) = just b
  boolOf (inj₁ _)       = nothing

_ : boolOf (runTx handlerP (claimOutboxV 87 99999 8) stO) ≡ just false
_ = refl
_ : obStatusAt 87 (runTx handlerP (claimOutboxV 87 99999 8) stO) ≡ just OutFailed
_ = refl
