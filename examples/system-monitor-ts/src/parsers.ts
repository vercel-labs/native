// system-monitor-ts parsers module: the pure byte parsers over the sampler
// tools' output, plus the integer number tier and the byte/format helpers
// they share — the TS counterpart of the Zig original's fixture-tested
// sampler.zig, one import away from core.ts. Everything here is
// (bytes) -> value | null — no effects, no clock. The e2e suite in the SDK
// repo replays the same committed real command captures through these
// parsers via the app's spawn path.
//
// The number tier splits every quantity into two domains that never meet
// (NS1016): INTEGER values (pids, byte counts, CPU tenths — everything
// parsed, compared, and formatted into template holes) and FLOAT values
// (the sparkline fractions, layout offsets). Integer division is `intDiv`
// below — binary long division, integer end to end — and floats derive
// from integers by parallel accumulation (0.001 per permille step), never
// by conversion, because the tier has none.

import { asciiBytes } from "@native-sdk/core";
import { trimAsciiSpaces } from "@native-sdk/core/text";

export type Bytes = Uint8Array;

/// Top-CPU process rows kept per sample (the exact top-K selection; the
/// total count and CPU sum still cover every parsed row).
export const MAX_ROWS = 128;

// ------------------------------------------------------------ number tier

/// Integer division by binary long division (n >= 0, d > 0): quotient in
/// the integer domain end to end — `/` is float-classed in the tier and no
/// float-to-integer conversion exists, so whole-unit subtraction with
/// doubling steps stands in (~2*log2(n/d) iterations, exact for every
/// integer f64 holds).
export function intDiv(n: number, d: number): number {
  let q = 0;
  let r = n;
  while (r >= d) {
    let step = d;
    let count = 1;
    while (step + step <= r) {
      step += step;
      count += count;
    }
    r -= step;
    q += count;
  }
  return q;
}

/// Rounded integer division: round-half-up, the display rounding the Zig
/// original's `{d:.1}`/`{d:.0}` formats apply (half-way ties may differ in
/// the last digit; ps and the byte sizes never produce them in practice).
export function intDivRound(n: number, d: number): number {
  return intDiv(n + n + d, d + d);
}

/// permille (0..1000, integer) -> fraction (0..1, float) by parallel
/// accumulation — the NS1016 idiom: count down in the integer domain while
/// the float accumulates alongside, one 0.001 step per unit.
export function permilleFraction(permille: number): number {
  let out = 0;
  let rest = permille;
  while (rest >= 1) {
    rest -= 1;
    out += 0.001;
  }
  return out;
}

// ------------------------------------------------------------ bytes helpers

export function concat2(a: Bytes, b: Bytes): Bytes {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

export function concat3(a: Bytes, b: Bytes, c: Bytes): Bytes {
  const out = new Uint8Array(a.length + b.length + c.length);
  out.set(a, 0);
  out.set(b, a.length);
  out.set(c, a.length + b.length);
  return out;
}

/// a + " · " + b — the middle dot is UTF-8 (0xC2 0xB7), outside asciiBytes'
/// alphabet, so the separator bytes are written directly.
export function dotJoin(a: Bytes, b: Bytes): Bytes {
  const out = new Uint8Array(a.length + 4 + b.length);
  out.set(a, 0);
  out[a.length] = 0x20;
  out[a.length + 1] = 0xc2;
  out[a.length + 2] = 0xb7;
  out[a.length + 3] = 0x20;
  out.set(b, a.length + 4);
  return out;
}

/// a + " — " + b (the em dash the Zig original's strings carry).
export function emDashJoin(a: Bytes, b: Bytes): Bytes {
  const out = new Uint8Array(a.length + 5 + b.length);
  out.set(a, 0);
  out[a.length] = 0x20;
  out[a.length + 1] = 0xe2;
  out[a.length + 2] = 0x80;
  out[a.length + 3] = 0x94;
  out[a.length + 4] = 0x20;
  out.set(b, a.length + 5);
  return out;
}

/// text + "…" (U+2026, three UTF-8 bytes).
export function withEllipsis(text: Bytes): Bytes {
  const out = new Uint8Array(text.length + 3);
  out.set(text, 0);
  out[text.length] = 0xe2;
  out[text.length + 1] = 0x80;
  out[text.length + 2] = 0xa6;
  return out;
}

export function containsBytes(haystack: Bytes, needle: Bytes): boolean {
  if (needle.length === 0) return true;
  if (needle.length > haystack.length) return false;
  for (let start = 0; start + needle.length <= haystack.length; start++) {
    let hit = true;
    for (let i = 0; i < needle.length; i++) {
      if (haystack[start + i] !== needle[i]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

function bytesStartWith(text: Bytes, prefix: Bytes): boolean {
  if (prefix.length > text.length) return false;
  for (let i = 0; i < prefix.length; i++) {
    if (text[i] !== prefix[i]) return false;
  }
  return true;
}

/// Two-digit zero-padded integer ("07", "23").
export function pad2(value: number): Bytes {
  return value < 10 ? asciiBytes(`0${value}`) : asciiBytes(`${value}`);
}

/// Human-readable bytes: whole KB/MB below a GB, one decimal GB above —
/// the Zig original's formatBytes, in integer math.
export function formatBytes(bytes: number): Bytes {
  if (bytes >= 1073741824) {
    const tenthsGb = intDivRound(bytes * 10, 1073741824);
    const whole = intDiv(tenthsGb, 10);
    const tenth = tenthsGb - whole * 10;
    return asciiBytes(`${whole}.${tenth} GB`);
  }
  if (bytes >= 1048576) {
    return asciiBytes(`${intDivRound(bytes, 1048576)} MB`);
  }
  return asciiBytes(`${intDivRound(bytes, 1024)} KB`);
}

/// Day-clock ms -> `HH:MM:SS` (UTC; the point is "how fresh").
export function formatClock(dayMs: number): Bytes {
  const daySeconds = intDiv(dayMs, 1000);
  const hours = intDiv(daySeconds, 3600);
  const minutes = intDiv(daySeconds - hours * 3600, 60);
  const secs = daySeconds - hours * 3600 - minutes * 60;
  return concat3(concat2(pad2(hours), asciiBytes(":")), pad2(minutes), concat2(asciiBytes(":"), pad2(secs)));
}

// ------------------------------------------------------- number parsing

function isDigit(b: number): boolean {
  return b >= 0x30 && b <= 0x39;
}

function parseUnsigned(text: Bytes): number | null {
  if (text.length === 0) return null;
  let value = 0;
  for (const b of text) {
    if (!isDigit(b)) return null;
    value = value * 10 + (b - 0x30);
  }
  return value;
}

/// "12.3" -> 123 tenths (integer; rounds on the second decimal when a
/// tool prints more — ps prints exactly one). The integer-domain stand-in
/// for the Zig original's f32 parse: ps values carry one decimal, so
/// tenths are lossless.
function parseTenths(text: Bytes): number | null {
  let dot = -1;
  for (let i = 0; i < text.length; i++) {
    if (text[i] === 0x2e) {
      dot = i;
      break;
    }
  }
  if (dot === -1) {
    const whole = parseUnsigned(text);
    if (whole === null) return null;
    return whole * 10;
  }
  const whole = parseUnsigned(text.subarray(0, dot));
  if (whole === null) return null;
  const frac = text.subarray(dot + 1);
  if (frac.length === 0) return null;
  for (const b of frac) {
    if (!isDigit(b)) return null;
  }
  let out = whole * 10 + (frac[0] - 0x30);
  if (frac.length > 1 && frac[1] >= 0x35) out += 1;
  return out;
}

/// `ps` elapsed time: `MM:SS`, `HH:MM:SS`, or `D-HH:MM:SS` (days can be
/// multi-digit). Returns seconds.
function parseEtime(text: Bytes): number | null {
  let days = 0;
  let clock = text;
  let dash = -1;
  for (let i = 0; i < text.length; i++) {
    if (text[i] === 0x2d) {
      dash = i;
      break;
    }
  }
  if (dash >= 0) {
    const parsed = parseUnsigned(text.subarray(0, dash));
    if (parsed === null) return null;
    days = parsed;
    clock = text.subarray(dash + 1);
  }
  let parts0 = 0;
  let parts1 = 0;
  let parts2 = 0;
  let count = 0;
  let start = 0;
  for (let i = 0; i <= clock.length; i++) {
    if (i === clock.length || clock[i] === 0x3a) {
      if (count >= 3) return null;
      const part = parseUnsigned(clock.subarray(start, i));
      if (part === null) return null;
      if (count === 0) parts0 = part;
      else if (count === 1) parts1 = part;
      else parts2 = part;
      count += 1;
      start = i + 1;
    }
  }
  if (count === 2) return days * 86400 + parts0 * 60 + parts1;
  if (count === 3) return days * 86400 + parts0 * 3600 + parts1 * 60 + parts2;
  return null;
}

/// The basename of a command path; a name with no slash is itself.
function basename(path: Bytes): Bytes {
  let slash = -1;
  for (let i = 0; i < path.length; i++) {
    if (path[i] === 0x2f) slash = i;
  }
  if (slash >= 0 && slash + 1 < path.length) return path.subarray(slash + 1);
  return path;
}

// ------------------------------------------------------------ ps parsing

export interface ParsedProcess {
  readonly pid: number;
  /// %cpu in tenths (integer): ps prints one decimal, so tenths are the
  /// lossless integer form of the Zig original's f32.
  readonly cpuTenths: number;
  /// %mem in tenths — parsed for row validation, mirrored for parity with
  /// the Zig model's unused `mem` field.
  readonly memTenths: number;
  /// Resident set size in KiB.
  readonly rssKb: number;
  readonly name: Bytes;
}

export interface PsSample {
  readonly processCount: number;
  /// The count again, float-classed for the sparkline window (parallel
  /// accumulation — the count and the float never meet in one expression).
  readonly processCountFloat: number;
  /// Sum of every row's %cpu in tenths.
  readonly cpuSumTenths: number;
  /// Uptime read from pid 1's etime (launchd/init started at boot).
  readonly uptimeSeconds: number;
  /// Malformed lines skipped (loud, never silent).
  readonly skippedLines: number;
  /// The exact top-MAX_ROWS rows by CPU: a stable descending sort over
  /// every parsed row, cut to the cap — same selection as the Zig
  /// original's in-place min-replacement, expressed immutably.
  readonly rows: readonly ParsedProcess[];
}

interface ParsedPsLine {
  readonly process: ParsedProcess;
  readonly etimeSeconds: number;
}

/// One ps row: five numeric columns, then `comm` as the untokenized rest
/// of the line (command paths may contain spaces — "Software Update.app").
function parsePsLine(line: Bytes): ParsedPsLine | null {
  let cursor = 0;
  let pid = 0;
  let cpuTenths = 0;
  let memTenths = 0;
  let rssKb = 0;
  let etimeSeconds = 0;
  for (let column = 0; column < 5; column++) {
    while (cursor < line.length && (line[cursor] === 0x20 || line[cursor] === 0x09)) cursor += 1;
    let end = cursor;
    while (end < line.length && line[end] !== 0x20 && line[end] !== 0x09) end += 1;
    if (end === cursor) return null;
    const token = line.subarray(cursor, end);
    if (column === 0) {
      const parsed = parseUnsigned(token);
      if (parsed === null) return null;
      pid = parsed;
    } else if (column === 1) {
      const parsed = parseTenths(token);
      if (parsed === null) return null;
      cpuTenths = parsed;
    } else if (column === 2) {
      const parsed = parseTenths(token);
      if (parsed === null) return null;
      memTenths = parsed;
    } else if (column === 3) {
      const parsed = parseUnsigned(token);
      if (parsed === null) return null;
      rssKb = parsed;
    } else {
      const parsed = parseEtime(token);
      if (parsed === null) return null;
      etimeSeconds = parsed;
    }
    cursor = end;
  }
  const command = trimAsciiSpaces(line.subarray(cursor));
  if (command.length === 0) return null;
  return {
    process: { pid: pid, cpuTenths: cpuTenths, memTenths: memTenths, rssKb: rssKb, name: basename(command) },
    etimeSeconds: etimeSeconds,
  };
}

/// Parse whole `ps axo pid=,pcpu=,pmem=,rss=,etime=,comm=` output.
export function parsePs(bytes: Bytes): PsSample {
  const all: ParsedProcess[] = [];
  let processCount = 0;
  let processCountFloat = 0;
  let cpuSumTenths = 0;
  let uptimeSeconds = 0;
  let skippedLines = 0;
  let start = 0;
  while (start <= bytes.length) {
    let end = start;
    while (end < bytes.length && bytes[end] !== 0x0a) end += 1;
    const line = trimAsciiSpaces(bytes.subarray(start, end));
    if (line.length > 0) {
      const row = parsePsLine(line);
      if (row === null) {
        skippedLines += 1;
      } else {
        processCount += 1;
        processCountFloat += 1;
        cpuSumTenths += row.process.cpuTenths;
        if (row.process.pid === 1) uptimeSeconds = row.etimeSeconds;
        all.push(row.process);
      }
    }
    if (end >= bytes.length) break;
    start = end + 1;
  }
  // The exact top-K: a STABLE descending sort keeps the earliest of equal
  // CPUs first (the Zig min-replacement keeps first-encountered on ties),
  // then the cut.
  const top = all.toSorted((a, b) => b.cpuTenths - a.cpuTenths).slice(0, MAX_ROWS);
  return {
    processCount: processCount,
    processCountFloat: processCountFloat,
    cpuSumTenths: cpuSumTenths,
    uptimeSeconds: uptimeSeconds,
    skippedLines: skippedLines,
    rows: top,
  };
}

// -------------------------------------------------------- memory parsing

export interface MemSample {
  /// Bytes in use. vm_stat counts active + wired + compressor-occupied
  /// pages; /proc/meminfo counts MemTotal - MemAvailable.
  readonly usedBytes: number;
  /// Total physical memory when the sample itself carries it (meminfo
  /// does; vm_stat does not — macOS totals come from the boot probe).
  readonly totalBytes: number;
}

/// The trailing integer of a `Pages active:   794612.` line.
function trailingCount(line: Bytes): number | null {
  let end = line.length;
  while (end > 0 && (line[end - 1] === 0x2e || line[end - 1] === 0x20 || line[end - 1] === 0x09 || line[end - 1] === 0x0d)) end -= 1;
  let start = end;
  while (start > 0 && isDigit(line[start - 1])) start -= 1;
  if (start === end) return null;
  return parseUnsigned(line.subarray(start, end));
}

/// macOS `vm_stat`: page counts at a page size declared on the banner
/// line. Used = active + wired down + occupied by compressor.
export function parseVmStat(bytes: Bytes): MemSample | null {
  let pageSize = 0;
  let active = -1;
  let wired = -1;
  let compressor = -1;
  let start = 0;
  while (start <= bytes.length) {
    let end = start;
    while (end < bytes.length && bytes[end] !== 0x0a) end += 1;
    const line = bytes.subarray(start, end);
    if (containsBytes(line, asciiBytes("page size of "))) {
      // The digits after the marker, up to the following space.
      let at = 0;
      const marker = asciiBytes("page size of ");
      for (let i = 0; i + marker.length <= line.length; i++) {
        if (bytesStartWith(line.subarray(i), marker)) {
          at = i + marker.length;
          break;
        }
      }
      let digitsEnd = at;
      while (digitsEnd < line.length && isDigit(line[digitsEnd])) digitsEnd += 1;
      const parsed = parseUnsigned(line.subarray(at, digitsEnd));
      if (parsed !== null) pageSize = parsed;
    } else if (bytesStartWith(line, asciiBytes("Pages active:"))) {
      const parsed = trailingCount(line);
      if (parsed !== null) active = parsed;
    } else if (bytesStartWith(line, asciiBytes("Pages wired down:"))) {
      const parsed = trailingCount(line);
      if (parsed !== null) wired = parsed;
    } else if (bytesStartWith(line, asciiBytes("Pages occupied by compressor:"))) {
      const parsed = trailingCount(line);
      if (parsed !== null) compressor = parsed;
    }
    if (end >= bytes.length) break;
    start = end + 1;
  }
  if (pageSize === 0 || active < 0 || wired < 0 || compressor < 0) return null;
  return { usedBytes: (active + wired + compressor) * pageSize, totalBytes: 0 };
}

/// Linux `/proc/meminfo`: `MemTotal:` and `MemAvailable:` in kB.
function meminfoField(bytes: Bytes, key: Bytes): number | null {
  let start = 0;
  while (start <= bytes.length) {
    let end = start;
    while (end < bytes.length && bytes[end] !== 0x0a) end += 1;
    const line = bytes.subarray(start, end);
    if (bytesStartWith(line, key)) {
      const rest = line.subarray(key.length);
      let at = 0;
      while (at < rest.length && !isDigit(rest[at])) at += 1;
      let digitsEnd = at;
      while (digitsEnd < rest.length && isDigit(rest[digitsEnd])) digitsEnd += 1;
      if (digitsEnd === at) return null;
      return parseUnsigned(rest.subarray(at, digitsEnd));
    }
    if (end >= bytes.length) break;
    start = end + 1;
  }
  return null;
}

export function parseMeminfo(bytes: Bytes): MemSample | null {
  const totalKb = meminfoField(bytes, asciiBytes("MemTotal:"));
  if (totalKb === null) return null;
  const availableKb = meminfoField(bytes, asciiBytes("MemAvailable:"));
  if (availableKb === null) return null;
  if (availableKb > totalKb) return null;
  return { usedBytes: (totalKb - availableKb) * 1024, totalBytes: totalKb * 1024 };
}

// ------------------------------------------------------- host-info parsing

export interface HostInfo {
  readonly cores: number;
  /// Total physical memory; 0 when the probe's tool does not carry it
  /// (nproc — Linux totals ride every meminfo sample instead).
  readonly memoryBytes: number;
}

/// sysctl probe: two lines (`hw.ncpu`, `hw.memsize`). nproc: one line.
export function parseHostInfo(bytes: Bytes, expectMemory: boolean): HostInfo | null {
  let cores = -1;
  let memoryBytes = 0;
  let start = 0;
  let lineIndex = 0;
  while (start <= bytes.length) {
    let end = start;
    while (end < bytes.length && bytes[end] !== 0x0a) end += 1;
    const line = trimAsciiSpaces(bytes.subarray(start, end));
    if (line.length > 0) {
      if (lineIndex === 0) {
        const parsed = parseUnsigned(line);
        if (parsed === null) return null;
        cores = parsed;
      } else if (lineIndex === 1 && expectMemory) {
        const parsed = parseUnsigned(line);
        if (parsed === null) return null;
        memoryBytes = parsed;
      }
      lineIndex += 1;
    }
    if (end >= bytes.length) break;
    start = end + 1;
  }
  if (cores <= 0) return null;
  if (expectMemory && memoryBytes === 0) return null;
  return { cores: cores, memoryBytes: memoryBytes };
}
