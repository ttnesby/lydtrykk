-- | Mikro-benchmark for den varme stien i "Lyd.Felt" — rutenett-beregningen
-- bak kart-simulatoren. Kjøres med @cabal bench@ (ikke en del av CI, og
-- bevisst uten benchmark-avhengigheter: bare base + lyd-core). Oppsettet
-- speiler et realistisk kartscenario: 8 pumper, 6 tett digitaliserte
-- husrekker (80 hjørner hver), 200×200 celler à 1 m.
module Main (main) where

import qualified Data.Vector.Storable as VS
import Lyd.Beregning
import Lyd.Felt
import System.CPUTime (getCPUTime)
import Text.Printf (printf)

kilde :: Kilde
kilde =
  Kilde
    { oppgittNivaa = Desibel 55,
      referanseavstand = standardR0,
      montering = Frittstaaende,
      kabinettDemping = 0
    }

pumper :: [PlassertKilde]
pumper =
  [ PlassertKilde
      (Punkt (20 + fromIntegral i * 35) (30 + fromIntegral (i `mod` 3) * 60))
      (fromIntegral ((i * 47) `mod` 360))
  | i <- [0 .. 7 :: Int]
  ]

-- | Rektangel sentrert i (cx, cy) med 'per' hjørner per side — etterligner
-- de reelt digitaliserte husrekkene (~60–300 hjørner per rekke).
tettRektangel :: Double -> Double -> Double -> Double -> Int -> Polygon
tettRektangel cx cy b h per =
  side (x0, y0) (b, 0) ++ side (x0 + b, y0) (0, h)
    ++ side (x0 + b, y0 + h) (-b, 0)
    ++ side (x0, y0 + h) (0, -h)
  where
    x0 = cx - b / 2
    y0 = cy - h / 2
    side (sx, sy) (dx, dy) =
      [ Punkt (sx + t * dx) (sy + t * dy)
      | i <- [0 .. per - 1],
        let t = fromIntegral i / fromIntegral per
      ]

husrekker :: [Polygon]
husrekker =
  [ tettRektangel (50 + fromIntegral p * 40) (60 + fromIntegral (p `mod` 2) * 80) 30 8 20
  | p <- [0 .. 5 :: Int]
  ]

-- | Rutenettet: 200×200 celler à 1 m, med radStart forskjøvet per pass så
-- identiske kall ikke deles (CSE) mellom målingene.
stripe :: Int -> Stripe
stripe pass = Stripe pass (pass + 200) 200 (Meter 1)

celler :: Int
celler = 200 * 200

-- | Kjør beregningen for ett pass og tving frem hele resultatet. NaN-celler
-- (maskert inne i husrekkene) summeres som NaN — summen brukes bare til å
-- hindre at beregningen optimaliseres bort.
pass :: [Polygon] -> Int -> Double
pass polys n = VS.sum (rutenettStripeSkjermet kilde pumper polys (stripe n))

mål :: String -> [Polygon] -> IO ()
mål navn polys = do
  -- ett varmpass utenfor målingen
  pass polys 0 `seq` pure ()
  t0 <- getCPUTime
  let resultater = [pass polys n | n <- [1 .. antall]]
  sum resultater `seq` pure ()
  t1 <- getCPUTime
  let ms = fromIntegral (t1 - t0) / 1e9 / fromIntegral antall :: Double
  printf
    "%-28s %8.1f ms/pass  %8.2f µs/celle\n"
    navn
    ms
    (ms * 1000 / fromIntegral celler)
  where
    antall = 3 :: Int

main :: IO ()
main = do
  printf "%d celler, %d pumper, %d polygoner à %d hjørner\n"
    celler (length pumper) (length husrekker) (length (head husrekker))
  mål "uskjermet (uten polygoner)" []
  mål "skjermet (med husrekker)" husrekker
