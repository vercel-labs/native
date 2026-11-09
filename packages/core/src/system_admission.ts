/** Portable OS-service descriptor admission. Payloads and OS results stay native. */
function nscvSystemAdmission(request: Uint8Array): Uint8Array {
  if (request.length < 32 || request[0] !== 86 || request[1] !== 1 || request[2]! > 6)
    throw new Error("invalid system admission header");
  const mode = request[2]!, data = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const word = (at: number): number => data.getUint32(at, true);
  const empty = (at: number): boolean => word(at) === 0 && word(at + 4) === 0;
  const over = (at: number, limit: number): boolean => word(at + 4) !== 0 || word(at) > limit;
  let status = 0, next = 0;
  if (mode === 0) {
    const category = request[3]!;
    if (category > 17) throw new Error("invalid system field category");
    const limit = category < 2 || category === 3 || category === 4 ? 4096 : category === 2 ? 512 : category === 7 ? 256 : category === 8 || category === 12 ? 1024 : category === 16 ? 65536 : 128;
    const copied = category === 16 ? 0 : over(8, limit) ? limit : word(8);
    if (request.length !== 32 + copied) throw new Error("invalid system field extent");
    for (let i = 4; i < 8; i++) if (request[i] !== 0) throw new Error("invalid system field padding");
    for (let i = 16; i < 32; i++) if (request[i] !== 0) throw new Error("invalid system field padding");
    const invalid = category === 0 ? 1 : category === 1 ? 3 : category <= 8 ? 5 : category <= 14 ? 7 : category <= 16 ? 10 : 9;
    const tooLarge = category === 0 ? 2 : category === 1 ? 4 : category <= 8 ? 6 : category <= 14 ? 8 : category <= 16 ? 11 : 9;
    const required = category < 2 || category === 5 || category === 8 || category === 15 || category === 17;
    if (required && empty(8)) status = invalid;
    else if (over(8, limit)) status = tooLarge;
    else if (category === 17) status = nscvStatusCommandError(request, { statusByteAt: 32, statusByteCount: word(8), statusNextAt: request.length }) === 0 ? 0 : 9;
    else if (category !== 16) for (let i = 32; i < request.length; i++) {
      const ch = request[i]!;
      if (ch === 0 || category === 8 && ch === 59 || category === 15 && (ch === 92 || ch <= 32 || ch === 127)) status = invalid;
    }
  } else {
    if (request.length !== 64 || request[3] !== 0) throw new Error("invalid system descriptor extent");
    const fieldCount = mode === 1 ? 2 : mode === 2 ? 3 : mode === 3 || mode === 4 ? 6 : 1;
    for (let i = 0; i < fieldCount; i++) if (word(32 + i * 4) > 11) throw new Error("invalid system field verdict");
    if (mode === 1 || mode === 2) {
      if (empty(8)) status = 5;
      for (let i = 0; i < fieldCount && status === 0; i++) status = word(32 + i * 4);
    } else if (mode === 3) {
      for (let i = 0; i < 6 && status === 0; i++) status = word(32 + i * 4);
    } else if (mode === 4) {
      if (word(56) > 11) throw new Error("invalid notification command verdict");
      if (empty(8)) status = 7;
      for (let i = 0; i < 6 && status === 0; i++) status = word(32 + i * 4);
      if (status === 0 && empty(16) !== empty(24)) status = 7;
      if (status === 0 && !empty(24)) status = word(56);
    } else if (mode === 5) status = word(32) || (over(8, 65536) ? 11 : 0);
    else {
      const previous = word(8);
      if (previous > 1025 || word(12) !== 0) throw new Error("invalid filter continuation");
      status = word(32);
      if (status === 0) {
        if (over(16, 1024)) throw new Error("invalid admitted extension length");
        const total = previous + word(16);
        if (total > 1024) status = 6;
        else next = total + 1;
      }
    }
  }
  const result = new Uint8Array(16), out = new DataView(result.buffer);
  out.setUint32(0, 1, true); out.setUint32(4, mode, true);
  out.setUint32(8, status, true); out.setUint32(12, next, true);
  return result;
}
