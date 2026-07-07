{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Lyd.Beregning
#ifdef WASM
import qualified Data.Vector.Storable as VS
import Foreign.ForeignPtr (mallocForeignPtrArray, withForeignPtr)
import Foreign.Ptr (Ptr)
import Lyd.Felt
#endif
import Miso
import qualified Miso.Html as H
import qualified Miso.Html.Event as E
import qualified Miso.Html.Property as P
import Data.Maybe (fromMaybe)
import Miso.Lens
import Numeric (showFFloat)
import Text.Read (readMaybe)

data Model = Model
  { _nivaaTekst :: MisoString,
    _monteringValg :: Montering,
    _kabinettTekst :: MisoString,
    _vinkelValg :: Vinkel,
    _valgtKlasse :: Lydklasse,
    _valgtTidsrom :: Tidsrom,
    _avstandTekst :: MisoString
  }
  deriving (Eq)

nivaaTekst :: Lens Model MisoString
nivaaTekst = lens _nivaaTekst $ \r f -> r {_nivaaTekst = f}

monteringValg :: Lens Model Montering
monteringValg = lens _monteringValg $ \r f -> r {_monteringValg = f}

kabinettTekst :: Lens Model MisoString
kabinettTekst = lens _kabinettTekst $ \r f -> r {_kabinettTekst = f}

vinkelValg :: Lens Model Vinkel
vinkelValg = lens _vinkelValg $ \r f -> r {_vinkelValg = f}

valgtKlasse :: Lens Model Lydklasse
valgtKlasse = lens _valgtKlasse $ \r f -> r {_valgtKlasse = f}

valgtTidsrom :: Lens Model Tidsrom
valgtTidsrom = lens _valgtTidsrom $ \r f -> r {_valgtTidsrom = f}

avstandTekst :: Lens Model MisoString
avstandTekst = lens _avstandTekst $ \r f -> r {_avstandTekst = f}

data Action
  = SettNivaa MisoString
  | SettVeggmontert Checked
  | SettKabinett MisoString
  | SettVinkel MisoString
  | SettKlasse Lydklasse
  | VelgCelle Lydklasse Tidsrom
  | SettAvstand MisoString
  deriving (Eq)

main :: IO ()
main = startApp defaultEvents app

#ifdef WASM
foreign export javascript "hs_start" main :: IO ()

-- Delt akustikk-kjerne eksponert til JS (kart-simulatoren i lydnivakart.html).
-- Bruker nøyaktig samme 'Lyd.Beregning' som NS 8175-siden, så de to sidene
-- kan ikke vise ulike tall. 'src' er effektivt kildenivå ved 1 m (JS legger
-- selv på +3 dB for veggmontering), 'vinkel' er grader fra viftens front.
-- " sync" gjør eksportene synkrone (returnerer tallet direkte, ikke en
-- Promise) — nødvendig fordi simulatoren kaller dem inne i tegneløkkene.
-- Trygt her: funksjonene er rene og gjør ingen blokkerende FFI.
foreign export javascript "acoustics_dirGain sync" js_dirGain :: Double -> Double
foreign export javascript "acoustics_reqDist sync" js_reqDist :: Double -> Double -> Double -> Double
foreign export javascript "acoustics_levelAt sync" js_levelAt :: Double -> Double -> Double -> Double
foreign export javascript "acoustics_dbSum sync" js_dbSum :: JSVal -> Double
foreign export javascript "acoustics_grense sync" js_grense :: Int -> Int -> Double

-- Batch-eksport for rutenettet (gridWorker.js): hele celle-løkken kjøres i
-- Haskell ('Lyd.Felt'), så én worker-stripe koster ett eksport-kall i stedet
-- for celler·(pumper+1). IO er trygt i en sync-eksport her: kroppen gjør kun
-- unsafe imports (array-skriving), ingen blokkering.
foreign export javascript "acoustics_gridStripe sync"
  js_gridStripe :: Double -> JSVal -> Int -> Int -> Int -> Double -> JSVal -> IO ()

-- Skjermings-varianten er en NY eksport (ikke en utvidet signatur på den
-- gamle): gridWorker.js feature-detekterer på navnet, og en eldre deployet
-- binær ville ellers stille ignorert polygon-argumentene og regnet uten
-- skjerming uten at noen merket det.
foreign export javascript "acoustics_gridStripeSkjermet sync"
  js_gridStripeSkjermet :: Double -> JSVal -> JSVal -> JSVal -> Int -> Int -> Int -> Double -> JSVal -> IO ()

-- Verste fasadepunkt per husrekke ('Lyd.Felt.versteFasadepunkt'). Også en ny
-- eksport av samme grunn som over: hovedtråden feature-detekterer på navnet
-- og lar featuren ligge med en eldre binær.
foreign export javascript "acoustics_fasadeVerst sync"
  js_fasadeVerst :: Double -> JSVal -> JSVal -> JSVal -> Int -> JSVal -> IO ()

-- PerKilde-variantene: hver pumpe har sitt eget effektive nivå (lokale
-- verdier per utedel i simulatoren) — pumpene kommer som flat stride-4-array
-- [x,y,retning,nivå] i stedet for delt nivå + stride-3. Nye eksportnavn av
-- samme grunn som skjermingsvarianten over: JS feature-detekterer på navnet,
-- og en eldre binær faller synlig tilbake (høyeste nivå for alle,
-- konservativt) i stedet for å regne stille feil.
foreign export javascript "acoustics_gridStripePerKilde sync"
  js_gridStripePerKilde :: JSVal -> Int -> Int -> Int -> Double -> JSVal -> IO ()

foreign export javascript "acoustics_gridStripeSkjermetPerKilde sync"
  js_gridStripeSkjermetPerKilde :: JSVal -> JSVal -> JSVal -> Int -> Int -> Int -> Double -> JSVal -> IO ()

foreign export javascript "acoustics_fasadeVerstPerKilde sync"
  js_fasadeVerstPerKilde :: JSVal -> JSVal -> JSVal -> Int -> JSVal -> IO ()

-- Punktforklaring ('Lyd.Felt.punktBidragForklart'): per-kilde avstand/vinkel/
-- nivå før og etter skjerming for ett klikket rutenettpunkt — kartets
-- «forklar celle»-visning (stråler fra hver pumpe), ikke den varme
-- rutenett-stien. En ny eksport av samme grunn som variantene over: JS
-- feature-detekterer på navnet. Ingen delt-nivå/legacy-variant — featuren
-- er ny, så det finnes ingen eldre binær å falle tilbake fra. Nivået
-- returneres alltid både før og etter skjerming; JS avgjør selv (ut fra
-- «Skjermer»-boksen) hvilket som vises, i stedet for et eget flagg her.
foreign export javascript "acoustics_forklarPunkt sync"
  js_forklarPunkt :: Double -> Double -> JSVal -> JSVal -> JSVal -> JSVal -> IO ()

foreign import javascript unsafe "$1.length" js_arrLen :: JSVal -> Int
foreign import javascript unsafe "$1[$2]" js_arrAt :: JSVal -> Int -> Double

-- Bulk-kopiering mellom JS-arrays og wasm-lineærminnet: rutenettet er
-- hundretusenvis av celler, og med ett FFI-kall per element dominerte selve
-- wasm↔JS-krysningene kjøretiden. '__exports' er wasm-instansens exports
-- (inkl. 'memory') og er i scope i JSFFI-snuttene via closuren som
-- post-link.mjs genererer i ghc_wasm_jsffi.js. Viewet bygges per kall —
-- 'memory.buffer' byttes ut når minnet vokser, så det kan ikke caches.
foreign import javascript unsafe "new Float64Array(__exports.memory.buffer, $2, $3).set($1)"
  js_kopierInn :: JSVal -> Ptr Double -> Int -> IO ()

foreign import javascript unsafe "$1.set(new Float64Array(__exports.memory.buffer, $2, $3))"
  js_kopierUt :: JSVal -> Ptr Double -> Int -> IO ()

-- | Kopier en JS Float64Array inn som Storable-vektor — én FFI-krysning i
-- stedet for ett 'js_arrAt'-kall per element (husrekkene alene er flere
-- tusen tall per stripe).
lesFloat64 :: JSVal -> IO (VS.Vector Double)
lesFloat64 arr = do
  let n = js_arrLen arr
  fp <- mallocForeignPtrArray n
  withForeignPtr fp $ \p -> js_kopierInn arr p n
  pure (VS.unsafeFromForeignPtr0 fp n)

-- | Skriv en Storable-vektor til en JS Float64Array — én FFI-krysning i
-- stedet for ett @$1[$2] = $3@-kall per celle. Vektoren fra
-- 'rutenettStripe'\/'rutenettStripeSkjermet' ligger i pinnet minne, så
-- adressen er stabil gjennom det unsafe importkallet.
skrivFloat64 :: JSVal -> VS.Vector Double -> IO ()
skrivFloat64 ut v = VS.unsafeWith v $ \p -> js_kopierUt ut p (VS.length v)

-- | Frittstående kilde med 1 m referanse; 'src' inkluderer alt nivå (også
-- ev. veggtillegg), så monteringen settes til 'Frittstaaende' her.
simKilde :: Double -> Kilde
simKilde src =
  Kilde
    { oppgittNivaa = Desibel src,
      referanseavstand = standardR0,
      montering = Frittstaaende,
      kabinettDemping = 0
    }

-- | Retningsgevinst (≤ 0 dB) — negasjon av kjernens 'vinkelkorreksjon'.
js_dirGain :: Double -> Double
js_dirGain vinkel = negate (vinkelkorreksjon (vinkelKlampet vinkel))

-- | Avstand (m) der 'grenseDb' akkurat nås, i gitt vinkel. = 'avstand'.
js_reqDist :: Double -> Double -> Double -> Double
js_reqDist src grenseDb vinkel =
  meter (avstand (simKilde src) (vinkelKlampet vinkel) (Desibel grenseDb))

-- | Lydnivå (dBA) i avstand 'r' og gitt vinkel. = 'lydnivaa'.
js_levelAt :: Double -> Double -> Double -> Double
js_levelAt src r vinkel =
  dBA (lydnivaa (simKilde src) (vinkelKlampet vinkel) (Meter r))

-- | Logaritmisk sum av nivåene i en JS-array. = 'kumulativ'.
js_dbSum :: JSVal -> Double
js_dbSum arr = dBA (kumulativ [Desibel (js_arrAt arr i) | i <- [0 .. js_arrLen arr - 1]])

-- | Fyller 'ut' (Float64Array med (radSlutt−radStart)·kolonner elementer)
-- med kumulativt lydnivå per rutenettcelle, radmajor. = 'rutenettStripe'.
-- 'pumperXYB' er en flat stride-3-array [x0,y0,retning0, x1,y1,retning1, …]
-- i lokale plan-koordinater (meter fra rutenettets SV-hjørne, retning i
-- grader 0° = nord, medurs) — samme konvensjon som gridWorker.js. Hele
-- stripen skrives til 'ut' i én bulk-kopi ('skrivFloat64').
js_gridStripe :: Double -> JSVal -> Int -> Int -> Int -> Double -> JSVal -> IO ()
js_gridStripe src pumperXYB radStart radSlutt kolonner celleM ut = do
  plasserte <- lesPlasserte src pumperXYB
  skrivFloat64 ut (rutenettStripe plasserte stripe)
  where
    stripe = Stripe radStart radSlutt kolonner (Meter celleM)

-- | Som 'js_gridStripe', men med eget nivå per pumpe: 'pumperXYBN' er en
-- flat stride-4-array [x,y,retning,nivå] der nivået er pumpens effektive
-- kildenivå ved 1 m (JS har alt lagt på veggtillegg og trukket kabinett).
js_gridStripePerKilde :: JSVal -> Int -> Int -> Int -> Double -> JSVal -> IO ()
js_gridStripePerKilde pumperXYBN radStart radSlutt kolonner celleM ut = do
  plasserte <- lesPlassertePerKilde pumperXYBN
  skrivFloat64 ut (rutenettStripe plasserte stripe)
  where
    stripe = Stripe radStart radSlutt kolonner (Meter celleM)

-- | Som 'js_gridStripe', men med husrekke-polygoner og skjerming
-- (= 'rutenettStripeSkjermet'): celler inne i et polygon får NaN (maskeres
-- av tegnesiden), og kildebidrag med brutt siktlinje får det faste
-- skjermingsfradraget. 'polyXY' er alle polygonhjørnene flatt
-- [x0,y0,x1,y1,…] i samme lokale plan som pumpene, 'polyAntall' antall
-- hjørner per polygon (grensene mellom polygonene i den flate arrayen).
js_gridStripeSkjermet :: Double -> JSVal -> JSVal -> JSVal -> Int -> Int -> Int -> Double -> JSVal -> IO ()
js_gridStripeSkjermet src pumperXYB polyXY polyAntall radStart radSlutt kolonner celleM ut = do
  plasserte <- lesPlasserte src pumperXYB
  polygoner <- lesPolygoner polyXY polyAntall
  skrivFloat64 ut (rutenettStripeSkjermet plasserte polygoner stripe)
  where
    stripe = Stripe radStart radSlutt kolonner (Meter celleM)

-- | Som 'js_gridStripeSkjermet', med eget nivå per pumpe (stride-4, se
-- 'js_gridStripePerKilde').
js_gridStripeSkjermetPerKilde :: JSVal -> JSVal -> JSVal -> Int -> Int -> Int -> Double -> JSVal -> IO ()
js_gridStripeSkjermetPerKilde pumperXYBN polyXY polyAntall radStart radSlutt kolonner celleM ut = do
  plasserte <- lesPlassertePerKilde pumperXYBN
  polygoner <- lesPolygoner polyXY polyAntall
  skrivFloat64 ut (rutenettStripeSkjermet plasserte polygoner stripe)
  where
    stripe = Stripe radStart radSlutt kolonner (Meter celleM)

-- | Verste fasadepunkt per polygon (= 'versteFasadepunkt'): skriver
-- [x, y, nivå] per polygon inn i 'ut' (Float64Array med 3·antall polygoner
-- elementer, samme rekkefølge som 'polyAntall'). 'medSkjerm' ≠ 0 → nivået
-- regnes med skjerming/maskering mot alle polygonene; 0 → uskjermet (samme
-- valg som rutenettet, styrt av samme avkrysning). NaN i alle tre feltene
-- når polygonet er degenerert. Ingen pumper gir nivå -Infinity.
js_fasadeVerst :: Double -> JSVal -> JSVal -> JSVal -> Int -> JSVal -> IO ()
js_fasadeVerst src pumperXYB polyXY polyAntall medSkjerm ut = do
  plasserte <- lesPlasserte src pumperXYB
  fasadeVerstFelles plasserte polyXY polyAntall medSkjerm ut

-- | Som 'js_fasadeVerst', med eget nivå per pumpe (stride-4, se
-- 'js_gridStripePerKilde').
js_fasadeVerstPerKilde :: JSVal -> JSVal -> JSVal -> Int -> JSVal -> IO ()
js_fasadeVerstPerKilde pumperXYBN polyXY polyAntall medSkjerm ut = do
  plasserte <- lesPlassertePerKilde pumperXYBN
  fasadeVerstFelles plasserte polyXY polyAntall medSkjerm ut

fasadeVerstFelles :: [PlassertKilde] -> JSVal -> JSVal -> Int -> JSVal -> IO ()
fasadeVerstFelles plasserte polyXY polyAntall medSkjerm ut = do
  polygoner <- lesPolygoner polyXY polyAntall
  let skjermMed = if medSkjerm /= 0 then polygoner else []
      trippel poly = case versteFasadepunkt plasserte skjermMed poly of
        Just (Punkt px py, n) -> [px, py, n]
        Nothing -> [0 / 0, 0 / 0, 0 / 0]
  skrivFloat64 ut (VS.fromList (concatMap trippel polygoner))

-- | Forklaring for ett rutenettpunkt (= 'punktBidragForklart'): skriver
-- [avstand, vinkelGrader, nivåUskjermet, nivåEtterSkjerming] per pumpe
-- (stride 4) inn i 'ut' (Float64Array med pumper·4 elementer, JS-preallokert
-- ut fra antall pumper den selv sendte, samme rekkefølge som 'pumperXYBN').
js_forklarPunkt :: Double -> Double -> JSVal -> JSVal -> JSVal -> JSVal -> IO ()
js_forklarPunkt x y pumperXYBN polyXY polyAntall ut = do
  plasserte <- lesPlassertePerKilde pumperXYBN
  polygoner <- lesPolygoner polyXY polyAntall
  let bidrag = punktBidragForklart plasserte polygoner (Punkt x y)
      flat (KildeBidrag a v u e) = [a, v, u, e]
  skrivFloat64 ut (VS.fromList (concatMap flat bidrag))

-- | Polygonene fra flat hjørne-array [x0,y0,x1,y1,…] + antall hjørner per
-- polygon (grensene mellom polygonene i den flate arrayen). Begge arrayene
-- bulk-kopieres inn ('lesFloat64') før de pakkes ut.
lesPolygoner :: JSVal -> JSVal -> IO [Polygon]
lesPolygoner polyXY polyAntall = do
  xy <- lesFloat64 polyXY
  antall <- lesFloat64 polyAntall
  let antallHjoerner = [truncate (antall VS.! i) :: Int | i <- [0 .. VS.length antall - 1]]
      gaa _ [] = []
      gaa fra (n : rest) =
        [Punkt (xy VS.! (2 * (fra + i))) (xy VS.! (2 * (fra + i) + 1)) | i <- [0 .. n - 1]]
          : gaa (fra + n) rest
  pure (gaa 0 antallHjoerner)

-- | Pumpene fra flat stride-3-array [x0,y0,retning0, x1,y1,retning1, …] med
-- delt effektivt nivå 'src' (de gamle eksportene), bulk-kopiert inn
-- ('lesFloat64').
lesPlasserte :: Double -> JSVal -> IO [PlassertKilde]
lesPlasserte src pumperXYB = do
  v <- lesFloat64 pumperXYB
  pure
    [ PlassertKilde
        (Punkt (v VS.! (i * 3)) (v VS.! (i * 3 + 1)))
        (v VS.! (i * 3 + 2))
        (simKilde src)
    | i <- [0 .. VS.length v `div` 3 - 1]
    ]

-- | Pumpene fra flat stride-4-array [x0,y0,retning0,nivå0, x1,…] — eget
-- effektivt nivå per pumpe (PerKilde-eksportene).
lesPlassertePerKilde :: JSVal -> IO [PlassertKilde]
lesPlassertePerKilde pumperXYBN = do
  v <- lesFloat64 pumperXYBN
  pure
    [ PlassertKilde
        (Punkt (v VS.! (i * 4)) (v VS.! (i * 4 + 1)))
        (v VS.! (i * 4 + 2))
        (simKilde (v VS.! (i * 4 + 3)))
    | i <- [0 .. VS.length v `div` 4 - 1]
    ]

-- | Grenseverdi (dBA) fra NS 8175-tabellen, = 'grense'. Indeksene følger
-- enum-rekkefølgen: klasse 0–3 = A, B+, B, C; tidsrom 0–2 = Dag, Kveld, Natt
-- (JS-siden bygger hele grensetabellen herfra i stedet for å ha en kopi av
-- tallene). Indeksene klampes til gyldig område, så et vilkårlig JS-kall
-- aldri kan treffe utenfor enumene.
js_grense :: Int -> Int -> Double
js_grense k t = dBA (grense klasse tidsrom)
  where
    klasse = toEnum (max 0 (min (fromEnum (maxBound :: Lydklasse)) k))
    tidsrom = toEnum (max 0 (min (fromEnum (maxBound :: Tidsrom)) t))
#endif

app :: App Model Action
app = component startModel updateModel viewModel

startModel :: Model
startModel =
  Model
    { _nivaaTekst = "50",
      _monteringValg = Frittstaaende,
      _kabinettTekst = "0",
      _vinkelValg = startVinkel,
      _valgtKlasse = KlasseB,
      _valgtTidsrom = Kveld,
      _avstandTekst = "5"
    }

updateModel :: Action -> Effect parent props Model Action
updateModel = \case
  SettNivaa s -> nivaaTekst .= s
  SettVeggmontert (Checked b) ->
    monteringValg .= if b then Veggmontert else Frittstaaende
  SettKabinett s -> kabinettTekst .= s
  SettVinkel s -> case nyVinkel =<< parseDouble s of
    Just v -> vinkelValg .= v
    Nothing -> pure ()
  SettKlasse k -> valgtKlasse .= k
  VelgCelle k t -> valgtKlasse .= k >> valgtTidsrom .= t
  SettAvstand s -> avstandTekst .= s

-- Hjelpere ---------------------------------------------------------------

parseDouble :: MisoString -> Maybe Double
parseDouble = readMaybe . fromMisoString

klamp :: Double -> Double -> Double -> Double
klamp lo hi = max lo . min hi

-- | Kilden slik den er beskrevet i inndata-panelet, hvis nivået er gyldig.
kilde :: Model -> Maybe Kilde
kilde m = do
  v <- parseDouble (m ^. nivaaTekst)
  pure
    Kilde
      { oppgittNivaa = Desibel (klamp 40 70 v),
        referanseavstand = standardR0,
        montering = m ^. monteringValg,
        kabinettDemping = kabinett m
      }

-- | Kabinett-demping (dB) fra inndata; tomt/ugyldig felt tolkes som 0.
kabinett :: Model -> Double
kabinett m = max 0 (fromMaybe 0 (parseDouble (m ^. kabinettTekst)))

-- | Avstand til nabo fra inndata, hvis gyldig (> 0 m).
naboAvstand :: Model -> Maybe Meter
naboAvstand m = case parseDouble (m ^. avstandTekst) of
  Just r | r > 0 -> Just (Meter r)
  _ -> Nothing

-- | Effektivt kildenivå mot naboen ved 1 m: effektivt kildenivå (vegg og
-- kabinett) minus retningskorreksjonen for den valgte vinkelen.
effektivtMotNabo :: Kilde -> Vinkel -> Desibel
effektivtMotNabo k v =
  Desibel (dBA (effektivtKildenivaa k) - vinkelkorreksjon v)

-- | Tall med én desimal og norsk desimaltegn.
desimal :: Double -> MisoString
desimal x = ms (map punktumTilKomma (showFFloat (Just 1) x ""))
  where
    punktumTilKomma c = if c == '.' then ',' else c

visMeter :: Meter -> MisoString
visMeter r = desimal (meter r) <> " m"

-- | Slideren starter midt i området (45°). Med cosinus-modellen gir alle
-- vinkler 0–90° korreksjon, så hele spennet er meningsfullt.
startVinkel :: Vinkel
startVinkel = fromMaybe rettFrem (nyVinkel 45)

visVinkel :: Vinkel -> MisoString
visVinkel v = ms (show (round (grader v) :: Int)) <> "°"

-- | Tidsrom-overskrift i rutenettet. Natt er dimensjonerende, derav «dim.».
tidsromKort :: Tidsrom -> MisoString
tidsromKort Dag = "Dag 07–19"
tidsromKort Kveld = "Kveld 19–23"
tidsromKort Natt = "Natt 23–07 · dim."

klasseNavn :: Lydklasse -> MisoString
klasseNavn KlasseA = "Klasse A"
klasseNavn KlasseBpluss = "Klasse B+"
klasseNavn KlasseB = "Klasse B"
klasseNavn KlasseC = "Klasse C"

klasseUndertittel :: Lydklasse -> MisoString
klasseUndertittel KlasseA = "streng · frivillig"
klasseUndertittel KlasseBpluss = "custom · C − 7 dB"
klasseUndertittel KlasseB = "anbefalt · frivillig"
klasseUndertittel KlasseC = "minstekrav"

-- | Klassene i visningsrekkefølge: strengest øverst.
alleKlasser :: [Lydklasse]
alleKlasser = [minBound .. maxBound]

-- | CSS-klasse for heatmap-tone etter grenseverdi (strengere = mørkere blå).
-- Grensene er heltall, så «h25»…«h45» dekker alle cellene.
heatKlasse :: Desibel -> MisoString
heatKlasse (Desibel g) = ms ("h" <> show (round g :: Int))

-- | Grenseverdi som heltall, «35 dB(A)».
visGrense :: Desibel -> MisoString
visGrense (Desibel g) = ms (show (round g :: Int)) <> " dB(A)"

-- | Beregnet nivå med én desimal, «23,5 dB(A)».
visNivaa :: Desibel -> MisoString
visNivaa d = desimal (dBA d) <> " dB(A)"

-- | Vinkel og tilhørende demping, «90° · −5,0 dB».
visVinkelDemping :: Vinkel -> MisoString
visVinkelDemping v = visVinkel v <> " · " <> tegn <> desimal korr <> " dB"
  where
    korr = vinkelkorreksjon v
    tegn = if korr > 0 then "−" else ""

-- Visning -----------------------------------------------------------------

viewModel :: props -> Model -> View Model Action
viewModel _ m =
  H.div_
    [P.class_ "app"]
    [ H.h1_ [] [text "Varmepumpe: lydnivå og avstand (NS 8175)"],
      H.p_ [] [H.a_ [P.href_ "lydnivakart.html"] [text "enkel simulator på kart"]],
      inndataPanel m,
      case kilde m of
        Nothing ->
          H.section_
            [P.class_ "panel"]
            [H.p_ [P.class_ "feil"] [text "Oppgi gyldig lydnivå (40–70 dBA)."]]
        Just k ->
          H.div_
            []
            [ rutenettPanel m k,
              detaljPanel m k
            ],
      H.p_
        [P.class_ "fotnote"]
        [ text
            ( "Forenklet frittfeltmodell (invers kvadratlov). Faktiske forhold "
                <> "med refleksjoner og skjerming kan avvike. Grenseverdier: "
                <> "NS 8175, LAFmax på uteoppholdsareal."
            )
        ]
    ]

-- | Inndata i to seksjoner: «Lydkilde» (nivå, vegg, kabinett → effektivt
-- kildenivå) og «Nabo» (avstand, vinkel) — geometrien matrisen bruker.
inndataPanel :: Model -> View Model Action
inndataPanel m =
  H.section_
    [P.class_ "panel inndata"]
    [ H.div_
        [P.class_ "seksjon"]
        [ H.h3_ [P.class_ "seksjon-tittel"] [text "Lydkilde"],
          H.div_
            [P.class_ "felter"]
            [ felt "nivaa" "Lydnivå 1 m (dBA)" $
                H.input_
                  [ P.id_ "nivaa",
                    P.type_ "number",
                    P.min_ "40",
                    P.max_ "70",
                    P.step_ "1",
                    P.value_ (m ^. nivaaTekst),
                    E.onInput SettNivaa
                  ],
              H.div_
                [P.class_ "felt"]
                [ H.label_
                    [P.class_ "sjekk"]
                    [ H.input_
                        [ P.type_ "checkbox",
                          P.checked_ (m ^. monteringValg == Veggmontert),
                          E.onChecked SettVeggmontert
                        ],
                      text " +3 dB vegg"
                    ]
                ],
              felt "kabinett" "Kabinettdemping (dB)" $
                H.input_
                  [ P.id_ "kabinett",
                    P.type_ "number",
                    P.min_ "0",
                    P.step_ "1",
                    P.value_ (m ^. kabinettTekst),
                    E.onInput SettKabinett
                  ]
            ],
          H.div_
            [P.class_ "effektivt"]
            [ H.span_ [P.class_ "hint"]
                [ text
                    ( "Effektivt kildenivå: "
                        <> maybe "–" (visNivaa . effektivtKildenivaa) (kilde m)
                    )
                ]
            ]
        ],
      H.div_
        [P.class_ "seksjon"]
        [ H.h3_ [P.class_ "seksjon-tittel"] [text "Nabo"],
          H.div_
            [P.class_ "felter"]
            [ felt "avstand" "Avstand (m)" $
                H.input_
                  [ P.id_ "avstand",
                    P.type_ "number",
                    P.min_ "0.5",
                    P.step_ "0.5",
                    P.value_ (m ^. avstandTekst),
                    E.onInput SettAvstand
                  ],
              H.div_
                [P.class_ "felt vinkelfelt"]
                [ H.label_ [P.for_ "vinkel"] [text ("Vinkel · " <> visVinkelDemping (m ^. vinkelValg))],
                  H.input_
                    [ P.id_ "vinkel",
                      P.type_ "range",
                      P.min_ "0",
                      P.max_ "90",
                      P.step_ "1",
                      P.value_ (ms (show (round (grader (m ^. vinkelValg)) :: Int))),
                      E.onInput SettVinkel
                    ]
                ]
            ]
        ],
      -- Linje på tvers av begge seksjoner: kildenivå justert for vinkel.
      -- Dette nivået ved 1 m er det matrisen regner avstandene ut fra.
      H.div_ [P.class_ "samlet"] samletInnhold
    ]
  where
    felt feltId etikett inp =
      H.div_ [P.class_ "felt"] [H.label_ [P.for_ feltId] [text etikett], inp]
    samletInnhold = case kilde m of
      Nothing -> [H.span_ [P.class_ "hint"] [text "–"]]
      Just k ->
        let v = m ^. vinkelValg
         in [ H.strong_ [] [text ("Effektivt kildenivå inkl. vinkel: " <> visNivaa (effektivtMotNabo k v))],
              H.span_
                [P.class_ "hint"]
                [ text
                    ( visNivaa (effektivtKildenivaa k)
                        <> " − "
                        <> desimal (vinkelkorreksjon v)
                        <> " dB retningsdemping ved "
                        <> visVinkel v
                        <> ". Matrisen regner avstandene ut fra dette nivået."
                    )
                ]
            ]

-- | Rutenett: 4 lydklasser (rader) × 3 tidsrom (kolonner). Hver celle viser
-- grenseverdi og nødvendig avstand, fargelagt etter strenghet, med en hake
-- når avstanden til naboen er innenfor. Klikk på en rad velger klassen som
-- vises i detaljpanelet.
rutenettPanel :: Model -> Kilde -> View Model Action
rutenettPanel m k =
  H.section_
    [P.class_ "panel"]
    [ H.div_ [P.class_ "rutenett"] (hodeceller ++ concatMap klasseCeller alleKlasser),
      likhetNotat m k,
      legende
    ]
  where
    v = m ^. vinkelValg
    mr = naboAvstand m
    valgtK = m ^. valgtKlasse
    valgtT = m ^. valgtTidsrom
    -- Grensen i den valgte cellen; alle celler med samme grense rammes inn.
    valgtGrense = grense valgtK valgtT
    hodeceller =
      H.div_ [P.class_ "kolonnehode hjorne"] []
        : [H.div_ [P.class_ "kolonnehode"] [text (tidsromKort t)] | t <- [Dag, Kveld, Natt]]
    klasseCeller klasse = etikett : [celle t | t <- [Dag, Kveld, Natt]]
      where
        etikett =
          H.div_
            [ P.class_ ("klassecelle" <> if klasse == valgtK then " valgt" else ""),
              E.onClick (SettKlasse klasse)
            ]
            [ H.span_ [P.class_ "knavn"] [text (klasseNavn klasse)],
              H.span_ [P.class_ "kundertittel"] [text (klasseUndertittel klasse)]
            ]
        celle t =
          let g = grense klasse t
              d = avstand k v g
              -- Status mot naboavstanden: innenfor → hake, utenfor → kryss.
              naboStatus = fmap (\r -> lydnivaa k v r <= g) mr
              samme = if g == valgtGrense then " samme" else ""
              valgtCelle = if klasse == valgtK && t == valgtT then " valgt-celle" else ""
           in H.div_
                [ P.class_ ("celle " <> heatKlasse g <> samme <> valgtCelle),
                  E.onClick (VelgCelle klasse t)
                ]
                [ H.span_ [P.class_ "grense"] [text (visGrense g)],
                  H.span_ [P.class_ "cavstand"] [text (visMeter d)],
                  statusMerke naboStatus
                ]

    -- Hake (innenfor) / kryss (utenfor) / ingenting (ingen avstand oppgitt).
    statusMerke naboStatus = case naboStatus of
      Just True -> H.span_ [P.class_ "hake ok"] [text "✓"]
      Just False -> H.span_ [P.class_ "hake feil"] [text "✗"]
      Nothing -> text ""

-- | Notat om −5 dB-gitteret: A dag = B kveld = C natt (alle 35 dB(A)).
likhetNotat :: Model -> Kilde -> View Model Action
likhetNotat m k =
  H.p_
    [P.class_ "likhet"]
    [ text
        ( visGrense (Desibel 35)
            <> " → "
            <> visMeter (avstand k (m ^. vinkelValg) (Desibel 35))
            <> " · A dag = B kveld = C natt"
        )
    ]

-- | Fargeforklaring: fra strengere (rød, lengre avstand) til mildere (grønn).
legende :: View Model Action
legende =
  H.div_
    [P.class_ "legende"]
    [ H.span_ [] [text "strengere grense (lengre avstand)"],
      H.div_ [P.class_ "legende-bar"] [],
      H.span_ [] [text "mildere grense"]
    ]

-- | Detaljpanel for valgt klasse: avstand per tidsrom, påkrevd nattkabinett
-- ved naboavstanden, og en kort tolkning.
detaljPanel :: Model -> Kilde -> View Model Action
detaljPanel m k =
  H.section_
    [P.class_ "panel detalj"]
    [ H.div_
        [P.class_ "detalj-hode"]
        [ H.h2_ [] [text (klasseNavn klasse)],
          H.span_ [P.class_ "kundertittel"] [text (klasseUndertittel klasse <> " — grense LAFmax")]
        ],
      H.div_ [P.class_ "chips"] (avstandChips ++ [kabinettChip]),
      H.p_ [P.class_ "detalj-tekst"] forklaring
    ]
  where
    klasse = m ^. valgtKlasse
    v = m ^. vinkelValg
    mr = naboAvstand m
    nattG = grense klasse Natt
    chip etikett verdi =
      H.div_
        [P.class_ "chip"]
        [ H.span_ [P.class_ "chip-etikett"] [text etikett],
          H.span_ [P.class_ "chip-verdi"] [text verdi]
        ]
    -- Chip med tooltip: ⓘ-ikon i etiketten, forklaring vises ved hover.
    chipMedTip etikett verdi tip =
      H.div_
        [P.class_ "chip tip"]
        [ H.span_
            [P.class_ "chip-etikett"]
            [text etikett, H.span_ [P.class_ "info"] [text "ⓘ"]],
          H.span_ [P.class_ "chip-verdi"] [text verdi],
          H.span_ [P.class_ "tip-tekst"] [text tip]
        ]
    avstandChips =
      [chip (tidsromKort t) (visMeter (avstand k v (grense klasse t))) | t <- [Dag, Kveld, Natt]]
    kabinettTip =
      "Demping (dB) utedelen trenger for at nattgrensen ("
        <> visGrense nattG
        <> ") akkurat er oppfylt ved naboavstanden. Regnes uten dagens kabinett; "
        <> "0 dB betyr at grensen alt holder."
    kabinettChip = case mr of
      Nothing -> chipMedTip "Kabinettbehov natt" "–" kabinettTip
      Just r ->
        chipMedTip
          ("Kabinettbehov natt v/ " <> visMeter r)
          (desimal (paakrevdDemping k v r nattG) <> " dB")
          kabinettTip
    forklaring = case mr of
      Nothing -> [text "Oppgi en avstand til naboen for å se nivå og kabinettbehov."]
      Just r ->
        let nivaa = lydnivaa k v r
            oppfylt = nivaa <= nattG
            kab = kabinett m
            klOffset = klasseOffset klasse
         in [ text ("Ved " <> visMeter r <> " er nivået ca. " <> visNivaa nivaa <> ". Nattgrensen (" <> visGrense nattG <> ") er "),
              H.strong_
                [P.class_ (if oppfylt then "ok" else "for-hoyt")]
                [text (if oppfylt then "oppfylt" else "ikke oppfylt")],
              text (kabinettSetning oppfylt kab <> offsetSetning klOffset)
            ]
    kabinettSetning oppfylt kab
      | oppfylt && kab > 0 = " — kabinettet på " <> desimal kab <> " dB holder. "
      | oppfylt = ". "
      | otherwise = " — øk avstand eller kabinett. "
    offsetSetning klOffset
      | klOffset > 0 = ms (show (round klOffset :: Int)) <> " dB under minstekrav (Klasse C) i alle tidsrom."
      | otherwise = "Dette er minstekravet (Klasse C)."
