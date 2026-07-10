{-# OPTIONS --without-K --guardedness #-}

-- PsychCxm.Server — П4b: маршрутный слой пака /psych/* + /payments/* на cxm-server-pg
-- (порт легаси PsychCxm.{Api,Payments} с WAL-Txn на PG-Tx; контракт 1:1 с PsychCxm.Client).
-- Сервер пак только МОНТИРУЕТ (isPsychPath → tryPsych/payCreateIO) — вся вертикальная
-- семантика здесь; ядро нейтрально, Err→HTTP делает серверный runW (аборты команд ядра
-- доезжают как 404/409/402/…).
--
--   GET  /psych/offerings                      → {data:[{code,label,sessions,price}]}
--   POST /psych/availability {type,from,days}  → {data:[{start,end}]}   (сетка − брони)
--   POST /psych/book {type,start,name,email}   → {data:{id}} + письмо-подтверждение (outbox)
--   POST /psych/purchase {offering,name,email} → {data:{id}} (пакетный эпизод; прямой грант —
--        ручная/офлайн оплата; онлайн-путь — /payments/create + webhook)
--   POST /psych/session {eng,start}            → {data:{id}} | 402 Insufficient (кредиты)
--   POST /psych/package {eng}                  → {data:{eng,offering,label,sessionsTotal/Used/Left,price}}
--   POST /psych/cancel {act}                   → {data:{result:"canceled"|"late_canceled"}} (24h-правило)
--   POST /psych/complete|no-show|reopen {act}  → {data:{ok:true}}
--   POST /psych/reminders/run {leadHours}      → {data:{reminded:N}} (воркер и так гоняет)
--   POST /payments/create {offering,name,email}→ ЮKassa (или dev-стаб без YOOKASSA_SHOP_ID)
--        → pending + {paymentId,confirmationUrl[,extId в dev]}
--   POST /payments/record {extId,offering,…}   → pending вручную (реконсиляция)
--   POST /payments/webhook                     → подпись → payment.succeeded: succeed
--        (fulfilment-гранты) + пакетный эпизод, ОДНА транзакция; редоставка → 200 idempotent
module PsychCxm.Server where

open import Agda.Builtin.IO using (IO)
open import Agda.Builtin.Unit using (⊤; tt)
open import Agda.Builtin.String using (primStringEquality)
open import Data.Nat using (ℕ; suc; _*_; _∸_; _/_; _≡ᵇ_; _<ᵇ_)
open import Data.Nat.Show using (show)
open import Data.Bool using (Bool; true; false; if_then_else_; _∧_; _∨_; not)
open import Data.Char using (Char)
open import Data.List using (List; []; _∷_; foldr; map; null)
open import Data.Maybe using (Maybe; just; nothing; maybe′)
open import Data.Product using (_×_; _,_; proj₁; proj₂)
open import Data.String using (String; toList) renaming (_++_ to _<>_)

open import Agdelte.FFI.Server using
  ( HttpRequest; HttpResponse; reqMethod; reqPath; reqBody; reqHeaders; lookupHeader
  ; mkResponse; eqStrCI; _>>=_; pure )
open import Agdelte.FFI.Json using (jsonGetField; jsonGetNat; escapeJsonString)
import Agdelte.Payment.YooKassa as YK

open import Cxm.Appointment using
  ( Appointment; apStartsAt; apStatus; apEpisode
  ; ApptStatus; ApScheduled; ApCanceled; ApCompleted; ApNoShow )
open import Cxm.Episode using (Episode; epJtbd; epSubject)
open import Cxm.Entitlement using (TOffering; SGrant)
open import Cxm.Payment using (Payment; payId; payOffering; paySubject; payStatus; PayStatus; PayPending)
open import Cxm.Schedule using
  ( Settings; Interval; availabilityFrom; validateSlot; freeCancelWindow; setHorizonDays )
open import Cxm.Store.Base using (Err; NotFound; Conflict; Insufficient)
open import Cxm.Store.Verbs
open import Cxm.CommandsV
open import PsychCxm.Catalog

------------------------------------------------------------------------
-- Конфиг платежей (env при старте; pcShopId "" = dev-стаб без сети)
------------------------------------------------------------------------

record PayConfig : Set where
  constructor mkPayConfig
  field
    pcManager       : YK.HttpManager
    pcShopId        : String
    pcKey           : String
    pcWebhookSecret : String       -- "" = проверка подписи выключена (dev)
    pcReturnUrl     : String
open PayConfig public

------------------------------------------------------------------------
-- Локальные JSON/HTTP хелперы (конверт как у сервера; его энкодеры private)
------------------------------------------------------------------------

private
  str : String → String
  str s = "\"" <> escapeJsonString s <> "\""

  arr : List String → String
  arr xs = "[" <> foldr joinC "" xs <> "]"
    where joinC : String → String → String
          joinC x ""  = x
          joinC x acc = x <> "," <> acc

  okJson : String → HttpResponse
  okJson body = mkResponse 200 ("{\"data\":" <> body <> "}")

  errJson : ℕ → String → String → HttpResponse
  errJson st code msg =
    mkResponse st ("{\"error\":{\"code\":" <> str code <> ",\"message\":" <> str msg <> "}}")

  idJson : ℕ → HttpResponse
  idJson n = okJson ("{\"id\":" <> show n <> "}")

  slotJson : Interval → String
  slotJson s = "{\"start\":" <> show (proj₁ s) <> ",\"end\":" <> show (proj₂ s) <> "}"

  offeringJson : Offering → String
  offeringJson o = "{\"code\":" <> show (oCode o) <> ",\"label\":" <> str (oLabel o)
    <> ",\"sessions\":" <> show (oSessions o) <> ",\"price\":" <> show (oPriceKop o) <> "}"

  fieldOr : HttpRequest → String → String → String
  fieldOr req k d = maybe′ (λ v → v) d (jsonGetField k (reqBody req))

  natOr : HttpRequest → String → ℕ → ℕ
  natOr req k d = maybe′ (λ v → v) d (jsonGetNat k (reqBody req))

  orType : Maybe String → SlotType
  orType (just t) = maybe′ (λ ty → ty) Session (parseSlotType t)
  orType nothing  = Session

  rubles : ℕ → String                -- копейки → ЮKassa "RUB.kk" (цены — целые рубли)
  rubles kop = show (kop / 100) <> ".00"

  isPending : PayStatus → Bool
  isPending PayPending = true
  isPending _          = false

------------------------------------------------------------------------
-- Доменные читалки пака (кредиты пакета)
------------------------------------------------------------------------

private
  -- потреблённые кредиты эпизода: не-отменённые брони (Canceled освобождает, NoShow сжигает)
  consumesᵇ : ApptStatus → Bool
  consumesᵇ ApCanceled = false
  consumesᵇ _          = true

  matchEpᵇ : Maybe ℕ → ℕ → Bool
  matchEpᵇ (just x) ep = x ≡ᵇ ep
  matchEpᵇ nothing  _  = false

  sessionsUsedV : (episode : ℕ) → Tx ℕ
  sessionsUsedV ep = scan tcAppointment >>=T λ rows → returnT (foldr step 0 rows)
    where step : ℕ × Appointment → ℕ → ℕ
          step (_ , a) acc =
            if matchEpᵇ (apEpisode a) ep ∧ consumesᵇ (apStatus a) then suc acc else acc

  packageJson : (eng used : ℕ) → Offering → String
  packageJson eng used o =
    "{\"eng\":" <> show eng <> ",\"offering\":" <> show (oCode o)
    <> ",\"label\":" <> str (oLabel o)
    <> ",\"sessionsTotal\":" <> show (oSessions o)
    <> ",\"sessionsUsed\":"  <> show used
    <> ",\"sessionsLeft\":"  <> show (oSessions o ∸ used)
    <> ",\"price\":" <> show (oPriceKop o) <> "}"

------------------------------------------------------------------------
-- Tx-обработчики
------------------------------------------------------------------------

private
  -- бронь: слот валиден (сетка/notice/горизонт — b4-политики из Catalog.settings) →
  -- клиент по email (identity-мост: без дублей субъектов) + бронь + письмо, ОДНА транзакция
  bookTx : (req : HttpRequest) (ten now : ℕ) → Tx HttpResponse
  bookTx req ten now with jsonGetNat "start" (reqBody req)
  ... | nothing = returnT (errJson 400 "validation" "missing start")
  ... | just start with durationMin (orType (jsonGetField "type" (reqBody req)))
  ...   | dur with validateSlot settings dur now start
  ...     | just msg = returnT (errJson 400 "validation" msg)
  ...     | nothing =
            resolveOrCreateSubjectV "email" (fieldOr req "email" "") (fieldOr req "name" "")
              "Europe/Moscow" ten now >>=T λ subj →
            bookAppointmentV subj 0 nothing nothing start dur ten now >>=T λ aid →
            enqueueNotificationV "email" (fieldOr req "email" "")
              "Подтверждение записи" "Вы записаны на встречу." ten now >>T
            returnT (idJson aid)

  -- прямой грант пакета (ручная/офлайн оплата): эпизод (код офферинга в jtbd) + entitlement
  purchaseTx : (req : HttpRequest) (ten now : ℕ) → Tx HttpResponse
  purchaseTx req ten now with jsonGetNat "offering" (reqBody req)
  ... | nothing = returnT (errJson 400 "validation" "missing offering")
  ... | just code with offeringOf code
  ...   | nothing = returnT (errJson 404 "not_found" "unknown offering")
  ...   | just _ =
          ensureProtocolV packageProtocol 0 ten now >>=T λ proto →
          resolveOrCreateSubjectV "email" (fieldOr req "email" "") (fieldOr req "name" "")
            "Europe/Moscow" ten now >>=T λ subj →
          createEpisodeV subj proto (jtbdFor code) ten now >>=T λ ep →
          grantEntitlementV subj TOffering code now nothing SGrant ten now >>T
          returnT (idJson ep)

  -- сессия из пакета: кредит-гейт (Insufficient → 402) + бронь, привязанная к эпизоду
  sessionTx : (req : HttpRequest) (ten now : ℕ) → Tx HttpResponse
  sessionTx req ten now =
    require tcEpisode (natOr req "eng" 0) NotFound >>=T λ e →
    go (offeringFromJtbd (epJtbd e)) e
    where
      go : Maybe Offering → Episode → Tx HttpResponse
      go nothing  _ = returnT (errJson 404 "not_found" "not a package")
      go (just o) e =
        sessionsUsedV (natOr req "eng" 0) >>=T λ used →
        guardT (used <ᵇ oSessions o) Insufficient >>T
        bookAppointmentV (epSubject e) 0 (just (natOr req "eng" 0)) nothing
          (natOr req "start" 0) (durationMin Session) ten now >>=T λ aid →
        returnT (idJson aid)

  packageTx : (req : HttpRequest) → Tx HttpResponse
  packageTx req =
    require tcEpisode (natOr req "eng" 0) NotFound >>=T λ e →
    go (offeringFromJtbd (epJtbd e)) e
    where
      go : Maybe Offering → Episode → Tx HttpResponse
      go nothing  _ = returnT (errJson 404 "not_found" "not a package")
      go (just o) _ =
        sessionsUsedV (natOr req "eng" 0) >>=T λ used →
        returnT (okJson (packageJson (natOr req "eng" 0) used o))

  -- отмена по 24h-правилу (b4): в окне — Canceled (кредит освобождён), позже — NoShow (сгорел)
  cancelTx : (req : HttpRequest) (now : ℕ) → Tx HttpResponse
  cancelTx req now =
    require tcAppointment (natOr req "act" 0) NotFound >>=T λ a →
    if freeCancelWindow settings now (apStartsAt a)
    then cancelAppointmentV (natOr req "act" 0) >>T
         returnT (okJson "{\"result\":\"canceled\"}")
    else noShowAppointmentV (natOr req "act" 0) >>T
         returnT (okJson "{\"result\":\"late_canceled\"}")

  availabilityTx : (req : HttpRequest) (now : ℕ) → Tx HttpResponse
  availabilityTx req now =
    resourceBusyV 0 >>=T λ busy →
    returnT (okJson (arr (map slotJson
      (availabilityFrom settings (durationMin (orType (jsonGetField "type" (reqBody req))))
        now (natOr req "from" now) (natOr req "days" (setHorizonDays settings)) busy))))

  okUnitJson : ⊤ → HttpResponse
  okUnitJson _ = okJson "{\"ok\":true}"

  -- вебхук: подпись → payment.succeeded → succeed (fulfilment-гранты ядра) + пакетный
  -- эпизод, одна транзакция. Редоставка/чужой extId → 200 {"granted":false} (не 4xx —
  -- провайдер не должен ретраить идемпотентный повтор).
  webhookTx : PayConfig → (req : HttpRequest) (ten now : ℕ) → Tx HttpResponse
  webhookTx cfg req ten now =
    if not verifiedᵇ then returnT (errJson 401 "unauthorized" "bad webhook signature")
    else handle (YK.parseWebhookFields (reqBody req))
    where
      verifiedᵇ : Bool
      verifiedᵇ = if null (toList (pcWebhookSecret cfg)) then true
                  else YK.verifyWebhookSig (pcWebhookSecret cfg)
                         (maybe′ (λ s → s) "" (lookupHeader "x-yookassa-signature" (reqHeaders req)))
                         (reqBody req)
      idem : HttpResponse
      idem = okJson "{\"granted\":false,\"idempotent\":true}"
      openPackage : Payment → Maybe Offering → Tx HttpResponse
      openPackage _ nothing  = returnT (okJson "{\"granted\":true}")   -- не пакетный офферинг
      openPackage p (just _) =
        ensureProtocolV packageProtocol 0 ten now >>=T λ proto →
        createEpisodeV (paySubject p) proto (jtbdFor (payOffering p)) ten now >>=T λ ep →
        returnT (okJson ("{\"granted\":true,\"engagement\":" <> show ep <> "}"))
      grant : Maybe Payment → Tx HttpResponse
      grant nothing  = returnT idem
      grant (just p) =
        if not (isPending (payStatus p)) then returnT idem
        else markPaymentSucceededV (payId p) now >>T
             openPackage p (offeringOf (payOffering p))
      handle : Maybe YK.RawPair → Tx HttpResponse
      handle nothing   = returnT (errJson 400 "validation" "unparseable webhook")
      handle (just pr) =
        if primStringEquality (YK.rpFst pr) "payment.succeeded"
        then (findPaymentByExtIdV (YK.rpSnd pr) >>=T grant)
        else returnT (okJson "{\"ignored\":true}")

  recordTx : (req : HttpRequest) (ten now : ℕ) → Tx HttpResponse
  recordTx req ten now with jsonGetField "extId" (reqBody req) | jsonGetNat "offering" (reqBody req)
  ... | just ext | just off =
        resolveOrCreateSubjectV "email" (fieldOr req "email" "") (fieldOr req "name" "")
          "Europe/Moscow" ten now >>=T λ subj →
        recordPaymentV ext off subj (natOr req "amount" 0)
          (fieldOr req "name" "") (fieldOr req "email" "") ten now >>=T λ pid →
        returnT (idJson pid)
  ... | _ | _ = returnT (errJson 400 "validation" "missing extId/offering")

------------------------------------------------------------------------
-- Маунт-поверхность
------------------------------------------------------------------------

isPsychPath : String → Bool
isPsychPath p = pref (toList p)
  ∨ eqStrCI p "/payments/create" ∨ eqStrCI p "/payments/record" ∨ eqStrCI p "/payments/webhook"
  where
    pref : List Char → Bool
    pref ('/' ∷ 'p' ∷ 's' ∷ 'y' ∷ 'c' ∷ 'h' ∷ '/' ∷ _) = true
    pref _ = false

-- все Tx-маршруты пака; nothing = не наш путь (сервер отдаст 404)
tryPsych : PayConfig → HttpRequest → (tenant now : ℕ) → Maybe (Tx HttpResponse)
tryPsych cfg req ten now =
  let m = reqMethod req ; p = reqPath req
  in if eqStrCI m "GET" ∧ eqStrCI p "/psych/offerings" then
       just (returnT (okJson (arr (map offeringJson offerings))))
     else if eqStrCI m "POST" ∧ eqStrCI p "/psych/availability" then just (availabilityTx req now)
     else if eqStrCI m "POST" ∧ eqStrCI p "/psych/book" then just (bookTx req ten now)
     else if eqStrCI m "POST" ∧ eqStrCI p "/psych/purchase" then just (purchaseTx req ten now)
     else if eqStrCI m "POST" ∧ eqStrCI p "/psych/session" then just (sessionTx req ten now)
     else if eqStrCI m "POST" ∧ eqStrCI p "/psych/package" then just (packageTx req)
     else if eqStrCI m "POST" ∧ eqStrCI p "/psych/cancel" then just (cancelTx req now)
     else if eqStrCI m "POST" ∧ eqStrCI p "/psych/complete" then
       just (completeAppointmentV (natOr req "act" 0) >>=T λ u → returnT (okUnitJson u))
     else if eqStrCI m "POST" ∧ eqStrCI p "/psych/no-show" then
       just (noShowAppointmentV (natOr req "act" 0) >>=T λ u → returnT (okUnitJson u))
     else if eqStrCI m "POST" ∧ eqStrCI p "/psych/reopen" then
       just (reopenAppointmentV (natOr req "act" 0) >>=T λ u → returnT (okUnitJson u))
     else if eqStrCI m "POST" ∧ eqStrCI p "/psych/reminders/run" then
       just (remindDueAppointmentsV now (natOr req "leadHours" 24 * 3600) >>=T λ n →
             returnT (okJson ("{\"reminded\":" <> show n <> "}")))
     else if eqStrCI m "POST" ∧ eqStrCI p "/payments/record" then just (recordTx req ten now)
     else if eqStrCI m "POST" ∧ eqStrCI p "/payments/webhook" then just (webhookTx cfg req ten now)
     else nothing

-- /payments/create: сетевой вызов ЮKassa ВНЕ транзакции (или dev-стаб без YOOKASSA_SHOP_ID:
-- extId детерминированный, отдаётся в ответе — смоук доигрывает вебхуком), затем pending-Tx
payCreateIO : PayConfig → HttpRequest → (tenant now : ℕ) → IO (Tx HttpResponse)
payCreateIO cfg req ten now with jsonGetNat "offering" (reqBody req)
... | nothing = pure (returnT (errJson 400 "validation" "missing offering"))
... | just code with offeringOf code
...   | nothing = pure (returnT (errJson 404 "not_found" "unknown offering"))
...   | just o =
        if null (toList (pcShopId cfg))
        then pure (recordPending ("dev-" <> show now <> "-" <> show code)
                     ("https://pay.invalid/dev/" <> show now) true)
        else YK.createPayment (pcManager cfg) (pcShopId cfg) (pcKey cfg)
               (rubles (oPriceKop o)) (oLabel o) (pcReturnUrl cfg)
               ("psych-" <> show now <> "-" <> show code) "" >>= λ where
                 (YK.PaymentOk extId url) → pure (recordPending extId url false)
                 (YK.PaymentError _ txt)  → pure (returnT (errJson 502 "payment_provider" txt))
  where
    recordPending : (extId url : String) (dev : Bool) → Tx HttpResponse
    recordPending ext url dev =
      resolveOrCreateSubjectV "email" (fieldOr req "email" "") (fieldOr req "name" "")
        "Europe/Moscow" ten now >>=T λ subj →
      recordPaymentV ext (natOr req "offering" 0) subj
        (maybe′ oPriceKop 0 (offeringOf (natOr req "offering" 0)))
        (fieldOr req "name" "") (fieldOr req "email" "") ten now >>=T λ pid →
      returnT (okJson ("{\"paymentId\":" <> show pid
                       <> ",\"confirmationUrl\":" <> str url
                       <> (if dev then ",\"extId\":" <> str ext else "") <> "}"))
