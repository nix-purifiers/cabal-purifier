import Control.Concurrent.Async (concurrently)

main :: IO ()
main = do
  (a, b) <- concurrently (pure "hello") (pure "update")
  putStrLn (a ++ " " ++ b)
