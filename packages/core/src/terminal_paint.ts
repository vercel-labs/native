/** Complete terminal canvas programs over copied resolved viewport facts.
 * Native retains measurement, display-list storage and drawing capabilities. */
interface NscTerminalRect { x: number; y: number; width: number; height: number }
interface NscTerminalColor { r: number; g: number; b: number; a: number }
interface NscTerminalCell { cp: number; wide: number; underline: boolean; fg: NscTerminalColor; bg: NscTerminalColor | null; cluster: Uint8Array }
interface NscTerminalRow { cells: NscTerminalCell[]; selection: number[] }
interface NscTerminalCommand { op: number; low: number; high: number; rect: NscTerminalRect; color: NscTerminalColor; size: number; text: number; length: number; path: number; paths: number; width: number; height: number }
interface NscTerminalPath { verb: number; points: number[] }
const nscTerminalSides: number[][] = [
  [9472, 0, 0, 1, 1],
  [9548, 0, 0, 1, 1],
  [9473, 0, 0, 2, 2],
  [9549, 0, 0, 2, 2],
  [9474, 1, 1, 0, 0],
  [9550, 1, 1, 0, 0],
  [9475, 2, 2, 0, 0],
  [9551, 2, 2, 0, 0],
  [9476, 0, 0, 1, 1],
  [9480, 0, 0, 1, 1],
  [9477, 0, 0, 2, 2],
  [9481, 0, 0, 2, 2],
  [9478, 1, 1, 0, 0],
  [9482, 1, 1, 0, 0],
  [9479, 2, 2, 0, 0],
  [9483, 2, 2, 0, 0],
  [9484, 0, 1, 0, 1],
  [9485, 0, 1, 0, 2],
  [9486, 0, 2, 0, 1],
  [9487, 0, 2, 0, 2],
  [9488, 0, 1, 1, 0],
  [9489, 0, 1, 2, 0],
  [9490, 0, 2, 1, 0],
  [9491, 0, 2, 2, 0],
  [9492, 1, 0, 0, 1],
  [9493, 1, 0, 0, 2],
  [9494, 2, 0, 0, 1],
  [9495, 2, 0, 0, 2],
  [9496, 1, 0, 1, 0],
  [9497, 1, 0, 2, 0],
  [9498, 2, 0, 1, 0],
  [9499, 2, 0, 2, 0],
  [9500, 1, 1, 0, 1],
  [9501, 1, 1, 0, 2],
  [9502, 2, 1, 0, 1],
  [9503, 1, 2, 0, 1],
  [9504, 2, 2, 0, 1],
  [9505, 2, 1, 0, 2],
  [9506, 1, 2, 0, 2],
  [9507, 2, 2, 0, 2],
  [9508, 1, 1, 1, 0],
  [9509, 1, 1, 2, 0],
  [9510, 2, 1, 1, 0],
  [9511, 1, 2, 1, 0],
  [9512, 2, 2, 1, 0],
  [9513, 2, 1, 2, 0],
  [9514, 1, 2, 2, 0],
  [9515, 2, 2, 2, 0],
  [9516, 0, 1, 1, 1],
  [9517, 0, 1, 2, 1],
  [9518, 0, 1, 1, 2],
  [9519, 0, 1, 2, 2],
  [9520, 0, 2, 1, 1],
  [9521, 0, 2, 2, 1],
  [9522, 0, 2, 1, 2],
  [9523, 0, 2, 2, 2],
  [9524, 1, 0, 1, 1],
  [9525, 1, 0, 2, 1],
  [9526, 1, 0, 1, 2],
  [9527, 1, 0, 2, 2],
  [9528, 2, 0, 1, 1],
  [9529, 2, 0, 2, 1],
  [9530, 2, 0, 1, 2],
  [9531, 2, 0, 2, 2],
  [9532, 1, 1, 1, 1],
  [9533, 1, 1, 2, 1],
  [9534, 1, 1, 1, 2],
  [9535, 1, 1, 2, 2],
  [9536, 2, 1, 1, 1],
  [9537, 1, 2, 1, 1],
  [9538, 2, 2, 1, 1],
  [9539, 2, 1, 2, 1],
  [9540, 2, 1, 1, 2],
  [9541, 1, 2, 2, 1],
  [9542, 1, 2, 1, 2],
  [9543, 2, 1, 2, 2],
  [9544, 1, 2, 2, 2],
  [9545, 2, 2, 2, 1],
  [9546, 2, 2, 1, 2],
  [9547, 2, 2, 2, 2],
  [9552, 0, 0, 3, 3],
  [9553, 3, 3, 0, 0],
  [9554, 0, 1, 0, 3],
  [9555, 0, 3, 0, 1],
  [9556, 0, 3, 0, 3],
  [9557, 0, 1, 3, 0],
  [9558, 0, 3, 1, 0],
  [9559, 0, 3, 3, 0],
  [9560, 1, 0, 0, 3],
  [9561, 3, 0, 0, 1],
  [9562, 3, 0, 0, 3],
  [9563, 1, 0, 3, 0],
  [9564, 3, 0, 1, 0],
  [9565, 3, 0, 3, 0],
  [9566, 1, 1, 0, 3],
  [9567, 3, 3, 0, 1],
  [9568, 3, 3, 0, 3],
  [9569, 1, 1, 3, 0],
  [9570, 3, 3, 1, 0],
  [9571, 3, 3, 3, 0],
  [9572, 0, 1, 3, 3],
  [9573, 0, 3, 1, 1],
  [9574, 0, 3, 3, 3],
  [9575, 1, 0, 3, 3],
  [9576, 3, 0, 1, 1],
  [9577, 3, 0, 3, 3],
  [9578, 1, 1, 3, 3],
  [9579, 3, 3, 1, 1],
  [9580, 3, 3, 3, 3],
  [9588, 0, 0, 1, 0],
  [9589, 1, 0, 0, 0],
  [9590, 0, 0, 0, 1],
  [9591, 0, 1, 0, 0],
  [9592, 0, 0, 2, 0],
  [9593, 2, 0, 0, 0],
  [9594, 0, 0, 0, 2],
  [9595, 0, 2, 0, 0],
  [9596, 0, 0, 1, 2],
  [9597, 1, 2, 0, 0],
  [9598, 0, 0, 2, 1],
  [9599, 2, 1, 0, 0],
];
const nscTerminalZeroRect: NscTerminalRect = { x: 0, y: 0, width: 0, height: 0 };
const nscTerminalZeroColor: NscTerminalColor = { r: 0, g: 0, b: 0, a: 0 };
function nsctBox(cp: number): boolean { return cp >= 0x2500 && cp <= 0x259f; }
function nsctMerge(cp: number): boolean { return cp === 0x2500 || cp === 0x2501 || cp === 0x2550 || (cp >= 0x2580 && cp <= 0x2588) || (cp >= 0x2591 && cp <= 0x2594); }
function nsctSides(cp: number): number[] | null { for (const record of nscTerminalSides) if (record[0] === cp) return record.slice(1); return null; }
function nsctCorner(cp: number): number { return cp === 0x2554 ? 3 : cp === 0x2557 ? 1 : cp === 0x255a ? 2 : cp === 0x255d ? 0 : -1; }
function nsctCost(cp: number): number {
  if (nsctCorner(cp) >= 0) return 4;
  const s = nsctSides(cp);
  if (s !== null) {
    if (s[0] === 0 && s[1] === 0 && s[2] === s[3] && s[2] !== 0) return s[2] === 3 ? 2 : 1;
    if (s[2] === 0 && s[3] === 0 && s[0] === s[1] && s[0] !== 0) return s[0] === 3 ? 2 : 1;
    let count = 0; for (const w of s) count += w === 3 ? 2 : w === 0 ? 0 : 1; return count;
  }
  return (cp >= 0x256d && cp <= 0x2570) || cp === 0x2573 ? 2 : cp >= 0x2596 && cp <= 0x259f ? 3 : 1;
}
function nsctColorEqual(a: NscTerminalColor, b: NscTerminalColor): boolean { return a.r === b.r && a.g === b.g && a.b === b.b && a.a === b.a; }
function nsctRect(x: number, y: number, width: number, height: number): NscTerminalRect { return { x, y, width, height }; }
function nsctReadColor(w: DataView, at: number): NscTerminalColor { return { r: w.getFloat32(at, true), g: w.getFloat32(at + 4, true), b: w.getFloat32(at + 8, true), a: w.getFloat32(at + 12, true) }; }
function nsctRound(value: number): number { return value === 0 || !Number.isFinite(value) ? value : value < 0 ? -Math.floor(-value + 0.5) : Math.floor(value + 0.5); }

class NscTerminalPaint {
  commands: NscTerminalCommand[] = [];
  paths: NscTerminalPath[] = [];
  text: number[] = [];
  error = 0;
  low: number; high: number; keyed: boolean; rules: number;
  initialCommands: number; commandCapacity: number; initialPaths: number; pathCapacity: number; initialText: number; textCapacity: number;
  constructor(low: number, high: number, rules: number, initialCommands: number, commandCapacity: number, initialPaths: number, pathCapacity: number, initialText: number, textCapacity: number) {
    this.low = (low * 16777216) >>> 0; this.high = ((high << 24) | (low >>> 8)) >>> 0; this.keyed = low !== 0 || high !== 0;
    this.rules = rules; this.initialCommands = initialCommands; this.commandCapacity = commandCapacity;
    this.initialPaths = initialPaths; this.pathCapacity = pathCapacity; this.initialText = initialText; this.textCapacity = textCapacity;
  }
  min(a: number, b: number): number { return nscvResourceExtremum(a, b, false, this.rules); }
  max(a: number, b: number): number { return nscvResourceExtremum(a, b, true, this.rules); }
  emit(op: number, offset: number, rect: NscTerminalRect, color: NscTerminalColor, size = 0, text = 0, length = 0, path = 0, paths = 0, width = 0, height = 0): boolean {
    if (this.error !== 0) return false;
    if (this.initialCommands + this.commands.length >= this.commandCapacity) { this.error = 1; return false; }
    const sum = this.low + offset, low = this.keyed ? sum >>> 0 : 0, high = this.keyed ? (this.high + Math.floor(sum / 4294967296)) >>> 0 : 0;
    this.commands.push({ op, low, high, rect, color, size, text, length, path, paths, width, height }); return true;
  }
  fill(id: number, rect: NscTerminalRect, color: NscTerminalColor): boolean { return this.emit(0, id, rect, color); }
  stroke(id: number, rect: NscTerminalRect, color: NscTerminalColor, size: number): boolean { return this.emit(1, id, rect, color, size); }
  line(id: number, from: NscTerminalRect, color: NscTerminalColor, size: number): boolean { return this.emit(4, id, from, color, size); }
  segment(id: number, weight: number, t: number, x: number, y: number, length: number, horizontal: boolean, color: NscTerminalColor): number {
    const f = Math.fround;
    if (weight === 0) return id;
    if (weight === 3) {
      for (const offset of [-t, t]) {
        const rect = horizontal ? nsctRect(x, f(f(y + offset) - f(t / 2)), length, t) : nsctRect(f(f(x + offset) - f(t / 2)), y, t, length);
        if (!this.fill(id, rect, color)) return id; id++;
      }
    } else {
      const w = weight === 2 ? f(t * 2) : t;
      if (!this.fill(id, horizontal ? nsctRect(x, f(y - f(w / 2)), length, w) : nsctRect(f(x - f(w / 2)), y, w, length), color)) return id;
      id++;
    }
    return id;
  }
  fraction(id: number, rect: NscTerminalRect, color: NscTerminalColor, opacity: number, side: number, fraction: number): void {
    const f = Math.fround, shaded = { r: color.r, g: color.g, b: color.b, a: f(color.a * opacity) };
    const r = side === 0 ? nsctRect(rect.x, rect.y, rect.width, f(rect.height * fraction)) : side === 1 ? nsctRect(rect.x, f(rect.y + f(rect.height * f(1 - fraction))), rect.width, f(rect.height * fraction)) : side === 2 ? nsctRect(rect.x, rect.y, f(rect.width * fraction), rect.height) : nsctRect(f(rect.x + f(rect.width * f(1 - fraction))), rect.y, f(rect.width * fraction), rect.height);
    this.fill(id, r, shaded);
  }
  box(id: number, rect: NscTerminalRect, cp: number, color: NscTerminalColor, thickness: number): void {
    const f = Math.fround, t = this.max(1, thickness), cx = f(rect.x + f(rect.width / 2)), cy = f(rect.y + f(rect.height / 2));
    const corner = nsctCorner(cp);
    if (corner >= 0) {
      const down = (corner & 1) !== 0, right = (corner & 2) !== 0;
      const ox = right ? f(cx - t) : f(cx + t), ix = right ? f(cx + t) : f(cx - t), oy = down ? f(cy - t) : f(cy + t), iy = down ? f(cy + t) : f(cy - t);
      for (const pair of [[oy, ox], [iy, ix]]) {
        const x0 = right ? f(pair[1]! - f(t / 2)) : rect.x, x1 = right ? f(rect.x + rect.width) : f(pair[1]! + f(t / 2));
        if (!this.fill(id++, nsctRect(x0, f(pair[0]! - f(t / 2)), f(x1 - x0), t), color)) return;
      }
      for (const pair of [[ox, oy], [ix, iy]]) {
        const y0 = down ? f(pair[1]! - f(t / 2)) : rect.y, y1 = down ? f(rect.y + rect.height) : f(pair[1]! + f(t / 2));
        if (!this.fill(id++, nsctRect(f(pair[0]! - f(t / 2)), y0, t, f(y1 - y0)), color)) return;
      }
      return;
    }
    const s = nsctSides(cp);
    if (s !== null) {
      if (s[0] === 0 && s[1] === 0 && s[2] === s[3] && s[2] !== 0) { this.segment(id, s[2]!, t, rect.x, cy, rect.width, true, color); return; }
      if (s[2] === 0 && s[3] === 0 && s[0] === s[1] && s[0] !== 0) { this.segment(id, s[0]!, t, cx, rect.y, rect.height, false, color); return; }
      const half = (weight: number): number => weight === 0 ? 0 : weight === 1 ? f(t / 2) : weight === 2 ? t : f(t * 1.5);
      if (s[2] !== 0) id = this.segment(id, s[2]!, t, rect.x, cy, f(f(cx - rect.x) + half(s[2]!)), true, color);
      if (s[3] !== 0) id = this.segment(id, s[3]!, t, f(cx - half(s[3]!)), cy, f(f(f(rect.x + rect.width) - cx) + half(s[3]!)), true, color);
      if (s[0] !== 0) id = this.segment(id, s[0]!, t, cx, rect.y, f(f(cy - rect.y) + half(s[0]!)), false, color);
      if (s[1] !== 0) this.segment(id, s[1]!, t, cx, f(cy - half(s[1]!)), f(f(f(rect.y + rect.height) - cy) + half(s[1]!)), false, color);
      return;
    }
    if (cp >= 0x256d && cp <= 0x2570) {
      if (this.initialPaths + this.paths.length + 3 > this.pathCapacity) { this.error = 2; return; }
      const radius = f(this.min(rect.width, rect.height) / 2), down = cp <= 0x256e, right = cp === 0x256d || cp === 0x2570;
      const start = down ? f(rect.y + rect.height) : rect.y, bendY = down ? f(cy + f(radius / 2)) : f(cy - f(radius / 2)), bendX = right ? f(cx + f(radius / 2)) : f(cx - f(radius / 2));
      const at = this.paths.length;
      this.paths.push({ verb: 0, points: [cx, start, 0, 0, 0, 0] }, { verb: 1, points: [cx, bendY, 0, 0, 0, 0] }, { verb: 2, points: [cx, cy, bendX, cy, 0, 0] });
      if (!this.emit(5, id, nscTerminalZeroRect, color, t, 0, 0, at, 3)) return;
      const run = right ? nsctRect(bendX, f(cy - f(t / 2)), f(f(rect.x + rect.width) - bendX), t) : nsctRect(rect.x, f(cy - f(t / 2)), f(f(cx - f(radius / 2)) - rect.x), t);
      this.fill(id + 1, run, color); return;
    }
    if (cp >= 0x2571 && cp <= 0x2573) {
      if (cp !== 0x2572 && !this.line(id++, nsctRect(rect.x, f(rect.y + rect.height), f(rect.x + rect.width), rect.y), color, t)) return;
      if (cp !== 0x2571) this.line(id, nsctRect(rect.x, rect.y, f(rect.x + rect.width), f(rect.y + rect.height)), color, t);
      return;
    }
    if (cp === 0x2580) this.fraction(id, rect, color, 1, 0, 0.5);
    else if (cp >= 0x2581 && cp <= 0x2588) this.fraction(id, rect, color, 1, 1, f((cp - 0x2580) / 8));
    else if (cp >= 0x2589 && cp <= 0x258f) this.fraction(id, rect, color, 1, 2, f((0x2590 - cp) / 8));
    else if (cp === 0x2590) this.fraction(id, rect, color, 1, 3, 0.5);
    else if (cp >= 0x2591 && cp <= 0x2593) this.fraction(id, rect, color, f((cp - 0x2590) / 4), 1, 1);
    else if (cp === 0x2594) this.fraction(id, rect, color, 1, 0, 0.125);
    else if (cp === 0x2595) this.fraction(id, rect, color, 1, 3, 0.125);
    else if (cp >= 0x2596 && cp <= 0x259f) {
      const quads = [4, 8, 1, 13, 9, 7, 11, 2, 6, 14][cp - 0x2596]!, hw = f(rect.width / 2), hh = f(rect.height / 2);
      for (let i = 0; i < 4; i++) if ((quads & (1 << i)) !== 0) {
        if (!this.fill(id++, nsctRect(i % 2 === 0 ? rect.x : f(rect.x + hw), i < 2 ? rect.y : f(rect.y + hh), hw, hh), color)) return;
      }
    }
  }
  result(painted: number): Uint8Array {
    const out = new Uint8Array(32 + this.commands.length * 96 + this.paths.length * 28 + this.text.length), w = new DataView(out.buffer);
    w.setUint32(0, 1, true); w.setUint32(4, this.commands.length, true); w.setUint32(8, this.paths.length, true); w.setUint32(12, this.text.length, true); w.setUint32(16, painted, true); w.setUint32(20, this.error, true);
    for (let i = 0; i < this.commands.length; i++) {
      const c = this.commands[i]!, at = 32 + i * 96;
      w.setUint32(at, c.op, true); w.setUint32(at + 4, c.low, true); w.setUint32(at + 8, c.high, true);
      const values = [c.rect.x, c.rect.y, c.rect.width, c.rect.height, c.color.r, c.color.g, c.color.b, c.color.a, c.size];
      for (let j = 0; j < values.length; j++) w.setFloat32(at + 16 + j * 4, values[j]!, true);
      for (const [offset, value] of [[52, c.text], [56, c.length], [60, c.path], [64, c.paths]]) w.setUint32(at + offset!, value!, true);
      w.setFloat32(at + 68, c.width, true); w.setFloat32(at + 72, c.height, true);
    }
    const base = 32 + this.commands.length * 96;
    for (let i = 0; i < this.paths.length; i++) { const p = this.paths[i]!, at = base + i * 28; w.setUint32(at, p.verb, true); for (let j = 0; j < 6; j++) w.setFloat32(at + 4 + j * 4, p.points[j]!, true); }
    for (let i = 0; i < this.text.length; i++) out[base + this.paths.length * 28 + i] = this.text[i]!;
    return out;
  }
}
function nsctRowCost(row: NscTerminalRow): number {
  let cost = 1;
  for (let i = 0; i < row.cells.length; i++) {
    const cell = row.cells[i]!;
    if (cell.wide === 2) continue;
    if (cell.bg !== null) cost++;
    if (cell.cp === 0) continue;
    if (nsctBox(cell.cp)) {
      if (nsctMerge(cell.cp)) {
        let span = 1;
        while (i + span < row.cells.length) {
          const next = row.cells[i + span]!;
          if (next.cp !== cell.cp || !nsctColorEqual(next.fg, cell.fg) || next.underline !== cell.underline) break;
          if (next.bg !== null) cost++; span++;
        }
        cost += 3; i += span - 1;
      } else cost += nsctCost(cell.cp) + 1;
    } else cost += 2;
  }
  return cost;
}
function nsctGlyphs(bytes: Uint8Array, seen: Set<number>): number {
  let added = 0;
  for (let i = 0; i < bytes.length;) {
    const first = bytes[i++]!;
    let cp = first, need = 0, minimum = 0;
    if (first >= 0xc2 && first <= 0xdf) { cp = first & 31; need = 1; minimum = 128; }
    else if (first >= 0xe0 && first <= 0xef) { cp = first & 15; need = 2; minimum = 2048; }
    else if (first >= 0xf0 && first <= 0xf4) { cp = first & 7; need = 3; minimum = 65536; }
    else if (first >= 128) throw new Error("invalid terminal cluster UTF-8");
    for (let j = 0; j < need; j++) { if (i >= bytes.length || (bytes[i]! & 192) !== 128) throw new Error("invalid terminal cluster UTF-8"); cp = cp * 64 + (bytes[i++]! & 63); }
    if (cp < minimum || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) throw new Error("invalid terminal cluster UTF-8");
    if (!seen.has(cp)) { seen.add(cp); added++; }
  }
  return added;
}
function nscvTerminalPaint(request: Uint8Array): Uint8Array {
  if (request.length < 4 || request[0] !== 78 || request[1] !== 1 || request[2]! > 2 || request[3]! > 15) throw new Error("invalid terminal paint header");
  const mode = request[2]!, rules = request[3]!, w = new DataView(request.buffer, request.byteOffset, request.byteLength), f = Math.fround;
  if (mode === 1) {
    if (request.length !== 16 || w.getUint32(12, true) !== 0) throw new Error("invalid terminal metric facts");
    const size = w.getFloat32(4, true), measured = w.getFloat32(8, true), out = new Uint8Array(16), o = new DataView(out.buffer);
    o.setUint32(0, 1, true); o.setFloat32(4, measured > 0 ? f(measured / 16) : nsctRound(f(size * f(0.6))), true);
    o.setFloat32(8, nsctRound(f(size * f(1.4))), true); o.setFloat32(12, size, true); return out;
  }
  if (mode === 2) {
    if (request.length !== 16 || w.getUint32(12, true) !== 0) throw new Error("invalid terminal grid facts");
    let cols = Math.max(2, Math.min(320, w.getUint32(4, true))), rows = Math.max(2, Math.min(96, w.getUint32(8, true)));
    if (cols * rows > 7168) rows = Math.max(2, Math.floor(7168 / cols));
    if (cols * rows > 7168) cols = Math.max(2, Math.floor(7168 / rows));
    const out = new Uint8Array(12), o = new DataView(out.buffer); o.setUint32(0, 1, true); o.setUint32(4, cols, true); o.setUint32(8, rows, true); return out;
  }
  if (request.length < 272) throw new Error("truncated terminal viewport facts");
  const flags = w.getUint32(4, true), rowCount = w.getUint32(8, true);
  if (flags > 31 || w.getUint32(224, true) > 2) throw new Error("invalid terminal viewport flags");
  for (let at = 248; at < 272; at += 4) if (w.getUint32(at, true) !== 0) throw new Error("invalid terminal viewport tail");
  const initialCommands = w.getUint32(12, true), commandCapacity = w.getUint32(16, true), budget = w.getUint32(20, true);
  const initialText = w.getUint32(24, true), textCapacity = w.getUint32(28, true), viewText = w.getUint32(32, true), textReserve = w.getUint32(36, true);
  const initialPaths = w.getUint32(40, true), pathCapacity = w.getUint32(44, true), viewPaths = w.getUint32(48, true), pathReserve = w.getUint32(52, true), glyphBudget = Math.min(w.getUint32(56, true), 8192);
  if (initialCommands > commandCapacity || initialText > textCapacity || initialPaths > pathCapacity || textCapacity !== 32768 || pathCapacity !== 2048 || w.getUint32(60, true) !== 0) throw new Error("invalid terminal storage facts");
  const rows: NscTerminalRow[] = []; let at = 272;
  for (let r = 0; r < rowCount; r++) {
    if (at + 16 > request.length) throw new Error("truncated terminal row facts");
    const count = w.getUint32(at, true), selected = w.getUint32(at + 4, true), first = w.getUint32(at + 8, true), last = w.getUint32(at + 12, true); at += 16;
    if (selected > 1 || first > 65535 || last > 65535 || (selected === 0 && (first !== 0 || last !== 0)) || (selected !== 0 && last < first)) throw new Error("invalid terminal selection facts");
    const cells: NscTerminalCell[] = [];
    for (let c = 0; c < count; c++) {
      if (at + 48 > request.length) throw new Error("truncated terminal cell facts");
      const cp = w.getUint32(at, true), bits = w.getUint32(at + 4, true), length = w.getUint32(at + 8, true);
      if (cp > 0x1fffff || bits > 15 || (bits & 3) > 2 || w.getUint32(at + 12, true) !== 0 || at + 48 + length > request.length) throw new Error("invalid terminal cell facts");
      if ((bits & 8) === 0) for (let j = 32; j < 48; j += 4) if (w.getUint32(at + j, true) !== 0) throw new Error("invalid absent terminal background");
      cells.push({ cp, wide: bits & 3, underline: (bits & 4) !== 0, fg: nsctReadColor(w, at + 16), bg: (bits & 8) !== 0 ? nsctReadColor(w, at + 32) : null, cluster: request.slice(at + 48, at + 48 + length) }); at += 48 + length;
    }
    rows.push({ cells, selection: selected === 0 ? [] : [first, last] });
  }
  if (at !== request.length) throw new Error("invalid terminal viewport length");
  const p = new NscTerminalPaint(w.getUint32(64, true), w.getUint32(68, true), rules, initialCommands, commandCapacity, initialPaths, pathCapacity, initialText, textCapacity);
  if (budget > 0 && initialCommands + 8 > budget) return p.result(0);
  const frame = nscvResourceRect(w, 72), background = (flags & 16) !== 0 ? nscvResourceRect(w, 88) : frame;
  const size = w.getFloat32(104, true), cellW = w.getFloat32(108, true), cellH = w.getFloat32(112, true);
  if (w.getUint32(116, true) !== 0) throw new Error("invalid terminal metric tail");
  const gridBg = nsctReadColor(w, 120), gridFg = nsctReadColor(w, 136), cursorColor = nsctReadColor(w, 152), selectionColor = nsctReadColor(w, 168), focusColor = nsctReadColor(w, 184), mutedColor = nsctReadColor(w, 200);
  if (!p.fill(0x610000, background, gridBg) || !p.emit(2, 0x610001, frame, nscTerminalZeroColor)) return p.result(0);
  let textTotal = viewText, pathTotal = viewPaths, glyphs = 0, painted = 0;
  const textCeiling = Math.max(0, 32768 - textReserve), pathCeiling = Math.max(0, pathCapacity - pathReserve), seen = new Set<number>();
  const thickness = p.max(1, nsctRound(f(size / 8)));
  for (let rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    const row = rows[rowIndex]!;
    if (budget > 0 && initialCommands + p.commands.length + nsctRowCost(row) + 8 > budget) break;
    let rowText = 0, rowPaths = 0;
    for (const cell of row.cells) if (cell.wide !== 2 && cell.cp !== 0) {
      if (!nsctBox(cell.cp)) rowText += cell.cluster.length;
      if (cell.cp >= 0x256d && cell.cp <= 0x2570) rowPaths += 3;
    }
    if (rowText > 0 && textTotal + rowText > textCeiling) break;
    if (rowPaths > 0 && pathTotal + rowPaths > pathCeiling) break;
    if (glyphBudget > 0) {
      for (const cell of row.cells) if (cell.wide !== 2 && cell.cp !== 0 && !nsctBox(cell.cp)) glyphs += nsctGlyphs(cell.cluster, seen) * 4;
      if (glyphs > glyphBudget) break;
    }
    const commandStart = p.commands.length, pathStart = p.paths.length, textStart = p.text.length;
    const y = f(frame.y + f(f(rowIndex) * cellH)), rowId = rowIndex * 65536;
    if (y >= f(frame.y + frame.height)) break;
    let runStart = 0, runColor: NscTerminalColor | null = null;
    for (let x = 0; x <= row.cells.length; x++) {
      const bg = x < row.cells.length ? row.cells[x]!.bg : null;
      if (runColor !== null) {
        if (bg === null || !nsctColorEqual(bg, runColor)) {
          if (!p.fill(rowId + 1 + runStart, nsctRect(f(frame.x + f(f(runStart) * cellW)), y, f(f(x - runStart) * cellW), cellH), runColor)) return p.result(painted);
          runColor = bg; runStart = x;
        }
      } else if (bg !== null) { runColor = bg; runStart = x; }
    }
    if (row.selection.length !== 0) {
      if (!p.fill(rowId + 0x4000, nsctRect(f(frame.x + f(f(row.selection[0]!) * cellW)), y, f(f(row.selection[1]! - row.selection[0]! + 1) * cellW), cellH), { r: selectionColor.r, g: selectionColor.g, b: selectionColor.b, a: f(0.3) })) return p.result(painted);
    }
    let runLength = 0, runX = 0, runFg = gridFg, runUnderline = false, text: number[] = [], breakAfterCluster = false, torn = false;
    for (let x = 0; x <= row.cells.length; x++) {
      let cp = 0, fg = gridFg, underline = false, skip = false, boxCp = 0, cellBytes = 0, multi = false;
      if (x < row.cells.length) {
        const cell = row.cells[x]!; cp = cell.cp; fg = cell.fg; underline = cell.underline; skip = cell.wide === 2;
        if (cp !== 0 && !skip && nsctBox(cp)) { boxCp = cp; cp = 0; }
        if (cp !== 0 && !skip) { cellBytes = cell.cluster.length; const primary = cp < 128 ? 1 : cp < 2048 ? 2 : cp < 65536 ? 3 : cp <= 0x10ffff ? 4 : 1; multi = cellBytes > primary; }
      }
      const breaks = x === row.cells.length || skip || cp === 0 || !nsctColorEqual(fg, runFg) || underline !== runUnderline || multi || breakAfterCluster || text.length + cellBytes > 32768;
      if (breaks && runLength > 0 && text.length > 0) {
        if (initialText + p.text.length + text.length > textCapacity) { torn = true; break; }
        const start = p.text.length; for (const b of text) p.text.push(b);
        const baseline = f(f(y + f(f(cellH - f(size * 1.25)) * 0.5)) + size);
        if (!p.emit(3, rowId + 0x8000 + runX, nsctRect(f(frame.x + f(f(runX) * cellW)), baseline, 0, 0), runFg, size, start, text.length, 0, 0, cellW, cellH)) return p.result(painted);
        if (runUnderline && !p.fill(rowId + 0xc000 + runX, nsctRect(f(frame.x + f(f(runX) * cellW)), f(f(y + cellH) - 2), f(f(runLength) * cellW), 1), runFg)) return p.result(painted);
        text = []; runLength = 0;
      }
      if (x >= row.cells.length || skip) continue;
      if (boxCp !== 0) {
        let span = 1;
        if (nsctMerge(boxCp)) while (x + span < row.cells.length) { const next = row.cells[x + span]!; if (next.cp !== boxCp || !nsctColorEqual(next.fg, fg) || next.underline !== underline) break; span++; }
        const rect = nsctRect(f(frame.x + f(f(x) * cellW)), y, f(f(span) * cellW), cellH);
        p.box(rowId + 0x6000 + x * 8, rect, boxCp, fg, thickness);
        if (p.error !== 0) { p.error = 0; torn = true; break; }
        if (underline && !p.fill(rowId + 0xd000 + x, nsctRect(rect.x, f(f(y + cellH) - 2), rect.width, 1), fg)) { p.error = 0; torn = true; break; }
        x += span - 1; continue;
      }
      if (cp === 0) continue;
      if (runLength === 0) { runX = x; runFg = fg; runUnderline = underline; }
      const cell = row.cells[x]!, take = Math.min(cell.cluster.length, 32768 - text.length);
      for (let i = 0; i < take; i++) text.push(cell.cluster[i]!);
      runLength += cell.wide === 1 ? 2 : 1; breakAfterCluster = multi;
    }
    if (torn) { p.commands.length = commandStart; p.paths.length = pathStart; p.text.length = textStart; break; }
    textTotal += p.text.length - textStart; pathTotal += p.paths.length - pathStart; painted = rowIndex + 1;
  }
  if ((flags & 4) !== 0 && w.getUint32(220, true) < painted) {
    const x = f(frame.x + f(f(w.getUint32(216, true)) * cellW)), y = f(frame.y + f(f(w.getUint32(220, true)) * cellH)), shape = w.getUint32(224, true);
    const color = { r: cursorColor.r, g: cursorColor.g, b: cursorColor.b, a: f((flags & 1) !== 0 ? 0.45 : 0.22) };
    const rect = shape === 1 ? nsctRect(x, y, 2, cellH) : shape === 2 ? nsctRect(x, f(f(y + cellH) - 2), cellW, 2) : nsctRect(x, y, cellW, cellH);
    if (!p.emit((flags & 3) === 3 ? 0 : 1, 0x610002, rect, color, (flags & 3) === 3 ? 0 : 1)) return p.result(painted);
  }
  if ((flags & 8) !== 0 && w.getUint32(232, true) < painted) {
    if (!p.stroke(0x610003, nsctRect(f(frame.x + f(f(w.getUint32(228, true)) * cellW)), f(frame.y + f(f(w.getUint32(232, true)) * cellH)), cellW, cellH), focusColor, 1)) return p.result(painted);
  }
  const offset = w.getUint32(236, true), visible = w.getUint32(240, true), total = w.getUint32(244, true);
  if (total > visible && offset + visible < total) {
    const t = f(total), v = f(visible), thumb = p.max(24, f(frame.height * f(v / t))), y = f(frame.y + f(f(frame.height - thumb) * f(f(offset) / p.max(1, f(t - v)))));
    if (!p.fill(0x610004, nsctRect(f(f(frame.x + frame.width) - 5), y, 3, thumb), { r: mutedColor.r, g: mutedColor.g, b: mutedColor.b, a: f(0.6) })) return p.result(painted);
  }
  p.emit(6, 0, nscTerminalZeroRect, nscTerminalZeroColor); return p.result(painted);
}
