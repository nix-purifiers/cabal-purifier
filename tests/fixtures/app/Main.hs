import Control.Concurrent.Async (concurrently)
import System.Random (mkStdGen, randomR)

main :: IO ()
main = do
  (a, b) <- concurrently (pure (fst (randomR (1 :: Int, 6) (mkStdGen 42)))) (pure "purified")
  putStrLn ("hello " ++ b ++ " " ++ show a)
