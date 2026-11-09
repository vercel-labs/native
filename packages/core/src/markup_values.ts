/** Runtime value, typed-message and binding programs (113). Native capabilities
 * expose reflected types and exact numeric/storage facts; no pointer or i64 is
 * transported through the numeric program fields. All names remain raw bytes.
 */
function nscmDot(path: Uint8Array): number {
  for (let i = 0; i < path.length; i++) if (path[i] === 46) return i;
  return -1;
}
function nscmIcon(r: NscElementReader, out: number[]): void {
  const raw = r.blob(), names = r.names(), classification: number[] = [];
  // Icons deliberately use raw expression grammar, even with a typed cache.
  nsccAttribute(classification, 0, new Uint8Array(0), raw);
  const kind = classification[1]!;
  if (kind === 2) { nsceEmit(out, 73); return; }
  if (kind !== 1) { nsceFail(out, 42); return; }
  if (raw.length >= 4 && nsceNamed(raw.subarray(0, 4), "app:")) {
    let dash = true;
    for (let i = 4; i < raw.length; i++) {
      const byte = raw[i]!;
      if (byte >= 97 && byte <= 122 || byte >= 48 && byte <= 57) dash = false;
      else if (byte === 45 && !dash) dash = true;
      else { nsceFail(out, 43); return; }
    }
    if (dash) nsceFail(out, 43);
    else nsceEmit(out, 72, 1);
    return;
  }
  for (const byte of raw) if (byte === 58) { nsceFail(out, 44); return; }
  if (nsceIn(raw, names)) nsceEmit(out, 72);
  else nsceFail(out, 42);
}
function nscmTrim(bytes: Uint8Array, start: number, end: number, newlines: boolean): number[] {
  while (start < end && (bytes[start] === 32 || bytes[start] === 9 || newlines && (bytes[start] === 13 || bytes[start] === 10))) start++;
  while (end > start && (bytes[end - 1] === 32 || bytes[end - 1] === 9 || newlines && (bytes[end - 1] === 13 || bytes[end - 1] === 10))) end--;
  return [start, end];
}
function nscmLanguage(r: NscElementReader, out: number[]): void {
  const raw = r.blob(), names = r.names(), span = nscmTrim(raw, 0, raw.length, true), folded = raw.slice(span[0]!, span[1]!);
  for (let i = 0; i < folded.length; i++) if (folded[i]! >= 65 && folded[i]! <= 90) folded[i] = folded[i]! + 32;
  const groups = ["plain text", "zig", "js mjs javascript", "ts typescript", "json jsonc", "yaml yml", "sh bash zsh shell", "py python", "rs rust", "c h cc cpp c++ cs csharp java kotlin swift", "go golang", "html xml svg", "css scss less", "sql", "jsx", "tsx", "md markdown"];
  const canonical = ["plain", "zig", "javascript", "typescript", "json", "yaml", "shell", "python", "rust", "c_like", "go", "html", "css", "sql", "jsx", "tsx", "markdown"];
  for (let i = 0; i < groups.length; i++) for (const alias of groups[i]!.split(" ")) if (nsceNamed(folded, alias)) {
    for (let j = 0; j < names.length; j++) if (nsceNamed(names[j]!, canonical[i]!)) { nsceEmit(out, 76, 0, j); return; }
    throw new Error("missing native code language capability");
  }
  nsceFail(out, 45);
}
function nscmLinePieces(r: NscElementReader, out: number[]): void {
  const spec = r.blob(), span = nscmTrim(spec, 0, spec.length, true), end = span[1]!;
  let start = span[0]!;
  if (start === end) { nsceEmit(out, 200); return; }
  while (start <= end) {
    let stop = start; while (stop < end && spec[stop] !== 44) stop++;
    const piece = nscmTrim(spec, start, stop, true), first = piece[0]!, last = piece[1]!;
    if (first === last) { nsceFail(out, 46); return; }
    let dash = -1;
    for (let i = first; i < last; i++) if (spec[i] === 45) {
      if (dash >= 0) { nsceFail(out, 46); return; }
      dash = i;
    }
    const a = nscmTrim(spec, first, dash < 0 ? last : dash, false);
    const b = dash < 0 ? a : nscmTrim(spec, dash + 1, last, false);
    if (a[0] === a[1] || b[0] === b[1]) { nsceFail(out, 46); return; }
    // Exact usize conversion runs natively, in order, before the next piece.
    out.push(77, 0, a[0]!, a[1]!, b[0]!, b[1]!, 0);
    if (stop === end) break;
    start = stop + 1;
  }
  nsceEmit(out, 200);
}
function nscmLineRange(r: NscElementReader, out: number[]): void {
  const firstValid = r.flag(), firstWithin = r.flag(), first = r.word();
  const lastValid = r.flag(), lastWithin = r.flag(), last = r.word(), capacity = r.word(), count = r.word(), lines: number[] = [];
  if (count > capacity) throw new Error("invalid native line storage");
  for (let i = 0; i < count; i++) { const line = r.word(); if (line === 0 || line > capacity) throw new Error("invalid stored line"); lines.push(line); }
  if (!firstValid || !lastValid || !firstWithin || !lastWithin || first === 0 || last < first || last > capacity) { nsceFail(out, 46); return; }
  for (let line = first; line <= last; line++) {
    let duplicate = false; for (const stored of lines) if (stored === line) duplicate = true;
    if (duplicate) continue;
    if (lines.length === capacity) { nsceFail(out, 46); return; }
    nsceEmit(out, 78, 0, lines.length, line); lines.push(line);
  }
}
function nscmValues(r: NscElementReader, out: number[], mode: number): void {
  if (mode === 0) {
    const channel = r.word(), name = r.blob(), binding = r.flag();
    if (channel > 2) throw new Error("invalid resource channel");
    const element = channel === 0 ? nsceOne(name, ["avatar", "image"]) : nsceNamed(name, channel === 1 ? "media-surface" : "terminal");
    if (!element) nsceFail(out, channel * 2 + 1);
    else if (!binding) nsceFail(out, channel * 2 + 2);
    else nsceEmit(out, 1);
  } else if (mode === 1) {
    const channel = r.word(), kind = r.word(), nonnegative = r.flag();
    if (channel > 2 || kind > 3) throw new Error("invalid resource value");
    if (kind === 0 && nonnegative) nsceEmit(out, 2);
    else if (channel === 2 && kind === 3) nsceEmit(out, 3);
    else nsceFail(out, channel * 2 + 2);
  } else if (mode === 2) {
    const family = r.word(), name = r.blob(), eligible = r.names();
    if (family > 2) throw new Error("invalid element family");
    if (nsceIn(name, eligible)) nsceEmit(out, 1);
    else nsceFail(out, family === 0 ? 7 : family === 1 ? 8 : 9);
  } else if (mode === 3) {
    const kind = r.word(), phase = r.word(), anchor = r.flag(), valid = r.flag();
    if (kind > 2 || phase > 1) throw new Error("invalid anchor phase");
    if (phase === 0 && kind !== 0 && !anchor) nsceFail(out, 10);
    else if (phase === 1 && !valid) nsceFail(out, 11 + kind);
    else nsceEmit(out, 1);
  } else if (mode === 4 || mode === 5) {
    const type = r.word(), kind = r.word(), withinRange = r.flag();
    if (type > 5 || kind > 3) throw new Error("invalid typed value fact");
    const admitted = type === 1 ? kind === 0 || kind === 1 : type === 2 ? true : type === 3 || type === 5 ? kind === 3 : type === 4 ? kind === 0 && withinRange : false;
    if (admitted) nsceEmit(out, type);
    else if (mode === 5) nsceFail(out, 27);
    else nsceFail(out, type === 1 ? 20 : type === 3 ? 21 : type === 4 ? kind === 0 ? 23 : 24 : type === 5 ? 26 : 25);
  } else if (mode === 6) {
    const drag = r.flag(), tag = r.blob(), payload = r.flag(), names = r.names(), classes: number[] = [];
    for (let i = 0; i < names.length; i++) { const kind = r.word(); if (kind > 2) throw new Error("invalid message type"); classes.push(kind); }
    if (drag && !payload) { nsceFail(out, 31); return; }
    for (let i = 0; i < names.length; i++) if (nsceEqual(tag, names[i]!)) {
      const kind = classes[i]!;
      if (drag) { if (kind !== 2) nsceFail(out, 31); else nsceEmit(out, 42, 0, i); }
      else if (kind === 0) { if (payload) nsceFail(out, 28); else nsceEmit(out, 40, 0, i); }
      else if (!payload) nsceFail(out, 29);
      else nsceEmit(out, 41, 0, i);
      return;
    }
    nsceFail(out, drag ? 31 : 30);
  } else if (mode === 7) {
    const tag = r.blob(), names = r.names(), classes: number[] = [];
    for (let i = 0; i < names.length; i++) { const kind = r.word(); if (kind > 2) throw new Error("invalid callback class"); classes.push(kind); }
    for (let i = 0; i < names.length; i++) if (classes[i] !== 0 && nsceEqual(tag, names[i]!)) { nsceEmit(out, 43, 0, i, classes[i]!); return; }
    nsceEmit(out, 0);
  } else if (mode === 8) {
    const kind = r.word(), aware = r.flag();
    if (kind > 5) throw new Error("invalid attribute kind");
    if (kind === 0) nsceEmit(out, aware ? 50 : 51);
    else if (kind === 1) nsceEmit(out, 52);
    else if (kind === 2) { nsceEmit(out, 53); nsceEmit(out, 54); nsceEmit(out, 55); }
    else if (kind === 3) nsceEmit(out, 56);
    else nsceFail(out, 32);
  } else if (mode === 9) {
    nsceEmit(out, r.flag() ? 57 : 58);
  } else if (mode === 10) {
    const count = r.word();
    for (let i = 0; i < count; i++) {
      const binding = r.flag(), comparison = r.flag();
      if (binding) nsceEmit(out, 59, 0, i, comparison ? 0 : 1);
    }
    nsceEmit(out, 60);
  } else if (mode === 11) {
    const path = r.blob(), floor = r.word(), names = r.names(), classes: number[] = [];
    if (floor > names.length) throw new Error("invalid binding floor");
    for (let i = 0; i < names.length; i++) { const kind = r.word(); if (kind > 4) throw new Error("invalid scope payload"); classes.push(kind); }
    const dot = nscmDot(path), head = path.subarray(0, dot < 0 ? path.length : dot), tail = dot + 1;
    for (let i = names.length - 1; i >= floor; i--) if (nsceEqual(head, names[i]!)) {
      const kind = classes[i]!;
      if (kind === 0) nsceEmit(out, dot < 0 ? 62 : 61, 0, i, tail);
      else if (kind === 1) nsceFail(out, 36);
      else if (kind === 2) { if (dot >= 0) nsceFail(out, 37); else nsceEmit(out, 63, 0, i); }
      else if (kind === 3) { if (dot < 0) nsceFail(out, 41); else nsceEmit(out, 64, 0, i, tail); }
      else throw new Error("named slot capture is unreachable");
      return;
    }
    nsceEmit(out, 65, 0, head.length);
  } else if (mode === 12) {
    const domain = r.word(), phase = r.word(), present = r.flag(), allowArena = r.flag();
    if (domain > 3 || phase > 2) throw new Error("invalid binding resolution phase");
    if (phase === 2) { nsceFail(out, present ? 38 : 39); return; }
    if (phase === 1 && present) { nsceFail(out, 33); return; }
    if (present) { nsceEmit(out, 66); return; }
    if (phase === 0 && domain < 2 && !allowArena) nsceEmit(out, 67);
    else if (domain === 1) nsceEmit(out, 75);
    else nsceFail(out, domain === 0 ? 34 : domain === 2 ? 40 : 35);
  } else if (mode === 13) {
    const type = r.word(), path = r.blob(), arena = r.flag(), fields = r.names(), declarations = r.names(), classes: number[] = [];
    if (type > 2) throw new Error("invalid reflected binding type");
    for (let i = 0; i < declarations.length; i++) { const kind = r.word(); if (kind > 2) throw new Error("invalid declaration class"); classes.push(kind); }
    if (type === 2) { nsceEmit(out, 70); return; }
    if (type === 0) { nsceEmit(out, 0); return; }
    const dot = nscmDot(path), head = path.subarray(0, dot < 0 ? path.length : dot);
    for (let i = 0; i < fields.length; i++) if (nsceEqual(head, fields[i]!)) { nsceEmit(out, 68, 0, i, dot + 1); return; }
    if (dot < 0) for (let i = 0; i < declarations.length; i++) if (classes[i] !== 0 && nsceEqual(head, declarations[i]!)) {
      if (classes[i] === 2 && !arena) nsceEmit(out, 0);
      else nsceEmit(out, 69, 0, i, classes[i]!);
      return;
    }
    nsceEmit(out, 0);
  } else if (mode === 14) {
    nscmIcon(r, out);
  } else if (mode === 15) {
    const text = r.blob(), names = r.names();
    for (let i = 0; i < names.length; i++) if (nsceEqual(text, names[i]!)) { nsceEmit(out, 74, 0, i); return; }
    nsceEmit(out, 0);
  } else if (mode === 16) nscmLanguage(r, out);
  else if (mode === 17) nscmLinePieces(r, out);
  else if (mode === 18) nscmLineRange(r, out);
  else if (mode === 19) {
    const raw = r.blob(), names = r.names();
    const area = nsceNamed(raw, "area");
    const canonical = area || nsceNamed(raw, "line") ? "line" : nsceNamed(raw, "bar") ? "bar" : "";
    if (canonical === "") { nsceFail(out, 47); return; }
    for (let i = 0; i < names.length; i++) if (nsceNamed(names[i]!, canonical)) { nsceEmit(out, 79, area ? 1 : 0, i); return; }
    throw new Error("missing native chart kind capability");
  } else if (mode === 20) {
    // Native conversion precedes admission; these are the exact IEEE f32 bits.
    const bits = r.word();
    if (bits > 0xffffffff) throw new Error("invalid native f32 representation");
    if (bits > 0 && bits < 0x7f800000) nsceEmit(out, 1);
    else nsceFail(out, 48);
  } else if (mode === 21) {
    const channel = r.word(), kind = r.word(), low = r.word(), high = r.word(), capacity = r.word();
    if (channel > 2 || kind > 3 || low > 0xffffffff || high > 0xffffffff || capacity > 255) throw new Error("invalid numeric option channel");
    if (kind !== 0) { nsceFail(out, channel === 0 ? 50 : channel === 1 ? 52 : 53); return; }
    // Exact two's-complement i64 words never pass through a floating conversion.
    if (channel === 0) {
      if (high <= 0x1fffff) nsceEmit(out, 1);
      else nsceFail(out, 49);
    } else if (channel === 1) nsceEmit(out, high >= 0x80000000 ? 2 : 1);
    else if (high === 0 && low <= capacity) nsceEmit(out, 1);
    else nsceFail(out, 54);
  } else if (mode === 22) {
    const bits = r.word();
    if (bits > 0xffffffff) throw new Error("invalid native f32 representation");
    if (bits < 0x7f800000 || bits === 0x80000000) nsceEmit(out, 1);
    else nsceFail(out, 51);
  } else if (mode === 23) {
    const raw = r.blob(), names = r.names(), selected = nsceNamed(raw, "trailing") ? "trailing" : "leading";
    for (let i = 0; i < names.length; i++) if (nsceNamed(names[i]!, selected)) { nsceEmit(out, 80, 0, i); return; }
    throw new Error("missing native virtual anchor capability");
  } else if (mode === 24) {
    const base = r.word(), count = r.word();
    if (base <= 9007199254740991 - count) nsceEmit(out, 0);
    else nsceFail(out, 55);
  } else if (mode === 25) {
    const bits = r.word(), estimator = r.flag();
    if (bits > 0xffffffff) throw new Error("invalid native f32 representation");
    if (estimator || bits !== 0 && bits !== 0x80000000) nsceEmit(out, 0);
    else nsceFail(out, 56);
  } else if (mode === 26) {
    const channel = r.word(), name = r.blob(), present = r.flag();
    if (channel > 1 || !nsceOne(name, channel === 0 ? ["item-count", "overscan", "index-base"] : ["item-extent", "gap", "viewport-fallback"])) throw new Error("invalid virtual option name");
    if (present) nsceEmit(out, 1);
    else nsceEmit(out, 0, 0, nsceNamed(name, "overscan") ? 4 : 0);
  }
  else if (mode === 27) {
    const channel = r.word(), form = r.word(), payloadLength = r.word();
    if (channel > 13 || form > 5) throw new Error("invalid specialized attribute form");
    const diagnostics = [57, 58, 59, 60, 61, 62, 63, 45, 64, 65, 47, 66, 67, 46];
    const admitted = channel === 1 || channel === 2 ? form === 4 && payloadLength === 0
      : channel === 5 ? form !== 2 && form !== 5
      : channel === 7 || channel === 10 || channel === 12 ? form === 0
      : channel === 8 ? form === 4
      : channel === 13 ? form !== 5
      : form === 1;
    if (!admitted) nsceFail(out, diagnostics[channel]!);
    else nsceEmit(out, channel === 13 && form !== 0 ? 2 : 1);
  } else if (mode === 28) {
    const channel = r.word(), kind = r.word(), length = r.word();
    if (channel > 4 || kind > 3) throw new Error("invalid specialized value kind");
    const diagnostics = [57, 63, 62, 46, 48];
    if (channel === 4) {
      if (kind < 2) nsceEmit(out, kind === 0 ? 2 : 1);
      else nsceFail(out, 48);
    } else if (kind !== 3) nsceFail(out, diagnostics[channel]!);
    else nsceEmit(out, channel === 2 && length === 0 ? 0 : 1);
  } else if (mode === 29) {
    // Raw empty presence wins even when a typed cache says otherwise.
    nsceEmit(out, r.word() === 0 ? 1 : 2);
  } else if (mode === 30) {
    const phase = r.word();
    if (phase === 0) {
      const count = r.word(), firstKind = r.blob();
      nsceEmit(out, count === 1 && nsceNamed(firstKind, "slot_block") ? 2 : 1);
    } else if (phase === 1) {
      if (r.flag()) nsceEmit(out, 1);
      else nsceFail(out, 68);
    } else throw new Error("invalid stepper capture phase");
  } else if (mode === 31) {
    const phase = r.word();
    if (phase === 0) {
      const raw = r.blob(), aware = r.flag(), name = r.blob(), textNames = r.names();
      // Schema text takes precedence even over exact boolean and numeric text.
      // Conversion is requested in order; exact native values stay native.
      if (aware && nsceIn(name, textNames)) nsceEmit(out, 81);
      else if (nsceNamed(raw, "true")) nsceEmit(out, 82, 1);
      else if (nsceNamed(raw, "false")) nsceEmit(out, 82);
      else nsceEmit(out, 83);
    } else if (phase === 1) nsceEmit(out, r.flag() ? 84 : 85);
    else if (phase === 2) nsceEmit(out, r.flag() ? 86 : 81);
    else throw new Error("invalid literal inference phase");
  } else if (mode === 32) {
    const length = r.word(), floor = r.word();
    if (floor > length) throw new Error("invalid capture floor");
    let selected = 0;
    for (let i = 0; i < length; i++) {
      const slot = r.flag();
      // An empty capture still shadows every outer capture.
      if (i >= floor && slot) selected = i + 1;
    }
    nsceEmit(out, 87, 0, selected);
  } else if (mode === 33) {
    const press = r.flag(), provenance = r.flag();
    // Root construction can fail before either postprocessing capability runs.
    nsceEmit(out, 88);
    if (press) nsceEmit(out, 89);
    if (provenance) nsceEmit(out, 90);
    nsceEmit(out, 91);
  } else if (mode === 34) {
    const count = r.word();
    for (let i = 0; i < count; i++) {
      // Toggle buttons retain their distinct on-toggle contract.
      if (nsceNamed(r.blob(), "button")) nsceEmit(out, 92, 0, i);
    }
  } else if (mode === 35) {
    const path = r.blob(), dot = nscmDot(path);
    // Return borrowed byte offsets; a trailing dot has a present empty tail.
    nsceEmit(out, 93, 0, dot < 0 ? path.length : dot, dot < 0 ? 0 : dot + 1);
  } else if (mode === 36) {
    // A use-site handler replaces the local timeline handler before construction.
    nsceEmit(out, r.flag() ? 1 : 0);
  } else throw new Error("invalid markup value mode");
}
function nscvMarkupValues(input: Uint8Array): Uint8Array {
  if (input.length < 4 || input[0] !== 113 || input[1] !== 1 || input[2]! > 36 || input[3]! > 1) throw new Error("invalid markup value header");
  const r = new NscElementReader(input), out: number[] = [];
  nscmValues(r, out, input[2]!);
  if (r.at !== input.length) throw new Error("trailing markup value facts");
  const count = out.length / 7, bytes = new Uint8Array(input[3] === 0 ? 16 : 16 + count * 48), wire = new DataView(bytes.buffer);
  bytes[0] = 113; bytes[1] = 1; bytes[2] = input[3]!; wire.setFloat64(8, count, true);
  if (input[3] === 1) for (let i = 0; i < count; i++) {
    const at = 16 + i * 48, from = i * 7; bytes[at] = out[from]!; bytes[at + 1] = out[from + 1]!;
    for (let j = 0; j < 5; j++) wire.setFloat64(at + 8 + j * 8, out[from + j + 2]!, true);
  }
  return bytes;
}
