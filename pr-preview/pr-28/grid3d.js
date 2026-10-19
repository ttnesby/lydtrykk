// Ren rutenett-/geometrilogikk for 3D-visningen (lydnivakart3d.js): ingen
// MapLibre/DOM-avhengighet, så modulen testes med Node
// (frontend/test/grid3d.test.mjs) akkurat som gridGeo.js/migrering.js/
// husrekker.js. lydnivakart3d.js sine egne, 3D-spesifikke valg (MAX_CELLS,
// VEGG_HALVBREDDE_M, HUS_HOYDE_M, EKSTRA_ETASJE_M, farger) blir værende der
// – dette er bare de rene regnestykkene/geometribyggerne.
import { toLocal, fromLocal } from './gridGeo.js';

// gridDims()-ekvivalent fra lydnivakart.html:685 – regner cols/rows fra det
// overførte grid-oppsettet (sw/ne/res), med samme MAX_CELLS-grovning. Tallet
// selv ('maxCells') er en parameter (ikke en modul-konstant) nettopp for at
// denne funksjonen skal være ren og testbar uavhengig av hvilket tak
// 3D-siden velger å bruke (lavere enn 2D sitt, se lydnivakart3d.js).
export function gridDimsFraOppsett(grid, maxCells) {
  const sw = { lat: Math.min(grid.sw.lat, grid.ne.lat), lng: Math.min(grid.sw.lng, grid.ne.lng) };
  const ne = { lat: Math.max(grid.sw.lat, grid.ne.lat), lng: Math.max(grid.sw.lng, grid.ne.lng) };
  const { x: wRaw, y: hRaw } = toLocal(ne, sw);
  const w = Math.max(wRaw, 2), h = Math.max(hRaw, 2);
  let res = grid.res || 2, coarsened = false;
  let cols = Math.max(2, Math.round(w / res) + 1), rows = Math.max(2, Math.round(h / res) + 1);
  if (cols * rows > maxCells) {
    res = res * Math.sqrt((cols * rows) / maxCells);
    cols = Math.max(2, Math.round(w / res) + 1);
    rows = Math.max(2, Math.round(h / res) + 1);
    coarsened = true;
  }
  return { sw, res, cols, rows, coarsened };
}

// Effektivt kildenivå – samme klamping/regnestykke som nivaaAv() i
// lydnivakart.html. 'globale' er {lyd,vegg,kab} fra det overførte oppsettets
// toppnivå-felter (opp.lyd/vegg/kab); en pumpe med 'lokal' bruker sine egne.
export function nivaaAv(v) {
  const lyd = Math.min(70, Math.max(40, parseFloat(v.lyd) || 0));
  const vegg = v.vegg ? 3 : 0;
  const kab = Math.max(0, parseFloat(v.kab) || 0);
  return lyd + vegg - kab;
}

export function pumpsLocal(pumps, origin, globale) {
  return pumps.map(p => ({ ...toLocal({ lat: p.lat, lng: p.lng }, origin), brg: p.brg, nivaa: nivaaAv(p.lokal || globale) }));
}

export function husPolysLocal(husRekker, origin) {
  const antall = [], xy = [];
  husRekker.forEach(r => {
    antall.push(r.punkter.length);
    r.punkter.forEach(pt => { const l = toLocal(pt, origin); xy.push(l.x, l.y); });
  });
  return { xy: new Float64Array(xy), antall: new Float64Array(antall) };
}

// Lukker en åpen punktring ({lat,lng}[] fra normaliserHusrekke, som ikke
// dupliserer siste==første) til en GeoJSON-koordinatring [[lng,lat],...].
function lukketRing(punkter) {
  return [...punkter.map(p => [p.lng, p.lat]), [punkter[0].lng, punkter[0].lat]];
}

export function husrekkerGeoJSON(husRekker) {
  return {
    type: 'FeatureCollection',
    features: husRekker.map(r => ({
      type: 'Feature',
      properties: { navn: r.navn },
      geometry: { type: 'Polygon', coordinates: [lukketRing(r.punkter)] },
    })),
  };
}

// Delpolygonene for enheter med 3. etasje (normaliserHusrekke sitt valgfrie
// 'tredjeEtasje'-felt), flatet ut til én FeatureCollection på tvers av alle
// rekker – konsumeres som ett eget fill-extrusion-lag, stablet oppå
// hoved-ekstruderingen (base = husets grunnhøyde) i lydnivakart3d.js.
export function tredjeEtasjeGeoJSON(husRekker) {
  return {
    type: 'FeatureCollection',
    features: husRekker.flatMap(r => r.tredjeEtasje.map(punkter => ({
      type: 'Feature',
      properties: { navn: r.navn },
      geometry: { type: 'Polygon', coordinates: [lukketRing(punkter)] },
    }))),
  };
}

// Bygger en tynn, ekstrudérbar stripe-polygon per kontursegment: samme
// segmenter (rad/kolonne-koordinater) som renderContours() i lydnivakart.html
// bruker til konturlinjene i 2D, bufret vinkelrett i det lokale metriske
// planet (ikke i lat/lng, som ikke er metrisk) før projeksjon til lat/lng.
export function veggerGeoJSON(segments, res, sw, halvbredde) {
  const features = [];
  for (const [p0, p1] of segments) {
    const x0 = p0[1] * res, y0 = p0[0] * res;
    const x1 = p1[1] * res, y1 = p1[0] * res;
    const dx = x1 - x0, dy = y1 - y0, len = Math.hypot(dx, dy);
    if (len === 0) continue;
    const nx = (-dy / len) * halvbredde, ny = (dx / len) * halvbredde;
    const hjorner = [[x0 + nx, y0 + ny], [x1 + nx, y1 + ny], [x1 - nx, y1 - ny], [x0 - nx, y0 - ny], [x0 + nx, y0 + ny]];
    const ring = hjorner.map(([x, y]) => { const { lat, lng } = fromLocal(x, y, sw); return [lng, lat]; });
    features.push({ type: 'Feature', geometry: { type: 'Polygon', coordinates: [ring] } });
  }
  return { type: 'FeatureCollection', features };
}
