import qualified Data.Text as Text
import Greeting (greet)

main :: IO ()
main = print (sum [Text.length (greet (Text.pack (show n))) | n <- [1 .. 1000 :: Int]])
