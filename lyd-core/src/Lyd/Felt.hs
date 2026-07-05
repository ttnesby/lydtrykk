-- | Lydfelt over et rutenett i et lokalt plan — regnekjernen bak
-- kart-simulatorens rutenett (lydnivakart.html\/gridWorker.js). Plangeometrien
-- her (retning 0° = nord, medurs; minsteavstand 1 m) er simulator-policy,
-- ikke NS 8175-domene, og holdes derfor utenfor "Lyd.Beregning".
module Lyd.Felt
  ( -- * Plangeometri
    Punkt (..),
    PlassertKilde (..),
    retningsavvik,

    -- * Husrekke-polygoner og skjerming
    Polygon,
    punktIPolygon,
    segmentKrysserPolygon,
    egetPolygon,
    skjermingDb,

    -- * Lydfelt
    nivaaIPunkt,
    nivaaIPunktSkjermet,
    Stripe (..),
    rutenettStripe,
    rutenettStripeSkjermet,
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

-- Husrekke-polygoner og skjerming --------------------------------------------

-- | Lukket polygon i planet (hjørnene i rekkefølge, uten duplisert
-- sluttpunkt) — en husrekke sett ovenfra, i samme lokale koordinater som
-- 'Punkt'. Polygoner med færre enn 3 hjørner behandles som ikke-eksisterende
-- av felt-funksjonene under (de kan verken inneholde punkter eller skjerme).
type Polygon = [Punkt]

-- | Fast skjermingsfradrag (dB) per kildebidrag med brutt siktlinje.
-- Bevisst konservativt: en reell husrekke gir typisk 15–25 dB (ISO 9613-2
-- kapper enkeltdiffraksjon på 20 dB), og marginen dekker også at modellen
-- ikke regner refleksjoner mellom fasader (~+3 dB nær fasade) —
-- nettomodellen skal aldri underestimere nivået.
skjermingDb :: Double
skjermingDb = 10

-- | Kantene i polygonet, siste hjørne koblet tilbake til første.
kanter :: Polygon -> [(Punkt, Punkt)]
kanter ps = zip ps (drop 1 ps ++ take 1 ps)

-- | Punkt-i-polygon med stråletest (partall\/oddetall-regelen, tåler konkave
-- polygoner). Punkter nøyaktig på kanten er udefinert terreng — kalles med
-- rutenettceller og pumpeposisjoner, der 'egetPolygon'-marginen fanger
-- kanttilfellet som betyr noe.
punktIPolygon :: Polygon -> Punkt -> Bool
punktIPolygon poly (Punkt x y) = odd (length kryssedeKanter)
  where
    kryssedeKanter =
      [ ()
      | (Punkt x1 y1, Punkt x2 y2) <- kanter poly,
        (y1 > y) /= (y2 > y),
        x < (x2 - x1) * (y - y1) / (y2 - y1) + x1
      ]

-- | Ekte kryssing (segmentene deler et indre punkt). Berøring i et endepunkt
-- og kollinear overlapp regnes bevisst IKKE som kryssing: en stråle som
-- streifer et hjørne eller sklir langs en fasade gir ingen skjerming — den
-- konservative siden av tvilen, og samtidig det som slipper lyd forbi
-- rekkeendene, der en binær sikttest ellers overestimerer skjermingen.
segmenterKrysser :: Punkt -> Punkt -> Punkt -> Punkt -> Bool
segmenterKrysser a b c d =
  kryss a b c * kryss a b d < 0 && kryss c d a * kryss c d b < 0
  where
    kryss (Punkt px py) (Punkt qx qy) (Punkt rx ry) =
      (qx - px) * (ry - py) - (qy - py) * (rx - px)

-- | Krysser segmentet a→b noen av polygonets kanter? (Rent geometrisk test —
-- «eget polygon»-unntaket og bounding-boks-forfilteret ligger i
-- felt-funksjonene som bruker den.)
segmentKrysserPolygon :: Punkt -> Punkt -> Polygon -> Bool
segmentKrysserPolygon a b poly = any (uncurry (segmenterKrysser a b)) (kanter poly)

-- | Er polygonet kildens «eget» hus? En pumpe plassert med kartklikk kan
-- lande numerisk innenfor (eller helt inntil) fasadepolygonet den står på —
-- da ville siktlinja til alt krysse eget hus og gi fradrag overalt. Kilder i
-- polygonet eller innen 1 m fra kanten får derfor polygonet unntatt fra sin
-- sikttest.
egetPolygon :: Punkt -> Polygon -> Bool
egetPolygon p poly =
  punktIPolygon poly p || any ((< 1) . punktSegmentAvstand p) (kanter poly)

punktSegmentAvstand :: Punkt -> (Punkt, Punkt) -> Double
punktSegmentAvstand (Punkt px py) (Punkt ax ay, Punkt bx by) =
  sqrt ((px - nx) * (px - nx) + (py - ny) * (py - ny))
  where
    dx = bx - ax
    dy = by - ay
    l2 = dx * dx + dy * dy
    t
      | l2 == 0 = 0
      | otherwise = max 0 (min 1 (((px - ax) * dx + (py - ay) * dy) / l2))
    nx = ax + t * dx
    ny = ay + t * dy

-- Lydfelt ---------------------------------------------------------------------

-- | Kumulativt lydnivå i et punkt fra alle plasserte kilder. Alle kildene
-- deler samme effektive nivå ('Kilde' beskriver typen utedel, 'PlassertKilde'
-- hvor de står). Avstanden klampes nedad til 1 m — nærmere enn referanse-
-- avstanden gir frittfeltmodellen urimelig høye verdier. Ingen kilder gir
-- -Infinity (via 'kumulativ').
nivaaIPunkt :: Kilde -> [PlassertKilde] -> Punkt -> Desibel
nivaaIPunkt kilde plasserte pt = kumulativ [punktBidrag kilde p pt | p <- plasserte]

-- | Én kildes bidrag i et punkt (avstanden klampet nedad til 1 m).
punktBidrag :: Kilde -> PlassertKilde -> Punkt -> Desibel
punktBidrag kilde p@(PlassertKilde (Punkt kx ky) _) pt@(Punkt x y) =
  let dx = x - kx
      dy = y - ky
      r = max (sqrt (dx * dx + dy * dy)) 1
   in lydnivaa kilde (vinkelKlampet (retningsavvik p pt)) (Meter r)

-- | Som 'nivaaIPunkt', men med husrekke-polygoner: et punkt inne i et polygon
-- gir NaN — utendørs grenseverdier gjelder utenfor fasade, så cellen maskeres
-- og konturalgoritmen bryter der. Ellers får hvert kildebidrag med brutt
-- siktlinje ('segmentKrysserPolygon', minus kildens eget hus via
-- 'egetPolygon') det faste fradraget 'skjermingDb' — aldri null bidrag, for
-- lyd diffrakterer over tak og rundt rekkeender. Returnerer dBA som Double
-- siden NaN ikke er et lydnivå.
nivaaIPunktSkjermet :: Kilde -> [PlassertKilde] -> [Polygon] -> Punkt -> Double
nivaaIPunktSkjermet kilde plasserte polygoner pt
  | any (`punktIPolygon` pt) gyldige = 0 / 0 -- NaN: maskert celle
  | otherwise = dBA (kumulativ [skjermetBidrag p | p <- plasserte])
  where
    gyldige = filter ((>= 3) . length) polygoner
    skjermetBidrag p =
      let Desibel l = punktBidrag kilde p pt
       in Desibel (l - fradrag (pkPos p))
    fradrag pos
      | any (blokkerer pos) gyldige = skjermingDb
      | otherwise = 0
    blokkerer pos poly =
      not (egetPolygon pos poly) && segmentKrysserPolygon pos pt poly

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

-- | 'rutenettStripe' med husrekke-polygoner: hver celle regnes som i
-- 'nivaaIPunktSkjermet' (NaN-maskering + skjermingsfradrag), radmajor.
-- Bounding-boksene og «eget polygon»-unntaket per kilde regnes én gang for
-- stripen, ikke per celle — resultatet er identisk med å kalle
-- 'nivaaIPunktSkjermet' per celle (pinnes av en test). Uten polygoner er
-- resultatet identisk med 'rutenettStripe'.
rutenettStripeSkjermet :: Kilde -> [PlassertKilde] -> [Polygon] -> Stripe -> [Double]
rutenettStripeSkjermet kilde plasserte polygoner stripe =
  [ verdi (Punkt (fromIntegral kol * celle) (fromIntegral rad * celle))
  | rad <- [stRadStart stripe .. stRadSlutt stripe - 1],
    kol <- [0 .. stKolonner stripe - 1]
  ]
  where
    Meter celle = stCelleM stripe
    hindre = map tilHinder (filter ((>= 3) . length) polygoner)
    -- per kilde: hindrene som ikke er kildens eget hus
    kildeHindre =
      [ (p, [h | h <- hindre, not (egetPolygon (pkPos p) (hiPoly h))])
      | p <- plasserte
      ]
    verdi pt
      | any (\h -> iBoks h pt && punktIPolygon (hiPoly h) pt) hindre = 0 / 0
      | otherwise = dBA (kumulativ [bidrag p hs | (p, hs) <- kildeHindre])
      where
        bidrag p hs =
          let Desibel l = punktBidrag kilde p pt
              blokkert h =
                boksTreffes (pkPos p) pt h
                  && segmentKrysserPolygon (pkPos p) pt (hiPoly h)
           in Desibel (l - if any blokkert hs then skjermingDb else 0)

-- | Polygon med forhåndsberegnet bounding-boks — forfilteret som gjør
-- sikttesten billig når kilde og celle ligger på samme side av rekka.
data Hinder = Hinder
  { hiPoly :: Polygon,
    hiMinX, hiMinY, hiMaxX, hiMaxY :: !Double
  }

tilHinder :: Polygon -> Hinder
tilHinder poly = Hinder poly (minimum xs) (minimum ys) (maximum xs) (maximum ys)
  where
    xs = map pX poly
    ys = map pY poly

iBoks :: Hinder -> Punkt -> Bool
iBoks h (Punkt x y) =
  x >= hiMinX h && x <= hiMaxX h && y >= hiMinY h && y <= hiMaxY h

-- | Overlapper segmentets bounding-boks polygonets?
boksTreffes :: Punkt -> Punkt -> Hinder -> Bool
boksTreffes (Punkt ax ay) (Punkt bx by) h =
  min ax bx <= hiMaxX h
    && max ax bx >= hiMinX h
    && min ay by <= hiMaxY h
    && max ay by >= hiMinY h
