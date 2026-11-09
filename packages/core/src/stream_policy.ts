/** Portable routing over native-owned spawn/fetch stream slots.
 * 0 admits, 1 looks up, 2 handles a line, 3 handles a spawn terminal,
 * and 4 handles a fetch terminal. Results are copied; the dispatch cycle
 * retains arena ownership. No OS resource or payload bytes cross this seam.
 */
export function native_stream_policy(request: Uint8Array): Uint8Array {
  const operation = request[0];
  if (operation === 0 || operation === 1) {
    const keyAt = operation === 0 ? 5 : 2;
    if (request.length < keyAt) throw new Error("invalid stream declaration");
    if (operation === 0 && (request[1]! > 1 || request[2]! > 1 || request[3]! > 1))
      throw new Error("invalid stream admission fact");
    const keyLength = request[keyAt - 1]!;
    let at = keyAt + keyLength, matching = -1, free = -1;
    if (at > request.length) throw new Error("truncated stream key");
    for (let slot = 0; slot < 16; slot++) {
      if (at + 2 > request.length) throw new Error("truncated stream table");
      const used = request[at]!, length = request[at + 1]!;
      at += 2;
      if (used > 1 || at + length > request.length) throw new Error("invalid stream slot");
      let equal = used === 1 && length === keyLength;
      for (let i = 0; i < length; i++) if (request[at + i] !== request[keyAt + i]) equal = false;
      if (equal && matching < 0) matching = slot;
      if (used === 0 && free < 0) free = slot;
      at += length;
    }
    if (at !== request.length) throw new Error("trailing stream bytes");
    const blocked = operation === 0 && keyLength > 0 &&
      (matching >= 0 || request[2] === 1 || (request[1] === 1 && request[3] === 1));
    const slot = operation === 1 ? matching : blocked ? -1 : free;
    const result = new Uint8Array(1);
    result[0] = slot < 0 ? 255 : slot;
    return result;
  }
  // Result: [route, payload (bytes/number/number+bytes), damage, retire,
  //          error source (native reason / literal truncated)].
  const result = new Uint8Array(5);
  if (operation === 2) {
    if (request.length !== 6) throw new Error("invalid stream line request");
    for (let i = 1; i < 5; i++) if (request[i]! > 1) throw new Error("invalid stream line fact");
    result[0] = request[5]!;
    result[2] = request[2] === 1 || (request[1] === 1 && (request[3] === 1 || request[4] === 1)) ? 1 : 0;
  } else if (operation === 3) {
    if (request.length !== 6) throw new Error("invalid spawn terminal request");
    for (let i = 1; i < 4; i++) if (request[i]! > 1) throw new Error("invalid spawn terminal fact");
    const success = request[2] === 1 && (request[1] === 0 || request[3] === 0);
    result[0] = request[success ? 4 : 5]!;
    result[1] = success ? request[1] === 1 ? 2 : 1 : 0;
    result[3] = 1;
    result[4] = !success && request[2] === 1 ? 1 : 0;
  } else if (operation === 4) {
    if (request.length !== 7) throw new Error("invalid fetch terminal request");
    for (let i = 1; i < 5; i++) if (request[i]! > 1) throw new Error("invalid fetch terminal fact");
    const damaged = request[1] === 1 || request[2] === 1 || request[3] === 1;
    const success = request[4] === 1 && !damaged;
    result[0] = request[success ? 5 : 6]!;
    result[1] = success ? 1 : 0;
    result[2] = damaged ? 1 : 0;
    result[3] = 1;
    result[4] = request[4] === 1 && damaged ? 1 : 0;
  } else throw new Error("invalid stream policy operation");
  return result;
}
