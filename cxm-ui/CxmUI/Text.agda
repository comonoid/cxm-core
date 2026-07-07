{-# OPTIONS --without-K #-}

-- CxmUI.Text — ALL user-facing strings of the widget layer in ONE module (аудит №11).
-- Language is brand/locale territory (layer 3), so the widgets must not scatter copy —
-- this is the single point a fork patches today and an I18n record parametrizes tomorrow
-- (agdelte has Agdelte.I18n; parametrization comes with the first real second locale).
-- Naming: t<Widget><What>; shared pieces are unprefixed.
module CxmUI.Text where

open import Agda.Builtin.String using (primStringEquality)
open import Data.Bool using (if_then_else_)
open import Data.String using (String)

-- shared
tReload tLoad : String
tReload = "Обновить"
tLoad   = "Загрузить"

-- error prefixes (CxmUI.Widget.errText)
tErrNet tErrServer tErrDecode : String
tErrNet    = "сеть: "
tErrServer = "сервер: "
tErrDecode = "разбор: "

-- client card (CxmUI.ClientCard)
tCardHint tCardLoadingRoster tCardNoClients tCardLoadingCard tCardNoKnowledge : String
tCardHint          = "нажми «Загрузить» — список клиентов"
tCardLoadingRoster = "загрузка списка…"
tCardNoClients     = "клиентов пока нет"
tCardLoadingCard   = "загрузка карточки…"
tCardNoKnowledge   = "знаний пока нет"
tCardRebuilding tCardRebuilt tCardRevising tCardSavingDetail tCardRevised : String
tCardRebuilding   = "перестраиваю вывод…"
tCardRebuilt      = "вывод перестроен, обновляю знания…"
tCardRevising     = "ревизия: "        -- ++ kind ++ tEllipsis
tCardSavingDetail = "сохраняю детали…"
tCardRevised      = "ревизия применена, обновляю…"
tEllipsis : String
tEllipsis = "…"
tCardClients tCardKnowledge tCardRebuild tCardEpisodes tCardAppointments tCardExpectations : String
tCardClients      = "Клиенты"
tCardKnowledge    = "Знания"
tCardRebuild      = "↻ перестроить вывод"
tCardEpisodes     = "Эпизоды"
tCardAppointments = "Брони"
tCardExpectations = "Ожидания"
tCardConfirm tCardRefute tCardSupersede tCardRedetail : String
tCardConfirm    = "✓ подтвердить"
tCardRefute     = "✗ опровергнуть"
tCardSupersede  = "⤳ заменить"
tCardRedetail   = "✎ детали"
-- шаг ±N приходит из виджета (один источник — ClientCard.revStep), тут только префиксы
tCardStrengthenPfx tCardWeakenPfx : String
tCardStrengthenPfx = "▲ +"
tCardWeakenPfx     = "▼ −"
-- русские подписи wire-kind'ов ревизий для статус-строки (сами kind'ы — контракт, не локаль)
tKindRu : String → String
tKindRu k =
  if primStringEquality k "confirm"    then "подтверждение"
  else if primStringEquality k "refute"     then "опровержение"
  else if primStringEquality k "supersede"  then "замена"
  else if primStringEquality k "strengthen" then "усиление"
  else if primStringEquality k "weaken"     then "ослабление"
  else if primStringEquality k "redetail"   then "правка деталей"
  else k
tCardSaveDetail tCardCancel : String
tCardSaveDetail = "Сохранить детали"
tCardCancel     = "Отмена"
tCardEpisode tCardEpState tCardBooking tCardMin tCardLevel : String
tCardEpisode = "эпизод #"
tCardEpState = " · состояние "
tCardBooking = "бронь #"
tCardMin     = " мин · "
tCardLevel   = "уровень "
tCardWhy tCardWhyHead tCardEvidenceRow tCardNoEvidence tCardLoadingEvidence tClose : String
tCardWhy             = "🔎 почему"
tCardWhyHead         = "Почему (цепочка доказательств)"
tCardEvidenceRow     = "событие #"
tCardNoEvidence      = "доказательств не записано"
tCardLoadingEvidence = "загрузка доказательств…"
tClose               = "✕ закрыть"
tCardObsPlaceholder tCardAddObs tCardAddingObs : String
tCardObsPlaceholder = "новое наблюдение (STATED)…"
tCardAddObs         = "➕ добавить наблюдение"
tCardAddingObs      = "добавляю наблюдение…"

-- panel VIII.a
tWsHead tWsSync tWsAsync tWsDetailFirst tWsPictureFirst tWsHandoff tWsBare : String
tWsHead         = "Как достучаться"
tWsSync         = "синхронно"
tWsAsync        = "асинхронно"
tWsDetailFirst  = "сначала детали"
tWsPictureFirst = "сначала общая картина"
tWsHandoff      = "хэндофф полон: "
tWsBare         = "стратегия без параметров"

-- feed
tFeedHint tFeedLoading tFeedEmpty tAuthor tTs tLockedContent : String
tFeedHint      = "нажми «Обновить» — лента подписок"
tFeedLoading   = "загрузка ленты…"
tFeedEmpty     = "лента пуста"
tAuthor        = "автор #"
tTs            = "t="
tLockedContent = "🔒 закрытый контент"

-- thread
tThreadHint tThreadLoading tThreadEmpty tLockedReply : String
tThreadHint    = "нажми «Обновить» — разговор"
tThreadLoading = "загрузка разговора…"
tThreadEmpty   = "разговор пуст"
tLockedReply   = "🔒 закрытая реплика"
tReply tReplying tReplyPlaceholder : String
tReply            = "Ответить"
tReplying         = "отправляю ответ…"
tReplyPlaceholder = "текст ответа…"

-- showcase
tShowcaseHint tShowcaseLoading tShowcaseEmpty : String
tShowcaseHint    = "нажми «Обновить» — витрина"
tShowcaseLoading = "загрузка витрины…"
tShowcaseEmpty   = "витрина пуста"

-- paywall
tPaywallHint tPaywallLoading tPaywallEmpty tBuying tPaymentCreated tBuy tOfferNo : String
tPaywallHint    = "нажми «Обновить» — что можно купить"
tPaywallLoading = "загрузка предложений…"
tPaywallEmpty   = "предложений нет"
tBuying         = "покупка #"       -- ++ offering ++ tEllipsis
tPaymentCreated = " создан — после оплаты контент откроется"   -- "платёж #N" ++ this
tBuy            = "Купить"
tOfferNo        = "№"
tPayment : String
tPayment = "платёж #"
