/** Runtime import-closure programs (108). Native supplies source loading,
 * tree storage and exact decimal position bytes. The program owns path
 * admission, graph order, cycle/dedupe/limit decisions and diagnostics.
 * All text remains raw bytes, including malformed UTF-8 and NULs.
 */
class NscImportReader {
  at: number = 4;
  readonly data: Uint8Array;
  readonly view: DataView;
  constructor(data: Uint8Array) { this.data = data; this.view = new DataView(data.buffer, data.byteOffset, data.byteLength); }
  number(): number {
    if (this.at + 8 > this.data.length) throw new Error("short import word");
    const n = this.view.getFloat64(this.at, true); this.at += 8;
    if (!Number.isSafeInteger(n) || n < 0) throw new Error("invalid import integer");
    return n;
  }
  blob(): Uint8Array {
    const n = this.number(); if (n > this.data.length - this.at) throw new Error("short import bytes");
    const out = this.data.subarray(this.at, this.at + n); this.at += n; return out;
  }
  done(): void { if (this.at !== this.data.length) throw new Error("trailing import bytes"); }
}
function nscimpEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
function nscimpLiteral(text: string): Uint8Array { return new TextEncoder().encode(text); }
function nscimpReply(stage: number, action: number, a: number = 0, b: number = 0, c: number = 0, payload: Uint8Array = new Uint8Array(0)): Uint8Array {
  const out = new Uint8Array(32 + payload.length), view = new DataView(out.buffer);
  out[0] = 108; out[1] = 1; out[2] = stage; out[3] = action;
  view.setFloat64(8, a, true); view.setFloat64(16, b, true); view.setFloat64(24, c, true); out.set(payload, 32); return out;
}
function nscimpShape(src: Uint8Array): number {
  if (src.length === 0) return 3;
  if (src.length > 200) return 4;
  if (src[0] === 47) return 5;
  for (const byte of src) if (byte === 58) return 5;
  for (const byte of src) if (byte === 92) return 6;
  const suffix = nscimpLiteral(".native");
  if (src.length < suffix.length || !nscimpEqual(src.subarray(src.length - suffix.length), suffix)) return 7;
  return 0;
}
function nscimpSegments(bytes: Uint8Array): Uint8Array[] {
  const parts: Uint8Array[] = []; let start = 0;
  for (let i = 0; i <= bytes.length; i++) if (i === bytes.length || bytes[i] === 47) {
    if (i > start) parts.push(bytes.subarray(start, i)); start = i + 1;
  }
  return parts;
}
function nscimpPath(stage: number, root: Uint8Array, importer: Uint8Array, src: Uint8Array, capacity: number): Uint8Array {
  const shape = nscimpShape(src); if (shape !== 0) return nscimpReply(stage, 1, shape);
  let slash = -1; for (let i = 0; i < importer.length; i++) if (importer[i] === 47) slash = i;
  const parts = nscimpSegments(importer.subarray(0, slash < 0 ? 0 : slash));
  if (parts.length > 24) return nscimpReply(stage, 1, 4);
  for (const part of nscimpSegments(src)) {
    if (part.length === 1 && part[0] === 46) continue;
    if (part.length === 2 && part[0] === 46 && part[1] === 46) {
      if (parts.length === 0) return nscimpReply(stage, 1, 8);
      parts.pop(); continue;
    }
    if (parts.length >= 24) return nscimpReply(stage, 1, 4);
    parts.push(part);
  }
  const prefix = importer.length > 0 && importer[0] === 47 ? importer.length > 1 && importer[1] === 47 ? 2 : 1 : 0;
  let length = prefix; for (let i = 0; i < parts.length; i++) length += parts[i]!.length + (i > 0 ? 1 : 0);
  if (length > capacity) return nscimpReply(stage, 1, 4);
  const path = new Uint8Array(length); let at = prefix;
  for (let i = 0; i < prefix; i++) path[i] = 47;
  for (let i = 0; i < parts.length; i++) { if (i > 0) path[at++] = 47; path.set(parts[i]!, at); at += parts[i]!.length; }
  if (root.length > 0) {
    if (path.length <= root.length || path[root.length] !== 47 || !nscimpEqual(path.subarray(0, root.length), root)) return nscimpReply(stage, 1, 8);
  }
  return nscimpReply(stage, 4, 0, 0, 0, path);
}
function nscimpChunks(parts: readonly Uint8Array[]): Uint8Array {
  let size = 0; for (const part of parts) size += 8 + part.length;
  const out = new Uint8Array(size), view = new DataView(out.buffer); let at = 0;
  for (const part of parts) { view.setFloat64(at, part.length, true); at += 8; out.set(part, at); at += part.length; }
  return out;
}
function nscimpFormatted(stage: number, format: string, parts: readonly Uint8Array[]): Uint8Array {
  // Preserve each writer call and its initial reservation, including the
  // final owned-slice shrink. A single copied message changes OOM behavior.
  return nscimpReply(stage, 15, parts.length, nscimpLiteral(format).length, 0, nscimpChunks(parts));
}
function nscvMarkupImports(input: Uint8Array): Uint8Array {
  if (input.length < 4 || input[0] !== 108 || input[1] !== 1 || input[2]! > 4 || input[3] !== 0) throw new Error("invalid import program request");
  const stage = input[2]!, r = new NscImportReader(input);
  if (stage === 0) {
    const root = r.blob(), importer = r.blob(), capacity = r.number(), children = r.number(), count = r.number();
    const names: Uint8Array[] = [], values: Uint8Array[] = [];
    for (let i = 0; i < count; i++) { names.push(r.blob()); values.push(r.blob()); } r.done();
    if (children > 0) return nscimpReply(stage, 3, 1);
    let found = false;
    let first: Uint8Array = new Uint8Array(0);
    for (let i = 0; i < count; i++) {
      if (!nscimpEqual(names[i]!, nscimpLiteral("src"))) return nscimpReply(stage, 2, 2, i);
      const code = nscimpShape(values[i]!); if (code !== 0) return nscimpReply(stage, 2, code, i);
      if (!found) first = values[i]!; found = true;
    }
    if (!found) return nscimpReply(stage, 1, 3);
    return nscimpPath(stage, root, importer, first, capacity);
  }
  if (stage === 1) {
    const path = r.blob(), depth = r.number(), files = r.number(), chainCount = r.number();
    if (depth >= 8 || chainCount !== depth + 1) throw new Error("invalid import chain");
    const chain: Uint8Array[] = []; let cycle = -1;
    for (let i = 0; i < chainCount; i++) { const link = r.blob(); chain.push(link); if (nscimpEqual(link, path)) cycle = i; }
    const count = r.number(); if (count > 32) throw new Error("invalid visited import count");
    let visited = false; for (let i = 0; i < count; i++) if (nscimpEqual(r.blob(), path)) visited = true; r.done();
    if (cycle >= 0) {
      const chunks: Uint8Array[] = [nscimpLiteral("import cycle: ")];
      for (let i = cycle; i < chain.length; i++) { chunks.push(chain[i]!); chunks.push(nscimpLiteral(" -> ")); }
      chunks.push(path); return nscimpReply(stage, 5, chunks.length, 0, 0, nscimpChunks(chunks));
    }
    if (visited) return nscimpReply(stage, 6);
    if (depth + 1 >= 8) return nscimpReply(stage, 1, 9);
    return nscimpReply(stage, files + 1 > 32 ? 8 : 7, files + 1);
  }
  if (stage === 2) {
    const phase = r.number(), cursor = r.number(), imports = r.number(), templates = r.number(), root = r.number(), depth = r.number(); r.done();
    if (phase > 2 || root > 1 || depth >= 8) throw new Error("invalid import visit state");
    if (phase === 0 && cursor < imports) return nscimpReply(stage, 9, cursor, 0, cursor + 1);
    const at = phase === 0 ? 0 : cursor;
    if (phase < 2 && at < templates) return nscimpReply(stage, 10, at, 1, at + 1);
    if (root === 0) return nscimpReply(stage, 13);
    return nscimpReply(stage, depth > 0 ? 11 : 12, depth > 0 ? 12 : 0);
  }
  if (stage === 3) {
    const count = r.number(), hasName = r.number(), name = r.blob();
    if (hasName > 1 || count > 256) throw new Error("invalid template state");
    let duplicate = false;
    let priorPath: Uint8Array = new Uint8Array(0), priorLine: Uint8Array = new Uint8Array(0), priorColumn: Uint8Array = new Uint8Array(0);
    for (let i = 0; i < count; i++) {
      const present = r.number(), existing = r.blob(), path = r.blob(), line = r.blob(), column = r.blob();
      if (present > 1) throw new Error("invalid template name flag");
      if (!duplicate && hasName === 1 && present === 1 && nscimpEqual(name, existing)) { duplicate = true; priorPath = path; priorLine = line; priorColumn = column; }
    } r.done();
    if (count >= 256) return nscimpReply(stage, 1, 11);
    if (duplicate) return nscimpFormatted(stage, 'duplicate template name "{s}" - also defined at {s}:{d}:{d}; template names are document-wide once imports resolve, so rename one (imports never shadow silently)', [nscimpLiteral('duplicate template name "'), name, nscimpLiteral('" - also defined at '), priorPath, nscimpLiteral(":"), priorLine, nscimpLiteral(":"), priorColumn, nscimpLiteral('; template names are document-wide once imports resolve, so rename one (imports never shadow silently)')]);
    return nscimpReply(stage, 14);
  }
  const path = r.blob(); r.done();
  return nscimpFormatted(stage, 'unable to read imported file "{s}"', [nscimpLiteral('unable to read imported file "'), path, nscimpLiteral('"')]);
}
