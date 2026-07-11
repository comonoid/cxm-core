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
-- Waves 2+ (все смонтированы): RBAC-authz, /v1 site surface, social, медиа; вертикали — Ext-хуком.
-- Рекомпозиция-2 р1 (2026-07-11): БЫВШИЙ CxmServerPg расколот — это НЕЙТРАЛЬНАЯ
-- route-библиотека (health/auth/кабинет/v1/медиа + бут/воркер/listen); вертикальный
-- composition-root (Main) живёт в репо вертикали и монтирует свой пак Ext-хуком
-- (serverMain). Вертикаль здесь не называется.
module CxmServerLib where

open import Agda.Builtin.IO using (IO)
open import Agda.Builtin.Unit using (⊤; tt)
open import Agda.Builtin.String using (String; primStringEquality)
open import Data.Bool using (Bool; true; false; if_then_else_; _∧_; _∨_; not)
open import Data.Char using (Char)
open import Agda.Builtin.Char using (primCharToNat)
open import Data.List using (List; []; _∷_; map; length; concat; null; foldr; reverse)
open import Data.Maybe using (Maybe; just; nothing; maybe′)
open import Data.Nat using (ℕ; suc; _+_; _*_; _≡ᵇ_; _≤ᵇ_)
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
open import Agdelte.Auth.SignedUrl using (signUrl)
open import Agdelte.Auth.RBAC using (Policy; Perm; Role; role; parsePerm; can)
open import Agdelte.Storage.PgConn using (TxRunner; connectPerTxn; withConnRaw; execConn; queryConn; Conn)
open import Agdelte.Storage.JsonRow using (decodeIds)
open import Agdelte.Storage.Migration using (up)

open import Cxm.Tenant using (Tenant; mkTenant; defaultTenant)
open import Cxm.Subject using (Subject; sId; sDisplayName; sDeletedAt; EXTERNAL; Person)
open import Cxm.Identity using (Identity; iTenant; iVerified; iChannel; iSubject)
open import Cxm.Edge using (participation)
open import Cxm.Expectation using
  ( ExpStatus; ExpMet; ExpUnmet; ExpUnknown; ExpSource; ExpOurPromise; ExpCompetitor; ExpIndustryNorm
  ; Expectation; xpId; xpSubject; xpTenant; xpTopic; xpSource; xpLevel; xpStatus; xpCreatedAt )
open import Cxm.Episode using
  ( Episode; epId; epSubject; epProtocol; epTenant; epCurrentState; epJtbd; epDeletedAt )
open import Cxm.Appointment using (Appointment; apTenant; apStartsAt; apDurationMin; apStatus; ApptStatus; ApScheduled; ApCanceled; ApCompleted; ApNoShow)
open import Cxm.Site using (IntTokenRow; itkTenant; itkScope; itkRevokedAt; webhookPayload)
open import Cxm.Event using (mkExperienceEvent; Integration; Client; View; eeTimestamp; eePayload)
open import Cxm.Edge using (SubjectEdge)
open import Cxm.Entitlement using (Entitlement)
open import Cxm.Resource using (Resource; rId; rPayload; rAuthor; rCreatedAt; rDeletedAt; ResourceLink; Mention; mSubject; mResource)
open import Cxm.Social using (feedViews; threadViews; showcaseViews; ContentView; mkContentView; cvLocked; cvResource; canList; canAccess; ThreadView; tvDepth; tvLocked; tvResource)
open import Cxm.Knowledge using
  ( Knowledge; kDetail; kTenant; kId; kSubject; kType; kSource; kConfidence
  ; kValidFrom; kValidTo; kDecay; kStatus; kEpisode
  ; EpistemicType; FACT; HYPOTHESIS; STATE; TRAIT
  ; Source; OBSERVED; INFERRED; STATED; IMPORTED
  ; KStatus; ACTIVE; CONFIRMED; REFUTED; SUPERSEDED
  ; KRevision; KStrengthen; KWeaken; KConfirm; KRefute; KSupersede; KRedetail )
open import Cxm.Offering using (Offering; oId; oKind; oPrice; oCurrency; oMetadata; oTenant; oDeletedAt)
open import Cxm.Collections using (Evidence; evdId; evdKnowledge; evdEvent; evdTenant; evdCreatedAt)
open import Cxm.Users using (User; uTenant; uPassHash; RoleAssignment; raSubject; raRoleId)
open import Cxm.Bus using (OutboxEntry; obTo; obSubject; obBody; obChannel; obAttempts; obTenant; obStatus; OutStatus; OutPending; OutSent; OutFailed)
open import Cxm.Store.Base using
  ( Err; NotFound; Conflict; Insufficient; InvalidTransition; Forbidden; Invariant
  ; subjByTenant; knowBySubject; apptBySubject; intTokenByTenant; epBySubject; expBySubject
  ; evdByKnowledge )
open import Cxm.Store.Verbs
open import Cxm.Store.Pg using (runCxmTx)
open import Cxm.Store.Registry using (cxmHistory)
open import Cxm.CommandsV

------------------------------------------------------------------------
-- Ext-шов (р1): расширение вертикали. Composition-root отдаёт хук; nothing = не его путь,
-- запрос идёт дальше по нейтральной цепочке (v1 → кабинет).
------------------------------------------------------------------------

Ext : Set
Ext = HttpRequest → IO (Maybe HttpResponse)

noExt : Ext
noExt _ = pure nothing

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

  -- версия wire-контракта (аудит-5 №4): инкрементировать при ЛЮБОМ изменении формы
  -- энкодеров/роутов; cxm-ui сверяет со своей ожидаемой (Contract.expectedContract) через /health.
  contractVersion : ℕ
  contractVersion = 1

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

  -- parse a knowledge revision from the request (Ф2.3): kind + optional amount/detail
  parseRev : HttpRequest → KRevision
  parseRev req =
    let k = fieldOr req "kind" "" in
    if is k "confirm"    then KConfirm
    else if is k "refute"    then KRefute
    else if is k "supersede" then KSupersede
    else if is k "strengthen" then KStrengthen (natOr req "amount" 0)
    else if is k "weaken"     then KWeaken (natOr req "amount" 0)
    else KRedetail (fieldOr req "detail" "")   -- "redetail" (and unknown kinds) rewrite kDetail

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

  -- Ф0.4.2: episodes by subject (client card). EpisodeView = id/subject/protocol/state/jtbd; skip soft-deleted.
  listEpisodes : (ct sid : ℕ) → Tx String
  listEpisodes ct sid =
    byIx tcEpisode epBySubject sid >>=T λ ids →
    getEach tcEpisode ids >>=T λ es →
    returnT ("[" <> joinComma (map enc (mine es)) <> "]")
    where
      mine : List Episode → List Episode
      mine = foldr (λ e acc → if (epTenant e ≡ᵇ ct) ∧ maybe′ (λ _ → false) true (epDeletedAt e)
                              then e ∷ acc else acc) []
      enc : Episode → String
      enc e = "{\"id\":" <> show (epId e) <> ",\"subject\":" <> show (epSubject e)
              <> ",\"protocol\":" <> show (epProtocol e) <> ",\"state\":" <> show (epCurrentState e)
              <> ",\"jtbd\":" <> str (epJtbd e) <> "}"

  -- Ф0.4.3: expectations by subject (expectation-gap). id/subject/topic/source/level/status/createdAt.
  expSrcStr : ExpSource → String
  expSrcStr ExpOurPromise = "our_promise" ; expSrcStr ExpCompetitor = "competitor"
  expSrcStr ExpIndustryNorm = "industry_norm"
  expStatStr : ExpStatus → String
  expStatStr ExpMet = "met" ; expStatStr ExpUnmet = "unmet" ; expStatStr ExpUnknown = "unknown"
  listExpectations : (ct sid : ℕ) → Tx String
  listExpectations ct sid =
    byIx tcExpectation expBySubject sid >>=T λ ids →
    getEach tcExpectation ids >>=T λ xs →
    returnT ("[" <> joinComma (map enc (mine xs)) <> "]")
    where
      mine : List Expectation → List Expectation
      mine = foldr (λ x acc → if xpTenant x ≡ᵇ ct then x ∷ acc else acc) []
      enc : Expectation → String
      enc x = "{\"id\":" <> show (xpId x) <> ",\"subject\":" <> show (xpSubject x)
              <> ",\"topic\":" <> str (xpTopic x) <> ",\"source\":" <> str (expSrcStr (xpSource x))
              <> ",\"level\":" <> show (xpLevel x) <> ",\"status\":" <> str (expStatStr (xpStatus x))
              <> ",\"createdAt\":" <> show (xpCreatedAt x) <> "}"

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

  -- cxm-ui аудит №8: the explainability read — the evidence chain behind ONE knowledge unit
  -- (why the system believes it). Each row is JOINED with its event (timestamp + opaque payload):
  -- a bare event id is a pointer, not an explanation (аудит-2 №4). Mirrors cxm-ui evidenceDec.
  listEvidence : (ct kid : ℕ) → Tx String
  listEvidence ct kid =
    byIx tcEvidence evdByKnowledge kid >>=T λ ids →
    getEach tcEvidence ids >>=T λ es →
    encAll (mine es) >>=T λ rows →
    returnT ("[" <> joinComma rows <> "]")
    where
      mine : List Evidence → List Evidence
      mine = foldr (λ e acc → if evdTenant e ≡ᵇ ct then e ∷ acc else acc) []
      enc1 : Evidence → Tx String
      enc1 e = get tcEvent (evdEvent e) >>=T λ mev →
        returnT ("{\"id\":" <> show (evdId e) <> ",\"knowledge\":" <> show (evdKnowledge e)
                <> ",\"event\":" <> show (evdEvent e) <> ",\"createdAt\":" <> show (evdCreatedAt e)
                <> ",\"eventAt\":" <> show (maybe′ eeTimestamp 0 mev)
                <> ",\"eventPayload\":" <> str (maybe′ eePayload "" mev) <> "}")
      encAll : List Evidence → Tx (List String)
      encAll [] = returnT []
      encAll (e ∷ es′) = enc1 e >>=T λ r → encAll es′ >>=T λ rs → returnT (r ∷ rs)

  -- cxm-ui аудит №12: optional page cap for the community readers (0 = всё). They are
  -- newest-first/rank-ordered, so `limit n` = "the top n" — the compatible pagination seed.
  takeN : ∀ {A : Set} → ℕ → List A → List A
  takeN 0 _ = []
  takeN _ [] = []
  takeN (suc n) (x ∷ xs) = x ∷ takeN n xs

  capL : ∀ {A : Set} → ℕ → List A → List A
  capL 0 xs = xs
  capL n xs = takeN n xs

  -- cxm-ui Ф3.4: the viewer-facing offering list (paywall buy buttons). Live offerings of the
  -- token's tenant; metadata is the server-side fulfilment plan — exposed so the site can match
  -- an offering to the node it unlocks (grants are data, not a secret: possession grants nothing).
  listOfferingsV1 : (vt : ℕ) → Tx String
  listOfferingsV1 vt =
    scan tcOffering >>=T λ os →
    returnT ("[" <> joinComma (map enc (mine (map proj₂ os))) <> "]")
    where
      liveO : Offering → Bool
      liveO o = maybe′ (λ _ → false) true (oDeletedAt o)
      mine : List Offering → List Offering
      mine = foldr (λ o acc → if (oTenant o ≡ᵇ vt) ∧ liveO o then o ∷ acc else acc) []
      enc : Offering → String
      enc o = "{\"id\":" <> show (oId o) <> ",\"kind\":" <> show (oKind o)
              <> ",\"price\":" <> show (oPrice o) <> ",\"currency\":" <> str (oCurrency o)
              <> ",\"metadata\":" <> str (oMetadata o) <> "}"

  -- social reads (bucket D): scan the three graph tables, run the pure Social view function.
  -- fetch+fold now; the hot ones become query-EDSL terms later. viewer 0 = anonymous.
  vals : (t : TableCode) → Tx (List (Val t))
  vals t = scan t >>=T λ xs → returnT (map proj₂ xs)

  -- cxm-ui Ф1.3: feed/showcase rows carry author (0 = none) + createdAt — a feed item without
  -- author/time is unrenderable. Payload stays stripped when locked (teaser = chrome only).
  -- аудит-4 №2: rows are JOINED with the author's display name ("" = none/erased) — «автор #19»
  -- в ленте нежизнеспособен, а другого пути отрезолвить имя у сайта нет.
  nameLookup : List (ℕ × Subject) → ℕ → String
  nameLookup [] _ = ""
  nameLookup ((i , s) ∷ rest) a = if i ≡ᵇ a then sDisplayName s else nameLookup rest a

  cvEnc : (ℕ → String) → ContentView → String
  cvEnc nameOf cv = "{\"id\":" <> show (rId (cvResource cv))
             <> ",\"author\":" <> show (maybe′ (λ a → a) 0 (rAuthor (cvResource cv)))
             <> ",\"authorName\":" <> str (maybe′ nameOf "" (rAuthor (cvResource cv)))
             <> ",\"createdAt\":" <> show (rCreatedAt (cvResource cv))
             <> ",\"locked\":" <> (if cvLocked cv then "true" else "false")
             <> ",\"payload\":" <> str (if cvLocked cv then "" else rPayload (cvResource cv)) <> "}"

  readFeed : (now viewer lim : ℕ) → Tx String
  readFeed now viewer lim =
    vals tcEdge >>=T λ es → vals tcEntitlement >>=T λ ens → vals tcResource >>=T λ rs →
    scan tcSubject >>=T λ subs →
    returnT ("[" <> joinComma (map (cvEnc (nameLookup subs)) (capL lim (feedViews now viewer es ens rs))) <> "]")

  -- Ф4.1 (site-plan): mentions inbox — «все ответы мне»: узлы, где viewer в addressees
  -- (child-таблица Mention, §8.1). Feed-shaped строки (cvEnc): live + canList (listing-
  -- политика S7), locked = ¬canAccess, newest-first. Аноним (0) — пусто по построению.
  readMentions : (now viewer lim : ℕ) → Tx String
  readMentions now 0 _ = returnT "[]"
  readMentions now viewer lim =
    vals tcMention >>=T λ ms → vals tcEdge >>=T λ es → vals tcEntitlement >>=T λ ens →
    vals tcResource >>=T λ rs → scan tcSubject >>=T λ subs →
    returnT ("[" <> joinComma (map (cvEnc (nameLookup subs))
                                   (capL lim (mentionViews ms es ens rs))) <> "]")
    where
      mine : List Mention → ℕ → Bool
      mine [] _ = false
      mine (mn ∷ rest) rid =
        if (mSubject mn ≡ᵇ viewer) ∧ (mResource mn ≡ᵇ rid) then true else mine rest rid
      mentionViews : List Mention → List SubjectEdge → List Entitlement
                   → List Resource → List ContentView
      mentionViews ms es ens rsAll = foldr step [] rsAll
        where
          liveRᵇ : Resource → Bool
          liveRᵇ r = maybe′ (λ _ → false) true (rDeletedAt r)
          wanted : Resource → Bool
          wanted r = liveRᵇ r ∧ mine ms (rId r) ∧ canList now (just viewer) es ens rsAll r
          view : Resource → ContentView
          view r = mkContentView (not (canAccess now (just viewer) es ens rsAll r)) r
          insDesc : ContentView → List ContentView → List ContentView
          insDesc x [] = x ∷ []
          insDesc x (y ∷ ys) = if rCreatedAt (cvResource y) ≤ᵇ rCreatedAt (cvResource x)
                               then x ∷ y ∷ ys else y ∷ insDesc x ys
          step : Resource → List ContentView → List ContentView
          step r acc = if wanted r then insDesc (view r) acc else acc

  readShowcase : (now viewer from lim : ℕ) → Tx String
  readShowcase now viewer from lim =
    vals tcEdge >>=T λ es → vals tcEntitlement >>=T λ ens →
    vals tcResourceLink >>=T λ ls → vals tcResource >>=T λ rs →
    scan tcSubject >>=T λ subs →
    returnT ("[" <> joinComma (map (cvEnc (nameLookup subs))
                                   (capL lim (showcaseViews now (mV viewer) es ens ls from rs))) <> "]")
    where mV : ℕ → Maybe ℕ
          mV 0 = nothing
          mV n = just n

  tvEnc : (ℕ → String) → ThreadView → String
  tvEnc nameOf tv = "{\"depth\":" <> show (tvDepth tv) <> ",\"id\":" <> show (rId (tvResource tv))
             <> ",\"author\":" <> show (maybe′ (λ a → a) 0 (rAuthor (tvResource tv)))
             <> ",\"authorName\":" <> str (maybe′ nameOf "" (rAuthor (tvResource tv)))
             <> ",\"createdAt\":" <> show (rCreatedAt (tvResource tv))
             <> ",\"locked\":" <> (if tvLocked tv then "true" else "false")
             <> ",\"payload\":" <> str (if tvLocked tv then "" else rPayload (tvResource tv)) <> "}"

  readThread : (now viewer root lim : ℕ) → Tx String
  readThread now viewer root lim =
    vals tcEdge >>=T λ es → vals tcEntitlement >>=T λ ens → vals tcResource >>=T λ rs →
    scan tcSubject >>=T λ subs →
    returnT ("[" <> joinComma (map (tvEnc (nameLookup subs))
                                   (capL lim (threadViews now (mV viewer) es ens root rs))) <> "]")
    where mV : ℕ → Maybe ℕ
          mV 0 = nothing
          mV n = just n

  parseExpSt : String → ExpStatus
  parseExpSt s = if is s "met" then ExpMet else if is s "unmet" then ExpUnmet else ExpUnknown

  mFk : ℕ → Maybe ℕ
  mFk 0 = nothing
  mFk n = just n

  -- addressees на проводе — ПЛОСКИЙ массив "[1,2]" (CxmUI.Client.showIds). Найдено Ф4-смоуком
  -- (2026-07-10): раньше тут стоял Storage.decodeIds, который парсит [{"id":N}]-строки —
  -- писатель и читатель расходились, mentions не создавались никогда. Толерантный числовой
  -- сканер в духе Cxm.Fulfilment: не-цифры — разделители, мусор игнорируется.
  parseNats : String → List ℕ
  parseNats s = reverse (go (toList s) [] [])
    where
      isDigitᶜ : Char → Bool
      isDigitᶜ c = let n = primCharToNat c in ((48 ≤ᵇ n) ∧ (n ≤ᵇ 57))
      flushN : List Char → List ℕ → List ℕ            -- cur — реверснутые цифры числа
      flushN [] acc = acc
      flushN cur acc = maybe′ (λ n → n ∷ acc) acc (readMaybe 10 (fromList (reverse cur)))
      go : List Char → List Char → List ℕ → List ℕ    -- acc реверснут (внешний reverse)
      go [] cur acc = flushN cur acc
      go (c ∷ cs) cur acc =
        if isDigitᶜ c then go cs (c ∷ cur) acc else go cs [] (flushN cur acc)

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
    else if is m "POST" ∧ is p "/knowledge/evidence/by-knowledge" then
      runW run (listEvidence ct (natOr req "knowledge" 0)) okJson
    else if is m "POST" ∧ is p "/knowledge/rebuild-inference" then
      runW run (rebuildInferenceV (natOr req "subject" 0) ct) okUnit
    else if is m "POST" ∧ is p "/knowledge/revise" then
      runW run (updateKnowledgeV (natOr req "knowledge" 0) (parseRev req) ct) okUnit
    else if is m "POST" ∧ is p "/subjects/delete" then
      runW run (cascadeDeleteSubjectV (natOr req "id" 0) ct) okUnit
    else if is m "POST" ∧ is p "/subjects/erase" then
      runW run (gdprEraseSubjectV (natOr req "id" 0) ct now) okUnit
    else if is m "POST" ∧ is p "/edges" then
      runW run (addEdgeV (natOr req "from" 0) (natOr req "to" 0) participation nothing 0 now nothing ct now) idJson
    -- cxm-ui Ф3.3: curate the showcase — link `to` under showcase node `from` with a rank and an
    -- optional validTo window (0 = open-ended). linkResourceV existed but had no HTTP surface.
    else if is m "POST" ∧ is p "/resources/link" then
      runW run (linkResourceV (natOr req "from" 0) (natOr req "to" 0) (fieldOr req "kind" "showcase")
                  (natOr req "rank" 0) (mFk (natOr req "validTo" 0)) ct now) idJson
    else if is m "POST" ∧ is p "/resources/unlink" then
      runW run (unlinkResourceV (natOr req "link" 0)) okUnit
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
    else if is m "POST" ∧ is p "/episodes/by-subject" then
      runW run (listEpisodes ct (natOr req "subject" 0)) okJson
    else if is m "POST" ∧ is p "/expectations/by-subject" then
      runW run (listExpectations ct (natOr req "subject" 0)) okJson
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

  -- П4c: типы медиа, которые вообще принимаем (лимит размера — на media-host)
  mimeOk : String → Bool
  mimeOk s = go (toList s)
    where
      go : List Char → Bool
      go ('v' ∷ 'i' ∷ 'd' ∷ 'e' ∷ 'o' ∷ '/' ∷ _) = true
      go ('a' ∷ 'u' ∷ 'd' ∷ 'i' ∷ 'o' ∷ '/' ∷ _) = true
      go ('i' ∷ 'm' ∷ 'a' ∷ 'g' ∷ 'e' ∷ '/' ∷ _) = true
      go _ = false

  v1dispatch : TxRunner → (vt now : ℕ) → (msec : String) (mttl : ℕ) → HttpRequest → IO HttpResponse
  v1dispatch run vt now msec mttl req =
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
      -- addressees (упоминания, аудит-5 №3): строка-JSON "[1,2]" (jsonGetField берёт только
      -- string-поля — в духе payload/metadata), parseNats парсит "[1,2]" (формат
      -- CxmUI.Client.showIds; НЕ Storage.decodeIds — тот про [{"id":N}]-строки, Ф4-фикс);
      -- отсутствие/мусор = []
      runW run (resolveOrCreateSubjectV ich iid "" "UTC" vt now >>=T λ author →
                commentOnV author (fieldOr req "anchor_kind" "resource") (natOr req "anchor_id" 0)
                  (mFk (natOr req "parent" 0)) (mStr (fieldOr req "visibility" ""))
                  (mStr (fieldOr req "listing" "")) (fieldOr req "payload" "{}")
                  (maybe′ parseNats [] (jsonGetField "addressees" (reqBody req))) vt now) idJson
    else if is p "/v1/merge-session" then
      -- Ф3.2-шов (site-plan): сайт числовых id субъектов НЕ знает — provisional задаётся и
      -- identity-ПАРОЙ (provisional_channel/provisional_id; дефолт канала "cookie"), резолв
      -- серверный; вызывающий сайт обязан звать merge ПОСЛЕ своего /auth/login (login
      -- доказывает контроль login-identity — trust-модель /v1). Уже слитая пара (prov ≡
      -- канон login-identity) — идемпотентный no-op: mergeV prov prov зациклил бы
      -- sCanonical на себя.
      runW run ((let pn = natOr req "provisional" 0 in
                 if pn ≡ᵇ 0
                 then resolveViewer (fieldOr req "provisional_channel" "cookie")
                                    (fieldOr req "provisional_id" "")
                 else returnT pn) >>=T λ prov →
                resolveViewer ich iid >>=T λ canon0 →
                (if not (prov ≡ᵇ 0) ∧ (prov ≡ᵇ canon0)
                 then returnT tt
                 else mergeSessionV prov ich iid vt now)) okUnit
    -- cxm-ui Ф3.4 (paywall): viewer-facing offering list + purchase start. Payment success stays
    -- webhook-authoritative (/payments/succeed, admin) — /v1/purchase only records a PENDING
    -- payment for the resolved viewer at the SERVER-side price (client sends no amount).
    else if is p "/v1/offerings" then
      runW run (listOfferingsV1 vt) okJson
    else if is p "/v1/purchase" then
      runW run (require tcOffering (natOr req "offering" 0) NotFound >>=T λ o →
                guardT ((oTenant o ≡ᵇ vt) ∧ maybe′ (λ _ → false) true (oDeletedAt o)) NotFound >>T
                resolveOrCreateSubjectV ich iid "" "UTC" vt now >>=T λ buyer →
                recordPaymentV (fieldOr req "ext_id" "") (oId o) buyer (oPrice o)
                  (fieldOr req "name" "") (fieldOr req "email" "") vt now) idJson
    else if is p "/v1/feed" then
      runW run (resolveViewer ich iid >>=T λ vw → readFeed now vw (natOr req "limit" 0)) okJson
    else if is p "/v1/mentions" then
      runW run (resolveViewer ich iid >>=T λ vw → readMentions now vw (natOr req "limit" 0)) okJson
    -- П4c: медиа. Ресурс = ОБЫЧНЫЙ Resource (payload — метаданные, listing=private: не светится
    -- в лентах; visibility гейтит выдачу src). Байты живут на media-host (dev: serve.mjs /
    -- прод: nginx secure-link) — сервер только подписывает URL (SignedUrl: HMAC url|expires).
    else if is p "/v1/media" then
      (let mime = fieldOr req "mime" "" in
       if not (mimeOk mime) then pure (errJson 400 "validation" "unsupported mime")
       else runW run
         (resolveOrCreateSubjectV ich iid "" "UTC" vt now >>=T λ author →
          publishResourceV author nothing (mStr (fieldOr req "visibility" "entitled"))
            ("{\"kind\":\"media\",\"mime\":\"" <> escapeJsonString mime <> "\"}")
            (just "private") vt now)
         (λ rid → okJson ("{\"id\":" <> show rid <> ",\"uploadUrl\":"
                  <> str (signUrl msec ("/media-store/" <> show rid <> "/up") (now + 3600))
                  <> "}")))
    -- выдача src: S7 canAccess (автор / купил / публичное) → подписанный URL с истечением;
    -- не-entitled — 403 (тизер — забота рендера)
    else if is p "/v1/media-src" then
      runW run
        (resolveViewer ich iid >>=T λ vw →
         require tcResource (natOr req "id" 0) NotFound >>=T λ r →
         guardT (maybe′ (λ _ → false) true (rDeletedAt r)) NotFound >>T
         vals tcEdge >>=T λ es → vals tcEntitlement >>=T λ ens → vals tcResource >>=T λ rs →
         guardT (canAccess now (mFk vw) es ens rs r) Forbidden >>T
         returnT (natOr req "id" 0))
        (λ rid → okJson ("{\"url\":"
                 <> str (signUrl msec ("/media-store/" <> show rid) (now + mttl)) <> "}"))
    else if is p "/v1/thread" then
      runW run (resolveViewer ich iid >>=T λ vw →
                readThread now vw (natOr req "root" 0) (natOr req "limit" 0)) okJson
    else if is p "/v1/showcase" then
      runW run (resolveViewer ich iid >>=T λ vw →
                readShowcase now vw (natOr req "from" 0) (natOr req "limit" 0)) okJson
    else pure (errJson 404 "not_found" "no such /v1 route")

  route : TxRunner → String → Ext → (msec : String) (mttl : ℕ)
        → HttpRequest → IO HttpResponse
  route run secret ext msec mttl req =
    let m = reqMethod req ; p = reqPath req in
    if is m "GET" ∧ is p "/health" then
      pure (mkResponse 200 ("{\"ok\":true,\"backend\":\"postgres\",\"contract\":" <> show contractVersion <> "}"))
    else if is m "POST" ∧ is p "/auth/register" then postRegister run req
    else if is m "POST" ∧ is p "/auth/login" then postLogin run secret req
    else if is m "POST" ∧ is p "/verify-identity" then postVerifyIdentity run secret req
    else (ext req >>= λ where       -- р1: поверхность вертикали (ПУБЛИЧНАЯ, до Bearer-зоны)
      (just r) → pure r
      nothing →
        if isV1 p then
          (v1Tenant run req >>= λ where
            nothing   → pure (errJson 401 "unauthorized" "invalid integration token")
            (just vt) → getCurrentTime >>= λ now → v1dispatch run vt now msec mttl req)
        else withTenant run secret req (λ ct now → dispatch run secret ct now req))

------------------------------------------------------------------------
-- Публичные помощники composition-root'ов (р1): Tx→HTTP, tenant владельца, конверт ошибок
------------------------------------------------------------------------

runExtTx : TxRunner → Tx HttpResponse → IO HttpResponse
runExtTx run tx = runW run tx (λ r → r)

extErrJson : ℕ → String → String → HttpResponse
extErrJson = errJson

-- tenant владельца-оператора инстанса по логину (регистрация даёт каждому юзеру СВОЙ
-- tenant — defaultTenant годится только для admin-owner'а). Пер-запросный резолв:
-- корректно, даже если владелец зарегистрировался после старта.
tenantOfLogin : TxRunner → String → IO ℕ
tenantOfLogin run lg =
  if primStringEquality lg "" then pure defaultTenant
  else runCxmTx run (findUserByLoginV lg) >>= λ where
    (inj₂ (just u)) → pure (uTenant u)
    _               → pure defaultTenant

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

-- р1: НЕЙТРАЛЬНЫЙ вход. Composition-root вертикали зовёт serverMain со своим
-- Ext-инициализатором (тот получает TxRunner, читает СВОИ env, отдаёт хук).
-- Админ-логин: CXM_ADMIN_LOGIN/PASSWORD (легаси-имена PSYCH_ADMIN_* принимаются фолбэком).
{-# NON_TERMINATING #-}
serverMain : (TxRunner → IO Ext) → IO ⊤
serverMain mkExt =
  getEnvOr "CXM_PG" "host=127.0.0.1 dbname=agdelte user=n" >>= λ conninfo →
  getEnvOr "CXM_JWT_SECRET" "dev-secret-change-me" >>= λ secret →
  getEnvOr "CXM_DEV" "" >>= λ dev →
  getEnvOr "CXM_SOCKET" "" >>= λ sockPath →
  getEnvOr "PSYCH_ADMIN_LOGIN" "" >>= λ adminLegacy →
  getEnvOr "CXM_ADMIN_LOGIN" adminLegacy >>= λ adminLogin →
  getEnvOr "PSYCH_ADMIN_PASSWORD" "" >>= λ adminPassLegacy →
  getEnvOr "CXM_ADMIN_PASSWORD" adminPassLegacy >>= λ adminPass →
  envNat "CXM_WORKER_SEC" 30 >>= λ workerSec →
  envNat "CXM_MAX_ATTEMPTS" 8 >>= λ maxAtt →
  envNat "CXM_REMIND_LEAD_H" 24 >>= λ leadH →
  getEnvOr "CXM_SENDMAIL" "" >>= λ sendmail →
  getEnvOr "CXM_MAIL_FROM" "noreply" >>= λ mailFrom →
  getEnvOr "CXM_WEBHOOK_SECRET" "" >>= λ whSecret →
  getEnvOr "CXM_MEDIA_SECRET" "dev-media-secret" >>= λ msec →
  envNat "CXM_MEDIA_TTL" 300 >>= λ mttl →
  envNat "CXM_PORT" 8138 >>= λ port →       -- П5: флот на одной машине — порт per-инстанс
  newHttpClientManager >>= λ mgr →
  setLineBuffering >>
  let run = connectPerTxn conninfo
      devMode    = primStringEquality dev "1" ∨ primStringEquality dev "true"
      weakSecret = primStringEquality secret "dev-secret-change-me" ∨ null (toList secret)
  in if weakSecret ∧ not devMode
     then putStrLn "FATAL: refusing to start — set a strong CXM_JWT_SECRET (or CXM_DEV=1 for local dev)."
     else
       (mkExt run >>= λ ext →
        getCurrentTime >>= λ now →
        bootMigrations conninfo now >>
        runCxmTx run (seedTenantsV (mkTenant defaultTenant "default" now ∷ [])) >>= λ _ →
        (if null (toList adminLogin) then pure tt
         else hashPassword adminPass >>= λ ph →
              runCxmTx run (ensureAdminV adminLogin ph "" defaultTenant now) >>= λ _ → pure tt) >>
        (if workerSec ≡ᵇ 0 then putStrLn "(pg-worker off)"
         else forkLoopNudged workerSec (workerTick mgr whSecret sendmail mailFrom run leadH maxAtt)) >>
        putStrLn "CXM neutral server lib on POSTGRES + pg-worker (Ext mounted)" >>
        (if null (toList sockPath)
         then listenHost "127.0.0.1" port (route run secret ext msec mttl)
         else listenUnix sockPath (route run secret ext msec mttl)))