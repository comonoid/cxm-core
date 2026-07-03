{-# OPTIONS --without-K --guardedness #-}

-- IO-inclusive umbrella: the pure core (Cxm.All) plus every module that touches IO and thus
-- needs --guardedness (the WAL backend now; the headless Api in Phase 8). Kept separate from
-- Cxm.All so the pure-core typecheck target stays --without-K only (convention: --guardedness
-- only where IO). `agda Cxm/AllIO.agda` typechecks EVERYTHING.
module Cxm.AllIO where

open import Cxm.All
open import Cxm.Store.Wal
open import Cxm.Api
open import Cxm.Worker
