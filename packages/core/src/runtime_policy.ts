/** Status-item reconciliation over eight native-owned slots. Operations 0/1
 * return retirement masks or ordered admission decisions. Operation 2 compares
 * three opaque eight-byte hashes independently; no hash crosses as a number.
 * Native applies OS results before the next admission, owns capability failures
 * and retains frame lifetime until all borrowed commands have been consumed.
 */
export function native_status_policy(request: Uint8Array): Uint8Array {
  const result = new Uint8Array(2); result[1] = 255;
  if (request[0] === 2) {
    if (request.length !== 49) throw new Error("invalid status patch request");
    for (let field = 0; field < 3; field++) {
      let changed = false;
      for (let byte = 0; byte < 8; byte++) {
        if (request[1 + field * 8 + byte] !== request[25 + field * 8 + byte]) changed = true;
      }
      if (changed) result[0] = result[0]! | (1 << field);
    }
    return result;
  }
  if (request.length < 44 || (request[0] !== 0 && request[0] !== 1)) throw new Error("invalid status policy request");
  const operation = request[0]!, index = request[1]!, count = request[2]!, appliedCount = request[3]!;
  if (count > 8 || appliedCount > 8 || request.length !== 44 + count * 4 || (operation === 1 && index >= count)) {
    throw new Error("invalid status declaration table");
  }
  const data = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const ids: number[] = [];
  for (let i = 0; i < count; i++) ids.push(data.getUint32(4 + i * 4, true));
  const active: boolean[] = [], stored: number[] = [];
  for (let slot = 0; slot < 8; slot++) {
    const at = 4 + count * 4 + slot * 5;
    if (request[at]! > 1) throw new Error("invalid status slot");
    active.push(request[at] === 1); stored.push(data.getUint32(at + 1, true));
  }
  if (operation === 0) {
    for (let slot = 0; slot < 8; slot++) {
      let keep = false;
      for (const id of ids) if (id === stored[slot]) keep = true;
      if (active[slot] && !keep) result[0] = result[0]! | (1 << slot);
    }
    return result;
  }
  const id = ids[index]!;
  if (id === 0) return result;
  for (let i = 0; i < index; i++) if (ids[i] === id) return result;
  // Retained lookup precedes the count guard and first-free admission.
  for (let slot = 0; slot < 8; slot++) if (active[slot] && stored[slot] === id) {
    result[0] = 3; result[1] = slot; return result;
  }
  if (appliedCount < 8) for (let slot = 0; slot < 8; slot++) if (!active[slot]) {
    result[0] = 2; result[1] = slot; return result;
  }
  result[0] = 1; return result;
}

/** Portable stock-theme decisions. Native retains owned token registers, OS
 * appearance facts and surface scale. Results are copied without resetting
 * the dispatch arena: a theme helper may still own borrowed accent bytes.
 * Operations: 0 exact #rrggbb parsing; 1 pack/scheme/accent resolution;
 * 2 complete-token precedence and appearance/rebuild coordination.
 */
export function native_theme_policy(request: Uint8Array): Uint8Array {
  const result = new Uint8Array(4);
  if (request[0] === 0) {
    if (request.length !== 8 || request[1] !== 35) return result;
    for (let channel = 0; channel < 3; channel++) {
      const hi = themeHexNibble(request[2 + channel * 2]!);
      const lo = themeHexNibble(request[3 + channel * 2]!);
      if (hi < 0 || lo < 0) return new Uint8Array(4);
      result[channel + 1] = hi * 16 + lo;
    }
    result[0] = 1;
    return result;
  }
  if (request[0] === 1) {
    if (request.length !== 8 || request[1]! > 2 || request[2]! < 1 || request[2]! > 2 || request[3]! > 2) {
      throw new Error("invalid stock theme request");
    }
    for (let i = 4; i < 8; i++) if (request[i]! > 1) throw new Error("invalid theme appearance flag");
    result[0] = request[1] === 0 ? request[2]! : request[1]!;
    result[1] = request[3] === 0 ? request[4]! : request[3]! - 1;
    result[2] = request[5] === 1 ? 0 : request[6] === 1 ? 1 : request[7] === 1 ? 2 : 0;
    return result;
  }
  if (request[0] === 2) {
    if ((request.length !== 5 && request.length !== 6) || request[4]! > 2 || (request.length === 6 && request[5]! > 1)) throw new Error("invalid theme control request");
    for (let i = 1; i < 4; i++) if (request[i]! > 1) throw new Error("invalid theme control flag");
    result[0] = request[1] === 1 ? 1 : request[2] === 1 ? 2 : 0;
    result[1] = result[0] === 0 && (request[3] === 0 || request[4] === 0) ? 1 : 0;
    const overrides = request.length === 6 && request[5] === 1;
    result[2] = request[1] === 1 || request[3] === 1 || result[1] === 1 || overrides ? 1 : 0;
    return result;
  }
  throw new Error("unknown theme policy operation");
}

function themeHexNibble(byte: number): number {
  if (byte >= 48 && byte <= 57) return byte - 48;
  if (byte >= 65 && byte <= 70) return byte - 65 + 10;
  if (byte >= 97 && byte <= 102) return byte - 97 + 10;
  return -1;
}

/** An engine identity remains two exact words. Only a bounded table offset
 * becomes a number; adjacent namespaces and max-u64 must never alias a slot.
 */
function completionSlot(request: Uint8Array, keyAt: number, baseAt: number): number {
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const keyLower = wire.getUint32(keyAt, true), keyUpper = wire.getUint32(keyAt + 4, true);
  const baseLower = wire.getUint32(baseAt, true), baseUpper = wire.getUint32(baseAt + 4, true);
  if (keyUpper < baseUpper || keyUpper === baseUpper && keyLower < baseLower)
    throw new Error("completion outside key namespace");
  const difference = keyLower - baseLower;
  const upper = keyUpper - baseUpper - (difference < 0 ? 1 : 0);
  const slot = difference < 0 ? difference + 4294967296 : difference;
  if (upper !== 0 || slot >= 16) throw new Error("completion outside owner table");
  return slot;
}

/** Buffered callbacks (17): legacy file, complete file, buffered fetch and
 * clipboard read. A 24-byte header carries family, operation, outcome,
 * truncation and exact key/base words; sixteen records hold used/dropped and
 * the two routes. The eight-byte plan owns slot, route, payload, reason,
 * retirement and silent-drop decisions. Native copies borrowed payloads.
 */
function bufferedCompletionPolicy(request: Uint8Array): Uint8Array {
  if (request.length !== 88 || request[1]! > 3 || request[4]! > 1 || request[5] !== 0 || request[6] !== 0 || request[7] !== 0)
    throw new Error("invalid buffered completion header");
  const family = request[1]!, operation = request[2]!, outcome = request[3]!;
  if (family <= 1 ? operation > 8 || outcome > 8 : operation !== 0 || outcome > (family === 2 ? 6 : 3))
    throw new Error("invalid buffered completion enum");
  for (let at = 24; at < 88; at += 4)
    if (request[at]! > 1 || request[at + 1]! > 1) throw new Error("invalid buffered completion slot");
  const slot = completionSlot(request, 8, 16), owner = 24 + slot * 4;
  if (request[owner] !== 1) throw new Error("buffered completion owner is not tracked");
  const result = new Uint8Array(8);
  result[0] = slot; result[4] = 1;
  const dropped = request[owner + 1] === 1;
  if (family === 1) {
    result[1] = request[owner + (dropped ? 3 : 2)]!;
    result[2] = 6; result[5] = dropped ? 1 : 0;
    return result;
  }
  if (dropped) { result[1] = request[owner + 3]!; result[5] = 1; return result; }
  const cut = family === 2 && request[4] === 1;
  const success = outcome === 0 && !cut;
  result[1] = request[owner + (success ? 2 : 3)]!;
  result[2] = success ? family === 2 ? 4 : family === 3 || operation === 0 ? 2 : operation === 3 ? 3 : 1 : 5;
  result[3] = success ? 0 : outcome === 0 && cut ? 2 : 1;
  return result;
}

/** Timer callbacks (7): delay or subscription, outcome, exact key/timestamp/
 * base words, then sixteen used/full-result/mode/route records. The complete
 * 40-byte plan returns slot, route, payload, retirement, exact decimal
 * timestamp and the legacy fractional-millisecond value. Subscription fires
 * intentionally retain the old queued-fire behavior for an unused slot.
 */
function timerCompletionPolicy(request: Uint8Array): Uint8Array {
  if (request.length !== 96 || request[1]! > 1 || request[2]! > 1 || request[3] !== 0)
    throw new Error("invalid timer completion header");
  for (let i = 28; i < 32; i++) if (request[i] !== 0) throw new Error("invalid timer completion reserved byte");
  for (let at = 32; at < 96; at += 4)
    if (request[at]! > 1 || request[at + 1]! > 1 || request[at + 2]! > 1) throw new Error("invalid timer completion slot");
  const subscription = request[1] === 1, rejected = request[2] === 1;
  if (subscription && rejected) throw new Error("platform rejected subscription timer");
  const slot = completionSlot(request, 4, 20), owner = 32 + slot * 4;
  if (!subscription && request[owner] !== 1) throw new Error("delay completion owner is not armed");
  const full = !subscription && request[owner + 1] === 1;
  if (!subscription && !full && rejected) throw new Error("platform rejected legacy delay");
  const result = new Uint8Array(40), wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  result[0] = slot; result[1] = request[owner + 3]!; result[2] = full ? 1 : 0;
  result[3] = !subscription && (!full || request[owner + 2] === 0 || rejected) ? 1 : 0;
  let lower = wire.getUint32(12, true), upper = wire.getUint32(16, true);
  new DataView(result.buffer).setFloat64(8, (upper * 4294967296 + lower) / 1000000, true);
  const reversed = new Uint8Array(20);
  let length = 0;
  do {
    const quotientUpper = Math.floor(upper / 10);
    const combined = (upper - quotientUpper * 10) * 4294967296 + lower;
    const quotientLower = Math.floor(combined / 10);
    reversed[length++] = 48 + combined - quotientLower * 10;
    upper = quotientUpper; lower = quotientLower;
  } while (upper !== 0 || lower !== 0);
  result[4] = length;
  for (let i = 0; i < length; i++) result[16 + i] = reversed[length - i - 1]!;
  return result;
}

/** Window set reconciliation over ordered native-owned slots. Operation 0
 * selects the first stale slot; the caller removes it (swapping the last slot)
 * and asks again before creating anything. Operation 1 handles one descriptor
 * against the current table, so failed OS creates never reserve an identity.
 * Labels are opaque bytes. Existing labels only update the owned close message;
 * their creation-time canvas, title, geometry and close policy stay fixed.
 */
export function native_window_policy(request: Uint8Array): Uint8Array {
  if (request[0] === 2) return nscvShellLayout(request);
  if (request[0] === 3) return nscvSurfaceLayout(request);
  if (request[0] === 4) return nscvGridLayout(request);
  if (request[0] === 5) return nscvContainerLayout(request);
  if (request[0] === 6) return nscvIntrinsicLayout(request);
  if (request[0] === 7) return nscvWrappedLayout(request);
  if (request[0] === 8) return nscvVirtualFlow(request);
  if (request[0] === 9) return nscvSemanticTree(request);
  if (request[0] === 10) return nscvExtentPolicy(request);
  if (request[0] === 11) return nscvTextCachePolicy(request);
  if (request[0] === 12) return nscvRenderCachePolicy(request);
  if (request[0] === 13) return nscvRenderPlanPolicy(request);
  if (request[0] === 14) return nscvRenderOverridePolicy(request);
  if (request[0] === 15) return nscvRenderDamagePolicy(request);
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
  if (request[0] === 7) return timerCompletionPolicy(request);
  if (request[0] === 2 || request[0] === 3 || request[0] === 6) return delayDeclaration(request);
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
  const rejectable = request[0] === 6;
  const arm = request[0] === 2 || rejectable, keyLength = request[1]!;
  let at = 2 + keyLength;
  if (at + (arm ? 10 : 0) > request.length) throw new Error("truncated delay declaration");
  let after = 0, tag = 0, blocked = 0;
  if (arm) {
    after = new DataView(request.buffer, request.byteOffset, request.byteLength).getFloat64(at, true);
    tag = request[at + 8]!;
    if (!(after >= 1 && after <= 31536000000)) {
      if (!rejectable) throw new Error("delay interval must be between 1ms and one year");
      blocked = 1;
    }
    const externalBlocked = request[at + 9]!;
    blocked = Math.max(blocked, externalBlocked);
    if (externalBlocked > 1) throw new Error("invalid delay admission fact");
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
  if (slot < 0 && !rejectable) throw new Error("more than 16 armed delays");
  const result = new Uint8Array(10);
  result[0] = slot < 0 ? 255 : slot;
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
  if (request.length < 2 || request[0]! > 17) throw new Error("invalid effect policy request");
  if (request[0] === 17) return bufferedCompletionPolicy(request);
  if (request[0] === 15) return fileStreamPolicy(request);
  if (request[0] === 16) return clipboardWritePolicy(request);
  if (request[0] === 11) return requestCoordinationPolicy(request);
  if (request[0] === 12) return cancellationPolicy(request);
  if (request[0] === 13) return credentialRecordPolicy(request);
  if (request[0] === 14) return dbCommandPolicy(request);
  if (request[0] === 8) return playbackLoadPolicy(request);
  if (request[0] === 9) return ptyCoordinationPolicy(request);
  if (request[0] === 10) return playbackEventPolicy(request);
  if (request[0] === 6) return mediaTransportPolicy(request);
  if (request[0]! >= 3) return mediaSlotPolicy(request);
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

/** Media lifecycle operations share the effect ABI and borrow native-owned
 * tables. 3 admits a numeric owner; 4 resolves a numeric control; 5 routes and
 * retires a complete event; 7 performs an opaque u64 lookup. Header: operation,
 * family (image/channel/capture), count, event, tag, source, channels, reserved,
 * key (f64 for 3/4, opaque u64 otherwise), u32 rate, f64 expected bytes. Slots:
 * used, opaque u64 key, tag, source, u32 rate, channels. Results are owned bytes;
 * keys/tokens never pass through a lossy floating-point conversion.
 */
function mediaSlotPolicy(request: Uint8Array): Uint8Array {
  if (request.length < 28 || ![3, 4, 5, 7].includes(request[0]!)) throw new Error("invalid media slot operation");
  const operation = request[0]!, family = request[1]!, count = request[2]!;
  if (family > 2 || count > (family === 0 ? 16 : 8) || request.length !== 28 + count * 16 || request[7] !== 0 || request[5]! > 1)
    throw new Error("invalid media slot request");
  if (operation === 5 && (family === 0 ? request[3] !== 0 : family === 1 ? request[3]! > 2 : request[3]! > 4))
    throw new Error("invalid media event kind");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const result = new Uint8Array(28), out = new DataView(result.buffer);
  result[1] = 255; result[2] = request[4]!; result[4] = request[5]!; result[5] = request[6]!;
  out.setUint32(24, wire.getUint32(16, true), true);
  const numberKey = operation === 3 || operation === 4;
  const key = wire.getFloat64(8, true);
  const valid = !numberKey || Number.isFinite(key) && key >= 1 && key < 9007199254740992 && Math.floor(key) === key;
  result[0] = valid ? 1 : 0;
  if (valid) for (let i = 0; i < 8; i++) result[8 + i] = request[8 + i]!;
  // f64 wire keys become exact u64 words only after the representability gate.
  if (numberKey && valid) {
    out.setUint32(8, key % 4294967296, true); out.setUint32(12, Math.floor(key / 4294967296), true);
  }
  const expected = wire.getFloat64(20, true);
  if (Number.isFinite(expected) && expected >= 1 && expected < 9007199254740992 && Math.floor(expected) === expected) {
    out.setUint32(16, expected % 4294967296, true); out.setUint32(20, Math.floor(expected / 4294967296), true);
  }
  let matching = -1, free = -1;
  for (let slot = 0; slot < count; slot++) {
    const at = 28 + slot * 16;
    if (request[at]! > 1 || request[at + 10]! > 1) throw new Error("invalid media slot fact");
    let equal = valid && request[at] === 1;
    for (let i = 0; i < 8; i++) if (request[at + 1 + i] !== result[8 + i]) equal = false;
    if (equal && matching < 0) matching = slot;
    if (request[at] === 0 && free < 0) free = slot;
  }
  if (operation === 3) {
    const rate = wire.getUint32(16, true), channels = request[6]!;
    const format = family !== 2 || (rate === 16000 || rate === 24000 || rate === 48000) && (channels === 1 || channels === 2);
    if (valid && format && matching < 0 && free >= 0) result[1] = free;
    return result;
  }
  if (matching < 0) {
    if (operation === 5) throw new Error("media event has no tracked owner");
    return result;
  }
  result[1] = matching;
  const at = 28 + matching * 16;
  result[2] = request[at + 9]!;
  if (operation === 5) {
    result[3] = family === 0 || family === 1 && request[3] !== 0 || family === 2 && request[3]! >= 3 ? 1 : 0;
    if (family === 2) {
      result[4] = request[at + 10]!;
      if (request[6] === 0) result[5] = request[at + 15]!;
      if (wire.getUint32(16, true) === 0) out.setUint32(24, wire.getUint32(at + 11, true), true);
    }
  }
  return result;
}

/** Operation 6 plans playback controls from opaque key equality and native
 * ownership facts (foreign/owned/idle). Native retains exact owner tokens,
 * stops only the named token, and applies OS calls in command order. Result:
 * action (255 = no-op), retirement, re-key, reserved, scalar f64.
 */
function mediaTransportPolicy(request: Uint8Array): Uint8Array {
  if (request.length < 15 || request[1]! > 1 || request[2]! > 1 || request[3]! > 2 || request.length !== 15 + request[5]! + request[6]!)
    throw new Error("invalid media transport request");
  const result = new Uint8Array(12); result[0] = 255;
  const video = request[1] === 1, verb = request[4]!;
  let matches = request[2] === 1 && request[5] === request[6];
  if (matches) for (let i = 0; i < request[5]!; i++) if (request[15 + i] !== request[15 + request[5]! + i]) matches = false;
  if (!matches) return result;
  // Stop cancels this stream's staged results even after a foreign replacement.
  // Volume may update a remembered preference while the channel is idle.
  if (video && verb !== 2 && request[3] !== 1 && !(verb === 4 && request[3] === 2)) return result;
  if (verb > (video ? 7 : 4)) throw new Error("unknown media transport verb");
  result[0] = verb; result[1] = verb === 2 ? 1 : 0; result[2] = video && verb === 7 ? 1 : 0;
  for (let i = 0; i < 8; i++) result[4 + i] = request[7 + i]!;
  const value = new DataView(request.buffer, request.byteOffset, request.byteLength).getFloat64(7, true);
  const out = new DataView(result.buffer);
  if (verb === 3) {
    const seek = value >= 0 && value <= 9007199254740992 ? Math.trunc(value) : video && value > 9007199254740992 && Number.isFinite(value) ? 9007199254740991 : 0;
    out.setFloat64(4, seek === 0 ? 0 : seek, true);
  }
  else if (video && (verb === 5 || verb === 6)) out.setFloat64(4, value !== 0 ? 1 : 0, true);
  return result;
}

/** Playback load preparation (8): family, route, flags, four reserved bytes,
 * f64 size/surface, u32 path length, u32 URL length, then at most 1024 URL bytes.
 * Audio intentionally truncates sizes and admits 2^53. Video preserves the
 * native URI grammar, including opaque paths and permissive authorities.
 * Results own admission, route, flags and exact u64 surface/size words.
 */
function playbackLoadPolicy(request: Uint8Array): Uint8Array {
  if (request.length < 24 || request[1]! > 1) throw new Error("invalid playback load request");
  for (let i = 4; i < 8; i++) if (request[i] !== 0) throw new Error("invalid playback load reserved byte");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const pathLength = wire.getUint32(16, true), urlLength = wire.getUint32(20, true);
  if (request.length !== 24 + Math.min(urlLength, 1024)) throw new Error("invalid playback URL length");
  const result = new Uint8Array(24), out = new DataView(result.buffer);
  result[1] = request[2]!; result[2] = request[3]! & 7;
  const value = wire.getFloat64(8, true);
  if (request[1] === 0) {
    result[0] = 1;
    if (value >= 1 && value <= 9007199254740992) {
      const size = Math.trunc(value);
      out.setUint32(16, size % 4294967296, true); out.setUint32(20, Math.floor(size / 4294967296), true);
    }
  } else {
    if (value >= 1 && value < 9007199254740992 && Math.floor(value) === value) {
      out.setUint32(8, value % 4294967296, true); out.setUint32(12, Math.floor(value / 4294967296), true);
      if ((pathLength !== 0 || urlLength !== 0) && pathLength <= 1024 && urlLength <= 1024 &&
          (urlLength === 0 || playbackHttpUri(request.subarray(24)))) result[0] = 1;
    }
  }
  return result;
}

// Match std.Uri.parse's HTTP(S) acceptance over bytes, without URL canonicalization.
function playbackHttpUri(url: Uint8Array): boolean {
  let colon = -1;
  for (let i = 0; i < url.length; i++) if (url[i] === 58) { colon = i; break; }
  if (colon !== 4 && colon !== 5) return false;
  const scheme = [104, 116, 116, 112, 115];
  for (let i = 0; i < colon; i++) {
    const byte = url[i]!;
    if ((byte >= 65 && byte <= 90 ? byte + 32 : byte) !== scheme[i]) return false;
  }
  const start = colon + 1;
  if (start + 1 >= url.length || url[start] !== 47 || url[start + 1] !== 47) return true;
  const authorityStart = start + 2;
  let end = authorityStart;
  while (end < url.length && url[end] !== 47 && url[end] !== 63 && url[end] !== 35) end++;
  if (end === authorityStart) return authorityStart < url.length && url[authorityStart] === 47;
  let host = authorityStart;
  for (let i = authorityStart; i < end; i++) if (url[i] === 64) { host = i + 1; break; }
  if (host === end) return true;
  if (url[host] === 93) return false;
  let hostEnd = end, port = -1;
  if (url[host] === 91) {
    let bracket = -1;
    for (let i = authorityStart; i < end; i++) if (url[i] === 93) bracket = i;
    if (bracket < 0) return false;
    hostEnd = bracket + 1;
    for (let i = authorityStart; i < end; i++) if (url[i] === 58) port = i;
    if (port < hostEnd) port = -1;
  } else {
    for (let i = authorityStart; i < end; i++) if (url[i] === 58) port = i;
    if (port < host) port = -1;
  }
  if (port >= 0) {
    hostEnd = Math.min(hostEnd, port);
    let i = port + 1, negative = false, value = 0;
    if (i < end && (url[i] === 43 || url[i] === 45)) { negative = url[i] === 45; i++; }
    if (i >= end || url[i] === 95 || url[end - 1] === 95) return false;
    for (; i < end; i++) {
      const byte = url[i]!;
      if (byte === 95) continue;
      if (byte < 48 || byte > 57) return false;
      value = value * 10 + byte - 48;
      if (value > 65535 || negative && value !== 0) return false;
    }
  }
  return host < hostEnd;
}

/** PTY operation 9 plans spawn, lookup, resize, named binding and event routing
 * (actions 0..4). Header: action/count/blocked/kind/tag/key length/reserved,
 * opaque event u64, f64 cols/rows, then key and [used,bound,tag,key length,key]
 * slots. Ended bound identities remain reserved. Native owns key storage,
 * staged refusal lifetimes and the OS transport; all result bytes are owned.
 */
function ptyCoordinationPolicy(request: Uint8Array): Uint8Array {
  if (request.length < 32 || request[1]! > 4 || request[2] !== 4 || request[3]! > 1 || request[7] !== 0 ||
      (request[1] === 4 && request[4]! > 1)) throw new Error("invalid PTY coordination request");
  const action = request[1]!, length = request[6]!;
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const result = new Uint8Array(16), out = new DataView(result.buffer); result[0] = 255; result[1] = request[5]!;
  const cols = wire.getFloat64(16, true), rows = wire.getFloat64(24, true);
  out.setUint16(4, cols >= 1 && cols <= 65535 && Math.floor(cols) === cols ? cols : 0, true);
  out.setUint16(6, rows >= 1 && rows <= 65535 && Math.floor(rows) === rows ? rows : 0, true);
  let at = 32 + length, live = -1, bound = -1, free = -1, binding = -1;
  if (at > request.length) throw new Error("truncated PTY key");
  const positions: number[] = [];
  for (let slot = 0; slot < 4; slot++) {
    if (at + 4 > request.length || request[at]! > 1 || request[at + 1]! > 1) throw new Error("invalid PTY slot");
    const size = request[at + 3]!; positions.push(at);
    if (at + 4 + size > request.length) throw new Error("truncated PTY slot key");
    let equal = size === length;
    for (let i = 0; i < size; i++) if (request[at + 4 + i] !== request[32 + i]) equal = false;
    const used = request[at] === 1, retained = request[at + 1] === 1;
    if (equal && length > 0 && used && live < 0) live = slot;
    if (equal && !used && retained && bound < 0) bound = slot;
    if (!used && !retained && free < 0) free = slot;
    if (equal && length > 0 && (used || retained) && binding < 0) binding = slot;
    at += 4 + size;
  }
  if (at !== request.length) throw new Error("trailing PTY coordination bytes");
  let selected = -1;
  if (action === 0) {
    if (!(length > 0 && (live >= 0 || request[3] === 1))) selected = bound >= 0 ? bound : free;
  } else if (action === 1) selected = live;
  else if (action === 2) { if (out.getUint16(4, true) !== 0 && out.getUint16(6, true) !== 0) selected = live; }
  else if (action === 3) { selected = binding; if (selected >= 0) result[3] = 1; }
  else {
    const slot = wire.getUint32(8, true);
    if (wire.getUint32(12, true) !== 0x54535054 || slot >= 4 || request[positions[slot]!] !== 1)
      throw new Error("PTY event has no tracked owner");
    selected = slot; result[2] = request[4] === 1 ? 1 : 0;
  }
  if (selected >= 0) {
    result[0] = selected;
    if (action !== 0) result[1] = request[positions[selected]! + 2]!;
    out.setUint32(8, selected, true); out.setUint32(12, 0x54535054, true);
  }
  return result;
}

/** Playback events (10) retain audio's active-entry route and video's original
 * low-byte route even across replacement. Terminal events do not retire either.
 */
function playbackEventPolicy(request: Uint8Array): Uint8Array {
  if (request.length !== 12 || request[1]! > 1 || request[2]! > 1) throw new Error("invalid playback event request");
  if (request[1] === 0 && request[2] === 0) throw new Error("audio event has no tracked owner");
  const result = new Uint8Array(1); result[0] = request[1] === 1 ? request[4]! : request[3]!;
  return result;
}

/** Operation 2 of the window ABI plans a complete shell in stable declaration
 * passes. Labels remain opaque bytes; f32 rounding happens at each native
 * arithmetic step. A missing/cyclic parent returns the valid prefix, so the
 * host observes the same ordered OS calls and rollback boundary as before.
 * Header: opcode, u16 count, four f32 bounds. Each declaration carries kind,
 * edge (255 = absent), axis, fill, an eight-bit optional-geometry mask, eight
 * f32 values, u16-sized label and parent (65535 = absent). Result: refusal,
 * u16 count, then u16 declaration index + local/absolute/platform rectangles.
 */
interface NscShellRect { x: number; y: number; width: number; height: number }
interface NscShellView {
  kind: number; edge: number; axis: number; fill: boolean; mask: number;
  values: number[]; label: Uint8Array; parent: Uint8Array | null;
}
interface NscShellResolved {
  index: number; view: NscShellView; frame: NscShellRect; absolute: NscShellRect;
}

function nscvShellLayout(request: Uint8Array): Uint8Array {
  if (request.length < 19) throw new Error("truncated shell layout request");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const count = wire.getUint16(1, true);
  if (count > 128) throw new Error("invalid shell layout count");
  let at = 3;
  const readRect = (): NscShellRect => {
    const value = { x: wire.getFloat32(at, true), y: wire.getFloat32(at + 4, true),
      width: wire.getFloat32(at + 8, true), height: wire.getFloat32(at + 12, true) };
    at += 16; return value;
  };
  const readLabel = (nullable: boolean): Uint8Array | null => {
    if (at + 2 > request.length) throw new Error("truncated shell label");
    const length = wire.getUint16(at, true); at += 2;
    if (nullable && length === 65535) return null;
    if (length > request.length - at) throw new Error("truncated shell label");
    const value = request.subarray(at, at + length); at += length; return value;
  };
  let remaining = readRect();
  const views: NscShellView[] = [];
  for (let index = 0; index < count; index++) {
    if (at + 37 > request.length) throw new Error("truncated shell declaration");
    const kind = request[at++]!, edge = request[at++]!, axis = request[at++]!, fill = request[at++]!, mask = request[at++]!;
    if (kind > 18 || edge !== 255 && edge > 3 || axis > 1 || fill > 1) throw new Error("invalid shell declaration");
    const values: number[] = [];
    for (let field = 0; field < 8; field++) { values.push(wire.getFloat32(at, true)); at += 4; }
    const label = readLabel(false)!;
    views.push({ kind, edge, axis, fill: fill === 1, mask, values, label, parent: readLabel(true) });
  }
  if (at !== request.length) throw new Error("trailing shell layout bytes");
  let fill = remaining;
  for (const view of views) if (view.parent === null && !view.fill && view.edge !== 255) {
    fill = nscvShellConsume(fill, view.edge, nscvShellDock(fill, view));
  }
  const resolved: NscShellResolved[] = [];
  const created: boolean[] = [];
  const parents: string[] = [];
  const first = new Map<string, number>();
  const cursorX: number[] = [], cursorY: number[] = [];
  // Hex keys preserve every opaque byte, including NUL and invalid UTF-8.
  // Resolve each parent through the first recorded declaration, so duplicates
  // share cursors exactly as the reference does without repeated label scans.
  const keys: string[] = [];
  for (let i = 0; i < count; i++) {
    created.push(false); cursorX.push(8); cursorY.push(8);
    keys.push(nscvShellKey(views[i]!.label));
    parents.push(views[i]!.parent === null ? "" : nscvShellKey(views[i]!.parent!));
  }
  while (resolved.length < count) {
    let progressed = false;
    for (let index = 0; index < count; index++) {
      if (created[index]) continue;
      const view = views[index]!;
      const parentIndex = view.parent === null ? -1 : first.get(parents[index]!) ?? -1;
      if (view.parent !== null && parentIndex === -1) continue;
      let frame: NscShellRect;
      if (parentIndex >= 0) {
        const parent = resolved[parentIndex]!;
        const split = parent.view.kind === 5, row = parent.view.axis === 0;
        const x = nscvShellValue(view, 0, row ? cursorX[parentIndex]! : split ? 0 : 8);
        let y: number, width: number, height: number;
        if (split) {
          y = nscvShellValue(view, 1, row ? 0 : cursorY[parentIndex]!);
          const availableWidth = nscvShellMax(Math.fround(parent.frame.width - x), 0);
          const availableHeight = nscvShellMax(Math.fround(parent.frame.height - y), 0);
          width = nscvShellWidth(view, nscvShellValue(view, 2, row ? view.fill ? availableWidth : nscvShellDefaultWidth(view.kind) : availableWidth));
          height = nscvShellHeight(view, nscvShellValue(view, 3, row ? availableHeight : view.fill ? availableHeight : nscvShellDefaultHeight(view.kind, parent.frame.height)));
          if (row) cursorX[parentIndex] = nscvShellMax(cursorX[parentIndex]!, Math.fround(x + width));
          else cursorY[parentIndex] = nscvShellMax(cursorY[parentIndex]!, Math.fround(y + height));
        } else {
          width = nscvShellWidth(view, nscvShellValue(view, 2, nscvShellDefaultWidth(view.kind)));
          height = nscvShellHeight(view, nscvShellValue(view, 3, nscvShellDefaultHeight(view.kind, parent.frame.height)));
          y = nscvShellValue(view, 1, row ? parent.frame.height <= height ? 0 : Math.fround(Math.fround(parent.frame.height - height) / 2) : cursorY[parentIndex]!);
          if (row && (view.mask & 1) === 0) cursorX[parentIndex] = Math.fround(Math.fround(x + width) + 8);
          if (!row && (view.mask & 2) === 0) cursorY[parentIndex] = Math.fround(Math.fround(y + height) + 8);
        }
        frame = { x, y, width, height };
      } else if (view.fill) {
        frame = { x: nscvShellValue(view, 0, fill.x), y: nscvShellValue(view, 1, fill.y),
          width: nscvShellWidth(view, nscvShellValue(view, 2, fill.width)), height: nscvShellHeight(view, nscvShellValue(view, 3, fill.height)) };
      } else if (view.edge !== 255) {
        frame = nscvShellDock(remaining, view); remaining = nscvShellConsume(remaining, view.edge, frame);
      } else {
        frame = { x: nscvShellValue(view, 0, 0), y: nscvShellValue(view, 1, 0),
          width: nscvShellWidth(view, nscvShellValue(view, 2, nscvShellDefaultWidth(view.kind))),
          height: nscvShellHeight(view, nscvShellValue(view, 3, nscvShellDefaultHeight(view.kind, 0))) };
      }
      const absolute = parentIndex < 0 ? frame : { ...frame,
        x: Math.fround(frame.x + resolved[parentIndex]!.absolute.x), y: Math.fround(frame.y + resolved[parentIndex]!.absolute.y) };
      const next = resolved.length;
      resolved.push({ index, view, frame, absolute });
      cursorX[next] = view.kind === 5 ? 0 : 8; cursorY[next] = view.kind === 5 ? 0 : 8;
      if (!first.has(keys[index]!)) first.set(keys[index]!, next);
      created[index] = true; progressed = true;
    }
    if (!progressed) break;
  }
  const output = new Uint8Array(3 + resolved.length * 50);
  const out = new DataView(output.buffer);
  output[0] = resolved.length === count ? 0 : 1; out.setUint16(1, resolved.length, true);
  at = 3;
  const writeRect = (frame: NscShellRect): void => {
    out.setFloat32(at, frame.x, true); out.setFloat32(at + 4, frame.y, true);
    out.setFloat32(at + 8, frame.width, true); out.setFloat32(at + 12, frame.height, true); at += 16;
  };
  for (const item of resolved) {
    out.setUint16(at, item.index, true); at += 2;
    writeRect(item.frame); writeRect(item.absolute);
    const initial = resolved[first.get(keys[item.index]!)!]!;
    const main = nscvShellEqual(item.view.label, new Uint8Array([109, 97, 105, 110]));
    writeRect(item.view.kind === 0 && item.view.parent !== null && main ? initial.absolute : item.frame);
  }
  return output;
}

function nscvShellKey(label: Uint8Array): string {
  const chunks: string[] = [];
  for (const byte of label) chunks.push(byte.toString(16).padStart(2, "0"));
  return chunks.join("");
}
function nscvShellEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
// Zig's min/max ignore one NaN operand. All arithmetic operands already carry
// native f32 values, and the explicit rounds preserve native evaluation order.
function nscvShellMax(a: number, b: number): number { return Number.isNaN(a) ? b : Number.isNaN(b) ? a : Math.max(a, b); }
function nscvShellMin(a: number, b: number): number { return Number.isNaN(a) ? b : Number.isNaN(b) ? a : Math.min(a, b); }
function nscvShellValue(view: NscShellView, field: number, fallback: number): number {
  return (view.mask & (1 << field)) === 0 ? fallback : view.values[field]!;
}
function nscvShellWidth(view: NscShellView, value: number): number {
  let width = value;
  if ((view.mask & 16) !== 0) width = nscvShellMax(width, view.values[4]!);
  if ((view.mask & 64) !== 0) width = nscvShellMin(width, view.values[6]!);
  return width;
}
function nscvShellHeight(view: NscShellView, value: number): number {
  let height = value;
  if ((view.mask & 32) !== 0) height = nscvShellMax(height, view.values[5]!);
  if ((view.mask & 128) !== 0) height = nscvShellMin(height, view.values[7]!);
  return height;
}
function nscvShellDock(remaining: NscShellRect, view: NscShellView): NscShellRect {
  const vertical = view.edge === 0 || view.edge === 2;
  const width = nscvShellWidth(view, nscvShellValue(view, 2, vertical ? remaining.width : nscvShellDefaultWidth(view.kind)));
  const height = nscvShellHeight(view, nscvShellValue(view, 3, vertical ? nscvShellDefaultHeight(view.kind, 0) : remaining.height));
  return { x: view.edge === 1 ? Math.fround(remaining.x + nscvShellMax(Math.fround(remaining.width - width), 0)) : remaining.x,
    y: view.edge === 2 ? Math.fround(remaining.y + nscvShellMax(Math.fround(remaining.height - height), 0)) : remaining.y, width, height };
}
function nscvShellConsume(remaining: NscShellRect, edge: number, frame: NscShellRect): NscShellRect {
  return { x: edge === 3 ? Math.fround(remaining.x + frame.width) : remaining.x,
    y: edge === 0 ? Math.fround(remaining.y + frame.height) : remaining.y,
    width: edge === 1 || edge === 3 ? nscvShellMax(Math.fround(remaining.width - frame.width), 0) : remaining.width,
    height: edge === 0 || edge === 2 ? nscvShellMax(Math.fround(remaining.height - frame.height), 0) : remaining.height };
}
function nscvShellDefaultWidth(kind: number): number {
  switch (kind) {
    case 7: case 10: case 11: return 96;
    case 8: return 32;
    case 9: case 13: case 14: return 220;
    case 12: return 168;
    case 15: return 160;
    case 16: return 12;
    case 18: return 24;
    case 3: return 240;
    default: return 0;
  }
}
function nscvShellDefaultHeight(kind: number, parent: number): number {
  switch (kind) {
    case 7: case 8: case 9: case 10: case 11: case 12: return 32;
    case 15: case 18: return 24;
    case 16: return nscvShellMax(parent, 1);
    case 13: case 14: case 4: return 28;
    case 1: return 48;
    case 2: return 36;
    default: return 0;
  }
}

/** Floating-surface placement over measured native geometry. The existing
 * window ABI's operation 3 carries modal, anchored, and caption-clearance
 * requests. Each arithmetic intermediate preserves native f32 ordering.
 * Consumers copy the result; the enclosing view/cycle owns arena collection.
 */
interface NscSurfaceRect { readonly x: number; readonly y: number; readonly width: number; readonly height: number; }
function nscvSurfaceMax(a: number, b: number): number { return Number.isNaN(a) ? b : Number.isNaN(b) ? a : Math.max(a, b); }
function nscvSurfaceMin(a: number, b: number): number { return Number.isNaN(a) ? b : Number.isNaN(b) ? a : Math.min(a, b); }
function nscvSurfaceClamp(v: number, lo: number, hi: number, keepsLowerZero: boolean): number {
  // The native numeric capability preserves the target's zero endpoint sign.
  const result = nscvSurfaceMax(lo, nscvSurfaceMin(v, hi));
  return keepsLowerZero && result === lo ? lo : result;
}
function nscvSurfaceBound(v: number, lo: number, hi: number): number { return nscvSurfaceMax(lo, hi > 0 ? nscvSurfaceMin(v, hi) : v); }
function nscvSurfaceNormalize(r: NscSurfaceRect): NscSurfaceRect {
  return { x: r.width < 0 ? Math.fround(r.x + r.width) : r.x, y: r.height < 0 ? Math.fround(r.y + r.height) : r.y,
    width: r.width < 0 ? -r.width : r.width, height: r.height < 0 ? -r.height : r.height };
}
function nscvSurfaceRight(r: NscSurfaceRect): number { return Math.fround(r.x + r.width); }
function nscvSurfaceBottom(r: NscSurfaceRect): number { return Math.fround(r.y + r.height); }
function nscvSurfaceLayout(request: Uint8Array): Uint8Array {
  if (request.length < 4 || request[0] !== 3) throw new Error("invalid surface layout request");
  const operation = request[1]!, a = request[2]!, b = request[3]!;
  const length = operation === 0 ? 56 : operation === 1 ? 80 : operation === 2 ? 36 : 0;
  if (request.length !== length) throw new Error("invalid surface layout length");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const v: number[] = [];
  for (let at = 4; at < request.length; at += 4) v.push(wire.getFloat32(at, true));
  const bounds = nscvSurfaceNormalize({ x: v[0]!, y: v[1]!, width: v[2]!, height: v[3]! });
  let frame: NscSurfaceRect = bounds, present = true;
  if (operation === 0) {
    // Kind 0/1/2 is dialog/drawer/sheet; 255 preserves unsupported-kind null.
    if (a !== 0 && a !== 1 && a !== 2 && a !== 255 || b > 1) throw new Error("invalid modal layout flags");
    if (a === 255 || bounds.width <= 0 || bounds.height <= 0) present = false;
    else {
      let width = v[4]!, height = v[5]!;
      if (b === 1) {
        width = nscvSurfaceBound(width > 0 ? width : v[6]!, v[8]!, v[10]!);
        height = nscvSurfaceBound(height > 0 ? height : v[7]!, v[9]!, v[11]!);
      }
      width = Number.isFinite(width) && width > 0 ? width : a === 0 ? 420 : a === 1 ? 360 : 320;
      height = Number.isFinite(height) && height > 0 ? height : a === 0 ? 220 : a === 1 ? 280 : 420;
      if (a === 0) {
        const margin = nscvSurfaceMin(nscvSurfaceMax(0, Number.isFinite(v[12]!) ? v[12]! : 0), Math.fround(nscvSurfaceMin(bounds.width, bounds.height) * 0.5));
        width = nscvSurfaceMin(width, nscvSurfaceMax(1, Math.fround(bounds.width - Math.fround(margin * 2))));
        height = nscvSurfaceMin(height, nscvSurfaceMax(1, Math.fround(bounds.height - Math.fround(margin * 2))));
        frame = { x: Math.fround(bounds.x + Math.fround(Math.fround(bounds.width - width) * 0.5)), y: Math.fround(bounds.y + Math.fround(Math.fround(bounds.height - height) * 0.5)), width, height };
      } else if (a === 1) {
        height = nscvSurfaceMin(nscvSurfaceMax(0, height), nscvSurfaceMax(1, bounds.height));
        frame = { x: bounds.x, y: Math.fround(nscvSurfaceBottom(bounds) - height), width: nscvSurfaceMax(1, bounds.width), height };
      } else {
        width = nscvSurfaceMin(nscvSurfaceMax(0, width), nscvSurfaceMax(1, bounds.width));
        frame = { x: Math.fround(nscvSurfaceRight(bounds) - width), y: bounds.y, width, height: nscvSurfaceMax(1, bounds.height) };
      }
    }
  } else if (operation === 1) {
    if (a > 1 || b > 14) throw new Error("invalid anchor layout flags");
    const point = (b & 4) !== 0, alignment = b & 3, keepsLowerZero = (b & 8) !== 0;
    if (alignment > 2) throw new Error("invalid anchor alignment");
    const anchor = point ? { x: nscvSurfaceClamp(v[17]!, bounds.x, nscvSurfaceRight(bounds), keepsLowerZero), y: nscvSurfaceClamp(v[18]!, bounds.y, nscvSurfaceBottom(bounds), keepsLowerZero), width: 0, height: 0 }
      : nscvSurfaceNormalize({ x: v[4]!, y: v[5]!, width: v[6]!, height: v[7]! });
    let width = v[8]! > 0 ? v[8]! : v[10]!;
    if (alignment === 2) width = nscvSurfaceMax(width, anchor.width);
    width = nscvSurfaceMin(nscvSurfaceBound(width, v[12]!, v[14]!), bounds.width);
    let height = nscvSurfaceBound(v[9]! > 0 ? v[9]! : v[11]!, v[13]!, v[15]!);
    const offset = nscvSurfaceMax(0, v[16]!);
    const belowSpace = Math.fround(Math.fround(nscvSurfaceBottom(bounds) - nscvSurfaceBottom(anchor)) - offset);
    const aboveSpace = Math.fround(Math.fround(anchor.y - bounds.y) - offset);
    const preferred = a === 0 ? belowSpace : aboveSpace, other = a === 0 ? aboveSpace : belowSpace;
    const below = (a === 0) !== (height > preferred && other > preferred);
    height = nscvSurfaceMin(height, nscvSurfaceMax(0, below ? belowSpace : aboveSpace));
    const y = below ? Math.fround(nscvSurfaceBottom(anchor) + offset) : Math.fround(Math.fround(anchor.y - offset) - height);
    const x = alignment === 1 ? Math.fround(nscvSurfaceRight(anchor) - width) : anchor.x;
    frame = { x: nscvSurfaceClamp(x, bounds.x, nscvSurfaceMax(bounds.x, Math.fround(nscvSurfaceRight(bounds) - width)), keepsLowerZero),
      y: nscvSurfaceClamp(y, bounds.y, nscvSurfaceMax(bounds.y, Math.fround(nscvSurfaceBottom(bounds) - height)), keepsLowerZero), width, height };
  } else {
    if (a > 1 || b > 1) throw new Error("invalid caption clearance flags");
    // Content is already normalized by the layout. Preserve it verbatim
    // when reservation is absent or the native control cluster misses it.
    frame = { x: v[0]!, y: v[1]!, width: v[2]!, height: v[3]! };
    const controls = nscvSurfaceNormalize({ x: v[4]!, y: v[5]!, width: v[6]!, height: v[7]! });
    const x0 = nscvSurfaceMax(frame.x, controls.x), y0 = nscvSurfaceMax(frame.y, controls.y);
    const x1 = nscvSurfaceMin(nscvSurfaceRight(frame), nscvSurfaceRight(controls)), y1 = nscvSurfaceMin(nscvSurfaceBottom(frame), nscvSurfaceBottom(controls));
    const misses = x1 <= x0 || y1 <= y0;
    const emptyIntersection = Math.fround(x1 - x0) <= 0 || Math.fround(y1 - y0) <= 0;
    if (a === 1 && b === 1 && !(controls.width <= 0 || controls.height <= 0) && !misses && !emptyIntersection) {
      if (Math.fround(controls.x + Math.fround(controls.width / 2)) >= Math.fround(frame.x + Math.fround(frame.width / 2))) {
        frame = { x: frame.x, y: frame.y, width: nscvSurfaceMax(0, Math.fround(nscvSurfaceMin(nscvSurfaceRight(frame), controls.x) - frame.x)), height: frame.height };
      } else {
        const start = nscvSurfaceMin(nscvSurfaceRight(frame), nscvSurfaceMax(frame.x, nscvSurfaceRight(controls)));
        frame = { x: start, y: frame.y, width: nscvSurfaceMax(0, Math.fround(nscvSurfaceRight(frame) - start)), height: frame.height };
      }
    }
  }
  const result = new Uint8Array(17);result[0] = present ? 1 : 0;
  const output = new DataView(result.buffer);
  output.setFloat32(1, frame.x, true);output.setFloat32(5, frame.y, true);output.setFloat32(9, frame.width, true);output.setFloat32(13, frame.height, true);
  return result;
}

/** Grid geometry over native-owned children and measured row extents.
 * Operation 0 plans the grid and virtual row window; operation 1 places one
 * flow child. Integer lanes preserve declared usize columns even above the
 * exact JS number range; native conversion facts preserve u64-to-f32 rounding.
 * Results are owned bytes, collected only by the enclosing view/cycle.
 */
function nscvGridLayout(request: Uint8Array): Uint8Array {
  if (request.length < 4 || request[0] !== 4 || request[3] !== 0) throw new Error("invalid grid layout request");
  const op = request[1]!, flags = request[2]!;
  if ((op !== 0 && op !== 1) || request.length !== 76 || flags > (op === 0 ? 7 : 3))
    throw new Error("invalid grid layout operation, length or flags");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const integer = (at: number): number => wire.getUint32(at, true) + wire.getUint32(at + 4, true) * 4294967296;
  const float = (at: number): number => wire.getFloat32(at, true);
  const virtual = (flags & 1) !== 0;
  const f = Math.fround;
  if (op === 0) {
    const count = integer(4), declared = integer(12), overscan = integer(20);
    if (!Number.isSafeInteger(count)) throw new Error("invalid grid child count");
    const columns = count === 0 ? 0 : declared > 0 ? declared : count;
    const rows = columns === 0 ? 0 : 1 + Math.floor((count - 1) / columns);
    const columnsF = count === 0 ? 0 : declared > 0 ? float(64) : float(60);
    const gap = nscvSurfaceMax(0, float(44));
    const width = columns > 0 ? f(nscvSurfaceMax(0, f(float(36) - f(gap * (declared > 0 ? float(72) : float(68))))) / columnsF) : 0;
    let height = rows > 0 ? f(nscvSurfaceMax(0, f(float(40) - f(gap * f(rows - 1)))) / f(rows)) : 0;
    let start = 0, end = count, offset = 0, extent = 0;
    if (virtual) {
      extent = float(48) > 0 ? float(48) : float(52);
      const range = nscvFlowRange(nscvFlowSmall(rows), f(rows), extent, gap, float(40), float(56), nscvFlowInteger(wire, 20), flags >> 1);
      start = range.start.low + range.start.high * 4294967296;
      end = range.end.low + range.end.high * 4294967296;
      offset = range.offset; extent = range.extent; height = range.extent;
    }
    const result = new Uint8Array(52), out = new DataView(result.buffer);
    // Preserve all integer bits of the chosen declared column count.
    if (count > 0) result.set(request.subarray(declared > 0 ? 12 : 4, declared > 0 ? 20 : 12), 0);
    for (const [at, value] of [[8, rows], [16, start], [24, end]]) {
      out.setUint32(at!, value! % 4294967296, true); out.setUint32(at! + 4, Math.floor(value! / 4294967296), true);
    }
    for (const [at, value] of [[32, width], [36, height], [40, gap], [44, offset], [48, extent]]) out.setFloat32(at!, value!, true);
    return result;
  }
  const index = integer(4), columns = integer(12);
  if (!Number.isSafeInteger(index) || columns === 0) throw new Error("invalid grid cell index or columns");
  const row = Math.floor(index / columns), column = index - row * columns;
  const x = f(float(20) + f(f(column) * f(float(28) + float(36))));
  let y = f(float(24) + f(f(row) * f(float(32) + float(36))));
  if (virtual) y = f(y - float(40));
  let width = float(52) > 0 ? float(52) : float(28);
  if ((flags & 2) !== 0) width = nscvSurfaceMax(width, nscvSurfaceMax(0, f(float(28) - float(44))));
  width = nscvSurfaceBound(width, float(60), float(68));
  const height = nscvSurfaceBound(float(56) > 0 ? float(56) : float(32), float(64), float(72));
  const result = new Uint8Array(17), out = new DataView(result.buffer); result[0] = 1;
  out.setFloat32(1, f(x + float(44)), true); out.setFloat32(5, f(y + float(48)), true);
  out.setFloat32(9, width, true); out.setFloat32(13, height, true); return result;
}

function nscvGridCount(value: number): number {
  if (!Number.isSafeInteger(value) || value < 0) throw new Error("invalid grid columns");
  return value;
}

type NscContainerChild = {
  flags: number; grow: number; main: number; cross: number; offsetMain: number; offsetCross: number;
  minMain: number; maxMain: number; minCross: number; maxCross: number;
  measuredMain: number; measuredCross: number;
};

/** Container allocation over owned native measurement facts. A cross-size
 * pass supplies the width for wrapped text before the final allocation pass.
 * The same allocation chooses row measurement widths; stacking is operation 3.
 * Every arithmetic boundary follows the native f32 evaluation order.
 */
function nscvContainerLayout(request: Uint8Array): Uint8Array {
  if (request.length < 36 || request[0] !== 5) throw new Error("invalid container layout request");
  const op = request[1]!, axis = request[2]!, main = request[3]!, cross = request[4]!;
  if (op > 3 || axis > 1 || main > 3 || cross > 3 || request[5] !== 0 || request[6] !== 0 || request[7] !== 0)
    throw new Error("invalid container layout operation or flags");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength), count = wire.getUint32(8, true);
  if (request.length !== 36 + count * 48 || op === 3 && (count !== 1 || axis !== 0)) throw new Error("invalid container layout length");
  const f = Math.fround, max = nscvSurfaceMax, min = nscvSurfaceMin;
  const x = wire.getFloat32(12, true), y = wire.getFloat32(16, true);
  const available = wire.getFloat32(axis === 0 ? 20 : 24, true), band = wire.getFloat32(axis === 0 ? 24 : 20, true);
  const gap = max(0, wire.getFloat32(28, true));
  if (wire.getUint32(32, true) !== 0) throw new Error("invalid container layout reserved bytes");
  const children: NscContainerChild[] = [];
  for (let i = 0; i < count; i++) {
    const at = 36 + i * 48, flags = wire.getUint32(at, true);
    if (flags > 31 || op === 3 && (flags & 28) !== 0) throw new Error("invalid container child flags");
    children.push({ flags, grow: max(0, wire.getFloat32(at + 4, true)), main: wire.getFloat32(at + 8, true),
      cross: wire.getFloat32(at + 12, true), offsetMain: wire.getFloat32(at + 16, true), offsetCross: wire.getFloat32(at + 20, true),
      minMain: wire.getFloat32(at + 24, true), maxMain: wire.getFloat32(at + 28, true), minCross: wire.getFloat32(at + 32, true),
      maxCross: wire.getFloat32(at + 36, true), measuredMain: wire.getFloat32(at + 40, true), measuredCross: wire.getFloat32(at + 44, true) });
  }
  const result = new Uint8Array(12 + count * (op === 0 ? 4 : 16)), out = new DataView(result.buffer);
  out.setUint32(0, count, true);
  if (op === 3) {
    const child = children[0]!, left = f(x + child.offsetMain), top = f(y + child.offsetCross);
    let width = nscvSurfaceBound(child.main > 0 ? child.main : available, child.minMain, child.maxMain);
    const height = nscvSurfaceBound(child.cross > 0 ? child.cross : band, child.minCross, child.maxCross);
    if ((child.flags & 2) !== 0) width = nscvSurfaceBound(max(width, max(0, f(f(x + available) - left))), child.minMain, child.maxMain);
    out.setFloat32(12, left, true); out.setFloat32(16, top, true); out.setFloat32(20, width, true); out.setFloat32(24, height, true);
    return result;
  }
  if (op === 0) {
    for (let i = 0; i < count; i++) out.setFloat32(12 + i * 4, (children[i]!.flags & 1) !== 0 ? nscvContainerCross(children[i]!, axis, band, cross) : 0, true);
    return result;
  }
  let flowCount = 0, fillCount = 0, fixed = 0, growTotal = 0;
  const preferred: number[] = [];
  for (const child of children) {
    let extent = nscvSurfaceBound(child.main > 0 ? child.main : child.measuredMain, max(0, child.minMain), child.maxMain);
    if (axis === 0 && (child.flags & 8) !== 0 && child.main <= 0 && child.maxMain <= 0 && available > 0)
      extent = min(extent, max(f(available * f(0.8)), max(0, child.minMain)));
    preferred.push(extent);
    if ((child.flags & 1) === 0) continue;
    flowCount++;
    if ((child.flags & 2) !== 0 && child.grow === 0) fillCount++;
    else if (child.grow > 0) growTotal = f(growTotal + child.grow);
    else fixed = f(fixed + extent);
  }
  const totalGap = flowCount > 0 ? f(gap * f(flowCount - 1)) : 0;
  const flexible = max(0, f(f(available - fixed) - totalGap));
  const fillShare = fillCount > 0 ? f(flexible / f(fillCount)) : 0;
  let fillExtent = 0;
  const extents: number[] = [];
  for (let i = 0; i < count; i++) {
    const child = children[i]!;
    const fills = (child.flags & 2) !== 0 && child.grow === 0;
    const extent = fills ? nscvSurfaceBound(max(preferred[i]!, fillShare), max(0, child.minMain), child.maxMain) : preferred[i]!;
    extents.push(extent);
    if ((child.flags & 1) !== 0 && fills) fillExtent = f(fillExtent + extent);
  }
  const remaining = max(0, f(flexible - fillExtent));
  let assigned = f(fixed + fillExtent);
  if (growTotal > 0) {
    for (let i = 0; i < count; i++) {
      const child = children[i]!;
      if ((child.flags & 1) === 0 || child.grow <= 0) continue;
      const extent = nscvSurfaceBound(f(f(remaining * child.grow) / growTotal), max(0, child.minMain), child.maxMain);
      extents[i] = extent; assigned = f(assigned + extent);
    }
  }
  const used = f(assigned + totalGap), free = max(0, f(available - used));
  const overflow = f(used - available);
  out.setFloat32(4, used, true); out.setFloat32(8, overflow <= 0.5 ? 0 : overflow, true);
  const childGap = main === 3 && flowCount > 1 ? f(gap + f(free / f(flowCount - 1))) : gap;
  let cursor = f((axis === 0 ? x : y) + (main === 1 ? f(free * 0.5) : main === 2 ? free : 0));
  for (let i = 0; i < count; i++) {
    const child = children[i]!;
    if ((child.flags & 1) === 0) continue;
    const size = nscvContainerCross(child, axis, band, cross);
    const delta = f(band - size), shift = cross === 2 ? f(delta * 0.5) : cross === 3 ? max(0, delta) : 0;
    const origin = f(f((axis === 0 ? y : x) + child.offsetCross) + shift);
    const at = 12 + i * 16;
    out.setFloat32(at, axis === 0 ? cursor : origin, true); out.setFloat32(at + 4, axis === 0 ? origin : cursor, true);
    out.setFloat32(at + 8, axis === 0 ? extents[i]! : size, true); out.setFloat32(at + 12, axis === 0 ? size : extents[i]!, true);
    cursor = f(cursor + f(extents[i]! + childGap));
  }
  return result;
}

function nscvContainerCross(child: NscContainerChild, axis: number, available: number, alignment: number): number {
  const f = Math.fround, max = nscvSurfaceMax, min = nscvSurfaceMin;
  if ((child.flags & 16) !== 0) return nscvSurfaceBound(available, child.minCross, child.maxCross);
  if (axis === 1 && (child.flags & 4) !== 0)
    return nscvSurfaceBound(max(child.cross, max(0, f(available - child.offsetCross))), child.minCross, child.maxCross);
  if (child.cross > 0) return nscvSurfaceBound(child.cross, child.minCross, child.maxCross);
  if (axis === 1 && (child.flags & 8) !== 0 && child.cross <= 0 && child.maxCross <= 0 && available > 0) {
    const fitted = min(available, child.measuredCross);
    return nscvSurfaceBound(min(fitted, max(f(available * f(0.8)), max(0, child.minCross))), child.minCross, child.maxCross);
  }
  if (alignment === 0) return nscvSurfaceBound(available, child.minCross, child.maxCross);
  return nscvSurfaceBound(axis === 0 && alignment === 2 ? child.measuredCross : min(available, child.measuredCross), child.minCross, child.maxCross);
}

/** Intrinsic composition over native text/leaf measurements. Child bounds,
 * separator contributions, flow aggregation, padding and surface chrome are
 * portable policy. Native copies every result before recursive measurement;
 * collection belongs to the enclosing app cycle, never to this operation.
 */
function nscvIntrinsicLayout(request: Uint8Array): Uint8Array {
  if (request.length < 96 || request[0] !== 6) throw new Error("invalid intrinsic layout request");
  const op = request[1]!, axis = request[2]!, flags = request[3]!;
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength), count = wire.getUint32(4, true);
  if (op > 10 || axis > 1 || flags > 3 || wire.getUint32(92, true) !== 0 || request.length !== 96 + count * 40)
    throw new Error("invalid intrinsic layout operation, flags or length");
  const f = Math.fround, max = nscvSurfaceMax, min = nscvSurfaceMin;
  const v = (at: number): number => wire.getFloat32(at, true);
  const minWidth = v(24), minHeight = v(28), left = v(32), right = v(36), top = v(40), bottom = v(44);
  const gap = max(0, v(48)), stopped = (flags & 1) !== 0, hasTitle = (flags & 2) !== 0;
  const result = new Uint8Array(12 + count * 12), out = new DataView(result.buffer); out.setUint32(0, count, true);
  let flows = 0, width = 0, height = 0;
  for (let i = 0; i < count; i++) {
    const at = 96 + i * 40, childFlags = wire.getUint32(at, true);
    if (childFlags > 3) throw new Error("invalid intrinsic child flags");
    if ((childFlags & 1) === 0) continue;
    flows++;
    let w = nscvSurfaceBound(max(v(at + 4), max(0, v(at + 12))), v(at + 20), v(at + 28));
    let h = nscvSurfaceBound(max(v(at + 8), max(0, v(at + 16))), v(at + 24), v(at + 32));
    if (op === 1 && axis === 0 && (childFlags & 2) !== 0 && v(at + 12) <= 0) {
      const thin = min(w, h); w = max(max(0, v(at + 20)), thin); h = max(max(0, v(at + 24)), thin);
    }
    out.setFloat32(12 + i * 12, w, true); out.setFloat32(16 + i * 12, h, true);
    out.setFloat32(20 + i * 12, v(at + 12) > 0 ? v(at + 12) : w, true);
    if (op === 1) {
      width = axis === 0 ? f(width + w) : max(width, w);
      height = axis === 0 ? max(height, h) : f(height + h);
    } else { width = max(width, w); height = max(height, op === 3 ? v(at + 36) : h); }
  }
  if (op === 0) return result;
  const paddedWidth = (w: number): number => max(f(f(w + left) + right), minWidth);
  const paddedHeight = (h: number): number => max(f(f(h + top) + bottom), minHeight);
  if (op === 6) { width = paddedWidth(v(52)); height = paddedHeight(v(56)); }
  else if (op === 7) {
    width = paddedWidth(width); height = paddedHeight(f(f(v(64) + (height > 0 ? gap : 0)) + height));
  } else if (op >= 8) {
    const childrenWidth = width, childrenHeight = height;
    width = max(v(68), f(v(60) + f(v(76) * 2)));
    height = max(v(72), hasTitle ? f(v(64) + f(v(76) * 2)) : 0);
    if (op === 10) {
      width = max(v(68), f(f(f(f(v(60) + left) + right) + v(80)) + v(84)));
      height = max(v(72), f(f(v(64) + top) + bottom));
      if (childrenHeight > 0) {
        if (hasTitle) {
          height = max(height, f(f(f(f(v(64) + v(88)) + childrenHeight) + top) + bottom));
          width = max(width, f(f(f(f(childrenWidth + v(80)) + v(84)) + left) + right));
        } else { height = max(height, f(f(childrenHeight + top) + bottom)); width = max(width, f(f(childrenWidth + left) + right)); }
      }
    } else if (childrenHeight > 0) {
      const childHeight = f(f(childrenHeight + top) + bottom);
      height = op === 8 ? max(height, childHeight) : hasTitle ? max(childHeight, f(v(64) + f(v(76) * 2))) : childHeight;
      width = max(width, f(f(childrenWidth + left) + right));
    }
  } else if (op === 5) {
    if (stopped) { width = 0; height = 0; }
  } else if (stopped || count === 0 || (op === 1 || op === 4) && flows === 0) {
    width = op === 3 ? 0 : max(0, minWidth); height = max(0, minHeight);
  } else {
    if (op === 1) {
      const gaps = f(gap * f(flows - 1));
      if (axis === 0) width = f(width + gaps); else height = f(height + gaps);
    } else if (op === 4) {
      const declared = wire.getUint32(8, true) + wire.getUint32(12, true) * 4294967296;
      const columns = declared > 0 ? declared : flows, rows = 1 + Math.floor((flows - 1) / columns);
      const columnsF = declared > 0 ? v(16) : f(flows), columnsMinusF = declared > 0 ? v(20) : f(flows - 1);
      width = f(f(width * columnsF) + f(gap * columnsMinusF));
      height = f(f(height * f(rows)) + f(gap * f(rows - 1)));
    }
    width = op === 3 ? 0 : paddedWidth(width); height = paddedHeight(height);
  }
  out.setFloat32(4, width, true); out.setFloat32(8, height, true); return result;
}

/** Width-aware sizing over stable widget-kind codes and native paragraph,
 * theme and row/bubble measurements. Operation 0 plans widths; 1 composes
 * measured heights; 2 measures the accordion's hidden content independently
 * of its own height, padding and depth guard. Results own their bytes.
 */
function nscvWrappedLayout(request: Uint8Array): Uint8Array {
  if (request.length < 80 || request[0] !== 7) throw new Error("invalid wrapped layout request");
  const op = request[1]!, kind = request[2]!, flags = request[3]!;
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength), count = wire.getUint32(4, true);
  if (op > 2 || kind > 62 || flags > 31 || request.length !== 80 + count * 16 || op === 2 && kind !== 14)
    throw new Error("invalid wrapped layout operation, kind, flags or length");
  const f = Math.fround, max = nscvSurfaceMax;
  const v = (at: number): number => wire.getFloat32(at, true);
  let mode = 0;
  if ((kind === 26 || kind === 44) && (flags & 1) !== 0) mode = 1;
  else if (kind === 2 || kind === 7 || kind === 4 || kind === 5 || kind === 24 || kind === 25) mode = (flags & 2) !== 0 ? 0 : 2;
  else if (kind === 0 || kind === 22 || kind === 18 || kind === 15 || kind === 16 || kind === 23) mode = 3;
  else if (kind === 17) mode = 4;
  else if (kind === 14) mode = 5;
  else if (kind === 1 || kind === 43 || kind === 8 || kind === 9 || kind === 10 || kind === 11 || kind === 12 || kind === 13 || kind === 44 && count > 0 || kind === 42 && (flags & 16) !== 0) mode = 6;
  if (op === 2) mode = 7;
  const stopped = wire.getUint32(8, true) >= wire.getUint32(12, true);
  const action = op === 2 ? 3 : stopped ? 0 : v(20) > 0 ? 1 : mode === 0 ? 0 : mode === 1 ? 2 : mode === 5 && (flags & 8) === 0 ? 4 : 3;
  const inner = op === 2 ? v(16) : max(0, f(f(v(16) - v(32)) - v(36)));
  const result = new Uint8Array(20 + count * 8), out = new DataView(result.buffer);
  out.setUint32(0, count, true); out.setUint32(4, action, true); out.setFloat32(8, inner, true); out.setUint32(16, mode, true);
  let content = 0, flows = 0;
  for (let i = 0; i < count; i++) {
    const at = 80 + i * 16, childFlags = wire.getUint32(at, true);
    if (childFlags > 7) throw new Error("invalid wrapped child flags");
    if ((childFlags & 1) === 0 || action !== 3) continue;
    flows++;
    let width = v(at + 4) > 0 ? v(at + 4) : mode === 4 && (flags & 4) !== 0 ? max(0, f(inner - v(56))) : inner;
    let query = 0;
    if (mode === 6) { query = (childFlags & 4) !== 0 ? 0 : 1; width = v(at + 8); }
    else if (mode === 2 && (childFlags & 2) !== 0 && !(v(at + 4) > 0)) {
      query = (childFlags & 4) !== 0 ? 0 : 2; width = v(at + 8);
    }
    out.setFloat32(20 + i * 8, width, true); out.setUint32(24 + i * 8, query, true);
    content = mode === 2 ? f(content + v(at + 12)) : max(content, v(at + 12));
  }
  let height = action === 0 ? v(68) : action === 1 ? v(20) : action === 2 ? v(64) : action === 4 ? v(52) : content;
  if (action === 3 && mode === 2 && flows > 1) height = f(height + f(max(0, v(48)) * f(flows - 1)));
  if (action === 3 && mode === 4) {
    if ((flags & 4) !== 0) height = f(v(52) + (height > 0 ? f(v(76) + height) : 0));
    const floor = max(v(60), f(v(52) + f(v(72) * 2)));
    height = max(height, f(f(floor - v(40)) - v(44)));
  }
  if (action === 3 && mode === 5) height = f(f(v(52) + (height > 0 ? max(0, v(48)) : 0)) + height);
  if (op !== 2 && action !== 0) {
    if (action !== 1) height = f(f(height + v(40)) + v(44));
    height = nscvSurfaceBound(height, v(24), v(28));
  }
  out.setFloat32(12, height, true); return result;
}


type NscFlowInteger = { low: number; high: number };
function nscvFlowInteger(wire: DataView, at: number): NscFlowInteger { return { low: wire.getUint32(at, true), high: wire.getUint32(at + 4, true) }; }
function nscvFlowCompare(a: NscFlowInteger, b: NscFlowInteger): number { return a.high !== b.high ? a.high - b.high : a.low - b.low; }
function nscvFlowSmall(n: number): NscFlowInteger { return { low: n % 4294967296, high: Math.floor(n / 4294967296) }; }
function nscvFlowAdd(a: NscFlowInteger, b: NscFlowInteger, checked: boolean): NscFlowInteger {
  const low = a.low + b.low, high = a.high + b.high + Math.floor(low / 4294967296);
  if (checked && high > 4294967295) throw new Error("virtual flow index overflow");
  return { low: low % 4294967296, high: high % 4294967296 };
}
function nscvFlowSubtract(a: NscFlowInteger, b: NscFlowInteger): NscFlowInteger {
  if (nscvFlowCompare(a, b) <= 0) return { low: 0, high: 0 };
  return { low: a.low >= b.low ? a.low - b.low : a.low + 4294967296 - b.low, high: a.high - b.high - (a.low < b.low ? 1 : 0) };
}
function nscvFlowMin(a: NscFlowInteger, b: NscFlowInteger): NscFlowInteger { return nscvFlowCompare(a, b) < 0 ? a : b; }
function nscvFlowMax(a: NscFlowInteger, b: NscFlowInteger): NscFlowInteger { return nscvFlowCompare(a, b) > 0 ? a : b; }
function nscvFlowZero(a: NscFlowInteger): boolean { return a.low === 0 && a.high === 0; }
function nscvFlowIndex(value: number, ceil: boolean, checked: boolean): NscFlowInteger {
  if (!Number.isFinite(value) || value <= 0) return { low: 0, high: 0 };
  const integer = ceil ? Math.ceil(value) : Math.floor(value);
  if (integer >= 18446744073709551616) {
    if (checked) throw new Error("virtual flow floating index overflow");
    return { low: 4294967295, high: 4294967295 };
  }
  return nscvFlowSmall(integer);
}
function nscvFlowSemantic(value: NscFlowInteger): number { return value.high > 0 ? 4294967295 : value.low; }
function nscvFlowWrite(out: DataView, at: number, value: NscFlowInteger): void { out.setUint32(at, value.low, true); out.setUint32(at + 4, value.high, true); }

type NscFlowRange = { start: NscFlowInteger; end: NscFlowInteger; extent: number; gap: number; offset: number; total: number };
/** Shared uniform-window arithmetic over exact integer lanes and native
 * integer-to-f32 conversion facts. Native owns measurement and traversal. */
function nscvFlowRange(count: NscFlowInteger, countF: number, authored: number, gapValue: number, viewportValue: number, scroll: number, overscan: NscFlowInteger, flags: number): NscFlowRange {
  const zero = { low: 0, high: 0 }, f = Math.fround, max = nscvSurfaceMax;
  if (nscvFlowZero(count) || authored <= 0 || viewportValue <= 0) return { start: zero, end: zero, extent: 0, gap: 0, offset: 0, total: 0 };
  const extent = max(0, authored), gap = max(0, gapValue), stride = f(extent + gap), viewport = max(0, viewportValue);
  const total = f(f(countF * extent) + f(max(0, f(countF - 1)) * gap));
  const maximum = max(0, f(total - viewport)), raw = Number.isFinite(scroll) ? scroll : 0;
  const offset = nscvSurfaceClamp(max(0, raw), 0, maximum, (flags & 1) !== 0);
  const layout = nscvSurfaceClamp(raw, -viewport, f(maximum + viewport), (flags & 1) !== 0);
  const first = nscvFlowMin(nscvFlowSubtract(count, nscvFlowSmall(1)), nscvFlowIndex(f(offset / stride), false, (flags & 2) !== 0));
  const visibleEnd = nscvFlowMin(count, nscvFlowIndex(f(f(f(offset + viewport) + gap) / stride), true, (flags & 2) !== 0));
  return { start: nscvFlowSubtract(first, overscan), end: nscvFlowMin(count, nscvFlowAdd(visibleEnd, overscan, (flags & 2) !== 0)), extent, gap, offset: layout, total };
}

/** Virtual row placement, scroll displacement and content extents over
 * explicit native measurement facts. Requests/results have copied ownership;
 * index lanes retain every usize bit independently of JS number precision. */
function nscvVirtualFlow(request: Uint8Array): Uint8Array {
  if (request.length < 128 || request[0] !== 8) throw new Error("invalid virtual flow request");
  const op = request[1]!, flags = request[2]!, axes = request[3]!;
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength), count = wire.getUint32(4, true);
  if (op > 2 || flags > 3 || axes > 7 || request.length !== 128 + count * 64 || wire.getUint32(120, true) !== 0 || wire.getUint32(124, true) !== 0) throw new Error("invalid virtual flow operation, flags or length");
  const first = nscvFlowInteger(wire, 8), declared = nscvFlowInteger(wire, 16), anchor = nscvFlowInteger(wire, 24), overscan = nscvFlowInteger(wire, 32);
  const semantic = nscvFlowInteger(wire, 40), gridRows = nscvFlowInteger(wire, 48), f = Math.fround, max = nscvSurfaceMax;
  const v = (at: number): number => wire.getFloat32(at, true);
  let flows = 0;
  for (let i = 0; i < count; i++) { const lane = wire.getUint32(128 + i * 64, true); if (lane > 1) throw new Error("invalid virtual flow child flags"); if (lane === 1) flows++; }
  const checked = (flags & 2) !== 0, windowed = !nscvFlowZero(declared), variable = windowed && v(116) > 0;
  const builtEnd = op === 1 && variable ? declared : op !== 2 && windowed ? nscvFlowAdd(first, nscvFlowSmall(flows), checked) : nscvFlowSmall(flows);
  let items = windowed ? nscvFlowMax(declared, builtEnd) : op === 1 && (axes & 4) !== 0 && flows > 0 ? gridRows : flows > 0 ? nscvFlowSmall(flows) : semantic;
  let itemsF = windowed ? nscvFlowCompare(declared, builtEnd) >= 0 ? v(64) : v(60) : op === 1 && (axes & 4) !== 0 && flows > 0 ? v(68) : flows > 0 ? v(56) : v(72);
  if (op === 0 && flows === 0) { items = nscvFlowSmall(0); itemsF = 0; }
  const x = v(76), y = v(80), width = v(84), viewport = v(88), gap = max(0, v(92));
  const extent = v(96) > 0 ? v(96) : v(100), scroll = v(108);
  const range = variable || op === 2 ? { start: nscvFlowSmall(0), end: items, extent: 0, gap, offset: 0, total: v(116) }
    : nscvFlowRange(items, itemsF, extent, v(92), viewport, scroll, op === 1 ? nscvFlowSmall(0) : overscan, flags);
  const result = new Uint8Array(48 + count * 32), out = new DataView(result.buffer);
  out.setUint32(0, count, true); out.setUint32(4, op === 2 ? 4 : op === 1 ? variable ? 2 : 3 : variable ? 1 : 0, true);
  out.setUint32(8, nscvFlowSemantic(items), true); out.setFloat32(12, range.extent, true);
  out.setFloat32(16, op === 1 && variable ? v(116) : range.total, true); out.setFloat32(20, range.offset, true); nscvFlowWrite(out, 40, items);
  const translatedX = op === 2 ? f(x - ((axes & 1) !== 0 ? v(104) : 0)) : x;
  const translatedY = op === 2 ? f(y - ((axes & 2) !== 0 ? scroll : 0)) : y;
  for (const [at, value] of [[24, translatedX], [28, translatedY], [32, width], [36, viewport]]) out.setFloat32(at!, value!, true);
  let anchorChild = 0, leading = 0;
  if (op === 0 && variable && flows > 0) {
    const boundedAnchor = nscvFlowMin(nscvFlowSubtract(anchor, first), nscvFlowSmall(flows - 1)); anchorChild = boundedAnchor.low;
    const total = max(0, v(116)), maximum = max(0, f(total - viewport)), raw = Number.isFinite(scroll) ? scroll : 0;
    const offset = nscvSurfaceClamp(raw, -viewport, f(maximum + viewport), (flags & 1) !== 0);
    leading = f(f(y + max(0, v(112))) - offset);out.setFloat32(20, offset, true);
    let before = 0;
    for (let i = 0; i < count && before < anchorChild; i++) {
      const at = 128 + i * 64;if (wire.getUint32(at, true) === 0) continue;
      const height = nscvSurfaceBound(v(at + 12) > 0 ? v(at + 12) : v(at + 40), v(at + 24), v(at + 28));
      leading = f(leading - f(height + gap)); before++;
    }
  }
  let index = 0;
  for (let i = 0; i < count; i++) {
    const at = 128 + i * 64, target = 48 + i * 32;
    if (wire.getUint32(at, true) === 0 || op === 1) continue;
    const absolute = op === 2 ? nscvFlowSmall(0) : nscvFlowAdd(first, nscvFlowSmall(index), checked); index++;
    if (op === 0 && !variable && (nscvFlowCompare(absolute, range.start) < 0 || nscvFlowCompare(absolute, range.end) >= 0)) continue;
    const measureHorizontal = op === 2 && (axes & 1) !== 0 && v(at + 8) <= 0;
    out.setUint32(target, measureHorizontal ? 3 : 1, true);out.setUint32(target + 4, nscvFlowSemantic(absolute), true);nscvFlowWrite(out, target + 24, absolute);
    let childX: number, childY: number, childWidth: number, childHeight: number;
    if (op === 2) {
      childX = v(at + 48);childY = v(at + 52);childWidth = measureHorizontal ? max(v(at + 56), v(at + 44)) : v(at + 56);childHeight = v(at + 60);
    } else {
      childX = f(x + v(at + 32));childWidth = nscvSurfaceBound(v(at + 8) > 0 ? v(at + 8) : width, v(at + 16), v(at + 20));
      childHeight = nscvSurfaceBound(v(at + 12) > 0 ? v(at + 12) : variable ? v(at + 40) : range.extent, v(at + 24), v(at + 28));
      childY = variable ? f(leading + v(at + 36)) : f(f(f(y + f(v(at + 4) * f(range.extent + range.gap))) - range.offset) + v(at + 36));
      if (variable) leading = f(leading + f(childHeight + gap));
    }
    for (const [offset, value] of [[8, childX], [12, childY], [16, childWidth], [20, childHeight]]) out.setFloat32(target + offset!, value!, true);
  }
  return result;
}

const nscvSemanticRoles = [1,1,1,1,14,14,1,11,1,1,1,19,1,1,1,1,1,1,1,8,8,8,1,8,9,9,2,4,4,4,2,5,5,5,5,6,6,6,6,6,7,10,12,13,15,2,16,17,18,20,5,21,22,0,0,22,23,1,26,24,1,4,6];
type NscSemanticMetric = { present: boolean; offset: number; viewport: number; content: number };
type NscSemanticScroll = { vertical: NscSemanticMetric; horizontal: NscSemanticMetric; primary: NscSemanticMetric; value: number; scrollable: boolean };

/** Exact unsigned division for authored grid columns and child counts. No
 * pointer, usize, or declared index crosses through a floating JS number. */
function nscvSemanticDivide(value: NscFlowInteger, divisor: NscFlowInteger): { quotient: NscFlowInteger; remainder: NscFlowInteger } {
  if (nscvFlowZero(divisor)) throw new Error("zero semantic grid divisor");
  let low = 0, high = 0, quotientLow = 0, quotientHigh = 0;
  for (let bit = 63; bit >= 0; bit--) {
    const carry = high >= 2147483648;
    high = (high * 2 + Math.floor(low / 2147483648)) % 4294967296;
    low = (low * 2 + ((bit >= 32 ? value.high >>> (bit - 32) : value.low >>> bit) & 1)) % 4294967296;
    if (carry || nscvFlowCompare({ low, high }, divisor) >= 0) {
      const borrow = low < divisor.low ? 1 : 0;
      low = (low - divisor.low + 4294967296) % 4294967296;
      high = (high - divisor.high - borrow + 4294967296) % 4294967296;
      if (bit >= 32) quotientHigh += 2 ** (bit - 32); else quotientLow += 2 ** bit;
    }
  }
  return { quotient: { low: quotientLow, high: quotientHigh }, remainder: { low, high } };
}

/** Complete semantic reduction over measured native tree facts. String and
 * text-range storage stays native-owned; selectors choose those borrowed
 * fields. The established semantic-action policy supplies action facts. */
function nscvSemanticTree(request: Uint8Array): Uint8Array {
  if (request.length < 16 || request[0] !== 9 || request[1]! > 1 || request[2]! > 1 || request[3] !== 0) throw new Error("invalid semantic tree header");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const count = wire.getUint32(4, true), target = wire.getUint32(8, true), capacity = wire.getUint32(12, true), query = request[1] === 1;
  if (request.length !== 16 + count * 128 || (query ? target >= count : target !== 0)) throw new Error("invalid semantic tree length or target");
  const word = (i: number, at: number): number => wire.getUint32(16 + i * 128 + at, true);
  const value = (i: number, at: number): number => wire.getFloat32(16 + i * 128 + at, true);
  const integer = (i: number, at: number): NscFlowInteger => nscvFlowInteger(wire, 16 + i * 128 + at);
  for (let i = 0; i < count; i++) {
    if (word(i, 0) > 62 || word(i, 4) > 26 || word(i, 16) > 32767 || word(i, 20) > 1023 || word(i, 24) > 2047 ||
        (word(i, 12) !== 4294967295 && word(i, 12) >= count)) throw new Error("invalid semantic node facts");
    for (let at = 104; at < 128; at += 4) if (word(i, at) !== 0) throw new Error("invalid semantic node reserved bytes");
  }
  const result = new Uint8Array(16 + (query ? 1 : count) * 144), out = new DataView(result.buffer), f = Math.fround, max = nscvSurfaceMax;
  const missing = 4294967295, flag = (i: number, bit: number): boolean => (word(i, 16) & bit) !== 0;
  const kind = (i: number): number => word(i, 0), parent = (i: number): number => word(i, 12), depth = (i: number): number => word(i, 8);
  const modal = (i: number): boolean => kind(i) >= 19 && kind(i) <= 21;
  const skip = (i: number): number => { let next = i + 1; while (next < count && depth(next) > depth(i)) next++; return next; };
  const childCount = (p: number, k: number): number => { let total = 0; for (let i = 0; i < count; i++) if (parent(i) === p && (k < 0 || kind(i) === k)) total++; return total; };
  const ordinal = (p: number, child: number, k: number): number => { let at = 0; for (let i = 0; i < count; i++) if (parent(i) === p && (k < 0 || kind(i) === k)) { if (i === child) return at; at++; } return missing; };
  const columns = (i: number): NscFlowInteger => { const children = integer(i, 44), authored = integer(i, 36); return nscvFlowZero(children) ? children : nscvFlowZero(authored) ? children : authored; };
  const rows = (i: number, cols: NscFlowInteger): NscFlowInteger => {
    if (flag(i, 4096)) return nscvFlowSmall(word(i, 28));
    const children = integer(i, 44);
    return nscvFlowZero(children) || nscvFlowZero(cols) ? nscvFlowSmall(0) : nscvFlowAdd(nscvFlowSmall(1), nscvSemanticDivide(nscvFlowSubtract(children, nscvFlowSmall(1)), cols).quotient, true);
  };
  const table = (i: number): boolean => kind(i) === 4 || kind(i) === 5;
  const tableRows = (i: number): number => flag(i, 4096) ? word(i, 28) : childCount(i, 43);
  const scroll = (i: number): NscSemanticScroll => {
    const vx = value(i, 68), vy = value(i, 72), vw = value(i, 76), vh = value(i, 80), virtual = flag(i, 4);
    const empty = { present: false, offset: 0, viewport: 0, content: 0 };
    let vertical: NscSemanticMetric = empty, horizontal: NscSemanticMetric = empty;
    for (let axis = 0; axis < 2; axis++) {
      if (axis === 0 ? kind(i) === 6 && !virtual && !flag(i, 64) : kind(i) !== 6 || virtual || !flag(i, 32)) continue;
      const extent = axis === 0 ? vh : vw, origin = axis === 0 ? vy : vx, raw = value(i, axis === 0 ? 84 : 88);
      let reach = f(origin + extent), content: number;
      if (axis === 0 && virtual) content = max(extent, value(i, 100));
      else {
        let child = i + 1;
        while (child < count && depth(child) > depth(i)) {
          if (axis === 0 ? modal(child) || flag(child, 8) && parent(child) === i : modal(child) || flag(child, 8)) { child = skip(child); continue; }
          reach = max(reach, f(f(value(child, axis === 0 ? 56 : 52) + value(child, axis === 0 ? 64 : 60)) + raw));
          if (axis === 0 ? kind(child) === 14 : kind(child) === 6 || flag(child, 16) || flag(child, 4) || kind(child) === 14 && !flag(child, 128)) child = skip(child); else child++;
        }
        content = max(0, f(reach - origin));
      }
      const maximum = max(0, f(content - extent));
      const metric = { present: true, offset: nscvSurfaceClamp(raw < 0 ? 0 : raw, 0, maximum, request[2] === 1), viewport: extent, content };
      if (axis === 0) vertical = metric; else horizontal = metric;
    }
    const verticalRange = vertical.present && vertical.content > vertical.viewport, horizontalRange = horizontal.present && horizontal.content > horizontal.viewport;
    let primary = verticalRange || vertical.present && !horizontalRange ? vertical : horizontal.present ? horizontal : vertical;
    const exposes = kind(i) === 6 || virtual && (kind(i) === 3 || kind(i) === 7 || table(i));
    if (!exposes || vw <= 0 || vh <= 0) primary = empty;
    const maximum = max(0, f(primary.content - primary.viewport));
    return { vertical, horizontal, primary, value: maximum > 0 ? f(primary.offset / maximum) : 0, scrollable: primary.present && maximum > 0 };
  };
  let emitted = 0, hidden = missing, concealed = missing;
  const stack: number[] = []; for (let d = 0; d < 32; d++) stack.push(missing);
  for (let i = query ? target : 0; i < (query ? target + 1 : count); i++) {
    const d = depth(i), k = kind(i), state = word(i, 20), disabled = (state & 8) !== 0;
    const role = word(i, 4) || nscvSemanticRoles[k]!;
    if (!query) {
      if (d >= 32) { out.setUint32(4, 1, true); break; }
      if (hidden !== missing) { if (d > hidden) continue; hidden = missing; }
      if (concealed !== missing) { if (d > concealed) continue; concealed = missing; }
      for (let level = d + 1; level < 32; level++) stack[level] = missing;
      if (flag(i, 1)) { hidden = d; continue; }
      if (k === 14 && !flag(i, 128)) concealed = d;
      if (role === 0 || flag(i, 2)) continue;
      if (emitted >= capacity) { out.setUint32(4, 2, true); break; }
    }
    const at = 16 + emitted * 144, s = scroll(i);
    out.setUint32(at, i, true);
    let ancestor = missing; if (!query) for (let level = d - 1; level >= 0; level--) if (stack[level] !== missing) { ancestor = stack[level]!; break; }
    out.setUint32(at + 4, ancestor, true); out.setUint32(at + 8, role, true);
    let actions = word(i, 24); if (s.scrollable && !disabled) actions |= 1 | 8 | 16;
    const selected = (state & 16) !== 0 || value(i, 84) >= 0.5;
    let composedState = state;
    if ((state & 256) === 0) {
      if (k === 14) composedState |= 256 | (selected ? 512 : 0);
      else if (k === 34 || k === 38) composedState |= 256;
      else if (k === 23 || k === 24 || k === 25) composedState |= 256 | 512;
    }
    let hasValue = flag(i, 512), semanticValue = value(i, 92);
    if (!hasValue) {
      if (k === 48 || k === 42 || k === 41 || k === 44 || k === 46 || k === 14 || k === 47 || k === 49 || k === 50 || k === 32) { hasValue = true; semanticValue = selected ? 1 : 0; }
      else if (k === 51 || k === 52 || k === 58) { hasValue = true; semanticValue = nscvSurfaceClamp(value(i, 84), 0, 1, request[2] === 1); }
      else if (k === 56 && flag(i, 1024)) { hasValue = true; semanticValue = value(i, 96); }
    }
    if (s.primary.present) { hasValue = true; semanticValue = s.value; }
    const focusable = !disabled && !flag(i, 1) && !flag(i, 2) && (flag(i, 8192) || flag(i, 16384) || (actions & 1) !== 0);
    const text = k >= 35 && k <= 39 || k === 62, placeholder = k >= 34 && k <= 39;
    out.setUint32(at + 12, (flag(i, 256) ? 1 : 0) | (text ? 2 : 0) | (placeholder ? 4 : 0) | (focusable ? 8 : 0) | (hasValue ? 16 : 0), true);
    out.setUint32(at + 16, composedState, true); out.setUint32(at + 20, actions, true); out.setFloat32(at + 24, semanticValue, true);
    const p = parent(i);
    if (p !== missing && kind(p) === 7) {
      let listCount = 0, listIndex = missing;
      if (flag(i, 2048) && flag(i, 4096)) { listCount = word(i, 28); listIndex = word(i, 32); }
      else if (k === 42) { listCount = childCount(p, 42); if (listCount > 0) listIndex = ordinal(p, i, 42); }
      if (listIndex !== missing || flag(i, 2048) && flag(i, 4096)) {
        out.setUint32(at + 28, 1, true); out.setUint32(at + 32, listIndex, true); out.setUint32(at + 36, listCount, true);
      }
    }
    let gridMask = 0;
    const gridValue = (bit: number, offset: number, value: NscFlowInteger): void => { gridMask |= bit; nscvFlowWrite(out, at + offset, value); };
    let gridParent = p;
    if (k === 3) {
      if (word(i, 4) === 14) { const cols = columns(i); gridValue(4, 60, rows(i, cols)); gridValue(8, 68, cols); }
    } else if (table(i)) {
      let maximum = 0; for (let child = 0; child < count; child++) if (parent(child) === i && kind(child) === 43) maximum = Math.max(maximum, childCount(child, 44));
      gridValue(4, 60, nscvFlowSmall(tableRows(i))); gridValue(8, 68, nscvFlowSmall(maximum));
    } else {
      if (gridParent !== missing && kind(gridParent) === 3 && word(gridParent, 4) === 14) {
        const cols = columns(gridParent), index = flag(i, 2048) ? word(i, 32) : ordinal(gridParent, i, -1);
        if (!nscvFlowZero(cols) && (index !== missing || flag(i, 2048))) { const divided = nscvSemanticDivide(nscvFlowSmall(index), cols); gridValue(1, 44, divided.quotient); gridValue(2, 52, divided.remainder); gridValue(4, 60, rows(gridParent, cols)); gridValue(8, 68, cols); }
      } else if (k === 43 || k === 44) {
        const row = k === 43 ? i : p;
        if (row !== missing && kind(row) === 43) {
          gridParent = parent(row);
          if (gridParent !== missing && table(gridParent)) {
            const index = flag(row, 2048) ? word(row, 32) : ordinal(gridParent, row, 43);
            if (index !== missing || flag(row, 2048)) gridValue(1, 44, nscvFlowSmall(index));
            if (k === 44) { const cell = ordinal(row, i, 44); if (cell !== missing) gridValue(2, 52, nscvFlowSmall(cell)); }
            gridValue(4, 60, nscvFlowSmall(tableRows(gridParent))); gridValue(8, 68, nscvFlowSmall(childCount(row, 44)));
          }
        }
      }
    }
    out.setUint32(at + 40, gridMask, true);
    for (let axis = 0; axis < 3; axis++) {
      const metric = axis === 0 ? s.primary : axis === 1 ? s.vertical : s.horizontal;
      const offset = axis === 0 ? 76 : axis === 1 ? 100 : 116;
      out.setUint32(at + offset, metric.present ? 1 : 0, true); out.setFloat32(at + offset + 4, metric.offset, true); out.setFloat32(at + offset + 8, metric.viewport, true); out.setFloat32(at + offset + 12, metric.content, true);
    }
    out.setFloat32(at + 92, s.value, true); out.setUint32(at + 96, s.scrollable ? 1 : 0, true);
    if (!query) stack[d] = emitted;
    emitted++;
  }
  out.setUint32(0, emitted, true); return result;
}

/** Retained variable-window transitions. Estimate arithmetic and search decisions use bounded copied facts; sparse corrections cross once per measured
 * batch and hot window coordination uses small scalar records. No retained
 * native address or borrowed model bytes escape this copied boundary. */
function nscvExtentPolicy(request: Uint8Array): Uint8Array {
  if (request.length < 4 || request[0] !== 10 || request[2]! > 1) throw new Error("invalid extent policy header");
  const op = request[1]!, w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const f = Math.fround, max = nscvSurfaceMax, integer = (at: number): NscFlowInteger => nscvFlowInteger(w, at);
  const v = (at: number): number => w.getFloat32(at, true);
  const fixed = (length: number): void => { if (request.length !== length) throw new Error("invalid extent policy length"); };
  if (op === 0) {
    fixed(72); if (request[3] !== 0) throw new Error("invalid extent sync flags");
    const oldId = integer(8), id = integer(16), oldCount = integer(24), count = integer(32), oldBase = integer(40), base = integer(48);
    if (nscvFlowZero(id) || w.getUint32(4,true) !== 0 || w.getUint32(64,true) !== 0 || w.getUint32(68,true) !== 0) throw new Error("invalid extent sync identity");
    const fresh = nscvFlowZero(oldId) || nscvFlowCompare(oldId,id) !== 0;
    const mode = fresh ? 1 : nscvFlowCompare(base,oldBase) < 0 ? 2 : nscvFlowCompare(base,oldBase) > 0 ? 3 : nscvFlowCompare(count,oldCount) > 0 ? 4 : nscvFlowCompare(count,oldCount) < 0 ? 5 : 0;
    const chunkSource = mode === 4 ? oldCount : mode === 5 ? count : nscvFlowSmall(0);
    const firstChunk = { low: Math.floor(chunkSource.low / 64) + (chunkSource.high % 64) * 67108864, high: Math.floor(chunkSource.high / 64) };
    const shift = mode === 2 ? nscvFlowMin(nscvFlowSubtract(oldBase,base),count) : mode === 3 ? nscvFlowMin(nscvFlowSubtract(base,oldBase),oldCount) : nscvFlowSmall(0);
    const result = new Uint8Array(40), out = new DataView(result.buffer);
    result[0] = mode; result[1] = mode === 1 ? 1 : mode === 4 ? 2 : mode === 2 ? 4 : 0;
    out.setFloat32(4,nscvExtentClean(v(56)),true); out.setFloat32(8,fresh ? 0 : v(60),true);
    nscvFlowWrite(out,16,firstChunk); nscvFlowWrite(out,24,shift); return result;
  }
  if (op === 1) return nscvExtentCorrections(request);
  if (op === 2) {
    fixed(32); if (request[3]! > 7) throw new Error("invalid extent window flags");
    const flags = request[3]!, retained = (flags & 4) !== 0, trailing = (flags & 1) !== 0, mounted = (flags & 2) !== 0;
    let offset = retained ? f(v(4) + v(8)) : v(4);
    if (trailing && (!mounted || (retained && v(20) >= 0 && v(4) >= f(max(0,f(v(20)-v(24))) - 1)))) offset = max(0,f(v(12)-v(16)));
    const result = new Uint8Array(4); new DataView(result.buffer).setFloat32(0,offset,true); return result;
  }
  if (op === 3) {
    fixed(32); if (request[3] !== 0 || w.getUint32(4,true) !== 0 || w.getUint32(28,true) !== 0) throw new Error("invalid extent range bounds");
    const result = new Uint8Array(16), out = new DataView(result.buffer);
    if (nscvFlowZero(integer(8)) || v(20) <= 0) return result;
    const maximum = max(0,f(v(16)-v(20))), raw = Number.isFinite(v(24)) ? v(24) : 0;
    const offset = nscvSurfaceClamp(max(0,raw),0,maximum,request[2] === 1);
    out.setUint32(0,1,true); out.setFloat32(4,offset,true); out.setFloat32(8,nscvSurfaceClamp(raw,-v(20),f(maximum+v(20)),request[2] === 1),true);
    out.setFloat32(12,f(offset+v(20)),true); return result;
  }
  if (op === 4 || op === 7) {
    fixed(op === 4 ? 48 : 64); if (request[3] !== 0 || w.getUint32(4,true) !== 0 || w.getUint32(40,true) !== 0 && op === 4 || w.getUint32(44,true) !== 0 && op === 4) throw new Error("invalid extent index facts");
    const count = integer(8), overscan = integer(32), first = nscvFlowMin(nscvFlowSubtract(count,nscvFlowSmall(1)),integer(16));
    let end = nscvFlowMin(count,nscvFlowAdd(integer(24),nscvFlowSmall(1),true));
    if (op === 4 && nscvFlowCompare(end,first) <= 0) end = nscvFlowAdd(first,nscvFlowSmall(1),true);
    const start = nscvFlowSubtract(first,overscan), last = nscvFlowSubtract(end,nscvFlowSmall(1));
    end = nscvFlowMin(count,nscvFlowAdd(end,overscan,true));
    if (op === 7) {
      if (w.getUint32(56,true) !== 0 || w.getUint32(60,true) !== 0) throw new Error("invalid extent coverage padding");
      const result = new Uint8Array(1); result[0] = nscvFlowCompare(start,integer(40)) < 0 || nscvFlowCompare(end,integer(48)) > 0 ? 1 : 0; return result;
    }
    const result = new Uint8Array(32), out = new DataView(result.buffer);
    nscvFlowWrite(out,0,start); nscvFlowWrite(out,8,end); nscvFlowWrite(out,16,first); nscvFlowWrite(out,24,last); return result;
  }
  if (op === 5) {
    fixed(32); if (request[3] !== 0 || w.getUint32(28,true) !== 0) throw new Error("invalid extent range finish");
    const result = new Uint8Array(24), out = new DataView(result.buffer);
    for (let i=0;i<6;i++) out.setFloat32(i*4,i === 0 ? v(20) : i === 1 ? v(24) : i === 2 ? v(4) : i === 3 ? v(12) : i === 4 ? max(0,f(v(4)-v(8))) : v(16),true);
    return result;
  }
  if (op === 6) {
    if (request.length < 24 || request[3] !== 0 || w.getUint32(12,true) !== 0) throw new Error("invalid extent slot header");
    const count=w.getUint32(4,true), declared=w.getUint32(8,true), id=integer(16);
    if (count > 254 || declared > 254 || request.length !== 24 + (count+declared)*8) throw new Error("invalid extent slot table");
    const result=new Uint8Array(2); result[1]=255; if(nscvFlowZero(id))return result;
    for(let i=0;i<count;i++)if(nscvFlowCompare(integer(24+i*8),id) === 0){result[1]=i;return result;}
    for(let i=0;i<count;i++)if(nscvFlowZero(integer(24+i*8))){result[1]=i;return result;}
    for(let i=0;i<count;i++){
      let keep=false;for(let j=0;j<declared;j++)if(nscvFlowCompare(integer(24+i*8),integer(24+(count+j)*8)) === 0)keep=true;
      if(!keep){result[0]=1;result[1]=i;return result;}
    }
    return result;
  }
  if (op === 8) {
    fixed(16);if(request[3]! > 1 || w.getUint32(12,true) !== 0)throw new Error("invalid extent pending shift");
    const result=new Uint8Array(4);new DataView(result.buffer).setFloat32(0,request[3] === 1 ? f(v(4)-v(8)) : f(v(4)+v(8)),true);return result;
  }
  if (op === 9 || op === 10) {
    if (request.length < 32 || request[3] !== 0) throw new Error("invalid extent estimate header");
    const count=w.getUint32(4,true);
    if (count > (op === 9 ? 1024 : 63) || request.length !== 32+count*4 || w.getUint32(28,true)!==0) throw new Error("invalid extent estimate batch");
    if (op === 9) {
      const result=new Uint8Array(4*Math.ceil(count/64)),out=new DataView(result.buffer);let prefix=v(8);
      for(let chunk=0;chunk<Math.ceil(count/64);chunk++){
        let sum=0;for(let i=chunk*64;i<Math.min(count,(chunk+1)*64);i++)sum=f(sum+v(32+i*4));
        prefix=f(prefix+sum);out.setFloat32(chunk*4,prefix,true);
      }
      return result;
    }
    let prefix=v(8);for(let i=0;i<count;i++)prefix=f(prefix+v(32+i*4));
    if(v(16)>0)prefix=f(prefix+f(v(16)*f(v(12)/v(20))));
    const result=new Uint8Array(4);new DataView(result.buffer).setFloat32(0,prefix,true);return result;
  }
  if (op === 11) {
    fixed(24);if(request[3]!>1 || w.getUint32(20,true)!==0)throw new Error("invalid extent scalar query");
    const result=new Uint8Array(4),out=new DataView(result.buffer);
    out.setFloat32(0,request[3]===1?max(0,f(v(4)+v(8))):f(f(v(4)+v(8))+f(v(12)*v(16))),true);return result;
  }
  if (op === 12) {
    fixed(40);if(request[3]!>3 || w.getUint32(4,true)!==0)throw new Error("invalid extent search continuation");
    const checked=(request[3]!&1)!==0,continued=(request[3]!&2)!==0,count=integer(8),target=max(0,v(32));
    let low=continued?integer(16):nscvFlowSmall(0),high=continued?integer(24):nscvFlowSubtract(count,nscvFlowSmall(1));
    const midpoint=(a:NscFlowInteger,b:NscFlowInteger):NscFlowInteger=>{
      const sum=nscvFlowAdd(nscvFlowAdd(a,b,checked),nscvFlowSmall(1),checked);
      return {low:Math.floor(sum.low/2)+(sum.high%2)*2147483648,high:Math.floor(sum.high/2)};
    };
    if(nscvFlowCompare(low,high)>0 || (!nscvFlowZero(count)&&nscvFlowCompare(high,count)>=0) || (continued&&nscvFlowCompare(low,high)>=0))throw new Error("invalid extent search bounds");
    if(continued){const mid=midpoint(low,high);if(v(36)<=target)low=mid;else high=nscvFlowSubtract(mid,nscvFlowSmall(1));}
    const active=nscvFlowCompare(low,high)<0,result=new Uint8Array(32),out=new DataView(result.buffer);
    nscvFlowWrite(out,0,low);nscvFlowWrite(out,8,high);nscvFlowWrite(out,16,active?midpoint(low,high):low);out.setUint32(24,active?1:0,true);out.setFloat32(28,target,true);return result;
  }
  if (op === 13) {
    fixed(48);if(request[3]!>6 || (request[3]!&3)>2 || w.getUint32(4,true)!==0)throw new Error("invalid extent query plan");
    const mode=request[3]!&3,count=integer(8),index=mode===2?count:nscvFlowMin(integer(16),count),covered=integer(32),chunks=integer(40);
    if(nscvFlowCompare(covered,nscvFlowSmall(262144))>0 || nscvFlowCompare(covered,count)>0 || chunks.high!==0 || chunks.low!==Math.ceil(covered.low/64))throw new Error("invalid extent cache shape");
    const tail=nscvFlowCompare(index,covered)>0;
    const chunk=tail?chunks.low:Math.floor(index.low/64),start=tail?covered:nscvFlowSmall(chunk*64),samples=tail?0:nscvFlowSubtract(index,start).low;
    const extra=tail?nscvFlowSubtract(index,covered):nscvFlowSmall(0),gapCount=mode===2?nscvFlowSubtract(count,nscvFlowSmall(1)):index;
    const logical=mode===1?nscvFlowAdd(integer(24),index,(request[3]!&4)!==0):nscvFlowSmall(0);
    const result=new Uint8Array(64),out=new DataView(result.buffer);
    nscvFlowWrite(out,0,index);nscvFlowWrite(out,8,logical);nscvFlowWrite(out,16,start);nscvFlowWrite(out,24,extra);nscvFlowWrite(out,32,gapCount);
    out.setUint32(40,chunk,true);out.setUint32(44,samples,true);out.setUint32(48,tail?1:0,true);out.setUint32(52,mode===2&&nscvFlowZero(count)?1:0,true);return result;
  }
  if (op === 14) {
    fixed(24);if(request[3]!==0 || w.getUint32(4,true)!==0)throw new Error("invalid extent rebuild plan");
    const covered=nscvFlowMin(integer(8),nscvFlowSmall(262144)),chunks=Math.ceil(covered.low/64),first=nscvFlowMin(integer(16),nscvFlowSmall(chunks)).low,end=Math.min(first+16,chunks);
    const result=new Uint8Array(40),out=new DataView(result.buffer);
    out.setUint32(0,covered.low,true);out.setUint32(4,chunks,true);out.setUint32(8,first,true);out.setUint32(12,end,true);
    out.setUint32(16,Math.min(covered.low,first*64),true);out.setUint32(20,Math.min(covered.low,end*64),true);out.setUint32(24,first<chunks?1:0,true);return result;
  }
  if (op === 15) {
    if(request.length<40 || request[3]!>3)throw new Error("invalid extent composed query");
    const count=w.getUint32(4,true);if(count>63 || request.length!==40+count*4 || w.getUint32(36,true)!==0)throw new Error("invalid extent composed facts");
    const tail=(request[3]!&1)!==0,empty=(request[3]!&2)!==0;
    if((tail&&count!==0) || (tail&&!(v(20)>0)))throw new Error("invalid extent tail facts");
    let prefix=v(8);for(let i=0;i<count;i++)prefix=f(prefix+v(40+i*4));
    if(tail)prefix=f(prefix+f(v(16)*f(v(12)/v(20))));
    const gap=f(v(28)*v(32)),result=new Uint8Array(12),out=new DataView(result.buffer);
    out.setFloat32(0,prefix,true);out.setFloat32(4,gap,true);out.setFloat32(8,empty?0:f(f(prefix+v(24))+gap),true);return result;
  }
  throw new Error("unknown extent policy operation");
}
function nscvExtentClean(value:number):number{return !Number.isFinite(value) || value < 0 ? 0 : value;}
type NscExtentMeasured={index:NscFlowInteger;delta:number;prefix:number};
function nscvExtentDistance(a:NscFlowInteger,b:NscFlowInteger):NscFlowInteger{return nscvFlowCompare(a,b)>0?nscvFlowSubtract(a,b):nscvFlowSubtract(b,a);}
function nscvExtentCorrections(request:Uint8Array):Uint8Array{
  if(request.length<64 || request[3]!>5)throw new Error("invalid extent correction header");
  const w=new DataView(request.buffer,request.byteOffset,request.byteLength), mode=request[3]!, count=w.getUint32(4,true), rows=w.getUint32(8,true), f=Math.fround;
  if(count>2048 || w.getUint32(12,true)>1 || request.length!==64+count*16+rows*16 || w.getUint32(60,true)!==0 || (mode!==1 && mode!==3 && rows!==0))throw new Error("invalid extent correction table");
  const base=nscvFlowInteger(w,16), items=nscvFlowInteger(w,24);
  const anchor=mode===0 || mode===3?nscvFlowMin(nscvFlowInteger(w,32),items):nscvFlowInteger(w,32), logicalAnchor=mode===4 || mode===5?base:nscvFlowAdd(base,anchor,true);
  const measured:NscExtentMeasured[]=[];
  for(let i=0;i<count;i++){
    const at=64+i*16,index=nscvFlowInteger(w,at);
    if(i>0 && nscvFlowCompare(measured[i-1]!.index,index)>=0)throw new Error("invalid extent measurement ordering");
    measured.push({index,delta:w.getFloat32(at+8,true),prefix:w.getFloat32(at+12,true)});
  }
  let dirty=w.getUint32(12,true)===1,total=w.getFloat32(48,true),pending=w.getFloat32(44,true),before=w.getFloat32(40,true);
  const deltaBefore=():number=>{
    if(dirty)throw new Error("dirty extent query");
    for(const entry of measured)if(nscvFlowCompare(entry.index,logicalAnchor)>=0)return entry.prefix;
    return total;
  };
  if(mode===0 || mode===3){
    if(dirty)throw new Error("dirty extent correction begin");
    if(request[2]===0)before=f(f(w.getFloat32(52,true)+deltaBefore())+w.getFloat32(56,true));
  }
  if(mode===4){
    const end=nscvFlowAdd(base,items,true);
    // Both end truncation and head compaction mark the prefix dirty, even
    // when no entry drops. Preserve that intermediate state until finish.
    for(let i=measured.length-1;i>=0;i--)if(nscvFlowCompare(measured[i]!.index,base)<0 || nscvFlowCompare(measured[i]!.index,end)>=0)measured.splice(i,1);
    dirty=true;
  }
  for(let i=0;i<rows;i++){
    const at=64+count*16+i*16,physical=nscvFlowInteger(w,at);
    if(nscvFlowCompare(physical,items)>=0)continue;
    const index=nscvFlowAdd(base,physical,true),delta=f(nscvExtentClean(w.getFloat32(at+12,true))-nscvExtentClean(w.getFloat32(at+8,true)));
    let slot=0;while(slot<measured.length && nscvFlowCompare(measured[slot]!.index,index)<0)slot++;
    if(slot<measured.length && nscvFlowCompare(measured[slot]!.index,index)===0){
      if(Math.abs(f(measured[slot]!.delta-delta))<=0.25)continue;
      measured[slot]!.delta=delta;dirty=true;continue;
    }
    if(Math.abs(delta)<=0.25)continue;
    if(measured.length>=2048){
      const first=nscvExtentDistance(measured[0]!.index,logicalAnchor),last=nscvExtentDistance(measured[measured.length-1]!.index,logicalAnchor),incoming=nscvExtentDistance(index,logicalAnchor);
      const evictLast=nscvFlowCompare(last,first)>=0,far=evictLast?last:first;
      if(nscvFlowCompare(incoming,far)>=0)continue;
      measured.splice(evictLast?measured.length-1:0,1);dirty=true;
      slot=0;while(slot<measured.length && nscvFlowCompare(measured[slot]!.index,index)<0)slot++;
    }
    measured.splice(slot,0,{index,delta,prefix:0});dirty=true;
  }
  if(mode===2 || mode===3 || mode===5){
    if(dirty){total=0;for(const entry of measured){entry.prefix=total;total=f(total+entry.delta);}dirty=false;}
    if(mode!==5)pending=f(pending+f(f(f(w.getFloat32(52,true)+deltaBefore())+w.getFloat32(56,true))-before));
  }
  const result=new Uint8Array(32+measured.length*16),out=new DataView(result.buffer);
  nscvFlowWrite(out,0,anchor);out.setFloat32(8,before,true);out.setFloat32(12,pending,true);out.setFloat32(16,total,true);out.setUint32(20,dirty?1:0,true);out.setUint32(24,measured.length,true);
  for(let i=0;i<measured.length;i++){const at=32+i*16,e=measured[i]!;nscvFlowWrite(out,at,e.index);out.setFloat32(at+8,e.delta,true);out.setFloat32(at+12,e.prefix,true);}
  return result;
}

/** Ordered text-layout and glyph-cache reconciliation over copied key facts.
 * Native supplies hash buckets and stores resources; equality, admission,
 * retention and eviction belong here. No pointers or arena reset cross this call.
 */
function nscvTextCachePolicy(request: Uint8Array): Uint8Array {
  if (request.length < 48 || request[1]! > 1 || request[2] !== 0 || request[3] !== 0) throw new Error("invalid text cache request");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const current = w.getUint32(4,true), previous = w.getUint32(8,true), capacity = w.getUint32(12,true), actionCapacity = w.getUint32(16,true), total = current + previous;
  if (total > 4294967295 || request.length !== 48 + total * 80 || w.getUint32(20,true)!==0 || w.getUint32(40,true)!==0 || w.getUint32(44,true)!==0) throw new Error("invalid text cache shape");
  const glyph = request[1] === 1, slots = glyph ? 32768 : 8192, indexed = (current >= 64 || previous >= 64) && total <= slots / 2;
  const equal = (a:number,b:number):boolean => {
    const x=48+a*80,y=48+b*80;
    const floats = glyph ? 1 : 6;
    for(let i=0;i<floats;i++) if(w.getFloat32(x+i*4,true)!==w.getFloat32(y+i*4,true))return false;
    const start=glyph?4:24,end=glyph?24:64;
    for(let i=start;i<end;i++)if(request[x+i]!==request[y+i])return false;
    return true;
  };
  const entries:number[]=[],actions:number[]=[];
  const prevHeads=new Uint32Array(indexed?slots:0),entryHeads=new Uint32Array(indexed?slots:0),prevNext=new Uint32Array(indexed?previous:0),entryNext=new Uint32Array(indexed?Math.min(capacity,total):0);
  if(indexed) {
    // Reverse insertion retains the lowest original index at each chain head.
    for(let i=previous-1;i>=0;i--){const source=current+i,bucket=w.getUint32(48+source*80+72,true)&(slots-1);prevNext[i]=prevHeads[bucket]!;prevHeads[bucket]=i+1;}
  }
  const lookup = (source:number,old:boolean):number => {
    if(indexed){const heads=old?prevHeads:entryHeads,next=old?prevNext:entryNext,bucket=w.getUint32(48+source*80+72,true)&(slots-1);let match=-1;
      for(let stored=heads[bucket]!;stored>0;stored=next[stored-1]!){const i=stored-1;if(equal(source,old?current+i:entries[i]!) && (match<0 || i<match))match=i;}
      return match;
    }
    const count=old?previous:entries.length;
    for(let i=0;i<count;i++)if(equal(source,old?current+i:entries[i]!))return i;
    return -1;
  };
  let failed=false;
  const appendEntry=(source:number):boolean=>{if(entries.length>=capacity)return false;const index=entries.length;entries.push(source);if(indexed){const bucket=w.getUint32(48+source*80+72,true)&(slots-1);entryNext[index]=entryHeads[bucket]!;entryHeads[bucket]=index+1;}return true;};
  const appendAction=(kind:number,source:number,cache:number):boolean=>{if(actions.length/3>=actionCapacity)return false;actions.push(kind,source,cache);return true;};
  for(let i=0;i<current;i++){
    if(lookup(i,false)>=0)continue;
    const old=lookup(i,true);
    if(!appendEntry(i) || !appendAction(old<0?0:1,i,old)){failed=true;break;}
  }
  if(!failed)for(let i=0;i<previous;i++){
    const source=current+i;if(lookup(source,false)>=0)continue;
    const last={low:w.getUint32(48+source*80+64,true),high:w.getUint32(48+source*80+68,true)},frame={low:w.getUint32(24,true),high:w.getUint32(28,true)},retention={low:w.getUint32(32,true),high:w.getUint32(36,true)};
    const warm=!nscvFlowZero(retention) && (nscvFlowCompare(frame,last)<=0 || nscvFlowCompare(nscvFlowSubtract(frame,last),retention)<=0);
    if(warm && entries.length<capacity){if(!appendEntry(source) || !appendAction(1,source,i)){failed=true;break;}}
    else if(!appendAction(2,source,i)){failed=true;break;}
  }
  const result=new Uint8Array(16+entries.length*4+actions.length*4),out=new DataView(result.buffer);
  out.setUint32(0,entries.length,true);out.setUint32(4,actions.length/3,true);out.setUint32(8,failed?1:0,true);
  for(let i=0;i<entries.length;i++)out.setUint32(16+i*4,entries[i]!,true);
  for(let i=0;i<actions.length;i++)out.setUint32(16+entries.length*4+i*4,actions[i]!<0?4294967295:actions[i]!,true);
  return result;
}

/** Copied render-cache keys. Native retains fingerprints, resources and GPU objects. */
function nscvRenderCachePolicy(request: Uint8Array): Uint8Array {
  if (request.length < 24 || request[1]! > 5 || request[2] !== 0 || request[3] !== 0) throw new Error("invalid render cache request");
  const input = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const current = input.getUint32(4, true), previous = input.getUint32(8, true);
  const capacity = input.getUint32(12, true), actionCapacity = input.getUint32(16, true), total = current + previous;
  if (total > 4294967295 || request.length !== 24 + total * 56 || input.getUint32(20, true) !== 0) throw new Error("invalid render cache shape");
  for (let i = 0; i < total; i++) if (input.getUint32(24 + i * 56 + 52, true) !== 0) throw new Error("invalid render cache fact");
  const indexed = request[1] === 4 && (current >= 64 || previous >= 64) && current <= 2048 && previous <= 2048;
  const entries = new Uint32Array(Math.min(capacity, current));
  const actions = new Uint32Array(Math.min(actionCapacity, total) * 3);
  const previousHeads = new Uint32Array(indexed ? 4096 : 0), entryHeads = new Uint32Array(indexed ? 4096 : 0);
  const previousNext = new Uint32Array(indexed ? previous : 0), entryNext = new Uint32Array(indexed ? Math.min(capacity, current) : 0);
  if (indexed) for (let i = previous - 1; i >= 0; i--) {
    const bucket = input.getUint32(24 + (current + i) * 56 + 48, true) & 4095;
    previousNext[i] = previousHeads[bucket]!; previousHeads[bucket] = i + 1;
  }
  const equal = (a: number, b: number): boolean => {
    const x = 24 + a * 56, y = 24 + b * 56;
    for (let i = 0; i < 48; i++) if (request[x + i] !== request[y + i]) return false;
    return true;
  };
  let entryCount = 0, actionCount = 0, failed = false;
  const lookup = (source: number, old: boolean): number => {
    if (indexed) {
      const heads = old ? previousHeads : entryHeads, next = old ? previousNext : entryNext;
      const bucket = input.getUint32(24 + source * 56 + 48, true) & 4095;
      let match = -1;
      for (let stored = heads[bucket]!; stored > 0; stored = next[stored - 1]!) {
        const i = stored - 1;
        if (equal(source, old ? current + i : entries[i]!) && (match < 0 || i < match)) match = i;
      }
      return match;
    }
    for (let i = 0; i < (old ? previous : entryCount); i++) if (equal(source, old ? current + i : entries[i]!)) return i;
    return -1;
  };
  for (let i = 0; i < current; i++) {
    if (lookup(i, false) >= 0) continue;
    const old = lookup(i, true);
    if (actionCount >= actionCapacity) { failed = true; break; }
    actions[actionCount * 3] = old < 0 ? 0 : 1;
    actions[actionCount * 3 + 1] = i; actions[actionCount * 3 + 2] = old < 0 ? 4294967295 : old; actionCount++;
    // Native writes the action first, including when entry capacity then fails.
    if (entryCount >= capacity) { failed = true; break; }
    entries[entryCount] = i;
    if (indexed) {
      const bucket = input.getUint32(24 + i * 56 + 48, true) & 4095;
      entryNext[entryCount] = entryHeads[bucket]!; entryHeads[bucket] = entryCount + 1;
    }
    entryCount++;
  }
  if (!failed) for (let i = 0; i < previous; i++) {
    const source = current + i;
    if (lookup(source, false) >= 0) continue;
    if (actionCount >= actionCapacity) { failed = true; break; }
    actions[actionCount * 3] = 2; actions[actionCount * 3 + 1] = source; actions[actionCount * 3 + 2] = i; actionCount++;
  }
  const result = new Uint8Array(16 + entryCount * 4 + actionCount * 12), output = new DataView(result.buffer);
  output.setUint32(0, entryCount, true); output.setUint32(4, actionCount, true); output.setUint32(8, failed ? 1 : 0, true);
  for (let i = 0; i < entryCount; i++) output.setUint32(16 + i * 4, entries[i]!, true);
  for (let i = 0; i < actionCount * 3; i++) output.setUint32(16 + entryCount * 4 + i * 4, actions[i]!, true);
  return result;
}

/** Ordered render-state and adjacent-batch coordination. Native supplies local
 * drawing bounds and primitive tags; commands, identities and resources stay
 * borrowed natively. Opcode 13 uses copied buffers and never collects an arena.
 * State replies include every written stack slot and complete partial commands.
 * Every arithmetic intermediate rounds in the native f32 evaluation order.
 */
interface NscRenderAffine { readonly a: number; readonly b: number; readonly c: number; readonly d: number; readonly tx: number; readonly ty: number; }
/** Override coordination copies exact ID words and numerical command facts.
 * Native retains payloads, geometry providers, animation clocks and resources.
 * Merging preserves every accepted/replaced prefix on capacity failure.
 */
function nscvRenderOverridePolicy(request: Uint8Array): Uint8Array {
  if (request.length < 32 || request[1]! > 1 || request[2]! > 15 || request[3] !== 0) throw new Error("invalid render override header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), mode = request[1]!, flags = request[2]!;
  const first = w.getUint32(4, true), second = w.getUint32(8, true), commands = w.getUint32(12, true), entries = w.getUint32(16, true), capacity = w.getUint32(20, true);
  const commandAt = 32 + (first + second) * 40, entryAt = commandAt + commands * 92;
  if (request.length !== entryAt + entries * 28 || w.getUint32(24, true) !== 0 || w.getUint32(28, true) !== 0 || (mode === 0 && (commands !== 0 || entries !== 0)) || (mode === 1 && capacity !== 0)) throw new Error("invalid render override shape");
  const idEqual = (a: number, b: number): boolean => w.getUint32(a, true) === w.getUint32(b, true) && w.getUint32(a + 4, true) === w.getUint32(b + 4, true);
  for (let i = 0; i < first + second; i++) if (w.getUint32(32 + i * 40 + 8, true) > 3) throw new Error("invalid render override flags");
  for (let i = 0; i < commands; i++) if (w.getUint32(commandAt + i * 92 + 8, true) > 1 || w.getUint32(commandAt + i * 92 + 72, true) > 1) throw new Error("invalid render command flags");
  for (let i = 0; i < entries; i++) if (w.getUint32(entryAt + i * 28 + 8, true) > 1) throw new Error("invalid render damage flags");
  if (mode === 0) {
    const sources = new Uint32Array(Math.min(first + second, capacity));
    let count = 0, failed = false;
    for (let i = 0; i < first; i++) {
      if (count >= capacity) { failed = true; break; }
      sources[count++] = i;
    }
    if (!failed) for (let i = first; i < first + second; i++) {
      let found = -1;
      for (let j = 0; j < count; j++) if (idEqual(32 + sources[j]! * 40, 32 + i * 40)) { found = j; break; }
      if (found >= 0) { sources[found] = i; continue; }
      if (count >= capacity) { failed = true; break; }
      sources[count++] = i;
    }
    const result = new Uint8Array(16 + count * 4), out = new DataView(result.buffer);
    out.setUint32(0, count, true); out.setUint32(4, failed ? 1 : 0, true);
    for (let i = 0; i < count; i++) out.setUint32(16 + i * 4, sources[i]!, true);
    return result;
  }
  const find = (id: number, start: number, count: number): number => {
    for (let i = 0; i < count; i++) { const at = 32 + (start + i) * 40; if (idEqual(id, at)) return at; }
    return -1;
  };
  const equal = (a: number, b: number): boolean => {
    if (a < 0 || b < 0) return a === b;
    const mask = w.getUint32(a + 8, true);
    if (mask !== w.getUint32(b + 8, true) || !idEqual(a, b)) return false;
    if ((mask & 1) !== 0 && w.getFloat32(a + 12, true) !== w.getFloat32(b + 12, true)) return false;
    if ((mask & 2) !== 0) for (let i = 0; i < 6; i++) if (w.getFloat32(a + 16 + i * 4, true) !== w.getFloat32(b + 16 + i * 4, true)) return false;
    return true;
  };
  const union = (a: NscSurfaceRect | null, b: NscSurfaceRect | null): NscSurfaceRect | null => a === null ? b : b === null ? a : nscvRenderUnion(a, b, flags);
  const transformed = (at: number, override: number): NscSurfaceRect | null => {
    let transform = nscvRenderAffine(w, at + 16);
    if (override >= 0 && (w.getUint32(override + 8, true) & 2) !== 0) transform = nscvRenderMultiply(transform, nscvRenderAffine(w, override + 16));
    let bounds = nscvRenderTransform(transform, nscvRenderRect(w, at + 40), flags);
    const clip = nscvRenderOptional(w, at + 72);
    if (clip !== null) bounds = nscvRenderIntersection(bounds, clip, flags);
    bounds = nscvSurfaceNormalize(bounds);
    return nscvRenderEmpty(bounds) ? null : bounds;
  };
  let dirty: NscSurfaceRect | null = null, bounds: NscSurfaceRect | null = null, animationDirty: NscSurfaceRect | null = null;
  const result = new Uint8Array(64 + commands * 44), out = new DataView(result.buffer);
  out.setUint32(0, commands, true);
  // Damage observes original command transforms, before any override applies.
  for (let i = 0; i < commands; i++) {
    const at = commandAt + i * 92, hasId = w.getUint32(at + 8, true) === 1;
    const old = hasId ? find(at, 0, first) : -1, next = hasId ? find(at, first, second) : -1;
    if (!equal(old, next)) { dirty = union(dirty, transformed(at, old)); dirty = union(dirty, transformed(at, next)); }
    let opacity = w.getFloat32(at + 12, true), transform = nscvRenderAffine(w, at + 16), rect = nscvRenderRect(w, at + 56);
    if (next >= 0) {
      const mask = w.getUint32(next + 8, true);
      if ((mask & 1) !== 0) opacity = Math.fround(opacity * nscvRenderExtreme(0, nscvRenderExtreme(w.getFloat32(next + 12, true), 1, flags, false), flags, true));
      if ((mask & 2) !== 0) { transform = nscvRenderMultiply(transform, nscvRenderAffine(w, next + 16)); rect = transformed(at, next) ?? { x: 0, y: 0, width: 0, height: 0 }; }
    }
    const target = 64 + i * 44;
    out.setFloat32(target, opacity, true); nscvRenderPutAffine(out, target + 4, transform); nscvRenderPutRect(out, target + 28, rect);
    bounds = union(bounds, rect);
  }
  for (let i = 0; i < entries; i++) {
    const at = entryAt + i * 28;
    if (find(at, 0, first) < 0 && find(at, first, second) < 0) continue;
    const rect = nscvRenderOptional(w, at + 8);
    if (rect === null) { if (animationDirty !== null) animationDirty = nscvSurfaceNormalize(animationDirty); }
    else animationDirty = animationDirty === null ? nscvSurfaceNormalize(rect) : nscvRenderUnion(animationDirty, rect, flags);
  }
  nscvRenderPutOptional(out, 4, bounds); nscvRenderPutOptional(out, 24, dirty); nscvRenderPutOptional(out, 44, animationDirty);
  return result;
}
function nscvRenderExtreme(a: number, b: number, flags: number, maximum: boolean): number {
  if (a === 0 && b === 0) {
    const an = 1 / a < 0, bn = 1 / b < 0;
    if (an === bn) return a;
    return (flags & (1 << ((maximum ? 2 : 0) + (an ? 0 : 1)))) !== 0 ? -0 : 0;
  }
  return maximum ? nscvSurfaceMax(a, b) : nscvSurfaceMin(a, b);
}
function nscvRenderRect(w: DataView, at: number): NscSurfaceRect {
  return { x: w.getFloat32(at, true), y: w.getFloat32(at + 4, true), width: w.getFloat32(at + 8, true), height: w.getFloat32(at + 12, true) };
}
function nscvRenderPutRect(w: DataView, at: number, r: NscSurfaceRect): void {
  w.setFloat32(at, r.x, true); w.setFloat32(at + 4, r.y, true); w.setFloat32(at + 8, r.width, true); w.setFloat32(at + 12, r.height, true);
}
function nscvRenderOptional(w: DataView, at: number): NscSurfaceRect | null { return w.getUint32(at, true) === 0 ? null : nscvRenderRect(w, at + 4); }
function nscvRenderPutOptional(w: DataView, at: number, r: NscSurfaceRect | null): void {
  w.setUint32(at, r === null ? 0 : 1, true);
  nscvRenderPutRect(w, at + 4, r === null ? { x: 0, y: 0, width: 0, height: 0 } : r);
}
function nscvRenderAffine(w: DataView, at: number): NscRenderAffine {
  return { a: w.getFloat32(at, true), b: w.getFloat32(at + 4, true), c: w.getFloat32(at + 8, true), d: w.getFloat32(at + 12, true), tx: w.getFloat32(at + 16, true), ty: w.getFloat32(at + 20, true) };
}
function nscvRenderPutAffine(w: DataView, at: number, t: NscRenderAffine): void {
  w.setFloat32(at, t.a, true); w.setFloat32(at + 4, t.b, true); w.setFloat32(at + 8, t.c, true); w.setFloat32(at + 12, t.d, true); w.setFloat32(at + 16, t.tx, true); w.setFloat32(at + 20, t.ty, true);
}
function nscvRenderMultiply(t: NscRenderAffine, u: NscRenderAffine): NscRenderAffine {
  const f = Math.fround;
  return { a: f(f(t.a * u.a) + f(t.c * u.b)), b: f(f(t.b * u.a) + f(t.d * u.b)), c: f(f(t.a * u.c) + f(t.c * u.d)), d: f(f(t.b * u.c) + f(t.d * u.d)),
    tx: f(f(f(t.a * u.tx) + f(t.c * u.ty)) + t.tx), ty: f(f(f(t.b * u.tx) + f(t.d * u.ty)) + t.ty) };
}
function nscvRenderTransform(t: NscRenderAffine, rect: NscSurfaceRect, flags: number): NscSurfaceRect {
  const r = nscvSurfaceNormalize(rect), f = Math.fround;
  let minX = f(f(f(t.a * r.x) + f(t.c * r.y)) + t.tx), minY = f(f(f(t.b * r.x) + f(t.d * r.y)) + t.ty), maxX = minX, maxY = minY;
  for (let i = 1; i < 4; i++) {
    const x = (i & 1) !== 0 ? nscvSurfaceRight(r) : r.x, y = i >= 2 ? nscvSurfaceBottom(r) : r.y;
    const px = f(f(f(t.a * x) + f(t.c * y)) + t.tx), py = f(f(f(t.b * x) + f(t.d * y)) + t.ty);
    minX = nscvRenderExtreme(minX, px, flags, false); minY = nscvRenderExtreme(minY, py, flags, false);
    maxX = nscvRenderExtreme(maxX, px, flags, true); maxY = nscvRenderExtreme(maxY, py, flags, true);
  }
  return { x: minX, y: minY, width: f(maxX - minX), height: f(maxY - minY) };
}
function nscvRenderEmpty(r: NscSurfaceRect): boolean { return r.width <= 0 || r.height <= 0; }
function nscvRenderIntersection(a: NscSurfaceRect, b: NscSurfaceRect, flags: number): NscSurfaceRect {
  const x = nscvRenderExtreme(a.x, b.x, flags, true), y = nscvRenderExtreme(a.y, b.y, flags, true), right = nscvRenderExtreme(nscvSurfaceRight(a), nscvSurfaceRight(b), flags, false), bottom = nscvRenderExtreme(nscvSurfaceBottom(a), nscvSurfaceBottom(b), flags, false);
  return { x, y, width: right <= x || bottom <= y ? 0 : Math.fround(right - x), height: right <= x || bottom <= y ? 0 : Math.fround(bottom - y) };
}
function nscvRenderUnion(left: NscSurfaceRect, right: NscSurfaceRect, flags: number): NscSurfaceRect {
  const a = nscvSurfaceNormalize(left), b = nscvSurfaceNormalize(right);
  if (nscvRenderEmpty(a) && nscvRenderEmpty(b)) return { x: 0, y: 0, width: 0, height: 0 };
  if (nscvRenderEmpty(a)) return b;
  if (nscvRenderEmpty(b)) return a;
  const x = nscvRenderExtreme(a.x, b.x, flags, false), y = nscvRenderExtreme(a.y, b.y, flags, false);
  return { x, y, width: Math.fround(nscvRenderExtreme(nscvSurfaceRight(a), nscvSurfaceRight(b), flags, true) - x), height: Math.fround(nscvRenderExtreme(nscvSurfaceBottom(a), nscvSurfaceBottom(b), flags, true) - y) };
}
function nscvRenderRectEqual(a: NscSurfaceRect | null, b: NscSurfaceRect | null): boolean {
  return a === null ? b === null : b !== null && a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height;
}
function nscvRenderPlanPolicy(request: Uint8Array): Uint8Array {
  if (request.length < 16 || request[1]! > 1 || request[2]! > 15 || request[3] !== 0) throw new Error("invalid render planning header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), mode = request[1]!, flags = request[2]!, count = w.getUint32(4, true), capacity = w.getUint32(8, true), header = mode === 0 ? 16 : 32;
  if (request.length !== header + count * 48 + (mode === 0 ? w.getUint32(12, true) : 0) || (mode === 1 && w.getUint32(12, true) > 1)) throw new Error("invalid render planning shape");
  for (let i = 0; i < count; i++) {
    const at = header + i * 48, kind = w.getUint32(at, true);
    if (kind > 14 || w.getUint32(at + 4, true) > (mode === 0 && kind === 12 ? 2 : 1) || (mode === 1 && w.getUint32(at + 12, true) > 1)) throw new Error("invalid render planning fact");
  }
  if (mode === 1) return nscvRenderBatches(w, count, capacity, flags);
  const result = new Uint8Array(864 + Math.min(count, capacity) * 68), out = new DataView(result.buffer), f = Math.fround, resume = w.getUint32(12, true);
  let start = 0;
  if (resume !== 0) {
    const at = 16 + count * 48;
    if (resume < 864 || resume > result.length || w.getUint32(at + 4, true) !== 4 || resume !== 864 + w.getUint32(at, true) * 68 || w.getUint32(at + 16, true) > 32 || w.getUint32(at + 20, true) > 32 || w.getUint32(at + 8, true) > w.getUint32(at + 16, true) || w.getUint32(at + 12, true) > w.getUint32(at + 20, true)) throw new Error("invalid render continuation state");
    result.set(request.subarray(at, at + resume)); start = out.getUint32(860, true);
    if (start >= count || w.getUint32(16 + start * 48 + 4, true) === 2) throw new Error("unresolved render continuation fact");
  }
  let opacity = resume === 0 ? 1 : out.getFloat32(24, true), transform: NscRenderAffine = resume === 0 ? { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 } : nscvRenderAffine(out, 48), clip: NscSurfaceRect | null = resume === 0 ? null : nscvRenderOptional(out, 28), bounds: NscSurfaceRect | null = resume === 0 ? null : nscvRenderOptional(out, 72);
  let clips = resume === 0 ? 0 : out.getUint32(8, true), opacities = resume === 0 ? 0 : out.getUint32(12, true), clipWritten = resume === 0 ? 0 : out.getUint32(16, true), opacityWritten = resume === 0 ? 0 : out.getUint32(20, true), emitted = resume === 0 ? 0 : out.getUint32(0, true), failed = 0, pending = 0;
  for (let i = start; i < count; i++) {
    const at = 16 + i * 48, kind = w.getUint32(at, true);
    if (kind === 0) {
      if (clips === 32) { failed = 1; break; }
      nscvRenderPutOptional(out, 92 + clips * 20, clip); clips++; clipWritten = Math.max(clipWritten, clips);
      const next = nscvRenderTransform(transform, nscvRenderRect(w, at + 8), flags);
      clip = clip === null ? next : nscvRenderIntersection(clip, next, flags);
    } else if (kind === 1) {
      if (clips === 0) { failed = 2; break; }
      clips--; clip = nscvRenderOptional(out, 92 + clips * 20);
    } else if (kind === 2) {
      if (opacities === 32) { failed = 1; break; }
      out.setFloat32(732 + opacities * 4, opacity, true); opacities++; opacityWritten = Math.max(opacityWritten, opacities);
      opacity = f(opacity * nscvRenderExtreme(0, nscvRenderExtreme(w.getFloat32(at + 8, true), 1, flags, false), flags, true));
    } else if (kind === 3) {
      if (opacities === 0) { failed = 2; break; }
      opacities--; opacity = out.getFloat32(732 + opacities * 4, true);
    } else if (kind === 4) transform = nscvRenderMultiply(transform, nscvRenderAffine(w, at + 24));
    else if (!(opacity <= 0) && w.getUint32(at + 4, true) !== 0) {
      if (w.getUint32(at + 4, true) === 2) { failed = 4; pending = i; break; }
      const local = nscvRenderRect(w, at + 8), transformed = nscvRenderTransform(transform, local, flags), visible = clip === null ? transformed : nscvRenderIntersection(clip, transformed, flags);
      if (nscvRenderEmpty(visible)) continue;
      if (emitted === capacity) { failed = 3; break; }
      const target = 864 + emitted * 68;
      out.setUint32(target, i, true); out.setFloat32(target + 4, opacity, true); nscvRenderPutOptional(out, target + 8, clip); nscvRenderPutAffine(out, target + 28, transform); nscvRenderPutRect(out, target + 52, visible);
      emitted++; bounds = bounds === null ? visible : nscvRenderUnion(bounds, visible, flags);
    }
  }
  out.setUint32(0, emitted, true); out.setUint32(4, failed, true); out.setUint32(8, clips, true); out.setUint32(12, opacities, true); out.setUint32(16, clipWritten, true); out.setUint32(20, opacityWritten, true);
  out.setFloat32(24, opacity, true); nscvRenderPutOptional(out, 28, clip); nscvRenderPutAffine(out, 48, transform); nscvRenderPutOptional(out, 72, bounds);
  out.setUint32(860, pending, true);
  return result.subarray(0, 864 + emitted * 68);
}
function nscvRenderBatches(w: DataView, count: number, capacity: number, flags: number): Uint8Array {
  const result = new Uint8Array(32 + Math.min(count, capacity) * 52), out = new DataView(result.buffer);
  nscvRenderPutOptional(out, 8, nscvRenderOptional(w, 12));
  let emitted = 0, failed = 0;
  for (let i = 0; i < count; i++) {
    const at = 32 + i * 48, kind = w.getUint32(at, true), fill = w.getUint32(at + 4, true), opacity = w.getFloat32(at + 8, true), clip = nscvRenderOptional(w, at + 12), bounds = nscvRenderRect(w, at + 32);
    const pipeline = kind <= 4 ? 0 : kind <= 8 ? fill : kind <= 10 ? 4 : kind === 11 ? 2 : kind === 12 ? 3 : kind === 13 ? 5 : 6;
    const previous = 32 + (emitted - 1) * 52;
    if (emitted > 0 && out.getUint32(previous, true) === pipeline && out.getUint32(previous + 4, true) + out.getUint32(previous + 8, true) === i && out.getFloat32(previous + 12, true) === opacity && nscvRenderRectEqual(nscvRenderOptional(out, previous + 16), clip)) {
      out.setUint32(previous + 8, out.getUint32(previous + 8, true) + 1, true); nscvRenderPutRect(out, previous + 36, nscvRenderUnion(nscvRenderRect(out, previous + 36), bounds, flags));
    } else {
      if (emitted === capacity) { failed = 4; break; }
      const target = 32 + emitted * 52;
      out.setUint32(target, pipeline, true); out.setUint32(target + 4, i, true); out.setUint32(target + 8, 1, true); out.setFloat32(target + 12, opacity, true); nscvRenderPutOptional(out, target + 16, clip); nscvRenderPutRect(out, target + 36, bounds); emitted++;
    }
  }
  out.setUint32(0, emitted, true); out.setUint32(4, failed, true);
  return result.subarray(0, 32 + emitted * 52);
}

/** Final damage coordination uses copied numeric and exact-key facts. Native
 * owns drawing payloads, fingerprints, platform sampling support and storage.
 * Modes: diagnostic, presentation, effective-scale widening, retained edits.
 * Device clipping precedes f32 encoding; edge walks compare exact f64 products.
 */
function nscvRenderDamagePolicy(request: Uint8Array): Uint8Array {
  if (request.length < 128 || request[1]! > 3 || request[2]! > 15 || request[3]! > 3) throw new Error("invalid render damage header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), mode = request[1]!, flags = request[2]!;
  const changes = w.getUint32(104, true), rectCount = w.getUint32(108, true), blurs = w.getUint32(112, true), baseline = w.getUint32(116, true), current = w.getUint32(120, true), capacity = w.getUint32(124, true);
  const rectAt = 128 + changes * 20, blurAt = rectAt + rectCount * 16, baselineAt = blurAt + blurs * 68, currentAt = baselineAt + baseline * 32;
  if (request.length !== currentAt + current * 32 || capacity < 1 || capacity > 8 || rectCount > capacity || (mode !== 3 && (baseline !== 0 || current !== 0)) || (mode === 3 && (changes !== 0 || rectCount !== 0 || blurs !== 0))) throw new Error("invalid render damage shape");
  for (let i = 0; i < 4; i++) if (w.getUint32(16 + i * 20, true) > 1) throw new Error("invalid render damage bounds");
  for (let i = 0; i < changes; i++) if (w.getUint32(128 + i * 20, true) > 1) throw new Error("invalid render damage change");
  for (let i = 0; i < blurs; i++) if (w.getUint32(blurAt + i * 68 + 40, true) > 1) throw new Error("invalid render damage clip");
  const f = Math.fround, extreme = (a: number, b: number, maximum: boolean): number => nscvRenderExtreme(a, b, flags, maximum);
  const union = (a: NscSurfaceRect | null, b: NscSurfaceRect | null): NscSurfaceRect | null => a === null ? b === null ? null : nscvSurfaceNormalize(b) : b === null ? nscvSurfaceNormalize(a) : nscvRenderUnion(a, b, flags);
  const intersects = (a: NscSurfaceRect, b: NscSurfaceRect): boolean => !nscvRenderEmpty(nscvRenderIntersection(a, b, flags));
  const clusters: NscSurfaceRect[] = [];
  let bounds: NscSurfaceRect | null = null;
  const add = (rect: NscSurfaceRect): void => {
    const normalized = nscvSurfaceNormalize(rect);
    if (nscvRenderEmpty(normalized)) return;
    bounds = union(bounds, normalized);
    for (let i = 0; i < clusters.length; i++) if (intersects(clusters[i]!, normalized)) { clusters[i] = nscvRenderUnion(clusters[i]!, normalized, flags); return; }
    if (clusters.length < capacity) { clusters.push(normalized); return; }
    let best = 0, cost = 3.4028234663852886e38;
    for (let i = 0; i < clusters.length; i++) {
      const cluster = clusters[i]!, merged = nscvRenderUnion(cluster, normalized, flags), delta = f(f(merged.width * merged.height) - f(cluster.width * cluster.height));
      if (delta < cost) { best = i; cost = delta; }
    }
    clusters[best] = nscvRenderUnion(clusters[best]!, normalized, flags);
  };
  const matched = new Uint8Array(baseline), stable = new Uint8Array(baseline), upsert = new Uint8Array(current);
  let valid = true;
  if (mode === 3) {
    // Open addressing changes lookup cost, never first-match or draw order.
    let slots = 64;
    while (slots < baseline * 2) slots *= 2;
    const table = new Uint32Array(slots);
    const equalKey = (a: number, b: number): boolean => w.getUint32(a, true) === w.getUint32(b, true) && w.getUint32(a + 4, true) === w.getUint32(b + 4, true);
    const hash = (at: number): number => (w.getUint32(at, true) ^ w.getUint32(at + 4, true)) >>> 0;
    for (let i = 0; i < baseline; i++) {
      const at = baselineAt + i * 32;
      let slot = hash(at) % slots;
      while (table[slot]! !== 0 && !equalKey(at, baselineAt + (table[slot]! - 1) * 32)) slot = (slot + 1) % slots;
      if (table[slot]! === 0) table[slot] = i + 1;
    }
    for (let i = 0; i < current; i++) {
      const at = currentAt + i * 32;
      let slot = hash(at) % slots;
      while (table[slot]! !== 0 && !equalKey(at, baselineAt + (table[slot]! - 1) * 32)) slot = (slot + 1) % slots;
      upsert[i] = 1;
      if (table[slot]! !== 0) {
        const index = table[slot]! - 1, old = baselineAt + index * 32;
        matched[index] = 1;
        if (w.getUint32(at + 8, true) === w.getUint32(old + 8, true) && w.getUint32(at + 12, true) === w.getUint32(old + 12, true)) { stable[index] = 1; upsert[i] = 0; continue; }
        add(nscvRenderRect(w, old + 16));
      }
      add(nscvRenderRect(w, at + 16));
    }
    for (let i = 0; i < baseline; i++) if (matched[i] === 0) add(nscvRenderRect(w, baselineAt + i * 32 + 16));
    let walk = 0;
    for (let i = 0; i < current; i++) {
      if (upsert[i] !== 0) continue;
      while (walk < baseline && stable[walk] === 0) walk++;
      if (walk >= baseline || !equalKey(baselineAt + walk * 32, currentAt + i * 32)) { valid = false; break; }
      walk++;
    }
  }
  const scale = w.getFloat32(12, true), surface = nscvSurfaceNormalize({ x: 0, y: 0, width: w.getFloat32(4, true), height: w.getFloat32(8, true) });
  const render = nscvRenderOptional(w, 16), fullBounds = nscvRenderEmpty(surface) ? render : surface;
  let full = (request[3]! & 1) !== 0, count = clusters.length;
  const written: NscSurfaceRect[] = [];
  if (mode === 3) for (const cluster of clusters) written.push(cluster);
  else if (mode === 2) {
    bounds = render;
    if (full || scale === w.getFloat32(100, true)) {
      for (let i = 0; i < rectCount; i++) written.push(nscvRenderRect(w, rectAt + i * 16));
      count = rectCount;
    } else {
      bounds = nscvDamageSnap(bounds, scale, w.getFloat32(4, true), w.getFloat32(8, true), flags);
      for (let i = 0; i < rectCount; i++) { const rect = nscvDamageSnap(nscvRenderRect(w, rectAt + i * 16), scale, w.getFloat32(4, true), w.getFloat32(8, true), flags); if (rect !== null) written.push(rect); }
      count = written.length < 2 ? 0 : written.length;
    }
  } else if (full) bounds = fullBounds;
  else {
    const overrides = mode === 0 ? nscvRenderOptional(w, 36) : union(nscvRenderOptional(w, 36), nscvRenderOptional(w, 56));
    if (mode === 1 && (request[3]! & 2) !== 0) {
      bounds = nscvRenderOptional(w, 76);
      for (let i = 0; i < rectCount; i++) clusters.push(nscvRenderRect(w, rectAt + i * 16));
      if (overrides !== null) add(overrides);
      bounds = nscvDamageSnap(bounds, scale, w.getFloat32(4, true), w.getFloat32(8, true), flags);
      if (bounds !== null && clusters.length > 1) for (const cluster of clusters) { const aligned = nscvDamageSnap(cluster, scale, w.getFloat32(4, true), w.getFloat32(8, true), flags); if (aligned !== null) written.push(aligned); }
    } else {
      for (let i = 0; i < changes; i++) bounds = union(bounds, nscvRenderOptional(w, 128 + i * 20));
      bounds = nscvDamageSnap(union(bounds, overrides), scale, w.getFloat32(4, true), w.getFloat32(8, true), flags);
    }
    count = written.length < 2 ? 0 : written.length;
    const requested = w.getFloat32(96, true), multiplier = Number.isFinite(requested) ? extreme(1, requested, true) : 1;
    for (let i = 0; i < blurs; i++) {
      const at = blurAt + i * 68, radius = w.getFloat32(at + 64, true), opacity = w.getFloat32(at + 60, true);
      if (!(radius > 0) || !(opacity > 0)) continue;
      const rect = nscvSurfaceNormalize(nscvRenderRect(w, at)), transform = nscvRenderAffine(w, at + 16), clip = nscvRenderOptional(w, at + 40);
      let output = nscvRenderTransform(transform, rect, flags);
      if (clip !== null) output = nscvRenderIntersection(output, nscvSurfaceNormalize(clip), flags);
      if (nscvRenderEmpty(output)) continue;
      let footprint: NscSurfaceRect;
      if (multiplier === 1) footprint = nscvSurfaceNormalize(nscvRenderTransform(transform, nscvDamageInflate(rect, extreme(0, radius, true)), flags));
      else {
        const x = f(Math.sqrt(f(f(transform.a * transform.a) + f(transform.b * transform.b)))), y = f(Math.sqrt(f(f(transform.c * transform.c) + f(transform.d * transform.d))));
        const extent = f(f(extreme(0, radius, true) * extreme(f(0.0001), extreme(x, y, true), true)) * multiplier);
        footprint = nscvDamageInflate(nscvSurfaceNormalize(output), extent);
      }
      if (count === 0 ? bounds !== null && intersects(footprint, nscvSurfaceNormalize(bounds)) : written.some((dirty) => intersects(footprint, nscvSurfaceNormalize(dirty)))) { full = true; bounds = fullBounds; count = 0; break; }
    }
  }
  const result = new Uint8Array(64 + written.length * 16 + baseline * 2 + current), out = new DataView(result.buffer);
  out.setUint32(0, full ? 1 : 0, true); out.setUint32(4, count, true); out.setUint32(8, written.length, true); out.setUint32(12, valid ? 1 : 0, true);
  nscvRenderPutOptional(out, 16, bounds);
  for (let i = 0; i < written.length; i++) nscvRenderPutRect(out, 64 + i * 16, written[i]!);
  let at = 64 + written.length * 16;
  for (let i = 0; i < baseline; i++) { result[at++] = matched[i]!; result[at++] = stable[i]!; }
  for (let i = 0; i < current; i++) result[at++] = upsert[i]!;
  return result;
}
function nscvDamageInflate(r: NscSurfaceRect, extent: number): NscSurfaceRect {
  const f = Math.fround;
  return { x: f(r.x - extent), y: f(r.y - extent), width: f(f(r.width + extent) + extent), height: f(f(r.height + extent) + extent) };
}
function nscvDamageSnap(bounds: NscSurfaceRect | null, scale: number, width: number, height: number, flags: number): NscSurfaceRect | null {
  if (bounds === null) return null;
  const f = Math.fround, r = nscvSurfaceNormalize(bounds), device = Number.isFinite(scale) && scale > 0 ? scale : 1;
  const bits = new DataView(new ArrayBuffer(4));
  const next = (value: number, up: boolean): number => {
    if (Number.isNaN(value) || value === (up ? Infinity : -Infinity)) return value;
    if (value === 0) { bits.setUint32(0, up ? 1 : 2147483649, true); return bits.getFloat32(0, true); }
    bits.setFloat32(0, value, true);
    const raw = bits.getUint32(0, true); bits.setUint32(0, raw + ((value > 0) === up ? 1 : -1), true);
    return bits.getFloat32(0, true);
  };
  const extreme = (a: number, b: number, maximum: boolean): number => nscvRenderExtreme(a, b, flags, maximum);
  const nudge = (value: number, up: boolean): number => {
    if (Number.isNaN(value)) return 0;
    const limit = 3.4028234663852886e38;
    let edge = extreme(-limit, extreme(value, limit, false), true);
    edge = next(next(edge, up), up);
    return extreme(-limit, extreme(edge, limit, false), true);
  };
  const axis = (low: number, high: number, extent: number): NscDamageAxis | null => {
    let min = f(Math.floor(f(low * device)) - 1), max = f(Math.ceil(f(high * device)) + 1);
    if (Number.isFinite(extent) && extent > 0) {
      const surface = Math.ceil(f(extent * device));
      if (Number.isFinite(surface)) {
        min = extreme(0, extreme(min, surface, false), true); max = extreme(0, extreme(max, surface, false), true);
        if (!(max > min)) return null;
      }
    }
    if (!(min >= -16777216 && min <= 16777216 && max >= -16777216 && max <= 16777216)) {
      const edge = nudge(f(min / device), false), end = nudge(f(max / device), true);
      let span = extreme(0, nudge(f(end - edge), true), true);
      while (span > 0 && !Number.isFinite(f(edge + span))) span = next(span, false);
      return { edge, span };
    }
    let edge = f(min / device);
    while (edge * device >= min) edge = next(edge, false);
    while (edge * device < min) edge = next(edge, true);
    if (edge === 0) edge = 0;
    let target = f(max / device);
    while (target * device <= max) target = next(target, true);
    while (target * device > max) target = next(target, false);
    if (target <= edge) return { edge, span: 0 };
    let span = f(target - edge);
    while (span > 0 && edge + span > target) { const smaller = next(span, false); if (smaller === span) return { edge, span: 0 }; span = smaller; }
    return { edge, span: span <= 0 ? 0 : span };
  };
  const x = axis(r.x, nscvSurfaceRight(r), width), y = axis(r.y, nscvSurfaceBottom(r), height);
  if (x === null || y === null || x.span <= 0 || y.span <= 0) return null;
  return { x: x.edge, y: y.edge, width: x.span, height: y.span };
}
interface NscDamageAxis { readonly edge: number; readonly span: number; }

/** Routed requests borrow all 36 native-owned slots: 16 host, 16 record-store,
 * four credentials. Admission preserves cross-pool cancellation before capacity
 * refusal. Completion returns owned routing data and copies opaque channel words.
 */
function requestCoordinationPolicy(request: Uint8Array): Uint8Array {
  if (request.length < 16 || request[1]! > 3 || request[2]! > 2 || request[4]! > 1 || request[5]! > 1 || request[8]! > 1 || request[9]! > 1 || request[11]! > 1)
    throw new Error("invalid request coordination header");
  for (let i = 12; i < 16; i++) if (request[i] !== 0) throw new Error("reserved request coordination byte");
  const action = request[1]!, length = request[3]!;
  const positions = new DataView(new ArrayBuffer(36 * 4));
  let at = 16 + length, matching = -1, free = -1;
  const first = request[2] === 0 ? 0 : request[2] === 1 ? 16 : 32;
  const end = request[2] === 0 ? 16 : request[2] === 1 ? 32 : 36;
  for (let slot = 0; slot < 36; slot++) {
    if (at + 2 > request.length) throw new Error("truncated request coordination table");
    const size = request[at + 1]!, route = at + 2 + size;
    if (route + 13 > request.length || request[at]! > 1 || request[route + 2]! > 1 || request[route + 3]! > 1 || request[route + 4]! > 1)
      throw new Error("invalid request coordination slot");
    positions.setUint32(slot * 4, at, true);
    let equal = request[at] === 1 && size === length;
    for (let i = 0; i < size; i++) if (request[at + 2 + i] !== request[16 + i]) equal = false;
    if (equal && matching < 0) matching = slot;
    if (request[at] === 0 && slot >= first && slot < end && free < 0) free = slot;
    at = route + 13;
  }
  if (at !== request.length) throw new Error("trailing request coordination bytes");
  const result = new Uint8Array(16);
  result[0] = 255; result[1] = 255;
  if (action === 1) { result[0] = matching < 0 ? 255 : matching; return result; }
  if (action === 2) {
    const slot = request[10]!;
    if (slot >= 36) throw new Error("request result slot is out of bounds");
    const entry = positions.getUint32(slot * 4, true), route = entry + 2 + request[entry + 1]!;
    if (request[entry] !== 1) throw new Error("request result has no tracked owner");
    const ok = request[9] === 1;
    result[0] = slot; result[2] = request[route + (ok ? 0 : 1)]!;
    result[3] = ok && request[route + 3] === 1 ? 2 : ok && request[route + 2] === 1 ? 1 : 0;
    result[4] = 1; result[5] = request[route + 4]!;
    if (result[5] === 1) for (let i = 0; i < 8; i++) result[8 + i] = request[route + 5 + i]!;
    return result;
  }
  if (action === 3) {
    // Duplicate/collision refusal precedes capacity, which precedes channel
    // ownership refusal. The engine's actual channel admission follows this.
    result[3] = length > 0 && (matching >= 0 || request[4] === 1) ? 1 : free < 0 ? 2 : request[11] === 1 ? 3 : 0;
    result[0] = free < 0 ? 255 : free;
    return result;
  }
  result[2] = request[6]!; result[3] = request[7]!; result[4] = request[8]!;
  if (request[4] === 1 || length > 0 && matching >= 0 && request[5] === 1) return result;
  if (length > 0 && matching >= 0) {
    if (matching >= first && matching < end) { result[0] = matching; return result; }
    result[1] = matching; // Retire the old pool even if the destination is full.
  }
  result[0] = free < 0 ? 255 : free;
  return result;
}

/** First-match cancellation over requests, named effects, clipboard writes,
 * subprocess streams, file streams, delays and DB commands. Declarative live
 * queries and synchronous exec terminals keep their owners and never cancel.
 */
function cancellationPolicy(request: Uint8Array): Uint8Array {
  if (request.length < 2) throw new Error("invalid cancellation request");
  const length = request[1]!;
  let at = 2 + length;
  const counts = [36, 16, 16, 16, 4, 16, 16];
  const result = new Uint8Array(8); result[0] = 255; result[1] = 255;
  for (let family = 0; family < 7; family++) for (let slot = 0; slot < counts[family]!; slot++) {
    if (at + 3 > request.length) throw new Error("truncated cancellation table");
    const used = request[at]!, flags = request[at + 1]!, size = request[at + 2]!;
    if (used > 1 || flags > (family === 6 ? 3 : family === 0 || family === 1 || family === 4 ? 1 : 0) || at + 4 + size > request.length)
      throw new Error("invalid cancellation slot");
    let equal = length > 0 && used === 1 && size === length && (family !== 1 || flags === 0);
    for (let i = 0; i < size; i++) if (request[at + 3 + i] !== request[2 + i]) equal = false;
    if (equal && result[0] === 255) {
      result[0] = family; result[1] = slot; result[2] = family === 0 || family === 5 || family === 4 && flags === 0 || family === 6 && flags === 1 ? 1 : 0;
      result[3] = family !== 6 || flags === 1 ? 1 : 0;
      result[4] = family === 4 && flags === 1 ? 1 : 0;
      result[5] = family === 0 && flags === 1 ? 1 : 0;
      result[6] = request[at + 3 + size]!;
      result[7] = result[5]!;
    }
    at += 4 + size;
  }
  if (at !== request.length) throw new Error("trailing cancellation bytes");
  return result;
}

/** Fallible credential request decoding returns offsets into the original
 * borrowed packet. Malformed authored payloads are normal rejections; no secret
 * or credential bytes are copied into the policy result or retained by it.
 */
function credentialRecordPolicy(request: Uint8Array): Uint8Array {
  if (request.length < 2 || 2 + request[1]! > request.length) throw new Error("truncated credential policy header");
  const names = ["core.credentials.set", "core.credentials.get", "core.credentials.delete"];
  let operation = -1;
  for (let candidate = 0; candidate < 3; candidate++) {
    const name = names[candidate]!;
    let equal = name.length === request[1];
    if (equal) for (let i = 0; i < name.length; i++) if (name.charCodeAt(i) !== request[2 + i]) equal = false;
    if (equal) operation = candidate;
  }
  const result = new Uint8Array(20);
  if (operation < 0) return result;
  const data = new DataView(request.buffer, request.byteOffset, request.byteLength), out = new DataView(result.buffer);
  const start = 2 + request[1]!;
  let at = start;
  for (let field = 0; field < (operation === 0 ? 2 : 1); field++) {
    if (at + 4 > request.length) return new Uint8Array(20);
    const length = data.getUint32(at, true); at += 4;
    if (length > request.length - at) return new Uint8Array(20);
    out.setUint32(4 + field * 8, at - start, true); out.setUint32(8 + field * 8, length, true);
    at += length;
  }
  if (at !== request.length) return new Uint8Array(20);
  result[0] = 1; result[1] = operation;
  return result;
}

/** Database command admission and complete page/done/exec result routing are
 * separate from live-query reconciliation. Replacement may reuse only a
 * one-shot query; an exec or live subscription keeps its original route.
 */
function dbCommandPolicy(request: Uint8Array): Uint8Array {
  if (request.length < 12 || request[1]! > 1 || request[3]! > 1 || request[4]! > 1 || request[9]! > 2 || request[10]! > 1 || request[11] !== 0)
    throw new Error("invalid database command header");
  const positions = new DataView(new ArrayBuffer(64)), length = request[2]!;
  let at = 12 + length, matching = -1, free = -1;
  for (let slot = 0; slot < 16; slot++) {
    if (at + 7 > request.length) throw new Error("truncated database command table");
    const size = request[at + 6]!;
    if (request[at]! > 1 || request[at + 1]! > 1 || request[at + 2]! > 1 || at + 7 + size > request.length)
      throw new Error("invalid database command slot");
    positions.setUint32(slot * 4, at, true);
    let equal = length > 0 && request[at] === 1 && size === length;
    for (let i = 0; i < size; i++) if (request[at + 7 + i] !== request[12 + i]) equal = false;
    if (equal && matching < 0) matching = slot;
    if (request[at] === 0 && free < 0) free = slot;
    at += 7 + size;
  }
  if (at !== request.length) throw new Error("trailing database command bytes");
  const result = new Uint8Array(8); result[0] = 255;
  result[1] = request[5]!; result[2] = request[6]!; result[3] = request[7]!;
  if (request[1] === 0) {
    if (request[3] === 1) return result;
    if (matching >= 0) {
      const entry = positions.getUint32(matching * 4, true);
      if (request[4] !== 1 || request[entry + 1] !== 1 || request[entry + 2] === 1) return result;
    }
    result[0] = matching < 0 ? free < 0 ? 255 : free : matching;
    return result;
  }
  const slot = request[8]!;
  if (slot >= 16) throw new Error("database result slot is out of bounds");
  const entry = positions.getUint32(slot * 4, true);
  if (request[entry] !== 1) throw new Error("database result has no tracked owner");
  result[0] = slot;
  if (request[10] === 0) { result[4] = request[entry + 5]!; result[5] = 2; result[6] = request[entry + 2] === 1 ? 0 : 1; return result; }
  const kind = request[9]!;
  if (kind === 1 && request[entry + 1] !== 1 || kind === 2 && request[entry + 1] === 1) throw new Error("database terminal reached the wrong route");
  result[4] = request[entry + (kind === 0 ? 3 : 4)]!;
  result[5] = kind === 0 ? 0 : 1;
  result[6] = kind === 2 || kind === 1 && request[entry + 2] === 0 ? 1 : 0;
  return result;
}

/** File-stream lifecycle (15). Header: action (lookup/read/open/chunk/close/
 * completion), key length, foreign-owner fact, result slot/op/event/outcome,
 * chunk/done/error tags, reserved. Four slots carry used/sink/busy/cancelling,
 * three routes, key length and exact key bytes. Native retains buffers and
 * engine identities. Owned result: slot, refusal, route, shape (void/bytes/
 * number/outcome), retirement, clear-busy, two reserved bytes.
 */
function fileStreamPolicy(request: Uint8Array): Uint8Array {
  if (request.length < 12 || request[1]! > 5 || request[3]! > 1 || request[11] !== 0)
    throw new Error("invalid file stream header");
  const action = request[1]!, length = request[2]!;
  let at = 12 + length;
  if (at > request.length) throw new Error("truncated file stream key");
  const positions: number[] = [];
  let matching = -1, free = -1;
  for (let slot = 0; slot < 4; slot++) {
    if (at + 8 > request.length) throw new Error("truncated file stream slot");
    for (let i = 0; i < 4; i++) if (request[at + i]! > 1) throw new Error("invalid file stream fact");
    const size = request[at + 7]!;
    if (at + 8 + size > request.length) throw new Error("truncated file stream owner");
    positions.push(at);
    let equal = request[at] === 1 && size === length;
    if (equal) for (let i = 0; i < length; i++) if (request[at + 8 + i] !== request[12 + i]) equal = false;
    if (equal && matching < 0) matching = slot;
    if (request[at] === 0 && free < 0) free = slot;
    at += 8 + size;
  }
  if (at !== request.length) throw new Error("trailing file stream bytes");
  const result = new Uint8Array(8); result[0] = 255;
  if (action === 0) { result[0] = matching < 0 ? 255 : matching; return result; }
  result[2] = request[10]!;
  if (action === 1 || action === 2) {
    const replace = action === 1 && length > 0 && matching >= 0;
    const slot = replace ? matching : free;
    const refused = request[3] === 1 || action === 2 && (length === 0 || matching >= 0)
      || replace && request[positions[matching]! + 1] === 1 || slot < 0;
    if (refused) result[1] = 1;
    else { result[0] = slot; result[2] = request[9]!; }
    return result;
  }
  if (action === 3 || action === 4) {
    if (matching < 0 || request[positions[matching]! + 1] !== 1 || request[positions[matching]! + 3] === 1) result[1] = 2;
    else if (request[positions[matching]! + 2] === 1) result[1] = 3;
    else { result[0] = matching; result[2] = request[9]!; }
    return result;
  }
  const slot = request[4]!;
  if (slot >= 4 || request[positions[slot]!] !== 1 || request[5]! > 8 || request[6]! > 2 || request[7]! > 8)
    throw new Error("invalid file stream completion owner or enum");
  const owner = positions[slot]!, op = request[5]!, event = request[6]!, outcome = request[7]!;
  result[0] = slot; result[2] = request[owner + 6]!; result[3] = 3;
  if (request[owner + 3] === 1 && outcome === 5) result[4] = 1;
  else if (op === 4 && event === 1 && outcome === 0) { result[2] = request[owner + 4]!; result[3] = 1; }
  else if (op === 4 && event === 2 && outcome === 0) { result[2] = request[owner + 5]!; result[3] = 2; result[4] = 1; }
  else if (outcome === 0) { result[2] = request[owner + 5]!; result[3] = 0; result[4] = op === 7 ? 1 : 0; result[5] = 1; }
  else if (op === 6 && (outcome === 4 || outcome === 7)) result[5] = 1;
  else result[4] = 1;
  return result;
}

/** Clipboard-write coordination (16). Header: lookup/admit/complete, key
 * length, collision fact, completion slot, authored route, two reserved bytes.
 * Sixteen slots carry used/route/key length/exact bytes. Empty names never
 * match but can occupy independent slots. Complete records borrow the native
 * owner key until dispatch; the policy owns slot, route and retirement only.
 */
function clipboardWritePolicy(request: Uint8Array): Uint8Array {
  if (request.length < 8 || request[1]! > 2 || request[3]! > 1 || request[6] !== 0 || request[7] !== 0)
    throw new Error("invalid clipboard write header");
  const action = request[1]!, length = request[2]!;
  let at = 8 + length;
  if (at > request.length) throw new Error("truncated clipboard key");
  const positions: number[] = [];
  let matching = -1, free = -1;
  for (let slot = 0; slot < 16; slot++) {
    if (at + 3 > request.length || request[at]! > 1) throw new Error("invalid clipboard slot");
    const size = request[at + 2]!;
    if (at + 3 + size > request.length) throw new Error("truncated clipboard owner");
    positions.push(at);
    let equal = length > 0 && request[at] === 1 && size === length;
    if (equal) for (let i = 0; i < length; i++) if (request[at + 3 + i] !== request[8 + i]) equal = false;
    if (equal && matching < 0) matching = slot;
    if (request[at] === 0 && free < 0) free = slot;
    at += 3 + size;
  }
  if (at !== request.length) throw new Error("trailing clipboard bytes");
  const result = new Uint8Array(4); result[0] = 255; result[1] = request[5]!;
  if (action === 0) result[0] = matching < 0 ? 255 : matching;
  else if (action === 1) result[0] = request[3] === 1 || matching >= 0 || free < 0 ? 255 : free;
  else {
    const slot = request[4]!;
    if (slot >= 16 || request[positions[slot]!] !== 1) throw new Error("untracked clipboard completion");
    result[0] = slot; result[1] = request[positions[slot]! + 1]!; result[2] = 1;
  }
  return result;
}
