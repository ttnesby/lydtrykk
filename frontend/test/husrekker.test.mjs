// Tester for husrekker.js – UTM33→WGS84-konverteringen og normaliseringen av
// husrekke-json. Kjøres med Node sin innebygde testrunner:
// `node --test frontend/test`. Testene leser de ekte polygonfilene fra
// husrekker/polygoner/, så også manifestet (index.json) valideres.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { utm33TilLatLng, normaliserHusrekke } from '../static/husrekker.js';

const POLYGONER = new URL('../../husrekker/polygoner/', import.meta.url);
const les = f => JSON.parse(readFileSync(new URL(f, POLYGONER), 'utf8'));

const CENTER = { lat: 59.6502276, lng: 10.8092635 };   // samme som i kartet

test('utm33TilLatLng: gylne verdier (fasit fra pyproj, EPSG:25833 → 4326)', () => {
  const FASIT = [
    [263902.2294569672, 6619893.929747747, 59.650042395, 10.809493827],   // k-rekkas første punkt
    [263902.0, 6619890.0, 59.650007071, 10.809494163],
    [263878.9795862069, 6619928.21299422, 59.650336260, 10.809044089],    // l-rekkas første punkt
    [262600.0, 6649000.0, 59.909950571, 10.753412934],                    // Oslo, ~30 km unna
  ];
  for (const [oest, nord, lat, lng] of FASIT) {
    const p = utm33TilLatLng(oest, nord);
    assert.ok(Math.abs(p.lat - lat) < 1e-7, `lat ${p.lat} != ${lat}`);
    assert.ok(Math.abs(p.lng - lng) < 1e-7, `lng ${p.lng} != ${lng}`);
  }
});

test('normaliserHusrekke: de ekte filene i manifestet normaliserer og ligger ved kartsenteret', () => {
  const { filer } = les('index.json');
  assert.ok(Array.isArray(filer) && filer.length >= 2, 'index.json skal liste filene');
  for (const f of filer) {
    const rekke = normaliserHusrekke(les(f));
    assert.ok(rekke.navn.length > 0, `${f}: navn mangler`);
    assert.ok(rekke.punkter.length >= 3, `${f}: for få punkter`);
    for (const p of rekke.punkter) {
      const m = Math.hypot((p.lat - CENTER.lat) * 111320,
                           (p.lng - CENTER.lng) * 111320 * Math.cos(CENTER.lat * Math.PI / 180));
      assert.ok(m < 300, `${f}: punkt ${m.toFixed(0)} m fra kartsenteret`);
    }
  }
});

test('normaliserHusrekke: (tilnærmet) duplisert sluttpunkt droppes', () => {
  const k = les('k-rekka.json');
  // k-rekka lukker polygonet med ~2 cm avvik mellom første og siste punkt
  assert.equal(normaliserHusrekke(k).punkter.length, k.polygon.length - 1);
  // et åpent polygon beholder alle punktene
  const aapen = { navn: 't', polygon: [[0, 6600000], [10, 6600000], [10, 6600010]] };
  assert.equal(normaliserHusrekke(aapen).punkter.length, 3);
});

test('normaliserHusrekke: manglende crs antas EPSG:25833, ukjent crs avvises', () => {
  const polygon = [[263900, 6619890], [263910, 6619890], [263910, 6619900]];
  assert.deepEqual(normaliserHusrekke({ navn: 't', polygon }),
                   normaliserHusrekke({ navn: 't', crs: 'EPSG:25833', polygon }));
  assert.throws(() => normaliserHusrekke({ navn: 't', crs: 'EPSG:25832', polygon }), /EPSG:25833/);
});

test('normaliserHusrekke: feilmeldinger ved ugyldig input', () => {
  assert.throws(() => normaliserHusrekke(null), /Ugyldig husrekke/);
  assert.throws(() => normaliserHusrekke({ navn: 't' }), /Ugyldig husrekke/);
  assert.throws(() => normaliserHusrekke({ navn: 't', polygon: [[1, 2], [3, 4]] }), /minst 3 punkter/);
  assert.throws(() => normaliserHusrekke({ navn: 't', polygon: [[1, 2], [3], [5, 6]] }), /Ugyldig punkt/);
  assert.throws(() => normaliserHusrekke({ navn: 't', polygon: [[1, 2], ['x', 4], [5, 6]] }), /Ugyldig punkt/);
});

test('normaliserHusrekke: tredjeEtasje – additivt/valgfritt felt for 3D-visningens ekstra etasjeboks', () => {
  const polygon = [[263900, 6619890], [263910, 6619890], [263910, 6619900]];
  // mangler feltet helt → ingen ekstra etasje (gamle filer uendret gyldige)
  assert.deepEqual(normaliserHusrekke({ navn: 't', polygon }).tredjeEtasje, []);
  // gyldig delpolygon konverteres akkurat som hoved-polygonet
  const tredjeEtasje = [[[263901, 6619891], [263911, 6619891], [263911, 6619899]]];
  const rekke = normaliserHusrekke({ navn: 't', polygon, tredjeEtasje });
  assert.equal(rekke.tredjeEtasje.length, 1);
  assert.equal(rekke.tredjeEtasje[0].length, 3);
  assert.deepEqual(rekke.tredjeEtasje[0][0], utm33TilLatLng(263901, 6619891));
  // et tilstedeværende, ugyldig delpolygon kaster – samme prinsipp som hoved-polygonet
  assert.throws(() => normaliserHusrekke({ navn: 't', polygon, tredjeEtasje: [[[1, 2], [3, 4]]] }), /minst 3 punkter/);
});
