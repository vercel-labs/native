// Paragraph layout continuation. The host measures only the requested raw
// span slice. Every cursor, word, line, alignment and capacity decision lives
// in this copied packet; no host pointer or compiler frame is retained.
function nscvParagraphLayout(request: Uint8Array): Uint8Array {
  if (request.length < 192 || request[0] !== 53 || request[1]! > 1 || request[2] !== 1 || request[3]! > 2 || request[4]! > 2 || request[5]! > 1 || request[6]! > 1 || request[7]! > 2)
    throw new Error("invalid paragraph header");
  const out = request.slice(), w = new DataView(out.buffer);
  const u = (at: number): number => w.getUint32(at, true);
  const f = (at: number): number => w.getFloat32(at, true);
  const put = (at: number, value: number): void => { w.setUint32(at, value, true); };
  const float = (at: number, value: number): void => { w.setFloat32(at, value, true); };
  const sourceCount = u(8), count = Math.min(sourceCount, 32), capacity = u(12), first = u(16), data = u(20);
  const pieces = 192 + sourceCount * 32, runs = pieces + 32 * 16;
  if (data !== runs + capacity * 32 || u(24) !== out.length || data > out.length)
    throw new Error("invalid paragraph storage");
  let endOfText = data;
  for (let s = 0; s < sourceCount; s++) {
    const at = 192 + s * 32;
    if (u(at) !== endOfText || u(at + 4) > out.length - endOfText || u(at + 16) > 1)
      throw new Error("invalid paragraph span");
    endOfText += u(at + 4);
    for (let p = at + 20; p < at + 32; p++) if (out[p] !== 0) throw new Error("invalid paragraph reserved byte");
  }
  if (endOfText !== out.length || u(56) > capacity || u(60) > u(56) || u(96) > 32 || u(112) > u(96) || u(72) > 1 || u(76) > 1 || u(40) > 10)
    throw new Error("invalid paragraph continuation");
  if (out[5] !== (sourceCount > 32 ? 1 : 0)) throw new Error("invalid paragraph truncation flag");
  for (let at = 172; at < 184; at++) if (out[at] !== 0) throw new Error("invalid paragraph reserved byte");
  const length = (s: number): number => { if (s >= count) throw new Error("invalid paragraph span index"); return u(196 + s * 32); };
  const byte = (s: number, p: number): number => { if (p >= length(s)) throw new Error("invalid paragraph byte index"); return out[u(192 + s * 32) + p]!; };
  const range = (s: number, a: number, b: number): void => { if (s >= count || a > b || b > length(s)) throw new Error("invalid paragraph range"); };
  const cursor = (s: number, p: number): void => {
    if (s > count || (s === count ? p !== 0 : p > length(s))) throw new Error("invalid paragraph cursor");
  };
  const savedPhase = u(40);
  if (savedPhase === 10) {
    if (out[6] !== 0 || out[7] !== 0) throw new Error("invalid paragraph initial status");
    for (let at = 44; at < 192; at++) if (out[at] !== 0) throw new Error("invalid paragraph initial state");
    for (let at = pieces; at < data; at++) if (out[at] !== 0) throw new Error("invalid paragraph initial storage");
  } else {
    if (out[6] !== 1 || out[7] !== 1) throw new Error("paragraph measurement reply missing");
    if (savedPhase !== 1 && savedPhase !== 3 && savedPhase !== 6 && savedPhase !== 8) throw new Error("invalid paragraph reply phase");
    cursor(u(44), u(48)); cursor(u(100), u(104)); cursor(u(152), u(156));
    if (u(160) > u(156) || u(52) > out.length || u(144) !== 0) throw new Error("invalid paragraph extent");
    if (u(84) !== u(88)) range(u(80), u(84), u(88));
    for (let n = 0; n < u(96); n++) range(u(pieces + n * 16), u(pieces + n * 16 + 4), u(pieces + n * 16 + 8));
    for (let n = 0; n < u(56); n++) {
      const at = runs + n * 32, start = u(at + 4), size = u(at + 8), line = u(at + 12);
      range(u(at), start, start + size);
      if (size === 0 || line < first || line > u(52) || line >= Math.min(4294967295, first + 128) || u(at + 28) !== 0)
        throw new Error("invalid paragraph run");
    }
    range(u(128), u(132), u(136));
    if (savedPhase === 1 && (u(128) !== u(44) || u(132) !== u(48))) throw new Error("invalid paragraph whitespace reply");
    if (savedPhase === 3 && (u(96) >= 32 || u(128) !== u(100) || u(132) !== u(104))) throw new Error("invalid paragraph word reply");
    if (savedPhase === 6) {
      if (u(112) >= u(96)) throw new Error("invalid paragraph piece cursor");
      const at = pieces + u(112) * 16;
      if (u(128) !== u(at) || u(116) < u(at + 4) || u(116) > u(120) || u(120) >= u(at + 8) || u(132) !== u(116) || u(136) <= u(120) || u(136) > u(at + 8))
        throw new Error("invalid paragraph prefix reply");
    }
    if (savedPhase === 8 && (u(128) !== u(152) || u(132) !== u(160) || u(136) !== u(156))) throw new Error("invalid paragraph intrinsic reply");
    if ((out[1] === 1) !== (savedPhase === 8)) throw new Error("invalid paragraph reply mode");
  }
  const next = (s: number, start: number, offset: number, limit: number): number => {
    let cursor = offset;
    while (cursor > start && cursor < limit && (byte(s, cursor) & 0xc0) === 0x80) cursor--;
    const lead = byte(s, cursor), size = (lead & 0x80) === 0 ? 1 : (lead & 0xe0) === 0xc0 ? 2 : (lead & 0xf0) === 0xe0 ? 3 : (lead & 0xf8) === 0xf0 ? 4 : 1;
    const result = Math.min(limit, cursor + size);
    return result <= offset ? Math.min(limit, offset + 1) : result;
  };
  const clearPending = (): void => { put(84, 0); put(88, 0); float(92, 0); };
  const place = (s: number, start: number, end: number, width: number): void => {
    range(s, start, end);
    if (start === end) return;
    const line = u(52), n = u(56);
    if (line >= first) {
      const at = runs + (n - 1) * 32;
      if (n > u(60) && u(at) === s && u(at + 12) === line && u(at + 4) + u(at + 8) === start) {
        put(at + 8, u(at + 8) + end - start); float(at + 20, Math.fround(f(at + 20) + width));
      } else if (n >= capacity || line >= Math.min(4294967295, first + 128)) put(76, 1);
      else {
        const at = runs + n * 32;
        put(at, s); put(at + 4, start); put(at + 8, end - start); put(at + 12, line);
        float(at + 16, f(64)); float(at + 20, width);
        float(at + 24, Math.fround(f(188) + Math.fround(Math.fround(line) * f(184)))); put(at + 28, 0); put(56, n + 1);
      }
    }
    const pen = Math.fround(f(64) + width); float(64, pen); float(68, nscvShellMax(f(68), pen)); put(72, 1);
  };
  const flush = (): void => { const s = u(80), a = u(84), b = u(88), width = f(92); clearPending(); if (a !== b) place(s, a, b, width); };
  const align = (): void => {
    if (out[4] === 0 || !Number.isFinite(f(36))) return;
    const extra = Math.fround(f(36) - f(64)); if (extra <= 0) return;
    const dx = out[4] === 1 ? Math.fround(extra * 0.5) : extra;
    for (let n = u(60); n < u(56); n++) float(runs + n * 32 + 16, Math.fround(f(runs + n * 32 + 16) + dx));
  };
  const lineBreak = (): void => { clearPending(); align(); put(60, u(56)); put(52, u(52) + 1); float(64, 0); put(72, 0); };
  const ask = (phase: number, s: number, start: number, end: number): Uint8Array => {
    range(s, start, end); put(40, phase); put(128, s); put(132, start); put(136, end); float(140, 0); out[6] = 0; out[7] = 1; return out;
  };
  let phase = u(40);
  if (phase === 10) {
    let scale = 1;
    for (let s = 0; s < sourceCount; s++) { const v = f(204 + s * 32); scale = Math.max(scale, Number.isFinite(v) && v > 0 ? v : 1); }
    float(188, Math.fround(f(32) * scale));
    float(184, f(28) > 0 ? f(28) : Math.fround(f(188) * 1.25));
    if (out[3] === 0 || !(f(36) > 0) || !Number.isFinite(f(36))) float(36, Infinity);
    put(76, out[5]!); phase = out[1] === 1 ? 7 : 0;
  }
  if (phase === 1 || phase === 3 || phase === 6 || phase === 8) {
    if (out[6] !== 1 || out[7] !== 1) throw new Error("paragraph measurement reply missing");
    range(u(128), u(132), u(136));
    const width = f(140);
    if (phase === 1) {
      flush(); put(80, u(128)); put(84, u(132)); put(88, u(136)); float(92, width); put(48, u(136)); phase = 0;
    } else if (phase === 3) {
      const at = pieces + u(96) * 16;
      if (u(96) >= 32) throw new Error("paragraph word overflow");
      put(at, u(128)); put(at + 4, u(132)); put(at + 8, u(136)); float(at + 12, width);
      put(96, u(96) + 1); float(108, Math.fround(f(108) + width)); put(104, u(136)); phase = 2;
    } else if (phase === 6) {
      const overflow = Math.fround(f(64) + width) > Math.fround(f(36) + 0.015625);
      if (overflow) {
        if (u(120) === u(116) && u(72) === 0) { put(120, u(136)); float(124, width); }
        phase = 9;
      } else { put(120, u(136)); float(124, width); phase = 5; }
    } else {
      float(164, Math.fround(f(164) + width));
      if (u(156) < length(u(152))) {
        if (byte(u(152), u(156)) === 10) { float(168, nscvShellMax(f(168), f(164))); float(164, 0); }
        put(156, u(156) + 1); put(160, u(156));
      } else { put(152, u(152) + 1); put(156, 0); put(160, 0); }
      phase = 7;
    }
    out[6] = 0; out[7] = 0;
  }
  while (true) {
    if (phase === 7) {
      const s = u(152);
      if (s >= count) { float(68, nscvShellMax(f(168), f(164))); break; }
      let cursor = u(156);
      while (cursor < length(s) && byte(s, cursor) !== 10 && byte(s, cursor) !== 13) cursor++;
      put(156, cursor); return ask(8, s, u(160), cursor);
    }
    if (phase === 0) {
      const s = u(44), offset = u(48);
      if (s >= count) { clearPending(); align(); const n = u(52) + (u(72) !== 0 || u(56) > u(60) || u(52) === 0 ? 1 : 0); put(144, n); float(148, Math.fround(Math.fround(n) * f(184))); break; }
      if (offset >= length(s)) { put(44, s + 1); put(48, 0); continue; }
      const b = byte(s, offset);
      if (b === 10) { lineBreak(); put(48, offset + 1); continue; }
      if (b === 13) { put(48, offset + 1); continue; }
      if (b === 32 || b === 9) {
        let end = offset;
        while (end < length(s) && (byte(s, end) === 32 || byte(s, end) === 9)) end++;
        if (u(72) !== 0 || u(208 + s * 32) === 1) return ask(1, s, offset, end);
        put(48, end); continue;
      }
      put(96, 0); put(112, 0); put(100, s); put(104, offset); float(108, 0); phase = 2;
    } else if (phase === 2) {
      const s = u(100), offset = u(104);
      if (s < count && u(96) < 32) {
        if (offset >= length(s)) { put(100, s + 1); put(104, 0); continue; }
        const b = byte(s, offset);
        if (b !== 10 && b !== 32 && b !== 9) {
          let end = offset;
          while (end < length(s) && byte(s, end) !== 10 && byte(s, end) !== 13 && byte(s, end) !== 32 && byte(s, end) !== 9) end++;
          return ask(3, s, offset, end);
        }
      }
      if (out[3] === 1 && u(72) !== 0 && Math.fround(Math.fround(f(64) + f(92)) + f(108)) > Math.fround(f(36) + 0.015625)) lineBreak(); else flush();
      put(112, 0); phase = 4;
    } else if (phase === 4) {
      const p = u(112);
      if (p >= u(96)) { put(44, u(100)); put(48, u(104)); phase = 0; continue; }
      const at = pieces + p * 16, s = u(at), a = u(at + 4), b = u(at + 8), width = f(at + 12);
      range(s, a, b);
      if (a !== b && Math.fround(f(64) + width) > Math.fround(f(36) + 0.015625)) { put(116, a); put(120, a); float(124, 0); phase = 5; }
      else { place(s, a, b, width); put(112, p + 1); }
    } else if (phase === 5) {
      const at = pieces + u(112) * 16, s = u(at), limit = u(at + 8);
      if (u(120) < limit) return ask(6, s, u(116), next(s, u(at + 4), u(120), limit));
      phase = 9;
    } else if (phase === 9) {
      const at = pieces + u(112) * 16, s = u(at), limit = u(at + 8);
      if (u(120) === u(116)) { lineBreak(); phase = 5; continue; }
      place(s, u(116), u(120), f(124)); put(116, u(120));
      if (u(116) < limit) { lineBreak(); put(120, u(116)); float(124, 0); phase = 5; }
      else { put(112, u(112) + 1); phase = 4; }
    } else throw new Error("invalid paragraph phase");
  }
  put(40, 0); out[6] = 0; out[7] = 2; return out;
}
