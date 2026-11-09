/** Window capability transactions and activation over current native-owned
 * observations. Native executes OS calls, keeps tables and borrowed labels,
 * and supplies outcome classes without moving policy into the transport.
 */
function nscvWindowLifecycle(request: Uint8Array): Uint8Array {
  if (request.length < 128 || request[0] !== 81 || request[1] !== 1 || request[2]! > 6 || request[3]! > 4)
    throw new Error("invalid window lifecycle header");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const mode = request[2]!, verb = request[3]!, windows = wire.getUint32(4, true), views = wire.getUint32(8, true);
  const value = wire.getUint32(12, true), cursor = wire.getUint32(24, true), target = wire.getUint32(28, true);
  const saved = wire.getUint32(32, true), outcome = wire.getUint32(36, true), length = wire.getUint32(40, true), active = wire.getUint32(44, true);
  if (windows > 16 || views > 32 || request.length !== 128 + windows * 128 + views * 16 || value > 1 || active > 1 || saved > 31 || outcome > 2 || length > (mode === 5 ? 65 : 64))
    throw new Error("invalid window lifecycle bounds");
  if ((mode !== 0 && mode !== 1 && mode !== 3 && verb !== 0) || (mode === 1 && verb > 3) || (mode === 3 && verb > 1))
    throw new Error("invalid window lifecycle variant");
  for (let i = 0; i < windows; i++) {
    const at = 128 + i * 128;
    if (wire.getUint32(at + 8, true) > 31 || wire.getUint32(at + 12, true) > 64)
      throw new Error("invalid window lifecycle record");
    for (let j = 16; j < 64; j++) if (request[at + j] !== 0) throw new Error("invalid window lifecycle reserved bytes");
  }
  const viewAt = 128 + windows * 128;
  for (let i = 0; i < views; i++) if (wire.getUint32(viewAt + i * 16 + 8, true) > 1 || wire.getUint32(viewAt + i * 16 + 12, true) !== 0)
    throw new Error("invalid window lifecycle view");
  let selected = -1;
  if (mode === 0) {
    for (let i = 0; i < windows; i++) if (nscvWindowIdentity(wire, 16, 128 + i * 128)) { selected = i; break; }
  } else if (mode === 5) {
    for (let i = 0; i < windows; i++) {
      const at = 128 + i * 128;
      if (length !== wire.getUint32(at + 12, true)) continue;
      let same = true;
      for (let j = 0; j < length; j++) if (request[64 + j] !== request[at + 64 + j]) { same = false; break; }
      if (same) { selected = i; break; }
    }
  } else if (mode !== 3) {
    if (cursor >= windows) throw new Error("invalid window lifecycle cursor");
    selected = cursor;
  }
  const state = selected < 0 ? 0 : wire.getUint32(128 + selected * 128 + 8, true);
  let status = 0, decisions = 0, mask = 0, flags = 0, keyboard = 0;
  if (mode === 0) {
    if (selected < 0 || (verb !== 0 && (state & 1) === 0)) status = 1;
    else if (verb === 0) mask = 7;
    else if (verb === 1) { mask = 6; flags = 4; }
    else if (verb === 2) mask = 4;
    else if (verb === 3 && (state & 4) !== 0) decisions = 16;
  } else if (mode === 1) {
    if (outcome !== 0 && !(verb === 0 && value === 1 && outcome === 2)) {
      decisions = 8;
      if (verb <= 2) { mask = verb === 0 ? 7 : verb === 1 ? 6 : 4; flags = saved & mask; }
    } else if (verb === 0) decisions = 3;
    else if (verb === 1) decisions = 2;
    else if (verb === 2) decisions = 2 | ((state & 8) !== 0 ? 4 : 0);
    else decisions = 6;
  } else if (mode === 2) {
    mask = 2; flags = value === 1 ? 2 : 0;
    if ((state & 2) !== 0 && value === 0) decisions = 32;
  } else if (mode === 3) {
    if (cursor >= views || (verb === 0 && target >= windows)) throw new Error("invalid window lifecycle keyboard cursor");
    const at = viewAt + cursor * 16;
    let admitted = true, focused = false;
    if (verb === 0) {
      admitted = nscvWindowIdentity(wire, at, 128 + target * 128);
      focused = value === 1;
    } else {
      for (let i = 0; i < windows; i++) if (nscvWindowIdentity(wire, at, 128 + i * 128)) {
        focused = (wire.getUint32(128 + i * 128 + 8, true) & 2) !== 0; break;
      }
    }
    keyboard = active === 1 && focused ? 1 : 0;
    if (admitted && keyboard !== wire.getUint32(at + 8, true)) decisions = 1;
  } else if (mode === 4) {
    mask = 5; flags = saved & 5;
    decisions = (saved & 2) !== 0 ? 4 : 16;
    if ((state & 16) === 0) decisions |= 128;
  } else if (mode === 5) {
    if (selected < 0 || (state & 1) === 0) decisions = 64;
    else if (value === 1) { mask = 7; decisions = 3; }
    else { mask = 4; decisions = 6; }
  } else if (mode === 6) keyboard = cursor === target ? 1 : 0;
  const output = new Uint8Array(64), result = new DataView(output.buffer);
  result.setUint32(0, 1, true); result.setUint32(4, mode, true); result.setUint32(8, status, true);
  result.setUint32(12, selected < 0 ? 4294967295 : selected, true); result.setUint32(16, decisions, true);
  result.setUint32(20, mask, true); result.setUint32(24, flags, true); result.setUint32(28, keyboard, true);
  // A host's content rectangle keeps the original f32 width/height bits.
  if ((decisions & 128) !== 0) output.set(request.subarray(56, 64), 40);
  return output;
}
function nscvWindowIdentity(wire: DataView, a: number, b: number): boolean {
  return wire.getUint32(a, true) === wire.getUint32(b, true) && wire.getUint32(a + 4, true) === wire.getUint32(b + 4, true);
}
