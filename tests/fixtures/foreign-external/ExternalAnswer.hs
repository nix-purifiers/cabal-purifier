{-# LANGUAGE ForeignFunctionInterface #-}
module ExternalAnswer where
import Foreign.C.Types
{-# NOINLINE externalAnswer #-}
externalAnswer :: CInt
externalAnswer = 42
foreign export ccall "purifier_external_marker" externalMarker :: IO CInt
externalMarker :: IO CInt
externalMarker = pure externalAnswer
