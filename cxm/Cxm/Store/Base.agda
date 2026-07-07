{-# OPTIONS --without-K #-}

-- CXM store vocabulary — the NEUTRAL, backend-agnostic core: the domain error type `Err` and
-- the secondary-index POSITION constants (a typed-name layer over the ℕ index positions each
-- Wire schema declares). Both are shared by every store interpreter (pure test handler,
-- Postgres exec). Zero dependency on any concrete backend.
--
-- HISTORY: this module used to also carry the WAL in-memory backend (`Base` record + `CxmOp`
-- + `apply` over IndexedMap). That backend — the abandoned WAL experiment — was removed when
-- the store went Postgres-only (2026-07-07); only the neutral vocabulary remains.
module Cxm.Store.Base where

open import Data.Nat using (ℕ)
open import Data.String using (String)

------------------------------------------------------------------------
-- Secondary-index positions (typed-name layer over the ℕ positions). These MUST match the
-- order of idxCol columns in each Wire schema (see the per-record notes there) and are the
-- keys the verb interpreters pass to byIx / rByIndex.
------------------------------------------------------------------------

subjByTenant    : ℕ
subjByTenant    = 0
subjByCanonical : ℕ
subjByCanonical = 1
edgeByFrom      : ℕ
edgeByFrom      = 0
edgeByTo        : ℕ
edgeByTo        = 1
edgeByKind      : ℕ
edgeByKind      = 2
identBySubject  : ℕ
identBySubject  = 0
identByTenant   : ℕ
identByTenant   = 1
intTokenByTenant : ℕ
intTokenByTenant = 0
eventBySubject  : ℕ
eventBySubject  = 0
eventByEpisode  : ℕ
eventByEpisode  = 1
busByProcessed  : ℕ
busByProcessed  = 0
outByStatus     : ℕ
outByStatus     = 0
knowBySubject   : ℕ
knowBySubject   = 0
evdByKnowledge  : ℕ
evdByKnowledge  = 0
evdByEvent      : ℕ
evdByEvent      = 1
trByEpisode     : ℕ
trByEpisode     = 0
dvByEpisode     : ℕ
dvByEpisode     = 0
psByProtocol    : ℕ
psByProtocol    = 0
ptByProtocol    : ℕ
ptByProtocol    = 0
offeringByTenant : ℕ
offeringByTenant = 0
resByParent     : ℕ
resByParent     = 0
entBySubject    : ℕ
entBySubject    = 0
paymentBySubject : ℕ
paymentBySubject = 0
expBySubject    : ℕ
expBySubject    = 0
promBySubject   : ℕ
promBySubject   = 0
promByStatus    : ℕ
promByStatus    = 1
protoByTenant   : ℕ
protoByTenant   = 0
epBySubject     : ℕ
epBySubject     = 0
epByProtocol    : ℕ
epByProtocol    = 1
apptBySubject   : ℕ
apptBySubject   = 0
apptByResource  : ℕ
apptByResource  = 1
apptByEpisode   : ℕ
apptByEpisode   = 2
rlByFrom        : ℕ
rlByFrom        = 0
mByResource     : ℕ
mByResource     = 0
mBySubject      : ℕ
mBySubject      = 1

------------------------------------------------------------------------
-- Errors (domain outcome type; shared by every interpreter)
------------------------------------------------------------------------

data Err : Set where
  NotFound          : Err
  Conflict          : Err
  Insufficient      : Err
  InvalidTransition : Err
  Forbidden         : Err
  Invariant         : String → Err
