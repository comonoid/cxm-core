{-# OPTIONS --without-K --guardedness #-}

-- Cxm.Api — headless HTTP entry (cxm-plan.md Phase 8, §3, §4.17). GHC-only IO glue.
--   GET  → readBase + Query/Decision → {"data": …}
--   POST → parse JSON → build a Txn → commitTxn → {"data": …} | {"error": …}
-- The engine (Cxm.Store.Wal commitTxn/readBase) is domain-agnostic; this maps HTTP ↔ commands
-- and shapes the {data}/{error} envelope. Packs plug in through `routeExt` (no vertical named
-- here). Authz is a hook the app/pack supplies (route→perm + `canAssign` per scope, §4.15).
module Cxm.Api where

open import Agda.Builtin.IO using (IO)
open import Agda.Builtin.Unit using (⊤; tt)
open import Agda.Builtin.String using (String; primStringEquality)
open import Data.Nat using (ℕ; _+_; _*_; _≡ᵇ_; _≤ᵇ_; _<ᵇ_)
open import Data.Nat.Show using (show)
open import Data.Bool using (Bool; true; false; if_then_else_; _∧_)
open import Data.Maybe using (Maybe; just; nothing; maybe′)
open import Data.List using (List; []; _∷_; foldr; map; mapMaybe; null; take)
open import Data.Char using (Char)
open import Data.Product using (_×_; _,_; proj₁; proj₂)
open import Data.String using (toList; fromList) renaming (_++_ to _<>_)

open import Agdelte.Auth.JWT using (signJWT; verifyJWT)
open import Agdelte.FFI.Crypto using (verifyPassword; hashPassword; randomBytesB64)

open import Agdelte.FFI.Server using
  ( HttpRequest; HttpResponse; reqMethod; reqPath; reqBody; reqHeaders; lookupHeader
  ; mkResponse; mkResponseHRaw; StrPair; mkStrPair; putStrLn; _>>=_; _>>_; pure )
open import Agdelte.FFI.Json using (jsonGetField; jsonGetNat; escapeJsonString)
open import Agdelte.FFI.Time using (getCurrentTime)
open import Agdelte.FFI.Crypto using (hmacSHA256)

open import Cxm.Tenant using (Tenant; defaultTenant)
open import Cxm.Subject using (Subject; sId; sDisplayName; sTenant; sProvisional; sDeletedAt; EXTERNAL; Person)
open import Cxm.Users using (User; uLogin; uPassHash; RoleAssignment; raId; raSubject; raRoleId; raScope)
open import Cxm.Episode using (Episode; epId; epSubject; epProtocol; epCurrentState; epJtbd; epDeletedAt)
open import Cxm.Appointment using
  ( Appointment; apId; apSubject; apResource; apEpisode; apStartsAt; apDurationMin; apStatus
  ; ApptStatus; ApScheduled; ApCompleted; ApCanceled; ApNoShow )
open import Cxm.Identity using (Identity; iSubject; iChannel; iExternalId; iVerified)
open import Cxm.Edge using
  ( SubjectEdge; seId; seFrom; seTo; seKind
  ; EdgeKind; participation; membership; decision_consult; owner; patient; follow )
open import Cxm.Resource using (Resource; rId; rParent; rAuthor; rVisibility; rPayload; rCreatedAt; rDeletedAt
                               ; rAnchorKind; rAnchorId; rStreamRoot; rUpdatedAt
                               ; Mention; mId; mResource; mSubject; mOrd
                               ; ResourceLink; rlId; rlFrom; rlTo; rlKind; rlRank; rlValidTo)
open import Cxm.Entitlement using (TResource; SGrant)
open import Cxm.Offering using (Offering; oId; oKind; oPrice; oCurrency; oMetadata; oCreatedAt; oDeletedAt)
open import Cxm.Account using (Account; acId; acBalance)
open import Cxm.Payment using (Payment; payId; payExtId; payOffering; paySubject; payEmail; payAmount; payStatus; payEntitlement; PayStatus; PayPending; PaySucceeded; PayFailed)
open import Cxm.Bus using (OutboxEntry; obId; obChannel; obTo; obSubject; obBody; obStatus; obAttempts; OutStatus; OutPending; OutSent; OutFailed
                          ; Event; evId; evTopic; evProcessed)
open import Cxm.Event using
  ( ExperienceEvent; mkExperienceEvent; eeId; eeSubject; eeCounterpart; eeChannel; eeActor; eeType
  ; eeTimestamp; eeEpisode; eeIsPeak; eeIsEnd; eeSentiment
  ; Channel; Web; Mobile; Chat; Email; Integration; Community; Actor; Client; Peer
  ; Phone; Product; Internal; Staff; System; InternalSubject
  ; EventType; View; Purchase; TicketOpen; FeatureUse; FeatureRequest; InternalHandoff
  ; LifecycleChange; PromiseListed; PromiseTransferred; PromiseSettled; PromiseDefaulted; PromiseDeclared
  ; Publish; Reaction )
open import Cxm.Expectation using
  ( Expectation; Promise; pmId; pmSubject; pmTopic; pmDeadline; pmStatus; pmDirection
  ; pmHolder; pmTransferable; pmCollateral; pmStakeAccount; pmPenaltyTo; pmReferable
  ; PromStatus; PromPending; PromFulfilled; PromBroken; PromDirection; Ours; Theirs )
open import Cxm.Site using
  ( IntegrationToken; tokenAuthorizes; webhookPayload
  ; IntTokenRow; itkId; itkToken; itkScope; itkOrigin; itkRevokedAt; verifyTokenIn; findIdentityIn )
open import Cxm.Store.Base
open import Cxm.Txn using (Txn)
open import Cxm.Store.Wal using (WalHandle; commitTxn; readBase; openStore; committed; rejected; ioFailed)
open import Cxm.Store.Interface using
  ( subjectsT; tenantsT; knowledgeT; accountsT; expectationsT; promisesT; eventsT; usersT; paymentsT
  ; episodesT; appointmentsT; edgesT; outboxT; busEventsT; assignmentsT; identitiesT; resourcesT; entitlementsT
  ; integrationTokensT; resourceLinksT; mentionsT ; offeringsT ; tget; tbyIndex; tscan )
open import Cxm.Commands
open import Cxm.Query
open import Cxm.Projection using (contributionOf)
open import Cxm.Social using
  ( feedViews; threadViews; canList; canAccess; ContentView; cvLocked; cvResource
  ; ThreadView; tvDepth; tvLocked; tvResource; showcaseViews )
open import Cxm.Decision
open import Cxm.Config using (InstanceConfig; cfgStorage; cfgSeedTenants; cfgApiToken; cfgJwtSecret; StorageHandle; shWalPath)
open import Cxm.Instance using (packActive)

------------------------------------------------------------------------
-- Config re-export (one WAL config for the whole core, from Cxm.Store.Wal)
------------------------------------------------------------------------

open import Cxm.Store.Wal public using (cxmWalConfig)

------------------------------------------------------------------------
-- Envelope + Err mapping (§3)
------------------------------------------------------------------------

okJson : String → HttpResponse
okJson body = mkResponse 200 ("{\"data\":" <> body <> "}")

errJson : ℕ → String → String → HttpResponse
errJson status code msg =
  mkResponse status ("{\"error\":{\"code\":\"" <> code <> "\",\"message\":\""
                     <> escapeJsonString msg <> "\"}}")

errResp : Err → HttpResponse
errResp NotFound          = errJson 404 "not_found"          "not found"
errResp Conflict          = errJson 409 "conflict"           "conflict"
errResp Insufficient      = errJson 402 "insufficient_funds" "insufficient funds"
errResp InvalidTransition = errJson 409 "invalid_transition" "invalid transition"
errResp Forbidden         = errJson 403 "forbidden"          "forbidden"
errResp (Invariant m)     = errJson 400 "validation"         m

-- run a Txn returning an id → {data:{id}} / {error}
commit : WalHandle Base CxmOp → Txn ℕ → IO HttpResponse
commit h tx =
  commitTxn h tx >>= λ where
    (committed id) → pure (okJson ("{\"id\":" <> show id <> "}"))
    (rejected e)   → pure (errResp e)
    ioFailed       → pure (errJson 503 "internal" "storage write failed")

-- run a Txn with no payload → {data:{ok:true}} / {error}
commitUnit : WalHandle Base CxmOp → Txn ⊤ → IO HttpResponse
commitUnit h tx =
  commitTxn h tx >>= λ where
    (committed _) → pure (okJson "{\"ok\":true}")
    (rejected e)  → pure (errResp e)
    ioFailed      → pure (errJson 503 "internal" "storage write failed")

------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------

private
  str : String → String
  str s = "\"" <> escapeJsonString s <> "\""

  boolJson : Bool → String
  boolJson true  = "true"
  boolJson false = "false"

  array : List String → String
  array xs = "[" <> foldr joinC "" xs <> "]"
    where joinC : String → String → String
          joinC x ""  = x
          joinC x acc = x <> "," <> acc

  -- body field with a default (missing/malformed → default)
  fieldOr : HttpRequest → String → String → String
  fieldOr req name dflt = maybe′ (λ v → v) dflt (jsonGetField name (reqBody req))

  natOr : HttpRequest → String → ℕ → ℕ
  natOr req name dflt = maybe′ (λ v → v) dflt (jsonGetNat name (reqBody req))

  listAll : ∀ {V : Set} → (V → String) → List (ℕ × V) → String
  listAll enc xs = array (map (λ p → enc (proj₂ p)) xs)

  -- soft-delete filter (audit #1): listings of entities with a deletedAt show LIVE rows only
  liveᵇ : Maybe ℕ → Bool
  liveᵇ nothing  = true
  liveᵇ (just _) = false

  filterRows : ∀ {V : Set} → (V → Bool) → List (ℕ × V) → List (ℕ × V)
  filterRows p = foldr (λ x acc → if p (proj₂ x) then x ∷ acc else acc) []

  mNat0 : Maybe ℕ → ℕ
  mNat0 = maybe′ (λ x → x) 0

------------------------------------------------------------------------
-- JSON encoders for reads
------------------------------------------------------------------------

subjectJson : Subject → String
subjectJson s =
  "{\"id\":" <> show (sId s) <> ",\"name\":" <> str (sDisplayName s)
  <> ",\"tenant\":" <> show (sTenant s) <> ",\"provisional\":" <> boolJson (sProvisional s) <> "}"

-- subject listing enriched with the subject's primary "email" identity (for the console client
-- join — subjects hold no email column; it lives in Identity). "" when none bound.
private
  emailOfSubj : ℕ → List (ℕ × Identity) → String
  emailOfSubj _ []             = ""
  emailOfSubj s ((_ , i) ∷ is-) =
    if (iSubject i ≡ᵇ s) ∧ primStringEquality (iChannel i) "email"
    then iExternalId i else emailOfSubj s is-

subjectJsonE : List (ℕ × Identity) → Subject → String
subjectJsonE ids s =
  "{\"id\":" <> show (sId s) <> ",\"name\":" <> str (sDisplayName s)
  <> ",\"email\":" <> str (emailOfSubj (sId s) ids)
  <> ",\"tenant\":" <> show (sTenant s) <> ",\"provisional\":" <> boolJson (sProvisional s) <> "}"

kpiJson : MetaKPI → String
kpiJson k =
  "{\"total\":" <> show (kpiTotal k) <> ",\"observed\":" <> show (kpiObserved k)
  <> ",\"inferred\":" <> show (kpiInferred k) <> ",\"fresh\":" <> show (kpiFresh k) <> "}"

------------------------------------------------------------------------
-- Endpoints
------------------------------------------------------------------------

-- GET /subjects → LIVE subjects (soft-deleted excluded, audit #1)
getSubjects : WalHandle Base CxmOp → IO HttpResponse
getSubjects h = readBase h >>= λ b →
  pure (okJson (listAll (subjectJsonE (tscan identitiesT b))
                        (filterRows (λ s → liveᵇ (sDeletedAt s)) (tscan subjectsT b))))

-- POST /subjects {"name":…, "tz":…} → create an external Person subject (default tenant)
postSubject : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postSubject h req = getCurrentTime >>= λ now →
  commit h (createSubject EXTERNAL Person (fieldOr req "name" "") (fieldOr req "tz" "UTC") defaultTenant now)

-- POST /query {"subject":N} → the meta-KPI of what we know about the subject
postQuery : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postQuery h req = getCurrentTime >>= λ now → readBase h >>= λ b →
  let subj = natOr req "subject" 0
      ks   = map proj₂ (tscan knowledgeT b)
  in pure (okJson (kpiJson (metaKPI now 500 subj ks)))

-- POST /accounts → open a zero-balance account (default tenant)
postAccount : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postAccount h req = getCurrentTime >>= λ now → commit h (openAccount defaultTenant now)

-- POST /charge {"acc":N,"amt":N} → proof-gated charge (never overdraws)
postCharge : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postCharge h req = commitUnit h (charge (natOr req "acc" 0) (natOr req "amt" 0))

-- POST /decision {"subject":N,"confidence":C} → the next-best-action for the subject, gathered
-- from its unmet expectations / overdue promises / sentiment drift (threshold 500, drift 2).
private
  actionStr : Action → String
  actionStr Recovery         = "recovery"
  actionStr ProactiveContact = "proactive_contact"
  actionStr Intervene        = "intervene"
  actionStr Explore          = "explore"
  actionStr Exploit          = "exploit"
  actionStr NoAction         = "none"

  -- the subject's recent offset sentiments (annotated events only)
  subjSentiments : ℕ → List (ℕ × ExperienceEvent) → List ℕ
  subjSentiments subj = foldr step []
    where step : (ℕ × ExperienceEvent) → List ℕ → List ℕ
          step p acc = let e = proj₂ p in
            if eeSubject e ≡ᵇ subj
            then maybe′ (λ s → s ∷ acc) acc (eeSentiment e)
            else acc

postDecision : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postDecision h req = getCurrentTime >>= λ now → readBase h >>= λ b →
  let subj = natOr req "subject" 0
      conf = natOr req "confidence" 0
      act  = nextBestAction now subj conf 500 2
               (map proj₂ (tscan expectationsT b)) (map proj₂ (tscan promisesT b))
               (subjSentiments subj (tscan eventsT b))
  in pure (okJson ("{\"action\":" <> str (actionStr act) <> "}"))

-- POST /events/dispatch → flip every unprocessed bus Event to processed, return the count
dispatchEvents : WalHandle Base CxmOp → IO HttpResponse
dispatchEvents h =
  commitTxn h dispatchBus >>= λ where
    (committed n) → pure (okJson ("{\"dispatched\":" <> show n <> "}"))
    (rejected e)  → pure (errResp e)
    ioFailed      → pure (errJson 503 "internal" "storage write failed")

------------------------------------------------------------------------
-- Operator surface (CXM-native, covering Crm.Api's capabilities): entity listings + CRUD.
-- JSON encoders (salient fields) + enum→string.
------------------------------------------------------------------------

private
  apStatusStr : ApptStatus → String
  apStatusStr ApScheduled = "scheduled" ; apStatusStr ApCompleted = "completed"
  apStatusStr ApCanceled  = "canceled"  ; apStatusStr ApNoShow    = "no_show"

  channelStr : Channel → String
  channelStr Web = "web" ; channelStr Mobile = "mobile" ; channelStr Chat = "chat"
  channelStr Email = "email" ; channelStr Phone = "phone" ; channelStr Product = "product"
  channelStr Internal = "internal" ; channelStr Integration = "integration"
  channelStr Community = "community"

  actorStr : Actor → String
  actorStr Client = "client" ; actorStr Staff = "staff" ; actorStr System = "system"
  actorStr InternalSubject = "internal" ; actorStr Peer = "peer"

  eventTypeStr : EventType → String
  eventTypeStr View = "view" ; eventTypeStr Purchase = "purchase"
  eventTypeStr TicketOpen = "ticket_open" ; eventTypeStr FeatureUse = "feature_use"
  eventTypeStr FeatureRequest = "feature_request" ; eventTypeStr InternalHandoff = "internal_handoff"
  eventTypeStr LifecycleChange = "lifecycle_change"
  eventTypeStr PromiseListed = "promise_listed" ; eventTypeStr PromiseTransferred = "promise_transferred"
  eventTypeStr PromiseSettled = "promise_settled" ; eventTypeStr PromiseDefaulted = "promise_defaulted"
  eventTypeStr PromiseDeclared = "promise_declared"
  eventTypeStr Publish = "publish" ; eventTypeStr Reaction = "reaction"

  -- locked=true ⇒ the payload is STRIPPED (S7 teaser: existence/metadata visible, content not)
  resourceJsonL : Bool → Resource → String
  resourceJsonL locked r = "{\"id\":" <> show (rId r) <> ",\"parent\":" <> show (mNat0 (rParent r))
    <> ",\"author\":" <> show (mNat0 (rAuthor r))
    <> ",\"visibility\":" <> str (maybe′ (λ v → v) "public" (rVisibility r))
    <> ",\"locked\":" <> boolJson locked
    <> ",\"payload\":" <> str (if locked then "" else rPayload r)
    <> ",\"createdAt\":" <> show (rCreatedAt r)
    <> ",\"updatedAt\":" <> show (mNat0 (rUpdatedAt r)) <> "}"

  resourceJson : Resource → String
  resourceJson = resourceJsonL false

  contentViewJson : ContentView → String
  contentViewJson v = resourceJsonL (cvLocked v) (cvResource v)

  -- deep-link cosmetics (§10.5): the ROOT of a served thread masks its parent pointer (do not
  -- hint at what is above a shared sub-branch)
  threadViewJson : ThreadView → String
  threadViewJson n = "{\"depth\":" <> show (tvDepth n) <> ",\"node\":"
    <> resourceJsonL (tvLocked n) (maskRoot (tvResource n)) <> "}"
    where maskRoot : Resource → Resource
          maskRoot r = if tvDepth n ≡ᵇ 0 then record r { rParent = nothing } else r

  -- conversation node (§10): + anchor/streamRoot/mentions (ordered; first = primary)
  convNodeJson : List ℕ → Bool → Resource → String
  convNodeJson tos locked r = "{\"id\":" <> show (rId r) <> ",\"parent\":" <> show (mNat0 (rParent r))
    <> ",\"author\":" <> show (mNat0 (rAuthor r))
    <> ",\"streamRoot\":" <> show (mNat0 (rStreamRoot r))
    <> ",\"locked\":" <> boolJson locked
    <> ",\"payload\":" <> str (if locked then "" else rPayload r)
    <> ",\"to\":" <> array (map show tos)
    <> ",\"createdAt\":" <> show (rCreatedAt r)
    <> ",\"updatedAt\":" <> show (mNat0 (rUpdatedAt r)) <> "}"

  -- the experience LOG row (D5): the operator's read of the source-of-truth stream
  experienceJson : ExperienceEvent → String
  experienceJson e = "{\"id\":" <> show (eeId e) <> ",\"subject\":" <> show (eeSubject e)
    <> ",\"counterpart\":" <> show (mNat0 (eeCounterpart e))
    <> ",\"channel\":" <> str (channelStr (eeChannel e))
    <> ",\"actor\":" <> str (actorStr (eeActor e))
    <> ",\"type\":" <> str (eventTypeStr (eeType e))
    <> ",\"timestamp\":" <> show (eeTimestamp e)
    <> ",\"episode\":" <> show (mNat0 (eeEpisode e))
    <> ",\"isPeak\":" <> boolJson (eeIsPeak e) <> ",\"isEnd\":" <> boolJson (eeIsEnd e) <> "}"

  edgeKindStr : EdgeKind → String
  edgeKindStr participation = "participation" ; edgeKindStr membership = "membership"
  edgeKindStr decision_consult = "decision_consult" ; edgeKindStr owner = "owner"
  edgeKindStr patient = "patient" ; edgeKindStr follow = "follow"

  outStatusStr : OutStatus → String
  outStatusStr OutPending = "pending" ; outStatusStr OutSent = "sent"
  outStatusStr OutFailed  = "failed"


  episodeJson : Episode → String
  episodeJson e = "{\"id\":" <> show (epId e) <> ",\"subject\":" <> show (epSubject e)
    <> ",\"protocol\":" <> show (epProtocol e) <> ",\"state\":" <> show (epCurrentState e)
    <> ",\"jtbd\":" <> str (epJtbd e) <> "}"

  appointmentJson : Appointment → String
  appointmentJson a = "{\"id\":" <> show (apId a) <> ",\"subject\":" <> show (apSubject a)
    <> ",\"resource\":" <> show (apResource a) <> ",\"episode\":" <> show (mNat0 (apEpisode a))
    <> ",\"startsAt\":" <> show (apStartsAt a)
    <> ",\"duration\":" <> show (apDurationMin a) <> ",\"status\":" <> str (apStatusStr (apStatus a)) <> "}"

  identityJson : Identity → String
  identityJson i = "{\"subject\":" <> show (iSubject i) <> ",\"channel\":" <> str (iChannel i)
    <> ",\"externalId\":" <> str (iExternalId i) <> ",\"verified\":" <> boolJson (iVerified i) <> "}"

  edgeJson : SubjectEdge → String
  edgeJson e = "{\"id\":" <> show (seId e) <> ",\"from\":" <> show (seFrom e)
    <> ",\"to\":" <> show (seTo e) <> ",\"kind\":" <> str (edgeKindStr (seKind e)) <> "}"

  accountJson : Account → String
  accountJson a = "{\"id\":" <> show (acId a) <> ",\"balance\":" <> show (acBalance a) <> "}"

  outboxJson : OutboxEntry → String
  outboxJson o = "{\"id\":" <> show (obId o) <> ",\"channel\":" <> str (obChannel o)
    <> ",\"to\":" <> str (obTo o) <> ",\"status\":" <> str (outStatusStr (obStatus o)) <> "}"

  busEventJson : Event → String
  busEventJson e = "{\"id\":" <> show (evId e) <> ",\"topic\":" <> str (evTopic e)
    <> ",\"processed\":" <> boolJson (evProcessed e) <> "}"

  promStatusStr : PromStatus → String
  promStatusStr PromPending = "pending" ; promStatusStr PromFulfilled = "fulfilled"
  promStatusStr PromBroken  = "broken"

  pdStr : PromDirection → String
  pdStr Ours = "ours" ; pdStr Theirs = "theirs"

  promiseJson : Promise → String
  promiseJson p = "{\"id\":" <> show (pmId p) <> ",\"subject\":" <> show (pmSubject p)
    <> ",\"topic\":" <> str (pmTopic p) <> ",\"deadline\":" <> show (pmDeadline p)
    <> ",\"status\":" <> str (promStatusStr (pmStatus p))
    <> ",\"direction\":" <> str (pdStr (pmDirection p))
    <> ",\"holder\":" <> show (mNat0 (pmHolder p))
    <> ",\"transferable\":" <> boolJson (pmTransferable p)
    <> ",\"collateral\":" <> show (pmCollateral p)
    <> ",\"stakeAccount\":" <> show (mNat0 (pmStakeAccount p))
    <> ",\"penaltyTo\":" <> show (mNat0 (pmPenaltyTo p))
    <> ",\"referable\":" <> boolJson (pmReferable p) <> "}"

  payStatusStr : PayStatus → String
  payStatusStr PayPending = "pending" ; payStatusStr PaySucceeded = "succeeded"
  payStatusStr PayFailed = "failed"

  paymentJson : Payment → String
  paymentJson p = "{\"id\":" <> show (payId p) <> ",\"extId\":" <> str (payExtId p)
    <> ",\"offering\":" <> show (payOffering p) <> ",\"subject\":" <> show (paySubject p)
    <> ",\"email\":" <> str (payEmail p) <> ",\"amount\":" <> show (payAmount p)
    <> ",\"status\":" <> str (payStatusStr (payStatus p))
    <> ",\"entitlement\":" <> show (payEntitlement p) <> "}"

  offeringJson : Offering → String
  offeringJson o = "{\"id\":" <> show (oId o) <> ",\"kind\":" <> show (oKind o)
    <> ",\"price\":" <> show (oPrice o) <> ",\"currency\":" <> str (oCurrency o)
    <> ",\"metadata\":" <> str (oMetadata o) <> "}"

  reliabilityJson : Reliability → String
  reliabilityJson r = "{\"oursKept\":" <> show (relOursKept r)
    <> ",\"oursBroken\":" <> show (relOursBroken r)
    <> ",\"theirsKept\":" <> show (relTheirsKept r)
    <> ",\"theirsBroken\":" <> show (relTheirsBroken r)
    <> ",\"noShows\":" <> show (relNoShows r) <> "}"

  intTokenJson : IntTokenRow → String
  intTokenJson r = "{\"id\":" <> show (itkId r) <> ",\"token\":" <> str (itkToken r)
    <> ",\"scope\":" <> str (itkScope r) <> ",\"origin\":" <> str (itkOrigin r)
    <> ",\"revokedAt\":" <> show (mNat0 (itkRevokedAt r)) <> "}"

  assignmentJson : RoleAssignment → String
  assignmentJson a = "{\"id\":" <> show (raId a) <> ",\"subject\":" <> str (raSubject a)
    <> ",\"role\":" <> str (raRoleId a) <> ",\"scope\":" <> str (raScope a) <> "}"

------------------------------------------------------------------------
-- GET listings
------------------------------------------------------------------------

getEpisodes : WalHandle Base CxmOp → IO HttpResponse   -- LIVE episodes only (audit #1)
getEpisodes h = readBase h >>= λ b →
  pure (okJson (listAll episodeJson (filterRows (λ e → liveᵇ (epDeletedAt e)) (tscan episodesT b))))

getAppointments : WalHandle Base CxmOp → IO HttpResponse
getAppointments h = readBase h >>= λ b → pure (okJson (listAll appointmentJson (tscan appointmentsT b)))

getEdges : WalHandle Base CxmOp → IO HttpResponse
getEdges h = readBase h >>= λ b → pure (okJson (listAll edgeJson (tscan edgesT b)))

getIdentities : WalHandle Base CxmOp → IO HttpResponse   -- for subject→email/phone joins (console)
getIdentities h = readBase h >>= λ b → pure (okJson (listAll identityJson (tscan identitiesT b)))

getAccounts : WalHandle Base CxmOp → IO HttpResponse
getAccounts h = readBase h >>= λ b → pure (okJson (listAll accountJson (tscan accountsT b)))

getOutbox : WalHandle Base CxmOp → IO HttpResponse
getOutbox h = readBase h >>= λ b → pure (okJson (listAll outboxJson (tscan outboxT b)))

getBusEvents : WalHandle Base CxmOp → IO HttpResponse
getBusEvents h = readBase h >>= λ b → pure (okJson (listAll busEventJson (tscan busEventsT b)))

-- the EXPERIENCE log (D5): the [СОБ] source-of-truth stream (append-only, no live-filter);
-- distinct from GET /events, which lists the domain BUS (§8.2 three logs)
getExperienceLog : WalHandle Base CxmOp → IO HttpResponse
getExperienceLog h = readBase h >>= λ b → pure (okJson (listAll experienceJson (tscan eventsT b)))

getAssignments : WalHandle Base CxmOp → IO HttpResponse
getAssignments h = readBase h >>= λ b → pure (okJson (listAll assignmentJson (tscan assignmentsT b)))

getIntTokens : WalHandle Base CxmOp → IO HttpResponse   -- operator: minted integration tokens
getIntTokens h = readBase h >>= λ b → pure (okJson (listAll intTokenJson (tscan integrationTokensT b)))

getPromises : WalHandle Base CxmOp → IO HttpResponse    -- promises incl. futures fields (A6)
getPromises h = readBase h >>= λ b → pure (okJson (listAll promiseJson (tscan promisesT b)))

getResources : WalHandle Base CxmOp → IO HttpResponse   -- live content nodes (social minimum S5)
getResources h = readBase h >>= λ b →
  pure (okJson (listAll resourceJson (filterRows (λ r → liveᵇ (rDeletedAt r)) (tscan resourcesT b))))

getPayments : WalHandle Base CxmOp → IO HttpResponse    -- operator payments overview (CRM parity)
getPayments h = readBase h >>= λ b → pure (okJson (listAll paymentJson (tscan paymentsT b)))

getOfferings : WalHandle Base CxmOp → IO HttpResponse   -- live sellable catalog (П3 fulfilment)
getOfferings h = readBase h >>= λ b →
  pure (okJson (listAll offeringJson (filterRows (λ o → liveᵇ (oDeletedAt o)) (tscan offeringsT b))))

-- reverse-index reads
postAppointmentsByEpisode : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postAppointmentsByEpisode h req = readBase h >>= λ b →
  pure (okJson (array (map appointmentJson
    (mapMaybe (λ id → tget appointmentsT id b) (tbyIndex appointmentsT apptByEpisode (natOr req "episode" 0) b)))))

postEdgesBySubject : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postEdgesBySubject h req = readBase h >>= λ b →
  pure (okJson (array (map edgeJson
    (mapMaybe (λ id → tget edgesT id b) (tbyIndex edgesT edgeByFrom (natOr req "subject" 0) b)))))

------------------------------------------------------------------------
-- POST commands
------------------------------------------------------------------------

postEpisode : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postEpisode h req = getCurrentTime >>= λ now →
  commit h (createEpisode (natOr req "subject" 0) (natOr req "protocol" 0) (fieldOr req "jtbd" "") defaultTenant now)

postEpisodeTransition : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postEpisodeTransition h req = getCurrentTime >>= λ now →
  commit h (transitionEpisode (natOr req "episode" 0) (natOr req "state" 0) defaultTenant now)

postEdge : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postEdge h req = getCurrentTime >>= λ now →
  commit h (addEdge (natOr req "from" 0) (natOr req "to" 0) participation nothing 0 now nothing defaultTenant now)

postAppointment : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postAppointment h req = getCurrentTime >>= λ now →
  commit h (bookAppointment (natOr req "subject" 0) (natOr req "resource" 0) nothing nothing
                            (natOr req "start" 0) (natOr req "duration" 60) defaultTenant now)

postApptCancel postApptComplete postApptNoShow postSubjectDelete : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postApptCancel   h req = commitUnit h (cancelAppointment   (natOr req "id" 0))
postApptComplete h req = commitUnit h (completeAppointment (natOr req "id" 0))
postApptNoShow   h req = commitUnit h (noShowAppointment   (natOr req "id" 0))
postSubjectDelete h req = commitUnit h (cascadeDeleteSubject (natOr req "id" 0))

postCredit : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postCredit h req = commitUnit h (credit (natOr req "acc" 0) (natOr req "amt" 0))

postNotification : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postNotification h req = getCurrentTime >>= λ now →
  commit h (enqueueNotification (fieldOr req "channel" "email") (fieldOr req "to" "")
                                (fieldOr req "subject" "") (fieldOr req "body" "") defaultTenant now)

drainOutboxEP : WalHandle Base CxmOp → IO HttpResponse
drainOutboxEP h = commitTxn h drainOutbox >>= λ where
  (committed n) → pure (okJson ("{\"drained\":" <> show n <> "}"))
  (rejected e)  → pure (errResp e)
  ioFailed      → pure (errJson 503 "internal" "storage write failed")

postAssign : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postAssign h req = getCurrentTime >>= λ now →
  commit h (assignRole (fieldOr req "subject" "") (fieldOr req "role" "") (fieldOr req "scope" "") defaultTenant now)

postRevoke : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postRevoke h req = commitUnit h (revokeRole (fieldOr req "subject" "") (fieldOr req "role" "") (fieldOr req "scope" ""))

-- POST /integration-tokens {scope,origin} → mint a store-backed site credential. The bearer secret
-- is generated here (crypto random) and returned ONCE ({id,token}); the operator hands it to the site.
postCreateIntToken : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postCreateIntToken h req = getCurrentTime >>= λ now → randomBytesB64 24 >>= λ tok →
  commitTxn h (createIntegrationToken tok (fieldOr req "scope" "/v1") (fieldOr req "origin" "") defaultTenant now) >>= λ where
    (committed tid) → pure (okJson ("{\"id\":" <> show tid <> ",\"token\":" <> str tok <> "}"))
    (rejected e)    → pure (errResp e)
    ioFailed        → pure (errJson 503 "internal" "storage write failed")

-- POST /integration-tokens/revoke {id} → soft-revoke (keeps the audit row)
postRevokeIntToken : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postRevokeIntToken h req = getCurrentTime >>= λ now → commitUnit h (revokeIntegrationToken (natOr req "id" 0) now)

private
  mFk : ℕ → Maybe ℕ            -- request nat 0 ⇒ absent (ids start at 1)
  mFk 0 = nothing
  mFk n = just n

  mStr : String → Maybe String -- request field "" ⇒ absent
  mStr s = if primStringEquality s "" then nothing else just s

-- POST /resources {payload[,parent,visibility,author,kind]} → publish content (author>0 also
-- journals the Publish event in the SAME Txn; authorless = operator/system content) — S5
postResource : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postResource h req = getCurrentTime >>= λ now → pick (natOr req "author" 0) now
  where
    pick : ℕ → ℕ → IO HttpResponse
    pick 0 now = commit h (createResource (mFk (natOr req "parent" 0)) (natOr req "kind" 1) 0
                             (mStr (fieldOr req "visibility" "")) (fieldOr req "payload" "{}")
                             nothing (mStr (fieldOr req "listing" "")) defaultTenant now)
    pick a now = commit h (publishResource a (mFk (natOr req "parent" 0))
                             (mStr (fieldOr req "visibility" "")) (fieldOr req "payload" "{}")
                             (mStr (fieldOr req "listing" "")) defaultTenant now)

-- POST /resources/update {id[,payload,visibility,listing]} → edit a LIVE node ("" = keep the
-- current value); stamps rUpdatedAt (П2 blog hygiene). Operator right: this route sits behind
-- the operator gate (JWT/token), so no author check — the operator edits any node of the instance.
postResourceUpdate : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postResourceUpdate h req = getCurrentTime >>= λ now →
  commitUnit h (updateResource (natOr req "id" 0)
                               (mStr (fieldOr req "payload" ""))
                               (mStr (fieldOr req "visibility" ""))
                               (mStr (fieldOr req "listing" "")) now)

-- POST /entitlements {subject,target} → grant TResource access (sell/comp a node or a TREE root) — S5
postGrantEntitlement : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postGrantEntitlement h req = getCurrentTime >>= λ now →
  commit h (grantEntitlement (natOr req "subject" 0) TResource (natOr req "target" 0)
                             now nothing SGrant defaultTenant now)

-- POST /offerings {kind,price,currency,metadata} → create a sellable offering. `metadata` is the
-- fulfilment PLAN (П3, fulfilment-as-data): e.g. {"grants":[{"kind":"resource","id":N}]} — on a
-- succeeded payment fulfillOffering issues those grants to the buyer (Cxm.Fulfilment interprets it).
postOffering : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postOffering h req = getCurrentTime >>= λ now →
  commit h (createOffering (natOr req "kind" 1) (natOr req "price" 0)
                           (fieldOr req "currency" "RUB") (fieldOr req "metadata" "{}") defaultTenant now)

-- POST /payments/succeed {id} → mark a payment succeeded (grants the offering + runs fulfilment,
-- ONE idempotent Txn). This is the provider/operator confirmation hinge (a real gateway calls it
-- from its signed webhook via a pack; the core exposes it operator-gated so a provider-less
-- self-service deploy can confirm too). NOT public: confirming a payment is a trust boundary —
-- a buyer must not succeed their own payment.
postPaymentSucceed : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postPaymentSucceed h req = getCurrentTime >>= λ now →
  commitUnit h (markPaymentSucceeded (natOr req "id" 0) now)

-- Curation links (S8): pin/promote content on a showcase node; a SOLD promo slot = a link with
-- validTo = the paid-through time (until=0 ⇒ open-ended). Expiry is projection-side.
postResourceLink : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postResourceLink h req = getCurrentTime >>= λ now →
  commit h (linkResource (natOr req "from" 0) (natOr req "to" 0)
                         (fieldOr req "kind" "pin") (natOr req "rank" 0)
                         (mFk (natOr req "until" 0)) defaultTenant now)

postResourceUnlink : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postResourceUnlink h req = commitUnit h (unlinkResource (natOr req "id" 0))

getResourceLinks : WalHandle Base CxmOp → IO HttpResponse
getResourceLinks h = readBase h >>= λ b →
  pure (okJson (listAll linkJson (tscan resourceLinksT b)))
  where linkJson : ResourceLink → String
        linkJson l = "{\"id\":" <> show (rlId l) <> ",\"from\":" <> show (rlFrom l)
          <> ",\"to\":" <> show (rlTo l) <> ",\"kind\":" <> str (rlKind l)
          <> ",\"rank\":" <> show (rlRank l) <> ",\"until\":" <> show (mNat0 (rlValidTo l)) <> "}"

-- POST /identities {subject,channel,id[,verified]} → bind a channel identifier to a subject
-- (audit fix, CRM parity: the operator adds a client email/phone — email lives in Identity)
postBindIdentity : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postBindIdentity h req = getCurrentTime >>= λ now →
  commit h (bindIdentity (natOr req "subject" 0) (fieldOr req "channel" "email")
                         (fieldOr req "id" "")
                         (primStringEquality (fieldOr req "verified" "false") "true")
                         defaultTenant now)

-- protocol definitions as data (audit fix: lines could not transition — no way to create rules)
postProtocol : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postProtocol h req = getCurrentTime >>= λ now →
  commit h (createProtocol (fieldOr req "name" "") (natOr req "initial" 0) defaultTenant now)

postProtocolState : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postProtocolState h req =
  commit h (addProtocolState (natOr req "protocol" 0) (natOr req "state" 0)
                             (fieldOr req "name" "") defaultTenant)

postProtocolTransition : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postProtocolTransition h req =
  commit h (addProtocolTransition (natOr req "protocol" 0) (natOr req "from" 0)
                                  (natOr req "to" 0) defaultTenant)

-- Promise futures (upgrade-план A6) + П6 controllable obligations: create directed WITH a held
-- stake (collateral + stakeAccount) and a declared consequence (penaltyTo) / clearing / reliability
postPromise : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postPromise h req = getCurrentTime >>= λ now →
  commit h (createPromiseDirected (natOr req "subject" 0) (fieldOr req "topic" "")
                                  (natOr req "deadline" 0)
                                  (if primStringEquality (fieldOr req "direction" "ours") "theirs"
                                   then Theirs else Ours)
                                  (boolOr req "transferable") (natOr req "collateral" 0)
                                  (mFk (natOr req "stakeAccount" 0)) (mFk (natOr req "penaltyTo" 0))
                                  (boolOr req "referable")
                                  defaultTenant now)
  where boolOr : HttpRequest → String → Bool
        boolOr r name = primStringEquality (fieldOr r name "false") "true"

postPromiseList : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postPromiseList h req = getCurrentTime >>= λ now →
  commit h (listPromise (natOr req "id" 0) defaultTenant now)

-- П6: sell/gift the CLAIM — reassign recipient; penaltyTo optionally follows to the new holder
postPromiseTransfer : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postPromiseTransfer h req = getCurrentTime >>= λ now →
  commitUnit h (transferPromise (natOr req "id" 0) (natOr req "holder" 0)
                                (mFk (natOr req "penaltyTo" 0)) defaultTenant now)

-- П6: refer the DUTY — reassign the obligor's stake to a colleague's account (proof-gated)
postPromiseRefer : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postPromiseRefer h req = getCurrentTime >>= λ now →
  commitUnit h (referPromise (natOr req "id" 0) (natOr req "newStakeAccount" 0) defaultTenant now)

postPromiseSettle : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postPromiseSettle h req = getCurrentTime >>= λ now →
  commitUnit h (settlePromise (natOr req "id" 0) defaultTenant now)

postPromiseDefault : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postPromiseDefault h req = getCurrentTime >>= λ now →
  commitUnit h (defaultPromise (natOr req "id" 0) defaultTenant now)

postReliability : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postReliability h req = readBase h >>= λ b →
  pure (okJson (reliabilityJson
    (reliabilityOf (natOr req "subject" 0)
                   (map proj₂ (tscan promisesT b)) (map proj₂ (tscan appointmentsT b)))))

------------------------------------------------------------------------
-- Authentication (login → JWT; whoami) — ported from Crm.Api. Password hashing is bcrypt at the
-- IO boundary; verifyPassword/JWT are pure. The principal (sub claim) = login = RBAC subject;
-- roles are resolved per-request from the store (not in the token).
------------------------------------------------------------------------

private
  jwtTTL : ℕ
  jwtTTL = 86400

  loginPayload : String → ℕ → String
  loginPayload login now = "{\"sub\":" <> str login <> ",\"exp\":" <> show (now + jwtTTL) <> "}"

  stripBearer : String → String
  stripBearer s with toList s
  ... | 'B' ∷ 'e' ∷ 'a' ∷ 'r' ∷ 'e' ∷ 'r' ∷ ' ' ∷ rest = fromList rest
  ... | _ = s

  findUserByLoginIn : String → List (ℕ × User) → Maybe User
  findUserByLoginIn _     []             = nothing
  findUserByLoginIn login ((_ , u) ∷ us) =
    if primStringEquality (uLogin u) login then just u else findUserByLoginIn login us

-- POST /auth/login {"login","password"} → {"token":<jwt>} | 401
postLogin : (secret : String) → WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postLogin secret h req = getCurrentTime >>= λ now → readBase h >>= λ b →
  verify (fieldOr req "login" "") (fieldOr req "password" "") now b
  where
    verify : String → String → ℕ → Base → IO HttpResponse
    verify login pw now b with findUserByLoginIn login (tscan usersT b)
    ... | nothing = pure (errJson 401 "unauthorized" "invalid credentials")
    ... | just u  = if verifyPassword pw (uPassHash u)
                    then pure (okJson ("{\"token\":" <> str (signJWT secret (loginPayload login now)) <> "}"))
                    else pure (errJson 401 "unauthorized" "invalid credentials")

-- GET /auth/me (Authorization: Bearer <jwt>) → {"login":…} | 401
getMe : (secret : String) → HttpRequest → IO HttpResponse
getMe secret req = getCurrentTime >>= λ now → check now
  where
    check : ℕ → IO HttpResponse
    check now with lookupHeader "authorization" (reqHeaders req)
    ... | nothing = pure (errJson 401 "unauthorized" "missing token")
    ... | just v  with verifyJWT secret now (stripBearer v)
    ...   | nothing      = pure (errJson 401 "unauthorized" "invalid or expired token")
    ...   | just payload with jsonGetField "sub" payload
    ...     | nothing  = pure (errJson 401 "unauthorized" "bad token")
    ...     | just sub = pure (okJson ("{\"login\":" <> str sub <> "}"))

-- POST /auth/users {"login","password"} → create an operator user (hash at the IO boundary)
postCreateUser : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postCreateUser h req = getCurrentTime >>= λ now →
  hashPassword (fieldOr req "password" "") >>= λ ph →
  commit h (createUser (fieldOr req "login" "") ph defaultTenant now)

-- resolve the principal (sub claim) from a Bearer JWT; nothing = anonymous
resolvePrincipal : (secret : String) → HttpRequest → IO (Maybe String)
resolvePrincipal secret req = getCurrentTime >>= λ now → pure (extract now)
  where
    extract : ℕ → Maybe String
    extract now with lookupHeader "authorization" (reqHeaders req)
    ... | nothing = nothing
    ... | just v  with verifyJWT secret now (stripBearer v)
    ...   | nothing      = nothing
    ...   | just payload = jsonGetField "sub" payload

------------------------------------------------------------------------
-- Routing: token gate + authz hook + pack extension (routeExt), then core dispatch
------------------------------------------------------------------------

private
  is : String → String → Bool
  is = primStringEquality

  -- bearer-token gate ("" = open, loopback-only). Authorization: Bearer <token>
  authOk : String → HttpRequest → Bool
  authOk ""  _   = true
  authOk tok req with lookupHeader "authorization" (reqHeaders req)
  ... | just v  = primStringEquality v ("Bearer " <> tok)
  ... | nothing = false

  dispatch : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
  dispatch h req =
    let m = reqMethod req ; p = reqPath req in
    if is m "GET" then
      (if      is p "/subjects"     then getSubjects h
       else if is p "/episodes"     then getEpisodes h
       else if is p "/appointments" then getAppointments h
       else if is p "/edges"        then getEdges h
       else if is p "/identities"   then getIdentities h
       else if is p "/accounts"     then getAccounts h
       else if is p "/outbox"       then getOutbox h
       else if is p "/events"       then getBusEvents h
       else if is p "/experience-events" then getExperienceLog h
       else if is p "/assignments"  then getAssignments h
       else if is p "/integration-tokens" then getIntTokens h
       else if is p "/promises"     then getPromises h
       else if is p "/payments"     then getPayments h
       else if is p "/resources"    then getResources h
       else if is p "/resource-links" then getResourceLinks h
       else if is p "/offerings"     then getOfferings h
       else pure (errJson 404 "not_found" "no route"))
    else if is m "POST" then
      (if      is p "/subjects"        then postSubject h req
       else if is p "/subjects/delete" then postSubjectDelete h req
       else if is p "/query"           then postQuery h req
       else if is p "/decision"        then postDecision h req
       else if is p "/episodes"        then postEpisode h req
       else if is p "/episodes/transition" then postEpisodeTransition h req
       else if is p "/edges"           then postEdge h req
       else if is p "/edges/by-subject" then postEdgesBySubject h req
       else if is p "/appointments"    then postAppointment h req
       else if is p "/appointments/cancel"     then postApptCancel h req
       else if is p "/appointments/complete"   then postApptComplete h req
       else if is p "/appointments/no-show"    then postApptNoShow h req
       else if is p "/appointments/by-episode" then postAppointmentsByEpisode h req
       else if is p "/accounts"        then postAccount h req
       else if is p "/charge"          then postCharge h req
       else if is p "/credit"          then postCredit h req
       else if is p "/notifications"   then postNotification h req
       else if is p "/outbox/drain"    then drainOutboxEP h
       else if is p "/events/dispatch" then dispatchEvents h
       else if is p "/assignments"     then postAssign h req
       else if is p "/assignments/revoke" then postRevoke h req
       else if is p "/integration-tokens" then postCreateIntToken h req
       else if is p "/integration-tokens/revoke" then postRevokeIntToken h req
       else if is p "/resources"         then postResource h req
       else if is p "/resources/update"  then postResourceUpdate h req
       else if is p "/entitlements"      then postGrantEntitlement h req
       else if is p "/offerings"         then postOffering h req
       else if is p "/payments/succeed"  then postPaymentSucceed h req
       else if is p "/resource-links"    then postResourceLink h req
       else if is p "/resource-links/remove" then postResourceUnlink h req
       else if is p "/identities"        then postBindIdentity h req
       else if is p "/protocols"         then postProtocol h req
       else if is p "/protocols/state"   then postProtocolState h req
       else if is p "/protocols/transition" then postProtocolTransition h req
       else if is p "/promises"          then postPromise h req
       else if is p "/promises/list"     then postPromiseList h req
       else if is p "/promises/transfer" then postPromiseTransfer h req
       else if is p "/promises/refer"    then postPromiseRefer h req
       else if is p "/promises/settle"   then postPromiseSettle h req
       else if is p "/promises/default"  then postPromiseDefault h req
       else if is p "/reliability"       then postReliability h req
       else if is p "/auth/users"      then postCreateUser h req
       else pure (errJson 404 "not_found" "no route"))
    else pure (errJson 405 "validation" "method not allowed")

-- Neutral extension hook: /auth/login + /auth/me bypass the token gate (login IS how you get a
-- token; /auth/me validates its own JWT). Otherwise: token gate → resolve the principal from the
-- Bearer JWT → `authz principal req` (`just <4xx>` BLOCKS — where the app enforces canAssign /
-- per-scope perms, §4.15 — `nothing` allows) → pack `ext` routes → core dispatch.
routeExt : (HttpRequest → IO (Maybe HttpResponse))
         → (Maybe String → HttpRequest → IO (Maybe HttpResponse))
         → (token secret : String) → WalHandle Base CxmOp → HttpRequest → IO HttpResponse
routeExt ext authz token secret h req =
  let m = reqMethod req ; p = reqPath req in
  if is m "POST" ∧ is p "/auth/login" then postLogin secret h req
  else if is m "GET" ∧ is p "/auth/me" then getMe secret req
  else if authOk token req
    then (resolvePrincipal secret req >>= λ principal →
          authz principal req >>= λ where
            (just blocked) → pure blocked
            nothing → (ext req >>= λ where
                         (just r) → pure r
                         nothing  → dispatch h req))
    else pure (errJson 401 "unauthorized" "missing or invalid bearer token")

-- Convenience router with NO pack routes and an ALLOW-ALL authz (audit #2): every valid-token
-- request reaches every operator route, including destructive ones (/subjects/delete, /assignments).
-- Safe only for open/loopback (token "") or single-operator deploys. PRODUCTION must call `routeExt`
-- with a real `authz` (route→perm + canAssign) — this default does not gate per-permission.
route : (token secret : String) → WalHandle Base CxmOp → HttpRequest → IO HttpResponse
route token secret h req = routeExt (λ _ → pure nothing) (λ _ _ → pure nothing) token secret h req

------------------------------------------------------------------------
-- §7.7 bookmark 1 — the API-FIRST PUBLIC boundary (a site credential, NOT the operator API):
-- versioned /v1 paths, CORS, gated by a SCOPED integration token (bookmark 4). Kept separate
-- from routeExt so "operator API" is never exposed outward.
------------------------------------------------------------------------

private
  corsHeaders : List StrPair
  corsHeaders = mkStrPair "Access-Control-Allow-Origin" "*"
              ∷ mkStrPair "Access-Control-Allow-Headers" "Content-Type, X-Integration-Token"
              ∷ mkStrPair "Access-Control-Allow-Methods" "GET, POST, OPTIONS" ∷ []

  okCors : String → HttpResponse
  okCors body = mkResponseHRaw 200 ("{\"data\":" <> body <> "}") corsHeaders

  errCors : ℕ → String → String → HttpResponse
  errCors status code msg =
    mkResponseHRaw status ("{\"error\":{\"code\":\"" <> code <> "\",\"message\":\""
                          <> escapeJsonString msg <> "\"}}") corsHeaders

  errCorsResp : Err → HttpResponse
  errCorsResp NotFound          = errCors 404 "not_found"          "not found"
  errCorsResp Conflict          = errCors 409 "conflict"           "conflict"
  errCorsResp Insufficient      = errCors 402 "insufficient_funds" "insufficient funds"
  errCorsResp InvalidTransition = errCors 409 "invalid_transition" "invalid transition"
  errCorsResp Forbidden         = errCors 403 "forbidden"          "forbidden"
  errCorsResp (Invariant m)     = errCors 400 "validation"         m

  preflight : HttpResponse
  preflight = mkResponseHRaw 204 "" corsHeaders

  commitCors : WalHandle Base CxmOp → Txn ℕ → IO HttpResponse
  commitCors h tx = commitTxn h tx >>= λ where
    (committed id) → pure (okCors ("{\"id\":" <> show id <> "}"))
    (rejected e)   → pure (errCorsResp e)
    ioFailed       → pure (errCors 503 "internal" "storage write failed")

  commitUnitCors : WalHandle Base CxmOp → Txn ⊤ → IO HttpResponse
  commitUnitCors h tx = commitTxn h tx >>= λ where
    (committed _) → pure (okCors "{\"ok\":true}")
    (rejected e)  → pure (errCorsResp e)
    ioFailed      → pure (errCors 503 "internal" "storage write failed")

  channelOf : String → Channel
  channelOf s = if is s "mobile" then Mobile else if is s "chat" then Chat
                else if is s "email" then Email else if is s "community" then Community
                else if is s "web" then Web else Integration

  eventTypeOf : String → EventType
  eventTypeOf s = if is s "purchase" then Purchase else if is s "ticket_open" then TicketOpen
                  else if is s "feature_use" then FeatureUse else if is s "feature_request" then FeatureRequest
                  else if is s "publish" then Publish else if is s "reaction" then Reaction
                  else View

-- §7.7 bookmark 2 — canonical event ingest: site → ExperienceEvent → append (single entry of
-- facts). The identity bridge (bookmark 3) is inside ingestSiteEvent: resolve identity_channel /
-- identity_id, else provision a subject + Identity, then append.
-- Peer events (B3): optional `counterpart_channel`/`counterpart_id` resolve the SECOND side
-- through the same identity bridge; `actor:"peer"` marks a client→client event (слой IX).
postV1Events : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postV1Events h req = getCurrentTime >>= λ now →
  let actor = if is (fieldOr req "actor" "client") "peer" then Peer else Client
      ev = mkExperienceEvent 0 0 defaultTenant (channelOf (fieldOr req "channel" "integration")) actor now
             (eventTypeOf (fieldOr req "type" "view")) 0 nothing nothing nothing nothing false false
             (fieldOr req "payload" "{}") nothing
  in commitCors h (ingestPeerEvent (fieldOr req "identity_channel" "cookie") (fieldOr req "identity_id" "")
                                   (fieldOr req "counterpart_channel" "cookie") (fieldOr req "counterpart_id" "")
                                   defaultTenant now ev)

-- §7.7 bookmark 3 — identity bridge on login: alias the session's provisional subject into the
-- canonical one (merge), so pre-login events read as one subject.
postV1Login : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postV1Login h req = getCurrentTime >>= λ now →
  commitUnitCors h (mergeSession (natOr req "provisional" 0)
                                 (fieldOr req "channel" "user_id") (fieldOr req "id" "") defaultTenant now)

-- self-facing progress (слой IX, upgrade-план B6): the subject's OWN public contribution fold,
-- served to them through the site. Resolve the identity WITHOUT provisioning (an unknown id is
-- 404, not a fresh subject — reads must not create), then run the projection.
postV1Progress : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postV1Progress h req = readBase h >>= λ b →
  answer (findIdentityIn (fieldOr req "identity_channel" "cookie") (fieldOr req "identity_id" "")
                         (map proj₂ (tscan identitiesT b))) b
  where
    answer : Maybe ℕ → Base → IO HttpResponse
    answer nothing  _ = pure (errCors 404 "not_found" "unknown identity")
    answer (just s) b = pure (okCors ("{\"subject\":" <> show s
      <> ",\"contribution\":" <> show (contributionOf s (map proj₂ (tscan eventsT b))) <> "}"))

-- social /v1 (cxm-social-plan S5): follow / publish / feed / thread — the LJ-like surface for
-- ANY integrated site, same identity-bridge, so the reader and the client are ONE subject.

postV1Follow : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postV1Follow h req = getCurrentTime >>= λ now →
  commitCors h
    ( resolveOrCreateSubject (fieldOr req "identity_channel" "cookie") (fieldOr req "identity_id" "")
                             "" "UTC" defaultTenant now >>=T λ follower →
      resolveOrCreateSubject (fieldOr req "target_channel" "user_id") (fieldOr req "target_id" "")
                             "" "UTC" defaultTenant now >>=T λ author →
      followSubject follower author defaultTenant now )
  where open import Cxm.Txn using (_>>=T_)

postV1Publish : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postV1Publish h req = getCurrentTime >>= λ now →
  commitCors h
    ( resolveOrCreateSubject (fieldOr req "identity_channel" "cookie") (fieldOr req "identity_id" "")
                             "" "UTC" defaultTenant now >>=T λ author →
      publishResource author (mFk (natOr req "parent" 0)) (mStr (fieldOr req "visibility" ""))
                      (fieldOr req "payload" "{}") (mStr (fieldOr req "listing" "")) defaultTenant now )
  where open import Cxm.Txn using (_>>=T_)

-- the viewer's feed (poll-минимум; push — WS-закладка). Unknown identity ⇒ 404 (reads don't create).
postV1Feed : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postV1Feed h req = getCurrentTime >>= λ now → readBase h >>= λ b →
  answer now b (findIdentityIn (fieldOr req "identity_channel" "cookie") (fieldOr req "identity_id" "")
                               (map proj₂ (tscan identitiesT b)))
  where
    answer : ℕ → Base → Maybe ℕ → IO HttpResponse
    answer _   _ nothing  = pure (errCors 404 "not_found" "unknown identity")
    answer now b (just v) = pure (okCors (array (map contentViewJson
      (feedViews now v (map proj₂ (tscan edgesT b)) (map proj₂ (tscan entitlementsT b))
                    (map proj₂ (tscan resourcesT b))))))

private
  -- F4 (аудит-2): may `viewer` open the thread rooted at `root`? A root inside a NON-resource
  -- anchored conversation is gated by the anchor's audience (the /v1/conversation gate must
  -- not be bypassable through the thread endpoint).
  threadAudienceOk : Base → Maybe ℕ → ℕ → Bool
  threadAudienceOk b viewer root with tget resourcesT root b
  ... | nothing = true                                            -- unknown root → empty anyway
  ... | just r with rAnchorKind r
  ...   | nothing = true                                          -- plain content thread
  ...   | just k  = if primStringEquality k "resource" then true
                    else maybe′ (λ v → anchorParticipantᵇ b k (mNat0 (rAnchorId r)) v) false viewer

-- a post's comment tree (self-rebuilding: pure projection per read); anonymous viewers allowed
-- for resource-anchored talks; non-resource anchors — audience-gated (F4).
postV1Thread : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postV1Thread h req = getCurrentTime >>= λ now → readBase h >>= λ b →
  let viewer = findIdentityIn (fieldOr req "identity_channel" "cookie") (fieldOr req "identity_id" "")
                              (map proj₂ (tscan identitiesT b))
      root = natOr req "root" 0
  in pure (okCors (array (map threadViewJson
       (if threadAudienceOk b viewer root
        then threadViews now viewer (map proj₂ (tscan edgesT b)) (map proj₂ (tscan entitlementsT b))
                         root (map proj₂ (tscan resourcesT b))
        else []))))
-- the front page / showcase read (S8): curated pins in rank order, teaser semantics; the
-- viewer is optional (anonymous front pages are the norm)
postV1Showcase : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postV1Showcase h req = getCurrentTime >>= λ now → readBase h >>= λ b →
  let viewer = findIdentityIn (fieldOr req "identity_channel" "cookie") (fieldOr req "identity_id" "")
                              (map proj₂ (tscan identitiesT b))
  in pure (okCors (array (map contentViewJson
       (showcaseViews now viewer (map proj₂ (tscan edgesT b)) (map proj₂ (tscan entitlementsT b))
                      (map proj₂ (tscan resourceLinksT b)) (natOr req "root" 0)
                      (map proj₂ (tscan resourcesT b))))))

-- §10: comment on ANY entity + the conversation read (since-cursor = pull-подписка)
private
  -- parse "3,5,7" → [3,5,7] (comma-separated nats; garbage segments dropped)
  splitNats : String → List ℕ
  splitNats s = go (toList s) 0 false
    where
      digit : Char → ℕ
      digit c = dig (fromList (c ∷ []))
        where dig : String → ℕ
              dig "0" = 0 ; dig "1" = 1 ; dig "2" = 2 ; dig "3" = 3 ; dig "4" = 4
              dig "5" = 5 ; dig "6" = 6 ; dig "7" = 7 ; dig "8" = 8 ; dig "9" = 9
              dig _ = 0
      go : List Char → ℕ → Bool → List ℕ
      go [] acc seen = if seen then acc ∷ [] else []
      go (c ∷ cs) acc seen =
        if is (fromList (c ∷ [])) "," then (if seen then acc ∷ go cs 0 false else go cs 0 false)
        else go cs (acc * 10 + digit c) true

postV1Comment : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postV1Comment h req = getCurrentTime >>= λ now →
  commitCors h
    ( resolveOrCreateSubject (fieldOr req "identity_channel" "cookie") (fieldOr req "identity_id" "")
                             "" "UTC" defaultTenant now >>=T λ author →
      commentOn author (fieldOr req "anchor_kind" "resource") (natOr req "anchor_id" 0)
                (mFk (natOr req "parent" 0)) (mStr (fieldOr req "visibility" ""))
                (mStr (fieldOr req "listing" "")) (fieldOr req "payload" "{}")
                (splitNats (fieldOr req "to" "")) defaultTenant now )
  where open import Cxm.Txn using (_>>=T_)

-- flat since-page of a conversation (client assembles the tree by id/parent; §10 storage synth)
private
  insMentionByOrd : Mention → List Mention → List Mention
  insMentionByOrd y [] = y ∷ []
  insMentionByOrd y (z ∷ zs) = if mOrd y ≤ᵇ mOrd z then y ∷ z ∷ zs else z ∷ insMentionByOrd y zs

  mentionSubjectsOrdered : Base → ℕ → List ℕ
  mentionSubjectsOrdered b rid =
    map mSubject (foldr insMentionByOrd []
      (mapMaybe (λ i → tget mentionsT i b) (tbyIndex mentionsT mByResource rid b)))

-- flat since-page of a conversation (client assembles the tree by id/parent; §10 storage synth).
-- F4 (аудит-фикс): for a NON-resource anchor the viewer must be an anchor PARTICIPANT
-- (anonymous ⇒ empty) — the anchor's audience gates the whole conversation; node policies
-- (canList/locked) apply on top. resource-anchored talks are ruled by node policies alone.
postV1Conversation : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postV1Conversation h req = getCurrentTime >>= λ now → readBase h >>= λ b →
  let viewer = findIdentityIn (fieldOr req "identity_channel" "cookie") (fieldOr req "identity_id" "")
                              (map proj₂ (tscan identitiesT b))
      ak = fieldOr req "anchor_kind" "resource"
      ai = natOr req "anchor_id" 0
      since = natOr req "since" 0
      lim = natOr req "limit" 100
      rsAll = map proj₂ (tscan resourcesT b)
      edgesL = map proj₂ (tscan edgesT b)
      entsL  = map proj₂ (tscan entitlementsT b)
      audienceOk : Bool
      audienceOk = if primStringEquality ak "resource" then true
                   else maybe′ (λ v → anchorParticipantᵇ b ak ai v) false viewer
      inConv : Resource → Bool
      inConv r = maybe′ (λ k → primStringEquality k ak) false (rAnchorKind r)
               ∧ maybe′ (λ x → x ≡ᵇ ai) false (rAnchorId r)
               ∧ (since <ᵇ rId r)
               ∧ maybe′ (λ _ → false) true (rDeletedAt r)
               ∧ canList now viewer edgesL entsL rsAll r
      enc : (ℕ × Resource) → String
      enc p = convNodeJson (mentionSubjectsOrdered b (proj₁ p))
                (notᵇ (canAccess now viewer edgesL entsL rsAll (proj₂ p))) (proj₂ p)
  in pure (okCors (array (map enc
       (if audienceOk then take lim (filterRows inConv (tscan resourcesT b)) else []))))
  where notᵇ : Bool → Bool
        notᵇ true = false
        notᵇ false = true

-- П2 (гигиена блога): edit YOUR OWN post from the site. The identity resolves WITHOUT
-- provisioning (an unknown identity cannot edit — 404, writes must not create here); the
-- author gate itself is IN the command (updateOwnResource → Forbidden for a non-author,
-- including authorless operator content). "" fields = keep the current value.
postV1ResourceUpdate : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postV1ResourceUpdate h req = getCurrentTime >>= λ now → readBase h >>= λ b →
  go now (findIdentityIn (fieldOr req "identity_channel" "cookie") (fieldOr req "identity_id" "")
                         (map proj₂ (tscan identitiesT b)))
  where
    go : ℕ → Maybe ℕ → IO HttpResponse
    go _   nothing  = pure (errCors 404 "not_found" "unknown identity")
    go now (just s) = commitUnitCors h
      (updateOwnResource s (natOr req "id" 0)
                         (mStr (fieldOr req "payload" ""))
                         (mStr (fieldOr req "visibility" ""))
                         (mStr (fieldOr req "listing" "")) now)

-- П2: the mentions INBOX («все ответы/упоминания мне», §10 F3) — ONE indexed lookup
-- (mentionsT bySubject) + a since-cursor on the MENTION id, ascending: the client keeps the
-- max id it has seen and polls {"since":<maxId>} (pull-подписка, same shape as /v1/conversation).
-- Reads must not create (unknown identity ⇒ 404). Every item renders its node through the SAME
-- gates as the conversation read (F4): non-resource anchors need the viewer to be an anchor
-- PARTICIPANT, existence needs canList, an unreadable payload is stripped (locked) — being
-- @-mentioned in a talk you may not see must NOT leak it into your inbox.
postV1Mentions : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postV1Mentions h req = getCurrentTime >>= λ now → readBase h >>= λ b →
  answer now b (findIdentityIn (fieldOr req "identity_channel" "cookie") (fieldOr req "identity_id" "")
                               (map proj₂ (tscan identitiesT b)))
  where
    insAscById : Mention → List Mention → List Mention
    insAscById x [] = x ∷ []
    insAscById x (y ∷ ys) = if mId x ≤ᵇ mId y then x ∷ y ∷ ys else y ∷ insAscById x ys

    answer : ℕ → Base → Maybe ℕ → IO HttpResponse
    answer _   _ nothing  = pure (errCors 404 "not_found" "unknown identity")
    answer now b (just v) = pure (okCors (array (take lim visiblePage)))
      where
        since lim : ℕ
        since = natOr req "since" 0
        lim   = natOr req "limit" 100
        edgesL = map proj₂ (tscan edgesT b)
        entsL  = map proj₂ (tscan entitlementsT b)
        rsAll  = map proj₂ (tscan resourcesT b)
        notᵇ : Bool → Bool
        notᵇ true = false
        notᵇ false = true
        audienceOk : Resource → Bool
        audienceOk r = maybe′ (λ k → if primStringEquality k "resource" then true
                                     else anchorParticipantᵇ b k (mNat0 (rAnchorId r)) v)
                              true (rAnchorKind r)
        visibleᵇ : Resource → Bool
        visibleᵇ r = liveᵇ (rDeletedAt r) ∧ audienceOk r
                   ∧ canList now (just v) edgesL entsL rsAll r
        -- since-cursor + F4-visibility gate BEFORE take lim (audit П2: filter-then-take, so a
        -- gated mention never eats a page slot — the page carries `lim` VISIBLE items, matching
        -- /v1/conversation's semantics). nothing = dropped (unknown node / gated / stale cursor).
        item : Mention → Maybe String
        item m with (since <ᵇ mId m) | tget resourcesT (mResource m) b
        ... | false | _        = nothing
        ... | true  | nothing  = nothing
        ... | true  | just r   = if visibleᵇ r
          then just ("{\"id\":" <> show (mId m) <> ",\"ord\":" <> show (mOrd m)
                     <> ",\"node\":" <> convNodeJson (mentionSubjectsOrdered b (rId r))
                          (notᵇ (canAccess now (just v) edgesL entsL rsAll r)) r <> "}")
          else nothing
        visiblePage : List String
        visiblePage = mapMaybe item
          (foldr insAscById [] (mapMaybe (λ i → tget mentionsT i b) (tbyIndex mentionsT mBySubject v b)))

-- П3 (покупка самообслуживанием, fulfilment-as-data): the buyer (identity-bridged) records a
-- PENDING payment for a LIVE offering at its price. Fulfilment does NOT happen here — money is
-- authoritative only on /payments/succeed (the provider/operator confirmation), which runs
-- fulfillOffering. Returns {id:<paymentId>}. Unknown/retired offering ⇒ 404. This is the public
-- entry; a provider-backed deploy points its gateway webhook at /payments/succeed for this id.
postV1Purchase : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postV1Purchase h req = getCurrentTime >>= λ now → readBase h >>= λ b →
  go now (tget offeringsT off b)
  where
    off : ℕ
    off = natOr req "offering" 0
    go : ℕ → Maybe Offering → IO HttpResponse
    go _   nothing  = pure (errCors 404 "not_found" "unknown offering")
    go now (just o) = if liveᵇ (oDeletedAt o)
      then commitCors h
        ( resolveOrCreateSubject (fieldOr req "identity_channel" "cookie") (fieldOr req "identity_id" "")
                                 (fieldOr req "name" "") "UTC" defaultTenant now >>=T λ subj →
          recordPayment ("v1-" <> show now <> "-" <> show off <> "-" <> show subj)
                        off subj (oPrice o) (fieldOr req "name" "") (fieldOr req "email" "") defaultTenant now )
      else pure (errCors 404 "not_found" "unknown offering")
      where open import Cxm.Txn using (_>>=T_)
private
  -- gate: a valid integration token in X-Integration-Token whose scope covers the REQUEST PATH
  -- (audit #A — scoping against the path, so a token scoped to "/v1/events" authorizes exactly
  -- that, and a "/v1" token authorizes all of /v1/*). Verify is supplied by the app (agdelte-auth).
  v1Authorized : (String → Maybe IntegrationToken) → HttpRequest → Bool
  v1Authorized verifyTok req with lookupHeader "x-integration-token" (reqHeaders req)
  ... | just t  = maybe′ (λ tok → tokenAuthorizes (reqPath req) tok) false (verifyTok t)
  ... | nothing = false

routeSite : (verifyTok : String → Maybe IntegrationToken) → WalHandle Base CxmOp → HttpRequest → IO HttpResponse
routeSite verifyTok h req =
  let m = reqMethod req ; p = reqPath req in
  if is m "OPTIONS" then pure preflight                         -- CORS preflight
  else if v1Authorized verifyTok req
    then (if      is m "POST" ∧ is p "/v1/events" then postV1Events h req
          else if is m "POST" ∧ is p "/v1/login"  then postV1Login h req
          else if is m "POST" ∧ is p "/v1/me/progress" then postV1Progress h req
          else if is m "POST" ∧ is p "/v1/follow"  then postV1Follow h req
          else if is m "POST" ∧ is p "/v1/publish" then postV1Publish h req
          else if is m "POST" ∧ is p "/v1/me/feed" then postV1Feed h req
          else if is m "POST" ∧ is p "/v1/thread"  then postV1Thread h req
          else if is m "POST" ∧ is p "/v1/showcase" then postV1Showcase h req
          else if is m "POST" ∧ is p "/v1/comment"  then postV1Comment h req
          else if is m "POST" ∧ is p "/v1/conversation" then postV1Conversation h req
          else if is m "POST" ∧ is p "/v1/resource/update" then postV1ResourceUpdate h req
          else if is m "POST" ∧ is p "/v1/me/mentions" then postV1Mentions h req
          else if is m "POST" ∧ is p "/v1/purchase" then postV1Purchase h req
          else pure (errCors 404 "not_found" "no route"))
    else pure (errCors 401 "unauthorized" "missing or invalid integration token")

------------------------------------------------------------------------
-- §7.7 bookmark 4 (outbound) — the signature an outbound webhook carries. Delivery (HTTP POST +
-- retries) is an edge adapter; the CORE guarantee is the HMAC-SHA256 over the canonical payload
-- (pattern from agdelte-payments). The receiver recomputes and constant-time compares.
-- Audit #D: `webhookPayload` is topic⊕body with no timestamp/nonce → no replay protection yet;
-- a hardened adapter adds a timestamp+nonce to the signed payload (edge, deferred with delivery).
------------------------------------------------------------------------

webhookSignature : (secret topic body : String) → String
webhookSignature secret topic body = hmacSHA256 secret (webhookPayload topic body)

------------------------------------------------------------------------
-- Startup: open (replay) the store and seed the configured tenants if the log is empty
-- (Phase-5 audit #C, §9.8). `emptyBase` hardcodes no tenant (principle 12); seeding is here.
------------------------------------------------------------------------

seedIfEmpty : WalHandle Base CxmOp → List Tenant → IO ⊤
seedIfEmpty h ts = readBase h >>= λ b →
  if null (tscan tenantsT b)
    then (commitTxn h (seedTenants ts) >> pure tt)
    else pure tt

openAndSeed : (walPath : String) → List Tenant → IO (WalHandle Base CxmOp)
openAndSeed path ts = openStore path >>= λ h → seedIfEmpty h ts >> pure h

------------------------------------------------------------------------
-- Phase 12 — run(core, config) + pack-activation gating (§7.6, §9.10, principle 12)
------------------------------------------------------------------------

-- the instance is fully determined by its config: open+seed the store from InstanceConfig alone.
runInstance : InstanceConfig → IO (WalHandle Base CxmOp)
runInstance cfg = openAndSeed (shWalPath (cfgStorage cfg)) (cfgSeedTenants cfg)

-- the operator router, with the bearer gate sourced from config (audit #A): now the whole
-- instance — store AND routing — is a pure function of `InstanceConfig` (principle 12).
runRouter : InstanceConfig → WalHandle Base CxmOp → HttpRequest → IO HttpResponse
runRouter cfg h req = route (cfgApiToken cfg) (cfgJwtSecret cfg) h req

-- gate a pack's routeExt extension by config: served only when the pack is active (§9.10). An
-- inactive pack always yields `nothing` (falls through to the core), so ONE binary serves
-- different pack subsets per config with NO code change (Phase 12 DoD). Compose into `routeExt`
-- as its `ext` argument: `routeExt (gatePack cfg "packA" packRoutes) authz token h req`.
gatePack : InstanceConfig → (packId : String) → (HttpRequest → IO (Maybe HttpResponse))
         → (HttpRequest → IO (Maybe HttpResponse))
gatePack cfg pid ext req = if packActive cfg pid then ext req else pure nothing
