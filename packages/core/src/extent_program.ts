/** Retained virtual-table capability programs. Arithmetic and sparse updates
 * stay with the existing extent reducer; this owner orders their effects on
 * native storage and the app's estimate callback. No pointer crosses the ABI.
 */
function nscvExtentProgram(request: Uint8Array): Uint8Array {
  if (request.length < 4 || request[0] !== 100 || request[1]! > 1 || request[3] !== 0)
    throw new Error("invalid extent program header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const actions: number[] = [], arguments_: NscFlowInteger[] = [];
  const emit = (action: number, argument: NscFlowInteger = nscvFlowSmall(0)): void => {
    actions.push(action); arguments_.push(argument);
  };
  let flags = 0, gap = 0;
  if (request[1] === 0) {
    if (request.length !== 72 || request[2]! > 1 || w.getUint32(4, true) !== 0 ||
        w.getUint32(60, true) !== 0 || w.getUint32(64, true) !== 0 || w.getUint32(68, true) !== 0)
      throw new Error("invalid extent sync program facts");
    // Reuse the original exact-word shape decision, with no redundant
    // interpretation of identities, counts, chunk arithmetic or gap values.
    const facts = request.slice(); facts[0] = 10; facts[1] = 0; facts[2] = 0;
    const decision = nscvExtentPolicy(facts), plan = new DataView(decision.buffer);
    const mode = decision[0]!;
    flags = decision[1]!; gap = plan.getFloat32(4, true);
    if (mode === 1) emit(0); // Reset before refreshing callback storage.
    emit(1); // Refresh estimate callback, context and uniform estimate.
    emit(mode === 1 ? 3 : 2); // Initialize fresh identity, or read old total.
    emit(4); // Install the new sanitized gap after reading the old total.
    if (mode === 3) emit(5, nscvFlowInteger(plan, 24)); // Old shape, new gap.
    if (mode !== 0) {
      emit(6); // Install the new count/base before pruning and rebuilding.
      if (mode === 2 || mode === 3 || mode === 5) emit(7);
      emit(8, nscvFlowInteger(plan, 16));
    }
    if (mode !== 1 && (mode === 2 || mode === 3 || mode === 5 || request[2] === 1)) emit(9);
    if (mode === 2) { emit(5, nscvFlowInteger(plan, 24)); emit(10); }
    if (mode === 3) emit(11);
  } else {
    if (request.length !== 16 || request[2]! > 3 || w.getUint32(4, true) !== 0 ||
        w.getUint32(8, true) !== 0 || w.getUint32(12, true) !== 0)
      throw new Error("invalid extent correction program facts");
    // A single measured row needs no prefix query. Begin, end and a complete
    // batch resolve the anchor against the current table before corrections.
    if (request[2] !== 1) emit(12);
    emit(13, nscvFlowSmall(request[2]!));
  }
  const result = new Uint8Array(16 + actions.length * 16), out = new DataView(result.buffer);
  out.setUint32(0, flags, true); out.setFloat32(4, gap, true); out.setUint32(8, actions.length, true);
  for (let i = 0; i < actions.length; i++) {
    out.setUint32(16 + i * 16, actions[i]!, true);
    nscvFlowWrite(out, 24 + i * 16, arguments_[i]!);
  }
  return result;
}
