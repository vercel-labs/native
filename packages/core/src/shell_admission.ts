/** Portable scene and runtime descriptor admission over copied raw facts. */
function nscvShellAdmission(request: Uint8Array): Uint8Array {
  if (request.length < 64 || request[0] !== 85 || request[1] !== 1 || request[2]! > 11 || request[3] !== 0)
    throw new Error("invalid shell admission header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), mode = request[2]!;
  const word = (at: number): number => w.getUint32(at, true);
  const over = (at: number, limit: number): boolean => word(at + 4) !== 0 || word(at) > limit;
  const empty = (at: number): boolean => word(at) === 0 && word(at + 4) === 0;
  let status = 0, state = 0;
  if (mode === 0) {
    const field = word(4), prior = word(12), count = word(32), final = word(36);
    if (field > 9 || prior > 15 || final > 1 || count > 256 || request.length !== 64 + count)
      throw new Error("invalid shell field bounds");
    const endLow = word(24) + count, carry = endLow > 4294967295 ? 1 : 0, endHigh = word(28) + carry;
    if (endHigh > word(20) || endHigh === word(20) && endLow - carry * 4294967296 > word(16) || final === 1 && (endHigh !== word(20) || endLow - carry * 4294967296 !== word(16)))
      throw new Error("invalid shell field extent");
    for (let i = 56; i < 64; i++) if (request[i] !== 0) throw new Error("invalid shell field padding");
    state = prior;
    const dot = word(20) === 0 && (word(16) === 1 && request[48] === 46 || word(16) === 2 && request[48] === 46 && request[49] === 46);
    let prefix = 0, web = false;
    if (field === 6) {
      if (request[48] === 104 && request[49] === 116 && request[50] === 116 && request[51] === 112) {
        if (request[52] === 58 && request[53] === 47 && request[54] === 47) { prefix = 7; web = true; }
        else if (request[52] === 115 && request[53] === 58 && request[54] === 47 && request[55] === 47) { prefix = 8; web = true; }
      } else if ((request[48] === 102 && request[49] === 105 && request[50] === 108 && request[51] === 101 || request[48] === 122 && request[49] === 101 && request[50] === 114 && request[51] === 111) && request[52] === 58 && request[53] === 47 && request[54] === 47) prefix = 7;
      if (prefix === 0 || word(20) === 0 && word(16) <= prefix) state |= 1;
    }
    const appIcon = field === 8 && request[48] === 97 && request[49] === 112 && request[50] === 112 && request[51] === 58;
    for (let i = 0; i < count; i++) {
      const ch = request[64 + i]!, position = word(24) + i, leading = word(28) === 0;
      if (field <= 2 || field === 5 || field === 9) {
        if (ch === 0 || ch === 47 || ch === 92) state |= 1;
        if (ch === 9 || ch === 10 || ch === 13) state |= 2;
      } else if (field === 3 || field === 4) {
        if (ch === 0) state |= 1;
      } else if (field === 6) {
        if (leading && position < prefix) continue;
        if (web && (state & 8) !== 0) continue;
        if (web && ch === 47) { state |= 8; continue; }
        state |= 4;
        if (ch === 0 || ch === 32 || ch === 9 || ch === 10 || ch === 13) state |= 1;
      } else if (field === 7) {
        if (ch < 32 || ch === 127) state |= 1;
      } else if (field === 8) {
        if (appIcon && leading && position < 4) continue;
        if (!(ch >= 97 && ch <= 122 || ch >= 48 && ch <= 57 || ch === 45 || ch === 95)) state |= 1;
      }
    }
    if (field <= 2) status = empty(16) || dot || (state & 1) !== 0 || field > 0 && over(16, 64) ? 1 : 0;
    else if (field <= 4) status = (state & 1) !== 0 || field === 3 && over(16, 256) ? 1 : 0;
    else if (field === 5) status = empty(16) || over(16, 128) ? 6 : dot || (state & 1) !== 0 ? 1 : (state & 2) !== 0 ? 6 : 0;
    else if (field === 6) status = (state & 1) !== 0 || final === 1 && (state & 4) === 0 ? 8 : 0;
    else if (field === 7) status = empty(16) || over(16, 128) || (state & 1) !== 0 ? 1 : 0;
    else if (field === 8) status = over(16, 64) || (state & 1) !== 0 || appIcon && word(20) === 0 && word(16) === 4 ? 1 : 0;
    else status = empty(16) || over(16, 128) || dot || (state & 3) !== 0 ? 6 : 0;
  } else if (mode === 3) {
    const count = word(16);
    if (over(16, 128) || request.length !== 64 + count * 4) throw new Error("invalid shell hierarchy bounds");
    const visits: number[] = [];
    for (let i = 0; i < count; i++) visits.push(0);
    for (let i = 0; i < count; i++) {
      let at = i;
      while (at !== 4294967295 && visits[at] === 0) {
        visits[at] = 1;
        at = word(64 + at * 4);
        if (at !== 4294967295 && at >= count) throw new Error("invalid shell parent slot");
      }
      if (at !== 4294967295 && visits[at] === 1) { status = 2; break; }
      at = i;
      while (at !== 4294967295 && visits[at] === 1) { visits[at] = 2; at = word(64 + at * 4); }
    }
  } else {
    if (request.length !== (mode === 2 || mode === 8 || mode === 9 ? 160 : 64)) throw new Error("invalid shell admission tail");
    if (mode === 1) {
      status = word(4) || word(8);
      if (status === 0 && (w.getFloat32(32, true) <= 0 || w.getFloat32(36, true) <= 0)) status = 5;
      if (status === 0 && over(16, 128)) status = 2;
    } else if (mode === 2) {
      const flags = word(4), duplicate = word(8), parent = word(12), kind = word(80);
      if (flags > 1023 || duplicate > 1 || kind > 18 || word(84) > 63) throw new Error("invalid shell descriptor facts");
      status = word(16);
      if (status === 0 && duplicate) status = 3;
      if (status === 0 && (flags & 64) !== 0) status = word(20) || (parent === 4294967295 || parent === word(88) ? 2 : 0);
      if (status === 0) {
        for (let i = 0; i < 6; i++) if ((flags & (1 << i)) !== 0) {
          const value = w.getFloat32(48 + i * 4, true);
          if (i === 2 || i === 3 ? value < 0 : value <= 0) status = 5;
        }
        if ((flags & 20) === 20 && w.getFloat32(56, true) > w.getFloat32(64, true) || (flags & 40) === 40 && w.getFloat32(60, true) > w.getFloat32(68, true)) status = 5;
      }
      for (let i = 0; i < 4 && status === 0; i++) status = word(24 + i * 4);
      if (status === 0) status = (flags & 128) !== 0 ? kind !== 0 ? 8 : word(40) : kind === 0 ? 9 : 0;
      if (status === 0 && kind !== 17 && word(84) !== 0) status = 10;
    } else if (mode === 4) status = over(16, 16) ? 2 : 0;
    else if (mode === 5) status = over(16, 5) || word(16) === 1 ? 2 : 0;
    else if (mode === 6) status = word(16) || word(20) || word(24) || (word(4) !== 0 ? 7 : 0);
    else if (mode === 7) status = word(4) !== 0 ? 4 : 0;
    else if (mode === 8 || mode === 9) {
      const flags = word(8), kind = word(4), patch = mode === 9;
      if (kind > 18 || flags > 63) throw new Error("invalid runtime descriptor facts");
      status = empty(64) ? 11 : over(64, 64) ? 12 : 0;
      if (status === 0 && (!patch || (flags & 1) !== 0)) for (let i = 0; i < 4; i++) if (w.getFloat32(32 + i * 4, true) < 0) status = 11;
      if (status === 0 && !patch && (flags & 1) !== 0 && (empty(72) || over(72, 64))) status = 11;
      if (status === 0 && over(80, 64)) status = 13;
      if (status === 0 && over(88, 256)) status = 14;
      if (status === 0 && over(96, 1024)) status = 15;
      if (status === 0 && !empty(104)) status = word(120);
      if (status === 0 && !patch && kind !== 0 && !empty(112)) status = 11;
      if (status === 0 && !patch && kind === 17 && !((request[16] === 1 || request[16] === 3) && request[17] === 1 && request[18] === 1 && (request[19] === 1 || request[19] === 2) && request[20] === 1 && request[21] === 1)) status = 16;
    } else if (mode === 10) {
      const category = word(4);
      if (category > 2) throw new Error("invalid runtime label category");
      status = empty(16) ? category === 0 ? 11 : 18 : over(16, 64) ? category === 0 ? 12 : 19 : 0;
      if (status === 0 && category === 2 && word(20) === 0 && word(16) === 4 && request[40] === 109 && request[41] === 97 && request[42] === 105 && request[43] === 110) status = 20;
    } else if (mode === 11) {
      const category = word(4);
      if (category > 2) throw new Error("invalid runtime frame category");
      const x = w.getFloat32(16, true), y = w.getFloat32(20, true), width = w.getFloat32(24, true), height = w.getFloat32(28, true);
      status = category === 0 ? x < 0 || y < 0 || width < 0 || height < 0 ? 11 : 0 : category === 1 ? !Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0 ? 17 : 0 : x >= 0 && y >= 0 && width > 0 && height > 0 ? 0 : 18;
    }
  }
  if (status > 20) throw new Error("invalid shell field verdict");
  const result = new Uint8Array(16), out = new DataView(result.buffer);
  out.setUint32(0, 1, true); out.setUint32(4, mode, true); out.setUint32(8, status, true); out.setUint32(12, state, true);
  return result;
}
