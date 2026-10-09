// Document-width decisions over copied bytes and font replies. Native keeps
// provider identities, generation counters, retained fields and storage.
function nscvTextDocumentWidth(request: Uint8Array): Uint8Array {
  if (request.length < 128 || request[0] !== 59 || request[1] !== 1 || request[2]! > 2 || request[3]! > 1)
    throw new Error("invalid document width header");
  const out = request.slice(0, 128), w = new DataView(out.buffer);
  const facts = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const mode = out[2]!, flags = w.getUint32(4, true), length = w.getUint32(8, true), textAt = w.getUint32(12, true), slots = w.getUint32(16, true);
  if (flags > (mode === 2 ? 3 : 15) || slots !== (mode === 2 ? Math.min(length, 65536) : 0) || textAt !== 128 + slots * 4 || request.length !== textAt + length || mode !== 2 && length !== 0)
    throw new Error("invalid document width storage");
  if (w.getUint32(52, true) !== 0) throw new Error("invalid document width padding");
  if (mode === 2) for (let at = 32; at < 80; at += 4) if (w.getUint32(at, true) !== 0) throw new Error("invalid document width facts");
  for (let at = 20; at < 32; at += 4) if (w.getUint32(at, true) !== 0) throw new Error("invalid document width padding");
  if (w.getUint32(120, true) !== 0 || w.getUint32(124, true) !== 0) throw new Error("invalid document width padding");
  if (out[3] === 0) {
    for (let at = 80; at < 120; at += 4) if (w.getUint32(at, true) !== 0) throw new Error("invalid initial document width state");
  } else if (mode !== 2 || w.getUint32(92, true) > 1 || w.getUint32(96, true) < 1 || w.getUint32(96, true) > 3 || w.getUint32(100, true) > length || w.getUint32(84, true) > w.getUint32(88, true) || w.getUint32(88, true) > length || w.getUint32(112, true) !== 0 || w.getUint32(116, true) !== 0) {
    throw new Error("invalid document width continuation");
  }
  if (mode !== 2) {
    if (mode === 1) w.setUint32(80, flags === 7 ? 1 : 0, true);
    else {
      let same = (flags & 8) === 0;
      for (let at = 32; at < 48; at += 4) if (w.getUint32(at, true) !== w.getUint32(at + 24, true)) same = false;
      const width = w.getFloat32(76, true);
      w.setUint32(80, same && w.getUint32(48, true) === w.getUint32(72, true) && width >= 0 && Number.isFinite(width) ? 1 : 0, true);
    }
    out[3] = 2; return out;
  }
  const text = request.subarray(textAt);
  let cursor = w.getUint32(100, true), widest = w.getFloat32(104, true), phase = w.getUint32(96, true);
  if (out[3] === 0) {
    if (flags === 3 && length === 0) { out[3] = 2; return out; }
    phase = flags === 3 ? 1 : 3;
  } else {
    const first = w.getUint32(84, true), last = w.getUint32(88, true);
    if (phase === 1) {
      if (w.getUint32(80, true) !== 1 || last - first > slots) throw new Error("invalid document width batch reply");
      if (w.getUint32(92, true) === 0) { cursor = 0; widest = 0; phase = 3; }
      else {
        let lineWidth = 0;
        for (let i = first; i < last; i++) {
          if (text[i] === 10) { widest = nscvTextRunMax(widest, lineWidth); lineWidth = 0; }
          else lineWidth = nscvTextRunAdd(lineWidth, facts.getFloat32(128 + (i - first) * 4, true));
        }
        if (last > first && text[last - 1] !== 10) widest = nscvTextRunMax(widest, lineWidth);
        cursor = last;
      }
    } else {
      if (w.getUint32(80, true) !== 2) throw new Error("invalid document width scalar reply");
      widest = nscvTextRunMax(widest, w.getFloat32(108, true));
      cursor = last < length ? last + 1 : last;
      if (phase === 3 && last === length) phase = 4;
      if (phase === 2) phase = 1;
    }
  }
  w.setFloat32(104, widest, true); w.setUint32(100, cursor, true);
  if (phase === 4 || phase === 1 && cursor === length) {
    out[3] = 2; w.setUint32(80, 0, true); w.setUint32(84, 0, true); w.setUint32(88, 0, true); w.setUint32(92, 0, true); w.setUint32(96, 0, true); w.setFloat32(108, 0, true); return out;
  }
  let last = length, action = 2;
  if (phase === 1) {
    last = Math.min(length, cursor + 65536);
    if (last < length) {
      let newline = -1;
      for (let i = last - 1; i >= cursor; i--) if (text[i] === 10) { newline = i; break; }
      if (newline >= 0) last = newline + 1;
      else {
        last = cursor;
        while (last < length && text[last] !== 10) last++;
        phase = 2;
      }
    }
    if (phase === 1) action = 1;
  } else {
    last = cursor;
    while (last < length && text[last] !== 10) last++;
  }
  out[3] = 1; w.setUint32(80, action, true); w.setUint32(84, cursor, true); w.setUint32(88, last, true); w.setUint32(92, 0, true); w.setUint32(96, phase, true); w.setFloat32(108, 0, true);
  return out;
}
