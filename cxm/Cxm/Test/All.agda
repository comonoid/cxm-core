{-# OPTIONS --without-K #-}

-- Umbrella for compile-time tests. `agda Cxm/Test/All.agda` runs every test (refl proofs).
-- Populated phase by phase alongside Cxm.All.
module Cxm.Test.All where

-- Phase 1
open import Cxm.Test.NumTest
open import Cxm.Test.KnowledgeTest

-- Phase 3
open import Cxm.Test.EventTest

-- Phase 4
open import Cxm.Test.WireTest
open import Cxm.Test.EnumCodecTest

-- Phase 5

-- Phase 6
open import Cxm.Test.ScheduleTest

-- Phase 7
open import Cxm.Test.InferenceTest
open import Cxm.Test.ProjectionTest
open import Cxm.Test.SocialTest
open import Cxm.Test.FulfilmentTest

-- Phase 8
open import Cxm.Test.DecisionTest

-- Phase 9
open import Cxm.Test.SiteTest

-- Phase 10
open import Cxm.Test.VersionTest

-- Phase 12
open import Cxm.Test.InstanceTest
