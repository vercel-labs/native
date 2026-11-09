/** Copied vector geometry and coverage programs. Native retains the edge,
 * crossing and pixel buffers; no address or sink crosses this boundary. */
interface NscRasterPoint { x: number; y: number }
interface NscRasterEdge { x0: number; y0: number; x1: number; y1: number; dir: number }

function nscvRasterPoint(x: number, y: number): NscRasterPoint { return { x, y }; }
function nscvRasterNormalize(p: NscRasterPoint): NscRasterPoint | null {
  const f = Math.fround, length = f(Math.sqrt(f(f(p.x * p.x) + f(p.y * p.y))));
  return length <= f(0.000001) ? null : { x: f(p.x / length), y: f(p.y / length) };
}
function nscvRasterSegments(a: NscRasterPoint, b: NscRasterPoint, c: NscRasterPoint, d: NscRasterPoint | null, tolerance: number, limit: number, rules: number): number {
  const f = Math.fround;
  let deviation = nscvResourceExtremum(Math.abs(f(f(a.x - f(2 * b.x)) + c.x)), Math.abs(f(f(a.y - f(2 * b.y)) + c.y)), true, rules);
  if (d !== null) deviation = f(nscvResourceExtremum(deviation, nscvResourceExtremum(Math.abs(f(f(b.x - f(2 * c.x)) + d.x)), Math.abs(f(f(b.y - f(2 * c.y)) + d.y)), true, rules), true, rules) * 0.75);
  else deviation = f(deviation * 0.25);
  const tol = nscvResourceExtremum(f(0.01), tolerance, true, rules);
  if (!(deviation > tol)) return 1;
  const count = Math.ceil(f(Math.sqrt(f(deviation / tol))));
  return !(count > 1) ? 1 : count >= limit ? limit : count;
}
function nscvRasterCurve(a: NscRasterPoint, b: NscRasterPoint, c: NscRasterPoint, d: NscRasterPoint | null, t: number): NscRasterPoint {
  const f = Math.fround, u = f(1 - t);
  if (d === null) return {
    x: f(f(f(f(u * u) * a.x) + f(f(f(2 * u) * t) * b.x)) + f(f(t * t) * c.x)),
    y: f(f(f(f(u * u) * a.y) + f(f(f(2 * u) * t) * b.y)) + f(f(t * t) * c.y)),
  };
  return {
    x: f(f(f(f(f(f(u * u) * u) * a.x) + f(f(f(f(3 * u) * u) * t) * b.x)) + f(f(f(f(3 * u) * t) * t) * c.x)) + f(f(f(t * t) * t) * d.x)),
    y: f(f(f(f(f(f(u * u) * u) * a.y) + f(f(f(f(3 * u) * u) * t) * b.y)) + f(f(f(f(3 * u) * t) * t) * c.y)) + f(f(f(t * t) * t) * d.y)),
  };
}

class NscVectorRaster {
  edges: NscRasterEdge[] = [];
  status = 0;
  minX = 0; minY = 0; maxX = 0; maxY = 0;
  capacity: number; rules: number;
  constructor(capacity: number, rules: number) { this.capacity = capacity; this.rules = rules; }
  edge(a: NscRasterPoint, b: NscRasterPoint): void {
    if (this.status !== 0 || a.y === b.y || !Number.isFinite(a.x) || !Number.isFinite(a.y) || !Number.isFinite(b.x) || !Number.isFinite(b.y)) return;
    if (this.edges.length >= this.capacity) { this.status = 1; return; }
    const x = nscvResourceExtremum(a.x, b.x, false, this.rules), right = nscvResourceExtremum(a.x, b.x, true, this.rules);
    const y = nscvResourceExtremum(a.y, b.y, false, this.rules), bottom = nscvResourceExtremum(a.y, b.y, true, this.rules);
    if (this.edges.length === 0) { this.minX = x; this.maxX = right; this.minY = y; this.maxY = bottom; }
    else {
      this.minX = nscvResourceExtremum(this.minX, x, false, this.rules); this.maxX = nscvResourceExtremum(this.maxX, right, true, this.rules);
      this.minY = nscvResourceExtremum(this.minY, y, false, this.rules); this.maxY = nscvResourceExtremum(this.maxY, bottom, true, this.rules);
    }
    this.edges.push({ x0: a.x, y0: a.y, x1: b.x, y1: b.y, dir: b.y > a.y ? 1 : -1 });
  }
  polygon(points: readonly NscRasterPoint[]): void {
    if (points.length < 3 || this.status !== 0) return;
    const f = Math.fround;
    let area = 0;
    for (let i = 0; i < points.length; i++) {
      const a = points[i]!, b = points[(i + 1) % points.length]!;
      area = f(area + f(f(a.x * b.y) - f(b.x * a.y)));
    }
    if (Math.abs(area) <= f(0.000000001)) return;
    if (area >= 0) for (let i = 0; i < points.length && this.status === 0; i++) this.edge(points[i]!, points[(i + 1) % points.length]!);
    else for (let i = points.length; i > 0 && this.status === 0; i--) this.edge(points[i % points.length]!, points[i - 1]!);
  }
  disc(center: NscRasterPoint, radius: number, tolerance: number): void {
    if (radius <= 0 || this.status !== 0) return;
    const f = Math.fround, k = f(f(0.5522847498307936) * radius), x = center.x, y = center.y;
    const anchors = [{ x: f(x + radius), y }, { x, y: f(y + radius) }, { x: f(x - radius), y }, { x, y: f(y - radius) }, { x: f(x + radius), y }];
    const first = [{ x: f(x + radius), y: f(y + k) }, { x: f(x - k), y: f(y + radius) }, { x: f(x - radius), y: f(y - k) }, { x: f(x + k), y: f(y - radius) }];
    const second = [{ x: f(x + k), y: f(y + radius) }, { x: f(x - radius), y: f(y + k) }, { x: f(x - k), y: f(y - radius) }, { x: f(x + radius), y: f(y - k) }];
    const points: NscRasterPoint[] = [anchors[0]!];
    for (let q = 0; q < 4; q++) {
      const a = anchors[q]!, b = first[q]!, c = second[q]!, d = anchors[q + 1]!;
      const count = nscvRasterSegments(a, b, c, d, tolerance, 48, this.rules);
      for (let i = 1; i <= count; i++) points.push(nscvRasterCurve(a, b, c, d, f(i / count)));
    }
    points.pop(); this.polygon(points);
  }
  segment(a: NscRasterPoint, b: NscRasterPoint, half: number): void {
    const f = Math.fround, dx = f(b.x - a.x), dy = f(b.y - a.y), length = f(Math.sqrt(f(f(dx * dx) + f(dy * dy))));
    if (length <= f(0.000001)) return;
    const nx = f(f(dy / length) * half), ny = f(f(-dx / length) * half);
    this.polygon([{ x: f(a.x + nx), y: f(a.y + ny) }, { x: f(b.x + nx), y: f(b.y + ny) }, { x: f(b.x - nx), y: f(b.y - ny) }, { x: f(a.x - nx), y: f(a.y - ny) }]);
  }
  join(prev: NscRasterPoint, vertex: NscRasterPoint, next: NscRasterPoint, half: number, round: boolean, miter: number, tolerance: number): void {
    const f = Math.fround, din = nscvRasterNormalize({ x: f(vertex.x - prev.x), y: f(vertex.y - prev.y) }), dout = nscvRasterNormalize({ x: f(next.x - vertex.x), y: f(next.y - vertex.y) });
    if (din === null || dout === null) return;
    const cross = f(f(din.x * dout.y) - f(din.y * dout.x)), dot = f(f(din.x * dout.x) + f(din.y * dout.y));
    if (dot > 0 && f(half * f(1 - dot)) < f(tolerance * 0.25)) return;
    if (round) { this.disc(vertex, half, tolerance); return; }
    if (Math.abs(cross) <= f(0.000001)) return;
    const sign = cross > 0 ? 1 : -1;
    const na = { x: f(f(din.y * sign) * half), y: f(f(-din.x * sign) * half) }, nb = { x: f(f(dout.y * sign) * half), y: f(f(-dout.x * sign) * half) };
    const a = { x: f(vertex.x + na.x), y: f(vertex.y + na.y) }, b = { x: f(vertex.x + nb.x), y: f(vertex.y + nb.y) };
    const mid = nscvRasterNormalize({ x: f(na.x + nb.x), y: f(na.y + nb.y) });
    if (mid === null) return;
    const cosine = f(f(f(mid.x * na.x) + f(mid.y * na.y)) / half);
    if (cosine <= f(0.000001)) return;
    const ratio = f(1 / cosine);
    if (ratio <= nscvResourceExtremum(1, miter, true, this.rules)) {
      const length = f(half * ratio), tip = { x: f(vertex.x + f(mid.x * length)), y: f(vertex.y + f(mid.y * length)) };
      this.polygon([vertex, a, tip, b]);
    } else this.polygon([vertex, a, b]);
  }
  stroke(points: readonly NscRasterPoint[], closed: boolean, half: number, cap: number, join: number, miter: number, tolerance: number): void {
    if (points.length === 0) return;
    if (points.length === 1) { if (cap === 1) this.disc(points[0]!, half, tolerance); return; }
    const count = closed ? points.length : points.length - 1;
    for (let i = 0; i < count && this.status === 0; i++) this.segment(points[i]!, points[(i + 1) % points.length]!, half);
    if (closed) for (let i = 0; i < points.length && this.status === 0; i++) this.join(points[(i + points.length - 1) % points.length]!, points[i]!, points[(i + 1) % points.length]!, half, join === 1, miter, tolerance);
    else {
      for (let i = 1; i + 1 <= points.length - 1 && this.status === 0; i++) this.join(points[i - 1]!, points[i]!, points[i + 1]!, half, join === 1, miter, tolerance);
      if (cap === 1 && this.status === 0) { this.disc(points[0]!, half, tolerance); this.disc(points[points.length - 1]!, half, tolerance); }
    }
  }
}

function nscvVectorRaster(request: Uint8Array): Uint8Array {
  if (request.length < 4 || request[0] !== 66 || request[1] !== 1 || request[2]! > 3 || request[3]! > 15) throw new Error("invalid vector raster header");
  const mode = request[2]!, rules = request[3]!, w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  if (mode >= 2) return nscvRasterSweep(request, w, mode, rules);
  if (request.length < 96) throw new Error("truncated vector geometry facts");
  const count = w.getUint32(4, true), capacity = w.getUint32(8, true), initial = w.getUint32(12, true), limit = w.getUint32(16, true);
  if (capacity > 18560 || initial > capacity || (limit !== 16 && limit !== 48) || request.length !== 96 + count * 28 + initial * 20 || w.getUint32(36, true) > 1 || w.getUint32(40, true) > 1) throw new Error("invalid vector geometry bounds");
  for (const at of [20, 44, 88, 92]) if (w.getUint32(at, true) !== 0) throw new Error("invalid vector geometry tail");
  for (let i = 0; i < count; i++) if (w.getUint32(96 + i * 28, true) > 4) throw new Error("invalid vector path verb");
  const f = Math.fround, tolerance = w.getFloat32(24, true), width = w.getFloat32(28, true), miter = w.getFloat32(32, true), cap = w.getUint32(36, true), join = w.getUint32(40, true);
  const raster = new NscVectorRaster(capacity, rules);
  raster.minX = w.getFloat32(72, true); raster.minY = w.getFloat32(76, true); raster.maxX = w.getFloat32(80, true); raster.maxY = w.getFloat32(84, true);
  for (let i = 0; i < initial; i++) {
    const at = 96 + count * 28 + i * 20;
    raster.edges.push({ x0: w.getFloat32(at, true), y0: w.getFloat32(at + 4, true), x1: w.getFloat32(at + 8, true), y1: w.getFloat32(at + 12, true), dir: w.getFloat32(at + 16, true) });
  }
  const transform = (at: number): NscRasterPoint => {
    const x = w.getFloat32(at, true), y = w.getFloat32(at + 4, true);
    return { x: f(f(f(w.getFloat32(48, true) * x) + f(w.getFloat32(56, true) * y)) + w.getFloat32(64, true)), y: f(f(f(w.getFloat32(52, true) * x) + f(w.getFloat32(60, true) * y)) + w.getFloat32(68, true)) };
  };
  let active = false, has = false, current = nscvRasterPoint(0, 0), start = nscvRasterPoint(0, 0), fillStart = start, fillCurrent = start;
  let points: NscRasterPoint[] = [];
  const begin = (p: NscRasterPoint): void => { active = true; fillStart = p; fillCurrent = p; points = [p]; };
  const point = (p: NscRasterPoint): void => {
    if (mode === 0) { raster.edge(fillCurrent, p); fillCurrent = p; return; }
    const last = points[points.length - 1]!, dx = f(p.x - last.x), dy = f(p.y - last.y);
    if (f(f(dx * dx) + f(dy * dy)) <= f(0.000000000001)) return;
    if (points.length >= 512) { raster.status = 1; return; }
    points.push(p);
  };
  const end = (closed: boolean): void => {
    if (mode === 0) raster.edge(fillCurrent, fillStart);
    else {
      let use = points;
      if (closed && points.length >= 2) {
        const a = points[0]!, b = points[points.length - 1]!, dx = f(a.x - b.x), dy = f(a.y - b.y);
        if (f(f(dx * dx) + f(dy * dy)) <= f(0.000000000001)) use = points.slice(0, points.length - 1);
      }
      raster.stroke(use, closed && use.length >= 2, f(width * 0.5), cap, join, miter, nscvResourceExtremum(f(0.01), tolerance, true, rules));
    }
    active = false;
  };
  if (mode === 0 || width > 0) for (let i = 0; i < count && raster.status === 0; i++) {
    const at = 96 + i * 28, verb = w.getUint32(at, true);
    if (verb === 0) {
      if (active) end(false);
      current = transform(at + 4); start = current; has = true;
    } else if (verb === 1) {
      const next = transform(at + 4);
      if (!has) { current = next; start = next; has = true; continue; }
      if (!active) begin(current);
      point(next); current = next;
    } else if (verb === 2 || verb === 3) {
      if (!has) continue;
      const b = transform(at + 4), c = transform(at + 12), d = verb === 3 ? transform(at + 20) : null;
      if (!active) begin(current);
      const segments = nscvRasterSegments(current, b, c, d, tolerance, limit, rules);
      for (let n = 1; n <= segments && raster.status === 0; n++) point(nscvRasterCurve(current, b, c, d, f(n / segments)));
      current = d === null ? c : d;
    } else { if (active) end(true); if (has) current = start; }
  }
  if (active && raster.status === 0) end(false);
  const output = new Uint8Array(32 + raster.edges.length * 20), out = new DataView(output.buffer);
  out.setUint32(0, raster.status, true); out.setUint32(4, raster.edges.length, true);
  out.setFloat32(8, raster.minX, true); out.setFloat32(12, raster.minY, true); out.setFloat32(16, raster.maxX, true); out.setFloat32(20, raster.maxY, true);
  for (let i = 0; i < raster.edges.length; i++) {
    const e = raster.edges[i]!, at = 32 + i * 20;
    out.setFloat32(at, e.x0, true); out.setFloat32(at + 4, e.y0, true); out.setFloat32(at + 8, e.x1, true); out.setFloat32(at + 12, e.y1, true); out.setFloat32(at + 16, e.dir, true);
  }
  return output;
}

function nscvRasterSweep(request: Uint8Array, w: DataView, mode: number, rules: number): Uint8Array {
  if (request.length < 80) throw new Error("truncated vector sweep facts");
  const count = w.getUint32(4, true), capacity = w.getUint32(8, true), rule = w.getUint32(12, true);
  if (count > 18560 || capacity > 18560 || rule > 1 || request.length !== 80 + count * 20) throw new Error("invalid vector sweep bounds");
  for (let at = 56; at < 80; at += 4) if (w.getUint32(at, true) !== 0) throw new Error("invalid vector sweep tail");
  const f = Math.fround;
  const floor = (v: number): number => Number.isFinite(v) ? Math.floor(v) : 0;
  const ceil = (v: number): number => Number.isFinite(v) ? Math.ceil(v) : 0;
  let x0 = Math.max(w.getInt32(32, true), floor(w.getFloat32(16, true))), y0 = Math.max(w.getInt32(36, true), floor(w.getFloat32(20, true)));
  let x1 = Math.min(w.getInt32(40, true), ceil(w.getFloat32(24, true))), y1 = Math.min(w.getInt32(44, true), ceil(w.getFloat32(28, true)));
  if (count === 0 || x1 <= x0 || y1 <= y0) { x0 = 0; x1 = 0; y0 = 0; y1 = 0; }
  if (x0 < -2147483648 || x1 > 2147483647 || y0 < -2147483648 || y1 > 2147483647) throw new Error("vector sweep coordinates exceed wire range");
  const width = x1 - x0, first = w.getInt32(48, true), rows = w.getUint32(52, true);
  if (mode === 2 && (first !== 0 || rows !== 0) || mode === 3 && (rows === 0 || rows > 16 || first < y0 || first > y1 || rows > y1 - first)) throw new Error("invalid vector coverage band");
  const output = new Uint8Array(32 + (mode === 3 && width <= 8192 ? width * rows * 4 : 0)), out = new DataView(output.buffer);
  out.setInt32(8, x0, true); out.setInt32(12, y0, true); out.setInt32(16, x1, true); out.setInt32(20, y1, true);
  if (width > 8192) { out.setUint32(0, 2, true); return output; }
  if (mode === 2) return output;
  for (let n = 0; n < rows; n++) {
    const row: number[] = [];
    for (let i = 0; i < width; i++) row.push(0);
    for (let sub = 0; sub < 4; sub++) {
      const sy = f(f(first + n) + f(f(sub + 0.5) / 4)), crossings: NscRasterPoint[] = [];
      for (let i = 0; i < count; i++) {
        const at = 80 + i * 20, ax = w.getFloat32(at, true), ay = w.getFloat32(at + 4, true), bx = w.getFloat32(at + 8, true), by = w.getFloat32(at + 12, true);
        if (!(sy >= nscvResourceExtremum(ay, by, false, rules) && sy < nscvResourceExtremum(ay, by, true, rules))) continue;
        if (crossings.length >= capacity) { out.setUint32(0, 1, true); return output.slice(0, 32 + n * width * 4); }
        const value = { x: f(ax + f(f(f(sy - ay) * f(bx - ax)) / f(by - ay))), y: w.getFloat32(at + 16, true) };
        crossings.push(value);
        let j = crossings.length - 1;
        while (j > 0 && crossings[j - 1]!.x > value.x) { crossings[j] = crossings[j - 1]!; j--; }
        crossings[j] = value;
      }
      let winding = 0, parity = false, inside = false, start = 0;
      for (const cross of crossings) {
        const was = inside;
        if (rule === 0) { winding = f(winding + cross.y); inside = winding !== 0; }
        else { parity = !parity; inside = parity; }
        if (!was && inside) start = cross.x;
        else if (was && !inside) {
          const a = nscvResourceExtremum(nscvResourceExtremum(f(start - f(x0)), 0, true, rules), width, false, rules);
          const b = nscvResourceExtremum(nscvResourceExtremum(f(cross.x - f(x0)), 0, true, rules), width, false, rules);
          if (b <= a) continue;
          for (let px = Math.floor(a); px < width; px++) {
            const left = nscvResourceExtremum(a, f(px), true, rules), right = nscvResourceExtremum(b, f(px + 1), false, rules);
            if (right <= left) break;
            row[px] = f(row[px]! + f(f(right - left) * 0.25));
          }
        }
      }
    }
    for (let i = 0; i < width; i++) out.setFloat32(32 + (n * width + i) * 4, row[i]! > f(0.0009) ? nscvResourceExtremum(1, row[i]!, false, rules) : 0, true);
    out.setUint32(4, n + 1, true);
  }
  return output;
}
