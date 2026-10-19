// Delt WASI-boot for akustikk-kjernen (app.wasm). Brukes av kalkulatoren
// (index.js), kartsiden (lydnivakart.html) og gridWorker.js, slik at kjernen
// instansieres identisk alle steder og tallene garantert stemmer overens.
//
// To-trinns lasting, men KUN i lokal dev (se erLokalDev under): lokal
// app.wasm først; mangler den – typisk lokal utvikling uten wasm-
// verktøykjede – hentes den deployede binæren fra GitHub Pages i stedet
// (serveres med CORS * og application/wasm). I produksjon og PR-preview
// skal dist/app.wasm alltid finnes (CI bygger den), så der er IKKE dette
// fallbacket med: en feilet lokal lasting der kastes videre uendret, slik at
// siden viser sin vanlige feilmelding i stedet for å stille teste mot en
// annen (og for en PR-preview: potensielt en helt annen) binær enn den som
// faktisk ble deployet. Matematikken kommer dermed alltid fra
// Lyd.Beregning; det finnes ingen JS-kopi av formlene.
// WASI-shimen er vendored (vendor/wasi/ = dist-filene fra
// @bjorn3/browser_wasi_shim@0.3.0), så wasm-boot ikke avhenger av at
// jsdelivr er oppe. Oppgradering: last ned nye dist-filer til samme mappe.
import { WASI, OpenFile, File, ConsoleStdout } from "./vendor/wasi/index.js";

const REMOTE_BASE = "https://ttnesby.github.io/lydtrykk/";

// Er vi i lokal dev (ingen wasm-bygg forventet)? location finnes både i
// vindu- og Worker-scope. file:// gir tomt hostname.
function erLokalDev() {
  const { hostname, protocol } = location;
  return protocol === "file:" || hostname === "localhost" || hostname === "127.0.0.1" || hostname === "[::1]";
}

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
    if (!erLokalDev()) throw lokalFeil;   // prod/PR-preview: ikke bytt stille til en annen binær
    console.warn("[wasm] lokal app.wasm utilgjengelig – prøver deployet versjon (kun lokal dev):", lokalFeil);
    const exports = await instansier(REMOTE_BASE);
    console.log(`[wasm] akustikk-kjernen lastet fra ${REMOTE_BASE} (deployet versjon)`);
    return exports;
  }
}
