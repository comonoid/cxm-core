{-# OPTIONS --without-K --guardedness #-}

-- CXM headless server (migration Phase 5 entry) — the agdelte-cxm replacement for CrmServer.
-- Open+seed the store from an InstanceConfig (WAL replay + seed the default tenant), seed the
-- admin operator, then serve Cxm.Api.routeExt with the /psych booking+payments pack gated by
-- config. State persists across restarts via the WAL. Everything is a pure function of config
-- (principle 12); packs plug in through the neutral routeExt hook (the core names no vertical).
--
-- Deployment config from env (no recompile):
--   CXM_HOST / CXM_TOKEN (operator bearer; "" = open, gate at nginx) / CXM_JWT_SECRET / CXM_WAL;
--   PSYCH_ADMIN_LOGIN/PASSWORD (bootstrap a bcrypt admin, granted admin globally on first boot);
--   YOOKASSA_SHOP_ID / SECRET_KEY / WEBHOOK_SECRET / RETURN_URL (payments);
--   CXM_SENDMAIL (mail transport command fed RFC822 on stdin, e.g. "sendmail -t" / "msmtp -t";
--   "" = log-only stub) / CXM_MAIL_FROM (sender address).
-- Schedule hours + the service catalogue/prices are pack config (PsychCxm.Catalog), not env.
module CxmServer where

open import Agda.Builtin.IO using (IO)
open import Agda.Builtin.Unit using (⊤)
open import Agda.Builtin.String using (String)
open import Data.String using (toList) renaming (_++_ to _<>_)
open import Data.List using (null; []; _∷_)
open import Data.Bool using (not; if_then_else_)
open import Data.Maybe using (nothing)

postulate setLineBuffering : IO ⊤
{-# FOREIGN GHC import System.IO (hSetBuffering, stdout, BufferMode(LineBuffering)) #-}
{-# COMPILE GHC setLineBuffering = hSetBuffering stdout LineBuffering #-}

open import Data.Bool using (Bool; true; false; _∨_)
open import Data.List using (List; map; _∷_)
open import Data.Product using (proj₂)
open import Data.Nat using (ℕ; _≡ᵇ_; _*_)
open import Data.Nat.Show using (readMaybe; show)
open import Data.Maybe using (Maybe; just)
open import Agda.Builtin.String using (primStringEquality)
open import Agdelte.FFI.Server using
  ( listenHost; listenUnix; forkLoopEvery; getEnvOr; putStrLn; HttpRequest; HttpResponse
  ; reqMethod; reqPath; eqStrCI; StrPair; mkStrPair; _>>=_; _>>_; pure )
open import Agdelte.FFI.HttpClient using (HttpClientManager; newHttpClientManager; httpPostStatus)
open import Agdelte.FFI.Time using (getCurrentTime)
open import Agdelte.FFI.Crypto using (hashPassword)
open import Agdelte.Payment.YooKassa using (newHttpManager)

open import Cxm.Config using
  ( InstanceConfig; mkInstanceConfig; StorageHandle; mkStorageHandle
  ; TenantPolicy; SingleOperator )
open import Cxm.Tenant using (Tenant; mkTenant; defaultTenant)
open import Cxm.Store.Base using (Base; CxmOp)
open import Cxm.Store.Wal using (WalHandle; commitTxn; readBase)
open import Cxm.Store.Interface using (integrationTokensT; tscan)
open import Cxm.Site using (verifyTokenIn)
open import Cxm.Bus using (OutboxEntry; obChannel; obTo; obSubject; obBody)
open import Cxm.Commands using (ensureAdmin)
open import Cxm.Worker using (runOutboxOnce; runMaintenance)
open import Cxm.Api using (runInstance; routeExt; routeSite; gatePack; webhookSignature)
open import PsychCxm.Api using (tryRoute)
open import PsychCxm.Payments using (PayConfig; mkPayConfig)

-- the instance config, sourced from env: WAL-backed store, the "psych" pack active, single-operator
-- tenant policy, and the default tenant seeded (so single-operator collapses by absence, §7.1).
mkCfg : (walPath token secret : String) → InstanceConfig
mkCfg walPath token secret =
  mkInstanceConfig (mkStorageHandle walPath) ("psych" ∷ [])
                   SingleOperator defaultTenant (mkTenant defaultTenant "default" 0 ∷ [])
                   token secret

-- the whole public integration surface dispatches by PREFIX "/v1/" (routeSite 404s unknown
-- /v1 paths itself) — so new /v1 routes in the core need no entry change.
isV1 : String → Bool
isV1 p = pref (toList p)
  where
    open import Data.Char using (Char)
    open import Agda.Builtin.Char using (primCharEquality)
    pref : List Char → Bool
    pref ('/' ∷ 'v' ∷ '1' ∷ '/' ∷ _) = true
    pref _ = false

-- env ℕ with a default (unset/unparseable → def)
envNat : String → ℕ → IO ℕ
envNat key def = getEnvOr key (show def) >>= λ s → pure (orDef (readMaybe 10 s))
  where orDef : Maybe ℕ → ℕ
        orDef (just n) = n
        orDef _        = def

-- run a shell command, feed `stdin`, True iff exit 0 (the sendmail-провайдер seam: the mail
-- transport is WHATEVER command env names — sendmail -t / msmtp -t / a test-капкан "cat >> f").
-- Exceptions (missing binary, …) are absorbed to False — the Outbox retry loop owns recovery.
postulate runPipe : (cmd stdin : String) → IO Bool
{-# FOREIGN GHC
import qualified Data.Text as CxmT
import qualified System.Process as CxmProc
import qualified System.Exit as CxmExit
import qualified Control.Exception as CxmExc
#-}
{-# COMPILE GHC runPipe = \cmd body -> do
      { r <- CxmExc.try (CxmProc.readCreateProcessWithExitCode
                          (CxmProc.shell (CxmT.unpack cmd)) (CxmT.unpack body))
              :: IO (Either CxmExc.SomeException (CxmExit.ExitCode, String, String))
      ; case r of
          { Right (CxmExit.ExitSuccess, _, _) -> pure True
          ; _                                 -> pure False } } #-}

-- the RFC822 message a mail intent becomes (headers + blank line + body). Non-ASCII subjects go
-- through as raw UTF-8 (8BITMIME — fine for modern MTAs; RFC2047 encoding is a future nicety).
mailMessage : (from to subj body : String) → String
mailMessage from to subj body =
  "From: " <> from <> "\r\nTo: " <> to <> "\r\nSubject: " <> subj
  <> "\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n" <> body

-- the delivery ADAPTER (D4, решение 8): the transport side the headless core does not know.
--   "webhook" → POST obBody to obTo, signed (anti-replay: ts in the signed payload — решение 10);
--   "email"   → pipe an RFC822 message into CXM_SENDMAIL (П2: sendmail-провайдер; "" = log-only
--               stub). A failed/absent recipient is False → Outbox backoff → OutFailed audit row;
--   other     → considered delivered (compat with legacy intents).
deliverVia : HttpClientManager → (webhookSecret sendmailCmd mailFrom : String)
           → (now : ℕ) → OutboxEntry → IO Bool
deliverVia mgr secret sendmail mailFrom now e =
  if eqStrCI (obChannel e) "webhook" then
    (let ts  = show now
         sig = webhookSignature secret (obSubject e) (ts <> obBody e)
     in httpPostStatus mgr (obTo e) (obBody e)
          ( mkStrPair "X-Cxm-Topic" (obSubject e)
          ∷ mkStrPair "X-Cxm-Timestamp" ts
          ∷ mkStrPair "X-Cxm-Signature" sig ∷ [] ) >>= λ st →
        pure (ok2xx st))
  else if eqStrCI (obChannel e) "email" then
    (if null (toList sendmail)
     then putStrLn ("email (stub) → " <> obTo e <> ": " <> obSubject e) >> pure true
     else if null (toList (obTo e))
     then putStrLn ("email DROP (empty recipient): " <> obSubject e) >> pure false
     else runPipe sendmail (mailMessage mailFrom (obTo e) (obSubject e) (obBody e)) >>= λ ok →
          putStrLn ("email → " <> obTo e <> (if ok then " sent" else " FAILED")) >> pure ok)
  else pure true
  where
    ok2xx : ℕ → Bool
    ok2xx st = (st ≡ᵇ 200) ∨ (st ≡ᵇ 201) ∨ (st ≡ᵇ 202) ∨ (st ≡ᵇ 204)

-- seed a bcrypt admin + grant the admin role globally, if the login is set (idempotent across
-- restarts via ensureAdmin). Hashing is IO; the create+grant is one commit.
seedAdmin : WalHandle Base CxmOp → (login pass : String) → IO ⊤
seedAdmin h login pass =
  if not (null (toList login))
  then ( getCurrentTime >>= λ now →
         hashPassword pass >>= λ ph →
         commitTxn h (ensureAdmin login ph "*" defaultTenant now) >>= λ _ →
         putStrLn ("admin ensured: " <> login) )
  else putStrLn "(no admin seed — PSYCH_ADMIN_LOGIN unset)"

{-# NON_TERMINATING #-}
main : IO ⊤
main =
  setLineBuffering >>
  getEnvOr "CXM_HOST" "127.0.0.1" >>= λ host →
  getEnvOr "CXM_TOKEN" "" >>= λ token →
  getEnvOr "CXM_JWT_SECRET" "dev-secret-change-me" >>= λ secret →
  getEnvOr "CXM_WAL" "cxm.wal" >>= λ walPath →
  getEnvOr "CXM_SOCKET" "" >>= λ sockPath →
  getEnvOr "PSYCH_ADMIN_LOGIN" "" >>= λ adminLogin →
  getEnvOr "PSYCH_ADMIN_PASSWORD" "" >>= λ adminPass →
  getEnvOr "YOOKASSA_SHOP_ID" "" >>= λ ykShop →
  getEnvOr "YOOKASSA_SECRET_KEY" "" >>= λ ykKey →
  getEnvOr "YOOKASSA_WEBHOOK_SECRET" "" >>= λ ykWh →
  getEnvOr "YOOKASSA_RETURN_URL" "https://vtochku.fun/thanks" >>= λ ykRet →
  getEnvOr "CXM_WEBHOOK_SECRET" "" >>= λ whSecret →
  getEnvOr "CXM_SENDMAIL" "" >>= λ sendmailCmd →
  getEnvOr "CXM_MAIL_FROM" "noreply@localhost" >>= λ mailFrom →
  envNat "CXM_WORKER_SEC" 30 >>= λ workerSec →
  envNat "CXM_MAX_ATTEMPTS" 8 >>= λ maxAtt →
  envNat "CXM_REMIND_LEAD_H" 24 >>= λ leadH →
  newHttpManager >>= λ mgr →
  newHttpClientManager >>= λ cli →
  let cfg  = mkCfg walPath token secret
      pcfg = mkPayConfig mgr ykShop ykKey ykWh ykRet
  in runInstance cfg >>= λ h →
     seedAdmin h adminLogin adminPass >>
     -- D4: the orchestration loop (Concept Ч.2 §6 ORCH) — every CXM_WORKER_SEC seconds run
     -- maintenance (reminders → Outbox, bus dispatch) then deliver due Outbox intents via the
     -- adapter. 0 = worker off (e.g. a read-only replica).
     (if workerSec ≡ᵇ 0 then putStrLn "(worker off — CXM_WORKER_SEC=0)"
      else forkLoopEvery workerSec
             ( getCurrentTime >>= λ now →
               runMaintenance h now (leadH * 3600) >>
               runOutboxOnce h (deliverVia cli whSecret sendmailCmd mailFrom now) now maxAtt >>= λ n →
               (if n ≡ᵇ 0 then pure _ else putStrLn ("worker delivered: " <> show n)) )) >>
     putStrLn "CXM headless + /psych + /auth + /payments + worker" >>
     -- Two contours (§7.7): the public /v1 integration surface (site channel — omnichannel: an
     -- integrated site is just another event source, gated by a scoped integration token verified
     -- against the token store) vs the operator API (routeExt, behind JWT/nginx). CORS preflight
     -- (OPTIONS) → routeSite. verifyTok = scan the token store on a per-request base snapshot.
     (let handler = λ req →
            (if eqStrCI (reqMethod req) "OPTIONS" ∨ isV1 (reqPath req)
             then (readBase h >>= λ b →
                   routeSite (λ t → verifyTokenIn t (map proj₂ (tscan integrationTokensT b))) h req)
             else routeExt (gatePack cfg "psych" (tryRoute pcfg h))
                           (λ _ _ → pure nothing) token secret h req)
      in if null (toList sockPath) then listenHost host 8137 handler
         else listenUnix sockPath handler)
