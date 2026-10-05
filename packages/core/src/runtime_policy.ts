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
    if (request.length !== 5 || request[4]! > 2) throw new Error("invalid theme control request");
    for (let i = 1; i < 4; i++) if (request[i]! > 1) throw new Error("invalid theme control flag");
    result[0] = request[1] === 1 ? 1 : request[2] === 1 ? 2 : 0;
    result[1] = result[0] === 0 && (request[3] === 0 || request[4] === 0) ? 1 : 0;
    result[2] = request[1] === 1 || request[3] === 1 || result[1] === 1 ? 1 : 0;
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
      if (rows === 0 || extent <= 0 || float(40) <= 0) { start = 0; end = 0; extent = 0; height = 0; }
      else {
        extent = nscvSurfaceMax(0, extent);
        const stride = f(extent + gap), viewport = nscvSurfaceMax(0, float(40));
        const total = f(f(f(rows) * extent) + f(nscvSurfaceMax(0, f(f(rows) - 1)) * gap));
        const maxOffset = nscvSurfaceMax(0, f(total - viewport));
        const raw = Number.isFinite(float(56)) ? float(56) : 0;
        const bounded = nscvSurfaceClamp(nscvSurfaceMax(0, raw), 0, maxOffset, (flags & 2) !== 0);
        offset = nscvSurfaceClamp(raw, -viewport, f(maxOffset + viewport), (flags & 2) !== 0);
        const firstValue = f(bounded / stride), endValue = f(f(f(bounded + viewport) + gap) / stride);
        const first = Math.min(rows - 1, Number.isFinite(firstValue) && firstValue > 0 ? Math.floor(firstValue) : 0);
        const visibleEnd = Math.min(rows, Number.isFinite(endValue) && endValue > 0 ? Math.ceil(endValue) : 0);
        start = first > overscan ? first - overscan : 0;
        // Native usize addition is checked in safety builds and wraps in
        // optimized builds. Keep the two lanes until after that boundary.
        const lowSum = wire.getUint32(20, true) + visibleEnd % 4294967296;
        const hiSum = wire.getUint32(24, true) + Math.floor(visibleEnd / 4294967296) + Math.floor(lowSum / 4294967296);
        if (hiSum > 4294967295 && (flags & 4) !== 0) throw new Error("grid overscan overflow");
        const sum = lowSum % 4294967296 + (hiSum % 4294967296) * 4294967296;
        end = Math.min(rows, sum); height = extent;
      }
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
