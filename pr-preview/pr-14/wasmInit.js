// Delt WASI-boot for akustikk-kjernen (app.wasm). Brukes av kalkulatoren
// (index.js), kartsiden (lydnivakart.html) og gridWorker.js, slik at kjernen
// instansieres identisk alle steder og tallene garantert stemmer overens.
//
// To-trinns lasting: lokal app.wasm først (et ekte bygg, f.eks. dist/);
// mangler den – typisk lokal utvikling uten wasm-verktøykjede – hentes den
// deployede binæren fra GitHub Pages i stedet (serveres med CORS * og
// application/wasm). Matematikken kommer dermed alltid fra Lyd.Beregning;
// det finnes ingen JS-kopi av formlene. Kan ingen av kildene lastes, kastes
// feilen videre til kalleren, som viser en synlig feilmelding.
import { WASI, OpenFile, File, ConsoleStdout } from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.3.0/dist/index.js";

const REMOTE_BASE = "https://ttnesby.github.io/lydtrykk/";

async function instansier(base) {
  // Dynamisk, base-relativ import: ghc_wasm_jsffi.js må komme fra samme sted
  // som app.wasm (post-link.mjs genererer dem i par).
  const jsffi = (await import(new URL("ghc_wasm_jsffi.js", base).href)).default;
  const wasi = new WASI([], ["GHCRTS=-H64m"], [
    new OpenFile(new File([])),
    ConsoleStdout.lineBuffered((msg) => console.log(`[wasm] ${msg}`)),
    ConsoleStdout.lineBuffered((msg) => console.warn(`[wasm] ${msg}`)),
  ], { debug: false });
  const exports = {};
  const { instance } = await WebAssembly.instantiateStreaming(fetch(new URL("app.wasm", base)), {
    wasi_snapshot_preview1: wasi.wasiImport,
    ghc_wasm_jsffi: jsffi(exports),
  });
  Object.assign(exports, instance.exports);
  wasi.initialize(instance);
  return instance.exports;
}

export async function initAcoustics() {
  try {
    const exports = await instansier(import.meta.url);
    console.log("[wasm] akustikk-kjernen lastet lokalt");
    return exports;
  } catch (lokalFeil) {
    console.warn("[wasm] lokal app.wasm utilgjengelig – prøver deployet versjon:", lokalFeil);
    const exports = await instansier(REMOTE_BASE);
    console.log(`[wasm] akustikk-kjernen lastet fra ${REMOTE_BASE} (deployet versjon)`);
    return exports;
  }
}
