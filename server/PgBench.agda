{-# OPTIONS --without-K --guardedness #-}

-- pg-bench — chattiness measurement (pg-store-plan A6). For a battery of representative commands
-- (cheap → expensive), measures on LIVE Postgres:
--   • round-trips  — SQL statements per atom (BEGIN + verbs + COMMIT), counted in the driver seam
--                    (Agdelte.Storage.PgConn.pgStmtCount/pgStmtReset). This is the pure chattiness
--                    number the driver-v2 decision hangs on: it does NOT include the physical
--                    connect (newPool bypasses execConn/queryConn), so it is transport-agnostic.
--   • wall-clock   — median of R runs, monotonic ns. This DOES include the v1 connect-per-txn
--                    overhead (a fresh 1-conn pool per atom) — the gap between it and round-trips×RTT
--                    is exactly what a persistent-conn driver (v2) would recover.
--
--   env CXM_PG (default host=127.0.0.1 dbname=agdelte user=agdelte)
--
-- ⚠ DESTRUCTIVE on the target database: applies genesis DDL, then TRUNCATEs all cxm tables and
-- resets cxm_id_seq before EVERY measured run. Point it at a scratch database only.
module PgBench where

open import Agda.Builtin.IO using (IO)
open import Agda.Builtin.Unit using (⊤; tt)
open import Agda.Builtin.String using (String)
open import Data.Bool using (Bool; true; false; if_then_else_)
open import Data.List using (List; []; _∷_; map; length; concat; foldr)
open import Data.Maybe using (Maybe; just; nothing; maybe′)
open import Data.Nat using (ℕ; suc; _+_; _*_; _∸_; _≡ᵇ_; _<ᵇ_; _/_; _%_)
open import Data.Nat.Show using (show)
open import Data.Product using (_×_; _,_)
open import Data.Sum using (_⊎_; inj₁; inj₂)
open import Data.String using () renaming (_++_ to _<>_)

open import Agda.Builtin.Nat using (Nat)

open import Agdelte.FFI.Server using (putStrLn; _>>=_; _>>_; pure; getEnvOr)
open import Agdelte.Storage.Migration using (up)
open import Agdelte.Storage.PgConn using
  (TxRunner; connectPerTxn; withConnRaw; execConn; queryConn; pgStmtCount; pgStmtReset)

open import Cxm.Store.Base using (Err; outByStatus)
open import Cxm.Store.Verbs
open import Cxm.Store.Pg using (runCxmTx)
open import Cxm.Store.Registry using (dumps; dName; cxmHistory)
open import Cxm.CommandsV
open import Cxm.Expectation using (Ours)
open import Cxm.Event using (mkExperienceEvent; Web; Client; View)

------------------------------------------------------------------------
-- Monotonic clock (ns) — GHC.Clock.getMonotonicTimeNSec, transport-independent wall time.
------------------------------------------------------------------------

postulate nowNanos : IO Nat
{-# FOREIGN GHC import qualified GHC.Clock as GClk #-}
{-# COMPILE GHC nowNanos = fmap fromIntegral GClk.getMonotonicTimeNSec #-}

------------------------------------------------------------------------
-- Scenarios: representative atoms, cheap → expensive. Each is ONE runCxmTx (one atom / one txn),
-- run against an empty world so surrogate ids are stable. Return value is discarded (we measure
-- cost, not result — pg-diff already proves correctness).
------------------------------------------------------------------------

private
  -- cheapest: one lock + one read miss path folded into a create.
  bIdentity : Tx ⊤
  bIdentity =
    resolveOrCreateSubjectV "email" "a@x" "Cli" "UTC" 1 7 >>=T λ sid →
    bindIdentityNotifyV sid "email" "a@x" 1 8 "Confirm" (λ n → "v:" <> show n) >>=T λ _ →
    returnT tt

  -- mid: book then cancel (two aggregate touches, slot index probe).
  bBooking : Tx ⊤
  bBooking =
    resolveOrCreateSubjectV "email" "c@x" "Cli" "UTC" 1 7 >>=T λ s →
    bookAppointmentV s 0 nothing nothing 5000 60 1 7 >>=T λ aid →
    cancelAppointmentV aid >>T returnT tt

  -- mid: two-account directed promise + settle (proof-gated stake movement).
  bPromise : Tx ⊤
  bPromise =
    openAccountV 1 0 >>=T λ a1 →
    creditV a1 100 >>T
    openAccountV 1 0 >>=T λ a2 →
    resolveOrCreateSubjectV "email" "d@x" "Cli" "UTC" 1 7 >>=T λ s →
    createPromiseDirectedV s "t" 99 Ours true 30 (just a1) (just a2) true 1 7 >>=T λ pid →
    settlePromiseV pid 1 8 >>T returnT tt

  -- expensive: build a subject with several dependents, then cascade-delete it (the deep path —
  -- lockRoot + fan-out scans + per-row deletes; the worst chattiness offender).
  bCascade : Tx ⊤
  bCascade =
    resolveOrCreateSubjectV "email" "z@x" "Cli" "UTC" 1 7 >>=T λ s →
    bindIdentityNotifyV s "email" "z@x" 1 8 "C" (λ n → "v:" <> show n) >>=T λ _ →
    ingestSiteEventV "email" "z@x" 1 9
      (mkExperienceEvent 0 0 1 Web Client 7 View 0 nothing nothing nothing nothing false false
        "p" nothing) >>=T λ _ →
    bookAppointmentV s 0 nothing nothing 5000 60 1 10 >>=T λ _ →
    cascadeDeleteSubjectV s 1 >>T returnT tt

  scenarios : List (String × Tx ⊤)
  scenarios =
      ("identity-bind-notify" , bIdentity)
    ∷ ("booking-cancel"       , bBooking)
    ∷ ("promise-stake-settle" , bPromise)
    ∷ ("cascade-delete-deep"  , bCascade)
    ∷ []

------------------------------------------------------------------------
-- DB plumbing (mirrors PgDiff: genesis once, TRUNCATE + seq reset per run)
------------------------------------------------------------------------

private
  joinComma : List String → String
  joinComma []           = ""
  joinComma (x ∷ [])     = x
  joinComma (x ∷ y ∷ xs) = x <> "," <> joinComma (y ∷ xs)

  truncStmt : String
  truncStmt = "TRUNCATE " <> joinComma (map (λ d → "\"" <> dName d <> "\"") dumps) <> " CASCADE;"

  sqlEach : _ → List String → IO ⊤
  sqlEach c []         = pure tt
  sqlEach c (st ∷ sts) = execConn c st >>= λ _ → sqlEach c sts

  applyGenesis : String → IO ⊤
  applyGenesis conninfo = withConnRaw conninfo λ c → sqlEach c (concat (map up cxmHistory))

  resetDb : String → IO ⊤
  resetDb conninfo = withConnRaw conninfo λ c →
    execConn c truncStmt >>= λ _ →
    queryConn c "SELECT setval('cxm_id_seq', 1, false)" >>= λ _ → pure tt

------------------------------------------------------------------------
-- Measurement: round-trips (1 run) + wall-clock median over R runs
------------------------------------------------------------------------

private
  reps : ℕ
  reps = 9

  -- one measured execution: reset db, reset counter, time the atom, read the counter.
  --   returns (round-trips , elapsed-ns)
  measureOnce : String → Tx ⊤ → IO (ℕ × ℕ)
  measureOnce conninfo prog =
    resetDb conninfo >>
    pgStmtReset >>
    nowNanos >>= λ t0 →
    runCxmTx (connectPerTxn conninfo) prog >>= λ _ →
    nowNanos >>= λ t1 →
    pgStmtCount >>= λ rt →
    pure (rt , (t1 ∸ t0))

  -- insertion into a sorted (ascending) list — for the median.
  insSorted : ℕ → List ℕ → List ℕ
  insSorted x []       = x ∷ []
  insSorted x (y ∷ ys) = if x <ᵇ y then x ∷ y ∷ ys else y ∷ insSorted x ys

  nth : ℕ → List ℕ → ℕ
  nth _       []       = 0
  nth 0       (x ∷ _)  = x
  nth (suc k) (_ ∷ xs) = nth k xs

  -- run R reps, keep the round-trip count (deterministic) and the sorted ns samples.
  runReps : String → Tx ⊤ → ℕ → ℕ → List ℕ → IO (ℕ × List ℕ)
  runReps conninfo prog 0       rt acc = pure (rt , acc)
  runReps conninfo prog (suc k) rt acc =
    measureOnce conninfo prog >>= λ where
      (r , ns) → runReps conninfo prog k r (insSorted ns acc)

  -- ns → "X.YZ ms"
  showMs : ℕ → String
  showMs ns = show (ns / 1000000) <> "." <> pad3 ((ns / 1000) % 1000) <> " ms"
    where
      pad3 : ℕ → String
      pad3 n = (if n <ᵇ 100 then "0" else "")
             <> (if n <ᵇ 10  then "0" else "") <> show n

  runOne : String → String × Tx ⊤ → IO ⊤
  runOne conninfo (name , prog) =
    runReps conninfo prog reps 0 [] >>= λ where
      (rt , samples) →
        putStrLn ("  " <> name
                  <> "\n      round-trips (BEGIN+verbs+COMMIT): " <> show rt
                  <> "\n      wall-clock median of " <> show reps <> " (incl v1 connect): "
                  <> showMs (nth (reps / 2) samples)
                  <> "\n      wall-clock min:                  " <> showMs (nth 0 samples))

  loop : String → List (String × Tx ⊤) → IO ⊤
  loop _        []       = pure tt
  loop conninfo (s ∷ ss) = runOne conninfo s >> loop conninfo ss

{-# NON_TERMINATING #-}
main : IO ⊤
main =
  getEnvOr "CXM_PG" "host=127.0.0.1 dbname=agdelte user=agdelte" >>= λ conninfo →
  putStrLn "pg-bench: chattiness on live PG (DESTRUCTIVE on target db)" >>
  applyGenesis conninfo >>
  loop conninfo scenarios >>
  putStrLn "pg-bench: done"
