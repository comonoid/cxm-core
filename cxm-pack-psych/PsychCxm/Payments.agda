{-# OPTIONS --without-K --guardedness #-}

-- PsychCxm.Payments — the online-payment flow (§4.15) on the ЮKassa client (agdelte-payments),
-- REBUILT on agdelte-cxm. Contour-agnostic: TEST vs PROD = which YOOKASSA_SHOP_ID/SECRET_KEY are
-- set. The outbound createPayment needs network/creds (live-tested in deployment); the webhook →
-- GRANT path is pure store logic.
--
--   POST /payments/create  {offering,name,email} → createPayment → record pending +
--                          {paymentId, confirmationUrl}
--   POST /payments/record  {extId,offering,name,email,amount} → record pending directly
--                          (manual/reconciliation)
--   POST /payments/webhook → verify sig → on payment.succeeded: mark succeeded (grants the
--                          Entitlement, idempotent) + open the package Episode, in ONE Txn.
module PsychCxm.Payments where

open import Agda.Builtin.IO using (IO)
open import Agda.Builtin.String using (primStringEquality)
open import Data.Nat using (ℕ; _/_)
open import Data.Nat.Show using (show)
open import Data.Bool using (Bool; true; false; if_then_else_)
open import Data.List using (null)
open import Data.Maybe using (Maybe; just; nothing)
open import Data.String using (String; toList) renaming (_++_ to _<>_)

open import Agdelte.FFI.Server using
  ( HttpRequest; HttpResponse; reqBody; reqHeaders; lookupHeader; _>>=_; pure )
open import Agdelte.FFI.Json using (jsonGetField; jsonGetNat)
open import Agdelte.FFI.Time using (getCurrentTime)

open import Cxm.Tenant using (defaultTenant)
open import Cxm.Payment using (Payment; PayStatus; PayPending; payId; payOffering; paySubject; payStatus)
open import Cxm.Store.Base using (Base; CxmOp; NotFound; Conflict)
open import Cxm.Store.Wal using (WalHandle; commitTxn; committed; rejected; ioFailed)
open import Cxm.Txn using (Txn; _>>=T_; _>>T_; returnT; requireJust; guardT)
open import Cxm.Commands using
  ( recordPayment; findPaymentByExtId; markPaymentSucceeded
  ; resolveOrCreateSubject; ensureProtocol; createEpisode )
open import Cxm.Api using (okJson; errJson; errResp; commit)
open import Agdelte.Payment.YooKassa as YK using
  ( HttpManager; createPayment; parseWebhookFields; verifyWebhookSig
  ; PaymentResult; PaymentOk; PaymentError; rpFst; rpSnd )
open import PsychCxm.Catalog using (Offering; offeringOf; oLabel; oPriceKop; jtbdFor; packageProtocol)

private
  _==ˢ_ : String → String → Bool
  a ==ˢ b = primStringEquality a b

  isEmpty : String → Bool
  isEmpty s = null (toList s)

  rubles : ℕ → String                 -- kopecks → ЮKassa "RUB.kk" (prices are whole rubles)
  rubles kop = show (kop / 100) <> ".00"

  orStr : Maybe String → String → String
  orStr (just s) _ = s
  orStr nothing  d = d

  orNat : Maybe ℕ → ℕ
  orNat (just n) = n
  orNat nothing  = 0

  isPending : PayStatus → Bool
  isPending PayPending = true
  isPending _          = false

------------------------------------------------------------------------
-- Config (env at startup): ЮKassa creds + connection manager
------------------------------------------------------------------------

record PayConfig : Set where
  constructor mkPayConfig
  field
    pcManager       : HttpManager
    pcShopId        : String
    pcKey           : String
    pcWebhookSecret : String       -- "" = signature verification off (dev)
    pcReturnUrl     : String
open PayConfig public

------------------------------------------------------------------------
-- GRANT (money-critical, idempotent): for a succeeded payment, mark it succeeded (which grants the
-- offering Entitlement to the buyer) AND open the package Episode — in ONE Txn. guardT Conflict if
-- not still pending, so at-least-once webhook redelivery (§4.15) never double-grants.
------------------------------------------------------------------------

grantTxn : (extId : String) (now : ℕ) → Txn ℕ
grantTxn ext now =
  findPaymentByExtId ext >>=T requireJust NotFound >>=T λ p →
  guardT (isPending (payStatus p)) Conflict >>T
  markPaymentSucceeded (payId p) now >>T
  ensureProtocol packageProtocol 0 defaultTenant now >>=T λ proto →
  createEpisode (paySubject p) proto (jtbdFor (payOffering p)) defaultTenant now

------------------------------------------------------------------------
-- Handlers
------------------------------------------------------------------------

-- POST /payments/create — ЮKassa payment + record pending (buyer resolved-or-created by email)
postCreate : PayConfig → WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postCreate cfg h req = pick (jsonGetNat "offering" body)
  where
    body  = reqBody req
    name  = orStr (jsonGetField "name"  body) ""
    email = orStr (jsonGetField "email" body) ""

    record-and-reply : ℕ → Offering → String → String → ℕ → IO HttpResponse
    record-and-reply off o extId url now =
      commitTxn h (resolveOrCreateSubject "email" email name "Europe/Moscow" defaultTenant now >>=T λ subj →
                   recordPayment extId off subj (oPriceKop o) name email defaultTenant now) >>= λ where
        (committed pid) → pure (okJson ("{\"paymentId\":" <> show pid
                                        <> ",\"confirmationUrl\":\"" <> url <> "\"}"))
        (rejected e)    → pure (errResp e)
        ioFailed        → pure (errJson 503 "internal" "storage write failed")

    go : ℕ → Maybe Offering → IO HttpResponse
    go off nothing  = pure (errJson 404 "not_found" "unknown offering")
    go off (just o) =
      getCurrentTime >>= λ now →
      createPayment (pcManager cfg) (pcShopId cfg) (pcKey cfg)
                    (rubles (oPriceKop o)) (oLabel o) (pcReturnUrl cfg)
                    ("psych-" <> show now <> "-" <> show off) email >>= λ where
        (PaymentOk extId url) → record-and-reply off o extId url now
        (PaymentError _ txt)  → pure (errJson 502 "payment_provider" txt)

    pick : Maybe ℕ → IO HttpResponse
    pick nothing    = pure (errJson 400 "validation" "missing offering")
    pick (just off) = go off (offeringOf off)

-- POST /payments/record — record a pending payment directly (manual/reconciliation)
postRecord : WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postRecord h req = pick (jsonGetField "extId" body) (jsonGetNat "offering" body)
  where
    body  = reqBody req
    name  = orStr (jsonGetField "name"  body) ""
    email = orStr (jsonGetField "email" body) ""
    pick : Maybe String → Maybe ℕ → IO HttpResponse
    pick (just ext) (just off) =
      getCurrentTime >>= λ now →
      commit h (resolveOrCreateSubject "email" email name "Europe/Moscow" defaultTenant now >>=T λ subj →
                recordPayment ext off subj (orNat (jsonGetNat "amount" body)) name email defaultTenant now)
    pick _ _ = pure (errJson 400 "validation" "missing extId/offering")

-- POST /payments/webhook — verify, then on payment.succeeded grant the package
postWebhook : PayConfig → WalHandle Base CxmOp → HttpRequest → IO HttpResponse
postWebhook cfg h req =
  if verified then handle (parseWebhookFields body)
  else pure (errJson 401 "unauthorized" "bad webhook signature")
  where
    body = reqBody req
    sig  = orStr (lookupHeader "x-yookassa-signature" (reqHeaders req)) ""
    verified : Bool
    verified = if isEmpty (pcWebhookSecret cfg) then true
               else verifyWebhookSig (pcWebhookSecret cfg) sig body

    grant : String → IO HttpResponse
    grant ext =
      getCurrentTime >>= λ now →
      commitTxn h (grantTxn ext now) >>= λ where
        (committed eng) → pure (okJson ("{\"granted\":true,\"engagement\":" <> show eng <> "}"))
        (rejected _)    → pure (okJson "{\"granted\":false,\"idempotent\":true}")
        ioFailed        → pure (errJson 503 "internal" "storage write failed")

    handle : Maybe YK.RawPair → IO HttpResponse
    handle nothing   = pure (errJson 400 "validation" "unparseable webhook")
    handle (just pr) =
      if rpFst pr ==ˢ "payment.succeeded" then grant (rpSnd pr)
      else pure (okJson "{\"ignored\":true}")
