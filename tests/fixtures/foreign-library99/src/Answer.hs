{-# LANGUAGE ForeignFunctionInterface #-}
module Answer where
import LocalAnswer (localAnswer)
import Control.Exception (evaluate)
import qualified Data.ByteString as BS
import Foreign.C.Types
import System.Mem (performGC)
import System.Random.SplitMix (mkSMGen, nextWord64)

foreign export ccall "purifier_answer" answer :: CInt -> IO CInt
answer :: CInt -> IO CInt
answer delta = do
  let (seed, _) = nextWord64 (mkSMGen (fromIntegral delta))
      bytes = BS.pack [fromIntegral (seed + fromIntegral n) | n <- [0 .. 41 :: Int]]
  _ <- evaluate (BS.head bytes)
  count <- evaluate (BS.length bytes)
  performGC
  pure (fromIntegral count + delta + localAnswer - 42)
