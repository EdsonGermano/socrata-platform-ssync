{-# LANGUAGE LambdaCase, ViewPatterns, RankNTypes #-}

module SSync.SignatureComputer (
  produceSignatureTable
, BlockSize
, blockSize
, blockSize'
) where

import Conduit
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Monoid ((<>))
import Data.Serialize.Put (runPut, putWord32be, putByteString)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Word (Word32)

import SSync.Hash
import SSync.Util
import SSync.Util.Cereal
import SSync.Constants
import SSync.BlockSize
import qualified SSync.RollingChecksum as RC

produceAndHash :: (Monad m) => HashState -> ConduitM ByteString ByteString m HashState
produceAndHash s0 = execStateC s0 $ awaitForever $ \bs -> do
  updateS bs
  yield bs

produceShortString :: (Monad m) => String -> Producer m ByteString
produceShortString s =
  let bs = encodeUtf8 . T.pack $ s
  in yield $ (BS.singleton . fromIntegral . BS.length $ bs) <> bs

produceVarInt :: (Monad m) => Word32 -> Producer m ByteString
produceVarInt = yield . runPut . putVarInt

-- each signature-block represents as close to 1MB of source data as possible
signatureBlockSizeForBlockSize :: Word32 -> Word32
signatureBlockSizeForBlockSize blockSz = min (1 + ((1024*1024) `div` blockSz)) maxSignatureBlockSize

-- receives blocks of data, produces blocks of signatures
sigs :: (Monad m) => Word32 -> Word32 -> HashAlgorithm -> Conduit ByteString m ByteString
sigs blockSz sigsPerBlock hashAlg = go 0 $ return ()
  where go sigsSoFar sigData =
          if sigsSoFar == sigsPerBlock
          then do
            yield . runPut $ putVarInt sigsSoFar >> sigData
            go 0 $ return ()
          else
            await >>= \case
              Just block -> do
                let weak = RC.value . RC.forBlock rcZero $ block
                    strong = digest . update strongZero $ block
                go (sigsSoFar + 1) (sigData >> putWord32be weak >> putByteString strong)
              Nothing ->
                yield . runPut $ putVarInt sigsSoFar >> sigData
        rcZero = RC.init blockSz
        strongZero = initState hashAlg

produceSignatureTableUnframed :: (Monad m) => HashAlgorithm -> BlockSize -> Conduit ByteString m ByteString
produceSignatureTableUnframed strongHashAlg (blockSizeWord -> blockSz) = do
  let sigBlockSize = signatureBlockSizeForBlockSize blockSz
  produceVarInt blockSz
  produceShortString (show strongHashAlg)
  produceVarInt sigBlockSize
  rechunk (fromIntegral blockSz) $= sigs blockSz sigBlockSize strongHashAlg

produceSignatureTable :: (Monad m) => HashAlgorithm -> HashAlgorithm -> BlockSize -> Conduit ByteString m ByteString
produceSignatureTable checksumAlg strongHashAlg blockSz = do
  produceShortString $ show checksumAlg
  d <- withHashT checksumAlg $ do
    withHashState' $ \hs -> produceSignatureTableUnframed strongHashAlg blockSz $= produceAndHash hs
    digestS
  yield d
