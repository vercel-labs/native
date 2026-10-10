/** Ordered paint capabilities. The host owns widget/text/path buffers and
 * executes these copied recipes; the compiler arena never owns a display list. */
function nscvRenderRecipe(request: Uint8Array): Uint8Array {
  if (request.length !== 32 || request[0] !== 43 || request[1] !== 1 || request[2]! > 1 || request[3]! > 2)
    throw new Error("invalid render recipe header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const flags = w.getUint32(4, true), kind = w.getUint32(20, true), retained = request[2] === 1;
  if (flags > 2047 || kind > 62 || w.getUint32(24, true) !== 0 || w.getUint32(28, true) !== 0 ||
      retained && (w.getUint32(8, true) !== 0 || w.getUint32(12, true) !== 0))
    throw new Error("invalid render recipe facts");
  const result = new Uint8Array(64), out = new DataView(result.buffer);
  out.setUint32(0, 1, true);
  // Direct-tree depth errors precede hiding, and never initialize a command.
  if (!retained && (w.getUint32(12, true) !== 0 || w.getUint32(8, true) >= 32)) {
    out.setUint32(4, 2, true); return result;
  }
  if (!retained && (flags & 256) !== 0) { out.setUint32(4, 1, true); return result; }
  let count = 0;
  const emit = (op: number, arg: number = 0): void => {
    if (count >= 6) throw new Error("render recipe capacity exceeded");
    out.setUint32(16 + count * 8, op, true); out.setUint32(20 + count * 8, arg, true); count++;
  };
  // op: backdrop, draw, scrim, children, separators, scrollbars, reactions.
  // Child arguments: low byte clip (none/content/frame/disclosure), bit 8
  // bubble palette, bit 9 direct-tree segment stamps. Palette restoration is
  // implicit on return; reactions always use the caller's palette.
  const contentClip = (flags & 1) !== 0 ? 1 : 0;
  const virtual = (flags & 2) !== 0, spans = (flags & 4) !== 0;
  emit(0);
  let draw = -1;
  switch (kind) {
    case 0: case 1: case 2: draw = 0; break;
    case 43: draw = 1; break;
    case 12: draw = 2; break;
    case 17: draw = 3; break;
    case 18: draw = 4; break;
    case 19: draw = 5; break;
    case 20: draw = 6; break;
    case 21: draw = 7; break;
    case 14: draw = 8; break;
    case 15: draw = 9; break;
    case 16: case 22: draw = 10; break;
    case 23: draw = 11; break;
    case 24: case 25: draw = 12; break;
    case 26: draw = (flags & 8) !== 0 ? 14 : spans ? 15 : 13; break;
    case 27: draw = 16; break;
    case 28: draw = 17; break;
    case 61: draw = 18; break;
    case 62: draw = 19; break;
    case 29: draw = 20; break;
    case 30: draw = 21; break;
    case 31: case 32: case 50: draw = 22; break;
    case 33: draw = 23; break;
    case 34: draw = 24; break;
    case 35: case 36: draw = 25; break;
    case 39: draw = (flags & 16) !== 0 ? 26 : 25; break;
    case 37: case 38: draw = 27; break;
    case 40: draw = 28; break;
    case 41: draw = 29; break;
    case 42: draw = 30; break;
    case 44: draw = 31; break;
    case 45: draw = 32; break;
    case 46: draw = 33; break;
    case 47: draw = 34; break;
    case 48: draw = 35; break;
    case 49: draw = 36; break;
    case 51: draw = 37; break;
    case 52: draw = 38; break;
    case 53: draw = 39; break;
    case 58: draw = 40; break;
    case 54: draw = 41; break;
    case 55: draw = 42; break;
    case 56: draw = 43; break;
    case 60: draw = 44; break;
  }
  if (kind >= 19 && kind <= 21 && (flags & 1024) !== 0) emit(2);
  if (draw >= 0) emit(1, draw);
  if (kind === 15) { emit(3, 256 | contentClip); emit(6); }
  else if (kind === 14) {
    const disclosure = retained ? request[3]! : (flags & 64) !== 0 ? 2 : 0;
    if (disclosure !== 0) emit(3, disclosure === 1 ? 3 : contentClip);
  } else if (kind === 6) {
    emit(3, 2); if ((flags & 32) === 0) emit(5, 1);
  } else if (kind === 4 || kind === 5) {
    const scroll = retained && virtual;
    emit(3, scroll ? contentClip === 1 ? 1 : 2 : contentClip);
    if (scroll && (flags & 32) === 0) emit(5, 0);
    emit(4, scroll ? 1 : 0);
  } else if (retained && (kind === 3 || kind === 7) && virtual) {
    emit(3, contentClip === 1 ? 1 : 2); if ((flags & 32) === 0) emit(5, 0);
  } else if (retained) emit(3, contentClip);
  else if (kind === 9) {
    const stamps = (flags & 512) !== 0 || w.getFloat32(16, true) <= 0;
    emit(3, contentClip | (stamps ? 512 : 0));
  } else if (kind <= 13 || kind === 16 || kind === 17 || kind === 18 ||
      kind >= 19 && kind <= 25 || kind === 42 || kind === 43 || kind === 57 || kind === 59 || kind === 60 ||
      kind === 44 && !spans && (flags & 128) !== 0) emit(3, contentClip);
  out.setUint32(8, count, true); return result;
}

/** Direct-tree siblings include hidden nodes: visiting a hidden child still
 * checks its depth. Layer ties retain source order; segment positions count
 * visible source siblings, independently of the order in which they paint. */
function nscvRenderChildren(request: Uint8Array): Uint8Array {
  if (request.length < 32 || request[0] !== 44 || request[1] !== 1 || request[2]! > 1 || request[3] !== 0)
    throw new Error("invalid render child header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), count = w.getUint32(4, true);
  if (request.length !== 32 + count * 12 || w.getUint32(24, true) !== 0 || w.getUint32(28, true) !== 0)
    throw new Error("invalid render child shape");
  let visible = 0;
  for (let i = 0; i < count; i++) {
    const at = 32 + i * 12, flags = w.getUint32(at + 4, true);
    if (w.getUint32(at, true) > 62 || flags > 3) throw new Error("invalid render child facts");
    if ((flags & 1) === 0) visible++;
    if ((flags & 2) === 0 && w.getUint32(at + 8, true) !== 0) throw new Error("invalid absent render layer");
  }
  const layer = (i: number): number => {
    const at = 32 + i * 12, kind = w.getUint32(at, true);
    if ((w.getUint32(at + 4, true) & 2) !== 0) return w.getInt32(at + 8, true);
    return w.getInt32(kind >= 19 && kind <= 21 ? 12 : kind === 23 || kind === 24 || kind === 25 ? 16 : kind === 40 ? 20 : 8, true);
  };
  const result = new Uint8Array(8 + count * 8), out = new DataView(result.buffer); out.setUint32(0, 1, true); out.setUint32(4, count, true);
  let previous = -1, previousLayer = 0;
  for (let dest = 0; dest < count; dest++) {
    let best = -1, bestLayer = 0;
    for (let i = 0; i < count; i++) {
      const value = layer(i);
      if (previous >= 0 && (value < previousLayer || value === previousLayer && i <= previous)) continue;
      if (best < 0 || value < bestLayer || value === bestLayer && i < best) { best = i; bestLayer = value; }
    }
    if (best < 0) throw new Error("render child ordering made no progress");
    let segment = 0;
    if (request[2] === 1 && visible > 1) {
      let ordinal = 0;
      if ((w.getUint32(36 + best * 12, true) & 1) === 0)
        for (let i = 0; i < best; i++) if ((w.getUint32(36 + i * 12, true) & 1) === 0) ordinal++;
      segment = ordinal === 0 ? 1 : ordinal === visible - 1 ? 3 : 2;
    }
    out.setUint32(8 + dest * 8, best, true); out.setUint32(12 + dest * 8, segment, true);
    previous = best; previousLayer = bestLayer;
  }
  return result;
}

/** Split the authored chrome around the widget span. Budgets retain all
 * u64 words; native owns the builder and supplies its actual bounded counts. */
function nscvChromeComposition(request: Uint8Array): Uint8Array {
  if (request.length !== 40 || request[0] !== 67 || request[1] !== 1 || request[2]! > 3 || request[3] !== 0)
    throw new Error("invalid chrome composition header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  if (w.getUint32(4, true) !== 0) throw new Error("invalid chrome composition reserved bytes");
  const separate = (request[2]! & 1) !== 0, variable = (request[2]! & 2) !== 0;
  const prefixBudget = w.getUint32(8, true), prefixHigh = w.getUint32(12, true);
  const suffixBudget = w.getUint32(16, true), suffixHigh = w.getUint32(20, true);
  const count = w.getUint32(24, true), countHigh = w.getUint32(28, true);
  const before = w.getUint32(32, true), beforeHigh = w.getUint32(36, true);
  const result = new Uint8Array(24), out = new DataView(result.buffer);
  out.setUint32(0, 1, true);
  // A builder cannot supply more than a u32 count. This rejects, rather
  // than rounding, any malformed or unrepresentable observed count.
  let valid = countHigh === 0 && beforeHigh === 0 && (separate || before === 0);
  const prefix = separate ? before : count - suffixBudget;
  const suffix = separate ? count - before : suffixBudget;
  valid &&= prefix >= 0 && suffix >= 0 && prefix <= count && suffix <= count;
  valid &&= separate ? suffixHigh !== 0 || suffix <= suffixBudget : suffixHigh === 0;
  valid &&= variable ? prefixHigh !== 0 || prefix <= prefixBudget : prefixHigh === 0 && prefix === prefixBudget;
  out.setUint32(4, valid ? 0 : 1, true);
  if (valid) { out.setUint32(8, prefix, true); out.setUint32(12, suffix, true); }
  return result;
}
