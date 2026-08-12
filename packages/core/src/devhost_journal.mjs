import fs from "node:fs";

// Kept in lockstep with `zig build print-pins`; the Node test suite checks
// both values so a runtime wire change cannot silently strand dev-host
// recordings.
export const journalFormatFingerprint = 0x7f56860e36c25e39n;
export const automationProtocolFingerprint = 0x096c8aa4730c11ecn;

const requestKeyBase = 0x5453525100000000n;
const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

function concat(parts) {
  const length = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(length);
  let at = 0;
  for (const part of parts) { out.set(part, at); at += part.length; }
  return out;
}

function numberBytes(method, size, value) {
  const out = new Uint8Array(size);
  new DataView(out.buffer)[method](0, value, true);
  return out;
}
const u16 = (value) => numberBytes("setUint16", 2, value);
const u32 = (value) => numberBytes("setUint32", 4, value);
const i32 = (value) => numberBytes("setInt32", 4, value);
const u64 = (value) => numberBytes("setBigUint64", 8, BigInt(value));
const i64 = (value) => numberBytes("setBigInt64", 8, BigInt(value));
const f32 = (value) => numberBytes("setFloat32", 4, value);
const stringBytes = (value) => { const bytes = typeof value === "string" ? textEncoder.encode(value) : value; return concat([u32(bytes.length), bytes]); };

function frame(kind, payload) {
  return concat([new Uint8Array([kind]), u32(payload.length), payload]);
}

function defaultEffect(kind, key, payload, options = {}) {
  return concat([
    new Uint8Array([kind]), u64(key), stringBytes(payload), stringBytes(new Uint8Array(0)),
    new Uint8Array([0]), u32(options.dropped ?? 0), i32(options.code ?? 0), new Uint8Array([0, 0, 0]), u16(0),
    // fetch outcome, file op/outcome, clipboard op/outcome, timer outcome
    new Uint8Array([0, 0, 0, 1, 0]), u64(0), new Uint8Array([0]), i64(0),
    // audio defaults: position, zero timing/state, 32 zero bands
    new Uint8Array([1]), u64(0), u64(0), new Uint8Array([0, 0]), new Uint8Array(32),
    // image defaults + 16-byte blob hash
    new Uint8Array([0]), u64(0), u64(0), new Uint8Array(16), u64(0),
    // channel event + cumulative drops
    new Uint8Array([options.channelKind ?? 0]), u32(options.channelDroppedTotal ?? 0),
    // video defaults
    new Uint8Array([1]), u64(0), u64(0), new Uint8Array([0, 0]), u64(0), u64(0), u64(0), new Uint8Array([0, 0]),
    // pty defaults + 16-byte blob hash
    new Uint8Array([0]), i32(0), u32(0), new Uint8Array(16), u64(0),
  ]);
}

export class DevhostJournalWriter {
  constructor(file, appName, canvasLabel, width, height) {
    this.file = file;
    this.parts = [];
    this.eventCount = 0;
    this.effectCount = 0;
    const preamble = new Uint8Array(16);
    preamble.set(textEncoder.encode("NSDKSJNL"), 0);
    new DataView(preamble.buffer).setBigUint64(8, journalFormatFingerprint, true);
    this.parts.push(preamble);
    const platform = process.platform === "darwin" ? "macos" : process.platform === "win32" ? "windows" : process.platform;
    const header = concat([u64(automationProtocolFingerprint), stringBytes(platform), stringBytes(appName), i64(Date.now()), f32(width), f32(height)]);
    this.parts.push(frame(1, header));
  }

  event(tag, payload = new Uint8Array(0)) {
    this.parts.push(frame(2, concat([new Uint8Array([tag]), payload])));
    this.eventCount += 1;
  }

  installFrame(canvasLabel, width, height) {
    this.event(18, concat([
      u64(1), stringBytes(canvasLabel), f32(width), f32(height), f32(1),
      u64(1), u64(1_000_000), u64(0), u64(0), new Uint8Array([1]),
    ]));
  }
  appStart() { this.event(1); }
  wake() { this.event(16); }
  menuCommand(name) { this.event(14, concat([stringBytes(name), u64(1)])); }
  host(index, ok, payload) {
    this.parts.push(frame(3, defaultEffect(9, requestKeyBase + BigInt(index), payload, { code: ok ? 0 : 1 })));
    this.effectCount += 1;
  }
  channel(key, state, payload = new Uint8Array(0), dropped = 0, droppedTotal = 0) {
    const channelKind = state === "data" ? 0 : state === "closed" ? 1 : 2;
    this.parts.push(frame(3, defaultEffect(12, BigInt(key), payload, { dropped, channelKind, channelDroppedTotal: droppedTotal })));
    this.effectCount += 1;
  }
  finish() {
    this.parts.push(frame(6, concat([u64(this.eventCount), u64(this.effectCount), u64(0), u64(0)])));
    fs.writeFileSync(this.file, concat(this.parts));
  }
}

class Reader {
  constructor(bytes) { this.bytes = bytes; this.at = 0; }
  take(length) { if (this.at + length > this.bytes.length) throw new Error("truncated session journal"); const out = this.bytes.subarray(this.at, this.at + length); this.at += length; return out; }
  byte() { return this.take(1)[0]; }
  u16() { const b = this.take(2); return new DataView(b.buffer, b.byteOffset, 2).getUint16(0, true); }
  u32() { const b = this.take(4); return new DataView(b.buffer, b.byteOffset, 4).getUint32(0, true); }
  i32() { const b = this.take(4); return new DataView(b.buffer, b.byteOffset, 4).getInt32(0, true); }
  u64() { const b = this.take(8); return new DataView(b.buffer, b.byteOffset, 8).getBigUint64(0, true); }
  i64() { const b = this.take(8); return new DataView(b.buffer, b.byteOffset, 8).getBigInt64(0, true); }
  f32() { const b = this.take(4); return new DataView(b.buffer, b.byteOffset, 4).getFloat32(0, true); }
  string() { return this.take(this.u32()); }
  done() { return this.at === this.bytes.length; }
}

function decodeEffect(payload) {
  const r = new Reader(payload);
  const kind = r.byte();
  const key = r.u64();
  const bytes = r.string();
  r.string(); r.byte();
  const dropped = r.u32();
  const code = r.i32();
  r.byte(); r.byte(); r.byte(); r.u16();
  r.byte(); r.byte(); r.byte(); r.byte(); r.byte(); r.u64(); r.byte(); r.i64();
  r.byte(); r.u64(); r.u64(); r.byte(); r.byte(); r.take(32);
  r.byte(); r.u64(); r.u64(); r.take(16); r.u64();
  const channelKind = r.byte();
  const channelDroppedTotal = r.u32();
  r.byte(); r.u64(); r.u64(); r.byte(); r.byte(); r.u64(); r.u64(); r.u64(); r.byte(); r.byte();
  r.byte(); r.i32(); r.u32(); r.take(16); r.u64();
  if (!r.done()) throw new Error("unsupported session effect suffix");
  return { type: "effect", kind, key, payload: bytes, code, dropped, channelKind, channelDroppedTotal };
}

export function readDevhostJournal(file) {
  const bytes = new Uint8Array(fs.readFileSync(file));
  const r = new Reader(bytes);
  if (textDecoder.decode(r.take(8)) !== "NSDKSJNL") throw new Error("not a Native SDK session journal");
  if (r.u64() !== journalFormatFingerprint) throw new Error("session journal format differs from this SDK; re-record it");
  const records = [];
  let headerSeen = false;
  let events = 0;
  let effects = 0;
  let ended = false;
  while (!r.done()) {
    const kind = r.byte();
    const payload = r.take(r.u32());
    if (kind === 1) {
      if (headerSeen || records.length > 0) throw new Error("session journal header is misplaced");
      headerSeen = true;
      const h = new Reader(payload);
      if (h.u64() !== automationProtocolFingerprint) throw new Error("session automation protocol differs from this SDK");
      h.string(); h.string(); h.i64(); h.f32(); h.f32();
      if (!h.done()) throw new Error("invalid session journal header");
    } else if (kind === 2) {
      const event = new Reader(payload);
      const tag = event.byte();
      let name = null;
      if (tag === 14) { name = textDecoder.decode(event.string()); event.u64(); }
      records.push({ type: "event", tag, name });
      events += 1;
    } else if (kind === 3) {
      records.push(decodeEffect(payload));
      effects += 1;
    } else if (kind === 4 || kind === 5) {
      // Renderer checkpoints are meaningful to the packaged host and inert
      // in the logic-only dev host.
    } else if (kind === 6) {
      const end = new Reader(payload);
      const expectedEvents = Number(end.u64());
      const expectedEffects = Number(end.u64());
      end.u64(); end.u64();
      if (!end.done() || expectedEvents !== events || expectedEffects !== effects) throw new Error("session journal record counts disagree");
      ended = true;
    } else throw new Error(`unsupported session journal record ${kind}`);
  }
  if (!headerSeen || !ended) throw new Error("session journal is incomplete");
  return records;
}

export { requestKeyBase };
