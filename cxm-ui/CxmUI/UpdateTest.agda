{-# OPTIONS --without-K #-}

-- CxmUI.UpdateTest — refl-тесты ЧИСТОЙ update-логики виджетов (аудит-2 №12: метод проекта —
-- «чистая логика → тайпчек/refl» — теперь распространён и на слой виджетов). Проверяются
-- инварианты, которые рантайм-смоук ловит только случайно: дроп стейл-ответов (ifCurrent),
-- сбросы при Select, busy-переходы, toggle evidence-панели, per-purchase ext_id.
-- Запуск: agda CxmUI/UpdateTest.agda (npm run test:update) — красный тест не тайпчекается.
module CxmUI.UpdateTest where

open import Agda.Builtin.Equality using (_≡_; refl)
open import Agda.Builtin.Unit using (tt)
open import Data.Bool using (true; false)
open import Data.List using (List; []; _∷_)
open import Data.String using (String)

open import Agdelte.Core.Result using (ok; err)

open import CxmUI.Contract
open import CxmUI.Client using (mkCfg; mkV1Cfg; httpErr)
open import CxmUI.Widget using (emptyOr; authorLabel)
open import CxmUI.Text using (tKindRu)
import CxmUI.ClientCard as C
import CxmUI.Thread as T
import CxmUI.Paywall as P

private
  kv : KnowledgeView
  kv = mkKnowledgeView 1 7 "state" "stated" 500 0 0 0 "active" "d" 0

  m₀ = C.initModel (mkCfg "" "")
  m₇ = C.updateModel (C.Select 7) m₀              -- оператор смотрит клиента 7

------------------------------------------------------------------------
-- Стейл-гонка (аудит №3): ответ про ЧУЖОГО субъекта дропается, про текущего — применяется
------------------------------------------------------------------------

_ : C.knowledge (C.updateModel (C.GotKnowledge 5 (ok (kv ∷ []))) m₇) ≡ []
_ = refl

_ : C.knowledge (C.updateModel (C.GotKnowledge 7 (ok (kv ∷ []))) m₇) ≡ kv ∷ []
_ = refl

_ : C.status (C.updateModel (C.GotKnowledge 5 (err (httpErr "late"))) m₇) ≡ C.status m₇
_ = refl

------------------------------------------------------------------------
-- Select сбрасывает ВСЁ пер-субъектное (аудит №2 + busy-фейлсейф)
------------------------------------------------------------------------

private
  mDirty = C.updateModel (C.Revise 3 "confirm")           -- busy = true
             (C.updateModel (C.EditDetail 3 "x")          -- форма открыта
               (C.updateModel (C.LoadEvidence 3) m₇))     -- evidence открыт
  mAfter = C.updateModel (C.Select 8) mDirty

_ : C.editing mAfter ≡ 0
_ = refl
_ : C.busy mAfter ≡ false
_ = refl
_ : C.evidenceFor mAfter ≡ 0
_ = refl
_ : C.obsText mAfter ≡ ""
_ = refl

------------------------------------------------------------------------
-- busy-переходы: write ставит, СВОЙ ответ снимает (ok и err); ЧУЖОЙ (стейл от прежнего
-- клиента) — дропается и busy НЕ трогает (аудит-5 №1: окно двойного сабмита закрыто)
------------------------------------------------------------------------

private
  mBusy = C.updateModel (C.Revise 3 "confirm") m₇

_ : C.busy mBusy ≡ true
_ = refl
_ : C.busy (C.updateModel (C.GotRevise 7 (ok tt)) mBusy) ≡ false
_ = refl
_ : C.busy (C.updateModel (C.GotRevise 7 (err (httpErr "x"))) mBusy) ≡ false
_ = refl
_ : C.busy (C.updateModel (C.GotRevise 5 (ok tt)) mBusy) ≡ true          -- стейл: busy цел
_ = refl
_ : C.busy (C.updateModel (C.GotRebuild 5 (ok tt)) mBusy) ≡ true         -- стейл: busy цел
_ = refl
_ : C.busy (C.updateModel (C.GotObs 5 (ok 9)) mBusy) ≡ true              -- стейл: busy цел
_ = refl
_ : C.editing (C.updateModel (C.GotRevise 7 (ok tt)) (C.updateModel (C.EditDetail 3 "y") mBusy)) ≡ 0
_ = refl

------------------------------------------------------------------------
-- Evidence-панель: toggle (повторный клик закрывает), ошибка прячет панель
------------------------------------------------------------------------

private
  mEv = C.updateModel (C.LoadEvidence 3) m₇

_ : C.evidenceFor mEv ≡ 3
_ = refl
_ : C.evidenceFor (C.updateModel (C.LoadEvidence 3) mEv) ≡ 0        -- toggle
_ = refl
_ : C.evidenceFor (C.updateModel (C.GotEvidence 3 (err (httpErr "x"))) mEv) ≡ 0
_ = refl
_ : C.evidenceFor (C.updateModel C.CloseEvidence mEv) ≡ 0
_ = refl

------------------------------------------------------------------------
-- «Добавить наблюдение»: guard пустого сабмита (аудит-3 №1) + busy-цикл
------------------------------------------------------------------------

private
  mObs = C.updateModel (C.ObsInput "клиент избегает утро") m₇

_ : C.updateModel C.AddObs m₇ ≡ m₇                    -- пустое поле → no-op (мусор не создаём)
_ = refl
_ : C.busy (C.updateModel C.AddObs mObs) ≡ true
_ = refl
_ : C.obsText (C.updateModel C.AddObs mObs) ≡ ""
_ = refl
_ : C.busy (C.updateModel (C.GotObs 7 (ok 9)) (C.updateModel C.AddObs mObs)) ≡ false
_ = refl

------------------------------------------------------------------------
-- Thread: Reply — guard пустого, чистит поле, busy-цикл
------------------------------------------------------------------------

private
  tm₀ = T.initModel (mkV1Cfg "" "" "" "") 21 0
  tm  = T.updateModel (T.ReplyInput "привет") tm₀
  tm′ = T.updateModel T.Reply tm

_ : T.updateModel T.Reply tm₀ ≡ tm₀                   -- пустой ответ → no-op
_ = refl
_ : T.replyText tm′ ≡ ""
_ = refl
_ : T.busy tm′ ≡ true
_ = refl
_ : T.busy (T.updateModel (T.GotReply (ok 1)) tm′) ≡ false
_ = refl

------------------------------------------------------------------------
-- Text: русские подписи wire-kind'ов (неизвестный — как есть)
------------------------------------------------------------------------

_ : tKindRu "confirm" ≡ "подтверждение"
_ = refl
_ : tKindRu "weaken" ≡ "ослабление"
_ = refl
_ : tKindRu "какой-то-новый" ≡ "какой-то-новый"
_ = refl

------------------------------------------------------------------------
-- Paywall: per-purchase ext_id (аудит-2 №17) + lastPayment для сайта
------------------------------------------------------------------------

private
  pm  = P.initModel (mkV1Cfg "" "" "" "") "site"
  pm₁ = P.updateModel (P.Buy 4) pm

_ : P.nextExtId pm ≡ "site-1"
_ = refl
_ : P.nextExtId pm₁ ≡ "site-2"
_ = refl
_ : P.nextExtId (P.initModel (mkV1Cfg "" "" "" "") "") ≡ ""          -- без префикса — без коррел.
_ = refl
_ : P.nextExtId (P.updateModel (P.Bought (err (httpErr "x"))) pm₁) ≡ "site-2"
_ = refl   -- номер съеден и при ошибке — дырки в нумерации допустимы, коллизии нет
_ : P.lastPayment (P.updateModel (P.Bought (ok 95)) pm₁) ≡ 95
_ = refl
_ : P.busy (P.updateModel (P.Bought (ok 95)) pm₁) ≡ false
_ = refl

------------------------------------------------------------------------
-- Widget: emptyOr-конвенция пустых состояний
------------------------------------------------------------------------

_ : emptyOr {A = String} "пусто" [] ≡ "пусто"
_ = refl
_ : emptyOr "пусто" ("x" ∷ []) ≡ ""
_ = refl

------------------------------------------------------------------------
-- Widget.authorLabel (аудит-4 №2): серверное имя, фолбэк «автор #id»
------------------------------------------------------------------------

_ : authorLabel (mkContentView 5 19 "" 0 false "{}") ≡ "автор #19"
_ = refl
_ : authorLabel (mkContentView 5 19 "Мария К." 0 false "{}") ≡ "Мария К."
_ = refl
