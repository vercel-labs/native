/** Portable component composition compiled with scriptc beside the app model.
 * These functions emit only primitive view records. Native owns measurement,
 * rendering, hit testing, and delivery of the declared message envelopes.
 */
import { textWordSelectionAtOffset as nscvWordSelection, textLineSelectionAtOffset as nscvLineSelection, caretSelectionAt as nscvSelection, applyTextInputEvent as nscvApplyTextEdit, sanitizedSingleLineTextInputEvent as nscvSanitizeTextInput, type TextInputEvent as NscvTextInputEvent } from "@native-sdk/core/text";

type NscViewNode = {
  end: number; kind: string; text: string; placeholder?: string; wrap?: boolean; submitOnEnter?: boolean;
  key?: string; keyInt?: number; keySlot?: number; globalKey?: string; globalKeyInt?: number;
  gap?: number; padding?: number; grow?: number; width?: number; height?: number; minWidth?: number;
  resizeDuration?: number; resizeEasing?: string; resizeOrigin?: number;
  value?: number; valueX?: number; axis?: string; overscroll?: string;
  image?: number; icon?: string; label?: string; role?: string;
  background?: string; foreground?: string; radius?: string; windowDrag?: boolean;
  main?: string; cross?: string; size?: string; variant?: string; checked?: boolean;
  disabled?: boolean; selected?: boolean; focusable?: boolean;
  expanded?: boolean; treeLevel?: number;
  listItemIndex?: number; listItemCount?: number;
  spanWeight?: string; spanColor?: string; spanScale?: number;
  press?: number[]; toggle?: number[]; change?: number[]; drag?: number[]; scroll?: number;
  input?: number; valueChange?: number; resize?: number; submit?: number[]; dismiss?: number[];
  anchor?: string; anchorAlignment?: string; anchorOffset?: number;
};

function nscvPush(nodes: NscViewNode[], node: NscViewNode): void {
  if (nodes.length >= 1024) throw new Error("compiled view exceeds 1024 nodes");
  nodes.push(node);
  node.end = nodes.length;
}

/** Text keyboard intent. Eight bytes: operation (0 newline, 1 edit, 2 submit),
 * multiline, phase (0 down, 1 up, 2 text), modifier bits (shift/control/alt/super),
 * macOS, submit-on-enter, normalized key, text-present. The two-byte result is
 * intent plus extend-selection: 0 none, 1 borrowed text, 2 newline, 3/4 deletion,
 * 5/6 previous/next, 7/8 start/end, 9/10 previous/next word, 11/12 word deletion,
 * 13 line-start deletion, 14 select-all, 15 submit, 16 document-start deletion.
 * Keys are 0 unknown, 1 Enter, 2 Return, 3 Backspace, 4 Delete, 5/6 Left/Right,
 * 7 Home, 8 End, 9 A. Native retains insert bytes and geometry.
 */
export function native_text_policy(request: Uint8Array): Uint8Array {
  if (request[0] === 3) return nscvTextPointerSelection(request);
  if (request[0] === 4) return nscvTextEdit(request);
  if (request[0] === 5) return nscvTextReconcile(request);
  if (request[0] === 6) return nscvTextInput(request);
  if (request[0] === 7) return nscvTextHistoryReplay(request);
  if (request.length !== 8 || request[0]! > 2 || request[1]! > 1 || request[2]! > 2 ||
      request[3]! > 15 || request[4]! > 1 || request[5]! > 1 || request[6]! > 9 || request[7]! > 1)
    throw new Error("invalid text policy request");
  const operation = request[0]!, multiline = request[1] === 1, phase = request[2]!, key = request[6]!;
  const shift = (request[3]! & 1) !== 0, control = (request[3]! & 2) !== 0;
  const alt = (request[3]! & 4) !== 0, meta = (request[3]! & 8) !== 0;
  const command = control || meta, navigation = command || alt;
  let intent = 0;
  if (operation === 0) {
    if (multiline && phase === 0 && request[7] === 0 && !navigation &&
        (key === 1 || key === 2) && !(request[5] === 1 && !shift)) intent = 2;
  } else if (operation === 2) {
    if (phase === 0 && key === 1) {
      if (multiline ? (command && !alt && !shift || request[5] === 1 && !navigation && !shift) : !navigation)
        intent = 15;
    }
  } else if (phase === 2) {
    if (request[7] === 1 && !command) intent = 1;
  } else if (phase === 0) {
    if (command && !alt && !shift && key === 9) intent = 14;
    else if (meta && !alt && (key === 5 || key === 6)) intent = key === 5 ? 7 : 8;
    else if (!meta && alt !== control && (key === 5 || key === 6)) intent = key === 5 ? 9 : 10;
    else if (!shift && (!meta || request[4] === 0 && control) && alt !== control && (key === 3 || key === 4))
      intent = key === 3 ? 11 : 12;
    else if (request[4] === 1 && meta && !control && !alt && key === 3) intent = multiline ? 13 : 16;
    else if (!navigation) {
      if (key === 3) intent = 3;
      else if (key === 4) intent = 4;
      else if (key === 5) intent = 5;
      else if (key === 6) intent = 6;
      else if (key === 7) intent = 7;
      else if (key === 8) intent = 8;
    }
  }
  const result = new Uint8Array(2);
  result[0] = intent; result[1] = shift ? 1 : 0;
  return result;
}

/** Tagged pointer request: 3, multiline, click count (2/3), mode
 * (0 fresh click/1 drag/2 Shift extension), then offset and anchor run's
 * start/end as LE u32, followed by borrowed UTF-8 text. Result is four LE
 * u32 values: oriented selection anchor/focus and retained anchor run.
 */
function nscvTextPointerSelection(request: Uint8Array): Uint8Array {
  if (request.length < 16 || request.length > 16 + 512 * 1024 || request[1]! > 1 ||
      request[2]! < 2 || request[2]! > 3 || request[3]! > 2) throw new Error("invalid text pointer policy request");
  const data = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const text = request.subarray(16), offset = data.getUint32(4, true);
  const unit = (at: number): { readonly anchor: number; readonly focus: number } => {
    if (request[2] === 2) return nscvWordSelection(text, at);
    if (request[1] === 1) return nscvLineSelection(text, at);
    return nscvSelection(0, text.length);
  };
  const selected = unit(offset);
  let start = Math.min(selected.anchor, selected.focus), end = Math.max(selected.anchor, selected.focus);
  if (request[3] === 1) {
    const a = Math.min(data.getUint32(8, true), text.length), b = Math.min(data.getUint32(12, true), text.length);
    start = Math.min(a, b); end = Math.max(a, b);
  } else if (request[3] === 2) {
    const anchor = unit(data.getUint32(8, true));
    start = Math.min(anchor.anchor, anchor.focus); end = Math.max(anchor.anchor, anchor.focus);
  }
  let anchor = start, focus = end;
  if (selected.anchor < start) { anchor = end; focus = selected.anchor; }
  else if (selected.focus > end) { anchor = start; focus = selected.focus; }
  const result = new Uint8Array(16), out = new DataView(result.buffer);
  out.setUint32(0, anchor, true); out.setUint32(4, focus, true);
  out.setUint32(8, start, true); out.setUint32(12, end, true);
  return result;
}

/** Tagged reducer request: 4, event (the SDK text event order), caret direction,
 * extend, composition-present, cursor-present, two reserved zero bytes;
 * then LE u32 text length, anchor/focus, composition start/end, event arguments,
 * and capacity. UTF-8 source and insert/preedit bytes follow the 40-byte header.
 * Result: LE u32 flags (1 accepted, 2 retain original text), anchor/focus,
 * composition-present/start/end, then edited bytes. Four zero bytes refuse
 * an over-capacity edit. Native keeps storage, history and painted affinity.
 */
function nscvTextEdit(request: Uint8Array): Uint8Array {
  const budget = 512 * 1024;
  if (request.length < 40 || request.length > 40 + 2 * budget || request[1]! > 12 ||
      request[2]! > 5 || request[3]! > 1 || request[4]! > 1 || request[5]! > 1 ||
      request[6] !== 0 || request[7] !== 0) throw new Error("invalid text reducer request");
  const data = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const length = data.getUint32(8, true), capacity = data.getUint32(36, true);
  if (length > budget || request.length < 40 + length || request.length - 40 - length > budget || capacity > budget)
    throw new Error("invalid text reducer budget");
  const text = request.subarray(40, 40 + length), inserted = request.subarray(40 + length);
  const selection = nscvSelection(data.getUint32(12, true), data.getUint32(16, true));
  const composition = nscvSelection(data.getUint32(20, true), data.getUint32(24, true));
  const args = nscvSelection(data.getUint32(28, true), data.getUint32(32, true));
  let edit: NscvTextInputEvent;
  switch (request[1]) {
    case 0: edit = { kind: "insert_text", text: inserted }; break;
    case 1: edit = { kind: "delete_backward" }; break;
    case 2: edit = { kind: "delete_forward" }; break;
    case 3: edit = { kind: "delete_word_backward" }; break;
    case 4: edit = { kind: "delete_word_forward" }; break;
    case 5: edit = { kind: "delete_to_start" }; break;
    case 6: edit = { kind: "delete_to_line_start" }; break;
    case 7: edit = { kind: "clear" }; break;
    case 8: edit = { kind: "move_caret", move: {
      direction: request[2] === 0 ? "previous" : request[2] === 1 ? "next" :
        request[2] === 2 ? "previous_word" : request[2] === 3 ? "next_word" : request[2] === 4 ? "start" : "end",
      extend: request[3] === 1 } }; break;
    case 9: edit = { kind: "set_selection", selection: args }; break;
    case 10: edit = { kind: "set_composition", text: inserted, cursor: request[5] === 1 ? args.anchor : null }; break;
    case 11: edit = { kind: "commit_composition" }; break;
    default: edit = { kind: "cancel_composition" }; break;
  }
  const next = nscvApplyTextEdit({ text, selection,
    composition: request[4] === 1 ? { start: composition.anchor, end: composition.focus } : null }, edit, capacity);
  if (next === null) return new Uint8Array(4);
  const retained = next.text === text;
  const result = new Uint8Array(24 + (retained ? 0 : next.text.length)), out = new DataView(result.buffer);
  out.setUint32(0, retained ? 3 : 1, true);
  out.setUint32(4, next.selection.anchor, true); out.setUint32(8, next.selection.focus, true);
  out.setUint32(12, next.composition !== null ? 1 : 0, true);
  out.setUint32(16, next.composition !== null ? next.composition.start : 0, true);
  out.setUint32(20, next.composition !== null ? next.composition.end : 0, true);
  if (!retained) result.set(next.text, 24);
  return result;
}

/** Rebuild policy: tag 5, source-unchanged, source-matches-retained, reserved;
 * source flags (selection/composition/downstream), retained selection flags
 * (present/downstream), previous source selection flags, reserved. Four LE
 * u64 offsets follow: source anchor/focus, retained anchor/focus. Compare
 * their u32 halves exactly, including offsets beyond JS's safe integers.
 * Result bits retain text, retain native scroll/cache state, retain selection
 * and composition, and retain affinity. Native owns bytes and caret geometry.
 */
function nscvTextReconcile(request: Uint8Array): Uint8Array {
  if (request.length !== 40 || request[1]! > 1 || request[2]! > 1 || request[3] !== 0 ||
      request[4]! > 7 || request[5]! > 3 || request[6]! > 3 || request[7] !== 0)
    throw new Error("invalid text reconcile request");
  const result = new Uint8Array(1);
  if (request[1] === 0 && request[2] === 0) return result;
  let flags = 2 | (request[1] === 1 ? 1 : 0);
  const sourceSelection = (request[4]! & 1) !== 0;
  if (!sourceSelection && (request[4]! & 2) === 0) flags |= 4;
  else if (sourceSelection && (request[5]! & 1) !== 0) {
    const data = new DataView(request.buffer, request.byteOffset, request.byteLength);
    const echoed = data.getUint32(8, true) === data.getUint32(24, true) &&
      data.getUint32(12, true) === data.getUint32(28, true) &&
      data.getUint32(16, true) === data.getUint32(32, true) &&
      data.getUint32(20, true) === data.getUint32(36, true);
    const downstream = (request[4]! & 4) !== 0;
    const affinityChanged = (request[6]! & 1) !== 0 ? downstream !== ((request[6]! & 2) !== 0) : downstream;
    if (echoed && !affinityChanged) flags |= 8;
  }
  result[0] = flags;
  return result;
}

/** New input: tag 6, mode (0 insert/1 composition/2 paste), single-line,
 * cursor-present, LE u32 cursor/available paste bytes/reserved zero, then
 * input bytes. Sanitize before applying the paste limit. The result's LE
 * u32 flags (1 present/2 borrowed prefix/4 cursor-present/8 truncated),
 * cursor and length precede copied bytes. Native copies before arena reset.
 */
function nscvTextInput(request: Uint8Array): Uint8Array {
  const budget = 512 * 1024;
  if (request.length < 16 || request.length > 16 + budget || request[1]! > 2 ||
      request[2]! > 1 || request[3]! > 1) throw new Error("invalid text input request");
  const data = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const mode = request[1]!, available = data.getUint32(8, true);
  if (available > budget || data.getUint32(12, true) !== 0 ||
      mode !== 1 && (request[3] !== 0 || data.getUint32(4, true) !== 0))
    throw new Error("invalid text input arguments");
  const source = request.subarray(16);
  const rawCursor = data.getUint32(4, true);
  const cursorOffset = rawCursor >= 0 && rawCursor <= 4294967295 ? Math.trunc(rawCursor) : 0;
  const event: NscvTextInputEvent = mode === 1 ?
    { kind: "set_composition", text: source, cursor: request[3] === 1 ? cursorOffset : null } :
    { kind: "insert_text", text: source };
  const sanitized = request[2] === 1 ? nscvSanitizeTextInput(event) : event;
  if (sanitized === null) return new Uint8Array(12);
  if (sanitized.kind !== "insert_text" && sanitized.kind !== "set_composition")
    throw new Error("invalid prepared text event");
  let text = sanitized.text;
  const borrowed = text === source;
  const truncated = mode === 2 && text.length > available;
  if (truncated) {
    let end = available;
    while (end > 0 && end < text.length && (text[end]! & 0xc0) === 0x80) end -= 1;
    text = text.subarray(0, end);
  }
  const cursor = sanitized.kind === "set_composition" ? sanitized.cursor : null;
  const result = new Uint8Array(12 + (borrowed ? 0 : text.length)), out = new DataView(result.buffer);
  out.setUint32(0, 1 | (borrowed ? 2 : 0) | (cursor !== null ? 4 : 0) | (truncated ? 8 : 0), true);
  out.setUint32(4, cursor === null ? 0 : cursor, true); out.setUint32(8, text.length, true);
  if (!borrowed) result.set(text, 12);
  return result;
}

/** History replay: tag 7, mode (0 start/1 continue/2 commit), redo,
 * before/after byte-match bits and current/before/after affinity bits.
 * Three exact LE u64 anchor/focus pairs follow at byte 8. LE u32 prefix,
 * removed length and inserted length at byte 56 precede retained payloads.
 * The 24-byte result carries action (none/clear/complete/insert/backward/
 * forward/selection), affinity and exact u64 selection. Native retains
 * history bytes and applies one step before re-reading the entry by serial.
 */
function nscvTextHistoryReplay(request: Uint8Array): Uint8Array {
  const budget = 512 * 1024;
  if (request.length < 68 || request[1]! > 2 || request[2]! > 1 || request[3]! > 3 ||
      request[4]! > 7 || request[5] !== 0 || request[6] !== 0 || request[7] !== 0)
    throw new Error("invalid text history request");
  const data = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const prefix = data.getUint32(56, true), removed = data.getUint32(60, true), inserted = data.getUint32(64, true);
  if (removed + inserted > budget || prefix + removed > budget || prefix + inserted > budget ||
      request.length !== 68 + removed + inserted) throw new Error("invalid text history budget");
  const redo = request[2] === 1, mode = request[1]!, desired = redo ? 40 : 24;
  const currentAffinity = request[4]! & 1, desiredAffinity = (request[4]! >> (redo ? 2 : 1)) & 1;
  const equal = (a: number, b: number): boolean => data.getUint32(a, true) === data.getUint32(b, true) &&
    data.getUint32(a + 4, true) === data.getUint32(b + 4, true) &&
    data.getUint32(a + 8, true) === data.getUint32(b + 8, true) &&
    data.getUint32(a + 12, true) === data.getUint32(b + 12, true);
  const at = (a: number, anchor: number, focus: number): boolean => data.getUint32(a, true) === anchor &&
    data.getUint32(a + 4, true) === 0 && data.getUint32(a + 8, true) === focus && data.getUint32(a + 12, true) === 0;
  const single = (start: number, length: number): boolean => {
    if (length === 0) return false;
    let offset = length - 1;
    while (offset > 0 && (request[start + offset]! & 0xc0) === 0x80) offset -= 1;
    return offset === 0;
  };
  const targetMatches = (request[3]! & (redo ? 2 : 1)) !== 0;
  const sourceMatches = (request[3]! & (redo ? 1 : 2)) !== 0;
  const selectionMatches = currentAffinity === desiredAffinity && equal(8, desired);
  const result = new Uint8Array(24), out = new DataView(result.buffer);
  if (mode === 2) { result[0] = targetMatches && selectionMatches ? 2 : 0; return result; }
  if (mode === 1 && targetMatches) {
    if (selectionMatches) result[0] = 2;
    else { result[0] = 6; result[1] = desiredAffinity; result.set(request.subarray(desired, desired + 16), 8); }
    return result;
  }
  if (!sourceMatches) { result[0] = 1; return result; }
  const oldLength = redo ? removed : inserted, newLength = redo ? inserted : removed;
  if (!redo && removed === 0 && single(68 + removed, inserted) && at(8, prefix + inserted, prefix + inserted) &&
      desiredAffinity === 0 && at(desired, prefix, prefix)) result[0] = 4;
  else if ((!redo && inserted === 0 || redo && removed === 0) && at(8, prefix, prefix) &&
      desiredAffinity === 0 && at(desired, prefix + newLength, prefix + newLength)) result[0] = 3;
  else if (redo && inserted === 0 && single(68, removed) && desiredAffinity === 0 && at(desired, prefix, prefix) &&
      at(8, prefix + removed, prefix + removed)) result[0] = 4;
  else if (redo && inserted === 0 && single(68, removed) && desiredAffinity === 0 && at(desired, prefix, prefix) &&
      at(8, prefix, prefix)) result[0] = 5;
  else if (currentAffinity !== 0 || !at(8, prefix, prefix + oldLength)) {
    result[0] = 6; out.setUint32(8, prefix, true); out.setUint32(16, prefix + oldLength, true);
  } else result[0] = 3;
  return result;
}

function nscvInteger(value: number): number {
  if (!Number.isSafeInteger(value)) throw new Error("compiled view key is not an exact integer");
  return value;
}

function nscvVariant(value: string): string {
  if (value === "default" || value === "primary" || value === "secondary" || value === "ghost" ||
      value === "destructive" || value === "outline") return value;
  throw new Error("unknown component variant");
}

function nscvLoopKeys(nodes: NscViewNode[], first: number, base: string | number): void {
  let slot = 0;
  for (let i = first; i < nodes.length; i = nodes[i]!.end) {
    const node = nodes[i]!;
    if (node.key === undefined && node.keyInt === undefined && node.globalKey === undefined && node.globalKeyInt === undefined) {
      if (typeof base === "number") node.keyInt = base;
      else node.key = base;
      node.keySlot = slot;
    }
    slot++;
  }
}

function nscvStepper(nodes: NscViewNode[], root: NscViewNode, active: number, labels: string[]): void {
  if (!Number.isSafeInteger(active)) throw new Error("stepper active is not an exact integer");
  active = Math.max(0, active);
  root.kind = "row"; root.gap = 8; root.cross = "center"; root.role = "list";
  nscvPush(nodes, root);
  for (let index = 0; index < labels.length; index++) {
    const state = index < active ? "completed" : index === active ? "active" : "pending";
    const item: NscViewNode = { end: 0, kind: "row", text: "", keyInt: index,
      gap: 6, cross: "center", selected: state === "active", role: "listitem",
      label: labels[index]! + " (" + state + ")", listItemIndex: index, listItemCount: labels.length };
    nscvPush(nodes, item);
    nscvPush(nodes, { end: 0, kind: "badge", text: state === "completed" ? "" : String(index + 1),
      icon: state === "completed" ? "check" : "", variant: state === "pending" ? "outline" : "primary" });
    const title: NscViewNode = { end: 0, kind: "text", text: labels[index]! };
    if (state === "active") title.spanWeight = "bold";
    if (state === "pending") title.foreground = "text_muted";
    nscvPush(nodes, title);
    item.end = nodes.length;
    if (index + 1 < labels.length) nscvPush(nodes, { end: 0, kind: "separator", text: "", grow: 1 });
  }
  root.end = nodes.length;
}

type NscTimelineItem = {
  root: NscViewNode; title: string; description: string; meta: string;
  indicator: string; icon: string; variant: string; connector: boolean;
};

function nscvTimelineItem(nodes: NscViewNode[], options: NscTimelineItem): void {
  const root = options.root;
  root.kind = "stack"; root.role = "listitem"; root.label = options.title;
  root.focusable = root.press !== undefined;
  nscvPush(nodes, root);
  const row: NscViewNode = { end: 0, kind: "row", text: "", gap: 10, padding: 8 };
  nscvPush(nodes, row);
  const lead: NscViewNode = { end: 0, kind: "column", text: "", cross: "center" };
  if (options.connector) lead.gap = 4;
  nscvPush(nodes, lead);
  const dot = options.indicator.length === 0 && options.icon.length === 0;
  nscvPush(nodes, { end: 0, kind: "badge", text: options.indicator, icon: options.icon,
    variant: options.variant, width: dot ? 10 : 0, height: dot ? 10 : 0 });
  if (options.connector) nscvPush(nodes, { end: 0, kind: "separator", text: "", grow: 1, width: 1 });
  lead.end = nodes.length;
  const content: NscViewNode = { end: 0, kind: "column", text: "", grow: 1, gap: 2 };
  nscvPush(nodes, content);
  nscvPush(nodes, { end: 0, kind: "text", text: options.title, spanWeight: "bold" });
  if (options.description.length > 0) nscvPush(nodes, { end: 0, kind: "text", text: options.description,
    wrap: true, foreground: "text_muted" });
  if (options.meta.length > 0) nscvPush(nodes, { end: 0, kind: "text", text: options.meta,
    spanColor: "text_muted", spanScale: 0.9 });
  content.end = nodes.length;
  if (root.press !== undefined) nscvPush(nodes, { end: 0, kind: "text", text: "›", foreground: "text_muted" });
  row.end = nodes.length;
  root.end = nodes.length;
}

/** Retained radio policy wire v1: operation, subject u16, count u16,
 * followed by parent u16, kind (0 other/1 radio/2 group), flags
 * (1 logical focus/2 visible focus/4 selected). Index 65535 means absent.
 * Operations: 0 scope, 1 logical entry, 2 visible stop, 3 visible entry,
 * 4 previous, 5 next, 6 first, 7 last, 8 selection clear mask.
 * Target responses are u16 indices; selection responds with one byte per node.
 * Native supplies geometry eligibility; this pure function chooses scopes,
 * selection clearing, and authored-order roving focus without reading Model.
 */
export function native_radio_policy(request: Uint8Array): Uint8Array {
  const read = (at: number): number => request[at]! + request[at + 1]! * 256;
  if (request.length < 5) throw new Error("invalid radio policy request");
  const operation = request[0]!, subject = read(1), count = read(3);
  if (count > 1024 || subject >= count || request.length !== 5 + count * 4 || operation > 8) throw new Error("invalid radio policy request");
  const kind = (i: number): number => request[7 + i * 4]!;
  const flags = (i: number): number => request[8 + i * 4]!;
  const parent = (i: number): number => read(5 + i * 4);
  const scope = (i: number): number => {
    let ancestor = parent(i);
    for (let depth = 0; ancestor !== 65535 && depth < count; depth++) {
      if (ancestor >= i) throw new Error("invalid radio policy parent");
      if (kind(ancestor) === 2) return ancestor;
      ancestor = parent(ancestor);
    }
    return 65535;
  };
  const group = kind(subject) === 2 ? subject : scope(subject);
  if (operation === 8) {
    const result = new Uint8Array(count);
    for (let i = 0; i < count; i++) {
      if (i !== subject && kind(i) === 1 && (flags(i) & 4) !== 0 && scope(i) === group &&
          (group !== 65535 || parent(i) === parent(subject))) result[i] = 1;
    }
    return result;
  }
  let target = 65535;
  if (operation === 0) target = scope(subject);
  else if (group !== 65535) {
    const eligible: number[] = [];
    for (let i = 0; i < count; i++) {
      const mask = operation === 2 || operation === 3 ? 2 : 1;
      if (kind(i) === 1 && scope(i) === group && (flags(i) & mask) !== 0) eligible.push(i);
    }
    if (eligible.length > 0) {
      target = eligible[0]!;
      if (operation === 1 || operation === 3) {
        for (const i of eligible) if ((flags(i) & 4) !== 0) { target = i; break; }
      } else if (operation === 7) target = eligible[eligible.length - 1]!;
      else if (operation === 4 || operation === 5) {
        target = subject;
        if (operation === 4) {
          target = eligible[eligible.length - 1]!;
          for (const i of eligible) if (i < subject) target = i;
        } else {
          target = eligible[0]!;
          for (const i of eligible) if (i > subject) { target = i; break; }
        }
      }
    } else if (operation === 4 || operation === 5) target = subject;
  }
  const result = new Uint8Array(2);
  result[0] = target % 256; result[1] = Math.floor(target / 256);
  return result;
}

/** Tabs wire: operation u8 (0 scope, 4 previous, 5 next, 6 first,
 * 7 last, 8 selection clear mask), subject/count u16LE, then
 * parent u16LE, kind (0 other/1 segment/2 tabs), flags (2 visible,
 * 4 selected). Segments share their direct parent; arrows do not wrap.
 * Native owns visibility, applied selection, and focus presentation.
 */
export function native_tabs_policy(request: Uint8Array): Uint8Array {
  const read = (at: number): number => request[at]! + request[at + 1]! * 256;
  if (request.length < 5) throw new Error("invalid tabs policy request");
  const operation = request[0]!, subject = read(1), count = read(3);
  if (count > 1024 || subject >= count || request.length !== 5 + count * 4 ||
      ![0, 4, 5, 6, 7, 8].includes(operation)) throw new Error("invalid tabs policy request");
  const parent = (i: number): number => read(5 + i * 4);
  const kind = (i: number): number => request[7 + i * 4]!;
  const flags = (i: number): number => request[8 + i * 4]!;
  const group = parent(subject);
  if (operation === 8) {
    const result = new Uint8Array(count);
    for (let i = 0; i < count; i++) if (i !== subject && kind(i) === 1 &&
      parent(i) === group && (flags(i) & 4) !== 0) result[i] = 1;
    return result;
  }
  let target = 65535;
  if (operation === 0) target = group < count && kind(group) === 2 ? group : 65535;
  else {
    for (let i = 0; i < count; i++) {
      if (kind(i) !== 1 || parent(i) !== group || (flags(i) & 2) === 0) continue;
      if (operation === 6) { target = i; break; }
      if (operation === 7 || operation === 4 && i < subject) target = i;
      if (operation === 5 && i > subject) { target = i; break; }
    }
    if (target === 65535 && (operation === 4 || operation === 5)) target = subject;
  }
  const result = new Uint8Array(2);
  result[0] = target % 256; result[1] = Math.floor(target / 256);
  return result;
}

/** Lower direct button triggers after structural if/for expansion, matching
 * native markup. Nested buttons and toggle-button contracts stay distinct.
 */
function nscvTabs(nodes: NscViewNode[], first: number): void {
  for (let i = first + 1; i < nodes[first]!.end; i = nodes[i]!.end) {
    if (nodes[i]!.kind === "button") nodes[i]!.kind = "segmented_control";
  }
}

function nscvTreeLevel(value: number): number {
  if (!Number.isSafeInteger(value) || value < 0 || value > 65535) throw new Error("tree-level requires an integer from 0 to 65535");
  return value;
}

/** A split's two panes are counted after structural expansion. The native
 * consumer synthesizes the divider without changing authored pane keys.
 */
function nscvSplit(nodes: NscViewNode[], first: number): void {
  const root = nodes[first]!;
  if ((root.resizeEasing !== undefined || root.resizeOrigin !== undefined) && (root.resizeDuration ?? 0) === 0) throw new Error("split resize options require nonzero resize-duration");
  let count = 0;
  for (let i = first + 1; i < nodes[first]!.end; i = nodes[i]!.end) count++;
  if (count !== 2) throw new Error("split requires exactly two panes");
}

function nscvResizeDuration(value: number): number {
  if (!Number.isInteger(value) || value < 0 || value > 4294967295) throw new Error("resize-duration requires a nonnegative u32 integer");
  return value;
}

/** Retained list wire: operation u8, subject/count u16LE, then parent
 * u16LE, kind (0 other/1 list item/2 list), flags (1 logical focus,
 * 2 visible focus/4 selected). Arrows (4 previous/5 next) traverse direct
 * list children logically, allowing native scroll reveal. Home/End (6/7)
 * retain visible same-parent targets; 8 clears selected same-parent items,
 * including bare items. Arrows do not wrap or activate the landed row.
 */
export function native_list_policy(request: Uint8Array): Uint8Array {
  const read = (at: number): number => request[at]! + request[at + 1]! * 256;
  if (request.length < 5) throw new Error("invalid list policy request");
  const operation = request[0]!, subject = read(1), count = read(3);
  if (count > 1024 || subject >= count || request.length !== 5 + count * 4 ||
      ![4, 5, 6, 7, 8].includes(operation)) throw new Error("invalid list policy request");
  const parent = (i: number): number => read(5 + i * 4);
  const kind = (i: number): number => request[7 + i * 4]!;
  const flags = (i: number): number => request[8 + i * 4]!;
  const group = parent(subject);
  if (operation === 8) {
    const result = new Uint8Array(count);
    for (let i = 0; i < count; i++) if (i !== subject && kind(i) === 1 &&
      parent(i) === group && (flags(i) & 4) !== 0) result[i] = 1;
    return result;
  }
  let target = 65535;
  if (operation === 6 || operation === 7) {
    for (let i = 0; i < count; i++) {
      if (kind(i) !== 1 || parent(i) !== group || (flags(i) & 2) === 0) continue;
      target = i;
      if (operation === 6) break;
    }
  } else if (group < count && kind(group) === 2) {
    target = subject;
    let previous = 65535, sawSubject = false;
    for (let i = 0; i < count; i++) {
      if (kind(i) !== 1 || parent(i) !== group || (flags(i) & 1) === 0) continue;
      if (sawSubject) { target = i; break; }
      if (i === subject) {
        if (operation === 4) { if (previous !== 65535) target = previous; break; }
        sawSubject = true;
      } else previous = i;
    }
  }
  const result = new Uint8Array(2);
  result[0] = target % 256; result[1] = Math.floor(target / 256);
  return result;
}

/** Retained menu wire: operation u8, subject/count u16LE, then parent
 * u16LE, kind (0 other/1 menu item/2 menu surface/3 list item), flags
 * (2 visible focus/4 selected state or value/8 selected state).
 * Entry (2 first/3 last)
 * prefers a selected visible descendant, including list items. Arrows
 * (4 previous/5 next) traverse visible direct menu children without wrapping;
 * 6/7 preserve visible same-parent Home/End. Selection (8) returns a
 * committed-choice byte followed by a sibling clear mask: action menus
 * without a selected row never acquire a checkmark on activation.
 */
export function native_menu_policy(request: Uint8Array): Uint8Array {
  const read = (at: number): number => request[at]! + request[at + 1]! * 256;
  if (request.length < 5) throw new Error("invalid menu policy request");
  const operation = request[0]!, subject = read(1), count = read(3);
  if (count > 1024 || subject >= count || request.length !== 5 + count * 4 ||
      ![2, 3, 4, 5, 6, 7, 8].includes(operation)) throw new Error("invalid menu policy request");
  const parent = (i: number): number => read(5 + i * 4);
  const kind = (i: number): number => request[7 + i * 4]!;
  const flags = (i: number): number => request[8 + i * 4]!;
  const group = parent(subject);
  if (operation === 8) {
    const result = new Uint8Array(count + 1);
    for (let i = 0; i < count; i++) if (kind(i) === 1 && parent(i) === group && (flags(i) & 4) !== 0) {
      result[0] = 1;
      if (i !== subject) result[i + 1] = 1;
    }
    return result;
  }
  let target = 65535;
  if (operation === 2 || operation === 3) {
    for (let i = 0; i < count; i++) {
      if ((kind(i) !== 1 && kind(i) !== 3) || (flags(i) & 2) === 0) continue;
      let ancestor = parent(i), inside = false;
      for (let steps = 0; steps < count && ancestor < count; steps++) {
        if (ancestor === subject) { inside = true; break; }
        ancestor = parent(ancestor);
      }
      if (!inside) continue;
      if ((flags(i) & 8) !== 0) { target = i; break; }
      if (operation === 3 || target === 65535) target = i;
    }
  } else if (operation === 6 || operation === 7) {
    for (let i = 0; i < count; i++) {
      if (kind(i) !== 1 || parent(i) !== group || (flags(i) & 2) === 0) continue;
      target = i;
      if (operation === 6) break;
    }
  } else if (group < count && kind(group) === 2) {
    target = subject;
    let previous = 65535, sawSubject = false;
    for (let i = 0; i < count; i++) {
      if (kind(i) !== 1 || parent(i) !== group || (flags(i) & 2) === 0) continue;
      if (sawSubject) { target = i; break; }
      if (i === subject) {
        if (operation === 4) { if (previous !== 65535) target = previous; break; }
        sawSubject = true;
      } else previous = i;
    }
  }
  const result = new Uint8Array(2);
  result[0] = target % 256; result[1] = Math.floor(target / 256);
  return result;
}

/** Toggle state requests: operation 8 (activate), 9 (chip reconcile), or
 * 10 (checkbox/switch/toggle reconcile), then
 * flags (1 current/source selected, 2 previous source selected, 4 retained
 * selected). A source asserted now or previously wins; otherwise retain
 * the uncontrolled chip state. Checkboxes, switches, and plain toggles
 * always preserve retained state on rebuild. Results are one selected byte.
 * Focus requests: operation 4/5 (Left/Right), 6/7 (Home/End), subject/count
 * u16LE, then parent u16LE, kind (0 other/1 toggle/2 toggle group/3 button
 * group), flags (2 visible focus). Arrows stay on visible direct children
 * without wrapping; Home/End preserve native same-parent edges.
 */
export function native_toggle_policy(request: Uint8Array): Uint8Array {
  if (request.length === 0) throw new Error("invalid toggle policy request");
  const operation = request[0]!;
  if (operation === 8 || operation === 9 || operation === 10) {
    if (request.length !== 2 || request[1]! > 7) throw new Error("invalid toggle state request");
    const flags = request[1]!, source = (flags & 1) !== 0;
    let selected = !source;
    if (operation === 9) selected = (source || (flags & 2) !== 0) ? source : (flags & 4) !== 0;
    if (operation === 10) selected = (flags & 4) !== 0;
    const result = new Uint8Array(1);
    result[0] = selected ? 1 : 0;
    return result;
  }
  const read = (at: number): number => request[at]! + request[at + 1]! * 256;
  if (request.length < 5) throw new Error("invalid toggle focus request");
  const subject = read(1), count = read(3);
  if (count > 1024 || subject >= count || request.length !== 5 + count * 4 ||
      ![4, 5, 6, 7].includes(operation)) throw new Error("invalid toggle focus request");
  const parent = (i: number): number => read(5 + i * 4);
  const kind = (i: number): number => request[7 + i * 4]!;
  const flags = (i: number): number => request[8 + i * 4]!;
  const group = parent(subject);
  let target = 65535;
  if (group < count && (kind(group) === 2 || kind(group) === 3)) {
    for (let i = 0; i < count; i++) {
      if (kind(i) !== 1 || parent(i) !== group || (flags(i) & 2) === 0) continue;
      if (operation === 6) { target = i; break; }
      if (operation === 7 || operation === 4 && i < subject) target = i;
      if (operation === 5 && i > subject) { target = i; break; }
    }
    if (target === 65535 && (operation === 4 || operation === 5)) target = subject;
  }
  const result = new Uint8Array(2);
  result[0] = target % 256; result[1] = Math.floor(target / 256);
  return result;
}

/** Accordion state requests: operation 8 (activate) or 9 (reconcile),
 * then flags (1 current/source open, 2 previous source open, 4 retained
 * open, 8 previous source present). A source flip wins; an unchanged or
 * absent previous source preserves retained expansion. Native owns the
 * disclosure animation, geometry, and concealed-content eligibility.
 */
export function native_accordion_policy(request: Uint8Array): Uint8Array {
  if (request.length !== 2 || (request[0] !== 8 && request[0] !== 9) || request[1]! > 15) {
    throw new Error("invalid accordion state request");
  }
  const flags = request[1]!, source = (flags & 1) !== 0;
  const moved = (flags & 8) !== 0 && source !== ((flags & 2) !== 0);
  const selected = request[0] === 8 ? !source : moved ? source : (flags & 4) !== 0;
  const result = new Uint8Array(1);
  result[0] = selected ? 1 : 0;
  return result;
}

/** Slider wire: operation u8, flags (1 previous source present, 2 pressed),
 * then current/source, previous source, and retained value as f32LE.
 * Operations: 0 clamp an applied value, 1 reconcile, 2/3 small decrement/
 * increment, 4/5 coarse decrement/increment, 6 Home, 7 End. Keyboard step
 * results are unclamped so native action flags retain their edge behavior.
 * Source changes win unless a drag is pressed; unchanged or absent history
 * preserves retained state. Native owns geometry and input eligibility.
 */
export function native_slider_policy(request: Uint8Array): Uint8Array {
  if (request.length !== 14 || request[0]! > 7 || request[1]! > 3) {
    throw new Error("invalid slider policy request");
  }
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const operation = request[0]!, flags = request[1]!;
  const current = wire.getFloat32(2, true), previous = wire.getFloat32(6, true), retained = wire.getFloat32(10, true);
  if (!Number.isFinite(current) || !Number.isFinite(previous) || !Number.isFinite(retained)) {
    throw new Error("non-finite slider policy value");
  }
  let value = current;
  if (operation === 1 && ((flags & 1) === 0 || current === previous || (flags & 2) !== 0)) value = retained;
  if (operation === 2 || operation === 3 || operation === 4 || operation === 5) {
    const step = Math.fround(operation < 4 ? 0.05 : 0.1);
    value = Math.fround(current + (operation === 2 || operation === 4 ? -step : step));
  }
  if (operation === 6) value = 0;
  if (operation === 7) value = 1;
  if (operation < 2) value = Math.max(0, Math.min(1, value));
  const result = new Uint8Array(4);
  new DataView(result.buffer).setFloat32(0, value, true);
  return result;
}

/** Split wire: operation u8, flags (1 previous source present, 2 declared
 * tween, 4 armed tween), then value, available width, first/second minimum,
 * previous source, and retained fraction as f32LE. Operations: 0 layout,
 * 1 applied clamp, 2 reconcile, 3/4 small decrement/increment, 5/6 coarse
 * decrement/increment, 7 Home, 8 End. Native owns geometry, capture, timing,
 * eligibility and mutation. Each arithmetic stage preserves native f32.
 */
export function native_split_policy(request: Uint8Array): Uint8Array {
  if (request.length !== 26 || request[0]! > 8 || request[1]! > 7) throw new Error("invalid split policy request");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const operation = request[0]!, flags = request[1]!;
  const current = wire.getFloat32(2, true), available = wire.getFloat32(6, true);
  const first = wire.getFloat32(10, true), second = wire.getFloat32(14, true);
  const previous = wire.getFloat32(18, true), retained = wire.getFloat32(22, true);
  if (![available, first, second, previous, retained].every(value => Number.isFinite(value)) || operation !== 0 && !Number.isFinite(current)) {
    throw new Error("non-finite split policy value");
  }
  let value = current;
  if (operation === 2 && (flags & 1) !== 0 && (current === previous || (flags & 6) !== 0)) value = retained;
  if (operation === 3 || operation === 4 || operation === 5 || operation === 6) {
    const step = Math.fround(operation < 5 ? 0.05 : 0.1);
    value = Math.fround(current + (operation === 3 || operation === 5 ? -step : step));
  }
  if (operation === 7) value = 0;
  if (operation === 8) value = 1;
  if (operation === 0 || operation === 1) {
    if (operation === 1) value = Math.max(value, Math.fround(0.0001));
    value = !Number.isFinite(value) || value <= 0 ? 0.5 : Math.min(value, 1);
    let low = 0, high = 1;
    if (available > 0) {
      low = Math.max(0, Math.min(1, Math.fround(Math.max(0, first) / available)));
      high = Math.max(0, Math.min(1, Math.fround(1 - Math.fround(Math.max(0, second) / available))));
      if (low > high) {
        const mid = Math.fround(low / Math.max(Math.fround(low + Math.fround(1 - high)), Math.fround(0.0001)));
        low = mid; high = mid;
      }
    }
    value = Math.max(low, Math.min(high, value));
  }
  const result = new Uint8Array(4);
  new DataView(result.buffer).setFloat32(0, value, true);
  return result;
}

/** Resizable wire: operation u8 (0 drag, 1 retained reconcile), then
 * panel height, current/retained width, and drag delta as f32LE. The
 * minimum is max(48, height); authored width seeds fresh panels and
 * retained width wins every enabled rebuild. Native owns capture,
 * eligibility and mutation; neighboring and descendant frames stay put.
 */
export function native_resizable_policy(request: Uint8Array): Uint8Array {
  if (request.length !== 13 || request[0]! > 1) throw new Error("invalid resizable policy request");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const height = wire.getFloat32(1, true), current = wire.getFloat32(5, true), delta = wire.getFloat32(9, true);
  // Zig @max chooses the other operand for NaN, including retained data.
  const minimum = Number.isNaN(height) ? 48 : Math.max(48, height);
  const candidate = request[0] === 0 ? Math.fround(current + delta) : current;
  const value = Number.isNaN(candidate) ? minimum : Math.max(minimum, candidate);
  const result = new Uint8Array(4);
  new DataView(result.buffer).setFloat32(0, value, true);
  return result;
}

/** Scroll wire: tagged operation u8 (128 + operation), flags (1 granted axis, 2 previous source,
 * 4 retained offset, 8 horizontal keymap, 16 dual keymap), then six f32LE:
 * current/source, viewport, content, delta/authored source, previous source,
 * retained offset. Results are two f32LE (scalar in X, keyboard delta X/Y).
 * Operations: 0 layout clamp, 1 discrete move, 2 reconcile, 3 programmatic
 * clamp, 4..9 Left/Right/Up/Down/PageUp/PageDown, 10/11 assistive decrement/
 * increment, 12/13 Home/End, 14 can consume. Keyboard uses viewport/content
 * slots for width/height. OS offsets and wheel/kinetic physics remain native.
 */
export function native_scroll_policy(request: Uint8Array): Uint8Array {
  if (request.length !== 26 || request[0]! < 128 || request[0]! > 142 || request[1]! > 31) {
    throw new Error("invalid scroll policy request");
  }
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const operation = request[0]! - 128, flags = request[1]!;
  const current = wire.getFloat32(2, true), viewport = wire.getFloat32(6, true);
  const content = wire.getFloat32(10, true), delta = wire.getFloat32(14, true);
  const previous = wire.getFloat32(18, true), retained = wire.getFloat32(22, true);
  const nonnegative = (value: number): number => Number.isNaN(value) ? 0 : Math.max(0, value);
  const maximum = Math.max(0, Math.fround(nonnegative(content) - nonnegative(viewport)));
  let x = current, y = 0;
  if (operation === 0 || operation === 3) {
    const moved = (flags & 2) === 0 || delta !== previous;
    const echo = (flags & 4) !== 0 && delta === retained;
    if (operation === 0 || moved && !echo) {
      x = (flags & 1) !== 0 ? Math.min(maximum, nonnegative(current)) : 0;
    }
  } else if (operation === 1) {
    x = (flags & 1) !== 0 ? Math.min(maximum, nonnegative(Math.fround(current + delta))) : 0;
  } else if (operation === 2) {
    if ((flags & 7) === 7 && current === previous) x = retained;
  } else if (operation >= 4 && operation <= 11) {
    const horizontal = (flags & 8) !== 0 || (flags & 16) !== 0 && (operation === 4 || operation === 5);
    const extent = horizontal ? viewport : content;
    const line = Math.max(24, Math.fround(extent * Math.fround(0.35)));
    const page = Math.max(line, Math.fround(extent * Math.fround(0.85)));
    const step = operation >= 8 ? page : line;
    const signed = operation === 4 || operation === 6 || operation === 8 || operation === 10 ? -step : step;
    x = horizontal ? signed : 0; y = horizontal ? 0 : signed;
  } else if (operation === 12 || operation === 13) {
    x = (flags & 1) !== 0 && operation === 13 ? maximum : 0;
  } else if (operation === 14) {
    x = delta === 0 ? 0 : current < 0 ? (delta > 0 ? 1 : 0) : current > maximum ? (delta < 0 ? 1 : 0) :
      delta > 0 ? (current < maximum ? 1 : 0) : (current > 0 ? 1 : 0);
  }
  const result = new Uint8Array(8), out = new DataView(result.buffer);
  out.setFloat32(0, x, true); out.setFloat32(4, y, true);
  return result;
}

/** Retained tree wire: operation u8, subject/count u16LE, then parent
 * u16LE, kind bits (1 treeitem/2 tree scope), flags (1 logical focus,
 * 4 selected/8 expanded), and tree-level u16LE per node. Operations:
 * 0 nearest scope, 4 previous, 5 next, 6 first, 7 last, 8 selection clear
 * mask, 9 Left, 10 Right. Index 65535 means no target/disclosure intent.
 * Traversal preserves native preorder and flat-level/nested hierarchy;
 * geometry eligibility and applied state remain native. Expansion and
 * the presence of child rows remain model-owned.
 */
export function native_tree_policy(request: Uint8Array): Uint8Array {
  const read = (at: number): number => request[at]! + request[at + 1]! * 256;
  if (request.length < 5) throw new Error("invalid tree policy request");
  const operation = request[0]!, subject = read(1), count = read(3);
  if (count > 1024 || subject >= count || request.length !== 5 + count * 6 ||
      ![0, 4, 5, 6, 7, 8, 9, 10].includes(operation)) throw new Error("invalid tree policy request");
  const parent = (i: number): number => read(5 + i * 6);
  const kind = (i: number): number => request[7 + i * 6]!;
  const flags = (i: number): number => request[8 + i * 6]!;
  const level = (i: number): number => read(9 + i * 6);
  for (let i = 0; i < count; i++) if (parent(i) !== 65535 && parent(i) >= i) throw new Error("invalid tree policy parent");
  const scope = (i: number): number => {
    for (let p = parent(i); p !== 65535; p = parent(p)) if ((kind(p) & 2) !== 0) return p;
    return 65535;
  };
  const descendant = (i: number, ancestor: number): boolean => {
    for (let p = parent(i); p !== 65535; p = parent(p)) if (p === ancestor) return true;
    return false;
  };
  const row = (i: number): boolean => (kind(i) & 1) !== 0;
  const focus = (i: number): boolean => row(i) && (flags(i) & 1) !== 0;
  const group = scope(subject);
  if (operation === 8) {
    const result = new Uint8Array(count);
    for (let i = 0; i < count; i++) if (i !== subject && row(i) && (flags(i) & 4) !== 0 && scope(i) === group) result[i] = 1;
    return result;
  }
  let target = 65535;
  if (operation === 0) target = group;
  else if (group !== 65535 && row(subject)) {
    if (operation >= 4 && operation <= 7) {
      for (let i = group + 1; i < count && descendant(i, group); i++) {
        if (!focus(i)) continue;
        if (operation === 6) { target = i; break; }
        if (operation === 7 || operation === 4 && i < subject) target = i;
        if (operation === 5 && i > subject) { target = i; break; }
      }
      if (target === 65535 && (operation === 4 || operation === 5)) target = subject;
    } else if (operation === 9 && (flags(subject) & 8) === 0) {
      target = subject;
      if (level(subject) > 1) {
        for (let i = subject - 1; i > group; i--) {
          if (!row(i)) continue;
          if (level(i) === level(subject) - 1) { if (focus(i)) target = i; break; }
          if (level(i) !== 0 && level(i) < level(subject) - 1) break;
        }
      } else {
        for (let p = parent(subject); p !== 65535 && p !== group; p = parent(p)) {
          if (focus(p)) { target = p; break; }
        }
      }
    } else if (operation === 10 && (flags(subject) & 8) !== 0) {
      target = subject;
      if (level(subject) > 0) {
        for (let i = subject + 1; i < count && descendant(i, group); i++) {
          if (!row(i)) continue;
          if (level(i) === level(subject) + 1 && focus(i)) target = i;
          break;
        }
      } else {
        for (let i = subject + 1; i < count && descendant(i, subject); i++) {
          if (focus(i)) { target = i; break; }
        }
      }
    }
  }
  const result = new Uint8Array(2);
  result[0] = target % 256; result[1] = Math.floor(target / 256);
  return result;
}
