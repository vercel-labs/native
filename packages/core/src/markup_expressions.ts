/** Runtime expression programs (102). Only copied node/operand kinds cross
 * this boundary. Native retains exact i64/f32 values, strings, formatting and
 * allocation; this owner selects capabilities and positions type failures in
 * eager post-order. A digits probe precedes fixed/percent/pad type admission,
 * preserving their value-dependent error priority without executing ahead.
 * Wire kinds: unknown=0, string=1, integer=2, float=3, boolean=4.
 * Instructions: literal=0, binding=1, operators=2..16, digits=17,
 * closed library capabilities=18..34, teaching failure=35.
 */
function nscvMarkupExpressions(request: Uint8Array): Uint8Array {
  if (request.length < 8 || request[0] !== 102 || request[1] !== 1 ||
      request[2] === 0 || request[2]! > 64 || request[3]! >= request[2]! ||
      request[4] !== 0 || request[5] !== 0 || request[6] !== 0 || request[7] !== 0 ||
      request.length !== 8 + request[2]! * 12) throw new Error("invalid expression header");
  const count = request[2]!, root = request[3]!;
  // Validate the whole copied tree, including nodes after a teaching failure.
  for (let i = 0; i < count; i++) {
    const at = 8 + i * 12, kind = request[at]!, fn = request[at + 1]!, argc = request[at + 2]!;
    if (kind > 20 || fn > 16 || request[at + 3]! > 4 || request[at + 10] !== 0 || request[at + 11] !== 0 ||
        (kind === 4 ? request[at + 3] === 0 : request[at + 3] !== 0))
      throw new Error("invalid expression node");
    if ((kind === 5 || kind === 6) && request[at + 4]! >= i ||
        kind >= 7 && kind <= 19 && (request[at + 4]! >= i || request[at + 5]! >= i))
      throw new Error("invalid expression operand");
    if (kind === 20) {
      const minimum = fn === 0 || fn === 9 || fn === 10 || fn === 16 ? 2 : fn === 15 ? 3 : 1;
      const maximum = fn === 2 ? 2 : minimum;
      if (argc < minimum || argc > maximum) throw new Error("invalid expression arity");
      for (let a = 0; a < argc; a++) if (request[at + 6 + a]! >= i) throw new Error("invalid expression argument");
    } else if (argc !== 0) throw new Error("invalid expression argument count");
  }
  const kinds = new Uint8Array(count), instructions: number[] = [];
  for (let i = 0; i < count; i++) {
    const at = 8 + i * 12, kind = request[at]!, fn = request[at + 1]!;
    const left = kinds[request[at + 4]!]!, right = kinds[request[at + 5]!]!;
    let result = 0, failure = 0, capability = kind < 4 ? 0 : kind - 3;
    if (kind < 4) result = kind === 0 ? 2 : kind === 1 ? 3 : kind === 2 ? 1 : 4;
    else if (kind === 4) result = request[at + 3]!;
    else if (kind === 5) { result = left; if (left !== 2 && left !== 3) failure = 1; }
    else if (kind === 6) { result = 4; if (left !== 4) failure = 2; }
    else if (kind >= 7 && kind <= 10) {
      result = kind === 10 || left === 3 || right === 3 ? 3 : 2;
      if ((left !== 2 && left !== 3) || (right !== 2 && right !== 3)) failure = 3;
    } else if (kind === 11) result = 1;
    else if (kind === 12 || kind === 13) result = 4;
    else if (kind >= 14 && kind <= 17) {
      result = 4; if ((left !== 2 && left !== 3) || (right !== 2 && right !== 3)) failure = 4;
    } else if (kind === 18 || kind === 19) {
      result = 4; if (left !== 4 || right !== 4) failure = 2;
    } else {
      capability = 18 + fn;
      const a = kinds[request[at + 6]!]!, b = kinds[request[at + 7]!]!, c = kinds[request[at + 8]!]!;
      const numeric = a === 2 || a === 3;
      result = fn === 9 || fn === 10 ? (a === 2 && b === 2 ? 2 : 3) :
        fn === 11 ? a : fn >= 12 && fn <= 14 ? 2 : 1;
      if (fn === 0 || fn === 2 || fn === 16) {
        // A non-integer digits operand has the range diagnostic, even if
        // the value operand has the wrong type. Probe its range before
        // admitting the value type; previous nodes still execute first.
        if (fn !== 2 || request[at + 2]! > 1) {
          if (b !== 2) failure = 5;
          else instructions.push(i, 17, 0, 0);
        }
        if (failure === 0 && (fn === 16 ? a !== 2 : !numeric)) failure = 16 + fn;
      } else if (fn === 1 || fn >= 3 && fn <= 5) { if (a !== 2) failure = 16 + fn; }
      else if (fn >= 6 && fn <= 8) { if (a !== 1) failure = 16 + fn; }
      else if (fn === 9 || fn === 10) { if (!numeric || (b !== 2 && b !== 3)) failure = 16 + fn; }
      else if (fn >= 11 && fn <= 14) { if (!numeric) failure = 16 + fn; }
      else if (fn === 15 && (a !== 2 || b !== 1 || c !== 1)) failure = 16 + fn;
    }
    instructions.push(i, failure === 0 ? capability : 35, failure, failure === 0 ? result : 0);
    if (failure !== 0) break;
    kinds[i] = result;
  }
  const result = new Uint8Array(8 + instructions.length);
  result[0] = 102; result[1] = 1; result[2] = instructions.length / 4; result[3] = root;
  for (let i = 0; i < instructions.length; i++) result[8 + i] = instructions[i]!;
  return result;
}
