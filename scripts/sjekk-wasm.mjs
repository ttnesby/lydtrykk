// Røyktest for den bygde binæren: kan dist/app.wasm faktisk kompileres og
// instansieres med standard WebAssembly, slik en nettleser gjør det?
//
// Bakgrunn: binaryen 133 + `wasm-opt -all -Oz` skrev en app.wasm med
// eksperimentelle features («compact imports», import kind 0x7e, og
// exact-heap-typer). Bygget og CI var grønne, men ingen nettleser kunne
// kompilere binæren, og produksjonssiden viste «Beregningskjernen kunne ikke
// lastes». Denne sjekken kjøres i CI etter ./build.sh og stopper deploy før
// en slik binær når gh-pages.
//
// Kjøres uten --experimental-wasm-*-flagg, så node (V8) godtar bare
// standardiserte, default-på features – samme grunnlag som Chrome. Det er
// ingen garanti for Safari/Firefox, men fanger nettopp typen feil over.
//
// Bruk: node scripts/sjekk-wasm.mjs [katalog]   (standard: dist)
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { WASI, OpenFile, File, ConsoleStdout } from "../frontend/static/vendor/wasi/index.js";

const katalog = resolve(process.argv[2] ?? "dist");

function feil(steg, e) {
  console.error(`feil: ${katalog}/app.wasm – ${steg}: ${e?.message ?? e}`);
  process.exit(1);
}

const bytes = await readFile(resolve(katalog, "app.wasm")).catch((e) => feil("kunne ikke leses", e));

// 1) Kompilering – det som feilet i nettleserne med binaryen 133 + -all.
const modul = await WebAssembly.compile(bytes).catch((e) => feil("WebAssembly.compile feilet", e));

// 2) Instansiering etter samme mønster som instansier() i
// frontend/static/wasmInit.js: vendored WASI-shim + paret ghc_wasm_jsffi.js.
// Fanger f.eks. en jsffi-fil som ikke hører til binæren (manglende imports).
let exports;
try {
  const jsffi = (await import(pathToFileURL(resolve(katalog, "ghc_wasm_jsffi.js")).href)).default;
  const wasi = new WASI([], ["GHCRTS=-H64m"], [
    new OpenFile(new File([])),
    ConsoleStdout.lineBuffered((msg) => console.log(`[wasm] ${msg}`)),
    ConsoleStdout.lineBuffered((msg) => console.warn(`[wasm] ${msg}`)),
  ], { debug: false });
  exports = {};
  const instance = await WebAssembly.instantiate(modul, {
    wasi_snapshot_preview1: wasi.wasiImport,
    ghc_wasm_jsffi: jsffi(exports),
  });
  Object.assign(exports, instance.exports);
  wasi.initialize(instance);
} catch (e) {
  feil("instansiering feilet", e);
}

// 3) Ett ekte kall inn i kjernen: grenseverdien for klasse A / dag. Kartsiden
// bygger hele grensematrisen fra denne eksporten ved oppstart, så den må finnes
// og gi et endelig, positivt tall.
if (typeof exports.acoustics_grense !== "function") feil("mangler eksporten acoustics_grense", "");
let grense;
try {
  grense = exports.acoustics_grense(0, 0);
} catch (e) {
  feil("kall til acoustics_grense(0, 0) feilet", e);
}
if (!Number.isFinite(grense) || grense <= 0) feil("acoustics_grense(0, 0) ga ugyldig verdi", String(grense));

console.log(`ok: ${katalog}/app.wasm kompilerer og instansierer (acoustics_grense(0, 0) = ${grense} dBA)`);
