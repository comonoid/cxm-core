{-# OPTIONS --without-K #-}

-- CxmUI.Tokens — операторский виджет integration-токенов (Ф6-хвост: ревокация).
-- Bearer-поверхность (Cfg): список (id/scope/revoked — сам токен сервер показывает ТОЛЬКО
-- при минте, аудит-4 №3), минт (свежий токен показывается один раз в статусе) и ревокация.
-- Embedding-паттерн как у всех: PUBLIC Model/Msg/updateModel/cmdOf/template.
module CxmUI.Tokens where

open import Data.Bool using (Bool; true; false; if_then_else_)
open import Data.Nat using (ℕ)
open import Data.Nat.Show using (show)
open import Data.String using (String; _++_)
open import Data.List using (List; []; _∷_; [_])
open import Agda.Builtin.Unit using (⊤)

open import Agdelte.Core.Result using (Result; ok; err)
open import Agdelte.Core.Cmd using (Cmd; ε)
open import Agdelte.Core.Event using (never)
open import Agdelte.Reactive.Node

open import CxmUI.Contract using (IntTokenView; itId; itScope; itRevoked)
open import CxmUI.Client using
  ( Cfg; CallErr; MintedToken; mtId; mtToken
  ; listIntegrationTokens; mintIntegrationToken; revokeIntegrationToken )
open import CxmUI.Widget using (errText; emptyOr; toolbar)

record Model : Set where
  constructor mkModel
  field
    cfg    : Cfg
    items  : List IntTokenView
    status : String
    minted : String     -- свежий токен ОТДЕЛЬНО от status: перечит списка не должен
                        -- затереть «скопируйте…» (урок гонки Booking.done)
open Model public

initModel : Cfg → Model
initModel c = mkModel c [] "…" ""

data Msg : Set where
  Load    : Msg
  Got     : Result CallErr (List IntTokenView) → Msg
  Mint    : Msg
  Minted  : Result CallErr MintedToken → Msg
  Revoke  : ℕ → Msg
  Revoked : Result CallErr ⊤ → Msg

updateModel : Msg → Model → Model
updateModel Load m = record m { status = "загружаю…" }
updateModel (Got (ok xs)) m = record m { items = xs ; status = emptyOr "токенов нет" xs }
updateModel (Got (err e)) m = record m { status = errText e }
updateModel Mint m = record m { status = "минчу…" ; minted = "" }
-- сам токен виден ТОЛЬКО здесь и только один раз — скопируйте сразу
updateModel (Minted (ok t)) m =
  record m { minted = "токен #" ++ show (mtId t) ++ " (скопируйте, больше не покажется): "
                      ++ mtToken t }
updateModel (Minted (err e)) m = record m { status = errText e }
updateModel (Revoke _) m = record m { status = "отзываю…" }
updateModel (Revoked (ok _)) m = m
updateModel (Revoked (err e)) m = record m { status = errText e }

cmdOf : Msg → Model → Cmd Msg
cmdOf Load m = listIntegrationTokens (cfg m) Got
cmdOf Mint m = mintIntegrationToken (cfg m) "cabinet" Minted
cmdOf (Minted (ok _)) m = listIntegrationTokens (cfg m) Got
cmdOf (Revoke i) m = revokeIntegrationToken (cfg m) i Revoked
cmdOf (Revoked (ok _)) m = listIntegrationTokens (cfg m) Got
cmdOf _ _ = ε

private
  row : IntTokenView → ℕ → Node Model Msg
  row t _ = li (class ("cxm-token" ++ (if itRevoked t then " cxm-token-revoked" else "")) ∷ [])
    ( span (class "cxm-token-id" ∷ []) [ text ("#" ++ show (itId t)) ]
    ∷ span (class "cxm-token-scope" ∷ []) [ text (itScope t) ]
    ∷ (if itRevoked t
        then span (class "cxm-token-state" ∷ []) [ text "отозван" ]
        else button (onClick (Revoke (itId t)) ∷ class "cxm-token-revoke" ∷ []) [ text "Отозвать" ])
    ∷ [] )

tokensTemplate : Node Model Msg
tokensTemplate = div (class "cxm-tokens" ∷ [])
  ( toolbar "Обновить" Load status
  ∷ button (onClick Mint ∷ class "cxm-token-mint" ∷ []) [ text "Новый токен" ]
  ∷ div (class "cxm-token-fresh" ∷ []) [ bindF minted ]
  ∷ ul [] ( foreachKeyed items (λ t → show (itId t)) row ∷ [] )
  ∷ [] )

tokensApp : Cfg → ReactiveApp Model Msg
tokensApp c = mkReactiveApp (initModel c) updateModel tokensTemplate cmdOf (λ _ → never)
