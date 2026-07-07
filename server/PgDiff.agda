{-# OPTIONS --without-K --guardedness #-}

-- pg-diff — THE live diff harness (pg-store-plan Ф3): runs a battery of real command scenarios
-- through BOTH interpreters — the pure reference handler (Cxm.Store.VerbsTest.handlerP, empty
-- state) and live Postgres (runCxmTx over connectPerTxn v1) — and compares the rendered results.
-- Scenarios are single-threaded and abort-free in their mainline (plus one abort scenario
-- comparing the error), so surrogate ids advance identically on both sides (E1 convention).
--
--   env CXM_PG (default host=127.0.0.1 dbname=agdelte user=agdelte)
--
-- ⚠ DESTRUCTIVE on the target database: applies the genesis DDL, then TRUNCATEs all cxm tables
-- and resets cxm_id_seq before EVERY scenario. Point it at a scratch database only.
module PgDiff where

open import Agda.Builtin.IO using (IO)
open import Agda.Builtin.Unit using (⊤; tt)
open import Agda.Builtin.String using (String; primStringEquality)
open import Data.Bool using (Bool; true; false; if_then_else_)
open import Data.List using (List; []; _∷_; map; length; concat)
open import Data.Maybe using (Maybe; just; nothing; maybe′)
open import Data.Nat using (ℕ; _+_; _≡ᵇ_)
open import Data.Nat.Show using (show)
open import Data.Product using (_×_; _,_)
open import Data.Sum using (_⊎_; inj₁; inj₂)
open import Data.String using () renaming (_++_ to _<>_)

open import Agdelte.FFI.Server using (putStrLn; _>>=_; _>>_; pure; getEnvOr)
open import Agdelte.Storage.Migration using (up)
open import Agdelte.Storage.PgConn using (TxRunner; connectPerTxn; withConnRaw; execConn; queryConn)

open import Cxm.Store.Base using
  ( Err; NotFound; Conflict; Insufficient; InvalidTransition; Forbidden; Invariant
  ; outByStatus; busByProcessed )
open import Cxm.Store.Verbs
open import Cxm.Store.Pg using (runCxmTx)
open import Cxm.Store.Registry using (dumps; dName; cxmHistory)
open import Cxm.Store.VerbsTest using (PSt; mkP; handlerP)
open import Cxm.CommandsV
open import Cxm.Knowledge using (KRedetail)
open import Cxm.Identity using (iVerified)
open import Cxm.Knowledge using (STATE; STATED; kDetail)
open import Cxm.Appointment using (apStatus; ApptStatus; ApScheduled; ApCanceled; ApCompleted; ApNoShow)
open import Cxm.Account using (acBalance)
open import Cxm.Bus using (mkEvent; evProcessed)
open import Cxm.Expectation using (Ours)
open import Cxm.Event using (mkExperienceEvent; Web; Client; View; eePayload)

------------------------------------------------------------------------
-- Rendering (both sides reduce to a comparable String)
------------------------------------------------------------------------

private
  showErr : Err → String
  showErr NotFound          = "ERR:not_found"
  showErr Conflict          = "ERR:conflict"
  showErr Insufficient      = "ERR:insufficient"
  showErr InvalidTransition = "ERR:invalid_transition"
  showErr Forbidden         = "ERR:forbidden"
  showErr (Invariant m)     = "ERR:" <> m

  shB : Bool → String
  shB true  = "1"
  shB false = "0"

  shAp : ApptStatus → String
  shAp ApScheduled = "S"
  shAp ApCanceled  = "C"
  shAp ApCompleted = "D"
  shAp ApNoShow    = "N"

  renderPure : Err ⊎ (String × PSt) → String
  renderPure (inj₁ e)       = showErr e
  renderPure (inj₂ (s , _)) = s

  renderPg : Err ⊎ String → String
  renderPg (inj₁ e) = showErr e
  renderPg (inj₂ s) = s

------------------------------------------------------------------------
-- Scenarios: real ported commands, empty world on both sides
------------------------------------------------------------------------

private
  sIdentity : Tx String
  sIdentity =
    resolveOrCreateSubjectV "email" "a@x" "Cli" "UTC" 1 7 >>=T λ sid →
    bindIdentityNotifyV sid "email" "a@x" 1 8 "Confirm" (λ n → "v:" <> show n) >>=T λ iid →
    verifyIdentityV iid 9 >>T
    get tcIdentity iid >>=T λ mi →
    byIx tcOutbox outByStatus 0 >>=T λ pend →
    returnT ("verified=" <> shB (maybe′ iVerified false mi) <> ";pending=" <> show (length pend))

  sKnowledge : Tx String
  sKnowledge =
    resolveOrCreateSubjectV "email" "b@x" "Cli" "UTC" 1 7 >>=T λ s →
    createKnowledgeV s STATE STATED 500 "old" 0 0 nothing nothing 1 >>=T λ kid →
    updateKnowledgeV kid (KRedetail "new") 1 >>T
    get tcKnowledge kid >>=T λ mk →
    returnT ("detail=" <> maybe′ kDetail "?" mk)

  sBooking : Tx String
  sBooking =
    resolveOrCreateSubjectV "email" "c@x" "Cli" "UTC" 1 7 >>=T λ s →
    bookAppointmentV s 0 nothing nothing 5000 60 1 7 >>=T λ aid →
    cancelAppointmentV aid >>T
    get tcAppointment aid >>=T λ ma →
    returnT ("appt=" <> maybe′ (λ a → shAp (apStatus a)) "?" ma)

  sPromise : Tx String
  sPromise =
    openAccountV 1 0 >>=T λ a1 →
    creditV a1 100 >>T
    openAccountV 1 0 >>=T λ a2 →
    resolveOrCreateSubjectV "email" "d@x" "Cli" "UTC" 1 7 >>=T λ s →
    createPromiseDirectedV s "t" 99 Ours true 30 (just a1) (just a2) true 1 7 >>=T λ pid →
    settlePromiseV pid 1 8 >>T
    get tcAccount a1 >>=T λ m1 →
    get tcAccount a2 >>=T λ m2 →
    returnT ("a1=" <> maybe′ (λ a → show (acBalance a)) "?" m1
             <> ";a2=" <> maybe′ (λ a → show (acBalance a)) "?" m2)

  sGdpr : Tx String
  sGdpr =
    ingestSiteEventV "email" "e@x" 1 7
      (mkExperienceEvent 0 0 1 Web Client 7 View 0 nothing nothing nothing nothing false false
        "PII" nothing) >>=T λ _ →
    resolveOrCreateSubjectV "email" "e@x" "Cli" "UTC" 1 8 >>=T λ s →
    gdprEraseSubjectV s 1 9 >>T
    scan tcEvent >>=T λ evs →
    get tcSubject s >>=T λ ms →
    returnT ("events=" <> show (length evs)
             <> ";payload=" <> firstPayload evs
             <> ";subject=" <> maybe′ (λ _ → "alive") "gone" ms)
    where
      firstPayload : List (ℕ × _) → String
      firstPayload []            = "-"
      firstPayload ((_ , e) ∷ _) = eePayload e

  sAbort : Tx String
  sAbort =
    openAccountV 1 0 >>=T λ a →
    chargeV a 999 >>T
    returnT "unreachable"

  sBus : Tx String
  sBus =
    fresh >>=T λ i →
    put tcBusEvent (mkEvent i "topic" "payload" false 1 7) >>T
    dispatchBusV >>=T λ n →
    get tcBusEvent i >>=T λ me →
    returnT ("dispatched=" <> show n <> ";processed="
             <> maybe′ (λ e → shB (evProcessed e)) "?" me)

  scenarios : List (String × Tx String)
  scenarios =
      ("identity-bind-verify-notify" , sIdentity)
    ∷ ("knowledge-create-update"     , sKnowledge)
    ∷ ("booking-cancel"              , sBooking)
    ∷ ("promise-stake-settle"        , sPromise)
    ∷ ("gdpr-erase"                  , sGdpr)
    ∷ ("charge-insufficient-abort"   , sAbort)
    ∷ ("bus-dispatch-bool-index"     , sBus)      -- G2 regression net (CBool index → TRUE/FALSE)
    ∷ []

------------------------------------------------------------------------
-- PG side plumbing: genesis DDL once, TRUNCATE + sequence reset per scenario
------------------------------------------------------------------------

private
  emptyP : PSt
  emptyP = mkP (λ _ → []) 1 []

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

  runOne : String → ℕ → String × Tx String → IO ℕ
  runOne conninfo fails (name , prog) =
    resetDb conninfo >>
    runCxmTx (connectPerTxn conninfo) prog >>= λ pgRes →
    check (renderPure (runTx handlerP prog emptyP)) (renderPg pgRes)
    where
      check : String → String → IO ℕ
      check nat pg =
        if primStringEquality nat pg
        then putStrLn ("✓ " <> name <> "  [" <> nat <> "]") >> pure fails
        else putStrLn ("✗ " <> name <> "\n    native: " <> nat <> "\n    pg:     " <> pg)
               >> pure (1 + fails)

  loop : String → ℕ → List (String × Tx String) → IO ℕ
  loop _        fails []       = pure fails
  loop conninfo fails (s ∷ ss) = runOne conninfo fails s >>= λ f → loop conninfo f ss

{-# NON_TERMINATING #-}
main : IO ⊤
main =
  getEnvOr "CXM_PG" "host=127.0.0.1 dbname=agdelte user=agdelte" >>= λ conninfo →
  putStrLn "pg-diff: native ≡ PG over the ported command corpus (DESTRUCTIVE on target db)" >>
  applyGenesis conninfo >>
  loop conninfo 0 scenarios >>= λ fails →
  putStrLn (if fails ≡ᵇ 0 then "pg-diff: ALL GREEN" else ("pg-diff: FAILURES: " <> show fails))