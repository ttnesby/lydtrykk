// 3D-visning av et lydnivakart-oppsett overført fra lydnivakart.html.
// Read-only: viser posisjoner (pumper/husrekker) pluss dB-ekvidistansene som
// ekstruderte vegger. Redigering skjer fortsatt i 2D-simulatoren.
import { normaliserOppsett } from './migrering.js';
import { normaliserHusrekke } from './husrekker.js';
import { toLocal, fromLocal, marchingSquares, boundarySegments } from './gridGeo.js';
import { initAcoustics } from './wasmInit.js';

const SESSION_KEY = 'lydnivakart3d:config';

// Samme hybrid-fetch-med-fallback som loadHusrekker() i lydnivakart.html
// (raw fra main → dist/PR-preview → dev-server fra repo-rota). Ikke delt som
// modul siden de to sidene er selvstendige (samme mønster som ellers i repoet).
const HUS_BASER = [
  'https://raw.githubusercontent.com/ttnesby/lydtrykk/main/husrekker/polygoner/',
  'husrekker/polygoner/',
  '../../husrekker/polygoner/',
];

// Ekte bygningshøyde finnes ikke i husrekker/polygoner/*.json ennå – midlertidig
// fast ekstruderingshøyde til dataene finnes.
const HUS_HOYDE_M = 6;

// Farge per dB-grense, duplisert fra FARGE/heat() i lydnivakart.html – samme
// farge på veggene her som på konturlinjene i 2D (de to sidene er selvstendige,
// ingen delt modul for denne vesle tabellen).
const FARGE = { 25: '#dc2626', 28: '#ea580c', 30: '#d97706', 33: '#ca8a04', 35: '#2563eb', 38: '#0891b2', 40: '#059669', 45: '#65a30d' };
function heat(limit) { return FARGE[limit] || '#888'; }

// Rene visuelle konstanter for veggenes høyde – ingen fysisk betydning (dB er
// ikke meter). Stigende med dB gir en trappet form: strengeste/lengst-unna
// grense lavest, mildeste/nærmest kilden høyest – samme konvensjon som
// fargeleggingen i 2D (varm = strengest = ytterst).
const DB_BASISLINJE = 20;
const DB_TIL_METER = 0.6;
const VEGG_HALVBREDDE_M = 0.3;

// Tak på celletall, samme sikkerhetsnett som MAX_CELLS i lydnivakart.html –
// et veldig stort overført rutenett skal grovnes automatisk, ikke fryse fanen
// (denne siden regner ett synkront hovedtråd-kall, ingen worker-pool).
const MAX_CELLS = 400000;

async function hentHusrekker() {
  const get = url => fetch(url + '?t=' + Date.now(), { cache: 'no-store' })
    .then(r => { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); });
  for (const base of HUS_BASER) {
    let filer;
    try { ({ filer } = await get(base + 'index.json')); } catch (e) { continue; }
    if (!Array.isArray(filer)) continue;
    const rekker = await Promise.all(filer.map(f =>
      get(base + f).then(normaliserHusrekke)
        .catch(e => { console.warn(`Husrekka ${f} hoppes over:`, e); return null; })));
    return rekker.filter(Boolean);
  }
  console.warn('Ingen husrekker funnet – index.json utilgjengelig fra alle kandidatene.');
  return [];
}

async function bootWasmSafe() {
  try { return await initAcoustics(); }
  catch (e) { console.warn('[3d] akustikk-kjernen kunne ikke lastes:', e); return null; }
}

function bboxSenter(pumps, husRekker) {
  const pts = [
    ...pumps.map(p => [p.lat, p.lng]),
    ...husRekker.flatMap(r => r.punkter.map(pt => [pt.lat, pt.lng])),
  ];
  if (!pts.length) return null;
  const lats = pts.map(p => p[0]), lngs = pts.map(p => p[1]);
  return { center: [(Math.min(...lngs) + Math.max(...lngs)) / 2, (Math.min(...lats) + Math.max(...lats)) / 2], zoom: 18 };
}

function husrekkerGeoJSON(husRekker) {
  return {
    type: 'FeatureCollection',
    features: husRekker.map(r => ({
      type: 'Feature',
      properties: { navn: r.navn },
      geometry: {
        type: 'Polygon',
        // GeoJSON krever lukket ring; normaliserHusrekke returnerer en åpen
        // ring (Leaflet lukker selv) – tetter den igjen her.
        coordinates: [[...r.punkter.map(p => [p.lng, p.lat]), [r.punkter[0].lng, r.punkter[0].lat]]],
      },
    })),
  };
}

// ---- rutenett (dB-vegger) ----
// gridDims()-ekvivalent fra lydnivakart.html:685 – regner cols/rows fra det
// overførte grid-oppsettet (sw/ne/res), med samme MAX_CELLS-grovning.
function gridDimsFraOppsett(grid) {
  const sw = { lat: Math.min(grid.sw.lat, grid.ne.lat), lng: Math.min(grid.sw.lng, grid.ne.lng) };
  const ne = { lat: Math.max(grid.sw.lat, grid.ne.lat), lng: Math.max(grid.sw.lng, grid.ne.lng) };
  const { x: wRaw, y: hRaw } = toLocal(ne, sw);
  const w = Math.max(wRaw, 2), h = Math.max(hRaw, 2);
  let res = grid.res || 2;
  let cols = Math.max(2, Math.round(w / res) + 1), rows = Math.max(2, Math.round(h / res) + 1);
  if (cols * rows > MAX_CELLS) {
    res = res * Math.sqrt((cols * rows) / MAX_CELLS);
    cols = Math.max(2, Math.round(w / res) + 1);
    rows = Math.max(2, Math.round(h / res) + 1);
  }
  return { sw, res, cols, rows };
}

// Effektivt kildenivå – samme klamping/regnestykke som nivaaAv() i
// lydnivakart.html. 'globale' er {lyd,vegg,kab} fra det overførte oppsettets
// toppnivå-felter (opp.lyd/vegg/kab); en pumpe med 'lokal' bruker sine egne.
function nivaaAv(v) {
  const lyd = Math.min(70, Math.max(40, parseFloat(v.lyd) || 0));
  const vegg = v.vegg ? 3 : 0;
  const kab = Math.max(0, parseFloat(v.kab) || 0);
  return lyd + vegg - kab;
}
function pumpsLocal(pumps, origin, globale) {
  return pumps.map(p => ({ ...toLocal({ lat: p.lat, lng: p.lng }, origin), brg: p.brg, nivaa: nivaaAv(p.lokal || globale) }));
}
function husPolysLocal(husRekker, origin) {
  const antall = [], xy = [];
  husRekker.forEach(r => {
    antall.push(r.punkter.length);
    r.punkter.forEach(pt => { const l = toLocal(pt, origin); xy.push(l.x, l.y); });
  });
  return { xy: new Float64Array(xy), antall: new Float64Array(antall) };
}

// Mirrorer WASM-kallkonvensjonen i gridWorker.js (samme stride-4-pumper, samme
// feature-detect/fallback-rekkefølge for PerKilde/Skjermet-eksportene), men
// som ETT synkront hovedtråd-kall (rowStart=0, rowEnd=rows) – denne siden er
// en statisk engangsvisning, ingen worker-pool å holde jevn under dragging.
function beregnRutenett(opp, husRekker, acoustics) {
  if (typeof acoustics.acoustics_gridStripe !== 'function') {
    return { feil: 'app.wasm mangler rutenett-eksporten (eldre binær) – bygg lokalt eller bruk PR-previewen.' };
  }
  const { sw, res, cols, rows } = gridDimsFraOppsett(opp.grid);
  const globale = { lyd: opp.lyd, vegg: opp.vegg, kab: opp.kab };
  const pl = pumpsLocal(opp.pumps, sw, globale);
  const medHus = opp.husOn && opp.husSkjerm;
  const polys = medHus ? husPolysLocal(husRekker, sw) : null;
  const medSkjerm = !!(polys && polys.antall.length > 0);
  const perKilde = typeof acoustics.acoustics_gridStripePerKilde === 'function';
  const values = new Float64Array(rows * cols);
  let uskjermet = false, fellesnivaa = false;

  if (pl.length === 0) {
    values.fill(-Infinity);
  } else if (perKilde) {
    const xybn = new Float64Array(pl.length * 4);
    pl.forEach((p, i) => { xybn[i * 4] = p.x; xybn[i * 4 + 1] = p.y; xybn[i * 4 + 2] = p.brg; xybn[i * 4 + 3] = p.nivaa; });
    if (medSkjerm && typeof acoustics.acoustics_gridStripeSkjermetPerKilde === 'function') {
      acoustics.acoustics_gridStripeSkjermetPerKilde(xybn, polys.xy, polys.antall, 0, rows, cols, res, values);
    } else {
      uskjermet = medSkjerm;
      acoustics.acoustics_gridStripePerKilde(xybn, 0, rows, cols, res, values);
    }
  } else {
    const felles = Math.max(...pl.map(p => p.nivaa));
    fellesnivaa = pl.some(p => p.nivaa !== felles);
    const xyb = new Float64Array(pl.length * 3);
    pl.forEach((p, i) => { xyb[i * 3] = p.x; xyb[i * 3 + 1] = p.y; xyb[i * 3 + 2] = p.brg; });
    if (medSkjerm && typeof acoustics.acoustics_gridStripeSkjermet === 'function') {
      acoustics.acoustics_gridStripeSkjermet(felles, xyb, polys.xy, polys.antall, 0, rows, cols, res, values);
    } else {
      uskjermet = medSkjerm;
      acoustics.acoustics_gridStripe(felles, xyb, 0, rows, cols, res, values);
    }
  }
  return { grid: values, rows, cols, res, sw, uskjermet, fellesnivaa };
}

// Bygger en tynn, ekstrudérbar stripe-polygon per kontursegment: samme
// segmenter (rad/kolonne-koordinater) som renderContours() i lydnivakart.html
// bruker til konturlinjene i 2D, bufret vinkelrett i det lokale metriske
// planet (ikke i lat/lng, som ikke er metrisk) før projeksjon til lat/lng.
function veggerGeoJSON(segments, res, sw) {
  const features = [];
  for (const [p0, p1] of segments) {
    const x0 = p0[1] * res, y0 = p0[0] * res;
    const x1 = p1[1] * res, y1 = p1[0] * res;
    const dx = x1 - x0, dy = y1 - y0, len = Math.hypot(dx, dy);
    if (len === 0) continue;
    const nx = (-dy / len) * VEGG_HALVBREDDE_M, ny = (dx / len) * VEGG_HALVBREDDE_M;
    const hjorner = [[x0 + nx, y0 + ny], [x1 + nx, y1 + ny], [x1 - nx, y1 - ny], [x0 - nx, y0 - ny], [x0 + nx, y0 + ny]];
    const ring = hjorner.map(([x, y]) => { const { lat, lng } = fromLocal(x, y, sw); return [lng, lat]; });
    features.push({ type: 'Feature', geometry: { type: 'Polygon', coordinates: [ring] } });
  }
  return { type: 'FeatureCollection', features };
}

function leggTilVegger(map, opp, resultat) {
  const { grid, rows, cols, res, sw } = resultat;
  const aktive = [...opp.limits].sort((a, b) => a - b);
  aktive.forEach(lim => {
    const segs = marchingSquares(grid, rows, cols, lim).concat(boundarySegments(grid, rows, cols, lim));
    if (!segs.length) return;
    const srcId = `vegg-${lim}`;
    map.addSource(srcId, { type: 'geojson', data: veggerGeoJSON(segs, res, sw) });
    map.addLayer({
      id: srcId,
      type: 'fill-extrusion',
      source: srcId,
      paint: {
        'fill-extrusion-color': heat(lim),
        'fill-extrusion-height': Math.max(0.5, (lim - DB_BASISLINJE) * DB_TIL_METER),
        'fill-extrusion-base': 0,
        'fill-extrusion-opacity': 0.9,
      },
    });
  });
  return aktive;
}

function visFargenokkel(aktive) {
  const info = document.getElementById('info');
  const deler = aktive.map(lim => `<span class="sw" style="background:${heat(lim)}"></span>${lim} dB(A)`);
  info.innerHTML = `dB-vegger: ${deler.join('')}`;
}

async function start(opp) {
  const melding = document.getElementById('melding');
  melding.textContent = `${opp.pumps.length} utedel(er) overført`;

  const husOn = opp.husOn !== false;
  const [husRekker, acoustics] = await Promise.all([
    husOn ? hentHusrekker() : Promise.resolve([]),
    bootWasmSafe(),
  ]);

  const view = opp.view
    ? { center: [opp.view.center[1], opp.view.center[0]], zoom: opp.view.zoom }
    : bboxSenter(opp.pumps, husRekker) || { center: [10.75, 59.91], zoom: 14 };

  const map = new maplibregl.Map({
    container: 'map3d',
    style: {
      version: 8,
      sources: {
        kv: {
          type: 'raster',
          tiles: ['https://cache.kartverket.no/v1/wmts/1.0.0/topograatone/default/webmercator/{z}/{y}/{x}.png'],
          tileSize: 256,
          maxzoom: 18,
          attribution: '&copy; Kartverket',
        },
      },
      layers: [{ id: 'kv', type: 'raster', source: 'kv' }],
    },
    center: view.center,
    zoom: view.zoom,
    pitch: 60,
    maxPitch: 85,
  });
  map.addControl(new maplibregl.NavigationControl({ visualizePitch: true }));

  map.on('load', async () => {
    if (husRekker.length) {
      map.addSource('husrekker', { type: 'geojson', data: husrekkerGeoJSON(husRekker) });
      map.addLayer({
        id: 'husrekker-3d',
        type: 'fill-extrusion',
        source: 'husrekker',
        paint: {
          'fill-extrusion-color': '#888',
          'fill-extrusion-height': HUS_HOYDE_M,
          'fill-extrusion-base': 0,
          'fill-extrusion-opacity': 0.85,
        },
      });
    }

    opp.pumps.forEach(p => {
      const el = document.createElement('div');
      el.className = 'pnum3d';
      el.textContent = p.num;
      new maplibregl.Marker({ element: el }).setLngLat([p.lng, p.lat]).addTo(map);
    });

    // ---- dB-vegger ----
    if (!opp.gridOn) {
      melding.textContent += ' · rutenett var avslått i 2D – ingen dB-vegger vist';
      return;
    }
    if (!acoustics) {
      melding.textContent += ' · beregningskjernen kunne ikke lastes – ingen dB-vegger';
      return;
    }
    if (!opp.grid || !opp.limits || !opp.limits.length) {
      melding.textContent += ' · ingen aktive grenser å vise som vegger';
      return;
    }
    melding.textContent += ' · beregner dB-konturer …';
    await new Promise(r => setTimeout(r, 0));   // la meldingen male før det blokkerende WASM-kallet
    const resultat = beregnRutenett(opp, husRekker, acoustics);
    if (resultat.feil) {
      melding.textContent = `${opp.pumps.length} utedel(er) overført · ${resultat.feil}`;
      return;
    }
    const aktive = leggTilVegger(map, opp, resultat);
    melding.textContent = `${opp.pumps.length} utedel(er) overført`;
    if (resultat.uskjermet) melding.textContent += ' · kjernen mangler skjerming-eksporten (eldre binær) – regnet uten husskjerming (konservativt)';
    if (resultat.fellesnivaa) melding.textContent += ' · kjernen mangler per-utedel-eksporten (eldre binær) – regnet med høyeste nivå for alle utedelene (konservativt)';
    visFargenokkel(aktive);
  });
}

const raw = sessionStorage.getItem(SESSION_KEY);
const opp = raw ? normaliserOppsett(JSON.parse(raw)) : null;
if (!opp) {
  document.getElementById('feil').classList.add('vis');
} else {
  start(opp);
}
