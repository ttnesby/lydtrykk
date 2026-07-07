module Main (main) where

import qualified Data.Vector.Storable as VS
import Lyd.Beregning
import Lyd.Felt
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "lyd-core"
    [grenseTests, vinkelTests, kildeTests, paakrevdDempingTests, gylneVerdier, lydnivaaKrysssjekk, tabellTests, egenskaper, kumulativTests, simulatorEgenskaper, feltTests, skjermTests, forklaringTests, forenklingTests, fasadeTests]

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

-- | Plassert 53 dBA-kilde — standardkilden i felt-/skjermingstestene.
pk53 :: Punkt -> Double -> PlassertKilde
pk53 pos retning = PlassertKilde pos retning (frittstaaende 53)

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

-- | Lydfeltet over rutenettet ('Lyd.Felt') — regnekjernen bak kart-
-- simulatorens rutenett. Gylne verdier gjenbruker fasiten fra
-- 'lydnivaaKrysssjekk' (53 dBA frittstående, r0 = 1). Hver plasserte kilde
-- bærer sin egen 'Kilde' ('pkKilde'), så blandede nivåer (lokale verdier per
-- pumpe i simulatoren) pinnes her også.
feltTests :: TestTree
feltTests =
  testGroup
    "lydfelt (rutenett, Lyd.Felt)"
    [ testCase "pumpe i origo mot nord: punkt 5 m foran → 39,02" $
        rund2 (dBA (nivaaIPunkt [iOrigoMotNord] (Punkt 0 5)))
          @?= 39.02,
      testCase "pumpe i origo mot nord: punkt 5 m til siden (90°) → 34,02" $
        rund2 (dBA (nivaaIPunkt [iOrigoMotNord] (Punkt 5 0)))
          @?= 34.02,
      testCase "to samlokaliserte pumper = én + 10·log10 2" $
        assertBool "≈ +3,01 dB" $
          abs
            ( dBA (nivaaIPunkt [iOrigoMotNord, iOrigoMotNord] (Punkt 0 5))
                - (dBA (nivaaIPunkt [iOrigoMotNord] (Punkt 0 5)) + 10 * logBase 10 2)
            )
            < 1e-9,
      testCase "ulike nivåer per kilde = kumulativ av enkeltbidragene" $
        let hoy = PlassertKilde (Punkt 0 0) 0 (frittstaaende 60)
            lav = PlassertKilde (Punkt 3 0) 0 (frittstaaende 45)
            pt = Punkt 0 5
         in assertBool "log-sum av 60- og 45-bidraget" $
              abs
                ( dBA (nivaaIPunkt [hoy, lav] pt)
                    - dBA
                      ( kumulativ
                          [nivaaIPunkt [hoy] pt, nivaaIPunkt [lav] pt]
                      )
                )
                < 1e-9,
      testCase "ingen pumper → -Infinity" $
        let n = dBA (nivaaIPunkt [] (Punkt 0 0))
         in assertBool "-Infinity" (isInfinite n && n < 0),
      testCase "avstand under 1 m klampes til 1 m" $
        nivaaIPunkt [iOrigoMotNord] (Punkt 0 0.5)
          @?= nivaaIPunkt [iOrigoMotNord] (Punkt 0 1),
      testCase "retningsavvik: retning 350° mot punkt rett nord → 10°" $
        assertBool "≈ 10°" $
          abs (retningsavvik (PlassertKilde (Punkt 0 0) 350 (frittstaaende 53)) (Punkt 0 5) - 10) < 1e-9,
      testCase "punkt rett bak: avvik 180°, dempes som 90° (vinkelKlampet)" $ do
        assertBool "≈ 180°" $
          abs (retningsavvik iOrigoMotNord (Punkt 0 (-5)) - 180) < 1e-9
        -- toleranse: kumulativ-rundturen (10**/log10) er ikke bit-eksakt
        assertBool "≈ nivå ved 90°" $
          abs
            ( dBA (nivaaIPunkt [iOrigoMotNord] (Punkt 0 (-5)))
                - dBA (lydnivaa (frittstaaende 53) (vinkelKlampet 90) (Meter 5))
            )
            < 1e-9,
      testProperty "rutenettStripe = nivaaIPunkt celle for celle, radmajor" $
        forAll genPlasserte $ \plasserte ->
          forAll genStripe $ \stripe ->
            let Meter celle = stCelleM stripe
                forventet =
                  [ dBA (nivaaIPunkt plasserte (Punkt (fromIntegral kol * celle) (fromIntegral rad * celle)))
                  | rad <- [stRadStart stripe .. stRadSlutt stripe - 1],
                    kol <- [0 .. stKolonner stripe - 1]
                  ]
             in VS.toList (rutenettStripe plasserte stripe) === forventet,
      testProperty "stripe-lengde = rader · kolonner" $
        forAll genPlasserte $ \plasserte ->
          forAll genStripe $ \stripe ->
            VS.length (rutenettStripe plasserte stripe)
              === (stRadSlutt stripe - stRadStart stripe) * stKolonner stripe,
      testProperty "retningsavvik periodisk i retning (+360°)" $
        forAll genPlassert $ \p ->
          forAll genPunkt $ \pt ->
            abs
              ( retningsavvik p pt
                  - retningsavvik p {pkRetning = pkRetning p + 360} pt
              )
              < 1e-9,
      testProperty "kumulativt punktnivå >= sterkeste enkeltpumpe" $
        forAll genPlasserte $ \plasserte ->
          not (null plasserte) ==>
            forAll genPunkt $ \pt ->
              dBA (nivaaIPunkt plasserte pt)
                >= maximum [dBA (nivaaIPunkt [p] pt) | p <- plasserte] - 1e-9
    ]
  where
    iOrigoMotNord = PlassertKilde (Punkt 0 0) 0 (frittstaaende 53)

-- Delte generatorer for lydfeltet ('feltTests'/'skjermTests') -----------------

genPunkt :: Gen Punkt
genPunkt = Punkt <$> choose (-50, 50) <*> choose (-50, 50)

-- | Retninger også utenfor 0–360, som 'retningsavvik' skal tåle. Nivået
-- varierer per kilde ('pkKilde'), så alle egenskapene under dekker også
-- blandede nivåer (lokale verdier per pumpe).
genPlassert :: Gen PlassertKilde
genPlassert =
  PlassertKilde
    <$> genPunkt
    <*> choose (-360, 720)
    <*> (frittstaaende <$> choose (40, 70))

genPlasserte :: Gen [PlassertKilde]
genPlasserte = listOf genPlassert

genStripe :: Gen Stripe
genStripe = do
  radStart <- choose (0, 20)
  rader <- choose (1, 8)
  kolonner <- choose (1, 12)
  celle <- choose (0.5, 5)
  pure (Stripe radStart (radStart + rader) kolonner (Meter celle))

-- | Akse-parallelle rektangler som husrekke-polygoner — samme form som de
-- reelle rekkene, og nok til å pinne bounding-boks-forfilteret.
genRektangel :: Gen Polygon
genRektangel = do
  x0 <- choose (-40, 40)
  y0 <- choose (-40, 40)
  b <- choose (1, 25)
  h <- choose (1, 25)
  pure [Punkt x0 y0, Punkt (x0 + b) y0, Punkt (x0 + b) (y0 + h), Punkt x0 (y0 + h)]

genPolygoner :: Gen [Polygon]
genPolygoner = do
  n <- choose (0, 3 :: Int)
  vectorOf n genRektangel

-- | Del hver kant i 'deler' like biter (nye, eksakt kollineære hjørner) —
-- etterligner de tett digitaliserte reelle husrekkene.
oppdelt :: Int -> Polygon -> Polygon
oppdelt deler poly =
  concat
    [ [ Punkt (pX a + t * (pX b - pX a)) (pY a + t * (pY b - pY a))
      | i <- [0 .. deler - 1],
        let t = fromIntegral i / fromIntegral deler
      ]
    | (a, b) <- zip poly (drop 1 poly ++ take 1 poly)
    ]

-- | Husrekke-skjermingen ('Lyd.Felt'): geometri-primitivene og den skjermede
-- feltberegningen. Modellen: NaN-maskering inne i polygonene, fast
-- 'skjermingDb'-fradrag per kildebidrag med brutt siktlinje, kildens eget
-- hus unntatt.
skjermTests :: TestTree
skjermTests =
  testGroup
    "skjerming (husrekke-polygoner, Lyd.Felt)"
    [ testCase "punktIPolygon: inne i og utenfor kvadratet" $ do
        punktIPolygon kvadrat (Punkt 0 0) @?= True
        punktIPolygon kvadrat (Punkt 3 0) @?= False
        punktIPolygon kvadrat (Punkt 0 (-3)) @?= False,
      testCase "punktIPolygon: konkav L-form, hakket er utenfor" $ do
        punktIPolygon lForm (Punkt 1 1) @?= True
        punktIPolygon lForm (Punkt 1 3) @?= True
        punktIPolygon lForm (Punkt 3 3) @?= False,
      testCase "segmentKrysserPolygon: tvers gjennom / helt utenom" $ do
        segmentKrysserPolygon (Punkt (-5) 0) (Punkt 5 0) kvadrat @?= True
        segmentKrysserPolygon (Punkt (-5) 5) (Punkt 5 5) kvadrat @?= False,
      testCase "streifende segment langs en fasade skjermer ikke (konservativt)" $
        segmentKrysserPolygon (Punkt (-5) 2) (Punkt 5 2) kvadrat @?= False,
      testCase "brutt siktlinje: én kilde senkes nøyaktig skjermingDb" $
        assertBool "≈ −10 dB" $
          abs
            ( nivaaIPunktSkjermet [bakVeggen] [vegg] foranVeggen
                - (dBA (nivaaIPunkt [bakVeggen] foranVeggen) - skjermingDb)
            )
            < 1e-9,
      testCase "fri siktlinje (samme side av veggen): uendret nivå" $
        nivaaIPunktSkjermet [bakVeggen] [vegg] (Punkt 0 3)
          @?= dBA (nivaaIPunkt [bakVeggen] (Punkt 0 3)),
      testCase "eget polygon: kilde inne i veggen skjermes ikke av den" $
        nivaaIPunktSkjermet [pk53 (Punkt 0 0) 180] [vegg] foranVeggen
          @?= dBA (nivaaIPunkt [pk53 (Punkt 0 0) 180] foranVeggen),
      testCase "eget polygon: kilde < 1 m fra fasaden unntas KUN for egen kant, ikke hele bygget" $ do
        let kildeNaerFasaden = pk53 (Punkt 0 1.5) 180 -- 0,5 m nord for veggens nordkant (y=1)
        -- samme side som kilden (nord for veggen): ingen falsk selv-skjerming
        -- fra kanten kilden nesten står inntil
        nivaaIPunktSkjermet [kildeNaerFasaden] [vegg] (Punkt 0 3)
          @?= dBA (nivaaIPunkt [kildeNaerFasaden] (Punkt 0 3))
        -- motsatt side (gjennom hele veggen, sør): skal likevel skjermes —
        -- «eget hus» er bare den nære fasaden, ikke resten av bygningskroppen
        assertBool "skjermet ≈ −10 dB tvers gjennom bygget til motsatt side" $
          abs
            ( nivaaIPunktSkjermet [kildeNaerFasaden] [vegg] foranVeggen
                - (dBA (nivaaIPunkt [kildeNaerFasaden] foranVeggen) - skjermingDb)
            )
            < 1e-9,
      testCase "punkt inne i et polygon maskeres (NaN)" $
        assertBool "NaN" $
          isNaN (nivaaIPunktSkjermet [bakVeggen] [vegg] (Punkt 0 0)),
      testCase "degenerert polygon (< 3 hjørner) ignoreres" $
        nivaaIPunktSkjermet [bakVeggen] [[Punkt 0 0, Punkt 1 0]] foranVeggen
          @?= dBA (nivaaIPunkt [bakVeggen] foranVeggen),
      testProperty "uten polygoner: identisk med rutenettStripe" $
        forAll genPlasserte $ \plasserte ->
          forAll genStripe $ \stripe ->
            rutenettStripeSkjermet plasserte [] stripe
              === rutenettStripe plasserte stripe,
      testProperty "skjermet nivå aldri over uskjermet (utenfor polygonene)" $
        forAll genPlasserte $ \plasserte ->
          forAll genPolygoner $ \polys ->
            forAll genPunkt $ \pt ->
              not (any (`punktIPolygon` pt) polys) ==>
                nivaaIPunktSkjermet plasserte polys pt
                  <= dBA (nivaaIPunkt plasserte pt) + 1e-9,
      testProperty "rutenettStripeSkjermet = nivaaIPunktSkjermet celle for celle" $
        forAll genPlasserte $ \plasserte ->
          forAll genPolygoner $ \polys ->
            forAll genStripe $ \stripe ->
              let Meter celle = stCelleM stripe
                  forventet =
                    [ nivaaIPunktSkjermet plasserte polys (Punkt (fromIntegral kol * celle) (fromIntegral rad * celle))
                    | rad <- [stRadStart stripe .. stRadSlutt stripe - 1],
                      kol <- [0 .. stKolonner stripe - 1]
                    ]
                  fikk = VS.toList (rutenettStripeSkjermet plasserte polys stripe)
                  -- NaN /= NaN, så maskerte celler sammenlignes eksplisitt
                  likNaN a b = (isNaN a && isNaN b) || a == b
               in counterexample (show (fikk, forventet)) $
                    length fikk == length forventet && and (zipWith likNaN fikk forventet)
    ]
  where
    -- kvadrat sentrert i origo, sidekant 4
    kvadrat = [Punkt (-2) (-2), Punkt 2 (-2), Punkt 2 2, Punkt (-2) 2]
    -- L-form: 4×4 med et 2×2-hakk i NØ-hjørnet
    lForm = [Punkt 0 0, Punkt 4 0, Punkt 4 2, Punkt 2 2, Punkt 2 4, Punkt 0 4]
    -- «veggen»: lav, bred rekke tvers over origo; kilden bak, punktet foran
    vegg = [Punkt (-5) (-1), Punkt 5 (-1), Punkt 5 1, Punkt (-5) 1]
    bakVeggen = pk53 (Punkt 0 10) 180
    foranVeggen = Punkt 0 (-10)

-- | Punktforklaringen ('Lyd.Felt.punktBidragForklart') for kart-simulatorens
-- «forklar celle»-visning: samme per-kilde-skjermingsregel som
-- 'nivaaIPunktSkjermet', men uten å kollapse til én sum og uten
-- NaN-maskering av punkter inne i et polygon (JS avgjør selv om det
-- klikkede punktet er maskert, ved å slå opp i det allerede beregnede
-- rutenettet).
forklaringTests :: TestTree
forklaringTests =
  testGroup
    "punktforklaring (Lyd.Felt.punktBidragForklart)"
    [ testCase "blokkert kilde senkes nøyaktig skjermingDb, fri kilde uendret" $ do
        let [b] = punktBidragForklart [bakVeggen] [vegg] foranVeggen
        assertBool "blokkert: uskjermet - etterSkjerming == skjermingDb" $
          abs ((kbNivaaUskjermet b - kbNivaaEtterSkjerming b) - skjermingDb) < 1e-9
        let [f] = punktBidragForklart [bakVeggen] [vegg] (Punkt 0 3)
        assertBool "fri siktlinje: uendret" $
          abs (kbNivaaUskjermet f - kbNivaaEtterSkjerming f) < 1e-9,
      testCase "punkt inne i polygon regnes likevel (ikke maskert, i motsetning til nivaaIPunktSkjermet)" $
        assertBool "ingen NaN" $
          not (any (isNaN . kbNivaaEtterSkjerming) (punktBidragForklart [bakVeggen] [vegg] (Punkt 0 0))),
      testProperty "lengde og rekkefølge følger plasserte kilder" $
        forAll genPlasserte $ \plasserte ->
          forAll genPolygoner $ \polys ->
            forAll genPunkt $ \pt ->
              length (punktBidragForklart plasserte polys pt) === length plasserte,
      testProperty "log-sum av nivaaEtterSkjerming = nivaaIPunktSkjermet (utenfor maskerte celler)" $
        forAll genPlasserte $ \plasserte ->
          forAll genPolygoner $ \polys ->
            forAll genPunkt $ \pt ->
              (not (null plasserte) && not (any (`punktIPolygon` pt) polys)) ==>
                let bidrag = punktBidragForklart plasserte polys pt
                    total = dBA (kumulativ [Desibel (kbNivaaEtterSkjerming b) | b <- bidrag])
                    forventet = nivaaIPunktSkjermet plasserte polys pt
                 in counterexample (show (total, forventet)) $
                      abs (total - forventet) < 1e-6
    ]
  where
    vegg = [Punkt (-5) (-1), Punkt 5 (-1), Punkt 5 1, Punkt (-5) 1]
    bakVeggen = pk53 (Punkt 0 10) 180
    foranVeggen = Punkt 0 (-10)

-- | Polygonforenklingen ('forenkletPolygon') som felt-funksjonene bruker før
-- maskering og sikttest — både spesifikasjonsstien ('nivaaIPunktSkjermet')
-- og den varme stien ('rutenettStripeSkjermet') forenkler likt, så
-- forenklingen må bevare geometrien innenfor toleransen og aldri endre et
-- allerede enkelt polygon.
forenklingTests :: TestTree
forenklingTests =
  testGroup
    "polygonforenkling (Douglas–Peucker, Lyd.Felt)"
    [ testCase "rektangel er uendret" $
        forenkletPolygon forenkleToleranseM kvadrat @?= kvadrat,
      testCase "trekant (ingenting å fjerne) er uendret" $
        forenkletPolygon forenkleToleranseM trekant @?= trekant,
      testCase "kollineære mellompunkter fjernes" $
        forenkletPolygon
          forenkleToleranseM
          [Punkt 0 0, Punkt 5 0, Punkt 10 0, Punkt 10 10, Punkt 0 10]
          @?= [Punkt 0 0, Punkt 10 0, Punkt 10 10, Punkt 0 10],
      testCase "avvik under toleransen fjernes, over beholdes" $ do
        forenkletPolygon 0.2 [Punkt 0 0, Punkt 5 0.1, Punkt 10 0, Punkt 10 10, Punkt 0 10]
          @?= [Punkt 0 0, Punkt 10 0, Punkt 10 10, Punkt 0 10]
        forenkletPolygon 0.2 [Punkt 0 0, Punkt 5 1, Punkt 10 0, Punkt 10 10, Punkt 0 10]
          @?= [Punkt 0 0, Punkt 5 1, Punkt 10 0, Punkt 10 10, Punkt 0 10],
      testProperty "tett oppdelt rektangel forenkles tilbake til hjørnene" $
        forAll genRektangel $ \rekt ->
          forAll (choose (2, 8 :: Int)) $ \deler ->
            forenkletPolygon forenkleToleranseM (oppdelt deler rekt) === rekt,
      -- den semantiske begrunnelsen for forenklingen: tettere digitalisering
      -- av samme geometri skal ikke endre det skjermede feltet
      testProperty "oppdelte kanter endrer ikke det skjermede feltet" $
        forAll genPlasserte $ \plasserte ->
          forAll genRektangel $ \rekt ->
            forAll (choose (2, 8 :: Int)) $ \deler ->
              forAll genPunkt $ \pt ->
                let a = nivaaIPunktSkjermet plasserte [rekt] pt
                    b = nivaaIPunktSkjermet plasserte [oppdelt deler rekt] pt
                 in counterexample (show (a, b)) ((isNaN a && isNaN b) || a == b)
    ]
  where
    kvadrat = [Punkt (-2) (-2), Punkt 2 (-2), Punkt 2 2, Punkt (-2) 2]
    trekant = [Punkt 0 0, Punkt 4 0, Punkt 2 3]

-- | Fasadepunktene ('Lyd.Felt'): prøvepunkter langs husrekke-omkretsen og
-- «verste punkt per rekke» — operasjonaliseringen av verste punkt ved
-- naboens fasade.
fasadeTests :: TestTree
fasadeTests =
  testGroup
    "fasadepunkter (verste punkt per husrekke, Lyd.Felt)"
    [ testCase "alle punkter utenfor polygonet, ca. fasadeOffsetM fra kanten" $ do
        let pts = fasadepunkter kvadrat
        assertBool "har punkter" (not (null pts))
        assertBool "alle utenfor" (not (any (punktIPolygon kvadrat) pts))
        assertBool "alle ~1 m fra kanten" $
          all (\p -> abs (kantAvstand kvadrat p - fasadeOffsetM) < 1e-9) pts,
      testCase "punkttetthet: minst omkrets/fasadePunktAvstandM punkter" $
        -- kvadrat med sidekant 4 → omkrets 16
        assertBool "≥ 16 punkter" (length (fasadepunkter kvadrat) >= 16),
      testCase "degenerert polygon (< 3 hjørner) gir ingen punkter" $ do
        fasadepunkter [Punkt 0 0, Punkt 1 0] @?= []
        versteFasadepunkt [bakVeggen] [] [Punkt 0 0, Punkt 1 0] @?= Nothing,
      testCase "verste punkt vender mot kilden (nordsida av veggen)" $
        case versteFasadepunkt [bakVeggen] [vegg] vegg of
          Nothing -> assertFailure "fant ikke noe fasadepunkt"
          Just (pt, niv) -> do
            assertBool "på nordsida (mot kilden)" (pY pt > 1)
            -- fri siktlinje på kildesida: nivået er det uskjermede
            assertBool "= uskjermet nivå i punktet" $
              abs (niv - dBA (nivaaIPunkt [bakVeggen] pt)) < 1e-9,
      testCase "ingen kilder: verste punkt finnes, nivået er -Infinity" $
        case versteFasadepunkt [] [vegg] vegg of
          Nothing -> assertFailure "fant ikke noe fasadepunkt"
          Just (_, niv) -> assertBool "-Infinity" (isInfinite niv && niv < 0),
      testProperty "skjermet verste punkt aldri over uskjermet" $
        forAll genPlasserte $ \plasserte ->
          forAll genRektangel $ \rekt ->
            let skjermet = versteFasadepunkt plasserte [rekt] rekt
                uskjermet = versteFasadepunkt plasserte [] rekt
             in case (skjermet, uskjermet) of
                  (Just (_, s), Just (_, u)) -> property (s <= u + 1e-9)
                  _ -> counterexample "manglet fasadepunkt" (property False),
      -- pinner den optimaliserte hindre-stien (nivaaMedHindre) mot
      -- spesifikasjons-implementasjonen nivaaIPunktSkjermet
      testProperty "versteFasadepunkt = maksimum av nivaaIPunktSkjermet over fasadepunktene" $
        forAll genPlasserte $ \plasserte ->
          forAll genPolygoner $ \polys ->
            forAll genRektangel $ \rekt ->
              let fasit =
                    [ n
                    | pt <- fasadepunkter rekt,
                      let n = nivaaIPunktSkjermet plasserte polys pt,
                      not (isNaN n)
                    ]
               in case versteFasadepunkt plasserte polys rekt of
                    Nothing -> property (null fasit)
                    Just (pt, n) ->
                      counterexample (show (pt, n)) $
                        not (null fasit)
                          && n == maximum fasit
                          && n == nivaaIPunktSkjermet plasserte polys pt
    ]
  where
    kvadrat = [Punkt (-2) (-2), Punkt 2 (-2), Punkt 2 2, Punkt (-2) 2]
    vegg = [Punkt (-5) (-1), Punkt 5 (-1), Punkt 5 1, Punkt (-5) 1]
    bakVeggen = pk53 (Punkt 0 10) 180
    -- minste avstand fra p til polygonets kanter (testens egen fasit-geometri)
    kantAvstand poly p =
      minimum [segAvstand p a b | (a, b) <- zip poly (drop 1 poly ++ take 1 poly)]
    segAvstand (Punkt px py) (Punkt ax ay) (Punkt bx by) =
      let dx = bx - ax
          dy = by - ay
          l2 = dx * dx + dy * dy
          t = if l2 == 0 then 0 else max 0 (min 1 (((px - ax) * dx + (py - ay) * dy) / l2))
          nx = ax + t * dx
          ny = ay + t * dy
       in sqrt ((px - nx) * (px - nx) + (py - ny) * (py - ny))

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
