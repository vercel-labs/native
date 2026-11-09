/** Markup text/calendar capabilities (103). Byte chunks carry no pointers;
 * exact integer decimal conversion and timestamp division remain native.
 * Results describe either owned bytes or cuts/choices into caller storage.
 * Modes: upper, lower, trim, thousands, pad, date, time, datetime, plural.
 */
function nscvMarkupTextSpace(byte: number): boolean {
  return byte === 32 || byte === 9 || byte === 13 || byte === 10;
}
function nscvMarkupTextDigits(out: Uint8Array, at: number, value: number, width: number): void {
  for (let i = width - 1; i >= 0; i--) {
    out[at + i] = 48 + value % 10;
    value = Math.floor(value / 10);
  }
}
function nscvMarkupText(request: Uint8Array): Uint8Array {
  if (request.length < 32 || request[0] !== 103 || request[1] !== 1 || request[2]! > 8)
    throw new Error("invalid markup text header");
  const mode = request[2]!, width = request[3]!, r = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const length = r.getUint16(4, true);
  if (length > 256 || request.length !== 32 + length || width > (mode === 4 ? 6 : 0) ||
      r.getUint16(6, true) !== 0 || r.getUint32(8, true) !== 0 || r.getUint32(12, true) !== 0 ||
      (mode >= 5 && length !== 0) || r.getUint32(28, true) !== 0)
    throw new Error("invalid markup text storage");
  if (mode < 5 && (r.getUint32(16, true) !== 0 || r.getUint32(20, true) !== 0 || r.getUint32(24, true) !== 0) ||
      mode === 8 && r.getUint32(24, true) !== 0) throw new Error("invalid markup text facts");
  const bytes = request.subarray(32);
  let resultLength = 0, sign = 0, zeros = 0, first = 0, last = length;
  if (mode === 0 || mode === 1) resultLength = length;
  else if (mode === 2) {
    while (first < length && nscvMarkupTextSpace(bytes[first]!)) first++;
    while (last > first && nscvMarkupTextSpace(bytes[last - 1]!)) last--;
  } else if (mode === 3 || mode === 4) {
    if (length === 0 || length > 20) throw new Error("invalid markup decimal length");
    sign = bytes[0] === 45 ? 1 : 0;
    if (length === sign) throw new Error("invalid markup decimal sign");
    for (let i = sign; i < length; i++) if (bytes[i]! < 48 || bytes[i]! > 57)
      throw new Error("invalid markup decimal byte");
    zeros = Math.max(0, width - (length - sign));
    resultLength = length + (mode === 3 ? Math.floor((length - sign - 1) / 3) : 0);
  } else if (mode < 8) {
    const days = r.getFloat64(16, true), seconds = r.getUint32(24, true);
    if (!Number.isSafeInteger(days) || Math.abs(days) > 106751991167301 || seconds >= 86400)
      throw new Error("invalid markup timestamp facts");
    resultLength = days < -719162 || days > 2932896 ? 0 : mode === 5 ? 10 : mode === 6 ? 5 : 16;
  }
  const out = new Uint8Array(16 + resultLength), w = new DataView(out.buffer);
  out[0] = 103; out[1] = 1; out[2] = mode; w.setUint16(8, resultLength, true);
  if (mode === 0 || mode === 1) {
    for (let i = 0; i < length; i++) {
      const b = bytes[i]!;
      out[16 + i] = mode === 0 && b >= 97 && b <= 122 ? b - 32 : mode === 1 && b >= 65 && b <= 90 ? b + 32 : b;
    }
  } else if (mode === 2) {
    w.setUint16(4, first, true); w.setUint16(6, last, true);
  } else if (mode === 3) {
    let at = 16;
    if (sign === 1) out[at++] = 45;
    for (let i = sign; i < length; i++) {
      if (i > sign && (length - i) % 3 === 0) out[at++] = 44;
      out[at++] = bytes[i]!;
    }
  } else if (mode === 4) {
    out[4] = sign; out[5] = zeros; out[6] = length - sign;
    for (let i = 0; i < length; i++) out[16 + i] = bytes[i]!;
  } else if (mode < 8) {
    if (resultLength === 0) { out[3] = 1; return out; }
    // Gregorian eras use exact small integers after the admitted year range.
    const shifted = r.getFloat64(16, true) + 719468, era = Math.floor(shifted / 146097);
    const dayOfEra = shifted - era * 146097;
    const yearOfEra = Math.floor((dayOfEra - Math.floor(dayOfEra / 1460) + Math.floor(dayOfEra / 36524) - Math.floor(dayOfEra / 146096)) / 365);
    const dayOfYear = dayOfEra - (365 * yearOfEra + Math.floor(yearOfEra / 4) - Math.floor(yearOfEra / 100));
    const monthIndex = Math.floor((5 * dayOfYear + 2) / 153), month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9;
    const year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0), day = dayOfYear - Math.floor((153 * monthIndex + 2) / 5) + 1;
    if (mode !== 6) {
      nscvMarkupTextDigits(out, 16, year, 4); out[20] = 45;
      nscvMarkupTextDigits(out, 21, month, 2); out[23] = 45; nscvMarkupTextDigits(out, 24, day, 2);
    }
    if (mode !== 5) {
      const at = mode === 6 ? 16 : 27, seconds = r.getUint32(24, true);
      if (mode === 7) out[26] = 32;
      nscvMarkupTextDigits(out, at, Math.floor(seconds / 3600), 2); out[at + 2] = 58;
      nscvMarkupTextDigits(out, at + 3, Math.floor(seconds % 3600 / 60), 2);
    }
  } else out[4] = r.getUint32(16, true) === 1 && r.getUint32(20, true) === 0 ? 1 : 2;
  return out;
}
