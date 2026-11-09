/** Raw view-table policy. Native owns table storage, borrowed labels, render
 * invalidation and OS calls; this program owns selection, focus and ancestry.
 */
function nscvViewCoordination(request: Uint8Array): Uint8Array {
  if (request.length < 192 || request[0] !== 80 || request[1] !== 1 || request[2]! > 10 || request[3]! > 3)
    throw new Error("invalid view coordination header");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const mode = request[2]!, variant = request[3]!;
  const windows = wire.getUint32(4, true), natives = wire.getUint32(8, true), webviews = wire.getUint32(12, true);
  const capacity = wire.getUint32(32, true), depth = wire.getUint32(36, true), cursor = wire.getUint32(40, true), flags = wire.getUint32(44, true);
  if (windows > 16 || natives > 32 || webviews > 16 || request.length !== 192 + windows * 64 + (natives + webviews) * 192 || capacity > 49 || flags > 1)
    throw new Error("invalid view coordination bounds");
  if ((mode !== 1 && mode !== 7 && mode !== 9 && variant !== 0) || (mode === 1 && variant > 1) || (mode === 7 && variant > 1) || (mode === 9 && variant === 0))
    throw new Error("invalid view coordination variant");
  const nativeAt = 192 + windows * 64, webviewAt = nativeAt + natives * 192;
  for (let i = 0; i < windows; i++) {
    const at = 192 + i * 64;
    if (wire.getUint32(at + 8, true) > 15 || wire.getUint32(at + 12, true) !== 0 || wire.getUint32(at + 56, true) !== 0 || wire.getUint32(at + 60, true) !== 0)
      throw new Error("invalid view coordination window");
  }
  for (let i = 0; i < natives + webviews; i++) {
    const at = nativeAt + i * 192, parent = wire.getUint32(at + 20, true);
    if (wire.getUint32(at + 8, true) > 15 || wire.getUint32(at + 12, true) !== 0 || wire.getUint32(at + 16, true) > 64 || (parent !== 4294967295 && parent > 64))
      throw new Error("invalid view coordination record");
  }
  let window = -1;
  for (let i = 0; i < windows; i++) if (nscvViewsIdentity(wire, 16, 192 + i * 64)) { window = i; break; }
  const windowAt = 192 + window * 64;
  const live = window >= 0 && (wire.getUint32(windowAt + 8, true) & 1) !== 0;
  const selections: number[] = [];
  let status = 0, decision = 0, selectedKind = 0, selectedSlot = 0;
  let frame: number[] = [];
  if (mode === 0 || mode === 1 || mode === 2) {
    const listed: number[] = [];
    if (live) {
      if ((wire.getUint32(windowAt + 8, true) & 2) !== 0) { listed.push(1); listed.push(window); }
      for (let i = 0; i < natives; i++) {
        const at = nativeAt + i * 192;
        if (nscvViewsIdentity(wire, 16, at) && (wire.getUint32(at + 8, true) & 1) !== 0) { listed.push(2); listed.push(i); }
      }
      for (let i = 0; i < webviews; i++) {
        const at = webviewAt + i * 192;
        if (nscvViewsIdentity(wire, 16, at) && (wire.getUint32(at + 8, true) & 1) !== 0) { listed.push(3); listed.push(i); }
      }
    }
    if (mode === 0) {
      for (let i = 0; i < listed.length && i < capacity * 2; i++) selections.push(listed[i]!);
    } else {
      const eligible: number[] = [];
      let focused = -1;
      for (let i = 0; i < listed.length; i += 2) {
        const kind = listed[i]!, slot = listed[i + 1]!;
        const at = kind === 1 ? 192 + slot * 64 : (kind === 2 ? nativeAt : webviewAt) + slot * 192;
        const state = wire.getUint32(at + 8, true);
        if (kind !== 1 && (state & 7) !== 7) continue;
        if ((state & (kind === 1 ? 4 : 8)) !== 0) focused = eligible.length / 2;
        eligible.push(kind); eligible.push(slot);
      }
      if (mode === 1) {
        if (!live) status = 1;
        else if (eligible.length === 0) status = 4;
        else {
          const count = eligible.length / 2;
          const target = variant === 0 ? (focused < 0 ? 0 : (focused + 1) % count) : (focused <= 0 ? count - 1 : focused - 1);
          selectedKind = eligible[target * 2]!; selectedSlot = eligible[target * 2 + 1]!;
        }
      } else {
        decision = focused >= 0 ? 0 : eligible.length === 0 ? 1 : 2;
        if (decision === 2) { selectedKind = eligible[0]!; selectedSlot = eligible[1]!; }
      }
    }
  } else if (mode === 3) {
    if (wire.getUint32(28, true) !== 4294967295) {
      if (nscvViewsText(request, wire, 64, 24, 128, 28)) status = 3;
      else if (nscvViewsLookup(request, wire, windows, natives, webviews, 128, 28)[0] === 0) status = 2;
    }
  } else if (mode >= 4 && mode <= 6) {
    if (mode === 4 || wire.getUint32(28, true) !== 4294967295) {
      const result = nscvViewsAbsolute(request, wire, windows, natives, webviews, mode === 4 ? 64 : 128, mode === 4 ? 24 : 28, mode === 4 ? depth : 0);
      status = result[0]!;
      frame = result.slice(1);
    } else frame = [0, 0, 0, 0];
    if (status === 0 && mode !== 4) {
      frame = [Math.fround(wire.getFloat32(48, true) + (mode === 5 ? frame[0]! : -frame[0]!)), Math.fround(wire.getFloat32(52, true) + (mode === 5 ? frame[1]! : -frame[1]!)), wire.getFloat32(56, true), wire.getFloat32(60, true)];
      // No parent preserves the raw base bits, including signed zero.
      if (wire.getUint32(28, true) === 4294967295) frame = nscvViewsFrame(wire, 48);
    }
  } else if (mode === 7) {
    if (cursor > 48) throw new Error("invalid view coordination descendant cursor");
    if (depth < 48) {
      for (let i = 0; i < natives + webviews; i++) {
        // Zero lists the whole current table; other cursors observe one slot
        // at its execution stage, after any earlier capability callback.
        if (cursor !== 0 && cursor !== (i < natives ? i + 1 : i - natives + 33)) continue;
        const at = nativeAt + i * 192;
        if (nscvViewsIdentity(wire, 16, at) && wire.getUint32(at + 20, true) !== 4294967295 && nscvViewsText(request, wire, 64, 24, at + 128, at + 20)) {
          selections.push(i < natives ? 2 : 3); selections.push(i < natives ? i : i - natives);
        }
      }
    }
    decision = variant === 0 ? 1 : 2; // WebView OS call before/after recursion.
  } else if (mode === 8) {
    decision = nscvViewsSubtreeFocused(request, wire, windows, natives, webviews, 64, 24, depth) ? 1 : 0;
  } else if (mode === 9) {
    let at = 0;
    if (variant === 1) {
      if (window >= 0) { selectedKind = 1; selectedSlot = window; decision = 1 | (flags === 0 && nscvViewsMain(request, wire, 64, 24) ? 2 : 0); }
    } else {
      const count = variant === 2 ? natives : webviews;
      if (cursor >= count) throw new Error("invalid view coordination mutation cursor");
      at = (variant === 2 ? nativeAt : webviewAt) + cursor * 192;
      if (nscvViewsIdentity(wire, 16, at)) {
        const next = flags === 0 && nscvViewsText(request, wire, 64, 24, at + 64, at + 16);
        decision = 1 | (next ? 2 : 0) | ((wire.getUint32(at + 8, true) & 8) !== 0 && !next ? 4 : 0);
        selectedKind = variant; selectedSlot = cursor;
      }
    }
  } else if (mode === 10 && !live) status = 1;
  const output = new Uint8Array(32 + selections.length * 4 + (status === 0 && mode >= 4 && mode <= 6 ? 16 : 0));
  const result = new DataView(output.buffer);
  result.setUint32(0, 1, true); result.setUint32(4, mode, true); result.setUint32(8, status, true); result.setUint32(12, decision, true);
  result.setUint32(16, selectedKind, true); result.setUint32(20, selectedSlot, true); result.setUint32(24, selections.length / 2, true);
  for (let i = 0; i < selections.length; i++) result.setUint32(32 + i * 4, selections[i]!, true);
  if (status === 0 && mode >= 4 && mode <= 6) for (let i = 0; i < 4; i++) result.setFloat32(32 + i * 4, frame[i]!, true);
  return output;
}

function nscvViewsIdentity(wire: DataView, a: number, b: number): boolean {
  return wire.getUint32(a, true) === wire.getUint32(b, true) && wire.getUint32(a + 4, true) === wire.getUint32(b + 4, true);
}
function nscvViewsText(bytes: Uint8Array, wire: DataView, a: number, al: number, b: number, bl: number): boolean {
  const length = wire.getUint32(al, true);
  if (length > 64 || length !== wire.getUint32(bl, true)) return false;
  for (let i = 0; i < length; i++) if (bytes[a + i] !== bytes[b + i]) return false;
  return true;
}
function nscvViewsMain(bytes: Uint8Array, wire: DataView, at: number, lengthAt: number): boolean {
  return wire.getUint32(lengthAt, true) === 4 && bytes[at] === 109 && bytes[at + 1] === 97 && bytes[at + 2] === 105 && bytes[at + 3] === 110;
}
function nscvViewsFrame(wire: DataView, at: number): number[] {
  return [wire.getFloat32(at, true), wire.getFloat32(at + 4, true), wire.getFloat32(at + 8, true), wire.getFloat32(at + 12, true)];
}
function nscvViewsLookup(bytes: Uint8Array, wire: DataView, windows: number, natives: number, webviews: number, textAt: number, lengthAt: number): number[] {
  const nativeAt = 192 + windows * 64;
  for (let i = 0; i < natives + webviews; i++) {
    const at = nativeAt + i * 192;
    if (nscvViewsIdentity(wire, 16, at) && (wire.getUint32(at + 8, true) & 1) !== 0 && nscvViewsText(bytes, wire, textAt, lengthAt, at + 64, at + 16)) return [i < natives ? 2 : 3, i < natives ? i : i - natives];
  }
  if (nscvViewsMain(bytes, wire, textAt, lengthAt)) {
    // Main exists without a source only when its window record exists.
    for (let i = 0; i < windows; i++) if (nscvViewsIdentity(wire, 16, 192 + i * 64)) return [1, i];
  }
  return [0, 0];
}
function nscvViewsAbsolute(bytes: Uint8Array, wire: DataView, windows: number, natives: number, webviews: number, textAt: number, lengthAt: number, depth: number): number[] {
  if (depth >= 49) return [3];
  if (nscvViewsMain(bytes, wire, textAt, lengthAt)) {
    for (let i = 0; i < windows; i++) {
      const at = 192 + i * 64;
      if (nscvViewsIdentity(wire, 16, at)) {
        if ((wire.getUint32(at + 8, true) & 8) !== 0) return [0, ...nscvViewsFrame(wire, at + 32)];
        return [0, 0, 0, wire.getFloat32(at + 24, true), wire.getFloat32(at + 28, true)];
      }
    }
    return [1];
  }
  const selected = nscvViewsLookup(bytes, wire, windows, natives, webviews, textAt, lengthAt), kind = selected[0]!;
  if (kind === 0) return [2];
  const at = 192 + windows * 64 + (kind === 2 ? selected[1]! : natives + selected[1]!) * 192;
  const frame = nscvViewsFrame(wire, at + 32);
  if (kind === 2 && wire.getUint32(at + 20, true) !== 4294967295) {
    const parent = nscvViewsAbsolute(bytes, wire, windows, natives, webviews, at + 128, at + 20, depth + 1);
    if (parent[0] !== 0) return parent;
    frame[0] = Math.fround(frame[0]! + parent[1]!); frame[1] = Math.fround(frame[1]! + parent[2]!);
  }
  return [0, ...frame];
}
function nscvViewsSubtreeFocused(bytes: Uint8Array, wire: DataView, windows: number, natives: number, webviews: number, textAt: number, lengthAt: number, depth: number): boolean {
  if (depth >= 48) return false;
  const nativeAt = 192 + windows * 64;
  // Native and WebView lookups are independent; a malformed duplicate label
  // can have focus in either table, just as in the native reference.
  for (let table = 0; table < 2; table++) {
    const first = table === 0 ? 0 : natives, end = table === 0 ? natives : natives + webviews;
    for (let i = first; i < end; i++) {
      const at = nativeAt + i * 192;
      if (nscvViewsIdentity(wire, 16, at) && (wire.getUint32(at + 8, true) & 1) !== 0 && nscvViewsText(bytes, wire, textAt, lengthAt, at + 64, at + 16)) {
        if ((wire.getUint32(at + 8, true) & 8) !== 0) return true;
        break;
      }
    }
  }
  for (let i = 0; i < natives + webviews; i++) {
    const at = nativeAt + i * 192;
    if (nscvViewsIdentity(wire, 16, at) && wire.getUint32(at + 20, true) !== 4294967295 && nscvViewsText(bytes, wire, textAt, lengthAt, at + 128, at + 20) && nscvViewsSubtreeFocused(bytes, wire, windows, natives, webviews, at + 64, at + 16, depth + 1)) return true;
  }
  return false;
}
