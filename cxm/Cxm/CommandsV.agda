{-# OPTIONS --without-K #-}

-- Ф2 command port, pack #1: identity/subject cluster on the verb layer (Cxm.Store.Verbs).
-- Same notation as Cxm.Commands, plus the RC lock discipline made explicit:
--   * bindIdentityV      — STRENGTHENED vs the old raw bindIdentity: root lock + existence +
--                          tenant guard (existence-hidden NotFound), bounded byCol lookup;
--   * verifyIdentityV    — the read → lockRoot → RE-READ under the lock pattern (+ a Conflict
--                          guard that the root did not move between the peek and the lock);
--   * resolveOrCreateSubjectV — THE create-if-absent: serialized by an advisory key
--                          (nsIdentityCreate, hashKey "ch:ext") — the PG race the plan predicted;
--   * enqueueNotificationV — outbox is a queue table (root-exempt put);
--   * bindIdentityNotifyV  — the TWO-COMMIT HANDLER REVISION: bind + verification mail are ONE
--                          atom; the mail body depends on the fresh id via a host-glue function
--                          (the HMAC token is computed by the Api layer, which owns the secret).
module Cxm.CommandsV where

open import Agda.Builtin.String using (String; primStringEquality)
open import Agda.Builtin.Unit using (⊤; tt)
open import Data.Bool using (Bool; true; false; if_then_else_; _∧_)
open import Data.List using (List; []; _∷_; foldr)
open import Data.Maybe using (Maybe; just; nothing; maybe′)
open import Data.Nat using (ℕ; _≡ᵇ_; _+_; _*_)
open import Data.Product using (_×_; _,_)
open import Data.String using () renaming (_++_ to _<>_)

open import Data.Bool using (not)
open import Cxm.Subject using (Subject; mkSubject; sTenant; sDeletedAt; sCanonical; sProvisional; SubjectKind; SubjectStructure; EXTERNAL; Person)
open import Cxm.Edge using (SubjectEdge; mkEdge; EdgeKind; follow)
open import Cxm.Tenant using (Tenant; mkTenant)
open import Cxm.Users using (User; mkUser; mkAssignment; RoleAssignment; raSubject; raRoleId; raScope)
open import Cxm.Expectation using (mkExpectation; ExpSource; ExpStatus; ExpUnknown; xpSubject; xpTenant; xpStatus; mkPromise; PromPending; Ours)
open import Cxm.Collections using (mkTransition; ptFromState; ptToState; mkProtocolState; mkProtocolTransition)
open import Cxm.Protocol using (mkProtocol)
open import Cxm.Episode using (epSubject; epProtocol; epCurrentState)
open import Cxm.Site using (mkIntTokenRow; itkTenant; itkRevokedAt)
open import Cxm.Event using (mkExperienceEvent; eeId; Internal; System; PromiseDeclared; LifecycleChange; Community; Client; Publish)
open import Data.Nat.Show using (show)
open import Cxm.Identity
open import Cxm.Knowledge
open import Cxm.Collections using (mkEvidence)
open import Cxm.Episode using (mkEpisode)
open import Cxm.Event using (ExperienceEvent; eeSubject; eePayload; eeEmotion)
open import Cxm.Protocol using (Protocol; prInitialState; prName)
open import Cxm.Bus using (OutboxEntry; mkOutbox; OutPending; OutSent; OutFailed; obStatus; obAttempts; obLastAttempt; evProcessed)
open import Cxm.Appointment using
  ( Appointment; mkAppointment; apSubject; apResource; apStartsAt; apDurationMin; apStatus
  ; ApptStatus; ApScheduled; ApCanceled; ApNoShow; ApCompleted )
open import Cxm.Schedule using (Interval; slotFree)
open import Cxm.Offering using (Offering; mkOffering; oMetadata; oDeletedAt)
open import Cxm.Payment using (Payment; mkPayment; paySubject; payStatus; payTenant; payOffering; payEntitlement; PayStatus; PayPending; PaySucceeded)
open import Cxm.Fulfilment using (Grant; gKind; gTarget; parseFulfilment)
open import Cxm.Resource using (Resource; mkResource; rPayload; rVisibility; rListing; rUpdatedAt; rDeletedAt; rAuthor; rAnchorKind; rAnchorId; rStreamRoot; ConvCtx; mkConvCtx; ccAnchorKind; ccAnchorId; ResourceLink; mkResourceLink; rlFrom; Mention; mkMention)
open import Cxm.Expectation using (Promise; pmDeadline; pmRemindedAt)
open import Cxm.Appointment using (apRemindedAt; apTenant)
open import Cxm.Event using (Community; Client; Peer; Publish; Reaction; eeCounterpart)
open import Cxm.Store.Base using (Forbidden)
open import Data.Nat using (_≤ᵇ_)
open import Data.List using (length)
open import Data.Product using (proj₁; proj₂)
open import Data.Bool using (_∨_)
open import Cxm.Expectation using (mkPromise; PromStatus; PromPending; PromFulfilled; PromBroken; PromDirection; Ours; pmSubject; pmStatus; pmTransferable; pmReferable; pmCollateral; pmStakeAccount; pmPenaltyTo; pmHolder)
open import Cxm.Event using (EventType; PromiseDeclared; PromiseListed; PromiseTransferred; PromiseSettled; PromiseDefaulted)
open import Data.Nat using (_≤?_; suc; _≤_; _∸_; _<ᵇ_)
open import Relation.Nullary using (yes; no)
open import Cxm.Store.Base using (Insufficient)
open import Cxm.Entitlement using (EntTarget; EntSource; mkEntitlement; TOffering; SPayment; enSubject)
open import Cxm.Account using (Account; mkAccount; acBalance)
open import Cxm.Store.Base using
  ( Err; NotFound; Conflict; Invariant; InvalidTransition
  ; edgeByFrom; edgeByTo; identBySubject; entBySubject; epBySubject; knowBySubject; ptByProtocol
  ; expBySubject; promBySubject; paymentBySubject; apptBySubject; evdByKnowledge
  ; trByEpisode; dvByEpisode; outByStatus; busByProcessed )
open import Cxm.Store.Verbs
open import Cxm.Knowledge using (KRevision; KStrengthen; KWeaken; KConfirm; KRefute; KSupersede; KRedetail)
open import Cxm.Inference using (strengthen; weaken; confirm; refute; supersede)

private
  emptyStr : String → Bool
  emptyStr s = primStringEquality s ""

  -- balance ≥ 0 by construction (proof-gated debit); result is the true difference. Moved here
  -- verbatim from the retired Cxm.Commands (WAL) — the invariant lives in the TYPE, not a check.
  debit : (bal amt : ℕ) → amt ≤ bal → ℕ
  debit bal amt _ = bal ∸ amt

  -- worker retry backoff (seconds): quadratic, capped at 1h. Also from the retired Cxm.Commands.
  backoffSec : ℕ → ℕ
  backoffSec n = let d = n * n * 60 in if 3600 <ᵇ d then 3600 else d

  -- mirrored from the retired Cxm.Commands (private there)
  isFactK : Knowledge → Bool
  isFactK k with kType k
  ... | FACT = true
  ... | _    = false

  regradesConf : KRevision → Bool
  regradesConf (KStrengthen _) = true
  regradesConf (KWeaken _)     = true
  regradesConf KRefute         = true
  regradesConf _               = false

------------------------------------------------------------------------
-- bindIdentity (strengthened): lock the subject root, guard tenant, find-or-create the binding
------------------------------------------------------------------------

bindIdentityV : (subject : ℕ) (channel externalId : String) (verified : Bool) (tenant now : ℕ) → Tx ℕ
bindIdentityV sub ch ext v ten now =
  lockRoot tcSubject sub >>T
  require tcSubject sub NotFound >>=T λ s →
  guardT (sTenant s ≡ᵇ ten) NotFound >>T
  byCol tcIdentity "external_id" ext >>=T λ hits →
  found (mine hits)
  where
    mine : List (ℕ × Identity) → Maybe ℕ
    mine [] = nothing
    mine ((k , i) ∷ rest) =
      if primStringEquality (iChannel i) ch ∧ (iSubject i ≡ᵇ sub) then just k else mine rest
    found : Maybe ℕ → Tx ℕ
    found (just k) = returnT k
    found nothing  = fresh >>=T λ iid →
                     put tcIdentity (mkIdentity iid sub ch ext v ten now) >>T
                     returnT iid

------------------------------------------------------------------------
-- verifyIdentity: peek → lock the root → re-read under the lock (RC-safe check-then-write)
------------------------------------------------------------------------

verifyIdentityV : (identityId now : ℕ) → Tx ⊤
verifyIdentityV iid now =
  require tcIdentity iid NotFound >>=T λ i₀ →
  lockRoot tcSubject (iSubject i₀) >>T
  require tcIdentity iid NotFound >>=T λ i →
  guardT (iSubject i ≡ᵇ iSubject i₀) Conflict >>T      -- root moved between peek and lock ⇒ retry
  put tcIdentity (record i { iVerified = true })

------------------------------------------------------------------------
-- resolveOrCreateSubject: create-if-absent, serialized by the advisory key
------------------------------------------------------------------------

resolveOrCreateSubjectV : (channel externalId name tz : String) (tenant now : ℕ) → Tx ℕ
resolveOrCreateSubjectV ch ext name tz ten now =
  lockKey nsIdentityCreate (hashKey (ch <> ":" <> ext)) >>T   -- two concurrent creates serialize HERE
  byCol tcIdentity "external_id" ext >>=T λ hits →
  go (if emptyStr ext then nothing else mine hits)
  where
    mine : List (ℕ × Identity) → Maybe ℕ
    mine [] = nothing
    mine ((_ , i) ∷ rest) =
      if primStringEquality (iChannel i) ch then just (iSubject i) else mine rest
    bindIf : ℕ → Tx ⊤
    bindIf sid = if emptyStr ext then returnT tt
                 else fresh >>=T λ iid →
                      put tcIdentity (mkIdentity iid sid ch ext false ten now)
    go : Maybe ℕ → Tx ℕ
    go (just s) = returnT s
    go nothing  =
      fresh >>=T λ sid →
      put tcSubject (mkSubject sid EXTERNAL Person name tz now nothing ten nothing nothing false) >>T
      bindIf sid >>T
      returnT sid

------------------------------------------------------------------------
-- outbox enqueue (queue table: root-exempt) + the one-atom bind+notify revision
------------------------------------------------------------------------

enqueueNotificationV : (channel to subject body : String) (tenant now : ℕ) → Tx ℕ
enqueueNotificationV ch to subj body ten now =
  fresh >>=T λ oid →
  put tcOutbox (mkOutbox oid ch to subj body OutPending ten now 0 nothing) >>T
  returnT oid

-- the postBindIdentity revision: ONE transaction — either the binding exists AND its
-- verification mail is enqueued, or neither. `mkBody` closes over the fresh identity id
-- (the Api layer builds "verify: identity=N token=HMAC(secret, N)" — it owns the secret).
bindIdentityNotifyV : (subject : ℕ) (channel externalId : String) (tenant now : ℕ)
                    → (mailSubject : String) (mkBody : ℕ → String) → Tx ℕ
bindIdentityNotifyV sub ch ext ten now mailSubj mkBody =
  bindIdentityV sub ch ext false ten now >>=T λ iid →
  enqueueNotificationV ch ext mailSubj (mkBody iid) ten now >>T
  returnT iid

------------------------------------------------------------------------
-- Pack #2: knowledge/episode cluster
------------------------------------------------------------------------

-- createKnowledge: root = the subject; the §4.1 builders are reused verbatim
createKnowledgeV : (subject : ℕ) (ty : EpistemicType) (src : Source) (conf : ℕ)
                   (detail : String) (decay validFrom : ℕ) (validTo episode : Maybe ℕ)
                   (tenant : ℕ) → Tx ℕ
createKnowledgeV subj ty src conf detail dec vf vt ep ten =
  lockRoot tcSubject subj >>T
  require tcSubject subj NotFound >>=T λ s →
  guardT (sTenant s ≡ᵇ ten) NotFound >>T                       -- owner-isolation (как в оригинале)
  fresh >>=T λ kid →
  put tcKnowledge (build kid ty src) >>T returnT kid
  where
    build : ℕ → EpistemicType → Source → Knowledge
    build kid FACT       IMPORTED = mkFact    kid subj ten FImported detail vf vt dec ep
    build kid FACT       _        = mkFact    kid subj ten FObserved detail vf vt dec ep
    build kid HYPOTHESIS STATED   = statedK   kid subj ten IHypothesis conf detail dec vf vt ep
    build kid STATE      STATED   = statedK   kid subj ten IState      conf detail dec vf vt ep
    build kid TRAIT      STATED   = statedK   kid subj ten ITrait      conf detail dec vf vt ep
    build kid HYPOTHESIS _        = inferredK kid subj ten IHypothesis conf detail dec vf vt ep
    build kid STATE      _        = inferredK kid subj ten IState      conf detail dec vf vt ep
    build kid TRAIT      _        = inferredK kid subj ten ITrait      conf detail dec vf vt ep

-- updateKnowledge: peek → lockRoot (its subject) → RE-READ under the lock (RC-safe), then the
-- original guards (owner-isolation; FACT confidence is immutable — supersede instead)
updateKnowledgeV : (kid : ℕ) (rev : KRevision) (caller : ℕ) → Tx ⊤
updateKnowledgeV kid rev caller =
  require tcKnowledge kid NotFound >>=T λ k₀ →
  lockRoot tcSubject (kSubject k₀) >>T
  require tcKnowledge kid NotFound >>=T λ k →
  guardT (kSubject k ≡ᵇ kSubject k₀) Conflict >>T              -- root moved between peek and lock
  guardT (kTenant k ≡ᵇ caller) NotFound >>T
  guardT (not (isFactK k ∧ regradesConf rev)) (Invariant "cannot re-grade a FACT (use supersede)") >>T
  put tcKnowledge (revise rev k)
  where
    revise : KRevision → Knowledge → Knowledge
    revise (KStrengthen d) k = strengthen d k
    revise (KWeaken d)     k = weaken d k
    revise KConfirm        k = confirm k
    revise KRefute         k = refute k
    revise KSupersede      k = supersede k
    revise (KRedetail s)   k = record k { kDetail = s }

-- attachEvidence: evidence roots at its KNOWLEDGE row (rootOf) — lock it, re-read, guard, insert
attachEvidenceV : (kid eventId : ℕ) (tenant now : ℕ) → Tx ℕ
attachEvidenceV kid ev ten now =
  require tcKnowledge kid NotFound >>=T λ _ →
  lockRoot tcKnowledge kid >>T
  require tcKnowledge kid NotFound >>=T λ k →
  guardT (kTenant k ≡ᵇ ten) NotFound >>T
  require tcEvent ev NotFound >>=T λ _ →
  fresh >>=T λ eid →
  put tcEvidence (mkEvidence eid kid ev ten now) >>T returnT eid

-- createEpisode: root = the subject; initial state comes from the protocol
createEpisodeV : (subject protocol : ℕ) (jtbd : String) (tenant now : ℕ) → Tx ℕ
createEpisodeV subj proto jtbd ten now =
  lockRoot tcSubject subj >>T
  require tcSubject subj NotFound >>=T λ s →
  guardT (sTenant s ≡ᵇ ten) NotFound >>T
  require tcProtocol proto NotFound >>=T λ pr →
  fresh >>=T λ eid →
  put tcEpisode (mkEpisode eid subj proto ten (prInitialState pr) jtbd nothing nothing now nothing) >>T
  returnT eid

------------------------------------------------------------------------
-- Pack #3: appointments / payments
------------------------------------------------------------------------

private
  -- mirrored from Cxm.Commands (private there)
  apScheduledᵇ : ApptStatus → Bool
  apScheduledᵇ ApScheduled = true
  apScheduledᵇ _           = false

-- busy intervals of a resource (scan-based like the original resourceBusy; a byIx-bounded
-- version is a bucket-A optimization once ixField/PG indexes carry it)
resourceBusyV : (resource : ℕ) → Tx (List Interval)
resourceBusyV res =
  scan tcAppointment >>=T λ as → returnT (foldr step [] as)
  where
    step : (ℕ × Appointment) → List Interval → List Interval
    step (_ , a) acc =
      if (apResource a ≡ᵇ res) ∧ apScheduledᵇ (apStatus a)
      then (apStartsAt a , apStartsAt a + apDurationMin a * 60) ∷ acc else acc

-- bookAppointment — STRENGTHENED vs the original: the busy-check reads OTHER subjects'
-- appointments on the SAME resource, so the subject root alone does NOT serialize competing
-- books (double-booking race under RC; the memory-image was saved by global serialization).
-- The advisory (nsBooking, resource) serializes check→insert per resource. Advisory locks go
-- FIRST, row locks after — the global lock order of the plan.
bookAppointmentV : (subject resource : ℕ) (episode entitlement : Maybe ℕ)
                   (startsAt durationMin tenant now : ℕ) → Tx ℕ
bookAppointmentV subj res ep ent start dur ten now =
  lockKey nsBooking res >>T
  lockRoot tcSubject subj >>T
  require tcSubject subj NotFound >>=T λ s →
  guardT (sTenant s ≡ᵇ ten) NotFound >>T
  resourceBusyV res >>=T λ busy →
  guardT (slotFree start (dur * 60) busy) Conflict >>T
  fresh >>=T λ aid →
  put tcAppointment (mkAppointment aid subj res ep ent start dur ApScheduled nothing ten now nothing) >>T
  returnT aid

private
  -- only a Scheduled appointment transitions; peek → lockRoot (its subject) → re-read
  apptTransitionV : (apptId : ℕ) → ApptStatus → Tx ⊤
  apptTransitionV aid to =
    require tcAppointment aid NotFound >>=T λ a₀ →
    lockRoot tcSubject (apSubject a₀) >>T
    require tcAppointment aid NotFound >>=T λ a →
    guardT (apSubject a ≡ᵇ apSubject a₀) Conflict >>T
    guardT (apScheduledᵇ (apStatus a)) InvalidTransition >>T
    put tcAppointment (record a { apStatus = to })

cancelAppointmentV : (apptId : ℕ) → Tx ⊤                   -- frees the credit
cancelAppointmentV aid = apptTransitionV aid ApCanceled

noShowAppointmentV : (apptId : ℕ) → Tx ⊤                   -- forfeits the credit
noShowAppointmentV aid = apptTransitionV aid ApNoShow

completeAppointmentV : (apptId : ℕ) → Tx ⊤
completeAppointmentV aid = apptTransitionV aid ApCompleted

-- credit: THE balance-safety showcase — lockRoot serializes read-modify-write on the account
creditV : (accId amt : ℕ) → Tx ⊤
creditV accId amt =
  lockRoot tcAccount accId >>T                              -- A3 also gives existence
  require tcAccount accId NotFound >>=T λ a →
  put tcAccount (record a { acBalance = acBalance a + amt })

-- grantEntitlement (internal, called from the payment flow — no tenant guard, as the original)
grantEntitlementV : (subject : ℕ) (targetKind : EntTarget) (target validFrom : ℕ)
                    (validTo : Maybe ℕ) (src : EntSource) (tenant now : ℕ) → Tx ℕ
grantEntitlementV subj tk target vf vt src ten now =
  lockRoot tcSubject subj >>T
  require tcSubject subj NotFound >>=T λ _ →
  fresh >>=T λ enid →
  put tcEntitlement (mkEntitlement enid subj ten tk target vf vt src now) >>T returnT enid

------------------------------------------------------------------------
-- Pack #4: cascades (subject deletion / GDPR erasure)
------------------------------------------------------------------------

-- deep-delete children whose roots sit BELOW the subject: transitions/deviations root at their
-- EPISODE, evidence at its KNOWLEDGE — so the deep deletes take the intermediate root lock.
-- Nested locks under an already-exclusive subject root cannot deadlock across cascades: two
-- cascades on the same subject serialize at the subject; different subjects touch disjoint trees.
deleteEpisodeDeepV : ℕ → Tx ⊤
deleteEpisodeDeepV epid =
  lockRoot tcEpisode epid >>T
  byIx tcTransition trByEpisode epid >>=T λ ts → forEachTx ts (del tcTransition) >>T
  byIx tcDeviation  dvByEpisode epid >>=T λ ds → forEachTx ds (del tcDeviation)  >>T
  del tcEpisode epid

deleteKnowledgeDeepV : ℕ → Tx ⊤
deleteKnowledgeDeepV kid =
  lockRoot tcKnowledge kid >>T
  byIx tcEvidence evdByKnowledge kid >>=T λ es → forEachTx es (del tcEvidence) >>T
  del tcKnowledge kid

-- the cascade (audit-complete list incl. appointments). Incoming edges (byTo) delete under the
-- subject's OWN lock via altRoots: an edge is a relationship, either endpoint's owner severs it.
cascadeDeleteSubjectV : (sid caller : ℕ) → Tx ⊤
cascadeDeleteSubjectV sid caller =
  lockRoot tcSubject sid >>T
  require tcSubject sid NotFound >>=T λ s →
  guardT (sTenant s ≡ᵇ caller) NotFound >>T
  byIx tcEdge edgeByFrom sid          >>=T λ fe → forEachTx fe (del tcEdge)        >>T
  byIx tcEdge edgeByTo sid            >>=T λ te → forEachTx te (del tcEdge)        >>T
  byIx tcIdentity identBySubject sid  >>=T λ is → forEachTx is (del tcIdentity)    >>T
  byIx tcEntitlement entBySubject sid >>=T λ es → forEachTx es (del tcEntitlement) >>T
  byIx tcEpisode epBySubject sid      >>=T λ ep → forEachTx ep deleteEpisodeDeepV  >>T
  byIx tcKnowledge knowBySubject sid  >>=T λ ks → forEachTx ks deleteKnowledgeDeepV >>T
  byIx tcExpectation expBySubject sid >>=T λ xs → forEachTx xs (del tcExpectation) >>T
  byIx tcPromise promBySubject sid    >>=T λ ps → forEachTx ps (del tcPromise)     >>T
  byIx tcPayment paymentBySubject sid >>=T λ ys → forEachTx ys (del tcPayment)     >>T
  byIx tcAppointment apptBySubject sid >>=T λ as → forEachTx as (del tcAppointment) >>T
  del tcSubject sid

-- GDPR §7.5: redact PII in the append-only experience log (events CANNOT be deleted), then
-- hard-delete everything deletable. Event puts root at the subject — held by the cascade's lock.
scrubEventsForV : (sid : ℕ) → Tx ⊤
scrubEventsForV sid =
  scan tcEvent >>=T λ es → forEachTx es redact
  where
    redact : ℕ × ExperienceEvent → Tx ⊤
    redact (_ , e) = if eeSubject e ≡ᵇ sid
                     then put tcEvent (record e { eePayload = "[erased]" ; eeEmotion = nothing })
                     else returnT tt

gdprEraseSubjectV : (sid caller now : ℕ) → Tx ⊤
gdprEraseSubjectV sid caller now =
  lockRoot tcSubject sid >>T
  require tcSubject sid NotFound >>=T λ s →
  guardT (sTenant s ≡ᵇ caller) NotFound >>T
  scrubEventsForV sid >>T
  cascadeDeleteSubjectV sid caller

------------------------------------------------------------------------
-- Pack #5: social / owner / protocol / expectations / promises / tokens
------------------------------------------------------------------------

-- append an experience event (PRECONDITION: the event's subject root is already held)
appendEventV : ExperienceEvent → Tx ℕ
appendEventV ev = fresh >>=T λ eid → put tcEvent (record ev { eeId = eid }) >>T returnT eid

-- addEdge: the multi-root showcase — BOTH endpoints locked via lockRoots (canonical order
-- inside the combinator, so two concurrent addEdges over the same pair cannot deadlock)
addEdgeV : (from to : ℕ) (kind : EdgeKind) (role : Maybe String)
           (ordinal validFrom : ℕ) (validTo : Maybe ℕ) (tenant now : ℕ) → Tx ℕ
addEdgeV from to kind role ord vf vt ten now =
  lockRoots ((tcSubject , from) ∷ (tcSubject , to) ∷ []) >>T
  require tcSubject from NotFound >>=T λ sf → guardT (sTenant sf ≡ᵇ ten) NotFound >>T
  require tcSubject to   NotFound >>=T λ st → guardT (sTenant st ≡ᵇ ten) NotFound >>T
  fresh >>=T λ eid →
  put tcEdge (mkEdge eid from to kind role ord vf vt ten now) >>T returnT eid

followSubjectV : (follower author tenant now : ℕ) → Tx ℕ
followSubjectV follower author ten now =
  addEdgeV follower author follow nothing 0 now nothing ten now

-- registerOwner: tenant + user + "owner" role, all self-rooted creates → ONE advisory key
-- serializes a duplicate registration race on the login
createUserV : (login passHash : String) (tenant now : ℕ) → Tx ℕ
createUserV login ph ten now =
  fresh >>=T λ uid → put tcUser (mkUser uid ten login ph now) >>T returnT uid

registerOwnerV : (login passHash name : String) (now : ℕ) → Tx ℕ
registerOwnerV login ph name now =
  lockKey nsOwnerRegister (hashKey login) >>T
  fresh >>=T λ tid →
  put tcTenant (mkTenant tid name now) >>T
  createUserV login ph tid now >>=T λ _ →
  fresh >>=T λ aid →
  put tcAssignment (mkAssignment aid tid login "owner" "" now) >>T
  returnT tid

-- expectations (слой II)
createExpectationV : (subject : ℕ) (topic : String) (src : ExpSource)
                     (level : ℕ) (tenant now : ℕ) → Tx ℕ
createExpectationV subj topic src lvl ten now =
  lockRoot tcSubject subj >>T
  require tcSubject subj NotFound >>=T λ s →
  guardT (sTenant s ≡ᵇ ten) NotFound >>T
  fresh >>=T λ xid →
  put tcExpectation (mkExpectation xid subj ten topic src lvl ExpUnknown now) >>T returnT xid

setExpectationStatusV : (xid : ℕ) (st : ExpStatus) (caller : ℕ) → Tx ⊤
setExpectationStatusV xid st caller =
  require tcExpectation xid NotFound >>=T λ x₀ →
  lockRoot tcSubject (xpSubject x₀) >>T
  require tcExpectation xid NotFound >>=T λ x →
  guardT (xpSubject x ≡ᵇ xpSubject x₀) Conflict >>T
  guardT (xpTenant x ≡ᵇ caller) NotFound >>T
  put tcExpectation (record x { xpStatus = st })

-- createPromise (simple form: no stake/collateral — the promise-market ops are pack #6)
createPromiseV : (subject : ℕ) (topic : String) (deadline tenant now : ℕ) → Tx ℕ
createPromiseV subj topic deadline ten now =
  lockRoot tcSubject subj >>T
  require tcSubject subj NotFound >>=T λ _ →
  fresh >>=T λ pid →
  put tcPromise (mkPromise pid subj ten topic deadline PromPending nothing now Ours
                   nothing false 0 nothing nothing false) >>T
  appendEventV (mkExperienceEvent 0 subj ten Internal System now PromiseDeclared 0
                  nothing nothing nothing nothing false false
                  ("{\"promise\":" <> show pid <> "}") nothing) >>T
  returnT pid

-- protocols
createProtocolV : (name : String) (initialState tenant now : ℕ) → Tx ℕ
createProtocolV name ini ten now =
  lockKey nsIdentityCreate (hashKey name) >>T          -- self-rooted create (ensureProtocol races)
  fresh >>=T λ pid →
  put tcProtocol (mkProtocol pid ten name ini now) >>T returnT pid

-- episode state machine: legal transition per the protocol graph, journalled to the event log
transitionEpisodeV : (episode toState tenant now : ℕ) → Tx ℕ
transitionEpisodeV epi toState ten now =
  require tcEpisode epi NotFound >>=T λ e₀ →
  lockRoots ((tcSubject , epSubject e₀) ∷ (tcEpisode , epi) ∷ []) >>T   -- subject THEN episode (canonical)
  require tcEpisode epi NotFound >>=T λ e →
  guardT (epSubject e ≡ᵇ epSubject e₀) Conflict >>T
  byIx tcProtocolTransition ptByProtocol (epProtocol e) >>=T λ ptIds →
  hasTrans (epCurrentState e) toState ptIds >>=T λ ok →
  guardT ok InvalidTransition >>T
  fresh >>=T λ trid →
  put tcTransition (mkTransition trid epi (epCurrentState e) toState now 0 ten) >>T
  put tcEpisode (record e { epCurrentState = toState }) >>T
  appendEventV (mkExperienceEvent 0 (epSubject e) ten Internal System now LifecycleChange toState
                  (just epi) nothing nothing nothing false false "episode.transition" nothing) >>T
  returnT trid
  where
    hasTrans : ℕ → ℕ → List ℕ → Tx Bool
    hasTrans cur to [] = returnT false
    hasTrans cur to (i ∷ is) = get tcProtocolTransition i >>=T λ where
      nothing  → hasTrans cur to is
      (just p) → if (ptFromState p ≡ᵇ cur) ∧ (ptToState p ≡ᵇ to)
                 then returnT true else hasTrans cur to is

-- integration tokens (owner self-service)
createIntegrationTokenV : (token scope origin : String) (tenant now : ℕ) → Tx ℕ
createIntegrationTokenV tok scope origin ten now =
  lockKey nsTokenMint (hashKey tok) >>T                -- self-rooted create
  fresh >>=T λ tid →
  put tcIntToken (mkIntTokenRow tid ten tok scope origin now nothing) >>T returnT tid

revokeIntegrationTokenV : (tokenId caller now : ℕ) → Tx ⊤
revokeIntegrationTokenV tid caller now =
  lockRoot tcIntToken tid >>T                          -- self-root; absent ⇒ NotFound (A3, domain shape)
  require tcIntToken tid NotFound >>=T λ r →
  guardT (itkTenant r ≡ᵇ caller) NotFound >>T
  put tcIntToken (record r { itkRevokedAt = just now })
------------------------------------------------------------------------
-- Pack #6a: accounts / offerings / payments
------------------------------------------------------------------------

openAccountV : (tenant now : ℕ) → Tx ℕ
openAccountV ten now =
  lockKey nsSelfCreate ten >>T                         -- self-rooted create
  fresh >>=T λ aid → put tcAccount (mkAccount aid ten 0 now) >>T returnT aid

-- charge: the PROOF-GATED debit carried over verbatim — the balance≥0 invariant lives in the
-- type of `debit`, not in a runtime check that could drift
chargeV : (accId amt : ℕ) → Tx ⊤
chargeV accId amt =
  lockRoot tcAccount accId >>T
  require tcAccount accId NotFound >>=T λ a →
  chargeAcc a
  where
    chargeAcc : Account → Tx ⊤
    chargeAcc a with amt ≤? acBalance a
    ... | yes pf = put tcAccount (record a { acBalance = debit (acBalance a) amt pf })
    ... | no  _  = abortT Insufficient

createOfferingV : (kind price : ℕ) (currency metadata : String) (tenant now : ℕ) → Tx ℕ
createOfferingV kind price cur md ten now =
  lockKey nsSelfCreate ten >>T
  fresh >>=T λ oid →
  put tcOffering (mkOffering oid ten kind price cur md now nothing) >>T returnT oid

softDeleteOfferingV : (oid now : ℕ) → Tx ⊤
softDeleteOfferingV oid now =
  lockRoot tcOffering oid >>T                          -- self-root (A3 gives existence)
  require tcOffering oid NotFound >>=T λ o →
  put tcOffering (record o { oDeletedAt = just now })

-- fulfilment-as-data (П3): the offering's stored plan issues the declared grants — atomic with
-- the payment state because it runs inside markPaymentSucceededV's transaction
fulfillOfferingV : (subject offering tenant now : ℕ) → Tx ⊤
fulfillOfferingV subj off ten now =
  get tcOffering off >>=T λ mo → maybe′ go (returnT tt) mo
  where
    issue : Grant → Tx ⊤
    issue g = grantEntitlementV subj (gKind g) (gTarget g) now nothing SPayment ten now >>T returnT tt
    go : Offering → Tx ⊤
    go o = forEachTx (parseFulfilment (oMetadata o)) issue

recordPaymentV : (extId : String) (offering subject amount : ℕ)
                 (name email : String) (tenant now : ℕ) → Tx ℕ
recordPaymentV ext off subj amt name email ten now =
  lockKey nsSelfCreate ten >>T                         -- covers the orphan (subject 0) create too
  fresh >>=T λ pid →
  put tcPayment (mkPayment pid ten ext off subj name email amt PayPending 0 now) >>T returnT pid

findPaymentByExtIdV : String → Tx (Maybe Payment)
findPaymentByExtIdV ext =
  byCol tcPayment "ext_id" ext >>=T λ hits → returnT (first hits)   -- bounded byCol, not a scan
  where
    first : List (ℕ × Payment) → Maybe Payment
    first []            = nothing
    first ((_ , p) ∷ _) = just p

-- authoritative success: IDEMPOTENT (a PaySucceeded payment is a no-op — at-least-once webhook
-- redelivery never double-grants); an orphan payment (subject 0) is marked but not granted yet
markPaymentSucceededV : (payId now : ℕ) → Tx ⊤
markPaymentSucceededV pid now =
  require tcPayment pid NotFound >>=T λ p₀ →
  lockRoots (rootOf tcPayment p₀ ∷ []) >>T             -- subject root, or self for an orphan
  require tcPayment pid NotFound >>=T λ p →
  idem p
  where
    grant : Payment → Tx ⊤
    grant p with paySubject p
    ... | 0     = put tcPayment (record p { payStatus = PaySucceeded })
    ... | suc s = fresh >>=T λ enid →
          put tcEntitlement (mkEntitlement enid (suc s) (payTenant p) TOffering (payOffering p)
                               now nothing SPayment now) >>T
          fulfillOfferingV (suc s) (payOffering p) (payTenant p) now >>T
          put tcPayment (record p { payStatus = PaySucceeded ; payEntitlement = enid })
    idem : Payment → Tx ⊤
    idem q with payStatus q
    ... | PaySucceeded = returnT tt
    ... | _            = grant q

------------------------------------------------------------------------
-- Pack #6b: the promise market (clearing lifecycle; stake ops are proof-gated via chargeV)
------------------------------------------------------------------------

private
  pendingᵖ : PromStatus → Bool
  pendingᵖ PromPending = true
  pendingᵖ _           = false

  holdStakeV : (stakeAccount : Maybe ℕ) (amt : ℕ) → Tx ⊤
  holdStakeV (just a) amt = if amt ≡ᵇ 0 then returnT tt else chargeV a amt
  holdStakeV nothing  _   = returnT tt

  releaseStakeV : (stakeAccount : Maybe ℕ) (amt : ℕ) → Tx ⊤
  releaseStakeV (just a) amt = if amt ≡ᵇ 0 then returnT tt else creditV a amt
  releaseStakeV nothing  _   = returnT tt

  routePenaltyV : (stakeAccount penaltyTo : Maybe ℕ) (amt : ℕ) → Tx ⊤
  routePenaltyV (just _) (just to) amt = if amt ≡ᵇ 0 then returnT tt else creditV to amt
  routePenaltyV (just _) nothing   _   = returnT tt              -- forfeit (stake burned)
  routePenaltyV nothing  _         _   = returnT tt

  clearingEventV : (ty : EventType) (subject : ℕ) (payload : String) (tenant now : ℕ) → Tx ℕ
  clearingEventV ty subj pl ten now =
    appendEventV (mkExperienceEvent 0 subj ten Internal System now ty 0
                    nothing nothing nothing nothing false false pl nothing)

  -- accounts a promise op may touch, as extra lockRoots targets (E3: pre-lock in canonical
  -- order BEFORE the credit/charge sub-commands take their own — avoids cross-account deadlock)
  accRoots : List (Maybe ℕ) → List (TableCode × ℕ)
  accRoots []             = []
  accRoots (just a  ∷ ms) = (tcAccount , a) ∷ accRoots ms
  accRoots (nothing ∷ ms) = accRoots ms

createPromiseDirectedV : (subject : ℕ) (topic : String) (deadline : ℕ) (dir : PromDirection)
                         (transferable : Bool) (collateral : ℕ)
                         (stakeAccount penaltyTo : Maybe ℕ) (referable : Bool) (tenant now : ℕ) → Tx ℕ
createPromiseDirectedV subj topic deadline dir tr col stake pen ref ten now =
  lockRoots ((tcSubject , subj) ∷ accRoots (stake ∷ [])) >>T
  require tcSubject subj NotFound >>=T λ _ →
  holdStakeV stake col >>T
  fresh >>=T λ pid →
  put tcPromise (mkPromise pid subj ten topic deadline PromPending nothing now dir nothing tr col stake pen ref) >>T
  clearingEventV PromiseDeclared subj ("{\"promise\":" <> show pid <> "}") ten now >>T
  returnT pid

listPromiseV : (pid tenant now : ℕ) → Tx ℕ
listPromiseV pid ten now =
  require tcPromise pid NotFound >>=T λ p₀ →
  lockRoot tcSubject (pmSubject p₀) >>T
  require tcPromise pid NotFound >>=T λ p →
  guardT (pmTransferable p) (Invariant "not transferable") >>T
  guardT (pendingᵖ (pmStatus p)) InvalidTransition >>T
  clearingEventV PromiseListed (pmSubject p) ("{\"promise\":" <> show pid <> "}") ten now

transferPromiseV : (pid newHolder : ℕ) (newPenaltyTo : Maybe ℕ) (tenant now : ℕ) → Tx ⊤
transferPromiseV pid newHolder newPen ten now =
  require tcPromise pid NotFound >>=T λ p₀ →
  lockRoots ((tcSubject , pmSubject p₀) ∷ (tcSubject , newHolder) ∷ []) >>T
  require tcPromise pid NotFound >>=T λ p →
  guardT (pmTransferable p) (Invariant "not transferable") >>T
  guardT (pendingᵖ (pmStatus p)) InvalidTransition >>T
  require tcSubject newHolder NotFound >>=T λ _ →
  put tcPromise (record p { pmHolder = just newHolder
                          ; pmPenaltyTo = maybe′ just (pmPenaltyTo p) newPen }) >>T
  clearingEventV PromiseTransferred (pmSubject p)
    ("{\"promise\":" <> show pid <> ",\"holder\":" <> show newHolder <> "}") ten now >>T
  returnT tt

-- the stake follows the duty: release the old obligor, charge the new one — proof-gated, so a
-- referral only succeeds if the new obligor CAN post the stake (else the whole atom rolls back)
referPromiseV : (pid newStakeAccount tenant now : ℕ) → Tx ⊤
referPromiseV pid newStake ten now =
  require tcPromise pid NotFound >>=T λ p₀ →
  lockRoots ((tcSubject , pmSubject p₀) ∷ accRoots (pmStakeAccount p₀ ∷ just newStake ∷ [])) >>T
  require tcPromise pid NotFound >>=T λ p →
  guardT (pmReferable p) (Invariant "not referable") >>T
  guardT (pendingᵖ (pmStatus p)) InvalidTransition >>T
  releaseStakeV (pmStakeAccount p) (pmCollateral p) >>T
  holdStakeV (just newStake) (pmCollateral p) >>T
  put tcPromise (record p { pmStakeAccount = just newStake }) >>T
  clearingEventV PromiseTransferred (pmSubject p)
    ("{\"promise\":" <> show pid <> ",\"obligor_stake\":" <> show newStake <> "}") ten now >>T
  returnT tt

settlePromiseV : (pid tenant now : ℕ) → Tx ⊤
settlePromiseV pid ten now =
  require tcPromise pid NotFound >>=T λ p₀ →
  lockRoots ((tcSubject , pmSubject p₀) ∷ accRoots (pmStakeAccount p₀ ∷ [])) >>T
  require tcPromise pid NotFound >>=T λ p →
  guardT (pendingᵖ (pmStatus p)) InvalidTransition >>T
  releaseStakeV (pmStakeAccount p) (pmCollateral p) >>T
  put tcPromise (record p { pmStatus = PromFulfilled }) >>T
  clearingEventV PromiseSettled (pmSubject p) ("{\"promise\":" <> show pid <> "}") ten now >>T
  returnT tt

-- broken ⟹ consequence, atomically: route the held stake AND journal PromiseDefaulted
defaultPromiseV : (pid tenant now : ℕ) → Tx ⊤
defaultPromiseV pid ten now =
  require tcPromise pid NotFound >>=T λ p₀ →
  lockRoots ((tcSubject , pmSubject p₀) ∷ accRoots (pmStakeAccount p₀ ∷ pmPenaltyTo p₀ ∷ [])) >>T
  require tcPromise pid NotFound >>=T λ p →
  guardT (pendingᵖ (pmStatus p)) InvalidTransition >>T
  routePenaltyV (pmStakeAccount p) (pmPenaltyTo p) (pmCollateral p) >>T
  put tcPromise (record p { pmStatus = PromBroken }) >>T
  clearingEventV PromiseDefaulted (pmSubject p) ("{\"promise\":" <> show pid <> "}") ten now >>T
  returnT tt

markPromiseFulfilledV : (pid : ℕ) → Tx ⊤
markPromiseFulfilledV pid =
  require tcPromise pid NotFound >>=T λ p₀ →
  lockRoot tcSubject (pmSubject p₀) >>T
  require tcPromise pid NotFound >>=T λ p →
  put tcPromise (record p { pmStatus = PromFulfilled })

markPromiseBrokenV : (pid : ℕ) → Tx ⊤
markPromiseBrokenV pid =
  require tcPromise pid NotFound >>=T λ p₀ →
  lockRoot tcSubject (pmSubject p₀) >>T
  require tcPromise pid NotFound >>=T λ p →
  put tcPromise (record p { pmStatus = PromBroken })

------------------------------------------------------------------------
-- Pack #6c: resources / conversations (community content)
------------------------------------------------------------------------

private
  liveResᵇ : Resource → Bool
  liveResᵇ r = maybe′ (λ _ → false) true (rDeletedAt r)

createResourceV : (parent : Maybe ℕ) (kind ord : ℕ) (vis : Maybe String)
                  (payload : String) (author : Maybe ℕ) (listing : Maybe String) (tenant now : ℕ) → Tx ℕ
createResourceV parent kind ord vis payload author listing ten now =
  lockKey nsSelfCreate ten >>T
  fresh >>=T λ rid →
  put tcResource (mkResource rid ten parent kind ord vis payload now nothing author listing nothing nothing) >>T
  returnT rid

publishResourceV : (author : ℕ) (parent : Maybe ℕ) (vis : Maybe String)
                   (payload : String) (listing : Maybe String) (tenant now : ℕ) → Tx ℕ
publishResourceV author parent vis payload listing ten now =
  lockKey nsSelfCreate ten >>T                        -- advisory FIRST (plan lock order)
  lockRoot tcSubject author >>T
  require tcSubject author NotFound >>=T λ _ →
  createResourceV parent 1 0 vis payload (just author) listing ten now >>=T λ rid →
  appendEventV (mkExperienceEvent 0 author ten Community Client now Publish 0
                  nothing nothing nothing nothing false false
                  ("{\"resource\":" <> show rid <> "}") nothing) >>T
  returnT rid

updateResourceV : (rid : ℕ) (payload vis listing : Maybe String) (now : ℕ) → Tx ⊤
updateResourceV rid payload vis listing now =
  lockRoot tcResource rid >>T                         -- self-root (A3 gives existence)
  require tcResource rid NotFound >>=T λ r →
  guardT (liveResᵇ r) NotFound >>T
  put tcResource (record r
    { rPayload    = maybe′ (λ p → p) (rPayload r) payload
    ; rVisibility = maybe′ just (rVisibility r) vis
    ; rListing    = maybe′ just (rListing r) listing
    ; rUpdatedAt  = just now })

updateOwnResourceV : (author rid : ℕ) (payload vis listing : Maybe String) (now : ℕ) → Tx ⊤
updateOwnResourceV author rid payload vis listing now =
  lockRoot tcResource rid >>T
  require tcResource rid NotFound >>=T λ r →
  guardT (maybe′ (λ a → a ≡ᵇ author) false (rAuthor r)) Forbidden >>T
  updateResourceV rid payload vis listing now         -- re-lock/re-read inside: harmless dup

linkResourceV : (from to : ℕ) (kind : String) (rank : ℕ) (validTo : Maybe ℕ)
                (tenant now : ℕ) → Tx ℕ
linkResourceV from to kind rank vt ten now =
  lockRoot tcResource from >>T                        -- link roots at its from-resource
  require tcResource from NotFound >>=T λ _ →
  require tcResource to   NotFound >>=T λ _ →
  fresh >>=T λ lid →
  put tcResourceLink (mkResourceLink lid ten from to kind rank now vt now) >>T returnT lid

unlinkResourceV : (linkId : ℕ) → Tx ⊤
unlinkResourceV lid =
  require tcResourceLink lid NotFound >>=T λ l₀ →
  lockRoot tcResource (rlFrom l₀) >>T
  require tcResourceLink lid NotFound >>=T λ _ →
  del tcResourceLink lid

requireAnchorV : (kind : String) (id : ℕ) → Tx ⊤
requireAnchorV kind i =
  if      eq "resource"    then (require tcResource i NotFound    >>T returnT tt)
  else if eq "appointment" then (require tcAppointment i NotFound >>T returnT tt)
  else if eq "promise"     then (require tcPromise i NotFound     >>T returnT tt)
  else if eq "entitlement" then (require tcEntitlement i NotFound >>T returnT tt)
  else if eq "subject"     then (require tcSubject i NotFound     >>T returnT tt)
  else if eq "episode"     then (require tcEpisode i NotFound     >>T returnT tt)
  else abortT (Invariant "unknown anchor kind")
  where eq : String → Bool
        eq k = primStringEquality kind k

-- F4: the author must belong to the anchor's audience — now a Tx read (get per kind)
anchorParticipantV : (kind : String) (anchorId subject : ℕ) → Tx Bool
anchorParticipantV kind ai subj =
  if      eq "resource"    then returnT true
  else if eq "appointment" then (get tcAppointment ai >>=T λ m → returnT (maybe′ (λ a → apSubject a ≡ᵇ subj) false m))
  else if eq "promise"     then (get tcPromise ai >>=T λ m → returnT (maybe′ pOk false m))
  else if eq "entitlement" then (get tcEntitlement ai >>=T λ m → returnT (maybe′ (λ e → enSubject e ≡ᵇ subj) false m))
  else if eq "subject"     then returnT (ai ≡ᵇ subj)
  else if eq "episode"     then (get tcEpisode ai >>=T λ m → returnT (maybe′ (λ e → epSubject e ≡ᵇ subj) false m))
  else returnT false
  where
    eq : String → Bool
    eq k = primStringEquality kind k
    pOk : Promise → Bool
    pOk p = (pmSubject p ≡ᵇ subj) ∨ maybe′ (λ h → h ≡ᵇ subj) false (pmHolder p)

private
  addMentionsV : (rid tenant : ℕ) → ℕ → List ℕ → Tx ⊤
  addMentionsV _   _   _   []       = returnT tt
  addMentionsV rid ten ord (s ∷ ss) =
    require tcSubject s NotFound >>=T λ _ →
    fresh >>=T λ mid →
    put tcMention (mkMention mid rid s ord ten) >>T
    addMentionsV rid ten (suc ord) ss

  headOr : List ℕ → Maybe ℕ
  headOr []      = nothing
  headOr (x ∷ _) = just x

-- conversations-from-anything (§10): comment node + mentions + peer event, ONE atom.
-- Mention rows root at their RESOURCE (rootOf) — the fresh comment is created under the
-- nsSelfCreate advisory, which also admits its mention children in the same txn.
commentOnV : (author : ℕ) (anchorKind : String) (anchorId : ℕ) (parent : Maybe ℕ)
             (vis listing : Maybe String) (payload : String) (addressees : List ℕ)
             (tenant now : ℕ) → Tx ℕ
commentOnV author ak ai parent vis listing payload tos ten now =
  lockKey nsSelfCreate ten >>T
  lockRoot tcSubject author >>T
  require tcSubject author NotFound >>=T λ _ →
  fresh >>=T λ rid →
  resolveCtx rid parent >>=T λ ctx →
  anchorParticipantV (ccAnchorKind ctx) (ccAnchorId ctx) author >>=T λ ok →
  guardT ok Forbidden >>T
  put tcResource (mkResource rid ten parent 1 0 vis payload now nothing (just author) listing
                    (just ctx) nothing) >>T
  addMentionsV rid ten 0 tos >>T
  appendEventV (mkExperienceEvent 0 author ten Community Peer now Reaction 0
                  nothing nothing nothing nothing false false
                  ("{\"resource\":" <> show rid <> "}") (headOr tos)) >>T
  returnT rid
  where
    resolveCtx : ℕ → Maybe ℕ → Tx ConvCtx
    resolveCtx rid nothing  =
      requireAnchorV ak ai >>T
      returnT (mkConvCtx ak ai rid)
    resolveCtx rid (just p) =
      require tcResource p NotFound >>=T λ par →
      returnT (inherit par)
      where
        ownStream : ℕ → ℕ
        ownStream inherited = maybe′ (λ _ → rid) inherited vis
        inherit : Resource → ConvCtx
        inherit par with rAnchorKind par | rAnchorId par
        ... | just k  | just x  = mkConvCtx k x (ownStream (maybe′ (λ s → s) p (rStreamRoot par)))
        ... | _       | _       = mkConvCtx "resource" p (ownStream (maybe′ (λ s → s) p (rStreamRoot par)))

------------------------------------------------------------------------
-- Pack #6d: worker internals (outbox / reminders / bus). Outbox and bus are queue tables
-- (root-exempt puts); appointment/promise reminder marks take the subject root.
------------------------------------------------------------------------

markSentV : (outId : ℕ) → Tx ⊤
markSentV oid =
  require tcOutbox oid NotFound >>=T λ o →
  put tcOutbox (record o { obStatus = OutSent })

drainOutboxV : Tx ℕ
drainOutboxV =
  byIx tcOutbox outByStatus 0 >>=T λ ids →
  forEachTx ids markSentV >>T returnT (length ids)

private
  obDueV : (now : ℕ) → OutboxEntry → Bool
  obDueV now o = maybe′ (λ t → t + backoffSec (obAttempts o) ≤ᵇ now) true (obLastAttempt o)

dueOutboxV : (now : ℕ) → Tx (List ℕ)
dueOutboxV now =
  byIx tcOutbox outByStatus 0 >>=T λ ids → go ids
  where
    go : List ℕ → Tx (List ℕ)
    go []       = returnT []
    go (i ∷ is) = get tcOutbox i >>=T λ m → go is >>=T λ rest →
                  returnT (if maybe′ (obDueV now) false m then i ∷ rest else rest)

markAttemptV : (oid now maxAttempts : ℕ) → Tx ⊤
markAttemptV oid now maxAtt =
  require tcOutbox oid NotFound >>=T λ o →
  put tcOutbox (record o { obAttempts    = suc (obAttempts o)
                         ; obLastAttempt = just now
                         ; obStatus      = if maxAtt ≤ᵇ suc (obAttempts o) then OutFailed else OutPending })

private
  notRemindedᵇ : Maybe ℕ → Bool
  notRemindedᵇ = maybe′ (λ _ → false) true

  dueProm : ℕ → Promise → Bool
  dueProm deadline p = pendingᵖ (pmStatus p) ∧ (pmDeadline p ≤ᵇ deadline) ∧ notRemindedᵇ (pmRemindedAt p)

dueRemindersV : (now window : ℕ) → Tx (List ℕ)
dueRemindersV now window =
  scan tcPromise >>=T λ ps →
  returnT (foldr (λ pr acc → if dueProm (now + window) (proj₂ pr) then proj₁ pr ∷ acc else acc) [] ps)

markRemindedV : (pid now : ℕ) → Tx ⊤
markRemindedV pid now =
  require tcPromise pid NotFound >>=T λ p₀ →
  lockRoot tcSubject (pmSubject p₀) >>T
  require tcPromise pid NotFound >>=T λ p →
  put tcPromise (record p { pmRemindedAt = just now })

private
  apDueV : (now windowEnd : ℕ) → Appointment → Bool
  apDueV now we a =
    apScheduledᵇ (apStatus a) ∧ (now ≤ᵇ apStartsAt a) ∧ (apStartsAt a ≤ᵇ we)
      ∧ notRemindedᵇ (apRemindedAt a)

dueAppointmentRemindersV : (now lead : ℕ) → Tx (List ℕ)
dueAppointmentRemindersV now lead =
  scan tcAppointment >>=T λ as →
  returnT (foldr (λ p acc → if apDueV now (now + lead) (proj₂ p) then proj₁ p ∷ acc else acc) [] as)

markApptRemindedV : (apptId now : ℕ) → Tx ⊤
markApptRemindedV aid now =
  require tcAppointment aid NotFound >>=T λ a₀ →
  lockRoot tcSubject (apSubject a₀) >>T
  require tcAppointment aid NotFound >>=T λ a →
  put tcAppointment (record a { apRemindedAt = just now })

private
  emailOfSubjectV : ℕ → List (ℕ × Identity) → String
  emailOfSubjectV _    []             = ""
  emailOfSubjectV subj ((_ , i) ∷ is) =
    if (iSubject i ≡ᵇ subj) ∧ primStringEquality (iChannel i) "email"
    then iExternalId i else emailOfSubjectV subj is

  -- the worker locks MANY subject roots in one txn — sort by subject ASCENDING (E3), or a
  -- concurrent two-root command (addEdge sorts ascending) could deadlock against us
  insertBySubj : (ℕ × ℕ) → List (ℕ × ℕ) → List (ℕ × ℕ)
  insertBySubj x [] = x ∷ []
  insertBySubj (a , sa) ((b , sb) ∷ ys) =
    if sa ≤ᵇ sb then (a , sa) ∷ (b , sb) ∷ ys else (b , sb) ∷ insertBySubj (a , sa) ys

  sortBySubj : List (ℕ × ℕ) → List (ℕ × ℕ)
  sortBySubj []       = []
  sortBySubj (x ∷ xs) = insertBySubj x (sortBySubj xs)

remindDueAppointmentsV : (now lead : ℕ) → Tx ℕ
remindDueAppointmentsV now lead =
  scan tcIdentity >>=T λ ids →
  dueAppointmentRemindersV now lead >>=T λ appts →
  withSubjects appts >>=T λ pairs →
  forEachTx (sortBySubj pairs) (remindOne ids) >>T returnT (length appts)
  where
    withSubjects : List ℕ → Tx (List (ℕ × ℕ))
    withSubjects []       = returnT []
    withSubjects (a ∷ as) = get tcAppointment a >>=T λ m → withSubjects as >>=T λ rest →
                            returnT (maybe′ (λ ap → (a , apSubject ap) ∷ rest) rest m)
    remindOne : List (ℕ × Identity) → ℕ × ℕ → Tx ⊤
    remindOne ids (aid , _) = get tcAppointment aid >>=T λ m → doIt m
      where
        doIt : Maybe Appointment → Tx ⊤
        doIt nothing  = returnT tt
        doIt (just a) =
          enqueueNotificationV "email" (emailOfSubjectV (apSubject a) ids)
                               "Напоминание о встрече" "Ваша встреча скоро." (apTenant a) now >>T
          markApptRemindedV aid now

dispatchBusV : Tx ℕ
dispatchBusV =
  byIx tcBusEvent busByProcessed 0 >>=T λ ids →
  forEachTx ids flip >>T returnT (length ids)
  where
    flip : ℕ → Tx ⊤
    flip i = require tcBusEvent i NotFound >>=T λ e →
             put tcBusEvent (record e { evProcessed = true })

private
  apReopenV : ApptStatus → Bool
  apReopenV ApCompleted = true
  apReopenV ApNoShow    = true
  apReopenV _           = false

reopenAppointmentV : (apptId : ℕ) → Tx ⊤
reopenAppointmentV aid =
  require tcAppointment aid NotFound >>=T λ a₀ →
  lockRoot tcSubject (apSubject a₀) >>T
  require tcAppointment aid NotFound >>=T λ a →
  guardT (apReopenV (apStatus a)) InvalidTransition >>T
  put tcAppointment (record a { apStatus = ApScheduled })

------------------------------------------------------------------------
-- Pack #6e: subject lifecycle (provisional / soft-delete / merge / site ingest)
------------------------------------------------------------------------

provisionalSubjectV : (name tz : String) (tenant now : ℕ) → Tx ℕ
provisionalSubjectV name tz ten now =
  lockKey nsSelfCreate ten >>T
  fresh >>=T λ sid →
  put tcSubject (mkSubject sid EXTERNAL Person name tz now nothing ten nothing nothing true) >>T
  returnT sid

softDeleteSubjectV : (sid now : ℕ) → Tx ⊤
softDeleteSubjectV sid now =
  lockRoot tcSubject sid >>T
  require tcSubject sid NotFound >>=T λ s →
  put tcSubject (record s { sDeletedAt = just now })

-- alias a provisional subject into its canonical one (§4.4) — both roots locked, canonical order
mergeV : (provId canonId : ℕ) → Tx ⊤
mergeV provId canonId =
  lockRoots ((tcSubject , provId) ∷ (tcSubject , canonId) ∷ []) >>T
  require tcSubject canonId NotFound >>=T λ _ →
  require tcSubject provId  NotFound >>=T λ prov →
  put tcSubject (record prov { sCanonical = just canonId })

private
  bindIfIdV : (subject : ℕ) (channel externalId : String) (tenant now : ℕ) → Tx ⊤
  bindIfIdV subj ch ext ten now =
    if emptyStr ext then returnT tt
    else fresh >>=T λ iid → put tcIdentity (mkIdentity iid subj ch ext false ten now)

  -- resolve (channel, extId) to an existing subject — bounded byCol, channel-filtered
  resolveIdent : (channel externalId : String) → Tx (Maybe ℕ)
  resolveIdent ch ext =
    if emptyStr ext then returnT nothing
    else byCol tcIdentity "external_id" ext >>=T λ hits → returnT (mine hits)
    where
      mine : List (ℕ × Identity) → Maybe ℕ
      mine [] = nothing
      mine ((_ , i) ∷ rest) =
        if primStringEquality (iChannel i) ch then just (iSubject i) else mine rest

-- STRENGTHENED vs the original scan-based ingest: the advisory key serializes duplicate ingest
-- of the same new identity (two first-visits with one cookie no longer make two provisionals)
ingestSiteEventV : (channel externalId : String) (tenant now : ℕ) (ev : ExperienceEvent) → Tx ℕ
ingestSiteEventV ch ext ten now ev =
  lockKey nsIdentityCreate (hashKey (ch <> ":" <> ext)) >>T
  resolveIdent ch ext >>=T λ ms → resolve ms
  where
    resolve : Maybe ℕ → Tx ℕ
    resolve (just s) =
      lockRoot tcSubject s >>T                              -- event roots at its subject
      appendEventV (record ev { eeSubject = s })
    resolve nothing  =
      provisionalSubjectV "anon" "UTC" ten now >>=T λ s →   -- advisory admits the whole create path
      bindIfIdV s ch ext ten now >>T
      appendEventV (record ev { eeSubject = s })

private
  -- two advisory keys, LOWER objid first (advisory↔advisory deadlock guard for peer ingest)
  lockKeyPair : (classid o₁ o₂ : ℕ) → Tx ⊤
  lockKeyPair c o₁ o₂ =
    if o₁ ≤ᵇ o₂ then (lockKey c o₁ >>T lockKey c o₂)
    else (lockKey c o₂ >>T lockKey c o₁)

-- peer ingest (слой IX): resolve/provision BOTH sides, append with eeCounterpart
ingestPeerEventV : (channel externalId cpChannel cpExternalId : String)
                   (tenant now : ℕ) (ev : ExperienceEvent) → Tx ℕ
ingestPeerEventV ch ext cch cext ten now ev = go (emptyStr cext)
  where
    resolveOne : (channel externalId : String) → Tx ℕ
    resolveOne c e =
      resolveIdent c e >>=T λ ms → pick ms
      where
        pick : Maybe ℕ → Tx ℕ
        pick (just s) = returnT s
        pick nothing  = provisionalSubjectV "anon" "UTC" ten now >>=T λ s →
                        bindIfIdV s c e ten now >>T returnT s
    go : Bool → Tx ℕ
    go true  = ingestSiteEventV ch ext ten now ev
    go false =
      lockKeyPair nsIdentityCreate (hashKey (cch <> ":" <> cext)) (hashKey (ch <> ":" <> ext)) >>T
      resolveOne cch cext >>=T λ cp →
      resolveOne ch ext   >>=T λ s →
      lockSubj s >>T
      appendEventV (record ev { eeSubject = s ; eeCounterpart = just cp })
      where
        lockSubj : ℕ → Tx ⊤
        lockSubj s = lockRoot tcSubject s                   -- resolve path: row exists; create: advisory held

-- on login: alias the session's provisional subject into the login's canonical one, or promote it
mergeSessionV : (provisional : ℕ) (loginChannel loginExtId : String) (tenant now : ℕ) → Tx ⊤
mergeSessionV prov ch ext ten now =
  lockKey nsIdentityCreate (hashKey (ch <> ":" <> ext)) >>T
  resolveIdent ch ext >>=T λ ms → go ms
  where
    go : Maybe ℕ → Tx ⊤
    go (just canon) = mergeV prov canon
    go nothing      =
      lockRoot tcSubject prov >>T
      require tcSubject prov NotFound >>=T λ s →
      put tcSubject (record s { sProvisional = false }) >>T
      bindVerified                                           -- login PROVES channel control (audit F2:
      where                                                  -- оригинальная семантика verified=true)
        bindVerified : Tx ⊤
        bindVerified = if emptyStr ext then returnT tt
                       else fresh >>=T λ iid →
                            put tcIdentity (mkIdentity iid prov ch ext true ten now)

------------------------------------------------------------------------
-- Pack #6f: admin / seed / protocol authoring
------------------------------------------------------------------------

addProtocolStateV : (protocol stateCode : ℕ) (name : String) (tenant : ℕ) → Tx ℕ
addProtocolStateV proto code name ten =
  lockRoot tcProtocol proto >>T
  require tcProtocol proto NotFound >>=T λ _ →
  fresh >>=T λ sid →
  put tcProtocolState (mkProtocolState sid proto code name ten) >>T returnT sid

addProtocolTransitionV : (protocol fromState toState tenant : ℕ) → Tx ℕ
addProtocolTransitionV proto frm to ten =
  lockRoot tcProtocol proto >>T
  require tcProtocol proto NotFound >>=T λ _ →
  fresh >>=T λ tid →
  put tcProtocolTransition (mkProtocolTransition tid proto frm to ten) >>T returnT tid

-- idempotent seed: the advisory key is taken BEFORE the lookup (find-then-create race closed)
ensureProtocolV : (name : String) (initialState tenant now : ℕ) → Tx ℕ
ensureProtocolV name ini ten now =
  lockKey nsIdentityCreate (hashKey name) >>T
  byCol tcProtocol "name" name >>=T λ hits → go hits
  where
    go : List (ℕ × Protocol) → Tx ℕ
    go ((i , _) ∷ _) = returnT i
    go []            = createProtocolV name ini ten now

findUserByLoginV : String → Tx (Maybe User)
findUserByLoginV login =
  byCol tcUser "login" login >>=T λ hits → returnT (first hits)
  where
    first : List (ℕ × User) → Maybe User
    first []            = nothing
    first ((_ , u) ∷ _) = just u

assignRoleV : (subject roleId scope : String) (tenant now : ℕ) → Tx ℕ
assignRoleV subj role scope ten now =
  lockKey nsSelfCreate ten >>T                               -- assignment is self-rooted
  fresh >>=T λ aid →
  put tcAssignment (mkAssignment aid ten subj role scope now) >>T returnT aid

revokeRoleV : (subject roleId scope : String) → Tx ⊤
revokeRoleV subj role scope =
  scan tcAssignment >>=T λ as →
  forEachTx (matches as) unassign
  where
    matches : List (ℕ × RoleAssignment) → List ℕ            -- scan is id-ordered in every
    matches [] = []                                          -- interpreter ⇒ locks below ascend
    matches ((i , a) ∷ rest) =
      if primStringEquality (raSubject a) subj ∧ primStringEquality (raRoleId a) role
           ∧ primStringEquality (raScope a) scope
      then i ∷ matches rest else matches rest
    unassign : ℕ → Tx ⊤
    unassign i = lockRoot tcAssignment i >>T del tcAssignment i

scopedRolesOfV : String → Tx (List RoleAssignment)
scopedRolesOfV subj =
  scan tcAssignment >>=T λ as → returnT (mine as)
  where
    mine : List (ℕ × RoleAssignment) → List RoleAssignment
    mine [] = []
    mine ((_ , a) ∷ rest) =
      if primStringEquality (raSubject a) subj then a ∷ mine rest else mine rest

ensureAdminV : (login passHash scope : String) (tenant now : ℕ) → Tx ⊤
ensureAdminV login ph scope ten now =
  lockKey nsOwnerRegister (hashKey login) >>T              -- find-then-create race closed
  findUserByLoginV login >>=T λ mu → check mu
  where
    check : Maybe User → Tx ⊤
    check (just _) = returnT tt
    check nothing  =
      createUserV login ph ten now >>=T λ _ →
      assignRoleV login "admin" scope ten now >>T returnT tt

seedTenantsV : List Tenant → Tx ⊤
seedTenantsV ts =
  lockKey nsSelfCreate 0 >>T                               -- boot seed: one advisory admits all
  forEachTx ts (put tcTenant)

-- cabinet subject creation (POST /subjects): self-rooted create under the tenant advisory
createSubjectV : (kind : SubjectKind) (structure : SubjectStructure)
                 (name tz : String) (tenant now : ℕ) → Tx ℕ
createSubjectV kind structure name tz ten now =
  lockKey nsSelfCreate ten >>T
  fresh >>=T λ sid →
  put tcSubject (mkSubject sid kind structure name tz now nothing ten nothing nothing false) >>T
  returnT sid
