#!/usr/bin/env bash
# Bygger Miso-frontenden til WebAssembly og assemblerer dist/.
# Krever ghc-wasm-meta (wasm32-wasi-ghc/-cabal), se README.md.
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v wasm32-wasi-cabal >/dev/null 2>&1; then
  if [ -f "$HOME/.ghc-wasm/env" ]; then
    # shellcheck source=/dev/null
    . "$HOME/.ghc-wasm/env"
  else
    echo "feil: wasm32-wasi-cabal ikke funnet — installer ghc-wasm-meta (se README.md)" >&2
    exit 1
  fi
fi

PROJECT=(--project-file=cabal.project.wasm)

if [ "${SKIP_CABAL_UPDATE:-0}" = "1" ]; then
  echo "hopper over cabal update (SKIP_CABAL_UPDATE=1)"
else
  wasm32-wasi-cabal "${PROJECT[@]}" update
fi
wasm32-wasi-cabal "${PROJECT[@]}" build app

WASM=$(wasm32-wasi-cabal "${PROJECT[@]}" list-bin app | tail -n 1)

rm -rf dist
mkdir -p dist
# '/.' kopierer også skjulte filer (f.eks. .nojekyll), som '*' hopper over.
cp -R frontend/static/. dist/
"$(wasm32-wasi-ghc --print-libdir)"/post-link.mjs --input "$WASM" --output dist/ghc_wasm_jsffi.js
cp "$WASM" dist/app.wasm

# Krymp binæren (ca. halvering) hvis binaryen er tilgjengelig. PR-preview kan
# sette WASM_OPT=0 for raskere bygg; produksjon beholder optimaliseringen.
if [ "${WASM_OPT:-1}" = "0" ]; then
  echo "hopper over wasm-opt (WASM_OPT=0)" >&2
elif command -v wasm-opt >/dev/null 2>&1; then
  wasm-opt -all -Oz dist/app.wasm -o dist/app.wasm.opt
  mv dist/app.wasm.opt dist/app.wasm
else
  echo "advarsel: wasm-opt ikke funnet — hopper over størrelsesoptimalisering" >&2
fi

echo "dist/ klar — app.wasm: $(du -h dist/app.wasm | cut -f1)"
