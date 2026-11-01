import Data.Default.Class (def)
import Data.Proxy (Proxy (..))
import Data.Tagged (Tagged (..), untag)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Greeting (greet)
import Shared (place)

newtype Marker = Marker ()

main :: IO ()
main = do
  let tagged = Tagged (Text.pack place) :: Tagged Marker Text.Text
      unit = def :: ()
  Text.putStrLn (greet (untag tagged))
  print (unit, Proxy :: Proxy Marker)
