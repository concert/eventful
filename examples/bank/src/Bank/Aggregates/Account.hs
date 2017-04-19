module Bank.Aggregates.Account
  ( Account (..)
  , PendingAccountTransfer (..)
  , AccountEvent (..)
  , accountEventSerializer
  , AccountOpened (..)
  , AccountCredited (..)
  , AccountDebited (..)
  , AccountProjection
  , accountProjection
  , AccountCommand (..)
  , OpenAccountData (..)
  , CreditAccountData (..)
  , DebitAccountData (..)
  , TransferToAccountData (..)
  , AcceptTransferData (..)
  , AccountCommandError (..)
  , NotEnoughFundsData (..)
  , AccountAggregate
  , accountAggregate

  , accountAvailableBalance
  ) where

import Data.Aeson.TH
import Data.List (delete, lookup)
import Data.Maybe (isJust)

import Eventful
import Eventful.TH

import Bank.Events
import Bank.Json

data Account =
  Account
  { accountBalance :: Double
  , accountOwner :: Maybe UUID
  , accountPendingTransfers :: [(UUID, PendingAccountTransfer)]
  } deriving (Show, Eq)

accountDefault :: Account
accountDefault = Account 0 Nothing []

data PendingAccountTransfer =
  PendingAccountTransfer
  { pendingAccountTransferAmount :: Double
  , pendingAccountTransferTargetAccount :: UUID
  } deriving (Show, Eq)

deriveJSON (unPrefixLower "account") ''Account
deriveJSON (unPrefixLower "pendingAccountTransfer") ''PendingAccountTransfer

-- | Account balance minus pending balance
accountAvailableBalance :: Account -> Double
accountAvailableBalance account = accountBalance account - pendingBalance
  where
    transfers = map snd $ accountPendingTransfers account
    pendingBalance = if null transfers then 0 else sum (map pendingAccountTransferAmount transfers)

applyAccountOpened :: Account -> AccountOpened -> Account
applyAccountOpened account (AccountOpened uuid amount) = account { accountOwner = Just uuid, accountBalance = amount }

applyAccountCredited :: Account -> AccountCredited -> Account
applyAccountCredited account (AccountCredited amount _) = account { accountBalance = accountBalance account + amount }

applyAccountDebited :: Account -> AccountDebited -> Account
applyAccountDebited account (AccountDebited amount _) = account { accountBalance = accountBalance account - amount }

applyAccountTransferStarted :: Account -> AccountTransferStarted -> Account
applyAccountTransferStarted account (AccountTransferStarted uuid amount targetId) =
  account { accountPendingTransfers = (uuid, transfer) : accountPendingTransfers account }
  where
    transfer = PendingAccountTransfer amount targetId

applyAccountTransferCompleted :: Account -> AccountTransferCompleted -> Account
applyAccountTransferCompleted account (AccountTransferCompleted uuid) =
  -- If the transfer isn't present, something is wrong, but we can't fail in an
  -- event handler.
  maybe account go (lookup uuid (accountPendingTransfers account))
  where
    go trans@(PendingAccountTransfer amount _) =
      account
      { accountBalance = accountBalance account - amount
      , accountPendingTransfers = delete (uuid, trans) (accountPendingTransfers account)
      }

applyAccountTransferRejected :: Account -> AccountTransferRejected -> Account
applyAccountTransferRejected account (AccountTransferRejected uuid _) =
  account { accountPendingTransfers = transfers' }
  where
    transfers = accountPendingTransfers account
    transfers' = maybe transfers (\trans -> delete (uuid, trans) transfers) (lookup uuid transfers)

applyAccountCreditedFromTransfer :: Account -> AccountCreditedFromTransfer -> Account
applyAccountCreditedFromTransfer account (AccountCreditedFromTransfer _ _ amount) =
  account { accountBalance = accountBalance account + amount }

mkProjection ''Account 'accountDefault
  [ ''AccountOpened
  , ''AccountCredited
  , ''AccountDebited
  , ''AccountTransferStarted
  , ''AccountTransferCompleted
  , ''AccountTransferRejected
  , ''AccountCreditedFromTransfer
  ]
deriving instance Show AccountEvent
deriving instance Eq AccountEvent

mkSumTypeSerializer "accountEventSerializer" ''AccountEvent ''BankEvent

data AccountCommand
  = OpenAccount OpenAccountData
  | CreditAccount CreditAccountData
  | DebitAccount DebitAccountData
  | TransferToAccount TransferToAccountData
  | AcceptTransfer AcceptTransferData
  deriving (Show, Eq)

data OpenAccountData =
  OpenAccountData
  { openAccountDataOwner :: UUID
  , openAccountDataInitialFunding :: Double
  } deriving (Show, Eq)

data CreditAccountData =
  CreditAccountData
  { creditAccountDataAmount :: Double
  , creditAccountDataReason :: String
  } deriving (Show, Eq)

data DebitAccountData =
  DebitAccountData
  { debitAccountDataAmount :: Double
  , debitAccountDataReason :: String
  } deriving (Show, Eq)

data TransferToAccountData =
  TransferToAccountData
  { transferToAccountDataTransferId :: UUID
  , transferToAccountDataAmount :: Double
  , transferToAccountDataTargetAccount :: UUID
  } deriving (Show, Eq)

data AcceptTransferData =
  AcceptTransferData
  { acceptTransferTransferId :: UUID
  , acceptTransferSourceId :: UUID
  , acceptTransferDataAmount :: Double
  } deriving (Show, Eq)

data AccountCommandError
  = AccountAlreadyOpenError
  | InvalidInitialDepositError
  | NotEnoughFundsError NotEnoughFundsData
  | AccountNotOwnedError
  deriving (Show, Eq)

data NotEnoughFundsData =
  NotEnoughFundsData
  { notEnoughFundsDataRemainingFunds :: Double
  } deriving  (Show, Eq)

deriveJSON (unPrefixLower "notEnoughFundsData") ''NotEnoughFundsData
deriveJSON defaultOptions ''AccountCommandError

applyAccountCommand :: Account -> AccountCommand -> Either AccountCommandError [AccountEvent]
applyAccountCommand account (OpenAccount (OpenAccountData owner amount)) =
  case accountOwner account of
    Just _ -> Left AccountAlreadyOpenError
    Nothing ->
      if amount < 0
      then Left InvalidInitialDepositError
      else Right [AccountAccountOpened $ AccountOpened owner amount]
applyAccountCommand _ (CreditAccount (CreditAccountData amount reason)) =
  Right [AccountAccountCredited $ AccountCredited amount reason]
applyAccountCommand account (DebitAccount (DebitAccountData amount reason)) =
  if accountAvailableBalance account - amount < 0
  then Left $ NotEnoughFundsError (NotEnoughFundsData $ accountAvailableBalance account)
  else Right [AccountAccountDebited $ AccountDebited amount reason]
applyAccountCommand account (TransferToAccount (TransferToAccountData uuid amount targetId)) =
  if accountAvailableBalance account - amount < 0
  then Left $ NotEnoughFundsError (NotEnoughFundsData $ accountAvailableBalance account)
  else Right [AccountAccountTransferStarted $ AccountTransferStarted uuid amount targetId]
applyAccountCommand account (AcceptTransfer (AcceptTransferData transferId sourceId amount)) =
  if isJust (accountOwner account)
  then Right [AccountAccountCreditedFromTransfer $ AccountCreditedFromTransfer transferId sourceId amount]
  else Left AccountNotOwnedError

type AccountAggregate = Aggregate Account AccountEvent AccountCommand AccountCommandError

accountAggregate :: AccountAggregate
accountAggregate = Aggregate applyAccountCommand accountProjection