/** Display assembly programs (104), shared by interpolation, concatenation,
 * fixed and percent. No values or pointers cross this boundary: native
 * capabilities supply exact i64 conversion, f32 scaling/decimal rendering
 * and arena appends. Each append retains its original allocation boundary.
 * Modes: scalar=0, fixed=1, percent=2. Kinds match expression programs.
 * Instructions: integer=0, shortest=1, scale=2, decimal=3, source=4,
 * number=5, literal=6, repeat=7. Literal bytes belong to the returned plan.
 */
function nscvMarkupDisplay(request: Uint8Array): Uint8Array {
  if (request.length !== 8 || request[0] !== 104 || request[1] !== 1 || request[2]! > 2 ||
      request[3]! < 1 || request[3]! > 4 || request[4]! > 6 || request[5]! > 1 ||
      request[6] !== 0 || request[7] !== 0 || request[2] === 0 && request[4] !== 0 ||
      request[3] !== 4 && request[5] !== 0 || request[2] !== 0 && request[3] !== 2 && request[3] !== 3)
    throw new Error("invalid markup display request");
  const mode = request[2]!, kind = request[3]!, digits = request[4]!;
  const actions: number[] = [], literals: number[] = [];
  if (mode === 0 && kind === 1) actions.push(4, 0, 0, 0);
  else if (mode === 0 && kind === 4) {
    if (request[5] === 1) literals.push(116, 114, 117, 101);
    else literals.push(102, 97, 108, 115, 101);
    actions.push(6, 0, literals.length, 0);
  } else {
    if (mode === 2) actions.push(2, 0, 0, 0);
    actions.push(mode === 2 || mode === 1 && kind === 3 ? 3 : kind === 2 ? 0 : 1,
      mode === 0 ? 0 : digits, 0, 0);
    actions.push(5, 0, 0, 0);
    if (mode === 1 && kind === 2 && digits > 0) {
      literals.push(46);
      actions.push(6, 0, 1, 0, 7, 48, digits, 0);
    }
    // Keep even the empty suffix append in the fixed-format program.
    if (mode !== 0) {
      const offset = literals.length;
      if (mode === 2) literals.push(37);
      actions.push(6, offset, mode === 2 ? 1 : 0, 0);
    }
  }
  const out = new Uint8Array(8 + actions.length + literals.length);
  out[0] = 104; out[1] = 1; out[2] = mode; out[3] = actions.length / 4; out[4] = literals.length;
  for (let i = 0; i < actions.length; i++) out[8 + i] = actions[i]!;
  for (let i = 0; i < literals.length; i++) out[8 + actions.length + i] = literals[i]!;
  return out;
}
