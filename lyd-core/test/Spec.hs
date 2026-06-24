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
    [grenseTests, vinkelTests, kildeTests, paakrevdDempingTests, gylneVerdier, lydnivaaKrysssjekk, tabellTests, egenskaper, kumulativTests, simulatorEgenskaper]

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
        grense KlasseB Natt @?= Desibel 30,
      testCase "klasse B+ = klasse C - 7" $ do
        grense KlasseBpluss Dag @?= Desibel 38
        grense KlasseBpluss Kveld @?= Desibel 33
        grense KlasseBpluss Natt @?= Desibel 28,
      testCase "klasse A = klasse C - 10" $ do
        grense KlasseA Dag @?= Desibel 35
        grense KlasseA Kveld @?= Desibel 30
        grense KlasseA Natt @?= Desibel 25,
      testCase "klasseOffset C/B/B+/A = 0/5/7/10" $ do
        klasseOffset KlasseC @?= 0
        klasseOffset KlasseB @?= 5
        klasseOffset KlasseBpluss @?= 7
        klasseOffset KlasseA @?= 10,
      testCase "klasserekkefølge: strengest først" $
        [minBound .. maxBound] @?= [KlasseA, KlasseBpluss, KlasseB, KlasseC]
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
          @?= Desibel 56,
      testCase "kabinett trekker fra demping" $
        effektivtKildenivaa (frittstaaende 52) {kabinettDemping = 14}
          @?= Desibel 38,
      testCase "vegg + kabinett: oppgitt + 3 - kabinett" $
        effektivtKildenivaa
          (frittstaaende 52) {montering = Veggmontert, kabinettDemping = 14}
          @?= Desibel 41
    ]

-- | Påkrevd kabinett-demping (omvendt beregning) mot mockup-tallet i issue #5:
-- 52 dBA frittstående, vinkel 90° (−5 dB), 3 m, nattgrense B+ = 28 → ≈ 9,5 dB.
-- Beregnes mot kilden uten dagens kabinett, så svaret er uavhengig av et
-- allerede satt kabinett.
paakrevdDempingTests :: TestTree
paakrevdDempingTests =
  testGroup
    "påkrevd kabinett-demping"
    [ testCase "52 dBA, 90°, 3 m, grense 28 → ≈ 9,5 dB" $
        case nyVinkel 90 of
          Nothing -> assertFailure "ugyldig vinkel"
          Just v ->
            assertBool
              "≈ 9,46 dB"
              ( abs
                  ( paakrevdDemping (frittstaaende 52) v (Meter 3) (Desibel 28)
                      - 9.4576
                  )
                  < 1e-3
              ),
      testCase "uavhengig av allerede satt kabinett" $
        case nyVinkel 90 of
          Nothing -> assertFailure "ugyldig vinkel"
          Just v ->
            paakrevdDemping (frittstaaende 52) {kabinettDemping = 14} v (Meter 3) (Desibel 28)
              @?= paakrevdDemping (frittstaaende 52) v (Meter 3) (Desibel 28),
      testCase "0 når grensen alt er oppfylt" $
        case nyVinkel 0 of
          Nothing -> assertFailure "ugyldig vinkel"
          Just v ->
            paakrevdDemping (frittstaaende 40) v (Meter 10) (Desibel 50) @?= 0
    ]

-- | Frittstående kilde med standard referanseavstand (1 m), uten kabinett.
frittstaaende :: Double -> Kilde
frittstaaende lp0 =
  Kilde
    { oppgittNivaa = Desibel lp0,
      referanseavstand = standardR0,
      montering = Frittstaaende,
      kabinettDemping = 0
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
            (54, 35, 45, 7.53),
            (54, 35, 60, 6.68),
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

-- | Lydnivå-kryss-sjekk mot notatbokens cosinus-fasit: L(lp0, r, v),
-- frittstående, r0 = 1, 2 desimaler.
lydnivaaKrysssjekk :: TestTree
lydnivaaKrysssjekk =
  testGroup "lydnivå kryss-sjekk (cosinus, 2 desimaler)" $
    [ testCase (show lp0 ++ " dBA @ " ++ show r ++ " m, " ++ show v ++ "°") $
        case nyVinkel v of
          Nothing -> assertFailure "ugyldig vinkel i testtabellen"
          Just vk ->
            rund2 (dBA (lydnivaa (frittstaaende lp0) vk (Meter r))) @?= forventet
      | (lp0, r, v, forventet) <-
          [ (53, 5, 0, 39.02),
            (53, 5, 90, 34.02),
            (53, 10, 45, 31.54)
          ]
    ]

-- | Slå opp avstanden for en gitt vinkel (grader) i en 'AvstandsRad',
-- avrundet til to desimaler.
celle :: AvstandsRad -> Double -> Maybe Double
celle rad g =
  rund2 . meter . snd
    <$> lookupBy (\(v, _) -> grader v == g) (arCeller rad)
  where
    lookupBy p = foldr (\x acc -> if p x then Just x else acc) Nothing

-- | Avstandstabellen reproduserer notatbokens grid for lp0 = 44, r0 = 1
-- (frittstående), jf. @avstandVedLydnivaaOgVinkelKlassCOgBGrid[44, 1, …]@.
tabellTests :: TestTree
tabellTests =
  testGroup
    "avstandstabell (lp0 = 44, r0 = 1, 2 desimaler)"
    [ testCase "noenVinkler = 0,50,60,70,80,90" $
        map grader noenVinkler @?= [0, 50, 60, 70, 80, 90],
      testCase "tre rader per klasse (Dag/Kveld/Natt)" $
        map arTidsrom (avstandsTabell (frittstaaende 44) noenVinkler KlasseC)
          @?= [Dag, Kveld, Natt],
      testGroup "gylne celler fra bildet" $
        [ testCase (show klasse ++ " " ++ show t ++ " @ " ++ show v ++ "°") $
            celle (rad klasse t) v @?= Just forventet
          | (klasse, t, v, forventet) <-
              [ -- Klasse C: Dag 45, Kveld 40, Natt 35
                (KlasseC, Dag, 0, 0.89),
                (KlasseC, Dag, 60, 0.67),
                (KlasseC, Dag, 90, 0.50),
                (KlasseC, Kveld, 0, 1.58),
                -- Klasse C Natt: hele raden (mellomvinkler pinner cosinus-formen)
                (KlasseC, Natt, 0, 2.82),
                (KlasseC, Natt, 50, 2.29),
                (KlasseC, Natt, 60, 2.11),
                (KlasseC, Natt, 70, 1.93),
                (KlasseC, Natt, 80, 1.75),
                (KlasseC, Natt, 90, 1.58),
                -- Klasse B: Dag 40, Kveld 35, Natt 30
                (KlasseB, Dag, 0, 1.58),
                (KlasseB, Kveld, 0, 2.82),
                (KlasseB, Kveld, 90, 1.58),
                -- Klasse B Natt: hele raden
                (KlasseB, Natt, 0, 5.01),
                (KlasseB, Natt, 50, 4.08),
                (KlasseB, Natt, 60, 3.76),
                (KlasseB, Natt, 70, 3.43),
                (KlasseB, Natt, 80, 3.11),
                (KlasseB, Natt, 90, 2.82)
              ]
        ]
    ]
  where
    tabell klasse = avstandsTabell (frittstaaende 44) noenVinkler klasse
    rad klasse t = head [r | r <- tabell klasse, arTidsrom r == t]

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
      testProperty "monotoni: avstand strengt synkende i vinkel (0–90°)" $
        forAll gyldigInput $ \(kilde, lp, _) ->
          forAll (choose (1, 88) `suchThatMap` nyVinkel) $ \v1 ->
            forAll (choose (grader v1 + 1, 90) `suchThatMap` nyVinkel) $ \v2 ->
              avstand kilde v1 lp > avstand kilde v2 lp
    ]

-- | Egenskaper kart-simulatoren hviler på. Den deler nøyaktig disse
-- funksjonene via WASM, så her sikrer vi modellens grunnantakelser.
simulatorEgenskaper :: TestTree
simulatorEgenskaper =
  testGroup
    "simulator-kjerne (delt med kartet)"
    [ testProperty "lydnivaa strengt synkende i avstand" $
        forAll gyldigInput $ \(kilde, _, v) ->
          forAll (choose (1, 50)) $ \r1 ->
            forAll (choose (0.01, 50)) $ \dr ->
              dBA (lydnivaa kilde v (Meter r1))
                > dBA (lydnivaa kilde v (Meter (r1 + dr))),
      testProperty "kumulativ >= sterkeste enkeltkilde" $
        forAll (listOf1 (choose (20, 70))) $ \ls ->
          dBA (kumulativ (map Desibel ls)) >= maximum ls - 1e-9,
      testCase "retningskorreksjon: 0 dB front, 5 dB ved 90°" $ do
        vinkelkorreksjon rettFrem @?= 0
        assertBool
          "≈ 5 dB ved 90°"
          (abs (vinkelkorreksjon (vinkelKlampet 90) - 5) < 1e-9),
      testCase "vinkelKlampet: |vinkel| klampet til [0, 90], symmetrisk" $ do
        grader (vinkelKlampet (-30)) @?= 30
        grader (vinkelKlampet 30) @?= 30
        grader (vinkelKlampet (-200)) @?= 90
        grader (vinkelKlampet 200) @?= 90
        grader (vinkelKlampet 45) @?= 45,
      testProperty "retningskorreksjon symmetrisk om fronten" $
        forAll (choose (0, 90)) $ \a ->
          vinkelkorreksjon (vinkelKlampet a) == vinkelkorreksjon (vinkelKlampet (negate a))
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
