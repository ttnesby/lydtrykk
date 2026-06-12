module Main (main) where

import Lyd.Beregning
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "lyd-core"
    [grenseTests, vinkelTests, kildeTests, gylneVerdier, egenskaper, kumulativTests]

grenseTests :: TestTree
grenseTests =
  testGroup
    "grenseverdier NS 8175"
    [ testCase "klasse C" $ do
        grense KlasseC Dag @?= Desibel 45
        grense KlasseC Kveld @?= Desibel 40
        grense KlasseC Natt @?= Desibel 35,
      testCase "klasse B = klasse C - 5" $ do
        grense KlasseB Dag @?= Desibel 40
        grense KlasseB Kveld @?= Desibel 35
        grense KlasseB Natt @?= Desibel 30
    ]

vinkelTests :: TestTree
vinkelTests =
  testGroup
    "vinkel-invariant"
    [ testCase "0–90° er gyldig" $ do
        fmap grader (nyVinkel 0) @?= Just 0
        fmap grader (nyVinkel 90) @?= Just 90,
      testCase "utenfor modellen avvises" $ do
        nyVinkel (-1) @?= Nothing
        nyVinkel 90.1 @?= Nothing
    ]

kildeTests :: TestTree
kildeTests =
  testGroup
    "effektivt kildenivå"
    [ testCase "frittstående = oppgitt" $
        effektivtKildenivaa (frittstaaende 53) @?= Desibel 53,
      testCase "veggmontert = oppgitt + 3" $
        effektivtKildenivaa (frittstaaende 53) {montering = Veggmontert}
          @?= Desibel 56
    ]

-- | Frittstående kilde med standard referanseavstand (1 m).
frittstaaende :: Double -> Kilde
frittstaaende lp0 =
  Kilde
    { oppgittNivaa = Desibel lp0,
      referanseavstand = standardR0,
      montering = Frittstaaende
    }

-- | Avrunding til to desimaler, slik de gylne verdiene er oppgitt.
rund2 :: Double -> Double
rund2 x = fromIntegral (round (x * 100) :: Integer) / 100

gylneVerdier :: TestTree
gylneVerdier =
  testGroup "gylne verdier (r0 = 1, 2 desimaler)" $
    [ testCase (show lp0 ++ " dBA -> " ++ show lp ++ " dBA @ " ++ show v ++ "°") $
        case nyVinkel v of
          Nothing -> assertFailure "ugyldig vinkel i testtabellen"
          Just vk ->
            rund2 (meter (avstand (frittstaaende lp0) vk (Desibel lp)))
              @?= forventet
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

-- | Generator for gyldige (kilde, mål-nivå, vinkel) iht. §2.5.
gyldigInput :: Gen (Kilde, Desibel, Vinkel)
gyldigInput = do
  lp0 <- choose (40, 70)
  lp <- choose (25, lp0 - 1)
  v <- choose (0, 90) `suchThatMap` nyVinkel
  pure (frittstaaende lp0, Desibel lp, v)

egenskaper :: TestTree
egenskaper =
  testGroup
    "QuickCheck-egenskaper"
    [ testProperty "rundtur: lydnivaa (avstand lp) == lp innen 1e-9" $
        forAll gyldigInput $ \(kilde, lp, v) ->
          let r = avstand kilde v lp
           in counterexample ("r = " ++ show r) $
                abs (dBA (lydnivaa kilde v r) - dBA lp) < 1e-9,
      testProperty "monotoni: avstand strengt synkende i mål-nivå" $
        forAll gyldigInput $ \(kilde, Desibel lp, v) ->
          forAll (choose (0.01, 5)) $ \delta ->
            avstand kilde v (Desibel lp) > avstand kilde v (Desibel (lp + delta)),
      testProperty "monotoni: avstand strengt synkende i vinkel for v > 45" $
        forAll gyldigInput $ \(kilde, lp, _) ->
          forAll (choose (45.01, 89) `suchThatMap` nyVinkel) $ \v1 ->
            forAll (choose (grader v1 + 0.01, 90) `suchThatMap` nyVinkel) $ \v2 ->
              avstand kilde v1 lp > avstand kilde v2 lp
    ]

kumulativTests :: TestTree
kumulativTests =
  testGroup
    "kumulativt nivå"
    [ testProperty "kumulativ [l, l] == l + 10*log10 2" $
        forAll (choose (20, 70)) $ \l ->
          abs (dBA (kumulativ [Desibel l, Desibel l]) - (l + 10 * logBase 10 2))
            < 1e-9,
      testCase "én kilde er identitet" $
        assertBool
          "kumulativ [53] ~ 53"
          (abs (dBA (kumulativ [Desibel 53]) - 53) < 1e-9)
    ]
