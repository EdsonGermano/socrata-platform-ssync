{-# LANGUAGE RankNTypes, GADTs, BangPatterns, ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables, LambdaCase, NamedFieldPuns, OverloadedStrings #-}

module SSync.PatchComputer (patchComputer, patchComputer', Chunk(..)) where

import Conduit
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.DList as DL
import Data.Monoid (mconcat, mempty, (<>))
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Word (Word32)

import SSync.Chunk
import qualified SSync.DataQueue as DQ
import SSync.Hash
import qualified SSync.RollingChecksum as RC
import SSync.SignatureTable.Internal
import SSync.Util

data SizedBuilder = SizedBuilder (DL.DList ByteString) {-# UNPACK #-} !Int
sbEmpty :: SizedBuilder
sbEmpty = SizedBuilder DL.empty 0

sizedByteString :: ByteString -> SizedBuilder
sizedByteString bs = SizedBuilder (DL.singleton bs) (BS.length bs)

atLeastBlockSizeOrEnd :: (Monad m) => Int -> ByteString -> ConduitM ByteString a m ByteString
atLeastBlockSizeOrEnd target pfx = go (DL.singleton pfx) (BS.length pfx)
  where go sb !len =
          if target <= len
            then return $ mconcat $ DL.toList sb
            else await >>= \case
              Nothing -> return $ mconcat $ DL.toList sb
              Just bs -> go (DL.snoc sb bs) (len + BS.length bs)

-- | A signature file is a short-string header naming the checksum
-- algorithm, followed by the block size as a varint, followed by all
-- the chunks, followed by 255 (or equivalently an "END" chunk),
-- followed by the checksum of the chunk data.
--
-- A BLOCK chunk is a 0 byte followed by the number of the referenced
-- block encoded as a varint.
--
-- A DATA chunk is a 1 byte followed by the length of the data as a
-- varint, followed by the bytes of the data.
--
-- An END chunk is a 255 byte and must occur exactly once, at the end
-- of the chunk stream.
fromChunks :: (Monad m) => HashAlgorithm -> Word32 -> Conduit Chunk m ByteString
fromChunks checksumAlg blockSize = do
  let checksumAlgName = encodeUtf8 . name $ checksumAlg
  yield $ BS.singleton (fromIntegral $ BS.length checksumAlgName) <> checksumAlgName
  checksum <- withHashT checksumAlg $ do
    let loop i acc | i > 1000 = do
                       flush acc
                       loop 0 mempty
                   | otherwise =
                       lift await >>= \case
                         Just (Block n) ->
                           loop (i+1) $ acc <> BS.word8 0 <> encodeVarInt n
                         Just (Data d) -> do
                           flush $ acc <> BS.word8 1 <> encodeVarInt (fromIntegral $ BSL.length d) <> BS.lazyByteString d
                           loop 0 mempty
                         Nothing -> do
                           flush $ acc <> BS.word8 255
                           digestS
        flush builder = do
          let chunks = BSL.toChunks $ BS.toLazyByteString builder
          mapM_ updateS chunks
          lift $ mapM_ yield chunks
    loop (0 :: Int) (encodeVarInt blockSize)
  yield checksum

-- | Given a 'SignatureTable', convert a stream of 'ByteString's into
-- a signature file.
patchComputer :: (Monad m) => SignatureTable -> Conduit ByteString m ByteString
patchComputer st = patchComputer' st $= fromChunks (stChecksumAlg st) (stBlockSize st)

-- | Given a 'SignatureTable', convert a stream of 'ByteString's into
-- a stream of patch 'Chunk's.  Use 'patchComputer' to produce an
-- actual signature file instead.
patchComputer' :: (Monad m) => SignatureTable -> Conduit ByteString m Chunk
patchComputer' st = go
  where go = do
          initBS <- atLeastBlockSizeOrEnd blockSizeI ""
          sb <- fromChunk initBS sbEmpty
          yieldData sb
        fromChunk initBS sb =
          if (BS.null initBS)
          then return sb
          else
            let initQ = DQ.create initBS 0 (min blockSizeI (BS.length initBS) - 1)
                rc0 = RC.forBlock (RC.init blockSize) initBS
            in loop rc0 initQ sb
        blockSize = stBlockSize st
        blockSizeI = stBlockSizeI st
        hashComputer :: HashT Identity ByteString -> ByteString
        hashComputer = runIdentity . strongHashComputer st
        loop rc q sb =
          -- DQ.validate "loop 1" q
          -- Is there a block at the current position in the queue?
          case findBlock st rc (hashComputer $ DQ.hashBlock q) of
            Just b ->
              -- Yes; add the data we've skipped, send the block ID
              -- itself, and then start over.
              blockFound q b sb
            Nothing ->
              -- no; move forward 1 byte (which might entail dropping a block from the front
              -- of the queue; if that happens, it's data).
              attemptSlide rc q sb
        blockFound q b sb = do
          sb' <- addData blockSizeI (DQ.beforeBlock q) sb
          yieldBlock b sb'
          nextBS <- atLeastBlockSizeOrEnd blockSizeI $ DQ.afterBlock q
          fromChunk nextBS sbEmpty
        attemptSlide rc q sb =
          case DQ.slide q of
            Just (dropped, !q') ->
              -- DQ.validate "loop 2" q'
              let !rc' = RC.roll rc (DQ.firstByteOfBlock q) (DQ.lastByteOfBlock q')
              in case dropped of
                Just bs ->
                  addData blockSizeI bs sb >>= loop rc' q'
                Nothing ->
                  loop rc' q' sb
            Nothing ->
              -- can't even do that; we need more from upstream
              fetchMore rc q sb
        fetchMore rc q sb =
          awaitNonEmpty >>= \case
            Just nextBlock ->
              -- ok good.  By adding that block we might drop one from the queue;
              -- if so, send it as data.
              let (dropped, !q') = DQ.addBlock q nextBlock
                  !rc' = RC.roll rc (DQ.firstByteOfBlock q) (DQ.lastByteOfBlock q')
              in case dropped of
                Just bs ->
                  addData blockSizeI bs sb >>= loop rc' q'
                Nothing ->
                  loop rc' q' sb
            Nothing ->
              -- Nothing!  Ok, we're in the home stretch now.
              finish rc q sb
        finish rc q sb = do
          -- sliding just failed, so let's slide off.  Again, this can
          -- cause a block to be dropped.
          case DQ.slideOff q of
            (dropped, Just !q') -> do
              -- DQ.validate "finish" q'
              sb' <- case dropped of
                Just bs ->
                  addData blockSizeI bs sb
                Nothing ->
                  return sb
              let !rc' = RC.roll rc (DQ.firstByteOfBlock q) 0
              case findBlock st rc' (hashComputer $ DQ.hashBlock q') of
                Just b -> do
                  sb'' <- addData blockSizeI (DQ.beforeBlock q') sb'
                  yieldBlock b sb''
                  return sbEmpty
                Nothing ->
                  finish rc' q' sb'
            -- Done!
            (Just dropped, Nothing) ->
              addData blockSizeI dropped sb
            (Nothing, Nothing) ->
              return sb

yieldBlock :: (Monad m) => Word32 -> SizedBuilder -> Producer m Chunk
yieldBlock i sb = do
  yieldData sb
  yield $ Block i

yieldData :: (Monad m) => SizedBuilder -> Producer m Chunk
yieldData (SizedBuilder pendingL pendingS) =
  unless (pendingS == 0) $ do
    let bytes = BSL.fromChunks $ DL.toList pendingL
    yield $ Data bytes

addData :: (Monad m) => Int -> ByteString -> SizedBuilder -> ConduitM a Chunk m SizedBuilder
addData blockSize bs sb@(SizedBuilder pendingL pendingS) =
  if BS.null bs
  then return sb
  else
    let newSize = pendingS + BS.length bs
        newList = DL.snoc pendingL bs
    in if newSize < blockSize
      then return $ SizedBuilder newList newSize
      else let bs64 = fromIntegral blockSize
               loop converted = do
                 yield $ Data $ BSL.take bs64 converted
                 let remaining = BSL.drop bs64 converted
                 if BSL.length remaining < bs64
                   then return $ sizedByteString $ BSL.toStrict remaining
                   else loop remaining
           in loop $ BSL.fromChunks $ DL.toList newList
