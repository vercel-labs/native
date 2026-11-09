/** Shell installation decisions. Native owns descriptor bytes, storage, and OS calls. */
function nscvShellCoordination(request: Uint8Array): Uint8Array {
  if (request.length < 64 || request[0] !== 84 || request[1] !== 1 || request[2]! > 7 || request[3] !== 0)
    throw new Error("invalid shell coordination header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const mode = request[2]!, facts = w.getUint32(4, true), count = w.getUint32(8, true), cursor = w.getUint32(12, true);
  for (let i = 48; i < 64; i++) if (request[i] !== 0) throw new Error("invalid shell coordination padding");
  let status = 0, decisions = 0, selected = 4294967295;
  const choices: number[] = [];
  if (mode === 0) {
    if (facts > 1 || count > 16 || cursor > 7 || cursor !== 0 && count !== 1) throw new Error("invalid shell scene bounds");
    let at = 64, needsSource = false;
    for (let i = 0; i < count; i++) {
      if (at + 4 > request.length || request[at]! > 1 || request[at + 1]! > 1) throw new Error("invalid shell window");
      const hidden = request[at] === 1, explicit = request[at + 1] === 1, views = w.getUint16(at + 2, true);
      if (views > 128) throw new Error("invalid shell view count");
      at += 4;
      let hasMain = (cursor & 1) !== 0, hasWeb = (cursor & 2) !== 0, hasGpu = (cursor & 4) !== 0;
      for (let j = 0; j < views; j++) {
        if (at + 13 > request.length || request[at]! > 18) throw new Error("invalid shell view");
        const kind = request[at]!, length = w.getUint32(at + 1, true);
        if (kind === 0) {
          hasWeb = true;
          if (length === 4 && w.getUint32(at + 5, true) === 0 && request[at + 9] === 109 && request[at + 10] === 97 && request[at + 11] === 105 && request[at + 12] === 110) hasMain = true;
        }
        if (kind === 17) hasGpu = true;
        at += 13;
      }
      const usesSource = hasMain || !(hasGpu && !hasWeb) && facts === 0;
      needsSource = needsSource || hasMain;
      // Carry only observations so an app callback may replace a validated
      // view slice with an oversized one before the ordinary creation gate.
      choices.push((hidden ? 1 : hasGpu ? 2 : 0) | (usesSource ? 4 : 0) | (explicit ? 8 : 0) | ((hasMain ? 1 : 0) | (hasWeb ? 2 : 0) | (hasGpu ? 4 : 0)) << 4);
    }
    if (at !== request.length) throw new Error("invalid shell scene tail");
    decisions = count > 0 && (needsSource || facts === 0) ? 1 : 0;
  } else if (mode === 5) {
    if (facts !== 0 || count > 16 || request.length !== 64 + count * 8) throw new Error("invalid shell binding bounds");
    for (let i = 0; i < count; i++) {
      if (w.getUint32(16, true) === w.getUint32(64 + i * 8, true) && w.getUint32(20, true) === w.getUint32(68 + i * 8, true)) { selected = i; break; }
    }
    if (selected === 4294967295) {
      if (count === 16) status = 1;
      else { selected = count; decisions = 1; }
    }
  } else if (mode === 7) {
    if (facts > 5 || (facts & 2) !== 0 || cursor > 1 || count > 128 || request.length !== 64 + count) throw new Error("invalid shell presentation bounds");
    let hasGpu = cursor === 1;
    for (let i = 0; i < count; i++) {
      if (request[64 + i]! > 18) throw new Error("invalid shell presentation kind");
      if (request[64 + i] === 17) hasGpu = true;
    }
    decisions = ((facts & 1) !== 0 ? 1 : hasGpu ? 2 : 0) | ((facts & 4) !== 0 ? 4 : 0) | (hasGpu ? 8 : 0);
  } else {
    if (request.length !== 64) throw new Error("invalid shell coordination tail");
    if (mode === 1) {
      // Ordered, chunked opaque-byte equality; no native equality verdict.
      if (facts > 1 || count > 16 || cursor !== 0) throw new Error("invalid shell comparison bounds");
      decisions = facts;
      for (let i = 0; i < count; i++) if (request[16 + i] !== request[32 + i]) decisions = 0;
    } else if (mode === 2) {
      if (facts > 7 || w.getUint32(16, true) > 18) throw new Error("invalid shell application facts");
      const update = (facts & 1) !== 0, main = (facts & 2) !== 0 && w.getUint32(16, true) === 0, missing = (facts & 4) !== 0;
      decisions = (main ? 1 : 0) | (!update && !main ? 2 : 4) | (update && missing ? 8 : 0);
    } else if (mode === 3) {
      if (facts !== 0 || count > 128 || cursor > count) throw new Error("invalid shell rollback bounds");
      if (cursor > 0) selected = cursor - 1;
    } else if (mode === 4) {
      if (facts > 3) throw new Error("invalid shell restoration facts");
      let different = (facts & 2) !== 0;
      for (let i = 0; i < 4; i++) if (w.getFloat32(16 + i * 4, true) !== w.getFloat32(32 + i * 4, true)) different = true;
      decisions = (facts & 1) === 0 ? 0 : (different ? 1 : 0) | (count !== cursor ? 2 : 0);
    } else if (mode === 6) {
      if (facts > 7 || cursor > 2 || cursor !== 2 && w.getUint32(16, true) > 18 || w.getUint32(28, true) > 32 || w.getUint32(32, true) > 16) throw new Error("invalid shell admission facts");
      const kind = w.getUint32(16, true), main = kind === 0 && (facts & 4) !== 0;
      if ((facts & 1) !== 0 || !main && (facts & 2) !== 0) status = 2;
      else if (!main) decisions = kind === 0 ? 1 : 2;
      if (cursor === 1) {
        if (w.getUint32(20, true) > 32 - w.getUint32(28, true)) status = 3;
        else if (w.getUint32(24, true) > 16 - w.getUint32(32, true)) status = 4;
        decisions = 0;
      } else if (cursor === 2) {
        status = w.getUint32(20, true) !== 0 || w.getUint32(16, true) > 128 ? 3 : 0;
        decisions = 0;
      }
    }
  }
  const result = new Uint8Array(24 + choices.length * 4), out = new DataView(result.buffer);
  out.setUint32(0, 1, true); out.setUint32(4, mode, true); out.setUint32(8, status, true);
  out.setUint32(12, decisions, true); out.setUint32(16, selected, true); out.setUint32(20, choices.length, true);
  for (let i = 0; i < choices.length; i++) out.setUint32(24 + i * 4, choices[i]!, true);
  return result;
}
