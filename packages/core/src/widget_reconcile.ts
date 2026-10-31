/** One rebuild plan for controls and text. Native supplies exact storage
 * lookups, byte/fingerprint equality and caret geometry; no retained pointer,
 * text buffer, composition or code-cache identity crosses this wire.
 * Header: tag 93, three zero bytes, count u32LE. Each 64-byte fact contains
 * kind, admission flags, comparison flags, zero, four f32 values, selection
 * flags and three zeros, four opaque u64 caret offsets, and eight zeros.
 * Each output is action bits u32LE and a control value f32LE.
 */
function nscvWidgetReconcile(request: Uint8Array): Uint8Array {
  if (request.length < 8 || request[0] !== 93 || request[1] !== 0 || request[2] !== 0 || request[3] !== 0)
    throw new Error("invalid widget reconcile header");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const count = wire.getUint32(4, true);
  if (count > 1024 || request.length !== 8 + count * 64) throw new Error("invalid widget reconcile table");
  const output = new Uint8Array(8 + count * 8), out = new DataView(output.buffer);
  output[0] = 93; out.setUint32(4, count, true);
  for (let i = 0; i < count; i++) {
    const at = 8 + i * 64, kind = request[at]!, admission = request[at + 1]!, facts = request[at + 2]!;
    if (kind > 62 || facts > 127 || request[at + 3] !== 0 || request[at + 20]! > 127 ||
        request[at + 21] !== 0 || request[at + 22] !== 0 || request[at + 23] !== 0 ||
        wire.getUint32(at + 56, true) !== 0 || wire.getUint32(at + 60, true) !== 0)
      throw new Error("invalid widget reconcile fact");
    const editable = kind >= 35 && kind <= 39;
    let actions = editable ? 1024 : 0, value = 0;
    const eligible = (admission & 7) === 1;
    if (eligible && (admission & 8) !== 0) {
      const source = (facts & 1) !== 0, previous = (facts & 2) !== 0, retained = (facts & 4) !== 0;
      const exclusive = kind === 14 || kind === 41 || kind === 42 || kind === 44 || kind === 46 || kind === 48;
      if (kind === 32 || kind === 47 || kind === 49 || kind === 50 || exclusive) {
        const selected = kind === 32 ? source || previous ? source : retained :
          exclusive && (admission & 16) !== 0 && source !== previous ? source : retained;
        actions |= 1 | (selected ? 2 : 0);
      } else if (kind === 51) {
        const current = wire.getFloat32(at + 4, true), prior = wire.getFloat32(at + 8, true);
        const runtime = wire.getFloat32(at + 12, true);
        const candidate = (admission & 16) === 0 || current === prior || (facts & 8) !== 0 ? runtime : current;
        // Native clamp evaluates max(0, min(candidate, 1)); NaN selects the upper bound.
        value = Number.isNaN(candidate) ? 1 : Math.max(0, Math.min(candidate, 1)); actions |= 4;
      } else if (kind === 16) {
        const minimum = wire.getFloat32(at + 16, true), retainedWidth = wire.getFloat32(at + 12, true);
        value = Number.isNaN(retainedWidth) ? minimum : Math.max(minimum, retainedWidth); actions |= 8;
      }
    }
    if (eligible && (admission & 32) !== 0) {
      const selection = request[at + 20]!;
      if (kind === 26) {
        if ((selection & 1) === 0 && (facts & 48) === 48) actions |= 64;
      } else if (editable) {
        const packet = new Uint8Array(40);
        packet[0] = 5; packet[1] = (facts & 64) !== 0 ? 1 : 0; packet[2] = (facts & 16) !== 0 ? 1 : 0;
        packet[4] = selection & 7; packet[5] = (selection >>> 3) & 3; packet[6] = (selection >>> 5) & 3;
        packet.set(request.subarray(at + 24, at + 56), 8);
        const result = nscvTextReconcile(packet)[0]!;
        if ((result & 2) !== 0) {
          actions |= 32 | ((result & 1) !== 0 ? 16 : 0) | ((result & 4) !== 0 ? 64 : 0) | ((result & 8) !== 0 ? 128 : 0);
          if ((admission & 64) !== 0) actions |= 256 | ((admission & 128) === 0 ? 512 : 0);
        }
      }
    }
    out.setUint32(8 + i * 8, actions, true); out.setFloat32(12 + i * 8, value, true);
  }
  return output;
}
