/** Shared composition recipes compiled by scriptc beside the app model.
 * Operation 19 takes copied facts, exact u64 words and authored f32 words.
 * Native assembles the selected nodes in its arena and retains IDs/routes.
 */
function nscvCompositionStateName(state: number): string {
  return state === 0 ? "completed" : state === 1 ? "active" : "pending";
}

function nscvCompositionPolicy(request: Uint8Array): Uint8Array {
  if (request.length !== 64 || request[0] !== 19 || request[1]! > 7 || request[2]! > 63 || request[3]! > 26)
    throw new Error("invalid composition packet");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  if (wire.getUint32(4, true) !== 0 || wire.getUint32(40, true) !== 0 || wire.getUint32(44, true) !== 0 || wire.getUint32(48, true) !== 0 || wire.getUint32(52, true) !== 0 || wire.getUint32(56, true) !== 0 || wire.getUint32(60, true) !== 0)
    throw new Error("invalid composition reserved words");
  const op = request[1]!, facts = request[2]!;
  const allowed = op === 0 ? 1 : op === 1 ? 15 : op === 5 ? 31 : op === 6 ? 1 : 0;
  if ((facts & ~allowed) !== 0) throw new Error("invalid composition facts");
  const result = new Uint8Array(128), out = new DataView(result.buffer);
  result[0] = request[3]!;
  const float = (slot: number, value: number): void => out.setFloat32(32 + slot * 4, value, true);
  const authored = (slot: number, at: number): void => out.setUint32(32 + slot * 4, wire.getUint32(at, true), true);
  // The three integers are active, index and count. They never round through
  // a JavaScript number, including max-u64 active navigation and step values.
  const activeLo = wire.getUint32(8, true), activeHi = wire.getUint32(12, true);
  const indexLo = wire.getUint32(16, true), indexHi = wire.getUint32(20, true);
  const countLo = wire.getUint32(24, true), countHi = wire.getUint32(28, true);
  if (op === 0) {
    if (result[0] === 0) result[0] = 1; // input group
    result[1] = facts & 1;
    result[3] = (facts & 1) !== 0 ? 2 : 1;
  } else if (op === 1) {
    result[1] = facts & 7; // dissolve only unauthored entry chrome
    if ((facts & 8) !== 0) float(6, 1);
    else authored(6, 32);
  } else if (op === 2) {
    authored(0, 36);
    float(2, 4); float(3, 8); float(4, 8); float(5, 8);
  } else if (op === 3) {
    if (result[0] === 0) result[0] = 11; // stepper list
    float(0, 8);
    if (countLo !== 0 || countHi !== 0) {
      // Match the host checked count arithmetic before allocating children.
      if (countHi >= 2147483648) throw new Error("composition child count overflow");
      const low = (countLo * 2 - 1) >>> 0;
      const high = (countHi * 2 + (countLo >= 2147483648 ? 1 : 0) - (countLo === 0 ? 1 : 0)) >>> 0;
      out.setUint32(16, low, true); out.setUint32(20, high, true);
    }
  } else if (op === 4) {
    const earlier = indexHi < activeHi || indexHi === activeHi && indexLo < activeLo;
    const same = indexHi === activeHi && indexLo === activeLo;
    result[2] = earlier ? 0 : same ? 1 : 2;
    result[4] = result[2] === 2 ? 3 : 1; // outline / primary
    result[1] = (result[2] === 0 ? 1 : 0) | (same ? 2 : 0) | (result[2] === 2 ? 4 : 0);
    float(0, 6);
    const suffix = new TextEncoder().encode(nscvCompositionStateName(result[2]!));
    result[100] = suffix.length;
    for (let i = 0; i < suffix.length; i++) result[104 + i] = suffix[i]!;
  } else if (op === 5) {
    result[0] = 12; // timeline item
    result[1] = facts & 15;
    result[3] = 1 + ((facts & 2) !== 0 ? 1 : 0) + ((facts & 4) !== 0 ? 1 : 0);
    float(7, (facts & 16) !== 0 ? 10 : 0); float(8, (facts & 16) !== 0 ? 10 : 0);
    float(9, (facts & 1) !== 0 ? 4 : 0); float(10, 1); float(11, 1);
    float(12, 1); float(13, 2); float(14, 10); float(15, 8); float(16, 0.9);
  } else if (op === 7) {
    if (result[0] === 0) result[0] = 11;
    authored(0, 36);
  } else {
    if (result[0] === 0) result[0] = 1; // navigation group
    if (countLo !== 0 || countHi !== 0) {
      const lastLo = (countLo - 1) >>> 0, lastHi = (countHi - (countLo === 0 ? 1 : 0)) >>> 0;
      const beyond = activeHi > lastHi || activeHi === lastHi && activeLo > lastLo;
      out.setUint32(8, beyond ? lastLo : activeLo, true);
      out.setUint32(12, beyond ? lastHi : activeHi, true);
      out.setUint32(16, (facts & 1) !== 0 ? countLo : 1, true);
      out.setUint32(20, (facts & 1) !== 0 ? countHi : 0, true);
    }
    result[1] = facts & 1;
  }
  return result;
}

function nscvCompositionRequest(op: number, facts: number, role: number, active: number, index: number, count: number, grow = 0, gap = 0): Uint8Array {
  const request = new Uint8Array(64), wire = new DataView(request.buffer);
  request[0] = 19; request[1] = op; request[2] = facts; request[3] = role;
  for (let i = 0; i < 3; i++) {
    const value = i === 0 ? active : i === 1 ? index : count;
    if (!Number.isSafeInteger(value) || value < 0) throw new Error("composition requires nonnegative exact integers");
    wire.setUint32(8 + i * 8, value % 4294967296, true);
    wire.setUint32(12 + i * 8, Math.floor(value / 4294967296), true);
  }
  wire.setFloat32(32, grow, true); wire.setFloat32(36, gap, true);
  return nscvCompositionPolicy(request);
}
