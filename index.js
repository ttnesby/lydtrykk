// Boot for NS 8175-kalkulatoren (Miso). Deler wasm-lastingen med kartsiden
// via wasmInit.js – inkludert fallback til deployet app.wasm fra GitHub
// Pages – så siden fungerer lokalt også uten et wasm-bygg (krever nett).
// Dynamisk import: en feilet statisk import (f.eks. manglende
// ghc_wasm_jsffi.js) ville ellers drept hele modulen før try/catch rakk å
// fange noe som helst.
try {
  const { initAcoustics } = await import("./wasmInit.js");
  const exports = await initAcoustics();
  await exports.hs_start();
} catch (e) {
  console.error("WASM-kjernen kunne ikke lastes:", e);
  document.body.insertAdjacentHTML(
    "afterbegin",
    '<p style="margin:16px;padding:12px;border:1px solid #c4362f;border-radius:8px;color:#c4362f;background:#fff">' +
      "Beregningskjernen kunne ikke lastes – sjekk nettilkoblingen og last siden på nytt.</p>",
  );
}
