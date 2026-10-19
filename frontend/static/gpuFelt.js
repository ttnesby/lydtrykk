// FORSØK (gpu-spike.html), ikke produksjonskode: kart-simulatorens rutenett
// (kumulativt dB per celle fra alle utedeler, med husrekke-maskering og
// -skjerming) regnet i en WebGPU compute shader (WGSL), for å måle fart og
// avvik mot Haskell-kjernen (Lyd.Felt.rutenettStripeSkjermet via WASM).
//
// Dette ER en andre implementasjon av modellen – stikk i strid med
// «én implementasjon»-prinsippet i CLAUDE.md – og finnes bare for å gi
// grunnlag for en beslutning. Ingenting i den vanlige kartflyten bruker den.
//
// Fordeling CPU/GPU:
// - Alt som bare avhenger av kilde og polygon (ikke av cellen) regnes én gang
//   på CPU i float64, med nøyaktig samme operasjoner som Haskell, så de
//   beslutningene er bit-identiske med kjernen: polygonforenklingen
//   (Douglas–Peucker, 0,2 m), «kilden står inni polygonet» (hele polygonet
//   unntatt) og «kanten ligger < 1 m fra kilden» (bare den kanten unntatt).
// - Alt som avhenger av cellen (avstand, retning, maskering, sikttest) regnes
//   på GPU i float32 – det er her avvik kan oppstå.

// ---------------------------------------------------------------------------
// Douglas–Peucker – direkte port av Lyd.Felt.forenkletPolygon, inkludert
// tie-breaking (maximumBy velger SISTE maksimum; maximum på (avvik, indeks)-
// par velger største indeks ved likt avvik). Kjernen eksporterer ikke
// forenklingen, så forsøket trenger denne kopien; den er sjekket mot
// Haskell-kjernen nativt (samme hjørne-indekser for alle husrekkene, se
// rapporten). En produksjonsversjon bør heller få de forenklede polygonene
// fra en ny WASM-eksport.

export const FORENKLE_TOLERANSE_M = 0.2;  // = Lyd.Felt.forenkleToleranseM
export const SKJERMING_DB = 10;           // = Lyd.Felt.skjermingDb

function punktSegmentAvstand(px, py, ax, ay, bx, by) {
  const dx = bx - ax, dy = by - ay;
  const l2 = dx * dx + dy * dy;
  const t = l2 === 0 ? 0 : Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / l2));
  const nx = ax + t * dx, ny = ay + t * dy;
  return Math.sqrt((px - nx) * (px - nx) + (py - ny) * (py - ny));
}

// poly: [{x,y}, …] uten duplisert sluttpunkt
export function forenkletPolygon(tol, poly) {
  if (poly.length < 4) return poly;
  const v0 = poly[0];
  let delIndeks = 0, best = -Infinity;
  for (let i = 0; i < poly.length; i++) {
    const p = poly[i];
    const d = (p.x - v0.x) * (p.x - v0.x) + (p.y - v0.y) * (p.y - v0.y);
    if (d >= best) { best = d; delIndeks = i; }   // >= : siste maksimum, som maximumBy
  }
  if (delIndeks === 0) return poly;
  const dp = (ps) => {
    if (ps.length <= 2) return ps;
    const a = ps[0], b = ps[ps.length - 1];
    let avvik = -Infinity, verst = 0;
    for (let i = 1; i < ps.length - 1; i++) {
      const d = punktSegmentAvstand(ps[i].x, ps[i].y, a.x, a.y, b.x, b.y);
      if (d >= avvik) { avvik = d; verst = i; }     // >= : største indeks ved likhet, som maximum
    }
    if (avvik <= tol) return [a, b];
    return [...dp(ps.slice(0, verst + 1)).slice(0, -1), ...dp(ps.slice(verst))];
  };
  const fram = poly.slice(0, delIndeks), bak = poly.slice(delIndeks);
  const resultat = [...dp([...fram, bak[0]]).slice(0, -1), ...dp([...bak, v0]).slice(0, -1)];
  return resultat.length >= 3 ? resultat : poly;
}

// Stråletesten (Lyd.Felt.punktIKanter) i float64 – brukes bare på CPU for
// «kilden står inni polygonet»-unntaket, med samme uttrykk som Haskell.
function punktIPolygon64(poly, x, y) {
  let inne = false;
  for (let i = 0; i < poly.length; i++) {
    const a = poly[i], b = poly[(i + 1) % poly.length];
    if ((a.y > y) !== (b.y > y) && x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x) inne = !inne;
  }
  return inne;
}

// polys: {xy: Float64Array, antall: Float64Array} (husPolysLocal-formatet)
// → [[{x,y},…],…], filtrert til ≥3 hjørner og forenklet (= gyldigeHusrekker).
export function gyldigeHusrekker(polys) {
  const ut = [];
  if (!polys) return ut;
  let k = 0;
  for (const nf of polys.antall) {
    const n = Math.max(0, nf);
    const poly = [];
    for (let i = 0; i < n; i++, k += 2) poly.push({ x: polys.xy[k], y: polys.xy[k + 1] });
    if (poly.length >= 3) ut.push(forenkletPolygon(FORENKLE_TOLERANSE_M, poly));
  }
  return ut;
}

// ---------------------------------------------------------------------------
// WGSL. Én tråd per celle; løkke over kildene, og per kilde over polygonene
// (bbox-forfilter) og kantene. Matematisk identisk med nivaaMedHindre:
//
//   Haskell:  acc += 10^((L0 − 20·log10 r − 5(1 − cos v) − fradrag)/10)
//   her:      acc += P0 · r⁻² · 10^(−(1 − cos v)/2) · (blokkert ? 0,1 : 1)
//             med P0 = 10^(L0/10) forhåndsregnet i float64.
//
// Vinkelen: v = min(90°, avvik) der avvik er vinkelen mellom vifteretningen
// og retningen kilde→celle, så cos v = max(0, û·d̂) – samme tall uten
// atan2/mod/acos. (Celle nøyaktig i kilden: atan2(0,0) = 0 i Haskell, dvs.
// retning nord, d̂ = (0,1).)
//
// Maskerte celler skrives som MASKERT (WGSL garanterer ikke NaN), og gjøres
// om til NaN etter tilbakelesing. Koordinatene er flyttet til et origo midt
// i rutenettet (et helt antall celler, så cellekoordinatene fortsatt er
// eksakte i float32) for å halvere størrelsen på tallene.
export const MASKERT = -1.0e30;

export const WGSL = /* wgsl */ `
struct Param {
  kolonner: u32, rader: u32, nPumper: u32, nPoly: u32,
  celle: f32, medHus: u32, ordPoly: u32, ordKant: u32,
  kolSkift: i32, radSkift: i32, forklarCelle: u32, _p: u32,
};
@group(0) @binding(0) var<uniform> P: Param;
// per pumpe: (x, y, ux, uy) – posisjon og enhetsvektor for vifteretningen
@group(0) @binding(1) var<storage, read> pumper: array<vec4<f32>>;
// per pumpe: P0 = 10^(nivå/10)
@group(0) @binding(2) var<storage, read> effekt: array<f32>;
// per polygon: bounding-boks (minX, minY, maxX, maxY)
@group(0) @binding(3) var<storage, read> boks: array<vec4<f32>>;
// per polygon: (første kant, antall kanter)
@group(0) @binding(4) var<storage, read> spenn: array<vec2<u32>>;
// alle kanter: (x1, y1, x2, y2)
@group(0) @binding(5) var<storage, read> kanter: array<vec4<f32>>;
// per pumpe × polygon (bitmaske): kilden står inni polygonet → unntatt
@group(0) @binding(6) var<storage, read> polyUnntak: array<u32>;
// per pumpe × kant (bitmaske): kanten ligger < 1 m fra kilden → unntatt
@group(0) @binding(7) var<storage, read> kantUnntak: array<u32>;
@group(0) @binding(8) var<storage, read_write> ut: array<f32>;

const MASKERT: f32 = ${MASKERT.toExponential()};
const LOG2_10_DIV_2: f32 = 1.6609640474436813;   // log2(10)/2
const DB_PER_LOG2: f32 = 3.0102999566398120;      // 10·log10(2)

// (to funksjoner i stedet for én med peker-parameter: storage-pekere som
// funksjonsargument krever et WGSL-språktillegg ikke alle nettlesere har)
fn polyUnntatt(i: u32, j: u32) -> bool {
  return ((polyUnntak[i * P.ordPoly + (j >> 5u)] >> (j & 31u)) & 1u) == 1u;
}
fn kantUnntatt(i: u32, e: u32) -> bool {
  return ((kantUnntak[i * P.ordKant + (e >> 5u)] >> (e & 31u)) & 1u) == 1u;
}

fn kryss(px: f32, py: f32, qx: f32, qy: f32, rx: f32, ry: f32) -> f32 {
  return (qx - px) * (ry - py) - (qy - py) * (rx - px);
}

// Lyd.Felt.segmenterKrysser: bare ekte kryssing (streifing/berøring skjermer ikke)
fn krysser(ax: f32, ay: f32, bx: f32, by: f32, k: vec4<f32>) -> bool {
  return kryss(ax, ay, bx, by, k.x, k.y) * kryss(ax, ay, bx, by, k.z, k.w) < 0.0
      && kryss(k.x, k.y, k.z, k.w, ax, ay) * kryss(k.x, k.y, k.z, k.w, bx, by) < 0.0;
}

fn inne(x: f32, y: f32) -> bool {
  for (var j = 0u; j < P.nPoly; j++) {
    let b = boks[j];
    if (x < b.x || x > b.z || y < b.y || y > b.w) { continue; }
    let s = spenn[j];
    var odde = false;
    for (var e = s.x; e < s.x + s.y; e++) {
      let k = kanter[e];
      if ((k.y > y) != (k.w > y) && x < (k.z - k.x) * (y - k.y) / (k.w - k.y) + k.x) { odde = !odde; }
    }
    if (odde) { return true; }
  }
  return false;
}

// kildeFradrag: brytes siktlinja kilde i → (x, y) av et polygon som ikke er
// kildens eget, utenom kanter < 1 m fra kilden?
fn blokkert(i: u32, ax: f32, ay: f32, x: f32, y: f32) -> bool {
  let lox = min(ax, x); let hix = max(ax, x);
  let loy = min(ay, y); let hiy = max(ay, y);
  for (var j = 0u; j < P.nPoly; j++) {
    if (polyUnntatt(i, j)) { continue; }
    let b = boks[j];
    if (lox > b.z || hix < b.x || loy > b.w || hiy < b.y) { continue; }
    let s = spenn[j];
    for (var e = s.x; e < s.x + s.y; e++) {
      if (krysser(ax, ay, x, y, kanter[e]) && !kantUnntatt(i, e)) { return true; }
    }
  }
  return false;
}

fn bidrag(i: u32, x: f32, y: f32) -> f32 {
  let p = pumper[i];
  let dx = x - p.x; let dy = y - p.y;
  let d = sqrt(dx * dx + dy * dy);
  let r = max(d, 1.0);
  var c = p.w;                         // celle i kilden: retning nord
  if (d > 0.0) { c = (dx * p.z + dy * p.w) / d; }
  c = clamp(c, 0.0, 1.0);              // cos(min(90°, avvik))
  var t = effekt[i] / (r * r) * exp2(-(1.0 - c) * LOG2_10_DIV_2);
  if (P.medHus != 0u && blokkert(i, p.x, p.y, x, y)) { t = t * 0.1; }   // −10 dB
  return t;
}

fn cellePos(kol: u32, rad: u32) -> vec2<f32> {
  return vec2<f32>(f32(i32(kol) - P.kolSkift) * P.celle, f32(i32(rad) - P.radSkift) * P.celle);
}

@compute @workgroup_size(8, 8)
fn felt(@builtin(global_invocation_id) g: vec3<u32>) {
  let kol = g.x; let rad = g.y;
  if (kol >= P.kolonner || rad >= P.rader) { return; }
  let pos = cellePos(kol, rad);
  let idx = rad * P.kolonner + kol;
  if (P.medHus != 0u && inne(pos.x, pos.y)) { ut[idx] = MASKERT; return; }
  var acc = 0.0;
  for (var i = 0u; i < P.nPumper; i++) { acc += bidrag(i, pos.x, pos.y); }
  ut[idx] = log2(acc) * DB_PER_LOG2;
}

// Diagnose: for én celle (P.forklarCelle), skriv 1/0 per pumpe for om
// siktlinja er blokkert – samme blokkert()-funksjon som felt() bruker, så
// avvik mot kjernens acoustics_forklarPunkt kan spores til enkeltkilder.
@compute @workgroup_size(64)
fn forklar(@builtin(global_invocation_id) g: vec3<u32>) {
  // layout: 'auto' tar bare med bindinger inngangspunktet faktisk bruker;
  // uten denne ville bind-gruppen (felles for begge inngangene) bli avvist
  _ = effekt[0];
  let i = g.x;
  if (i >= P.nPumper) { return; }
  let kol = P.forklarCelle % P.kolonner; let rad = P.forklarCelle / P.kolonner;
  let pos = cellePos(kol, rad);
  let p = pumper[i];
  ut[i] = select(0.0, 1.0, blokkert(i, p.x, p.y, pos.x, pos.y));
}
`;

// ---------------------------------------------------------------------------
// CPU-forberedelse (float64): flate arrays klare for opplasting.
// pumps: [{x,y,brg,nivaa}] i rutenettets lokale plan (pumpsLocal);
// polys: husPolysLocal-formatet eller null (= uskjermet, ingen maskering).
export function forbered(pumps, polys, rows, cols, res) {
  const t0 = performance.now();
  const kolSkift = Math.floor(cols / 2), radSkift = Math.floor(rows / 2);
  const sx = kolSkift * res, sy = radSkift * res;   // origo-skift (eksakt antall celler)
  const gyldige = gyldigeHusrekker(polys);
  const nPoly = gyldige.length;
  const nKant = gyldige.reduce((s, p) => s + p.length, 0);
  const ordPoly = Math.max(1, Math.ceil(nPoly / 32));
  const ordKant = Math.max(1, Math.ceil(nKant / 32));

  const pumper = new Float32Array(pumps.length * 4);
  const effekt = new Float32Array(Math.max(1, pumps.length));
  pumps.forEach((p, i) => {
    const b = p.brg * Math.PI / 180;
    pumper.set([p.x - sx, p.y - sy, Math.sin(b), Math.cos(b)], i * 4);
    effekt[i] = Math.pow(10, p.nivaa / 10);
  });

  const boks = new Float32Array(Math.max(1, nPoly) * 4);
  const spenn = new Uint32Array(Math.max(1, nPoly) * 2);
  const kanter = new Float32Array(Math.max(1, nKant) * 4);
  const kant64 = [];   // (ax, ay, bx, by) i float64, uskiftet – for unntaket under
  let e = 0;
  gyldige.forEach((poly, j) => {
    const xs = poly.map(q => q.x), ys = poly.map(q => q.y);
    boks.set([Math.min(...xs) - sx, Math.min(...ys) - sy, Math.max(...xs) - sx, Math.max(...ys) - sy], j * 4);
    spenn.set([e, poly.length], j * 2);
    for (let k = 0; k < poly.length; k++, e++) {
      const a = poly[k], b = poly[(k + 1) % poly.length];
      kanter.set([a.x - sx, a.y - sy, b.x - sx, b.y - sy], e * 4);
      kant64.push([a.x, a.y, b.x, b.y]);
    }
  });

  const polyUnntak = new Uint32Array(Math.max(1, pumps.length) * ordPoly);
  const kantUnntak = new Uint32Array(Math.max(1, pumps.length) * ordKant);
  let antPolyUnntak = 0, antKantUnntak = 0;
  pumps.forEach((p, i) => {
    gyldige.forEach((poly, j) => {
      if (punktIPolygon64(poly, p.x, p.y)) { polyUnntak[i * ordPoly + (j >> 5)] |= 1 << (j & 31); antPolyUnntak++; }
    });
    kant64.forEach(([ax, ay, bx, by], k) => {
      // segmentKrysserKanterVUtenomEgenFasade: kanten teller bare når avstanden er ≥ 1
      if (!(punktSegmentAvstand(p.x, p.y, ax, ay, bx, by) >= 1)) { kantUnntak[i * ordKant + (k >> 5)] |= 1 << (k & 31); antKantUnntak++; }
    });
  });

  return {
    rows, cols, res, kolSkift, radSkift, nPumper: pumps.length, nPoly, nKant, ordPoly, ordKant,
    medHus: !!polys, gyldige, pumper, effekt, boks, spenn, kanter, polyUnntak, kantUnntak,
    antPolyUnntak, antKantUnntak, cpuMs: performance.now() - t0,
  };
}

// ---------------------------------------------------------------------------
// GPU-vert. lagGpuFelt kompilerer pipelinen én gang; beregn() laster opp,
// regner og leser tilbake – tiden den rapporterer er hele rundturen.
export async function lagGpuFelt() {
  if (!navigator.gpu) throw new Error('navigator.gpu finnes ikke – nettleseren har ikke WebGPU');
  const adapter = await navigator.gpu.requestAdapter({ powerPreference: 'high-performance' });
  if (!adapter) throw new Error('requestAdapter() ga ingen adapter');
  const device = await adapter.requestDevice({
    requiredLimits: { maxStorageBuffersPerShaderStage: Math.min(8, adapter.limits.maxStorageBuffersPerShaderStage) },
  });
  device.lost.then(info => console.error('[gpu] enheten tapt:', info.message));
  const t0 = performance.now();
  const modul = device.createShaderModule({ code: WGSL });
  const info = await modul.getCompilationInfo();
  const feil = info.messages.filter(m => m.type === 'error');
  if (feil.length) throw new Error('WGSL: ' + feil.map(m => `${m.lineNum}:${m.linePos} ${m.message}`).join('; '));
  const [feltPipe, forklarPipe] = await Promise.all([
    device.createComputePipelineAsync({ layout: 'auto', compute: { module: modul, entryPoint: 'felt' } }),
    device.createComputePipelineAsync({ layout: 'auto', compute: { module: modul, entryPoint: 'forklar' } }),
  ]);
  const kompileringMs = performance.now() - t0;

  const lagBuffer = (data, usage) => {
    const b = device.createBuffer({ size: Math.max(16, Math.ceil(data.byteLength / 4) * 4), usage: usage | GPUBufferUsage.COPY_DST });
    device.queue.writeBuffer(b, 0, data);
    return b;
  };

  async function kjør(f, pipe, nUt, forklarCelle, dispatch) {
    const param = new ArrayBuffer(48);
    const u = new Uint32Array(param), fl = new Float32Array(param), s = new Int32Array(param);
    u[0] = f.cols; u[1] = f.rows; u[2] = f.nPumper; u[3] = f.nPoly;
    fl[4] = f.res; u[5] = f.medHus ? 1 : 0; u[6] = f.ordPoly; u[7] = f.ordKant;
    s[8] = f.kolSkift; s[9] = f.radSkift; u[10] = forklarCelle; u[11] = 0;
    const S = GPUBufferUsage.STORAGE;
    const bufre = [
      lagBuffer(new Uint8Array(param), GPUBufferUsage.UNIFORM),
      lagBuffer(f.pumper, S), lagBuffer(f.effekt, S), lagBuffer(f.boks, S), lagBuffer(f.spenn, S),
      lagBuffer(f.kanter, S), lagBuffer(f.polyUnntak, S), lagBuffer(f.kantUnntak, S),
    ];
    const utBuf = device.createBuffer({ size: nUt * 4, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC });
    const lesBuf = device.createBuffer({ size: nUt * 4, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST });
    device.pushErrorScope('validation');
    const bindGroup = device.createBindGroup({
      layout: pipe.getBindGroupLayout(0),
      entries: [...bufre, utBuf].map((buffer, binding) => ({ binding, resource: { buffer } })),
    });
    const bindFeil = await device.popErrorScope();
    if (bindFeil) throw new Error('WebGPU-validering (bind group): ' + bindFeil.message);
    device.pushErrorScope('validation');
    const enc = device.createCommandEncoder();
    const pass = enc.beginComputePass();
    pass.setPipeline(pipe);
    pass.setBindGroup(0, bindGroup);
    pass.dispatchWorkgroups(...dispatch);
    pass.end();
    enc.copyBufferToBuffer(utBuf, 0, lesBuf, 0, nUt * 4);
    device.queue.submit([enc.finish()]);
    const valideringsfeil = await device.popErrorScope();
    if (valideringsfeil) throw new Error('WebGPU-validering: ' + valideringsfeil.message);
    await lesBuf.mapAsync(GPUMapMode.READ);
    const res = new Float32Array(lesBuf.getMappedRange().slice(0));
    lesBuf.unmap();
    [...bufre, utBuf, lesBuf].forEach(b => b.destroy());
    return res;
  }

  return {
    // GPUAdapterInfo har getter-felter (ikke egne egenskaper) – kopier eksplisitt
    adapterInfo: Object.fromEntries(['vendor', 'architecture', 'device', 'description'].map(k => [k, adapter.info?.[k] ?? ''])),
    kompileringMs,
    // Hele rutenettet. Returnerer Float64Array (NaN for maskerte) + ms for
    // opplasting+beregning+tilbakelesing.
    async beregn(f) {
      const t = performance.now();
      const r32 = await kjør(f, feltPipe, f.rows * f.cols, 0, [Math.ceil(f.cols / 8), Math.ceil(f.rows / 8)]);
      const gpuMs = performance.now() - t;
      const verdier = new Float64Array(r32.length);
      for (let i = 0; i < r32.length; i++) verdier[i] = r32[i] <= MASKERT / 10 ? NaN : r32[i];
      return { verdier, gpuMs };
    },
    // Per pumpe: er siktlinja til cellen 'idx' blokkert (GPU-ens svar)?
    async blokkertPerPumpe(f, idx) {
      const r = await kjør(f, forklarPipe, Math.max(1, f.nPumper), idx, [Math.ceil(f.nPumper / 64)]);
      return Array.from(r.slice(0, f.nPumper), v => v === 1);
    },
  };
}
