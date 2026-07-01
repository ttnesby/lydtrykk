# lydtrykk

**Varmepumpe: lydnivå og avstand (NS 8175)** — enkel kalkulator for
lydtrykknivå og avstand til lydkilde (varmepumpe-utedel), skrevet i Haskell
og kompilert til WebAssembly med [Miso](https://github.com/haskell-miso/miso)
og GHC sin WASM-backend. Ingen backend — kun statiske filer.

**Live:** <https://ttnesby.github.io/lydtrykk/>

## Hva den gjør

Regner begge veier mellom lydtrykknivå og avstand, mot grenseverdiene i
NS 8175 (LAFmax på uteoppholdsareal), for fire lydklasser fra strengest
(A) til minstekrav (C):

| Tidsrom       | Klasse A | Klasse B+ | Klasse B | Klasse C |
|---------------|----------|-----------|----------|----------|
| Dag (07–19)   | 35 dBA   | 38 dBA    | 40 dBA   | 45 dBA   |
| Kveld (19–23) | 30 dBA   | 33 dBA    | 35 dBA   | 40 dBA   |
| Natt (23–07)  | 25 dBA   | 28 dBA    | 30 dBA   | 35 dBA   |

Klasse B+ er en mellomklasse (7 dBA strengere enn minstekravet C); de
andre offsettene er A = 10 dBA og B = 5 dBA strengere enn C.

- **Modus A**: nødvendig minsteavstand per tidsrom, inkl. scenario med
  nattavslag (pumpen av kl. 23–07 ⇒ kveldsgrensen dimensjonerer).
- **Modus B**: beregnet lydnivå ved gitt avstand, med innenfor/utenfor-status
  per tidsrom.
- **Modus C**: avstandstabell for et fast vinkelsett, alle fire klasser side om
  side, én undertabell per tidsrom.

## Simulator (lydnivåsoner på kart)

`lydnivakart.html` er en Leaflet-basert kart-simulator, lenket fra kalkulatoren
(«enkel simulator på kart») og nås også direkte via `…/lydnivakart.html`:

- Klikk i kartet for å plassere **utedeler**. De kan dras og roteres (hvitt
  håndtak), og bakgrunnskart byttes (Kartverket gråtone som standard, topo,
  flyfoto, OSM). Sidepanelet kan skjules og bredden justeres.
- **Felles lydkilde**: ett lydnivå-felt (dBA ved 1 m) + veggmontering (+3 dB)
  + kabinettdemping gjelder alle utedeler.
- **Klassematrise**: en 4×3-rutenett (klasse × tidsrom) med de åtte distinkte
  grenseverdiene fra tabellen over. Cellene ER sonevelgeren — klikk for å
  vise/skjule en grense; celler med samme dB(A) (f.eks. A dag = B kveld =
  C natt) henger sammen og fargelegges likt.
- **Rutenett og dB-ekvidistanser**: to draggbare hjørnemarkører setter et
  rutenett (justerbar oppløsning, 1–5 m, default 2 m) som regner **kumulativt**
  (logaritmisk summert) lydnivå fra alle utedeler for hver rute — i en pool av
  Web Workers (`gridWorker.js`, egen WASM-instans hver) for ekte parallell
  beregning. Ruter over strengeste aktive grense markeres røde, og
  ekvidistanser (konturlinjer, via en enkel marching-squares-implementasjon)
  tegnes ved de aktive klassematrise-grensene. Rutenettet kan skrus av i
  panelet; da vises i stedet hver utedels egen **halvbue** (retningsavhengig
  rekkevidde for én kilde) for den valgte grensen.
- **Lagre / last oppsett**: «Lagre til fil» laster ned hele tilstanden som en
  menneskelesbar JSON-fil i nedlastingsmappa — lydkilde, valgte soner,
  standardretning, karttype, alle utedeler (plassering + vinkel), rutenettets
  hjørner/oppløsning/av-på-status og kartutsnitt. «Last fra fil» setter alt
  tilbake til lagret tilstand, og eldre lagringsformater (inkl. filer med det
  utgåtte «nabo»-punktet) leses fortsatt inn uten feil.
  (Nettleseren lagrer til nedlastingsmappa; lasting krever at du velger fila i
  filvelgeren — en nettside kan ikke lese mapper på egen hånd.)

Simulatoren deler **samme akustikk-kjerne** (`Lyd.Beregning`) som NS 8175-siden,
eksponert fra `app.wasm` via synkrone JSFFI-eksporter (`acoustics_dirGain`,
`acoustics_reqDist`, `acoustics_levelAt`, `acoustics_dbSum`). Både hovedtråden
og hver grid-worker instansierer WASM-kjernen via en delt boot-sekvens
(`wasmInit.js`), så tallene kan ikke divergere. En ren JS-fallback med
identisk modell brukes dersom WASM ikke lastes noe sted.

### Oppdatere standard-oppsettet

Ved hver (hard) refresh laster simulatoren et default-oppsett, slik at den
åpner med et ferdig sett utedeler, soner og kartutsnitt. Kilden er
[`frontend/static/default.json`](frontend/static/default.json) — samme
filformat som «Lagre til fil» produserer.

Fila hentes **live fra GitHub raw**, så standardverdiene kan oppdateres **uten
ny deploy**:

1. Lag ønsket oppsett i simulatoren og bruk **«Lagre til fil»**.
2. Lim innholdet inn i `frontend/static/default.json` på `main` (f.eks. via
   blyant-ikonet i GitHub sitt webgrensesnitt) og commit.
3. Brukerne ser endringen ved neste hard refresh (innen ~5 min, pga.
   CDN-cache på raw). `paths-ignore` i workflowen hindrer at en ren
   default-endring trigger et unødvendig wasm-bygg.

Hvis raw ikke kan hentes (nett/CORS/offline) faller siden tilbake på den
bundlede kopien fra forrige deploy, så defaults lastes alltid. For å oppdatere
den bundlede fallback-kopien, kjør deploy-workflowen manuelt («Run workflow»).

## Formler

Forenklet frittfeltmodell (punktkilde, invers kvadratlov), med referansenivå
`lp0` målt ved `r0` (normalt 1 m) og vinkel `v` (grader) relativt viftens
hovedretning:

```
lp(r, v) = lp0 − 20·log10(r / r0) − korr(v)
korr(v)  = 5·(1 − cos v)   for 0° ≤ v ≤ 90°   (cosinus-karakteristikk)
r(lp, v) = r0 · 10^((lp0 − lp − korr(v)) / 20)
```

Veggmontert utedel gir +3 dBA på `lp0` (refleksjon). Kumulativt nivå for
flere kilder: `ltot = 10·log10(Σ 10^(l/10))`.

> Forenklet modell — faktiske forhold med refleksjoner og skjerming kan
> avvike. Se [PLAN.md](PLAN.md) for full spesifikasjon.

> Retningskorreksjonen bruker en glatt cosinus-karakteristikk (0 dB rett frem,
> 5 dBA ved 90°). Fasit-tallene den er verifisert mot er dokumentert i
> [COSINUS-OVERGANG.md](COSINUS-OVERGANG.md).

## Prosjektstruktur

- `lyd-core/` — ren domenelogikk, uten Miso-avhengighet. Testes med nativ GHC
  (tasty + QuickCheck, inkl. gylne verdier og rundtur-egenskap).
- `frontend/` — Miso-app, bygges kun for wasm32-wasi. `app/Main.hs` inneholder
  både kalkulatoren og JSFFI-eksportene av akustikk-kjernen til JS.
  `static/` er alt som serveres direkte:
  - `index.html` — kalkulatoren (Miso monteres inn her).
  - `lydnivakart.html` — kart-simulatoren (samme `app.wasm`, kjørt i
    reactor-modus uten `hs_start`).
  - `gridWorker.js` — Web Worker som regner en rad-stripe av rutenettet;
    hovedtråden kjører flere av disse parallelt (se «Simulator» over).
  - `wasmInit.js` — delt WASI-boot, importert av både `lydnivakart.html` og
    `gridWorker.js`.
  - `default.json` — standard-oppsettet simulatoren laster ved oppstart
    (se eget avsnitt under).
- `build.sh` — wasm-bygg → `dist/` (post-link av JSFFI-glue, wasm-opt -Oz).
- `.github/workflows/deploy.yml` — test (nativ GHC) → wasm-bygg → GitHub Pages.

## Bygge lokalt

### Tester (nativ GHC)

```sh
cabal test all
```

### WASM-bygg

Krever [ghc-wasm-meta](https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta).
Installert med (GHC 9.12-flavour, non-nix):

```sh
curl -f -L --retry 5 https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta/-/raw/master/bootstrap.sh -o bootstrap.sh
FLAVOUR=9.12 sh bootstrap.sh
source ~/.ghc-wasm/env
```

Deretter:

```sh
./build.sh
python3 -m http.server -d dist
# åpne http://localhost:8000
```

`app.wasm` er ca. 1,6 MB etter `wasm-opt -Oz` (3,3 MB uoptimalisert).

## Deploy

Push til `main` kjører testene, bygger wasm og deployer `dist/` til GitHub
Pages via `actions/deploy-pages`. Workflowen forsøker selv å aktivere Pages
(`actions/configure-pages` med `enablement: true`); hvis det feiler, slå på
GitHub Pages med «GitHub Actions» som source under Settings → Pages.

### Hoppe over deploy for trivielle endringer

For commits som ikke påvirker det som bygges (f.eks. ren dokumentasjon), kan du
hoppe over hele workflow-kjøringen ved å ta med en av disse i commit-meldingen
(tittel **eller** melding-body):

```
[skip ci]   [ci skip]   [no ci]   [skip actions]   [actions skip]
```

Dette gjelder kun `push`/`pull_request` — manuell kjøring via «Run workflow»
påvirkes ikke. Standard-oppsettet (`default.json`) hoppes over automatisk via
`paths-ignore` og trenger derfor ingen slik markør.
