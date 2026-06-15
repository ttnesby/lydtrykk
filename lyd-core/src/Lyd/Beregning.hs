-- | Lydberegning for varmepumpe-utedel etter NS 8175 (LAFmax,
-- uteoppholdsareal/åpent vindu). Forenklet frittfeltmodell (punktkilde,
-- invers kvadratlov) med retningskorreksjon for vifteorientering.
module Lyd.Beregning
  ( -- * Grenseverdier (NS 8175)
    Tidsrom (..),
    Lydklasse (..),
    grense,

    -- * Domenetyper
    Desibel (..),
    Meter (..),
    Vinkel,
    nyVinkel,
    rettFrem,
    grader,
    Montering (..),
    Kilde (..),
    standardR0,

    -- * Frittfeltmodell
    veggtillegg,
    effektivtKildenivaa,
    vinkelkorreksjon,
    lydnivaa,
    avstand,

    -- * Avstandstabell (vinkel × tidsrom × klasse)
    noenVinkler,
    AvstandsRad (..),
    avstandsTabell,

    -- * Flere kilder
    kumulativ,
  )
where

import Data.Maybe (mapMaybe)

-- | Tidsrom i døgnet slik NS 8175 deler dem inn:
-- dag 07–19, kveld 19–23, natt 23–07.
data Tidsrom = Dag | Kveld | Natt
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Lydklasse etter NS 8175. Klasse C er minstekrav, klasse B er anbefalt
-- (5 dBA strengere).
data Lydklasse = KlasseC | KlasseB
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Grenseverdi (LAFmax på uteoppholdsareal) for gitt lydklasse og tidsrom.
grense :: Lydklasse -> Tidsrom -> Desibel
grense KlasseC Dag = Desibel 45
grense KlasseC Kveld = Desibel 40
grense KlasseC Natt = Desibel 35
grense KlasseB tidsrom = Desibel (dBA (grense KlasseC tidsrom) - 5)

-- | Lydtrykknivå i dBA.
newtype Desibel = Desibel {dBA :: Double}
  deriving (Eq, Ord, Show)

-- | Avstand i meter.
newtype Meter = Meter {meter :: Double}
  deriving (Eq, Ord, Show)

-- | Vinkel relativt viftens hovedretning. Modellen gjelder 0–90°, og
-- invarianten håndheves av 'nyVinkel' — en verdi av denne typen er alltid
-- innenfor modellen.
newtype Vinkel = Vinkel Double
  deriving (Eq, Ord, Show)

-- | Konstruer en vinkel. Vinkler utenfor 0–90° er utenfor modellen og
-- gir 'Nothing'.
nyVinkel :: Double -> Maybe Vinkel
nyVinkel g
  | g >= 0 && g <= 90 = Just (Vinkel g)
  | otherwise = Nothing

-- | 0°: rett frem i viftens hovedretning.
rettFrem :: Vinkel
rettFrem = Vinkel 0

-- | Vinkelen i grader.
grader :: Vinkel -> Double
grader (Vinkel g) = g

-- | Hvordan utedelen er montert.
data Montering = Frittstaaende | Veggmontert
  deriving (Eq, Show)

-- | En lydkilde (utedel) med oppgitt nivå ved en referanseavstand.
data Kilde = Kilde
  { -- | lp0: oppgitt lydtrykknivå målt ved referanseavstanden
    oppgittNivaa :: Desibel,
    -- | r0: avstanden nivået er oppgitt for, normalt 1 m
    referanseavstand :: Meter,
    montering :: Montering
  }
  deriving (Eq, Show)

-- | Standard referanseavstand: 1 m.
standardR0 :: Meter
standardR0 = Meter 1

-- | Tillegg i dBA for veggmontert utedel (refleksjon).
veggtillegg :: Double
veggtillegg = 3

-- | Kildens effektive nivå: oppgitt nivå, pluss 'veggtillegg' hvis
-- utedelen er veggmontert.
effektivtKildenivaa :: Kilde -> Desibel
effektivtKildenivaa kilde = case montering kilde of
  Frittstaaende -> oppgittNivaa kilde
  Veggmontert -> Desibel (dBA (oppgittNivaa kilde) + veggtillegg)

-- | Retningskorreksjon i dBA: 0 opp til 45°, deretter lineært økende til
-- 5 dBA ved 90°. ('Vinkel'-invarianten garanterer at vi aldri er over 90°.)
vinkelkorreksjon :: Vinkel -> Double
vinkelkorreksjon (Vinkel v)
  | v > 45 = (v - 45) * 5 / 45
  | otherwise = 0

-- | Lydnivået fra kilden i gitt vinkel og avstand.
lydnivaa :: Kilde -> Vinkel -> Meter -> Desibel
lydnivaa kilde v (Meter r) =
  Desibel (lp0 - 20 * logBase 10 (r / r0) - vinkelkorreksjon v)
  where
    Desibel lp0 = effektivtKildenivaa kilde
    Meter r0 = referanseavstand kilde

-- | Avstanden fra kilden der lydnivået er som oppgitt, i gitt vinkel.
-- Invers av 'lydnivaa'.
avstand :: Kilde -> Vinkel -> Desibel -> Meter
avstand kilde v (Desibel lp) =
  Meter (r0 * 10 ** ((lp0 - lp - vinkelkorreksjon v) / 20))
  where
    Desibel lp0 = effektivtKildenivaa kilde
    Meter r0 = referanseavstand kilde

-- | Standard vinkelsett for avstandstabellen: rett frem, så 50–90° i steg
-- på 10°. Som i den verifiserte notatboken (@noenVinkler@).
noenVinkler :: [Vinkel]
noenVinkler = mapMaybe nyVinkel [0, 50, 60, 70, 80, 90]

-- | Én undertabell i avstandstabellen: et tidsrom med sin grenseverdi, og
-- nødvendig minsteavstand for hver vinkel i settet.
data AvstandsRad = AvstandsRad
  { arTidsrom :: Tidsrom,
    arGrense :: Desibel,
    arCeller :: [(Vinkel, Meter)]
  }
  deriving (Eq, Show)

-- | Avstandstabell for én lydklasse: én 'AvstandsRad' per tidsrom
-- (Dag, Kveld, Natt), der hver celle er minsteavstanden for å overholde
-- tidsrommets grense i den gitte vinkelen. Cellene bruker kildens effektive
-- nivå, så veggmontering slår inn her som ellers.
avstandsTabell :: Kilde -> [Vinkel] -> Lydklasse -> [AvstandsRad]
avstandsTabell kilde vinkler klasse =
  [ AvstandsRad
      { arTidsrom = t,
        arGrense = g,
        arCeller = [(v, avstand kilde v g) | v <- vinkler]
      }
  | t <- [Dag, Kveld, Natt],
    let g = grense klasse t
  ]

-- | Kumulativt lydnivå for flere kilder:
-- @ltot = 10 * log10 (sum [10**(l/10) | l <- ls])@.
-- For tom liste blir resultatet -Infinity (ingen kilder, ingen lyd).
kumulativ :: [Desibel] -> Desibel
kumulativ ls = Desibel (10 * logBase 10 (sum [10 ** (dBA l / 10) | l <- ls]))
