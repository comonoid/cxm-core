{-# OPTIONS --without-K #-}

-- SitePsych.Main — П4 «морда», Ф0+Ф1: кабинет психолога (слой 3 — БРЕНД/композиция; контрактное —
-- в cxm-ui). Стадия Login (Ф0: форма → Client.login + сверка контракта /health) → стадия Cabinet
-- с вкладками: «Клиенты» (Ф0: ClientCard, embedding-паттерн zoomNode/mapCmd) и «Записи» (Ф1).
--
-- Ф1 «Записи»: свои посты = cxm-ui Feed с identity ВЛАДЕЛЬЦА — owner-читалка не нужна,
-- feedViews включает автора без фоллова (Cxm.Social.fromFeedAuthor: a ≡ᵇ viewer). /v1-конфиг
-- кабинета: после логина минтится integration-token → V1Cfg base itok "user_id" login; автором
-- становится субъект, которого /v1/publish резолвит/создаёт по этой identity.
-- Редактор: textarea (markdown, payload — opaque строка сайта; рендер — Ф2) + видимость
-- public|entitled|private; listing НЕ селектор, а политика сайта: entitled ⇒ listing=public
-- (платный пост виден в лентах locked-тизером — storefront-семантика S7), иначе серверный
-- дефолт. Цена (₽): при entitled+цене>0 после публикации создаётся offering c grants на пост
-- (fulfilment-as-data, Cxm.Fulfilment). «На полку»: linkResource(полка, запись) — id полки
-- вводится (конфиг сайта; листалки полок у сервера нет).
-- `app` — same-origin (браузер, дев-прокси); `appWith base` — параметризация для смоука.
module SitePsych.Main where

open import Agda.Builtin.String using (primStringEquality)
open import Data.Bool using (Bool; true; false; not; _∧_; _∨_; if_then_else_)
open import Data.Nat using (ℕ; _≡ᵇ_; _*_; _<ᵇ_)
open import Data.Nat.Show using (show; readMaybe)
open import Data.Maybe using (maybe′)
open import Data.String using (String; _++_)
open import Data.List using (List; []; _∷_; [_])

open import Agdelte.Core.Result using (Result; ok; err)
open import Agdelte.Core.Cmd using (Cmd; ε; batch; mapCmd)
open import Agdelte.Core.Event using (never)
open import Agdelte.Reactive.Node

open import CxmUI.Contract using (HealthView; hContract; expectedContract; ContentView; cnPayload)
open import CxmUI.Client using
  ( Cfg; mkCfg; CallErr; login; health
  ; V1Cfg; mkV1Cfg; MintedToken; mtToken; mintIntegrationToken
  ; publishV1; createOffering; linkResource )
open import CxmUI.Widget using (errText)
import CxmUI.ClientCard as Card
import CxmUI.Feed as Feed
import CxmUI.Inbox as Inbox

------------------------------------------------------------------------
-- Model
------------------------------------------------------------------------

data Stage : Set where
  SLogin SCabinet : Stage

data Tab : Set where
  TClients TPosts TInbox : Tab

record Model : Set where
  constructor mkModel
  field
    base   : String       -- origin ("" = same-origin через дев-прокси)
    stage  : Stage
    tab    : Tab
    lg pw  : String       -- форма логина
    banner : String       -- ошибки логина/минта / дрейф контракта
    bjwt   : String       -- Bearer-JWT (кабинетные записи: offerings, resources/link)
    card   : Card.Model   -- переинициализируется с JWT после логина
    feedM  : Feed.Model   -- «Записи»; переинициализируется с V1Cfg после минта токена
    inboxM : Feed.Model   -- «Упоминания» (Ф4): Feed-модель, источник — Inbox.cmdOf (/v1/mentions)
    draft  : String       -- редактор: текст записи (markdown)
    vis    : String       -- видимость: public | entitled | private
    price  : String       -- цена в ₽ (для entitled; ""/0 = офферинг не создаётся)
    postF  : String       -- «на полку»: id записи (после публикации — последняя)
    shelfF : String       -- «на полку»: id полки
    note   : String       -- статус экрана «Записи»
open Model public

initModel : String → Model
initModel b = mkModel b SLogin TClients "" "" "" ""
  (Card.initModel (mkCfg b ""))
  (Feed.initModel (mkV1Cfg b "" "user_id" "") 0)
  (Feed.initModel (mkV1Cfg b "" "user_id" "") 0)
  "" "public" "" "" "" ""

private
  is : String → String → Bool
  is = primStringEquality

  natF : String → ℕ                 -- поле-число; мусор/пусто = 0
  natF s = maybe′ (λ n → n) 0 (readMaybe 10 s)

  isLogin isCabinet isClients isPosts isInbox : Model → Bool
  isLogin m with stage m
  ... | SLogin = true
  ... | SCabinet = false
  isCabinet m = not (isLogin m)
  isClients m with tab m
  ... | TClients = isCabinet m
  ... | _ = false
  isPosts m with tab m
  ... | TPosts = isCabinet m
  ... | _ = false
  isInbox m with tab m
  ... | TInbox = isCabinet m
  ... | _ = false

  bcfg : Model → Cfg
  bcfg m = mkCfg (base m) (bjwt m)

  v1cOf : Model → String → V1Cfg    -- identity владельца = его логин
  v1cOf m tok = mkV1Cfg (base m) tok "user_id" (lg m)

  priceKop : Model → ℕ
  priceKop m = natF (price m) * 100

  paidᵇ : Model → Bool
  paidᵇ m = is (vis m) "entitled" ∧ (0 <ᵇ priceKop m)

  listingOf : Model → String        -- entitled ⇒ listed-locked тизер; иначе серверный дефолт
  listingOf m = if is (vis m) "entitled" then "public" else ""

  grantsMeta : ℕ → String           -- fulfilment-план офферинга: покупка открывает пост
  grantsMeta i = "{\"grants\":[{\"kind\":\"resource\",\"id\":" ++ show i ++ "}]}"

  shelveArgsOk : Model → Bool
  shelveArgsOk m = not ((natF (postF m) ≡ᵇ 0) ∨ (natF (shelfF m) ≡ᵇ 0))

------------------------------------------------------------------------
-- Update / Cmd
------------------------------------------------------------------------

data Msg : Set where
  Lg Pw     : String → Msg
  DoLogin   : Msg
  GotJwt    : Result CallErr String → Msg
  GotHealth : Result CallErr HealthView → Msg
  GotItok   : Result CallErr MintedToken → Msg
  CardMsg   : Card.Msg → Msg
  FeedMsg   : Feed.Msg → Msg
  InboxMsg  : Feed.Msg → Msg
  TabTo     : Tab → Msg
  Draft Vis Price PostF ShelfF : String → Msg
  DoPublish : Msg
  GotPost   : Result CallErr ℕ → Msg
  GotOffer  : Result CallErr ℕ → Msg
  DoShelve  : Msg
  GotLink   : Result CallErr ℕ → Msg

updateModel : Msg → Model → Model
updateModel (Lg s) m = record m { lg = s }
updateModel (Pw s) m = record m { pw = s }
updateModel DoLogin m = record m { banner = "вхожу…" }
updateModel (GotJwt (ok jwt)) m =
  record m { stage = SCabinet ; banner = "" ; pw = "" ; bjwt = jwt
           ; card = Card.initModel (mkCfg (base m) jwt) }
updateModel (GotJwt (err e)) m = record m { banner = errText e }
updateModel (GotHealth (ok h)) m =
  if hContract h ≡ᵇ expectedContract then m
  else record m { banner = "⚠ версия контракта: сервер " ++ show (hContract h)
                          ++ " ≠ сайт " ++ show expectedContract }
updateModel (GotHealth (err e)) m = record m { banner = errText e }
updateModel (GotItok (ok t)) m = record m { feedM = Feed.initModel (v1cOf m (mtToken t)) 0
                                          ; inboxM = Feed.initModel (v1cOf m (mtToken t)) 0 }
updateModel (GotItok (err e)) m = record m { banner = errText e }
updateModel (CardMsg cm) m = record m { card = Card.updateModel cm (card m) }
updateModel (FeedMsg fm) m = record m { feedM = Feed.updateModel fm (feedM m) }
updateModel (InboxMsg fm) m = record m { inboxM = Feed.updateModel fm (inboxM m) }
updateModel (TabTo t) m = record m { tab = t }
updateModel (Draft s) m = record m { draft = s }
updateModel (Vis s) m = record m { vis = s }
updateModel (Price s) m = record m { price = s }
updateModel (PostF s) m = record m { postF = s }
updateModel (ShelfF s) m = record m { shelfF = s }
updateModel DoPublish m = record m { note = "публикую…" }
updateModel (GotPost (ok i)) m =
  record m { draft = "" ; postF = show i
           ; note = "запись #" ++ show i ++ " опубликована"
                    ++ (if paidᵇ m then ", создаю офферинг…" else "") }
updateModel (GotPost (err e)) m = record m { note = errText e }
updateModel (GotOffer (ok i)) m =
  record m { note = "офферинг #" ++ show i ++ " создан — запись продаётся" }
updateModel (GotOffer (err e)) m = record m { note = errText e }
updateModel DoShelve m =
  record m { note = if shelveArgsOk m then "кладу на полку…"
                    else "нужны id записи и id полки (числа)" }
updateModel (GotLink (ok i)) m = record m { note = "на полке (связь #" ++ show i ++ ")" }
updateModel (GotLink (err e)) m = record m { note = errText e }

-- NB: cmdOf видит ПРЕ-батч модель (снапшот-семантика agdelte) — команды строят конфиги
-- из самого сообщения (jwt/token), а не из полей, которые выставит этот же update.
cmdOf : Msg → Model → Cmd Msg
cmdOf DoLogin m = batch ( health (mkCfg (base m) "") GotHealth
                        ∷ login (mkCfg (base m) "") (lg m) (pw m) GotJwt ∷ [] )
cmdOf (GotJwt (ok jwt)) m = mintIntegrationToken (mkCfg (base m) jwt) "site-psych" GotItok
cmdOf (GotItok (ok t)) m = batch
  ( mapCmd FeedMsg (Feed.cmdOf Feed.Load (Feed.initModel (v1cOf m (mtToken t)) 0))
  ∷ mapCmd InboxMsg (Inbox.cmdOf Feed.Load (Feed.initModel (v1cOf m (mtToken t)) 0))
  ∷ [] )
cmdOf (CardMsg cm) m = mapCmd CardMsg (Card.cmdOf cm (card m))
cmdOf (FeedMsg fm) m = mapCmd FeedMsg (Feed.cmdOf fm (feedM m))
cmdOf (InboxMsg fm) m = mapCmd InboxMsg (Inbox.cmdOf fm (inboxM m))
cmdOf DoPublish m =
  publishV1 (Feed.cfg (feedM m)) 0 (vis m) (listingOf m) (draft m) GotPost
cmdOf (GotPost (ok i)) m = batch
  ( (if paidᵇ m then createOffering (bcfg m) 1 (priceKop m) "RUB" (grantsMeta i) GotOffer else ε)
  ∷ mapCmd FeedMsg (Feed.cmdOf Feed.Load (feedM m))
  ∷ [] )
cmdOf DoShelve m =
  if shelveArgsOk m
  then linkResource (bcfg m) (natF (shelfF m)) (natF (postF m)) 1 0 GotLink
  else ε
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

  tabsView : Node Model Msg
  tabsView = nav (class "site-tabs" ∷ [])
    ( button (onClick (TabTo TClients) ∷ class "site-tab-clients" ∷ []) [ text "Клиенты" ]
    ∷ button (onClick (TabTo TPosts) ∷ class "site-tab-posts" ∷ []) [ text "Записи" ]
    ∷ button (onClick (TabTo TInbox) ∷ class "site-tab-inbox" ∷ []) [ text "Упоминания" ]
    ∷ [] )

  editorView : Node Model Msg
  editorView = div (class "site-editor" ∷ [])
    ( elem "textarea" (valueBind draft ∷ onInput Draft
        ∷ attr "placeholder" "текст записи (markdown)" ∷ class "site-draft" ∷ []) []
    ∷ elem "select" (onChange Vis ∷ class "site-vis" ∷ [])
        ( elem "option" (attr "value" "public" ∷ []) [ text "публичная" ]
        ∷ elem "option" (attr "value" "entitled" ∷ []) [ text "платная" ]
        ∷ elem "option" (attr "value" "private" ∷ []) [ text "приватная" ]
        ∷ [] )
    ∷ input (valueBind price ∷ onInput Price ∷ attr "placeholder" "цена ₽ (для платной)"
             ∷ class "site-price" ∷ [])
    ∷ button (onClick DoPublish ∷ class "site-publish" ∷ []) [ text "Опубликовать" ]
    ∷ [] )

  shelveView : Node Model Msg
  shelveView = div (class "site-shelve" ∷ [])
    ( input (valueBind postF ∷ onInput PostF ∷ attr "placeholder" "id записи"
             ∷ class "site-post-id" ∷ [])
    ∷ input (valueBind shelfF ∷ onInput ShelfF ∷ attr "placeholder" "id полки"
             ∷ class "site-shelf-id" ∷ [])
    ∷ button (onClick DoShelve ∷ class "site-shelf-btn" ∷ []) [ text "На полку" ]
    ∷ [] )

  -- Ф2.1: payload записи = сырой markdown сайта → docsify-стек на клиенте: Agda проносит
  -- источник атрибутом, custom-element <site-markdown> (dev/md-element.mjs) рендерит его
  -- marked+DOMPurify (движок docsify; полноценный docsify — обвязка публичной страницы Ф3)
  mdPayload : ContentView → Node Feed.Model Feed.Msg
  mdPayload c = elem "site-markdown" (attr "data-md" (cnPayload c) ∷ []) []

  postsView : Node Model Msg
  postsView = div (class "site-posts" ∷ [])
    ( h2 [] [ text "Записи" ]
    ∷ editorView
    ∷ div (class "site-note" ∷ []) [ bindF note ]
    ∷ shelveView
    ∷ zoomNode feedM FeedMsg (Feed.feedTemplateWith mdPayload)
    ∷ [] )

  -- Ф4: инбокс = Feed-шаблон (тот же markdown-хук), источник — Inbox.cmdOf (/v1/mentions)
  inboxView : Node Model Msg
  inboxView = div (class "site-inbox" ∷ [])
    ( h2 [] [ text "Упоминания" ]
    ∷ zoomNode inboxM InboxMsg (Feed.feedTemplateWith mdPayload)
    ∷ [] )

siteTemplate : Node Model Msg
siteTemplate = div (class "site" ∷ [])
  ( div (class "site-banner" ∷ []) [ bindF banner ]
  ∷ when isLogin loginView
  ∷ when isCabinet tabsView
  ∷ when isClients (zoomNode card CardMsg Card.cardTemplate)
  ∷ when isPosts postsView
  ∷ when isInbox inboxView
  ∷ [] )

------------------------------------------------------------------------
-- App
------------------------------------------------------------------------

appWith : String → ReactiveApp Model Msg
appWith b = mkReactiveApp (initModel b) updateModel siteTemplate cmdOf (λ _ → never)

app : ReactiveApp Model Msg
app = appWith ""
