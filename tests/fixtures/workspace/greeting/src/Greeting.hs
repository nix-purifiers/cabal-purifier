module Greeting (greet) where

import Data.Text (Text)
import qualified Data.Text as Text

-- | Greets someone by name.
greet :: Text -> Text
greet name = Text.concat [Text.pack "hello ", name]
