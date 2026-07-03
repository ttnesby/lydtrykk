# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

### JS tests (node, no dependencies)

The pure JS modules (`frontend/static/gridGeo.js` — projection/marching
squares, `frontend/static/migrering.js` — save-format migration) are tested
with node's built-in runner:

```sh
node --test frontend/test/*.test.mjs
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

Without a wasm build, both HTML pages still run: `wasmInit.js` tries the local
`app.wasm` first, and when that fails it loads the deployed binary (plus its
paired `ghc_wasm_jsffi.js`) from `https://ttnesby.github.io/lydtrykk/` —
GitHub Pages serves both with CORS `*` and correct MIME types. This is enough
to iterate on UI/map logic without the wasm toolchain installed, but it needs
network access, and a *new* JSFFI export that only exists on your branch is
absent from the deployed binary — exercising it requires a local build (or
the PR preview) until it reaches `main`.

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
properties. Change the model here, and check tests — the JS side only *calls*
the core (via WASM), it never re-implements it.

### WASM export surface (`frontend/app/Main.hs`)

Under `#ifdef WASM` (set via `cpp-options: -DWASM` only when
`arch(wasm32)`, see `frontend/frontend.cabal`), `Main.hs` exports five
*synchronous* JSFFI functions layered directly on `Lyd.Beregning`:
`acoustics_dirGain`, `acoustics_reqDist`, `acoustics_levelAt`,
`acoustics_dbSum`, and `acoustics_grense` (limit table by clamped
class/tidsrom enum indices — the map page builds its whole `GRENSE` matrix
from this at boot, so the NS 8175 numbers have no JS copy either; the
`KLASSER`/`TIDSROM` array order in `lydnivakart.html` must match the Haskell
enum order). Synchronous exports (the `" sync"` suffix in the
`foreign export javascript` declarations) are required because both
`lydnivakart.html` and `gridWorker.js` call them inside tight draw/compute
loops — an async/Promise-based export would be unworkable there. The linker
flags that actually expose these symbols from the wasm binary live in
`frontend.cabal`'s `--export=...` list, not in the Haskell source; adding a
new export needs both a `foreign export javascript` line *and* a matching
`--export` flag.

### Single implementation: all math lives in `Lyd.Beregning`

There are no JS copies of the acoustics formulas — nor of the limit table
(fetched via `acoustics_grense`, see above). Every call site (main thread in
`lydnivakart.html`, each `gridWorker.js` instance, and `index.js`) gets the
core through the shared two-stage boot in `wasmInit.js`: local `app.wasm`
first, then the deployed binary from GitHub Pages (see "Commands" above). If
neither loads — or the binary is too old to have `acoustics_grense` — the
pages show a visible error instead of silently computing wrong numbers: on
the map page, matrix/zones/grid render only after `bootAkustikk()` has
received the exports (guards in `drawPump`/`renderMatrise` cover map clicks
that arrive before then), and a worker without a core replies `{error: true}`
so that grid round is skipped.

### Runtime dependencies: vendored WASI shim, SRI-pinned Leaflet

The WASI shim (`@bjorn3/browser_wasi_shim@0.3.0` dist files) is vendored in
`frontend/static/vendor/wasi/` — wasm boot does not depend on jsdelivr being
up; upgrade by re-downloading the dist files. Leaflet still comes from cdnjs
but is pinned with SRI `integrity` hashes in `lydnivakart.html`; bumping the
Leaflet version requires recomputing those hashes
(`curl -s <url> | openssl dgst -sha384 -binary | openssl base64 -A`).

### Testable JS modules (`gridGeo.js`, `migrering.js`)

The map page's main script is one ES module that imports the pure parts from
two node-testable modules (`frontend/test/*.test.mjs`, run in CI before the
Haskell tests): `gridGeo.js` (local planar projection, `destPoint`/`bearing`,
marching squares — returns plain `{lat, lng}` objects, no Leaflet dependency)
and `migrering.js` (`normaliserOppsett`, the tolerant v1/v2/v3 save-format
migration that `restore()` applies).

### `lydnivakart.html`: grid/ekvidistanser feature (the newest, most involved part)

Two draggable corner markers define a rectangular grid over the map. For
each cell, cumulative dB from all placed units is computed and rendered as
dB-equidistance contour lines (custom marching-squares implementation, no
external dependency) at each active class-matrix limit, colored/dashed to
match the existing limit color scale. Where the over-limit region extends
past the grid, the contour is closed along the grid edge
(`boundarySegments` in `gridGeo.js`) — otherwise a saturated edge would be
invisible; simultaneously saturated limits are nested slightly inward per
active limit (strictest outermost) so they don't draw on top of each other.
A soft canvas `L.imageOverlay` (`renderFyll`) tints each cell with the
color of the *highest* active limit it exceeds — flat concentric bands
(one color per cell, deliberately non-accumulating) so the over-limit side
of each contour is readable without map-reading habits.

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
