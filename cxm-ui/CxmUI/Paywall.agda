{-# OPTIONS --without-K #-}

-- CxmUI.Paywall — the purchase widget (Ф3.4): the viewer-facing offering list with buy buttons.
-- Buying starts a PENDING payment at the SERVER-side price (/v1/purchase); confirmation is the
-- provider webhook's job (/payments/succeed) — this widget only reports the created payment and
-- tells the viewer that content unlocks after payment (entitlement lands on the next read, so
-- the site refreshes its feed/thread widgets). Matching an offering to the node it unlocks is
-- site-side (ofMetadata carries the grants plan). Brand-neutral; a site mounts `paywallApp v1cfg`.
module CxmUI.Paywall where

open import Data.Bool using (if_then_else_)
open import Data.Nat using (ℕ; _<ᵇ_)
open import Data.Nat.DivMod using (_/_; _%_)
open import Data.Nat.Show using (show)
open import Data.String using (String; _++_)
open import Data.List using (List; []; _∷_; [_])

open import Agdelte.Core.Result using (Result; ok; err)
open import Agdelte.Core.Cmd using (Cmd; ε)
open import Agdelte.Core.Event using (never)
open import Agdelte.Reactive.Node

open import CxmUI.Contract
open import CxmUI.Client
open import CxmUI.Widget using (errText; emptyOr; toolbar)

record Model : Set where
  constructor mkModel
  field
    cfg    : V1Cfg
    items  : List OfferingView
    status : String
open Model public

initModel : V1Cfg → Model
initModel c = mkModel c [] "нажми «Обновить» — что можно купить"

data Msg : Set where
  Load   : Msg
  Got    : Result CallErr (List OfferingView) → Msg
  Buy    : ℕ → Msg                       -- offering id
  Bought : Result CallErr ℕ → Msg        -- payment id

updateModel : Msg → Model → Model
updateModel Load m = record m { status = "загрузка предложений…" }
updateModel (Got (ok xs)) m = record m { items = xs ; status = emptyOr "предложений нет" xs }
updateModel (Got (err e)) m = record m { status = errText e }
updateModel (Buy off) m = record m { status = ("покупка #" ++ show off ++ "…") }
updateModel (Bought (ok pid)) m =
  record m { status = ("платёж #" ++ show pid ++ " создан — после оплаты контент откроется") }
updateModel (Bought (err e)) m = record m { status = errText e }

cmdOf : Msg → Model → Cmd Msg
cmdOf Load      m = offeringsV1 (cfg m) Got
cmdOf (Buy off) m = purchase (cfg m) off "" Bought
cmdOf _         _ = ε

-- kopecks → "500.00" (minor units, always two decimals)
showAmount : ℕ → String
showAmount p = show (p / 100) ++ "." ++ (if (p % 100) <ᵇ 10 then "0" else "") ++ show (p % 100)

private
  offerRow : OfferingView → ℕ → Node Model Msg
  offerRow o _ = li (class ("cxm-offer cxm-offer-" ++ show (ofId o)) ∷ [])
    ( span (class "cxm-offer-id" ∷ []) [ text ("№" ++ show (ofId o)) ]
    ∷ span (class "cxm-offer-price" ∷ [])
        [ text (showAmount (ofPrice o) ++ " " ++ ofCurrency o) ]
    ∷ button (onClick (Buy (ofId o)) ∷ class "cxm-buy" ∷ []) [ text "Купить" ]
    ∷ [] )

paywallTemplate : Node Model Msg
paywallTemplate =
  div (class "cxm-paywall" ∷ [])
    ( toolbar "Обновить" Load status
    ∷ ul [] ( foreachKeyed items (λ o → show (ofId o)) offerRow ∷ [] )
    ∷ [] )

paywallApp : V1Cfg → ReactiveApp Model Msg
paywallApp c = mkReactiveApp (initModel c) updateModel paywallTemplate cmdOf (λ _ → never)
