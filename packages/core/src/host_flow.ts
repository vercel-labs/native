/** Host event scheduling and runtime lifecycle/dispatch action order.
 * Native owns typed event storage, exact handles, callback execution and OS/GPU
 * capabilities. Every result is a copied program; input is borrowed and immutable.
 */
export function hostFlowPolicy(input: Uint8Array): Uint8Array {
  if (input.length !== 64 || input[0] !== 31 || input[1] !== 1 || input[2]! > 11) throw new Error("invalid host flow request");
  const w = new DataView(input.buffer, input.byteOffset, input.byteLength);
  const out = new Uint8Array(64), v = new DataView(out.buffer);
  const stage = input[2]!, kind = input[3]!, a = input[4]!, b = input[5]!;
  const count = w.getUint32(8, true), used = w.getUint32(12, true), cost = w.getUint32(16, true);
  const head = w.getUint32(20, true), delivered = w.getUint32(24, true);
  for (let at = 6; at < 8; at++) if (input[at] !== 0) throw new Error("invalid host flow reserved field");
  for (let at = 28; at < 64; at++) if (input[at] !== 0) throw new Error("invalid host flow reserved field");
  if (stage === 0 && (kind > 28 || a > 1 || b !== 0 || count > 4096 || used > 4194304 || head !== 0 || delivered !== 0)) throw new Error("invalid host enqueue facts");
  if (stage === 1 && (kind !== 0 || a !== 0 || b !== 0 || count > 4096 || used !== 0 || cost !== 0 || delivered !== 0)) throw new Error("invalid host take facts");
  if ((stage === 2 || stage === 4 || stage === 9) && (kind !== 0 || a > 1 || b > 1 || count !== 0 || used !== 0 || cost !== 0 || head !== 0 || delivered !== 0 || stage === 2 && b !== 0)) throw new Error("invalid host state facts");
  if (stage === 3 && (kind !== 0 || a !== 0 || b !== 0 || count > 4096 || delivered > 4096 || used !== 0 || cost !== 0 || head !== 0)) throw new Error("invalid host turn facts");
  if ((stage === 5 || stage === 7 || stage === 8) && (a !== 0 || b !== 0 || count !== 0 || used !== 0 || cost !== 0 || head !== 0 || delivered !== 0 || stage === 8 && kind !== 0)) throw new Error("invalid host program facts");
  if ((stage === 10 || stage === 11) && (kind > 28 || a > 1 || b > 1 || count !== 0 || used !== 0 || cost !== 0 || head !== 0 || delivered !== 0 || stage === 11 && b !== 0)) throw new Error("invalid host journal facts");
  if (stage === 6 && (count !== 0 || used !== 0 || cost !== 0 || head !== 0 || delivered !== 0 || b > 1 || kind !== 0 && kind !== 3 && kind !== 7 && kind !== 9 && a > 1 || kind === 0 && a > 28 || (kind === 3 || kind === 9) && a > 28 || kind === 7 && (a < 1 || a > 4) || kind !== 0 && kind !== 1 && kind !== 4 && b !== 0)) throw new Error("invalid host gate facts");
  if (stage === 0) {
    out[0] = kind === 4 && count !== 0 && a !== 0 ? 1 : count === 4096 || cost > 4194304 - used ? 2 : 3;
    v.setUint32(8, Math.max(0, 4194304 - used - cost), true);
  } else if (stage === 1) {
    out[0] = count === 0 ? 1 : head >= 4096 && head >= count ? 2 : 0;
  } else if (stage === 2) out[0] = a !== 0 ? 1 : 2;
  else if (stage === 3) out[0] = count === 0 ? 0 : delivered === 4096 ? 2 : 1;
  else if (stage === 4) out[0] = a !== 0 ? 1 : b !== 0 ? 2 : 0;
  else if (stage === 5) {
    switch (kind) {
      case 0: out.set([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]); break;
      case 1: out.set([13, 16, 18]); break;
      case 2: out.set([14, 15, 17, 19]); break;
      case 3: out.set([20, 21, 22]); break;
      case 4: out.set([38]); break;
      case 5: out.set([49, 50, 51, 52, 53]); break;
      case 6: out.set([23, 24, 25, 26, 27, 28]); break;
      case 7: out.set([29, 30, 31, 32, 33, 34]); break;
      case 8: out.set([35, 36]); break;
      case 9: out.set([37, 36]); break;
      case 10: out.set([39]); break;
      case 11: out.set([40, 54]); break;
      case 12: out.set([55, 41, 42, 43]); break;
      case 13: out.set([56]); break;
      case 14: out.set([57]); break;
      case 15: out.set([58]); break;
      case 16: out.set([59]); break;
      case 17: out.set([60]); break;
      case 18: out.set([63]); break;
      case 19: out.set([45, 46, 47, 48, 43]); break;
      case 20: out.set([64]); break;
      case 21: out.set([65, 44]); break;
      case 22: out.set([66]); break;
      case 23: out.set([67]); break;
      case 24: out.set([68]); break;
      case 25: out.set([70]); break;
      case 26: out.set([69]); break;
      case 27: out.set([61]); break;
      case 28: out.set([62]); break;
      default: throw new Error("unknown host event");
    }
  } else if (stage === 6) {
    // Gates: event trace, close edge, harness propagation, journal seal,
    // watcher startup/result, stop fallback, borrowed-drop refusal, presence.
    switch (kind) {
      case 0: out[0] = a !== 4 && a !== 20 || b !== 0 ? 1 : 0; break;
      case 1: out[0] = a !== 0 && b === 0 ? 1 : 0; break;
      case 2: out[0] = a !== 0 ? 1 : 0; break;
      case 3: out[0] = a === 5 ? 1 : 0; break;
      case 4: out[0] = a === 0 ? 0 : b === 0 ? 2 : 1; break;
      case 5: out[0] = a !== 0 ? 0 : 1; break;
      case 6: out[0] = a === 0 ? 1 : 0; break;
      case 7: out[0] = a > 0 && a <= 3 ? 1 : 0; break;
      case 8: out[0] = a !== 0 ? 1 : 0; break;
      case 9: out[0] = a === 0 ? 1 : 0; break;
      default: throw new Error("unknown host flow gate");
    }
  } else if (stage === 7) {
    if (kind > 26) throw new Error("unknown app event");
    out[0] = 4; out[1] = 5;
    if (kind === 2) { out[2] = 1; out[3] = 2; }
    else if (kind === 3 || kind === 17 || kind === 20) out[2] = 2;
    else if (kind === 1 || kind === 25) out[2] = 3;
  } else if (stage === 8) out.set([1, 2, 3, 4, 5, 6, 7]);
  else if (stage === 9) { out[0] = 1; let at = 1; if (a === 0) out[at++] = 2; out[at++] = 3; if (b !== 0) out[at] = 4; }
  else if (stage === 10) { let at = 0; if (a !== 0) out[at++] = 1; if (kind !== 4 && kind !== 20 || b !== 0) out[at] = 2; }
  else if (stage === 11 && a !== 0) { out[0] = 1; out[1] = 2; if (kind === 5) out[2] = 3; }
  return out;
}
