{-# OPTIONS --without-K --guardedness #-}

-- pg-query-diff — the LIVE half of the query-EDSL diff (Storage.QueryTest foresaw it: "the live
-- half … waits for the txn driver"). For each reified `Count` term it compares the TWO
-- interpreters on real Postgres over the SAME rows:
--   native  = runCount q (decodeRows knowledgeSchema ⟵ selectAll)   -- reference fold in Agda
--   pg      = decodeFirstNat "count" ⟵ queryConn (compileCount q)   -- the compiled SELECT on PG
-- Agreement proves the SQL compiler's WHERE/predicate translation matches the reference semantics.
--
--   env CXM_PG (default host=127.0.0.1 dbname=agdelte user=agdelte)
--
-- ⚠ DESTRUCTIVE: applies genesis DDL, TRUNCATEs all cxm tables, then seeds knowledge rows.
module PgQueryDiff where

open import Agda.Builtin.IO using (IO)
open import Agda.Builtin.Unit using (⊤; tt)
open import Agda.Builtin.String using (String; primStringEquality)
open import Data.Bool using (Bool; true; false; if_then_else_)
open import Data.List using (List; []; _∷_; map; concat; length)
open import Data.Maybe using (Maybe; just; nothing)
open import Data.Nat using (ℕ; _+_; _≡ᵇ_)
open import Data.Nat.Show using (show)
open import Data.Product using (_×_; _,_)
open import Data.Sum using (_⊎_; inj₁; inj₂)
open import Data.String using () renaming (_++_ to _<>_)

open import Agdelte.FFI.Server using (putStrLn; _>>=_; _>>_; pure; getEnvOr)
open import Agdelte.Storage.Migration using (up)
open import Agdelte.Storage.SQL using (selectAll)
open import Agdelte.Storage.JsonRow using (decodeRows; decodeFirstNat)
open import Agdelte.Storage.Query using (Count; countWhere; eqN; runCount; compileCount)
open import Agdelte.Storage.Schema using (Row)
open import Agdelte.Storage.PgConn using (Conn; TxRunner; connectPerTxn; withConnRaw; execConn; queryConn)

open import Cxm.Wire using (knowledgeSchema)
open import Cxm.Knowledge using (STATE; STATED)
open import Cxm.Store.Verbs using (Tx; _>>=T_; _>>T_; returnT)
open import Cxm.Store.Pg using (runCxmTx)
open import Cxm.Store.Registry using (dumps; dName; cxmHistory)
open import Cxm.CommandsV using (resolveOrCreateSubjectV; createKnowledgeV)

------------------------------------------------------------------------
-- Seed: two subjects across two tenants, six knowledge rows with known (tenant, confidence)
------------------------------------------------------------------------

private
  seedQ : Tx ⊤
  seedQ =
    resolveOrCreateSubjectV "email" "qa@x" "Cli" "UTC" 1 7 >>=T λ sa →
    createKnowledgeV sa STATE STATED 500 "a1" 0 0 nothing nothing 1 >>=T λ _ →
    createKnowledgeV sa STATE STATED 500 "a2" 0 0 nothing nothing 1 >>=T λ _ →
    createKnowledgeV sa STATE STATED 900 "a3" 0 0 nothing nothing 1 >>=T λ _ →
    resolveOrCreateSubjectV "email" "qb@x" "Cli" "UTC" 2 8 >>=T λ sb →
    createKnowledgeV sb STATE STATED 500 "b1" 0 0 nothing nothing 2 >>=T λ _ →
    returnT tt

  -- reified Count terms (eqN's existence/ℕ-ness proof auto-solves: T (hasNatCol …) reduces to ⊤)
  queries : List (String × Count knowledgeSchema)
  queries =
      ("tenant=1"          , countWhere "knowledge" (eqN "tenant" 1 ∷ []))
    ∷ ("tenant=2"          , countWhere "knowledge" (eqN "tenant" 2 ∷ []))
    ∷ ("confidence=500"    , countWhere "knowledge" (eqN "confidence" 500 ∷ []))
    ∷ ("tenant=1&conf=500" , countWhere "knowledge" (eqN "tenant" 1 ∷ eqN "confidence" 500 ∷ []))
    ∷ ("all (WHERE TRUE)"  , countWhere "knowledge" [])
    ∷ ("confidence=999 (∅)" , countWhere "knowledge" (eqN "confidence" 999 ∷ []))
    ∷ []

------------------------------------------------------------------------
-- DB plumbing (mirrors PgDiff)
------------------------------------------------------------------------

private
  joinComma : List String → String
  joinComma []           = ""
  joinComma (x ∷ [])     = x
  joinComma (x ∷ y ∷ xs) = x <> "," <> joinComma (y ∷ xs)

  sqlEach : Conn → List String → IO ⊤
  sqlEach c []         = pure tt
  sqlEach c (st ∷ sts) = execConn c st >>= λ _ → sqlEach c sts

  applyGenesis : String → IO ⊤
  applyGenesis conninfo = withConnRaw conninfo λ c → sqlEach c (concat (map up cxmHistory))

  resetDb : String → IO ⊤
  resetDb conninfo = withConnRaw conninfo λ c →
    execConn c ("TRUNCATE " <> joinComma (map (λ d → "\"" <> dName d <> "\"") dumps) <> " CASCADE;") >>= λ _ →
    queryConn c "SELECT setval('cxm_id_seq', 1, false)" >>= λ _ → pure tt

------------------------------------------------------------------------
-- Compare
------------------------------------------------------------------------

private
  shN : Maybe ℕ → String
  shN (just n) = show n
  shN nothing  = "?"

  eqMN : Maybe ℕ → Maybe ℕ → Bool
  eqMN (just a) (just b) = a ≡ᵇ b
  eqMN _        _        = false

  runOne : List (Row knowledgeSchema) → Conn → ℕ → String × Count knowledgeSchema → IO ℕ
  runOne rows c fails (name , q) =
    queryConn c (compileCount q) >>= λ cj →
    check (just (runCount q rows)) (decodeFirstNat "count" cj)
    where
      check : Maybe ℕ → Maybe ℕ → IO ℕ
      check nat pg =
        if eqMN nat pg
        then putStrLn ("✓ " <> name <> "  [" <> shN nat <> "]") >> pure fails
        else putStrLn ("✗ " <> name <> "  native=" <> shN nat <> "  pg=" <> shN pg)
               >> pure (1 + fails)

  loop : List (Row knowledgeSchema) → Conn → ℕ → List (String × Count knowledgeSchema) → IO ℕ
  loop _    _ fails []       = pure fails
  loop rows c fails (q ∷ qs) = runOne rows c fails q >>= λ f → loop rows c f qs

{-# NON_TERMINATING #-}
main : IO ⊤
main =
  getEnvOr "CXM_PG" "host=127.0.0.1 dbname=agdelte user=agdelte" >>= λ conninfo →
  putStrLn "pg-query-diff: native runCount ≡ PG compileCount (DESTRUCTIVE on target db)" >>
  applyGenesis conninfo >>
  resetDb conninfo >>
  runCxmTx (connectPerTxn conninfo) seedQ >>= λ _ →
  withConnRaw conninfo λ c →
    queryConn c (selectAll "knowledge" knowledgeSchema) >>= λ rowsJson →
    rowsThen c (decodeRows knowledgeSchema rowsJson)
  where
    rowsThen : Conn → Maybe (List (Row knowledgeSchema)) → IO ⊤
    rowsThen _ nothing     = putStrLn "pg-query-diff: FAILED to decode knowledge rows"
    rowsThen c (just rows) =
      putStrLn ("  (seeded knowledge rows: " <> show (length rows) <> ")") >>
      loop rows c 0 queries >>= λ fails →
      putStrLn (if fails ≡ᵇ 0 then "pg-query-diff: ALL GREEN" else ("pg-query-diff: FAILURES: " <> show fails))
