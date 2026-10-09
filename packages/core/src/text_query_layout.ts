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
    const mode = out[2]!, capacity = this.w.getUint32(8, true), prepared = out[5] === 1, length = this.w.getUint32(548, true), factsEnd = this.w.getUint32(40, true), lineCount = this.w.getUint32(44, true);
    if (this.w.getUint32(12, true) !== request.length || factsEnd !== 1024 + this.w.getUint32(552, true) * 32 + length * 5 || factsEnd + lineCount * 64 !== request.length || this.w.getUint32(520, true) + length !== factsEnd || this.w.getUint32(520, true) !== 1024 + this.w.getUint32(552, true) * 32 + length * 4 || this.w.getUint32(24, true) > 1 || this.w.getUint32(92, true) > 1 || out[512] !== 54 || out[513] !== 1 || this.w.getUint32(524, true) !== factsEnd || (prepared ? mode < 5 : mode >= 5) || (mode !== 1 && !prepared && lineCount !== 0) || (mode === 1 && lineCount !== 64))
      throw new Error("invalid text query storage");
    for (let at = 6; at < 8; at++) if (out[at] !== 0) throw new Error("invalid text query reserved byte");
    for (let at = 48; at < 80; at += 4) if (w.getUint32(at, true) !== 0) throw new Error("invalid text query reserved byte");
    for (let at = 440; at < 512; at += 4) if (w.getUint32(at, true) !== 0) throw new Error("invalid text query reserved byte");
    if (out[3] === 0) {
      for (let at = 80; at < 440; at += 4) if (w.getUint32(at, true) !== 0) throw new Error("invalid initial text query state");
      if (out[514] !== 0 || out[515] !== 0) throw new Error("invalid initial text query child");
      for (let at = 556; at < 576; at += 4) if (w.getUint32(at, true) !== 0) throw new Error("invalid initial text query child");
      for (let at = 592; at < 1024; at += 4) if (w.getUint32(at, true) !== 0) throw new Error("invalid initial text query child");
    }
    if (out[3] === 1 && (this.w.getUint32(92, true) !== 1 || this.w.getUint32(96, true) > 14 || this.w.getUint32(100, true) > 1 || this.w.getUint32(104, true) > 14 || this.w.getUint32(116, true) > 1 || this.w.getUint32(184, true) > 1 || this.w.getUint32(188, true) > 1 || this.w.getUint32(248, true) > 1 || this.w.getUint32(272, true) > 1 || this.w.getUint32(308, true) > 1 || this.w.getUint32(312, true) > 1 || this.w.getUint32(316, true) > 64 || this.w.getUint32(124, true) > capacity))
      throw new Error("invalid text query continuation");
    const text = request.subarray(this.w.getUint32(520, true), factsEnd);
    this.mode = mode; this.capacity = capacity; this.prepared = prepared;
    this.length = length; this.factsEnd = factsEnd; this.lineCount = lineCount; this.text = text;
  }
  snap(offset: number): number { let at = Math.min(offset, this.length); while (at > 0 && at < this.length && (this.text[at]! & 192) === 128) at--; return at; }
  lineFirst(at: number): number { return Math.min(this.w.getUint32(at, true), this.length); }
  lineLast(at: number): number { return Math.min(this.length, this.lineFirst(at) + this.w.getUint32(at + 4, true)); }
  copyLine(to: number, from: number): void { this.out.set(this.out.slice(from, from + 56), to); }
  done(): Uint8Array { this.out[3] = 2; this.w.setUint32(80, 0, true); this.w.setUint32(84, 0, true); this.w.setUint32(92, 0, true); return this.out; }
  action(kind: number, slot: number, resume: number): Uint8Array { this.out[3] = 1; this.w.setUint32(80, kind, true); this.w.setUint32(84, slot, true); this.w.setUint32(92, 0, true); this.w.setUint32(96, resume, true); return this.out; }
  startSub(childMode: number, resume: number, lineAt = 128, offset = 0, x = 0): void {
    this.out.fill(0, 592, 1024); this.out[514] = childMode; this.out[515] = 0;
    this.w.setUint32(556, childMode === 0 ? this.w.getUint32(108, true) : 0, true); this.w.setUint32(560, childMode === 0 ? this.w.getUint32(112, true) : 0, true); this.w.setUint32(564, childMode === 0 ? this.w.getUint32(116, true) : 0, true);
    this.w.setUint32(568, offset, true); this.w.setFloat32(572, x, true);
    if (childMode !== 0 && childMode !== 5 && childMode !== 8) this.out.set(this.out.slice(lineAt, lineAt + 56), 832);
    this.w.setUint32(368, this.w.getUint32(368, true) + 1, true); this.w.setUint32(100, 1, true); this.w.setUint32(104, resume, true);
  }
  nextLine(resume: number, fromPrepared = this.prepared): void {
    if (fromPrepared) {
      const at = this.w.getUint32(120, true), count = this.prepared ? this.lineCount : this.w.getUint32(316, true);
      this.w.setUint32(184, at < count ? 1 : 0, true);
      if (at < count) { this.out.set(this.request.subarray(this.factsEnd + at * 64, this.factsEnd + at * 64 + 56), 128); this.w.setUint32(120, at + 1, true); }
      this.w.setUint32(96, resume, true);
    } else this.startSub(0, resume);
  }
  unionRect(at: number, source: number, normalize: boolean): void {
    let ax = this.w.getFloat32(at, true), ay = this.w.getFloat32(at + 4, true), aw = this.w.getFloat32(at + 8, true), ah = this.w.getFloat32(at + 12, true);
    let bx = this.w.getFloat32(source, true), by = this.w.getFloat32(source + 4, true), bw = this.w.getFloat32(source + 8, true), bh = this.w.getFloat32(source + 12, true);
    if (normalize) {
      if (aw < 0) { ax = nscvTextRunAdd(ax, aw); aw = -aw; } if (ah < 0) { ay = nscvTextRunAdd(ay, ah); ah = -ah; }
      if (bw < 0) { bx = nscvTextRunAdd(bx, bw); bw = -bw; } if (bh < 0) { by = nscvTextRunAdd(by, bh); bh = -bh; }
    }
    const emptyA = aw <= 0 || ah <= 0, emptyB = bw <= 0 || bh <= 0;
    if (emptyA && emptyB) { this.out.fill(0, at, at + 16); return; }
    if (emptyA) { this.w.setFloat32(at, bx, true); this.w.setFloat32(at + 4, by, true); this.w.setFloat32(at + 8, bw, true); this.w.setFloat32(at + 12, bh, true); return; }
    if (emptyB) { this.w.setFloat32(at, ax, true); this.w.setFloat32(at + 4, ay, true); this.w.setFloat32(at + 8, aw, true); this.w.setFloat32(at + 12, ah, true); return; }
    const x0 = nscvTextRunMin(ax, bx), y0 = nscvTextRunMin(ay, by), x1 = nscvTextRunMax(nscvTextRunAdd(ax, aw), nscvTextRunAdd(bx, bw)), y1 = nscvTextRunMax(nscvTextRunAdd(ay, ah), nscvTextRunAdd(by, bh));
    this.w.setFloat32(at, x0, true); this.w.setFloat32(at + 4, y0, true); this.w.setFloat32(at + 8, nscvTextRunSubtract(x1, x0), true); this.w.setFloat32(at + 12, nscvTextRunSubtract(y1, y0), true);
  }
  accumulateBounds(source: number): void {
    if (this.w.getUint32(272, true) === 0) { this.out.set(this.out.slice(source, source + 16), 256); this.w.setUint32(272, 1, true); }
    else this.unionRect(256, source, true);
  }
  run(): Uint8Array {
    let phase = this.w.getUint32(96, true);
    if (this.out[3] === 0) {
      if (this.mode === 3 || this.mode === 6) {
        this.w.setUint32(280, this.snap(Math.min(this.w.getUint32(16, true), this.w.getUint32(20, true))), true); this.w.setUint32(284, this.snap(Math.max(this.w.getUint32(16, true), this.w.getUint32(20, true))), true);
        if (this.w.getUint32(280, true) === this.w.getUint32(284, true)) return this.done();
      }
      if (this.mode === 1 && this.out[4] === 0) this.startSub(8, 14);
      else { if (this.mode === 1) this.w.setUint32(88, 1, true); this.w.setUint32(96, 1, true); }
    }
    while (true) {
      if (this.w.getUint32(100, true) !== 0) {
        const result = new NscTextRunContext(this.out, 512, this.request, 1024, this.factsEnd).run();
        this.out.set(result, 512);
        if (result[3] === 1) return this.action(1, 0, this.w.getUint32(96, true));
        const child = this.out[514]!; this.w.setUint32(100, 0, true); this.w.setUint32(96, this.w.getUint32(104, true), true);
        if (child === 0) { this.w.setUint32(108, this.w.getUint32(800, true), true); this.w.setUint32(112, this.w.getUint32(804, true), true); this.w.setUint32(116, this.w.getUint32(808, true), true); this.w.setUint32(184, this.w.getUint32(812, true), true); if (this.w.getUint32(812, true) !== 0) this.copyLine(128, 832); }
      }
      phase = this.w.getUint32(96, true);
      if (phase === 1) { this.nextLine(2); continue; }
      if (phase === 2) {
        if (this.mode === 0 || this.mode === 1 && this.w.getUint32(88, true) === 1) {
          if (this.w.getUint32(184, true) === 0) {
            if (this.mode === 0) return this.done();
            this.w.setUint32(316, this.w.getUint32(124, true), true); this.w.setUint32(120, 0, true); this.w.setUint32(88, 2, true); this.w.setUint32(272, 0, true); this.w.setUint32(96, 8, true); continue;
          }
          const limit = this.mode === 0 ? this.capacity : 64;
          if (this.w.getUint32(124, true) >= limit) {
            if (this.mode === 0) { this.w.setUint32(312, 1, true); return this.done(); }
            // The reference first attempts its 64-line scratch, including
            // planning the overflowing line, then restarts an uncapped walk.
            this.w.setUint32(108, 0, true); this.w.setUint32(112, 0, true); this.w.setUint32(116, 0, true); this.w.setUint32(88, 3, true); this.w.setUint32(272, 0, true); this.w.setUint32(96, 8, true); continue;
          }
          if (this.mode === 0) this.accumulateBounds(144);
          const slot = this.w.getUint32(124, true); this.w.setUint32(124, slot + 1, true);
          return this.action(this.mode === 0 ? 2 : 3, slot, 1);
        }
        if (this.mode === 2 || this.mode === 5) {
          if (this.w.getUint32(184, true) === 0) { if (this.w.getUint32(188, true) === 0) return this.done(); this.copyLine(128, 192); this.startSub(2, 3, 128, this.w.getUint32(16, true)); continue; }
          const offset = this.snap(this.w.getUint32(16, true)), first = this.lineFirst(128), last = this.lineLast(128);
          if (offset < first) { if (this.w.getUint32(188, true) !== 0) this.copyLine(128, 192); this.startSub(2, 3, 128, this.w.getUint32(16, true)); continue; }
          if (offset < last || offset === last && this.w.getUint32(24, true) === 0) { this.startSub(2, 3, 128, this.w.getUint32(16, true)); continue; }
          if (offset === last) { this.copyLine(192, 128); this.w.setUint32(188, 1, true); this.nextLine(11); continue; }
          this.copyLine(192, 128); this.w.setUint32(188, 1, true); this.w.setUint32(96, 1, true); continue;
        }
        if (this.mode === 3 || this.mode === 6) {
          if (this.w.getUint32(184, true) === 0) return this.done();
          this.w.setUint32(288, Math.max(this.w.getUint32(280, true), this.lineFirst(128)), true); this.w.setUint32(292, Math.min(this.w.getUint32(284, true), this.lineLast(128)), true);
          if (this.w.getUint32(288, true) >= this.w.getUint32(292, true)) { this.w.setUint32(96, 1, true); continue; }
          this.startSub(2, 4, 128, this.w.getUint32(288, true)); continue;
        }
        if (this.mode === 4 || this.mode === 7) {
          if (this.w.getUint32(184, true) === 0) {
            if (this.w.getUint32(188, true) === 0) return this.done();
            this.copyLine(128, 192); this.copyLine(192, 384); this.w.setUint32(188, this.w.getUint32(248, true), true);
            this.startSub(3, 12, 128, 0, this.w.getFloat32(28, true)); continue;
          }
          if (this.w.getFloat32(32, true) < nscvTextRunAdd(this.w.getFloat32(148, true), this.w.getFloat32(156, true))) { this.startSub(3, 12, 128, 0, this.w.getFloat32(28, true)); continue; }
          this.copyLine(384, 192); this.w.setUint32(248, this.w.getUint32(188, true), true); this.copyLine(192, 128); this.w.setUint32(188, 1, true); this.w.setUint32(96, 1, true); continue;
        }
        throw new Error("invalid text query traversal");
      }
      if (phase === 3) {
        this.w.setFloat32(256, this.w.getFloat32(816, true), true); this.w.setFloat32(260, this.w.getFloat32(148, true), true); this.w.setFloat32(264, 1, true); this.w.setFloat32(268, nscvTextRunMax(1, this.w.getFloat32(156, true)), true); this.w.setUint32(272, 1, true); return this.done();
      }
      if (phase === 4) { this.w.setFloat32(276, this.w.getFloat32(816, true), true); this.startSub(2, 5, 128, this.w.getUint32(292, true)); continue; }
      if (phase === 5) {
        const left = nscvTextRunMin(this.w.getFloat32(276, true), this.w.getFloat32(816, true)), right = nscvTextRunMax(this.w.getFloat32(276, true), this.w.getFloat32(816, true));
        this.w.setFloat32(352, left, true); this.w.setFloat32(356, this.w.getFloat32(148, true), true); this.w.setFloat32(360, nscvTextRunMax(1, nscvTextRunSubtract(right, left)), true); this.w.setFloat32(364, nscvTextRunMax(1, this.w.getFloat32(156, true)), true);
        if (this.capacity === 0) { this.w.setUint32(96, 1, true); continue; }
        let slot = this.w.getUint32(124, true);
        if (slot === this.capacity) { slot--; this.w.setUint32(324, this.w.getUint32(292, true), true); this.unionRect(328, 352, false); }
        else { this.w.setUint32(320, this.w.getUint32(288, true), true); this.w.setUint32(324, this.w.getUint32(292, true), true); this.out.set(this.out.slice(352, 368), 328); this.w.setUint32(124, slot + 1, true); }
        return this.action(4, slot, 1);
      }
      if (phase === 8) { this.nextLine(9, this.w.getUint32(88, true) === 2); continue; }
      if (phase === 9) {
        if (this.w.getUint32(184, true) === 0) {
          if (this.w.getUint32(272, true) === 0) { this.startSub(8, 14); continue; }
          this.out.fill(0, 128, 184); this.out.set(this.out.slice(256, 272), 144); this.startSub(7, 10); continue;
        }
        this.startSub(6, 13); continue;
      }
      if (phase === 10) { this.out.set(this.out.slice(848, 864), 256); this.w.setUint32(272, 1, true); return this.done(); }
      if (phase === 11) {
        if (this.w.getUint32(184, true) === 0 || this.lineFirst(128) !== this.snap(this.w.getUint32(16, true))) this.copyLine(128, 192);
        this.startSub(2, 3, 128, this.w.getUint32(16, true)); continue;
      }
      if (phase === 12) {
        const offset = this.w.getUint32(820, true); this.w.setUint32(304, offset, true); this.w.setUint32(308, this.w.getUint32(188, true) !== 0 && offset === this.lineFirst(128) && this.lineLast(192) === offset ? 1 : 0, true); this.w.setUint32(272, 1, true); return this.done();
      }
      if (phase === 13) { this.accumulateBounds(848); this.w.setUint32(96, 8, true); continue; }
      if (phase === 14) { this.w.setUint32(272, this.w.getUint32(812, true), true); if (this.w.getUint32(812, true) !== 0) this.out.set(this.out.slice(848, 864), 256); return this.done(); }
      throw new Error("invalid text query phase");
    }
  }
}
