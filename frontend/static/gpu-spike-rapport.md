# GPU-forsøk: kartsimulatorens rutenett i WebGPU

Forsøk, ikke produksjon. Testsiden er `frontend/static/gpu-spike.html`, og
shaderen og vertskoden ligger i `frontend/static/gpuFelt.js`. `lyd-core` er
ikke endret. Kartsimulatoren kan bruke shaderen bak avkrysningsboksen «GPU
(forsøk)», som er av som standard (se «Oppfølging» nederst).

Tabellene under «Resultater» er fra første runde, med sikttesten uten
ε-margin. Effekten av marginen står under «Oppfølging».

## Hva som er sammenlignet

- **Oppsett:** `default.json` (138 utedeler) og de 29 husrekkene fra
  `husrekker/polygoner/` (sjekket inn i repoet, lastes lokalt). Rutenettet
  har samme hjørner som kartsiden, men 0,5 m oppløsning: 644 × 507 =
  **326 508 celler**, uten grovning.
- **WASM:** `gridWorker.js` uendret, i en pool på 16 workere (samme
  `POOL_SIZE`-formel som kartsiden), med radene delt sammenhengende. Kjernen
  er den deployede `app.wasm` fra GitHub Pages, fordi det ikke finnes noe
  lokalt wasm-bygg. Variant A bruker `acoustics_gridStripePerKilde` og
  variant B `acoustics_gridStripeSkjermetPerKilde`.
- **GPU:** én compute-dispatch for hele rutenettet med én tråd per celle
  (8×8-arbeidsgrupper), i float32. Tiden er målt fra opprettelse og
  opplasting av buffere til ferdig tilbakelesing (`mapAsync`). Den er median
  av 5 runder etter én oppvarmingsrunde. Kompilering av shader og pipeline
  (~25 ms første gang) er ikke med.
- **CPU-forberedelse** (float64, egen kolonne): polygonforenkling og
  unntaksmasker per kilde.

### Arbeidsdeling: hva som er bit-identisk og hva som er float32

Beslutninger som bare avhenger av kilde og polygon, ikke av cellen, regnes på
CPU i float64 med nøyaktig samme operasjoner som Haskell. De er derfor
bit-identiske med kjernen:

- **Douglas–Peucker (0,2 m):** JS-port av `forenkletPolygon`, med samme
  tie-breaking. Den er kryssjekket nativt mot `Lyd.Felt.gyldigeHusrekker`
  (via `cabal repl lyd-core`), og alle 29 polygonene fikk bit-identiske
  hjørnekoordinater (2760 → 985 hjørner). Kjernen eksporterer ikke
  forenklingen. Derfor er dette en kopi, men en verifisert en.
- **Kilde inni polygon** (hele polygonet unntas): 0 tilfeller i
  default-oppsettet.
- **Kant mindre enn 1 m fra kilden** (bare den kanten unntas): 256
  kilde×kant-par.

Alt som avhenger av cellen regnes på GPU i float32: avstand, retning,
maskering (stråletest) og sikttest (ekte kryssing, der streifing ikke
skjermer). Formelen er matematisk identisk med `nivaaMedHindre`, men skrevet
uten logaritmer per par:
`P0 · r⁻² · 10^(−(1−cos v)/2) · (0,1 hvis blokkert)`, der `cos v = max(0, û·d̂)`.

## Resultater

Maskinen er en Apple M5 Pro (6 ytelses- og 12 effektivitetskjerner,
`hardwareConcurrency` 18, 20 GPU-kjerner). Nettleseren er det innebygde
nettleserpanelet i Claude-appen (Chromium 152), med WebGPU-adapter
`apple / metal-3`.

**Synlighet:** tallene under er målt med panelet **synlig**
(`document.visibilityState` = `visible` ved start og slutt, og panelet ble
vist eksplisitt). Det er likevel ikke kontrollert at Claude-vinduet lå
øverst på skjermen hele tiden. En første kjøring med skjult panel ga
WASM 140 s for variant A, og den er forkastet. WASM-tiden varierer mye også
med synlig panel: variant A tok 6,4 s i én kjøring og 21 s i en annen. GPU-tiden
var stabil (±1 ms).

| Variant | WASM (pool 16) | GPU (opplasting + beregning + tilbakelesing) | CPU-forb. | Faktor |
|---|---|---|---|---|
| A – uskjermet | 6,4 s (21 s i én kjøring) | **2,8 ms** | 0,1 ms | ~2300× |
| B – skjermet + maskert | 6,8–7,5 s | **27,5–28 ms** | 4,4 ms | ~250× |

| Avvik | A – uskjermet | B – skjermet + maskert |
|---|---|---|
| Endelige celler | 326 508 | 286 216 (+ 40 292 maskert i begge) |
| Maks \|Δ\| | 2,3·10⁻⁴ dB | **0,21 dB** (én celle) |
| Snitt \|Δ\| | 2,2·10⁻⁶ dB | 3,4·10⁻⁶ dB |
| NaN-status ulik | 0 | **0** |
| Celler > 0,1 dB | 0 | 1 |
| Celler > 0,01 dB | 0 | 4 |
| Maks \|Δ\| uten de 4 cellene | – | 2,4·10⁻⁴ dB |

Resultatene var identiske i alle kjøringene (begge sider er deterministiske).

### De 4 cellene med avvik over 0,01 dB

Hver av cellene skyldes nøyaktig én kilde der skjermingsbeslutningen er ulik.
Dette er funnet ved å sammenligne `acoustics_forklarPunkt` (Haskell) med den
samme `blokkert()`-funksjonen i shaderen per kilde. I alle fire tilfellene
går siktlinja **høyst 1,2 µm** fra et polygonhjørne eller kantendepunkt, så
det er rene avrundingskanter (float32 mot float64):

| Celle (kol, rad) | Kilde | Haskell | GPU | Margin |
|---|---|---|---|---|
| 361, 123 | 27 | fri | blokkert | 0,37 µm |
| 527, 148 | 29 | blokkert | fri | 0,10 µm |
| 47, 298 | 122 | fri | blokkert | 1,16 µm |
| 314, 506 | 129 | fri | blokkert | 0,33 µm |

Ingen celler har ulik NaN-status. Ingen rutenettcelle ligger så nær en
polygonkant at stråletesten vipper.

## Vurdering

**Skyggekant-avvikene er akseptable for formålet.** Begrunnelsen:

- Beslutningene som vipper, gjelder siktlinjer under ett mikrometer fra et
  hjørne. Der er også Haskell-svaret i praksis tilfeldig: polygonene er
  digitalisert med centimeternøyaktighet, og forenklingen flytter geometrien
  inntil 0,2 m. Ingen av svarene er «mer riktig».
- Avviket er begrenset av én kildes bidrag (høyst 10 dB på den ene kilden),
  og her ble det høyst 0,21 dB i én celle av 286 216. Det gjelder 4 par av
  rundt 45 millioner celle×kilde-par.
- **Ett forbehold:** i 3 av de 4 tilfellene skjermer GPU-en der Haskell ikke
  gjør det. Der underestimerer GPU-en, med opptil 0,21 dB. Hvis «aldri lavere
  enn kjernen» skal gjelde strengt, kan shaderen kreve en minstemargin
  (|kryssprodukt| > ε) før den teller en kryssing som skjermende. Da vipper
  marginale tilfeller alltid mot «ikke skjermet», som er den konservative
  siden. Det er ikke prøvd.

**Farten:** GPU-en er rundt 250 ganger raskere enn dagens worker-pool med
skjerming, og over 1000 ganger raskere uten. Det flytter en full
0,5 m-runde fra sekunder til godt under én skjermoppdatering. Merk også at
skjermingen nesten ikke koster noe i WASM (6,4 mot 6,8 s), mens den er
rundt 10 ganger kostnaden av det uskjermede feltet på GPU.

**Det dette ikke avgjør:**

- *Prinsippet om én implementasjon.* Shaderen er en andre implementasjon av
  modellen. En eventuell integrasjon trenger enten (a) at kjernen leverer
  alt som ikke avhenger av cellen (forenklede polygoner og unntaksmasker) via
  nye WASM-eksporter, slik at bare den rene celleformelen og sikttesten
  ligger i WGSL, eller (b) en golden-test som kjører begge og feiler ved
  avvik. Denne testsiden er i praksis en manuell utgave av (b).
- *Nettleserdekning.* Bare testet i Chromium 152 på macOS (Metal). Safari og
  Firefox er ikke prøvd, og uten WebGPU trengs WASM-stien uansett som
  reserve.
- *Fasadepunktene* (`acoustics_fasadeVerst…`) og forklaringsvisningen er ikke
  dekket.
- *Integrasjon:* både dra-oppførsel og en GPU-watchdog for større rutenett er
  ennå uprøvd. Én dispatch på 28 ms er langt unna noen watchdog-grense.

## Oppfølging: bryter i kartet, ε-margin og dra

Målt 19.10.2026 på samme maskin (Apple M5 Pro, Chromium 152 i Claude-appens
nettleserpanel). Panelet var **synlig** under alle målingene
(`document.visibilityState` = `visible` ved start og slutt). Kjernen er den
deployede `app.wasm`, fordi det ikke finnes noe lokalt wasm-bygg.

### ε-margin i sikttesten

`krysser()` i shaderen teller nå en kryssing som skjermende bare når hvert
endepunkt ligger mer enn ε fra det andre segmentets linje. Tvilstilfeller
blir dermed uskjermet, altså litt for høyt nivå i stedet for litt for lavt.
Testsiden kjører samme WASM-runde mot flere ε (`?eps=…`) og to celle-gitre
(`?res=…`).

| ε | Gitter | Celler > 0,01 dB **under** kjernen | Maks under (dB) | Celler > 0,01 dB **over** | Maks over (dB) |
|---|---|---|---|---|---|
| 0 | 0,5 m (326 508) | **3** | 0,21 | 1 | – |
| 5 µm | 0,47 m (369 900) | 0 | 1,1·10⁻⁴ | 14 | 0,17 |
| 10 µm | 0,5 m | 0 | 2,4·10⁻⁴ | 22 | 0,59 |
| 10 µm | 0,47 m | 0 | 1,1·10⁻⁴ | 28 | 0,41 |
| **20 µm (valgt)** | 0,5 m | **0** | 2,4·10⁻⁴ | 40 | 0,93 |
| **20 µm (valgt)** | 0,47 m | **0** | 1,1·10⁻⁴ | 56 | 2,44 |
| 50 µm | 0,5 m | 0 | 2,4·10⁻⁴ | 110 | 1,46 |
| 1 mm | 0,5 m | 0 | 2,4·10⁻⁴ | 2181 | 7,61 |

(Med ε = 0 på 0,47 m-gitteret: 1 celle under, maks 0,054 dB.)

- **Med ε > 0 ligger GPU-en aldri under kjernen** i noen av kjøringene. Det
  som gjenstår, er ren float32-støy (≤ 2,4·10⁻⁴ dB).
- **Prisen er celler som blir for høye, og antallet vokser lineært med ε.**
  Grunnen er at kjernen skjermer fullt (−10 dB) så snart siktlinja så vidt
  klipper et hjørne. Marginen gjør en smal kile bak hvert polygonhjørne
  uskjermet. 1 mm, som var første forslag, er altfor mye: da blir 2181
  celler opptil 7,6 dB for høye. Alle disse ble sporet til siktlinjer under
  1 mm fra et hjørne.
- **Valgt ε = 20 µm** (`EPS_SIKT_M` i `gpuFelt.js`). Alle vippene mot «GPU
  skjermer, kjernen ikke» lå under 1,2 µm fra et hjørne. float32-avrundingen
  av koordinatene er likevel opptil ~8 µm så langt fra origo, så 20 µm gir
  margin mot det. Det koster ~0,015 % av cellene (40–56), og de ligger
  opptil 0,9–2,4 dB for høyt. Det er konservativt, men det er ingen garanti:
  marginen er målt på to gitre over ett oppsett, ikke bevist.

### Bryteren i kartet

«GPU (forsøk)» i rutenett-gruppen kjører `forbered()` + `beregn()` med
samme `pumpsLocal`/`husPolysLocal` og samme SV-origo som worker-poolen.
Resultatet går inn i `lastGrid` og videre til `renderFyll`/`renderContours`.

| 0,5 m, 326 508 celler, skjermet | WASM (pool 16) | GPU |
|---|---|---|
| Hel runde, inkl. tegning | 7,3–7,5 s | 79–117 ms (GPU 33–45 ms + forb. 2–6 ms + tegning 15–30 ms) |
| Celler med ulik NaN-status | – | 0 |
| Celler > 0,01 dB under / over WASM | – | 0 / 40 |
| Celle×grense-par på ulik side av en aktiv grense | – | 2 av ~2,3 mill. |

Konturene er visuelt like med GPU av og på (skjermbilder sammenlignet).
Dra-oppførselen ble målt med syntetiske `mousemove`-hendelser (60 Hz i 4 s)
på en utedel:

| Under dra | WASM (DRAG_COARSEN = 3) | GPU (ingen grovning) |
|---|---|---|
| Oppløsning | 1,5 m (36 550 celler) | **0,5 m (326 508 celler)** |
| Runder per sekund | 1,3 | **18,8** |
| Tid per runde (median / maks) | 850 / 853 ms | 52 / 96 ms |
| Animasjonsrammer (median / p95 / maks) | 13,3 / 13,4 / 14,4 ms | 13,3 / 13,9 / 40 ms |
| Rammer over 50 ms | 0 | 0 |

Slipp (ekte dra med nettleserverktøyet): med GPU kom siste fulle runde
66 ms etter at musa ble sluppet, mot 7,5 s med WASM.

**Vurdering av dra:** med GPU følger konturene utedelen i full oppløsning, med
rundt 19 oppdateringer i sekundet. Med WASM kommer én grov oppdatering i
sekundet, og det fine bildet først 7 s etter slipp. Derfor hopper
`gridDims()` over `DRAG_COARSEN` når GPU-en er i bruk. Kostnaden er at
konturer og fyll for 326 000 celler nå tegnes på hovedtråden for hver runde.
Det ga enkelte rammer på opptil 40 ms, mot ~14 ms med workerne, men ingen
over 50 ms. «Føles jevnt» er her lest ut av rammetidene. Det er ikke prøvd
med en ekte hånd på musa.

**Fallback:** uten WebGPU (simulert ved å skjule `navigator.gpu`) står
feilen i infolinja («GPU-forsøket feilet (…) – regnet med WASM-workerne»),
og runden regnes med workerne. Feilen er klebrig til boksen slås av og på
igjen. Med boksen av er worker-stien uendret: 1,5 m under dra og full
0,5 m-runde etter slipp.

**Ikke dekket:** fasadepunktene (`acoustics_fasadeVerst…`) og «Forklar
celle» bruker fortsatt kjernen. Forklaringen kan derfor i sjeldne
hjørnetilfeller vise en annen skjermingsbeslutning enn GPU-rutenettet. Det er
heller ikke testet i Safari eller Firefox, eller på svakere GPU-er.

## Kjøre forsøket

Serve repo-rota (husrekkene lastes som `../../husrekker/polygoner/`), åpne
`http://localhost:8133/frontend/static/gpu-spike.html` og trykk «Kjør
forsøket». Hold fanen synlig mens det kjører.

```sh
python3 -m http.server 8133
```

Uten et lokalt wasm-bygg hentes den deployede `app.wasm`, så siden trenger
nett.

`?eps=0,1e-5,2e-5` velger hvilke ε som prøves (standard: 0, 10, 20 og 50 µm
og 1 mm), og `?res=0.47` gir et annet celle-gitter over samme oppsett.
