-- | Lydberegning for varmepumpe-utedel etter NS 8175 (LAFmax,
-- uteoppholdsareal/åpent vindu). Forenklet frittfeltmodell (punktkilde,
-- invers kvadratlov) med retningskorreksjon for vifteorientering.
module Lyd.Beregning
  ( -- * Grenseverdier (NS 8175)
    Tidsrom (..),
    Lydklasse (..),
    grense,

    -- * Frittfeltmodell
    standardR0,
    vinkelkorreksjon,
    lydnivaa,
    avstand,

    -- * Tillegg og modi
    veggtillegg,
    effektivtKildenivaa,
    kumulativ,
  )
where

-- | Tidsrom i døgnet slik NS 8175 deler dem inn:
-- dag 07–19, kveld 19–23, natt 23–07.
data Tidsrom = Dag | Kveld | Natt
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Lydklasse etter NS 8175. Klasse C er minstekrav, klasse B er anbefalt
-- (5 dBA strengere).
data Lydklasse = KlasseC | KlasseB
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Grenseverdi i dBA (LAFmax på uteoppholdsareal) for gitt lydklasse og
-- tidsrom.
grense :: Lydklasse -> Tidsrom -> Double
grense KlasseC Dag = 45
grense KlasseC Kveld = 40
grense KlasseC Natt = 35
grense KlasseB tidsrom = grense KlasseC tidsrom - 5

-- | Standard referanseavstand: 1 m.
standardR0 :: Double
standardR0 = 1

-- | Retningskorreksjon i dBA for vinkel @v@ (grader) relativt viftens
-- hovedretning. 0 opp til 45°, deretter lineært økende til 5 dBA ved 90°.
-- Vinkler over 90° er utenfor modellen og gis ingen ekstra korreksjon her;
-- UI skal begrense input til 0–90.
vinkelkorreksjon :: Double -> Double
vinkelkorreksjon v
  | v > 45 && v <= 90 = (v - 45) * 5 / 45
  | otherwise = 0

-- | Lydnivå (dBA) i avstand @r@ og vinkel @v@, gitt referansenivå @lp0@
-- målt ved @r0@.
lydnivaa ::
  -- | r0: referanseavstand (m)
  Double ->
  -- | lp0: kildenivå ved r0 (dBA)
  Double ->
  -- | v: vinkel (grader, 0–90)
  Double ->
  -- | r: avstand (m)
  Double ->
  Double
lydnivaa r0 lp0 v r = lp0 - 20 * logBase 10 (r / r0) - vinkelkorreksjon v

-- | Avstand (m) der lydnivået er @lp@, gitt referansenivå @lp0@ ved @r0@
-- og vinkel @v@. Invers av 'lydnivaa'.
avstand ::
  -- | r0: referanseavstand (m)
  Double ->
  -- | lp0: kildenivå ved r0 (dBA)
  Double ->
  -- | v: vinkel (grader, 0–90)
  Double ->
  -- | lp: mål-lydnivå (dBA)
  Double ->
  Double
avstand r0 lp0 v lp = r0 * 10 ** ((lp0 - lp - vinkelkorreksjon v) / 20)

-- | Tillegg for veggmontert utedel (refleksjon): +3 dBA på kildenivået.
veggtillegg :: Double
veggtillegg = 3

-- | Effektivt kildenivå gitt oppgitt nivå og om utedelen er veggmontert.
effektivtKildenivaa :: Bool -> Double -> Double
effektivtKildenivaa veggmontert lp0
  | veggmontert = lp0 + veggtillegg
  | otherwise = lp0

-- | Kumulativt lydnivå for flere kilder:
-- @ltot = 10 * log10 (sum [10**(l/10) | l <- ls])@.
-- For tom liste blir resultatet -Infinity (ingen kilder, ingen lyd).
kumulativ :: [Double] -> Double
kumulativ ls = 10 * logBase 10 (sum [10 ** (l / 10) | l <- ls])
