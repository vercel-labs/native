/** Development view evaluator. A view program (see view_program.ts) is the
 * same statement tree the release view compiler prints as TypeScript. This
 * module decodes that program and evaluates it against the committed model,
 * calling the same portable view builders the release code calls, so a
 * reloaded view produces exactly the records a rebuilt release view would.
 * The per-app bridge supplies typed model reads, helper calls and message
 * packing; everything here is fixed SDK code. Debug builds only.
 */
const NSCVD_UNDEFINED = 0, NSCVD_NUMBER = 1, NSCVD_STRING = 2, NSCVD_BOOL = 3, NSCVD_BYTES = 4, NSCVD_NULL = 5,
  NSCVD_LIST = 6, NSCVD_NUMS = 7, NSCVD_BOOLS = 8, NSCVD_BYTE_LIST = 9, NSCVD_STR_LIST = 10,
  NSCVD_NODE = 11, NSCVD_NODES = 12, NSCVD_SPAN = 13, NSCVD_CONTEXT_ITEM = 14, NSCVD_CHART_SERIES = 15,
  NSCVD_COMPONENT_TEXT = 16, NSCVD_TIMELINE_ITEM = 17, NSCVD_VIRTUAL_REQUEST = 18, NSCVD_VIDEO = 19,
  NSCVD_BUILD = 20, NSCVD_REQUESTS = 21, NSCVD_RANGE = 22, NSCVD_RANGES = 23, NSCVD_IMAGE_ID = 24, NSCVD_CONTRACT = 25;

type NscvdImageIdentity = { imageLower: number; imageUpper: number };

class NscvdValue {
  t: number = NSCVD_UNDEFINED;
  n: number = 0;
  s: string = "";
  b: boolean = false;
  bytes: Uint8Array = new Uint8Array(0);
  list: NscvdValue[] = [];
  nums: number[] = [];
  bools: boolean[] = [];
  byteList: Uint8Array[] = [];
  strs: string[] = [];
  node: NscViewNode | null = null;
  nodes: NscViewNode[] = [];
  span: NscViewSpan | null = null;
  item: NscContextMenuItem | null = null;
  series: NscChartSeries | null = null;
  componentText: NscComponentText | null = null;
  timeline: NscTimelineItem | null = null;
  request: NscVirtualRequest | null = null;
  video: NscVideoPlaybackState | null = null;
  build: NscVirtualBuild | null = null;
  requests: NscVirtualRequest[] = [];
  range: NscVirtualRange | null = null;
  ranges: NscVirtualRange[] = [];
  image: NscvdImageIdentity | null = null;
  c: NscvdContract | null = null;
  /** Contract type index and whether the value is a list of it (bridge-owned). */
  ct: number = 0;
  cl: boolean = false;
}

const nscvdUndefinedValue = new NscvdValue();
function nscvdTagged(tag: number): NscvdValue { const value = new NscvdValue(); value.t = tag; return value; }
function nscvdNum(n: number): NscvdValue { const value = nscvdTagged(NSCVD_NUMBER); value.n = n; return value; }
function nscvdStr(s: string): NscvdValue { const value = nscvdTagged(NSCVD_STRING); value.s = s; return value; }
function nscvdBoolean(b: boolean): NscvdValue { const value = nscvdTagged(NSCVD_BOOL); value.b = b; return value; }
function nscvdBytesValue(bytes: Uint8Array): NscvdValue { const value = nscvdTagged(NSCVD_BYTES); value.bytes = bytes; return value; }
function nscvdNumsValue(nums: number[]): NscvdValue { const value = nscvdTagged(NSCVD_NUMS); value.nums = nums; return value; }
function nscvdBoolsValue(bools: boolean[]): NscvdValue { const value = nscvdTagged(NSCVD_BOOLS); value.bools = bools; return value; }
function nscvdByteListValue(list: Uint8Array[]): NscvdValue { const value = nscvdTagged(NSCVD_BYTE_LIST); value.byteList = list; return value; }
function nscvdStrListValue(list: string[]): NscvdValue { const value = nscvdTagged(NSCVD_STR_LIST); value.strs = list; return value; }
function nscvdNodeValue(node: NscViewNode): NscvdValue { const value = nscvdTagged(NSCVD_NODE); value.node = node; return value; }
function nscvdRangeValue(range: NscVirtualRange): NscvdValue { const value = nscvdTagged(NSCVD_RANGE); value.range = range; return value; }

// ------------------------------------------------------------ conversions

function nscvdCopyNumbers(values: readonly number[]): number[] { const out: number[] = []; for (const value of values) out.push(value); return out; }
function nscvdCopyBooleans(values: readonly boolean[]): boolean[] { const out: boolean[] = []; for (const value of values) out.push(value); return out; }
function nscvdCopyBytes(values: readonly Uint8Array[]): Uint8Array[] { const out: Uint8Array[] = []; for (const value of values) out.push(value); return out; }
function nscvdCopyStrings(values: readonly string[]): string[] { const out: string[] = []; for (const value of values) out.push(value); return out; }
/** An exact integer for an integer-attested slot; never coerces. */
function nscvdI64(value: number): number {
  if (!Number.isSafeInteger(value)) throw new Error("development view expected an exact integer");
  return value >= -9007199254740991 && value <= 9007199254740991 ? Math.trunc(value) : 0;
}
function nscvdNull(): NscvdValue { return nscvdTagged(NSCVD_NULL); }
function nscvdUnsupported(what: string): NscvdValue { throw new Error("development view cannot read " + what); }

function nscvdNumber(value: NscvdValue): number {
  if (value.t !== NSCVD_NUMBER) throw new Error("development view expected a number");
  return value.n;
}
function nscvdString(value: NscvdValue): string {
  if (value.t !== NSCVD_STRING) throw new Error("development view expected text");
  return value.s;
}
function nscvdBool(value: NscvdValue): boolean {
  if (value.t !== NSCVD_BOOL) throw new Error("development view expected a boolean");
  return value.b;
}
function nscvdBytes(value: NscvdValue): Uint8Array {
  if (value.t !== NSCVD_BYTES) throw new Error("development view expected bytes");
  return value.bytes;
}
function nscvdNumbers(value: NscvdValue): number[] {
  if (value.t === NSCVD_NUMS) return value.nums;
  if (value.t === NSCVD_LIST) { const out: number[] = []; for (const item of value.list) out.push(nscvdNumber(item)); return out; }
  throw new Error("development view expected a number list");
}
function nscvdBooleans(value: NscvdValue): boolean[] {
  if (value.t === NSCVD_BOOLS) return value.bools;
  if (value.t === NSCVD_LIST && value.list.length === 0) return [];
  throw new Error("development view expected a boolean list");
}
function nscvdByteParts(value: NscvdValue): Uint8Array[] {
  if (value.t === NSCVD_BYTE_LIST) return value.byteList;
  if (value.t === NSCVD_LIST) { const out: Uint8Array[] = []; for (const item of value.list) out.push(nscvdBytes(item)); return out; }
  throw new Error("development view expected a byte list");
}
function nscvdNumberLists(value: NscvdValue): number[][] {
  if (value.t !== NSCVD_LIST) throw new Error("development view expected a list of number lists");
  const out: number[][] = [];
  for (const item of value.list) out.push(nscvdNumbers(item));
  return out;
}
function nscvdList(value: NscvdValue): NscvdValue[] {
  if (value.t !== NSCVD_LIST) throw new Error("development view expected a list");
  return value.list;
}
function nscvdSpans(value: NscvdValue): NscViewSpan[] {
  const out: NscViewSpan[] = [];
  for (const item of nscvdList(value)) { if (item.span === null) throw new Error("development view expected a span"); out.push(item.span); }
  return out;
}
function nscvdContextItems(value: NscvdValue): NscContextMenuItem[] {
  const out: NscContextMenuItem[] = [];
  for (const item of nscvdList(value)) { if (item.item === null) throw new Error("development view expected a context menu item"); out.push(item.item); }
  return out;
}
function nscvdSeriesList(value: NscvdValue): NscChartSeries[] {
  const out: NscChartSeries[] = [];
  for (const item of nscvdList(value)) { if (item.series === null) throw new Error("development view expected a chart series"); out.push(item.series); }
  return out;
}
function nscvdComponentTexts(value: NscvdValue): NscComponentText[] {
  const out: NscComponentText[] = [];
  for (const item of nscvdList(value)) out.push(nscvdComponentText(item));
  return out;
}
function nscvdComponentText(value: NscvdValue): NscComponentText {
  if (value.componentText === null) throw new Error("development view expected component text");
  return value.componentText;
}
function nscvdNode(value: NscvdValue): NscViewNode {
  if (value.node === null) throw new Error("development view expected a view node");
  return value.node;
}
function nscvdNodes(value: NscvdValue): NscViewNode[] {
  if (value.t !== NSCVD_NODES) throw new Error("development view expected the view node list");
  return value.nodes;
}
function nscvdRange(value: NscvdValue): NscVirtualRange {
  if (value.range === null) throw new Error("development view expected a virtual window range");
  return value.range;
}
function nscvdBuild(value: NscvdValue): NscVirtualBuild {
  if (value.build === null) throw new Error("development view expected a virtual window context");
  return value.build;
}

// ------------------------------------------------------------ records

function nscvdSetNode(node: NscViewNode, key: string, value: NscvdValue): void {
  if (value.t === NSCVD_UNDEFINED) return;
  switch (key) {
    case "end": node.end = nscvdNumber(value); return;
    case "kind": node.kind = nscvdString(value); return;
    case "text": node.text = nscvdString(value); return;
    case "textBytes": node.textBytes = nscvdNumbers(value); return;
    case "labelBytes": node.labelBytes = nscvdNumbers(value); return;
    case "placeholderBytes": node.placeholderBytes = nscvdNumbers(value); return;
    case "placeholder": node.placeholder = nscvdString(value); return;
    case "command": node.command = nscvdString(value); return;
    case "wrap": node.wrap = nscvdBool(value); return;
    case "submitOnEnter": node.submitOnEnter = nscvdBool(value); return;
    case "key": node.key = nscvdString(value); return;
    case "keyBytes": node.keyBytes = nscvdNumbers(value); return;
    case "keyInt": node.keyInt = nscvdNumber(value); return;
    case "keySlot": node.keySlot = nscvdNumber(value); return;
    case "globalKey": node.globalKey = nscvdString(value); return;
    case "globalKeyBytes": node.globalKeyBytes = nscvdNumbers(value); return;
    case "globalKeyInt": node.globalKeyInt = nscvdNumber(value); return;
    case "columns": node.columns = nscvdNumber(value); return;
    case "virtualized": node.virtualized = nscvdBool(value); return;
    case "virtualItemExtent": node.virtualItemExtent = nscvdNumber(value); return;
    case "virtualWindow": node.virtualWindow = nscvdNumber(value); return;
    case "gap": node.gap = nscvdNumber(value); return;
    case "padding": node.padding = nscvdNumber(value); return;
    case "grow": node.grow = nscvdNumber(value); return;
    case "width": node.width = nscvdNumber(value); return;
    case "height": node.height = nscvdNumber(value); return;
    case "minWidth": node.minWidth = nscvdNumber(value); return;
    case "maxWidth": node.maxWidth = nscvdNumber(value); return;
    case "paddingTop": node.paddingTop = nscvdNumber(value); return;
    case "paddingBottom": node.paddingBottom = nscvdNumber(value); return;
    case "paddingLeft": node.paddingLeft = nscvdNumber(value); return;
    case "paddingRight": node.paddingRight = nscvdNumber(value); return;
    case "resizeDuration": node.resizeDuration = nscvdNumber(value); return;
    case "resizeEasing": node.resizeEasing = nscvdString(value); return;
    case "resizeOrigin": node.resizeOrigin = nscvdNumber(value); return;
    case "value": node.value = nscvdNumber(value); return;
    case "valueX": node.valueX = nscvdNumber(value); return;
    case "axis": node.axis = nscvdString(value); return;
    case "overscroll": node.overscroll = nscvdString(value); return;
    case "videoSrc": node.videoSrc = nscvdString(value); return;
    case "videoControls": node.videoControls = nscvdBool(value); return;
    case "videoAutoplay": node.videoAutoplay = nscvdBool(value); return;
    case "videoLoop": node.videoLoop = nscvdBool(value); return;
    case "videoMuted": node.videoMuted = nscvdBool(value); return;
    case "videoControl": node.videoControl = nscvdString(value); return;
    case "zeroIntrinsic": node.zeroIntrinsic = nscvdBool(value); return;
    case "clipContent": node.clipContent = nscvdBool(value); return;
    case "overflow": node.overflow = nscvdString(value); return;
    case "pty": node.pty = nscvdNumber(value); return;
    case "ptyBytes": node.ptyBytes = nscvdNumbers(value); return;
    case "scrollback": node.scrollback = nscvdNumber(value); return;
    case "terminal": node.terminal = nscvdNumber(value); return;
    case "image": node.image = nscvdNumber(value); return;
    case "imageLower": node.imageLower = nscvdNumber(value); return;
    case "imageUpper": node.imageUpper = nscvdNumber(value); return;
    case "imageFit": node.imageFit = nscvdString(value); return;
    case "icon": node.icon = nscvdString(value); return;
    case "iconBytes": node.iconBytes = nscvdNumbers(value); return;
    case "iconPlacement": node.iconPlacement = nscvdString(value); return;
    case "label": node.label = nscvdString(value); return;
    case "role": node.role = nscvdString(value); return;
    case "background": node.background = nscvdString(value); return;
    case "foreground": node.foreground = nscvdString(value); return;
    case "borderColor": node.borderColor = nscvdString(value); return;
    case "focusRing": node.focusRing = nscvdString(value); return;
    case "accent": node.accent = nscvdString(value); return;
    case "accentForeground": node.accentForeground = nscvdString(value); return;
    case "radius": node.radius = nscvdString(value); return;
    case "backdropBlur": node.backdropBlur = nscvdString(value); return;
    case "quietHover": node.quietHover = nscvdBool(value); return;
    case "windowDrag": node.windowDrag = nscvdBool(value); return;
    case "main": node.main = nscvdString(value); return;
    case "cross": node.cross = nscvdString(value); return;
    case "size": node.size = nscvdString(value); return;
    case "variant": node.variant = nscvdString(value); return;
    case "checked": node.checked = nscvdBool(value); return;
    case "disabled": node.disabled = nscvdBool(value); return;
    case "selected": node.selected = nscvdBool(value); return;
    case "focusable": node.focusable = nscvdBool(value); return;
    case "autofocus": node.autofocus = nscvdBool(value); return;
    case "expanded": node.expanded = nscvdBool(value); return;
    case "treeLevel": node.treeLevel = nscvdNumber(value); return;
    case "listItemIndex": node.listItemIndex = nscvdNumber(value); return;
    case "listItemCount": node.listItemCount = nscvdNumber(value); return;
    case "spans": node.spans = nscvdSpans(value); return;
    case "textAlignment": node.textAlignment = nscvdString(value); return;
    case "spanWeight": node.spanWeight = nscvdString(value); return;
    case "spanColor": node.spanColor = nscvdString(value); return;
    case "spanScale": node.spanScale = nscvdNumber(value); return;
    case "markdownRecipe": node.markdownRecipe = nscvdNumbers(value); return;
    case "markdownLink": node.markdownLink = nscvdNumber(value); return;
    case "markdownDetails": node.markdownDetails = nscvdNumber(value); return;
    case "codeLanguage": node.codeLanguage = nscvdString(value); return;
    case "codeLineDigits": node.codeLineDigits = nscvdNumber(value); return;
    case "codeEditable": node.codeEditable = nscvdBool(value); return;
    case "codeNumbered": node.codeNumbered = nscvdBool(value); return;
    case "codeAddedLines": node.codeAddedLines = nscvdNumbers(value); return;
    case "codeRemovedLines": node.codeRemovedLines = nscvdNumbers(value); return;
    case "chartSeries": node.chartSeries = nscvdSeriesList(value); return;
    case "chartXLabels": node.chartXLabels = nscvdNumberLists(value); return;
    case "chartYMin": node.chartYMin = nscvdNumber(value); return;
    case "chartYMax": node.chartYMax = nscvdNumber(value); return;
    case "chartGridLines": node.chartGridLines = nscvdNumber(value); return;
    case "chartBaseline": node.chartBaseline = nscvdBool(value); return;
    case "chartYLabels": node.chartYLabels = nscvdBool(value); return;
    case "chartHoverDetails": node.chartHoverDetails = nscvdBool(value); return;
    case "chartStrokeWidth": node.chartStrokeWidth = nscvdNumber(value); return;
    case "contextMenu": node.contextMenu = nscvdContextItems(value); return;
    case "press": node.press = nscvdNumbers(value); return;
    case "doublePress": node.doublePress = nscvdNumbers(value); return;
    case "hold": node.hold = nscvdNumbers(value); return;
    case "toggle": node.toggle = nscvdNumbers(value); return;
    case "change": node.change = nscvdNumbers(value); return;
    case "drag": node.drag = nscvdNumbers(value); return;
    case "scroll": node.scroll = nscvdNumber(value); return;
    case "input": node.input = nscvdNumber(value); return;
    case "valueChange": node.valueChange = nscvdNumber(value); return;
    case "resize": node.resize = nscvdNumber(value); return;
    case "submit": node.submit = nscvdNumbers(value); return;
    case "dismiss": node.dismiss = nscvdNumbers(value); return;
    case "hoverEnter": node.hoverEnter = nscvdNumbers(value); return;
    case "hoverLeave": node.hoverLeave = nscvdNumbers(value); return;
    case "reachEnd": node.reachEnd = nscvdNumbers(value); return;
    case "reachStart": node.reachStart = nscvdNumbers(value); return;
    case "anchor": node.anchor = nscvdString(value); return;
    case "anchorAlignment": node.anchorAlignment = nscvdString(value); return;
    case "anchorOffset": node.anchorOffset = nscvdNumber(value); return;
    case "tooltipDelay": node.tooltipDelay = nscvdNumber(value); return;
  }
  throw new Error("unknown development view node field " + key);
}
function nscvdSetSpan(span: NscViewSpan, key: string, value: NscvdValue): void {
  if (value.t === NSCVD_UNDEFINED) return;
  switch (key) {
    case "text": span.text = nscvdString(value); return;
    case "textBytes": span.textBytes = nscvdNumbers(value); return;
    case "weight": span.weight = nscvdString(value); return;
    case "color": span.color = nscvdString(value); return;
    case "scale": span.scale = nscvdNumber(value); return;
    case "monospace": span.monospace = nscvdBool(value); return;
    case "italic": span.italic = nscvdBool(value); return;
    case "underline": span.underline = nscvdBool(value); return;
  }
  throw new Error("unknown development view span field " + key);
}
function nscvdSetContextItem(item: NscContextMenuItem, key: string, value: NscvdValue): void {
  if (value.t === NSCVD_UNDEFINED) return;
  switch (key) {
    case "label": item.label = nscvdString(value); return;
    case "labelBytes": item.labelBytes = nscvdNumbers(value); return;
    case "press": item.press = nscvdNumbers(value); return;
    case "enabled": item.enabled = nscvdBool(value); return;
    case "separator": item.separator = nscvdBool(value); return;
  }
  throw new Error("unknown development view context menu field " + key);
}
function nscvdSetSeries(series: NscChartSeries, key: string, value: NscvdValue): void {
  switch (key) {
    case "kind": series.kind = nscvdString(value); return;
    case "values": series.values = nscvdNumbers(value); return;
    case "color": series.color = nscvdString(value); return;
    case "fill": series.fill = nscvdBool(value); return;
    case "label": series.label = nscvdNumbers(value); return;
  }
  throw new Error("unknown development view chart series field " + key);
}
function nscvdSetComponentText(text: NscComponentText, key: string, value: NscvdValue): void {
  if (value.t === NSCVD_UNDEFINED) return;
  switch (key) {
    case "text": text.text = nscvdString(value); return;
    case "bytes": text.bytes = nscvdNumbers(value); return;
  }
  throw new Error("unknown development view component text field " + key);
}
function nscvdSetTimelineItem(item: NscTimelineItem, key: string, value: NscvdValue): void {
  switch (key) {
    case "root": item.root = nscvdNode(value); return;
    case "title": item.title = nscvdComponentText(value); return;
    case "description": item.description = nscvdComponentText(value); return;
    case "meta": item.meta = nscvdComponentText(value); return;
    case "indicator": item.indicator = nscvdComponentText(value); return;
    case "icon": item.icon = nscvdString(value); return;
    case "variant": item.variant = nscvdString(value); return;
    case "connector": item.connector = nscvdBool(value); return;
  }
  throw new Error("unknown development view timeline item field " + key);
}
function nscvdSetRequest(request: NscVirtualRequest, key: string, value: NscvdValue): void {
  switch (key) {
    case "id": request.id = nscvdString(value); return;
    case "itemCount": request.itemCount = nscvdNumber(value); return;
    case "itemExtent": request.itemExtent = nscvdNumber(value); return;
    case "gap": request.gap = nscvdNumber(value); return;
    case "overscan": request.overscan = nscvdNumber(value); return;
    case "viewportFallback": request.viewportFallback = nscvdNumber(value); return;
    case "indexBase": request.indexBase = nscvdNumber(value); return;
    case "trailing": request.trailing = nscvdBool(value); return;
    case "estimateHelper": request.estimateHelper = nscvdNumber(value); return;
  }
  throw new Error("unknown development view virtual request field " + key);
}
function nscvdRangeField(range: NscVirtualRange, key: string): number {
  switch (key) {
    case "start_index": return range.start_index;
    case "end_index": return range.end_index;
    case "first_visible_index": return range.first_visible_index;
    case "last_visible_index": return range.last_visible_index;
    case "item_extent": return range.item_extent;
    case "item_gap": return range.item_gap;
    case "scroll_offset": return range.scroll_offset;
    case "layout_offset": return range.layout_offset;
    case "content_extent": return range.content_extent;
    case "before_extent": return range.before_extent;
    case "after_extent": return range.after_extent;
    case "anchor_extent": return range.anchor_extent;
  }
  throw new Error("unknown development view range field " + key);
}

// ------------------------------------------------------------ program

/** Decoded program nodes. `k` is the encoded kind; see view_program.ts. */
class NscvdExpr {
  k: number = 0; n: number = 0; s: string = ""; t: string = "";
  a: NscvdExpr | null = null; b: NscvdExpr | null = null; c: NscvdExpr | null = null;
  args: NscvdExpr[] = []; keys: string[] = [];
}
class NscvdStmt {
  k: number = 0; s: string = "";
  a: NscvdExpr | null = null; b: NscvdExpr | null = null;
  body: NscvdStmt[] = []; otherwise: NscvdStmt[] | null = null;
}
class NscvdView { label: string = ""; body: NscvdStmt[] = []; attribution: string = ""; }
class NscvdReader {
  at: number = 0;
  readonly bytes: Uint8Array;
  readonly view: DataView;
  constructor(bytes: Uint8Array) { this.bytes = bytes; this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength); }
  need(count: number): void { if (count > this.bytes.length - this.at) throw new Error("truncated development view program"); }
  u8(): number { this.need(1); return this.bytes[this.at++]!; }
  u32(): number { this.need(4); const value = this.view.getUint32(this.at, true); this.at += 4; return value; }
  f64(): number { this.need(8); const value = this.view.getFloat64(this.at, true); this.at += 8; return value; }
  str(): string { const length = this.u32(); this.need(length); const value = new TextDecoder().decode(this.bytes.subarray(this.at, this.at + length)); this.at += length; return value; }
  count(): number { const value = this.u32(); if (value > this.bytes.length) throw new Error("invalid development view program count"); return value; }
}
function nscvdReadExpr(r: NscvdReader, depth: number): NscvdExpr {
  if (depth > 256) throw new Error("development view program nests too deeply");
  const e = new NscvdExpr(); e.k = r.u8();
  switch (e.k) {
    case 0: e.n = r.f64(); break;
    case 1: case 5: e.s = r.str(); break;
    case 2: e.n = r.u8(); break;
    case 3: case 4: case 25: break;
    case 6: e.a = nscvdReadExpr(r, depth + 1); e.s = r.str(); break;
    case 7: case 15: e.a = nscvdReadExpr(r, depth + 1); e.b = nscvdReadExpr(r, depth + 1); break;
    case 8: case 9: case 10: case 18: case 19: case 20: case 21: case 22: e.a = nscvdReadExpr(r, depth + 1); break;
    case 11: { e.s = r.str(); const n = r.count(); for (let i = 0; i < n; i++) e.args.push(nscvdReadExpr(r, depth + 1)); break; }
    case 12: e.s = r.str(); e.a = nscvdReadExpr(r, depth + 1); e.b = nscvdReadExpr(r, depth + 1); break;
    case 13: e.n = r.u8(); e.a = nscvdReadExpr(r, depth + 1); break;
    case 14: e.a = nscvdReadExpr(r, depth + 1); e.b = nscvdReadExpr(r, depth + 1); e.c = nscvdReadExpr(r, depth + 1); break;
    case 16: {
      e.t = r.str(); e.s = r.str(); const n = r.count();
      for (let i = 0; i < n; i++) { e.keys.push(r.str()); e.args.push(nscvdReadExpr(r, depth + 1)); }
      break;
    }
    case 17: { const n = r.count(); for (let i = 0; i < n; i++) e.args.push(nscvdReadExpr(r, depth + 1)); break; }
    case 23: e.a = nscvdReadExpr(r, depth + 1); e.n = r.u8(); break;
    case 24: e.a = nscvdReadExpr(r, depth + 1); e.n = r.u32(); break;
    default: throw new Error("unknown development view expression");
  }
  return e;
}
function nscvdReadBlock(r: NscvdReader, depth: number): NscvdStmt[] {
  const out: NscvdStmt[] = [];
  const n = r.count();
  for (let i = 0; i < n; i++) out.push(nscvdReadStmt(r, depth));
  return out;
}
function nscvdReadStmt(r: NscvdReader, depth: number): NscvdStmt {
  if (depth > 256) throw new Error("development view program nests too deeply");
  const st = new NscvdStmt(); st.k = r.u8();
  switch (st.k) {
    case 0: st.s = r.str(); st.a = nscvdReadExpr(r, 0); break;
    case 1: st.a = nscvdReadExpr(r, 0); break;
    case 2: case 3: st.a = nscvdReadExpr(r, 0); st.b = nscvdReadExpr(r, 0); break;
    case 4: st.a = nscvdReadExpr(r, 0); st.body = nscvdReadBlock(r, depth + 1); if (r.u8() === 1) st.otherwise = nscvdReadBlock(r, depth + 1); break;
    case 5: st.s = r.str(); st.a = nscvdReadExpr(r, 0); st.body = nscvdReadBlock(r, depth + 1); break;
    case 6: st.a = nscvdReadExpr(r, 0); st.s = r.str(); break;
    default: throw new Error("unknown development view statement");
  }
  return st;
}
const nscvdMagic = [78, 83, 86, 80];
/** Decode a program for this core's bridge; throws a teaching error otherwise. */
function nscvdDecodeProgram(bytes: Uint8Array): NscvdView[] {
  const r = new NscvdReader(bytes);
  for (let i = 0; i < 4; i++) if (r.u8() !== nscvdMagic[i]) throw new Error("not a development view program");
  if (r.u32() !== 1) throw new Error("development view program format is not supported by this build; rebuild the app");
  if (r.str() !== nscvdBridgeIdentity) throw new Error("development view program was compiled for a different build of this app; rebuild the app");
  const views: NscvdView[] = [];
  const n = r.count();
  if (n === 0 || n > 65) throw new Error("invalid development view program root count");
  for (let i = 0; i < n; i++) { const view = new NscvdView(); view.label = r.str(); view.body = nscvdReadBlock(r, 0); view.attribution = r.str(); views.push(view); }
  if (r.at !== bytes.length) throw new Error("trailing development view program bytes");
  if (views[0]!.label.length !== 0) throw new Error("development view program has no main view");
  return views;
}

// ------------------------------------------------------------ evaluation

type NscvdScope = Map<string, NscvdValue>;
function nscvdLookup(scope: NscvdScope, name: string): NscvdValue {
  if (name === "nscfCommitted") return nscvdModel();
  const value = scope.get(name);
  if (value === undefined) throw new Error("unbound development view name " + name);
  return value;
}
function nscvdLength(value: NscvdValue): number {
  switch (value.t) {
    case NSCVD_STRING: return value.s.length;
    case NSCVD_BYTES: return value.bytes.length;
    case NSCVD_LIST: return value.list.length;
    case NSCVD_NUMS: return value.nums.length;
    case NSCVD_BOOLS: return value.bools.length;
    case NSCVD_BYTE_LIST: return value.byteList.length;
    case NSCVD_STR_LIST: return value.strs.length;
    case NSCVD_NODES: return value.nodes.length;
    case NSCVD_REQUESTS: return value.requests.length;
    case NSCVD_RANGES: return value.ranges.length;
    case NSCVD_CONTRACT: return nscvdContractLength(value);
  }
  throw new Error("development view value has no length");
}
function nscvdItems(value: NscvdValue): NscvdValue[] {
  switch (value.t) {
    case NSCVD_LIST: return value.list;
    case NSCVD_NUMS: { const out: NscvdValue[] = []; for (const n of value.nums) out.push(nscvdNum(n)); return out; }
    case NSCVD_BOOLS: { const out: NscvdValue[] = []; for (const b of value.bools) out.push(nscvdBoolean(b)); return out; }
    case NSCVD_BYTE_LIST: { const out: NscvdValue[] = []; for (const b of value.byteList) out.push(nscvdBytesValue(b)); return out; }
    case NSCVD_STR_LIST: { const out: NscvdValue[] = []; for (const s of value.strs) out.push(nscvdStr(s)); return out; }
    case NSCVD_CONTRACT: return nscvdContractItems(value);
  }
  throw new Error("development view value is not iterable");
}
function nscvdField(target: NscvdValue, name: string): NscvdValue {
  switch (target.t) {
    case NSCVD_CONTRACT: return nscvdContractField(target, name);
    case NSCVD_RANGE: return nscvdNum(nscvdRangeField(nscvdRange(target), name));
    case NSCVD_IMAGE_ID: {
      const image = target.image!;
      if (name === "imageLower") return nscvdNum(image.imageLower);
      if (name === "imageUpper") return nscvdNum(image.imageUpper);
      break;
    }
    case NSCVD_BUILD: {
      const build = nscvdBuild(target);
      if (name === "requestsOnly") return nscvdBoolean(build.requestsOnly);
      if (name === "requests") { const value = nscvdTagged(NSCVD_REQUESTS); value.requests = build.requests; return value; }
      if (name === "ranges") { const value = nscvdTagged(NSCVD_RANGES); value.ranges = build.ranges; return value; }
      break;
    }
    case NSCVD_NODE: {
      const node = nscvdNode(target);
      if (name === "gap") return node.gap === undefined ? nscvdUndefinedValue : nscvdNum(node.gap);
      if (name === "end") return nscvdNum(node.end);
      break;
    }
  }
  throw new Error("unsupported development view field " + name);
}
function nscvdIndex(target: NscvdValue, index: NscvdValue): NscvdValue {
  const i = nscvdNumber(index);
  if (target.t === NSCVD_NODES) { const node = target.nodes[i]; return node === undefined ? nscvdUndefinedValue : nscvdNodeValue(node); }
  if (target.t === NSCVD_RANGES) { const range = target.ranges[i]; return range === undefined ? nscvdUndefinedValue : nscvdRangeValue(range); }
  throw new Error("unsupported development view index");
}
function nscvdEquals(left: NscvdValue, right: NscvdValue): boolean {
  if (left.t !== right.t) return false;
  switch (left.t) {
    case NSCVD_UNDEFINED: case NSCVD_NULL: return true;
    case NSCVD_NUMBER: return left.n === right.n;
    case NSCVD_STRING: return left.s === right.s;
    case NSCVD_BOOL: return left.b === right.b;
  }
  throw new Error("unsupported development view comparison");
}
function nscvdBinary(op: string, left: NscvdValue, right: NscvdValue): NscvdValue {
  switch (op) {
    case "===": return nscvdBoolean(nscvdEquals(left, right));
    case "!==": return nscvdBoolean(!nscvdEquals(left, right));
    case "+":
      if (left.t === NSCVD_STRING && right.t === NSCVD_STRING) return nscvdStr(left.s + right.s);
      return nscvdNum(nscvdNumber(left) + nscvdNumber(right));
    case "-": return nscvdNum(nscvdNumber(left) - nscvdNumber(right));
    case "*": return nscvdNum(nscvdNumber(left) * nscvdNumber(right));
    case "/": return nscvdNum(nscvdNumber(left) / nscvdNumber(right));
    case "<": return nscvdBoolean(nscvdNumber(left) < nscvdNumber(right));
    case "<=": return nscvdBoolean(nscvdNumber(left) <= nscvdNumber(right));
    case ">": return nscvdBoolean(nscvdNumber(left) > nscvdNumber(right));
    case ">=": return nscvdBoolean(nscvdNumber(left) >= nscvdNumber(right));
  }
  throw new Error("unsupported development view operator " + op);
}
function nscvdObject(e: NscvdExpr, scope: NscvdScope): NscvdValue {
  const values: NscvdValue[] = [];
  for (const arg of e.args) values.push(nscvdEval(arg, scope));
  switch (e.t) {
    case "node": {
      const node: NscViewNode = { end: 0, kind: "", text: "" };
      for (let i = 0; i < e.keys.length; i++) nscvdSetNode(node, e.keys[i]!, values[i]!);
      return nscvdNodeValue(node);
    }
    case "span": {
      const span: NscViewSpan = { text: "" };
      for (let i = 0; i < e.keys.length; i++) nscvdSetSpan(span, e.keys[i]!, values[i]!);
      const value = nscvdTagged(NSCVD_SPAN); value.span = span; return value;
    }
    case "context_item": {
      const item: NscContextMenuItem = { label: "", enabled: false, separator: false };
      for (let i = 0; i < e.keys.length; i++) nscvdSetContextItem(item, e.keys[i]!, values[i]!);
      const value = nscvdTagged(NSCVD_CONTEXT_ITEM); value.item = item; return value;
    }
    case "chart_series": {
      const series: NscChartSeries = { kind: "", values: [], color: "", fill: false, label: [] };
      for (let i = 0; i < e.keys.length; i++) nscvdSetSeries(series, e.keys[i]!, values[i]!);
      const value = nscvdTagged(NSCVD_CHART_SERIES); value.series = series; return value;
    }
    case "component_text": {
      const text: NscComponentText = { text: "" };
      for (let i = 0; i < e.keys.length; i++) nscvdSetComponentText(text, e.keys[i]!, values[i]!);
      const value = nscvdTagged(NSCVD_COMPONENT_TEXT); value.componentText = text; return value;
    }
    case "timeline_item": {
      const empty: NscComponentText = { text: "" };
      const item: NscTimelineItem = { root: { end: 0, kind: "", text: "" }, title: empty, description: empty, meta: empty, indicator: empty, icon: "", variant: "", connector: false };
      for (let i = 0; i < e.keys.length; i++) nscvdSetTimelineItem(item, e.keys[i]!, values[i]!);
      const value = nscvdTagged(NSCVD_TIMELINE_ITEM); value.timeline = item; return value;
    }
    case "virtual_request": {
      const request: NscVirtualRequest = { id: "", itemCount: 0, itemExtent: 0, gap: 0, overscan: 0, viewportFallback: 0, indexBase: 0, trailing: false, estimateHelper: -1 };
      for (let i = 0; i < e.keys.length; i++) nscvdSetRequest(request, e.keys[i]!, values[i]!);
      const value = nscvdTagged(NSCVD_VIRTUAL_REQUEST); value.request = request; return value;
    }
    case "msg": return nscvdNumsValue(nscvdPackMsg(e.s, e.keys, values));
  }
  throw new Error("unsupported development view record " + e.t);
}
function nscvdEval(e: NscvdExpr, scope: NscvdScope): NscvdValue {
  switch (e.k) {
    case 0: return nscvdNum(e.n);
    case 1: return nscvdStr(e.s);
    case 2: return nscvdBoolean(e.n !== 0);
    case 3: return nscvdUndefinedValue;
    case 4: return nscvdTagged(NSCVD_NULL);
    case 5: return nscvdLookup(scope, e.s);
    case 6: return nscvdField(nscvdEval(e.a!, scope), e.s);
    case 7: return nscvdIndex(nscvdEval(e.a!, scope), nscvdEval(e.b!, scope));
    case 8: {
      const value = nscvdEval(e.a!, scope);
      if (value.t === NSCVD_UNDEFINED || value.t === NSCVD_NULL) throw new Error("development view value is missing");
      return value;
    }
    case 9: return nscvdEval(e.a!, scope);
    case 10: return nscvdNum(nscvdLength(nscvdEval(e.a!, scope)));
    case 11: {
      const args: NscvdValue[] = [];
      for (const arg of e.args) args.push(nscvdEval(arg, scope));
      return nscvdCall(e.s, args);
    }
    case 12: {
      if (e.s === "&&") { const left = nscvdEval(e.a!, scope); return nscvdBool(left) ? nscvdBoolean(nscvdBool(nscvdEval(e.b!, scope))) : left; }
      if (e.s === "||") { const left = nscvdEval(e.a!, scope); return nscvdBool(left) ? left : nscvdBoolean(nscvdBool(nscvdEval(e.b!, scope))); }
      return nscvdBinary(e.s, nscvdEval(e.a!, scope), nscvdEval(e.b!, scope));
    }
    case 13: {
      const operand = nscvdEval(e.a!, scope);
      return e.n === 0 ? nscvdBoolean(!nscvdBool(operand)) : nscvdNum(-nscvdNumber(operand));
    }
    case 14: return nscvdBool(nscvdEval(e.a!, scope)) ? nscvdEval(e.b!, scope) : nscvdEval(e.c!, scope);
    case 15: {
      const left = nscvdEval(e.a!, scope);
      return left.t === NSCVD_UNDEFINED || left.t === NSCVD_NULL ? nscvdEval(e.b!, scope) : left;
    }
    case 16: return nscvdObject(e, scope);
    case 17: {
      const value = nscvdTagged(NSCVD_LIST);
      for (const item of e.args) value.list.push(nscvdEval(item, scope));
      return value;
    }
    case 18: return nscvdBytesValue(new TextEncoder().encode(nscvdString(nscvdEval(e.a!, scope))));
    case 19: return nscvdStr(new TextDecoder().decode(nscvdBytes(nscvdEval(e.a!, scope))));
    case 20: {
      const value = nscvdEval(e.a!, scope);
      if (value.t === NSCVD_NUMBER) return nscvdStr(String(value.n));
      if (value.t === NSCVD_BOOL) return nscvdStr(String(value.b));
      return nscvdStr(nscvdString(value));
    }
    case 21: return nscvdNumsValue(Array.from(nscvdBytes(nscvdEval(e.a!, scope))));
    case 22: return nscvdEval(e.a!, scope);
    case 23: {
      const value = nscvdEval(e.a!, scope), out = nscvdTagged(NSCVD_LIST);
      if (e.n === 1) for (const item of nscvdByteParts(value)) out.list.push(nscvdNumsValue(nscvTextBytes([item])));
      else for (const item of value.strs) out.list.push(nscvdNumsValue(nscvTextBytes([new TextEncoder().encode(item)])));
      return out;
    }
    case 24: {
      const bytes = nscvdBytes(nscvdEval(e.a!, scope));
      return nscvdNum(new DataView(bytes.buffer).getFloat32(e.n, true));
    }
    case 25: return nscvdBytesValue(new Uint8Array(0));
  }
  throw new Error("unknown development view expression");
}
function nscvdAssign(target: NscvdExpr, value: NscvdValue, scope: NscvdScope): void {
  if (target.k !== 6) throw new Error("unsupported development view assignment");
  const owner = nscvdEval(target.a!, scope);
  nscvdSetNode(nscvdNode(owner), target.s, value);
}
function nscvdRun(statements: readonly NscvdStmt[], scope: NscvdScope): void {
  for (const st of statements) {
    switch (st.k) {
      case 0: scope.set(st.s, nscvdEval(st.a!, scope)); break;
      case 1: nscvdEval(st.a!, scope); break;
      case 2: nscvdAssign(st.a!, nscvdEval(st.b!, scope), scope); break;
      case 3: {
        const target = nscvdEval(st.a!, scope), value = nscvdEval(st.b!, scope);
        if (target.t === NSCVD_NODES) target.nodes.push(nscvdNode(value));
        else if (target.t === NSCVD_LIST) target.list.push(value);
        else throw new Error("unsupported development view push");
        break;
      }
      case 4:
        if (nscvdBool(nscvdEval(st.a!, scope))) nscvdRun(st.body, scope);
        else if (st.otherwise !== null) nscvdRun(st.otherwise, scope);
        break;
      case 5: for (const item of nscvdItems(nscvdEval(st.a!, scope))) { scope.set(st.s, item); nscvdRun(st.body, scope); } break;
      case 6: if (nscvdBool(nscvdEval(st.a!, scope))) throw new Error(st.s); break;
    }
  }
}

// ------------------------------------------------------------ builders

function nscvdCall(fn: string, args: NscvdValue[]): NscvdValue {
  const arg = (index: number): NscvdValue => { const value = args[index]; if (value === undefined) throw new Error("missing development view argument"); return value; };
  switch (fn) {
    case "nscvTextBytes": return nscvdNumsValue(nscvTextBytes(nscvdByteParts(arg(0))));
    case "nscvInteger": return nscvdNum(nscvInteger(nscvdNumber(arg(0))));
    case "nscvChartGrid": return nscvdNum(nscvChartGrid(nscvdNumber(arg(0))));
    case "nscvChartWord": return nscvdNum(nscvChartWord(nscvdNumber(arg(0))));
    case "nscvChartWords": return nscvdNumsValue(nscvChartWords(nscvdNumbers(arg(0))));
    case "nscvGridCount": return nscvdNum(nscvGridCount(nscvdNumber(arg(0))));
    case "nscvResizeDuration": return nscvdNum(nscvResizeDuration(nscvdNumber(arg(0))));
    case "nscvPtyKey": return nscvdNum(nscvPtyKey(nscvdNumber(arg(0))));
    case "nscvScrollback": return nscvdNum(nscvScrollback(nscvdNumber(arg(0))));
    case "nscvTreeLevel": return nscvdNum(nscvTreeLevel(nscvdNumber(arg(0))));
    case "nscvTooltipDelay": return nscvdNum(nscvTooltipDelay(nscvdNumber(arg(0))));
    case "nscvSpanScale": return nscvdNum(nscvSpanScale(nscvdNumber(arg(0))));
    case "nscvVariant": return nscvdStr(nscvVariant(nscvdString(arg(0))));
    case "nscvCompositionRequest": {
      const n: number[] = [];
      for (let i = 0; i < 8; i++) n.push(nscvdNumber(arg(i)));
      return nscvdBytesValue(nscvCompositionRequest(n[0]!, n[1]!, n[2]!, n[3]!, n[4]!, n[5]!, n[6]!, n[7]!));
    }
    case "nscvImageIdentity": { const value = nscvdTagged(NSCVD_IMAGE_ID); value.image = nscvImageIdentity(nscvdBytes(arg(0))); return value; }
    case "nscvPush": nscvPush(nscvdNodes(arg(0)), nscvdNode(arg(1))); return nscvdUndefinedValue;
    case "nscvCodeEditor": nscvCodeEditor(nscvdNode(arg(0)), nscvdBool(arg(1)), nscvdBytes(arg(2)), nscvdBytes(arg(3))); return nscvdUndefinedValue;
    case "nscvTabs": nscvTabs(nscvdNodes(arg(0)), nscvdNumber(arg(1))); return nscvdUndefinedValue;
    case "nscvSplit": nscvSplit(nscvdNodes(arg(0)), nscvdNumber(arg(1))); return nscvdUndefinedValue;
    case "nscvLoopKeys": {
      const base = arg(2);
      nscvLoopKeys(nscvdNodes(arg(0)), nscvdNumber(arg(1)), base.t === NSCVD_NUMBER ? base.n : nscvdString(base));
      return nscvdUndefinedValue;
    }
    case "nscvLoopByteKeys": nscvLoopByteKeys(nscvdNodes(arg(0)), nscvdNumber(arg(1)), nscvdBytes(arg(2))); return nscvdUndefinedValue;
    case "nscvChart": nscvChart(nscvdNodes(arg(0)), nscvdNode(arg(1)), nscvdSeriesList(arg(2)), nscvdNumberLists(arg(3))); return nscvdUndefinedValue;
    case "nscvStepper": nscvStepper(nscvdNodes(arg(0)), nscvdNode(arg(1)), nscvdNumber(arg(2)), nscvdComponentTexts(arg(3))); return nscvdUndefinedValue;
    case "nscvTimelineItem": {
      const options = arg(1).timeline;
      if (options === null) throw new Error("development view expected a timeline item");
      nscvTimelineItem(nscvdNodes(arg(0)), options);
      return nscvdUndefinedValue;
    }
    case "nscvVideoElement": {
      const video = arg(2).video;
      if (video === null) throw new Error("development view expected video state");
      nscvVideoElement(nscvdNodes(arg(0)), nscvdNode(arg(1)), video, nscvdString(arg(3)), nscvdBool(arg(4)), nscvdBool(arg(5)), nscvdBool(arg(6)), nscvdBool(arg(7)));
      return nscvdUndefinedValue;
    }
    case "nscvMarkdownRecipe": case "nscvMarkdownRecipeWords": {
      const issue = arg(2), source = nscvdBytes(arg(0)), expanded = nscvdBooleans(arg(1));
      const link = issue.t === NSCVD_NULL ? null : nscvdBytes(issue);
      if (fn === "nscvMarkdownRecipe") return nscvdNumsValue(nscvMarkdownRecipe(source, expanded, link, nscvdMarkdownImages(arg(3))));
      return nscvdNumsValue(nscvMarkdownRecipeWords(source, expanded, link, nscvdMarkdownImageWords(arg(3))));
    }
    case "nscvVirtualRequest": {
      const requests = arg(0), request = arg(1).request;
      if (requests.t !== NSCVD_REQUESTS || request === null) throw new Error("development view expected a virtual window request");
      return nscvdNum(nscvVirtualRequest(requests.requests, request));
    }
    case "nscvVirtualConsume": nscvVirtualConsume(nscvdBuild(arg(0)), nscvdNumber(arg(1))); return nscvdUndefinedValue;
    case "nscvVirtualRow": nscvVirtualRow(nscvdNodes(arg(0)), nscvdNumber(arg(1))); return nscvdUndefinedValue;
    case "nscvVirtualList": nscvVirtualList(nscvdNodes(arg(0)), nscvdNumber(arg(1)), nscvdRange(arg(2))); return nscvdUndefinedValue;
    case "nscvSourceMark": {
      const sources = arg(0);
      if (sources.t !== NSCVD_NUMS) throw new Error("development view expected the source marks");
      nscvSourceMark(sources.nums, nscvdNumber(arg(1)), nscvdNumber(arg(2)), nscvdNumber(arg(3)));
      return nscvdUndefinedValue;
    }
  }
  return nscvdHelper(fn, args);
}

// ------------------------------------------------------------ views

let nscvdViews: NscvdView[] = [];

/** Run one view with the same prologue and epilogue as a compiled view. */
function nscvdRunView(view: NscvdView, video: NscVideoPlaybackState, virtual: NscVirtualBuild | undefined): Uint8Array {
  const nscvNodes: NscViewNode[] = [];
  const scope: NscvdScope = new Map();
  const nodes = nscvdTagged(NSCVD_NODES); nodes.nodes = nscvNodes; scope.set("nscvNodes", nodes);
  const videoValue = nscvdTagged(NSCVD_VIDEO); videoValue.video = video; scope.set("nscvVideo", videoValue);
  const sources = nscvdNumsValue([]); scope.set("nscvSources", sources);
  if (virtual === undefined) scope.set("nscvVirtual", nscvdUndefinedValue);
  else { const build = nscvdTagged(NSCVD_BUILD); build.build = virtual; scope.set("nscvVirtual", build); }
  nscvdRun(view.body, scope);
  if (virtual?.requestsOnly) return new TextEncoder().encode(JSON.stringify({ format: 1, requests: virtual.requests }));
  if (virtual !== undefined && (virtual.requests.length !== virtual.ranges.length || virtual.consumed.length !== virtual.requests.length)) throw new Error("virtual window context count mismatch");
  if (nscvNodes.length === 0 || nscvNodes[0]!.end !== nscvNodes.length) throw new Error("compiled view requires one rendered root");
  // A program compiled with source attribution answers as the development
  // compiled view does: records, their sources and the source table.
  if (view.attribution.length > 0) return new TextEncoder().encode('{"format":2,"nodes":' + JSON.stringify(nscvNodes) + ',"sources":' + JSON.stringify(sources.nums) + ',' + view.attribution + '}');
  return new TextEncoder().encode(JSON.stringify({ format: 2, nodes: nscvNodes }));
}

function nscvdLabelEquals(label: Uint8Array, expected: string): boolean {
  const bytes = new TextEncoder().encode(expected);
  if (label.length !== bytes.length) return false;
  for (let i = 0; i < bytes.length; i++) if (label[i] !== bytes[i]) return false;
  return true;
}

/** The active program's view for `label` (empty for the main view). */
function nscvdView(label: Uint8Array, video: NscVideoPlaybackState, virtual: NscVirtualBuild | undefined): Uint8Array {
  if (label.length === 0) return nscvdRunView(nscvdViews[0]!, video, virtual);
  for (let i = 1; i < nscvdViews.length; i++) if (nscvdLabelEquals(label, nscvdViews[i]!.label)) return nscvdRunView(nscvdViews[i]!, video, virtual);
  throw new Error(virtual === undefined ? "unknown compiled window view label" : "unknown compiled virtual window label");
}

/** Activate a program. Returns an empty string, or why the program was refused. */
function nscvdPrepare(bytes: Uint8Array): string {
  try {
    nscvdViews = nscvdDecodeProgram(bytes);
    return "";
  } catch (error) {
    return error instanceof Error ? error.message : "invalid development view program";
  }
}

function nscvdActive(): boolean { return nscvdViews.length > 0; }
function nscvdReset(): void { nscvdViews = []; }
