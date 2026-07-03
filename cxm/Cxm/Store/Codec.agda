{-# OPTIONS --without-K #-}

-- Op codec for the WAL (cxm-plan.md Phase 5, CRM #D pattern). Each op = a one-char tag +
-- the record body via Cxm.Wire (or the id via encℕ for deletes). Uppercase tag = Set,
-- lowercase = Del; one letter per entity. `decodeOp (encodeOp op) ≡ just op` (tested).
-- This is what Cxm.Store.Wal hands to the WAL as (walSerializeOp / walDeserializeOp).
module Cxm.Store.Codec where

open import Data.Nat using (ℕ)
open import Data.String using (String; toList; fromList) renaming (_++_ to _<>_)
open import Data.Maybe using (Maybe; just; nothing)
open import Data.Bool using (if_then_else_)
open import Data.List using ([]; _∷_)
open import Data.Char using (Char)
open import Agda.Builtin.Char using (primCharEquality)

open import Agdelte.Storage.Wire using (encℕ; decℕ)

open import Cxm.Store.Base
open import Cxm.Wire using
  ( encTenant; decTenant; encSubject; decSubject; encEdge; decEdge
  ; encIdentity; decIdentity; encExperienceEvent; decExperienceEvent
  ; encEvent; decEvent; encOutbox; decOutbox; encKnowledge; decKnowledge
  ; encEvidence; decEvidence; encTransition; decTransition; encDeviation; decDeviation
  ; encProtocolState; decProtocolState; encProtocolTransition; decProtocolTransition
  ; encOffering; decOffering; encResource; decResource; encEntitlement; decEntitlement
  ; encAccount; decAccount; encPayment; decPayment; encExpectation; decExpectation
  ; encPromise; decPromise; encProtocol; decProtocol; encEpisode; decEpisode
  ; encUser; decUser; encAssignment; decAssignment; encAppointment; decAppointment
  ; encIntToken; decIntToken; encResourceLink; decResourceLink; encMention; decMention )

encodeOp : CxmOp → String
encodeOp (SetTenant t)     = "T" <> encTenant t
encodeOp (SetSubject s)    = "S" <> encSubject s
encodeOp (SetEdge e)       = "G" <> encEdge e
encodeOp (SetIdentity x)   = "I" <> encIdentity x
encodeOp (SetEvent e)      = "X" <> encExperienceEvent e
encodeOp (SetBusEvent e)   = "B" <> encEvent e
encodeOp (SetOutbox o)     = "O" <> encOutbox o
encodeOp (SetKnowledge k)  = "K" <> encKnowledge k
encodeOp (SetEvidence e)   = "E" <> encEvidence e
encodeOp (SetTransition t) = "R" <> encTransition t
encodeOp (SetDeviation d)  = "D" <> encDeviation d
encodeOp (SetProtState p)  = "P" <> encProtocolState p
encodeOp (SetProtTrans p)  = "Q" <> encProtocolTransition p
encodeOp (SetOffering o)    = "F" <> encOffering o
encodeOp (SetResource r)    = "C" <> encResource r
encodeOp (SetEntitlement e) = "N" <> encEntitlement e
encodeOp (SetAccount a)     = "A" <> encAccount a
encodeOp (SetPayment p)     = "Y" <> encPayment p
encodeOp (SetExpectation x) = "W" <> encExpectation x
encodeOp (SetPromise p)     = "M" <> encPromise p
encodeOp (SetProtocol p)    = "L" <> encProtocol p
encodeOp (SetEpisode e)     = "J" <> encEpisode e
encodeOp (SetUser u)        = "U" <> encUser u
encodeOp (SetAssignment a)  = "H" <> encAssignment a
encodeOp (SetAppointment a) = "Z" <> encAppointment a
encodeOp (SetIntToken r) = "V" <> encIntToken r
encodeOp (SetResourceLink l) = "@" <> encResourceLink l
encodeOp (SetMention m) = "#" <> encMention m
encodeOp (DelTenant id)    = "t" <> encℕ id
encodeOp (DelSubject id)   = "s" <> encℕ id
encodeOp (DelEdge id)      = "g" <> encℕ id
encodeOp (DelIdentity id)  = "i" <> encℕ id
encodeOp (DelBusEvent id)  = "b" <> encℕ id
encodeOp (DelOutbox id)    = "o" <> encℕ id
encodeOp (DelKnowledge id) = "k" <> encℕ id
encodeOp (DelEvidence id)  = "e" <> encℕ id
encodeOp (DelTransition id)= "r" <> encℕ id
encodeOp (DelDeviation id) = "d" <> encℕ id
encodeOp (DelProtState id) = "p" <> encℕ id
encodeOp (DelProtTrans id) = "q" <> encℕ id
encodeOp (DelOffering id)    = "f" <> encℕ id
encodeOp (DelResource id)    = "c" <> encℕ id
encodeOp (DelEntitlement id) = "n" <> encℕ id
encodeOp (DelAccount id)     = "a" <> encℕ id
encodeOp (DelPayment id)     = "y" <> encℕ id
encodeOp (DelExpectation id) = "w" <> encℕ id
encodeOp (DelPromise id)     = "m" <> encℕ id
encodeOp (DelProtocol id)    = "l" <> encℕ id
encodeOp (DelEpisode id)     = "j" <> encℕ id
encodeOp (DelUser id)        = "u" <> encℕ id
encodeOp (DelAssignment id)  = "h" <> encℕ id
encodeOp (DelAppointment id) = "z" <> encℕ id
encodeOp (DelIntToken id) = "v" <> encℕ id
encodeOp (DelResourceLink id) = "x" <> encℕ id
encodeOp (DelMention id) = "%" <> encℕ id

private
  -- Set-op reconstructors: Maybe record → Maybe CxmOp.
  mSet : ∀ {V : Set} → (V → CxmOp) → Maybe V → Maybe CxmOp
  mSet f (just x) = just (f x)
  mSet f nothing  = nothing
  -- Del-op reconstructor: Maybe id → Maybe CxmOp.
  mDel : (ℕ → CxmOp) → Maybe ℕ → Maybe CxmOp
  mDel f (just n) = just (f n)
  mDel f nothing  = nothing

decodeOp : String → Maybe CxmOp
decodeOp s with toList s
... | []         = nothing
... | (c ∷ rest) =
  let body = fromList rest in
  if      primCharEquality c 'T' then mSet SetTenant     (decTenant body)
  else if primCharEquality c 'S' then mSet SetSubject    (decSubject body)
  else if primCharEquality c 'G' then mSet SetEdge       (decEdge body)
  else if primCharEquality c 'I' then mSet SetIdentity   (decIdentity body)
  else if primCharEquality c 'X' then mSet SetEvent      (decExperienceEvent body)
  else if primCharEquality c 'B' then mSet SetBusEvent   (decEvent body)
  else if primCharEquality c 'O' then mSet SetOutbox     (decOutbox body)
  else if primCharEquality c 'K' then mSet SetKnowledge  (decKnowledge body)
  else if primCharEquality c 'E' then mSet SetEvidence   (decEvidence body)
  else if primCharEquality c 'R' then mSet SetTransition (decTransition body)
  else if primCharEquality c 'D' then mSet SetDeviation  (decDeviation body)
  else if primCharEquality c 'P' then mSet SetProtState  (decProtocolState body)
  else if primCharEquality c 'Q' then mSet SetProtTrans  (decProtocolTransition body)
  else if primCharEquality c 't' then mDel DelTenant     (decℕ body)
  else if primCharEquality c 's' then mDel DelSubject    (decℕ body)
  else if primCharEquality c 'g' then mDel DelEdge       (decℕ body)
  else if primCharEquality c 'i' then mDel DelIdentity   (decℕ body)
  else if primCharEquality c 'b' then mDel DelBusEvent   (decℕ body)
  else if primCharEquality c 'o' then mDel DelOutbox     (decℕ body)
  else if primCharEquality c 'k' then mDel DelKnowledge  (decℕ body)
  else if primCharEquality c 'e' then mDel DelEvidence   (decℕ body)
  else if primCharEquality c 'r' then mDel DelTransition (decℕ body)
  else if primCharEquality c 'd' then mDel DelDeviation  (decℕ body)
  else if primCharEquality c 'p' then mDel DelProtState  (decℕ body)
  else if primCharEquality c 'q' then mDel DelProtTrans  (decℕ body)
  else if primCharEquality c 'F' then mSet SetOffering    (decOffering body)
  else if primCharEquality c 'C' then mSet SetResource    (decResource body)
  else if primCharEquality c 'N' then mSet SetEntitlement (decEntitlement body)
  else if primCharEquality c 'A' then mSet SetAccount     (decAccount body)
  else if primCharEquality c 'Y' then mSet SetPayment     (decPayment body)
  else if primCharEquality c 'W' then mSet SetExpectation (decExpectation body)
  else if primCharEquality c 'M' then mSet SetPromise     (decPromise body)
  else if primCharEquality c 'L' then mSet SetProtocol    (decProtocol body)
  else if primCharEquality c 'J' then mSet SetEpisode     (decEpisode body)
  else if primCharEquality c 'U' then mSet SetUser        (decUser body)
  else if primCharEquality c 'H' then mSet SetAssignment  (decAssignment body)
  else if primCharEquality c 'Z' then mSet SetAppointment (decAppointment body)
  else if primCharEquality c 'V' then mSet SetIntToken     (decIntToken body)
  else if primCharEquality c '@' then mSet SetResourceLink (decResourceLink body)
  else if primCharEquality c '#' then mSet SetMention      (decMention body)
  else if primCharEquality c 'f' then mDel DelOffering    (decℕ body)
  else if primCharEquality c 'c' then mDel DelResource    (decℕ body)
  else if primCharEquality c 'n' then mDel DelEntitlement (decℕ body)
  else if primCharEquality c 'a' then mDel DelAccount     (decℕ body)
  else if primCharEquality c 'y' then mDel DelPayment     (decℕ body)
  else if primCharEquality c 'w' then mDel DelExpectation (decℕ body)
  else if primCharEquality c 'm' then mDel DelPromise     (decℕ body)
  else if primCharEquality c 'l' then mDel DelProtocol    (decℕ body)
  else if primCharEquality c 'j' then mDel DelEpisode     (decℕ body)
  else if primCharEquality c 'u' then mDel DelUser        (decℕ body)
  else if primCharEquality c 'h' then mDel DelAssignment  (decℕ body)
  else if primCharEquality c 'z' then mDel DelAppointment (decℕ body)
  else if primCharEquality c 'v' then mDel DelIntToken     (decℕ body)
  else if primCharEquality c 'x' then mDel DelResourceLink (decℕ body)
  else if primCharEquality c '%' then mDel DelMention      (decℕ body)
  else nothing
