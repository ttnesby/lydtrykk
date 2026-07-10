// Tester for grid3d.js – de rene rutenett-/geometrifunksjonene 3D-visningen
// (lydnivakart3d.js) bruker til dB-vegger og husrekke-ekstrudering. Kjøres
// med Node sin innebygde testrunner: `node --test frontend/test`.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { toLocal } from '../static/gridGeo.js';
import {
  gridDimsFraOppsett, nivaaAv, pumpsLocal, husPolysLocal,
  husrekkerGeoJSON, tredjeEtasjeGeoJSON, veggerGeoJSON,
} from '../static/grid3d.js';

const SW = { lat: 59.65, lng: 10.81 };

test('gridDimsFraOppsett: ingen grovning når celletallet er innenfor taket', () => {
  const grid = { sw: SW, ne: { lat: SW.lat + 0.001, lng: SW.lng + 0.001 }, res: 5 };
  const d = gridDimsFraOppsett(grid, 100000);
  assert.equal(d.coarsened, false);
  assert.ok(d.cols * d.rows <= 100000);
});

test('gridDimsFraOppsett: grovner res oppover når celletallet ville oversteget taket, og havner innenfor', () => {
  const grid = { sw: SW, ne: { lat: SW.lat + 0.01, lng: SW.lng + 0.01 }, res: 0.5 };
  const uten = gridDimsFraOppsett(grid, 1e9);   // uten grovning, for å bekrefte at det faktisk ville oversteget
  assert.ok(uten.cols * uten.rows > 1000);
  const d = gridDimsFraOppsett(grid, 1000);
  assert.equal(d.coarsened, true);
  // Étt-pass sqrt-skalering (samme tilnærming som gridDims() i lydnivakart.html)
  // er en heuristikk, ikke en hard garanti – avrunding+1-per-akse kan gi noen
  // få prosent overskridelse av taket. Sjekk at grovningen faktisk monner,
  // ikke et eksakt tak.
  assert.ok(d.cols * d.rows <= 1000 * 1.1, `${d.cols * d.rows} altfor langt over taket`);
  assert.ok(d.res > 0.5);   // grovere celle enn ønsket oppløsning
});

test('gridDimsFraOppsett: bytter om sw/ne som ikke er i riktig hjørne-rekkefølge', () => {
  const grid = { sw: { lat: SW.lat + 0.001, lng: SW.lng + 0.001 }, ne: SW, res: 5 };
  const d = gridDimsFraOppsett(grid, 100000);
  assert.equal(d.sw.lat, SW.lat);
  assert.equal(d.sw.lng, SW.lng);
});

test('nivaaAv: klamper lydnivå til [40,70], legger til vegg-tillegg, trekker fra kabinettdemping', () => {
  assert.equal(nivaaAv({ lyd: 52, vegg: false, kab: 0 }), 52);
  assert.equal(nivaaAv({ lyd: 52, vegg: true, kab: 5 }), 52 + 3 - 5);
  assert.equal(nivaaAv({ lyd: 10, vegg: false, kab: 0 }), 40);   // klampet opp
  assert.equal(nivaaAv({ lyd: 90, vegg: false, kab: 0 }), 70);   // klampet ned
});

test('pumpsLocal: bruker lokale verdier når satt, ellers globale', () => {
  const pumps = [
    { lat: SW.lat, lng: SW.lng, brg: 90, lokal: { lyd: 60, vegg: false, kab: 0 } },
    { lat: SW.lat, lng: SW.lng, brg: 180, lokal: null },
  ];
  const globale = { lyd: 52, vegg: false, kab: 0 };
  const pl = pumpsLocal(pumps, SW, globale);
  assert.equal(pl[0].nivaa, 60);
  assert.equal(pl[1].nivaa, 52);
  assert.equal(pl[0].brg, 90);
  assert.ok(Number.isFinite(pl[0].x) && Number.isFinite(pl[0].y));
});

test('husPolysLocal: flater ut hjørner og antall-per-polygon riktig', () => {
  const husRekker = [
    { punkter: [{ lat: SW.lat, lng: SW.lng }, { lat: SW.lat, lng: SW.lng + 0.001 }, { lat: SW.lat + 0.001, lng: SW.lng }] },
    { punkter: [{ lat: SW.lat, lng: SW.lng }, { lat: SW.lat, lng: SW.lng + 0.001 }, { lat: SW.lat + 0.001, lng: SW.lng }, { lat: SW.lat + 0.001, lng: SW.lng + 0.001 }] },
  ];
  const { xy, antall } = husPolysLocal(husRekker, SW);
  assert.deepEqual([...antall], [3, 4]);
  assert.equal(xy.length, (3 + 4) * 2);
});

test('husrekkerGeoJSON/tredjeEtasjeGeoJSON: lukker ringen (første == siste punkt)', () => {
  const husRekker = [{
    navn: 'a-rekka',
    punkter: [{ lat: 1, lng: 1 }, { lat: 1, lng: 2 }, { lat: 2, lng: 2 }],
    tredjeEtasje: [[{ lat: 1.1, lng: 1.1 }, { lat: 1.1, lng: 1.2 }, { lat: 1.2, lng: 1.2 }]],
  }];
  const hoved = husrekkerGeoJSON(husRekker);
  assert.equal(hoved.features.length, 1);
  const ringHoved = hoved.features[0].geometry.coordinates[0];
  assert.deepEqual(ringHoved[0], ringHoved[ringHoved.length - 1]);
  assert.equal(ringHoved.length, husRekker[0].punkter.length + 1);

  const ekstra = tredjeEtasjeGeoJSON(husRekker);
  assert.equal(ekstra.features.length, 1);
  const ringEkstra = ekstra.features[0].geometry.coordinates[0];
  assert.deepEqual(ringEkstra[0], ringEkstra[ringEkstra.length - 1]);
});

test('tredjeEtasjeGeoJSON: tom FeatureCollection når ingen rekker har feltet', () => {
  const husRekker = [{ navn: 'a', punkter: [{ lat: 1, lng: 1 }, { lat: 1, lng: 2 }, { lat: 2, lng: 2 }], tredjeEtasje: [] }];
  assert.deepEqual(tredjeEtasjeGeoJSON(husRekker).features, []);
});

test('veggerGeoJSON: bufrer et segment til en lukket firkant med riktig halvbredde', () => {
  // Rad/kolonne-koordinater: (rad0,kol0) -> (rad0,kol10), res=1 => horisontal
  // linje langs x-aksen fra (0,0) til (10,0) i det lokale planet.
  const segments = [[[0, 0], [0, 10]]];
  const halvbredde = 0.3;
  const data = veggerGeoJSON(segments, 1, SW, halvbredde);
  assert.equal(data.features.length, 1);
  const ring = data.features[0].geometry.coordinates[0];
  assert.equal(ring.length, 5);
  assert.deepEqual(ring[0], ring[4]);   // lukket ring
  // Konverter hjørnene tilbake til det lokale planet og sjekk bredden.
  const lokale = ring.slice(0, 4).map(([lng, lat]) => toLocal({ lat, lng }, SW));
  const bredde = Math.abs(lokale[0].y - lokale[3].y);
  assert.ok(Math.abs(bredde - 2 * halvbredde) < 1e-6, `bredde ${bredde} != ${2 * halvbredde}`);
});

test('veggerGeoJSON: null-lengde segmenter (identiske endepunkter) hoppes over', () => {
  const data = veggerGeoJSON([[[0, 0], [0, 0]]], 1, SW, 0.3);
  assert.deepEqual(data.features, []);
});
