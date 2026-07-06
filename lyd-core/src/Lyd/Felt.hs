{-# LANGUAGE BangPatterns #-}

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
    forenkleToleranseM,
    forenkletPolygon,

    -- * Fasadepunkter (verste punkt per husrekke)
    fasadeOffsetM,
    fasadePunktAvstandM,
    fasadepunkter,
    versteFasadepunkt,

    -- * Lydfelt
    nivaaIPunkt,
    nivaaIPunktSkjermet,
    Stripe (..),
    rutenettStripe,
    rutenettStripeSkjermet,
  )
where

import Data.Fixed (mod')
import Data.List (foldl', maximumBy)
import Data.Ord (comparing)
import qualified Data.Vector.Storable as VS
import qualified Data.Vector.Unboxed as VU
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

-- | Toleranse (m) for polygonforenklingen felt-funksjonene gjør før
-- maskering og sikttest. Reelt digitaliserte husrekker har 60–300 hjørner,
-- mens både stråletesten og sikttesten er O(kanter) per celle — forenklingen
-- krymper kantlistene ~10× og flytter geometrien høyst 0,2 m, godt innenfor
-- modellstøyen til det flate, konservative 'skjermingDb'-fradraget.
forenkleToleranseM :: Double
forenkleToleranseM = 0.2

-- | Douglas–Peucker for lukket polygon: fjern hjørner som avviker mindre enn
-- toleransen fra en rettere kant. Ringen deles ved hjørnet lengst fra første
-- hjørne, og de to kjedene forenkles hver for seg (endepunktene beholdes).
-- Hjørnene i resultatet er en delmengde av originalens, i samme rekkefølge,
-- og et rektangel er uendret. Gir aldri færre enn 3 hjørner: kollapser
-- forenklingen (nær-lineært polygon), returneres originalen uendret.
forenkletPolygon :: Double -> Polygon -> Polygon
forenkletPolygon tol poly
  | length poly < 4 = poly
  | delIndeks == 0 = poly -- degenerert: alle hjørner sammenfaller med første
  | length resultat >= 3 = resultat
  | otherwise = poly
  where
    v0 = head poly
    kvadrertAvstand (Punkt x y) =
      let Punkt x0 y0 = v0 in (x - x0) * (x - x0) + (y - y0) * (y - y0)
    delIndeks =
      fst (maximumBy (comparing snd) (zip [(0 :: Int) ..] (map kvadrertAvstand poly)))
    (fram, bak) = splitAt delIndeks poly
    resultat = init (dp (fram ++ [head bak])) ++ init (dp (bak ++ [v0]))
    -- klassisk Douglas–Peucker på en åpen kjede (begge endepunktene beholdes)
    dp ps
      | length ps <= 2 = ps
      | stoersteAvvik <= tol = [a, b]
      | otherwise = init (dp (take (verstIndeks + 1) ps)) ++ dp (drop verstIndeks ps)
      where
        a = head ps
        b = last ps
        (stoersteAvvik, verstIndeks) =
          maximum
            [ (punktSegmentAvstand p (a, b), i)
            | (i, p) <- zip [(1 :: Int) ..] (init (drop 1 ps))
            ]

-- | Kantene i polygonet, siste hjørne koblet tilbake til første.
kanter :: Polygon -> [(Punkt, Punkt)]
kanter ps = zip ps (drop 1 ps ++ take 1 ps)

-- | Punkt-i-polygon med stråletest (partall\/oddetall-regelen, tåler konkave
-- polygoner). Punkter nøyaktig på kanten er udefinert terreng — kalles med
-- rutenettceller og pumpeposisjoner, der 'egetPolygon'-marginen fanger
-- kanttilfellet som betyr noe.
punktIPolygon :: Polygon -> Punkt -> Bool
punktIPolygon poly = punktIKanter (kanter poly)

-- | Stråletesten mot en ferdigbygd kantliste — spesifikasjonsstien; de varme
-- stiene ('rutenettStripeSkjermet'\/'versteFasadepunkt') bruker
-- 'punktIKanterV' mot 'Hinder'-vektorene i stedet.
punktIKanter :: [(Punkt, Punkt)] -> Punkt -> Bool
punktIKanter ks (Punkt x y) = odd (length kryssedeKanter)
  where
    kryssedeKanter =
      [ ()
      | (Punkt x1 y1, Punkt x2 y2) <- ks,
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
segmentKrysserPolygon a b poly = segmentKrysserKanter a b (kanter poly)

-- | Som 'segmentKrysserPolygon', mot en ferdigbygd kantliste
-- (spesifikasjonsstien; de varme stiene bruker 'segmentKrysserKanterV').
segmentKrysserKanter :: Punkt -> Punkt -> [(Punkt, Punkt)] -> Bool
segmentKrysserKanter a b = any (uncurry (segmenterKrysser a b))

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
-- lyd diffrakterer over tak og rundt rekkeender. Polygonene forenkles først
-- med 'forenkletPolygon' — samme forenkling som den varme stien
-- ('rutenettStripeSkjermet'\/'nivaaMedHindre') gjør, så de to stiene er
-- celle for celle identiske. Returnerer dBA som Double siden NaN ikke er et
-- lydnivå.
nivaaIPunktSkjermet :: Kilde -> [PlassertKilde] -> [Polygon] -> Punkt -> Double
nivaaIPunktSkjermet kilde plasserte polygoner pt
  | any (`punktIPolygon` pt) gyldige = 0 / 0 -- NaN: maskert celle
  | otherwise = dBA (kumulativ [skjermetBidrag p | p <- plasserte])
  where
    gyldige =
      map (forenkletPolygon forenkleToleranseM) (filter ((>= 3) . length) polygoner)
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
-- stripe med ett kall i stedet for celler·(kilder+1) enkeltkall. Resultatet
-- er en Storable-vektor (sammenhengende, pinnet minne) slik at wasm-siden
-- kan kopiere hele stripen ut av lineærminnet i én operasjon i stedet for
-- ett JS-kall per celle. Samme regnestykke som 'rutenettStripeSkjermet'
-- uten polygoner (pinnes av en test).
rutenettStripe :: Kilde -> [PlassertKilde] -> Stripe -> VS.Vector Double
rutenettStripe kilde plasserte = rutenettStripeSkjermet kilde plasserte []

-- | 'rutenettStripe' med husrekke-polygoner: hver celle regnes som i
-- 'nivaaIPunktSkjermet' (NaN-maskering + skjermingsfradrag), radmajor.
-- Polygonforenklingen, bounding-boksene og «eget polygon»-unntaket per kilde
-- regnes én gang for stripen, ikke per celle — resultatet er identisk med å
-- kalle 'nivaaIPunktSkjermet' per celle (pinnes av en test).
rutenettStripeSkjermet :: Kilde -> [PlassertKilde] -> [Polygon] -> Stripe -> VS.Vector Double
rutenettStripeSkjermet kilde plasserte polygoner stripe =
  VS.generate (max 0 rader * max 0 kolonner) celleVerdi
  where
    rader = stRadSlutt stripe - stRadStart stripe
    kolonner = stKolonner stripe
    Meter celle = stCelleM stripe
    hindre = lagHindre polygoner
    kildeHindre = lagKildeHindre hindre plasserte
    celleVerdi i =
      let (rad, kol) = i `divMod` kolonner
       in nivaaMedHindre
            kilde
            kildeHindre
            hindre
            (Punkt (fromIntegral kol * celle) (fromIntegral (stRadStart stripe + rad) * celle))

-- | Polygon med forhåndsberegnede kanter og bounding-boks. Kantene ligger i
-- en flat, unboxed vektor @(x1, y1, x2, y2)@: de varme testene
-- ('punktIKanterV'\/'segmentKrysserKanterV') går da som stramme løkker uten
-- pekerjaging — listetraverseringen og allokeringen per celle×polygon
-- dominerte kjøretiden med tett digitaliserte polygoner (59–304 hjørner per
-- reell husrekke, før forenkling). Boksen er forfilteret som gjør sikttesten
-- billig når kilde og punkt ligger på samme side av rekka. Polygonet
-- ('hiPoly') er allerede forenklet når 'lagHindre' har bygget hinderet.
data Hinder = Hinder
  { hiPoly :: Polygon,
    hiKanter :: !(VU.Vector (Double, Double, Double, Double)),
    hiMinX, hiMinY, hiMaxX, hiMaxY :: !Double
  }

tilHinder :: Polygon -> Hinder
tilHinder poly =
  Hinder
    poly
    (VU.fromList [(pX a, pY a, pX b, pY b) | (a, b) <- kanter poly])
    (minimum xs)
    (minimum ys)
    (maximum xs)
    (maximum ys)
  where
    xs = map pX poly
    ys = map pY poly

-- | Bygg hindrene for en stripe\/et fasadekall: filtrer degenererte
-- polygoner, forenkle ('forenkletPolygon' — samme forenkling som
-- spesifikasjonsstien 'nivaaIPunktSkjermet' gjør), og forhåndsberegn
-- kantvektor + bounding-boks.
lagHindre :: [Polygon] -> [Hinder]
lagHindre =
  map (tilHinder . forenkletPolygon forenkleToleranseM) . filter ((>= 3) . length)

-- | Per kilde: hindrene som ikke er kildens eget hus ('egetPolygon') —
-- regnes én gang, ikke per punkt.
lagKildeHindre :: [Hinder] -> [PlassertKilde] -> [(PlassertKilde, [Hinder])]
lagKildeHindre hindre plasserte =
  [ (p, [h | h <- hindre, not (egetPolygon (pkPos p) (hiPoly h))])
  | p <- plasserte
  ]

-- | Stråletesten ('punktIKanter') mot den flate kantvektoren — samme
-- partall\/oddetall-regel, som veksle-fold i stedet for listetelling.
punktIKanterV :: VU.Vector (Double, Double, Double, Double) -> Punkt -> Bool
punktIKanterV ks (Punkt x y) = VU.foldl' vend False ks
  where
    vend inne (x1, y1, x2, y2)
      | (y1 > y) /= (y2 > y) && x < (x2 - x1) * (y - y1) / (y2 - y1) + x1 = not inne
      | otherwise = inne

-- | 'segmentKrysserKanter' mot den flate kantvektoren.
segmentKrysserKanterV :: Punkt -> Punkt -> VU.Vector (Double, Double, Double, Double) -> Bool
segmentKrysserKanterV a b =
  VU.any (\(x1, y1, x2, y2) -> segmenterKrysser a b (Punkt x1 y1) (Punkt x2 y2))

-- | Den varme stien: samme regnestykke som 'nivaaIPunktSkjermet' (pinnes av
-- en test), men mot ferdigbygde 'Hinder' — delt mellom rutenettet og
-- fasadepunktene. Kildebidragene akkumuleres i en strikt fold i stedet for å
-- bygge en liste per celle; samme venstre-til-høyre-rekkefølge som listesummen
-- i 'kumulativ', så resultatet er bit-identisk.
nivaaMedHindre :: Kilde -> [(PlassertKilde, [Hinder])] -> [Hinder] -> Punkt -> Double
nivaaMedHindre kilde kildeHindre hindre pt
  | any (\h -> iBoks h pt && punktIKanterV (hiKanter h) pt) hindre = 0 / 0
  | otherwise = 10 * logBase 10 (foldl' leggTil 0 kildeHindre)
  where
    leggTil !acc (p, hs) =
      let Desibel l = punktBidrag kilde p pt
          blokkert h =
            boksTreffes (pkPos p) pt h
              && segmentKrysserKanterV (pkPos p) pt (hiKanter h)
          fradrag = if any blokkert hs then skjermingDb else 0
       in acc + 10 ** ((l - fradrag) / 10)

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

-- Fasadepunkter --------------------------------------------------------------

-- | Fasadepunktenes avstand utenfor fasaden (m). Grenseverdiene gjelder
-- utenfor fasade; 1 m holder punktene klar av eget polygon (streifende
-- siktlinjer) uten å flytte dem merkbart fra vedtektstekstens «ved fasaden».
fasadeOffsetM :: Double
fasadeOffsetM = 1

-- | Største avstand mellom to nabo-fasadepunkter langs en kant (m).
fasadePunktAvstandM :: Double
fasadePunktAvstandM = 1

-- | Prøvepunkter langs polygonets omkrets: hver kant deles i steg på høyst
-- 'fasadePunktAvstandM', og hvert punkt skyves 'fasadeOffsetM' ut fra
-- fasaden. Kantens sluttpunkt utelates — hjørnet dekkes av neste kants
-- startpunkt, så tett digitaliserte polygoner (mange korte kanter) ikke gir
-- doble punkter. Utover-retningen finnes ved å teste kandidaten mot
-- polygonet, så hjørnerekkefølgen (med/mot klokka) spiller ingen rolle.
-- Degenererte polygoner gir []. Punktene ligger langs det *uforenklede*
-- polygonet — markøren skal treffe den tegnede fasaden, ikke den forenklede
-- beregningsgeometrien.
fasadepunkter :: Polygon -> [Punkt]
fasadepunkter poly
  | length poly < 3 = []
  | otherwise = concatMap kantpunkter (kanter poly)
  where
    kantpunkter (Punkt ax ay, Punkt bx by)
      | len <= 0 = []
      | otherwise =
          [ utenfor (ax + t * dx) (ay + t * dy)
          | i <- [0 .. steg - 1],
            let t = fromIntegral i / fromIntegral steg
          ]
      where
        dx = bx - ax
        dy = by - ay
        len = sqrt (dx * dx + dy * dy)
        steg = max 1 (ceiling (len / fasadePunktAvstandM)) :: Int
        -- normalen (dy,-dx)/len; velg siden som havner utenfor polygonet
        utenfor px py =
          let kand = Punkt (px + fasadeOffsetM * dy / len) (py - fasadeOffsetM * dx / len)
           in if punktIPolygon poly kand
                then Punkt (px - fasadeOffsetM * dy / len) (py + fasadeOffsetM * dx / len)
                else kand

-- | Verste (høyeste) kumulative nivå blant polygonets fasadepunkter —
-- operasjonaliseringen av «verste punkt ved naboens fasade». Nivået regnes
-- med 'nivaaIPunktSkjermet' mot 'polygoner' (send inn alle husrekkene:
-- rekka skjermer sin egen bakside, og punkter som havner inne i en annen
-- rekke maskeres/hoppes over; send @[]@ for uskjermet nivå). Ingen kilder
-- gir -Infinity som nivå; 'Nothing' bare når polygonet er degenerert eller
-- alle punktene er maskert.
versteFasadepunkt :: Kilde -> [PlassertKilde] -> [Polygon] -> Polygon -> Maybe (Punkt, Double)
versteFasadepunkt kilde plasserte polygoner poly =
  case gyldige of
    [] -> Nothing
    xs -> Just (maximumBy (comparing snd) xs)
  where
    -- samme varme sti som rutenettet ('nivaaMedHindre') — hindrene bygges én
    -- gang for alle fasadepunktene, ikke per punkt
    hindre = lagHindre polygoner
    kildeHindre = lagKildeHindre hindre plasserte
    gyldige =
      [ (pt, niv)
      | pt <- fasadepunkter poly,
        let niv = nivaaMedHindre kilde kildeHindre hindre pt,
        not (isNaN niv)
      ]
