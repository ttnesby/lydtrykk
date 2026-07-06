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

// Lokale lydkilde-verdier per utedel (additivt felt på pumps[]): et gyldig
// objekt med tallverdi for 'lyd' går gjennom (vegg/kab leses defensivt),
// alt annet – manglende felt, eldre filer, søppel – blir null (= arv de
// globale verdiene). Verdiene klampes ikke her; det gjør nivaaAv() ved bruk,
// samme sted som de globale klampes.
function normaliserLokal(lokal) {
  if (!lokal || typeof lokal !== 'object') return null;
  const lyd = parseFloat(lokal.lyd);
  if (!Number.isFinite(lyd)) return null;
  return { lyd, vegg: !!lokal.vegg, kab: Number.isFinite(parseFloat(lokal.kab)) ? parseFloat(lokal.kab) : 0 };
}

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
    // husrekker på/av, skjerming og verste fasadepunkt (additive felter);
    // mangler de → null = behold nåværende. husOn er hovedbryteren,
    // husSkjerm/husVerst underpunktene.
    husOn: s.husOn != null ? !!s.husOn : null,
    husSkjerm: s.husSkjerm != null ? !!s.husSkjerm : null,
    husVerst: s.husVerst != null ? !!s.husVerst : null,
    // eldre filer kan ha et 'nabos'-felt – det ignoreres stille, siden
    // rutenettet erstattet enkeltpunkt-sjekken
    pumps: (d.pumps || []).map(p => ({
      num: p.num, lat: p.lat, lng: p.lng, brg: p.brg,
      lokal: normaliserLokal(p.lokal),
    })),
    grid: d.grid || null,
    gridOn: d.grid && d.grid.on != null ? d.grid.on : true,
    view: d.view && d.view.center ? { center: d.view.center, zoom: d.view.zoom } : null,
  };
}
