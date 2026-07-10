{-# OPTIONS --without-K #-}

-- CxmUI.Client — typed API client over cxm-server-pg (frontend layer 2). Each call builds the
-- HTTP request (url + Bearer + body) and decodes the {"data":…} / {"error":…} envelope into a
-- `Result CallErr <View>`, handed to the caller's message continuation `(… → M) → Cmd M`.
-- Talks HTTP/JSON ONLY — no dependency on the Agda `cxm` core. Views + decoders: CxmUI.Contract.
--
-- СТРУКТУРА (аудит-3 №9): request BODIES are pure public `…Body`/`…Extra` functions — the
-- testable half of every binding (node-тесты парсят их как JSON и сверяют поля; опечатка в имени
-- поля больше не доживает до рантайма). Cmd-обёртки — однострочники поверх них.
module CxmUI.Client where

open import Agda.Builtin.String using (primStringEquality)
open import Agda.Builtin.Unit using (⊤; tt)
open import Data.Char using (Char)
open import Data.Nat using (ℕ; suc; _<ᵇ_)
open import Data.Nat.Show using (show)
open import Data.String using (String; _++_; toList; fromList; intersperse)
open import Data.List using (List; []; _∷_; concatMap; take; length; map; null)
open import Data.Product using (_×_; _,_)
open import Data.Bool using (if_then_else_)

open import Agdelte.Core.Result using (Result; ok; err)
open import Agdelte.Core.Cmd using (Cmd; httpGetH; httpPostH)
open import Agdelte.Json using (Decoder; string; nat; bool; field′; decodeString; andThen; succeed)
open import CxmUI.Contract

private
  _>>=_ : ∀ {A B : Set} → Decoder A → (A → Decoder B) → Decoder B
  d >>= f = andThen f d
  infixl 1 _>>=_

------------------------------------------------------------------------
-- Errors + config
------------------------------------------------------------------------

record ApiErr : Set where
  constructor mkApiErr
  field aeCode aeMsg : String
open ApiErr public

data CallErr : Set where
  httpErr   : String → CallErr    -- network / non-2xx transport failure (onErr body)
  serverErr : ApiErr → CallErr    -- {"error":{"code","message"}} from the server
  decodeErr : String → CallErr    -- response was neither a decodable data nor error envelope

record Cfg : Set where
  constructor mkCfg
  field base jwt : String         -- base = origin ("" = same-origin); jwt = "" = anon
open Cfg public

------------------------------------------------------------------------
-- Envelope (PUBLIC — the pure, node-testable core)
------------------------------------------------------------------------

errDec : Decoder ApiErr
errDec = field′ "code" string >>= λ c → field′ "message" string >>= λ m → succeed (mkApiErr c m)

-- {"data":X} → ok X ; {"error":{…}} → serverErr ; else decodeErr
envelope : ∀ {A : Set} → Decoder A → String → Result CallErr A
envelope dec resp with decodeString (field′ "data" dec) resp
... | ok a  = ok a
... | err _ with decodeString (field′ "error" errDec) resp
...   | ok e  = err (serverErr e)
...   | err m = err (decodeErr m)

-- success writes come back as {"data":{"ok":true}} → reuse `envelope`, discard the bool
envelopeUnit : String → Result CallErr ⊤
envelopeUnit resp with envelope (field′ "ok" bool) resp
... | ok _  = ok tt
... | err e = err e

-- transport-error body → CallErr. The runtime hands the 4xx/5xx response BODY to the error
-- callback (agdelte 2026-07-07); the server puts its {"error":{code,message}} envelope there —
-- recover it as serverErr so widgets say «сервер: conflict», not «сеть: HTTP 409». A body that
-- is not an error envelope (proxy HTML page, truncated response) stays httpErr, CAPPED to a
-- status-line-sized snippet (аудит-2 №10: a whole gateway page must not land in the UI).
private
  truncTo : ℕ → String → String
  truncTo n s = let cs = toList s in
    if length cs <ᵇ suc n then s else fromList (take n cs) ++ "…"

errBody : String → CallErr
errBody r with decodeString (field′ "error" errDec) r
... | ok e  = serverErr e
... | err _ = httpErr (truncTo 120 r)

------------------------------------------------------------------------
-- JSON escaping (operator-typed text must not break hand-built bodies)
------------------------------------------------------------------------

escJson : String → String
escJson s = fromList (concatMap escChar (toList s))
  where
    escChar : Char → List Char
    escChar '"'  = '\\' ∷ '"' ∷ []
    escChar '\\' = '\\' ∷ '\\' ∷ []
    escChar '\n' = '\\' ∷ 'n' ∷ []
    escChar '\t' = '\\' ∷ 't' ∷ []
    escChar '\r' = '\\' ∷ 'r' ∷ []
    escChar c    = c ∷ []

------------------------------------------------------------------------
-- Request bodies — PURE and PUBLIC (аудит-3 №9): the wire contract of every write, testable
-- without executing HTTP. Field names here mirror the server routes 1:1.
------------------------------------------------------------------------

private
  q : String → String              -- a JSON string value
  q s = "\"" ++ escJson s ++ "\""

  kv : String → String → String    -- "key":<raw>
  kv k v = "\"" ++ k ++ "\":" ++ v

-- generic {"<key>":n} — unlink/revoke/fulfill/break/offer/settle/default/delete/erase…
idBody : String → ℕ → String
idBody key n = "{" ++ kv key (show n) ++ "}"

bySubjectBody : ℕ → String
bySubjectBody s = "{" ++ kv "subject" (show s) ++ "}"

loginBody : (login password : String) → String
loginBody lg pw = "{" ++ kv "login" (q lg) ++ "," ++ kv "password" (q pw) ++ "}"

registerBody : (login password name : String) → String
registerBody lg pw nm =
  "{" ++ kv "login" (q lg) ++ "," ++ kv "password" (q pw) ++ "," ++ kv "name" (q nm) ++ "}"

verifyIdentityBody : (identity : ℕ) (token : String) → String
verifyIdentityBody iid tok = "{" ++ kv "identity" (show iid) ++ "," ++ kv "token" (q tok) ++ "}"

identityBody : (subject : ℕ) (channel idv : String) → String
identityBody sid ch idv =
  "{" ++ kv "subject" (show sid) ++ "," ++ kv "channel" (q ch) ++ "," ++ kv "id" (q idv) ++ "}"

subjectBody : (name : String) → String
subjectBody nm = "{" ++ kv "name" (q nm) ++ "}"

knowledgeBody : (subject : ℕ) (detail : String) → String
knowledgeBody sid d = "{" ++ kv "subject" (show sid) ++ "," ++ kv "detail" (q d) ++ "}"

evidenceKnowledgeBody : (knowledge : ℕ) → String
evidenceKnowledgeBody kid = "{" ++ kv "knowledge" (show kid) ++ "}"

reviseBody : (knowledge : ℕ) (kind : String) → String
reviseBody kid kind = "{" ++ kv "knowledge" (show kid) ++ "," ++ kv "kind" (q kind) ++ "}"

reviseByBody : (knowledge : ℕ) (kind : String) (amount : ℕ) → String
reviseByBody kid kind amt =
  "{" ++ kv "knowledge" (show kid) ++ "," ++ kv "kind" (q kind)
      ++ "," ++ kv "amount" (show amt) ++ "}"

redetailBody : (knowledge : ℕ) (detail : String) → String
redetailBody kid d =
  "{" ++ kv "knowledge" (show kid) ++ "," ++ kv "kind" (q "redetail")
      ++ "," ++ kv "detail" (q d) ++ "}"

episodeBody : (subject protocol : ℕ) (jtbd : String) → String
episodeBody sid proto j =
  "{" ++ kv "subject" (show sid) ++ "," ++ kv "protocol" (show proto)
      ++ "," ++ kv "jtbd" (q j) ++ "}"

episodeTransitionBody : (episode to : ℕ) → String
episodeTransitionBody ep to = "{" ++ kv "episode" (show ep) ++ "," ++ kv "to" (show to) ++ "}"

protocolBody : (name : String) (initial : ℕ) → String
protocolBody nm ini = "{" ++ kv "name" (q nm) ++ "," ++ kv "initial" (show ini) ++ "}"

protocolStateBody : (protocol code : ℕ) (name : String) → String
protocolStateBody p c nm =
  "{" ++ kv "protocol" (show p) ++ "," ++ kv "code" (show c) ++ "," ++ kv "name" (q nm) ++ "}"

protocolTransitionBody : (protocol from to : ℕ) → String
protocolTransitionBody p f t =
  "{" ++ kv "protocol" (show p) ++ "," ++ kv "from" (show f) ++ "," ++ kv "to" (show t) ++ "}"

expectationBody : (subject : ℕ) (topic : String) (level : ℕ) → String
expectationBody sid topic lvl =
  "{" ++ kv "subject" (show sid) ++ "," ++ kv "topic" (q topic)
      ++ "," ++ kv "level" (show lvl) ++ "}"

appointmentBody : (subject resource start duration : ℕ) → String
appointmentBody sid res st dur =
  "{" ++ kv "subject" (show sid) ++ "," ++ kv "resource" (show res)
      ++ "," ++ kv "start" (show st) ++ "," ++ kv "duration" (show dur) ++ "}"

attachEvidenceBody : (knowledge event : ℕ) → String
attachEvidenceBody kid ev = "{" ++ kv "knowledge" (show kid) ++ "," ++ kv "event" (show ev) ++ "}"

linkBody : (from to rank validTo : ℕ) → String
linkBody f t rk vt =
  "{" ++ kv "from" (show f) ++ "," ++ kv "to" (show t)
      ++ "," ++ kv "rank" (show rk) ++ "," ++ kv "validTo" (show vt) ++ "}"

mintBody : (origin : String) → String
mintBody origin = "{" ++ kv "origin" (q origin) ++ "}"

offeringBody : (kind price : ℕ) (currency metadata : String) → String
offeringBody k p cur md =
  "{" ++ kv "kind" (show k) ++ "," ++ kv "price" (show p)
      ++ "," ++ kv "currency" (q cur) ++ "," ++ kv "metadata" (q md) ++ "}"

promiseBody : (subject : ℕ) (topic : String) (deadline : ℕ) → String
promiseBody sid topic dl =
  "{" ++ kv "subject" (show sid) ++ "," ++ kv "topic" (q topic)
      ++ "," ++ kv "deadline" (show dl) ++ "}"

promiseTransferBody : (id holder penaltyTo : ℕ) → String   -- penaltyTo 0 = нет
promiseTransferBody i h pt =
  "{" ++ kv "id" (show i) ++ "," ++ kv "holder" (show h)
      ++ "," ++ kv "penalty_to" (show pt) ++ "}"

promiseReferBody : (id stake : ℕ) → String
promiseReferBody i st = "{" ++ kv "id" (show i) ++ "," ++ kv "stake" (show st) ++ "}"

------------------------------------------------------------------------
-- Request plumbing
------------------------------------------------------------------------

private
  authHdr : String → List (String × String)
  authHdr j = if primStringEquality j "" then [] else ("Authorization" , "Bearer " ++ j) ∷ []

  postJson : ∀ {A M : Set} → Cfg → String → String → Decoder A → (Result CallErr A → M) → Cmd M
  postJson cfg path body dec k =
    httpPostH (base cfg ++ path) (authHdr (jwt cfg)) body
              (λ r → k (envelope dec r)) (λ r → k (err (errBody r)))

  getJson : ∀ {A M : Set} → Cfg → String → Decoder A → (Result CallErr A → M) → Cmd M
  getJson cfg path dec k =
    httpGetH (base cfg ++ path) (authHdr (jwt cfg))
             (λ r → k (envelope dec r)) (λ r → k (err (errBody r)))

  postUnit : ∀ {M : Set} → Cfg → String → String → (Result CallErr ⊤ → M) → Cmd M
  postUnit cfg path body k =
    httpPostH (base cfg ++ path) (authHdr (jwt cfg)) body
              (λ r → k (envelopeUnit r)) (λ r → k (err (errBody r)))

------------------------------------------------------------------------
-- Auth + onboarding (аудит-3 №3). login/register без Bearer; verify-identity — HMAC-токен
-- из письма (identities создаёт контакт и шлёт его).
------------------------------------------------------------------------

login : ∀ {M : Set} → Cfg → (login password : String) → (Result CallErr String → M) → Cmd M
login cfg lg pw k =
  httpPostH (base cfg ++ "/auth/login") [] (loginBody lg pw)
            (λ r → k (envelope (field′ "token" string) r)) (λ r → k (err (errBody r)))

register : ∀ {M : Set} → Cfg → (login password name : String) → (Result CallErr ℕ → M) → Cmd M
register cfg lg pw nm k =
  httpPostH (base cfg ++ "/auth/register") [] (registerBody lg pw nm)
            (λ r → k (envelope idDec r)) (λ r → k (err (errBody r)))

-- liveness + contract skew check (аудит-5 №4): /health — единственный НЕ-data-конверт;
-- сайт при маунте сверяет hContract с Contract.expectedContract.
health : ∀ {M : Set} → Cfg → (Result CallErr HealthView → M) → Cmd M
health cfg k =
  httpGetH (base cfg ++ "/health") []
           (λ r → k (bare r)) (λ r → k (err (errBody r)))
  where
    bare : String → Result CallErr HealthView
    bare r with decodeString healthDec r
    ... | ok h  = ok h
    ... | err m = err (decodeErr m)

-- confirm a contact with the HMAC token from the verification e-mail; {"verified":true} on ok
verifyIdentity : ∀ {M : Set} → Cfg → (identity : ℕ) (token : String) → (Result CallErr ⊤ → M) → Cmd M
verifyIdentity cfg iid tok k =
  httpPostH (base cfg ++ "/verify-identity") [] (verifyIdentityBody iid tok)
            (λ r → k (asUnit (envelope (field′ "verified" bool) r))) (λ r → k (err (errBody r)))
  where
    asUnit : Result CallErr _ → Result CallErr ⊤
    asUnit (ok _)  = ok tt
    asUnit (err e) = err e

-- bind a contact to a subject; server queues the verification mail ({"id":N,"verification":"sent"})
bindIdentity : ∀ {M : Set} → Cfg → (subject : ℕ) (channel idv : String) → (Result CallErr ℕ → M) → Cmd M
bindIdentity cfg sid ch idv = postJson cfg "/identities" (identityBody sid ch idv) idDec

------------------------------------------------------------------------
-- Cabinet reads (owner-scoped; jwt required). The client card composes these.
------------------------------------------------------------------------

roster : ∀ {M : Set} → Cfg → (Result CallErr (List RosterView) → M) → Cmd M
roster cfg = getJson cfg "/subjects" rosterListDec

knowledgeOf : ∀ {M : Set} → Cfg → ℕ → (Result CallErr (List KnowledgeView) → M) → Cmd M
knowledgeOf cfg sid = postJson cfg "/knowledge/by-subject" (bySubjectBody sid) knowledgeListDec

episodesOf : ∀ {M : Set} → Cfg → ℕ → (Result CallErr (List EpisodeView) → M) → Cmd M
episodesOf cfg sid = postJson cfg "/episodes/by-subject" (bySubjectBody sid) episodeListDec

expectationsOf : ∀ {M : Set} → Cfg → ℕ → (Result CallErr (List ExpectationView) → M) → Cmd M
expectationsOf cfg sid = postJson cfg "/expectations/by-subject" (bySubjectBody sid) expectationListDec

appointmentsOf : ∀ {M : Set} → Cfg → ℕ → (Result CallErr (List AppointmentView) → M) → Cmd M
appointmentsOf cfg sid = postJson cfg "/appointments/by-subject" (bySubjectBody sid) appointmentListDec

-- explainability: the evidence chain behind one knowledge unit (rows event-enriched)
evidenceOf : ∀ {M : Set} → Cfg → (knowledge : ℕ) → (Result CallErr (List EvidenceView) → M) → Cmd M
evidenceOf cfg kid =
  postJson cfg "/knowledge/evidence/by-knowledge" (evidenceKnowledgeBody kid) evidenceListDec

-- операторский ops-вид доставки (аудит-3 №8)
outbox : ∀ {M : Set} → Cfg → (Result CallErr (List OutboxView) → M) → Cmd M
outbox cfg = getJson cfg "/outbox" outboxListDec

------------------------------------------------------------------------
-- Cabinet writes — revises (return {"ok":true}) and creates (return {"data":{"id":N}})
------------------------------------------------------------------------

-- Ф2.4: re-derive a subject's ACTIVE hypotheses from its event log.
rebuildInference : ∀ {M : Set} → Cfg → ℕ → (Result CallErr ⊤ → M) → Cmd M
rebuildInference cfg sid = postUnit cfg "/knowledge/rebuild-inference" (bySubjectBody sid)

-- Ф2.3: revise a knowledge unit. `kind` ∈ confirm|refute|supersede (param-free).
reviseKnowledge : ∀ {M : Set} → Cfg → (knowledge : ℕ) (kind : String) → (Result CallErr ⊤ → M) → Cmd M
reviseKnowledge cfg kid kind = postUnit cfg "/knowledge/revise" (reviseBody kid kind)

-- Ф2.3-хвост: the amount-carrying moves (strengthen/weaken read "amount" on the server).
reviseKnowledgeBy : ∀ {M : Set} → Cfg → (knowledge : ℕ) (kind : String) (amount : ℕ)
                    → (Result CallErr ⊤ → M) → Cmd M
reviseKnowledgeBy cfg kid kind amt = postUnit cfg "/knowledge/revise" (reviseByBody kid kind amt)

-- Ф2.3-хвост: redetail — rewrite the opaque kDetail with operator-typed text (JSON-escaped).
reviseDetail : ∀ {M : Set} → Cfg → (knowledge : ℕ) (detail : String) → (Result CallErr ⊤ → M) → Cmd M
reviseDetail cfg kid d = postUnit cfg "/knowledge/revise" (redetailBody kid d)

createSubject : ∀ {M : Set} → Cfg → (name : String) → (Result CallErr ℕ → M) → Cmd M
createSubject cfg nm = postJson cfg "/subjects" (subjectBody nm) idDec

-- a STATED observation (server wraps it STATE/STATED conf 500 — the operator's raw note)
createKnowledge : ∀ {M : Set} → Cfg → (subject : ℕ) (detail : String) → (Result CallErr ℕ → M) → Cmd M
createKnowledge cfg sid d = postJson cfg "/knowledge" (knowledgeBody sid d) idDec

createEpisode : ∀ {M : Set} → Cfg → (subject protocol : ℕ) (jtbd : String) → (Result CallErr ℕ → M) → Cmd M
createEpisode cfg sid proto j = postJson cfg "/episodes" (episodeBody sid proto j) idDec

-- двинуть линию работы по FSM протокола (аудит-3 №5)
transitionEpisode : ∀ {M : Set} → Cfg → (episode to : ℕ) → (Result CallErr ℕ → M) → Cmd M
transitionEpisode cfg ep to = postJson cfg "/episodes/transition" (episodeTransitionBody ep to) idDec

createProtocol : ∀ {M : Set} → Cfg → (name : String) (initial : ℕ) → (Result CallErr ℕ → M) → Cmd M
createProtocol cfg nm ini = postJson cfg "/protocols" (protocolBody nm ini) idDec

addProtocolState : ∀ {M : Set} → Cfg → (protocol code : ℕ) (name : String) → (Result CallErr ℕ → M) → Cmd M
addProtocolState cfg p c nm = postJson cfg "/protocols/state" (protocolStateBody p c nm) idDec

addProtocolTransition : ∀ {M : Set} → Cfg → (protocol from to : ℕ) → (Result CallErr ℕ → M) → Cmd M
addProtocolTransition cfg p f t = postJson cfg "/protocols/transition" (protocolTransitionBody p f t) idDec

createExpectation : ∀ {M : Set} → Cfg → (subject : ℕ) (topic : String) (level : ℕ)
                    → (Result CallErr ℕ → M) → Cmd M
createExpectation cfg sid topic lvl = postJson cfg "/expectations" (expectationBody sid topic lvl) idDec

-- ⚠ `resource` — id бронируемого ресурса; ЧИТАЛКИ bookable-ресурсов на сервере пока НЕТ
-- (аудит-4 №4) — id приходит из внешней конфигурации сайта, пока сервер не отрастит листинг.
bookAppointment : ∀ {M : Set} → Cfg → (subject resource start duration : ℕ)
                  → (Result CallErr ℕ → M) → Cmd M
bookAppointment cfg sid res st dur = postJson cfg "/appointments" (appointmentBody sid res st dur) idDec

attachEvidence : ∀ {M : Set} → Cfg → (knowledge event : ℕ) → (Result CallErr ℕ → M) → Cmd M
attachEvidence cfg kid ev = postJson cfg "/knowledge/evidence" (attachEvidenceBody kid ev) idDec

-- showcase curation: owner links `to` under shelf `from`; validTo 0 = бессрочно
linkResource : ∀ {M : Set} → Cfg → (from to rank validTo : ℕ) → (Result CallErr ℕ → M) → Cmd M
linkResource cfg f t rk vt = postJson cfg "/resources/link" (linkBody f t rk vt) idDec

unlinkResource : ∀ {M : Set} → Cfg → (link : ℕ) → (Result CallErr ⊤ → M) → Cmd M
unlinkResource cfg l = postUnit cfg "/resources/unlink" (idBody "link" l)

-- paywall, сторона владельца (аудит-3 №4): metadata несёт fulfilment-план (grants-as-data)
createOffering : ∀ {M : Set} → Cfg → (kind price : ℕ) (currency metadata : String)
                 → (Result CallErr ℕ → M) → Cmd M
createOffering cfg k p cur md = postJson cfg "/offerings" (offeringBody k p cur md) idDec

deleteOffering : ∀ {M : Set} → Cfg → (offering : ℕ) → (Result CallErr ⊤ → M) → Cmd M
deleteOffering cfg o = postUnit cfg "/offerings/delete" (idBody "id" o)

-- integration tokens: mint returns {"data":{"id":N,"token":"…"}}
record MintedToken : Set where
  constructor mkMintedToken
  field mtId : ℕ ; mtToken : String
open MintedToken public

mintedDec : Decoder MintedToken
mintedDec = field′ "id" nat >>= λ i → field′ "token" string >>= λ t → succeed (mkMintedToken i t)

mintIntegrationToken : ∀ {M : Set} → Cfg → (origin : String) → (Result CallErr MintedToken → M) → Cmd M
mintIntegrationToken cfg origin = postJson cfg "/integration-tokens" (mintBody origin) mintedDec

-- аудит-4 №3: сам токен показывается ТОЛЬКО при минте; список — id/scope/revoked
listIntegrationTokens : ∀ {M : Set} → Cfg → (Result CallErr (List IntTokenView) → M) → Cmd M
listIntegrationTokens cfg = getJson cfg "/integration-tokens" intTokenListDec

revokeIntegrationToken : ∀ {M : Set} → Cfg → (tokenId : ℕ) → (Result CallErr ⊤ → M) → Cmd M
revokeIntegrationToken cfg tid = postUnit cfg "/integration-tokens/revoke" (idBody "id" tid)

-- GDPR (аудит-3 №6): каскадное удаление и crypto-erase клиента
deleteSubject : ∀ {M : Set} → Cfg → (subject : ℕ) → (Result CallErr ⊤ → M) → Cmd M
deleteSubject cfg sid = postUnit cfg "/subjects/delete" (idBody "id" sid)

eraseSubject : ∀ {M : Set} → Cfg → (subject : ℕ) → (Result CallErr ⊤ → M) → Cmd M
eraseSubject cfg sid = postUnit cfg "/subjects/erase" (idBody "id" sid)

openAccount : ∀ {M : Set} → Cfg → (Result CallErr ℕ → M) → Cmd M
openAccount cfg = postJson cfg "/accounts" "{}" idDec

------------------------------------------------------------------------
-- Promise-market (аудит-3 №7, Ч.2 §3): обещание = актив с клирингом. Виджетов пока нет
-- (сайт/П4 решают, как показывать) — но контракт биндед целиком.
------------------------------------------------------------------------

createPromise : ∀ {M : Set} → Cfg → (subject : ℕ) (topic : String) (deadline : ℕ)
                → (Result CallErr ℕ → M) → Cmd M
createPromise cfg sid topic dl = postJson cfg "/promises" (promiseBody sid topic dl) idDec

fulfillPromise : ∀ {M : Set} → Cfg → (promise : ℕ) → (Result CallErr ⊤ → M) → Cmd M
fulfillPromise cfg i = postUnit cfg "/promises/fulfill" (idBody "id" i)

breakPromise : ∀ {M : Set} → Cfg → (promise : ℕ) → (Result CallErr ⊤ → M) → Cmd M
breakPromise cfg i = postUnit cfg "/promises/break" (idBody "id" i)

-- выставить обещание на рынок (listing)
offerPromise : ∀ {M : Set} → Cfg → (promise : ℕ) → (Result CallErr ℕ → M) → Cmd M
offerPromise cfg i = postJson cfg "/promises/offer" (idBody "id" i) idDec

transferPromise : ∀ {M : Set} → Cfg → (promise holder penaltyTo : ℕ) → (Result CallErr ⊤ → M) → Cmd M
transferPromise cfg i h pt = postUnit cfg "/promises/transfer" (promiseTransferBody i h pt)

referPromise : ∀ {M : Set} → Cfg → (promise stake : ℕ) → (Result CallErr ⊤ → M) → Cmd M
referPromise cfg i st = postUnit cfg "/promises/refer" (promiseReferBody i st)

settlePromise : ∀ {M : Set} → Cfg → (promise : ℕ) → (Result CallErr ⊤ → M) → Cmd M
settlePromise cfg i = postUnit cfg "/promises/settle" (idBody "id" i)

defaultPromise : ∀ {M : Set} → Cfg → (promise : ℕ) → (Result CallErr ⊤ → M) → Cmd M
defaultPromise cfg i = postUnit cfg "/promises/default" (idBody "id" i)

------------------------------------------------------------------------
-- /v1 social surface (Ф1.3/Ф3). СВОЙ auth: `x-integration-token` header + viewer identity
-- в теле (identity_channel/identity_id). No Bearer here.
------------------------------------------------------------------------

record V1Cfg : Set where
  constructor mkV1Cfg
  field v1base v1token v1channel v1id : String   -- base origin, integration token, viewer identity
open V1Cfg public

-- полный /v1-body: identity-конверт + extra (PURE — тестируется как JSON)
v1Body : V1Cfg → String → String
v1Body c extra =
  "{" ++ kv "identity_channel" (q (v1channel c)) ++ "," ++ kv "identity_id" (q (v1id c))
      ++ extra ++ "}"

-- extra-куски (PURE): всегда начинаются с "," или пусты
limitOf : ℕ → String
limitOf 0 = ""
limitOf n = "," ++ kv "limit" (show n)

optStr : String → String → String   -- ,"key":"val" when val ≠ "" (server defaults on absence)
optStr key v = if primStringEquality v "" then "" else "," ++ kv key (q v)

optNat : String → ℕ → String        -- ,"key":n when n ≠ 0 (server mFk: 0 = nothing anyway)
optNat key 0 = ""
optNat key n = "," ++ kv key (show n)

purchaseExtra : (offering : ℕ) (extId : String) → String
purchaseExtra off ext = optNat "offering" off ++ "," ++ kv "ext_id" (q ext)

publishExtra : (parent : ℕ) (visibility listing payload : String) → String
publishExtra parent vis lst payload =
  optNat "parent" parent ++ optStr "visibility" vis ++ optStr "listing" lst
    ++ "," ++ kv "payload" (q payload)

-- a JSON array of nats AS A STRING VALUE ("[1,2]") — jsonGetField на сервере берёт только
-- string-поля, в духе payload/metadata (сервер парсит decodeIds)
showIds : List ℕ → String
showIds xs = "[" ++ intersperse "," (map show xs) ++ "]"

-- аудит-5 №2: anchorKind — параметр (сервер поддерживает resource/appointment/promise/
-- entitlement/subject/episode — «разговор в точке контакта»); addressees — упоминания (№3)
commentExtra : (anchorKind : String) (anchor parent : ℕ) (visibility listing : String)
               (addressees : List ℕ) (payload : String) → String
commentExtra ak anchor parent vis lst tos payload =
  "," ++ kv "anchor_kind" (q ak) ++ "," ++ kv "anchor_id" (show anchor)
    ++ optNat "parent" parent ++ optStr "visibility" vis ++ optStr "listing" lst
    ++ (if null tos then "" else "," ++ kv "addressees" (q (showIds tos)))
    ++ "," ++ kv "payload" (q payload)

followExtra : (targetChannel targetId : String) → String
followExtra tch tid = "," ++ kv "target_channel" (q tch) ++ "," ++ kv "target_id" (q tid)

eventExtra : (payload : String) → String
eventExtra payload = "," ++ kv "payload" (q payload)

private
  postV1 : ∀ {A M : Set} → V1Cfg → String → String → Decoder A → (Result CallErr A → M) → Cmd M
  postV1 c path extra dec k =
    httpPostH (v1base c ++ path) (("x-integration-token" , v1token c) ∷ []) (v1Body c extra)
              (λ r → k (envelope dec r)) (λ r → k (err (errBody r)))

  postV1Unit : ∀ {M : Set} → V1Cfg → String → String → (Result CallErr ⊤ → M) → Cmd M
  postV1Unit c path extra k =
    httpPostH (v1base c ++ path) (("x-integration-token" , v1token c) ∷ []) (v1Body c extra)
              (λ r → k (envelopeUnit r)) (λ r → k (err (errBody r)))

-- Ф3.1: content of followed authors, newest-first; locked rows are stripped teasers.
feed : ∀ {M : Set} → V1Cfg → (limit : ℕ) → (Result CallErr (List ContentView) → M) → Cmd M
feed c lim = postV1 c "/v1/feed" (limitOf lim) contentListDec

-- Ф4 (site-plan): mentions inbox — «все ответы мне» (узлы, где viewer в addressees);
-- feed-shaped rows, та же S7-семантика locked-тизеров.
mentionsV1 : ∀ {M : Set} → V1Cfg → (limit : ℕ) → (Result CallErr (List ContentView) → M) → Cmd M
mentionsV1 c lim = postV1 c "/v1/mentions" (limitOf lim) contentListDec

-- Ф3.2: pre-ordered conversation under a root (depth 0 = root, children createdAt-asc).
thread : ∀ {M : Set} → V1Cfg → (root limit : ℕ) → (Result CallErr (List ThreadNodeView) → M) → Cmd M
thread c root lim = postV1 c "/v1/thread" (optNat "root" root ++ limitOf lim) threadListDec

-- Ф3.3: curated showcase window at `from` (feed-shaped rows, rank-ordered server-side).
showcase : ∀ {M : Set} → V1Cfg → (from limit : ℕ) → (Result CallErr (List ContentView) → M) → Cmd M
showcase c from lim = postV1 c "/v1/showcase" (optNat "from" from ++ limitOf lim) contentListDec

-- Ф3.4: paywall — the live offering list, and purchase-start. The server records a PENDING
-- payment at ITS price (the client never sends an amount); success arrives via the provider
-- webhook (/payments/succeed), after which the entitlement unlocks content on the next read.
offeringsV1 : ∀ {M : Set} → V1Cfg → (Result CallErr (List OfferingView) → M) → Cmd M
offeringsV1 c = postV1 c "/v1/offerings" "" offeringListDec

purchase : ∀ {M : Set} → V1Cfg → (offering : ℕ) (extId : String) → (Result CallErr ℕ → M) → Cmd M
purchase c off ext = postV1 c "/v1/purchase" (purchaseExtra off ext) idDec

------------------------------------------------------------------------
-- /v1 writes: the interactive community — publish/comment/follow — and the session merge
-- that closes the paywall loop (anonymous buyer registers → their provisional subject and its
-- entitlements merge into the account). payload/visibility/listing — opaque site JSON / policy.
------------------------------------------------------------------------

publishV1 : ∀ {M : Set} → V1Cfg → (parent : ℕ) (visibility listing payload : String)
            → (Result CallErr ℕ → M) → Cmd M
publishV1 c parent vis lst payload = postV1 c "/v1/publish" (publishExtra parent vis lst payload) idDec

-- a conversation node under `parent` (0 = top-level), anchored to (anchorKind, anchor) —
-- resource|appointment|promise|entitlement|subject|episode; visibility/listing "" = серверные
-- дефолты; addressees = упоминания ([] = нет)
commentV1 : ∀ {M : Set} → V1Cfg → (anchorKind : String) (anchor parent : ℕ)
            (visibility listing : String) (addressees : List ℕ) (payload : String)
            → (Result CallErr ℕ → M) → Cmd M
commentV1 c ak anchor parent vis lst tos payload =
  postV1 c "/v1/comment" (commentExtra ak anchor parent vis lst tos payload) idDec

followV1 : ∀ {M : Set} → V1Cfg → (targetChannel targetId : String) → (Result CallErr ℕ → M) → Cmd M
followV1 c tch tid = postV1 c "/v1/follow" (followExtra tch tid) idDec

-- аудит-4 №1: поведенческий ingest — сайт кормит experience OS (просмотры/действия зрителя);
-- payload — opaque JSON сайта, сервер заворачивает в ExperienceEvent (View/Integration).
ingestEvent : ∀ {M : Set} → V1Cfg → (payload : String) → (Result CallErr ℕ → M) → Cmd M
ingestEvent c payload = postV1 c "/v1/events" (eventExtra payload) idDec

mergeSession : ∀ {M : Set} → V1Cfg → (provisional : ℕ) → (Result CallErr ⊤ → M) → Cmd M
mergeSession c prov = postV1Unit c "/v1/merge-session" (optNat "provisional" prov)

-- Ф3.2 (site-plan): слияние по identity-ПАРЕ — сайт числовых id субъектов не знает.
-- V1Cfg ЭТОГО вызова несёт LOGIN-identity аккаунта (сайт зовёт ПОСЛЕ успешного /auth/login —
-- login доказывает контроль канала; trust-модель /v1); provisional-сессия — парой
-- (обычно "cookie" + visitor-id). Сервер резолвит обоих; повторный merge — no-op.
mergeExtra : (provChannel provId : String) → String
mergeExtra pch pid = "," ++ kv "provisional_channel" (q pch) ++ "," ++ kv "provisional_id" (q pid)

mergeSessionBy : ∀ {M : Set} → V1Cfg → (provChannel provId : String) → (Result CallErr ⊤ → M) → Cmd M
mergeSessionBy c pch pid = postV1Unit c "/v1/merge-session" (mergeExtra pch pid)
