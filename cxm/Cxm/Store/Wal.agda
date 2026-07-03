{-# OPTIONS --without-K --guardedness #-}

-- The WAL backend (cxm-plan.md Phase 5, §9.3): the concrete implementation of the
-- repository seam over agdelte-store's WAL (WAL-only, in-memory state, replay-on-open —
-- ADR 0001). `CxmOp` is an INTERNAL detail here (§9.5): callers use Cxm.Txn + the
-- Cxm.Store.Interface vocabulary; this module only wires those into durable IO.
--
-- This is the only Store module that touches IO, hence `--guardedness` (convention). A
-- future Postgres backend (§8.7) is a SECOND module like this one — same `Txn`/`runTxn`
-- write path, a `BEGIN…COMMIT` instead of a WAL append — with the domain code unchanged.
module Cxm.Store.Wal where

open import Agda.Builtin.IO using (IO)
open import Agda.Builtin.String using (String)
open import Data.Sum using (_⊎_)

open import Agdelte.Storage.WAL using (WalConfig; mkWalConfig; walOpen; walRead; walTxn)

open import Cxm.Store.Base using (Base; CxmOp; Err; apply; emptyBase)
open import Cxm.Store.Codec using (encodeOp; decodeOp)
open import Cxm.Txn using (Txn; runTxn)

-- re-export the handle + outcome types so callers pattern-match without importing WAL directly
open import Agdelte.Storage.WAL public using (WalHandle; WalOutcome; committed; rejected; ioFailed)

------------------------------------------------------------------------
-- Config + lifecycle
------------------------------------------------------------------------

-- One WAL config for the whole core: the schema-derived codec (Cxm.Store.Codec) is both the
-- serializer and deserializer, `apply` is the replayed transition, `emptyBase` the replay
-- origin — so `live ≡ replay` by construction (the WAL replays the SAME apply).
cxmWalConfig : String → WalConfig Base CxmOp
cxmWalConfig path = mkWalConfig path apply encodeOp decodeOp emptyBase

-- open (or recover) the store: replays the log from emptyBase; refuses to start on corruption
openStore : String → IO (WalHandle Base CxmOp)
openStore path = walOpen (cxmWalConfig path)

-- non-exclusive snapshot of the current Base (the read path for queries/projections)
readBase : WalHandle Base CxmOp → IO Base
readBase h = walRead h

------------------------------------------------------------------------
-- commitTxn — the seam's write path (§8.7): run a Txn, durably append its ops, publish.
-- Returns committed a | rejected e | ioFailed (state untouched on the latter two).
------------------------------------------------------------------------

commitTxn : ∀ {A} → WalHandle Base CxmOp → Txn A → IO (WalOutcome Err A)
commitTxn h tx = walTxn h (runTxn tx)
