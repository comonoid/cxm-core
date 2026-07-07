{-# OPTIONS --without-K #-}

-- Cxm.AccessPolicy (RB2, access-control-plan §слой 2) — the ADVANCED content-access mode as
-- policy-as-data. A `Policy` is a DNF (OR of ANDs) over negatable atoms, parsed from the opaque
-- `Resource.rVisibility` string (§7.4), so the standard presets ("public"/"followers"/"entitled")
-- are just single-atom policies (full back-compat) and advanced owners compose richer rules —
-- e.g. `followers|entitled` (followers OR paying), `followers&!sub:42` (followers except a blocked
-- person), `entitled|sub:7|sub:9` (paying OR named people).
--
-- NEUTRAL: atoms are abstract; `Cxm.Social` supplies the decider (follows?/entitled?/id-eq?).
-- FAIL-CLOSED: any malformed policy → `nothing`, and the caller denies (never exposes on error) —
-- the owner-guardrail so a simple user cannot footgun themselves into an open door by a typo.
module Cxm.AccessPolicy where

open import Data.Nat using (ℕ; _≡ᵇ_)
open import Data.Nat.Show using (readMaybe)
open import Data.Bool using (Bool; true; false; if_then_else_; not; _∧_; _∨_)
open import Data.Char using (Char; toℕ)
open import Data.String using (String; toList; fromList)
open import Data.List using (List; []; _∷_; foldr; map)
open import Data.Maybe using (Maybe; just; nothing)
open import Data.Product using (_×_; _,_)
open import Agda.Builtin.String using (primStringEquality)

------------------------------------------------------------------------
-- AST
------------------------------------------------------------------------

data Atom : Set where
  aPublic aFollowers aEntitled : Atom
  aSub  : ℕ → Atom      -- viewer IS this subject id
  aNode : ℕ → Atom      -- viewer holds an entitlement on this node id

Lit : Set
Lit = Bool × Atom       -- fst = negated?

Clause : Set
Clause = List Lit       -- conjunction (AND) of literals

Policy : Set
Policy = List Clause    -- disjunction (OR) of clauses — DNF

------------------------------------------------------------------------
-- Evaluation (generic over a caller-supplied atom decider)
------------------------------------------------------------------------

evalLit : (Atom → Bool) → Lit → Bool
evalLit dec (neg , a) = if neg then not (dec a) else dec a

evalClause : (Atom → Bool) → Clause → Bool
evalClause dec = foldr (λ l acc → evalLit dec l ∧ acc) true

-- empty policy (no clauses) ⇒ deny; empty clause ⇒ true, but the validator rejects those.
eval : (Atom → Bool) → Policy → Bool
eval dec = foldr (λ c acc → evalClause dec c ∨ acc) false

------------------------------------------------------------------------
-- Parser  (clauses '|' , atoms '&' , negate leading '!')
------------------------------------------------------------------------

private
  splitOnᶜ : Char → List Char → List (List Char)
  splitOnᶜ c = foldr step ([] ∷ [])
    where step : Char → List (List Char) → List (List Char)
          step ch (cur ∷ rest) = if toℕ ch ≡ᵇ toℕ c then [] ∷ cur ∷ rest else (ch ∷ cur) ∷ rest
          step ch []           = (ch ∷ []) ∷ []          -- unreachable (seed is non-empty)

  splitS : Char → String → List String
  splitS c s = map fromList (splitOnᶜ c (toList s))

  traverseM : ∀ {A B : Set} → (A → Maybe B) → List A → Maybe (List B)
  traverseM f []       = just []
  traverseM f (x ∷ xs) with f x
  ... | nothing = nothing
  ... | just y  with traverseM f xs
  ...   | nothing = nothing
  ...   | just ys = just (y ∷ ys)

  -- "prefix:N" → just n iff the string is exactly prefix ++ ":" ++ decimal
  afterColon : String → List String
  afterColon = splitS ':'

parseAtom : String → Maybe Atom
parseAtom s =
  if primStringEquality s "public"    then just aPublic
  else if primStringEquality s "followers" then just aFollowers
  else if primStringEquality s "entitled"  then just aEntitled
  else kv (afterColon s)
  where
    kv : List String → Maybe Atom
    kv (k ∷ v ∷ []) with readMaybe 10 v
    ... | nothing = nothing
    ... | just n  = if primStringEquality k "sub"  then just (aSub n)
                    else if primStringEquality k "node" then just (aNode n)
                    else nothing
    kv _ = nothing

private
  -- leading '!' negates
  parseLit : String → Maybe Lit
  parseLit s with toList s
  ... | ('!' ∷ rest) with parseAtom (fromList rest)
  ...   | nothing = nothing
  ...   | just a  = just (true , a)
  parseLit s | _ with parseAtom s
  ...   | nothing = nothing
  ...   | just a  = just (false , a)

  parseClause : String → Maybe Clause
  parseClause s = traverseM parseLit (splitS '&' s)

parsePolicy : String → Maybe Policy
parsePolicy s = traverseM parseClause (splitS '|' s)

------------------------------------------------------------------------
-- Owner-guardrail validator: well-formed = non-empty policy, no empty clause. (Richer safety
-- bounds — e.g. warn when an "advanced" policy silently grants public — are a follow-up.)
------------------------------------------------------------------------

wellFormed : Policy → Bool
wellFormed []       = false
wellFormed (c ∷ cs) = nonEmptyClause c ∧ foldr (λ x acc → nonEmptyClause x ∧ acc) true cs
  where nonEmptyClause : Clause → Bool
        nonEmptyClause []      = false
        nonEmptyClause (_ ∷ _) = true

-- parse + validate in one step (nothing = malformed OR unsafe ⇒ caller denies)
compilePolicy : String → Maybe Policy
compilePolicy s with parsePolicy s
... | nothing = nothing
... | just p  = if wellFormed p then just p else nothing

------------------------------------------------------------------------
-- Tests (refl — pure, compile-time)
------------------------------------------------------------------------

private
  open import Relation.Binary.PropositionalEquality using (_≡_; refl)

  runP : (Atom → Bool) → String → Bool
  runP dec s = maybe′ (eval dec) false (compilePolicy s)
    where open import Data.Maybe using (maybe′)

  onlyPublic onlyFollowers onlyEntitled : Atom → Bool
  onlyPublic    aPublic    = true ; onlyPublic    _ = false
  onlyFollowers aFollowers = true ; onlyFollowers _ = false
  onlyEntitled  aEntitled  = true ; onlyEntitled  _ = false

  -- presets are subsumed (single-atom policies)
  _ : runP onlyPublic    "public"    ≡ true  ; _ = refl
  _ : runP onlyFollowers "followers" ≡ true  ; _ = refl
  _ : runP onlyEntitled  "entitled"  ≡ true  ; _ = refl
  _ : runP onlyFollowers "entitled"  ≡ false ; _ = refl

  -- advanced: OR of clauses
  _ : runP onlyEntitled  "followers|entitled" ≡ true ; _ = refl
  _ : runP onlyFollowers "followers|entitled" ≡ true ; _ = refl

  -- advanced: AND with negation — "followers except the blocked person 42"
  decBlocked decAllowed : Atom → Bool
  decBlocked aFollowers = true ; decBlocked (aSub n) = n ≡ᵇ 42 ; decBlocked _ = false
  decAllowed aFollowers = true ; decAllowed _ = false
  _ : runP decBlocked "followers&!sub:42" ≡ false ; _ = refl
  _ : runP decAllowed "followers&!sub:42" ≡ true  ; _ = refl

  -- fail-closed: malformed / empty ⇒ nothing (caller denies)
  _ : compilePolicy "garbage" ≡ nothing ; _ = refl
  _ : compilePolicy "sub:x"   ≡ nothing ; _ = refl
  _ : compilePolicy ""        ≡ nothing ; _ = refl
