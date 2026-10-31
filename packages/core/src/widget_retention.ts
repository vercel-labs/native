/** Ordered rebuild collections and edge-triggered autofocus. Native supplies
 * copied widget facts and owns retained storage, text fingerprints and buffers.
 * Identities remain opaque eight-byte keys, including zero and max-u64. */
function nscvWidgetRetention(request: Uint8Array): Uint8Array {
  if (request.length < 24 || request[0] !== 92 || request[1]! > 6 || request[2] !== 0 || request[3] !== 0)
    throw new Error("invalid widget retention header");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const operation = request[1]!, count = wire.getUint32(4, true), sources = wire.getUint32(8, true);
  const capacity = wire.getUint32(12, true), states = wire.getUint32(16, true);
  if (count > 1024 || sources > 1024 || capacity > 1024 || states > 1024 || wire.getUint32(20, true) !== 0 ||
      request.length !== 24 + (count + sources) * 16 || (operation !== 5 && operation !== 6 && sources !== 0))
    throw new Error("invalid widget retention table");
  for (let i = 0; i < count + sources; i++) {
    const at = 24 + i * 16;
    if (request[at + 8]! > 62 || request[at + 9]! > 31 || request[at + 10] !== 0 || request[at + 11] !== 0)
      throw new Error("invalid widget retention fact");
    if (i >= count && (request[at + 9] !== 0 || wire.getUint32(at + 12, true) !== 0))
      throw new Error("invalid widget retention source");
  }
  const entries: number[] = [], matches: number[] = [], flags: number[] = [];
  let target = 4294967295;
  // Capacity bounds the copied prefix, but autofocus must scan the whole tree:
  // a newly requested target can occur beyond the tracked flag budget.
  for (let i = 0; i < count; i++) {
    const at = 24 + i * 16, kind = request[at + 8]!, fact = request[at + 9]!;
    const nonzero = wire.getUint32(at, true) !== 0 || wire.getUint32(at + 4, true) !== 0;
    const editable = kind >= 35 && kind <= 39;
    const exclusive = kind === 41 || kind === 42 || kind === 44 || kind === 46 || kind === 48;
    const control = exclusive || kind === 14 || kind === 16 || kind === 32 || kind >= 47 && kind <= 51;
    const admit = nonzero && (operation === 0 ? kind === 6 || kind === 57 :
      operation === 1 ? exclusive || kind === 14 || kind === 32 || kind === 51 :
      operation === 2 ? control : operation === 3 ? kind === 6 && i < states :
      operation === 4 ? editable : operation === 5 ? editable || kind === 26 && (fact & 6) === 6 :
      (fact & 1) !== 0);
    if (!admit) continue;
    if (operation !== 6 && entries.length >= capacity) break;
    let match = 4294967295;
    if (operation === 5 || operation === 6) {
      for (let j = 0; j < sources; j++) {
        const source = 24 + (count + j) * 16;
        if (wire.getUint32(at, true) === wire.getUint32(source, true) &&
            wire.getUint32(at + 4, true) === wire.getUint32(source + 4, true) &&
            (operation === 6 || kind === request[source + 8])) { match = j; break; }
      }
    }
    if (operation === 6 && target === 4294967295 && match === 4294967295) target = i;
    if (entries.length < capacity) {
      entries.push(i); matches.push(match);
      flags.push(((fact & 16) !== 0 || wire.getFloat32(at + 12, true) >= 0.5 ? 1 : 0) |
        (kind === 16 ? 2 : 0) | ((fact & 8) !== 0 ? 4 : 0));
    }
  }
  const output = new Uint8Array(16 + entries.length * 12), out = new DataView(output.buffer);
  output[0] = 92; output[1] = operation;
  out.setUint32(4, entries.length, true); out.setUint32(8, target, true);
  for (let i = 0; i < entries.length; i++) {
    out.setUint32(16 + i * 12, entries[i]!, true);
    out.setUint32(20 + i * 12, matches[i]!, true);
    out.setUint32(24 + i * 12, flags[i]!, true);
  }
  return output;
}
