import Control.Concurrent.Async (concurrently)

main :: IO ()
main = do
  (a, b) <- concurrently (pure "hello") (pure "external")
  putStrLn (a ++ " " ++ b)
