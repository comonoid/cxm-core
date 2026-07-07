{-# OPTIONS --without-K #-}

-- SitePsych.Main — П4 «морда», Ф0: кабинет психолога (слой 3 — БРЕНД/композиция; контрактное —
-- в cxm-ui). Один agdelte-app: стадия Login (форма → Client.login, параллельно сверка версии
-- контракта через /health) → стадия Cabinet (ClientCard, встроенный embedding-паттерном:
-- Model содержит Card.Model, Msg оборачивает Card.Msg, template — zoomNode, cmd — mapCmd).
-- `app` — same-origin (браузер, дев-прокси); `appWith base` — параметризация для смоука.
module SitePsych.Main where

open import Data.Bool using (Bool; true; false; not; _∧_; if_then_else_)
open import Data.Nat using (ℕ; _≡ᵇ_)
open import Data.Nat.Show using (show)
open import Data.String using (String; _++_)
open import Data.List using (List; []; _∷_; [_])

open import Agdelte.Core.Result using (Result; ok; err)
open import Agdelte.Core.Cmd using (Cmd; ε; batch; mapCmd)
open import Agdelte.Core.Event using (never)
open import Agdelte.Reactive.Node

open import CxmUI.Contract using (HealthView; hContract; expectedContract)
open import CxmUI.Client using (Cfg; mkCfg; CallErr; login; health)
open import CxmUI.Widget using (errText)
import CxmUI.ClientCard as Card

------------------------------------------------------------------------
-- Model
------------------------------------------------------------------------

data Stage : Set where
  SLogin SCabinet : Stage

record Model : Set where
  constructor mkModel
  field
    base   : String       -- origin ("" = same-origin через дев-прокси)
    stage  : Stage
    lg pw  : String       -- форма логина
    banner : String       -- ошибки логина / дрейф контракта
    card   : Card.Model   -- переинициализируется с JWT после логина
open Model public

initModel : String → Model
initModel b = mkModel b SLogin "" "" "" (Card.initModel (mkCfg b ""))

private
  isLogin isCabinet : Model → Bool
  isLogin m with stage m
  ... | SLogin = true
  ... | SCabinet = false
  isCabinet m = not (isLogin m)

------------------------------------------------------------------------
-- Update / Cmd
------------------------------------------------------------------------

data Msg : Set where
  Lg Pw     : String → Msg
  DoLogin   : Msg
  GotJwt    : Result CallErr String → Msg
  GotHealth : Result CallErr HealthView → Msg
  CardMsg   : Card.Msg → Msg

updateModel : Msg → Model → Model
updateModel (Lg s) m = record m { lg = s }
updateModel (Pw s) m = record m { pw = s }
updateModel DoLogin m = record m { banner = "вхожу…" }
updateModel (GotJwt (ok jwt)) m =
  record m { stage = SCabinet ; banner = "" ; pw = ""
           ; card = Card.initModel (mkCfg (base m) jwt) }
updateModel (GotJwt (err e)) m = record m { banner = errText e }
updateModel (GotHealth (ok h)) m =
  if hContract h ≡ᵇ expectedContract then m
  else record m { banner = "⚠ версия контракта: сервер " ++ show (hContract h)
                          ++ " ≠ сайт " ++ show expectedContract }
updateModel (GotHealth (err e)) m = record m { banner = errText e }
updateModel (CardMsg cm) m = record m { card = Card.updateModel cm (card m) }

cmdOf : Msg → Model → Cmd Msg
cmdOf DoLogin m = batch ( health (mkCfg (base m) "") GotHealth
                        ∷ login (mkCfg (base m) "") (lg m) (pw m) GotJwt ∷ [] )
cmdOf (CardMsg cm) m = mapCmd CardMsg (Card.cmdOf cm (card m))
cmdOf _ _ = ε

------------------------------------------------------------------------
-- View (бренд-строки живут ЗДЕСЬ — слой 3)
------------------------------------------------------------------------

private
  loginView : Node Model Msg
  loginView = div (class "site-login" ∷ [])
    ( h1 [] [ text "Кабинет" ]
    ∷ input (valueBind lg ∷ onInput Lg ∷ attr "placeholder" "логин (email)"
             ∷ class "site-lg" ∷ [])
    ∷ input (valueBind pw ∷ onInput Pw ∷ attr "placeholder" "пароль" ∷ attr "type" "password"
             ∷ class "site-pw" ∷ [])
    ∷ button (onClick DoLogin ∷ class "site-enter" ∷ []) [ text "Войти" ]
    ∷ [] )

siteTemplate : Node Model Msg
siteTemplate = div (class "site" ∷ [])
  ( div (class "site-banner" ∷ []) [ bindF banner ]
  ∷ when isLogin loginView
  ∷ when isCabinet (zoomNode card CardMsg Card.cardTemplate)
  ∷ [] )

------------------------------------------------------------------------
-- App
------------------------------------------------------------------------

appWith : String → ReactiveApp Model Msg
appWith b = mkReactiveApp (initModel b) updateModel siteTemplate cmdOf (λ _ → never)

app : ReactiveApp Model Msg
app = appWith ""
