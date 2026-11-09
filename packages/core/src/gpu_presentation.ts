/** Retained presentation programs over copied capability outcomes. Native
 * owns payloads, encoding, baseline storage and the actual GPU calls. */
function nscvGpuPresentation(request: Uint8Array): Uint8Array {
  if (request.length !== 64 || request[0] !== 74 || request[1] !== 1 || request[2]! > 6 || request[3]! > 2)
    throw new Error("invalid GPU presentation header");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const phase = request[2]!, outcome = request[3]!, facts = wire.getUint32(4, true);
  const count = wire.getUint32(8, true), upserts = wire.getUint32(12, true);
  if (facts > 31 || phase < 3 && outcome !== 0 || upserts > count)
    throw new Error("invalid GPU presentation facts");
  for (let at = 48; at < 64; at += 4) if (wire.getUint32(at, true) !== 0)
    throw new Error("invalid GPU presentation reserved bytes");
  // Instructions: gather, edits, patch, keyed full, binary, JSON, done, fallback.
  // Mutations: invalidate baseline, record patch refusal, adopt baseline,
  // record ordinary full present. Refusals: none, missing, binary overflow,
  // JSON overflow, original packet refusal.
  let instruction = 7, mutations = 0, refusal = 0;
  const binary = (facts & 1) !== 0, json = (facts & 2) !== 0, current = (facts & 4) !== 0;
  const jsonNext = (): void => { instruction = json ? 5 : 7; refusal = json ? 0 : 1; };
  if (phase === 0) {
    if (binary) instruction = 0; else jsonNext();
  } else if (phase === 1) {
    if (!current) { instruction = 4; mutations = 1; }
    else if ((facts & 8) !== 0 && (facts & 16) === 0 &&
      wire.getFloat32(24, true) === wire.getFloat32(36, true) &&
      wire.getFloat32(28, true) === wire.getFloat32(40, true) &&
      wire.getFloat32(32, true) === wire.getFloat32(44, true)) instruction = 1;
    else instruction = 3;
  } else if (phase === 2) {
    instruction = upserts < count ? 2 : 3;
  } else if (phase === 3) {
    if (outcome === 0) { instruction = 6; mutations = 4; }
    else { instruction = 3; mutations = outcome === 2 ? 3 : 0; }
  } else if (phase === 4 || phase === 5) {
    if (outcome === 0) { instruction = 6; mutations = phase === 4 ? 4 : 8; }
    else {
      if (phase === 4) mutations = 1;
      if (outcome === 1 && !json) { instruction = 7; refusal = 2; }
      else jsonNext();
    }
  } else {
    if (outcome === 0) { instruction = 6; mutations = 9; }
    else { instruction = 7; refusal = outcome === 1 ? 3 : 4; }
  }
  const result = new Uint8Array(32), out = new DataView(result.buffer);
  out.setUint32(0, 1, true); out.setUint32(4, instruction, true);
  out.setUint32(8, mutations, true); out.setUint32(12, refusal, true);
  let lower = wire.getUint32(16, true), upper = wire.getUint32(20, true);
  if (instruction === 3) {
    if (lower === 4294967295 && upper === 4294967295) { lower = 1; upper = 0; }
    else { lower = (lower + 1) >>> 0; if (lower === 0) upper = (upper + 1) >>> 0; }
  }
  out.setUint32(16, lower, true); out.setUint32(20, upper, true);
  return result;
}
