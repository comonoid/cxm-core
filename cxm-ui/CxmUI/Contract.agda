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
-- Profile (POST /profile) — the aggregate card header
------------------------------------------------------------------------

record ProfileView : Set where
  constructor mkProfileView
  field
    pvSubject         : ℕ
    pvActiveKnowledge : ℕ
    pvActiveEpisodes  : ℕ
    pvEventCount      : ℕ

open ProfileView public

profileDec : Decoder ProfileView
profileDec =
  field′ "subject" nat         >>= λ s →
  field′ "activeKnowledge" nat >>= λ ak →
  field′ "activeEpisodes" nat  >>= λ ae →
  field′ "eventCount" nat      >>= λ ec →
  succeed (mkProfileView s ak ae ec)

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
-- Experience event (POST /experience-events/by-subject) — the touch/effort/peak stream
------------------------------------------------------------------------

record ExperienceView : Set where
  constructor mkExperienceView
  field
    evId          : ℕ
    evSubject     : ℕ
    evCounterpart : ℕ
    evChannel     : String
    evActor       : String
    evType        : String
    evTimestamp   : ℕ
    evEpisode     : ℕ
    evIsPeak      : Bool
    evIsEnd       : Bool

open ExperienceView public

experienceDec : Decoder ExperienceView
experienceDec =
  field′ "id" nat           >>= λ i →
  field′ "subject" nat      >>= λ s →
  field′ "counterpart" nat  >>= λ cp →
  field′ "channel" string   >>= λ ch →
  field′ "actor" string     >>= λ ac →
  field′ "type" string      >>= λ t →
  field′ "timestamp" nat    >>= λ ts →
  field′ "episode" nat      >>= λ ep →
  field′ "isPeak" bool      >>= λ pk →
  field′ "isEnd" bool       >>= λ en →
  succeed (mkExperienceView i s cp ch ac t ts ep pk en)

experienceListDec : Decoder (List ExperienceView)
experienceListDec = list experienceDec

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
-- Evidence (POST /knowledge/evidence/by-knowledge) — the explainability chain
------------------------------------------------------------------------

record EvidenceView : Set where
  constructor mkEvidenceView
  field
    edvId        : ℕ
    edvKnowledge : ℕ
    edvEvent     : ℕ
    edvCreatedAt : ℕ

open EvidenceView public

evidenceDec : Decoder EvidenceView
evidenceDec =
  field′ "id" nat        >>= λ i →
  field′ "knowledge" nat >>= λ k →
  field′ "event" nat     >>= λ e →
  field′ "createdAt" nat >>= λ ca →
  succeed (mkEvidenceView i k e ca)

evidenceListDec : Decoder (List EvidenceView)
evidenceListDec = list evidenceDec

------------------------------------------------------------------------
-- Subject (GET /subjects) — the client roster row
------------------------------------------------------------------------

record SubjectView : Set where
  constructor mkSubjectView
  field
    svId          : ℕ
    svName        : String
    svEmail       : String
    svTenant      : ℕ
    svProvisional : Bool

open SubjectView public

subjectDec : Decoder SubjectView
subjectDec =
  field′ "id" nat          >>= λ i →
  field′ "name" string     >>= λ n →
  field′ "email" string    >>= λ e →
  field′ "tenant" nat      >>= λ t →
  field′ "provisional" bool >>= λ pr →
  succeed (mkSubjectView i n e t pr)

subjectListDec : Decoder (List SubjectView)
subjectListDec = list subjectDec

------------------------------------------------------------------------
-- Roster (GET /subjects) — the THIN list view (id + name; server projects just these).
-- The full SubjectView above is for a future subject-detail read (Ф0.4.4).
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
------------------------------------------------------------------------

record ContentView : Set where
  constructor mkContentView
  field
    cnId        : ℕ
    cnAuthor    : ℕ        -- 0 = none
    cnCreatedAt : ℕ
    cnLocked    : Bool     -- true → teaser: payload = ""
    cnPayload   : String   -- opaque author JSON ("" when locked)
open ContentView public

contentDec : Decoder ContentView
contentDec =
  field′ "id" nat         >>= λ i →
  field′ "author" nat     >>= λ a →
  field′ "createdAt" nat  >>= λ ca →
  field′ "locked" bool    >>= λ l →
  field′ "payload" string >>= λ p →
  succeed (mkContentView i a ca l p)

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
