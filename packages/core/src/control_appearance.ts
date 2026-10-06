/** Portable control appearance, compiled beside the model and view. The wire
 * carries exact f32 bytes and explicit optional presence. Selected colors are
 * copied as bytes; arithmetic rounds at every native f32 stage. No token or
 * render-resource pointer crosses this boundary.
 */
const nscvAppearanceKinds = ["stack", "row", "column", "grid", "data_grid", "table", "scroll_view", "list", "breadcrumb", "button_group", "pagination", "radio_group", "tabs", "toggle_group", "accordion", "bubble", "resizable", "alert", "card", "dialog", "drawer", "sheet", "panel", "popover", "menu_surface", "dropdown_menu", "text", "icon", "image", "avatar", "badge", "button", "toggle_button", "icon_button", "select", "input", "text_field", "search_field", "combobox", "textarea", "tooltip", "menu_item", "list_item", "data_row", "data_cell", "status_bar", "segmented_control", "checkbox", "radio", "switch_control", "toggle", "slider", "progress", "separator", "skeleton", "spinner", "chart", "split", "split_divider", "tree", "input_group", "media_surface", "terminal"];
const nscvAppearanceTables = ["button_default", "button_primary", "button_secondary", "button_outline", "button_ghost", "button_destructive", "toggle_button", "accordion", "alert", "bubble", "card", "dialog", "drawer", "sheet", "select", "input", "text_field", "search_field", "combobox", "textarea", "list_item", "menu_item", "data_cell", "tabs", "segmented_control", "button_group", "checkbox", "radio", "switch_control", "slider", "progress", "scrollbar", "panel", "resizable", "popover", "menu_surface", "dropdown_menu", "tooltip", "avatar", "badge", "separator", "skeleton", "spinner"];
type NscAppearanceColor = Uint8Array;
interface NscAppearanceVisual { colors: (NscAppearanceColor | null)[]; radius: number | null; stroke: number | null }
interface NscAppearanceContext {
  variant: number; size: number; disabled: boolean; pressed: boolean; selected: boolean; hovered: boolean; toggle: boolean; detached: boolean;
  visual: NscAppearanceVisual; style: (NscAppearanceColor | null)[]; radius: number | null; stroke: number | null;
  palette: NscAppearanceColor[]; alpha: number[]; geometry: number[]; disabledBorder: NscAppearanceColor | null; fallback: NscAppearanceColor; scalar: number; numeric: number;
}
function nscvAppearanceTable(name: string): number { return nscvAppearanceTables.indexOf(name); }
function nscvAppearanceVisual(wire: DataView, bytes: Uint8Array, at: number): NscAppearanceVisual {
  const mask = wire.getUint32(at, true);
  if (mask > 2047) throw new Error("invalid control visual presence");
  const colors: (NscAppearanceColor | null)[] = [];
  for (let i = 0; i < 9; i++) colors.push((mask & (1 << i)) !== 0 ? bytes.subarray(at + 4 + i * 16, at + 20 + i * 16) : null);
  return { colors, radius: (mask & 512) !== 0 ? wire.getFloat32(at + 148, true) : null, stroke: (mask & 1024) !== 0 ? wire.getFloat32(at + 152, true) : null };
}
function nscvAppearanceWriteVisual(visual: NscAppearanceVisual): Uint8Array {
  const out = new Uint8Array(156), wire = new DataView(out.buffer); let mask = 0;
  for (let i = 0; i < 9; i++) { const color = visual.colors[i] ?? null; if (color !== null) { mask |= 1 << i; out.set(color, 4 + i * 16); } }
  if (visual.radius !== null) { mask |= 512; wire.setFloat32(148, visual.radius, true); }
  if (visual.stroke !== null) { mask |= 1024; wire.setFloat32(152, visual.stroke, true); }
  wire.setUint32(0, mask, true); return out;
}
function nscvAppearanceClamp(value: number, numeric = 0): number { return Number.isNaN(value) ? 1 : nscvAppearanceNonNegative(Math.min(value, 1), numeric); }
function nscvAppearanceNonNegative(value: number, numeric = 0): number { if (Number.isNaN(value)) return 0; if (value === 0 && 1 / value < 0 && (numeric & 4) !== 0) return value; return Math.max(0, value); }
function nscvAppearanceColorValue(color: NscAppearanceColor, channel: number): number { return new DataView(color.buffer, color.byteOffset, 16).getFloat32(channel * 4, true); }
function nscvAppearanceAlpha(color: NscAppearanceColor, alpha: number, numeric = 0): NscAppearanceColor {
  const out = new Uint8Array(color); new DataView(out.buffer).setFloat32(12, nscvAppearanceClamp(alpha, numeric), true); return out;
}
function nscvAppearanceWash(color: NscAppearanceColor, disabled: boolean, alpha: number, numeric = 0): NscAppearanceColor {
  return disabled ? nscvAppearanceAlpha(color, Math.fround(alpha * nscvAppearanceColorValue(color, 3)), numeric) : color;
}
function nscvAppearanceTransparent(): NscAppearanceColor { return new Uint8Array(16); }
function nscvAppearanceComposite(ink: NscAppearanceColor, page: NscAppearanceColor, alpha: number, numeric = 0): NscAppearanceColor {
  const f = Math.fround;
  const ia = f(nscvAppearanceClamp(alpha, numeric) * nscvAppearanceClamp(nscvAppearanceColorValue(ink, 3), numeric));
  const pa = nscvAppearanceClamp(nscvAppearanceColorValue(page, 3), numeric);
  const weight = f(pa * f(1 - ia)), outputAlpha = f(ia + weight);
  if (outputAlpha <= 0) return nscvAppearanceTransparent();
  const out = new Uint8Array(16), wire = new DataView(out.buffer);
  for (let i = 0; i < 3; i++) wire.setFloat32(i * 4, f(f(f(nscvAppearanceColorValue(ink, i) * ia) + f(nscvAppearanceColorValue(page, i) * weight)) / outputAlpha), true);
  wire.setFloat32(12, outputAlpha, true); return out;
}
function nscvAppearanceBackground(c: NscAppearanceContext, fallback: NscAppearanceColor): NscAppearanceColor { return c.style[0] ?? fallback; }
function nscvAppearanceAccent(c: NscAppearanceContext, fallback: NscAppearanceColor): NscAppearanceColor { return c.style[2] ?? fallback; }
function nscvAppearanceForeground(c: NscAppearanceContext, fallback: NscAppearanceColor, accent: boolean): NscAppearanceColor {
  return nscvAppearanceWash(c.style[accent ? 3 : 1] ?? fallback, c.disabled, c.alpha[0]!, c.numeric);
}
function nscvAppearanceState(v: NscAppearanceVisual, active: boolean, hovered: boolean, fallback: NscAppearanceColor): NscAppearanceColor {
  return active ? v.colors[2] ?? v.colors[1] ?? v.colors[0] ?? fallback : hovered ? v.colors[1] ?? v.colors[0] ?? fallback : v.colors[0] ?? fallback;
}
function nscvAppearanceControlState(c: NscAppearanceContext, fallback: NscAppearanceColor): NscAppearanceColor {
  return c.pressed && c.visual.colors[3] !== null ? c.visual.colors[3]! : nscvAppearanceState(c.visual, c.pressed || c.selected, c.hovered, fallback);
}
function nscvAppearanceRest(c: NscAppearanceContext): NscAppearanceContext { return { ...c, disabled: false, pressed: false, hovered: false }; }
function nscvAppearanceButtonFill(c: NscAppearanceContext): NscAppearanceColor {
  const v = c.visual.colors, p = c.palette;
  if (c.disabled) return v[4] ?? nscvAppearanceWash(nscvAppearanceButtonFill(nscvAppearanceRest(c)), true, c.alpha[0]!, c.numeric);
  if (c.detached) {
    if (c.pressed) return nscvAppearanceAccent(c, v[3] ?? v[2] ?? p[2]!);
    if (c.selected) return nscvAppearanceAccent(c, v[2] ?? p[2]!);
    return nscvAppearanceBackground(c, c.hovered ? v[1] ?? v[0] ?? p[1]! : v[0] ?? p[1]!);
  }
  if (c.variant === 0) return c.pressed || c.selected ? nscvAppearanceAccent(c, v[2] ?? p[3]!) : nscvAppearanceBackground(c, c.hovered ? v[1] ?? p[1]! : v[0] ?? p[0]!);
  if (c.variant === 1) {
    const base = p[3]!;
    const color = c.pressed ? v[3] ?? v[2] ?? v[1] ?? v[0] ?? nscvAppearanceAlpha(base, Math.fround(c.alpha[2]! * nscvAppearanceColorValue(base, 3)), c.numeric)
      : c.selected ? v[2] ?? v[1] ?? v[0] ?? base
      : c.hovered ? v[1] ?? v[0] ?? nscvAppearanceAlpha(base, Math.fround(c.alpha[1]! * nscvAppearanceColorValue(base, 3)), c.numeric) : v[0] ?? base;
    return nscvAppearanceAccent(c, color);
  }
  if (c.variant === 5) {
    const base = p[5]!;
    const color = c.pressed ? v[3] ?? v[2] ?? v[1] ?? nscvAppearanceAlpha(base, c.alpha[6]!, c.numeric)
      : c.selected ? v[0] ?? nscvAppearanceAlpha(base, c.alpha[4]!, c.numeric)
      : c.hovered ? v[1] ?? nscvAppearanceAlpha(base, c.alpha[5]!, c.numeric) : v[0] ?? nscvAppearanceAlpha(base, c.alpha[4]!, c.numeric);
    return nscvAppearanceAccent(c, color);
  }
  if (c.variant === 2) {
    const active = c.pressed || c.selected;
    const fallback = active ? p[2]! : c.hovered ? nscvAppearanceAlpha(p[1]!, Math.fround(c.alpha[3]! * nscvAppearanceColorValue(p[1]!, 3)), c.numeric) : p[1]!;
    return nscvAppearanceAccent(c, nscvAppearanceState(c.visual, active, c.hovered, fallback));
  }
  const quiet = c.pressed ? v[3] ?? v[2] ?? v[1] ?? p[2]!
    : c.selected && c.toggle ? v[2] ?? v[1] ?? p[1]! : c.hovered ? v[1] ?? p[1]! : v[0] ?? nscvAppearanceTransparent();
  return nscvAppearanceBackground(c, quiet);
}
function nscvAppearanceButtonText(c: NscAppearanceContext): NscAppearanceColor {
  const v = c.visual.colors, p = c.palette;
  if (c.disabled) {
    if (v[5] !== null) return v[5]!;
    const rest = nscvAppearanceButtonText(nscvAppearanceRest(c));
    return c.variant === 1 ? nscvAppearanceComposite(rest, p[7]!, c.alpha[0]!, c.numeric) : nscvAppearanceWash(rest, true, c.alpha[0]!, c.numeric);
  }
  if (c.detached) return c.pressed || c.selected ? nscvAppearanceForeground(c, v[7] ?? p[4]!, true) : nscvAppearanceForeground(c, v[6] ?? p[6]!, false);
  const active = c.pressed || c.selected;
  return c.variant === 1 || c.variant === 5 || c.variant === 0 && active
    ? nscvAppearanceForeground(c, v[6] ?? p[c.variant === 5 ? 5 : 4]!, true)
    : nscvAppearanceForeground(c, v[6] ?? p[6]!, false);
}
function nscvAppearanceButtonBorder(c: NscAppearanceContext): NscAppearanceColor {
  const v = c.visual.colors, border = c.style[4];
  let color: NscAppearanceColor;
  if (border !== null) color = border!;
  else if (c.detached) color = v[8] ?? nscvAppearanceTransparent();
  else if (c.variant === 1) color = nscvAppearanceAccent(c, v[8] ?? c.palette[3]!);
  else if (c.variant === 5) color = nscvAppearanceAccent(c, v[8] ?? nscvAppearanceTransparent());
  else if (c.variant === 4) color = v[8] ?? nscvAppearanceTransparent();
  else if (c.variant === 2) color = nscvAppearanceAccent(c, v[8] ?? c.fallback);
  else color = v[8] ?? c.fallback;
  if (c.disabled && border === null) {
    if ((c.variant === 0 || c.variant === 2 || c.variant === 3) && c.disabledBorder !== null) return c.disabledBorder;
    if (c.variant === 1 && v[8] === null) return nscvAppearanceTransparent();
  }
  return nscvAppearanceWash(color, c.disabled, c.alpha[0]!, c.numeric);
}
function nscvAppearanceBadgeBackground(c: NscAppearanceContext): NscAppearanceColor {
  if (c.disabled) return c.visual.colors[4] ?? nscvAppearanceWash(nscvAppearanceBadgeBackground(nscvAppearanceRest(c)), true, c.alpha[0]!, c.numeric);
  const base = c.variant < 2 ? c.palette[3]! : c.variant === 2 ? c.palette[1]!
    : c.variant === 5 ? nscvAppearanceAlpha(c.palette[5]!, c.alpha[7]!, c.numeric) : c.hovered || c.pressed ? c.palette[1]! : nscvAppearanceTransparent();
  const color = nscvAppearanceControlState(c, base);
  return c.variant === 3 || c.variant === 4 ? nscvAppearanceBackground(c, color) : nscvAppearanceAccent(c, color);
}
function nscvAppearanceBadgeText(c: NscAppearanceContext): NscAppearanceColor {
  if (c.disabled) return c.visual.colors[5] ?? nscvAppearanceWash(nscvAppearanceBadgeText(nscvAppearanceRest(c)), true, c.alpha[0]!, c.numeric);
  return nscvAppearanceForeground(c, c.visual.colors[6] ?? c.palette[c.variant < 2 ? 4 : c.variant === 5 ? 5 : 6]!, c.variant < 2 || c.variant === 5);
}
function nscvAppearanceSized(c: NscAppearanceContext, fallback: number): number { return c.size === 1 ? nscvAppearanceNonNegative(Math.fround(fallback - 2), c.numeric) : c.size === 2 ? Math.fround(fallback + 2) : fallback; }
function nscvControlAppearance(request: Uint8Array): Uint8Array {
  if (request.length < 8 || request[0] !== 16 || request[1]! > 38 || request[3]! >= nscvAppearanceKinds.length || request[4]! > 5 || request[5]! > 5 || request[6]! > 31 || request[7]! > 3) throw new Error("invalid control appearance header");
  const op = request[1]!, family = request[2]!, kind = nscvAppearanceKinds[request[3]!]!, variant = request[4]!, detached = request[7] === 3;
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  if (op === 0) {
    if (request.length !== 8 || family > 6) throw new Error("invalid control family request");
    let primary = "", fallback = "";
    if (family === 0) {
      if (detached) primary = "button_group";
      else { primary = ["button_default", "button_primary", "button_secondary", "button_outline", "button_ghost", "button_destructive"][variant]!; if (kind === "toggle_button" || kind === "toggle") { fallback = primary; primary = "toggle_button"; } }
    } else if (family === 1) {
      if (kind === "input") { primary = "input"; fallback = "text_field"; }
      else if (kind === "combobox") { primary = "combobox"; fallback = "search_field"; }
      else primary = kind === "search_field" ? "search_field" : kind === "textarea" || kind === "input_group" ? "textarea" : "text_field";
    } else if (family === 2) {
      if (["segmented_control", "checkbox", "radio", "switch_control", "slider", "progress"].includes(kind)) primary = kind;
    } else if (family === 3) {
      if (["accordion", "alert", "bubble", "card", "resizable"].includes(kind)) { primary = kind; fallback = "panel"; }
      else if (["dialog", "drawer", "sheet"].includes(kind)) { primary = kind; fallback = "popover"; }
      else if (kind === "dropdown_menu") { primary = kind; fallback = "menu_surface"; }
      else if (["panel", "popover", "menu_surface", "tooltip"].includes(kind)) primary = kind;
    } else if (family === 4) {
      if (["avatar", "badge", "separator", "skeleton", "spinner"].includes(kind)) primary = kind;
    } else if (family === 5) {
      if (kind === "data_cell" || kind === "menu_item") { primary = kind; fallback = "list_item"; }
      else if (kind === "list_item") primary = kind;
    } else { primary = "select"; fallback = "button_outline"; }
    const out = new Uint8Array(4); out[0] = primary === "" ? 255 : nscvAppearanceTable(primary); out[1] = fallback === "" ? 255 : nscvAppearanceTable(fallback); out[2] = fallback !== "" ? 1 : 0; return out;
  }
  if (op === 1) {
    if (request.length !== 320) throw new Error("invalid control fallback request");
    const a = nscvAppearanceVisual(wire, request, 8), b = nscvAppearanceVisual(wire, request, 164);
    const colors: (NscAppearanceColor | null)[] = []; for (let i = 0; i < 9; i++) colors.push(i === 7 ? null : a.colors[i] ?? b.colors[i] ?? null);
    return nscvAppearanceWriteVisual({ colors, radius: a.radius ?? b.radius, stroke: a.stroke ?? b.stroke });
  }
  if (request.length !== 496 || family !== 0) throw new Error("invalid control appearance context");
  const flags = request[6]!, styleMask = wire.getUint32(164, true); if (styleMask > 255 || wire.getUint32(452, true) > 1) throw new Error("invalid control style presence");
  const style: (NscAppearanceColor | null)[] = []; for (let i = 0; i < 6; i++) style.push((styleMask & (1 << i)) !== 0 ? request.subarray(168 + i * 16, 184 + i * 16) : null);
  const palette: NscAppearanceColor[] = []; for (let i = 0; i < 8; i++) palette.push(request.subarray(272 + i * 16, 288 + i * 16));
  const alpha: number[] = [], geometry: number[] = []; for (let i = 0; i < 9; i++) alpha.push(wire.getFloat32(400 + i * 4, true)); for (let i = 0; i < 4; i++) geometry.push(wire.getFloat32(436 + i * 4, true));
  const c: NscAppearanceContext = { variant, size: request[5]!, disabled: (flags & 1) !== 0, pressed: (flags & 2) !== 0, selected: (flags & 4) !== 0, hovered: (flags & 8) !== 0 && (flags & 16) === 0, toggle: kind === "toggle_button" || kind === "toggle", detached,
    visual: nscvAppearanceVisual(wire, request, 8), style, radius: (styleMask & 64) !== 0 ? wire.getFloat32(264, true) : null, stroke: (styleMask & 128) !== 0 ? wire.getFloat32(268, true) : null,
    palette, alpha, geometry, disabledBorder: wire.getUint32(452, true) !== 0 ? request.subarray(456, 472) : null, fallback: request.subarray(472, 488), scalar: wire.getFloat32(488, true), numeric: wire.getUint32(492, true) };
  if (c.numeric > 15) throw new Error("invalid appearance numeric capability");
  const v = c.visual.colors, p = c.palette; let color: NscAppearanceColor;
  if (op === 2) color = nscvAppearanceButtonFill(c);
  else if (op === 3) color = nscvAppearanceButtonText(c);
  else if (op === 4) color = nscvAppearanceButtonBorder(c);
  else if (op === 5) color = nscvAppearanceBadgeBackground(c);
  else if (op === 6) {
    const border = c.style[4] ?? (variant < 2 ? nscvAppearanceAccent(c, v[8] ?? p[3]!) : variant === 5 ? nscvAppearanceAccent(c, v[8] ?? p[5]!) : variant === 2 ? nscvAppearanceAccent(c, v[8] ?? c.fallback) : v[8] ?? c.fallback);
    color = nscvAppearanceWash(border, c.disabled, alpha[0]!, c.numeric);
  } else if (op === 7) color = nscvAppearanceBadgeText(c);
  else if (op === 8) color = c.pressed ? v[3] ?? v[2] ?? v[1] ?? v[0] ?? p[2]! : c.selected ? v[2] ?? v[1] ?? v[0] ?? p[2]! : c.hovered ? v[1] ?? v[0] ?? p[1]! : c.style[0] ?? v[0] ?? nscvAppearanceTransparent();
  else if (op === 9) color = c.style[0] ?? (c.pressed ? v[3] ?? v[2] ?? v[1] ?? p[2]! : c.selected ? v[2] ?? v[1] ?? p[2]! : c.hovered ? v[1] ?? p[1]! : v[0] ?? p[0]!);
  else if (op === 10) color = c.disabled ? v[4] ?? nscvAppearanceWash(nscvAppearanceBackground(c, nscvAppearanceState(c.visual, false, false, p[0]!)), true, alpha[0]!, c.numeric) : nscvAppearanceBackground(c, nscvAppearanceState(c.visual, false, c.hovered, p[0]!));
  else if (op === 11) color = c.style[4] ?? v[8] ?? c.fallback;
  else if (op === 12 || op === 13) color = nscvAppearanceForeground(c, c.fallback, op === 13);
  else if (op === 14) color = nscvAppearanceForeground(c, v[6] ?? p[6]!, false);
  else if (op === 15) color = c.style[2] ?? p[3]!;
  else if (op === 16) color = c.style[3] ?? p[4]!;
  else if (op === 17) color = nscvAppearanceAlpha(c.style[2] ?? p[3]!, alpha[8]!, c.numeric);
  else if (op >= 18 && op <= 26) {
    let value: number;
    if (op === 18) value = nscvAppearanceNonNegative(c.radius ?? nscvAppearanceSized(c, c.scalar), c.numeric);
    else if (op === 19) value = nscvAppearanceNonNegative(c.radius ?? nscvAppearanceSized(c, c.visual.radius ?? c.scalar), c.numeric);
    else if (op === 20) value = nscvAppearanceNonNegative(c.radius ?? c.visual.radius ?? geometry[c.size === 1 ? 0 : 1]!, c.numeric);
    else if (op === 21) value = nscvAppearanceNonNegative(c.radius ?? c.visual.radius ?? c.scalar, c.numeric);
    else if (op === 22) value = nscvAppearanceSized(c, c.scalar);
    else if (op === 23) value = nscvAppearanceNonNegative(c.stroke ?? c.scalar, c.numeric);
    else if (op === 24) value = nscvAppearanceNonNegative(c.stroke ?? c.visual.stroke ?? c.scalar, c.numeric);
    else if (op === 25) value = c.stroke !== null ? nscvAppearanceNonNegative(c.stroke, c.numeric) : c.visual.stroke !== null ? nscvAppearanceNonNegative(c.visual.stroke, c.numeric) : variant === 3 ? geometry[2]! : 0;
    else value = c.stroke !== null ? nscvAppearanceNonNegative(c.stroke, c.numeric) : c.visual.stroke !== null ? nscvAppearanceNonNegative(c.visual.stroke, c.numeric) : c.detached || variant === 4 || variant === 5 ? 0 : geometry[3]!;
    const out = new Uint8Array(4); new DataView(out.buffer).setFloat32(0, value, true); return out;
  } else if (op === 27) color = c.style[5] ?? c.fallback;
  else if (op === 28) color = nscvAppearanceBackground(c, c.fallback);
  else if (op === 29) color = nscvAppearanceAccent(c, c.fallback);
  else if (op === 30) color = c.style[4] ?? c.fallback;
  else if (op === 31) { const out = new Uint8Array(1); out[0] = c.detached ? 1 : 0; return out; }
  else if (op === 32) color = nscvAppearanceState(c.visual, c.selected, c.hovered, c.fallback);
  else if (op === 33) color = c.pressed && v[3] !== null ? v[3]! : nscvAppearanceState(c.visual, c.selected, c.hovered, c.fallback);
  else if (op >= 34 && op <= 36) color = !c.disabled ? c.fallback : op === 34 && v[4] !== null ? v[4]! : op === 35 && v[5] !== null ? v[5]! : nscvAppearanceWash(c.fallback, v[4] === null && v[5] === null, alpha[0]!, c.numeric);
  else if (op === 37) {
    if (variant !== 5) color = c.style[0] ?? (c.pressed ? v[3] ?? v[2] ?? v[1] ?? p[2]! : c.selected ? v[2] ?? v[1] ?? p[2]! : c.hovered ? v[1] ?? p[1]! : v[0] ?? p[0]!);
    else color = nscvAppearanceWash(c.style[0] ?? nscvAppearanceAlpha(c.style[2] ?? p[5]!, alpha[c.pressed ? 6 : c.hovered ? 5 : 4]!, c.numeric), c.disabled, alpha[0]!, c.numeric);
  } else color = nscvAppearanceWash(c.style[4] ?? (variant === 5 ? nscvAppearanceAlpha(c.style[2] ?? p[5]!, 0.5, c.numeric) : v[8] ?? c.fallback), c.disabled, alpha[0]!, c.numeric);
  return new Uint8Array(color);
}
