// Delt WASI-boot for akustikk-kjernen (app.wasm). Brukes av både hovedsiden
// (lydnivakart.html) og gridWorker.js, slik at kjernen instansieres identisk
// begge steder og tallene garantert stemmer overens.
import { WASI, OpenFile, File, ConsoleStdout } from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.3.0/dist/index.js";
import ghc_wasm_jsffi from "./ghc_wasm_jsffi.js";

export async function initAcoustics() {
  const wasi = new WASI([], ["GHCRTS=-H64m"], [
    new OpenFile(new File([])),
    ConsoleStdout.lineBuffered((msg) => console.log(`[wasm] ${msg}`)),
    ConsoleStdout.lineBuffered((msg) => console.warn(`[wasm] ${msg}`)),
  ], { debug: false });
  const exports = {};
  const { instance } = await WebAssembly.instantiateStreaming(fetch("app.wasm"), {
    wasi_snapshot_preview1: wasi.wasiImport,
    ghc_wasm_jsffi: ghc_wasm_jsffi(exports),
  });
  Object.assign(exports, instance.exports);
  wasi.initialize(instance);
  return instance.exports;
}
