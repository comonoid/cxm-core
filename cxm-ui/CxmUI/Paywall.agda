{-# OPTIONS --without-K #-}

-- CxmUI.Paywall — the purchase widget (Ф3.4): the viewer-facing offering list with buy buttons.
-- Buying starts a PENDING payment at the SERVER-side price (/v1/purchase); confirmation is the
-- provider webhook's job (/payments/succeed) — content unlocks on the next read, so the site
-- refreshes its feed/thread widgets after payment.
--
-- Site hooks (аудит №10): `lastPayment` in the Model carries the created payment id — an
-- embedding site (composing its own app from the PUBLIC pieces) reads it after `Bought` to hand
-- to the payment provider; `extId` (V1Cfg-independent, set at mount) correlates the provider's
-- webhook. Buy is busy-guarded: no double submits (аудит №4).
module CxmUI.Paywall where

open import Data.Bool using (Bool; true; false)
open import Data.Nat using (ℕ)
open import Data.Nat.Show using (show)
open import Data.String using (String; _++_)
open import Data.List using (List; []; _∷_; [_])

open import Agdelte.Core.Result using (Result; ok; err)
open import Agdelte.Core.Cmd using (Cmd; ε)
open import Agdelte.Core.Event using (never)
open import Agdelte.Reactive.Node

open import CxmUI.Contract
open import CxmUI.Client
open import CxmUI.Text
open import CxmUI.Widget using (errText; emptyOr; toolbar; showAmount)

record Model : Set where
  constructor mkModel
  field
    cfg         : V1Cfg
    extId       : String              -- provider-correlation id for purchases ("" = none)
    items       : List OfferingView
    status      : String
    busy        : Bool                -- purchase in flight → «Купить» выключены
    lastPayment : ℕ                   -- id последнего созданного платежа (0 = нет) — сайт читает
open Model public

initModel : V1Cfg → String → Model
initModel c ext = mkModel c ext [] tPaywallHint false 0

data Msg : Set where
  Load   : Msg
  Got    : Result CallErr (List OfferingView) → Msg
  Buy    : ℕ → Msg                       -- offering id
  Bought : Result CallErr ℕ → Msg        -- payment id

updateModel : Msg → Model → Model
updateModel Load m = record m { status = tPaywallLoading }
updateModel (Got (ok xs)) m = record m { items = xs ; status = emptyOr tPaywallEmpty xs }
updateModel (Got (err e)) m = record m { status = errText e }
updateModel (Buy off) m = record m { status = tBuying ++ show off ++ tEllipsis ; busy = true }
updateModel (Bought (ok pid)) m =
  record m { status = tPayment ++ show pid ++ tPaymentCreated ; busy = false ; lastPayment = pid }
updateModel (Bought (err e)) m = record m { status = errText e ; busy = false }

cmdOf : Msg → Model → Cmd Msg
cmdOf Load      m = offeringsV1 (cfg m) Got
cmdOf (Buy off) m = purchase (cfg m) off (extId m) Bought
cmdOf _         _ = ε

offerRow : OfferingView → ℕ → Node Model Msg
offerRow o _ = li (class ("cxm-offer cxm-offer-" ++ show (ofId o)) ∷ [])
  ( span (class "cxm-offer-id" ∷ []) [ text (tOfferNo ++ show (ofId o)) ]
  ∷ span (class "cxm-offer-price" ∷ [])
      [ text (showAmount (ofPrice o) ++ " " ++ ofCurrency o) ]
  ∷ button (onClick (Buy (ofId o)) ∷ disabledBind busy ∷ class "cxm-buy" ∷ []) [ text tBuy ]
  ∷ [] )

paywallTemplate : Node Model Msg
paywallTemplate =
  div (class "cxm-paywall" ∷ [])
    ( toolbar tReload Load status
    ∷ ul [] ( foreachKeyed items (λ o → show (ofId o)) offerRow ∷ [] )
    ∷ [] )

paywallAppWith : V1Cfg → (extId : String) → ReactiveApp Model Msg
paywallAppWith c ext = mkReactiveApp (initModel c ext) updateModel paywallTemplate cmdOf (λ _ → never)

paywallApp : V1Cfg → ReactiveApp Model Msg
paywallApp c = paywallAppWith c ""
