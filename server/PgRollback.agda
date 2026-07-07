{-# OPTIONS --without-K --guardedness #-}

-- pg-rollback — the DOWN-mode migration runner (pg-store-plan «Миграции», rollback half). Mirror
-- of the boot forward runner (CxmServerPg.applySteps over schema_migrations): reads the applied
-- ledger newest-first, takes the last N (env CXM_ROLLBACK_STEPS, default 1), resolves each step's
-- `down` from cxmHistory, and — ONLY if every step in range is reversible — applies them
-- newest-first, each in its own txn with its ledger row deleted atomically.
--
-- SAFETY: refuses ENTIRELY (touches nothing) if any step in range is honestly irreversible
-- (mDropColumn / mDropTable → down = nothing) or maps to no known migration id. So you can never
-- half-roll-back into an irreproducible state; make destructive changes a deliberate manual step.
--
--   env CXM_PG (default host=127.0.0.1 dbname=agdelte user=agdelte), CXM_ROLLBACK_STEPS (default 1)
--
-- ⚠ DESTRUCTIVE on the target database. Prints the target ids before doing anything.
module PgRollback where

open import Agda.Builtin.IO using (IO)
open import Agda.Builtin.Unit using (⊤; tt)
open import Agda.Builtin.String using (String)
open import Data.Bool using (Bool)
open import Data.List using (List; []; _∷_; map; take)
open import Data.Maybe using (Maybe; just; nothing; maybe′)
open import Data.Nat using (ℕ; suc; _+_; _∸_)
open import Data.Nat.Show using (show)
open import Data.Product using (_×_; _,_)
open import Data.String using () renaming (_++_ to _<>_)

open import Agdelte.FFI.Server using (putStrLn; _>>=_; _>>_; pure; getEnvOr)
open import Agdelte.Storage.Wire using (readℕ)
open import Agdelte.Storage.JsonRow using (decodeIds)
open import Agdelte.Storage.PgConn using (Conn; withConnRaw; execConn; queryConn)
open import Agdelte.Storage.Migration using (MigStep; down)
open import Cxm.Store.Registry using (cxmHistory)

private
  -- 0-based nth over the history (ledger id i ↔ cxmHistory position i−1, per the forward runner)
  idx0 : ℕ → List MigStep → Maybe MigStep
  idx0 _       []       = nothing
  idx0 0       (x ∷ _)  = just x
  idx0 (suc n) (_ ∷ xs) = idx0 n xs

  mbind : ∀ {A B : Set} → Maybe A → (A → Maybe B) → Maybe B
  mbind nothing  _ = nothing
  mbind (just a) f = f a

  -- resolve a ledger id → its rollback SQL (nothing = irreversible OR unknown id)
  stepDownOf : ℕ → Maybe (List String)
  stepDownOf i = mbind (idx0 (i ∸ 1) cxmHistory) down

  -- all-or-nothing: one `nothing` in range poisons the whole plan (refuse, touch nothing)
  resolveDowns : List ℕ → Maybe (List (ℕ × List String))
  resolveDowns []       = just []
  resolveDowns (i ∷ is) = mbind (stepDownOf i) λ stmts →
                          mbind (resolveDowns is) λ rest → just ((i , stmts) ∷ rest)

  showIds : List ℕ → String
  showIds []       = "-"
  showIds (x ∷ []) = show x
  showIds (x ∷ xs) = show x <> "," <> showIds xs

  sqlEach : Conn → List String → IO ⊤
  sqlEach c []       = pure tt
  sqlEach c (s ∷ ss) = execConn c s >>= λ _ → sqlEach c ss

  -- one migration rolled back per txn: down-SQL + ledger-row delete commit atomically
  applyRollback : Conn → List (ℕ × List String) → IO ℕ
  applyRollback c []               = pure 0
  applyRollback c ((i , stmts) ∷ rest) =
    execConn c "BEGIN" >>= λ _ →
    sqlEach c stmts >>
    execConn c ("DELETE FROM \"schema_migrations\" WHERE \"id\" = " <> show i <> ";") >>= λ _ →
    execConn c "COMMIT" >>= λ _ →
    applyRollback c rest >>= λ n → pure (1 + n)

  runPlan : Conn → Maybe (List (ℕ × List String)) → IO ⊤
  runPlan _ nothing     =
    putStrLn "pg-rollback: REFUSED — an irreversible step (DROP COLUMN/TABLE) or unknown id is in range; nothing changed."
  runPlan c (just plan) =
    applyRollback c plan >>= λ n → putStrLn ("pg-rollback: rolled back " <> show n <> " migration(s).")

main : IO ⊤
main =
  getEnvOr "CXM_PG" "host=127.0.0.1 dbname=agdelte user=agdelte" >>= λ conninfo →
  getEnvOr "CXM_ROLLBACK_STEPS" "1" >>= λ ks →
  withConnRaw conninfo λ c →
    queryConn c "SELECT \"id\" FROM \"schema_migrations\" ORDER BY \"id\" DESC" >>= λ j →
    let targets = take (maybe′ (λ x → x) 1 (readℕ ks)) (maybe′ (λ x → x) [] (decodeIds j)) in
    putStrLn ("pg-rollback: target ids (newest first): " <> showIds targets) >>
    runPlan c (resolveDowns targets)
