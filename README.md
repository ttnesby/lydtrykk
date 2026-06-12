# lydtrykk

**Varmepumpe: lydnivå og avstand (NS 8175)** — enkel kalkulator for
lydtrykknivå og avstand til lydkilde (varmepumpe-utedel), skrevet i Haskell
og kompilert til WebAssembly med [Miso](https://github.com/haskell-miso/miso)
og GHC sin WASM-backend. Ingen backend — kun statiske filer.

**Live:** <https://ttnesby.github.io/lydtrykk/>

## Hva den gjør

Regner begge veier mellom lydtrykknivå og avstand, mot grenseverdiene i
NS 8175 (LAFmax på uteoppholdsareal):

| Tidsrom      | Klasse C | Klasse B |
|--------------|----------|----------|
| Dag (07–19)  | 45 dBA   | 40 dBA   |
| Kveld (19–23)| 40 dBA   | 35 dBA   |
| Natt (23–07) | 35 dBA   | 30 dBA   |

- **Modus A**: nødvendig minsteavstand per tidsrom, inkl. scenario med
  nattavslag (pumpen av kl. 23–07 ⇒ kveldsgrensen dimensjonerer).
- **Modus B**: beregnet lydnivå ved gitt avstand, med innenfor/utenfor-status
  per tidsrom.

## Formler

Forenklet frittfeltmodell (punktkilde, invers kvadratlov), med referansenivå
`lp0` målt ved `r0` (normalt 1 m) og vinkel `v` (grader) relativt viftens
hovedretning:

```
lp(r, v) = lp0 − 20·log10(r / r0) − korr(v)
korr(v)  = (v − 45)·5/45  for 45° < v ≤ 90°, ellers 0
r(lp, v) = r0 · 10^((lp0 − lp − korr(v)) / 20)
```

Veggmontert utedel gir +3 dBA på `lp0` (refleksjon). Kumulativt nivå for
flere kilder: `ltot = 10·log10(Σ 10^(l/10))`.

> Forenklet modell — faktiske forhold med refleksjoner og skjerming kan
> avvike. Se [PLAN.md](PLAN.md) for full spesifikasjon.

## Prosjektstruktur

- `lyd-core/` — ren domenelogikk, uten Miso-avhengighet. Testes med nativ GHC
  (tasty + QuickCheck, inkl. gylne verdier og rundtur-egenskap).
- `frontend/` — Miso-app, bygges kun for wasm32-wasi.
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
