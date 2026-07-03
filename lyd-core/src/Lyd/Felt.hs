-- | Lydfelt over et rutenett i et lokalt plan — regnekjernen bak
-- kart-simulatorens rutenett (lydnivakart.html\/gridWorker.js). Plangeometrien
-- her (retning 0° = nord, medurs; minsteavstand 1 m) er simulator-policy,
-- ikke NS 8175-domene, og holdes derfor utenfor "Lyd.Beregning".
module Lyd.Felt
  ( -- * Plangeometri
    Punkt (..),
    PlassertKilde (..),
    retningsavvik,

    -- * Lydfelt
    nivaaIPunkt,
    Stripe (..),
    rutenettStripe,
  )
where

import Data.Fixed (mod')
import Lyd.Beregning

-- | Punkt i det lokale planet: meter øst (x) og nord (y) fra rutenettets
-- SV-hjørne (samme konvensjon som toLocal i gridGeo.js).
data Punkt = Punkt
  { pX, pY :: {-# UNPACK #-} !Double
  }
  deriving (Eq, Show)

-- | En kilde plassert i planet med vifteretning i grader (0° = nord, medurs
-- — kartets bearing-konvensjon, ikke 'Vinkel' som er relativ til viften).
data PlassertKilde = PlassertKilde
  { pkPos :: {-# UNPACK #-} !Punkt,
    pkRetning :: !Double
  }
  deriving (Eq, Show)

-- | Vinkelavvik 0–180° mellom kildens vifteretning og retningen kilde→punkt.
-- Samme regnestykke som gridWorker.js brukte:
-- @abs(((brgTilPunkt - retning + 540) % 360) - 180)@. 'mod'' tåler også
-- retninger utenfor 0–360 (JS-uttrykkets @+540@ sørget for positiv operand).
retningsavvik :: PlassertKilde -> Punkt -> Double
retningsavvik (PlassertKilde (Punkt kx ky) retning) (Punkt x y) =
  abs (((brgTilPunkt - retning + 540) `mod'` 360) - 180)
  where
    brgTilPunkt = (atan2 (x - kx) (y - ky) * 180 / pi + 360) `mod'` 360

-- | Kumulativt lydnivå i et punkt fra alle plasserte kilder. Alle kildene
-- deler samme effektive nivå ('Kilde' beskriver typen utedel, 'PlassertKilde'
-- hvor de står). Avstanden klampes nedad til 1 m — nærmere enn referanse-
-- avstanden gir frittfeltmodellen urimelig høye verdier. Ingen kilder gir
-- -Infinity (via 'kumulativ').
nivaaIPunkt :: Kilde -> [PlassertKilde] -> Punkt -> Desibel
nivaaIPunkt kilde plasserte pt@(Punkt x y) = kumulativ (map bidrag plasserte)
  where
    bidrag p@(PlassertKilde (Punkt kx ky) _) =
      let dx = x - kx
          dy = y - ky
          r = max (sqrt (dx * dx + dy * dy)) 1
       in lydnivaa kilde (vinkelKlampet (retningsavvik p pt)) (Meter r)

-- | En rad-stripe av rutenettet: radene [radStart, radSlutt) over
-- 'stKolonner' kolonner med kvadratiske celler på 'stCelleM'. Celle
-- (rad, kolonne) ligger i @Punkt (kolonne·celle) (rad·celle)@.
data Stripe = Stripe
  { stRadStart, stRadSlutt, stKolonner :: !Int,
    stCelleM :: !Meter
  }
  deriving (Eq, Show)

-- | Kumulativt lydnivå (dBA) for hver celle i stripen, radmajor —
-- @(stRadSlutt - stRadStart) · stKolonner@ verdier. Dette er hele
-- rutenett-løkken fra gridWorker.js, slik at WASM-siden kan svare på én
-- stripe med ett kall i stedet for celler·(kilder+1) enkeltkall.
rutenettStripe :: Kilde -> [PlassertKilde] -> Stripe -> [Double]
rutenettStripe kilde plasserte stripe =
  [ dBA (nivaaIPunkt kilde plasserte (Punkt (fromIntegral kol * celle) (fromIntegral rad * celle)))
  | rad <- [stRadStart stripe .. stRadSlutt stripe - 1],
    kol <- [0 .. stKolonner stripe - 1]
  ]
  where
    Meter celle = stCelleM stripe
