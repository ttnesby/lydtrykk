module Main (main) where

import Lyd.Beregning
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "lyd-core" [grenseTests, gylneVerdier, egenskaper, kumulativTests]

grenseTests :: TestTree
grenseTests =
  testGroup
    "grenseverdier NS 8175"
    [ testCase "klasse C" $ do
        grense KlasseC Dag @?= 45
        grense KlasseC Kveld @?= 40
        grense KlasseC Natt @?= 35,
      testCase "klasse B = klasse C - 5" $ do
        grense KlasseB Dag @?= 40
        grense KlasseB Kveld @?= 35
        grense KlasseB Natt @?= 30
    ]

-- | Avrunding til to desimaler, slik de gylne verdiene er oppgitt.
rund2 :: Double -> Double
rund2 x = fromIntegral (round (x * 100) :: Integer) / 100

gylneVerdier :: TestTree
gylneVerdier =
  testGroup "gylne verdier (r0 = 1, 2 desimaler)" $
    [ testCase (show lp0 ++ " dBA -> " ++ show lp ++ " dBA @ " ++ show v ++ "°") $
        rund2 (avstand standardR0 lp0 v lp) @?= forventet
      | (lp0, lp, v, forventet) <-
          [ (54, 35, 0, 8.91),
            (54, 35, 90, 5.01),
            (54, 30, 90, 8.91),
            (53, 35, 0, 7.94),
            (53, 35, 90, 4.47),
            (53, 30, 0, 14.13),
            (48, 35, 0, 4.47),
            (48, 30, 0, 7.94),
            (45, 35, 0, 3.16),
            (50, 30, 0, 10.00)
          ]
    ]

-- | Generator for gyldige (lp0, mål-lp, vinkel) iht. §2.5.
gyldigInput :: Gen (Double, Double, Double)
gyldigInput = do
  lp0 <- choose (40, 70)
  lp <- choose (25, lp0 - 1)
  v <- choose (0, 90)
  pure (lp0, lp, v)

egenskaper :: TestTree
egenskaper =
  testGroup
    "QuickCheck-egenskaper"
    [ testProperty "rundtur: lydnivaa (avstand lp) == lp innen 1e-9" $
        forAll gyldigInput $ \(lp0, lp, v) ->
          let r = avstand standardR0 lp0 v lp
           in counterexample ("r = " ++ show r) $
                abs (lydnivaa standardR0 lp0 v r - lp) < 1e-9,
      testProperty "monotoni: avstand strengt synkende i mål-lp" $
        forAll gyldigInput $ \(lp0, lp, v) ->
          forAll (choose (0.01, 5)) $ \delta ->
            avstand standardR0 lp0 v lp > avstand standardR0 lp0 v (lp + delta),
      testProperty "monotoni: avstand strengt synkende i vinkel for v > 45" $
        forAll gyldigInput $ \(lp0, lp, _) ->
          forAll (choose (45.01, 89)) $ \v1 ->
            forAll (choose (0.01, 90 - v1)) $ \dv ->
              avstand standardR0 lp0 v1 lp > avstand standardR0 lp0 (v1 + dv) lp
    ]

kumulativTests :: TestTree
kumulativTests =
  testGroup
    "kumulativt nivå"
    [ testProperty "kumulativ [l, l] == l + 10*log10 2" $
        forAll (choose (20, 70)) $ \l ->
          abs (kumulativ [l, l] - (l + 10 * logBase 10 2)) < 1e-9,
      testCase "én kilde er identitet" $
        assertBool "kumulativ [53] ~ 53" (abs (kumulativ [53] - 53) < 1e-9)
    ]
