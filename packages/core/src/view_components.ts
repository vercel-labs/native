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
  press?: number[]; toggle?: number[]; drag?: number[]; scroll?: number;
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
