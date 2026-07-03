{-# OPTIONS --without-K --guardedness #-}

-- PsychCxm.Api — the /psych/* HTTP routes, REBUILT on agdelte-cxm. Plugs into Cxm.Api's neutral
-- `routeExt` via `tryRoute` (just resp for /psych/*, nothing otherwise). All machinery is core
-- (Cxm.Schedule availability/validation, Cxm.Commands booking/appointments/notifications); this
-- module is thin glue reusing Cxm.Api's {data}/{error} envelope + commit.
--
--   GET  /psych/offerings                      → {data:[{code,label,sessions,price}]}
--   POST /psych/availability {type,from,days}  → {data:[{start,end}]}   (grid − booked slots)
--   POST /psych/book {type,start,name,email,…} → {data:{id}} | {error}
--   POST /psych/cancel {act}                   → {data:{result:"canceled"|"late_canceled"}}
--   POST /psych/complete|no-show|reopen {act}  → {data:{ok:true}} | {error}
--   POST /psych/reminders/run {leadHours}      → {data:{reminded:N}}
-- (purchase / session / package = prepaid packages — need a seeded package Protocol; added with
--  the CxmServer entry, migration Phase 5.)
module PsychCxm.Api where

open import Agda.Builtin.IO using (IO)
open import Agda.Builtin.Unit using (⊤)
open import Data.Nat using (ℕ; _*_; _∸_; suc)
open import Data.Nat.Show using (show)
open import Data.Bool using (Bool; false; if_then_else_; _∧_)
open import Data.Maybe using (Maybe; just; nothing)
open import Data.List using (List; []; _∷_; foldr; map; length)
open import Data.Product using (_×_; _,_; proj₁; proj₂)
open import Data.String using (String) renaming (_++_ to _<>_)

open import Agdelte.FFI.Server using
  ( HttpRequest; HttpResponse; reqMethod; reqPath; reqBody; eqStrCI; _>>=_; _>>_; pure )
open import Agdelte.FFI.Json using (jsonGetField; jsonGetNat; escapeJsonString)
open import Agdelte.FFI.Time using (getCurrentTime)

open import Cxm.Tenant using (defaultTenant)
open import Cxm.Appointment using (Appointment; apStartsAt)
open import Cxm.Episode using (Episode; epJtbd; epSubject)
open import Cxm.Entitlement using (TOffering; SGrant)
open import Cxm.Schedule using (Settings; Interval; availabilityFrom; validateSlot; freeCancelWindow; setHorizonDays)
open import Cxm.Store.Base using (Base; CxmOp)
open import Cxm.Store.Wal using (WalHandle; readBase; commitTxn; committed; rejected; ioFailed)
open import Cxm.Txn using (Txn; runTxn; _>>=T_; _>>T_; returnT; forEachT)
open import Cxm.Commands
open import Cxm.Store.Interface using (appointmentsT; episodesT; tget)
open import Cxm.Api using (okJson; errJson; errResp; commit; commitUnit)
open import PsychCxm.Catalog
open import PsychCxm.Payments using (PayConfig; postCreate; postRecord; postWebhook)

------------------------------------------------------------------------
-- Local JSON helpers + defaulting
------------------------------------------------------------------------

private
  str : String → String
  str s = "\"" <> escapeJsonString s <> "\""

  arr : List String → String
  arr xs = "[" <> foldr joinC "" xs <> "]"
    where joinC : String → String → String
          joinC x ""  = x
          joinC x acc = x <> "," <> acc

  slotJson : Interval → String
  slotJson s = "{\"start\":" <> show (proj₁ s) <> ",\"end\":" <> show (proj₂ s) <> "}"

  offeringJson : Offering → String
  offeringJson o = "{\"code\":" <> show (oCode o) <> ",\"label\":" <> str (oLabel o)
    <> ",\"sessions\":" <> show (oSessions o) <> ",\"price\":" <> show (oPriceKop o) <> "}"

  -- package status: prepaid credits total/used/left for a package episode
  packageJson : Base → (episode : ℕ) → Offering → String
  packageJson b eng o =
    let used = sessionsUsedForEpisode b eng in
    "{\"eng\":" <> show eng <> ",\"offering\":" <> show (oCode o)
    <> ",\"label\":" <> str (oLabel o)
    <> ",\"sessionsTotal\":" <> show (oSessions o)
    <> ",\"sessionsUsed\":"  <> show used
    <> ",\"sessionsLeft\":"  <> show (oSessions o ∸ used)
    <> ",\"price\":" <> show (oPriceKop o) <> "}"

  orType : Maybe String → SlotType
  orType (just t) with parseSlotType t
  ... | just ty = ty
  ... | nothing = Session
  orType nothing = Session

  fieldOr : HttpRequest → String → String → String
  fieldOr req name dflt with jsonGetField name (reqBody req)
  ... | just v  = v
  ... | nothing = dflt

  natOr : HttpRequest → String → ℕ → ℕ
  natOr req name dflt with jsonGetNat name (reqBody req)
  ... | just v  = v
  ... | nothing = dflt

------------------------------------------------------------------------
-- Handlers
------------------------------------------------------------------------

getOfferings : IO HttpResponse
getOfferings = pure (okJson (arr (map offeringJson offerings)))

-- POST /psych/purchase {offering,name,email} → buy a prepaid package: resolve-or-create the client,
-- open a package Episode (offering code stored in jtbd), grant the offering Entitlement. {data:{id}}
postPurchase : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postPurchase h req = getCurrentTime >>= λ now → pick (jsonGetNat "offering" body) now
  where
    body = reqBody req
    purchaseTxn : (offering now : ℕ) (name email : String) → Txn ℕ
    purchaseTxn code now name email =
      ensureProtocol packageProtocol 0 defaultTenant now >>=T λ proto →
      resolveOrCreateSubject "email" email name "Europe/Moscow" defaultTenant now >>=T λ subj →
      createEpisode subj proto (jtbdFor code) defaultTenant now >>=T λ ep →
      grantEntitlement subj TOffering code now nothing SGrant defaultTenant now >>T
      returnT ep
    pick : Maybe ℕ → ℕ → IO HttpResponse
    pick nothing     _   = pure (errJson 400 "validation" "missing offering")
    pick (just code) now with offeringOf code
    ... | nothing = pure (errJson 404 "not_found" "unknown offering")
    ... | just _  = commit h (purchaseTxn code now (fieldOr req "name" "") (fieldOr req "email" ""))

-- POST /psych/session {eng,start} → book one session against a package episode (draws a credit;
-- rejects Insufficient when all prepaid sessions are used). {data:{id}}
postSession : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postSession h req = getCurrentTime >>= λ now → readBase h >>= λ b →
  pick (jsonGetNat "eng" body) (jsonGetNat "start" body) now b
  where
    body = reqBody req
    pick : Maybe ℕ → Maybe ℕ → ℕ → Base → IO HttpResponse
    pick (just eng) (just start) now b with tget episodesT eng b
    ... | nothing = pure (errJson 404 "not_found" "episode not found")
    ... | just e  with offeringFromJtbd (epJtbd e)
    ...   | nothing = pure (errJson 404 "not_found" "not a package")
    ...   | just o  = commit h (bookIntoEpisode (epSubject e) 0 eng nothing (oSessions o)
                                                start (durationMin Session) defaultTenant now)
    pick _ _ _ _ = pure (errJson 400 "validation" "missing eng/start")

-- POST /psych/package {eng} → package status (sessions total/used/left, price)
postPackage : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postPackage h req = readBase h >>= λ b → pick (jsonGetNat "eng" (reqBody req)) b
  where
    pick : Maybe ℕ → Base → IO HttpResponse
    pick nothing    _ = pure (errJson 400 "validation" "missing eng")
    pick (just eng) b with tget episodesT eng b
    ... | nothing = pure (errJson 404 "not_found" "engagement not found")
    ... | just e  with offeringFromJtbd (epJtbd e)
    ...   | nothing = pure (errJson 404 "not_found" "not a package")
    ...   | just o  = pure (okJson (packageJson b eng o))

-- free slots = the working grid over the horizon minus the operator's booked appointments
postAvailability : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postAvailability h req = getCurrentTime >>= λ now → readBase h >>= λ b →
  let dur  = durationMin (orType (jsonGetField "type" (reqBody req)))
      from = natOr req "from" now
      days = natOr req "days" (setHorizonDays settings)
  in pure (okJson (arr (map slotJson (availabilityFrom settings dur now from days (resourceBusy b 0)))))

-- validate the slot (on-grid/notice/horizon), then create client + identity + appointment +
-- confirmation in ONE Txn (all-or-nothing).
postBook : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postBook h req = getCurrentTime >>= λ now → go now
  where
    body = reqBody req
    -- resolve-or-create the client by email (identity bridge — audit #1: no duplicate subjects
    -- for a returning client), then book + confirm, all in one Txn.
    bookTxn : (now start dur : ℕ) (name email : String) → Txn ℕ
    bookTxn now start dur name email =
      resolveOrCreateSubject "email" email name "Europe/Moscow" defaultTenant now >>=T λ sid →
      bookAppointment sid 0 nothing nothing start dur defaultTenant now >>=T λ aid →
      enqueueNotification "email" email "Подтверждение записи" "Вы записаны на встречу." defaultTenant now >>T
      returnT aid
    go : ℕ → IO HttpResponse
    go now with jsonGetNat "start" body
    ... | nothing    = pure (errJson 400 "validation" "missing start")
    ... | just start with durationMin (orType (jsonGetField "type" body))
    ...   | dur with validateSlot settings dur now start
    ...     | just msg = pure (errJson 400 "validation" msg)
    ...     | nothing  = commit h (bookTxn now start dur (fieldOr req "name" "") (fieldOr req "email" ""))

-- cancel with the 24h rule: free-cancel window ⇒ Canceled (credit freed); else NoShow (forfeit)
postCancel : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postCancel h req = getCurrentTime >>= λ now → readBase h >>= λ b → pick (jsonGetNat "act" (reqBody req)) now b
  where
    commitResult : String → Txn ⊤ → IO HttpResponse
    commitResult label tx = commitTxn h tx >>= λ where
      (committed _) → pure (okJson ("{\"result\":" <> str label <> "}"))
      (rejected e)  → pure (errResp e)
      ioFailed      → pure (errJson 503 "internal" "storage write failed")
    pick : Maybe ℕ → ℕ → Base → IO HttpResponse
    pick nothing    _   _ = pure (errJson 400 "validation" "missing act")
    pick (just act) now b with tget appointmentsT act b
    ... | nothing = pure (errJson 404 "not_found" "appointment not found")
    ... | just a  = if freeCancelWindow settings now (apStartsAt a)
                    then commitResult "canceled"      (cancelAppointment act)
                    else commitResult "late_canceled" (noShowAppointment act)

postComplete postNoShow postReopen : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postComplete h req = commitUnit h (completeAppointment (natOr req "act" 0))
postNoShow   h req = commitUnit h (noShowAppointment   (natOr req "act" 0))
postReopen   h req = commitUnit h (reopenAppointment   (natOr req "act" 0))

-- enqueue a reminder for each upcoming session in the lead window, mark it reminded (idempotent)
-- reminder cron → core `remindDueAppointments` (resolves each client's email, enqueues, marks)
postRunReminders : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postRunReminders h req = getCurrentTime >>= λ now →
  commitTxn h (remindDueAppointments now (natOr req "leadHours" 24 * 3600)) >>= λ where
    (committed n) → pure (okJson ("{\"reminded\":" <> show n <> "}"))
    (rejected e)  → pure (errResp e)
    ioFailed      → pure (errJson 503 "internal" "storage write failed")

------------------------------------------------------------------------
-- Route hook: just resp for /psych/*, nothing otherwise
------------------------------------------------------------------------

tryRoute : PayConfig → WalHandle Base CxmOp → HttpRequest → IO (Maybe HttpResponse)
tryRoute pcfg h req =
  let m = reqMethod req ; p = reqPath req
      some : IO HttpResponse → IO (Maybe HttpResponse)
      some io = io >>= λ r → pure (just r)
  in if eqStrCI m "GET" ∧ eqStrCI p "/psych/offerings"          then some getOfferings
  else if eqStrCI m "POST" ∧ eqStrCI p "/psych/availability"    then some (postAvailability h req)
  else if eqStrCI m "POST" ∧ eqStrCI p "/psych/book"            then some (postBook h req)
  else if eqStrCI m "POST" ∧ eqStrCI p "/psych/purchase"        then some (postPurchase h req)
  else if eqStrCI m "POST" ∧ eqStrCI p "/psych/session"         then some (postSession h req)
  else if eqStrCI m "POST" ∧ eqStrCI p "/psych/package"         then some (postPackage h req)
  else if eqStrCI m "POST" ∧ eqStrCI p "/psych/cancel"          then some (postCancel h req)
  else if eqStrCI m "POST" ∧ eqStrCI p "/psych/complete"        then some (postComplete h req)
  else if eqStrCI m "POST" ∧ eqStrCI p "/psych/no-show"         then some (postNoShow h req)
  else if eqStrCI m "POST" ∧ eqStrCI p "/psych/reopen"          then some (postReopen h req)
  else if eqStrCI m "POST" ∧ eqStrCI p "/psych/reminders/run"   then some (postRunReminders h req)
  else if eqStrCI m "POST" ∧ eqStrCI p "/payments/create"       then some (postCreate pcfg h req)
  else if eqStrCI m "POST" ∧ eqStrCI p "/payments/record"       then some (postRecord h req)
  else if eqStrCI m "POST" ∧ eqStrCI p "/payments/webhook"      then some (postWebhook pcfg h req)
  else pure nothing
