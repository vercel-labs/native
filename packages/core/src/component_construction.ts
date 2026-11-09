/** Portable widget construction, compiled by scriptc with the app.
 * Operation 17 owns element defaults, finalization, synthesized children and
 * builtin composition. Packets contain copied f32 values and presence bits;
 * native retains structural identities, typed routes and generation arenas.
 */
function nscvConstructionDefaults(kind: number, size: number): readonly number[] {
  if (kind === 18) return [1, size === 1 ? 16 : 24, size === 1 ? 16 : 24, 12, 0];
  if (kind === 17) return [1, size === 1 ? 14 : size === 2 ? 18 : 16, size === 1 ? 14 : size === 2 ? 18 : 16, 12, 0];
  if (kind === 15) return [1, 10, 12, 0, 0];
  if (kind === 12) return [1, 3, 3, 0, 2];
  return [0, 0, 0, 0, 0];
}

function nscvConstructionPolicy(request: Uint8Array): Uint8Array {
  if (request.length < 8 || request[0] !== 17) throw new Error("invalid construction packet");
  const op = request[1]!;
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  if (op === 0) {
    // 40 bytes: kind/size/checked-selected-padding/cross; seven f32s;
    // target max-number signed-zero facts. Result is a complete 44-byte plan.
    if (request.length !== 40 || request[2]! > 62 || request[3]! > 5 || request[4]! > 7 || request[5]! > 3 || request[6] !== 0 || request[7] !== 0 || wire.getUint32(36, true) > 3) throw new Error("invalid element construction");
    const kind = request[2]!, size = request[3]!, flags = request[4]!;
    const defaults = nscvConstructionDefaults(kind, size);
    const result = new Uint8Array(44), out = new DataView(result.buffer);
    const selected = (flags & 3) !== 0;
    result[0] = selected ? 1 : 0;
    result[1] = request[5] === 0 && defaults[0] === 1 ? defaults[4]! : request[5]!;
    result[2] = (flags & 4) === 0 && defaults[0] === 1 ? 1 : 0;
    out.setFloat32(4, wire.getFloat32(28, true) === 0 && defaults[0] === 1 ? defaults[3]! : wire.getFloat32(28, true), true);
    const padding = (flags & 4) !== 0 ? wire.getFloat32(24, true) : 0;
    for (let i = 0; i < 4; i++) out.setFloat32(8 + i * 4, result[2] === 1 ? defaults[i % 2 === 0 ? 1 : 2]! : padding, true);
    const width = wire.getFloat32(8, true), minimum = wire.getFloat32(16, true);
    let source = Number.isNaN(width) ? 16 : Number.isNaN(minimum) || width > minimum ? 8 : 16;
    if (width === 0 && minimum === 0) {
      const leftNegative = wire.getUint32(8, true) === 2147483648;
      const rightNegative = wire.getUint32(16, true) === 2147483648;
      const target = wire.getUint32(36, true);
      if (leftNegative !== rightNegative) source = leftNegative ? ((target & 1) !== 0 ? 8 : 16) : ((target & 2) !== 0 ? 16 : 8);
    }
    out.setUint32(24, wire.getUint32(source, true), true);
    out.setUint32(28, wire.getUint32(12, true), true);
    if (kind !== 16) {
      out.setUint32(32, wire.getUint32(width > 0 ? 8 : 20, true), true);
      out.setUint32(36, wire.getUint32(12, true), true);
    }
    if (kind === 48 && selected) out.setFloat32(40, 1, true);
    else out.setUint32(40, wire.getUint32(32, true), true);
    return result;
  }
  if (op === 1) {
    // 592 bytes: kind/wrap/facts, seven token references, complete action
    // and handler masks, style presence/values, 28 colors and five radii.
    if (request.length !== 592 || request[2]! > 62 || request[3]! > 2 || request[4]! > 31 || request[5] !== 0 || request[6] !== 0 || request[7] !== 0 || request[15] !== 0 || wire.getUint16(16, true) > 2047 || wire.getUint16(18, true) > 1023 || wire.getUint32(20, true) > 127) throw new Error("invalid final construction");
    for (let i = 8; i < 15; i++) if (request[i] !== 255 && request[i]! >= (i === 14 ? 5 : 28)) throw new Error("invalid construction token");
    const result = new Uint8Array(108), out = new DataView(result.buffer);
    for (let i = 0; i < 104; i++) result[4 + i] = request[20 + i]!;
    let actions = wire.getUint16(16, true), presence = wire.getUint32(20, true);
    const handlers = wire.getUint16(18, true), kind = request[2]!, facts = request[4]!;
    if ((handlers & (1 | 4 | 16)) !== 0) actions |= 2;
    if ((handlers & 2) !== 0) actions |= 256;
    if ((handlers & 8) !== 0) actions |= 4;
    if ((handlers & 128) !== 0) actions |= 32;
    if (kind === 51 && (handlers & (256 | 512)) !== 0) actions |= 8 | 16;
    out.setUint16(0, actions, true);
    result[2] = (kind === 26 && request[3] === 2 && (facts & 1) === 0 && (facts & 2) !== 0 ? 1 : 0) |
      ((facts & 16) !== 0 || kind === 26 && request[3] === 1 ? 2 : 0) |
      (kind === 57 && (facts & 4) !== 0 ? 4 : 0) |
      ((facts & 8) !== 0 || (handlers & (32 | 64)) !== 0 ? 8 : 0);
    for (let i = 0; i < 6; i++) {
      const token = request[8 + i]!;
      if ((presence & (1 << i)) === 0 && token !== 255) {
        let source = token;
        if (source >= 6 && source <= 12 && wire.getFloat32(124 + source * 16 + 12, true) === 0) source = source === 7 ? 5 : 4;
        for (let j = 0; j < 16; j++) result[8 + i * 16 + j] = request[124 + source * 16 + j]!;
        presence |= 1 << i;
      }
    }
    const radius = request[14]!;
    if ((presence & 64) === 0 && radius !== 255) {
      if (radius === 4) out.setFloat32(104, 0, true);
      else out.setUint32(104, wire.getUint32(572 + radius * 4, true), true);
      presence |= 64;
    }
    out.setUint32(4, presence, true);
    return result;
  }
  if (op === 2) {
    // 24 bytes: divider/menu-item/menu-surface operation and disabled,
    // separator/enabled/point facts; value and pointer coordinates.
    if (request.length !== 24 || request[2]! > 2 || request[3]! > 15 || wire.getUint32(4, true) !== 0 || wire.getUint32(20, true) !== 0) throw new Error("invalid synthesized construction");
    const kind = request[2]!, facts = request[3]!;
    const label = new TextEncoder().encode(kind === 0 ? "Split divider" : kind === 2 ? "Context menu" : "");
    const result = new Uint8Array(24 + label.length), out = new DataView(result.buffer);
    result[0] = kind === 0 ? 58 : kind === 2 ? 25 : (facts & 2) !== 0 ? 53 : 41;
    result[1] = kind === 0 ? facts & 1 : kind === 1 && (facts & 2) === 0 && (facts & 4) === 0 ? 1 : 0;
    result[2] = kind === 1 && (facts & 2) === 0 && (facts & 4) !== 0 ? 1 : 0;
    result[3] = kind === 2 && (facts & 8) !== 0 ? 1 : 0;
    if (kind === 0) out.setUint32(4, wire.getUint32(8, true), true);
    out.setFloat32(8, result[3] === 1 ? 0 : 4, true);
    if (result[3] === 1) { out.setUint32(12, wire.getUint32(12, true), true); out.setUint32(16, wire.getUint32(16, true), true); }
    // Placement/alignment are below/start (zero); the final byte carries
    // the structural menu-item identity admission, separate from enabled.
    result[22] = kind === 1 && (facts & 2) === 0 ? 1 : 0;
    result[23] = kind === 2 ? 1 : 0;
    for (let i = 0; i < label.length; i++) result[24 + i] = label[i]!;
    return result;
  }
  if (op === 3) {
    // Builtin extensions retain zero-sentinel spacing independently of
    // element nullable padding. No per-widget allocation or callback.
    if (request.length !== 36 || request[2]! > 31 || request[3] !== 255 && request[3]! > 5 || request[4] !== 255 && request[4]! > 5 || request[5]! > 26 || request[6]! > 3 || request[7]! > 3) throw new Error("invalid builtin construction");
    const roots = [14, 17, 29, 30, 8, 15, 31, 9, 18, 47, 38, 19, 20, 25, 35, 10, 52, 11, 16, 34, 53, 21, 54, 51, 55, 49, 5, 12, 39, 32, 13, 40];
    const roles = [1, 1, 4, 2, 1, 1, 5, 1, 1, 17, 6, 8, 8, 9, 6, 1, 22, 19, 1, 5, 0, 8, 0, 21, 22, 20, 14, 1, 6, 5, 1, 7];
    const component = request[2]!, root = roots[component]!;
    const size = request[4] === 255 ? (component === 24 ? 1 : 0) : request[4]!;
    const result = new Uint8Array(36), out = new DataView(result.buffer);
    for (let i = 8; i < 36; i++) result[i] = request[i]!;
    result[0] = root;
    result[1] = request[3] === 255 ? (component === 6 ? 1 : component === 19 ? 3 : component === 29 ? 4 : 0) : request[3]!;
    result[2] = size; result[3] = request[5] === 0 ? roles[component]! : request[5]!;
    result[4] = request[6]!; result[5] = request[7]! & 1; result[6] = (request[7]! >> 1) & 1;
    const defaults = nscvConstructionDefaults(root, size);
    let applies = defaults[0] === 1, vertical = defaults[1]!, horizontal = defaults[2]!, gap = defaults[3]!, cross = defaults[4]!, clip = applies && root !== 12, minWidth = 0, minHeight = 0;
    if (!applies) {
      applies = component === 18 || component === 11 || component === 12 || component === 21 || component === 13 || component === 15 || component === 4 || component === 7 || component === 17 || component === 30 || component === 0 || component === 26 || component === 28 || component === 20 || component === 22;
      if (component === 18) { vertical = 12; horizontal = 12; gap = 8; clip = true; }
      else if (component === 11 || component === 12 || component === 21) { vertical = 20; horizontal = 20; gap = 16; clip = true; }
      else if (component === 13) { vertical = 4; horizontal = 4; gap = 2; clip = true; }
      else if (component === 15) { gap = 2; cross = 2; }
      else if (component === 4 || component === 7 || component === 17 || component === 30) { gap = 4; cross = 2; }
      else if (component === 0 || component === 26) clip = true;
      else if (component === 28) { minWidth = 160; minHeight = 80; }
      else if (component === 20) { minWidth = 1; minHeight = 1; }
      else if (component === 22) { minWidth = 120; minHeight = 20; }
    }
    if (applies) {
      if (wire.getFloat32(8, true) === 0 && wire.getFloat32(12, true) === 0 && wire.getFloat32(16, true) === 0 && wire.getFloat32(20, true) === 0) {
        for (let i = 0; i < 4; i++) out.setFloat32(8 + i * 4, i % 2 === 0 ? vertical : horizontal, true);
        result[6] = 1;
      }
      if (wire.getFloat32(24, true) === 0) out.setFloat32(24, gap, true);
      if (request[6] === 0) result[4] = cross;
      if (result[5] === 0) result[5] = clip ? 1 : 0;
      if (wire.getFloat32(28, true) === 0 && wire.getFloat32(32, true) === 0) { out.setFloat32(28, minWidth, true); out.setFloat32(32, minHeight, true); }
    }
    return result;
  }
  throw new Error("unknown construction operation");
}
