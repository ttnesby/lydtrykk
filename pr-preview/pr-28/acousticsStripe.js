// Delt dispatch-logikk for rutenett-stripe-kallet mot akustikk-kjernen:
// bygger pumpearrayet og feature-detekterer PerKilde/Skjermet/legacy-
// eksportene (se CLAUDE.md "WASM export surface"). Brukt av gridWorker.js
// (2D, én stripe per worker) og lydnivakart3d.js (3D, hele rutenettet i ett
// synkront hovedtråd-kall) – de to kallerne hadde hver sin nesten identiske
// kopi av nøyaktig denne logikken, som er ren og parameterstyrt uten
// DOM/Worker-avhengighet, så den trekkes ut her i stedet for å holde to
// kopier i synk manuelt (samme "testbar ren modul"-mønster som gridGeo.js/
// grid3d.js). I MOTSETNING til f.eks. FARGE-tabellen og husrekke-
// fetch-mønsteret (se CLAUDE.md) er IKKE denne duplikasjonen et bevisst
// arkitekturvalg et annet sted i kodebasen.
//
// 'pumps' er [{x,y,brg,nivaa}, …] i lokalt plan (se Lyd.Felt-kommentarene for
// konvensjonen); 'polys' er enten null/uten polygoner, eller
// {xy:Float64Array, antall:Float64Array} (se husPolysLocal). 'values' er en
// forhåndsallokert Float64Array som fylles i radmajor-rekkefølge for
// [rowStart, rowEnd) av 'cols' kolonner. Returnerer {uskjermet, fellesnivaa}
// – samme konservative fallback-flagg som før (se gridWorker.js/
// lydnivakart3d.js sine egne kommentarer om hvorfor fallbackene er trygge).
export function beregnStripe(acoustics, pumps, polys, rowStart, rowEnd, cols, cellSizeM, values) {
  const medSkjerm = !!(polys && polys.antall && polys.antall.length > 0);
  const perKilde = typeof acoustics.acoustics_gridStripePerKilde === 'function';
  let uskjermet = false;
  let fellesnivaa = false;

  if (pumps.length === 0) {
    values.fill(-Infinity);
  } else if (perKilde) {
    const xybn = new Float64Array(pumps.length * 4);
    for (let i = 0; i < pumps.length; i++) {
      const p = pumps[i];
      xybn[i * 4] = p.x; xybn[i * 4 + 1] = p.y; xybn[i * 4 + 2] = p.brg; xybn[i * 4 + 3] = p.nivaa;
    }
    if (medSkjerm && typeof acoustics.acoustics_gridStripeSkjermetPerKilde === 'function') {
      acoustics.acoustics_gridStripeSkjermetPerKilde(xybn, polys.xy, polys.antall, rowStart, rowEnd, cols, cellSizeM, values);
    } else {
      uskjermet = medSkjerm;
      acoustics.acoustics_gridStripePerKilde(xybn, rowStart, rowEnd, cols, cellSizeM, values);
    }
  } else {
    const felles = Math.max(...pumps.map(p => p.nivaa));
    fellesnivaa = pumps.some(p => p.nivaa !== felles);
    const xyb = new Float64Array(pumps.length * 3);
    for (let i = 0; i < pumps.length; i++) {
      const p = pumps[i];
      xyb[i * 3] = p.x; xyb[i * 3 + 1] = p.y; xyb[i * 3 + 2] = p.brg;
    }
    if (medSkjerm && typeof acoustics.acoustics_gridStripeSkjermet === 'function') {
      acoustics.acoustics_gridStripeSkjermet(felles, xyb, polys.xy, polys.antall, rowStart, rowEnd, cols, cellSizeM, values);
    } else {
      uskjermet = medSkjerm;
      acoustics.acoustics_gridStripe(felles, xyb, rowStart, rowEnd, cols, cellSizeM, values);
    }
  }
  return { uskjermet, fellesnivaa };
}
