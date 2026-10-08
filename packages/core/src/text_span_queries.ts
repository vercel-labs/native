// Rich paragraph query coordination. Source facts and the bounded paragraph
// scratch page belong to the caller; continuations copy only this fixed state.
function nscvTextSpanQueries(request: Uint8Array): Uint8Array {
  if (request.length < 512 || request[0] !== 56 || request[1] !== 1 || request[2]! > 2 || request[3]! > 1)
    throw new Error("invalid span query header");
  const out = request.slice(0, 512), w = new DataView(out.buffer);
  const facts = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const u = (at: number): number => w.getUint32(at, true);
  const f = (at: number): number => w.getFloat32(at, true);
  const put = (at: number, value: number): void => { w.setUint32(at, value, true); };
  const float = (at: number, value: number): void => { w.setFloat32(at, value, true); };
  const fu = (at: number): number => facts.getUint32(at, true);
  const ff = (at: number): number => facts.getFloat32(at, true);
  const mode = out[2]!, spans = u(28), spanAt = u(24), runAt = u(32), paragraphAt = u(16), paragraphLen = u(20), clipLen = u(40);
  const none = 4294967295, fr = Math.fround;
  if (u(12) !== request.length || spanAt !== 512 || runAt !== spanAt + spans * 16 || u(36) < runAt + 160 * 32 ||
      paragraphAt !== u(36) + clipLen * 4 || paragraphLen > request.length - paragraphAt || u(96) > 1 || u(104) > 1 ||
      u(152) > 160 || u(156) > 160 || u(164) > u(8)) throw new Error("invalid span query storage");
  let end = paragraphAt + paragraphLen;
  for (let s = 0; s < spans; s++) {
    const at = spanAt + s * 16;
    if (fu(at) !== end || fu(at + 4) > request.length - end || fu(at + 12) > 1 ||
        (fu(at + 12) !== 0 && (fu(at + 8) > paragraphLen || fu(at + 4) > paragraphLen - fu(at + 8))))
      throw new Error("invalid span source facts");
    end += fu(at + 4);
  }
  if (u(36) !== runAt + 160 * 32 + clipLen || end !== request.length) throw new Error("invalid span query extent");
  const byte = (at: number, len: number, i: number): number => {
    if (i < 0 || i >= len || at > request.length || len > request.length - at) throw new Error("invalid span byte cursor");
    return request[at + i]!;
  };
  const snap = (at: number, len: number, p: number): number => {
    let c = Math.min(p, len); while (c > 0 && c < len && (byte(at, len, c) & 0xc0) === 0x80) c--; return c;
  };
  const previous = (at: number, len: number, p: number): number => {
    let c = snap(at, len, p); if (c === 0) return 0; c--; while (c > 0 && (byte(at, len, c) & 0xc0) === 0x80) c--; return c;
  };
  const next = (at: number, len: number, p: number): number => {
    const c = snap(at, len, p); if (c === len) return c; const lead = byte(at, len, c);
    const result = Math.min(len, c + ((lead & 0x80) === 0 ? 1 : (lead & 0xe0) === 0xc0 ? 2 : (lead & 0xf0) === 0xe0 ? 3 : (lead & 0xf8) === 0xf0 ? 4 : 1));
    return result <= p ? Math.min(len, p + 1) : result;
  };
  const run = (slot: number): number => {
    if (slot >= 160) throw new Error("invalid span run slot"); const at = runAt + slot * 32;
    if (fu(at) >= spans || fu(at + 4) > request.length || fu(at + 8) > request.length - fu(at + 4) || fu(at + 28) > 1 ||
        (fu(at + 28) !== 0 && (fu(at + 24) > paragraphLen || fu(at + 8) > paragraphLen - fu(at + 24))))
      throw new Error("invalid span run facts");
    return at;
  };
  const done = (present: boolean): Uint8Array => { put(80, 0); put(96, 0); put(112, present ? 1 : 0); out[3] = 2; return out; };
  const ask = (kind: number, slot: number, first: number, last: number, phase: number): Uint8Array => {
    put(80, kind); put(84, slot); put(88, first); put(92, last); put(96, 0); float(100, 0); put(104, 0); put(108, phase); out[3] = 1; return out;
  };
  const layout = (page: number, phase: number): Uint8Array => ask(1, page * 128, 0, 0, phase);
  const measure = (slot: number, prefix: number, phase: number): Uint8Array => {
    const at = run(slot); if (prefix > fu(at + 8)) throw new Error("invalid span prefix"); return ask(3, slot, 0, prefix, phase);
  };
  const pageEnd = (): number => {
    let value = none; for (let i = 0; i < u(152); i++) { const at = run(i); if (fu(at + 28) !== 0) value = Math.max(value === none ? 0 : value, fu(at + 24) + fu(at + 8)); } return value;
  };
  const sourceEnd = (p: number): number => {
    let c = Math.min(p, paragraphLen); while (c < paragraphLen && (byte(paragraphAt, paragraphLen, c) === 32 || byte(paragraphAt, paragraphLen, c) === 9)) c++;
    if (c < paragraphLen && byte(paragraphAt, paragraphLen, c) === 13) c++;
    if (c < paragraphLen && byte(paragraphAt, paragraphLen, c) === 10) c++; return c;
  };
  // Boundary search state is shared by the two contextual clipping searches.
  const boundary = (target: number, continuation: number): void => {
    put(204, continuation); put(208, 0); put(212, clipLen); float(216, target);
    if (target <= 0) { put(200, 0); put(108, continuation); }
    else if (target >= f(60)) { put(200, clipLen); put(108, continuation); }
    else put(108, 11);
  };
  const flush = (phase: number): Uint8Array => {
    const left = f(228), right = f(232), top = fr(fr(u(224)) * f(160));
    let a = u(236), b = u(240), x = left, y = top, width = nscvShellMax(1, fr(right - left)), height = nscvShellMax(1, f(160));
    const count = u(164), slot = count < u(8) ? count : count - 1;
    if (count >= u(8)) {
      a = u(280); x = nscvShellMin(f(288), x); y = nscvShellMin(f(292), y);
      width = fr(nscvShellMax(fr(f(288) + f(296)), fr(left + width)) - x);
      height = fr(nscvShellMax(fr(f(292) + f(300)), fr(top + height)) - y);
    } else put(164, count + 1);
    put(280, a); put(284, b); float(288, x); float(292, y); float(296, width); float(300, height);
    put(116, a); put(120, b); float(128, x); float(132, y); float(136, width); float(140, height);
    return ask(5, slot, 0, 0, phase);
  };
  let phase = u(108);
  if (phase === 0) {
    if (out[3] !== 0) throw new Error("invalid span query initial status");
    for (let at = 80; at < 512; at++) if (out[at] !== 0) throw new Error("invalid span query initial state");
    if (mode === 0) {
      if (clipLen === 0) return done(false);
      if (!Number.isFinite(f(64)) || !Number.isFinite(f(68)) || (f(64) <= 0 && f(68) >= f(60))) { put(116, 0); put(120, clipLen); return done(true); }
      return ask(2, 0, 0, clipLen, 1);
    }
    if (mode === 2) {
      const a = snap(paragraphAt, paragraphLen, Math.min(u(44), u(48))), b = snap(paragraphAt, paragraphLen, Math.max(u(44), u(48)));
      put(172, a); put(176, b); if (a === b || u(8) === 0) return done(false);
    }
    return layout(0, mode === 1 ? 21 : 31);
  }
  if (out[3] !== 1 || u(96) !== 1) throw new Error("span query reply missing");
  const action = u(80);
  if (mode === 0 ? ![1, 10, 12, 15, 16, 19, 20].includes(phase) : mode === 1 ? ![21, 22, 25, 28].includes(phase) : ![31, 33, 35, 37, 39, 41, 42, 43, 45].includes(phase))
    throw new Error("invalid span query reply phase");
  const expected = phase === 1 ? 2 : phase === 28 ? 4 : phase === 43 || phase === 45 ? 5 : phase === 21 || phase === 22 || phase === 31 || phase === 33 || phase === 35 || phase === 37 || phase === 39 ? 1 : 3;
  if (action !== expected) throw new Error("invalid span query reply action");
  for (let at = 344; at < 512; at++) if (out[at] !== 0) throw new Error("invalid span query reserved state");
  put(96, 0);
  while (true) {
    phase = u(108);
    if (phase === 1) {
      if (u(104) !== 0) {
        const at = run(0), textAt = fu(at + 4); let c = 0, x = 0, prev = none, prevX = 0, first = 0, firstX = 0, found = false, guard = false;
        while (c < clipLen) {
          const n = next(textAt, clipLen, c); let advance = 0; for (let i = c; i < n; i++) advance = fr(advance + ff(u(36) + i * 4)); advance = nscvShellMax(0, advance);
          if (Number.isFinite(advance) && advance > 0) {
            if (!found && fr(x + advance) > nscvShellMax(0, f(64))) { first = prev === none ? c : prev; firstX = prev === none ? x : prevX; found = true; }
            if (found && x >= f(68)) {
              if (guard) { put(116, first); put(120, c); float(128, firstX); return done(first < c); } guard = true;
            }
            prev = c; prevX = x;
          }
          x = fr(x + advance); c = n;
        }
        if (!found) { put(116, 0); put(120, clipLen); return done(x <= 0); }
        put(116, first); put(120, clipLen); float(128, firstX); return done(true);
      }
      boundary(nscvShellMax(0, f(64)), 13); continue;
    }
    if (phase === 11) {
      const at = run(0), textAt = fu(at + 4), low = u(208), high = u(212);
      if (next(textAt, clipLen, low) >= high) { put(200, high); put(108, u(204)); continue; }
      let middle = snap(textAt, clipLen, low + Math.floor((high - low) / 2));
      if (middle <= low) middle = next(textAt, clipLen, low); if (middle >= high) middle = previous(textAt, clipLen, high);
      if (middle <= low || middle >= high) { put(200, high); put(108, u(204)); continue; }
      put(220, middle); return measure(0, middle, 12);
    }
    if (phase === 12) { put(f(100) < f(216) ? 208 : 212, u(220)); put(108, 11); continue; }
    if (phase === 13) {
      if (u(200) === clipLen && f(64) >= f(60)) return done(false);
      const at = run(0), visible = previous(fu(at + 4), clipLen, u(200)); put(224, visible); put(228, visible); put(108, 14); continue;
    }
    if (phase === 14) {
      if (u(228) === 0) { put(116, u(224)); boundary(f(68), 17); continue; }
      const at = run(0), p = previous(fu(at + 4), clipLen, u(228)); put(232, p); return measure(0, next(fu(at + 4), clipLen, p), 15);
    }
    if (phase === 15) { float(236, f(100)); return measure(0, u(232), 16); }
    if (phase === 16) {
      if (nscvShellMax(0, fr(f(236) - f(100))) > 0) { put(116, u(232)); boundary(f(68), 17); }
      else { put(228, u(232)); put(108, 14); } continue;
    }
    if (phase === 17) { put(228, u(200)); put(240, 0); put(108, 18); continue; }
    if (phase === 18) {
      if (u(228) >= clipLen) { put(120, clipLen); if (u(116) >= clipLen) return done(false); return measure(0, u(116), 20); }
      const at = run(0); return measure(0, next(fu(at + 4), clipLen, u(228)), 19);
    }
    if (phase === 19) { float(236, f(100)); return measure(0, u(228), 10); }
    if (phase === 10) {
      if (nscvShellMax(0, fr(f(236) - f(100))) > 0) {
        if (u(240) !== 0) { put(120, u(228)); if (u(116) >= u(228)) return done(false); return measure(0, u(116), 20); } put(240, 1);
      }
      const at = run(0); put(228, next(fu(at + 4), clipLen, u(228))); put(108, 18); continue;
    }
    if (phase === 20) { float(128, f(100)); return done(u(116) < u(120)); }
    if (phase === 21) {
      if (u(144) === 0 || f(148) <= 0) return done(false);
      const rawLine = fr(f(56) / f(148)); if (!(rawLine < 0) && !Number.isFinite(rawLine)) throw new Error("invalid paragraph point line");
      const line = rawLine < 0 ? 0 : Math.min(u(144) - 1, Math.floor(rawLine)); put(168, line);
      if (line >= 128) return ask(1, line, 0, 0, 22); put(108, 22); continue;
    }
    if (phase === 22) {
      if (u(152) === 0) {
        let white = paragraphLen !== 0, count = 1;
        for (let i = 0; i < paragraphLen; i++) { const b = byte(paragraphAt, paragraphLen, i); if (b !== 10 && b !== 13 && b !== 32 && b !== 9) white = false; if (b === 10) count++; }
        if (!white) { put(116, paragraphLen); return done(paragraphLen !== 0); }
        if (byte(paragraphAt, paragraphLen, paragraphLen - 1) === 10) count--;
        const raw = fr(f(56) / f(148)), line = raw < 0 ? 0 : Math.min(count - 1, Math.floor(raw));
        let a = 0, b = 0, current = 0; while (current < line && a < paragraphLen) { while (a < paragraphLen && byte(paragraphAt, paragraphLen, a) !== 10) a++; a = Math.min(paragraphLen, a + 1); current++; }
        b = a; while (b < paragraphLen && byte(paragraphAt, paragraphLen, b) !== 10) b++; if (b < paragraphLen) b++;
        put(172, a); put(176, b); put(180, a); put(184, b > a && byte(paragraphAt, paragraphLen, b - 1) === 10 ? b - 1 : b); put(188, 0); float(192, 0); put(108, 27); continue;
      }
      put(212, 0); put(304, none); put(312, none); put(316, none); put(108, 23); continue;
    }
    if (phase === 23) {
      if (u(212) >= u(152)) {
        if (u(304) !== none) { put(116, u(304)); return done(true); }
        if (u(312) === none) {
          for (let i = 0; i < u(152); i++) { const at = run(i); if (fu(at + 12) < u(168)) continue; if (fu(at + 28) === 0) return done(false); put(116, fu(at + 24)); return done(true); }
          for (let i = u(152); i > 0; i--) { const at = run(i - 1); if (fu(at + 28) === 0) return done(false); put(116, fu(at + 24) + fu(at + 8)); return done(true); }
          return done(false);
        }
        put(116, f(52) >= f(324) ? sourceEnd(u(316)) : u(312)); return done(true);
      }
      const at = run(u(212)); if (fu(at + 12) !== u(168)) { put(212, u(212) + 1); continue; }
      if (fu(at + 28) === 0) return done(false);
      if (u(312) === none) { put(312, fu(at + 24)); float(320, ff(at + 16)); }
      put(316, fu(at + 24) + fu(at + 8)); float(324, fr(ff(at + 16) + ff(at + 20)));
      if (f(52) >= ff(at + 16) && f(52) < f(324)) { float(244, fr(f(52) - ff(at + 16))); put(248, 0); float(252, 0); put(108, 24); }
      else put(212, u(212) + 1); continue;
    }
    if (phase === 24) {
      const at = run(u(212)), n = next(fu(at + 4), fu(at + 8), u(248));
      if (u(248) >= fu(at + 8) || f(244) <= 0) { put(304, fu(at + 24) + (f(244) <= 0 ? 0 : fu(at + 8))); put(212, u(212) + 1); put(108, 23); continue; }
      put(256, n); return measure(u(212), n, 25);
    }
    if (phase === 25) {
      const nx = nscvShellMax(fr(f(252) + 1), f(100));
      if (f(244) < fr(fr(f(252) + nx) * 0.5)) { const at = run(u(212)); put(304, fu(at + 24) + u(248)); put(212, u(212) + 1); put(108, 23); }
      else { float(252, nx); put(248, u(256)); put(108, 24); } continue;
    }
    if (phase === 27) {
      if (u(172) >= u(184) || u(188) >= spans) { put(108, 29); continue; }
      const s = u(188), at = spanAt + s * 16; if (fu(at + 12) === 0) { float(192, 0); put(108, 29); continue; }
      const a = Math.max(u(172), fu(at + 8)), b = Math.min(u(184), fu(at + 8) + fu(at + 4));
      if (a >= b) { put(188, s + 1); continue; }
      if (a > u(180)) { float(192, 0); put(108, 29); continue; }
      put(196, b); return ask(4, s, a - fu(at + 8), b - fu(at + 8), 28);
    }
    if (phase === 28) { float(192, fr(f(192) + f(100))); put(180, Math.max(u(180), u(196))); if (u(180) >= u(184)) put(108, 29); else { put(188, u(188) + 1); put(108, 27); } continue; }
    if (phase === 29) {
      const width = u(180) >= u(184) ? f(192) : 0, midpoint = width > 0 ? fr(width * 0.5) : f(72) > 0 && Number.isFinite(f(72)) ? fr(f(72) * 0.5) : 0;
      put(116, f(52) < midpoint ? u(172) : u(176)); return done(true);
    }
    if (phase === 31) {
      if (u(144) === 0 || f(148) <= 0) return done(false);
      put(156, u(152)); float(160, f(148)); put(180, 0); put(184, Math.floor((u(144) + 127) / 128)); put(188, none); put(108, 32); continue;
    }
    if (phase === 32) {
      if (u(180) >= u(184)) { put(208, u(188)); put(108, 38); continue; }
      const middle = u(180) + Math.floor((u(184) - u(180)) / 2); put(192, middle); return layout(middle, 33);
    }
    if (phase === 33) {
      const end = pageEnd();
      if (end !== none) { if (end <= u(172)) put(180, u(192) + 1); else { put(188, u(192)); put(184, u(192)); } put(108, 32); }
      else { put(200, u(192)); put(108, 34); } continue;
    }
    if (phase === 34) {
      if (u(200) <= u(180)) { put(204, u(192) + 1); put(108, 36); continue; }
      put(200, u(200) - 1); return layout(u(200), 35);
    }
    if (phase === 35) {
      const end = pageEnd(); if (end === none) put(108, 34);
      else if (end > u(172)) { put(188, u(200)); put(184, u(200)); put(108, 32); }
      else { put(204, u(192) + 1); put(108, 36); } continue;
    }
    if (phase === 36) {
      if (u(204) >= u(184)) { put(208, u(188)); put(108, 38); continue; } return layout(u(204), 37);
    }
    if (phase === 37) {
      const end = pageEnd(); if (end === none) { put(204, u(204) + 1); put(108, 36); }
      else if (end > u(172)) { put(208, u(204)); put(108, 38); }
      else { put(180, u(204) + 1); put(108, 32); } continue;
    }
    if (phase === 38) {
      if (u(208) === none) return done(false);
      if (u(208) === 0) { put(152, u(156)); put(108, 39); continue; } return layout(u(208), 39);
    }
    if (phase === 39) { put(212, 0); put(216, 0); put(224, none); put(108, 40); continue; }
    if (phase === 40) {
      if (u(212) >= u(152)) { if (u(224) !== none) return flush(45); put(108, 45); continue; }
      const at = run(u(212)); if (fu(at + 28) === 0) { put(212, u(212) + 1); continue; }
      put(216, Math.max(u(216), fu(at + 24) + fu(at + 8)));
      const a = Math.max(u(172), fu(at + 24)), b = Math.min(u(176), fu(at + 24) + fu(at + 8));
      if (a >= b) { put(212, u(212) + 1); continue; } put(260, a); put(264, b); return measure(u(212), a - fu(at + 24), 41);
    }
    if (phase === 41) { const at = run(u(212)); float(268, fr(ff(at + 16) + f(100))); return measure(u(212), u(264) - fu(at + 24), 42); }
    if (phase === 42) {
      const at = run(u(212)), x1 = fr(ff(at + 16) + f(100)); float(272, x1);
      if (u(224) === fu(at + 12)) { float(228, nscvShellMin(f(228), nscvShellMin(f(268), x1))); float(232, nscvShellMax(f(232), nscvShellMax(f(268), x1))); put(236, Math.min(u(236), u(260))); put(240, Math.max(u(240), u(264))); put(212, u(212) + 1); put(108, 40); continue; }
      if (u(224) !== none) return flush(43); put(108, 43); continue;
    }
    if (phase === 43) {
      const at = run(u(212)); put(224, fu(at + 12)); float(228, nscvShellMin(f(268), f(272))); float(232, nscvShellMax(f(268), f(272))); put(236, u(260)); put(240, u(264)); put(212, u(212) + 1); put(108, 40); continue;
    }
    if (phase === 45) {
      if (u(216) >= u(176) || u(208) + 1 >= Math.floor((u(144) + 127) / 128)) return done(u(164) !== 0);
      put(208, u(208) + 1); return layout(u(208), 39);
    }
    throw new Error("invalid span query phase");
  }
}

// Round an exact unsigned 64-bit identity/index to f32 without an intervening
// lossy f64 conversion. Halfway values follow ties-to-even as native does.
function nscvSpanLineFloat(low: number, high: number): number {
  if (high === 0) return Math.fround(low);
  let exponent = 32, power = 1;
  while (power * 2 <= high) { power *= 2; exponent++; }
  const shift = exponent - 23, divisor = 2 ** shift;
  let mantissa: number, above: boolean, tie: boolean;
  if (shift <= 32) {
    mantissa = high * (4294967296 / divisor) + Math.floor(low / divisor);
    const remainder = low % divisor; above = remainder > divisor * 0.5; tie = remainder === divisor * 0.5;
  } else {
    const upperDivisor = 2 ** (shift - 32), remainder = high % upperDivisor;
    mantissa = Math.floor(high / upperDivisor); above = remainder > upperDivisor * 0.5 || (remainder === upperDivisor * 0.5 && low !== 0);
    tie = remainder === upperDivisor * 0.5 && low === 0;
  }
  if (above || (tie && mantissa % 2 !== 0)) mantissa++;
  return Math.fround(mantissa * divisor);
}
function nscvTextSpanBounds(request: Uint8Array): Uint8Array {
  if (request.length < 24 || request[0] !== 57 || request[1] !== 1 || request[2] !== 0 || request[3] !== 0)
    throw new Error("invalid span bounds header");
  const v = new DataView(request.buffer, request.byteOffset, request.byteLength), count = v.getUint32(4, true);
  if (request.length !== 24 + count * 24 || v.getUint32(20, true) !== 0) throw new Error("invalid span bounds storage");
  const low = v.getUint32(8, true), high = v.getUint32(12, true), height = v.getFloat32(16, true), out = new Uint8Array(20), w = new DataView(out.buffer);
  let present = false, x = 0, y = 0, width = 0;
  let accumulatedHeight = 0;
  for (let i = 0; i < count; i++) {
    const at = 24 + i * 24;
    if (v.getUint32(at, true) !== low || v.getUint32(at + 4, true) !== high) continue;
    const rx = v.getFloat32(at + 16, true), ry = Math.fround(nscvSpanLineFloat(v.getUint32(at + 8, true), v.getUint32(at + 12, true)) * height), rw = v.getFloat32(at + 20, true);
    if (!present) { x = rx; y = ry; width = rw; accumulatedHeight = height; present = true; }
    else {
      const empty = width <= 0 || accumulatedHeight <= 0, nextEmpty = rw <= 0 || height <= 0;
      if (empty && nextEmpty) { x = 0; y = 0; width = 0; accumulatedHeight = 0; }
      else if (empty) { x = rx; y = ry; width = rw; accumulatedHeight = height; }
      else if (!nextEmpty) {
        const left = nscvShellMin(x, rx), top = nscvShellMin(y, ry);
        width = Math.fround(nscvShellMax(Math.fround(x + width), Math.fround(rx + rw)) - left);
        accumulatedHeight = Math.fround(nscvShellMax(Math.fround(y + accumulatedHeight), Math.fround(ry + height)) - top); x = left; y = top;
      }
    }
  }
  if (present) { w.setUint32(0, 1, true); w.setFloat32(4, x, true); w.setFloat32(8, y, true); w.setFloat32(12, width, true); w.setFloat32(16, accumulatedHeight, true); }
  return out;
}
