{-# OPTIONS --without-K #-}

-- Domain commands (cxm-plan.md Phase 6). All commands are written against the repository seam
-- (Cxm.Store.Interface, principle 11) — they never touch IndexedMap or Base fields directly.
-- Records live in their own modules (Cxm.Subject, Cxm.Offering, …) to keep the store DAG
-- acyclic; this is the command layer on top (as CRM's Crm.Commands sits on Crm.Store).
--
-- Correctness by construction where cheap: the money invariant (balance ≥ 0) is PROOF-GATED —
-- `debit` cannot be called without a proof `amt ≤ bal`, and the only source of that proof is
-- the `yes` branch of the decidable `_≤?_`; the `no` branch is forced to `abort Insufficient`.
module Cxm.Commands where

open import Data.Nat using (ℕ; zero; suc; _≤_; _≤?_; _∸_; _+_; _*_; _≡ᵇ_; _≤ᵇ_; _<ᵇ_)
open import Data.Bool using (Bool; true; false; if_then_else_; _∧_; _∨_; not)
open import Data.Maybe using (Maybe; just; nothing; maybe′)
open import Data.List using (List; []; _∷_; foldr; length; map)
open import Data.String using (String) renaming (_++_ to _<>_)
open import Data.Nat.Show renaming (show to showℕ)
open import Data.Product using (_×_; _,_; proj₁; proj₂)
open import Relation.Nullary using (yes; no)
open import Agda.Builtin.Unit using (⊤; tt)
open import Agda.Builtin.String using (primStringEquality)

open import Cxm.Tenant using (TenantId; Tenant)
open import Cxm.Subject
open import Cxm.Edge
open import Cxm.Identity
open import Cxm.Event
open import Cxm.Bus using (Event; evProcessed; OutboxEntry; mkOutbox; OutStatus; OutPending; OutSent; OutFailed; obStatus; obAttempts; obLastAttempt)
open import Cxm.Collections using (Transition; mkTransition; ProtocolTransition; ptFromState; ptToState; mkProtocolTransition; ProtocolState; mkProtocolState)
open import Cxm.Offering
open import Cxm.Fulfilment using (Grant; gKind; gTarget; parseFulfilment)
open import Cxm.Resource
open import Cxm.Entitlement
open import Cxm.Account
open import Cxm.Payment
open import Cxm.Expectation
open import Cxm.Protocol
open import Cxm.Episode
open import Cxm.Users
open import Cxm.Appointment
open import Cxm.Schedule using (Interval; slotFree)
open import Cxm.Store.Base
open import Cxm.Txn
open import Cxm.Store.Interface
open import Cxm.Site using (findIdentityIn; IntTokenRow; mkIntTokenRow; itkRevokedAt)

------------------------------------------------------------------------
-- Subject (create / provisional / addEdge with FK / soft+cascade delete / merge)
------------------------------------------------------------------------

createSubject : (kind : SubjectKind) (structure : SubjectStructure)
                (name tz : String) (tenant now : ℕ) → Txn ℕ
createSubject kind structure name tz ten now =
  freshId >>=T λ sid →
  putT subjectsT (mkSubject sid kind structure name tz now nothing ten nothing nothing false)
  >>T returnT sid

-- an unresolved-identity event creates a provisional Subject (§4.4) so the log never waits
provisionalSubject : (name tz : String) (tenant now : ℕ) → Txn ℕ
provisionalSubject name tz ten now =
  freshId >>=T λ sid →
  putT subjectsT (mkSubject sid EXTERNAL Person name tz now nothing ten nothing nothing true)
  >>T returnT sid

-- FK-checked: both endpoints must exist (requireT aborts NotFound otherwise)
addEdge : (from to : ℕ) (kind : EdgeKind) (role : Maybe String)
          (ordinal validFrom : ℕ) (validTo : Maybe ℕ) (tenant now : ℕ) → Txn ℕ
addEdge from to kind role ord vf vt ten now =
  requireT subjectsT NotFound from >>T
  requireT subjectsT NotFound to   >>T
  freshId >>=T λ eid →
  putT edgesT (mkEdge eid from to kind role ord vf vt ten now)
  >>T returnT eid

softDeleteSubject : (sid now : ℕ) → Txn ⊤
softDeleteSubject sid now =
  requireT subjectsT NotFound sid >>=T λ s →
  putT subjectsT (record s { sDeletedAt = just now })

-- deep-delete an episode WITH its child tables (transition_log, deviations) so no child is
-- orphaned (audit #A). ExperienceEvents tied to the episode are append-only and left in place.
deleteEpisodeDeep : ℕ → Txn ⊤
deleteEpisodeDeep epid =
  byIndexT transitionsT trByEpisode epid >>=T λ ts → forEachT ts (delT transitionsT) >>T
  byIndexT deviationsT  dvByEpisode epid >>=T λ ds → forEachT ds (delT deviationsT)  >>T
  delT episodesT epid

-- deep-delete a knowledge row WITH its Evidence child rows (FK knowledge) — audit #A.
deleteKnowledgeDeep : ℕ → Txn ⊤
deleteKnowledgeDeep kid =
  byIndexT evidenceT evdByKnowledge kid >>=T λ es → forEachT es (delT evidenceT) >>T
  delT knowledgeT kid

-- cascade over the WRITE-MODEL dependents via reverse indexes (no dangling FK, audit #A):
-- edges (both directions), identities, entitlements, episodes (+transitions/deviations),
-- knowledge (+evidence), expectations, promises, payments. Append-only ExperienceEvents are
-- NOT deleted (§9.2/§7.5) — they remain as historical truth (their subject_id is a tombstone;
-- production may crypto-shred/anonymize rather than delete these financial/experience rows).
cascadeDeleteSubject : (sid : ℕ) → Txn ⊤
cascadeDeleteSubject sid =
  byIndexT edgesT edgeByFrom sid          >>=T λ fe → forEachT fe (delT edgesT)          >>T
  byIndexT edgesT edgeByTo sid            >>=T λ te → forEachT te (delT edgesT)          >>T
  byIndexT identitiesT identBySubject sid >>=T λ is → forEachT is (delT identitiesT)     >>T
  byIndexT entitlementsT entBySubject sid >>=T λ es → forEachT es (delT entitlementsT)   >>T
  byIndexT episodesT epBySubject sid      >>=T λ ep → forEachT ep deleteEpisodeDeep      >>T
  byIndexT knowledgeT knowBySubject sid   >>=T λ ks → forEachT ks deleteKnowledgeDeep    >>T
  byIndexT expectationsT expBySubject sid >>=T λ xs → forEachT xs (delT expectationsT)   >>T
  byIndexT promisesT promBySubject sid    >>=T λ ps → forEachT ps (delT promisesT)       >>T
  byIndexT paymentsT paymentBySubject sid >>=T λ ys → forEachT ys (delT paymentsT)       >>T
  delT subjectsT sid

-- merge = ALIAS, not rewrite (§4.4): point the provisional subject's canonical at the real one.
-- ExperienceEvents keep their original subject_id; reads resolve via `canonicalOf`.
merge : (provId canonId : ℕ) → Txn ⊤
merge provId canonId =
  requireT subjectsT NotFound canonId >>T
  requireT subjectsT NotFound provId  >>=T λ prov →
  putT subjectsT (record prov { sCanonical = just canonId })

-- resolve a subject id to its canonical (one hop; merge targets must be canonical, §4.4)
canonicalOf : Base → ℕ → ℕ
canonicalOf b id with tget subjectsT id b
... | just s  = maybe′ (λ c → c) id (sCanonical s)
... | nothing = id

------------------------------------------------------------------------
-- Money — balance ≥ 0 by construction (proof-gated debit)
------------------------------------------------------------------------

debit : (bal amt : ℕ) → amt ≤ bal → ℕ      -- proof-gated; result is the true difference
debit bal amt _ = bal ∸ amt

openAccount : (tenant now : ℕ) → Txn ℕ
openAccount ten now =
  freshId >>=T λ aid → putT accountsT (mkAccount aid ten 0 now) >>T returnT aid

private
  chargeAcc : Account → ℕ → Txn ⊤
  chargeAcc a amt with amt ≤? acBalance a
  ... | yes pf = putT accountsT (record a { acBalance = debit (acBalance a) amt pf })
  ... | no  _  = abort Insufficient

charge : (accId amt : ℕ) → Txn ⊤
charge accId amt = requireT accountsT NotFound accId >>=T λ a → chargeAcc a amt

credit : (accId amt : ℕ) → Txn ⊤
credit accId amt =
  requireT accountsT NotFound accId >>=T λ a →
  putT accountsT (record a { acBalance = acBalance a + amt })

------------------------------------------------------------------------
-- Ingest — the single entry of facts: append an immutable ExperienceEvent (id assigned here)
------------------------------------------------------------------------

appendEvent : ExperienceEvent → Txn ℕ
appendEvent ev =
  freshId >>=T λ eid → putT eventsT (record ev { eeId = eid }) >>T returnT eid

------------------------------------------------------------------------
-- Catalog — Offering / Resource / Entitlement
------------------------------------------------------------------------

createOffering : (kind price : ℕ) (currency metadata : String) (tenant now : ℕ) → Txn ℕ
createOffering kind price cur md ten now =
  freshId >>=T λ oid →
  putT offeringsT (mkOffering oid ten kind price cur md now nothing) >>T returnT oid

softDeleteOffering : (oid now : ℕ) → Txn ⊤
softDeleteOffering oid now =
  requireT offeringsT NotFound oid >>=T λ o →
  putT offeringsT (record o { oDeletedAt = just now })

createResource : (parent : Maybe ℕ) (kind ord : ℕ) (vis : Maybe String)
                 (payload : String) (author : Maybe ℕ) (listing : Maybe String) (tenant now : ℕ) → Txn ℕ
createResource parent kind ord vis payload author listing ten now =
  freshId >>=T λ rid →
  putT resourcesT (mkResource rid ten parent kind ord vis payload now nothing author listing nothing nothing) >>T returnT rid

grantEntitlement : (subject : ℕ) (targetKind : EntTarget) (target validFrom : ℕ)
                   (validTo : Maybe ℕ) (src : EntSource) (tenant now : ℕ) → Txn ℕ
grantEntitlement subj tk target vf vt src ten now =
  requireT subjectsT NotFound subj >>T
  freshId >>=T λ enid →
  putT entitlementsT (mkEntitlement enid subj ten tk target vf vt src now) >>T returnT enid

-- fulfilment-as-data (платформа-план П3): read THIS offering's stored plan (Offering.oMetadata,
-- interpreted purely by Cxm.Fulfilment) and issue every declared grant to the buyer as an
-- SPayment Entitlement — so a purchase unlocks the declared node(s) with NO operator, and no
-- privilege is forged from the request (the plan is server-side data). An unknown offering, or an
-- empty plan, is a no-op. Each grant is open-ended (validTo = nothing). Runs inside the payment
-- success Txn (markPaymentSucceeded), so it is atomic with the money state.
fulfillOffering : (subject offering tenant now : ℕ) → Txn ⊤
fulfillOffering subj off ten now =
  getT offeringsT off >>=T λ mo → maybe′ go (returnT tt) mo
  where
    issue : Grant → Txn ⊤
    issue g = grantEntitlement subj (gKind g) (gTarget g) now nothing SPayment ten now >>T returnT tt
    go : Offering → Txn ⊤
    go o = forEachT (parseFulfilment (oMetadata o)) issue

------------------------------------------------------------------------
-- Payment — pending → succeeded (grants an Entitlement), findByExtId (scan)
------------------------------------------------------------------------

recordPayment : (extId : String) (offering subject amount : ℕ)
                (name email : String) (tenant now : ℕ) → Txn ℕ
recordPayment ext off subj amt name email ten now =
  freshId >>=T λ pid →
  putT paymentsT (mkPayment pid ten ext off subj name email amt PayPending 0 now) >>T returnT pid

private
  findByExt : String → List (ℕ × Payment) → Maybe Payment
  findByExt _   []             = nothing
  findByExt ext ((_ , p) ∷ ps) =
    if primStringEquality (payExtId p) ext then just p else findByExt ext ps

findPaymentByExtId : String → Txn (Maybe Payment)
findPaymentByExtId ext = scanT paymentsT >>=T λ ps → returnT (findByExt ext ps)

-- authoritative success: mark succeeded AND grant the offering entitlement to the buyer.
-- IDEMPOTENT (audit #B): a payment already PaySucceeded is a no-op, so at-least-once webhook
-- redelivery (§4.15) never double-grants. A payment with no linked subject (paySubject 0, e.g.
-- a provisional/pre-login buyer) is marked succeeded but NOT granted yet — the grant is issued
-- once identity resolves (§4.4 merge), avoiding an entitlement dangling on subject 0.
private
  grantForPayment : Payment → ℕ → Txn ⊤
  grantForPayment p now with paySubject p
  ... | 0     = putT paymentsT (record p { payStatus = PaySucceeded })
  ... | suc s = freshId >>=T λ enid →
        putT entitlementsT (mkEntitlement enid (suc s) (payTenant p) TOffering (payOffering p) now nothing SPayment now) >>T
        fulfillOffering (suc s) (payOffering p) (payTenant p) now >>T
        putT paymentsT (record p { payStatus = PaySucceeded ; payEntitlement = enid })

markPaymentSucceeded : (payId now : ℕ) → Txn ⊤
markPaymentSucceeded pid now =
  requireT paymentsT NotFound pid >>=T λ p → idem p
  where
    idem : Payment → Txn ⊤
    idem q with payStatus q
    ... | PaySucceeded = returnT tt              -- already granted → idempotent no-op
    ... | _            = grantForPayment q now

------------------------------------------------------------------------
-- Expectation ↔ Promise
------------------------------------------------------------------------

createExpectation : (subject : ℕ) (topic : String) (src : ExpSource)
                    (level : ℕ) (tenant now : ℕ) → Txn ℕ
createExpectation subj topic src lvl ten now =
  requireT subjectsT NotFound subj >>T
  freshId >>=T λ xid →
  putT expectationsT (mkExpectation xid subj ten topic src lvl ExpUnknown now) >>T returnT xid

setExpectationStatus : (xid : ℕ) (st : ExpStatus) → Txn ⊤
setExpectationStatus xid st =
  requireT expectationsT NotFound xid >>=T λ x →
  putT expectationsT (record x { xpStatus = st })

-- П6 (контролируемые обязательства) — stake lifecycle over the PROOF-GATED Account ledger.
-- Holding the stake at creation makes `charge`'s balance≥0 invariant do the work: you can only
-- be penalised up to what you actually staked (штраф ≤ ставки by construction). nothing account
-- ⇒ no monetary stake (the consequence is reputation-only, i.e. the PromiseDefaulted event).
private
  holdStakeᵗ : (stakeAccount : Maybe ℕ) (amt : ℕ) → Txn ⊤        -- at creation: charge the staker
  holdStakeᵗ (just a) amt = if amt ≡ᵇ 0 then returnT tt else charge a amt
  holdStakeᵗ nothing  _   = returnT tt

  releaseStakeᵗ : (stakeAccount : Maybe ℕ) (amt : ℕ) → Txn ⊤     -- on fulfil: give the stake back
  releaseStakeᵗ (just a) amt = if amt ≡ᵇ 0 then returnT tt else credit a amt
  releaseStakeᵗ nothing  _   = returnT tt

  routePenaltyᵗ : (stakeAccount penaltyTo : Maybe ℕ) (amt : ℕ) → Txn ⊤   -- on default: compensate / forfeit
  routePenaltyᵗ (just _) (just to) amt = if amt ≡ᵇ 0 then returnT tt else credit to amt
  routePenaltyᵗ (just _) nothing   _   = returnT tt                       -- forfeit (stake burned)
  routePenaltyᵗ nothing  _         _   = returnT tt                       -- no monetary stake

-- full form (upgrade-план A3 + П6): direction (§0.2 symmetry — Theirs = the client's promise),
-- transferability + collateral (= HELD stake), and the declared consequence accounts. Holder
-- starts at the original counterparty (nothing); it changes only via transferPromise. If a stake
-- account is given the collateral is CHARGED here (held) in the same Txn.
createPromiseDirected : (subject : ℕ) (topic : String) (deadline : ℕ) (dir : PromDirection)
                        (transferable : Bool) (collateral : ℕ)
                        (stakeAccount penaltyTo : Maybe ℕ) (referable : Bool) (tenant now : ℕ) → Txn ℕ
createPromiseDirected subj topic deadline dir tr col stake pen ref ten now =
  requireT subjectsT NotFound subj >>T
  holdStakeᵗ stake col >>T
  freshId >>=T λ pid →
  putT promisesT (mkPromise pid subj ten topic deadline PromPending nothing now dir nothing tr col stake pen ref) >>T
  -- П6 (Inc1.1): journal the promise's BIRTH as an event — the head of the pair whose tail is
  -- PromiseSettled/Defaulted, so the append-only log carries the full life of the obligation.
  appendEvent (mkExperienceEvent 0 subj ten Internal System now PromiseDeclared 0
                nothing nothing nothing nothing false false
                ("{\"promise\":" <> showℕ pid <> "}") nothing) >>T
  returnT pid

-- legacy form: our non-transferable promise with no collateral/stake (call-sites keep compiling)
createPromise : (subject : ℕ) (topic : String) (deadline tenant now : ℕ) → Txn ℕ
createPromise subj topic deadline ten now =
  createPromiseDirected subj topic deadline Ours false 0 nothing nothing false ten now

markPromiseFulfilled : (pid : ℕ) → Txn ⊤
markPromiseFulfilled pid =
  requireT promisesT NotFound pid >>=T λ p →
  putT promisesT (record p { pmStatus = PromFulfilled })

markPromiseBroken : (pid : ℕ) → Txn ⊤
markPromiseBroken pid =
  requireT promisesT NotFound pid >>=T λ p →
  putT promisesT (record p { pmStatus = PromBroken })

------------------------------------------------------------------------
-- Promise futures — the clearing lifecycle (Concept Ч.2 §3, upgrade-план A3). Each command is
-- ONE Txn: the state change + its clearing-journal ExperienceEvent (append-only log = clearing
-- journal). Guards: only a PENDING promise moves; listing/transfer need pmTransferable.
------------------------------------------------------------------------

private
  pendingᵖ : PromStatus → Bool
  pendingᵖ PromPending = true
  pendingᵖ _           = false

  clearingEvent : (ty : EventType) (subject : ℕ) (payload : String) (tenant now : ℕ) → Txn ℕ
  clearingEvent ty subj pl ten now =
    appendEvent (mkExperienceEvent 0 subj ten Internal System now ty 0
                  nothing nothing nothing nothing false false pl nothing)

-- offer a transferable promise for transfer (the promise itself is unchanged — listing is a
-- journal fact); returns the event id
listPromise : (pid tenant now : ℕ) → Txn ℕ
listPromise pid ten now =
  requireT promisesT NotFound pid >>=T λ p →
  guardT (pmTransferable p) (Invariant "not transferable") >>T
  guardT (pendingᵖ (pmStatus p)) InvalidTransition >>T
  clearingEvent PromiseListed (pmSubject p) ("{\"promise\":" <> showℕ pid <> "}") ten now

-- П6: SELL the claim — reassign the recipient (gift/resale). The claim on the stake follows the
-- field: an explicit `newPenaltyTo` (just = the new holder's payout account) updates who is
-- compensated on default; nothing keeps it. Mutate in place, pmId stable (provenance in the log).
transferPromise : (pid newHolder : ℕ) (newPenaltyTo : Maybe ℕ) (tenant now : ℕ) → Txn ⊤
transferPromise pid newHolder newPen ten now =
  requireT promisesT NotFound pid >>=T λ p →
  guardT (pmTransferable p) (Invariant "not transferable") >>T
  guardT (pendingᵖ (pmStatus p)) InvalidTransition >>T
  requireT subjectsT NotFound newHolder >>T
  putT promisesT (record p { pmHolder = just newHolder
                           ; pmPenaltyTo = maybe′ just (pmPenaltyTo p) newPen }) >>T
  clearingEvent PromiseTransferred (pmSubject p)
    ("{\"promise\":" <> showℕ pid <> ",\"holder\":" <> showℕ newHolder <> "}") ten now >>T
  returnT tt

-- П6: REFER the duty — reassign the obligor (referral to a colleague). The stake moves with the
-- duty: release the old staker, charge the new one (proof-gated ⇒ referral only succeeds if the
-- new obligor can post the stake; if they can't, the whole Txn rolls back and nothing moved).
referPromise : (pid newStakeAccount tenant now : ℕ) → Txn ⊤
referPromise pid newStake ten now =
  requireT promisesT NotFound pid >>=T λ p →
  guardT (pmReferable p) (Invariant "not referable") >>T
  guardT (pendingᵖ (pmStatus p)) InvalidTransition >>T
  releaseStakeᵗ (pmStakeAccount p) (pmCollateral p) >>T
  holdStakeᵗ (just newStake) (pmCollateral p) >>T
  putT promisesT (record p { pmStakeAccount = just newStake }) >>T
  clearingEvent PromiseTransferred (pmSubject p)
    ("{\"promise\":" <> showℕ pid <> ",\"obligor_stake\":" <> showℕ newStake <> "}") ten now >>T
  returnT tt

-- honour a pending promise: RELEASE the stake back to the staker, journal PromiseSettled.
settlePromise : (pid tenant now : ℕ) → Txn ⊤
settlePromise pid ten now =
  requireT promisesT NotFound pid >>=T λ p →
  guardT (pendingᵖ (pmStatus p)) InvalidTransition >>T
  releaseStakeᵗ (pmStakeAccount p) (pmCollateral p) >>T
  putT promisesT (record p { pmStatus = PromFulfilled }) >>T
  clearingEvent PromiseSettled (pmSubject p) ("{\"promise\":" <> showℕ pid <> "}") ten now >>T
  returnT tt

-- break a pending promise: FIRE the declared consequence — route the held stake (compensate the
-- penaltyTo account, or forfeit) AND journal PromiseDefaulted (the always-emitted reputation
-- consequence). Both in this ONE Txn: broken ⟹ consequence is atomic (the platform's guarantee).
defaultPromise : (pid tenant now : ℕ) → Txn ⊤
defaultPromise pid ten now =
  requireT promisesT NotFound pid >>=T λ p →
  guardT (pendingᵖ (pmStatus p)) InvalidTransition >>T
  routePenaltyᵗ (pmStakeAccount p) (pmPenaltyTo p) (pmCollateral p) >>T
  putT promisesT (record p { pmStatus = PromBroken }) >>T
  clearingEvent PromiseDefaulted (pmSubject p) ("{\"promise\":" <> showℕ pid <> "}") ten now >>T
  returnT tt

------------------------------------------------------------------------
-- Protocol + Episode (transition checked for admissibility against the protocol)
------------------------------------------------------------------------

createProtocol : (name : String) (initialState tenant now : ℕ) → Txn ℕ
createProtocol name ini ten now =
  freshId >>=T λ pid →
  putT protocolsT (mkProtocol pid ten name ini now) >>T returnT pid

-- protocol DEFINITION rows (audit fix: transitionEpisode guards on ProtocolTransition rows, but
-- nothing could CREATE them — lines were stuck in their initial state). States and allowed
-- transitions are config-as-data (Ч.5 §1): the operator/pack defines them per protocol.
addProtocolState : (protocol stateCode : ℕ) (name : String) (tenant : ℕ) → Txn ℕ
addProtocolState proto code name ten =
  requireT protocolsT NotFound proto >>T
  freshId >>=T λ sid →
  putT protocolStatesT (mkProtocolState sid proto code name ten) >>T returnT sid

addProtocolTransition : (protocol fromState toState tenant : ℕ) → Txn ℕ
addProtocolTransition proto frm to ten =
  requireT protocolsT NotFound proto >>T
  freshId >>=T λ tid →
  putT protocolTransitionsT (mkProtocolTransition tid proto frm to ten) >>T returnT tid

-- find a protocol by name, or create it (idempotent seed — a pack ensures its own package/booking
-- protocol exists without a startup step or a hard-coded id; neutral: the NAME lives in the pack).
ensureProtocol : (name : String) (initialState tenant now : ℕ) → Txn ℕ
ensureProtocol name ini ten now =
  scanT protocolsT >>=T λ ps → go (findByName ps)
  where
    findByName : List (ℕ × Protocol) → Maybe ℕ
    findByName []             = nothing
    findByName ((i , p) ∷ rest) =
      if primStringEquality (prName p) name then just i else findByName rest
    go : Maybe ℕ → Txn ℕ
    go (just i) = returnT i
    go nothing  = createProtocol name ini ten now

createEpisode : (subject protocol : ℕ) (jtbd : String) (tenant now : ℕ) → Txn ℕ
createEpisode subj proto jtbd ten now =
  requireT subjectsT NotFound subj  >>T
  requireT protocolsT NotFound proto >>=T λ pr →
  freshId >>=T λ eid →
  putT episodesT (mkEpisode eid subj proto ten (prInitialState pr) jtbd nothing nothing now nothing)
  >>T returnT eid

private
  -- is there an allowed protocol transition from `frm` to `to` among these transition rows?
  hasTrans : (frm to : ℕ) → List ℕ → Txn Bool
  hasTrans _   _  []       = returnT false
  hasTrans frm to (i ∷ is) =
    getT protocolTransitionsT i >>=T λ mpt →
    check mpt
    where
      check : Maybe ProtocolTransition → Txn Bool
      check nothing   = hasTrans frm to is
      check (just pt) = if (ptFromState pt ≡ᵇ frm) ∧ (ptToState pt ≡ᵇ to)
                        then returnT true else hasTrans frm to is

-- move an episode to `toState` iff the protocol allows it; log a Transition child AND an
-- append-only LifecycleChange ExperienceEvent (§4.9). Returns the transition id.
transitionEpisode : (episode toState tenant now : ℕ) → Txn ℕ
transitionEpisode epi toState ten now =
  requireT episodesT NotFound epi >>=T λ e →
  byIndexT protocolTransitionsT ptByProtocol (epProtocol e) >>=T λ ptIds →
  hasTrans (epCurrentState e) toState ptIds >>=T λ ok →
  guardT ok InvalidTransition >>T
  freshId >>=T λ trid →
  putT transitionsT (mkTransition trid epi (epCurrentState e) toState now 0 ten) >>T
  putT episodesT (record e { epCurrentState = toState }) >>T
  appendEvent (mkExperienceEvent 0 (epSubject e) ten Internal System now LifecycleChange toState
                (just epi) nothing nothing nothing false false "episode.transition" nothing) >>T
  returnT trid

------------------------------------------------------------------------
-- Users / RBAC (policy + checks live in agdelte-auth; this is the data half)
------------------------------------------------------------------------

createUser : (login passHash : String) (tenant now : ℕ) → Txn ℕ
createUser login ph ten now =
  freshId >>=T λ uid → putT usersT (mkUser uid ten login ph now) >>T returnT uid

private
  findByLogin : String → List (ℕ × User) → Maybe User
  findByLogin _     []             = nothing
  findByLogin login ((_ , u) ∷ us) =
    if primStringEquality (uLogin u) login then just u else findByLogin login us

findUserByLogin : String → Txn (Maybe User)
findUserByLogin login = scanT usersT >>=T λ us → returnT (findByLogin login us)

assignRole : (subject roleId scope : String) (tenant now : ℕ) → Txn ℕ
assignRole subj role scope ten now =
  freshId >>=T λ aid →
  putT assignmentsT (mkAssignment aid ten subj role scope now) >>T returnT aid

private
  -- ids of assignments matching (subject, role, scope)
  matchAssign : (subj role scope : String) → List (ℕ × RoleAssignment) → List ℕ
  matchAssign _    _    _     []             = []
  matchAssign subj role scope ((i , a) ∷ as) =
    if primStringEquality (raSubject a) subj ∧ primStringEquality (raRoleId a) role
         ∧ primStringEquality (raScope a) scope
    then i ∷ matchAssign subj role scope as
    else matchAssign subj role scope as

  -- role assignments held by a principal
  rolesOf : String → List (ℕ × RoleAssignment) → List RoleAssignment
  rolesOf _    []             = []
  rolesOf subj ((_ , a) ∷ as) =
    if primStringEquality (raSubject a) subj then a ∷ rolesOf subj as else rolesOf subj as

revokeRole : (subject roleId scope : String) → Txn ⊤
revokeRole subj role scope =
  scanT assignmentsT >>=T λ as →
  forEachT (matchAssign subj role scope as) (delT assignmentsT)

scopedRolesOf : String → Txn (List RoleAssignment)
scopedRolesOf subj = scanT assignmentsT >>=T λ as → returnT (rolesOf subj as)

-- idempotent bootstrap: ensure an admin principal exists (create user + admin role if none)
-- Integration tokens (§7.7): runtime-minted, store-backed site credentials for the public /v1
-- surface. The bearer secret `tok` is generated at the IO edge (crypto random) and passed in.
-- Revocation is soft (sets itkRevokedAt) so an audit trail of issued tokens survives.
createIntegrationToken : (token scope origin : String) (tenant now : ℕ) → Txn ℕ
createIntegrationToken tok scope origin ten now =
  freshId >>=T λ tid →
  putT integrationTokensT (mkIntTokenRow tid ten tok scope origin now nothing) >>T returnT tid

revokeIntegrationToken : (tokenId now : ℕ) → Txn ⊤
revokeIntegrationToken tid now =
  requireT integrationTokensT NotFound tid >>=T λ r →
  putT integrationTokensT (record r { itkRevokedAt = just now })

ensureAdmin : (login passHash scope : String) (tenant now : ℕ) → Txn ⊤
ensureAdmin login ph scope ten now =
  findUserByLogin login >>=T λ mu →
  check mu
  where
    check : Maybe User → Txn ⊤
    check (just _) = returnT tt                             -- already present → no-op
    check nothing  =
      createUser login ph ten now >>T
      assignRole login "admin" scope ten now >>T returnT tt

------------------------------------------------------------------------
-- Reminders — protocol/deadline-based, idempotent (ported from CRM activity reminders)
------------------------------------------------------------------------

private
  pendingᵇ : PromStatus → Bool
  pendingᵇ PromPending = true
  pendingᵇ _           = false

  notRemindedᵇ : Maybe ℕ → Bool
  notRemindedᵇ nothing  = true
  notRemindedᵇ (just _) = false

  dueᵇ : ℕ → Promise → Bool
  dueᵇ deadline p = pendingᵇ (pmStatus p) ∧ (pmDeadline p ≤ᵇ deadline) ∧ notRemindedᵇ (pmRemindedAt p)

-- promise ids whose deadline is within [now, now+window] and not yet reminded
dueReminders : (now window : ℕ) → Txn (List ℕ)
dueReminders now window =
  scanT promisesT >>=T λ ps →
  returnT (foldr (λ pr acc → if dueᵇ (now + window) (proj₂ pr) then proj₁ pr ∷ acc else acc) [] ps)

markReminded : (pid now : ℕ) → Txn ⊤
markReminded pid now =
  requireT promisesT NotFound pid >>=T λ p →
  putT promisesT (record p { pmRemindedAt = just now })

------------------------------------------------------------------------
-- Seeding (Phase-5 audit #C, §9.8): write the configured tenants into an empty store at start.
-- The default tenant is thereby present as a real row; single-operator collapses to it.
------------------------------------------------------------------------

seedTenants : List Tenant → Txn ⊤
seedTenants ts = forEachT ts (putT tenantsT)

------------------------------------------------------------------------
-- Booking (Phase 11): the appointment vertical, NATIVE in the core. A resource's busy set is its
-- SCHEDULED appointments; a slot is bookable iff it does not overlap them (Cxm.Schedule). Credits
-- (a prepaid package) live as an Episode's non-canceled appointment count vs an Entitlement grant.
------------------------------------------------------------------------

private
  apScheduledᵇ : ApptStatus → Bool
  apScheduledᵇ ApScheduled = true
  apScheduledᵇ _           = false

  apConsumesᵇ : ApptStatus → Bool          -- a canceled appointment frees its credit
  apConsumesᵇ ApCanceled = false
  apConsumesᵇ _          = true

  matchEpᵇ : Maybe ℕ → ℕ → Bool
  matchEpᵇ (just e) ep = e ≡ᵇ ep
  matchEpᵇ nothing  _  = false

-- a resource's live scheduled appointments as busy [start, start+dur) intervals (pure over Base).
-- (audit #B: not tenant-filtered — fine for single-operator; add a tenant guard for multi-tenant.)
resourceBusy : Base → (resource : ℕ) → List Interval
resourceBusy b res = foldr step [] (tscan appointmentsT b)
  where step : (ℕ × Appointment) → List Interval → List Interval
        step p acc = let a = proj₂ p in
          if (apResource a ≡ᵇ res) ∧ apScheduledᵇ (apStatus a)
          then (apStartsAt a , apStartsAt a + apDurationMin a * 60) ∷ acc else acc

-- prepaid sessions consumed by an episode (non-canceled appointments) — credit accounting
sessionsUsedForEpisode : Base → (episode : ℕ) → ℕ
sessionsUsedForEpisode b ep = foldr step 0 (tscan appointmentsT b)
  where step : (ℕ × Appointment) → ℕ → ℕ
        step p acc = let a = proj₂ p in
          if matchEpᵇ (apEpisode a) ep ∧ apConsumesᵇ (apStatus a) then suc acc else acc

-- book a slot on a resource: rejects (Conflict) if it overlaps the resource's scheduled set.
-- Slot validity (on-grid / notice / horizon, Cxm.Schedule.validateSlot) is a caller precondition.
bookAppointment : (subject resource : ℕ) (episode entitlement : Maybe ℕ)
                  (startsAt durationMin tenant now : ℕ) → Txn ℕ
bookAppointment subj res ep ent start dur ten now =
  requireT subjectsT NotFound subj >>T
  getBase >>=T λ b →
  guardT (slotFree start (dur * 60) (resourceBusy b res)) Conflict >>T
  freshId >>=T λ aid →
  putT appointmentsT (mkAppointment aid subj res ep ent start dur ApScheduled nothing ten now nothing) >>T
  returnT aid

-- book against a prepaid package episode, drawing down one credit: rejects Insufficient when the
-- episode's consumed sessions already reached `creditLimit` (the offering's granted count, §B/§C
-- config from the pack), then the usual slot-conflict check via bookAppointment.
bookIntoEpisode : (subject resource episode : ℕ) (entitlement : Maybe ℕ)
                  (creditLimit startsAt durationMin tenant now : ℕ) → Txn ℕ
bookIntoEpisode subj res ep ent limit start dur ten now =
  getBase >>=T λ b →
  guardT (sessionsUsedForEpisode b ep <ᵇ limit) Insufficient >>T
  bookAppointment subj res (just ep) ent start dur ten now

private
  apptTransition : (apptId : ℕ) → ApptStatus → Txn ⊤     -- only a Scheduled appointment transitions
  apptTransition aid to =
    requireT appointmentsT NotFound aid >>=T λ a →
    guardT (apScheduledᵇ (apStatus a)) InvalidTransition >>T
    putT appointmentsT (record a { apStatus = to })

cancelAppointment : (apptId : ℕ) → Txn ⊤                   -- frees the credit
cancelAppointment aid = apptTransition aid ApCanceled

completeAppointment : (apptId : ℕ) → Txn ⊤
completeAppointment aid = apptTransition aid ApCompleted

noShowAppointment : (apptId : ℕ) → Txn ⊤                   -- forfeits the credit
noShowAppointment aid = apptTransition aid ApNoShow

private
  apReopenableᵇ : ApptStatus → Bool                        -- undo a mistaken close-out
  apReopenableᵇ ApCompleted = true
  apReopenableᵇ ApNoShow    = true
  apReopenableᵇ _           = false

-- Completed/NoShow → Scheduled (a correction). Canceled is NOT reopened (it freed the slot).
-- NOTE (audit #3): does not re-check slot-freedom — if the slot was rebooked meanwhile, reopen can
-- resurrect a conflicting appointment (CRM parity); a UI should confirm before reopening.
reopenAppointment : (apptId : ℕ) → Txn ⊤
reopenAppointment aid =
  requireT appointmentsT NotFound aid >>=T λ a →
  guardT (apReopenableᵇ (apStatus a)) InvalidTransition >>T
  putT appointmentsT (record a { apStatus = ApScheduled })

------------------------------------------------------------------------
-- Outbox notifications (§4.15): durable notification INTENT, written in the txn; a worker
-- delivers (external IO) then marks Sent. `enqueueNotification` composes with domain changes.
------------------------------------------------------------------------

enqueueNotification : (channel to subject body : String) (tenant now : ℕ) → Txn ℕ
enqueueNotification ch to subj body ten now =
  freshId >>=T λ oid →
  putT outboxT (mkOutbox oid ch to subj body OutPending ten now 0 nothing) >>T returnT oid

markSent : (outId : ℕ) → Txn ⊤
markSent oid =
  requireT outboxT NotFound oid >>=T λ o →
  putT outboxT (record o { obStatus = OutSent })

-- drain the outbox: mark every OutPending entry Sent (after a worker delivered), return the count.
-- (index key 0 = OutPending, osCode OutPending = 0.)
drainOutbox : Txn ℕ
drainOutbox =
  byIndexT outboxT outByStatus 0 >>=T λ ids →
  forEachT ids markSent >>T returnT (length ids)

------------------------------------------------------------------------
-- Outbox delivery retries (upgrade-план D2). The worker (Cxm.Worker) picks DUE pending entries,
-- attempts delivery through a caller-supplied transport (headless: the core knows no network),
-- then markSent / markAttempt. Backoff is a pure quadratic-with-cap schedule.
------------------------------------------------------------------------

-- attempts → seconds until the next try: 60·n², capped at 3600 (refl-testable)
backoffSec : ℕ → ℕ
backoffSec n = let d = n * n * 60 in if 3600 <ᵇ d then 3600 else d

private
  obDueᵇ : (now : ℕ) → OutboxEntry → Bool
  obDueᵇ now o = maybe′ (λ t → t + backoffSec (obAttempts o) ≤ᵇ now) true (obLastAttempt o)

-- pending entries whose backoff window has elapsed (never-tried ⇒ due immediately)
dueOutbox : (now : ℕ) → Txn (List ℕ)
dueOutbox now =
  byIndexT outboxT outByStatus 0 >>=T λ ids →
  getBase >>=T λ b →
  returnT (foldr (λ i acc → if check i b then i ∷ acc else acc) [] ids)
  where
    check : ℕ → Base → Bool
    check i b = maybe′ (obDueᵇ now) false (tget outboxT i b)

-- record a failed attempt: attempts+1, stamp lastAttempt; at maxAttempts the entry goes
-- OutFailed (an audit row — never silently dropped)
markAttempt : (oid now maxAttempts : ℕ) → Txn ⊤
markAttempt oid now maxAtt =
  requireT outboxT NotFound oid >>=T λ o →
  putT outboxT (record o { obAttempts    = suc (obAttempts o)
                         ; obLastAttempt = just now
                         ; obStatus      = if maxAtt ≤ᵇ suc (obAttempts o) then OutFailed else OutPending })

------------------------------------------------------------------------
-- Appointment reminders (native, on Appointment.apStartsAt — NOT the Promise-based dueReminders).
-- Idempotent via `apRemindedAt` (audit-2 #2/#3). A cron: dueAppointmentReminders → enqueue → mark.
------------------------------------------------------------------------

private
  -- scheduled, starts within [now, windowEnd] (UPCOMING — not past, audit #1), not yet reminded
  apDueᵇ : (now windowEnd : ℕ) → Appointment → Bool
  apDueᵇ now we a =
    apScheduledᵇ (apStatus a) ∧ (now ≤ᵇ apStartsAt a) ∧ (apStartsAt a ≤ᵇ we) ∧ notRemindedᵇ (apRemindedAt a)

-- ids of scheduled appointments starting within [now, now+lead] that have not been reminded yet
dueAppointmentReminders : (now lead : ℕ) → Txn (List ℕ)
dueAppointmentReminders now lead =
  scanT appointmentsT >>=T λ as →
  returnT (foldr (λ p acc → if apDueᵇ now (now + lead) (proj₂ p) then proj₁ p ∷ acc else acc) [] as)

markApptReminded : (apptId now : ℕ) → Txn ⊤
markApptReminded aid now =
  requireT appointmentsT NotFound aid >>=T λ a →
  putT appointmentsT (record a { apRemindedAt = just now })

private
  -- the subject's verified/first "email" Identity value, "" if none (for reminder delivery)
  emailOfSubject : ℕ → List (ℕ × Identity) → String
  emailOfSubject _    []             = ""
  emailOfSubject subj ((_ , i) ∷ is) =
    if (iSubject i ≡ᵇ subj) ∧ primStringEquality (iChannel i) "email"
    then iExternalId i else emailOfSubject subj is

-- run the reminder cron in ONE Txn: for each due appointment, enqueue a reminder to the subject's
-- email (resolved from Identity — audit fix) and mark it reminded (idempotent). Returns the count.
remindDueAppointments : (now lead : ℕ) → Txn ℕ
remindDueAppointments now lead =
  scanT identitiesT >>=T λ ids →
  dueAppointmentReminders now lead >>=T λ appts →
  forEachT appts (remindOne ids) >>T returnT (length appts)
  where
    remindOne : List (ℕ × Identity) → ℕ → Txn ⊤
    remindOne ids aid = getT appointmentsT aid >>=T doIt
      where
        doIt : Maybe Appointment → Txn ⊤
        doIt nothing  = returnT tt
        doIt (just a) =
          enqueueNotification "email" (emailOfSubject (apSubject a) ids)
                              "Напоминание о встрече" "Ваша встреча скоро." (apTenant a) now >>T
          markApptReminded aid now

------------------------------------------------------------------------
-- Domain bus dispatch (§4.15, at-least-once): mark every unprocessed Event processed, return
-- how many. The external delivery happens outside the Txn (a worker); this is the idempotent
-- state flip a dispatcher runs after delivering.
------------------------------------------------------------------------

private
  markBusProcessed : ℕ → Txn ⊤
  markBusProcessed id =
    requireT busEventsT NotFound id >>=T λ e → putT busEventsT (record e { evProcessed = true })

dispatchBus : Txn ℕ
dispatchBus =
  byIndexT busEventsT busByProcessed 0 >>=T λ ids →     -- index key 0 = unprocessed (Bool false)
  forEachT ids markBusProcessed >>T returnT (length ids)

------------------------------------------------------------------------
-- Site integration (Phase 9, §7.7): identity bridge + canonical event ingest + merge-on-login.
------------------------------------------------------------------------

-- bind a channel identifier (cookie / user_id / email …) to a subject
bindIdentity : (subject : ℕ) (channel externalId : String) (verified : Bool) (tenant now : ℕ) → Txn ℕ
bindIdentity subj ch ext v ten now =
  freshId >>=T λ iid → putT identitiesT (mkIdentity iid subj ch ext v ten now) >>T returnT iid

private
  emptyᵇ : String → Bool
  emptyᵇ s = primStringEquality s ""

  -- bind only when there is a real external id (audit #C: an empty id must NOT collapse distinct
  -- anonymous visitors into one subject via a shared ("cookie","") Identity)
  bindIfId : (subject : ℕ) (channel externalId : String) (tenant now : ℕ) → Txn ⊤
  bindIfId subj ch ext ten now =
    if emptyᵇ ext then returnT tt else (bindIdentity subj ch ext false ten now >>T returnT tt)

-- the SINGLE entry of facts from the site (§7.7): resolve the channel id to a subject, else spin
-- up a provisional subject (+ Identity when the id is non-empty) so no fact is lost (§4.4), then
-- append the event on it. An empty external id always provisions a FRESH subject (no binding).
ingestSiteEvent : (channel externalId : String) (tenant now : ℕ) (ev : ExperienceEvent) → Txn ℕ
ingestSiteEvent ch ext ten now ev =
  scanT identitiesT >>=T λ ids →
  resolve (if emptyᵇ ext then nothing else findIdentityIn ch ext (map proj₂ ids))
  where
    resolve : Maybe ℕ → Txn ℕ
    resolve (just s) = appendEvent (record ev { eeSubject = s })
    resolve nothing  =
      provisionalSubject "anon" "UTC" ten now >>=T λ s →
      bindIfId s ch ext ten now >>T
      appendEvent (record ev { eeSubject = s })

-- peer ingest (upgrade-план B3, §0.6/слой IX): a TWO-subject event from an integrated space —
-- resolve (or provision) BOTH sides through the same identity bridge, then append with
-- eeCounterpart set. Empty counterpart id ⇒ degrades to plain ingestSiteEvent.
ingestPeerEvent : (channel externalId cpChannel cpExternalId : String)
                  (tenant now : ℕ) (ev : ExperienceEvent) → Txn ℕ
ingestPeerEvent ch ext cch cext ten now ev = go (emptyᵇ cext)
  where
    resolveOne : (channel externalId : String) → Txn ℕ
    resolveOne c e =
      scanT identitiesT >>=T λ ids →
      pick (if emptyᵇ e then nothing else findIdentityIn c e (map proj₂ ids))
      where
        pick : Maybe ℕ → Txn ℕ
        pick (just s) = returnT s
        pick nothing  = provisionalSubject "anon" "UTC" ten now >>=T λ s →
                        bindIfId s c e ten now >>T returnT s
    go : Bool → Txn ℕ
    go true  = ingestSiteEvent ch ext ten now ev
    go false =
      resolveOne cch cext >>=T λ cp →
      resolveOne ch ext   >>=T λ s →
      appendEvent (record ev { eeSubject = s ; eeCounterpart = just cp })

-- resolve a channel id to an existing subject, else create one + bind the id (identity bridge,
-- §7.7) — so a returning client (same email/cookie) reuses their subject instead of duplicating.
-- Empty id ⇒ always a fresh subject (no shared blank Identity). Used by public booking ingest.
resolveOrCreateSubject : (channel externalId name tz : String) (tenant now : ℕ) → Txn ℕ
resolveOrCreateSubject ch ext name tz ten now =
  scanT identitiesT >>=T λ ids →
  go (if emptyᵇ ext then nothing else findIdentityIn ch ext (map proj₂ ids))
  where
    go : Maybe ℕ → Txn ℕ
    go (just s) = returnT s
    go nothing  = freshId >>=T λ sid →
                  putT subjectsT (mkSubject sid EXTERNAL Person name tz now nothing ten nothing nothing false) >>T
                  bindIfId sid ch ext ten now >>T returnT sid

-- on login: if the login id already resolves to a canonical subject → alias the session's
-- provisional subject into it (merge, §4.4), so pre-login events read as one subject; otherwise
-- (first login) promote the provisional subject — bind the login id AND clear its provisional
-- flag (audit #B), since it is now an identified account.
mergeSession : (provisional : ℕ) (loginChannel loginExtId : String) (tenant now : ℕ) → Txn ⊤
mergeSession prov ch ext ten now =
  scanT identitiesT >>=T λ ids → go (findIdentityIn ch ext (map proj₂ ids))
  where
    go : Maybe ℕ → Txn ⊤
    go (just canon) = merge prov canon
    go nothing      =
      requireT subjectsT NotFound prov >>=T λ s →
      putT subjectsT (record s { sProvisional = false }) >>T
      bindIdentity prov ch ext true ten now >>T returnT tt

------------------------------------------------------------------------
-- Social content (cxm-social-plan S4). Publishing is a Resource + its Publish event in ONE Txn
-- (the log and the content can't diverge); following is the generic follow edge. Reactions need
-- NO command — they are ordinary peer ingest (ingestPeerEvent, type Reaction).
------------------------------------------------------------------------

publishResource : (author : ℕ) (parent : Maybe ℕ) (vis : Maybe String)
                  (payload : String) (listing : Maybe String) (tenant now : ℕ) → Txn ℕ
publishResource author parent vis payload listing ten now =
  requireT subjectsT NotFound author >>T
  createResource parent 1 0 vis payload (just author) listing ten now >>=T λ rid →
  appendEvent (mkExperienceEvent 0 author ten Community Client now Publish 0
                nothing nothing nothing nothing false false
                ("{\"resource\":" <> showℕ rid <> "}") nothing) >>T
  returnT rid

followSubject : (follower author tenant now : ℕ) → Txn ℕ
followSubject follower author ten now =
  addEdge follower author follow nothing 0 now nothing ten now

------------------------------------------------------------------------
-- Blog hygiene (платформа-план П2): EDIT a live content node. payload/vis/listing are PATCHES
-- (nothing = keep the current value; there is no way to RESET a policy to default through this
-- command — set an explicit "public" instead). Every edit stamps rUpdatedAt. Rights are split
-- by CALLER, not here: the operator API calls `updateResource` (behind its JWT/token gate);
-- the public /v1 calls `updateOwnResource` (author-gated — only the author edits their post).
------------------------------------------------------------------------

private
  liveResᵇ : Resource → Bool
  liveResᵇ r = maybe′ (λ _ → false) true (rDeletedAt r)

updateResource : (rid : ℕ) (payload vis listing : Maybe String) (now : ℕ) → Txn ⊤
updateResource rid payload vis listing now =
  requireT resourcesT NotFound rid >>=T λ r →
  guardT (liveResᵇ r) NotFound >>T                    -- a soft-deleted node is not editable
  putT resourcesT (record r
    { rPayload    = maybe′ (λ p → p) (rPayload r) payload
    ; rVisibility = maybe′ just (rVisibility r) vis
    ; rListing    = maybe′ just (rListing r) listing
    ; rUpdatedAt  = just now })

-- the /v1 form: the caller edits ONLY their own post (rAuthor must equal the resolved subject;
-- authorless operator/system content is NOT editable from the public surface — Forbidden)
updateOwnResource : (author rid : ℕ) (payload vis listing : Maybe String) (now : ℕ) → Txn ⊤
updateOwnResource author rid payload vis listing now =
  requireT resourcesT NotFound rid >>=T λ r →
  guardT (maybe′ (λ a → a ≡ᵇ author) false (rAuthor r)) Forbidden >>T
  updateResource rid payload vis listing now

------------------------------------------------------------------------
-- Curation links (cxm-social-plan §8): pin/promote content on a showcase node. A SOLD promo
-- slot = a link whose validTo is the paid-through time (payment fulfilment calls linkResource;
-- expiry needs no worker — showcase reads filter by the window).
------------------------------------------------------------------------

linkResource : (from to : ℕ) (kind : String) (rank : ℕ) (validTo : Maybe ℕ)
               (tenant now : ℕ) → Txn ℕ
linkResource from to kind rank vt ten now =
  requireT resourcesT NotFound from >>T
  requireT resourcesT NotFound to   >>T
  freshId >>=T λ lid →
  putT resourceLinksT (mkResourceLink lid ten from to kind rank now vt now) >>T returnT lid

unlinkResource : (linkId : ℕ) → Txn ⊤
unlinkResource lid = requireT resourceLinksT NotFound lid >>T delT resourceLinksT lid

------------------------------------------------------------------------
-- Conversations-from-anything (§10). `commentOn` writes, in ONE Txn: the comment node (anchor
-- denormalized; streamRoot inherited unless the node carries its OWN policy — §10.5), its
-- ordered Mention rows (F3), and the peer event (first addressee → eeCounterpart).
------------------------------------------------------------------------

-- polymorphic-anchor FK check: a finite dispatch over the core tables (the table set is fixed
-- in Base, so this is total and not a differences-are-data violation)
-- F4 (аудит-фикс): аудитория якоря — participant check for non-resource anchors. resource ⇒
-- true (node policies rule there); unknown kind ⇒ false (closed). Staff/operator reads go
-- through the operator API, not this gate.
anchorParticipantᵇ : Base → (kind : String) → (anchorId subject : ℕ) → Bool
anchorParticipantᵇ b kind ai subj =
  if      eq "resource"    then true
  else if eq "appointment" then maybe′ (λ a → apSubject a ≡ᵇ subj) false (tget appointmentsT ai b)
  else if eq "promise"     then maybe′ pOk false (tget promisesT ai b)
  else if eq "entitlement" then maybe′ (λ e → enSubject e ≡ᵇ subj) false (tget entitlementsT ai b)
  else if eq "subject"     then ai ≡ᵇ subj
  else if eq "episode"     then maybe′ (λ e → epSubject e ≡ᵇ subj) false (tget episodesT ai b)
  else false
  where
    eq : String → Bool
    eq k = primStringEquality kind k
    pOk : Promise → Bool
    pOk p = (pmSubject p ≡ᵇ subj) ∨ maybe′ (λ h → h ≡ᵇ subj) false (pmHolder p)

requireAnchor : (kind : String) (id : ℕ) → Txn ⊤
requireAnchor kind i =
  if      eq "resource"    then (requireT resourcesT NotFound i    >>T returnT tt)
  else if eq "appointment" then (requireT appointmentsT NotFound i >>T returnT tt)
  else if eq "promise"     then (requireT promisesT NotFound i     >>T returnT tt)
  else if eq "entitlement" then (requireT entitlementsT NotFound i >>T returnT tt)
  else if eq "subject"     then (requireT subjectsT NotFound i     >>T returnT tt)
  else if eq "episode"     then (requireT episodesT NotFound i     >>T returnT tt)
  else abort (Invariant "unknown anchor kind")
  where eq : String → Bool
        eq k = primStringEquality kind k

private
  addMentions : (rid tenant : ℕ) → ℕ → List ℕ → Txn ⊤
  addMentions _   _   _   []       = returnT tt
  addMentions rid ten ord (s ∷ ss) =
    requireT subjectsT NotFound s >>T
    freshId >>=T λ mid →
    putT mentionsT (mkMention mid rid s ord ten) >>T
    addMentions rid ten (suc ord) ss

  headOr : List ℕ → Maybe ℕ
  headOr []      = nothing
  headOr (x ∷ _) = just x

-- comment on ANY entity. Root comment: parent = nothing, anchor given. Reply: parent given —
-- anchor AND streamRoot inherit from the parent; a node with its OWN visibility starts a new
-- stream (streamRoot = own id). Addressees: ordered, first = primary (→ eeCounterpart).
commentOn : (author : ℕ) (anchorKind : String) (anchorId : ℕ) (parent : Maybe ℕ)
            (vis listing : Maybe String) (payload : String) (addressees : List ℕ)
            (tenant now : ℕ) → Txn ℕ
commentOn author ak ai parent vis listing payload tos ten now =
  requireT subjectsT NotFound author >>T
  freshId >>=T λ rid →
  resolveCtx rid parent >>=T λ ctx →
  getBase >>=T λ b →
  -- F4 (аудит-фикс): the AUTHOR must belong to the anchor's audience (a stranger cannot start
  -- or join a conversation on somebody else's booking/promise/grant)
  guardT (anchorParticipantᵇ b (ccAnchorKind ctx) (ccAnchorId ctx) author) Forbidden >>T
  putT resourcesT (mkResource rid ten parent 1 0 vis payload now nothing (just author) listing
                    (just ctx) nothing) >>T
  addMentions rid ten 0 tos >>T
  appendEvent (mkExperienceEvent 0 author ten Community actorOf now Reaction 0
                nothing nothing nothing nothing false false
                ("{\"resource\":" <> showℕ rid <> "}") (headOr tos)) >>T
  returnT rid
  where
    actorOf : Actor
    actorOf = Peer
    -- (anchorKind, anchorId, streamRoot) for this node
    resolveCtx : ℕ → Maybe ℕ → Txn ConvCtx
    resolveCtx rid nothing  =
      requireAnchor ak ai >>T
      returnT (mkConvCtx ak ai rid)                               -- root comment = stream root
    resolveCtx rid (just p) =
      requireT resourcesT NotFound p >>=T λ par →
      returnT (inherit par)
      where
        ownStream : ℕ → ℕ
        ownStream inherited = maybe′ (λ _ → rid) inherited vis    -- own policy ⇒ new stream
        -- аудит-фикс #2: a reply under a PLAIN node (no anchor — an ordinary post) anchors the
        -- conversation to THAT node ("resource", p) — the request's ak/ai are IGNORED on replies
        -- (never trusted unvalidated)
        inherit : Resource → ConvCtx
        inherit par with rAnchorKind par | rAnchorId par
        ... | just k  | just x  = mkConvCtx k x (ownStream (maybe′ (λ s → s) p (rStreamRoot par)))
        ... | _       | _       = mkConvCtx "resource" p (ownStream (maybe′ (λ s → s) p (rStreamRoot par)))

