import qualified Data.Text as Text
import Greeting (greet)
import System.Exit (exitFailure)

main :: IO ()
main
  | greet (Text.pack "spec") == Text.pack "hello spec" = putStrLn "spec passed"
  | otherwise = exitFailure
