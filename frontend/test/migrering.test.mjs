// Tester for migrering.js – at alle historiske lagringsformater (v1/v2/v3)
// normaliseres riktig. Kjøres med `node --test frontend/test`.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normaliserOppsett } from '../static/migrering.js';

test('ukjent format avvises', () => {
  assert.equal(normaliserOppsett(null), null);
  assert.equal(normaliserOppsett({}), null);
  assert.equal(normaliserOppsett({ format: 'noe-annet' }), null);
});

test('v3: alle felter går gjennom uendret', () => {
  const opp = normaliserOppsett({
    format: 'lydnivakart', version: 3,
    settings: { lyd: 52, vegg: true, kab: 3, limits: [28, 35], defdir: 90, base: 'esri' },
    pumps: [{ num: 2, lat: 59.65, lng: 10.81, brg: 180 }],
    grid: { sw: { lat: 59.64, lng: 10.80 }, ne: { lat: 59.66, lng: 10.82 }, res: 1.5, on: false },
    view: { center: [59.65, 10.81], zoom: 19 },
  });
  assert.equal(opp.lyd, 52);
  assert.equal(opp.vegg, true);
  assert.equal(opp.kab, 3);
  assert.deepEqual(opp.limits, [28, 35]);
  assert.equal(opp.defdir, 90);
  assert.equal(opp.base, 'esri');
  assert.deepEqual(opp.pumps, [{ num: 2, lat: 59.65, lng: 10.81, brg: 180 }]);
  assert.equal(opp.grid.res, 1.5);
  assert.equal(opp.gridOn, false);   // eksplisitt lagret av
  assert.deepEqual(opp.view, { center: [59.65, 10.81], zoom: 19 });
});

test('v1: mode/mount migreres til lyd/vegg, bands til dB-grenser', () => {
  const opp = normaliserOppsett({
    format: 'lydnivakart', version: 1,
    settings: { mode: '53', mount: '3', bands: { natBp: true, nattC: true, kvC: false, dagC: true } },
  });
  assert.equal(opp.lyd, 53);
  assert.equal(opp.vegg, true);      // mount '3' betydde veggmontert (+3 dB)
  assert.equal(opp.kab, 0);          // fantes ikke i v1
  assert.deepEqual([...opp.limits].sort((a, b) => a - b), [28, 35, 45]);
  assert.equal(opp.grid, null);
  assert.equal(opp.gridOn, true);    // grid fantes ikke → på (standard)
});

test('v2: nabos-feltet ignoreres stille', () => {
  const opp = normaliserOppsett({
    format: 'lydnivakart', version: 2,
    settings: { lyd: 50, vegg: false, kab: 0, limits: [35] },
    pumps: [{ num: 1, lat: 59.65, lng: 10.81, brg: 0 }],
    nabos: [{ lat: 59.651, lng: 10.811 }],
  });
  assert.deepEqual(opp.limits, [35]);
  assert.equal(opp.pumps.length, 1);
  assert.ok(!('nabos' in opp));
});

test('manglende felter: limits null (behold nåværende), defaults for lydkilde', () => {
  const opp = normaliserOppsett({ format: 'lydnivakart' });
  assert.equal(opp.lyd, 50);         // parseFloat(undefined) || 50
  assert.equal(opp.vegg, false);
  assert.equal(opp.kab, 0);
  assert.equal(opp.limits, null);
  assert.equal(opp.defdir, null);
  assert.equal(opp.base, null);
  assert.deepEqual(opp.pumps, []);
  assert.equal(opp.view, null);
});

test('husOn/husSkjerm/husVerst: additive felter – med i fila går gjennom, mangler → null', () => {
  const med = normaliserOppsett({
    format: 'lydnivakart', version: 3,
    settings: { lyd: 50, vegg: false, kab: 0, husOn: false, husSkjerm: false, husVerst: false },
  });
  assert.equal(med.husOn, false);
  assert.equal(med.husSkjerm, false);
  assert.equal(med.husVerst, false);
  const uten = normaliserOppsett({
    format: 'lydnivakart', version: 3,
    settings: { lyd: 50, vegg: false, kab: 0 },
  });
  assert.equal(uten.husOn, null);       // eldre fil → behold nåværende tilstand
  assert.equal(uten.husSkjerm, null);
  assert.equal(uten.husVerst, null);
});

test('grid uten on-felt: gridOn er på (additivt felt, eldre v3-filer)', () => {
  const opp = normaliserOppsett({
    format: 'lydnivakart', version: 3,
    grid: { sw: { lat: 1, lng: 2 }, ne: { lat: 3, lng: 4 }, res: 2 },
  });
  assert.equal(opp.gridOn, true);
  assert.equal(opp.grid.res, 2);
});
