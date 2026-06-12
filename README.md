# lydtrykk

Varmepumpe: lydnivå og avstand (NS 8175). Enkel kalkulator for lydtrykknivå
og avstand til lydkilde — statisk web-app skrevet i Haskell, kompilert til
WebAssembly med [Miso](https://github.com/haskell-miso/miso) og GHC sin
WASM-backend. Se [PLAN.md](PLAN.md) for full spesifikasjon.

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
