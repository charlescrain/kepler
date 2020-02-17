{-# LANGUAGE TemplateHaskell #-}
module SimpleStorage.Modules.SimpleStorage.Keeper
  ( SimpleStorage
  , SimpleStorageEffs
  , updateCount
  , getCount
  , storeKey
  , eval
  ) where

import           Polysemy                                  (Members, Sem,
                                                            interpret, makeSem)
import           Polysemy.Output                           (Output)
import           SimpleStorage.Modules.SimpleStorage.Types (Count,
                                                            CountKey (..),
                                                            CountSet (..))
import qualified Tendermint.SDK.BaseApp                    as BaseApp

storeKey :: BaseApp.StoreKey "simple_storage"
storeKey = BaseApp.StoreKey "simple_storage"

data SimpleStorage m a where
    PutCount :: Count -> SimpleStorage m ()
    GetCount :: SimpleStorage m (Maybe Count)

makeSem ''SimpleStorage

type SimpleStorageEffs = '[SimpleStorage]

updateCount
  ::  Members '[SimpleStorage, Output BaseApp.Event, BaseApp.Logger] r
  => Count
  -> Sem r ()
updateCount count = do
  putCount count
  let event = CountSet count
  BaseApp.emit event
  BaseApp.logEvent event

eval
  :: forall r.
     Members BaseApp.TxEffs r
  => forall a. (Sem (SimpleStorage ': r) a -> Sem r a)
eval = interpret (\case
  PutCount count -> do
    BaseApp.put storeKey CountKey count
  GetCount -> BaseApp.get storeKey CountKey
  )