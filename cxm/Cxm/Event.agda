{-# OPTIONS --without-K #-}

-- `ExperienceEvent` — the canonical event (cxm-plan.md Phase 3, description §4.5, principle 4).
-- The SINGLE entry of facts into the system: append-only, immutable, the source of truth.
-- Everything from any channel normalizes into this envelope; inference builds projections
-- from it. There is NO Del semantics at the domain level (append-only — §8.3).
--
-- Distinguish the THREE logs (§8.2): (1) ExperienceEvent — the semantic event-sourcing
-- substrate (this module); (2) the domain bus `Event`/Outbox (Cxm.Bus) — transactional
-- outbox for consumers; (3) op-log WAL (Cxm.Store, Phase 5) — store-level durability. Not
-- the same thing.
--
-- Time is from IO: `eeTimestamp` is supplied at the boundary (§1); the core reads no clock.
module Cxm.Event where

open import Data.Nat using (ℕ)
open import Data.String using (String)
open import Data.Maybe using (Maybe)
open import Data.Bool using (Bool)

open import Cxm.Tenant using (TenantId)
open import Cxm.Num using (Sentiment)

------------------------------------------------------------------------
-- Enums (§4.5). Extensible sets — packs map their channels/types to the nearest.
------------------------------------------------------------------------

-- The channel the experience arrived through. (Distinct from Identity.iChannel, which
-- tags an identifier kind like "cookie"/"email".)
data Channel : Set where
  Web      : Channel
  Mobile   : Channel
  Chat     : Channel
  Email    : Channel
  Phone    : Channel
  Product  : Channel            -- product telemetry (feature use)
  Internal : Channel            -- internal-loop channel (§4.14)
  Integration : Channel         -- an integrated external site/app via the public /v1 API (§7.7):
                                -- omnichannel treats a headless integration as just another channel
  Community   : Channel         -- the community space (peer loop, слой IX): forum/chat/events
                                -- where clients co-produce each other's experience

-- Who acted.
data Actor : Set where
  Client          : Actor
  Staff           : Actor
  System          : Actor
  InternalSubject : Actor       -- an INTERNAL subject (dept/team), §4.14
  Peer            : Actor       -- another client (peer loop §0.6): the event happens in our
                                -- venue but not by our hand

-- The kind of experience. Folds in the Concept's "moments of truth"/"feature requests"/
-- "value realization" as types + annotations, not separate entities (§4.19).
data EventType : Set where
  View            : EventType
  Purchase        : EventType
  TicketOpen      : EventType
  FeatureUse      : EventType   -- + `eeEffort` → value realization / friction (§4.19)
  FeatureRequest  : EventType   -- window into unmet goals (§4.19)
  InternalHandoff : EventType   -- handoff between INTERNAL subjects (§4.14)
  LifecycleChange : EventType   -- an Episode state transition (§4.9); logged by transitionEpisode
  -- clearing journal (Concept Ч.2 §3, upgrade-план A2): the lifecycle of a TRADEABLE promise,
  -- logged in the same append-only stream — the log doubles as the clearing journal.
  PromiseDeclared    : EventType   -- П6: a controllable obligation was created (the HEAD of the
                                   -- pair — its resolution PromiseSettled/Defaulted is the tail;
                                   -- so the append-only log carries the full life of a promise)
  PromiseListed      : EventType   -- offered for transfer
  PromiseTransferred : EventType   -- holder changed
  PromiseSettled     : EventType   -- honoured
  PromiseDefaulted   : EventType   -- broken (no-show / non-payment)
  -- social content loop (§7.3, cxm-social-plan): publishing and peer reactions are ordinary
  -- experience events — the feed and contribution folds read them like everything else.
  Publish            : EventType   -- a subject published a Resource (payload: {"resource":id})
  Reaction           : EventType   -- a peer reacted to content (counterpart = the author)

------------------------------------------------------------------------
-- ExperienceEvent — [СОБ] source of truth
------------------------------------------------------------------------

record ExperienceEvent : Set where
  constructor mkExperienceEvent
  field
    eeId             : ℕ            -- event_id (primary key)
    eeSubject        : ℕ            -- subject_id (after identity resolution; may be provisional §4.4)
    eeTenant         : TenantId     -- §7.1 tenant axis
    eeChannel        : Channel
    eeActor          : Actor
    eeTimestamp      : ℕ            -- unix seconds (from IO, §1)
    eeType           : EventType
    eeLifecycleStage : ℕ            -- config-driven lifecycle stage id (differences are data, §9)
    eeEpisode        : Maybe ℕ      -- FK → episode this belongs to (§4.9); nothing = none
    -- experience annotations — what a plain CRM lacks:
    eeSentiment      : Maybe Sentiment  -- offset −1..1 (Cxm.Num); nothing = not annotated
    eeEmotion        : Maybe String     -- opaque emotion label; edge-defined
    eeEffort         : Maybe ℕ          -- effort score; nothing = not annotated
    eeIsPeak         : Bool             -- memory marker (peak) — principle 0.3
    eeIsEnd          : Bool             -- memory marker (end)
    eePayload        : String           -- type-specific opaque JSON (core does not index it, §8.1)
    eeCounterpart    : Maybe ℕ          -- the SECOND subject of a peer event (§0.6 / слой IX):
                                        -- both sides external, our role is the venue; nothing =
                                        -- an ordinary one-subject event

open ExperienceEvent public
