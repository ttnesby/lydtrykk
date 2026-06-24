-- | Lydberegning for varmepumpe-utedel etter NS 8175 (LAFmax,
-- uteoppholdsareal/åpent vindu). Forenklet frittfeltmodell (punktkilde,
-- invers kvadratlov) med retningskorreksjon for vifteorientering.
module Lyd.Beregning
  ( -- * Grenseverdier (NS 8175)
    Tidsrom (..),
    Lydklasse (..),
    klasseOffset,
    grenseC,
    grense,

    -- * Domenetyper
    Desibel (..),
    Meter (..),
    Vinkel,
    nyVinkel,
    vinkelKlampet,
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
    paakrevdDemping,

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

-- | Lydklasse etter NS 8175, fra strengest til mildest. Klasse C er
-- minstekrav; B er anbefalt (5 dBA strengere); A er streng/frivillig
-- (10 dBA strengere); B+ er en mellomklasse (7 dBA strengere). Rekkefølgen
-- følger visningen: strengeste klasse først.
data Lydklasse = KlasseA | KlasseBpluss | KlasseB | KlasseC
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Hvor mange dBA strengere enn Klasse C (minstekrav) en lydklasse er.
klasseOffset :: Lydklasse -> Double
klasseOffset KlasseA = 10
klasseOffset KlasseBpluss = 7
klasseOffset KlasseB = 5
klasseOffset KlasseC = 0

-- | Klasse C-grensen (minstekrav, LAFmax på uteoppholdsareal) per tidsrom.
grenseC :: Tidsrom -> Desibel
grenseC Dag = Desibel 45
grenseC Kveld = Desibel 40
grenseC Natt = Desibel 35

-- | Grenseverdi (LAFmax på uteoppholdsareal) for gitt lydklasse og tidsrom:
-- minstekravet (Klasse C) minus klassens 'klasseOffset'.
grense :: Lydklasse -> Tidsrom -> Desibel
grense klasse t = Desibel (dBA (grenseC t) - klasseOffset klasse)

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

-- | Bring en vilkårlig vinkel (grader) inn i modellens domene [0, 90].
-- Retningskorreksjonen er symmetrisk om hovedretningen, så fortegnet er
-- uvesentlig: en nabo 30° til venstre dempes som 30° til høyre — derfor
-- 'abs'. Vinkler bak utedelen (> 90°) behandles som siden (90°), i tråd med
-- antakelsen om at bakveggen står mot egen bolig. Brukes av kart-simulatoren.
vinkelKlampet :: Double -> Vinkel
vinkelKlampet = Vinkel . min 90 . abs

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
    montering :: Montering,
    -- | demping (dBA) fra kabinett/innebygging av utedelen; 0 hvis ingen
    kabinettDemping :: Double
  }
  deriving (Eq, Show)

-- | Standard referanseavstand: 1 m.
standardR0 :: Meter
standardR0 = Meter 1

-- | Tillegg i dBA for veggmontert utedel (refleksjon).
veggtillegg :: Double
veggtillegg = 3

-- | Kildens effektive nivå: oppgitt nivå, pluss 'veggtillegg' hvis utedelen
-- er veggmontert, minus eventuell 'kabinettDemping'.
effektivtKildenivaa :: Kilde -> Desibel
effektivtKildenivaa kilde =
  Desibel (dBA (oppgittNivaa kilde) + vegg - kabinettDemping kilde)
  where
    vegg = case montering kilde of
      Frittstaaende -> 0
      Veggmontert -> veggtillegg

-- | Retningskorreksjon i dBA: glatt cosinus-karakteristikk, 0 dB rett frem
-- og 5 dBA demping ved 90°. ('Vinkel'-invarianten garanterer 0–90°, der
-- @cos@ er ikke-negativ, så korreksjonen ligger i [0, 5].)
vinkelkorreksjon :: Vinkel -> Double
vinkelkorreksjon (Vinkel v) = 5 * (1 - cos (v * pi / 180))

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

-- | Hvor mye kabinett-demping (dBA) som trengs for at lydnivået i gitt vinkel
-- og avstand akkurat når 'grenseverdi'. Beregnes mot kilden uten dagens
-- kabinett, så svaret er det totale dempingsbehovet (0 hvis grensen alt er
-- oppfylt uten kabinett).
paakrevdDemping :: Kilde -> Vinkel -> Meter -> Desibel -> Double
paakrevdDemping kilde v r (Desibel grenseverdi) =
  max 0 (dBA (lydnivaa utenKabinett v r) - grenseverdi)
  where
    utenKabinett = kilde {kabinettDemping = 0}

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
