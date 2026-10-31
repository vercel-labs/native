/** Staged rebuild program over copied facts. Operation 96, mode 0 schedules
 * keyed splits, scroll restore, programmatic clamp, tab reveals and anchored
 * relayout in that order for each stratum. The 32-byte header carries count,
 * cursor, stratum, maximum stratum and phase as u32LE; each 8-byte node has
 * keyed-split admission and stratum. The 24-byte result carries action,
 * selected ordinal and the next cursor/phase/stratum. Native refreshes facts
 * after mutations and retains all identities, widgets and geometry buffers.
 * Mode 1 has a 32-byte request: admission flags, zero, then current/origin/
 * previous-source/retained f32LE and twelve zeros. Its 12-byte result selects
 * keep, enter-slide, value-only, retained-slide or relayout with an f32 value.
 */
function nscvStagedRebuild(request: Uint8Array): Uint8Array {
  if (request.length < 32 || request[0] !== 96 || request[1]! > 1 || request[3] !== 0)
    throw new Error("invalid staged rebuild header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  if (request[1] === 1) {
    const flags = request[2]!;
    if (request.length !== 32 || flags > 127 || w.getUint32(20, true) !== 0 || w.getUint32(24, true) !== 0 || w.getUint32(28, true) !== 0)
      throw new Error("invalid staged split facts");
    const current = w.getFloat32(4, true), origin = w.getFloat32(8, true);
    let action = 0, value = current;
    if ((flags & 1) === 0) {
      if ((flags & (4 | 8 | 16)) === (4 | 8 | 16)) { action = 1; value = origin; }
    } else {
      // Reuse the shipped split scalar policy; this program owns when and
      // how its retained result changes the staged geometry.
      const packet = new Uint8Array(26), split = new DataView(packet.buffer);
      packet[0] = 2; packet[1] = ((flags & 2) !== 0 ? 1 : 0) | ((flags & 8) !== 0 ? 2 : 0) | ((flags & 32) !== 0 ? 4 : 0);
      split.setFloat32(2, current, true); split.setFloat32(18, w.getFloat32(12, true), true); split.setFloat32(22, w.getFloat32(16, true), true);
      value = new DataView(nscvSplitPolicy(packet).buffer).getFloat32(0, true);
      if (value !== current) {
        action = 2;
        if ((flags & 4) !== 0) {
          const sourceMoved = (flags & 2) !== 0 && current !== w.getFloat32(12, true);
          action = (flags & 64) === 0 && ((flags & 32) !== 0 || sourceMoved && (flags & 8) !== 0) ? 3 : 4;
        }
      }
    }
    const result = new Uint8Array(12); result[0] = 96; result[1] = 1; result[2] = action;
    new DataView(result.buffer).setFloat32(4, value, true); return result;
  }
  const count = w.getUint32(4, true), cursor = w.getUint32(8, true), stratum = w.getUint32(12, true);
  const maximum = w.getUint32(16, true), phase = w.getUint32(20, true);
  if (request[2] !== 0 || count > 1024 || cursor > count || stratum > maximum || maximum > 1024 || phase > 3 ||
      request.length !== 32 + count * 8 || w.getUint32(24, true) !== 0 || w.getUint32(28, true) !== 0)
    throw new Error("invalid staged rebuild state");
  for (let i = 0; i < count; i++) if (w.getUint32(32 + i * 8, true) > 1 || w.getUint32(36 + i * 8, true) > maximum)
    throw new Error("invalid staged rebuild node");
  let action = 0, selected = 0, nextCursor = cursor, nextPhase = phase, nextStratum = stratum;
  if (phase === 0) {
    let index = cursor;
    while (index < count && (w.getUint32(32 + index * 8, true) === 0 || w.getUint32(36 + index * 8, true) !== stratum)) index++;
    if (index < count) { action = 1; selected = index; nextCursor = index + 1; }
    else { action = 2; nextPhase = 1; nextCursor = count; }
  } else if (phase < 3) { action = phase + 2; nextPhase = phase + 1; }
  else if (stratum < maximum) { action = 5; nextPhase = 0; nextCursor = 0; nextStratum++; }
  const result = new Uint8Array(24), out = new DataView(result.buffer);
  result[0] = 96; result[2] = action; out.setUint32(4, selected, true); out.setUint32(8, nextCursor, true);
  out.setUint32(12, nextPhase, true); out.setUint32(16, nextStratum, true); return result;
}
