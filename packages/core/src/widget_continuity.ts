/** Rebuild continuity over copied facts, without transporting identities or
 * retained pointers. Tag 95: mode (0 layout, 1 semantics), two zero bytes,
 * count u32LE, then 24-byte records. Each record has admission bits, three
 * zeros, current y/x and previous y/x f32LE, and four zeros. Admission bits:
 * keyed, scroll view, vertical/horizontal grant, previous scroll state,
 * source semantics, source list metrics, source scroll metrics. Results use
 * the same eight-byte header followed by one action byte per record:
 * restore list metrics, restore scroll semantics, retain y/x velocity.
 * Native owns exact first-match lookups and copies the selected full records.
 */
function nscvWidgetContinuity(request: Uint8Array): Uint8Array {
  if (request.length < 8 || request[0] !== 95 || request[1]! > 1 || request[2] !== 0 || request[3] !== 0)
    throw new Error("invalid widget continuity header");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const count = wire.getUint32(4, true), mode = request[1]!;
  if (count > 1024 || request.length !== 8 + count * 24) throw new Error("invalid widget continuity table");
  const output = new Uint8Array(8 + count);
  output[0] = 95; output[1] = mode;
  new DataView(output.buffer).setUint32(4, count, true);
  for (let i = 0; i < count; i++) {
    const at = 8 + i * 24, facts = request[at]!;
    if (request[at + 1] !== 0 || request[at + 2] !== 0 || request[at + 3] !== 0 || wire.getUint32(at + 20, true) !== 0)
      throw new Error("invalid widget continuity fact");
    let action = 0;
    if (mode === 1) {
      if ((facts & (32 | 128)) === (32 | 128)) action = 2;
    } else {
      if ((facts & (32 | 64)) === (32 | 64)) action = 1;
      if ((facts & (1 | 2 | 16)) === (1 | 2 | 16)) {
        if ((facts & 4) !== 0 && wire.getFloat32(at + 4, true) === wire.getFloat32(at + 12, true)) action |= 4;
        if ((facts & 8) !== 0 && wire.getFloat32(at + 8, true) === wire.getFloat32(at + 16, true)) action |= 8;
      }
    }
    output[8 + i] = action;
  }
  return output;
}
