{-# LANGUAGE DeriveDataTypeable, LambdaCase, RankNTypes, ScopedTypeVariables #-}

module SSync.Util.Cereal (
  getVarInt
, putVarInt
, MalformedVarInt(MalformedVarInt)
, sinkGet'
, consumeAndHash
) where

import SSync.Util (awaitNonEmpty, dropRight)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Serialize
import Control.Applicative ((<$>), (<*>))
import Data.Word (Word32)
import Data.Bits (shiftL, shiftR, (.|.), (.&.))
import Data.Typeable (Typeable)
import Control.Exception (Exception)
import Conduit
import Control.Monad (unless)
import Data.Maybe (fromMaybe)
import SSync.Hash (HashT, updateS)

-- | Thrown when 'getVarInt' fails to find a terminal byte within 10
-- bytes.  Note: this is _not_ thrown if the end of input is reached
-- before terminal byte is seen; that's a normal failure.
--
-- I hate throwing exceptions from pure code, but Cereal doesn't really
-- give a better way to report machine-inspectable errors.
data MalformedVarInt = MalformedVarInt
                     deriving (Eq, Show, Typeable)
-- instance Exception MalformedVarInt

type VarIntResult = Either MalformedVarInt Word32

-- $setup
-- The code examples in this module require GHC's `OverloadedStrings`
-- extension:
--
-- >>> :set -XOverloadedStrings

-- | Decode a protobuf-format variable-length unsigned 32-bit integer.  It will accept
-- an encoded 64-bit integer but drop the upper 32 bits.
--
-- >>> runGet getVarInt "\xa9\xb9\x9f\x05"
-- Right 11001001
--
-- >>> runGet getVarInt "\xbd\x84\xb4\x8f\xc5\x29" -- actually 1427303629373
-- 1374487101
--
-- Attempting to consume more than 10 bytes (the maximum a 64-bit integer can
-- produce) causes decoding to fail by throwing a 'MalformedVarInt'.
--
-- >>> return (show $ runGet getVarInt "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x00") `catch` (\MalformedVarInt -> return "oops"
-- "oops"
--
-- It is the inverse of putVarInt.
--
-- prop> runGet getVarInt (runPut $ putVarInt x) == Right x
getVarInt :: Get VarIntResult
getVarInt = next 0 (next 7 (next 14 (next 21 (next 28 (remainder 5))))) 0
-- equivalent to
--    foldr next (remainder 5) [0,7..28] 0
-- but produces nice straight-through core

getIntegralByte :: Get Word32
getIntegralByte = fromIntegral <$> getWord8
{-# INLINE getIntegralByte #-}

next :: Int -> (Word32 -> Get VarIntResult) -> Word32 -> Get VarIntResult
next o n v = do
  b <- getIntegralByte
  if b .&. 0x80 == 0
    then return $ Right $ v .|. (b `shiftL` o)
    else do
      let v' = v .|. ((b .&. 0x7f) `shiftL` o)
      n v'
{-# INLINE next #-}

remainder :: Int -> Word32 -> Get VarIntResult
remainder 0 _ = return $ Left MalformedVarInt
remainder n r = do
  b <- getIntegralByte
  if b .&. 0x80 == 0
    then return $ Right r
    else remainder (n-1) r

-- | Encode a 'Word32' in the protobuf variable-length encoding.
--
-- >>> runPut $ putVarInt 11001001
-- "\169\185\159\ENQ"
--
-- >>> runGet getVarInt $ runPut $ putVarInt 11001001
-- Right 11001001
putVarInt :: Putter Word32
putVarInt i =
  if i < 0x80
  then putWord8 $ fromIntegral i
  else do
    putWord8 $ fromIntegral (i .|. 0x80)
    putVarInt $ i `shiftR` 7

sinkGet' :: (Monad m) => Get r -> Consumer ByteString m (Either String r)
sinkGet' g = go (runGetPartial g)
  where go step =
          awaitNonEmpty >>= \case
            Just chunk ->
              handle step chunk go
            Nothing ->
              handle step BS.empty (const $ return $ Left "Unexpected EOF")
        handle step block recur =
          case step block of
            Done r leftovers -> do
              unless (BS.null leftovers) $ leftover leftovers
              return $ Right r
            Partial cont ->
              recur cont
            Fail msg _ ->
              return $ Left msg

consumeAndHash :: forall m o a e. (MonadThrow m, Exception e) => e -> Get (Either e a) -> HashT (ConduitM ByteString o m) a
consumeAndHash eofError = continue . runGetPartial
  where continue f = do
          bs <- fromMaybe BS.empty <$> lift awaitNonEmpty
          (loop <*> f) bs
        loop :: ByteString -> Result (Either e a) -> HashT (ConduitM ByteString o m) a
        loop _ (Fail _ _) = throwM eofError
        loop bs (Partial f) = do
          updateS bs
          continue f
        loop _ (Done (Left e) _) =
          throwM e
        loop bs (Done (Right r) l) = do
          updateS $ dropRight (BS.length l) bs
          lift $ leftover l
          return r
