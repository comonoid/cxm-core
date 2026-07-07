{-# OPTIONS --without-K #-}

-- CxmUI.Client — typed API client over cxm-server-pg (frontend layer 2). Each call builds the
-- HTTP request (url + Bearer + body) and decodes the {"data":…} / {"error":…} envelope into a
-- `Result CallErr <View>`, handed to the caller's message continuation `(… → M) → Cmd M`.
-- Request bodies are built as strings (no encoder FFI needed). Talks HTTP/JSON ONLY — no
-- dependency on the Agda `cxm` core. Views + decoders come from CxmUI.Contract.
module CxmUI.Client where

open import Agda.Builtin.String using (primStringEquality)
open import Agda.Builtin.Unit using (⊤; tt)
open import Data.Char using (Char)
open import Data.Nat using (ℕ; suc; _<ᵇ_)
open import Data.Nat.Show using (show)
open import Data.String using (String; _++_; toList; fromList)
open import Data.List using (List; []; _∷_; concatMap; take; length)
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
-- Request plumbing
------------------------------------------------------------------------

-- minimal JSON string escaper for hand-built request bodies (quote/backslash/newline —
-- enough for operator-typed text; full control-char coverage can come with a Json encoder)
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

  bySubjectBody : ℕ → String
  bySubjectBody s = "{\"subject\":" ++ show s ++ "}"

------------------------------------------------------------------------
-- Auth (login → JWT; live server envelopes it like everything else: {"data":{"token":…}} —
-- caught by the Ф4.1 live smoke, the original Ф1.1 decoder expected a bare {"token":…})
------------------------------------------------------------------------

login : ∀ {M : Set} → Cfg → (login password : String) → (Result CallErr String → M) → Cmd M
login cfg lg pw k =
  httpPostH (base cfg ++ "/auth/login") []
            ("{\"login\":\"" ++ escJson lg ++ "\",\"password\":\"" ++ escJson pw ++ "\"}")
            (λ r → k (envelope (field′ "token" string) r)) (λ r → k (err (errBody r)))

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

-- explainability (аудит №8): the evidence chain behind one knowledge unit — WHY the system
-- believes it (events attached by inference/operator).
evidenceOf : ∀ {M : Set} → Cfg → (knowledge : ℕ) → (Result CallErr (List EvidenceView) → M) → Cmd M
evidenceOf cfg kid =
  postJson cfg "/knowledge/evidence/by-knowledge" ("{\"knowledge\":" ++ show kid ++ "}") evidenceListDec

------------------------------------------------------------------------
-- /v1 social reads (Ф1.3). The /v1 surface has its OWN auth: an `x-integration-token` header
-- (site-scoped, resolves to the owner's tenant) + viewer identity in the body
-- (identity_channel/identity_id — e.g. cookie/session or user_id). No Bearer here.
------------------------------------------------------------------------

record V1Cfg : Set where
  constructor mkV1Cfg
  field v1base v1token v1channel v1id : String   -- base origin, integration token, viewer identity
open V1Cfg public

private
  postV1 : ∀ {A M : Set} → V1Cfg → String → String → Decoder A → (Result CallErr A → M) → Cmd M
  postV1 c path extra dec k =
    httpPostH (v1base c ++ path) (("x-integration-token" , v1token c) ∷ [])
              ("{\"identity_channel\":\"" ++ escJson (v1channel c) ++ "\",\"identity_id\":\""
                ++ escJson (v1id c) ++ "\"" ++ extra ++ "}")
              (λ r → k (envelope dec r)) (λ r → k (err (errBody r)))

  -- optional page size (0 = всё): the readers are newest-first/rank-ordered, so `limit n`
  -- means "the top n". Widgets pass 0 (unchanged behavior); sites cap community-scale lists.
  limitOf : ℕ → String
  limitOf 0 = ""
  limitOf n = ",\"limit\":" ++ show n

-- Ф3.1: content of followed authors, newest-first; locked rows are stripped teasers.
feed : ∀ {M : Set} → V1Cfg → (limit : ℕ) → (Result CallErr (List ContentView) → M) → Cmd M
feed c lim = postV1 c "/v1/feed" (limitOf lim) contentListDec

-- Ф3.2: pre-ordered conversation under a root (depth 0 = root, children createdAt-asc).
thread : ∀ {M : Set} → V1Cfg → (root limit : ℕ) → (Result CallErr (List ThreadNodeView) → M) → Cmd M
thread c root lim = postV1 c "/v1/thread" (",\"root\":" ++ show root ++ limitOf lim) threadListDec

-- Ф3.3: curated showcase window at `from` (feed-shaped rows, rank-ordered server-side).
showcase : ∀ {M : Set} → V1Cfg → (from limit : ℕ) → (Result CallErr (List ContentView) → M) → Cmd M
showcase c from lim = postV1 c "/v1/showcase" (",\"from\":" ++ show from ++ limitOf lim) contentListDec

-- Ф3.4: paywall — the live offering list, and purchase-start. The server records a PENDING
-- payment at ITS price (the client never sends an amount); success arrives via the provider
-- webhook (/payments/succeed), after which the entitlement unlocks content on the next read.
offeringsV1 : ∀ {M : Set} → V1Cfg → (Result CallErr (List OfferingView) → M) → Cmd M
offeringsV1 c = postV1 c "/v1/offerings" "" offeringListDec

purchase : ∀ {M : Set} → V1Cfg → (offering : ℕ) (extId : String) → (Result CallErr ℕ → M) → Cmd M
purchase c off ext =
  postV1 c "/v1/purchase" (",\"offering\":" ++ show off ++ ",\"ext_id\":\"" ++ escJson ext ++ "\"") idDec


------------------------------------------------------------------------
-- Cabinet writes (return {"ok":true} on success, NOT a data envelope)
------------------------------------------------------------------------

-- success writes come back as {"data":{"ok":true}} (okUnit is wrapped in the data envelope, same
-- as every ok response) → reuse `envelope` with a {"ok":…} inner decoder, discard the bool.
envelopeUnit : String → Result CallErr ⊤
envelopeUnit resp with envelope (field′ "ok" bool) resp
... | ok _  = ok tt
... | err e = err e

private
  postUnit : ∀ {M : Set} → Cfg → String → String → (Result CallErr ⊤ → M) → Cmd M
  postUnit cfg path body k =
    httpPostH (base cfg ++ path) (authHdr (jwt cfg)) body
              (λ r → k (envelopeUnit r)) (λ r → k (err (errBody r)))

-- Ф2.4: re-derive a subject's ACTIVE hypotheses from its event log.
rebuildInference : ∀ {M : Set} → Cfg → ℕ → (Result CallErr ⊤ → M) → Cmd M
rebuildInference cfg sid = postUnit cfg "/knowledge/rebuild-inference" (bySubjectBody sid)

-- Ф2.3: revise a knowledge unit. `kind` ∈ confirm|refute|supersede (param-free), or
-- strengthen|weaken (server reads "amount") / redetail (server reads "detail"). This form covers
-- the param-free moves; a richer overload can add amount/detail when the notebook needs them.
reviseKnowledge : ∀ {M : Set} → Cfg → (knowledge : ℕ) (kind : String) → (Result CallErr ⊤ → M) → Cmd M
reviseKnowledge cfg kid kind =
  postUnit cfg "/knowledge/revise" ("{\"knowledge\":" ++ show kid ++ ",\"kind\":\"" ++ kind ++ "\"}")

-- Ф2.3-хвост: the amount-carrying moves (strengthen/weaken read "amount" on the server).
reviseKnowledgeBy : ∀ {M : Set} → Cfg → (knowledge : ℕ) (kind : String) (amount : ℕ)
                    → (Result CallErr ⊤ → M) → Cmd M
reviseKnowledgeBy cfg kid kind amt =
  postUnit cfg "/knowledge/revise"
    ("{\"knowledge\":" ++ show kid ++ ",\"kind\":\"" ++ kind ++ "\",\"amount\":" ++ show amt ++ "}")

-- Ф2.3-хвост: redetail — rewrite the opaque kDetail with operator-typed text (JSON-escaped).
reviseDetail : ∀ {M : Set} → Cfg → (knowledge : ℕ) (detail : String) → (Result CallErr ⊤ → M) → Cmd M
reviseDetail cfg kid d =
  postUnit cfg "/knowledge/revise"
    ("{\"knowledge\":" ++ show kid ++ ",\"kind\":\"redetail\",\"detail\":\"" ++ escJson d ++ "\"}")

------------------------------------------------------------------------
-- Cabinet creates (аудит-2 №1): the operator ADDS things, not only revises them.
-- All return the created id ({"data":{"id":N}} → idDec).
------------------------------------------------------------------------

createSubject : ∀ {M : Set} → Cfg → (name : String) → (Result CallErr ℕ → M) → Cmd M
createSubject cfg nm = postJson cfg "/subjects" ("{\"name\":\"" ++ escJson nm ++ "\"}") idDec

-- a STATED observation (server wraps it STATE/STATED conf 500 — the operator's raw note)
createKnowledge : ∀ {M : Set} → Cfg → (subject : ℕ) (detail : String) → (Result CallErr ℕ → M) → Cmd M
createKnowledge cfg sid d =
  postJson cfg "/knowledge"
    ("{\"subject\":" ++ show sid ++ ",\"detail\":\"" ++ escJson d ++ "\"}") idDec

createEpisode : ∀ {M : Set} → Cfg → (subject protocol : ℕ) (jtbd : String) → (Result CallErr ℕ → M) → Cmd M
createEpisode cfg sid proto j =
  postJson cfg "/episodes"
    ("{\"subject\":" ++ show sid ++ ",\"protocol\":" ++ show proto
      ++ ",\"jtbd\":\"" ++ escJson j ++ "\"}") idDec

createExpectation : ∀ {M : Set} → Cfg → (subject : ℕ) (topic : String) (level : ℕ)
                    → (Result CallErr ℕ → M) → Cmd M
createExpectation cfg sid topic lvl =
  postJson cfg "/expectations"
    ("{\"subject\":" ++ show sid ++ ",\"topic\":\"" ++ escJson topic
      ++ "\",\"level\":" ++ show lvl ++ "}") idDec

bookAppointment : ∀ {M : Set} → Cfg → (subject resource start duration : ℕ)
                  → (Result CallErr ℕ → M) → Cmd M
bookAppointment cfg sid res st dur =
  postJson cfg "/appointments"
    ("{\"subject\":" ++ show sid ++ ",\"resource\":" ++ show res
      ++ ",\"start\":" ++ show st ++ ",\"duration\":" ++ show dur ++ "}") idDec

attachEvidence : ∀ {M : Set} → Cfg → (knowledge event : ℕ) → (Result CallErr ℕ → M) → Cmd M
attachEvidence cfg kid ev =
  postJson cfg "/knowledge/evidence"
    ("{\"knowledge\":" ++ show kid ++ ",\"event\":" ++ show ev ++ "}") idDec

-- showcase curation (аудит-2 №3): owner links `to` under shelf `from`; validTo 0 = бессрочно
linkResource : ∀ {M : Set} → Cfg → (from to rank validTo : ℕ) → (Result CallErr ℕ → M) → Cmd M
linkResource cfg f t rk vt =
  postJson cfg "/resources/link"
    ("{\"from\":" ++ show f ++ ",\"to\":" ++ show t ++ ",\"rank\":" ++ show rk
      ++ ",\"validTo\":" ++ show vt ++ "}") idDec

unlinkResource : ∀ {M : Set} → Cfg → (link : ℕ) → (Result CallErr ⊤ → M) → Cmd M
unlinkResource cfg l = postUnit cfg "/resources/unlink" ("{\"link\":" ++ show l ++ "}")

-- integration tokens (аудит-2 №5): mint returns {"data":{"id":N,"token":"…"}}
record MintedToken : Set where
  constructor mkMintedToken
  field mtId : ℕ ; mtToken : String
open MintedToken public

mintedDec : Decoder MintedToken
mintedDec = andThen (λ i → andThen (λ t → succeed (mkMintedToken i t)) (field′ "token" string))
                    (field′ "id" nat)

mintIntegrationToken : ∀ {M : Set} → Cfg → (origin : String) → (Result CallErr MintedToken → M) → Cmd M
mintIntegrationToken cfg origin =
  postJson cfg "/integration-tokens" ("{\"origin\":\"" ++ escJson origin ++ "\"}") mintedDec

revokeIntegrationToken : ∀ {M : Set} → Cfg → (tokenId : ℕ) → (Result CallErr ⊤ → M) → Cmd M
revokeIntegrationToken cfg tid =
  postUnit cfg "/integration-tokens/revoke" ("{\"id\":" ++ show tid ++ "}")

------------------------------------------------------------------------
-- /v1 writes (аудит-2 №2): the interactive community — publish/comment/follow — and the
-- session merge that closes the paywall loop (anonymous buyer registers → their provisional
-- subject and its entitlements merge into the account; without it the purchase stays with a
-- cookie-ghost). payload/visibility/listing are opaque site JSON / policy strings.
------------------------------------------------------------------------

private
  optStr : String → String → String   -- ,"key":"val" when val ≠ "" (server defaults on absence)
  optStr key v = if primStringEquality v "" then "" else ",\"" ++ key ++ "\":\"" ++ escJson v ++ "\""

  optNat : String → ℕ → String        -- ,"key":n when n ≠ 0 (server mFk: 0 = nothing anyway)
  optNat key 0 = ""
  optNat key n = ",\"" ++ key ++ "\":" ++ show n

publishV1 : ∀ {M : Set} → V1Cfg → (parent : ℕ) (visibility listing payload : String)
            → (Result CallErr ℕ → M) → Cmd M
publishV1 c parent vis lst payload =
  postV1 c "/v1/publish"
    (optNat "parent" parent ++ optStr "visibility" vis ++ optStr "listing" lst
      ++ ",\"payload\":\"" ++ escJson payload ++ "\"") idDec

-- a conversation node: anchored to resource `anchor`, threaded under `parent` (0 = top-level)
commentV1 : ∀ {M : Set} → V1Cfg → (anchor parent : ℕ) (payload : String)
            → (Result CallErr ℕ → M) → Cmd M
commentV1 c anchor parent payload =
  postV1 c "/v1/comment"
    (",\"anchor_kind\":\"resource\",\"anchor_id\":" ++ show anchor
      ++ optNat "parent" parent ++ ",\"payload\":\"" ++ escJson payload ++ "\"") idDec

followV1 : ∀ {M : Set} → V1Cfg → (targetChannel targetId : String) → (Result CallErr ℕ → M) → Cmd M
followV1 c tch tid =
  postV1 c "/v1/follow"
    (",\"target_channel\":\"" ++ escJson tch ++ "\",\"target_id\":\"" ++ escJson tid ++ "\"") idDec

mergeSession : ∀ {M : Set} → V1Cfg → (provisional : ℕ) → (Result CallErr ⊤ → M) → Cmd M
mergeSession c prov k =
  httpPostH (v1base c ++ "/v1/merge-session") (("x-integration-token" , v1token c) ∷ [])
            ("{\"identity_channel\":\"" ++ escJson (v1channel c) ++ "\",\"identity_id\":\""
              ++ escJson (v1id c) ++ "\",\"provisional\":" ++ show prov ++ "}")
            (λ r → k (envelopeUnit r)) (λ r → k (err (errBody r)))
