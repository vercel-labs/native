/** Input normalization and composition coordination over copied observations.
 * Native owns borrowed text, editor storage, allocation and event execution. */
function nscvInputComposition(request: Uint8Array): Uint8Array {
  if (request.length !== 256 || request[0] !== 78 || request[1] !== 1 ||
      request[2]! > 13 || request[3]! > 14 || request[4]! > 31 || request[5]! > 1 ||
      request[6]! > 2 || request[7]! > 2)
    throw new Error("invalid input composition header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const flags = w.getUint32(8, true);
  if (flags > 127 || w.getUint32(12, true) > 63 || w.getUint32(240, true) > 63 ||
      request[106] !== 0 || request[107] !== 0 || w.getUint32(108, true) !== 0)
    throw new Error("invalid input composition facts");
  for (let at = 244; at < 256; at += 4) if (w.getUint32(at, true) !== 0)
    throw new Error("invalid input composition tail");
  const nonzero = (at: number): boolean => w.getUint32(at, true) !== 0 || w.getUint32(at + 4, true) !== 0;
  const equal = (a: number, b: number): boolean => w.getUint32(a, true) === w.getUint32(b, true) && w.getUint32(a + 4, true) === w.getUint32(b + 4, true);
  const lengthIs = (at: number, length: number): boolean => w.getUint32(at, true) === length && w.getUint32(at + 4, true) === 0;
  const keyIs = (name: string): boolean => {
    if (!lengthIs(16, name.length)) return false;
    for (let i = 0; i < name.length; i++) {
      const byte = request[96 + i]!, lower = byte >= 65 && byte <= 90 ? byte + 32 : byte;
      if (lower !== name.charCodeAt(i)) return false;
    }
    return true;
  };
  const textIs = (byte: number): boolean => lengthIs(24, 1) && request[104] === byte;
  const sameSurface = (): boolean => {
    if (!equal(32, 40) || !equal(80, 88) || w.getUint32(84, true) !== 0 || w.getUint32(80, true) > 64) return false;
    for (let i = 0; i < w.getUint32(80, true); i++) if (request[112 + i] !== request[176 + i]) return false;
    return true;
  };
  const mode = request[2]!, kind = request[3]!, modifiers = request[4]!;
  const command = !(request[5] === 1 && (modifiers & 6) === 6) && (modifiers & 26) !== 0;
  const composition = kind >= 9 && kind <= 11;
  const ownerKind = w.getUint32(12, true), focusedKind = w.getUint32(240, true);
  const ownerAlive = (flags & 2) !== 0 && ownerKind >= 35 && ownerKind <= 39;
  const keys = kind === 6 || kind === 7;
  const owns = nonzero(72) && sameSurface();
  let ownerAt = 48, grace = request[6]!, claim = request[7]!;
  let pointer = 0, keyboard = 0, edit = 0, decisions = 0, source = 0, targetAt = 56;
  // Decision bits: chord, escape, IM-owned keys, target-less continuation,
  // orphan, swallow, target-less grace, skip editor, claimed text, clear preedit,
  // install preedit, clear target-less grace, deliver text, consume paste release.
  if (mode === 0) {
    pointer = kind < 6 ? kind + 1 : 0;
    keyboard = kind === 6 ? 1 : kind === 7 ? 2 : 0;
    edit = (kind === 6 || kind === 8) && nonzero(24) && !command ? 1 :
      kind === 9 ? 2 : kind === 10 ? 3 : kind === 11 ? 4 : 0;
    if (command) decisions |= 1;
    if (keyIs("escape") || keyIs("esc")) decisions |= 2;
  } else if (mode === 1) {
    if (keys && !command && owns) decisions |= 4;
  } else if (mode === 2) {
    if (composition && owns) decisions |= 8;
    let resolvedGrace = 0;
    if ((flags & 1) !== 0 && grace !== 0) {
      const armed = grace; grace = 0;
      if (kind === 8) {
        resolvedGrace = armed;
        if (armed === 1 && (!nonzero(48) || !ownerAlive)) { ownerAt = 0; resolvedGrace = 2; }
      } else if (armed === 1) ownerAt = 0;
    }
    if (composition && (flags & 1) !== 0 && ownerAt !== 0 && nonzero(48) && !ownerAlive) {
      decisions |= 16;
      if (kind !== 9) { ownerAt = 0; if (kind === 11) grace = 2; }
    }
    if (resolvedGrace === 2) decisions |= 32;
    // The target-less grace is global and is consumed by the next event,
    // including an event on another surface.
    if ((flags & 64) !== 0) { decisions |= 2048; if (kind === 8 && sameSurface()) decisions |= 64; }
    if ((flags & 4) !== 0 || (decisions & 120) !== 0) decisions |= 128;
  } else if (mode === 3) {
    if (kind === 9) ownerAt = 64;
    else if (kind === 11) { if (nonzero(48)) grace = 1; }
    else if (kind === 10 || kind === 8) ownerAt = 0;
  } else if (mode === 4) {
    claim = 0;
    const split = kind === 8 && (request[7] === 1 ? textIs(32) : request[7] === 2 && (textIs(13) || textIs(10)));
    if (split || (flags & 8) === 0 && (flags & 16) !== 0) decisions |= 256;
    if (!split && (flags & 8) === 0 && (flags & 16) !== 0 && kind === 6 && !nonzero(24))
      claim = keyIs("space") ? 1 : keyIs("enter") ? 2 : 0;
  } else if (mode === 5) {
    if ((kind === 8 || kind === 6) && !command) {
      if (kind === 8 || nonzero(24)) { if (owns) decisions |= 512; if (nonzero(24)) source = 1; }
    } else if (kind === 9) source = 3;
    else if (kind === 10) { source = nonzero(24) ? 1 : owns ? 2 : 0; if (owns) decisions |= 512; }
    else if (kind === 11 && owns) decisions |= 512 | 16384;
  } else if (mode === 6) {
    // Allocation success is an explicit capability result. Failed replacement
    // clears the prior preedit; its origin and grace remain unchanged.
    decisions |= (flags & 16) !== 0 ? 1024 : 512;
  } else if (mode === 7) {
    ownerAt = 0; grace = 0; claim = 0;
    if ((nonzero(72) || (flags & 64) !== 0) && sameSurface()) decisions |= 512 | 2048;
  } else if (mode === 8) {
    if ((composition || kind === 8) && nonzero(48) && ownerAlive) targetAt = 48;
    const selectedKind = targetAt === 48 ? ownerKind : focusedKind;
    if (selectedKind < 35 || selectedKind > 39) targetAt = 0;
  } else if (mode === 9) {
    if (keys && keyIs("v") && (flags & 64) !== 0) { decisions |= 2048; if (kind === 7) decisions |= 8192; }
  } else if (mode === 10) {
    if ((flags & 16) !== 0 && kind === 6 && equal(48, 64)) { ownerAt = 0; grace = 0; }
  } else if (mode === 11) {
    if ((flags & 1) !== 0 && (flags & 32) !== 0 && ((flags & 16) === 0 || (flags & 64) !== 0)) decisions |= 4096;
  } else if (mode === 12) source = nonzero(16) ? 1 : textIs(32) ? 2 : 0;
  else if ((flags & 1) !== 0 && (flags & 32) !== 0 && (flags & 8) === 0) decisions |= 4096;
  const result = new Uint8Array(64), out = new DataView(result.buffer);
  out.setUint32(0, 1, true); out.setUint32(4, pointer, true); out.setUint32(8, keyboard, true);
  out.setUint32(12, edit, true);
  out.setUint32(16, (modifiers & 7) | ((modifiers & 24) !== 0 ? 8 : 0), true);
  out.setUint32(20, decisions, true);
  if (ownerAt !== 0) { out.setUint32(24, w.getUint32(ownerAt, true), true); out.setUint32(28, w.getUint32(ownerAt + 4, true), true); }
  out.setUint32(32, grace, true); out.setUint32(36, claim, true); out.setUint32(40, source, true);
  if (targetAt !== 0) { out.setUint32(48, w.getUint32(targetAt, true), true); out.setUint32(52, w.getUint32(targetAt + 4, true), true); }
  return result;
}
