// Normalisering/migrering av lagrede lydnivakart-oppsett (se snapshot()/
// restore() i lydnivakart.html). Ren funksjon uten DOM/Leaflet, så
// migreringslogikken kan testes med Node (frontend/test/migrering.test.mjs).
//
// Tolererer alle historiske formater:
// - v1: settings.mode/mount (lydkilde) og settings.bands (navngitte soner)
// - v2: settings.lyd/vegg/kab + settings.limits; 'nabos'-feltet ignoreres
// - v3: som v2 + grid (hjørner/oppløsning/av-på)
// Nye felter legges til additivt og leses defensivt her – ikke bump versjonen
// for tolerante utvidelser.

// v1-bands → dB-grenser. Tallene beskriver det historiske filformatet
// (hvilken grense hvert navn betydde da formatet var i bruk), ikke modellen.
const V1_BANDS = { natBp: 28, nattB: 30, nattC: 35, kvC: 40, dagC: 45 };

// Returnerer et normalisert oppsett, eller null hvis 'd' ikke er et
// lydnivakart-oppsett. Felter som ikke finnes i fila blir null («behold
// nåværende verdi») – unntatt gridOn, som alltid har vært på når feltet
// mangler.
export function normaliserOppsett(d) {
  if (!d || d.format !== 'lydnivakart') return null;
  const s = d.settings || {};

  // lydkilde: v2/v3 (lyd/vegg/kab) eller migrering fra v1 (mode/mount)
  let lyd, vegg, kab;
  if (s.lyd != null) { lyd = s.lyd; vegg = !!s.vegg; kab = s.kab || 0; }
  else { lyd = parseFloat(s.mode) || 50; vegg = String(s.mount) === '3'; kab = 0; }

  // soner: v2/v3 (limits) eller v1 (bands); mangler begge → null
  let limits = null;
  if (Array.isArray(s.limits)) limits = [...s.limits];
  else if (s.bands) limits = Object.keys(V1_BANDS).filter(k => s.bands[k]).map(k => V1_BANDS[k]);

  return {
    lyd, vegg, kab, limits,
    defdir: s.defdir != null ? s.defdir : null,
    base: s.base != null ? s.base : null,
    // eldre filer kan ha et 'nabos'-felt – det ignoreres stille, siden
    // rutenettet erstattet enkeltpunkt-sjekken
    pumps: (d.pumps || []).map(p => ({ num: p.num, lat: p.lat, lng: p.lng, brg: p.brg })),
    grid: d.grid || null,
    gridOn: d.grid && d.grid.on != null ? d.grid.on : true,
    view: d.view && d.view.center ? { center: d.view.center, zoom: d.view.zoom } : null,
  };
}
