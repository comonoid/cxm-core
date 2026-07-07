{-# OPTIONS --without-K --guardedness #-}

-- cxm-server-pg — THE Postgres-backed CXM server (pg-store-plan Ф3, катовер-кандидат).
-- Boot: ledger-driven migrations (cxmHistory + schema_migrations) → seed → listen.
-- Every request = one PG transaction (runCxmTx over connectPerTxn v1; pgbouncer/v2 — только раннер).
-- Commands come from Cxm.CommandsV (the fully-ported, refl-tested corpus); the WAL server
-- (CxmServer) keeps running until the катовер — this binary is stood up NEXT TO it.
--
-- Wave 1 surface (live-smoke set): /health, /auth/{register,login}, /subjects (POST/GET),
-- /identities (bind+verify-mail, ONE atom), /verify-identity (public), /knowledge (+by-subject,
-- +evidence, +rebuild-inference: re-derive a subject's ACTIVE hypotheses from its event log),
-- /notifications (verified-recipient guard), /outbox; PG worker loop (outbox/reminders/bus).
-- Next waves: RBAC-authz port, /v1 site surface, social, query/decision, psych pack, transports.
module CxmServerPg where

open import Agda.Builtin.IO using (IO)
open import Agda.Builtin.Unit using (⊤; tt)
open import Agda.Builtin.String using (String; primStringEquality)
open import Data.Bool using (Bool; true; false; if_then_else_; _∧_; _∨_; not)
open import Data.Char using (Char)
open import Data.List using (List; []; _∷_; map; length; concat; null; foldr)
open import Data.Maybe using (Maybe; just; nothing; maybe′)
open import Data.Nat using (ℕ; _+_; _*_; _≡ᵇ_)
open import Data.Nat.Show using (show; readMaybe)
open import Data.Product using (_×_; _,_; proj₂)
open import Data.Sum using (_⊎_; inj₁; inj₂)
open import Data.String using (toList; fromList) renaming (_++_ to _<>_)

open import Agdelte.FFI.Server using
  ( listenHost; listenUnix; forkLoopNudged; nudgeWorker; getEnvOr; putStrLn
  ; HttpRequest; HttpResponse; reqMethod; reqPath; reqBody; reqHeaders; lookupHeader
  ; mkResponse; _>>=_; _>>_; pure )
open import Agdelte.FFI.Json using (jsonGetField; jsonGetNat; escapeJsonString)
open import Agdelte.FFI.Time using (getCurrentTime)
open import Agdelte.FFI.Crypto using (hashPassword; verifyPassword; hmacSHA256; randomBytesB64)
open import Agdelte.FFI.HttpClient using (HttpClientManager; newHttpClientManager; httpPostStatus)
open import Agdelte.FFI.Server using (eqStrCI; StrPair; mkStrPair)
open import Agdelte.Auth.JWT using (signJWT; verifyJWT)
open import Agdelte.Auth.RBAC using (Policy; Perm; Role; role; parsePerm; can)
open import Agdelte.Storage.PgConn using (TxRunner; connectPerTxn; withConnRaw; execConn; queryConn; Conn)
open import Agdelte.Storage.JsonRow using (decodeIds)
open import Agdelte.Storage.Migration using (up)

open import Cxm.Tenant using (Tenant; mkTenant; defaultTenant)
open import Cxm.Subject using (Subject; sId; sDisplayName; sDeletedAt; EXTERNAL; Person)
open import Cxm.Identity using (Identity; iTenant; iVerified; iChannel; iSubject)
open import Cxm.Edge using (participation)
open import Cxm.Expectation using (ExpStatus; ExpMet; ExpUnmet; ExpUnknown; ExpOurPromise)
open import Cxm.Appointment using (Appointment; apTenant; apStartsAt; apDurationMin; apStatus; ApptStatus; ApScheduled; ApCanceled; ApCompleted; ApNoShow)
open import Cxm.Site using (IntTokenRow; itkTenant; itkScope; itkRevokedAt; webhookPayload)
open import Cxm.Event using (mkExperienceEvent; Integration; Client; View)
open import Cxm.Edge using (SubjectEdge)
open import Cxm.Entitlement using (Entitlement)
open import Cxm.Resource using (Resource; rId; rPayload; rAuthor; rCreatedAt; ResourceLink)
open import Cxm.Social using (feedViews; threadViews; showcaseViews; ContentView; cvLocked; cvResource; ThreadView; tvDepth; tvLocked; tvResource)
open import Cxm.Knowledge using
  ( Knowledge; kDetail; kTenant; kId; kSubject; kType; kSource; kConfidence
  ; kValidFrom; kValidTo; kDecay; kStatus; kEpisode
  ; EpistemicType; FACT; HYPOTHESIS; STATE; TRAIT
  ; Source; OBSERVED; INFERRED; STATED; IMPORTED
  ; KStatus; ACTIVE; CONFIRMED; REFUTED; SUPERSEDED )
open import Cxm.Users using (User; uTenant; uPassHash; RoleAssignment; raSubject; raRoleId)
open import Cxm.Bus using (OutboxEntry; obTo; obSubject; obBody; obChannel; obAttempts; obTenant; obStatus; OutStatus; OutPending; OutSent; OutFailed)
open import Cxm.Store.Base using
  ( Err; NotFound; Conflict; Insufficient; InvalidTransition; Forbidden; Invariant
  ; subjByTenant; knowBySubject; apptBySubject; intTokenByTenant )
open import Cxm.Store.Verbs
open import Cxm.Store.Pg using (runCxmTx)
open import Cxm.Store.Registry using (cxmHistory)
open import Cxm.CommandsV

postulate setLineBuffering : IO ⊤
{-# FOREIGN GHC import System.IO (hSetBuffering, stdout, BufferMode(LineBuffering)) #-}
{-# COMPILE GHC setLineBuffering = hSetBuffering stdout LineBuffering #-}

postulate runPipe : (cmd stdin : String) → IO Bool
{-# FOREIGN GHC
import qualified Data.Text as CxmT
import qualified System.Process as CxmProc
import qualified System.Exit as CxmExit
import qualified Control.Exception as CxmExc
#-}
{-# COMPILE GHC runPipe = \cmd body -> do
      { r <- CxmExc.try (CxmProc.readCreateProcessWithExitCode
                          (CxmProc.shell (CxmT.unpack cmd)) (CxmT.unpack body))
              :: IO (Either CxmExc.SomeException (CxmExit.ExitCode, String, String))
      ; case r of
          { Right (CxmExit.ExitSuccess, _, _) -> pure True
          ; _                                 -> pure False } } #-}

------------------------------------------------------------------------
-- Small HTTP helpers (mirrors Cxm.Api's envelope; encoders local — Api's are private)
------------------------------------------------------------------------

private
  str : String → String
  str s = "\"" <> escapeJsonString s <> "\""

  okJson : String → HttpResponse
  okJson body = mkResponse 200 ("{\"data\":" <> body <> "}")

  errJson : ℕ → String → String → HttpResponse
  errJson st code msg =
    mkResponse st ("{\"error\":{\"code\":" <> str code <> ",\"message\":" <> str msg <> "}}")

  errResp : Err → HttpResponse
  errResp NotFound          = errJson 404 "not_found" "not found"
  errResp Conflict          = errJson 409 "conflict" "conflict"
  errResp Insufficient      = errJson 402 "insufficient_funds" "insufficient funds"
  errResp InvalidTransition = errJson 409 "invalid_transition" "invalid transition"
  errResp Forbidden         = errJson 403 "forbidden" "forbidden"
  errResp (Invariant m)     = errJson 400 "validation" m

  fieldOr : HttpRequest → String → String → String
  fieldOr req k d = maybe′ (λ v → v) d (jsonGetField k (reqBody req))

  natOr : HttpRequest → String → ℕ → ℕ
  natOr req k d = maybe′ (λ v → v) d (jsonGetNat k (reqBody req))

  is : String → String → Bool
  is = primStringEquality

  stripBearer : String → String
  stripBearer s = go (toList s)
    where go : List Char → String
          go ('B' ∷ 'e' ∷ 'a' ∷ 'r' ∷ 'e' ∷ 'r' ∷ ' ' ∷ rest) = fromList rest
          go _ = s

------------------------------------------------------------------------
-- Tx plumbing: one request = one PG transaction; Err → HTTP envelope
------------------------------------------------------------------------

private
  runW : ∀ {A : Set} → TxRunner → Tx A → (A → HttpResponse) → IO HttpResponse
  runW run tx enc = runCxmTx run tx >>= λ where
    (inj₁ e) → pure (errResp e)
    (inj₂ a) → pure (enc a)

  idJson : ℕ → HttpResponse
  idJson n = okJson ("{\"id\":" <> show n <> "}")

  okUnit : ⊤ → HttpResponse
  okUnit _ = okJson "{\"ok\":true}"

------------------------------------------------------------------------
-- Read programs (bucket-A reads as Tx programs; encoders inline)
------------------------------------------------------------------------

private
  getEach : (t : TableCode) → List ℕ → Tx (List (Val t))
  getEach t []       = returnT []
  getEach t (i ∷ is) = get t i >>=T λ m → getEach t is >>=T λ rest →
                       returnT (maybe′ (λ v → v ∷ rest) rest m)

  joinComma : List String → String
  joinComma []           = ""
  joinComma (x ∷ [])     = x
  joinComma (x ∷ y ∷ xs) = x <> "," <> joinComma (y ∷ xs)

  liveᵇ : Maybe ℕ → Bool
  liveᵇ nothing  = true
  liveᵇ (just _) = false

  listSubjects : (ct : ℕ) → Tx String
  listSubjects ct =
    byIx tcSubject subjByTenant ct >>=T λ ids →
    getEach tcSubject ids >>=T λ ss →
    returnT ("[" <> joinComma (map enc (live ss)) <> "]")
    where
      live : List Subject → List Subject
      live = foldr (λ s acc → if liveᵇ (sDeletedAt s) then s ∷ acc else acc) []
      enc : Subject → String
      enc s = "{\"id\":" <> show (sId s) <> ",\"name\":" <> str (sDisplayName s) <> "}"

  -- enum → wire code (matches CxmUI.Contract knowledgeDec)
  epTypeStr : EpistemicType → String
  epTypeStr FACT = "fact" ; epTypeStr HYPOTHESIS = "hypothesis"
  epTypeStr STATE = "state" ; epTypeStr TRAIT = "trait"
  srcStr : Source → String
  srcStr OBSERVED = "observed" ; srcStr INFERRED = "inferred"
  srcStr STATED = "stated" ; srcStr IMPORTED = "imported"
  kStatStr : KStatus → String
  kStatStr ACTIVE = "active" ; kStatStr CONFIRMED = "confirmed"
  kStatStr REFUTED = "refuted" ; kStatStr SUPERSEDED = "superseded"

  listKnowledge : (ct sid : ℕ) → Tx String
  listKnowledge ct sid =
    byIx tcKnowledge knowBySubject sid >>=T λ ids →
    getEach tcKnowledge ids >>=T λ ks →
    returnT ("[" <> joinComma (map enc (mine ks)) <> "]")
    where
      mine : List Knowledge → List Knowledge
      mine = foldr (λ k acc → if kTenant k ≡ᵇ ct then k ∷ acc else acc) []
      -- full KnowledgeView (Ф0.4.1): id/subject/type/source/confidence/validFrom/validTo/decay/
      -- status/detail/episode — питает блокнот знаний + эпист-бейджи. validTo/episode: 0 = none.
      enc : Knowledge → String
      enc k = "{\"id\":" <> show (kId k)
              <> ",\"subject\":" <> show (kSubject k)
              <> ",\"type\":" <> str (epTypeStr (kType k))
              <> ",\"source\":" <> str (srcStr (kSource k))
              <> ",\"confidence\":" <> show (kConfidence k)
              <> ",\"validFrom\":" <> show (kValidFrom k)
              <> ",\"validTo\":" <> show (maybe′ (λ x → x) 0 (kValidTo k))
              <> ",\"decay\":" <> show (kDecay k)
              <> ",\"status\":" <> str (kStatStr (kStatus k))
              <> ",\"detail\":" <> str (kDetail k)
              <> ",\"episode\":" <> show (maybe′ (λ x → x) 0 (kEpisode k)) <> "}"

  -- /notifications guard: the recipient must be YOUR tenant's VERIFIED binding (P1b)
  ownedTo : (ct : ℕ) (addr : String) → Tx Bool
  ownedTo ct addr =
    byCol tcIdentity "external_id" addr >>=T λ hits →
    returnT (any hits)
    where
      any : List (ℕ × Identity) → Bool
      any [] = false
      any ((_ , i) ∷ rest) = ((iTenant i ≡ᵇ ct) ∧ iVerified i) ∨ any rest

  -- id-preserving fetch (byIx gives ids; readers need (id, row) pairs)
  pairEach : (t : TableCode) → List ℕ → Tx (List (ℕ × Val t))
  pairEach t []       = returnT []
  pairEach t (i ∷ is) = get t i >>=T λ m → pairEach t is >>=T λ rest →
                        returnT (maybe′ (λ v → (i , v) ∷ rest) rest m)

  shAp : ApptStatus → String
  shAp ApScheduled = "scheduled"
  shAp ApCanceled  = "canceled"
  shAp ApCompleted = "completed"
  shAp ApNoShow    = "noshow"

  listAppointments : (ct sid : ℕ) → Tx String
  listAppointments ct sid =
    byIx tcAppointment apptBySubject sid >>=T λ ids →
    pairEach tcAppointment ids >>=T λ as →
    returnT ("[" <> joinComma (map enc (mine as)) <> "]")
    where
      mine : List (ℕ × Appointment) → List (ℕ × Appointment)
      mine = foldr (λ p acc → if apTenant (proj₂ p) ≡ᵇ ct then p ∷ acc else acc) []
      enc : ℕ × Appointment → String
      enc (i , a) = "{\"id\":" <> show i <> ",\"start\":" <> show (apStartsAt a)
                    <> ",\"duration\":" <> show (apDurationMin a)
                    <> ",\"status\":" <> str (shAp (apStatus a)) <> "}"

  stOut : OutStatus → String
  stOut OutPending = "pending"
  stOut OutSent    = "sent"
  stOut OutFailed  = "failed"

  listOutbox : (ct : ℕ) → Tx String
  listOutbox ct =
    scan tcOutbox >>=T λ os →
    returnT ("[" <> joinComma (map enc (mine os)) <> "]")
    where
      mine : List (ℕ × OutboxEntry) → List (ℕ × OutboxEntry)
      mine = foldr (λ p acc → if obTenant (proj₂ p) ≡ᵇ ct then p ∷ acc else acc) []
      enc : ℕ × OutboxEntry → String
      enc (i , o) = "{\"id\":" <> show i <> ",\"to\":" <> str (obTo o)
                    <> ",\"status\":" <> str (stOut (obStatus o)) <> "}"

  listTokens : (ct : ℕ) → Tx String
  listTokens ct =
    byIx tcIntToken intTokenByTenant ct >>=T λ ids →
    pairEach tcIntToken ids >>=T λ ts →
    returnT ("[" <> joinComma (map enc ts) <> "]")
    where
      enc : ℕ × IntTokenRow → String
      enc (i , r) = "{\"id\":" <> show i <> ",\"scope\":" <> str (itkScope r)
                    <> ",\"revoked\":" <> (maybe′ (λ _ → "true") "false" (itkRevokedAt r)) <> "}"

  -- social reads (bucket D): scan the three graph tables, run the pure Social view function.
  -- fetch+fold now; the hot ones become query-EDSL terms later. viewer 0 = anonymous.
  vals : (t : TableCode) → Tx (List (Val t))
  vals t = scan t >>=T λ xs → returnT (map proj₂ xs)

  cvEnc : ContentView → String
  cvEnc cv = "{\"id\":" <> show (rId (cvResource cv))
             <> ",\"locked\":" <> (if cvLocked cv then "true" else "false")
             <> ",\"payload\":" <> str (if cvLocked cv then "" else rPayload (cvResource cv)) <> "}"

  readFeed : (now viewer : ℕ) → Tx String
  readFeed now viewer =
    vals tcEdge >>=T λ es → vals tcEntitlement >>=T λ ens → vals tcResource >>=T λ rs →
    returnT ("[" <> joinComma (map cvEnc (feedViews now viewer es ens rs)) <> "]")

  readShowcase : (now viewer from : ℕ) → Tx String
  readShowcase now viewer from =
    vals tcEdge >>=T λ es → vals tcEntitlement >>=T λ ens →
    vals tcResourceLink >>=T λ ls → vals tcResource >>=T λ rs →
    returnT ("[" <> joinComma (map cvEnc (showcaseViews now (mV viewer) es ens ls from rs)) <> "]")
    where mV : ℕ → Maybe ℕ
          mV 0 = nothing
          mV n = just n

  tvEnc : ThreadView → String
  tvEnc tv = "{\"depth\":" <> show (tvDepth tv) <> ",\"id\":" <> show (rId (tvResource tv))
             <> ",\"locked\":" <> (if tvLocked tv then "true" else "false")
             <> ",\"payload\":" <> str (if tvLocked tv then "" else rPayload (tvResource tv)) <> "}"

  readThread : (now viewer root : ℕ) → Tx String
  readThread now viewer root =
    vals tcEdge >>=T λ es → vals tcEntitlement >>=T λ ens → vals tcResource >>=T λ rs →
    returnT ("[" <> joinComma (map tvEnc (threadViews now (mV viewer) es ens root rs)) <> "]")
    where mV : ℕ → Maybe ℕ
          mV 0 = nothing
          mV n = just n

  parseExpSt : String → ExpStatus
  parseExpSt s = if is s "met" then ExpMet else if is s "unmet" then ExpUnmet else ExpUnknown

  mFk : ℕ → Maybe ℕ
  mFk 0 = nothing
  mFk n = just n

  mStr : String → Maybe String
  mStr s = if is s "" then nothing else just s

------------------------------------------------------------------------
-- RBAC (A1): policy as data; the principal's roles come from role_assignment (byCol login)
------------------------------------------------------------------------

private
  defaultPolicy : Policy
  defaultPolicy =
      role "anon"  [] []
    ∷ role "owner" (parsePerm "cabinet:use" ∷ []) []
    ∷ role "admin" (parsePerm "admin:use" ∷ []) ("owner" ∷ [])
    ∷ []

  -- privileged routes → admin:use; everything else → cabinet:use (owner). Public routes
  -- (/health, /auth/*, /verify-identity, /v1/*) are gated BEFORE authz, so never reach here.
  privPaths : List String
  privPaths = "/auth/users" ∷ "/payments/succeed" ∷ "/credit" ∷ []

  pathPerm : String → Perm
  pathPerm p = if anyᵇ (is p) privPaths then parsePerm "admin:use" else parsePerm "cabinet:use"
    where anyᵇ : (String → Bool) → List String → Bool
          anyᵇ f = foldr (λ x acc → f x ∨ acc) false

  -- roles held by a login (from role_assignment; empty ⇒ ["owner"]: a registered user owns its
  -- own cabinet even before any explicit grant — registerOwnerV DOES grant "owner", this is the
  -- fail-safe default, NOT "anon", since the JWT already proved authenticated identity)
  rolesOfLogin : String → Tx (List String)
  rolesOfLogin login =
    byCol tcAssignment "subject" login >>=T λ hits → returnT (orOwner (map take hits))
    where
      take : ℕ × RoleAssignment → String
      take (_ , a) = raRoleId a
      orOwner : List String → List String
      orOwner [] = "owner" ∷ []
      orOwner xs = xs

------------------------------------------------------------------------
-- Auth: JWT sub → user → tenant (each authd request resolves through one small Tx)
------------------------------------------------------------------------

private
  jwtTTL : ℕ
  jwtTTL = 86400

  -- resolve login → (user tenant, roles) in ONE Tx; then RBAC-gate the route by pathPerm
  authd : TxRunner → HttpRequest → String → Tx (Maybe (ℕ × List String))
  authd run req login =
    findUserByLoginV login >>=T λ where
      nothing  → returnT nothing
      (just u) → rolesOfLogin login >>=T λ rs → returnT (just (uTenant u , rs))

  withTenant : TxRunner → String → HttpRequest → (ℕ → ℕ → IO HttpResponse) → IO HttpResponse
  withTenant run secret req k = getCurrentTime >>= λ now → go now (lookupHeader "authorization" (reqHeaders req))
    where
      k′ : ℕ → ℕ × List String → IO HttpResponse
      k′ now (ct , roles) =
        if can defaultPolicy roles (pathPerm (reqPath req))
        then k ct now
        else pure (errJson 403 "forbidden" "insufficient role")
      go : ℕ → Maybe String → IO HttpResponse
      go now nothing  = pure (errJson 401 "unauthorized" "missing token")
      go now (just v) with verifyJWT secret now (stripBearer v)
      ... | nothing      = pure (errJson 401 "unauthorized" "invalid or expired token")
      ... | just payload with jsonGetField "sub" payload
      ...   | nothing  = pure (errJson 401 "unauthorized" "bad token")
      ...   | just sub = runCxmTx run (authd run req sub) >>= λ where
              (inj₂ (just ctr)) → k′ now ctr
              _                 → pure (errJson 401 "unauthorized" "unknown principal")

------------------------------------------------------------------------
-- Handlers (wave-1 surface)
------------------------------------------------------------------------

private
  postRegister : TxRunner → HttpRequest → IO HttpResponse
  postRegister run req = getCurrentTime >>= λ now →
    hashPassword (fieldOr req "password" "") >>= λ ph →
    runW run (registerOwnerV (fieldOr req "login" "") ph (fieldOr req "name" "") now) idJson

  postLogin : TxRunner → String → HttpRequest → IO HttpResponse
  postLogin run secret req = getCurrentTime >>= λ now →
    runCxmTx run (findUserByLoginV (fieldOr req "login" "")) >>= λ where
      (inj₂ (just u)) →
        if verifyPassword (fieldOr req "password" "") (uPassHash u)
        then pure (okJson ("{\"token\":" <> str (signJWT secret
               ("{\"sub\":" <> str (fieldOr req "login" "") <> ",\"exp\":" <> show (now + jwtTTL) <> "}")) <> "}"))
        else pure (errJson 401 "unauthorized" "invalid credentials")
      _ → pure (errJson 401 "unauthorized" "invalid credentials")

  verifyBody : String → ℕ → String
  verifyBody secret iid =
    "verify: identity=" <> show iid <> " token=" <> hmacSHA256 secret ("verify-identity:" <> show iid)

  postVerifyIdentity : TxRunner → String → HttpRequest → IO HttpResponse
  postVerifyIdentity run secret req = getCurrentTime >>= λ now →
    let iid = natOr req "identity" 0
        tok = fieldOr req "token" ""
        expected = hmacSHA256 secret ("verify-identity:" <> show iid)
    in if primStringEquality tok expected
       then runW run (verifyIdentityV iid now) (λ _ → okJson "{\"verified\":true}")
       else pure (errJson 403 "forbidden" "bad token")

  dispatch : TxRunner → String → (ct now : ℕ) → HttpRequest → IO HttpResponse
  dispatch run secret ct now req =
    let m = reqMethod req ; p = reqPath req in
    if is m "POST" ∧ is p "/subjects" then
      runW run (createSubjectV EXTERNAL Person (fieldOr req "name" "") "UTC" ct now) idJson
    else if is m "GET" ∧ is p "/subjects" then
      runW run (listSubjects ct) okJson
    else if is m "POST" ∧ is p "/identities" then
      (runW run (bindIdentityNotifyV (natOr req "subject" 0) (fieldOr req "channel" "email")
                   (fieldOr req "id" "") ct now "Confirm your contact" (verifyBody secret))
           (λ iid → okJson ("{\"id\":" <> show iid <> ",\"verification\":\"sent\"}"))
        >>= λ resp → nudgeWorker >> pure resp)
    else if is m "POST" ∧ is p "/knowledge" then
      runW run (createKnowledgeV (natOr req "subject" 0) STATE STATED 500
                  (fieldOr req "detail" "") 0 now nothing nothing ct) idJson
    else if is m "POST" ∧ is p "/knowledge/by-subject" then
      runW run (listKnowledge ct (natOr req "subject" 0)) okJson
    else if is m "POST" ∧ is p "/knowledge/evidence" then
      runW run (attachEvidenceV (natOr req "knowledge" 0) (natOr req "event" 0) ct now) idJson
    else if is m "POST" ∧ is p "/knowledge/rebuild-inference" then
      runW run (rebuildInferenceV (natOr req "subject" 0) ct) okUnit
    else if is m "POST" ∧ is p "/subjects/delete" then
      runW run (cascadeDeleteSubjectV (natOr req "id" 0) ct) okUnit
    else if is m "POST" ∧ is p "/subjects/erase" then
      runW run (gdprEraseSubjectV (natOr req "id" 0) ct now) okUnit
    else if is m "POST" ∧ is p "/edges" then
      runW run (addEdgeV (natOr req "from" 0) (natOr req "to" 0) participation nothing 0 now nothing ct now) idJson
    else if is m "POST" ∧ is p "/episodes" then
      runW run (createEpisodeV (natOr req "subject" 0) (natOr req "protocol" 0) (fieldOr req "jtbd" "") ct now) idJson
    else if is m "POST" ∧ is p "/episodes/transition" then
      runW run (transitionEpisodeV (natOr req "episode" 0) (natOr req "to" 0) ct now) idJson
    else if is m "POST" ∧ is p "/protocols" then
      runW run (createProtocolV (fieldOr req "name" "") (natOr req "initial" 0) ct now) idJson
    else if is m "POST" ∧ is p "/protocols/state" then
      runW run (addProtocolStateV (natOr req "protocol" 0) (natOr req "code" 0) (fieldOr req "name" "") ct) idJson
    else if is m "POST" ∧ is p "/protocols/transition" then
      runW run (addProtocolTransitionV (natOr req "protocol" 0) (natOr req "from" 0) (natOr req "to" 0) ct) idJson
    else if is m "POST" ∧ is p "/appointments" then
      runW run (bookAppointmentV (natOr req "subject" 0) (natOr req "resource" 0) nothing nothing
                  (natOr req "start" 0) (natOr req "duration" 60) ct now) idJson
    else if is m "POST" ∧ is p "/appointments/cancel" then
      runW run (cancelAppointmentV (natOr req "id" 0)) okUnit
    else if is m "POST" ∧ is p "/appointments/complete" then
      runW run (completeAppointmentV (natOr req "id" 0)) okUnit
    else if is m "POST" ∧ is p "/appointments/noshow" then
      runW run (noShowAppointmentV (natOr req "id" 0)) okUnit
    else if is m "POST" ∧ is p "/appointments/reopen" then
      runW run (reopenAppointmentV (natOr req "id" 0)) okUnit
    else if is m "POST" ∧ is p "/appointments/by-subject" then
      runW run (listAppointments ct (natOr req "subject" 0)) okJson
    else if is m "POST" ∧ is p "/expectations" then
      runW run (createExpectationV (natOr req "subject" 0) (fieldOr req "topic" "") ExpOurPromise
                  (natOr req "level" 500) ct now) idJson
    else if is m "POST" ∧ is p "/expectations/status" then
      runW run (setExpectationStatusV (natOr req "id" 0) (parseExpSt (fieldOr req "status" "")) ct) okUnit
    else if is m "POST" ∧ is p "/promises" then
      runW run (createPromiseV (natOr req "subject" 0) (fieldOr req "topic" "") (natOr req "deadline" 0) ct now) idJson
    else if is m "POST" ∧ is p "/promises/fulfill" then
      runW run (markPromiseFulfilledV (natOr req "id" 0)) okUnit
    else if is m "POST" ∧ is p "/promises/break" then
      runW run (markPromiseBrokenV (natOr req "id" 0)) okUnit
    else if is m "POST" ∧ is p "/promises/offer" then
      runW run (listPromiseV (natOr req "id" 0) ct now) idJson
    else if is m "POST" ∧ is p "/promises/transfer" then
      runW run (transferPromiseV (natOr req "id" 0) (natOr req "holder" 0) (mFk (natOr req "penalty_to" 0)) ct now) okUnit
    else if is m "POST" ∧ is p "/promises/refer" then
      runW run (referPromiseV (natOr req "id" 0) (natOr req "stake" 0) ct now) okUnit
    else if is m "POST" ∧ is p "/promises/settle" then
      runW run (settlePromiseV (natOr req "id" 0) ct now) okUnit
    else if is m "POST" ∧ is p "/promises/default" then
      runW run (defaultPromiseV (natOr req "id" 0) ct now) okUnit
    else if is m "POST" ∧ is p "/accounts" then
      runW run (openAccountV ct now) idJson
    else if is m "POST" ∧ is p "/credit" then
      runW run (creditV (natOr req "acc" 0) (natOr req "amt" 0)) okUnit
    else if is m "POST" ∧ is p "/offerings" then
      runW run (createOfferingV (natOr req "kind" 0) (natOr req "price" 0) (fieldOr req "currency" "RUB")
                  (fieldOr req "metadata" "") ct now) idJson
    else if is m "POST" ∧ is p "/offerings/delete" then
      runW run (softDeleteOfferingV (natOr req "id" 0) now) okUnit
    else if is m "POST" ∧ is p "/payments/succeed" then
      runW run (markPaymentSucceededV (natOr req "id" 0) now) okUnit
    else if is m "POST" ∧ is p "/integration-tokens" then
      (randomBytesB64 32 >>= λ tok →
       runW run (createIntegrationTokenV tok (fieldOr req "scope" "/v1") (fieldOr req "origin" "") ct now)
         (λ tid → okJson ("{\"id\":" <> show tid <> ",\"token\":" <> str tok <> "}")))
    else if is m "POST" ∧ is p "/integration-tokens/revoke" then
      runW run (revokeIntegrationTokenV (natOr req "id" 0) ct now) okUnit
    else if is m "GET" ∧ is p "/integration-tokens" then
      runW run (listTokens ct) okJson
    else if is m "GET" ∧ is p "/outbox" then
      runW run (listOutbox ct) okJson
    else if is m "POST" ∧ is p "/notifications" then
      -- audit H1: guard + enqueue = ONE atom (no TOCTOU between the check and the write)
      (runW run (ownedTo ct (fieldOr req "to" "") >>=T λ ok →
                 guardT ok Forbidden >>T
                 enqueueNotificationV (fieldOr req "channel" "email") (fieldOr req "to" "")
                   (fieldOr req "subject" "") (fieldOr req "body" "") ct now) idJson
         >>= λ resp → nudgeWorker >> pure resp)
    else pure (errJson 404 "not_found" "no such route")

  isV1 : String → Bool
  isV1 p = pref (toList p)
    where pref : List Char → Bool
          pref ('/' ∷ 'v' ∷ '1' ∷ '/' ∷ _) = true
          pref _ = false

  -- /v1 gate: x-integration-token → live token row → its OWNER tenant (P2a)
  v1Tenant : TxRunner → HttpRequest → IO (Maybe ℕ)
  v1Tenant run req = go (lookupHeader "x-integration-token" (reqHeaders req))
    where
      live : List (ℕ × IntTokenRow) → Maybe ℕ
      live [] = nothing
      live ((_ , r) ∷ _) = maybe′ (λ _ → nothing) (just (itkTenant r)) (itkRevokedAt r)
      go : Maybe String → IO (Maybe ℕ)
      go nothing    = pure nothing
      go (just tok) = runCxmTx run (byCol tcIntToken "token" tok) >>= λ where
        (inj₂ hits) → pure (live hits)
        (inj₁ _)    → pure nothing

  -- reads never CREATE a viewer subject: unknown identity ⇒ 0 (anonymous, public-only)
  resolveViewer : (channel externalId : String) → Tx ℕ
  resolveViewer ch ext =
    if is ext "" then returnT 0
    else byCol tcIdentity "external_id" ext >>=T λ hits → returnT (pick hits)
    where
      pick : List (ℕ × Identity) → ℕ
      pick [] = 0
      pick ((_ , i) ∷ rest) = if is (iChannel i) ch then iSubject i else pick rest

  v1dispatch : TxRunner → (vt now : ℕ) → HttpRequest → IO HttpResponse
  v1dispatch run vt now req =
    let p = reqPath req
        ich = fieldOr req "identity_channel" "cookie"
        iid = fieldOr req "identity_id" ""
    in
    if is p "/v1/events" then
      runW run (ingestSiteEventV ich iid vt now
                  (mkExperienceEvent 0 0 vt Integration Client now View 0
                     nothing nothing nothing nothing false false (fieldOr req "payload" "{}") nothing)) idJson
    else if is p "/v1/publish" then
      runW run (resolveOrCreateSubjectV ich iid "" "UTC" vt now >>=T λ author →
                publishResourceV author (mFk (natOr req "parent" 0)) (mStr (fieldOr req "visibility" ""))
                  (fieldOr req "payload" "{}") (mStr (fieldOr req "listing" "")) vt now) idJson
    else if is p "/v1/follow" then
      runW run (resolveOrCreateSubjectV ich iid "" "UTC" vt now >>=T λ follower →
                resolveOrCreateSubjectV (fieldOr req "target_channel" "user_id") (fieldOr req "target_id" "")
                  "" "UTC" vt now >>=T λ author →
                followSubjectV follower author vt now) idJson
    else if is p "/v1/comment" then
      runW run (resolveOrCreateSubjectV ich iid "" "UTC" vt now >>=T λ author →
                commentOnV author (fieldOr req "anchor_kind" "resource") (natOr req "anchor_id" 0)
                  (mFk (natOr req "parent" 0)) (mStr (fieldOr req "visibility" ""))
                  (mStr (fieldOr req "listing" "")) (fieldOr req "payload" "{}") [] vt now) idJson
    else if is p "/v1/merge-session" then
      runW run (mergeSessionV (natOr req "provisional" 0) ich iid vt now) okUnit
    else if is p "/v1/feed" then
      runW run (resolveViewer ich iid >>=T λ vw → readFeed now vw) okJson
    else if is p "/v1/thread" then
      runW run (resolveViewer ich iid >>=T λ vw → readThread now vw (natOr req "root" 0)) okJson
    else if is p "/v1/showcase" then
      runW run (resolveViewer ich iid >>=T λ vw → readShowcase now vw (natOr req "from" 0)) okJson
    else pure (errJson 404 "not_found" "no such /v1 route")

  route : TxRunner → String → HttpRequest → IO HttpResponse
  route run secret req =
    let m = reqMethod req ; p = reqPath req in
    if is m "GET" ∧ is p "/health" then pure (mkResponse 200 "{\"ok\":true,\"backend\":\"postgres\"}")
    else if is m "POST" ∧ is p "/auth/register" then postRegister run req
    else if is m "POST" ∧ is p "/auth/login" then postLogin run secret req
    else if is m "POST" ∧ is p "/verify-identity" then postVerifyIdentity run secret req
    else if isV1 p then
      (v1Tenant run req >>= λ where
        nothing   → pure (errJson 401 "unauthorized" "invalid integration token")
        (just vt) → getCurrentTime >>= λ now → v1dispatch run vt now req)
    else withTenant run secret req (λ ct now → dispatch run secret ct now req)

------------------------------------------------------------------------
-- Boot: ledger migrations (schema_migrations over cxmHistory) + seed
------------------------------------------------------------------------

private
  member : ℕ → List ℕ → Bool
  member _ [] = false
  member n (x ∷ xs) = (n ≡ᵇ x) ∨ member n xs

  sqlEach : Conn → List String → IO ⊤
  sqlEach c []         = pure tt
  sqlEach c (st ∷ sts) = execConn c st >>= λ _ → sqlEach c sts

  -- audit H2: a step and its ledger row commit ATOMICALLY (PG DDL is transactional) — a crash
  -- mid-step re-runs the WHOLE step next boot instead of wedging on a half-applied one
  applySteps : Conn → ℕ → ℕ → List ℕ → List (List String) → IO ℕ
  applySteps c now i done [] = pure 0
  applySteps c now i done (stmts ∷ rest) =
    (if member i done then pure tt
     else execConn c "BEGIN" >>= λ _ →
          sqlEach c stmts >>
          execConn c ("INSERT INTO \"schema_migrations\" (\"id\",\"applied_at\") VALUES ("
                        <> show i <> ", " <> show now <> ");") >>= λ _ →
          execConn c "COMMIT" >>= λ _ → pure tt) >>
    applySteps c now (1 + i) done rest >>= λ n →
    pure (if member i done then n else 1 + n)

  bootMigrations : String → ℕ → IO ⊤
  bootMigrations conninfo now = withConnRaw conninfo λ c →
    execConn c "CREATE TABLE IF NOT EXISTS \"schema_migrations\" (\"id\" BIGINT NOT NULL PRIMARY KEY, \"applied_at\" BIGINT NOT NULL);" >>= λ _ →
    queryConn c "SELECT \"id\" FROM \"schema_migrations\" ORDER BY \"id\"" >>= λ j →
    applySteps c now 1 (maybe′ (λ x → x) [] (decodeIds j)) (map up cxmHistory) >>= λ n →
    putStrLn ("pg-boot: migrations applied: " <> show n)

------------------------------------------------------------------------
-- PG worker: outbox delivery (log-stub transport — real transports next wave) + reminders + bus
------------------------------------------------------------------------

private
  -- webhook signature (mirror of Cxm.Api.webhookSignature): HMAC over topic.body
  webhookSig : String → String → String → String
  webhookSig secret topic body = hmacSHA256 secret (webhookPayload topic body)

  ok2xx : ℕ → Bool
  ok2xx st = (st ≡ᵇ 200) ∨ (st ≡ᵇ 201) ∨ (st ≡ᵇ 202) ∨ (st ≡ᵇ 204)

  mailMessage : (from to subj body : String) → String
  mailMessage from to subj body =
    "From: " <> from <> "\r\nTo: " <> to <> "\r\nSubject: " <> subj
    <> "\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n" <> body

  -- the delivery ADAPTER (ported verbatim from the WAL server): webhook = signed POST;
  -- email = pipe RFC822 into CXM_SENDMAIL ("" = log-stub); other = considered delivered.
  deliverVia : HttpClientManager → (webhookSecret sendmailCmd mailFrom : String) → ℕ
             → OutboxEntry → IO Bool
  deliverVia mgr secret sendmail mailFrom now o =
    if eqStrCI (obChannel o) "webhook" then
      (let ts = show now ; sig = webhookSig secret (obSubject o) (ts <> obBody o)
       in httpPostStatus mgr (obTo o) (obBody o)
            (mkStrPair "X-Cxm-Topic" (obSubject o)
            ∷ mkStrPair "X-Cxm-Timestamp" ts
            ∷ mkStrPair "X-Cxm-Signature" sig ∷ []) >>= λ st → pure (ok2xx st))
    else if eqStrCI (obChannel o) "email" then
      (if null (toList sendmail)
       then putStrLn ("email (stub) → " <> obTo o <> ": " <> obSubject o) >> pure true
       else if null (toList (obTo o))
       then putStrLn ("email DROP (empty recipient): " <> obSubject o) >> pure false
       else runPipe sendmail (mailMessage mailFrom (obTo o) (obSubject o) (obBody o)) >>= λ ok →
            putStrLn ("email → " <> obTo o <> (if ok then " sent" else " FAILED")) >> pure ok)
    else pure true

  deliverOne : HttpClientManager → String → String → String → TxRunner → ℕ → ℕ → ℕ → IO ⊤
  deliverOne mgr secret sendmail mailFrom run now maxAtt oid =
    runCxmTx run (get tcOutbox oid) >>= λ where
      (inj₂ (just o)) → deliverVia mgr secret sendmail mailFrom now o >>= λ ok →
        (if ok then runCxmTx run (markSentV oid)
               else runCxmTx run (markAttemptV oid now maxAtt)) >>= λ _ → pure tt
      _ → pure tt

  deliverAll : HttpClientManager → String → String → String → TxRunner → ℕ → ℕ → List ℕ → IO ⊤
  deliverAll mgr sec sm mf run now maxAtt []       = pure tt
  deliverAll mgr sec sm mf run now maxAtt (i ∷ is) =
    deliverOne mgr sec sm mf run now maxAtt i >> deliverAll mgr sec sm mf run now maxAtt is

  workerTick : HttpClientManager → String → String → String → TxRunner → ℕ → ℕ → IO ⊤
  workerTick mgr sec sm mf run leadH maxAtt = getCurrentTime >>= λ now →
    runCxmTx run (remindDueAppointmentsV now (leadH * 3600)) >>= λ _ →
    runCxmTx run dispatchBusV >>= λ _ →
    runCxmTx run (dueOutboxV now) >>= λ where
      (inj₂ ids) → deliverAll mgr sec sm mf run now maxAtt ids >>
        (if null ids then pure tt else putStrLn ("pg-worker delivered: " <> show (length ids)))
      (inj₁ _)   → pure tt

------------------------------------------------------------------------
-- main
------------------------------------------------------------------------

private
  envNat : String → ℕ → IO ℕ
  envNat key d = getEnvOr key (show d) >>= λ s → pure (maybe′ (λ n → n) d (readMaybe 10 s))

{-# NON_TERMINATING #-}
main : IO ⊤
main =
  getEnvOr "CXM_PG" "host=127.0.0.1 dbname=agdelte user=n" >>= λ conninfo →
  getEnvOr "CXM_JWT_SECRET" "dev-secret-change-me" >>= λ secret →
  getEnvOr "CXM_DEV" "" >>= λ dev →
  getEnvOr "CXM_SOCKET" "" >>= λ sockPath →
  getEnvOr "PSYCH_ADMIN_LOGIN" "" >>= λ adminLogin →
  getEnvOr "PSYCH_ADMIN_PASSWORD" "" >>= λ adminPass →
  envNat "CXM_WORKER_SEC" 30 >>= λ workerSec →
  envNat "CXM_MAX_ATTEMPTS" 8 >>= λ maxAtt →
  envNat "CXM_REMIND_LEAD_H" 24 >>= λ leadH →
  getEnvOr "CXM_SENDMAIL" "" >>= λ sendmail →
  getEnvOr "CXM_MAIL_FROM" "noreply" >>= λ mailFrom →
  getEnvOr "CXM_WEBHOOK_SECRET" "" >>= λ whSecret →
  newHttpClientManager >>= λ mgr →
  setLineBuffering >>
  let run = connectPerTxn conninfo
      devMode    = primStringEquality dev "1" ∨ primStringEquality dev "true"
      weakSecret = primStringEquality secret "dev-secret-change-me" ∨ null (toList secret)
  in if weakSecret ∧ not devMode
     then putStrLn "FATAL: refusing to start — set a strong CXM_JWT_SECRET (or CXM_DEV=1 for local dev)."
     else
       (getCurrentTime >>= λ now →
        bootMigrations conninfo now >>
        runCxmTx run (seedTenantsV (mkTenant defaultTenant "default" now ∷ [])) >>= λ _ →
        (if null (toList adminLogin) then pure tt
         else hashPassword adminPass >>= λ ph →
              runCxmTx run (ensureAdminV adminLogin ph "" defaultTenant now) >>= λ _ → pure tt) >>
        (if workerSec ≡ᵇ 0 then putStrLn "(pg-worker off)"
         else forkLoopNudged workerSec (workerTick mgr whSecret sendmail mailFrom run leadH maxAtt)) >>
        putStrLn "CXM headless on POSTGRES (wave-1 surface) + pg-worker" >>
        (if null (toList sockPath)
         then listenHost "127.0.0.1" 8138 (route run secret)
         else listenUnix sockPath (route run secret)))