module Nameservice.Modules.Nameservice

  (
    -- * Module
    NameserviceM
  , nameserviceModule

    -- * types
  , Name(..)
  , Whois (..)
  , NameserviceException(..)
  , NameserviceMessage(..)
  , NameClaimed(..)
  , NameRemapped(..)
  , NameDeleted(..)
  , Faucetted(..)
  , BuyName(..)
  , SetName(..)
  , DeleteName(..)
  , FaucetAccount(..)

  -- * effects
  , NameserviceEffR
  , HasNameserviceEff
  , getWhois
  , buyName
  , setName
  , deleteName
  , faucetAccount

  -- * interpreter
  , eval

  -- * message router
  , router

  -- * query API
  , Api
  , server

  ) where

import           Nameservice.Modules.Nameservice.Keeper
import           Nameservice.Modules.Nameservice.Messages
import           Nameservice.Modules.Nameservice.Query
import           Nameservice.Modules.Nameservice.Router
import           Nameservice.Modules.Nameservice.Types
import           Nameservice.Modules.Token                (HasTokenEff)
import           Tendermint.SDK.BaseApp                   (HasBaseAppEff)
import           Tendermint.SDK.Module                    (Module (..))

type NameserviceM r = Module "nameservice" NameserviceMessage Api r

nameserviceModule
  :: HasBaseAppEff r
  => HasTokenEff r
  => HasNameserviceEff r
  => NameserviceM r
nameserviceModule = Module
  { moduleRouter = router
  , moduleQueryServer = server
  }