// A fixed copied continuation owns registered-face traversal, width, byte
// advances and ink reduction. Native answers only text and font-table reads.
function nscvRegisteredMin(a: number, b: number): number { return Number.isNaN(a) ? b : Number.isNaN(b) ? a : a < b ? a : b; }
function nscvRegisteredMax(a: number, b: number): number { return Number.isNaN(a) ? b : Number.isNaN(b) ? a : a > b ? a : b; }
class NscRegisteredFont {
  readonly bytes: Uint8Array;
  readonly wire: DataView;
  constructor(request: Uint8Array) {
    if (request.length !== 128 || request[0] !== 62 || request[1] !== 1 || request[2]! > 2 || request[3]! > 1 || request[4]! > 1 || request[5] !== 0 || request[6] !== 0 || request[7] !== 0)
      throw new Error("invalid registered font header");
    this.bytes = request.slice(); this.wire = new DataView(this.bytes.buffer);
    if (this.u(32) > this.u(8) || this.u(36) > this.u(8) || this.u(72) > 4 || this.u(84) > 1 || this.u(104) > 4 || this.u(124) > 1)
      throw new Error("invalid registered font state");
    if (request[3] === 0) {
      for (let i = 32; i < 128; i++) if (request[i] !== 0) throw new Error("invalid initial registered font state");
    } else if (this.u(72) === 0 || this.u(36) < this.u(32) || this.u(44) > 65535 || this.u(52) > 2) {
      throw new Error("invalid registered font continuation");
    }
  }
  u(at: number): number { return this.wire.getUint32(at, true); }
  f(at: number): number { return this.wire.getFloat32(at, true); }
  put(at: number, value: number): void { this.wire.setUint32(at, value, true); }
  float(at: number, value: number): void { this.wire.setFloat32(at, value, true); }
  action(value: number): Uint8Array { this.put(72, value); this.bytes[3] = value === 0 ? 2 : 1; return this.bytes; }
  cell(em: number): Uint8Array {
    const registered = this.bytes[4] === 1, font = this.u(16) === 0 ? this.u(12) : 0;
    const factor = registered ? 1 : Math.fround(font === 3 ? 1.02 : font === 4 || font === 6 ? 1.04 : 1);
    const value = Math.fround(Math.fround(this.f(20) * em) * factor);
    // A registered cluster is itself a one-cluster width sum starting at
    // +0. Built-in advance estimators return their product directly.
    this.float(76, registered ? Math.fround(0 + value) : value);
    if (this.bytes[2] !== 2) return this.finishCluster();
    const lead = this.bytes[108]!;
    if (lead === 32 || lead === 9 || lead === 10 || lead === 13) return this.finishCluster();
    if (this.u(40) !== 0xffffffff) return this.action(3);
    return this.block();
  }
  fallback(): number {
    const cp = this.u(40);
    return cp !== 0xffffffff && nscvScalarTextWide(cp) ? 1 : cp >= 0x2190 && cp <= 0x2bff ? Math.fround(0.8) : Math.fround(this.f(28) / this.f(24));
  }
  finishCluster(): Uint8Array {
    if (this.bytes[2] === 1) { this.put(112, this.u(32)); this.put(116, this.u(36)); this.float(120, this.f(76)); }
    this.float(80, Math.fround(this.f(80) + this.f(76)));
    this.put(32, this.u(36));
    return this.action(this.u(32) === this.u(8) ? 0 : 1);
  }
  ink(a: number, b: number, c: number, d: number): void {
    if (this.u(84) === 0) { this.float(88, a); this.float(92, b); this.float(96, c); this.float(100, d); this.put(84, 1); }
    else { this.float(88, nscvRegisteredMin(this.f(88), a)); this.float(92, nscvRegisteredMax(this.f(92), b)); this.float(96, nscvRegisteredMin(this.f(96), c)); this.float(100, nscvRegisteredMax(this.f(100), d)); }
  }
  block(): Uint8Array {
    this.ink(this.f(80), Math.fround(this.f(80) + this.f(76)), -this.f(20), 0);
    return this.finishCluster();
  }
  step(): Uint8Array {
    this.put(112, 0); this.put(116, 0); this.float(120, 0);
    if (this.bytes[3] === 0) {
      this.put(124, this.bytes[2] === 2 && this.bytes[4] === 0 ? 0 : 1);
      return this.action(this.u(8) === 0 || this.u(124) === 0 ? 0 : 1);
    }
    const action = this.u(72);
    if (action === 1) {
      const remaining = this.u(8) - this.u(32), available = Math.min(4, remaining);
      if (available === 0 || this.u(104) !== available) throw new Error("invalid registered font text reply");
      const lead = this.bytes[108]!, length = Math.min(remaining, nscvScalarTextSequence(lead));
      this.put(36, this.u(32) + length);
      const cp = nscvScalarTextCodepoint(this.bytes, 108, 108 + length);
      this.put(40, cp < 0 ? 0xffffffff : cp);
      if (this.bytes[4] === 0 && this.u(12) === 2 && this.u(16) === 0) return this.cell(Math.fround(0.6));
      return cp < 0 ? this.cell(this.fallback()) : this.action(2);
    }
    if (action === 2) return this.cell(this.u(44) === 0 ? this.fallback() : Math.fround(this.f(48) / this.f(24)));
    if (action === 3) return this.u(44) === 0 ? this.block() : this.action(4);
    if (action !== 4) throw new Error("invalid registered font action");
    if (this.u(52) === 2) { this.put(124, 0); return this.action(0); }
    if (this.u(52) === 1) {
      const scale = Math.fround(this.f(20) / this.f(24)), natural = Math.fround(this.f(48) * scale);
      const inset = nscvRegisteredMax(0, Math.fround(Math.fround(this.f(76) - natural) * 0.5));
      const start = Math.fround(this.f(80) + inset);
      this.ink(Math.fround(start + Math.fround(this.f(56) * scale)), Math.fround(start + Math.fround(Math.fround(this.f(56) + this.f(64)) * scale)),
        -Math.fround(Math.fround(this.f(60) + this.f(68)) * scale), -Math.fround(this.f(60) * scale));
    }
    return this.finishCluster();
  }
}
function nscvRegisteredFont(request: Uint8Array): Uint8Array { return new NscRegisteredFont(request).step(); }
