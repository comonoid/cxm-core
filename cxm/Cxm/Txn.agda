{-# OPTIONS --without-K #-}

-- Cxm.Txn — the CXM transaction monad: a thin instantiation of the generic store monad
-- `Agdelte.Storage.Txn` at the CXM's (Base, CxmOp, Err, apply). All combinators
-- (returnT / _>>=T_ / _>>T_ / getBase / abort / emit / require / requireJust / guardT /
-- forEachT / runTxn) come from there, re-exported so domain commands (Phase 6) and the API
-- (Phase 8) import them from here. `runTxn` yields the exact shape `walTxn` consumes.
--
-- Domain commands do NOT construct `CxmOp` or touch `IndexedMap` directly — they go through
-- the repository seam (Cxm.Store.Interface, principle 11), which is built on these primitives.
module Cxm.Txn where

open import Cxm.Store.Base using (Base; CxmOp; Err; apply)

open import Agdelte.Storage.Txn Base CxmOp Err apply public
