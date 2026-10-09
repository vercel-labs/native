// Whole-run traversal owns no host pointer or compiler-frame storage. A
// fixed query continuation encloses the existing portable line planner;
// source facts and prepared lines remain in the caller-owned request.
function nscvTextQueryLayout(request: Uint8Array): Uint8Array {
  return new NscTextQueryContext(request).run();
}

// One copied query context retains caller facts across each capability reply
// without allocating captured helper closures.
class NscTextQueryContext {
  readonly request: Uint8Array;
  readonly out: Uint8Array;
  readonly w: DataView;
  readonly mode: number;
  readonly capacity: number;
  readonly prepared: boolean;
  readonly length: number;
  readonly factsEnd: number;
  readonly lineCount: number;
  readonly text: Uint8Array;
  constructor(request: Uint8Array) {
    if (request.length < 1024 || request[0] !== 55 || request[1] !== 1 || request[2]! > 7 || request[3]! > 1 || request[4]! > 1 || request[5]! > 1)
      throw new Error("invalid text query header");
    const out = request.slice(0, 1024), w = new DataView(out.buffer);
    this.request = request; this.out = out; this.w = w;
    const mode = out[2]!, capacity = this.u(8), prepared = out[5] === 1, length = this.u(548), factsEnd = this.u(40), lineCount = this.u(44);
    if (this.u(12) !== request.length || factsEnd !== 1024 + this.u(552) * 32 + length * 5 || factsEnd + lineCount * 64 !== request.length || this.u(520) + length !== factsEnd || this.u(520) !== 1024 + this.u(552) * 32 + length * 4 || this.u(24) > 1 || this.u(92) > 1 || out[512] !== 54 || out[513] !== 1 || this.u(524) !== factsEnd || (prepared ? mode < 5 : mode >= 5) || (mode !== 1 && !prepared && lineCount !== 0) || (mode === 1 && lineCount !== 64))
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
    if (out[3] === 1 && (this.u(92) !== 1 || this.u(96) > 14 || this.u(100) > 1 || this.u(104) > 14 || this.u(116) > 1 || this.u(184) > 1 || this.u(188) > 1 || this.u(248) > 1 || this.u(272) > 1 || this.u(308) > 1 || this.u(312) > 1 || this.u(316) > 64 || this.u(124) > capacity))
      throw new Error("invalid text query continuation");
    const text = request.subarray(this.u(520), factsEnd);
    this.mode = mode; this.capacity = capacity; this.prepared = prepared;
    this.length = length; this.factsEnd = factsEnd; this.lineCount = lineCount; this.text = text;
  }
  u(at: number): number { return this.w.getUint32(at, true); }
  f(at: number): number { return this.w.getFloat32(at, true); }
  put(at: number, value: number): void { this.w.setUint32(at, value, true); }
  float(at: number, value: number): void { this.w.setFloat32(at, value, true); }
  snap(offset: number): number { let at = Math.min(offset, this.length); while (at > 0 && at < this.length && (this.text[at]! & 192) === 128) at--; return at; }
  lineFirst(at: number): number { return Math.min(this.u(at), this.length); }
  lineLast(at: number): number { return Math.min(this.length, this.lineFirst(at) + this.u(at + 4)); }
  copyLine(to: number, from: number): void { this.out.set(this.out.slice(from, from + 56), to); }
  done(): Uint8Array { this.out[3] = 2; this.put(80, 0); this.put(84, 0); this.put(92, 0); return this.out; }
  action(kind: number, slot: number, resume: number): Uint8Array { this.out[3] = 1; this.put(80, kind); this.put(84, slot); this.put(92, 0); this.put(96, resume); return this.out; }
  startSub(childMode: number, resume: number, lineAt = 128, offset = 0, x = 0): void {
    this.out.fill(0, 592, 1024); this.out[514] = childMode; this.out[515] = 0;
    this.put(556, childMode === 0 ? this.u(108) : 0); this.put(560, childMode === 0 ? this.u(112) : 0); this.put(564, childMode === 0 ? this.u(116) : 0);
    this.put(568, offset); this.float(572, x);
    if (childMode !== 0 && childMode !== 5 && childMode !== 8) this.out.set(this.out.slice(lineAt, lineAt + 56), 832);
    this.put(368, this.u(368) + 1); this.put(100, 1); this.put(104, resume);
  }
  nextLine(resume: number, fromPrepared = this.prepared): void {
    if (fromPrepared) {
      const at = this.u(120), count = this.prepared ? this.lineCount : this.u(316);
      this.put(184, at < count ? 1 : 0);
      if (at < count) { this.out.set(this.request.subarray(this.factsEnd + at * 64, this.factsEnd + at * 64 + 56), 128); this.put(120, at + 1); }
      this.put(96, resume);
    } else this.startSub(0, resume);
  }
  unionRect(at: number, source: number, normalize: boolean): void {
    let ax = this.f(at), ay = this.f(at + 4), aw = this.f(at + 8), ah = this.f(at + 12);
    let bx = this.f(source), by = this.f(source + 4), bw = this.f(source + 8), bh = this.f(source + 12);
    if (normalize) {
      if (aw < 0) { ax = nscvTextRunAdd(ax, aw); aw = -aw; } if (ah < 0) { ay = nscvTextRunAdd(ay, ah); ah = -ah; }
      if (bw < 0) { bx = nscvTextRunAdd(bx, bw); bw = -bw; } if (bh < 0) { by = nscvTextRunAdd(by, bh); bh = -bh; }
    }
    const emptyA = aw <= 0 || ah <= 0, emptyB = bw <= 0 || bh <= 0;
    if (emptyA && emptyB) { this.out.fill(0, at, at + 16); return; }
    if (emptyA) { this.float(at, bx); this.float(at + 4, by); this.float(at + 8, bw); this.float(at + 12, bh); return; }
    if (emptyB) { this.float(at, ax); this.float(at + 4, ay); this.float(at + 8, aw); this.float(at + 12, ah); return; }
    const x0 = nscvTextRunMin(ax, bx), y0 = nscvTextRunMin(ay, by), x1 = nscvTextRunMax(nscvTextRunAdd(ax, aw), nscvTextRunAdd(bx, bw)), y1 = nscvTextRunMax(nscvTextRunAdd(ay, ah), nscvTextRunAdd(by, bh));
    this.float(at, x0); this.float(at + 4, y0); this.float(at + 8, nscvTextRunSubtract(x1, x0)); this.float(at + 12, nscvTextRunSubtract(y1, y0));
  }
  accumulateBounds(source: number): void {
    if (this.u(272) === 0) { this.out.set(this.out.slice(source, source + 16), 256); this.put(272, 1); }
    else this.unionRect(256, source, true);
  }
  run(): Uint8Array {
    let phase = this.u(96);
    if (this.out[3] === 0) {
      if (this.mode === 3 || this.mode === 6) {
        this.put(280, this.snap(Math.min(this.u(16), this.u(20)))); this.put(284, this.snap(Math.max(this.u(16), this.u(20))));
        if (this.u(280) === this.u(284)) return this.done();
      }
      if (this.mode === 1 && this.out[4] === 0) this.startSub(8, 14);
      else { if (this.mode === 1) this.put(88, 1); this.put(96, 1); }
    }
    while (true) {
      if (this.u(100) !== 0) {
        const result = new NscTextRunContext(this.out, 512, this.request, 1024, this.factsEnd).run();
        this.out.set(result, 512);
        if (result[3] === 1) return this.action(1, 0, this.u(96));
        const child = this.out[514]!; this.put(100, 0); this.put(96, this.u(104));
        if (child === 0) { this.put(108, this.u(800)); this.put(112, this.u(804)); this.put(116, this.u(808)); this.put(184, this.u(812)); if (this.u(812) !== 0) this.copyLine(128, 832); }
      }
      phase = this.u(96);
      if (phase === 1) { this.nextLine(2); continue; }
      if (phase === 2) {
        if (this.mode === 0 || this.mode === 1 && this.u(88) === 1) {
          if (this.u(184) === 0) {
            if (this.mode === 0) return this.done();
            this.put(316, this.u(124)); this.put(120, 0); this.put(88, 2); this.put(272, 0); this.put(96, 8); continue;
          }
          const limit = this.mode === 0 ? this.capacity : 64;
          if (this.u(124) >= limit) {
            if (this.mode === 0) { this.put(312, 1); return this.done(); }
            // The reference first attempts its 64-line scratch, including
            // planning the overflowing line, then restarts an uncapped walk.
            this.put(108, 0); this.put(112, 0); this.put(116, 0); this.put(88, 3); this.put(272, 0); this.put(96, 8); continue;
          }
          if (this.mode === 0) this.accumulateBounds(144);
          const slot = this.u(124); this.put(124, slot + 1);
          return this.action(this.mode === 0 ? 2 : 3, slot, 1);
        }
        if (this.mode === 2 || this.mode === 5) {
          if (this.u(184) === 0) { if (this.u(188) === 0) return this.done(); this.copyLine(128, 192); this.startSub(2, 3, 128, this.u(16)); continue; }
          const offset = this.snap(this.u(16)), first = this.lineFirst(128), last = this.lineLast(128);
          if (offset < first) { if (this.u(188) !== 0) this.copyLine(128, 192); this.startSub(2, 3, 128, this.u(16)); continue; }
          if (offset < last || offset === last && this.u(24) === 0) { this.startSub(2, 3, 128, this.u(16)); continue; }
          if (offset === last) { this.copyLine(192, 128); this.put(188, 1); this.nextLine(11); continue; }
          this.copyLine(192, 128); this.put(188, 1); this.put(96, 1); continue;
        }
        if (this.mode === 3 || this.mode === 6) {
          if (this.u(184) === 0) return this.done();
          this.put(288, Math.max(this.u(280), this.lineFirst(128))); this.put(292, Math.min(this.u(284), this.lineLast(128)));
          if (this.u(288) >= this.u(292)) { this.put(96, 1); continue; }
          this.startSub(2, 4, 128, this.u(288)); continue;
        }
        if (this.mode === 4 || this.mode === 7) {
          if (this.u(184) === 0) {
            if (this.u(188) === 0) return this.done();
            this.copyLine(128, 192); this.copyLine(192, 384); this.put(188, this.u(248));
            this.startSub(3, 12, 128, 0, this.f(28)); continue;
          }
          if (this.f(32) < nscvTextRunAdd(this.f(148), this.f(156))) { this.startSub(3, 12, 128, 0, this.f(28)); continue; }
          this.copyLine(384, 192); this.put(248, this.u(188)); this.copyLine(192, 128); this.put(188, 1); this.put(96, 1); continue;
        }
        throw new Error("invalid text query traversal");
      }
      if (phase === 3) {
        this.float(256, this.f(816)); this.float(260, this.f(148)); this.float(264, 1); this.float(268, nscvTextRunMax(1, this.f(156))); this.put(272, 1); return this.done();
      }
      if (phase === 4) { this.float(276, this.f(816)); this.startSub(2, 5, 128, this.u(292)); continue; }
      if (phase === 5) {
        const left = nscvTextRunMin(this.f(276), this.f(816)), right = nscvTextRunMax(this.f(276), this.f(816));
        this.float(352, left); this.float(356, this.f(148)); this.float(360, nscvTextRunMax(1, nscvTextRunSubtract(right, left))); this.float(364, nscvTextRunMax(1, this.f(156)));
        if (this.capacity === 0) { this.put(96, 1); continue; }
        let slot = this.u(124);
        if (slot === this.capacity) { slot--; this.put(324, this.u(292)); this.unionRect(328, 352, false); }
        else { this.put(320, this.u(288)); this.put(324, this.u(292)); this.out.set(this.out.slice(352, 368), 328); this.put(124, slot + 1); }
        return this.action(4, slot, 1);
      }
      if (phase === 8) { this.nextLine(9, this.u(88) === 2); continue; }
      if (phase === 9) {
        if (this.u(184) === 0) {
          if (this.u(272) === 0) { this.startSub(8, 14); continue; }
          this.out.fill(0, 128, 184); this.out.set(this.out.slice(256, 272), 144); this.startSub(7, 10); continue;
        }
        this.startSub(6, 13); continue;
      }
      if (phase === 10) { this.out.set(this.out.slice(848, 864), 256); this.put(272, 1); return this.done(); }
      if (phase === 11) {
        if (this.u(184) === 0 || this.lineFirst(128) !== this.snap(this.u(16))) this.copyLine(128, 192);
        this.startSub(2, 3, 128, this.u(16)); continue;
      }
      if (phase === 12) {
        const offset = this.u(820); this.put(304, offset); this.put(308, this.u(188) !== 0 && offset === this.lineFirst(128) && this.lineLast(192) === offset ? 1 : 0); this.put(272, 1); return this.done();
      }
      if (phase === 13) { this.accumulateBounds(848); this.put(96, 8); continue; }
      if (phase === 14) { this.put(272, this.u(812)); if (this.u(812) !== 0) this.out.set(this.out.slice(848, 864), 256); return this.done(); }
      throw new Error("invalid text query phase");
    }
  }
}
