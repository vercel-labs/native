/** Portable chart rendering and hover plans. Resources and drawing storage stay
 * native; samples and identities cross the boundary as exact integer words. */

// Float32 logarithm follows the algorithm used by the native compiler runtime:
// https://git.musl-libc.org/cgit/musl/tree/src/math/log10f.c
// Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
// Developed at SunPro, a Sun Microsystems, Inc. business.
// Permission to use, copy, modify, and distribute this software is freely
// granted, provided that this notice is preserved.
// Rounding every operation avoids double-precision changes at tick boundaries.
function nscChartLog10(value: number): number {
  const f = Math.fround, w = new DataView(new ArrayBuffer(4));
  w.setFloat32(0, value, true);
  let word = w.getUint32(0, true), exponent = 0;
  if (word < 0x00800000 || (word >>> 31) !== 0) {
    if ((word << 1) === 0) return -Infinity;
    if ((word >>> 31) !== 0) return NaN;
    exponent -= 25; value = f(value * 33554432);
    w.setFloat32(0, value, true); word = w.getUint32(0, true);
  } else if (word >= 0x7f800000) return value;
  else if (word === 0x3f800000) return 0;
  word = (word + 0x3f800000 - 0x3f3504f3) >>> 0;
  exponent += (word >>> 23) - 127;
  w.setUint32(0, (word & 0x007fffff) + 0x3f3504f3, true);
  const a = f(w.getFloat32(0, true) - 1), s = f(a / f(2 + a)), z = f(s * s), q = f(z * z);
  const t1 = f(q * f(f(0xccce13 / 33554432) + f(q * f(0xf89e26 / 67108864))));
  const t2 = f(z * f(f(0xaaaaaa / 16777216) + f(q * f(0x91e9ee / 33554432))));
  const r = f(t2 + t1), half = f(f(0.5 * a) * a);
  w.setFloat32(0, f(a - half), true); w.setUint32(0, w.getUint32(0, true) & 0xfffff000, true);
  const hi = w.getFloat32(0, true), lo = f(f(f(a - hi) - half) + f(s * f(half + r)));
  return f(f(f(f(f(exponent * f(7.9034151668e-7)) + f(f(lo + hi) * f(-3.1689971365e-5))) + f(lo * f(4.3432617188e-1))) + f(hi * f(4.3432617188e-1))) + f(exponent * f(3.0102920532e-1)));
}
function nscChartPower10(exponent: number): number {
  if (Number.isNaN(exponent)) return NaN;
  if (exponent === Infinity) return Infinity;
  if (exponent === -Infinity) return 0;
  if (exponent === 0) return 1;
  if (exponent === 1) return 10;
  const f = Math.fround;
  let factor = 0.625, scale = 4, result = 1, resultScale = 0;
  for (let remaining = Math.abs(exponent); remaining !== 0; remaining = Math.floor(remaining / 2)) {
    if (remaining % 2 !== 0) { result = f(result * factor); resultScale += scale; }
    factor = f(factor * factor); scale *= 2;
    if (factor < 0.5) { factor = f(factor + factor); scale--; }
  }
  if (exponent < 0) { result = f(1 / result); resultScale = -resultScale; }
  return f(result * Math.pow(2, resultScale));
}
function nscChartLabel(word: number, places: number): number[] {
  const fraction = word % 8388608, field = Math.floor(word / 8388608) % 256;
  if (field === 255) return fraction !== 0 ? [110, 97, 110] : word >= 2147483648 ? [45, 105, 110, 102] : [105, 110, 102];
  if (field === 0 && fraction === 0) return [48];
  const mantissa = field === 0 ? fraction : fraction + 8388608, binaryExponent = field === 0 ? -149 : field - 150;
  const exact = nscChartBinaryDecimal(mantissa, binaryExponent);
  const lower = nscChartBinaryDecimal(mantissa * 4 - (fraction === 0 && field > 1 ? 1 : 2), binaryExponent - 2);
  const upper = nscChartBinaryDecimal(mantissa * 4 + 2, binaryExponent - 2), inclusive = mantissa % 2 === 0;
  let coefficient = 0, exponent = 0;
  for (let precision = 1; precision <= 9; precision++) {
    coefficient = 0;
    for (let i = 0; i < precision; i++) coefficient = coefficient * 10 + (i < exact.digits.length ? exact.digits[i]! : 0);
    const next = precision < exact.digits.length ? exact.digits[precision]! : 0;
    let tail = false;
    for (let i = precision + 1; i < exact.digits.length; i++) if (exact.digits[i] !== 0) tail = true;
    if (next > 5 || next === 5 && (tail || coefficient % 2 !== 0)) coefficient++;
    exponent = exact.exponent + exact.digits.length - precision;
    const candidate: NscChartDecimal = { digits: nscChartDigits(coefficient), exponent };
    let lo = nscChartCompare(candidate, lower), hi = nscChartCompare(candidate, upper);
    if (lo < 0 || lo === 0 && !inclusive) coefficient++;
    else if (hi > 0 || hi === 0 && !inclusive) coefficient--;
    const adjacent: NscChartDecimal = { digits: nscChartDigits(coefficient), exponent };
    lo = nscChartCompare(adjacent, lower); hi = nscChartCompare(adjacent, upper);
    if ((lo > 0 || inclusive && lo === 0) && (hi < 0 || inclusive && hi === 0)) break;
    if (precision === 9) throw new Error("chart label shortest decimal was not found");
  }
  while (coefficient % 10 === 0) { coefficient /= 10; exponent++; }
  const length = nscChartDigits(coefficient).length, decimals = Math.min(3, places);
  const keep = Math.max(0, decimals + length + exponent);
  if (keep < length) {
    for (let i = keep + 1; i < length; i++) { coefficient = Math.floor(coefficient / 10); exponent++; }
    if (coefficient % 10 >= 5) { coefficient = Math.floor(coefficient / 10) + 1; exponent++; }
    else { coefficient = Math.floor(coefficient / 10); exponent++; }
  }
  const digits = nscChartDigits(coefficient), point = digits.length + exponent, out: number[] = [];
  if (word >= 2147483648 && coefficient !== 0) out.push(45);
  for (let i = 0; i < Math.max(1, point); i++) out.push(point <= 0 || i >= digits.length ? 48 : 48 + digits[i]!);
  if (decimals > 0) {
    out.push(46);
    for (let i = 0; i < decimals; i++) { const at = point + i; out.push(at < 0 || at >= digits.length ? 48 : 48 + digits[at]!); }
    while (out[out.length - 1] === 48) out.pop();
    if (out[out.length - 1] === 46) out.pop();
  }
  return out.length === 2 && out[0] === 45 && out[1] === 48 ? [48] : out;
}

interface NscChartRenderSeries {
  chartSeriesKind: number; chartSeriesFill: boolean; chartSeriesWords: number[];
  chartSeriesLow: number[]; chartSeriesLabel: number[]; chartSeriesColor: number[];
}
interface NscChartRenderSource { chartRenderSeries: NscChartRenderSeries[]; chartRenderLabels: number[][] }
function nscChartRenderSource(w: DataView, bytes: Uint8Array): NscChartRenderSource {
  let at = 480;
  const series: NscChartRenderSeries[] = [], labels: number[][] = [];
  const octets = (count: number): number[] => {
    if (count > bytes.length - at) throw new Error("truncated chart render bytes");
    const out: number[] = []; for (let i = 0; i < count; i++) out.push(bytes[at++]!); return out;
  };
  const words = (count: number): number[] => {
    if (count > Math.floor((bytes.length - at) / 4)) throw new Error("truncated chart render samples");
    const out: number[] = []; for (let i = 0; i < count; i++) { out.push(w.getUint32(at, true)); at += 4; } return out;
  };
  const count = w.getUint32(8, true), labelCount = w.getUint32(12, true);
  if (count > Math.floor((bytes.length - at) / 40)) throw new Error("truncated chart render table");
  for (let i = 0; i < count; i++) {
    if (at + 40 > bytes.length) throw new Error("truncated chart render series");
    const kind = w.getUint32(at, true), fill = w.getUint32(at + 4, true), values = w.getUint32(at + 8, true), lows = w.getUint32(at + 12, true), length = w.getUint32(at + 16, true);
    if (kind > 2 || fill > 1 || w.getUint32(at + 20, true) !== 0) throw new Error("invalid chart render series");
    const color = [w.getUint32(at + 24, true), w.getUint32(at + 28, true), w.getUint32(at + 32, true), w.getUint32(at + 36, true)];
    at += 40; const label = octets(length), samples = words(values), low = words(lows);
    series.push({ chartSeriesKind: kind, chartSeriesFill: fill !== 0, chartSeriesWords: samples, chartSeriesLow: low, chartSeriesLabel: label, chartSeriesColor: color });
  }
  if (labelCount > Math.floor((bytes.length - at) / 4)) throw new Error("truncated chart render labels");
  for (let i = 0; i < labelCount; i++) {
    if (at + 4 > bytes.length) throw new Error("truncated chart render label header");
    const length = w.getUint32(at, true); at += 4; labels.push(octets(length));
  }
  if (at !== bytes.length) throw new Error("trailing chart render facts");
  return { chartRenderSeries: series, chartRenderLabels: labels };
}
function nscChartIdentity(id: NscPrimitiveWord, family: number, series: number, ordinal: number): NscPrimitiveWord {
  const secret0 = { primitiveLo: 0x78bd642f, primitiveHi: 0xa0761d64 }, secret1 = { primitiveLo: 0xa0b428db, primitiveHi: 0xe7037ed1 };
  const seed = { primitiveLo: family, primitiveHi: 0x5eedc4a8 }, row = { primitiveLo: series, primitiveHi: 0 }, item = { primitiveLo: ordinal, primitiveHi: 0 };
  const initial = nscvPrimitiveXor(seed, nscvPrimitiveMix(nscvPrimitiveXor(seed, secret0), secret1));
  const state = nscvPrimitiveMix(nscvPrimitiveXor(id, secret1), nscvPrimitiveXor(row, initial));
  const product = nscvPrimitiveMultiply(nscvPrimitiveXor(row, secret1), nscvPrimitiveXor(item, state));
  const result = nscvPrimitiveMix(nscvPrimitiveXor(nscvPrimitiveXor(product.productLower, secret0), { primitiveLo: 24, primitiveHi: 0 }), nscvPrimitiveXor(product.productUpper, secret1));
  return result.primitiveLo === 0 && result.primitiveHi === 0 ? { primitiveLo: 1, primitiveHi: 0 } : result;
}

/** One capability at a time preserves resource failures and measurement order.
 * The caller copies the continuation before a nested policy call or arena reset.
 * Modes: render, plot, hover index, hover geometry, and hover drawing. */
function nscvChartPlans(request: Uint8Array): Uint8Array {
  if (request.length < 480 || request[0] !== 50 || request[1] !== 1 || request[2]! > 4 || request[3]! > 15 || request[4]! > 1 || request[5]! > 3 || request[6] !== 0 || request[7] !== 0) throw new Error("invalid chart plan header");
  for (let i = 428; i < 480; i++) if (request[i] !== 0) throw new Error("invalid chart plan reserved bytes");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), f = Math.fround;
  const source = nscChartRenderSource(w, request), series = source.chartRenderSeries, labels = source.chartRenderLabels;
  const mode = request[2]!, flags = w.getUint32(104, true), grid = w.getUint32(108, true);
  if (flags > 127 || grid > 255) throw new Error("invalid chart plan facts");
  const max = (a: number, b: number): number => nscvRenderExtreme(a, b, request[3]!, true);
  const min = (a: number, b: number): number => nscvRenderExtreme(a, b, request[3]!, false);
  const clamp = (x: number, lo: number, hi: number): number => max(lo, min(x, hi));
  const v = (at: number): number => w.getFloat32(at, true);
  const bits = (x: number): number => { const wire = new DataView(new ArrayBuffer(4)); wire.setFloat32(0, x, true); return wire.getUint32(0, true); };
  const value = (word: number): number => { const wire = new DataView(new ArrayBuffer(4)); wire.setUint32(0, word, true); return wire.getFloat32(0, true); };
  const state = [w.getUint32(240, true), w.getUint32(244, true), w.getUint32(248, true), w.getUint32(252, true)];
  const cells: number[] = []; for (let i = 0; i < 40; i++) cells.push(v(256 + i * 4));
  const getRect = (at: number): NscSurfaceRect => ({ x: cells[at]!, y: cells[at + 1]!, width: cells[at + 2]!, height: cells[at + 3]! });
  const setRect = (at: number, rect: NscSurfaceRect): void => { cells[at] = rect.x; cells[at + 1] = rect.y; cells[at + 2] = rect.width; cells[at + 3] = rect.height; };
  const rawRect = (at: number): NscSurfaceRect => ({ x: v(at), y: v(at + 4), width: v(at + 8), height: v(at + 12) });
  const palette = (at: number): number[] => [w.getUint32(160 + at * 16, true), w.getUint32(164 + at * 16, true), w.getUint32(168 + at * 16, true), w.getUint32(172 + at * 16, true)];
  const faded = (color: readonly number[], factor: number): number[] => [color[0]!, color[1]!, color[2]!, bits(clamp(factor, 0, 1))];
  const round = (x: number): number => x < 0 || 1 / x < 0 ? -Math.floor(-x + 0.5) : Math.floor(x + 0.5);
  const snap = (x: number): number => f(round(f(x * v(100))) / v(100));
  const snapping = Number.isFinite(v(100)) && v(100) > 0;
  const snapRect = (r: NscSurfaceRect): NscSurfaceRect => {
    if ((request[5]! & 1) === 0 || !snapping) return r;
    const n = nscvSurfaceNormalize(r), x = snap(n.x), y = snap(n.y);
    return { x, y, width: max(0, f(snap(f(n.x + n.width)) - x)), height: max(0, f(snap(f(n.y + n.height)) - y)) };
  };
  const pointCount = (): number => { let count = 0; for (const row of series) count = Math.max(count, row.chartSeriesWords.length); return count; };
  const barsOnly = (): boolean => { for (const row of series) if (row.chartSeriesWords.length > 0 && row.chartSeriesKind !== 1) return false; return true; };
  const baseline = (): number => clamp(0, cells[8]!, cells[9]!);
  const mapY = (x: number, inset: number): number => {
    const p = getRect(4), fraction = clamp(f(f(x - cells[8]!) / f(cells[9]! - cells[8]!)), 0, 1);
    return f(f(f(p.y + p.height) - inset) - f(fraction * max(0, f(p.height - f(inset * 2)))));
  };
  const mapX = (ordinal: number, count: number, inset: number): number => {
    const p = getRect(4), width = max(0, f(p.width - f(inset * 2))), origin = f(p.x + inset);
    return count <= 1 ? f(origin + f(width * 0.5)) : f(origin + f(f(width * f(ordinal)) / f(count - 1)));
  };
  const sampleX = (ordinal: number, count: number): number => barsOnly() && count > 0 ? f(cells[4]! + f(f(cells[6]! / f(count)) * f(f(ordinal) + 0.5))) : mapX(ordinal, count, 0);
  const tick = (ordinal: number): number => f(cells[10]! + f(cells[11]! * f(ordinal)));
  const decimals = (step: number): number => !Number.isFinite(step) || step <= 0 ? 2 : step >= 1 ? 0 : step >= f(0.1) ? 1 : step >= f(0.01) ? 2 : 3;
  const points = (row: NscChartRenderSeries, inset: number): number[][] => {
    const count = Math.min(256, row.chartSeriesWords.length), out: number[][] = [];
    for (let i = 0; i < count; i++) { const x = value(row.chartSeriesWords[i]!); if (Number.isFinite(x)) out.push([mapX(i, count, inset), mapY(x, inset)]); } return out;
  };
  const result = (action: number, admitted = true, payload: readonly number[] = [], path = false): Uint8Array => {
    const bytes = new Uint8Array(288 + payload.length * (path ? 4 : 1)), out = new DataView(bytes.buffer);
    out.setUint32(0, 1, true); out.setUint32(4, action, true); out.setUint32(8, admitted ? 1 : 0, true);
    for (let i = 0; i < 4; i++) out.setUint32(16 + i * 4, state[i]!, true);
    for (let i = 0; i < 40; i++) out.setFloat32(32 + i * 4, cells[i]!, true);
    if (path) { out.setUint32(252, payload.length / 7, true); for (let i = 0; i < payload.length; i++) { if (i % 7 === 0) out.setUint32(288 + i * 4, payload[i]!, true); else out.setFloat32(288 + i * 4, payload[i]!, true); } }
    else { out.setUint32(252, payload.length, true); bytes.set(payload, 288); }
    return bytes;
  };
  const draw = (action: number, family: number, row: number, ordinal: number, rect: NscSurfaceRect, color: readonly number[], radius = 0, width = 0, path: readonly number[] = [], snapped = false): Uint8Array => {
    const bytes = result(action, true, path, true), out = new DataView(bytes.buffer);
    nscvPrimitiveWrite(out, 192, nscChartIdentity(nscvPrimitiveWord(w, 16), family, row, ordinal));
    const r = action === 2 || snapped ? snapRect(rect) : rect;
    for (let i = 0; i < 4; i++) out.setFloat32(200 + i * 4, i === 0 ? r.x : i === 1 ? r.y : i === 2 ? r.width : r.height, true);
    for (let i = 0; i < 4; i++) out.setUint32(236 + i * 4, color[i]!, true);
    out.setFloat32(228, width, true); out.setFloat32(232, radius, true);
    if (family === 8 && ordinal >= 1 && ordinal <= 3) out.setUint32(232, w.getUint32(84, true), true);
    return bytes;
  };
  const text = (action: number, kind: number, row: number, ordinal: number, bytes: readonly number[], allocate: boolean, family = 0, x = 0, y = 0, color: readonly number[] = []): Uint8Array => {
    const reply = result(action, true, bytes), out = new DataView(reply.buffer);
    out.setUint32(256, kind, true); out.setUint32(260, row, true); out.setUint32(264, ordinal, true); out.setUint32(268, allocate ? 1 : 0, true); out.setFloat32(224, cells[14]!, true);
    if (action === 4) {
      nscvPrimitiveWrite(out, 192, nscChartIdentity(nscvPrimitiveWord(w, 16), family, row, ordinal));
      out.setFloat32(216, (request[5]! & 2) !== 0 && snapping ? snap(x) : x, true); out.setFloat32(220, (request[5]! & 2) !== 0 && snapping ? snap(y) : y, true);
      for (let i = 0; i < 4; i++) out.setUint32(236 + i * 4, color[i]!, true);
    }
    return reply;
  };
  const title = (): number[] => state[3]! < labels.length && labels[state[3]!]!.length > 0 ? labels[state[3]!]! : nscChartLabel(bits(f(state[3]!)), 0);
  const nameKind = (row: number): number => series[row]!.chartSeriesLabel.length > 0 ? 2 : 3;
  const pathWords = (p: readonly (readonly number[])[], close: boolean): number[] => {
    const out: number[] = []; for (let i = 0; i < p.length; i++) out.push(i === 0 ? 0 : 1, p[i]![0]!, p[i]![1]!, 0, 0, 0, 0);
    if (close) out.push(2, 0, 0, 0, 0, 0, 0); return out;
  };
  const empty: NscSurfaceRect = { x: 0, y: 0, width: 0, height: 0 };
  // The stages below carry only copied continuations, never borrowed pointers.
  while (true) {
    if (state[0] === 0) {
      if ((mode === 2 || mode === 3) && (flags & 68) !== 68) return result(0, false);
      const frame = rawRect(24), content = nscvSurfaceNormalize({ x: f(frame.x + min(v(52), frame.width)), y: f(frame.y + min(v(40), frame.height)), width: max(0, f(f(frame.width - v(52)) - v(44))), height: max(0, f(f(frame.height - v(40)) - v(48))) });
      setRect(0, content); setRect(4, content);
      let hasValue = false, low = 0, high = 0;
      for (const row of series) {
        for (const word of row.chartSeriesWords) {
          const x = value(word); if (!Number.isFinite(x)) continue;
          if (!hasValue) { hasValue = true; low = x; high = x; } else { low = min(low, x); high = max(high, x); }
        }
        if (row.chartSeriesKind === 2) for (const word of row.chartSeriesLow) {
          const x = value(word); if (!Number.isFinite(x)) continue;
          if (!hasValue) { hasValue = true; low = x; high = x; } else { low = min(low, x); high = max(high, x); }
        }
        if (row.chartSeriesKind === 1 && hasValue) { low = min(low, 0); high = max(high, 0); }
      }
      if (!hasValue) { low = 0; high = 1; }
      if ((flags & 8) !== 0 && Number.isFinite(v(112))) low = v(112);
      if ((flags & 16) !== 0 && Number.isFinite(v(116))) high = v(116);
      if (!(high > low)) { high = f(low + 0.5); low = f(low - 0.5); }
      cells[8] = low; cells[9] = high;
      const raw = f(f(high - low) / f(Math.max(1, Math.min(grid + 1, 12))));
      const magnitude = nscChartPower10(Math.floor(request[4] === 0 ? nscChartLog10(raw) : f(Math.log10(raw))));
      const normalized = f(raw / magnitude), step = f((normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10) * magnitude);
      const start = f(Math.ceil(f(low / step)) * step);
      let count = 0;
      while (count < 13) { if (f(start + f(step * f(count))) > f(high + f(step * f(0.001)))) break; count++; }
      cells[10] = start; cells[11] = step; cells[12] = count; cells[13] = decimals(step);
      cells[14] = max(9, f(v(72) - 2)); cells[15] = f(cells[14]! * 1.25);
      const explicit = (flags & 32) !== 0 ? v(80) : 1.5;
      cells[29] = Number.isFinite(explicit) && explicit > 0 ? explicit : 1.5;
      state[1] = 0; state[2] = 0; cells[16] = 0;
      if (mode === 4) { setRect(4, rawRect(124)); setRect(20, snapRect(rawRect(144))); state[3] = w.getUint32(120, true); cells[19] = v(140); cells[14] = max(10, f(v(72) - 1)); cells[15] = f(cells[14]! * 1.25); state[0] = 80; }
      else state[0] = 1;
      continue;
    }
    if (state[0] === 1) {
      if ((flags & 2) !== 0 && state[1]! < cells[12]!) { const ordinal = state[1]!; state[0] = 101; return text(1, 4, 0, ordinal, nscChartLabel(bits(tick(ordinal)), cells[13]!), false); }
      const gutter = (flags & 2) !== 0 ? f(Math.ceil(cells[16]!) + 6) : 0;
      if ((flags & 2) !== 0) { cells[4] = f(cells[4]! + gutter); cells[6] = max(0, f(cells[6]! - gutter)); }
      if (labels.length > 0) cells[7] = max(0, f(cells[7]! - f(cells[15]! + 6)));
      state[0] = 2; state[1] = 0; continue;
    }
    if (state[0] === 101) { cells[16] = max(cells[16]!, v(416)); state[1] = state[1]! + 1; state[0] = 1; continue; }
    if (state[0] === 2) {
      const plot = getRect(4);
      if (mode === 1) return result(0);
      if (nscvRenderEmpty(plot) || plot.width <= 0 || plot.height <= 0) return result(0, false);
      if (mode === 2 || mode === 3) {
        const count = pointCount(), fraction = f(f(v(420) - plot.x) / plot.width);
        if (count === 0 || !Number.isFinite(fraction)) return result(0, false);
        const clamped = clamp(fraction, 0, 1);
        const ordinal = count === 1 ? 0 : barsOnly() ? Math.min(Math.trunc(f(clamped * f(count))), count - 1) : Math.min(round(f(clamped * f(count - 1))), count - 1);
        state[3] = ordinal; cells[19] = sampleX(ordinal, count);
        if (mode === 2) return result(0);
        cells[14] = max(10, f(v(72) - 1)); cells[15] = f(cells[14]! * 1.25); state[1] = 0; state[2] = 0; state[0] = 50; continue;
      }
      state[0] = 10; state[1] = 0; continue;
    }
    if (state[0] === 10) {
      const count = grid > 0 && (flags & 2) !== 0 ? cells[12]! : grid;
      while (state[1]! < count) {
        const ordinal = state[1]!; state[1] = ordinal + 1;
        const y = (flags & 2) !== 0 ? mapY(tick(ordinal), 0) : f(cells[5]! + f(f(cells[7]! * f(ordinal + 1)) / f(grid + 1)));
        if ((flags & 2) !== 0 && (tick(ordinal) <= cells[8]! || tick(ordinal) >= cells[9]!)) continue;
        const hairline = max(1, v(76));
        return draw(2, 1, 0, ordinal, { x: cells[4]!, y: f(y - f(hairline * 0.5)), width: cells[6]!, height: hairline }, palette(0));
      }
      state[0] = 11; continue;
    }
    if (state[0] === 11) {
      state[0] = 12; state[1] = 0;
      if ((flags & 1) !== 0) { const h = max(1, v(76)); return draw(2, 2, 0, 0, { x: cells[4]!, y: f(mapY(baseline(), 0) - f(h * 0.5)), width: cells[6]!, height: h }, palette(0)); }
      continue;
    }
    if (state[0] === 12) {
      if ((flags & 2) !== 0 && state[1]! < cells[12]!) { const ordinal = state[1]!; state[0] = 112; return text(1, 4, 0, ordinal, nscChartLabel(bits(tick(ordinal)), cells[13]!), true); }
      state[0] = 13; state[1] = 0; cells[16] = 0; continue;
    }
    if (state[0] === 112) {
      const ordinal = state[1]!, top = clamp(f(mapY(tick(ordinal), 0) - f(cells[15]! * 0.5)), cells[1]!, max(cells[1]!, f(f(cells[1]! + cells[3]!) - cells[15]!)));
      state[1] = ordinal + 1; state[0] = 12;
      return text(4, 5, 0, ordinal, [], false, 7, f(f(cells[4]! - 6) - v(416)), f(top + cells[14]!), palette(1));
    }
    if (state[0] === 13) {
      if (state[1]! < labels.length) { const ordinal = state[1]!; state[0] = 113; return text(1, 1, 0, ordinal, [], false); }
      if (labels.length > 0) {
        const ratio = f(cells[6]! / max(1, f(cells[16]! + 12)));
        if (!Number.isFinite(ratio) || ratio < 0 || ratio >= 18446744073709551616) throw new Error("invalid chart label fit");
        const fit = Math.max(1, Math.trunc(ratio)); state[3] = fit >= labels.length ? 1 : Math.max(1, Math.floor((labels.length + fit - 1) / fit));
      }
      state[0] = 14; state[1] = 0; continue;
    }
    if (state[0] === 113) { cells[16] = max(cells[16]!, v(416)); state[1] = state[1]! + 1; state[0] = 13; continue; }
    if (state[0] === 14) {
      while (state[1]! < labels.length) { const ordinal = state[1]!; if (labels[ordinal]!.length === 0) { state[1] = ordinal + state[3]!; continue; } state[0] = 114; return text(1, 1, 0, ordinal, [], false); }
      state[0] = 20; state[1] = 0; state[2] = 0; continue;
    }
    if (state[0] === 114) {
      const ordinal = state[1]!, width = v(416), center = sampleX(ordinal, Math.max(pointCount(), labels.length));
      const x = clamp(f(center - f(width * 0.5)), cells[0]!, max(cells[0]!, f(f(cells[0]! + cells[2]!) - width)));
      const y = min(f(f(f(cells[5]! + cells[7]!) + 6) + cells[14]!), f(cells[1]! + cells[3]!));
      state[1] = ordinal + state[3]!; state[0] = 14; return text(4, 1, 1, ordinal, [], false, 7, x, y, palette(1));
    }
    if (state[0] === 20 || state[0] === 21) {
      if (state[2]! >= series.length) return result(0);
      const rowIndex = state[2]!, row = series[rowIndex]!, color = row.chartSeriesColor;
      if (row.chartSeriesWords.length === 0) { state[2] = rowIndex + 1; state[1] = 0; state[0] = 20; continue; }
      if (row.chartSeriesKind === 1) {
        const count = row.chartSeriesWords.length, slot = f(cells[6]! / f(count)), gap = count > 1 ? clamp(f(slot * 0.25), 0.5, 4) : 0;
        const width = max(1, f(slot - gap)), base = baseline(), baseY = mapY(base, 0);
        while (state[1]! < count) {
          const ordinal = state[1]!; state[1] = ordinal + 1; const x = value(row.chartSeriesWords[ordinal]!);
          if (!Number.isFinite(x) || x === base) continue;
          const left = f(f(cells[4]! + f(slot * f(ordinal))) + f(f(slot - width) * 0.5)), y = mapY(x, 0), top = min(baseY, y), height = max(1, Math.abs(f(baseY - y)));
          return draw(3, 6, rowIndex, ordinal, { x: left, y: x >= base ? top : baseY, width, height }, color, min(1, f(width * 0.5)), 0, [], true);
        }
        state[2] = rowIndex + 1; state[1] = 0; continue;
      }
      const p = points(row, row.chartSeriesKind === 0 ? f(cells[29]! * 0.5) : 0);
      if (p.length === 0 || row.chartSeriesKind === 2 && p.length < 2) { state[2] = rowIndex + 1; state[1] = 0; continue; }
      if (row.chartSeriesKind === 0 && p.length === 1) {
        const extent = max(2, f(cells[29]! * 2)); state[2] = rowIndex + 1; state[1] = 0;
        return draw(3, 3, rowIndex, 0, { x: f(p[0]![0]! - f(extent * 0.5)), y: f(p[0]![1]! - f(extent * 0.5)), width: extent, height: extent }, color, f(extent * 0.5));
      }
      if (row.chartSeriesKind === 2) {
        const pairCount = Math.min(row.chartSeriesWords.length, row.chartSeriesLow.length), baseY = mapY(baseline(), 0);
        if (pairCount >= 2) for (let ordinal = pairCount - 1; ordinal >= 0; ordinal--) { const raw = value(row.chartSeriesLow[ordinal]!); p.push([mapX(ordinal, row.chartSeriesWords.length, 0), mapY(Number.isFinite(raw) ? raw : baseline(), 0)]); }
        else { p.push([p[p.length - 1]![0]!, baseY]); p.push([p[0]![0]!, baseY]); }
        state[2] = rowIndex + 1; state[1] = 0; return draw(5, 5, rowIndex, 0, empty, faded(color, 0.25), 0, 0, pathWords(p, true));
      }
      if (state[0] === 20 && row.chartSeriesFill) {
        const baseY = mapY(baseline(), 0); p.push([p[p.length - 1]![0]!, baseY]); p.push([p[0]![0]!, baseY]);
        state[0] = 21; return draw(5, 4, rowIndex, 0, empty, faded(color, f(0.18)), 0, 0, pathWords(p, true));
      }
      state[2] = rowIndex + 1; state[1] = 0; state[0] = 20; return draw(6, 3, rowIndex, 0, empty, color, 0, cells[29]!, pathWords(p, false));
    }
    if (state[0] === 50) { state[0] = 150; return text(1, 4, 0, 0, title(), false); }
    if (state[0] === 150) { cells[25] = v(416); state[0] = 51; continue; }
    if (state[0] === 51) {
      while (state[2]! < series.length && state[3]! >= series[state[2]!]!.chartSeriesWords.length) state[2] = state[2]! + 1;
      if (state[2]! < series.length) { state[0] = 151; return text(1, nameKind(state[2]!), state[2]!, 0, [], false); }
      if (state[1] === 0) return result(0, false);
      const width = f(Math.ceil(cells[25]!) + 20), height = f(f(16 + f(cells[15]! * f(state[1]! + 1))) + f(2 * f(state[1]!)));
      const bounds = rawRect(56), sample = cells[19]!;
      let x = f(sample + 12);
      if (f(x + width) > f(f(bounds.x + bounds.width) - 4)) x = f(f(sample - 12) - width);
      x = clamp(x, f(bounds.x + 4), max(f(bounds.x + 4), f(f(f(bounds.x + bounds.width) - width) - 4)));
      const y = clamp(f(cells[5]! + f(f(cells[7]! - height) * 0.5)), f(bounds.y + 4), max(f(bounds.y + 4), f(f(f(bounds.y + bounds.height) - height) - 4)));
      setRect(20, { x, y, width, height }); return result(0);
    }
    if (state[0] === 151) {
      cells[26] = v(416); state[0] = 152;
      return text(1, 4, 0, 0, nscChartLabel(series[state[2]!]!.chartSeriesWords[state[3]!]!, decimals(f(f(cells[9]! - cells[8]!) / 100))), false);
    }
    if (state[0] === 152) {
      const width = f(f(f(f(8 + 6) + cells[26]!) + 16) + v(416));
      cells[25] = max(cells[25]!, width); state[1] = state[1]! + 1; state[2] = state[2]! + 1; state[0] = 51; continue;
    }
    if (state[0] === 80) {
      const h = max(1, v(76)); state[0] = 81; state[2] = 0;
      return draw(2, 8, 0, 0, { x: f(cells[19]! - f(h * 0.5)), y: cells[5]!, width: h, height: cells[7]! }, palette(0));
    }
    if (state[0] === 81) {
      while (state[2]! < series.length) {
        const row = state[2]!, entry = series[row]!; state[2] = row + 1;
        if (entry.chartSeriesKind !== 0 || state[3]! >= entry.chartSeriesWords.length) continue;
        const x = value(entry.chartSeriesWords[state[3]!]!); if (!Number.isFinite(x)) continue;
        const inset = f(cells[29]! * 0.5);
        return draw(3, 9, row, 0, { x: f(mapX(state[3]!, entry.chartSeriesWords.length, inset) - 3), y: f(mapY(x, inset) - 3), width: 6, height: 6 }, entry.chartSeriesColor, 3);
      }
      state[0] = 82; continue;
    }
    if (state[0] === 82) {
      state[0] = 83;
      if (v(88) !== 0 || v(92) !== 0 || v(96) !== 0) return draw(7, 8, 0, 1, getRect(20), palette(4), v(84));
      continue;
    }
    if (state[0] === 83) { state[0] = 84; return draw(3, 8, 0, 2, getRect(20), palette(3), v(84)); }
    if (state[0] === 84) { state[0] = 85; return draw(8, 8, 0, 3, getRect(20), palette(0), v(84), max(1, v(76))); }
    if (state[0] === 85) {
      cells[24] = f(cells[21]! + 8); const y = f(cells[24]! + cells[14]!);
      cells[24] = f(cells[24]! + cells[15]!); state[0] = 86; state[2] = 0;
      return text(4, 4, 0, 4, title(), true, 8, f(cells[20]! + 10), y, palette(2));
    }
    if (state[0] === 86) {
      while (state[2]! < series.length && state[3]! >= series[state[2]!]!.chartSeriesWords.length) state[2] = state[2]! + 1;
      if (state[2]! >= series.length) return result(0);
      cells[24] = f(cells[24]! + 2); state[0] = 87;
      return draw(3, 10, state[2]!, 0, { x: f(cells[20]! + 10), y: f(cells[24]! + f(f(cells[15]! - 8) * 0.5)), width: 8, height: 8 }, series[state[2]!]!.chartSeriesColor, 2, 0, [], true);
    }
    if (state[0] === 87) {
      state[0] = 88;
      return text(4, nameKind(state[2]!), state[2]!, 1, [], false, 10, f(f(f(cells[20]! + 10) + 8) + 6), f(cells[24]! + cells[14]!), palette(1));
    }
    if (state[0] === 88) {
      state[0] = 188;
      return text(1, 4, state[2]!, 2, nscChartLabel(series[state[2]!]!.chartSeriesWords[state[3]!]!, decimals(f(f(cells[9]! - cells[8]!) / 100))), true);
    }
    if (state[0] === 188) {
      const row = state[2]!, y = f(cells[24]! + cells[14]!), x = f(f(f(cells[20]! + cells[22]!) - 10) - v(416));
      cells[24] = f(cells[24]! + cells[15]!); state[2] = row + 1; state[0] = 86;
      return text(4, 5, row, 2, [], false, 10, x, y, palette(2));
    }
    throw new Error("invalid chart plan continuation");
  }
}
