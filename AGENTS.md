# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## What this is

A static, backend-free web app: a Haskell domain-logic library compiled to
WebAssembly (via Miso + GHC's wasm32-wasi backend) that answers "how far /
how loud" questions for a heat-pump outdoor unit against NS 8175 noise
limits. Two UIs share one WASM binary and one domain module:

- `frontend/static/index.html` — the Miso calculator app.
- `frontend/static/lydnivakart.html` — a Leaflet map simulator that places
  multiple units and computes cumulative/spatial noise, calling into the
  *same* `app.wasm` in "reactor mode" (no `hs_start`, so Miso never mounts).

All UI text, comments, and commit messages are in Norwegian (bokmål).

## Commands

### Native tests (fast path — no wasm toolchain needed)

```sh
cabal test all
```

Run a single test group/case by name (tasty pattern match on the test tree
path, e.g. group "gylne verdier..." > case "..."):

```sh
cabal test lyd-core-test --test-options="--pattern <substring>"
```

### WASM build (full app, needed to exercise either HTML page for real)

Requires [ghc-wasm-meta](https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta)
(GHC 9.12 flavour):

```sh
curl -f -L --retry 5 https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta/-/raw/master/bootstrap.sh -o bootstrap.sh
FLAVOUR=9.12 sh bootstrap.sh
source ~/.ghc-wasm/env

./build.sh                       # -> dist/ (app.wasm + static files)
python3 -m http.server -d dist   # open http://localhost:8000
```

Without a wasm build, both HTML pages still run: `app.wasm`/`ghc_wasm_jsffi.js`
fetches 404, and every acoustics call falls back to an equivalent hand-written
JS formula (see "Dual implementation" below). This is enough to iterate on UI/
map logic without the wasm toolchain installed.

There is no separate lint/format command wired up; Haskell is formatted with
ormolu via HLS (2-space indent, see `.zed/settings.json`), not enforced by CI.

## Architecture

### Two cabal projects, one reason

- `cabal.project` — native, `lyd-core` only. What `cabal test all` and CI's
  test job use. wasm32-wasi-ghc cannot easily run a test-suite binary, so all
  tests run natively against pure Haskell.
- `cabal.project.wasm` — `lyd-core` + `frontend`, built only with
  `wasm32-wasi-cabal` (via `build.sh`). This is what produces `app.wasm`.

### `lyd-core` is the single source of truth

`lyd-core/src/Lyd/Beregning.hs` is a pure, Miso-free library: the NS 8175
limit table (4 classes A/B+/B/C × 3 tidsrom, offsets 10/7/5/0 dBA from the
class-C minimum), the free-field point-source model (inverse-square + cosine
directional correction), its inverse (level → distance), cumulative
logarithmic summation for multiple sources, and required-cabinet-attenuation.
Everything else in the repo — the calculator UI, the map simulator, and the
grid workers — is a thin caller of this module. `lyd-core/test/Spec.hs` pins
it down with golden values (from a verified reference notebook), a round-trip
QuickCheck property (`lydnivaa (avstand lp) == lp`), and monotonicity
properties. Change the model here first, and check tests before touching any
JS call site.

### WASM export surface (`frontend/app/Main.hs`)

Under `#ifdef WASM` (set via `cpp-options: -DWASM` only when
`arch(wasm32)`, see `frontend/frontend.cabal`), `Main.hs` exports four
*synchronous* JSFFI functions layered directly on `Lyd.Beregning`:
`acoustics_dirGain`, `acoustics_reqDist`, `acoustics_levelAt`,
`acoustics_dbSum`. Synchronous exports (the `" sync"` suffix in the
`foreign export javascript` declarations) are required because both
`lydnivakart.html` and `gridWorker.js` call them inside tight draw/compute
loops — an async/Promise-based export would be unworkable there. The linker
flags that actually expose these symbols from the wasm binary live in
`frontend.cabal`'s `--export=...` list, not in the Haskell source; adding a
new export needs both a `foreign export javascript` line *and* a matching
`--export` flag.

### Dual implementation: WASM is authoritative, JS is a pinned fallback

Every acoustics call site in JS (main thread in `lydnivakart.html`, and each
`gridWorker.js` instance) has a hand-written fallback (`dirGainJS`,
`levelAtJS`/inline equivalents, `dbSumJS`) using the exact same formulas as
`Beregning.hs`. If WASM fails to load, the site silently swaps to the JS
version with no visible difference to the user. When changing the model in
`Beregning.hs`, update these JS mirrors too, or the two code paths will
silently diverge in degraded mode.

### `lydnivakart.html`: grid/ekvidistanser feature (the newest, most involved part)

Two draggable corner markers define a rectangular grid over the map. For
each cell, cumulative dB from all placed units is computed and rendered two
ways: a red canvas `L.imageOverlay` for cells over the strictest active
class-matrix limit, and dB-equidistance contour lines (custom marching-squares
implementation, no external dependency) at each active class-matrix limit,
colored/dashed to match the existing limit color scale.

- **Parallelism**: a persistent pool of Web Workers (`gridWorker.js`, sized
  `min(8, hardwareConcurrency)`), each independently loading its own
  `app.wasm` instance via the shared boot sequence in `wasmInit.js` (dynamic
  `import()`, not static — a static import failure would otherwise prevent
  `self.onmessage` from ever being registered and hang the worker forever).
  Rows are split contiguously across the pool; each worker returns a
  transferable `Float64Array`.
- **Coordinates**: grid math uses a local planar (equirectangular) projection
  from the grid's SW corner, *not* Leaflet's haversine helpers — cheap and
  accurate enough at lot/neighborhood scale, and avoids needing Leaflet
  inside a worker (which has no DOM).
- **Scheduling**: `scheduleGrid()` is a busy/dirty loop (`gridBusy`/
  `gridDirty`), not a naive per-event recompute — it guarantees at most one
  in-flight computation, collapsing bursts (e.g. continuous pointer-drag
  events) into exactly one more pass once the current one finishes, instead
  of queuing an ever-growing backlog of stale work.
- **Resolution during interaction**: while `interacting` is true (set on
  pump/corner `drag`, cleared on `dragend`), `gridDims()` multiplies the
  configured resolution by `DRAG_COARSEN` for fast live feedback; the final
  `dragend` always triggers one full-resolution pass.
- **Cell cap**: `MAX_CELLS` auto-coarsens the effective resolution (not the
  user's setting) if the corner rectangle would exceed it, and reports this
  in the UI rather than silently truncating.
- **On/off**: `gridOn` toggles between this grid view and the older
  per-pump semicircle "halvbue" rendering (`drawPump`/`lobePts`, one pump at
  a time) — the two are mutually exclusive on the map to avoid visual
  clutter; turning the grid off is what re-enables halvbue rendering, not a
  separate code path.

### Save/load format (`snapshot()`/`restore()` in `lydnivakart.html`)

Versioned JSON (`format:"lydnivakart"`, currently `version:3`), downloaded/
re-selected by the user (no server, so no folder access — this is why it's a
manual file picker round-trip, not auto-restore). `restore()` tolerantly
migrates older shapes in place (v1 `mode`/`mount`/`bands` fields, v2's now-
removed `nabos` neighbor-point array is simply ignored if present). Add new
persisted fields by extending `snapshot()` and reading them defensively in
`restore()` — don't bump the version number for additive, tolerant changes.

### `default.json` hybrid live-fetch

On load, `lydnivakart.html` fetches
`frontend/static/default.json` live from `raw.githubusercontent.com/.../main/...`
(cache-busted with a timestamp query param) so editing this one file on
`main` updates everyone's default state within the CDN's ~5 min cache window,
*without* a new deploy or wasm rebuild. `.github/workflows/deploy.yml` has a
`paths-ignore` on this file for exactly that reason. If the raw fetch fails
(offline/CORS), it falls back to the bundled copy shipped in `dist/`.

### CI (`.github/workflows/test-build-deploy.yml`)

`test` (native GHC, `cabal test all`) → `build` (`ghc-wasm-meta` bootstrap +
`./build.sh`) → deploy. Pushes to `main` deploy to the `gh-pages` root; open
PRs get a preview under `gh-pages/pr-preview/pr-<N>/`, cleaned up when the PR
closes. `[skip ci]`/`[ci skip]`/etc. in a commit message (push/PR only, not
manual dispatch) skips the whole workflow.
