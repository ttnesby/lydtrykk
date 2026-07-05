// Web Worker: regner kumulativt lydnivå for en rad-stripe av rutenettet.
// Hovedtråden holder en pool av slike workere (se scheduleGrid/computeGrid i
// lydnivakart.html) – hver med sin egen WASM-instans, så beregningen skjer i
// ekte parallell på flere kjerner. Bruker nøyaktig samme akustikk-kjerne
// (Lyd.Beregning/Lyd.Felt via WASM) som resten av appen; wasmInit.js henter
// deployet app.wasm fra GitHub Pages hvis den lokale mangler. Det finnes
// ingen JS-kopi av formlene – kan kjernen ikke lastes, svares det med error,
// og hovedtråden hopper over runden i stedet for å regne stille feil.
// Hele stripen regnes med ETT kall til acoustics_gridStripe – eller
// acoustics_gridStripeSkjermet når husrekke-polygonene er med (hele
// celle-løkken ligger i Haskell, Lyd.Felt). En kjerne uten gridStripe-
// eksporten (binær eldre enn Lyd.Felt-omleggingen) behandles som manglende
// kjerne – error-svar, runden hoppes over – synlig feil fremfor en stille
// alternativ regnesti i JS.
// Dynamisk import (ikke statisk) slik at en feil her – f.eks. i lokal dev uten
// et WASM-bygg, der ghc_wasm_jsffi.js ikke finnes – ikke stopper hele modulen
// fra å laste. En feilet statisk import ville hindret 'self.onmessage' under i
// å noensinne bli registrert, og workeren ville hengt for alltid. En tidsfrist
// på toppen av dette er et ekstra sikkerhetsnett: ved høy samtidig nettverks-
// belastning (f.eks. mange workere som starter idet siden lastes) kan et
// feilet import()-løfte i praksis aldri avgjøres i enkelte nettlesere – uten
// fristen ville 'await acousticsReady' under bli hengende for alltid. Lykkes
// lastingen etter fristen, plukkes 'acoustics' opp av neste melding.
let acoustics = null;
function timeout(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }
const acousticsReady = Promise.race([
  import("./wasmInit.js").then((m) => m.initAcoustics()).then((exp) => { acoustics = exp; }),
  timeout(5000),
]).catch((e) => console.warn("[gridWorker] WASM kunne ikke lastes:", e));

// Planet koordinatsystem (meter fra rutenettets SV-hjørne) – se
// metersPerDeg/toLocal i lydnivakart.html. Cellen (row,col) ligger i
// (x,y) = (col*cellSizeM, row*cellSizeM). Vinkelen beregnes med samme
// bearing-konvensjon (0° = nord, medurs) som resten av appen bruker.
// 'polys' (valgfri) er husrekkene i samme lokale plan – {xy, antall} med alle
// hjørnene flatt [x0,y0,x1,…] og antall hjørner per polygon. Med polygoner
// brukes acoustics_gridStripeSkjermet (NaN-maskering + siktlinjeskjerming,
// Lyd.Felt.rutenettStripeSkjermet). Mangler den eksporten (eldre deployet
// binær) regnes stripen USKJERMET med den gamle eksporten og svaret merkes
// 'uskjermet' – trygt i konservativ retning (skjerming senker bare nivåene),
// og hovedtråden viser det synlig i stedet for at runden feiler.
self.onmessage = async (e) => {
  const { reqId, rowStart, rowEnd, cols, cellSizeM, pumps, srcLevel, polys } = e.data;
  await acousticsReady;
  if (!acoustics || typeof acoustics.acoustics_gridStripe !== "function") {
    self.postMessage({ reqId, error: true });
    return;
  }

  const rows = rowEnd - rowStart;
  const values = new Float64Array(rows * cols);
  const medSkjerm = polys && polys.antall && polys.antall.length > 0;
  let uskjermet = false;

  if (pumps.length === 0) {
    values.fill(-Infinity);
  } else {
    // Pumpene som flat stride-3-array [x0,y0,brg0, x1,…]; Haskell fyller
    // 'values' radmajor i ett kall.
    const xyb = new Float64Array(pumps.length * 3);
    for (let i = 0; i < pumps.length; i++) {
      const p = pumps[i];
      xyb[i * 3] = p.x; xyb[i * 3 + 1] = p.y; xyb[i * 3 + 2] = p.brg;
    }
    if (medSkjerm && typeof acoustics.acoustics_gridStripeSkjermet === "function") {
      acoustics.acoustics_gridStripeSkjermet(srcLevel, xyb, polys.xy, polys.antall, rowStart, rowEnd, cols, cellSizeM, values);
    } else {
      uskjermet = medSkjerm;
      acoustics.acoustics_gridStripe(srcLevel, xyb, rowStart, rowEnd, cols, cellSizeM, values);
    }
  }
  self.postMessage({ reqId, rowStart, values, uskjermet }, [values.buffer]);
};
