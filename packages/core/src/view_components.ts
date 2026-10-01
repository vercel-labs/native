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
  listItemIndex?: number; listItemCount?: number;
  spanWeight?: string; spanColor?: string; spanScale?: number;
  press?: number[]; toggle?: number[]; change?: number[]; drag?: number[]; scroll?: number;
  input?: number; submit?: number[];
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
