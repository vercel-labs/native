/** Window set reconciliation over ordered native-owned slots. Operation 0
 * selects the first stale slot; the caller removes it (swapping the last slot)
 * and asks again before creating anything. Operation 1 handles one descriptor
 * against the current table, so failed OS creates never reserve an identity.
 * Labels are opaque bytes. Existing labels only update the owned close message;
 * their creation-time canvas, title, geometry and close policy stay fixed.
 */
export function native_window_policy(request: Uint8Array): Uint8Array {
  const data = new DataView(request.buffer, request.byteOffset, request.byteLength);
  let at = 0;
  const byte = (): number => {
    if (at >= request.length) throw new Error("truncated window policy request");
    return request[at++]!;
  };
  const label = (): Uint8Array => {
    if (at + 4 > request.length) throw new Error("truncated window policy label");
    const length = data.getUint32(at, true); at += 4;
    if (length > request.length - at) throw new Error("truncated window policy label");
    const value = request.subarray(at, at + length); at += length; return value;
  };
  const equal = (a: Uint8Array, b: Uint8Array): boolean => {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
  };
  const operation = byte();
  if (operation > 1) throw new Error("invalid window policy operation");
  const declared: Uint8Array[] = [];
  let main: Uint8Array = new Uint8Array(0), name: Uint8Array = new Uint8Array(0), canvas: Uint8Array = new Uint8Array(0);
  if (operation === 0) {
    const count = byte();
    if (count > 4) throw new Error("invalid window declaration count");
    for (let i = 0; i < count; i++) declared.push(label());
  } else { main = label(); name = label(); canvas = label(); }
  const count = byte();
  if (count > 4) throw new Error("invalid live window count");
  const names: Uint8Array[] = [], canvases: Uint8Array[] = [];
  for (let i = 0; i < count; i++) { names.push(label()); canvases.push(label()); }
  if (at !== request.length) throw new Error("trailing window policy bytes");
  const result = new Uint8Array(2); result[1] = 255;
  if (operation === 0) {
    for (let i = 0; i < count; i++) {
      let keep = false;
      for (const candidate of declared) if (equal(candidate, names[i]!)) keep = true;
      if (!keep) { result[1] = i; break; }
    }
    return result;
  }
  // Lookup precedes admission: duplicate descriptors update the same slot
  // even when the table is full or their later creation fields are invalid.
  for (let i = 0; i < count; i++) if (equal(name, names[i]!)) {
    result[0] = 1; result[1] = i; return result;
  }
  if (count === 4) { result[0] = 2; return result; }
  if (name.length === 0 || name.length > 64 || canvas.length === 0 || canvas.length > 64) {
    result[0] = 3; return result;
  }
  let collision = equal(canvas, main);
  for (const value of canvases) if (equal(canvas, value)) collision = true;
  if (collision) result[0] = 4;
  return result;
}

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

/** Named buffered effects over native-owned slots. Admission returns both the
 * predecessor to drop and the first free slot: dropping precedes capacity
 * refusal, and a dropped predecessor stays occupied until its terminal drains.
 * Completion selects a route/payload and retires one slot. This pure callback
 * neither mutates its borrowed input nor resets the dispatch frame.
 */
export function native_effect_policy(request: Uint8Array): Uint8Array {
  if (request.length < 2 || request[0]! > 2) throw new Error("invalid effect policy request");
  if (request[0] === 2) {
    if (request.length !== 69 || request[1]! >= 16 || request[2]! > 3 || request[3]! > 1 || request[4]! > 1)
      throw new Error("invalid effect completion request");
    for (let at = 5; at < request.length; at += 4)
      if (request[at]! > 1 || request[at + 1]! > 1) throw new Error("invalid effect completion slot");
    const slot = request[1]!, at = 5 + slot * 4;
    if (request[at] !== 1) throw new Error("effect completion slot is not tracked");
    const result = new Uint8Array(4);
    result[0] = slot;
    if (request[at + 1] === 1) {
      result[1] = request[at + 3]!;
      return result; // Swallow; the inert stand-in uses the error arm.
    }
    const cut = request[2] === 3 && request[4] === 1;
    const success = request[3] === 1 && !cut;
    result[1] = request[at + (success ? 2 : 3)]!;
    result[2] = success ? request[2]! + 1 : 5;
    result[3] = success ? 0 : request[3] === 1 && cut ? 2 : 1;
    return result;
  }
  const arm = request[0] === 0, length = request[1]!;
  let at = 2 + length;
  if (at + (arm ? 3 : 0) > request.length) throw new Error("truncated effect declaration");
  let blocked = 0, ok = 0, err = 0;
  if (arm) {
    blocked = request[at]!; ok = request[at + 1]!; err = request[at + 2]!;
    if (blocked > 1) throw new Error("invalid effect admission fact");
    at += 3;
  }
  let matching = -1, free = -1;
  for (let slot = 0; slot < 16; slot++) {
    if (at + 3 > request.length) throw new Error("truncated effect policy table");
    const used = request[at]!, dropped = request[at + 1]!, size = request[at + 2]!;
    if (used > 1 || dropped > 1 || at + 5 + size > request.length) throw new Error("invalid effect policy slot");
    let equal = used === 1 && dropped === 0 && size === length;
    for (let i = 0; i < size; i++) if (request[at + 3 + i] !== request[2 + i]) equal = false;
    if (equal && matching < 0) matching = slot;
    if (used === 0 && free < 0) free = slot;
    at += 5 + size;
  }
  if (at !== request.length) throw new Error("trailing effect policy bytes");
  if (!arm) {
    const result = new Uint8Array(1);
    result[0] = matching < 0 ? 255 : matching;
    return result;
  }
  const result = new Uint8Array(5);
  result[0] = blocked === 0 ? 1 : 0;
  result[1] = blocked === 1 || free < 0 ? 255 : free;
  result[2] = blocked === 1 || length === 0 || matching < 0 ? 255 : matching;
  result[3] = ok; result[4] = err;
  return result;
}
