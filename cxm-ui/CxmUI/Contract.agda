{-# OPTIONS --without-K #-}

-- CxmUI.Contract — the typed CXM API contract on the CLIENT side: response record types +
-- JSON decoders that mirror, field-for-field, the encoders in `Cxm.Api` on the server. This is
-- the highest-value shared piece of cxm-ui: the wire contract encoded ONCE, so every site binds
-- the same shapes and contract drift is caught by the decoder round-trip tests (test/contract.test.mjs
-- decodes REAL cxm-server output). Decoders are FFI (Agdelte.Json postulates) — they run in JS,
-- so they are tested at the JS-runtime layer, not by refl (a postulate cannot reduce).
--
-- These decoders RUN under --js (test/contract.test.mjs: 9/9 against real cxm-server JSON). This
-- required an agdelte fix (2026-07-03): the `Agdelte.Json` decoder combinators take `∀ {A : Set}`
-- type-implicits which the --js backend does NOT drop (unlike GHC; `@0`-erasure doesn't help) — it
-- passes `null` in that slot, so the `COMPILE JS` impls now accept a leading type-slot per implicit.
-- We build with `andThen`/`succeed` (NOT the point-free `_<$>_`/`_<*>_`, which forward the type
-- args into their FFI target and crash regardless).
module CxmUI.Contract where

open import Agda.Builtin.String using (primStringEquality)
open import Data.Nat using (ℕ)
open import Data.String using (String)
open import Data.Bool using (Bool; if_then_else_)
open import Data.List using (List)
open import Data.Maybe using (Maybe; just; nothing)

open import Agdelte.Core.Result using (Result; ok; err)
open import Agdelte.Json using (Decoder; string; nat; bool; field′; optionalField; list;
                                andThen; succeed; fail; decodeString)

private
  -- monadic bind for decoders (NOT point-free, so the compiled wrapper maps arg positions and
  -- calls the `andThen` postulate correctly under --js).
  _>>=_ : ∀ {A B : Set} → Decoder A → (A → Decoder B) → Decoder B
  d >>= f = andThen f d
  infixl 1 _>>=_

------------------------------------------------------------------------
-- Knowledge (POST /knowledge/by-subject, /relationship-state/by-subject) — the notebook row
------------------------------------------------------------------------

record KnowledgeView : Set where
  constructor mkKnowledgeView
  field
    kvId         : ℕ
    kvSubject    : ℕ
    kvType       : String   -- fact | hypothesis | state | trait
    kvSource     : String   -- observed | inferred | stated | imported
    kvConfidence : ℕ        -- 0..1000 (now-decayed on read, Д5)
    kvValidFrom  : ℕ
    kvValidTo    : ℕ        -- 0 = open-ended
    kvDecay      : ℕ
    kvStatus     : String   -- active | confirmed | refuted | superseded
    kvDetail     : String   -- opaque subvariant JSON (e.g. convincer params)
    kvEpisode    : ℕ        -- 0 = subject-level

open KnowledgeView public

knowledgeDec : Decoder KnowledgeView
knowledgeDec =
  field′ "id" nat          >>= λ i →
  field′ "subject" nat     >>= λ s →
  field′ "type" string     >>= λ t →
  field′ "source" string   >>= λ src →
  field′ "confidence" nat  >>= λ c →
  field′ "validFrom" nat   >>= λ vf →
  field′ "validTo" nat     >>= λ vt →
  field′ "decay" nat       >>= λ d →
  field′ "status" string   >>= λ st →
  field′ "detail" string   >>= λ dt →
  field′ "episode" nat     >>= λ ep →
  succeed (mkKnowledgeView i s t src c vf vt d st dt ep)

knowledgeListDec : Decoder (List KnowledgeView)
knowledgeListDec = list knowledgeDec

------------------------------------------------------------------------
-- Expectation (POST /expectations/by-subject) — layer-II bar + gap status
------------------------------------------------------------------------

record ExpectationView : Set where
  constructor mkExpectationView
  field
    xvId        : ℕ
    xvSubject   : ℕ
    xvTopic     : String
    xvSource    : String   -- our_promise | competitor | industry_norm
    xvLevel     : ℕ
    xvStatus    : String   -- met | unmet | unknown  (the gap signal)
    xvCreatedAt : ℕ

open ExpectationView public

expectationDec : Decoder ExpectationView
expectationDec =
  field′ "id" nat        >>= λ i →
  field′ "subject" nat   >>= λ s →
  field′ "topic" string  >>= λ t →
  field′ "source" string >>= λ src →
  field′ "level" nat     >>= λ l →
  field′ "status" string >>= λ st →
  field′ "createdAt" nat >>= λ ca →
  succeed (mkExpectationView i s t src l st ca)

expectationListDec : Decoder (List ExpectationView)
expectationListDec = list expectationDec

------------------------------------------------------------------------
-- Episode (POST /episodes/by-subject, /lines) — a line of work
------------------------------------------------------------------------

record EpisodeView : Set where
  constructor mkEpisodeView
  field
    epvId       : ℕ
    epvSubject  : ℕ
    epvProtocol : ℕ
    epvState    : ℕ
    epvJtbd     : String

open EpisodeView public

episodeDec : Decoder EpisodeView
episodeDec =
  field′ "id" nat       >>= λ i →
  field′ "subject" nat  >>= λ s →
  field′ "protocol" nat >>= λ p →
  field′ "state" nat    >>= λ st →
  field′ "jtbd" string  >>= λ j →
  succeed (mkEpisodeView i s p st j)

episodeListDec : Decoder (List EpisodeView)
episodeListDec = list episodeDec

------------------------------------------------------------------------
-- Evidence (POST /knowledge/evidence/by-knowledge) — the explainability chain: WHY the system
-- holds a knowledge unit (which events back it). Fed by the notebook's «🔎 почему».
------------------------------------------------------------------------

record EvidenceView : Set where
  constructor mkEvidenceView
  field
    edvId           : ℕ
    edvKnowledge    : ℕ
    edvEvent        : ℕ
    edvCreatedAt    : ℕ
    edvEventAt      : ℕ        -- the backing event's timestamp (0 = event gone)
    edvEventPayload : String   -- the backing event's opaque payload ("" = event gone)

open EvidenceView public

evidenceDec : Decoder EvidenceView
evidenceDec =
  field′ "id" nat             >>= λ i →
  field′ "knowledge" nat      >>= λ k →
  field′ "event" nat          >>= λ e →
  field′ "createdAt" nat      >>= λ ca →
  field′ "eventAt" nat        >>= λ ea →
  field′ "eventPayload" string >>= λ ep →
  succeed (mkEvidenceView i k e ca ea ep)

evidenceListDec : Decoder (List EvidenceView)
evidenceListDec = list evidenceDec

------------------------------------------------------------------------
-- Health (GET /health) — liveness + CONTRACT VERSION (аудит-5 №4). The one response that is
-- NOT data-enveloped. `expectedContract` is what THIS cxm-ui build binds; a site compares it
-- with hContract at mount and screams on skew (server bumps its contractVersion on any
-- encoder/route shape change — the discipline lives in the server route's header comment).
------------------------------------------------------------------------

expectedContract : ℕ
expectedContract = 1

record HealthView : Set where
  constructor mkHealthView
  field
    hOk       : Bool
    hBackend  : String
    hContract : ℕ
open HealthView public

healthDec : Decoder HealthView
healthDec =
  field′ "ok" bool         >>= λ o →
  field′ "backend" string  >>= λ b →
  field′ "contract" nat    >>= λ c →
  succeed (mkHealthView o b c)

------------------------------------------------------------------------
-- Integration tokens (GET /integration-tokens) — the owner's token list (аудит-4 №3)
------------------------------------------------------------------------

record IntTokenView : Set where
  constructor mkIntTokenView
  field
    itId      : ℕ
    itScope   : String
    itRevoked : Bool
open IntTokenView public

intTokenDec : Decoder IntTokenView
intTokenDec =
  field′ "id" nat        >>= λ i →
  field′ "scope" string  >>= λ s →
  field′ "revoked" bool  >>= λ r →
  succeed (mkIntTokenView i s r)

intTokenListDec : Decoder (List IntTokenView)
intTokenListDec = list intTokenDec

------------------------------------------------------------------------
-- Outbox (GET /outbox) — the operator's delivery ops-view (pending/sent/failed mail)
------------------------------------------------------------------------

record OutboxView : Set where
  constructor mkOutboxView
  field
    ovId     : ℕ
    ovTo     : String
    ovStatus : String   -- pending | sent | failed
open OutboxView public

outboxDec : Decoder OutboxView
outboxDec =
  field′ "id" nat       >>= λ i →
  field′ "to" string    >>= λ t →
  field′ "status" string >>= λ st →
  succeed (mkOutboxView i t st)

outboxListDec : Decoder (List OutboxView)
outboxListDec = list outboxDec

------------------------------------------------------------------------
-- Roster (GET /subjects) — the THIN list view (id + name; server projects just these).
-- A rich subject-detail view returns when the server grows that read (Ф0.4.4).
-- NB (аудит №8, 2026-07-07): ProfileView/ExperienceView/SubjectView удалены — их роутов на
-- pg-сервере НЕТ (фикстуры были WAL-эры); вернуть вместе с реальными читалками.
------------------------------------------------------------------------

record RosterView : Set where
  constructor mkRosterView
  field rvId : ℕ ; rvName : String
open RosterView public

rosterDec : Decoder RosterView
rosterDec = field′ "id" nat >>= λ i → field′ "name" string >>= λ n → succeed (mkRosterView i n)

rosterListDec : Decoder (List RosterView)
rosterListDec = list rosterDec

------------------------------------------------------------------------
-- Appointment (POST /appointments/by-subject) — booking row for the client card
------------------------------------------------------------------------

record AppointmentView : Set where
  constructor mkAppointmentView
  field
    avId       : ℕ
    avStart    : ℕ
    avDuration : ℕ
    avStatus   : String   -- scheduled | canceled | completed | noshow
open AppointmentView public

appointmentDec : Decoder AppointmentView
appointmentDec =
  field′ "id" nat       >>= λ i →
  field′ "start" nat    >>= λ s →
  field′ "duration" nat >>= λ d →
  field′ "status" string >>= λ st →
  succeed (mkAppointmentView i s d st)

appointmentListDec : Decoder (List AppointmentView)
appointmentListDec = list appointmentDec

------------------------------------------------------------------------
-- Social reads (/v1/feed, /v1/thread, /v1/showcase — Ф1.3). Rows mirror the server's cvEnc/tvEnc:
-- author 0 = none; locked = listed-but-not-readable teaser (payload comes STRIPPED to "").
-- Showcase rows share the feed shape (cvEnc). payload is the author's opaque JSON.
--
-- PAGINATION CONTRACT (аудит-2 №14): the readers accept an optional `limit` (0 = всё) meaning
-- "the top N" of the server ordering (newest-first / rank-asc). This is a SILENT cap — no
-- hasMore/total comes back yet. Real pagination (cursor + continuation flag) is a deliberate
-- follow-up contract; until then sites must treat `limit` as "показать верхушку", not as a page.
------------------------------------------------------------------------

record ContentView : Set where
  constructor mkContentView
  field
    cnId         : ℕ
    cnAuthor     : ℕ        -- 0 = none
    cnAuthorName : String   -- display name, server-joined ("" = none/erased) — аудит-4 №2
    cnCreatedAt  : ℕ
    cnLocked     : Bool     -- true → teaser: payload = ""
    cnPayload    : String   -- opaque author JSON ("" when locked)
open ContentView public

contentDec : Decoder ContentView
contentDec =
  field′ "id" nat            >>= λ i →
  field′ "author" nat        >>= λ a →
  field′ "authorName" string >>= λ an →
  field′ "createdAt" nat     >>= λ ca →
  field′ "locked" bool       >>= λ l →
  field′ "payload" string    >>= λ p →
  succeed (mkContentView i a an ca l p)

contentListDec : Decoder (List ContentView)
contentListDec = list contentDec

record ThreadNodeView : Set where
  constructor mkThreadNodeView
  field
    tnDepth   : ℕ           -- 0 = root; children pre-ordered, createdAt-asc
    tnContent : ContentView
open ThreadNodeView public

threadNodeDec : Decoder ThreadNodeView
threadNodeDec =
  field′ "depth" nat >>= λ d →
  contentDec         >>= λ c →
  succeed (mkThreadNodeView d c)

threadListDec : Decoder (List ThreadNodeView)
threadListDec = list threadNodeDec

------------------------------------------------------------------------
-- Offering (/v1/offerings — Ф3.4 paywall). price is MINOR units (kopecks); metadata is the
-- server-side fulfilment plan (grants-as-data: {"grants":[{"kind":"resource","id":N}]}) — exposed
-- so a site can match an offering to the node it unlocks; possession grants nothing.
------------------------------------------------------------------------

record OfferingView : Set where
  constructor mkOfferingView
  field
    ofId       : ℕ
    ofKind     : ℕ
    ofPrice    : ℕ        -- minor units
    ofCurrency : String
    ofMetadata : String   -- fulfilment plan JSON (opaque to this layer)
open OfferingView public

offeringDec : Decoder OfferingView
offeringDec =
  field′ "id" nat          >>= λ i →
  field′ "kind" nat        >>= λ k →
  field′ "price" nat       >>= λ p →
  field′ "currency" string >>= λ c →
  field′ "metadata" string >>= λ md →
  succeed (mkOfferingView i k p c md)

offeringListDec : Decoder (List OfferingView)
offeringListDec = list offeringDec

-- write-responses of the {"data":{"id":N}} shape (/v1/purchase and every idJson route)
idDec : Decoder ℕ
idDec = field′ "id" nat

------------------------------------------------------------------------
-- Work strategy (panel VIII.a, Ф2.5) — the CONVENTION decoder for `kvDetail` of a work-strategy
-- TRAIT (Cxm.Knowledge header, upgrade-план C2): kDetail = {"kind":"work_strategy","sync":…,
-- "detail_first":…,"handoff_complete_when":…}. The core keeps kDetail opaque (§8.1) and there is
-- no server encoder — the string is operator-authored and stored verbatim — so THIS decoder is
-- where the convention becomes typed. All parameters are optional (a bare
-- {"kind":"work_strategy"} is a valid, empty strategy); an alien `kind` (e.g. a convincer) or
-- non-JSON detail must NOT parse — the kind gate is the discriminator.
------------------------------------------------------------------------

record WorkStrategyView : Set where
  constructor mkWorkStrategyView
  field
    wsSync        : Maybe Bool     -- just true = синхронно, just false = асинхронно
    wsDetailFirst : Maybe Bool     -- just true = сначала детали, just false = сначала картина
    wsHandoff     : Maybe String   -- handoff_complete_when: что делает хэндофф «полным»
open WorkStrategyView public

workStrategyDec : Decoder WorkStrategyView
workStrategyDec =
  field′ "kind" string >>= λ kind →
  if primStringEquality kind "work_strategy"
    then ( optionalField "sync" bool                    >>= λ sy →
           optionalField "detail_first" bool            >>= λ df →
           optionalField "handoff_complete_when" string >>= λ ho →
           succeed (mkWorkStrategyView sy df ho) )
    else fail "kDetail kind is not work_strategy"

-- The pure entry the panel (and tests) use: opaque kDetail string → Maybe strategy.
parseWorkStrategy : String → Maybe WorkStrategyView
parseWorkStrategy s with decodeString workStrategyDec s
... | ok w  = just w
... | err _ = nothing
