/** Portable component composition compiled with scriptc beside the app model.
 * These functions emit only primitive view records. Native owns measurement,
 * rendering, hit testing, and delivery of the declared message envelopes.
 */
type NscViewNode = {
  end: number; kind: string; text: string; placeholder?: string; wrap?: boolean;
  key?: string; keyInt?: number; keySlot?: number; globalKey?: string; globalKeyInt?: number;
  gap?: number; padding?: number; grow?: number; width?: number; height?: number;
  value?: number; image?: number; icon?: string; label?: string; role?: string;
  background?: string; foreground?: string; radius?: string; windowDrag?: boolean;
  main?: string; cross?: string; size?: string; variant?: string; checked?: boolean;
  disabled?: boolean; selected?: boolean; focusable?: boolean;
  expanded?: boolean; treeLevel?: number;
  listItemIndex?: number; listItemCount?: number;
  spanWeight?: string; spanColor?: string; spanScale?: number;
  press?: number[]; toggle?: number[]; change?: number[]; drag?: number[]; scroll?: number;
  input?: number; submit?: number[]; dismiss?: number[];
  anchor?: string; anchorAlignment?: string; anchorOffset?: number;
};

function nscvPush(nodes: NscViewNode[], node: NscViewNode): void {
  if (nodes.length >= 1024) throw new Error("compiled view exceeds 1024 nodes");
  nodes.push(node);
  node.end = nodes.length;
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
