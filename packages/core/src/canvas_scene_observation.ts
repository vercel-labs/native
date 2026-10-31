/** Retained scene observations and host presentation preparation. Native
 * supplies lazy command bounds and keeps display lists, buffers and OS calls. */
interface NscSceneIdentity { scene_low: number; scene_high: number; scene_slot: number }
function nscvSceneIdentityOrder(a: NscSceneIdentity, b: NscSceneIdentity): number {
  return a.scene_high === b.scene_high ? a.scene_low - b.scene_low || a.scene_slot - b.scene_slot : a.scene_high - b.scene_high;
}
function nscvCanvasSceneObservation(request: Uint8Array): Uint8Array {
  if (request.length < 64 || request[0] !== 76 || request[1] !== 1 || request[2]! > 6 || request[3] !== 0)
    throw new Error("invalid scene observation header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), mode = request[2]!;
  const previous = w.getUint32(4, true), current = w.getUint32(8, true), start = w.getUint32(12, true);
  const observed = w.getUint32(40, true);
  for (let at = 44; at < 64; at += 4) if (w.getUint32(at, true) !== 0) throw new Error("invalid scene reserved bytes");
  if (mode <= 2) {
    if (previous > Math.floor((request.length - 64) / 32) || current > Math.floor((request.length - 64) / 32) - previous || request.length !== 64 + (previous + current) * 32 ||
        mode !== 0 && previous !== 0 || (mode !== 1 && start !== 0) || (mode === 2 && observed !== 0) || (mode === 0 && observed > 1) || observed > 2 || start > current)
      throw new Error("invalid scene observation counts");
    for (let i = 0; i < previous + current; i++) {
      const at = 64 + i * 32, flags = w.getUint32(at, true);
      if (flags > 3 || w.getUint32(at + 12, true) !== 0 || (flags & 1) === 0 && (w.getUint32(at + 4, true) !== 0 || w.getUint32(at + 8, true) !== 0))
        throw new Error("invalid scene identity");
    }
  } else if (request.length !== 128 || previous !== 0 || current !== 0 || start !== 0 || observed !== 0)
    throw new Error("invalid scene preparation shape");
  if (mode !== 0) for (let at = 16; at < 40; at += 4) if (w.getUint32(at, true) !== 0) throw new Error("invalid scene unused header");
  if (mode >= 3) {
    const firstUnused = mode === 5 ? 80 : mode === 6 ? 68 : 84;
    for (let at = firstUnused; at < (mode <= 4 ? 96 : 128); at += 4) if (w.getUint32(at, true) !== 0) throw new Error("invalid scene unused preparation");
    if (mode <= 4) for (let at = 116; at < 128; at += 4) if (w.getUint32(at, true) !== 0) throw new Error("invalid scene unused bounds");
  }
  const result = new Uint8Array(mode === 0 ? 64 + (previous + current) * 16 : 64), out = new DataView(result.buffer);
  out.setUint32(0, 1, true);
  const copy = (to: number, from: number): void => out.setUint32(to, w.getUint32(from, true), true);
  if (mode === 0) {
    if (w.getUint32(16, true) === w.getUint32(24, true) && w.getUint32(20, true) === w.getUint32(28, true)) return result.subarray(0, 64);
    const keys = (offset: number, count: number): NscSceneIdentity[] => {
      const values: NscSceneIdentity[] = [];
      for (let i = 0; i < count; i++) {
        const at = 64 + (offset + i) * 32;
        if ((w.getUint32(at, true) & 1) !== 0) values.push({ scene_low: w.getUint32(at + 4, true), scene_high: w.getUint32(at + 8, true), scene_slot: i });
      }
      values.sort(nscvSceneIdentityOrder); return values;
    };
    if (observed === 1) { if (previous !== 0 || current !== 0) throw new Error("invalid scene observation admission"); out.setUint32(8, 1, true); return result; }
    const oldKeys = keys(0, previous), newKeys = keys(previous, current);
    const find = (values: NscSceneIdentity[], at: number): number => {
      const low = w.getUint32(at + 4, true), high = w.getUint32(at + 8, true);
      let first = 0, last = values.length;
      while (first < last) {
        const mid = first + Math.floor((last - first) / 2), row = values[mid]!;
        if (row.scene_high < high || row.scene_high === high && row.scene_low < low) first = mid + 1; else last = mid;
      }
      if (first === values.length) return -1;
      const row = values[first]!;
      return row.scene_low === low && row.scene_high === high ? row.scene_slot : -1;
    };
    let count = 0;
    const emit = (kind: number, before: number, after: number): boolean => {
      const at = 64 + count * 16;
      out.setUint32(at, kind, true); out.setUint32(at + 4, before, true); out.setUint32(at + 8, after, true); count++;
      // Include the first overflowing action: its lazy bounds observation
      // still precedes the native bounded-output error.
      return w.getUint32(36, true) === 0 && count > w.getUint32(32, true);
    };
    let stopped = false;
    for (let i = 0; i < previous; i++) {
      const at = 64 + i * 32;
      if ((w.getUint32(at, true) & 1) !== 0 && find(newKeys, at) < 0 && emit(1, i, 4294967295)) { stopped = true; break; }
    }
    if (!stopped) for (let i = 0; i < current; i++) {
      const at = 64 + (previous + i) * 32;
      if ((w.getUint32(at, true) & 1) === 0) continue;
      const before = find(oldKeys, at);
      if (emit(before < 0 ? 0 : 2, before < 0 ? 4294967295 : before, i)) break;
    }
    out.setUint32(4, count, true); return result.subarray(0, 64 + count * 16);
  }
  if (mode === 1) {
    if (observed === 2) out.setUint32(4, 1, true);
    else {
      let next = current;
      for (let i = start; i < current; i++) if ((w.getUint32(64 + i * 32, true) & 1) === 0) { next = i; break; }
      out.setUint32(8, next, true);
    }
  } else if (mode === 2) {
    for (let i = 0; i < current; i++) if (w.getUint32(64 + i * 32, true) === 2) { out.setUint32(4, 1, true); break; }
  } else if (mode === 3 || mode === 4) {
    const a = w.getUint32(64, true), b = w.getUint32(96, true);
    if (a > 1 || b > 1) throw new Error("invalid scene optional bounds");
    if (mode === 3 && (a === 0 || b === 0)) {
      const at = a !== 0 ? 68 : b !== 0 ? 100 : -1;
      if (at >= 0) {
        out.setUint32(4, 1, true); for (let i = 0; i < 4; i++) copy(16 + i * 4, at + i * 4);
        for (let i = 0; i < 2; i++) if (w.getFloat32(at + 8 + i * 4, true) < 0) {
          out.setFloat32(16 + i * 4, Math.fround(w.getFloat32(at + i * 4, true) + w.getFloat32(at + 8 + i * 4, true)), true);
          out.setUint32(24 + i * 4, (w.getUint32(at + 8 + i * 4, true) ^ 2147483648) >>> 0, true);
        }
      }
    } else if (a !== 0 && b !== 0) {
      const f = Math.fround;
      const rect = (at: number): number[] => {
        let x = w.getFloat32(at, true), y = w.getFloat32(at + 4, true), width = w.getFloat32(at + 8, true), height = w.getFloat32(at + 12, true);
        if (width < 0) { x = f(x + width); width = -width; }
        if (height < 0) { y = f(y + height); height = -height; }
        return [x, y, width, height];
      };
      const left = rect(68), right = rect(100);
      const min = (x: number, y: number): number => Number.isNaN(x) ? y : Number.isNaN(y) ? x : Math.min(x, y);
      const max = (x: number, y: number): number => Number.isNaN(x) ? y : Number.isNaN(y) ? x : Math.max(x, y);
      let x: number, y: number, width: number, height: number;
      if (mode === 3) {
        const emptyLeft = left[2]! <= 0 || left[3]! <= 0, emptyRight = right[2]! <= 0 || right[3]! <= 0;
        if (emptyLeft || emptyRight) {
          const value = emptyLeft && emptyRight ? [0, 0, 0, 0] : emptyLeft ? right : left;
          out.setUint32(4, 1, true);
          for (let i = 0; i < 4; i++) out.setFloat32(16 + i * 4, value[i]!, true);
          return result;
        }
        x = min(left[0]!, right[0]!); y = min(left[1]!, right[1]!);
        width = f(max(f(left[0]! + left[2]!), f(right[0]! + right[2]!)) - x);
        height = f(max(f(left[1]! + left[3]!), f(right[1]! + right[3]!)) - y);
      } else {
        x = max(0, right[0]!); y = max(0, right[1]!);
        const endX = min(left[2]!, f(right[0]! + right[2]!)), endY = min(left[3]!, f(right[1]! + right[3]!));
        if (endX <= x || endY <= y) return result;
        width = f(endX - x); height = f(endY - y);
        if (width <= 0 || height <= 0) return result;
        x = f(x + left[0]!); y = f(y + left[1]!);
      }
      out.setUint32(4, 1, true);
      out.setFloat32(16, x, true); out.setFloat32(20, y, true); out.setFloat32(24, width, true); out.setFloat32(28, height, true);
    }
  } else if (mode === 5) {
    for (let i = 0; i < 4; i++) {
      const value = w.getFloat32(64 + i * 4, true);
      // Native clamp chooses the upper endpoint for NaN.
      const clamped = Number.isNaN(value) ? 1 : Math.min(Math.max(value, 0), 1);
      result[16 + i] = Math.trunc(Math.fround(Math.fround(clamped * 255) + 0.5));
    }
  } else {
    const macos = w.getUint32(64, true); if (macos > 1) throw new Error("invalid blur host observation");
    out.setFloat32(16, macos === 1 ? 3 : 1, true);
  }
  return result;
}
