{-# OPTIONS --without-K #-}

-- refl-tests for Cxm.Fulfilment (платформа-план П3): the fulfilment-plan interpreter is a pure
-- total function, so its outputs reduce under `refl`. We prove: the JSON example from the plan,
-- the compact form, tolerance to noise words, and the empty/garbage cases.
module Cxm.Test.FulfilmentTest where

open import Relation.Binary.PropositionalEquality using (_≡_; refl)
open import Data.List using (List; []; _∷_)

open import Cxm.Entitlement using (TResource; TOffering; TMembership)
open import Cxm.Fulfilment using (Grant; mkGrant; parseFulfilment)

-- the JSON plan from the platform plan → two grants, in order
_ : parseFulfilment "{\"grants\":[{\"kind\":\"resource\",\"id\":12},{\"kind\":\"offering\",\"id\":3}]}"
      ≡ mkGrant TResource 12 ∷ mkGrant TOffering 3 ∷ []
_ = refl

-- the compact form yields the identical grant list (tolerant tokenizer, not a JSON parser)
_ : parseFulfilment "resource:12 offering:3" ≡ mkGrant TResource 12 ∷ mkGrant TOffering 3 ∷ []
_ = refl

-- membership kind + multi-digit id
_ : parseFulfilment "{\"kind\":\"membership\",\"id\":405}" ≡ mkGrant TMembership 405 ∷ []
_ = refl

-- empty / no-plan metadata → no grants
_ : parseFulfilment "{}" ≡ []
_ = refl
_ : parseFulfilment "" ≡ []
_ = refl

-- a number with no pending kind is ignored; unknown words skipped
_ : parseFulfilment "{\"price\":5000,\"note\":\"hi\"}" ≡ []
_ = refl

-- a kind with no following number contributes nothing (dangling kind dropped at end)
_ : parseFulfilment "resource" ≡ []
_ = refl
