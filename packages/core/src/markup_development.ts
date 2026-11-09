/** Markup reload and provenance programs. Source spans, identities and hashes
 * travel as raw words; native retains arenas, typed storage and OS execution.
 * Every returned buffer is owned and every borrowed input remains unchanged.
 */
class NscMarkupReader {
  at: number = 4;
  readonly view: DataView;
  readonly bytes: Uint8Array;
  constructor(bytes: Uint8Array) { this.bytes = bytes; this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength); }
  u8(): number { if (this.at >= this.bytes.length) throw new Error("short markup request"); return this.bytes[this.at++]!; }
  u32(): number { if (this.at + 4 > this.bytes.length) throw new Error("short markup word"); const v = this.view.getUint32(this.at, true); this.at += 4; return v; }
  blob(): Uint8Array { const n = this.u32(); if (n > this.bytes.length - this.at) throw new Error("short markup bytes"); const b = this.bytes.subarray(this.at, this.at + n); this.at += n; return b; }
  done(): void { if (this.at !== this.bytes.length) throw new Error("trailing markup bytes"); }
}
function nscmdEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
function nscmdWords(words: readonly number[]): Uint8Array {
  const out = new Uint8Array(words.length * 4), v = new DataView(out.buffer);
  for (let i = 0; i < words.length; i++) v.setUint32(i * 4, words[i]!, true);
  return out;
}
function nscmdBoolean(value: number): boolean {
  if (value > 1) throw new Error("invalid markup boolean");
  return value !== 0;
}
function nscmdPathIndex(paths: readonly Uint8Array[], path: Uint8Array): number {
  for (let i = 0; i < paths.length; i++) if (nscmdEqual(paths[i]!, path)) return i;
  return 255;
}
function nscmdSpan(r: NscMarkupReader): number {
  const lo = r.u32(), hi = r.u32(); return hi !== 0 ? 4294967295 : lo;
}
function nscmdText(parts: readonly Uint8Array[]): Uint8Array {
  let length = 0; for (const part of parts) length += part.length;
  const out = new Uint8Array(length); let at = 0;
  for (const part of parts) { out.set(part, at); at += part.length; }
  return out;
}
function nscmdLiteral(text: string): Uint8Array { return new TextEncoder().encode(text); }
function nscmdNumber(value: number): Uint8Array { return nscmdLiteral(value.toFixed(0)); }

/** Version 1, opcode 32. Stages 0–5 select reload/diagnostic/storage actions;
 * stage 6 builds a complete bounded provenance record, stage 7 writes its
 * complete public response, stages 8/9 select retained identities/paths, and
 * stages 10/11 derive committed file paths and aggregate rebuild admission.
 */
export function markupDevelopmentPolicy(input: Uint8Array): Uint8Array {
  if (input.length < 4 || input[0] !== 32 || input[1] !== 1 || input[2]! > 11 || input[3] !== 0) throw new Error("invalid markup development request");
  const r = new NscMarkupReader(input), stage = input[2]!;
  if (stage === 0) {
    const root = nscmdBoolean(r.u8()), view = nscmdBoolean(r.u8()), zero = nscmdBoolean(r.u8());
    const fragments = nscmdBoolean(r.u8()), count = r.u32(), capacity = r.u32(); r.done();
    return nscmdWords([root && view && zero ? 1 : 0, root || fragments && count !== 0 ? 1 : 0, fragments ? Math.min(count, capacity) : 0, fragments && count > capacity ? 1 : 0]);
  }
  if (stage === 1) {
    const kind = r.u8(), changed = nscmdBoolean(r.u8()), failed = nscmdBoolean(r.u8()), diagnostic = nscmdBoolean(r.u8());
    const baseline = nscmdBoolean(r.u8()), installed = nscmdBoolean(r.u8()); r.done();
    if (kind > 2) throw new Error("invalid markup reload kind");
    // Ordered actions: remember observed hash, report failure, canonicalize,
    // adopt root, commit provenance, rebuild root, restore compiled fragment,
    // adopt fragment, switch arena, clear diagnostic, mark fragment adoption.
    if (!changed) return new Uint8Array(12);
    if (failed) {
      const out = new Uint8Array(12); let at = 0;
      if (kind !== 0) out[at++] = 1;
      if (diagnostic) out[at] = 2;
      return out;
    }
    if (kind === 2) return baseline ? new Uint8Array([1, 7, 9, 10, 11, 0, 0, 0, 0, 0, 0, 0]) : new Uint8Array([1, 3, 8, 9, 10, 11, 0, 0, 0, 0, 0, 0]);
    return new Uint8Array([3, 4, 5, installed && kind === 1 ? 6 : 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  }
  if (stage === 2) {
    const present = nscmdBoolean(r.u8()), lineEqual = nscmdBoolean(r.u8()), columnEqual = nscmdBoolean(r.u8());
    const currentMessage = r.blob(), message = r.blob(), currentPath = r.blob(), path = r.blob();
    const messageCapacity = r.u32(), pathCapacity = r.u32(); r.done();
    return nscmdWords([present && lineEqual && columnEqual && nscmdEqual(currentMessage, message) && nscmdEqual(currentPath, path) ? 0 : 1, Math.min(message.length, messageCapacity), Math.min(path.length, pathCapacity)]);
  }
  if (stage === 3) {
    const prefix = r.blob(), path = r.blob(); r.done();
    let match = prefix.length > 0 && path.length > prefix.length && path[prefix.length] === 47;
    if (match) for (let i = 0; i < prefix.length; i++) if (prefix[i] !== path[i]) match = false;
    return nscmdWords([match ? prefix.length + 1 : 0]);
  }
  if (stage === 4 || stage === 5) {
    const count = r.u32(), capacity = r.u32(), first = r.u32(), second = r.u32(), pathCapacity = r.u32(); r.done();
    return nscmdWords([count >= capacity ? 0 : 1, Math.min(first, pathCapacity), Math.min(second, pathCapacity)]);
  }
  if (stage === 6) {
    const count = r.u32(), fileCount = r.u32();
    if (count > 1024 || fileCount > 33) throw new Error("invalid provenance capacity");
    const paths: Uint8Array[] = [];
    for (let i = 0; i < fileCount; i++) { const path = r.blob(); if (path.length > 240) throw new Error("invalid retained provenance path"); paths.push(path); }
    const out = new Uint8Array(160), v = new DataView(out.buffer);
    out[0] = count < 1024 ? 1 : 0;
    for (let i = 0; i < 2; i++) v.setUint32(4 + i * 4, r.u32(), true);
    out[12] = nscmdPathIndex(paths, r.blob());
    for (let i = 0; i < 4; i++) v.setUint32(16 + i * 4, nscmdSpan(r), true);
    const chainCount = r.u32(); out[1] = Math.min(chainCount, 4); out[2] = chainCount > 4 ? 1 : 0;
    for (let i = 0; i < Math.min(chainCount, 4); i++) {
      const at = 32 + i * 20; out[at] = nscmdPathIndex(paths, r.blob());
      for (let j = 0; j < 4; j++) v.setUint32(at + 4 + j * 4, nscmdSpan(r), true);
    }
    let truncated = nscmdBoolean(r.u8()), used = 0, stopped = false;
    const keyCount = r.u32(); if (keyCount > 50) throw new Error("invalid provenance key count");
    for (let i = 0; i < keyCount; i++) {
      const kind = r.u8(), bytes = r.blob(); if (kind > 1 || bytes.length > 49) throw new Error("invalid provenance key");
      if (stopped) continue;
      if (i > 0) { if (used < 48) out[112 + used++] = 47; else truncated = true; }
      for (let j = 0; j < bytes.length; j++) {
        if (used === 48) { truncated = true; break; }
        const byte = bytes[j]!; out[112 + used++] = kind === 1 && (byte < 32 || byte === 127) ? 58 : byte;
      }
      if (truncated) stopped = true;
    }
    out[3] = truncated ? 1 : 0; out[13] = used; r.done(); return out;
  }
  if (stage === 8) {
    const low = r.u32(), high = r.u32(), count = r.u32(); if (count > 1024) throw new Error("invalid provenance records");
    let found = 4294967295;
    for (let i = 0; i < count; i++) { const lo = r.u32(), hi = r.u32(); if (found === 4294967295 && lo === low && hi === high) found = i; }
    r.done(); return nscmdWords([found]);
  }
  if (stage === 9) {
    const count = r.u32(); if (count > 33) throw new Error("invalid provenance file count");
    const paths: Uint8Array[] = [];
    for (let i = 0; i < count; i++) { const path = r.blob(); if (path.length > 240) throw new Error("invalid provenance path"); paths.push(path); }
    const index = nscmdPathIndex(paths, r.blob()); r.done(); return nscmdWords([index]);
  }
  if (stage === 10) {
    const disk = nscmdBoolean(r.u8()), watch = nscmdBoolean(r.u8()), prefix = r.blob(), stamped = r.blob(); r.done();
    if (disk) return stamped.slice(0, 240);
    if (!watch || prefix.length !== 0 && prefix.length + 1 + stamped.length > 240) return new Uint8Array(0);
    return prefix.length === 0 ? stamped.slice(0, 240) : nscmdText([prefix, nscmdLiteral("/"), stamped]);
  }
  if (stage === 11) {
    const adopted = nscmdBoolean(r.u8()), installed = nscmdBoolean(r.u8()); r.done();
    return nscmdWords([adopted && installed ? 1 : 0]);
  }
  const found = nscmdBoolean(r.u8()), watching = nscmdBoolean(r.u8()), chainTruncated = nscmdBoolean(r.u8()), keysTruncated = nscmdBoolean(r.u8());
  const view = r.blob(), id = r.blob(), dropped = r.blob(), root = r.blob(), keys = r.blob();
  const count = r.u32(); if (count > 5 || !found && count !== 0) throw new Error("invalid provenance sites");
  const parts: Uint8Array[] = [];
  if (found) {
    parts.push(nscmdLiteral("provenance ok view="), view, nscmdLiteral(" id="), id, nscmdLiteral(" authored=markup watching="), nscmdLiteral(watching ? "true" : "false"), nscmdLiteral(" root="), root, nscmdLiteral("\n"));
    for (let i = 0; i < count; i++) {
      const file = r.blob(), stamped = r.blob(), hash = r.blob(), first = r.u32(), last = r.u32(), line = r.u32(), column = r.u32();
      parts.push(nscmdLiteral(i === 0 ? "node file=" : "use file="), file, nscmdLiteral(" stamped="), stamped, nscmdLiteral(" hash="), hash, nscmdLiteral(" span="), nscmdNumber(first), nscmdLiteral(".."), nscmdNumber(last), nscmdLiteral(" line="), nscmdNumber(line), nscmdLiteral(" column="), nscmdNumber(column), nscmdLiteral("\n"));
    }
    if (chainTruncated) parts.push(nscmdLiteral("chain_truncated=true\n"));
    if (keys.length !== 0 || keysTruncated) parts.push(nscmdLiteral("keys="), keys, nscmdLiteral(" keys_truncated="), nscmdLiteral(keysTruncated ? "true\n" : "false\n"));
  } else if (dropped.length !== 1 || dropped[0] !== 48) {
    parts.push(nscmdLiteral("provenance error view="), view, nscmdLiteral(" id="), id, nscmdLiteral(" message=\"provenance pool saturated ("), dropped, nscmdLiteral(" records dropped; canvas_limits.max_canvas_widget_provenance_records_per_view) - this widget's record may be among the dropped\"\n"));
  } else {
    parts.push(nscmdLiteral("provenance ok view="), view, nscmdLiteral(" id="), id, nscmdLiteral(" authored=zig message=\"no markup source: this widget was authored in Zig (the builder API) or synthesized by the engine - write-back edits markup files only, so find the ui.* call in the app's view code\"\n"));
  }
  r.done(); return nscmdText(parts);
}
