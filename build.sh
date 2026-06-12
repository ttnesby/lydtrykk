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

wasm32-wasi-cabal "${PROJECT[@]}" update
wasm32-wasi-cabal "${PROJECT[@]}" build app

WASM=$(wasm32-wasi-cabal "${PROJECT[@]}" list-bin app | tail -n 1)

rm -rf dist
mkdir -p dist
cp frontend/static/* dist/
"$(wasm32-wasi-ghc --print-libdir)"/post-link.mjs --input "$WASM" --output dist/ghc_wasm_jsffi.js
cp "$WASM" dist/app.wasm

echo "dist/ klar — app.wasm: $(du -h dist/app.wasm | cut -f1)"
