/** Portable chart preparation. Samples cross as IEEE words; selecting indices
 * preserves signed zero and NaN payloads in the host's owned f32 storage.
 * Decimal summaries use exact finite decimal intervals, with ties to even for
 * the shortest f32 representation and the reference's fixed-place rounding.
 */
interface NscChartDecimal { digits: number[]; exponent: number }
interface NscChartSource { kind: number; values: readonly number[]; low: readonly number[]; label: readonly number[] }
interface NscChartPlan { values: number[]; low: number[] }
interface NscChartPrepared { series: NscChartPlan[]; summary: number[]; downsampled: boolean }

function nscChartDigits(value: number): number[] {
  const reverse: number[] = [];
  do { reverse.push(value % 10); value = Math.floor(value / 10); } while (value > 0);
  const out: number[] = [];
  for (let i = reverse.length - 1; i >= 0; i--) out.push(reverse[i]!);
  return out;
}
function nscChartMultiply(digits: readonly number[], factor: number): number[] {
  const reverse: number[] = []; let carry = 0;
  for (let i = digits.length - 1; i >= 0; i--) {
    const next = digits[i]! * factor + carry;
    reverse.push(next % 10); carry = Math.floor(next / 10);
  }
  while (carry > 0) { reverse.push(carry % 10); carry = Math.floor(carry / 10); }
  const out: number[] = [];
  for (let i = reverse.length - 1; i >= 0; i--) out.push(reverse[i]!);
  return out;
}
function nscChartBinaryDecimal(mantissa: number, exponent: number): NscChartDecimal {
  let digits = nscChartDigits(mantissa);
  for (let i = 0; i < Math.abs(exponent); i++) digits = nscChartMultiply(digits, exponent < 0 ? 5 : 2);
  return { digits, exponent: Math.min(0, exponent) };
}
function nscChartCompare(a: NscChartDecimal, b: NscChartDecimal): number {
  const left = a.digits.length + a.exponent, right = b.digits.length + b.exponent;
  if (left !== right) return left < right ? -1 : 1;
  for (let i = 0; i < Math.max(a.digits.length, b.digits.length); i++) {
    const x = i < a.digits.length ? a.digits[i]! : 0, y = i < b.digits.length ? b.digits[i]! : 0;
    if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
}
function nscChartSummaryValue(bits: number): number[] {
  const out: number[] = []; if (bits >= 2147483648) out.push(45);
  const fraction = bits % 8388608, field = Math.floor(bits / 8388608) % 256;
  if (field === 255) {
    for (const byte of fraction === 0 ? [105, 110, 102] : [110, 97, 110]) out.push(byte);
    return out;
  }
  let coefficient = 0, exponent = 0;
  if (field !== 0 || fraction !== 0) {
    const mantissa = field === 0 ? fraction : fraction + 8388608;
    const binaryExponent = field === 0 ? -149 : field - 150;
    const exact = nscChartBinaryDecimal(mantissa, binaryExponent);
    // The predecessor spacing halves only at a normal power of two above
    // the smallest normal. Midpoints are admitted for an even significand.
    const lower = nscChartBinaryDecimal(mantissa * 4 - (fraction === 0 && field > 1 ? 1 : 2), binaryExponent - 2);
    const upper = nscChartBinaryDecimal(mantissa * 4 + 2, binaryExponent - 2);
    const inclusive = mantissa % 2 === 0;
    for (let precision = 1; precision <= 9; precision++) {
      coefficient = 0;
      for (let i = 0; i < precision; i++) coefficient = coefficient * 10 + (i < exact.digits.length ? exact.digits[i]! : 0);
      const next = precision < exact.digits.length ? exact.digits[precision]! : 0;
      let tail = false;
      for (let i = precision + 1; i < exact.digits.length; i++) if (exact.digits[i] !== 0) tail = true;
      if (next > 5 || next === 5 && (tail || coefficient % 2 !== 0)) coefficient++;
      exponent = exact.exponent + exact.digits.length - precision;
      const candidate: NscChartDecimal = { digits: nscChartDigits(coefficient), exponent };
      let lo = nscChartCompare(candidate, lower), hi = nscChartCompare(candidate, upper);
      // Power-of-two intervals are asymmetric. The nearest decimal may
      // miss the narrow side while the adjacent decimal is still shorter.
      if (lo < 0 || lo === 0 && !inclusive) coefficient++;
      else if (hi > 0 || hi === 0 && !inclusive) coefficient--;
      const adjacent: NscChartDecimal = { digits: nscChartDigits(coefficient), exponent };
      lo = nscChartCompare(adjacent, lower); hi = nscChartCompare(adjacent, upper);
      if ((lo > 0 || inclusive && lo === 0) && (hi < 0 || inclusive && hi === 0)) break;
      if (precision === 9) throw new Error("chart shortest decimal was not found");
    }
    while (coefficient % 10 === 0) { coefficient /= 10; exponent++; }
  }
  // Preserve the reference's two-place rounding of the shortest decimal,
  // rather than rounding a scaled binary value or formatting a widened f64.
  const length = nscChartDigits(coefficient).length;
  const keep = exponent > 0 ? length - 1 + 2 + exponent : Math.max(0, 2 + length + exponent);
  if (keep < length) {
    for (let i = keep + 1; i < length; i++) { coefficient = Math.floor(coefficient / 10); exponent++; }
    if (coefficient % 10 >= 5) {
      coefficient = Math.floor(coefficient / 10) + 1; exponent++;
      let power = coefficient;
      while (power > 0 && power % 10 === 0) power /= 10;
      if (power === 1 && coefficient > 1) { coefficient /= 10; exponent++; }
    }
  }
  const digits = nscChartDigits(coefficient), point = digits.length + exponent;
  for (let i = 0; i < Math.max(1, point); i++) out.push(point <= 0 || i >= digits.length ? 48 : 48 + digits[i]!);
  out.push(46);
  for (let i = 0; i < 2; i++) { const at = point + i; out.push(at < 0 || at >= digits.length ? 48 : 48 + digits[at]!); }
  return out;
}
function nscChartIndices(words: readonly number[]): number[] {
  const indices: number[] = [];
  if (words.length <= 256) { for (let i = 0; i < words.length; i++) indices.push(i); return indices; }
  const samples: number[] = [], bytes = new Uint8Array(4), wire = new DataView(bytes.buffer);
  for (const word of words) { wire.setUint32(0, word, true); samples.push(wire.getFloat32(0, true)); }
  for (let bucket = 0; bucket < 128; bucket++) {
    const start = Math.floor(bucket * words.length / 128), end = Math.floor((bucket + 1) * words.length / 128);
    let minIndex = start, maxIndex = start;
    for (let i = start; i < end; i++) {
      const value = samples[i]!, low = samples[minIndex]!, high = samples[maxIndex]!;
      if (value < low || Number.isNaN(low) && !Number.isNaN(value)) minIndex = i;
      if (value > high || Number.isNaN(high) && !Number.isNaN(value)) maxIndex = i;
    }
    indices.push(Math.min(minIndex, maxIndex), Math.max(minIndex, maxIndex));
  }
  return indices;
}
function nscChartPrepare(source: readonly NscChartSource[]): NscChartPrepared {
  const series: NscChartPlan[] = [], summary: number[] = [99, 104, 97, 114, 116, 58]; let downsampled = false;
  for (let i = 0; i < source.length; i++) {
    const entry = source[i]!, values = nscChartIndices(entry.values), low = entry.kind === 2 ? nscChartIndices(entry.low) : [];
    series.push({ values, low }); if (values.length !== entry.values.length) downsampled = true;
    if (i > 0) summary.push(59); summary.push(32);
    const name = entry.label.length > 0 ? entry.label : entry.kind === 0 ? [108, 105, 110, 101] : entry.kind === 1 ? [98, 97, 114] : [98, 97, 110, 100];
    for (const byte of name) summary.push(byte);
    if (entry.values.length === 0) summary.push(32, 101, 109, 112, 116, 121);
    else {
      summary.push(32); for (const digit of nscChartDigits(entry.values.length)) summary.push(48 + digit);
      summary.push(32, 112, 116, 115, 32, 108, 97, 115, 116, 32);
      for (const byte of nscChartSummaryValue(entry.values[entry.values.length - 1]!)) summary.push(byte);
    }
  }
  return { series, summary, downsampled };
}
function nscvChartContentPolicy(request: Uint8Array): Uint8Array {
  if (request.length < 8 || request[0] !== 21 || request[1] !== 0 || request[2] !== 0 || request[3] !== 0) throw new Error("invalid chart preparation header");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength), count = wire.getUint32(4, true);
  if (count > Math.floor((request.length - 8) / 16)) throw new Error("truncated chart series table");
  const source: NscChartSource[] = []; let at = 8;
  for (let i = 0; i < count; i++) {
    if (at + 16 > request.length || request[at]! > 2 || request[at + 1] !== 0 || request[at + 2] !== 0 || request[at + 3] !== 0) throw new Error("invalid chart series header");
    const kind = request[at]!, labels = wire.getUint32(at + 4, true), values = wire.getUint32(at + 8, true), lows = wire.getUint32(at + 12, true); at += 16;
    if (labels > request.length - at || values + lows > Math.floor((request.length - at - labels) / 4)) throw new Error("truncated chart data");
    const label: number[] = [], words: number[] = [], low: number[] = [];
    for (let j = 0; j < labels; j++) label.push(request[at++]!);
    for (let j = 0; j < values; j++) { words.push(wire.getUint32(at, true)); at += 4; }
    for (let j = 0; j < lows; j++) { low.push(wire.getUint32(at, true)); at += 4; }
    source.push({ kind, label, values: words, low });
  }
  if (at !== request.length) throw new Error("trailing chart data");
  const plan = nscChartPrepare(source); let length = 8 + plan.summary.length;
  for (const series of plan.series) length += 8 + 4 * (series.values.length + series.low.length);
  const result = new Uint8Array(length), out = new DataView(result.buffer); result[0] = plan.downsampled ? 1 : 0;
  out.setUint32(4, plan.summary.length, true); at = 8;
  for (const byte of plan.summary) result[at++] = byte;
  for (const series of plan.series) {
    out.setUint32(at, series.values.length, true); out.setUint32(at + 4, series.low.length, true); at += 8;
    for (const index of series.values) { out.setUint32(at, index, true); at += 4; }
    for (const index of series.low) { out.setUint32(at, index, true); at += 4; }
  }
  return result;
}
