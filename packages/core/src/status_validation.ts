/** Portable declaration admission. Native supplies bounded copied bytes, f32
 * values and opaque IDs; it owns retained storage and OS capability execution.
 * Oversized cross-row identity lists are compared in bounded copied chunks.
 */
interface NscvStatusField { readonly statusByteAt: number; readonly statusByteCount: number; readonly statusNextAt: number }
interface NscvStatusPresentation { readonly title: NscvStatusField; readonly width: number; readonly opacity: number; readonly font: number; readonly statusNextAt: number }
interface NscvStatusOption { readonly statusIdentity: number; readonly selected: boolean; readonly overflowDuplicate: boolean; readonly label: NscvStatusField; readonly command: NscvStatusField }
interface NscvStatusMetric { readonly primary: NscvStatusField; readonly secondary: NscvStatusField; readonly accessibility: NscvStatusField }
interface NscvStatusChart { readonly statusValueCount: number; readonly minimum: number; readonly maximum: number; readonly values: readonly number[]; readonly leading: NscvStatusField; readonly trailing: NscvStatusField; readonly accessibility: NscvStatusField }
interface NscvStatusRow {
  readonly statusIdentity: number; readonly role: number; readonly separator: boolean; readonly modifiers: number;
  readonly label: NscvStatusField; readonly command: NscvStatusField; readonly detail: NscvStatusField; readonly key: NscvStatusField;
  readonly segmented: boolean; readonly statusOptionCount: number; readonly options: readonly NscvStatusOption[];
  readonly metric: NscvStatusMetric | null; readonly chart: NscvStatusChart | null;
}
function nscvStatusField(input: Uint8Array, at: number, limit: number): NscvStatusField {
  if (at + 4 > input.length) throw new Error("truncated status field length");
  const length = new DataView(input.buffer, input.byteOffset, input.byteLength).getUint32(at, true);
  const next = at + 4 + Math.min(length, limit);
  if (next > input.length) throw new Error("truncated status field bytes");
  return { statusByteAt: at + 4, statusByteCount: length, statusNextAt: next };
}
function nscvStatusFieldError(input: Uint8Array, field: NscvStatusField, limit: number): number {
  if (field.statusByteCount > limit) return 2; // TrayFieldTooLarge precedes NUL validation.
  for (let i = 0; i < field.statusByteCount; i++) if (input[field.statusByteAt + i] === 0) return 1;
  return 0;
}
function nscvStatusCommandError(input: Uint8Array, field: NscvStatusField): number {
  const at = field.statusByteAt, length = field.statusByteCount;
  if (length === 0 || length > 128 || (length === 1 && input[at] === 46) || (length === 2 && input[at] === 46 && input[at + 1] === 46)) return 3;
  for (let i = 0; i < length; i++) {
    const byte = input[at + i]!;
    if (byte === 0 || byte === 47 || byte === 92 || byte === 10 || byte === 13 || byte === 9) return 3;
  }
  return 0;
}
function nscvStatusAscii(input: Uint8Array, field: NscvStatusField, name: string): boolean {
  const literal = new TextEncoder().encode(name);
  if (field.statusByteCount !== literal.length) return false;
  for (let i = 0; i < literal.length; i++) {
    const byte = input[field.statusByteAt + i]!;
    if ((byte >= 65 && byte <= 90 ? byte + 32 : byte) !== literal[i]) return false;
  }
  return true;
}
function nscvStatusShortcut(input: Uint8Array, field: NscvStatusField, modifiers: number): boolean {
  const length = field.statusByteCount;
  if (length === 0 || length > 32) return false;
  if (length === 1) {
    const c = input[field.statusByteAt]!;
    const valid = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c === 61 || c === 45 || c === 44 || c === 46 || c === 47 || c === 59 || c === 39 || c === 91 || c === 93 || c === 92 || c === 96;
    return valid && modifiers !== 0;
  }
  for (const key of ["escape", "enter", "tab", "space", "backspace", "arrowleft", "arrowright", "arrowup", "arrowdown", "delete", "home", "end", "pageup", "pagedown", "insert", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12"]) {
    if (nscvStatusAscii(input, field, key)) return modifiers !== 0 || !(key === "space" || key === "enter" || key === "tab" || key === "backspace");
  }
  return false;
}
function nscvStatusPresentation(input: Uint8Array, at: number): NscvStatusPresentation {
  const title = nscvStatusField(input, at, 64); at = title.statusNextAt;
  if (at + 12 > input.length) throw new Error("truncated status presentation");
  const data = new DataView(input.buffer, input.byteOffset, input.byteLength);
  return { title, width: data.getFloat32(at, true), opacity: data.getFloat32(at + 4, true), font: data.getFloat32(at + 8, true), statusNextAt: at + 12 };
}
function nscvStatusPresentationError(input: Uint8Array, value: NscvStatusPresentation): number {
  const title = nscvStatusFieldError(input, value.title, 64);
  if (title !== 0) return title;
  if (!Number.isFinite(value.width) || value.width < 0 || !Number.isFinite(value.opacity) || value.opacity < 0 || value.opacity > 1 || !Number.isFinite(value.font) || value.font < 0 || value.font > 64) return 1;
  return 0;
}
function nscvStatusMenuError(input: Uint8Array, count: number, rows: readonly NscvStatusRow[]): number {
  if (count > 32) return 1;
  let fallbackCount = 0;
  for (let slot = 0; slot < rows.length; slot++) {
    const row = rows[slot]!;
    for (let field = 0; field < 4; field++) {
      const value = field === 0 ? row.label : field === 1 ? row.command : field === 2 ? row.detail : row.key;
      const error = nscvStatusFieldError(input, value, field === 0 || field === 2 ? 256 : field === 1 ? 128 : 32);
      if (error !== 0) return error;
    }
    if (row.role !== 0 && row.role !== 4 && row.command.statusByteCount > 0) return 1;
    if (row.detail.statusByteCount > 0 && row.role !== 1 && row.role !== 3 && row.role !== 4 && row.role !== 5) return 1;
    if (row.separator && (row.detail.statusByteCount > 0 || row.role !== 0)) return 1;
    if ((row.role === 6) !== row.segmented || (row.role === 7) !== (row.chart !== null) || (row.metric !== null && row.role !== 3)) return 1;
    if ((row.role === 6 || row.role === 7) && (row.statusIdentity !== 0 || row.label.statusByteCount !== 0)) return 1;
    if (row.statusIdentity !== 0) for (let previous = 0; previous < slot; previous++) if (rows[previous]!.statusIdentity === row.statusIdentity) return 1;
    if (row.command.statusByteCount > 0) {
      if (row.separator || row.statusIdentity === 0) return 1;
      const error = nscvStatusCommandError(input, row.command); if (error !== 0) return error;
    }
    if (!row.separator && row.label.statusByteCount === 0 && row.role !== 6 && row.role !== 7 && row.metric === null) return 1;
    if (row.key.statusByteCount > 0 && (row.separator || row.command.statusByteCount === 0 || !nscvStatusShortcut(input, row.key, row.modifiers))) return 1;
    if (row.segmented) {
      if (row.statusOptionCount === 0 || row.statusOptionCount > 8) return 1;
      let selectedCount = 0;
      for (let optionSlot = 0; optionSlot < row.options.length; optionSlot++) {
        const option = row.options[optionSlot]!;
        if (option.statusIdentity === 0) return 1;
        const label = nscvStatusFieldError(input, option.label, 64); if (label !== 0) return label;
        const command = nscvStatusFieldError(input, option.command, 128); if (command !== 0) return command;
        if (option.label.statusByteCount === 0 || option.command.statusByteCount === 0) return 1;
        const commandName = nscvStatusCommandError(input, option.command); if (commandName !== 0) return commandName;
        if (option.selected) selectedCount++;
        for (let previous = 0; previous < optionSlot; previous++) if (row.options[previous]!.statusIdentity === option.statusIdentity) return 1;
        // The native reference checks other rows before validating them. Its
        // scans include oversized segmented arrays; their copied IDs were
        // compared by this policy in bounded chunks, preserving error order.
        if (option.overflowDuplicate) return 1;
        for (let otherSlot = 0; otherSlot < rows.length; otherSlot++) {
          if (otherSlot === slot) continue;
          const other = rows[otherSlot]!;
          if (other.statusIdentity === option.statusIdentity) return 1;
          for (const otherOption of other.options) if (otherOption.statusIdentity === option.statusIdentity) return 1;
        }
      }
      if (selectedCount > 1) return 1;
      fallbackCount += row.statusOptionCount;
    } else fallbackCount++;
    if (row.metric !== null) {
      for (let field = 0; field < 3; field++) {
        const value = field === 0 ? row.metric.primary : field === 1 ? row.metric.secondary : row.metric.accessibility;
        const error = nscvStatusFieldError(input, value, field === 2 ? 128 : 256); if (error !== 0) return error;
      }
      if (row.metric.primary.statusByteCount === 0 || row.metric.accessibility.statusByteCount === 0) return 1;
    }
    if (row.chart !== null) {
      const chart = row.chart;
      if (chart.statusValueCount === 0 || chart.statusValueCount > 32 || !Number.isFinite(chart.minimum) || !Number.isFinite(chart.maximum) || !(chart.maximum > chart.minimum)) return 1;
      for (let field = 0; field < 3; field++) {
        const value = field === 0 ? chart.leading : field === 1 ? chart.trailing : chart.accessibility;
        const error = nscvStatusFieldError(input, value, 128); if (error !== 0) return error;
      }
      if (chart.accessibility.statusByteCount === 0) return 1;
      for (const value of chart.values) if (!Number.isFinite(value) || value < chart.minimum || value > chart.maximum) return 1;
    }
  }
  return fallbackCount > 32 ? 1 : 0;
}

export function nscvStatusValidation(input: Uint8Array): Uint8Array {
  if (input.length < 8 || input[0] !== 70 || input[1]! > 6 || input[2] !== 0 || input[3] !== 0) throw new Error("invalid status admission header");
  const data = new DataView(input.buffer, input.byteOffset, input.byteLength), operation = input[1]!;
  if (operation === 6) {
    if (input.length < 16) throw new Error("truncated status identity comparison");
    const sourceRow = data.getUint32(4, true), queries = data.getUint32(8, true), count = data.getUint32(12, true);
    if (sourceRow >= 32 || queries > 256 || count > 128 || input.length !== 16 + queries * 8 + count * 4) throw new Error("invalid status identity comparison");
    const result = new Uint8Array(queries);
    for (let slot = 0; slot < queries; slot++) {
      const at = 16 + slot * 8;
      if (input[at]! >= 32 || input[at + 1]! >= 8 || input[at + 2] !== 0 || input[at + 3] !== 0) throw new Error("invalid status identity query");
      if (input[at] === sourceRow) continue;
      for (let value = 0; value < count; value++) if (data.getUint32(at + 4, true) === data.getUint32(16 + queries * 8 + value * 4, true)) { result[slot] = 1; break; }
    }
    return result;
  }
  let at = 4;
  const fields: NscvStatusField[] = [];
  let presentation: NscvStatusPresentation | null = null;
  if (operation === 0 || operation === 1) {
    const icon = nscvStatusField(input, at, 4096); fields.push(icon); at = icon.statusNextAt;
    if (operation === 0) {
      const title = nscvStatusField(input, at, 64); fields.push(title); at = title.statusNextAt;
      presentation = nscvStatusPresentation(input, at); at = presentation.statusNextAt;
    }
    for (let field = 0; field < 4; field++) { const value = nscvStatusField(input, at, field === 0 ? 256 : 128); fields.push(value); at = value.statusNextAt; }
  } else if (operation === 2) { const title = nscvStatusField(input, at, 64); fields.push(title); at = title.statusNextAt; }
  else if (operation === 3) { presentation = nscvStatusPresentation(input, at); at = presentation.statusNextAt; }
  let count = 0;
  const rows: NscvStatusRow[] = [];
  if (operation === 0 || operation === 4) {
    if (at + 4 > input.length) throw new Error("truncated status menu count");
    count = data.getUint32(at, true); at += 4;
    for (let slot = 0; slot < (count <= 32 ? count : 0); slot++) {
      if (at + 8 > input.length || input[at + 4]! > 7 || input[at + 5]! > 15 || input[at + 6]! > 31 || input[at + 7] !== 0) throw new Error("invalid status row header");
      const identity = data.getUint32(at, true), role = input[at + 4]!, flags = input[at + 5]!, modifiers = input[at + 6]!; at += 8;
      const label = nscvStatusField(input, at, 256); at = label.statusNextAt;
      const command = nscvStatusField(input, at, 128); at = command.statusNextAt;
      const detail = nscvStatusField(input, at, 256); at = detail.statusNextAt;
      const key = nscvStatusField(input, at, 32); at = key.statusNextAt;
      let optionCount = 0; const options: NscvStatusOption[] = [];
      if ((flags & 2) !== 0) {
        if (at + 4 > input.length) throw new Error("truncated status option count");
        optionCount = data.getUint32(at, true); at += 4;
        for (let optionSlot = 0; optionSlot < (optionCount <= 8 ? optionCount : 0); optionSlot++) {
          if (at + 8 > input.length || data.getUint32(at + 4, true) > 3) throw new Error("invalid status option header");
          const optionIdentity = data.getUint32(at, true), optionFlags = data.getUint32(at + 4, true); at += 8;
          const optionLabel = nscvStatusField(input, at, 64); at = optionLabel.statusNextAt;
          const optionCommand = nscvStatusField(input, at, 128); at = optionCommand.statusNextAt;
          options.push({ statusIdentity: optionIdentity, selected: (optionFlags & 1) !== 0, overflowDuplicate: (optionFlags & 2) !== 0, label: optionLabel, command: optionCommand });
        }
      }
      let metric: NscvStatusMetric | null = null;
      if ((flags & 4) !== 0) {
        const primary = nscvStatusField(input, at, 256); at = primary.statusNextAt;
        const secondary = nscvStatusField(input, at, 256); at = secondary.statusNextAt;
        const accessibility = nscvStatusField(input, at, 128); at = accessibility.statusNextAt;
        metric = { primary, secondary, accessibility };
      }
      let chart: NscvStatusChart | null = null;
      if ((flags & 8) !== 0) {
        if (at + 12 > input.length) throw new Error("truncated status chart header");
        const valueCount = data.getUint32(at, true), minimum = data.getFloat32(at + 4, true), maximum = data.getFloat32(at + 8, true); at += 12;
        const values: number[] = [];
        for (let value = 0; value < (valueCount <= 32 ? valueCount : 0); value++) {
          if (at + 4 > input.length) throw new Error("truncated status chart value"); values.push(data.getFloat32(at, true)); at += 4;
        }
        const leading = nscvStatusField(input, at, 128); at = leading.statusNextAt;
        const trailing = nscvStatusField(input, at, 128); at = trailing.statusNextAt;
        const accessibility = nscvStatusField(input, at, 128); at = accessibility.statusNextAt;
        chart = { statusValueCount: valueCount, minimum, maximum, values, leading, trailing, accessibility };
      }
      rows.push({ statusIdentity: identity, role, separator: (flags & 1) !== 0, modifiers, label, command, detail, key, segmented: (flags & 2) !== 0, statusOptionCount: optionCount, options, metric, chart });
    }
  }
  let statusIdentity = 1;
  if (operation === 5) { statusIdentity = data.getUint32(at, true); at += 4; }
  if (at !== input.length) throw new Error("trailing status admission bytes");
  let error = 0;
  if (operation === 0 || operation === 1) {
    for (let field = 0; field < fields.length; field++) {
      const limit = field === 0 ? 4096 : operation === 0 && field === 1 ? 64 : field === (operation === 0 ? 2 : 1) ? 256 : 128;
      error = nscvStatusFieldError(input, fields[field]!, limit); if (error !== 0) break;
      if (operation === 0 && field === 1) { error = nscvStatusPresentationError(input, presentation!); if (error !== 0) break; }
    }
    // All shell command field bounds precede every command-name check.
    if (error === 0) for (let field = operation === 0 ? 3 : 2; field < fields.length; field++) if (fields[field]!.statusByteCount > 0) { error = nscvStatusCommandError(input, fields[field]!); if (error !== 0) break; }
  } else if (operation === 2) error = nscvStatusFieldError(input, fields[0]!, 64);
  else if (operation === 3) error = nscvStatusPresentationError(input, presentation!);
  else if (operation === 5 && statusIdentity === 0) error = 1;
  if (error === 0 && (operation === 0 || operation === 4)) error = nscvStatusMenuError(input, count, rows);
  const result = new Uint8Array(4); result[0] = error; return result;
}
