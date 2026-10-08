// Ordinary text planning uses copied continuations. Fonts, widths and
// advances are capabilities; cursor, overflow and geometry decisions are
// portable. No result borrows a compiler frame or a host pointer.
function nscvTextRunLayout(request: Uint8Array): Uint8Array {
  if (request.length < 512 || request[0] !== 54 || request[1] !== 1 || request[2]! > 8 || request[3]! > 1 || request[4]! > 2 || request[5]! > 2 || request[6]! > 1 || request[7]! > 3)
    throw new Error("invalid text run header");
  // Only the fixed continuation is returned. Immutable text/glyph facts
  // stay in the caller-owned request rather than being copied per query.
  const out = request.slice(0, 512), w = new DataView(out.buffer);
  const facts = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const u = (at: number): number => w.getUint32(at, true);
  const f = (at: number): number => (at < 512 ? w : facts).getFloat32(at, true);
  const put = (at: number, value: number): void => { w.setUint32(at, value, true); };
  const float = (at: number, value: number): void => { w.setFloat32(at, value, true); };
  const add = (a: number, b: number): number => Math.fround(a + b);
  const sub = (a: number, b: number): number => Math.fround(a - b);
  const mul = (a: number, b: number): number => Math.fround(a * b);
  const div = (a: number, b: number): number => Math.fround(a / b);
  const min = (a: number, b: number): number => nscvShellMin(a, b);
  const max = (a: number, b: number): number => nscvShellMax(a, b);
  const mode = out[2]!, size = f(16), ox = f(20), oy = f(24), width = f(28);
  const textLength = u(36), glyphCount = u(40), advancesAt = 512 + glyphCount * 32, textAt = advancesAt + textLength * 4;
  if (u(8) !== textAt || u(12) !== request.length || textAt + textLength !== request.length || u(52) > 1 || u(44) > (glyphCount > 0 && mode === 0 ? glyphCount : textLength))
    throw new Error("invalid text run storage");
  const text = request.subarray(textAt), hasMeasure = (out[7]! & 1) !== 0, drawMeasure = (out[7]! & 2) !== 0;
  for (let n = 0; n < glyphCount; n++) for (let at = 512 + n * 32 + 20; at < 512 + (n + 1) * 32; at++) if (request[at] !== 0) throw new Error("invalid text glyph reserved byte");
  if (u(356) > 1 || u(364) > 1) throw new Error("invalid text line flags");
  for (let at = 376; at < 512; at++) if (out[at] !== 0) throw new Error("invalid text reserved byte");
  if (out[3] === 0) {
    for (let at = 80; at < 320; at++) if (out[at] !== 0) throw new Error("invalid initial text state");
    if (mode === 0 || mode === 1) for (let at = 320; at < 376; at++) if (out[at] !== 0) throw new Error("invalid initial text line");
  }
  const glyph = (n: number, field: number): number => { if (n >= glyphCount) throw new Error("invalid text glyph index"); return f(512 + n * 32 + field); };
  const glyphWord = (n: number, field: number): number => { if (n >= glyphCount) throw new Error("invalid text glyph index"); return facts.getUint32(512 + n * 32 + field, true); };
  const advance = (n: number): number => max(mul(size, 0.25), glyph(n, 8));
  const seq = (byte: number): number => (byte & 128) === 0 ? 1 : (byte & 224) === 192 ? 2 : (byte & 240) === 224 ? 3 : (byte & 248) === 240 ? 4 : 1;
  const snap = (offset: number): number => { let p = Math.min(offset, textLength); while (p > 0 && p < textLength && (text[p]! & 192) === 128) p--; return p; };
  const next = (offset: number): number => { const p = snap(offset); if (p >= textLength) return textLength; const end = Math.min(textLength, p + seq(text[p]!)); return end <= offset ? Math.min(textLength, offset + 1) : end; };
  const isBreak = (p: number): boolean => text[p] === 32 || text[p] === 9;
  const scalarCount = (a: number, b: number): number => { let n = 0; while (a < b) { n++; a += Math.min(seq(text[a]!), b - a); } return n; };
  const scalarOffset = (a: number, b: number, count: number): number => { let n = 0; while (a < b && n < count) { a = Math.min(b, next(a)); n++; } return a; };
  // Exact u64 product/division for proportional glyph ranges, including
  // packets whose valid index products exceed binary64's integer range.
  const ratioIndex = (a: number, b: number, denominator: number, ceil: boolean): number => {
    const al = a % 65536, ah = Math.floor(a / 65536), bl = b % 65536, bh = Math.floor(b / 65536);
    const p0 = al * bl, p1 = ah * bl + al * bh + Math.floor(p0 / 65536);
    const product: NscFlowInteger = { low: p0 % 65536 + (p1 % 65536) * 65536, high: ah * bh + Math.floor(p1 / 65536) };
    const result = nscvSemanticDivide(product, nscvFlowSmall(denominator));
    return result.quotient.low + result.quotient.high * 4294967296 + (ceil && (result.remainder.low !== 0 || result.remainder.high !== 0) ? 1 : 0);
  };
  const range = (start: number, length: number): { run_first_byte: number; run_last_byte: number } => {
    if (textLength === 0 || glyphCount === 0) return { run_first_byte: 0, run_last_byte: 0 };
    const end = Math.min(glyphCount, start + length), count = scalarCount(0, textLength);
    let a = textLength, b = 0, explicit = length > 0 && start < glyphCount;
    if (explicit) for (let n = start; n < end; n++) {
      const size = glyphWord(n, 16); if (size === 0) { explicit = false; break; }
      const at = glyphWord(n, 12), first = snap(at), last = snap(at + size);
      a = Math.min(a, first); b = Math.max(b, last);
    }
    if (explicit) return { run_first_byte: a, run_last_byte: b };
    if (count === 0) return { run_first_byte: 0, run_last_byte: 0 };
    return { run_first_byte: scalarOffset(0, textLength, Math.min(count, ratioIndex(start, count, glyphCount, false))), run_last_byte: scalarOffset(0, textLength, Math.min(count, ratioIndex(end, count, glyphCount, true))) };
  };
  const glyphBreak = (n: number): boolean => { const r = range(n, 1); return r.run_first_byte < r.run_last_byte && isBreak(r.run_first_byte); };
  const trim = (a: number, b: number): number => { let p = b; while (p > a && isBreak(p - 1)) p--; return p === a ? b : p; };
  const done = (): Uint8Array => { out[3] = 2; put(96, 0); put(100, 0); put(112, 0); return out; };
  const ask = (phase: number, kind: number, a: number, b: number): Uint8Array => {
    if (a > b || b > textLength) throw new Error("invalid text capability range");
    put(96, phase); put(100, kind); put(104, a); put(108, b); put(112, 0); float(116, 0); out[3] = 1; return out;
  };
  let phase = u(96);
  if (out[3] === 0 ? phase !== 0 : u(112) !== 1) throw new Error("invalid text continuation reply");
  if (phase !== 0 && (u(100) < 1 || u(100) > 7 || u(104) > u(108) || u(108) > textLength || u(120) > 1)) throw new Error("invalid text continuation capability");
  if (phase !== 0 && !(mode === 0 && (phase === 1 || phase === 3 || phase === 11 || phase === 12 || phase === 14 || phase === 15 || phase === 17 || phase === 19 || phase === 21 || phase === 22 || phase === 24 || phase === 31 || phase === 32) || mode === 1 && (phase === 1 || phase === 3) || mode === 2 && phase === 40 || mode === 3 && (phase === 42 || phase === 43) || mode === 4 && (phase === 31 || phase === 32) || mode === 5 && phase === 50 || mode === 6 && (phase === 60 || phase === 61) || mode === 8 && (phase === 50 || phase === 62))) throw new Error("invalid text mode continuation");
  if (phase !== 0) {
    const kind = phase === 1 || phase === 12 ? 3 : phase === 11 || phase === 15 || phase === 24 ? 5 : phase === 19 || phase === 21 ? 2 : phase === 31 ? 4 : phase === 42 ? drawMeasure ? 1 : 2 : phase === 60 || phase === 62 ? 6 : phase === 61 ? 7 : 1;
    if (u(100) !== kind || (kind === 3 || kind === 4) && (u(104) !== 0 || u(108) !== textLength) || (kind === 5 || kind === 7) && (u(104) !== 0 || u(108) !== 0)) throw new Error("invalid text phase capability");
  }
  const rawGlyphBounds = (start: number, length: number, baseline: number, height: number): void => {
    const end = Math.min(glyphCount, start + length), firstX = glyph(start, 0);
    let minX = 0, maxX = advance(start), minY = sub(baseline, size), maxY = add(minY, height);
    for (let n = start; n < end; n++) {
      const x = sub(glyph(n, 0), firstX), y = glyph(n, 4);
      minX = min(minX, x); maxX = max(maxX, add(x, advance(n)));
      minY = min(minY, sub(add(baseline, y), size)); maxY = max(maxY, add(add(baseline, y), mul(size, 0.25)));
    }
    float(336, add(ox, minX)); float(340, minY); float(344, max(0, sub(maxX, minX))); float(348, max(0, sub(maxY, minY)));
  };
  const finishBounds = (): Uint8Array => {
    if (mode === 4) return done();
    float(344, add(f(344), f(372)));
    const limit = max(0, width);
    if (!(limit <= 0 || f(344) >= limit)) {
      const extra = sub(limit, f(344)), dx = out[5] === 0 ? 0 : out[5] === 1 ? mul(extra, 0.5) : extra;
      float(336, add(f(336), dx)); float(340, add(f(340), 0));
    }
    put(300, 1); return done();
  };
  const setLine = (ts: number, tl: number, gs: number, gl: number): void => {
    put(320, ts); put(324, tl); put(328, gs); put(332, gl);
    const height = f(32) > 0 ? f(32) : mul(size, 1.25), baseline = add(oy, mul(Math.fround(u(48)), height));
    float(352, baseline); float(348, height);
  };
  const endPlain = (end: number): void => {
    put(148, end);
    if (mode === 1) { put(308, end); phase = 99; return; }
    let cursor = end;
    const finished = end >= textLength;
    if (!finished) { if (text[cursor] === 10) cursor++; else while (out[4] === 1 && cursor < textLength && isBreak(cursor)) cursor++; }
    put(288, finished ? u(44) : cursor); put(292, u(48) + 1); put(296, finished ? 1 : 0);
    setLine(u(144), end - u(144), u(144), end - u(144)); phase = 10;
  };
  const takeBreakWidth = (value: number): void => {
    const p = u(152), n = next(p); if (isBreak(p)) { put(156, n); put(160, 1); }
    const limit = width > 0 ? width : Infinity;
    if (value > limit) endPlain(p === u(144) ? n : out[4] === 1 && u(160) !== 0 && u(156) > u(144) ? trim(u(144), u(156)) : p);
    else { float(164, value); put(152, n); phase = 2; }
  };
  const elided = (length: number, painted: number): void => { put(356, 1); put(360, length); float(184, painted); put(188, 1); phase = 30; };
  const takeElisionAdvance = (value: number): void => {
    const p = u(152), n = next(p), total = add(f(164), value); float(164, total);
    if (total <= sub(width, f(372))) { put(172, n); float(176, total); }
    put(152, n); phase = 18;
  };
  const lineRange = (): { run_first_byte: number; run_last_byte: number } => { const start = Math.min(u(320), textLength); return { run_first_byte: start, run_last_byte: Math.min(textLength, start + u(324)) }; };
  const explicitLine = (): boolean => { if (u(332) === 0 || u(328) >= glyphCount) return false; for (let n = u(328); n < Math.min(glyphCount, u(328) + u(332)); n++) if (glyphWord(n, 16) === 0) return false; return true; };
  const savedRawGlyphBounds = (): { dx: number; first: number } => {
    const x = f(336), bh = f(348), saved = out.slice(336, 352);
    rawGlyphBounds(u(328), u(332), f(352), bh); const rawX = f(336);
    out.set(saved, 336);
    return { dx: sub(x, rawX), first: glyph(u(328), 0) };
  };
  const glyphX = (n: number, first: number, dx: number): number => add(sub(add(ox, glyph(n, 0)), first), dx);
  const inflate = (): void => {
    const em = max(0, size), left = mul(em, 0.1), top = mul(em, 0.35);
    float(336, sub(f(336), left)); float(340, sub(f(340), top));
    float(344, add(add(f(344), left), top)); float(348, add(add(f(348), top), left));
  };
  const unionInk = (x: number, y: number): void => {
    if (u(120) === 0) return;
    const bx = add(x, f(124)), by = sub(y, f(136)), bw = sub(f(132), f(124)), bh = sub(f(136), f(128));
    const emptyA = f(344) <= 0 || f(348) <= 0, emptyB = bw <= 0 || bh <= 0;
    if (emptyA && emptyB) { for (let at = 336; at < 352; at += 4) float(at, 0); return; }
    if (emptyB) return;
    if (emptyA) { float(336, bx); float(340, by); float(344, bw); float(348, bh); return; }
    const x0 = min(f(336), bx), y0 = min(f(340), by), x1 = max(add(f(336), f(344)), add(bx, bw)), y1 = max(add(f(340), f(348)), add(by, bh));
    float(336, x0); float(340, y0); float(344, sub(x1, x0)); float(348, sub(y1, y0));
  };
  while (true) {
    if (phase === 99) return done();
    if (phase === 0 && (mode === 0 || mode === 1)) {
      put(288, u(44)); put(292, u(48)); put(296, u(52));
      if (mode === 0 && u(52) !== 0) return done();
      put(144, u(44)); put(152, u(44));
      if (mode === 0 && glyphCount > 0) {
        let start = u(44); while (out[4] === 1 && start < glyphCount && glyphBreak(start)) start++;
        if (start >= glyphCount) {
          put(296, 1); if (u(48) > 0) return done(); setLine(0, 0, 0, 0); put(292, 1); phase = 30; continue;
        }
        let end = glyphCount, index = start, total = 0, last = -1;
        if (out[4] !== 0 && width > 0 && width !== Infinity) while (index < glyphCount) {
          if (glyphBreak(index)) last = index;
          const value = add(total, advance(index));
          if (value > width) { end = index === start ? index + 1 : out[4] === 1 && last > start ? last : index; break; }
          total = value; index++;
        }
        const r = range(start, end - start); setLine(r.run_first_byte, r.run_last_byte - r.run_first_byte, start, end - start);
        put(288, end); put(292, u(48) + 1); put(296, 0);
        if (!(out[4] === 0 && out[6] === 0 && width > 0 && width !== Infinity && end > start)) { phase = 30; continue; }
        total = 0; for (let n = start; n < end; n++) total = add(total, advance(n));
        if (total <= add(width, 0.125)) { phase = 30; continue; }
        return ask(24, 5, 0, 0);
      }
      if (textLength === 0) { endPlain(0); phase = mode === 1 ? 99 : 30; continue; }
      if (out[4] === 0 || !(width > 0) || width === Infinity) { let end = u(144); while (end < textLength && text[end] !== 10) end++; endPlain(end); continue; }
      if (hasMeasure) return ask(1, 3, 0, textLength);
      phase = 2;
    }
    if (phase === 1) { put(168, u(120)); phase = 2; }
    if (phase === 2) {
      const p = u(152); if (p >= textLength || text[p] === 10) { endPlain(p); continue; }
      if (u(168) !== 0) { takeBreakWidth(add(f(164), f(advancesAt + p * 4))); continue; }
      return ask(3, 1, u(144), next(p));
    }
    if (phase === 3) { takeBreakWidth(f(116)); continue; }
    if (phase === 10) {
      if (!(out[4] === 0 && out[6] === 0 && width > 0 && width !== Infinity && u(148) > u(144))) { phase = 30; continue; }
      if (hasMeasure) return ask(12, 3, 0, textLength);
      put(204, 2); return ask(11, 5, 0, 0);
    }
    if (phase === 12) {
      if (u(120) !== 0) { put(204, 1); return ask(11, 5, 0, 0); }
      return ask(14, 1, u(144), u(148));
    }
    if (phase === 14) {
      if (f(116) <= add(width, 0.125)) { float(184, f(116)); put(188, 1); phase = 30; continue; }
      return ask(15, 5, 0, 0);
    }
    if (phase === 15) {
      float(372, f(116));
      if (f(372) > width) { float(372, 0); elided(0, 0); continue; }
      put(152, u(144)); put(172, u(144)); float(176, 0); phase = 16;
    }
    if (phase === 16) { if (u(152) >= u(148)) { phase = 23; continue; } return ask(17, 1, u(144), next(u(152))); }
    if (phase === 17) {
      if (f(116) > sub(width, f(372))) { phase = 23; continue; }
      put(152, next(u(152))); put(172, u(152)); float(176, f(116)); phase = 16; continue;
    }
    if (phase === 23) {
      let end = u(172); while (end > u(144) && isBreak(end - 1)) end--;
      put(172, end); if (end === u(152)) { elided(end - u(144), f(176)); continue; }
      return ask(22, 1, u(144), end);
    }
    if (phase === 22) { elided(u(172) - u(144), f(116)); continue; }
    if (phase === 11) { float(372, f(116)); put(152, u(144)); put(172, u(144)); float(164, 0); float(176, 0); phase = 18; }
    if (phase === 18) {
      if (u(152) < u(148)) {
        if (u(204) === 1) { takeElisionAdvance(f(advancesAt + u(152) * 4)); continue; }
        return ask(19, 2, u(152), next(u(152)));
      }
      if (f(164) <= add(width, 0.125)) { float(372, 0); float(184, f(164)); put(188, 1); phase = 30; continue; }
      if (f(372) > width) { float(372, 0); elided(0, 0); continue; }
      float(184, f(176)); phase = 20;
    }
    if (phase === 19) { takeElisionAdvance(f(116)); continue; }
    if (phase === 20) {
      const p = u(172); if (p <= u(144) || !isBreak(p - 1)) { elided(p - u(144), max(0, f(184))); continue; }
      if (u(204) === 1) { float(184, sub(f(184), f(advancesAt + (p - 1) * 4))); put(172, p - 1); continue; }
      return ask(21, 2, p - 1, p);
    }
    if (phase === 21) { float(184, sub(f(184), f(116))); put(172, u(172) - 1); phase = 20; continue; }
    if (phase === 24) {
      float(372, f(116)); put(356, 1); put(364, 1);
      if (f(372) > width) { put(360, 0); put(368, 0); float(372, 0); phase = 30; continue; }
      let end = u(328), total = 0; const limit = u(328) + u(332);
      while (end < limit) { const value = add(total, advance(end)); if (value > sub(width, f(372))) break; total = value; end++; }
      while (end > u(328) && glyphBreak(end - 1)) end--;
      const r = range(u(328), end - u(328)); put(360, Math.max(0, r.run_last_byte - u(320))); put(368, end - u(328)); phase = 30;
    }
    if (phase === 0 && mode === 4) phase = 30;
    if (phase === 30) {
      const gs = u(328), gl = mode === 4 ? u(332) : u(364) !== 0 ? u(368) : u(332);
      if (gl > 0 && gs < glyphCount) { rawGlyphBounds(gs, gl, f(352), f(348)); return finishBounds(); }
      float(336, ox); float(340, sub(f(352), size));
      if (u(188) !== 0 && mode === 0) { float(344, f(184)); return finishBounds(); }
      if (drawMeasure) return ask(31, 4, 0, textLength);
      return ask(32, 1, u(320), Math.min(textLength, u(320) + (u(356) !== 0 ? u(360) : u(324))));
    }
    if (phase === 31) {
      if (u(120) === 0) return ask(32, 1, u(320), Math.min(textLength, u(320) + (u(356) !== 0 ? u(360) : u(324))));
      let total = 0; const end = Math.min(textLength, u(320) + (u(356) !== 0 ? u(360) : u(324)));
      for (let n = u(320); n < end; n++) total = add(total, f(advancesAt + n * 4)); float(344, total); return finishBounds();
    }
    if (phase === 32) { float(344, f(116)); return finishBounds(); }
    if (phase === 0 && mode === 2) {
      const r = lineRange(), offset = Math.max(r.run_first_byte, Math.min(r.run_last_byte, snap(u(56))));
      if (u(332) === 0 || u(328) >= glyphCount) return ask(40, 1, r.run_first_byte, offset);
      let x = f(336);
      if (r.run_last_byte > r.run_first_byte && offset > r.run_first_byte) {
        if (offset >= r.run_last_byte) x = add(f(336), f(344));
        else {
          const raw = savedRawGlyphBounds();
          if (explicitLine()) {
            x = add(f(336), f(344));
            for (let n = u(328); n < Math.min(glyphCount, u(328) + u(332)); n++) {
              const gr = range(n, 1); if (gr.run_last_byte <= r.run_first_byte || gr.run_first_byte >= r.run_last_byte) continue;
              const gx = glyphX(n, raw.first, raw.dx);
              if (offset <= gr.run_first_byte) { x = gx; break; }
              if (offset < gr.run_last_byte) { const count = scalarCount(gr.run_first_byte, gr.run_last_byte); let p = gr.run_first_byte, index = 0; while (p < snap(offset)) { p = next(p); index++; } x = add(gx, mul(div(Math.fround(Math.min(index, count)), Math.fround(count)), max(1, advance(n)))); break; }
            }
          } else {
            const count = scalarCount(r.run_first_byte, r.run_last_byte); let p = r.run_first_byte, index = 0; while (p < offset) { p = next(p); index++; }
            const relative = count === 0 ? 0 : Math.min(u(332), ratioIndex(index, u(332), count, false));
            x = relative === 0 ? f(336) : relative >= u(332) || u(328) + relative >= glyphCount ? add(f(336), f(344)) : glyphX(u(328) + relative, raw.first, raw.dx);
          }
        }
      }
      float(304, u(356) !== 0 || u(364) !== 0 ? min(x, add(f(336), f(344))) : x); return done();
    }
    if (phase === 40) { const x = add(f(336), f(116)); float(304, u(356) !== 0 || u(364) !== 0 ? min(x, add(f(336), f(344))) : x); return done(); }
    if (phase === 0 && mode === 3) {
      const r = lineRange(), x = f(60), right = add(f(336), f(344));
      if (x <= f(336)) { put(308, r.run_first_byte); return done(); }
      if (u(356) !== 0 || u(364) !== 0) {
        if (x >= right) { put(308, r.run_last_byte); return done(); }
        if (x >= sub(right, f(372))) { put(308, snap(Math.min(r.run_last_byte, u(320) + (u(356) !== 0 ? u(360) : u(324))))); return done(); }
      }
      if (u(332) > 0 && u(328) < glyphCount) {
        const raw = savedRawGlyphBounds(), explicit = explicitLine();
        for (let n = u(328); n < Math.min(glyphCount, u(328) + u(332)); n++) {
          const gx = glyphX(n, raw.first, raw.dx), step = max(1, advance(n)), gr = range(n, 1);
          if (explicit) {
            if (gr.run_last_byte <= r.run_first_byte || gr.run_first_byte >= r.run_last_byte) continue;
            if (x <= gx) { put(308, Math.max(r.run_first_byte, gr.run_first_byte)); return done(); }
            if (x < add(gx, step)) {
              const count = scalarCount(gr.run_first_byte, gr.run_last_byte), value = div(sub(x, gx), step), clamped = Number.isFinite(value) ? Math.max(0, Math.min(1, value)) : 0;
              const index = Math.floor(add(mul(clamped, Math.fround(count)), 0.5)); put(308, scalarOffset(gr.run_first_byte, gr.run_last_byte, Math.min(index, count))); return done();
            }
          } else if (x < add(gx, mul(step, 0.5))) { put(308, Math.max(r.run_first_byte, Math.min(r.run_last_byte, snap(gr.run_first_byte)))); return done(); }
        }
        put(308, r.run_last_byte); return done();
      }
      put(152, r.run_first_byte); float(164, f(336)); phase = 41;
    }
    if (phase === 41) { const r = lineRange(); if (u(152) >= r.run_last_byte) { put(308, r.run_last_byte); return done(); } return ask(42, drawMeasure ? 1 : 2, drawMeasure ? r.run_first_byte : u(152), next(u(152))); }
    if (phase === 42) { float(176, f(116)); if (drawMeasure) return ask(43, 1, lineRange().run_first_byte, u(152)); phase = 44; }
    if (phase === 43) { float(176, max(0, sub(f(176), f(116)))); phase = 44; }
    if (phase === 44) { const step = max(1, f(176)); if (f(60) < add(f(164), mul(step, 0.5))) { put(308, u(152)); return done(); } float(164, add(f(164), step)); put(152, next(u(152))); phase = 41; continue; }
    if (phase === 0 && (mode === 5 || mode === 8)) {
      if (glyphCount === 0 && textLength === 0) return done();
      if (glyphCount === 0) return ask(50, 1, 0, textLength);
      let minX = add(ox, glyph(0, 0)), maxX = add(minX, advance(0)), minY = sub(add(oy, glyph(0, 4)), size), maxY = add(add(oy, glyph(0, 4)), mul(size, 0.25));
      for (let n = 1; n < glyphCount; n++) {
        const x = add(ox, glyph(n, 0)), y = add(oy, glyph(n, 4));
        minX = min(minX, x); maxX = max(maxX, add(x, advance(n))); minY = min(minY, sub(y, size)); maxY = max(maxY, add(y, mul(size, 0.25)));
      }
      float(336, minX); float(340, minY); float(344, max(mul(size, 0.25), sub(maxX, minX))); float(348, max(mul(size, 1.25), sub(maxY, minY)));
      if (mode === 8) inflate(); put(300, 1); return done();
    }
    if (phase === 50) {
      float(336, ox); float(340, sub(oy, size)); float(344, max(mul(size, 0.25), sub(add(ox, f(116)), ox))); float(348, max(mul(size, 1.25), sub(add(oy, mul(size, 0.25)), sub(oy, size))));
      put(300, 1);
      if (mode === 8) { inflate(); if (drawMeasure) return ask(62, 6, 0, textLength); }
      return done();
    }
    if (phase === 0 && mode === 6) {
      put(300, 1); if (glyphCount > 0 || !drawMeasure) return done();
      float(220, f(336)); float(224, add(f(336), f(344)));
      const start = Math.min(u(320), textLength), end = Math.min(textLength, start + (u(356) !== 0 ? u(360) : u(324)));
      if (end > start) return ask(60, 6, start, end);
      phase = 63;
    }
    if (phase === 60) { unionInk(f(220), f(352)); phase = 63; }
    if (phase === 63) { if ((u(356) !== 0 || u(364) !== 0) && f(372) > 0) return ask(61, 7, 0, 0); return done(); }
    if (phase === 61) { unionInk(sub(f(224), f(372)), f(352)); return done(); }
    if (phase === 62) { unionInk(ox, oy); return done(); }
    if (phase === 0 && mode === 7) { inflate(); put(300, 1); return done(); }
    throw new Error("invalid text run phase");
  }
}
