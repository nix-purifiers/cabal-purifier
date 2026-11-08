{-# LANGUAGE ForeignFunctionInterface #-}
module LocalAnswer where
import Foreign.C.Types
import ExternalAnswer (externalAnswer)
{-# NOINLINE localAnswer #-}
localAnswer :: CInt
localAnswer = externalAnswer
foreign export ccall "purifier_local_marker" localMarker :: IO CInt
localMarker :: IO CInt
localMarker = pure localAnswer
