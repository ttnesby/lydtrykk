{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Lyd.Beregning
import Miso
import qualified Miso.Html as H
import qualified Miso.Html.Event as E
import qualified Miso.Html.Property as P
import Miso.Lens
import Numeric (showFFloat)
import Text.Read (readMaybe)

data Model = Model
  { _nivaaTekst :: MisoString
  , _veggmontert :: Bool
  , _vinkelGrader :: Double
  , _valgtKlasse :: Lydklasse
  , _avstandTekst :: MisoString
  }
  deriving (Eq)

nivaaTekst :: Lens Model MisoString
nivaaTekst = lens _nivaaTekst $ \r f -> r {_nivaaTekst = f}

veggmontert :: Lens Model Bool
veggmontert = lens _veggmontert $ \r f -> r {_veggmontert = f}

vinkelGrader :: Lens Model Double
vinkelGrader = lens _vinkelGrader $ \r f -> r {_vinkelGrader = f}

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
#endif

app :: App Model Action
app = component startModel updateModel viewModel

startModel :: Model
startModel =
  Model
    { _nivaaTekst = "53"
    , _veggmontert = True
    , _vinkelGrader = 0
    , _valgtKlasse = KlasseC
    , _avstandTekst = "10"
    }

updateModel :: Action -> Effect parent props Model Action
updateModel = \case
  SettNivaa s -> nivaaTekst .= s
  SettVeggmontert (Checked b) -> veggmontert .= b
  SettVinkel s -> case parseDouble s of
    Just v -> vinkelGrader .= klamp 0 90 v
    Nothing -> pure ()
  SettKlasse k -> valgtKlasse .= k
  SettAvstand s -> avstandTekst .= s

-- Hjelpere ---------------------------------------------------------------

parseDouble :: MisoString -> Maybe Double
parseDouble = readMaybe . fromMisoString

klamp :: Double -> Double -> Double -> Double
klamp lo hi = max lo . min hi

-- | Effektivt kildenivå (inkl. evt. veggtillegg), hvis input er gyldig.
kildenivaa :: Model -> Maybe Double
kildenivaa m = do
  v <- parseDouble (m ^. nivaaTekst)
  pure (effektivtKildenivaa (m ^. veggmontert) (klamp 40 70 v))

-- | Tall med én desimal og norsk desimaltegn.
desimal :: Double -> MisoString
desimal x = ms (map punktumTilKomma (showFFloat (Just 1) x ""))
  where
    punktumTilKomma c = if c == '.' then ',' else c

tidsromNavn :: Tidsrom -> MisoString
tidsromNavn Dag = "Dag (07–19)"
tidsromNavn Kveld = "Kveld (19–23)"
tidsromNavn Natt = "Natt (23–07)"

-- Visning -----------------------------------------------------------------

viewModel :: props -> Model -> View Model Action
viewModel _ m =
  H.div_
    [P.class_ "app"]
    [ H.h1_ [] [text "Varmepumpe: lydnivå og avstand (NS 8175)"]
    , inndataPanel m
    , case kildenivaa m of
        Nothing ->
          H.section_
            [P.class_ "panel"]
            [H.p_ [P.class_ "feil"] [text "Oppgi gyldig lydnivå (40–70 dBA)."]]
        Just lp0 ->
          H.div_
            []
            [ modusA m lp0
            , modusB m lp0
            ]
    , H.p_
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
    [ H.h2_ [] [text "Inndata"]
    , H.div_
        [P.class_ "felt"]
        [ H.label_ [P.for_ "nivaa"] [text "Oppgitt lydnivå utedel, 1 m frittfelt (dBA)"]
        , H.input_
            [ P.id_ "nivaa"
            , P.type_ "number"
            , P.min_ "40"
            , P.max_ "70"
            , P.step_ "1"
            , P.value_ (m ^. nivaaTekst)
            , E.onInput SettNivaa
            ]
        ]
    , H.div_
        [P.class_ "felt"]
        [ H.label_
            [P.class_ "sjekk"]
            [ H.input_
                [ P.type_ "checkbox"
                , P.checked_ (m ^. veggmontert)
                , E.onChecked SettVeggmontert
                ]
            , text " Veggmontert utedel (+3 dBA refleksjon)"
            ]
        , H.span_
            [P.class_ "hint"]
            [ text
                ( "Effektivt kildenivå: "
                    <> maybe "–" desimal (kildenivaa m)
                    <> " dBA"
                )
            ]
        ]
    , H.div_
        [P.class_ "felt"]
        [ H.label_
            [P.for_ "vinkel"]
            [ text
                ( "Vinkel til nabo relativt viftens hovedretning: "
                    <> ms (show (round (m ^. vinkelGrader) :: Int))
                    <> "°"
                )
            ]
        , H.input_
            [ P.id_ "vinkel"
            , P.type_ "range"
            , P.min_ "0"
            , P.max_ "90"
            , P.step_ "1"
            , P.value_ (ms (show (round (m ^. vinkelGrader) :: Int)))
            , E.onInput SettVinkel
            ]
        ]
    , H.div_
        [P.class_ "felt"]
        [ H.span_ [] [text "Lydklasse"]
        , H.label_
            [P.class_ "radio"]
            [ H.input_
                [ P.type_ "radio"
                , P.name_ "klasse"
                , P.checked_ (m ^. valgtKlasse == KlasseC)
                , E.onClick (SettKlasse KlasseC)
                ]
            , text " C (minstekrav)"
            ]
        , H.label_
            [P.class_ "radio"]
            [ H.input_
                [ P.type_ "radio"
                , P.name_ "klasse"
                , P.checked_ (m ^. valgtKlasse == KlasseB)
                , E.onClick (SettKlasse KlasseB)
                ]
            , text " B (anbefalt)"
            ]
        ]
    ]

-- | Modus A: nødvendig minsteavstand per tidsrom.
modusA :: Model -> Double -> View Model Action
modusA m lp0 =
  H.section_
    [P.class_ "panel"]
    [ H.h2_ [] [text "Avstand for å overholde grense"]
    , H.table_
        []
        [ H.thead_
            []
            [ H.tr_
                []
                [ H.th_ [] [text "Tidsrom"]
                , H.th_ [] [text "Grense"]
                , H.th_ [] [text "Minsteavstand"]
                ]
            ]
        , H.tbody_ [] (vanligeRader ++ [avslagRad])
        ]
    , H.p_
        [P.class_ "hint"]
        [text "Nattavslag: pumpen slås av kl. 23–07, da er kveldsgrensen dimensjonerende."]
    ]
  where
    k = m ^. valgtKlasse
    v = m ^. vinkelGrader
    avstandFor g = avstand standardR0 lp0 v g
    rader = [(tidsromNavn t, grense k t) | t <- [Dag, Kveld, Natt]]
    stoerst = maximum [avstandFor g | (_, g) <- rader]
    vanligeRader =
      [ rad navn g (avstandFor g == stoerst) "dimensjonerende"
      | (navn, g) <- rader
      ]
    avslagRad =
      rad "Natt m/ nattavslag" (grense k Kveld) True "dimensjonerende m/ nattavslag"
    rad navn g dim merke =
      H.tr_
        [P.class_ (if dim then "dim" else "")]
        [ H.td_ [] [text navn]
        , H.td_ [] [text (desimal g <> " dBA")]
        , H.td_
            []
            [ text (desimal (avstandFor g) <> " m")
            , if dim then H.span_ [P.class_ "merke"] [text merke] else text ""
            ]
        ]

-- | Modus B: lydnivå ved gitt avstand, innenfor/utenfor per tidsrom.
modusB :: Model -> Double -> View Model Action
modusB m lp0 =
  H.section_
    [P.class_ "panel"]
    [ H.h2_ [] [text "Lydnivå ved gitt avstand"]
    , H.div_
        [P.class_ "felt"]
        [ H.label_ [P.for_ "avstand"] [text "Avstand til nabo (meter)"]
        , H.input_
            [ P.id_ "avstand"
            , P.type_ "number"
            , P.min_ "0.5"
            , P.step_ "0.5"
            , P.value_ (m ^. avstandTekst)
            , E.onInput SettAvstand
            ]
        ]
    , case mr of
        Nothing -> H.p_ [P.class_ "feil"] [text "Oppgi gyldig avstand (> 0 m)."]
        Just r -> resultat r
    ]
  where
    k = m ^. valgtKlasse
    v = m ^. vinkelGrader
    mr = case parseDouble (m ^. avstandTekst) of
      Just r | r > 0 -> Just r
      _ -> Nothing
    resultat r =
      H.div_
        []
        [ H.p_
            []
            [ text "Beregnet lydnivå: "
            , H.strong_ [] [text (desimal nivaa <> " dBA")]
            ]
        , H.table_
            []
            [ H.thead_
                []
                [ H.tr_
                    []
                    [ H.th_ [] [text "Tidsrom"]
                    , H.th_ [] [text "Grense"]
                    , H.th_ [] [text "Status"]
                    ]
                ]
            , H.tbody_
                []
                ( [statusRad (tidsromNavn t) (grense k t) | t <- [Dag, Kveld, Natt]]
                    ++ [statusRad "Natt m/ nattavslag" (grense k Kveld)]
                )
            ]
        ]
      where
        nivaa = lydnivaa standardR0 lp0 v r
        statusRad navn g =
          let innenfor = nivaa <= g
           in H.tr_
                []
                [ H.td_ [] [text navn]
                , H.td_ [] [text (desimal g <> " dBA")]
                , H.td_
                    [P.class_ (if innenfor then "ok" else "for-hoyt")]
                    [text (if innenfor then "Innenfor" else "Utenfor")]
                ]
