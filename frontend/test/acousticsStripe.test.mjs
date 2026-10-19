// Tester for acousticsStripe.js – dispatch-logikken delt mellom gridWorker.js
// (2D) og lydnivakart3d.js (3D): samme pumpearray-bygging og PerKilde/
// Skjermet/legacy-feature-detect skal skje uansett hvilken av de to som
// kaller den. 'acoustics' mockes med enkle funksjoner som bare noterer at de
// ble kalt og skriver en kjenningsverdi inn i 'values' – selve WASM-
// regnestykket testes i lyd-core (native), dette tester bare at RIKTIG
// eksport velges for hver kombinasjon av tilgjengelige funksjoner og input.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { beregnStripe } from '../static/acousticsStripe.js';

const PUMP_A = { x: 1, y: 2, brg: 90, nivaa: 50 };
const PUMP_B = { x: 3, y: 4, brg: 180, nivaa: 55 };
const POLYS = { xy: new Float64Array([0, 0, 1, 0, 1, 1]), antall: new Float64Array([3]) };

function kallNotat() {
  const kalt = [];
  const noter = navn => (...args) => { kalt.push(navn); args[args.length - 1].fill(1); };
  return { kalt, noter };
}

test('PerKilde + Skjermet tilgjengelig, polygoner med: bruker SkjermetPerKilde', () => {
  const { kalt, noter } = kallNotat();
  const acoustics = {
    acoustics_gridStripePerKilde: noter('perKilde'),
    acoustics_gridStripeSkjermetPerKilde: noter('skjermetPerKilde'),
  };
  const values = new Float64Array(4);
  const r = beregnStripe(acoustics, [PUMP_A, PUMP_B], POLYS, 0, 2, 2, 1, values);
  assert.deepEqual(kalt, ['skjermetPerKilde']);
  assert.deepEqual(r, { uskjermet: false, fellesnivaa: false });
  assert.deepEqual([...values], [1, 1, 1, 1]);
});

test('kun PerKilde (ingen Skjermet-eksport), polygoner med: faller tilbake uskjermet', () => {
  const { kalt, noter } = kallNotat();
  const acoustics = { acoustics_gridStripePerKilde: noter('perKilde') };
  const values = new Float64Array(4);
  const r = beregnStripe(acoustics, [PUMP_A, PUMP_B], POLYS, 0, 2, 2, 1, values);
  assert.deepEqual(kalt, ['perKilde']);
  assert.deepEqual(r, { uskjermet: true, fellesnivaa: false });
});

test('ingen PerKilde-eksport (eldre binær), ulike nivåer: bruker høyeste nivå og flagger fellesnivaa', () => {
  const { kalt, noter } = kallNotat();
  const acoustics = {
    acoustics_gridStripe: noter('gridStripe'),
    acoustics_gridStripeSkjermet: noter('gridStripeSkjermet'),
  };
  const values = new Float64Array(4);
  const r = beregnStripe(acoustics, [PUMP_A, PUMP_B], POLYS, 0, 2, 2, 1, values);
  assert.deepEqual(kalt, ['gridStripeSkjermet']);
  assert.deepEqual(r, { uskjermet: false, fellesnivaa: true });
});

test('ingen PerKilde- eller Skjermet-eksport, like nivåer: legacy uskjermet, ingen fellesnivaa-flagg', () => {
  const { kalt, noter } = kallNotat();
  const acoustics = { acoustics_gridStripe: noter('gridStripe') };
  const values = new Float64Array(4);
  const samme = { ...PUMP_A };
  const r = beregnStripe(acoustics, [PUMP_A, samme], POLYS, 0, 2, 2, 1, values);
  assert.deepEqual(kalt, ['gridStripe']);
  assert.deepEqual(r, { uskjermet: true, fellesnivaa: false });
});

test('ingen polygoner: bruker PerKilde direkte, ikke Skjermet-varianten', () => {
  const { kalt, noter } = kallNotat();
  const acoustics = {
    acoustics_gridStripePerKilde: noter('perKilde'),
    acoustics_gridStripeSkjermetPerKilde: noter('skjermetPerKilde'),
  };
  const values = new Float64Array(4);
  const r = beregnStripe(acoustics, [PUMP_A], null, 0, 2, 2, 1, values);
  assert.deepEqual(kalt, ['perKilde']);
  assert.deepEqual(r, { uskjermet: false, fellesnivaa: false });
});

test('ingen pumper: values fylles -Infinity, ingen eksport kalt', () => {
  const { kalt, noter } = kallNotat();
  const acoustics = {
    acoustics_gridStripePerKilde: noter('perKilde'),
    acoustics_gridStripeSkjermetPerKilde: noter('skjermetPerKilde'),
  };
  const values = new Float64Array(4);
  const r = beregnStripe(acoustics, [], POLYS, 0, 2, 2, 1, values);
  assert.deepEqual(kalt, []);
  assert.deepEqual(r, { uskjermet: false, fellesnivaa: false });
  assert.deepEqual([...values], [-Infinity, -Infinity, -Infinity, -Infinity]);
});
