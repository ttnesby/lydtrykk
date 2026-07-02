// Web Worker: regner kumulativt lydnivå for en rad-stripe av rutenettet.
// Hovedtråden holder en pool av slike workere (se scheduleGrid/computeGrid i
// lydnivakart.html) – hver med sin egen WASM-instans, så beregningen skjer i
// ekte parallell på flere kjerner. Bruker nøyaktig samme akustikk-kjerne
// (Lyd.Beregning via WASM) som resten av appen; wasmInit.js henter deployet
// app.wasm fra GitHub Pages hvis den lokale mangler. Det finnes ingen
// JS-kopi av formlene – kan kjernen ikke lastes, svares det med error, og
// hovedtråden hopper over runden i stedet for å regne stille feil.
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
self.onmessage = async (e) => {
  const { reqId, rowStart, rowEnd, cols, cellSizeM, pumps, srcLevel } = e.data;
  await acousticsReady;
  if (!acoustics) { self.postMessage({ reqId, error: true }); return; }

  const rows = rowEnd - rowStart;
  const values = new Float64Array(rows * cols);
  const levels = new Float64Array(pumps.length);

  for (let row = rowStart; row < rowEnd; row++) {
    const y = row * cellSizeM;
    for (let col = 0; col < cols; col++) {
      const outIdx = (row - rowStart) * cols + col;
      if (pumps.length === 0) {
        values[outIdx] = -Infinity;
        continue;
      }
      const x = col * cellSizeM;
      for (let i = 0; i < pumps.length; i++) {
        const p = pumps[i];
        const dx = x - p.x, dy = y - p.y;
        const r = Math.max(Math.hypot(dx, dy), 1);
        const brgToCell = ((Math.atan2(dx, dy) * 180) / Math.PI + 360) % 360;
        const angle = Math.abs(((brgToCell - p.brg + 540) % 360) - 180);
        levels[i] = acoustics.acoustics_levelAt(srcLevel, r, angle);
      }
      values[outIdx] = acoustics.acoustics_dbSum(levels);
    }
  }
  self.postMessage({ reqId, rowStart, values }, [values.buffer]);
};
