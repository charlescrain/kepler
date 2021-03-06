{-# LANGUAGE TemplateHaskell #-}

module Tendermint.SDK.BaseApp.Store.RawStore
  (
  -- * Effects
    StoreEffs
  , Scope(..)
  , ReadStore(..)
  , storeGet
  , get
  , prove
  , WriteStore(..)
  , put
  , storePut
  , delete
  , storeDelete
  , CommitBlock(..)
  , commitBlock
  , Transaction(..)
  , beginTransaction
  , withSandbox
  , withTransaction
  , commit

  -- * Types
  , RawKey(..)
  , IsKey(..)
  , StoreKey(..)
  , KeyRoot(..)
  , makeKeyBytes
  , CommitResponse(..)
  , Store
  , nestStore
  , makeStore
  , makeStoreKey

  , Version(..)
  ) where

import           Control.Lens                  (Iso', iso, (^.))
import           Data.ByteArray.Base64String   (Base64String)
import qualified Data.ByteString               as BS
import           Data.Proxy
import           Data.String.Conversions       (cs)
import           Data.Text
import           Data.Word                     (Word64)
import           Numeric.Natural               (Natural)
import           Polysemy                      (Member, Members, Sem, makeSem)
import           Polysemy.Error                (Error, catch, throw)
import           Polysemy.Resource             (Resource, finally, onException)
import           Polysemy.Tagged               (Tagged)
import           Tendermint.SDK.BaseApp.Errors (AppError, SDKError (ParseError),
                                                throwSDKError)
import           Tendermint.SDK.Codec          (HasCodec (..))
import           Tendermint.SDK.Types.Address  (Address, addressFromBytes,
                                                addressToBytes)

--------------------------------------------------------------------------------
-- | Keys
--------------------------------------------------------------------------------

class RawKey k where
  rawKey :: Iso' k BS.ByteString

instance RawKey Text where
  rawKey = iso cs cs

instance RawKey Address where
    rawKey = iso addressToBytes addressFromBytes

instance RawKey Word64 where
    rawKey = iso encode (either (error "Error decoding Word64 RawKey") id . decode)

instance RawKey () where
    rawKey = iso (const "") (const ())

class RawKey k => IsKey k ns where
  type Value k ns :: *
  prefix :: Proxy k -> Proxy ns -> BS.ByteString

  default prefix :: Proxy k -> Proxy ns -> BS.ByteString
  prefix _ _ = ""

data StoreKey = StoreKey
  { skPathFromRoot :: [BS.ByteString]
  , skKey          :: BS.ByteString
  } deriving (Eq, Show, Ord)

makeKeyBytes :: StoreKey -> BS.ByteString
makeKeyBytes StoreKey{..} =  mconcat skPathFromRoot <> skKey

--------------------------------------------------------------------------------
-- | Store
--------------------------------------------------------------------------------

newtype KeyRoot ns =
  KeyRoot BS.ByteString deriving (Eq, Show)

data Store ns = Store
  { storePathFromRoot :: [BS.ByteString]
  }

makeStore :: KeyRoot ns  -> Store ns
makeStore (KeyRoot ns) = Store
  { storePathFromRoot = [ns]
  }

nestStore :: Store parentns -> Store childns -> Store childns
nestStore (Store parentPath) (Store childPath) =
  Store
    { storePathFromRoot =  parentPath ++ childPath
    }

makeStoreKey
  :: forall k ns.
     IsKey k ns
  => Store ns
  -> k
  -> StoreKey
makeStoreKey (Store path) k =
  StoreKey
    { skKey = prefix (Proxy @k) (Proxy @ns) <> k ^. rawKey
    , skPathFromRoot = path
    }


--------------------------------------------------------------------------------
-- | Read and Write Effects
--------------------------------------------------------------------------------


data ReadStore m a where
  StoreGet   :: StoreKey -> ReadStore m (Maybe BS.ByteString)
  StoreProve :: StoreKey -> ReadStore m (Maybe BS.ByteString)

makeSem ''ReadStore

data WriteStore m a where
  StorePut   :: StoreKey -> BS.ByteString -> WriteStore m ()
  StoreDelete :: StoreKey -> WriteStore m ()

makeSem ''WriteStore

put
  :: forall k r ns.
     IsKey k ns
  => HasCodec (Value k ns)
  => Member WriteStore r
  => Store ns
  -> k
  -> Value k ns
  -> Sem r ()
put store k a =
  let key = makeStoreKey store k
      val = encode a
  in storePut key val

get
  :: forall k r ns.
     IsKey k ns
  => HasCodec (Value k ns)
  => Members [ReadStore, Error AppError] r
  => Store ns
  -> k
  -> Sem r (Maybe (Value k ns))
get store k = do
  let key = makeStoreKey store k
  mRes <- storeGet key
  case mRes of
    Nothing -> pure Nothing
    Just raw -> case decode raw of
      Left e  -> throwSDKError (ParseError $ "Impossible codec error: "  <> cs e)
      Right a -> pure $ Just a

delete
  :: forall k ns r.
     IsKey k ns
  => Member WriteStore r
  => Store ns
  -> k
  -> Sem r ()
delete store k =
  let key = makeStoreKey store k
  in storeDelete key

prove
  :: forall k ns r.
     IsKey k ns
  => Member ReadStore r
  => Store ns
  -> k
  -> Sem r (Maybe BS.ByteString)
prove store k =
  let key = makeStoreKey store k
  in storeProve key

--------------------------------------------------------------------------------
-- | Consensus Effects
--------------------------------------------------------------------------------

data CommitBlock m a where
  CommitBlock :: CommitBlock m Base64String

makeSem ''CommitBlock

data CommitResponse = CommitResponse
  { rootHash   :: Base64String
  , newVersion :: Natural
  } deriving (Eq, Show)

data Transaction m a where
  -- transact
  BeginTransaction :: Transaction m ()
  Rollback :: Transaction m ()
  Commit :: Transaction m CommitResponse

makeSem ''Transaction

withTransaction
  :: forall r a.
     Members [Transaction, Resource, Error AppError] r
  => Sem r a
  -> Sem r (a, CommitResponse)
withTransaction m =
   let tryTx = m `catch` (\e -> rollback *> throw e)
       actionWithCommit = do
         res <- tryTx
         c <- commit
         pure (res, c)
   in do
      onException actionWithCommit rollback

withSandbox
  :: forall r a.
     Members [Transaction, Resource, Error AppError] r
  => Sem r a
  -> Sem r a
withSandbox m =
   let tryTx = m `catch` (\e -> rollback *> throw e)
   in finally (tryTx <* rollback) rollback

data Version =
    Genesis
  | Version Natural
  | Latest
  deriving (Eq, Show)

--------------------------------------------------------------------------------
-- | Store Effects
--------------------------------------------------------------------------------

data Scope = Consensus | QueryAndMempool

type StoreEffs =
  [ Tagged 'Consensus ReadStore
  , Tagged 'QueryAndMempool ReadStore
  , Tagged 'Consensus WriteStore
  , Transaction
  , CommitBlock
  ]
