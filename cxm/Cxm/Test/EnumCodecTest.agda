{-# OPTIONS --without-K #-}

-- Exhaustive enum codec tests (audit finding #7). The per-record round-trip in WireTest only
-- exercises ONE variant per enum; this checks `xOfOrd (xCode v) ≡ just v` for EVERY variant,
-- guarding against xCode/xOfOrd drift (which would silently decode to the wrong constructor).
-- `refl` IS the test.
module Cxm.Test.EnumCodecTest where

open import Relation.Binary.PropositionalEquality using (_≡_; refl)
open import Data.Maybe using (just)

open import Cxm.Subject
open import Cxm.Edge
open import Cxm.Event
open import Cxm.Bus
open import Cxm.Knowledge
open import Cxm.Expectation using (Ours; Theirs)
open import Cxm.Collections
open import Cxm.Wire

-- SubjectKind
_ : skOfOrd (skCode EXTERNAL) ≡ just EXTERNAL
_ = refl
_ : skOfOrd (skCode INTERNAL) ≡ just INTERNAL
_ = refl

-- SubjectStructure
_ : ssOfOrd (ssCode Person) ≡ just Person
_ = refl
_ : ssOfOrd (ssCode Org) ≡ just Org
_ = refl

-- EdgeKind
_ : ekOfOrd (ekCode participation) ≡ just participation
_ = refl
_ : ekOfOrd (ekCode membership) ≡ just membership
_ = refl
_ : ekOfOrd (ekCode decision_consult) ≡ just decision_consult
_ = refl
_ : ekOfOrd (ekCode owner) ≡ just owner
_ = refl
_ : ekOfOrd (ekCode patient) ≡ just patient
_ = refl
_ : ekOfOrd (ekCode follow) ≡ just follow
_ = refl

-- Channel
_ : chOfOrd (chCode Web) ≡ just Web
_ = refl
_ : chOfOrd (chCode Mobile) ≡ just Mobile
_ = refl
_ : chOfOrd (chCode Chat) ≡ just Chat
_ = refl
_ : chOfOrd (chCode Email) ≡ just Email
_ = refl
_ : chOfOrd (chCode Phone) ≡ just Phone
_ = refl
_ : chOfOrd (chCode Product) ≡ just Product
_ = refl
_ : chOfOrd (chCode Internal) ≡ just Internal
_ = refl

-- Actor
_ : acOfOrd (acCode Client) ≡ just Client
_ = refl
_ : acOfOrd (acCode Staff) ≡ just Staff
_ = refl
_ : acOfOrd (acCode System) ≡ just System
_ = refl
_ : acOfOrd (acCode InternalSubject) ≡ just InternalSubject
_ = refl

-- EventType
_ : etOfOrd (etCode View) ≡ just View
_ = refl
_ : etOfOrd (etCode Purchase) ≡ just Purchase
_ = refl
_ : etOfOrd (etCode TicketOpen) ≡ just TicketOpen
_ = refl
_ : etOfOrd (etCode FeatureUse) ≡ just FeatureUse
_ = refl
_ : etOfOrd (etCode FeatureRequest) ≡ just FeatureRequest
_ = refl
_ : etOfOrd (etCode InternalHandoff) ≡ just InternalHandoff
_ = refl
_ : etOfOrd (etCode LifecycleChange) ≡ just LifecycleChange
_ = refl
_ : etOfOrd (etCode PromiseListed) ≡ just PromiseListed
_ = refl
_ : etOfOrd (etCode PromiseTransferred) ≡ just PromiseTransferred
_ = refl
_ : etOfOrd (etCode PromiseSettled) ≡ just PromiseSettled
_ = refl
_ : etOfOrd (etCode PromiseDefaulted) ≡ just PromiseDefaulted
_ = refl

-- PromDirection (upgrade-план A1)
_ : pdOfOrd (pdCode Ours) ≡ just Ours
_ = refl
_ : pdOfOrd (pdCode Theirs) ≡ just Theirs
_ = refl

-- OutStatus
_ : osOfOrd (osCode OutPending) ≡ just OutPending
_ = refl
_ : osOfOrd (osCode OutSent) ≡ just OutSent
_ = refl

-- EpistemicType
_ : epOfOrd (epCode FACT) ≡ just FACT
_ = refl
_ : epOfOrd (epCode HYPOTHESIS) ≡ just HYPOTHESIS
_ = refl
_ : epOfOrd (epCode STATE) ≡ just STATE
_ = refl
_ : epOfOrd (epCode TRAIT) ≡ just TRAIT
_ = refl

-- Source
_ : srOfOrd (srCode OBSERVED) ≡ just OBSERVED
_ = refl
_ : srOfOrd (srCode INFERRED) ≡ just INFERRED
_ = refl
_ : srOfOrd (srCode STATED) ≡ just STATED
_ = refl
_ : srOfOrd (srCode IMPORTED) ≡ just IMPORTED
_ = refl

-- KStatus
_ : ksOfOrd (ksCode ACTIVE) ≡ just ACTIVE
_ = refl
_ : ksOfOrd (ksCode CONFIRMED) ≡ just CONFIRMED
_ = refl
_ : ksOfOrd (ksCode REFUTED) ≡ just REFUTED
_ = refl
_ : ksOfOrd (ksCode SUPERSEDED) ≡ just SUPERSEDED
_ = refl

-- DeviationKind
_ : dkOfOrd (dkCode Stuck) ≡ just Stuck
_ = refl
_ : dkOfOrd (dkCode Rollback) ≡ just Rollback
_ = refl
_ : dkOfOrd (dkCode Overdue) ≡ just Overdue
_ = refl

-- social loop (cxm-social-plan S2)
_ : etOfOrd (etCode Publish) ≡ just Publish
_ = refl
_ : etOfOrd (etCode Reaction) ≡ just Reaction
_ = refl
_ : etOfOrd (etCode PromiseDeclared) ≡ just PromiseDeclared    -- П6 Inc1.1
_ = refl
