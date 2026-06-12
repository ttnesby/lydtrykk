# PLAN.md — Lydnivå/avstand-kalkulator i Haskell (Miso + GHC WASM)

> Instruks til Claude Code: Implementer denne planen fase for fase, i rekkefølge.
> Hver fase har akseptkriterier. Ikke gå videre til neste fase før kriteriene er
> oppfylt og verifisert med kommando. Commit per fase med beskrivende melding.
> Spør hvis noe er tvetydig — ikke gjett på domeneformlene, de er fasit i §2.

## 0. Mål og rammer

En statisk web-side, skrevet i Haskell og kompilert til WebAssembly med Miso,
som regner **begge veier** mellom lydtrykknivå og avstand for en varmepumpe-utedel,
etter grenseverdiene i NS 8175. Hostes på GitHub Pages. Automatisk bygg og deploy
ved push til `main` via GitHub Actions.

- Språk i UI: norsk (bokmål).
- Ingen backend/server. Kun statiske filer.
- Domenelogikk skal være et rent bibliotek uten Miso-avhengighet, testbart med
  vanlig (nativ) GHC.

## 1. Teknologivalg (låst)

- **GHC WASM-backend** via `ghc-wasm-meta` (wasm32-wasi-ghc / wasm32-wasi-cabal),
  GHC 9.12-flavour. Installer med det offisielle installasjonsskriptet fra
  https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta (non-nix-varianten),
  eller nix flake hvis nix allerede finnes i miljøet.
- **Miso** ≥ 1.9 (WASM-støtte). Bruk gjerne `tweag/ghc-wasm-miso-examples` og
  Misos offisielle `sample-app`/WASM-eksempel som referanse for byggeoppsett
  (post-link, JSFFI-glue, index.html-loader) — men kopier kun det som trengs.
- **Tester**: cabal test-suite med `tasty` + `tasty-quickcheck` + `tasty-hunit`,
  kjøres på **nativ** GHC (ikke wasm) i CI.
- **CI/CD**: GitHub Actions → `actions/upload-pages-artifact` + `actions/deploy-pages`.
- Pin versjoner (index-state i cabal.project, eksakt ghc-wasm-meta-flavour i CI)
  slik at bygget er reproduserbart.

Fallback hvis WASM-toolchain feiler hardt i CI etter rimelig innsats:
dokumentér problemet i en issue-tekst, og foreslå jsaddle-dev-modus lokalt —
men ikke bytt arkitektur uten å spørre.

## 2. Domenemodell (fasit — skal implementeres nøyaktig slik)

Modul: `src/Lyd/Beregning.hs` (rent bibliotek, `lyd-core`).

### 2.1 Konstanter (NS 8175, LAFmax, uteoppholdsareal/åpent vindu)

| Tidsrom        | Klasse C | Klasse B |
|----------------|----------|----------|
| Dag (07–19)    | 45 dBA   | 40 dBA   |
| Kveld (19–23)  | 40 dBA   | 35 dBA   |
| Natt (23–07)   | 35 dBA   | 30 dBA   |

Klasse B = Klasse C − 5 dBA. Modellér som `data Tidsrom = Dag | Kveld | Natt`
og `data Lydklasse = KlasseC | KlasseB`, med en funksjon `grense :: Lydklasse -> Tidsrom -> Double`.

### 2.2 Lydnivå ved avstand (punktkilde, frittfelt)

For vinkel `v` (grader) relativt viftens hovedretning, referansenivå `lp0` målt
ved `r0` (normalt 1 m):

```
base       = lp0 - 20 * log10 (r / r0)
korr v     = if v > 45 && v <= 90 then (v - 45) * 5/45 else 0
lp r v     = base - korr v
```

Vinkler > 90° er utenfor modellen: avvis i UI (begrens input 0–90).

### 2.3 Avstand ved gitt lydnivå (invers)

```
r = r0 * 10 ** ((lp0 - lp - korr v) / 20)
```

### 2.4 Tillegg og modi

- **Veggmontert utedel**: +3 dBA på `lp0` (refleksjon). Toggle i UI.
- **Kumulativt nivå** for flere kilder: `ltot = 10 * log10 (sum [10**(l/10) | l <- ls])`.
- **Nattavslag-modus**: hvis pumpen slås av kl. 23–07, er kveldsgrensen (40/35)
  dimensjonerende i stedet for nattgrensen. UI skal kunne vise begge scenarier
  side om side.

### 2.5 Gylne testverdier (fra verifisert notatbok — skal treffes på 2 desimaler)

Med `r0 = 1`:

| lp0 | mål-lp | vinkel | forventet avstand |
|-----|--------|--------|-------------------|
| 54  | 35     | 0°     | 8.91 m  |
| 54  | 35     | 90°    | 5.01 m  |
| 54  | 30     | 90°    | 8.91 m  |
| 53  | 35     | 0°     | 7.94 m  |
| 53  | 35     | 90°    | 4.47 m  |
| 53  | 30     | 0°     | 14.13 m |
| 48  | 35     | 0°     | 4.47 m  |
| 48  | 30     | 0°     | 7.94 m  |
| 45  | 35     | 0°     | 3.16 m  |
| 50  | 30     | 0°     | 10.00 m |

QuickCheck-egenskaper:
1. Rundtur: `lp (r (x)) == x` innen 1e-9, for lp0 ∈ [40,70], lp ∈ [25, lp0−1], v ∈ [0,90].
2. Monotoni: avstand strengt synkende i mål-lp, strengt synkende i vinkel for v > 45.
3. Kumulativ: `kumulativ [l, l] == l + 10*log10 2` (≈ l + 3.01).

## 3. Prosjektstruktur

```
.
├── PLAN.md
├── cabal.project
├── lyd-core/                 # ren domenelogikk + tester (bygges nativt og for wasm)
│   ├── lyd-core.cabal
│   ├── src/Lyd/Beregning.hs
│   └── test/Spec.hs
├── frontend/                 # Miso-app (bygges kun for wasm)
│   ├── frontend.cabal
│   ├── app/Main.hs
│   └── static/
│       ├── index.html        # loader: wasm + jsffi-glue + browser_wasi_shim
│       └── style.css
├── build.sh                  # lokalt wasm-bygg → dist/
└── .github/workflows/deploy.yml
```

`cabal.project` skal fungere med begge toolchains: nativt bygg av `lyd-core`
(for test), wasm-bygg av `lyd-core` + `frontend` (for deploy). Bruk
`cabal.project` + evt. `cabal.project.wasm` hvis flagg må skilles.

## 4. UI-spesifikasjon (Miso)

Én side, to seksjoner. Stil: enkel, lesbar, mobilvennlig (folk åpner dette på
telefon på beboermøte). Ingen rammeverk, håndskrevet CSS.

### Inndata (felles panel)
- Oppgitt lydnivå utedel, 1 m frittfelt (number input, default 53, range 40–70)
- Veggmontert (checkbox, default på, +3 dBA, vis effektivt kildenivå)
- Vinkel til nabo (slider 0–90°, default 0, vis gradtall)
- Lydklasse (radio: C (minstekrav) / B (anbefalt))

### Modus A: «Avstand for å overholde grense»
- Viser nødvendig minsteavstand for Dag / Kveld / Natt i en tabell,
  pluss en egen rad «Natt m/ nattavslag» (= kveldsgrensen).
- Marker dimensjonerende rad (størst avstand av de som gjelder).

### Modus B: «Lydnivå ved gitt avstand»
- Avstand (number input, meter)
- Viser beregnet lydnivå og pr. tidsrom om det er **innenfor/utenfor**
  valgt lydklasse (grønn/rød markering), både med og uten nattavslag.

### Detaljer
- Alle tall med én desimal i UI.
- Liten fotnote: «Forenklet frittfeltmodell (invers kvadratlov). Faktiske
  forhold med refleksjoner og skjerming kan avvike. Grenseverdier: NS 8175,
  LAFmax på uteoppholdsareal.»
- Tittel: «Varmepumpe: lydnivå og avstand (NS 8175)».

## 5. Faser

### Fase 1 — lyd-core med tester (nativ GHC)
1. Init cabal-prosjekt, `lyd-core` med modul og test-suite iht. §2.
2. Akseptkriterier:
   - `cabal test` grønt lokalt.
   - Alle gylne verdier i §2.5 treffes på 2 desimaler.

### Fase 2 — WASM-toolchain og hello-Miso
1. Installer ghc-wasm-meta lokalt (dokumentér eksakt kommando i README).
2. Minimal Miso-app («det virker»-side) som bygger til wasm.
3. `build.sh`: wasm32-wasi-cabal build → kopier .wasm → kjør
   `post-link.mjs` for JSFFI-glue → assembler `dist/` med index.html,
   glue-js, wasm, css.
4. Akseptkriterier:
   - `./build.sh` produserer `dist/` som fungerer med
     `python3 -m http.server -d dist` i nettleser.

### Fase 3 — Kalkulator-UI
1. Implementer §4 mot `lyd-core`.
2. Akseptkriterier:
   - Modus A med default-verdier (53 dBA, veggmontert ⇒ 56… NB: kontroller
     mot §2: veggmontert betyr lp0=53 hvis 50 oppgitt + 3; med default 53
     oppgitt og veggmontert på blir effektivt 56) viser konsistente tall.
   - Manuell sjekk: lp0-effektiv 53, vinkel 0, klasse C, natt ⇒ 7.9 m.
   - Begge moduser er konsistente med hverandre (frem/tilbake).

### Fase 4 — CI/CD
1. Workflow `deploy.yml`:
   - Jobb 1 `test`: nativ GHC (haskell-actions/setup), cache, `cabal test`.
   - Jobb 2 `build-deploy` (needs: test): installer ghc-wasm-meta
     (cache `~/.ghc-wasm`), kjør `build.sh`, last opp `dist/` som
     pages-artifact, deploy med `actions/deploy-pages`. Kun på push til `main`.
2. Slå på GitHub Pages med «GitHub Actions» som source (dokumentér i README
   hvis det må gjøres manuelt i repo-settings).
3. Akseptkriterier:
   - Grønn pipeline på push til main.
   - Siden er live på `https://<bruker>.github.io/<repo>/`.
   - Total CI-tid < 10 min på varm cache.

### Fase 5 — Finpuss
- README.md (norsk): hva, hvorfor, formler, hvordan bygge lokalt, lenke til live-side.
- Lighthouse-sjekk på mobil-layout. Wasm-størrelse: rapporter, og aktiver
  gzip-vennlige tiltak hvis > 5 MB (strip, `-Oz`-tilsvarende GHC-flagg).

## 6. Konvensjoner

- Norske navn i domenemodulen er ok (`grense`, `Tidsrom`), engelske ellers.
- Ingen `unsafePerformIO`, ingen partial functions i lyd-core.
- HLint + ormolu/fourmolu hvis tilgjengelig, men ikke blokker på det.
- Commit-meldinger: `fase-N: <hva>`.
