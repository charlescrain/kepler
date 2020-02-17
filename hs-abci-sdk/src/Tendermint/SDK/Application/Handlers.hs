module Tendermint.SDK.Application.Handlers
  ( Handler
  , HandlersContext(..)
  , makeApp
  ) where

import           Control.Lens                             (from, to, (&), (.~),
                                                           (^.))
import           Crypto.Hash                              (Digest)
import           Crypto.Hash.Algorithms                   (SHA256)
import qualified Data.ByteArray.Base64String              as Base64
import           Data.Default.Class                       (Default (..))
import           Data.Proxy
import           Network.ABCI.Server.App                  (App (..),
                                                           MessageType (..),
                                                           Request (..),
                                                           Response (..),
                                                           transformApp)
import qualified Network.ABCI.Types.Messages.Request      as Req
import qualified Network.ABCI.Types.Messages.Response     as Resp
import           Polysemy
import           Polysemy.Error                           (catch)
import qualified Tendermint.SDK.Application.Module        as M
import qualified Tendermint.SDK.BaseApp                   as BA
import           Tendermint.SDK.BaseApp.Errors            (SDKError (..),
                                                           queryAppError,
                                                           throwSDKError,
                                                           txResultAppError)
import qualified Tendermint.SDK.BaseApp.Query             as Q
import qualified Tendermint.SDK.BaseApp.Store             as Store
import           Tendermint.SDK.BaseApp.Transaction       as T
import           Tendermint.SDK.BaseApp.Transaction.Cache (writeCache)
import           Tendermint.SDK.Crypto                    (RecoverableSignatureSchema,
                                                           SignatureSchema (..))
import           Tendermint.SDK.Types.Transaction         (parseTx)
import           Tendermint.SDK.Types.TxResult            (checkTxTxResult,
                                                           deliverTxTxResult)

type Handler mt r = Request mt -> Sem r (Response mt)

data Handlers r = Handlers
  { info       :: Handler 'MTInfo r
  , setOption  :: Handler 'MTSetOption r
  , initChain  :: Handler 'MTInitChain r
  , query      :: Handler 'MTQuery r
  , checkTx    :: Handler 'MTCheckTx r
  , beginBlock :: Handler 'MTBeginBlock r
  , deliverTx  :: Handler 'MTDeliverTx r
  , endBlock   :: Handler 'MTEndBlock r
  , commit     :: Handler 'MTCommit r
  }

defaultHandlers :: forall r. Handlers r
defaultHandlers = Handlers
  { info = defaultHandler
  , setOption = defaultHandler
  , initChain = defaultHandler
  , query = defaultHandler
  , checkTx = defaultHandler
  , beginBlock = defaultHandler
  , deliverTx = defaultHandler
  , endBlock = defaultHandler
  , commit = defaultHandler
  }
  where
    defaultHandler
      :: Default a
      => Applicative m
      => b
      -> m a
    defaultHandler = const $ pure def


data HandlersContext alg ms r core = HandlersContext
  { signatureAlgP :: Proxy alg
  , modules       :: M.ModuleList ms r
  , anteHandler   :: BA.AnteHandler r
  , compileToCore :: forall a. Sem (BA.BaseApp core) a -> Sem core a
  }

-- Common function between checkTx and deliverTx
makeHandlers
  :: forall alg ms r core.
     RecoverableSignatureSchema alg
  => Message alg ~ Digest SHA256
  => M.ToApplication ms (M.Effs ms (BA.BaseApp core))
  => T.HasTxRouter (M.ApplicationC ms) (M.Effs ms (BA.BaseApp core)) 'Store.QueryAndMempool
  => T.HasTxRouter (M.ApplicationC ms) (BA.BaseApp core) 'Store.QueryAndMempool
  => T.HasTxRouter (M.ApplicationD ms) (M.Effs ms (BA.BaseApp core)) 'Store.Consensus
  => T.HasTxRouter (M.ApplicationD ms) (BA.BaseApp core) 'Store.Consensus
  => Q.HasQueryRouter (M.ApplicationQ ms) (M.Effs ms (BA.BaseApp core))
  => Q.HasQueryRouter (M.ApplicationQ ms) (BA.BaseApp core)
  => M.Eval ms (BA.BaseApp core)
  => M.Effs ms (BA.BaseApp core) ~ r
  => HandlersContext alg ms r core
  -> Handlers (BA.BaseApp core)
makeHandlers (HandlersContext{..} :: HandlersContext alg ms r core) =
  let

      rProxy :: Proxy (BA.BaseApp core)
      rProxy = Proxy

      app :: M.Application (M.ApplicationC ms) (M.ApplicationD ms) (M.ApplicationQ ms)
               (T.TxEffs BA.:& BA.BaseApp core) (Q.QueryEffs BA.:& BA.BaseApp core)
      app = M.makeApplication rProxy anteHandler modules

      txParser bs = case parseTx signatureAlgP bs of
        Left err -> throwSDKError $ ParseError err
        Right tx -> pure $ T.RoutingTx tx

      checkServer :: T.TransactionApplication (Sem (BA.BaseApp core))
      checkServer =
        T.serveTxApplication (Proxy @(M.ApplicationC ms)) rProxy (Proxy @'Store.QueryAndMempool) $ M.applicationTxChecker app

      deliverServer :: T.TransactionApplication (Sem (BA.BaseApp core))
      deliverServer =
        T.serveTxApplication (Proxy @(M.ApplicationD ms)) rProxy (Proxy @'Store.Consensus) $ M.applicationTxDeliverer app

      queryServer :: Q.QueryApplication (Sem (BA.BaseApp core))
      queryServer = Q.serveQueryApplication (Proxy @(M.ApplicationQ ms)) rProxy $ M.applicationQuerier app

      query (RequestQuery q) =
        --Store.applyScope $
        catch
          (do
            queryResp <- queryServer q
            pure $ ResponseQuery queryResp
          )
          (\(err :: BA.AppError) ->
            return . ResponseQuery $ def & queryAppError .~ err
          )

      checkTx (RequestCheckTx _checkTx) =  do
        res <- catch
          ( let txBytes =  _checkTx ^. Req._checkTxTx . to Base64.toBytes
            in do
               (res, _) <- txParser txBytes >>= checkServer
               pure res
          )
          (\(err :: BA.AppError) ->
            return $ def & txResultAppError .~ err
          )
        return . ResponseCheckTx $ res ^. from checkTxTxResult

      deliverTx (RequestDeliverTx _deliverTx) = do
        res <- catch @BA.AppError
          ( let txBytes = _deliverTx ^. Req._deliverTxTx . to Base64.toBytes
            in do
               (res, cache) <- txParser txBytes >>= deliverServer
               maybe (pure ()) writeCache cache
               pure res
          )
          (\(err :: BA.AppError) ->
            return $ def & txResultAppError .~ err
          )
        return . ResponseDeliverTx $ res ^. from deliverTxTxResult

      commit :: Handler 'MTCommit (BA.BaseApp core)
      commit _ = do
        _ <- Store.commit
        rootHash <- Store.commitBlock
        return . ResponseCommit $ def
          & Resp._commitData .~ Base64.fromBytes rootHash

  in defaultHandlers
       { query = query
       , checkTx = checkTx
       , deliverTx = deliverTx
       , commit = commit
       }

makeApp
  :: forall alg ms r core.

     RecoverableSignatureSchema alg
  => Message alg ~ Digest SHA256
  => M.ToApplication ms (M.Effs ms (BA.BaseApp core))
  => T.HasTxRouter (M.ApplicationC ms) (M.Effs ms (BA.BaseApp core)) 'Store.QueryAndMempool
  => T.HasTxRouter (M.ApplicationC ms) (BA.BaseApp core) 'Store.QueryAndMempool
  => T.HasTxRouter (M.ApplicationD ms) (M.Effs ms (BA.BaseApp core)) 'Store.Consensus
  => T.HasTxRouter (M.ApplicationD ms) (BA.BaseApp core) 'Store.Consensus
  => Q.HasQueryRouter (M.ApplicationQ ms) (M.Effs ms (BA.BaseApp core))
  => Q.HasQueryRouter (M.ApplicationQ ms) (BA.BaseApp core)
  => M.Eval ms (BA.BaseApp core)
  => M.Effs ms (BA.BaseApp core) ~ r
  => HandlersContext alg ms r core
  -> App (Sem core)
makeApp handlersContext@HandlersContext{compileToCore} =
  let Handlers{..} = makeHandlers handlersContext :: Handlers (BA.BaseApp core)
  in transformApp compileToCore $ App $ \case
       RequestEcho echo ->
         pure . ResponseEcho $ def
           & Resp._echoMessage .~ echo ^. Req._echoMessage
       RequestFlush _ -> pure def
       msg@(RequestInfo _) -> info msg
       msg@(RequestSetOption _) -> setOption msg
       msg@(RequestInitChain _) -> initChain msg
       msg@(RequestQuery _) -> query msg
       msg@(RequestBeginBlock _) -> beginBlock msg
       msg@(RequestCheckTx _) ->  checkTx msg
       msg@(RequestDeliverTx _) -> deliverTx msg
       msg@(RequestEndBlock _) -> endBlock msg
       msg@(RequestCommit _) -> commit msg