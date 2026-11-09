/** Shared metric registers and complete leaf sizing over explicit native
 * font and paragraph measurements. Every result owns a fixed copied record. */
function nscvWidgetMetrics(request: Uint8Array): Uint8Array {
  if (request.length !== 224) throw new Error("invalid widget metric shape");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const op = request[2]!, numeric = request[3]!, size = request[4]!, density = request[5]!, tabs = request[6]!, kind = request[7]!;
  const flags = w.getUint32(12, true), f = Math.fround, v = (at: number): number => w.getFloat32(at, true);
  if (request[0] !== 32 || request[1] !== 1 || op > 32 || numeric > 15 || size > 5 || density > 2 || tabs > 1 || kind > 62 || request[8]! > 31 || flags > 255) throw new Error("invalid widget metric header");
  for (let i = 9; i < 12; i++) if (request[i] !== 0) throw new Error("invalid widget metric reserved bytes");
  for (let i = 200; i < 224; i++) if (request[i] !== 0) throw new Error("invalid widget metric reserved bytes");
  const max = (a: number, b: number): number => nscvRenderExtreme(a, b, numeric, true);
  const min = (a: number, b: number): number => nscvRenderExtreme(a, b, numeric, false);
  const signalingAt = (at: number): boolean => {
    const word = w.getUint32(at, true);
    return (word & 0x7f800000) === 0x7f800000 && (word & 0x007fffff) !== 0 && (word & 0x00400000) === 0;
  };
  const rawMaximum = (a: number, at: number): number => (request[8]! & 16) !== 0 && signalingAt(at) ? v(at) : max(a, v(at));
  const rawMinimum = (a: number, b: number): number => (request[8]! & 2) !== 0 && signalingAt(a) ? v(a) : (request[8]! & 4) !== 0 && signalingAt(b) ? v(b) : min(v(a), v(b));
  const result = new Uint8Array(32), out = new DataView(result.buffer); out.setUint32(0, 1, true);
  const scalar = (value: number): Uint8Array => { out.setUint32(4, 1, true); out.setFloat32(8, value, true); return result; };
  const rawScalar = (at: number): Uint8Array => { out.setUint32(4, 1, true); result.set(request.subarray(at, at + 4), 8); return result; };
  const extent = (width: number, height: number): Uint8Array => { out.setUint32(4, 2, true); out.setFloat32(12, width, true); out.setFloat32(16, height, true); return result; };
  const measure = (capability: number, textSize: number, count: number, maxWidth: number = 0): Uint8Array => { out.setUint32(4, 3, true); out.setFloat32(12, maxWidth, true); out.setUint32(20, capability, true); out.setFloat32(24, textSize, true); out.setUint32(28, count, true); return result; };
  const rectangle = (x: number, y: number, width: number, height: number): Uint8Array => { out.setUint32(4, 5, true); out.setFloat32(8, x, true); out.setFloat32(12, y, true); out.setFloat32(16, width, true); out.setFloat32(20, height, true); return result; };
  const scale = size === 1 ? f(0.875) : size === 2 ? f(1.125) : 1, d = density === 0 ? f(0.875) : density === 2 ? f(1.125) : 1;
  const dense = (value: number): number => f(value * d), sized = (value: number): number => f(dense(value) * scale);
  const stepped = (value: number): number => size === 1 ? max(0, f(value - v(88))) : size === 2 ? f(value + v(88)) : value;
  const inset = (value: number): number => dense(stepped(value));
  const typography = (base: number): number => size === 1 ? max(8, f(base - 1)) : size === 2 ? f(base + 1) : base;
  const body = (): number => kind === 26 && size === 4 ? v(32) : kind === 26 && size === 5 ? v(36) : typography(v(20));
  const label = (): number => typography(v(24));
  const button = (): number => size === 1 ? max(8, f(v(28) - v(68))) : size === 2 ? max(8, f(v(28) + v(72))) : v(28);
  const height = (): number => dense(size === 1 ? v(44) : size === 2 ? v(52) : v(48));
  const buttonInset = (): number => size === 3 ? 0 : dense(size === 1 ? v(56) : size === 2 ? v(64) : v(60));
  const tabText = (): number => tabs === 0 ? label() : typography(max(8, f(v(24) + v(92))));
  const tabHeight = (): number => tabs === 0 ? height() : sized(rawMaximum(0, 96));
  const tabInset = (): number => inset(tabs === 0 ? v(112) : rawMaximum(0, 100));
  const line = (value: number): number => f(value * f(1.25));
  const snap = (value: number): number => (flags & 128) !== 0 && Number.isFinite(v(124)) && v(124) > 0 ? f(Math.ceil(f(value * v(124))) / v(124)) : value;
  const rowIcon = (): number => f(body() + v(80)), rowGap = (): number => inset(v(108));
  if (op === 0) return size === 1 || size === 2 ? scalar(button()) : rawScalar(28);
  if (op === 1) return kind === 26 && size === 4 ? rawScalar(32) : kind === 26 && size === 5 ? rawScalar(36) : size === 1 || size === 2 ? scalar(body()) : rawScalar(20);
  if (op === 2) return size === 1 || size === 2 ? scalar(label()) : rawScalar(24);
  if (op === 3) return scalar(typography(max(8, f(v(24) - 1))));
  if (op === 4) return size === 1 || size === 2 ? scalar(typography(v(16))) : rawScalar(16);
  if (op === 5) return scalar(line(v(16)));
  if (op === 6) return (flags & 128) !== 0 && Number.isFinite(v(124)) && v(124) > 0 ? scalar(f(v(16) + f(1 / v(124)))) : rawScalar(16);
  const gutterColumns = (): number => { const digits = w.getUint32(176, true); return digits === 0 ? (flags & 16) !== 0 ? 1 : 0 : Math.min(Math.max(digits, 3), 20); };
  if (op === 7) { const columns = gutterColumns(); return columns === 0 ? scalar(0) : (flags & 32) === 0 ? measure(4, body(), columns) : scalar(f(v(144) + 12)); }
  if (op === 8 || op === 9) {
    let x = v(128), y = v(132), width = v(136), tall = v(140);
    const aligned = kind === 44 && (flags & 4) !== 0 && !(tall <= 0);
    if (op === 9) {
      x = f(x + rawMinimum(152, 136)); y = f(y + rawMinimum(160, 140));
      width = max(0, f(f(width - v(152)) - v(156))); tall = max(0, f(f(tall - v(160)) - v(164)));
      const columns = gutterColumns();
      if (columns !== 0 && (flags & 32) === 0) return measure(4, body(), columns);
      const gutter = min(width, columns === 0 ? 0 : f(v(144) + 12)); x = f(x + gutter); width = f(width - gutter);
    }
    if (aligned) {
      if ((flags & 64) === 0) return measure(3, body(), 0, width);
      y = f(y + max(0, f(f(tall - v(148)) * f(0.5))));
    }
    rectangle(x, y, width, tall);
    // Alignment changes only y. Copy untouched f32 words without a
    // floating conversion, including signaling NaNs and signed zero.
    if (op === 8) {
      result.set(request.subarray(128, 132), 8);
      if (!aligned) result.set(request.subarray(132, 136), 12);
      result.set(request.subarray(136, 144), 16);
    }
    return result;
  }
  if (op === 10) return scalar(height());
  if (op === 11) return scalar(f(button() + v(80)));
  if (op === 12 || op === 25) return scalar(dense(v(76)));
  if (op === 13) return scalar(f(label() + v(80)));
  if (op === 14 || op === 16) return scalar(rowGap());
  if (op === 15) return scalar(rowIcon());
  if (op === 17) return scalar(sized(v(84)));
  if (op === 18) return scalar(buttonInset());
  if (op === 19) return scalar(inset(v(16)));
  if (op === 20) return scalar(inset(v(116)));
  if (op === 21) return scalar(tabText());
  if (op === 22) return scalar(tabHeight());
  if (op === 23) return scalar(tabInset());
  if (op === 24) return scalar(f(tabText() + v(80)));
  if (op === 26) return scalar(dense(rawMaximum(0, 104)));
  if (op === 27) return scalar(sized(v(16)));
  if (op === 28) return size === 1 || size === 2 ? scalar(stepped(v(16))) : rawScalar(16);
  if (op === 29) return scalar(scale);
  if (op === 30) return scalar(dense(v(16)));
  if (op === 31) return scalar(d);
  if ((flags & 8) !== 0) return extent(0, 0);
  const hasIcon = (flags & 2) !== 0, hasText = (flags & 1) !== 0, hasSpans = (flags & 4) !== 0;
  const square = (value: number): Uint8Array => extent(value, value);
  if (kind === 27) return square(sized(18));
  if (kind === 29) return square(sized(40));
  if (kind === 33 || (kind === 31 || kind === 32 || kind === 50) && (size === 3 || hasIcon && !hasText)) return square(height());
  if (kind === 34 || kind === 37 || kind === 38) return extent(sized(200), height());
  if (kind === 35 || kind === 36) return extent(sized(160), height());
  if (kind === 39) return extent(sized(200), sized(80));
  if (kind === 43) return extent(0, sized(36));
  if (kind === 51) return extent(sized(160), max(sized(28), sized(20)));
  if (kind === 52) return extent(sized(160), sized(4));
  if (kind === 53) return extent(sized(160), v(184));
  if (kind === 54) return extent(sized(120), sized(20));
  if (kind === 55) return square(dense(size === 1 ? 16 : size === 2 ? 24 : 20));
  if (kind === 56) return extent(sized(160), sized(48));
  if (kind === 28 || kind === 57 || kind === 61 || kind === 62) return extent(0, 0);
  if (kind === 58) return extent(v(196) > 0 ? v(196) : 9, 0);
  if (kind === 30 && hasIcon && !hasText) return extent(max(sized(24), f(f(label() + v(80)) + f(v(120) * 2))), sized(20));
  if (kind === 42 && w.getUint32(180, true) !== 0 || kind === 44 && !hasSpans && w.getUint32(180, true) !== 0 || !(kind === 26 || kind >= 30 && kind <= 32 || kind >= 40 && kind <= 42 || kind >= 44 && kind <= 50)) { out.setUint32(4, 4, true); return result; }
  const textSize = kind === 30 ? typography(max(8, f(v(24) - 1))) : kind === 31 || kind === 32 || kind === 50 ? button() : kind === 40 || kind === 47 || kind === 48 || kind === 49 ? label() : kind === 46 ? tabText() : body();
  const paragraph = (kind === 26 || kind === 44) && hasSpans;
  if ((flags & 32) === 0) return measure(paragraph ? 2 : kind === 31 || kind === 32 || kind === 50 ? 1 : 0, textSize, 0);
  const measured = v(144), textHeight = line(paragraph ? f(textSize * v(172)) : textSize);
  if (kind === 26) return extent(paragraph ? f(measured + v(168)) : measured, textHeight);
  if (kind === 44 && paragraph) return extent(rawMaximum(f(f(f(measured + v(168)) + v(152)) + v(156)), 188), rawMaximum(f(f(textHeight + v(160)) + v(164)), 192));
  if (kind === 31 || kind === 32 || kind === 50) return extent(snap(max(sized(44), f(f((hasIcon ? f(f(button() + v(80)) + dense(v(76))) : 0) + measured) + f(buttonInset() * 2)))), height());
  if (kind === 30) return extent(snap(max(sized(24), f(f((hasIcon ? f(f(label() + v(80)) + rowGap()) : 0) + measured) + f(inset(v(108)) * 2)))), sized(20));
  if (kind === 40) return extent(snap(f(measured + f(inset(v(108)) * 2))), max(height(), f(textHeight + sized(8))));
  if (kind === 45) {
    const defaults = v(152) === 0 && v(156) === 0 && v(160) === 0 && v(164) === 0;
    return extent(snap(f(measured + (defaults ? 28 : f(v(152) + v(156))))), max(sized(32), f(textHeight + (defaults ? 14 : f(v(160) + v(164))))));
  }
  if (kind === 46) {
    const iconWidth = tabs === 1 && hasIcon ? f(f(tabText() + v(80)) + (hasText ? dense(v(76)) : 0)) : 0;
    const width = f(f(iconWidth + measured) + f(tabInset() * 2));
    return extent(snap(tabs === 0 ? max(sized(44), width) : width), tabHeight());
  }
  if (kind === 47 || kind === 48 || kind === 49) {
    const track = sized(kind === 49 ? 44 : 18), band = max(sized(kind === 49 ? 24 : 18), line(label()));
    const reserve = kind === 49 && (flags & 128) !== 0 && Number.isFinite(v(124)) && v(124) > 0 ? snap(max(track, f(band * f(1.75)))) : track;
    return extent(snap(f(f(reserve + (hasText ? rowGap() : 0)) + measured)), band);
  }
  const rowWidth = snap(f(f((hasIcon ? f(rowIcon() + rowGap()) : 0) + measured) + f(inset(v(112)) * 2)));
  return kind === 41 ? extent(snap(f(rowWidth + f(rowIcon() + rowGap()))), sized(32)) : extent(rowWidth, sized(v(84)));
}
