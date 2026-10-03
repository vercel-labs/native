/** Portable decisions over native-owned timer tables.
 * Operations 0/1 reconcile subscriptions; 2 arms a delay, 3 looks up its key,
 * and 4 routes a one-shot completion and retires its slot. The cycle owns both
 * arenas; callers copy results without resetting bytes between records.
 */
export function native_timer_policy(request: Uint8Array): Uint8Array {
  if (request[0] === 2 || request[0] === 3) return delayDeclaration(request);
  if (request[0] === 4) {
    if (request.length !== 20 || request[1]! >= 16) throw new Error("invalid delay completion request");
    const slot = request[1]!;
    const used = new DataView(request.buffer, request.byteOffset, request.byteLength).getUint16(2, true);
    if ((used & (1 << slot)) === 0) throw new Error("delay completion slot is not armed");
    const result = new Uint8Array(2);
    result[0] = slot;
    result[1] = request[4 + slot]!;
    return result;
  }
  const data = new DataView(request.buffer, request.byteOffset, request.byteLength);
  if (request.length === 5 && request[0] === 1) {
    const used = data.getUint16(1, true), seen = data.getUint16(3, true);
    const result = new Uint8Array(2);
    new DataView(result.buffer).setUint16(0, used & ~seen, true);
    return result;
  }
  if (request.length < 13 || request[0] !== 0) throw new Error("invalid timer policy request");
  const seen = data.getUint16(1, true), keyLength = request[3]!;
  const valueAt = 4 + keyLength;
  if (valueAt + 9 > request.length) throw new Error("truncated timer policy declaration");
  const every = data.getFloat64(valueAt, true), tag = request[valueAt + 8]!;
  if (!(every >= 1 && every <= 31536000000)) throw new Error("timer interval must be between 1ms and one year");
  let at = valueAt + 9, matching = -1, free = -1, previous = 0;
  for (let slot = 0; slot < 16; slot++) {
    if (at + 2 > request.length) throw new Error("truncated timer policy table");
    const used = request[at]!, length = request[at + 1]!;
    at += 2;
    if (used > 1 || at + length + 8 > request.length) throw new Error("invalid timer policy slot");
    let equal = used === 1 && length === keyLength;
    for (let i = 0; i < length; i++) if (request[at + i] !== request[4 + i]) equal = false;
    const interval = data.getFloat64(at + length, true);
    if (used === 1 && !(interval >= 1 && interval <= 31536000000)) throw new Error("invalid timer policy interval");
    if (equal) { matching = slot; previous = interval; }
    if (used === 0 && free < 0) free = slot;
    at += length + 8;
  }
  if (at !== request.length) throw new Error("trailing timer policy bytes");
  const slot = matching >= 0 ? matching : free;
  if (slot < 0) throw new Error("more than 16 subscription timers");
  const result = new Uint8Array(14), output = new DataView(result.buffer);
  result[0] = slot;
  result[1] = matching < 0 || previous !== every ? 1 : 0;
  result[2] = tag;
  const whole = Math.floor(every);
  output.setFloat64(4, every - whole >= 0.5 ? whole + 1 : whole, true);
  output.setUint16(12, seen | (1 << slot), true);
  return result;
}

/** Delays match the first live key; empty keys always allocate when arming.
 * Each table record is [used, key length, key bytes, route]. Interval history
 * is unnecessary: every arm restarts even when its cadence and route agree.
 */
function delayDeclaration(request: Uint8Array): Uint8Array {
  if (request.length < 2) throw new Error("invalid delay policy request");
  const arm = request[0] === 2, keyLength = request[1]!;
  let at = 2 + keyLength;
  if (at + (arm ? 10 : 0) > request.length) throw new Error("truncated delay declaration");
  let after = 0, tag = 0, blocked = 0;
  if (arm) {
    after = new DataView(request.buffer, request.byteOffset, request.byteLength).getFloat64(at, true);
    tag = request[at + 8]!;
    if (!(after >= 1 && after <= 31536000000)) throw new Error("delay interval must be between 1ms and one year");
    blocked = request[at + 9]!;
    if (blocked > 1) throw new Error("invalid delay admission fact");
    at += 10;
  }
  let matching = -1, free = -1;
  for (let slot = 0; slot < 16; slot++) {
    if (at + 2 > request.length) throw new Error("truncated delay policy table");
    const used = request[at]!, length = request[at + 1]!;
    at += 2;
    if (used > 1 || at + length + 1 > request.length) throw new Error("invalid delay policy slot");
    let equal = used === 1 && length === keyLength;
    for (let i = 0; i < length; i++) if (request[at + i] !== request[2 + i]) equal = false;
    if (equal && matching < 0) matching = slot;
    if (used === 0 && free < 0) free = slot;
    at += length + 1;
  }
  if (at !== request.length) throw new Error("trailing delay policy bytes");
  if (!arm) {
    const result = new Uint8Array(1);
    result[0] = matching < 0 ? 255 : matching;
    return result;
  }
  const slot = blocked === 1 ? 255 : keyLength > 0 && matching >= 0 ? matching : free;
  if (slot < 0) throw new Error("more than 16 armed delays");
  const result = new Uint8Array(10);
  result[0] = slot;
  result[1] = tag;
  const whole = Math.floor(after);
  new DataView(result.buffer).setFloat64(2, after - whole >= 0.5 ? whole + 1 : whole, true);
  return result;
}

/** Live-query reconciliation over a native-owned database table. Operation 0
 * finds a key, 1 retains declared live keys before allocation, and 2 plans one
 * declaration. Fingerprints are opaque bytes: preserve the reference host's
 * equality semantics without rounding its 64-bit hash through a JS number.
 * Inputs are borrowed; the host copies results and owns the cycle reset.
 */
export function native_db_policy(request: Uint8Array): Uint8Array {
  if (request.length < 2 || request[0]! > 2) throw new Error("invalid database policy request");
  const op = request[0]!;
  const data = new DataView(request.buffer, request.byteOffset, request.byteLength);
  let keyStart = 2, keyLength = request[1]!, tableStart = keyStart + keyLength;
  let keysEnd = 0, seen = 0, signatureAt = 0;
  if (op === 1) {
    if (request.length < 5) throw new Error("truncated database retention request");
    keysEnd = 5 + data.getUint32(1, true);
    if (keysEnd > request.length) throw new Error("truncated database retention request");
    tableStart = keysEnd;
    let at = 5;
    while (at < keysEnd) {
      const length = request[at]!;
      if (length === 0 || at + 1 + length > keysEnd) throw new Error("invalid live-query key list");
      at += 1 + length;
    }
  } else if (op === 2) {
    if (request.length < 4) throw new Error("truncated database declaration request");
    seen = data.getUint16(1, true);
    keyLength = request[3]!;
    keyStart = 4;
    signatureAt = keyStart + keyLength;
    tableStart = signatureAt + 11;
    if (keyLength === 0) throw new Error("a live query requires a non-empty subscription key");
  }
  if (tableStart > request.length) throw new Error("truncated database policy request");
  const offsets = new Uint8Array(64);
  const positions = new DataView(offsets.buffer);
  let at = tableStart, free = -1;
  for (let slot = 0; slot < 16; slot++) {
    if (at + 3 > request.length) throw new Error("truncated database policy table");
    const used = request[at]!, live = request[at + 1]!, length = request[at + 2]!;
    if (used > 1 || live > 1 || at + 11 + length > request.length) throw new Error("invalid database policy slot");
    positions.setUint32(slot * 4, at, true);
    if (used === 0 && free < 0) free = slot;
    at += 11 + length;
  }
  if (at !== request.length) throw new Error("trailing database policy bytes");
  if (op === 1) {
    let retained = 0;
    for (let keyAt = 5; keyAt < keysEnd; keyAt += 1 + request[keyAt]!) {
      const slot = dbPolicyLookup(request, positions, keyAt + 1, request[keyAt]!);
      if (slot >= 0 && request[positions.getUint32(slot * 4, true) + 1] === 1) retained |= 1 << slot;
    }
    const result = new Uint8Array(2);
    new DataView(result.buffer).setUint16(0, retained, true);
    return result;
  }
  const matching = dbPolicyLookup(request, positions, keyStart, keyLength);
  if (op === 0) {
    const result = new Uint8Array(1);
    result[0] = matching < 0 ? 255 : matching;
    return result;
  }
  const slot = matching >= 0 ? matching : free;
  if (slot < 0) throw new Error("database slot family is full");
  const entry = positions.getUint32(slot * 4, true), used = request[entry] === 1;
  if (used && request[entry + 1] !== 1) throw new Error("a live-query key collides with an in-flight database command");
  if ((seen & (1 << slot)) !== 0) throw new Error("duplicate live-query subscription key");
  let changed = !used;
  const storedSignature = entry + 3 + request[entry + 2]!;
  for (let i = 0; i < 8; i++) if (request[signatureAt + i] !== request[storedSignature + i]) changed = true;
  const result = new Uint8Array(8);
  result[0] = slot;
  result[1] = changed ? 1 : 0;
  result[2] = used && changed ? 1 : 0;
  result[3] = request[signatureAt + 8]!;
  result[4] = request[signatureAt + 9]!;
  result[5] = request[signatureAt + 10]!;
  new DataView(result.buffer).setUint16(6, seen | (1 << slot), true);
  return result;
}

function dbPolicyLookup(request: Uint8Array, positions: DataView, keyStart: number, keyLength: number): number {
  if (keyLength === 0) return -1;
  for (let slot = 0; slot < 16; slot++) {
    const at = positions.getUint32(slot * 4, true);
    if (request[at] !== 1 || request[at + 2] !== keyLength) continue;
    let equal = true;
    for (let i = 0; i < keyLength; i++) if (request[at + 3 + i] !== request[keyStart + i]) equal = false;
    if (equal) return slot;
  }
  return -1;
}
