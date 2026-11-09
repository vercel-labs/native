/** Context-menu coordination. Operation 98 uses copied integer words and
 * bounded ordinals; no callback, widget or label storage crosses this seam.
 * Modes: route (0), default presentation (1), next token (2), superseded
 * notice (3), post-notice admission (4), action admission (5), action (6).
 * Native executes the OS presenter, clipboard, text and app capabilities.
 */
function nscvContextMenus(request: Uint8Array): Uint8Array {
  if (request.length < 16 || request[0] !== 98 || request[1]! > 6 || request[2] !== 0 || request[3] !== 0)
    throw new Error("invalid context menu header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const word = (at: number): number => w.getUint32(at, true);
  const equal = (a: number, b: number): boolean => word(a) === word(b) && word(a + 4) === word(b + 4);
  const scalar = (value: number): Uint8Array => { const out = new Uint8Array(4); new DataView(out.buffer).setUint32(0, value, true); return out; };
  const mode = request[1]!;
  if (mode === 0) {
    const nodes = word(4), routes = word(8), missing = 4294967295;
    if (nodes > 1024 || routes > 1024 || word(12) !== 0 || request.length !== 16 + nodes * 16 + routes * 8)
      throw new Error("invalid context menu route");
    for (let i = 0; i < nodes; i++) if (word(28 + i * 16) > 1) throw new Error("invalid context menu node");
    let selected = missing, low = 0, high = 0;
    for (let i = 0; i < routes; i++) {
      const at = 16 + nodes * 16 + i * 8, slot = word(at);
      if (word(at + 4) !== 0 || slot >= nodes) continue;
      const node = 16 + slot * 16, dl = word(node), dh = word(node + 4);
      if (word(node + 8) === 0 || word(node + 12) !== 0) continue;
      if (selected === missing || dh > high || dh === high && dl >= low) { selected = slot; low = dl; high = dh; }
    }
    return scalar(selected);
  }
  if (mode === 1) {
    // Flags: target, editable, disabled, terminal, presenter, edit selection,
    // select-all, terminal selection, live PTY, selected-node/group present.
    const flags = word(4);
    if (request.length !== 56 || flags > 2047 || word(8) !== 0 || word(12) !== 0)
      throw new Error("invalid context menu presentation");
    let kind = 1;
    if ((flags & 1) !== 0) {
      if ((flags & 6) === 2) kind = (flags & 16) !== 0 ? 2 : 0;
      else if ((flags & 12) === 8) kind = (flags & 16) !== 0 ? 3 : 0;
      else if ((word(24) !== 0 || word(28) !== 0) && (equal(16, 24) || (flags & 1024) !== 0 &&
          (word(32) !== 0 || word(36) !== 0) && equal(32, 40))) kind = (flags & 16) !== 0 ? 4 : 0;
    }
    if (word(48) !== 0 || word(52) !== 0) throw new Error("invalid context menu presentation reserved bytes");
    const count = kind === 2 ? 5 : kind === 3 ? 2 : kind === 4 ? 1 : 0;
    const out = new Uint8Array(8 + count * 4); out[0] = kind; out[1] = count;
    if (kind === 2) {
      out.set([1, 1, (flags & 32) !== 0 ? 1 : 0, 0, 2, 2, (flags & 32) !== 0 ? 1 : 0, 0,
        3, 3, 1, 0, 0, 0, 1, 1, 4, 4, (flags & 64) !== 0 ? 1 : 0, 0], 8);
    } else if (kind === 3) out.set([2, 2, (flags & 128) !== 0 ? 1 : 0, 0, 3, 3, (flags & 256) !== 0 ? 1 : 0, 0], 8);
    else if (kind === 4) out.set([2, 2, 1, 0], 8);
    return out;
  }
  if (mode === 2) {
    if (request.length !== 16 || word(4) !== 0) throw new Error("invalid context menu token");
    let low = word(8) + 1, high = word(12);
    if (low === 4294967296) { low = 0; high = high === 4294967295 ? 0 : high + 1; }
    if (low === 0 && high === 0) low = 1;
    const out = new Uint8Array(8), v = new DataView(out.buffer); v.setUint32(0, low, true); v.setUint32(4, high, true); return out;
  }
  if (mode === 3) {
    if (request.length !== 16 || word(4) > 4 || word(8) !== 0 || word(12) !== 0) throw new Error("invalid context menu notice");
    return scalar(word(4) === 1 ? 1 : 0);
  }
  if (mode === 4) {
    if (request.length !== 32 || word(4) > 3 || word(24) !== 0 || word(28) !== 0) throw new Error("invalid context menu continuation");
    return scalar((word(4) & 1) === 0 || !equal(8, 16) ? 0 : (word(4) & 2) === 0 ? 1 : 2);
  }
  if (mode === 5) {
    if (request.length !== 48 || word(4) > 4 || word(44) !== 0) throw new Error("invalid context menu action admission");
    return scalar(word(4) === 0 || !equal(8, 16) || !equal(24, 32) ? 0 : word(40) === 0 ? (word(4) === 1 ? 1 : 2) : 3);
  }
  if (request.length !== 16 || word(4) < 1 || word(4) > 4 || word(12) !== 0) throw new Error("invalid context menu action");
  const kind = word(4), item = word(8);
  return scalar(kind === 1 ? 1 : kind === 2 ? item >= 1 && item <= 4 ? item + 1 : 0 :
    kind === 3 ? item === 2 ? 6 : item === 3 ? 7 : 0 : item === 2 ? 8 : 0);
}
