// 3D-visning av et lydnivakart-oppsett overført fra lydnivakart.html.
// Read-only: viser posisjoner (pumper/husrekker) pluss dB-ekvidistansene som
// ekstruderte vegger. Redigering skjer fortsatt i 2D-simulatoren.
import { normaliserOppsett } from './migrering.js';
import { normaliserHusrekke } from './husrekker.js';
import { fromLocal, marchingSquares, boundarySegments } from './gridGeo.js';
import { initAcoustics } from './wasmInit.js';
import {
  gridDimsFraOppsett, pumpsLocal, husPolysLocal,
  husrekkerGeoJSON, tredjeEtasjeGeoJSON, veggerGeoJSON,
} from './grid3d.js';

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
// Placeholder-tillegg for enheter med 3. etasje (normaliserHusrekke sitt
// valgfrie 'tredjeEtasje'-felt) – en ekstra boks stablet oppå HUS_HOYDE_M,
// ikke en erstatning av grunnhøyden. Samme «juster senere»-status som
// HUS_HOYDE_M: ekte tall kommer når brukerens polygondata er klare.
const EKSTRA_ETASJE_M = 3;

// Farge per dB-grense, duplisert fra FARGE/heat() i lydnivakart.html – samme
// farge på veggene her som på konturlinjene i 2D (de to sidene er selvstendige,
// ingen delt modul for denne vesle tabellen).
const FARGE = { 25: '#dc2626', 28: '#ea580c', 30: '#d97706', 33: '#ca8a04', 35: '#2563eb', 38: '#0891b2', 40: '#059669', 45: '#65a30d' };
function heat(limit) { return FARGE[limit] || '#888'; }

// Rene visuelle konstanter for veggenes høyde – ingen fysisk betydning (dB er
// ikke meter). Høyden regnes relativt til den *laveste aktive* grensen (ikke
// en fast dB-basislinje) – det holder den innerste/mildeste veggen i samme
// størrelsesorden som husrekkenes placeholder-høyde (HUS_HOYDE_M) uansett
// hvilke grenser som er aktive, i stedet for at f.eks. 45 dB alene ga en 15 m
// tårnhøy vegg. Stigende med dB gir fortsatt en trappet form: strengeste/
// lengst-unna grense lavest, mildeste/nærmest kilden høyest – samme
// konvensjon som fargeleggingen i 2D (varm = strengest = ytterst).
const VEGG_MIN_HOYDE_M = 0.56;
const VEGG_TRINN_PER_DB = 0.25;
// Tynn nok til å lese som et gardin langs konturlinjen, ikke en murvegg som
// visker ut 3D-følelsen mellom husrekke og veggens forside.
const VEGG_HALVBREDDE_M = 0.04;

// Samme dekkgrad som FYLL_ALPHA i lydnivakart.html (av 255) – gulvfargen skal
// se ut som 2D-fyllet (renderFyll), bare tegnet som en georeferert
// rasterflate i stedet for et Leaflet-canvaslag.
const GULV_ALPHA = 45;

// Tak på celletall – MERK: lavere enn MAX_CELLS (400 000) i lydnivakart.html.
// 2D fordeler cellene over en pool på opptil 16 web workers; denne siden
// regner alt i ETT synkront hovedtråd-kall. Et rutenett stort nok til å holde
// 2D-poolen travelt kan blokkere hovedtråden lenge nok til at nettleseren
// tror fanen har frosset (observert i praksis: gikk 2D→3D, forstørret/
// finkornet rutenettet i 2D, gikk tilbake til 3D – fanen hang). Grovnes
// derfor mye hardere her, og varsles synlig (samme mønster som
// gridDims()/updateGridInfo() i 2D) i stedet for å la det henge stille.
const MAX_CELLS = 60000;

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

// Mirrorer WASM-kallkonvensjonen i gridWorker.js (samme stride-4-pumper, samme
// feature-detect/fallback-rekkefølge for PerKilde/Skjermet-eksportene), men
// som ETT synkront hovedtråd-kall (rowStart=0, rowEnd=rows) – denne siden er
// en statisk engangsvisning, ingen worker-pool å holde jevn under dragging.
function beregnRutenett(opp, husRekker, acoustics) {
  if (typeof acoustics.acoustics_gridStripe !== 'function') {
    return { feil: 'app.wasm mangler rutenett-eksporten (eldre binær) – bygg lokalt eller bruk PR-previewen.' };
  }
  const { sw, res, cols, rows, coarsened } = gridDimsFraOppsett(opp.grid, MAX_CELLS);
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
  return { grid: values, rows, cols, res, sw, uskjermet, fellesnivaa, coarsened };
}

// Gulv-fyll: samme fargelogikk som renderFyll() i lydnivakart.html (hver
// celle får fargen til den *høyeste* aktive grensen den overskrider – ingen
// akkumulering), men tegnet som en georeferert bilde-kilde (MapLibre 'image'
// source) i stedet for et Leaflet-canvaslag. Gjør «rommet» mellom gulv og
// vegger lesbart, akkurat som fyllet gjør i 2D.
function leggTilGulv(map, opp, resultat) {
  const { grid, rows, cols, res, sw } = resultat;
  const aktive = [...opp.limits].sort((a, b) => a - b);
  if (!aktive.length) return;
  const rgb = aktive.map(l => { const n = parseInt(heat(l).slice(1), 16); return [(n >> 16) & 255, (n >> 8) & 255, n & 255]; });
  const canvas = document.createElement('canvas');
  canvas.width = cols; canvas.height = rows;
  const ctx = canvas.getContext('2d');
  const img = ctx.createImageData(cols, rows);
  for (let row = 0; row < rows; row++) {
    const outRow = rows - 1 - row;   // rad 0 i rutenettet = sør; bildets rad 0 = nord (topp) – samme flipp som renderFyll
    for (let col = 0; col < cols; col++) {
      const v = grid[row * cols + col];
      let i = -1;
      while (i + 1 < aktive.length && v > aktive[i + 1]) i++;
      if (i < 0) continue;
      const pi = (outRow * cols + col) * 4;
      img.data[pi] = rgb[i][0]; img.data[pi + 1] = rgb[i][1]; img.data[pi + 2] = rgb[i][2]; img.data[pi + 3] = GULV_ALPHA;
    }
  }
  ctx.putImageData(img, 0, 0);
  const nw = fromLocal(0, (rows - 1) * res, sw);
  const ne = fromLocal((cols - 1) * res, (rows - 1) * res, sw);
  const se = fromLocal((cols - 1) * res, 0, sw);
  const swPt = fromLocal(0, 0, sw);
  map.addSource('gulv', {
    type: 'image',
    url: canvas.toDataURL(),
    coordinates: [[nw.lng, nw.lat], [ne.lng, ne.lat], [se.lng, se.lat], [swPt.lng, swPt.lat]],
  });
  // Legges under husrekkene i lag-rekkefølgen (rent gulv, ikke oppå veggene).
  map.addLayer({ id: 'gulv', type: 'raster', source: 'gulv' }, map.getLayer('husrekker-3d') ? 'husrekker-3d' : undefined);
}

function leggTilVegger(map, opp, resultat) {
  const { grid, rows, cols, res, sw } = resultat;
  const aktive = [...opp.limits].sort((a, b) => a - b);
  const lavest = aktive[0];
  aktive.forEach(lim => {
    const segs = marchingSquares(grid, rows, cols, lim).concat(boundarySegments(grid, rows, cols, lim));
    if (!segs.length) return;
    const srcId = `vegg-${lim}`;
    map.addSource(srcId, { type: 'geojson', data: veggerGeoJSON(segs, res, sw, VEGG_HALVBREDDE_M) });
    map.addLayer({
      id: srcId,
      type: 'fill-extrusion',
      source: srcId,
      paint: {
        'fill-extrusion-color': heat(lim),
        'fill-extrusion-height': VEGG_MIN_HOYDE_M + (lim - lavest) * VEGG_TRINN_PER_DB,
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
      // Ekstra boks for enheter med 3. etasje (normaliserHusrekke sitt
      // valgfrie 'tredjeEtasje'-felt) – stablet oppå grunnhøyden, ikke en
      // erstatning av den. Hoppes over (ingen kilde/lag) hvis ingen rekker
      // har feltet ennå.
      const ekstraData = tredjeEtasjeGeoJSON(husRekker);
      if (ekstraData.features.length) {
        map.addSource('husrekker-ekstra', { type: 'geojson', data: ekstraData });
        map.addLayer({
          id: 'husrekker-3d-ekstra',
          type: 'fill-extrusion',
          source: 'husrekker-ekstra',
          paint: {
            'fill-extrusion-color': '#888',
            'fill-extrusion-height': HUS_HOYDE_M + EKSTRA_ETASJE_M,
            'fill-extrusion-base': HUS_HOYDE_M,
            'fill-extrusion-opacity': 0.85,
          },
        });
      }
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
    leggTilGulv(map, opp, resultat);
    const aktive = leggTilVegger(map, opp, resultat);
    melding.textContent = `${opp.pumps.length} utedel(er) overført`;
    if (resultat.coarsened) melding.textContent += ` · oppløsningen ble grovnet til ${resultat.res.toFixed(2)} m/celle (3D regner på én tråd, ikke i en worker-pool som 2D)`;
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

// «Tilbake»-lenken lukker denne fanen (åpnet med window.open fra 2D) i stedet
// for å navigere hit til en fersk lydnivakart.html – en vanlig navigasjon
// booter 2D på nytt fra default.json og virker dermed som om oppsettet ditt
// (pumpeendringer, rutenett osv.) ble nullstilt, mens den ekte 2D-fanen med
// endringene dine ligger urørt i bakgrunnen hele tiden. window.close()
// virker bare på skript-åpnede faner; lykkes den ikke (f.eks. fana ble åpnet
// på en annen måte), faller vi tilbake på vanlig navigasjon.
document.getElementById('tilbake').addEventListener('click', (e) => {
  e.preventDefault();
  window.close();
  setTimeout(() => { window.location.href = 'lydnivakart.html'; }, 150);
});
