{-# OPTIONS --without-K #-}

-- CxmUI.Client — typed API client over cxm-server-pg (frontend layer 2). Each call builds the
-- HTTP request (url + Bearer + body) and decodes the {"data":…} / {"error":…} envelope into a
-- `Result CallErr <View>`, handed to the caller's message continuation `(… → M) → Cmd M`.
-- Request bodies are built as strings (no encoder FFI needed). Talks HTTP/JSON ONLY — no
-- dependency on the Agda `cxm` core. Views + decoders come from CxmUI.Contract.
module CxmUI.Client where

open import Agda.Builtin.String using (primStringEquality)
open import Data.Nat using (ℕ)
open import Data.Nat.Show using (show)
open import Data.String using (String; _++_)
open import Data.List using (List; []; _∷_)
open import Data.Product using (_×_; _,_)
open import Data.Bool using (if_then_else_)

open import Agdelte.Core.Result using (Result; ok; err)
open import Agdelte.Core.Cmd using (Cmd; httpGetH; httpPostH)
open import Agdelte.Json using (Decoder; string; field′; decodeString; andThen; succeed)
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
-- Auth (login → JWT; server returns {"token":…}, NOT enveloped)
------------------------------------------------------------------------

-- ⚠ body is not JSON-escaped yet (Ф1): fine for typical login/password; add an escaper if values
-- may contain `"` or `\`.
login : ∀ {M : Set} → Cfg → (login password : String) → (Result CallErr String → M) → Cmd M
login cfg lg pw k =
  httpPostH (base cfg ++ "/auth/login") []
            ("{\"login\":\"" ++ lg ++ "\",\"password\":\"" ++ pw ++ "\"}")
            (λ r → k (tokenOf r)) (λ r → k (err (httpErr r)))
  where
    tokenOf : String → Result CallErr String
    tokenOf r with decodeString (field′ "token" string) r
    ... | ok t  = ok t
    ... | err _ with decodeString (field′ "error" errDec) r
    ...   | ok e  = err (serverErr e)
    ...   | err m = err (decodeErr m)

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
