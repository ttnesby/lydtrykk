// Web Worker: regner kumulativt lydnivå for en rad-stripe av rutenettet.
// Hovedtråden holder en pool av slike workere (se scheduleGrid/computeGrid i
// lydnivakart.html) – hver med sin egen WASM-instans, så beregningen skjer i
// ekte parallell på flere kjerner. Bruker nøyaktig samme akustikk-kjerne
// (Lyd.Beregning via WASM) som resten av appen, med samme JS-fallback-formler
// som hovedsiden hvis WASM ikke lastes, slik at tallene aldri kan avvike.
// Dynamisk import (ikke statisk) slik at en feil her – f.eks. i lokal dev uten
// et WASM-bygg, der ghc_wasm_jsffi.js ikke finnes – ikke stopper hele modulen
// fra å laste. En feilet statisk import ville hindret 'self.onmessage' under i
// å noensinne bli registrert, og workeren ville hengt for alltid. En tidsfrist
// på toppen av dette er et ekstra sikkerhetsnett: ved høy samtidig nettverks-
// belastning (f.eks. mange workere som starter idet siden lastes) kan et
// feilet import()-løfte i praksis aldri avgjøres i enkelte nettlesere – uten
// fristen ville 'await acousticsReady' under bli hengende for alltid.
let acoustics = null;
function timeout(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }
const acousticsReady = Promise.race([
  import("./wasmInit.js").then((m) => m.initAcoustics()).then((exp) => { acoustics = exp; }),
  timeout(5000),
]).catch((e) => console.warn("[gridWorker] WASM kunne ikke lastes – bruker JS-fallback:", e));

function dirGainJS(angleDeg) {
  const a = Math.min(Math.abs(angleDeg), 90);
  return -5 * (1 - Math.cos((a * Math.PI) / 180));
}
function levelAtJS(src, r, angleDeg) {
  return src + dirGainJS(angleDeg) - 20 * Math.log10(r);
}
function dbSumJS(levels) {
  let sum = 0;
  for (let i = 0; i < levels.length; i++) sum += Math.pow(10, levels[i] / 10);
  return 10 * Math.log10(sum);
}

// Planet koordinatsystem (meter fra rutenettets SV-hjørne) – se
// metersPerDeg/toLocal i lydnivakart.html. Cellen (row,col) ligger i
// (x,y) = (col*cellSizeM, row*cellSizeM). Vinkelen beregnes med samme
// bearing-konvensjon (0° = nord, medurs) som resten av appen bruker.
self.onmessage = async (e) => {
  const { reqId, rowStart, rowEnd, cols, cellSizeM, pumps, srcLevel } = e.data;
  await acousticsReady;
  const levelAt = acoustics ? (src, r, a) => acoustics.acoustics_levelAt(src, r, a) : levelAtJS;
  const dbSum = acoustics ? (levels) => acoustics.acoustics_dbSum(levels) : dbSumJS;

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
        levels[i] = levelAt(srcLevel, r, angle);
      }
      values[outIdx] = dbSum(levels);
    }
  }
  self.postMessage({ reqId, rowStart, values }, [values.buffer]);
};
