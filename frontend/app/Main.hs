{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Lyd.Beregning
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
    _vinkelValg :: Vinkel,
    _valgtKlasse :: Lydklasse,
    _avstandTekst :: MisoString
  }
  deriving (Eq)

nivaaTekst :: Lens Model MisoString
nivaaTekst = lens _nivaaTekst $ \r f -> r {_nivaaTekst = f}

monteringValg :: Lens Model Montering
monteringValg = lens _monteringValg $ \r f -> r {_monteringValg = f}

vinkelValg :: Lens Model Vinkel
vinkelValg = lens _vinkelValg $ \r f -> r {_vinkelValg = f}

valgtKlasse :: Lens Model Lydklasse
valgtKlasse = lens _valgtKlasse $ \r f -> r {_valgtKlasse = f}

avstandTekst :: Lens Model MisoString
avstandTekst = lens _avstandTekst $ \r f -> r {_avstandTekst = f}

data Action
  = SettNivaa MisoString
  | SettVeggmontert Checked
  | SettVinkel MisoString
  | SettKlasse Lydklasse
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

foreign import javascript unsafe "$1.length" js_arrLen :: JSVal -> Int
foreign import javascript unsafe "$1[$2]" js_arrAt :: JSVal -> Int -> Double

-- | Frittstående kilde med 1 m referanse; 'src' inkluderer alt nivå (også
-- ev. veggtillegg), så monteringen settes til 'Frittstaaende' her.
simKilde :: Double -> Kilde
simKilde src =
  Kilde {oppgittNivaa = Desibel src, referanseavstand = standardR0, montering = Frittstaaende}

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
#endif

app :: App Model Action
app = component startModel updateModel viewModel

startModel :: Model
startModel =
  Model
    { _nivaaTekst = "50",
      _monteringValg = Frittstaaende,
      _vinkelValg = startVinkel,
      _valgtKlasse = KlasseC,
      _avstandTekst = "6"
    }

updateModel :: Action -> Effect parent props Model Action
updateModel = \case
  SettNivaa s -> nivaaTekst .= s
  SettVeggmontert (Checked b) ->
    monteringValg .= if b then Veggmontert else Frittstaaende
  SettVinkel s -> case nyVinkel =<< parseDouble s of
    Just v -> vinkelValg .= v
    Nothing -> pure ()
  SettKlasse k -> valgtKlasse .= k
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
        montering = m ^. monteringValg
      }

-- | Tall med én desimal og norsk desimaltegn.
desimal :: Double -> MisoString
desimal x = ms (map punktumTilKomma (showFFloat (Just 1) x ""))
  where
    punktumTilKomma c = if c == '.' then ',' else c

visDb :: Desibel -> MisoString
visDb d = desimal (dBA d) <> " dBA"

visMeter :: Meter -> MisoString
visMeter r = desimal (meter r) <> " m"

-- | Slideren starter midt i området (45°). Med cosinus-modellen gir alle
-- vinkler 0–90° korreksjon, så hele spennet er meningsfullt.
startVinkel :: Vinkel
startVinkel = fromMaybe rettFrem (nyVinkel 45)

visVinkel :: Vinkel -> MisoString
visVinkel v = ms (show (round (grader v) :: Int)) <> "°"

tidsromNavn :: Tidsrom -> MisoString
tidsromNavn Dag = "Dag (07–19)"
tidsromNavn Kveld = "Kveld (19–23)"
tidsromNavn Natt = "Natt (23–07)"

klasseNavn :: Lydklasse -> MisoString
klasseNavn KlasseC = "Klasse C (minstekrav)"
klasseNavn KlasseB = "Klasse B (anbefalt)"

-- | Faktiske vinkelgrader for tabellen, f.eks. «0°», «50°».
vinkelGrad :: Vinkel -> MisoString
vinkelGrad v = ms (show (round (grader v) :: Int)) <> "°"

-- Visning -----------------------------------------------------------------

viewModel :: props -> Model -> View Model Action
viewModel _ m =
  H.div_
    [P.class_ "app"]
    [ H.h1_ [] [text "Varmepumpe: lydnivå og avstand (NS 8175)"],
      inndataPanel m,
      case kilde m of
        Nothing ->
          H.section_
            [P.class_ "panel"]
            [H.p_ [P.class_ "feil"] [text "Oppgi gyldig lydnivå (40–70 dBA)."]]
        Just k ->
          H.div_
            []
            [ modusA m k,
              modusB m k,
              modusC k
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

inndataPanel :: Model -> View Model Action
inndataPanel m =
  H.section_
    [P.class_ "panel"]
    [ H.h2_ [] [text "Inndata"],
      H.div_
        [P.class_ "felt"]
        [ H.label_ [P.for_ "nivaa"] [text "Oppgitt lydnivå utedel, 1 m frittfelt (dBA)"],
          H.input_
            [ P.id_ "nivaa",
              P.type_ "number",
              P.min_ "40",
              P.max_ "70",
              P.step_ "1",
              P.value_ (m ^. nivaaTekst),
              E.onInput SettNivaa
            ]
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
              text " Veggmontert utedel (+3 dBA refleksjon)"
            ],
          H.span_
            [P.class_ "hint"]
            [ text
                ( "Effektivt kildenivå: "
                    <> maybe "–" (visDb . effektivtKildenivaa) (kilde m)
                )
            ]
        ],
      H.div_
        [P.class_ "felt"]
        [ H.label_
            [P.for_ "vinkel"]
            [ text
                ( "Vinkel til nabo relativt viftens hovedretning: "
                    <> visVinkel (m ^. vinkelValg)
                )
            ],
          H.input_
            [ P.id_ "vinkel",
              P.type_ "range",
              P.min_ "0",
              P.max_ "90",
              P.step_ "1",
              P.value_ (ms (show (round (grader (m ^. vinkelValg)) :: Int))),
              E.onInput SettVinkel
            ],
          H.span_
            [P.class_ "hint"]
            [text "Retningskorreksjon følger en cosinus-karakteristikk: 0 dBA rett frem, økende til 5 dBA demping ved 90°."]
        ],
      H.div_
        [P.class_ "felt"]
        [ H.span_ [] [text "Lydklasse"],
          H.label_
            [P.class_ "radio"]
            [ H.input_
                [ P.type_ "radio",
                  P.name_ "klasse",
                  P.checked_ (m ^. valgtKlasse == KlasseC),
                  E.onClick (SettKlasse KlasseC)
                ],
              text " C (minstekrav)"
            ],
          H.label_
            [P.class_ "radio"]
            [ H.input_
                [ P.type_ "radio",
                  P.name_ "klasse",
                  P.checked_ (m ^. valgtKlasse == KlasseB),
                  E.onClick (SettKlasse KlasseB)
                ],
              text " B (anbefalt)"
            ]
        ]
    ]

-- | Modus A: nødvendig minsteavstand per tidsrom.
modusA :: Model -> Kilde -> View Model Action
modusA m k =
  H.section_
    [P.class_ "panel"]
    [ H.h2_ [] [text "Avstand for å overholde grense"],
      H.table_
        []
        [ H.thead_
            []
            [ H.tr_
                []
                [ H.th_ [] [text "Tidsrom"],
                  H.th_ [] [text "Grense"],
                  H.th_ [] [text "Minsteavstand"]
                ]
            ],
          H.tbody_ [] (vanligeRader ++ [avslagRad])
        ],
      H.p_
        [P.class_ "hint"]
        [text "Nattavslag: pumpen slås av kl. 23–07, da er kveldsgrensen dimensjonerende."]
    ]
  where
    klasse = m ^. valgtKlasse
    v = m ^. vinkelValg
    avstandFor g = avstand k v g
    rader = [(tidsromNavn t, grense klasse t) | t <- [Dag, Kveld, Natt]]
    stoerst = maximum [avstandFor g | (_, g) <- rader]
    vanligeRader =
      [ rad navn g (avstandFor g == stoerst) "dimensjonerende"
      | (navn, g) <- rader
      ]
    avslagRad =
      rad "Natt m/ nattavslag" (grense klasse Kveld) True "dimensjonerende m/ nattavslag"
    rad navn g dim merke =
      H.tr_
        [P.class_ (if dim then "dim" else "")]
        [ H.td_ [] [text navn],
          H.td_ [] [text (visDb g)],
          H.td_
            []
            [ text (visMeter (avstandFor g)),
              if dim then H.span_ [P.class_ "merke"] [text merke] else text ""
            ]
        ]

-- | Modus B: lydnivå ved gitt avstand, innenfor/utenfor per tidsrom.
modusB :: Model -> Kilde -> View Model Action
modusB m k =
  H.section_
    [P.class_ "panel"]
    [ H.h2_ [] [text "Lydnivå ved gitt avstand"],
      H.div_
        [P.class_ "felt"]
        [ H.label_ [P.for_ "avstand"] [text "Avstand til nabo (meter)"],
          H.input_
            [ P.id_ "avstand",
              P.type_ "number",
              P.min_ "0.5",
              P.step_ "0.5",
              P.value_ (m ^. avstandTekst),
              E.onInput SettAvstand
            ]
        ],
      case mr of
        Nothing -> H.p_ [P.class_ "feil"] [text "Oppgi gyldig avstand (> 0 m)."]
        Just r -> resultat r
    ]
  where
    klasse = m ^. valgtKlasse
    v = m ^. vinkelValg
    mr = case parseDouble (m ^. avstandTekst) of
      Just r | r > 0 -> Just (Meter r)
      _ -> Nothing
    resultat r =
      H.div_
        []
        [ H.p_
            []
            [ text "Beregnet lydnivå: ",
              H.strong_ [] [text (visDb nivaa)]
            ],
          H.table_
            []
            [ H.thead_
                []
                [ H.tr_
                    []
                    [ H.th_ [] [text "Tidsrom"],
                      H.th_ [] [text "Grense"],
                      H.th_ [] [text "Status"]
                    ]
                ],
              H.tbody_
                []
                ( [statusRad (tidsromNavn t) (grense klasse t) | t <- [Dag, Kveld, Natt]]
                    ++ [statusRad "Natt m/ nattavslag" (grense klasse Kveld)]
                )
            ]
        ]
      where
        nivaa = lydnivaa k v r
        statusRad navn g =
          let innenfor = nivaa <= g
           in H.tr_
                []
                [ H.td_ [] [text navn],
                  H.td_ [] [text (visDb g)],
                  H.td_
                    [P.class_ (if innenfor then "ok" else "for-hoyt")]
                    [text (if innenfor then "Innenfor" else "Utenfor")]
                ]

-- | Modus C: minsteavstand for et fast vinkelsett, Klasse C og B side om
-- side, én undertabell per tidsrom — som notatbokens grid.
modusC :: Kilde -> View Model Action
modusC k =
  H.section_
    [P.class_ "panel"]
    [ H.h2_ [] [text "Avstandstabell — vinkel og lydklasse"],
      H.div_
        [P.class_ "tabell-kolonner"]
        [klasseKolonne k klasse | klasse <- [KlasseC, KlasseB]],
      H.p_
        [P.class_ "hint"]
        [text "Minsteavstand (m) for å overholde grensen i hvert tidsrom, ved faste vinkler relativt viftens hovedretning. Følger effektivt kildenivå (inkl. veggmontering)."]
    ]

-- | Én klasse-kolonne: overskrift og tre undertabeller (Dag/Kveld/Natt).
klasseKolonne :: Kilde -> Lydklasse -> View Model Action
klasseKolonne k klasse =
  H.div_
    [P.class_ "tabell-kolonne"]
    ( H.h3_ [] [text (klasseNavn klasse)]
        : [undertabell rad | rad <- avstandsTabell k noenVinkler klasse]
    )

-- | Én undertabell for ett tidsrom: grensen i bildeteksten, vinkel → avstand.
undertabell :: AvstandsRad -> View Model Action
undertabell rad =
  H.table_
    []
    [ H.thead_
        []
        [ H.tr_
            []
            [ H.th_ [] [text (tidsromNavn (arTidsrom rad) <> " · " <> visDb (arGrense rad))],
              H.th_ [] [text "Avstand"]
            ]
        ],
      H.tbody_
        []
        [ H.tr_
            []
            [ H.td_ [] [text (vinkelGrad v)],
              H.td_ [] [text (visMeter r)]
            ]
        | (v, r) <- arCeller rad
        ]
    ]
