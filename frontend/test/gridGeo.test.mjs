// Tester for gridGeo.js – den rene geometrien kart-simulatoren hviler på.
// Kjøres med Node sin innebygde testrunner: `node --test frontend/test`.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { metersPerDeg, toLocal, fromLocal, destPoint, bearing, marchingSquares, boundarySegments } from '../static/gridGeo.js';

const ORIGO = { lat: 59.65, lng: 10.809 };   // samme strøk som CENTER i kartet

test('metersPerDeg: lengdegrad krymper med cos(lat)', () => {
  const ekvator = metersPerDeg(0);
  assert.equal(ekvator.mPerDegLon, ekvator.mPerDegLat);
  const nord = metersPerDeg(60);
  assert.ok(Math.abs(nord.mPerDegLon - nord.mPerDegLat * 0.5) < 1e-6);
});

test('toLocal: 1° nord = 111 320 m, origo = (0,0)', () => {
  assert.deepEqual(toLocal(ORIGO, ORIGO), { x: 0, y: 0 });
  const p = toLocal({ lat: ORIGO.lat + 1, lng: ORIGO.lng }, ORIGO);
  assert.equal(p.y, 111320);
  assert.equal(p.x, 0);
});

test('toLocal/fromLocal: rundtur innen 1e-9 grader', () => {
  for (const [x, y] of [[0, 0], [12.5, -33.7], [-250, 480], [1000, 1000]]) {
    const geo = fromLocal(x, y, ORIGO);
    const tilbake = toLocal(geo, ORIGO);
    assert.ok(Math.abs(tilbake.x - x) < 1e-6, `x: ${tilbake.x} != ${x}`);
    assert.ok(Math.abs(tilbake.y - y) < 1e-6, `y: ${tilbake.y} != ${y}`);
  }
});

test('destPoint: 100 m mot nord ligger 100 m unna, peiling 0', () => {
  const [lat, lng] = destPoint(ORIGO.lat, ORIGO.lng, 0, 100);
  const lokal = toLocal({ lat, lng }, ORIGO);
  assert.ok(Math.abs(lokal.y - 100) < 0.1, `y = ${lokal.y}`);
  assert.ok(Math.abs(lokal.x) < 0.01, `x = ${lokal.x}`);
  assert.ok(Math.abs(bearing(ORIGO, { lat, lng })) < 0.01);
});

test('bearing: rett øst = 90°, rett sør = 180°', () => {
  assert.ok(Math.abs(bearing(ORIGO, { lat: ORIGO.lat, lng: ORIGO.lng + 0.001 }) - 90) < 0.01);
  assert.ok(Math.abs(bearing(ORIGO, { lat: ORIGO.lat - 0.001, lng: ORIGO.lng }) - 180) < 0.01);
});

// marchingSquares-tester. Rutenettet er radmajor: grid[r*cols + c].

test('marchingSquares: uniformt felt gir ingen segmenter', () => {
  assert.deepEqual(marchingSquares(new Float64Array([1, 1, 1, 1]), 2, 2, 5), []);
  assert.deepEqual(marchingSquares(new Float64Array([9, 9, 9, 9]), 2, 2, 5), []);
});

test('marchingSquares: ett hjørne over grensen gir ett segment med riktig interpolering', () => {
  // 2×2, kun NØ-hjørnet (r=1, c=1) = 10 over grensen 5 → idx 4 → top–right.
  // top = [1, lerp(a=0, b=10)] = [1, 0.5]; right = [lerp(cc=0, b=10), 1] = [0.5, 1].
  const segs = marchingSquares(new Float64Array([0, 0, 0, 10]), 2, 2, 5);
  assert.deepEqual(segs, [[[1, 0.5], [0.5, 1]]]);
});

test('marchingSquares: sadelpunkt gir to segmenter (ingen kryssing tapt)', () => {
  // Diagonal 10/0/0/10 → idx 5; midtverdi = 5 er ikke > 5 → else-grenen.
  const segs = marchingSquares(new Float64Array([10, 0, 0, 10]), 2, 2, 5);
  assert.equal(segs.length, 2);
});

test('marchingSquares: øy i midten gir lukket kontur (4 segmenter i 3×3)', () => {
  const grid = new Float64Array([
    0, 0, 0,
    0, 10, 0,
    0, 0, 0,
  ]);
  const segs = marchingSquares(grid, 3, 3, 5);
  assert.equal(segs.length, 4);
  // Alle segmentpunkter skal ligge strengt innenfor rutenettet (øya berører ikke kanten).
  for (const [p0, p1] of segs) {
    for (const [r, c] of [p0, p1]) {
      assert.ok(r > 0 && r < 2 && c > 0 && c < 2, `punkt utenfor øya: ${r},${c}`);
    }
  }
});

test('marchingSquares: antall segmenter er symmetrisk om terskelen', () => {
  // Samme felt sett «ovenfra» og «nedenfra» skal gi like mange segmenter.
  const grid = new Float64Array([3, 7, 2, 9, 5.5, 1, 8, 4, 6]);
  const over = marchingSquares(grid, 3, 3, 5);
  const inv = new Float64Array([...grid].map(v => 10 - v));
  const under = marchingSquares(inv, 3, 3, 5);
  assert.equal(over.length, under.length);
});

// boundarySegments-tester: konturens fortsettelse langs rutenettkanten.

test('boundarySegments: felt helt under grensen gir ingen kantsegmenter', () => {
  assert.deepEqual(boundarySegments(new Float64Array([1, 1, 1, 1]), 2, 2, 5), []);
});

test('boundarySegments: felt helt over grensen tegner hele omkretsen', () => {
  // 2×2 med alt over grensen → ett fullt segment per kant (sør, nord, vest, øst).
  const segs = boundarySegments(new Float64Array([9, 9, 9, 9]), 2, 2, 5);
  assert.deepEqual(segs, [
    [[0, 0], [0, 1]],
    [[1, 0], [1, 1]],
    [[0, 0], [1, 0]],
    [[0, 1], [1, 1]],
  ]);
});

test('boundarySegments: kryssing på kanten interpoleres lineært', () => {
  // Sørkanten går fra 0 (SV) til 10 (SØ) med grense 5 → segment fra midtpunktet
  // [0, 0.5] til hjørnet [0, 1]. Østkanten fra 10 (SØ) til 0 (NØ) → [0,1]–[0.5,1].
  const grid = new Float64Array([
    0, 10,
    0, 0,
  ]);
  const segs = boundarySegments(grid, 2, 2, 5);
  assert.deepEqual(segs, [
    [[0, 0.5], [0, 1]],
    [[0, 1], [0.5, 1]],
  ]);
});

test('boundarySegments: inset rykker segmentene innover og klemmer hjørnene', () => {
  // 2×2 helt over grensen med inset 0.2 → omkretsen tegnes som et rektangel
  // 0.2 innenfor kanten, uten haler forbi hjørnene.
  const segs = boundarySegments(new Float64Array([9, 9, 9, 9]), 2, 2, 5, 0.2);
  assert.deepEqual(segs, [
    [[0.2, 0.2], [0.2, 0.8]],
    [[0.8, 0.2], [0.8, 0.8]],
    [[0.2, 0.2], [0.8, 0.2]],
    [[0.2, 0.8], [0.8, 0.8]],
  ]);
  // Uforsvarlig stort inset klemmes til midten i stedet for å vrenge rektangelet.
  for (const [p0, p1] of boundarySegments(new Float64Array([9, 9, 9, 9]), 2, 2, 5, 5)) {
    assert.deepEqual(p0, [0.5, 0.5]);
    assert.deepEqual(p1, [0.5, 0.5]);
  }
});

test('boundarySegments: kantpunktene møter marching squares-konturen', () => {
  // Halvplan over grensen (østre halvdel av 3×3) → marching squares gir en
  // vertikal kontur som ender åpent på sør- og nordkanten; kantsegmentenes
  // interpolerte endepunkter skal treffe nøyaktig de samme punktene.
  const grid = new Float64Array([
    0, 0, 10,
    0, 0, 10,
    0, 0, 10,
  ]);
  const ms = marchingSquares(grid, 3, 3, 5);
  const kant = boundarySegments(grid, 3, 3, 5);
  const punkt = segs => segs.flat().map(([r, c]) => `${r},${c}`);
  const msEnder = punkt(ms).filter(p => p.startsWith('0,') || p.startsWith('2,'));
  for (const p of msEnder) {
    assert.ok(punkt(kant).includes(p), `kantsegmentene mangler konturens endepunkt ${p}`);
  }
});
