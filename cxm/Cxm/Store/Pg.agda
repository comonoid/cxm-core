{-# OPTIONS --without-K --guardedness #-}

-- THE Exec: CXM verbs → SQL over one pinned connection (pg-store-plan Ф2/Ф3). This is the last
-- bridge piece before the driver: every verb becomes one statement built by the PROVEN codecs
-- (Storage.SQL) and decoded by the PROVEN reader (Storage.JsonRow) through the Tables wiring.
-- `runCxmTx` = the freer program under BEGIN…COMMIT/ROLLBACK (Storage.FreeIO).
--
-- Typechecks against the PgConn contract NOW; runs once the driver session fills the pragmas.
-- NOTE the asymmetry with the native handlers: the LOCK DISCIPLINE is not re-checked here —
-- PG enforces the locks themselves (FOR UPDATE / advisory) while the discipline (did the command
-- take them?) is what the pure/Base handlers verify in tests. Index positions map to columns
-- DERIVED from the schema (the p-th idxCol), so the mapping cannot drift from IndexedMap's.
module Cxm.Store.Pg where

open import Agda.Builtin.IO using (IO)
open import Agda.Builtin.String using (String)
open import Agda.Builtin.Unit using (⊤; tt)
open import Data.Bool using (Bool; true; false; if_then_else_)
open import Data.List using (List; []; _∷_)
open import Data.Maybe using (Maybe; just; nothing)
open import Data.Nat using (ℕ; suc; zero; _≡ᵇ_)
open import Data.Nat.Show using (show)
open import Data.Product using (_×_; _,_)
open import Data.String using () renaming (_++_ to _<>_)
open import Data.Sum using (_⊎_; inj₁; inj₂)

open import Agdelte.Storage.Schema using (Schema; Row; cname; cindexed)
open import Agdelte.Storage.SQL using (rowUpsert; deleteById; selectAll; selectByNat; selectByStr)
open import Agdelte.Storage.JsonRow using (decodeRows; decodeIds; rowPk)
open import Agdelte.Storage.PgConn using (Conn; execConn; queryConn; TxRunner)
open import Agdelte.Storage.FFI using (_>>=_; pure)

open import Cxm.Store.Base using (Err; NotFound; Invariant)
open import Cxm.Store.Verbs
open import Cxm.Store.Tables using (tableName; schemaOf; toRowOf; fromRowOf; idxCols; idxColTys)
import Agdelte.Storage.FreeIO Req Ans Err as FIO

private
  pgErr : String → Err
  pgErr m = Invariant ("pg: " <> m)

  nth : ∀ {A : Set} → ℕ → List A → Maybe A
  nth _       []       = nothing
  nth zero    (x ∷ _)  = just x
  nth (suc n) (_ ∷ xs) = nth n xs

  ixColName : TableCode → ℕ → Maybe String
  ixColName t p = nth p (idxCols (schemaOf t))

  -- audit G2: render the index KEY by the column TYPE (CBool ⇒ TRUE/FALSE, else a number)
  ixKeyLit : TableCode → ℕ → ℕ → String
  ixKeyLit t p k = render (nth p (idxColTys (schemaOf t)))
    where
      open import Agdelte.Storage.Schema using (CBool)
      render : Maybe _ → String
      render (just CBool) = if k Data.Nat.≡ᵇ 0 then "FALSE" else "TRUE"
        where import Data.Nat
      render _            = show k

  -- typed rows → (pk, value) pairs (byCol/scan answers)
  pairRows : (t : TableCode) → List (Row (schemaOf t)) → Maybe (List (ℕ × Val t))
  pairRows t [] = just []
  pairRows t (r ∷ rs) with rowPk (schemaOf t) r | fromRowOf t r | pairRows t rs
  ... | just k | just v | just xs = just ((k , v) ∷ xs)
  ... | _      | _      | _       = nothing

exec : Conn → (r : Req) → IO (Err ⊎ Ans r)
exec c (rLockRoot t id) =
  queryConn c ("SELECT \"id\" FROM \"" <> tableName t <> "\" WHERE \"id\" = "
                 <> show id <> " FOR UPDATE") >>= λ j → pure (ans (decodeIds j))
  where ans : Maybe (List ℕ) → Err ⊎ ⊤
        ans (just (_ ∷ _)) = inj₂ tt
        ans (just [])      = inj₁ NotFound        -- absent row locks nothing (A3, domain shape)
        ans nothing        = inj₁ (pgErr "lock reply decode")
exec c (rLockKey cl o) =
  queryConn c ("SELECT pg_advisory_xact_lock(" <> show cl <> ", " <> show o <> ")") >>= λ _ →
  pure (inj₂ tt)                                   -- int4 pair: hashKey is 31-bit bounded
exec c (rGet t k) =
  queryConn c (selectByNat (tableName t) (schemaOf t) "id" k) >>= λ j →
  pure (ans (decodeRows (schemaOf t) j))
  where ans : Maybe (List (Row (schemaOf t))) → Err ⊎ Maybe (Val t)
        ans (just (r ∷ _)) = dec (fromRowOf t r)
          where dec : Maybe (Val t) → Err ⊎ Maybe (Val t)
                dec (just v) = inj₂ (just v)
                dec nothing  = inj₁ (pgErr "row decode")
        ans (just []) = inj₂ nothing
        ans nothing   = inj₁ (pgErr "json decode")
exec c (rByIndex t p k) = go (ixColName t p)
  where go : Maybe String → IO (Err ⊎ List ℕ)
        go nothing    = pure (inj₁ (pgErr "unknown index position"))
        go (just col) =
          queryConn c ("SELECT \"id\" FROM \"" <> tableName t <> "\" WHERE \"" <> col <> "\" = "
                         <> ixKeyLit t p k <> " ORDER BY \"id\"") >>= λ j → pure (ans (decodeIds j))
          where ans : Maybe (List ℕ) → Err ⊎ List ℕ
                ans (just is) = inj₂ is
                ans nothing   = inj₁ (pgErr "ids decode")
exec c (rByCol t col key) =
  if byColSupported t col
  then (queryConn c (selectByStr (tableName t) (schemaOf t) col key) >>= λ j →
        pure (ans (decodeRows (schemaOf t) j)))
  else pure (inj₁ (Invariant "byCol: column not in the strField registry"))
  where ans : Maybe (List (Row (schemaOf t))) → Err ⊎ List (ℕ × Val t)
        ans (just rs) = dec (pairRows t rs)
          where dec : Maybe (List (ℕ × Val t)) → Err ⊎ List (ℕ × Val t)
                dec (just xs) = inj₂ xs
                dec nothing   = inj₁ (pgErr "row decode")
        ans nothing = inj₁ (pgErr "json decode")
exec c (rScan t) =
  queryConn c (selectAll (tableName t) (schemaOf t)) >>= λ j → pure (ans (decodeRows (schemaOf t) j))
  where ans : Maybe (List (Row (schemaOf t))) → Err ⊎ List (ℕ × Val t)
        ans (just rs) = dec (pairRows t rs)
          where dec : Maybe (List (ℕ × Val t)) → Err ⊎ List (ℕ × Val t)
                dec (just xs) = inj₂ xs
                dec nothing   = inj₁ (pgErr "row decode")
        ans nothing = inj₁ (pgErr "json decode")
exec c (rPut t v) =
  execConn c (rowUpsert (tableName t) (schemaOf t) (toRowOf t v)) >>= λ _ → pure (inj₂ tt)
exec c (rDel t k) =
  if appendOnly t
  then pure (inj₁ (Invariant "append-only entity: hard delete not permitted (§7.5 erasure = crypto-shred)"))
  else execConn c (deleteById (tableName t) (schemaOf t) k) >>= λ n →
       pure (if n ≡ᵇ 0 then inj₁ NotFound else inj₂ tt)   -- native parity: missing row ⇒ NotFound
exec c rFresh =
  queryConn c "SELECT nextval('cxm_id_seq') AS \"id\"" >>= λ j → pure (ans (decodeIds j))
  where ans : Maybe (List ℕ) → Err ⊎ ℕ
        ans (just (n ∷ _)) = inj₂ n
        ans _              = inj₁ (pgErr "nextval decode")

-- one command = one PG transaction on one pinned connection (BEGIN … COMMIT/ROLLBACK in FreeIO)
runCxmTx : TxRunner → ∀ {A} → Tx A → IO (Err ⊎ A)
runCxmTx run tx = FIO.runTxPg run exec tx