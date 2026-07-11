{-# OPTIONS --without-K #-}

-- SitePsych.Public — П4 «морда», Ф3.1: ПУБЛИЧНАЯ страница личного сайта (слой 3). Зритель —
-- аноним с cookie-identity: V1Cfg (channel "cookie", id = visitor, выдаётся JS-обвязкой и
-- живёт в localStorage); при первом ЧТЕНИИ сервер резолвит его в 0 (публичное-только), при
-- первой ПОКУПКЕ /v1/purchase создаст provisional-субъект под этой identity (Ф3.2 сольёт его
-- в аккаунт mergeSession'ом).
--
-- Роутинг = цели контент-схем Ф2.3: agdelte onUrlChange (hash): "/" — главная (витрина полки
-- сайта + paywall), "/post/N" — страница записи: тред под записью (root = сама запись,
-- locked → тизер) + paywall. Внутренние ссылки в markdown (#/post/N) работают здесь нативно.
-- Виджеты — embedding-паттерн (zoomNode/mapCmd), payload — <site-markdown> (Ф2.3).
--
-- `appWith base itok visitor shelf` — параметризация (смоук/обвязка); токен = integration-token
-- сайта (конфиг деплоя), полка = id полки-витрины (конфиг сайта).
module SitePsych.Public where

open import Agda.Builtin.String using (primStringEquality)
open import Agda.Builtin.Unit using (⊤)
open import Data.Bool using (Bool; true; false; not; _∨_; if_then_else_)
open import Data.Nat using (ℕ)
open import Data.Nat.Show using (readMaybe)
open import Data.Maybe using (maybe′)
open import Data.Char using (Char)
open import Data.String using (String; toList; fromList)
open import Data.List using (List; []; _∷_; [_])

open import Agdelte.Core.Result using (Result; ok; err)
open import Agdelte.Core.Cmd using (Cmd; ε; batch; mapCmd)
open import Agdelte.Core.Event using (Event; never; onUrlChange)
open import Agdelte.Reactive.Node

open import CxmUI.Contract using (ContentView; cnPayload)
open import CxmUI.Client using
  ( V1Cfg; mkV1Cfg; v1base; v1token; v1id
  ; Cfg; mkCfg; CallErr; register; login; mergeSessionBy )
open import CxmUI.Widget using (errText)
import CxmUI.Showcase as Sh
import CxmUI.Thread as Th
import CxmUI.Paywall as Pw
import SitePsych.Booking as Bk

------------------------------------------------------------------------
-- Route (цели контент-схем; парсер тотален: мусор = главная)
------------------------------------------------------------------------

data Route : Set where
  RHome : Route
  RPost : ℕ → Route
  RBook : Route

parseRoute : String → Route
parseRoute s = go (toList s)
  where
    go : List Char → Route
    go ('/' ∷ 'p' ∷ 'o' ∷ 's' ∷ 't' ∷ '/' ∷ rest) =
      maybe′ RPost RHome (readMaybe 10 (fromList rest))
    go ('/' ∷ 'b' ∷ 'o' ∷ 'o' ∷ 'k' ∷ _) = RBook
    go _ = RHome

------------------------------------------------------------------------
-- Model
------------------------------------------------------------------------

record Model : Set where
  constructor mkModel
  field
    v1c     : V1Cfg        -- cookie-identity зрителя (фиксируется при маунте)
    route   : Route
    shelfM  : Sh.Model     -- витрина полки сайта (главная)
    thM     : Th.Model     -- тред записи (переинициализируется на "/post/N")
    pwM     : Pw.Model     -- paywall (общий для страниц)
    bkM     : Bk.Model     -- запись на услуги (#/book)
    rlg rpw rnm : String   -- Ф3.2: форма «сохранить доступ»
    account : String       -- "" = аноним; после merge — login аккаунта
    note    : String       -- статус блока «доступ»
open Model public

initModel : (base itok visitor : String) (shelf : ℕ) → Model
initModel b tok vis shelf =
  let c = mkV1Cfg b tok "cookie" vis in
  mkModel c RHome (Sh.initModel c shelf 0) (Th.initModel c 0 0) (Pw.initModel c "site")
    (Bk.initModel b) "" "" "" "" ""

private
  is : String → String → Bool
  is = primStringEquality

  isHome isPost isBook : Model → Bool
  isHome m with route m
  ... | RHome = true
  ... | _ = false
  isPost m with route m
  ... | RPost _ = true
  ... | _ = false
  isBook m with route m
  ... | RBook = true
  ... | _ = false

  isAnon : Model → Bool
  isAnon m = is (account m) ""

  emptyCreds : Model → Bool
  emptyCreds m = is (rlg m) "" ∨ is (rpw m) ""

------------------------------------------------------------------------
-- Update / Cmd
------------------------------------------------------------------------

data Msg : Set where
  RouteTo  : String → Msg
  ShelfMsg : Sh.Msg → Msg
  ThMsg    : Th.Msg → Msg
  PwMsg    : Pw.Msg → Msg
  BkMsg    : Bk.Msg → Msg
  RLg RPw RNm : String → Msg
  DoSave   : Msg                            -- register→login→merge одной кнопкой
  GotReg   : Result CallErr ℕ → Msg
  GotJwt   : Result CallErr String → Msg
  GotMerge : Result CallErr ⊤ → Msg

updateModel : Msg → Model → Model
updateModel (RouteTo s) m with parseRoute s
... | RHome   = record m { route = RHome }
... | RPost i = record m { route = RPost i ; thM = Th.initModel (v1c m) i 0 }
... | RBook   = record m { route = RBook }
updateModel (ShelfMsg wm) m = record m { shelfM = Sh.updateModel wm (shelfM m) }
updateModel (ThMsg wm) m = record m { thM = Th.updateModel wm (thM m) }
updateModel (PwMsg wm) m = record m { pwM = Pw.updateModel wm (pwM m) }
updateModel (BkMsg wm) m = record m { bkM = Bk.updateModel wm (bkM m) }
updateModel (RLg s) m = record m { rlg = s }
updateModel (RPw s) m = record m { rpw = s }
updateModel (RNm s) m = record m { rnm = s }
updateModel DoSave m =
  record m { note = if emptyCreds m then "нужны email и пароль" else "сохраняю…" }
updateModel (GotReg _) m = m                -- 409 «уже есть» — норма, дальше логин
updateModel (GotJwt (ok _)) m = record m { note = "привязываю покупки…"
                                         ; account = rlg m ; rpw = "" }
updateModel (GotJwt (err e)) m = record m { note = errText e }
updateModel (GotMerge (ok _)) m = record m { note = "доступ сохранён — покупки привязаны к аккаунту" }
updateModel (GotMerge (err e)) m = record m { note = errText e }

-- NB: cmdOf видит ПРЕ-батч модель — для "/post/N" тред-команда строится на свежей модели
-- из самого сообщения (как GotItok в Main). onUrlChange стреляет и при маунте — начальная
-- загрузка виджетов едет отсюда же, отдельного Init не нужно.
cmdOf : Msg → Model → Cmd Msg
cmdOf (RouteTo s) m with parseRoute s
... | RHome   = batch ( mapCmd ShelfMsg (Sh.cmdOf Sh.Load (shelfM m))
                      ∷ mapCmd PwMsg (Pw.cmdOf Pw.Load (pwM m)) ∷ [] )
... | RPost i = batch ( mapCmd ThMsg (Th.cmdOf Th.Load (Th.initModel (v1c m) i 0))
                      ∷ mapCmd PwMsg (Pw.cmdOf Pw.Load (pwM m)) ∷ [] )
... | RBook   = mapCmd BkMsg (Bk.cmdOf Bk.Load (bkM m))
cmdOf (ShelfMsg wm) m = mapCmd ShelfMsg (Sh.cmdOf wm (shelfM m))
cmdOf (ThMsg wm) m = mapCmd ThMsg (Th.cmdOf wm (thM m))
cmdOf (PwMsg wm) m = mapCmd PwMsg (Pw.cmdOf wm (pwM m))
cmdOf (BkMsg wm) m = mapCmd BkMsg (Bk.cmdOf wm (bkM m))
-- Ф3.2: одна кнопка = register (409 «уже есть» не рвёт цепочку) → login (доказывает контроль
-- login-identity) → mergeSessionBy (login-identity в конверте, cookie-сессия парой) → перечитать
cmdOf DoSave m = if emptyCreds m then ε
  else register (mkCfg (v1base (v1c m)) "") (rlg m) (rpw m) (rnm m) GotReg
cmdOf (GotReg _) m = login (mkCfg (v1base (v1c m)) "") (rlg m) (rpw m) GotJwt
cmdOf (GotJwt (ok _)) m =
  mergeSessionBy (mkV1Cfg (v1base (v1c m)) (v1token (v1c m)) "user_id" (rlg m))
                 "cookie" (v1id (v1c m)) GotMerge
cmdOf (GotMerge (ok _)) m with route m
... | RHome   = mapCmd ShelfMsg (Sh.cmdOf Sh.Load (shelfM m))
... | RPost _ = mapCmd ThMsg (Th.cmdOf Th.Load (thM m))
... | RBook   = ε
cmdOf _ _ = ε

------------------------------------------------------------------------
-- View (бренд — слой 3)
------------------------------------------------------------------------

private
  -- Ф2.3: payload → <site-markdown> (marked+DOMPurify + контент-схемы) — для обоих виджетов
  mdP : ∀ {M Msg′ : Set} → ContentView → Node M Msg′
  mdP c = elem "site-markdown" (attr "data-md" (cnPayload c) ∷ []) []

  headerView : Node Model Msg
  headerView = div (class "pub-header" ∷ [])
    ( h1 [] [ text "Записи и материалы" ]
    ∷ nav (class "pub-nav" ∷ [])
        ( a (attr "href" "#/" ∷ class "pub-home-link" ∷ []) [ text "Главная" ]
        ∷ a (attr "href" "#/book" ∷ class "pub-book-link" ∷ []) [ text "Записаться" ]
        ∷ a (attr "href" "pages.html#/" ∷ class "pub-pages-link" ∷ []) [ text "О подходе" ]
        ∷ [] )
    ∷ [] )

  -- Ф3.2: «сохранить доступ» — регистрация/вход, привязывающие покупки cookie-сессии к аккаунту
  accountView : Node Model Msg
  accountView = div (class "pub-account" ∷ [])
    ( h2 [] [ text "Доступ" ]
    ∷ when isAnon (div (class "pub-reg" ∷ [])
        ( input (valueBind rlg ∷ onInput RLg ∷ attr "placeholder" "email"
                 ∷ class "pub-lg" ∷ [])
        ∷ input (valueBind rpw ∷ onInput RPw ∷ attr "placeholder" "пароль"
                 ∷ attr "type" "password" ∷ class "pub-pw" ∷ [])
        ∷ input (valueBind rnm ∷ onInput RNm ∷ attr "placeholder" "имя"
                 ∷ class "pub-nm" ∷ [])
        ∷ button (onClick DoSave ∷ class "pub-save" ∷ []) [ text "Сохранить доступ" ]
        ∷ [] ))
    ∷ div (class "pub-acc-note" ∷ []) [ bindF note ]
    ∷ [] )

pubTemplate : Node Model Msg
pubTemplate = div (class "pub" ∷ [])
  ( headerView
  ∷ when isHome (div (class "pub-main" ∷ [])
      [ zoomNode shelfM ShelfMsg (Sh.showcaseTemplateWith mdP) ])
  ∷ when isPost (div (class "pub-post" ∷ [])
      [ zoomNode thM ThMsg (Th.threadTemplateWith mdP) ])
  ∷ when isBook (div (class "pub-book" ∷ [])
      [ zoomNode bkM BkMsg Bk.bookingTemplate ])
  ∷ div (class "pub-pay" ∷ [])
      ( h2 [] [ text "Материалы и услуги" ]
      ∷ zoomNode pwM PwMsg Pw.paywallTemplate
      ∷ [] )
  ∷ accountView
  ∷ [] )

------------------------------------------------------------------------
-- App
------------------------------------------------------------------------

subsOf : Model → Event Msg
subsOf _ = onUrlChange RouteTo

appWith : (base itok visitor : String) (shelf : ℕ) → ReactiveApp Model Msg
appWith b tok vis shelf =
  mkReactiveApp (initModel b tok vis shelf) updateModel pubTemplate cmdOf subsOf
