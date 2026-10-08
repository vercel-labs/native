// Whole-run traversal owns no host pointer or compiler-frame storage. A
// fixed query continuation encloses the existing portable line planner;
// source facts and prepared lines remain in the caller-owned request.
function nscvTextQueryLayout(request: Uint8Array): Uint8Array {
  if (request.length < 1024 || request[0] !== 55 || request[1] !== 1 || request[2]! > 7 || request[3]! > 1 || request[4]! > 1 || request[5]! > 1)
    throw new Error("invalid text query header");
  const out = request.slice(0, 1024), w = new DataView(out.buffer);
  const u = (at: number): number => w.getUint32(at, true);
  const f = (at: number): number => w.getFloat32(at, true);
  const put = (at: number, value: number): void => { w.setUint32(at, value, true); };
  const float = (at: number, value: number): void => { w.setFloat32(at, value, true); };
  const add = (a: number, b: number): number => Math.fround(a + b);
  const sub = (a: number, b: number): number => Math.fround(a - b);
  const min = (a: number, b: number): number => nscvShellMin(a, b);
  const max = (a: number, b: number): number => nscvShellMax(a, b);
  const mode = out[2]!, capacity = u(8), prepared = out[5] === 1, length = u(548), factsEnd = u(40), lineCount = u(44);
  if (u(12) !== request.length || factsEnd !== 1024 + u(552) * 32 + length * 5 || factsEnd + lineCount * 64 !== request.length || u(520) + length !== factsEnd || u(520) !== 1024 + u(552) * 32 + length * 4 || u(24) > 1 || u(92) > 1 || out[512] !== 54 || out[513] !== 1 || u(524) !== factsEnd || (prepared ? mode < 5 : mode >= 5) || (mode !== 1 && !prepared && lineCount !== 0) || (mode === 1 && lineCount !== 64))
    throw new Error("invalid text query storage");
  for (let at = 6; at < 8; at++) if (out[at] !== 0) throw new Error("invalid text query reserved byte");
  for (let at = 48; at < 80; at++) if (out[at] !== 0) throw new Error("invalid text query reserved byte");
  for (let at = 440; at < 512; at++) if (out[at] !== 0) throw new Error("invalid text query reserved byte");
  if (out[3] === 0) {
    for (let at = 80; at < 440; at++) if (out[at] !== 0) throw new Error("invalid initial text query state");
    if (out[514] !== 0 || out[515] !== 0) throw new Error("invalid initial text query child");
    for (let at = 556; at < 576; at++) if (out[at] !== 0) throw new Error("invalid initial text query child");
    for (let at = 592; at < 1024; at++) if (out[at] !== 0) throw new Error("invalid initial text query child");
  }
  if (out[3] === 1 && (u(92) !== 1 || u(96) > 14 || u(100) > 1 || u(104) > 14 || u(116) > 1 || u(184) > 1 || u(188) > 1 || u(248) > 1 || u(272) > 1 || u(308) > 1 || u(312) > 1 || u(316) > 64 || u(124) > capacity))
    throw new Error("invalid text query continuation");
  const text = request.subarray(u(520), factsEnd);
  const snap = (offset: number): number => { let at = Math.min(offset, length); while (at > 0 && at < length && (text[at]! & 192) === 128) at--; return at; };
  const lineFirst = (at: number): number => Math.min(u(at), length);
  const lineLast = (at: number): number => Math.min(length, lineFirst(at) + u(at + 4));
  const copyLine = (to: number, from: number): void => { out.set(out.slice(from, from + 56), to); };
  const done = (): Uint8Array => { out[3] = 2; put(80, 0); put(84, 0); put(92, 0); return out; };
  const action = (kind: number, slot: number, resume: number): Uint8Array => { out[3] = 1; put(80, kind); put(84, slot); put(92, 0); put(96, resume); return out; };
  const startSub = (childMode: number, resume: number, lineAt = 128, offset = 0, x = 0): void => {
    out.fill(0, 592, 1024); out[514] = childMode; out[515] = 0;
    put(556, childMode === 0 ? u(108) : 0); put(560, childMode === 0 ? u(112) : 0); put(564, childMode === 0 ? u(116) : 0);
    put(568, offset); float(572, x);
    if (childMode !== 0 && childMode !== 5 && childMode !== 8) out.set(out.slice(lineAt, lineAt + 56), 832);
    put(368, u(368) + 1); put(100, 1); put(104, resume);
  };
  const nextLine = (resume: number, fromPrepared = prepared): void => {
    if (fromPrepared) {
      const at = u(120), count = prepared ? lineCount : u(316);
      put(184, at < count ? 1 : 0);
      if (at < count) { out.set(request.subarray(factsEnd + at * 64, factsEnd + at * 64 + 56), 128); put(120, at + 1); }
      put(96, resume);
    } else startSub(0, resume);
  };
  const unionRect = (at: number, source: number, normalize: boolean): void => {
    let ax = f(at), ay = f(at + 4), aw = f(at + 8), ah = f(at + 12);
    let bx = f(source), by = f(source + 4), bw = f(source + 8), bh = f(source + 12);
    if (normalize) {
      if (aw < 0) { ax = add(ax, aw); aw = -aw; } if (ah < 0) { ay = add(ay, ah); ah = -ah; }
      if (bw < 0) { bx = add(bx, bw); bw = -bw; } if (bh < 0) { by = add(by, bh); bh = -bh; }
    }
    const emptyA = aw <= 0 || ah <= 0, emptyB = bw <= 0 || bh <= 0;
    if (emptyA && emptyB) { out.fill(0, at, at + 16); return; }
    if (emptyA) { float(at, bx); float(at + 4, by); float(at + 8, bw); float(at + 12, bh); return; }
    if (emptyB) { float(at, ax); float(at + 4, ay); float(at + 8, aw); float(at + 12, ah); return; }
    const x0 = min(ax, bx), y0 = min(ay, by), x1 = max(add(ax, aw), add(bx, bw)), y1 = max(add(ay, ah), add(by, bh));
    float(at, x0); float(at + 4, y0); float(at + 8, sub(x1, x0)); float(at + 12, sub(y1, y0));
  };
  const accumulateBounds = (source: number): void => {
    if (u(272) === 0) { out.set(out.slice(source, source + 16), 256); put(272, 1); }
    else unionRect(256, source, true);
  };
  let phase = u(96);
  if (out[3] === 0) {
    if (mode === 3 || mode === 6) {
      put(280, snap(Math.min(u(16), u(20)))); put(284, snap(Math.max(u(16), u(20))));
      if (u(280) === u(284)) return done();
    }
    if (mode === 1 && out[4] === 0) startSub(8, 14);
    else { if (mode === 1) put(88, 1); put(96, 1); }
  }
  while (true) {
    if (u(100) !== 0) {
      const result = nscvTextRunLayoutFacts(out.subarray(512, 1024), request.subarray(0, factsEnd), 1024);
      out.set(result, 512);
      if (result[3] === 1) return action(1, 0, u(96));
      const child = out[514]!; put(100, 0); put(96, u(104));
      if (child === 0) { put(108, u(800)); put(112, u(804)); put(116, u(808)); put(184, u(812)); if (u(812) !== 0) copyLine(128, 832); }
    }
    phase = u(96);
    if (phase === 1) { nextLine(2); continue; }
    if (phase === 2) {
      if (mode === 0 || mode === 1 && u(88) === 1) {
        if (u(184) === 0) {
          if (mode === 0) return done();
          put(316, u(124)); put(120, 0); put(88, 2); put(272, 0); put(96, 8); continue;
        }
        const limit = mode === 0 ? capacity : 64;
        if (u(124) >= limit) {
          if (mode === 0) { put(312, 1); return done(); }
          // The reference first attempts its 64-line scratch, including
          // planning the overflowing line, then restarts an uncapped walk.
          put(108, 0); put(112, 0); put(116, 0); put(88, 3); put(272, 0); put(96, 8); continue;
        }
        if (mode === 0) accumulateBounds(144);
        const slot = u(124); put(124, slot + 1);
        return action(mode === 0 ? 2 : 3, slot, 1);
      }
      if (mode === 2 || mode === 5) {
        if (u(184) === 0) { if (u(188) === 0) return done(); copyLine(128, 192); startSub(2, 3, 128, u(16)); continue; }
        const offset = snap(u(16)), first = lineFirst(128), last = lineLast(128);
        if (offset < first) { if (u(188) !== 0) copyLine(128, 192); startSub(2, 3, 128, u(16)); continue; }
        if (offset < last || offset === last && u(24) === 0) { startSub(2, 3, 128, u(16)); continue; }
        if (offset === last) { copyLine(192, 128); put(188, 1); nextLine(11); continue; }
        copyLine(192, 128); put(188, 1); put(96, 1); continue;
      }
      if (mode === 3 || mode === 6) {
        if (u(184) === 0) return done();
        put(288, Math.max(u(280), lineFirst(128))); put(292, Math.min(u(284), lineLast(128)));
        if (u(288) >= u(292)) { put(96, 1); continue; }
        startSub(2, 4, 128, u(288)); continue;
      }
      if (mode === 4 || mode === 7) {
        if (u(184) === 0) {
          if (u(188) === 0) return done();
          copyLine(128, 192); copyLine(192, 384); put(188, u(248));
          startSub(3, 12, 128, 0, f(28)); continue;
        }
        if (f(32) < add(f(148), f(156))) { startSub(3, 12, 128, 0, f(28)); continue; }
        copyLine(384, 192); put(248, u(188)); copyLine(192, 128); put(188, 1); put(96, 1); continue;
      }
      throw new Error("invalid text query traversal");
    }
    if (phase === 3) {
      float(256, f(816)); float(260, f(148)); float(264, 1); float(268, max(1, f(156))); put(272, 1); return done();
    }
    if (phase === 4) { float(276, f(816)); startSub(2, 5, 128, u(292)); continue; }
    if (phase === 5) {
      const left = min(f(276), f(816)), right = max(f(276), f(816));
      float(352, left); float(356, f(148)); float(360, max(1, sub(right, left))); float(364, max(1, f(156)));
      if (capacity === 0) { put(96, 1); continue; }
      let slot = u(124);
      if (slot === capacity) { slot--; put(324, u(292)); unionRect(328, 352, false); }
      else { put(320, u(288)); put(324, u(292)); out.set(out.slice(352, 368), 328); put(124, slot + 1); }
      return action(4, slot, 1);
    }
    if (phase === 8) { nextLine(9, u(88) === 2); continue; }
    if (phase === 9) {
      if (u(184) === 0) {
        if (u(272) === 0) { startSub(8, 14); continue; }
        out.fill(0, 128, 184); out.set(out.slice(256, 272), 144); startSub(7, 10); continue;
      }
      startSub(6, 13); continue;
    }
    if (phase === 10) { out.set(out.slice(848, 864), 256); put(272, 1); return done(); }
    if (phase === 11) {
      if (u(184) === 0 || lineFirst(128) !== snap(u(16))) copyLine(128, 192);
      startSub(2, 3, 128, u(16)); continue;
    }
    if (phase === 12) {
      const offset = u(820); put(304, offset); put(308, u(188) !== 0 && offset === lineFirst(128) && lineLast(192) === offset ? 1 : 0); put(272, 1); return done();
    }
    if (phase === 13) { accumulateBounds(848); put(96, 8); continue; }
    if (phase === 14) { put(272, u(812)); if (u(812) !== 0) out.set(out.slice(848, 864), 256); return done(); }
    throw new Error("invalid text query phase");
  }
}
