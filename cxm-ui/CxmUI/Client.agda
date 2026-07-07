{-# OPTIONS --without-K #-}

-- CxmUI.Client — typed API client over cxm-server-pg (frontend layer 2). Each call builds the
-- HTTP request (url + Bearer + body) and decodes the {"data":…} / {"error":…} envelope into a
-- `Result CallErr <View>`, handed to the caller's message continuation `(… → M) → Cmd M`.
-- Request bodies are built as strings (no encoder FFI needed). Talks HTTP/JSON ONLY — no
-- dependency on the Agda `cxm` core. Views + decoders come from CxmUI.Contract.
module CxmUI.Client where

open import Agda.Builtin.String using (primStringEquality)
open import Agda.Builtin.Unit using (⊤; tt)
open import Data.Nat using (ℕ)
open import Data.Nat.Show using (show)
open import Data.String using (String; _++_)
open import Data.List using (List; []; _∷_)
open import Data.Product using (_×_; _,_)
open import Data.Bool using (if_then_else_)

open import Agdelte.Core.Result using (Result; ok; err)
open import Agdelte.Core.Cmd using (Cmd; httpGetH; httpPostH)
open import Agdelte.Json using (Decoder; string; bool; field′; decodeString; andThen; succeed)
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

------------------------------------------------------------------------
-- Request plumbing
------------------------------------------------------------------------

private
  authHdr : String → List (String × String)
  authHdr j = if primStringEquality j "" then [] else ("Authorization" , "Bearer " ++ j) ∷ []

  postJson : ∀ {A M : Set} → Cfg → String → String → Decoder A → (Result CallErr A → M) → Cmd M
  postJson cfg path body dec k =
    httpPostH (base cfg ++ path) (authHdr (jwt cfg)) body
              (λ r → k (envelope dec r)) (λ r → k (err (httpErr r)))

  getJson : ∀ {A M : Set} → Cfg → String → Decoder A → (Result CallErr A → M) → Cmd M
  getJson cfg path dec k =
    httpGetH (base cfg ++ path) (authHdr (jwt cfg))
             (λ r → k (envelope dec r)) (λ r → k (err (httpErr r)))

  bySubjectBody : ℕ → String
  bySubjectBody s = "{\"subject\":" ++ show s ++ "}"

------------------------------------------------------------------------
-- Auth (login → JWT; live server envelopes it like everything else: {"data":{"token":…}} —
-- caught by the Ф4.1 live smoke, the original Ф1.1 decoder expected a bare {"token":…})
------------------------------------------------------------------------

-- ⚠ body is not JSON-escaped yet (Ф1): fine for typical login/password; add an escaper if values
-- may contain `"` or `\`.
login : ∀ {M : Set} → Cfg → (login password : String) → (Result CallErr String → M) → Cmd M
login cfg lg pw k =
  httpPostH (base cfg ++ "/auth/login") []
            ("{\"login\":\"" ++ lg ++ "\",\"password\":\"" ++ pw ++ "\"}")
            (λ r → k (envelope (field′ "token" string) r)) (λ r → k (err (httpErr r)))

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
              ("{\"identity_channel\":\"" ++ v1channel c ++ "\",\"identity_id\":\"" ++ v1id c
                ++ "\"" ++ extra ++ "}")
              (λ r → k (envelope dec r)) (λ r → k (err (httpErr r)))

-- Ф3.1: content of followed authors, newest-first; locked rows are stripped teasers.
feed : ∀ {M : Set} → V1Cfg → (Result CallErr (List ContentView) → M) → Cmd M
feed c = postV1 c "/v1/feed" "" contentListDec

-- Ф3.2: pre-ordered conversation under a root (depth 0 = root, children createdAt-asc).
thread : ∀ {M : Set} → V1Cfg → (root : ℕ) → (Result CallErr (List ThreadNodeView) → M) → Cmd M
thread c root = postV1 c "/v1/thread" (",\"root\":" ++ show root) threadListDec

-- Ф3.3: curated showcase window at `from` (feed-shaped rows, rank-ordered server-side).
showcase : ∀ {M : Set} → V1Cfg → (from : ℕ) → (Result CallErr (List ContentView) → M) → Cmd M
showcase c from = postV1 c "/v1/showcase" (",\"from\":" ++ show from) contentListDec

-- Ф3.4: paywall — the live offering list, and purchase-start. The server records a PENDING
-- payment at ITS price (the client never sends an amount); success arrives via the provider
-- webhook (/payments/succeed), after which the entitlement unlocks content on the next read.
offeringsV1 : ∀ {M : Set} → V1Cfg → (Result CallErr (List OfferingView) → M) → Cmd M
offeringsV1 c = postV1 c "/v1/offerings" "" offeringListDec

purchase : ∀ {M : Set} → V1Cfg → (offering : ℕ) (extId : String) → (Result CallErr ℕ → M) → Cmd M
purchase c off ext =
  postV1 c "/v1/purchase" (",\"offering\":" ++ show off ++ ",\"ext_id\":\"" ++ ext ++ "\"") idDec

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
              (λ r → k (envelopeUnit r)) (λ r → k (err (httpErr r)))

-- Ф2.4: re-derive a subject's ACTIVE hypotheses from its event log.
rebuildInference : ∀ {M : Set} → Cfg → ℕ → (Result CallErr ⊤ → M) → Cmd M
rebuildInference cfg sid = postUnit cfg "/knowledge/rebuild-inference" (bySubjectBody sid)

-- Ф2.3: revise a knowledge unit. `kind` ∈ confirm|refute|supersede (param-free), or
-- strengthen|weaken (server reads "amount") / redetail (server reads "detail"). This form covers
-- the param-free moves; a richer overload can add amount/detail when the notebook needs them.
reviseKnowledge : ∀ {M : Set} → Cfg → (knowledge : ℕ) (kind : String) → (Result CallErr ⊤ → M) → Cmd M
reviseKnowledge cfg kid kind =
  postUnit cfg "/knowledge/revise" ("{\"knowledge\":" ++ show kid ++ ",\"kind\":\"" ++ kind ++ "\"}")
