# Overgang til cosinus-retningskorreksjon

> Status: **ikke besluttet**. Lineær rampe beholdes under testing; cosinus
> vurderes før publisering. Dette dokumentet er sjekklisten for byttet, og
> spesifiserer nøyaktig hvilke fasit-tall som må skaffes først.

## Bakgrunn

Dagens modell bruker en **lineær rampe**: ingen retningskorreksjon under 45°,
deretter lineært til 5 dB demping ved 90°.

```
korr(v) = (v − 45)·5/45   for 45° < v ≤ 90°, ellers 0
```

Cosinus-alternativet er en glatt retningskarakteristikk uten knekk ved 45°:

```
D(v) = 5 · (1 − cos v)    for v ∈ [0°, 90°]
D(v) = 5                  for v > 90°   (bak = som siden)
```

Forskjellen er ≤ ~1,5 dB (størst ved 45°), men cosinus gir en rundere lobe og
ingen vilkårlig 45°-klippe. Begge er forenklinger; «5 dB ved 90°» er like
udokumentert i begge.

Byttet er ikke gratis: **hele tallfasiten må regenereres**, og NS 8175-siden
endres (vinkelslider 45–90° → 0–90°, hjelpetekst, golden-verdier i testene).
Simulatoren trenger ingen JS-endring — den arver modellen automatisk via WASM.

## Det jeg trenger fra deg (test-tall)

Regn alt i **notatboken/Mathematica** — samme uavhengige kilde som den lineære
fasiten ble laget fra, ikke bare en reprodusert formel. Lever som tabeller.
Avstand i meter, r₀ = 1 m. Formler:

```
r(lp0, lp, v) = 10^((lp0 − lp − D(v)) / 20)
L(lp0, r, v)  = lp0 − 20·log10(r) − D(v)
```

### 1. Direktivitet `D(v)`

dB ved `v = 0, 15, 30, 45, 50, 60, 70, 80, 90`. **4 desimaler** (så vi kan
teste `≈`).

### 2. Avstand (erstatter `gylneVerdier` i `lyd-core/test/Spec.hs`)

`r` med r₀ = 1, frittstående, **2 desimaler**. Behold de eksisterende punktene
(ren utskifting) og legg til mellomvinkler der lineær og cosinus skiller lag:

| lp0 | lp (mål) | v               |
|-----|----------|-----------------|
| 54  | 35       | 0, 45, 60, 90   |
| 54  | 30       | 90              |
| 53  | 35       | 0, 90           |
| 53  | 30       | 0               |
| 48  | 35       | 0               |
| 48  | 30       | 0               |
| 45  | 35       | 0               |
| 50  | 30       | 0               |

### 3. Avstandstabell (erstatter `tabellTests` i `Spec.hs`)

For `lp0 = 44`, r₀ = 1, frittstående, vinkler `{0, 50, 60, 70, 80, 90}`, for
hver kombinasjon av klasse {C, B} og tidsrom {Dag, Kveld, Natt}. Grenser:
C = 45/40/35, B = 40/35/30. **2 desimaler**. Helt rutenett er fint; minst de
cellene som testes i dag (Dag@0, Dag@90, Kveld@0, Natt@0, Natt@90 for begge
klasser).

### 4. Lydnivå kryss-sjekk (valgfritt, men nyttig)

`L(lp0 = 53, r, v)` for `(r=5, v=0)`, `(r=5, v=90)`, `(r=10, v=45)`.

## Hva jeg gjør når tallene er klare

1. Bytt `vinkelkorreksjon` til cosinus i `lyd-core/src/Lyd/Beregning.hs`
   (`D(v) = 5·(1 − cos v)`; `vinkelKlampet` håndterer allerede |v| og bak-feltet).
2. Oppdater golden-verdiene i `Spec.hs` (pkt. 2–4) til din nye fasit.
3. NS 8175-siden (`frontend/app/Main.hs`): slider `min` 45 → 0, og hjelpetekst
   («0–45° gir ingen korreksjon» → glatt korreksjon fra 0°).
4. Juster simulatortekstene i `lydnivakart.html` («Les dette ærlig»).
5. Bygg (`./build.sh`) og verifiser i nettleser: lobe-symmetri, tall identiske
   mellom WASM og JS-fallback, og at NS-tabellene matcher din fasit.
