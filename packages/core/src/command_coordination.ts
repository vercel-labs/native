/** Command and status-item coordination over copied runtime facts. Native owns
 * registry storage, borrowed command strings, exact OS identities and execution.
 * Replies select native-owned rows/slots; no string or handle becomes a number.
 */
function nscvCommandSame(input: Uint8Array, first: number, firstLength: number, second: number, secondLength: number): boolean {
  if (firstLength !== secondLength) return false;
  for (let i = 0; i < firstLength; i++) if (input[first + i] !== input[second + i]) return false;
  return true;
}

function nscvCommandLiteral(input: Uint8Array, at: number, length: number, literal: readonly number[]): boolean {
  if (length !== literal.length) return false;
  for (let i = 0; i < length; i++) if (input[at + i] !== literal[i]) return false;
  return true;
}

export function nscvCommandCoordination(request: Uint8Array): Uint8Array {
  if (request.length < 8 || request[0] !== 69 || request[1]! > 5 || request[2] !== 0 || request[3] !== 0) throw new Error("invalid command coordination header");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const operation = request[1]!;
  if (operation === 5) {
    const count = wire.getUint32(4, true), entries: number[] = [];
    let at = 8;
    for (let slot = 0; slot < (count <= 256 ? count : 0); slot++) {
      if (at + 8 > request.length) throw new Error("truncated command catalog header");
      const idLength = wire.getUint32(at, true), titleLength = wire.getUint32(at + 4, true);
      entries.push(at); at += 8 + Math.min(idLength, 128) + Math.min(titleLength, 128);
      if (at > request.length) throw new Error("truncated command catalog bytes");
    }
    if (at !== request.length) throw new Error("trailing command catalog bytes");
    const result = new Uint8Array(4);
    if (count > 256) { result[0] = 1; return result; }
    for (let slot = 0; slot < entries.length; slot++) {
      const entry = entries[slot]!, idLength = wire.getUint32(entry, true), titleLength = wire.getUint32(entry + 4, true), idAt = entry + 8;
      if (idLength === 0 || idLength > 128) { result[0] = 1; return result; }
      if (nscvCommandLiteral(request, idAt, idLength, [46]) || nscvCommandLiteral(request, idAt, idLength, [46, 46])) { result[0] = 2; return result; }
      // Catalog admission keeps InvalidName distinct from dispatch's
      // InvalidCommand. The complete name scan precedes control-byte checks.
      for (let byte = 0; byte < idLength; byte++) if (request[idAt + byte] === 0 || request[idAt + byte] === 47 || request[idAt + byte] === 92) { result[0] = 2; return result; }
      for (let byte = 0; byte < idLength; byte++) if (request[idAt + byte] === 10 || request[idAt + byte] === 13 || request[idAt + byte] === 9) { result[0] = 1; return result; }
      if (titleLength > 128) { result[0] = 2; return result; }
      for (let byte = 0; byte < titleLength; byte++) if (request[idAt + idLength + byte] === 0) { result[0] = 2; return result; }
      for (let previous = 0; previous < slot; previous++) {
        const other = entries[previous]!;
        if (nscvCommandSame(request, idAt, idLength, other + 8, wire.getUint32(other, true))) { result[0] = 3; return result; }
      }
    }
    return result;
  }
  if (operation === 0 || operation === 4) {
    const length = wire.getUint32(4, true), limit = operation === 0 ? 128 : 64;
    if (request.length !== 8 + Math.min(length, limit)) throw new Error("invalid command text packet");
    const result = new Uint8Array(4);
    if (operation === 4) {
      result[0] = nscvCommandLiteral(request, 8, length, [109, 97, 105, 110]) ? 1 : 0;
      return result;
    }
    if (length === 0 || length > 128 || nscvCommandLiteral(request, 8, length, [46]) || nscvCommandLiteral(request, 8, length, [46, 46])) { result[0] = 1; return result; }
    for (let i = 8; i < request.length; i++) {
      const byte = request[i]!;
      if (byte === 0 || byte === 47 || byte === 92 || byte === 10 || byte === 13 || byte === 9) { result[0] = 1; return result; }
    }
    // app.check-for-updates is a reserved OS command. Unsupported execution
    // falls through to the app; other capability errors retain their identity.
    if (nscvCommandLiteral(request, 8, length, [97, 112, 112, 46, 99, 104, 101, 99, 107, 45, 102, 111, 114, 45, 117, 112, 100, 97, 116, 101, 115])) result[0] = 2;
    return result;
  }
  if (operation === 1) {
    if (request.length < 20) throw new Error("truncated command view header");
    const count = wire.getUint32(4, true), labelLength = wire.getUint32(16, true);
    if (count > 32) throw new Error("invalid command view count");
    let at = 20 + Math.min(labelLength, 64);
    if (at > request.length) throw new Error("truncated command view label");
    const entries: number[] = [];
    for (let i = 0; i < count; i++) {
      if (at + 16 > request.length) throw new Error("truncated command view facts");
      const flags = request[at]!, ownLength = request[at + 1]!, parentLength = request[at + 2]!;
      if (flags > 7 || ownLength > 64 || parentLength > 64 || request[at + 3] !== 0 || wire.getUint32(at + 12, true) !== 0 || ((flags & 4) === 0 && parentLength !== 0)) throw new Error("invalid command view facts");
      entries.push(at); at += 16 + ownLength + parentLength;
      if (at > request.length) throw new Error("truncated command view text");
    }
    if (at !== request.length) throw new Error("trailing command view bytes");
    const result = new Uint8Array(4); result[0] = 6; // native_view
    if (labelLength > 64) return result;
    let labelAt = 20, currentLength = labelLength;
    for (let depth = 0; depth < 32; depth++) {
      let found = -1;
      for (const entry of entries) {
        if ((request[entry]! & 1) !== 0 && nscvCommandSame(request, 8, 8, entry + 4, 8) && nscvCommandSame(request, labelAt, currentLength, entry + 16, request[entry + 1]!)) { found = entry; break; }
      }
      if (found < 0) return result;
      if ((request[found]! & 2) !== 0) { result[0] = 3; return result; } // toolbar
      if ((request[found]! & 4) === 0) return result;
      labelAt = found + 16 + request[found + 1]!; currentLength = request[found + 2]!;
    }
    return result;
  }
  if (operation === 2) {
    if (request.length < 12) throw new Error("truncated command menu header");
    const count = wire.getUint32(4, true), id = wire.getUint32(8, true);
    if (count > 32) throw new Error("invalid command menu count");
    const result = new Uint8Array(16), out = new DataView(result.buffer);
    out.setUint32(4, 0xffffffff, true); out.setUint32(8, 0xffffffff, true);
    let at = 12, queryDone = false, commandDone = false;
    for (let i = 0; i < count; i++) {
      if (at + 8 > request.length) throw new Error("truncated command menu row");
      const rowId = wire.getUint32(at, true), flags = request[at + 4]!, options = request[at + 5]!;
      if (flags > 15 || options > 8 || request[at + 6] !== 0 || request[at + 7] !== 0) throw new Error("invalid command menu row");
      if (!queryDone && rowId === id) {
        result[0] = 1; result[1] = (flags & 1) === 0 && (flags & 2) !== 0 && (flags & 4) !== 0 ? 1 : 0; queryDone = true;
      }
      if (!commandDone && rowId === id && (flags & 8) !== 0) { out.setUint32(4, i, true); commandDone = true; }
      at += 8;
      for (let option = 0; option < options; option++) {
        if (at + 8 > request.length || request[at + 4]! > 1 || request[at + 5] !== 0 || request[at + 6] !== 0 || request[at + 7] !== 0) throw new Error("invalid command menu option");
        if (wire.getUint32(at, true) === id) {
          if (!queryDone) { result[0] = 1; result[1] = request[at + 4]!; queryDone = true; }
          // Empty segmented commands are still the selected borrowed string.
          if (!commandDone) { out.setUint32(4, i, true); out.setUint32(8, option, true); commandDone = true; }
        }
        at += 8;
      }
    }
    if (at !== request.length) throw new Error("trailing command menu bytes");
    return result;
  }
  // Retained status-item lookup precedes admission's count check; active slots
  // and successful OS results remain in native storage between calls.
  if (request.length !== 80 || wire.getUint32(4, true) > 1 || wire.getUint32(12, true) > 8) throw new Error("invalid command status slots");
  const admission = wire.getUint32(4, true) === 1, id = wire.getUint32(8, true), used = wire.getUint32(12, true);
  const result = new Uint8Array(8), out = new DataView(result.buffer); out.setUint32(4, 0xffffffff, true);
  for (let slot = 0; slot < 8; slot++) {
    const at = 16 + slot * 8;
    if (request[at]! > 1 || request[at + 1] !== 0 || request[at + 2] !== 0 || request[at + 3] !== 0) throw new Error("invalid command status slot");
  }
  for (let slot = 0; slot < 8; slot++) if (request[16 + slot * 8] === 1 && wire.getUint32(20 + slot * 8, true) === id) { result[0] = 1; out.setUint32(4, slot, true); return result; }
  if (!admission) return result;
  if (used < 8) for (let slot = 0; slot < 8; slot++) if (request[16 + slot * 8] === 0) { result[0] = 2; out.setUint32(4, slot, true); return result; }
  result[0] = 3; return result;
}
