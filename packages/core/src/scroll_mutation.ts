/** Scroll mutation capability programs (101). Native retains the complete
 * states, f32 physics/geometry and callbacks. This owner sequences admission,
 * numeric capabilities, retained writes, events, accessibility and damage.
 * Facts are refreshed after each stage; no pointer or identity crosses here.
 * Modes: axis, textarea, driver, keyboard, kinetic region, kinetic finish,
 * and a batched kinetic-region selection over at most 1024 copied node facts.
 * Facts: valid=1, scroll=2, textarea=4, model-owned=8, y=16, x=32,
 * native=64, rubberband=128, viewport=256, moved=512, needs-step=1024.
 * Capabilities (see native Kind): 0–4 observations/delegation, 5–10 axis
 * arithmetic/store/compare, 11–16 geometry/event/semantics/revision/damage,
 * 17–23 driver/target/state/both-axis writes, 24–31 kinetic probes/steps/damage.
 */
function nscvScrollMutation(request: Uint8Array): Uint8Array {
  if (request[1] === 6) {
    if (request.length < 16 || request[0] !== 101 || request[2] !== 0 || request[3] !== 0 ||
        request[4] !== 0 || request[5] !== 0 || request[6] !== 0 || request[7] !== 0)
      throw new Error("invalid kinetic selection header");
    const w = new DataView(request.buffer, request.byteOffset, request.byteLength), count = w.getUint32(8, true);
    if (count > 1024 || request.length !== 16 + count || w.getUint32(12, true) !== 0)
      throw new Error("invalid kinetic selection facts");
    const result = new Uint8Array(8 + count); result[0] = 101; result[1] = 6;
    new DataView(result.buffer).setUint32(4, count, true);
    for (let i = 0; i < count; i++) result[8 + i] = (request[16 + i]! & (2 | 8 | 64)) === 2 ? 1 : 0;
    return result;
  }
  if (request.length !== 16 || request[0] !== 101 || request[1]! > 5 || request[2]! > 4 ||
      request[3]! > 2 || request[4]! > 1 || request[5] !== 0 || request[6] !== 0 || request[7] !== 0)
    throw new Error("invalid scroll mutation header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const mode = request[1]!, phase = request[2]!, source = request[3]!, facts = w.getUint32(8, true);
  if (facts > 2047 || w.getUint32(12, true) !== 0 || (mode === 3 && source > 1) ||
      (mode === 5 ? phase !== 0 : mode === 4 ? phase > 4 : phase > 2))
    throw new Error("invalid scroll mutation facts");
  const actions: number[] = [];
  let next = 255;
  const granted = (facts & (request[4] === 1 ? 16 : 32)) !== 0;
  if (mode === 5) {
    if ((facts & 512) !== 0) actions.push(14, 15);
  } else if (phase === 0) {
    if ((facts & 1) !== 0) {
      if (mode === 0) {
        if ((facts & 4) !== 0) { if (granted) actions.push(4); }
        else if ((facts & 2) !== 0 && (facts & 8) === 0 && granted) { actions.push(0); next = 1; }
      } else if (mode === 1) {
        if ((facts & 4) !== 0) { actions.push(1); next = 1; }
      } else if ((facts & 2) !== 0 && (facts & 8) === 0 && (mode !== 4 || (facts & 64) === 0)) {
        actions.push(0); next = 1;
      }
    }
  } else if (phase === 1) {
    if ((facts & 256) === 0) { if (mode === 4) actions.push(24); }
    else if (mode === 0 || mode === 1) {
      actions.push(mode === 0 ? 2 : 3);
      actions.push(source === 0 ? 7 : mode === 0 && (facts & 128) !== 0 && (facts & 64) === 0 ? 5 : 6);
      // Detented engine input cancels momentum even at an unchanged offset.
      // Textareas never retain this temporary velocity in the first place.
      if (mode === 0 && source === 2) actions.push(8);
      actions.push(mode === 0 ? 9 : 10); next = 2;
    } else {
      actions.push(2);
      if (mode === 4) { if ((facts & 16) !== 0) actions.push(25); next = 2; }
      else {
        if ((facts & 16) !== 0) actions.push(mode === 2 ? 17 : 19);
        if ((facts & 32) !== 0) actions.push(mode === 2 ? 18 : 20);
        actions.push(21); next = 2;
      }
    }
  } else if (mode === 4 && phase === 2) {
    actions.push((facts & (16 | 1024)) === (16 | 1024) ? 27 : 29);
    if ((facts & 32) !== 0) actions.push(26);
    next = 3;
  } else if (mode === 4 && phase === 3) {
    actions.push((facts & (32 | 1024)) === (32 | 1024) ? 28 : 30);
    actions.push(21); next = 4;
  } else if ((facts & 512) !== 0) {
    if (mode <= 1) actions.push(11);
    else actions.push(22);
    if (mode !== 1) actions.push(mode === 0 ? 12 : 23, 13);
    if (mode === 4) actions.push(31);
    else actions.push(14, 15, 16);
  }
  const result = new Uint8Array(8 + actions.length);
  result[0] = 101; result[1] = mode; result[2] = next; result[3] = actions.length;
  for (let i = 0; i < actions.length; i++) result[8 + i] = actions[i]!;
  return result;
}
