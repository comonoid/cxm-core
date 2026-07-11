{-# OPTIONS --without-K #-}

-- SitePsych.Booking — фронт услуг (первый потребитель psych-пака в слое 3): экран записи
-- на публичной странице. Wire-протокол — PsychCxm.Client (paths/bodies/decoders, пак-SDK);
-- HTTP-обвязка (Cmd) — здесь, по образцу CxmUI.Client. Публичная поверхность /psych/*:
-- без auth, слот-валидация и конфликты — серверные (пак), тут только их человеческий показ.
--
-- Поток: Load → сетка свободных слотов (кнопки; человеческое время рендерит <site-ts> —
-- тот же custom-element шов, что markdown) → клик выбирает слот → имя+email → «Записаться»
-- → BookOk id (слоты перечитываются — занятый исчезает) | BookErr msg (конфликт/notice).
-- Тип встречи: select intro (30 мин, бесплатно) / session (90 мин).
module SitePsych.Booking where

open import Agda.Builtin.String using (primStringEquality)
open import Data.Bool using (Bool; true; false; if_then_else_; _∨_; not)
open import Data.Nat using (ℕ; _≡ᵇ_)
open import Data.Nat.Show using (show)
open import Data.Maybe using (maybe′)
open import Data.String using (String; _++_)
open import Data.List using (List; []; _∷_; [_])
open import Data.Product using (proj₁; proj₂)

open import Agdelte.Core.Result using (Result; ok; err)
open import Agdelte.Core.Cmd using (Cmd; ε; httpPostH)
open import Agdelte.Core.Event using (never)
open import Agdelte.Json using (decodeString)
open import Agdelte.Reactive.Node

open import PsychCxm.Catalog using (SlotType; Intro; Session; parseSlotType)
open import PsychCxm.Client using
  ( Slot; availPath; availBody; bookPath; bookBody; slotsDec; bookDec
  ; BookOutcome; BookOk; BookErr; typeStr )

------------------------------------------------------------------------
-- Model
------------------------------------------------------------------------

record Model : Set where
  constructor mkModel
  field
    base    : String        -- origin ("" = same-origin)
    ty      : String        -- "intro" | "session" (строкой — прямо из select)
    slots   : List Slot
    chosen  : ℕ             -- start выбранного слота (0 = не выбран)
    bname   : String
    bemail  : String
    status  : String        -- состояние сетки/формы
    done    : String        -- подтверждение последней записи (отдельно: GotAv-перезагрузка
                            -- сетки не должна затирать «вы записаны»)
open Model public

initModel : String → Model
initModel b = mkModel b "session" [] 0 "" "" "выберите время" ""

private
  is : String → String → Bool
  is = primStringEquality

  tyOf : Model → SlotType
  tyOf m = maybe′ (λ t → t) Session (parseSlotType (ty m))

  canBook : Model → Bool
  canBook m = not ((chosen m ≡ᵇ 0) ∨ is (bname m) "" ∨ is (bemail m) "")

------------------------------------------------------------------------
-- Update / Cmd
------------------------------------------------------------------------

data Msg : Set where
  Load    : Msg
  GotAv   : Result String (List Slot) → Msg
  TyTo    : String → Msg
  Pick    : ℕ → Msg                      -- start слота
  BName BEmail : String → Msg
  DoBook  : Msg
  GotBook : Result String BookOutcome → Msg

updateModel : Msg → Model → Model
updateModel Load m = record m { status = "смотрю расписание…" ; chosen = 0 }
updateModel (GotAv (ok xs)) m =
  record m { slots = xs
           ; status = if lenZ xs then "свободных слотов нет" else "выберите время" }
  where lenZ : List Slot → Bool
        lenZ [] = true
        lenZ _  = false
updateModel (GotAv (err e)) m = record m { status = e }
updateModel (TyTo t) m = record m { ty = t ; chosen = 0 }
updateModel (Pick s) m = record m { chosen = s }
updateModel (BName s) m = record m { bname = s }
updateModel (BEmail s) m = record m { bemail = s }
updateModel DoBook m =
  record m { status = if canBook m then "записываю…"
                      else "выберите слот и заполните имя и email" }
updateModel (GotBook (ok (BookOk i))) m =
  record m { done = "вы записаны — встреча #" ++ show i ++ ", подтверждение придёт на почту"
           ; status = "" ; chosen = 0 }
updateModel (GotBook (ok (BookErr e))) m = record m { status = e }
updateModel (GotBook (err e)) m = record m { status = e }

private
  postDec : ∀ {A M : Set} → String → String → String
          → (String → Result String A) → (Result String A → M) → Cmd M
  postDec b path body dec k =
    httpPostH (b ++ path) [] body (λ r → k (dec r)) (λ e → k (err ("сеть: " ++ e)))

  decAv : String → Result String (List Slot)
  decAv r with decodeString slotsDec r
  ... | ok xs = ok xs
  ... | err _ = err "не смог разобрать расписание"

  decBook : String → Result String BookOutcome
  decBook r with decodeString bookDec r
  ... | ok o  = ok o
  ... | err _ = err "не смог разобрать ответ записи"

cmdOf : Msg → Model → Cmd Msg
cmdOf Load m = postDec (base m) availPath (availBody (tyOf m)) decAv GotAv
cmdOf (TyTo t) m =    -- cmd видит ПРЕ-модель — тип берём из сообщения
  postDec (base m) availPath (availBody (maybe′ (λ x → x) Session (parseSlotType t))) decAv GotAv
cmdOf DoBook m =
  if canBook m
  then postDec (base m) bookPath (bookBody (tyOf m) (chosen m) (bname m) (bemail m)) decBook GotBook
  else ε
cmdOf (GotBook (ok (BookOk _))) m = postDec (base m) availPath (availBody (tyOf m)) decAv GotAv
cmdOf _ _ = ε

------------------------------------------------------------------------
-- View
------------------------------------------------------------------------

private
  slotBtn : Slot → ℕ → Node Model Msg
  slotBtn s _ = li (class "bk-slot" ∷ [])
    [ button (onClick (Pick (proj₁ s)) ∷ class "bk-pick" ∷ [])
        [ elem "site-ts" (attr "data-ts" (show (proj₁ s)) ∷ []) [] ] ]

  hasChosen : Model → Bool
  hasChosen m = not (chosen m ≡ᵇ 0)

bookingTemplate : Node Model Msg
bookingTemplate = div (class "bk" ∷ [])
  ( h2 [] [ text "Записаться" ]
  ∷ elem "select" (onChange TyTo ∷ class "bk-ty" ∷ [])
      ( elem "option" (attr "value" "session" ∷ []) [ text "Сессия «в точку» (90 мин)" ]
      ∷ elem "option" (attr "value" "intro" ∷ []) [ text "Разговор «осмотреться» (30 мин, бесплатно)" ]
      ∷ [] )
  ∷ ul (class "bk-slots" ∷ []) ( foreachKeyed slots (λ s → show (proj₁ s)) slotBtn ∷ [] )
  -- выбранный слот — реактивной строкой (attrBind на обычном узле; бинды ВНУТРИ
  -- keyed-строк не живут — строки пере-рендерятся только по ключу)
  ∷ when hasChosen (div (class "bk-chosen" ∷ [])
      ( text "выбрано: "
      ∷ elem "site-ts" (attrBind "data-ts" (stringBinding (λ m → show (chosen m))) ∷ []) []
      ∷ [] ))
  ∷ div (class "bk-form" ∷ [])
      ( input (valueBind bname ∷ onInput BName ∷ attr "placeholder" "имя"
               ∷ class "bk-name" ∷ [])
      ∷ input (valueBind bemail ∷ onInput BEmail ∷ attr "placeholder" "email"
               ∷ class "bk-email" ∷ [])
      ∷ button (onClick DoBook ∷ class "bk-go" ∷ []) [ text "Записаться" ]
      ∷ [] )
  ∷ div (class "bk-status" ∷ []) [ bindF status ]
  ∷ div (class "bk-done" ∷ []) [ bindF done ]
  ∷ [] )
