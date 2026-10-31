/** Complete session payload layouts. Native supplies raw typed storage slots;
 * TypeScript owns tags, field order, optional suffixes, bounds and byte validation.
 * Scalar payloads are copied as bytes to retain all integer and floating bits.
 */
type NscJournalField = { path: string; kind: string; domain: string };
type NscJournalSlot = { path: string; bytes: Uint8Array };
function nscjFields(rows: readonly (readonly string[])[]): NscJournalField[] {
  return rows.map(row => ({ path: row[0]!, kind: row[1]!, domain: row[2]! }));
}
function nscjEventTag(name: string): number {
  switch (name) {
    case "app_start": return 1;
    case "app_activated": return 2;
    case "app_deactivated": return 3;
    case "appearance_changed": return 4;
    case "frame_requested": return 5;
    case "app_shutdown": return 6;
    case "surface_resized": return 7;
    case "window_frame_changed": return 8;
    case "window_focused": return 9;
    case "bridge_message": return 10;
    case "tray_action": return 11;
    case "shortcut": return 12;
    case "native_command": return 13;
    case "menu_command": return 14;
    case "timer": return 15;
    case "wake": return 16;
    case "files_dropped": return 17;
    case "gpu_surface_frame": return 18;
    case "gpu_surface_resized": return 19;
    case "gpu_surface_input": return 20;
    case "gpu_surface_scroll_driver": return 21;
    case "context_menu_action": return 22;
    case "widget_accessibility_action": return 23;
    case "audio": return 24;
    case "video": return 25;
    case "view_focused": return 26;
    case "tray_command": return 27;
    case "notification_command": return 28;
    case "widget_context_menu_action": return 29;
    default: throw new Error("unknown native event storage");
  }
}
function nscjEventName(tag: number): string {
  switch (tag) {
    case 1: return "app_start";
    case 2: return "app_activated";
    case 3: return "app_deactivated";
    case 4: return "appearance_changed";
    case 5: return "frame_requested";
    case 6: return "app_shutdown";
    case 7: return "surface_resized";
    case 8: return "window_frame_changed";
    case 9: return "window_focused";
    case 10: return "bridge_message";
    case 11: return "tray_action";
    case 12: return "shortcut";
    case 13: return "native_command";
    case 14: return "menu_command";
    case 15: return "timer";
    case 16: return "wake";
    case 17: return "files_dropped";
    case 18: return "gpu_surface_frame";
    case 19: return "gpu_surface_resized";
    case 20: return "gpu_surface_input";
    case 21: return "gpu_surface_scroll_driver";
    case 22: return "context_menu_action";
    case 23: return "widget_accessibility_action";
    case 24: return "audio";
    case 25: return "video";
    case 26: return "view_focused";
    case 27: return "tray_command";
    case 28: return "notification_command";
    case 29: return "widget_context_menu_action";
    default: return "";
  }
}
function nscjSchema(record: number, name: string): NscJournalField[] {
  if (record === 2) switch (name) {
    case "appearance_changed": return nscjFields([["color_scheme", "enum", "ColorScheme"], ["reduce_motion", "bool", ""], ["high_contrast", "bool", ""]]);
    case "surface_resized": return nscjFields([["id", "u64", ""], ["size.width", "f32", ""], ["size.height", "f32", ""], ["scale_factor", "f32", ""], ["safe_area_insets.top", "f32", ""], ["safe_area_insets.right", "f32", ""], ["safe_area_insets.bottom", "f32", ""], ["safe_area_insets.left", "f32", ""], ["keyboard_insets.top", "f32", ""], ["keyboard_insets.right", "f32", ""], ["keyboard_insets.bottom", "f32", ""], ["keyboard_insets.left", "f32", ""]]);
    case "window_frame_changed": return nscjFields([["id", "u64", ""], ["label", "str", ""], ["title", "str", ""], ["frame.x", "f32", ""], ["frame.y", "f32", ""], ["frame.width", "f32", ""], ["frame.height", "f32", ""], ["scale_factor", "f32", ""], ["open", "bool", ""], ["focused", "bool", ""], ["maximized", "bool", ""], ["fullscreen", "bool", ""], ["hidden", "bool", ""]]);
    case "window_focused": return nscjFields([["", "u64", ""]]);
    case "view_focused": return nscjFields([["window_id", "u64", ""], ["label", "str", ""]]);
    case "bridge_message": return nscjFields([["bytes", "str", ""], ["origin", "str", ""], ["window_id", "u64", ""], ["webview_label", "str", ""]]);
    case "tray_action": return nscjFields([["status_item_id", "u32", ""], ["item_id", "u32", ""]]);
    case "shortcut": return nscjFields([["id", "str", ""], ["key", "str", ""], ["modifiers", "modifiers", ""], ["window_id", "u64", ""]]);
    case "native_command": return nscjFields([["name", "str", ""], ["window_id", "u64", ""], ["view_label", "str", ""]]);
    case "menu_command": return nscjFields([["name", "str", ""], ["window_id", "u64", ""]]);
    case "tray_command": return nscjFields([["name", "str", ""], ["window_id", "u64", ""], ["status_item_id", "u32", ""]]);
    case "notification_command": return nscjFields([["name", "str", ""], ["window_id", "u64", ""]]);
    case "timer": return nscjFields([["id", "u64", ""], ["timestamp_ns", "u64", ""]]);
    case "audio": return nscjFields([["kind", "enum", "AudioEventKind"], ["position_ms", "u64", ""], ["duration_ms", "u64", ""], ["playing", "bool", ""], ["buffering", "bool", ""], ["bands", "bytes32", ""]]);
    case "video": return nscjFields([["kind", "enum", "VideoEventKind"], ["token", "u64", ""], ["position_ms", "u64", ""], ["duration_ms", "u64", ""], ["playing", "bool", ""], ["buffering", "bool", ""], ["width", "u64", ""], ["height", "u64", ""]]);
    case "files_dropped": return nscjFields([["window_id", "u64", ""], ["view_label", "str", ""], ["point", "optional-point", ""], ["paths", "paths", ""]]);
    case "gpu_surface_frame": return nscjFields([["window_id", "u64", ""], ["label", "str", ""], ["size.width", "f32", ""], ["size.height", "f32", ""], ["scale_factor", "f32", ""], ["frame_index", "u64", ""], ["timestamp_ns", "u64", ""], ["frame_interval_ns", "u64", ""], ["input_timestamp_ns", "u64", ""], ["canvas_frame_full_repaint", "bool", ""]]);
    case "gpu_surface_resized": return nscjFields([["window_id", "u64", ""], ["label", "str", ""], ["frame.x", "f32", ""], ["frame.y", "f32", ""], ["frame.width", "f32", ""], ["frame.height", "f32", ""], ["scale_factor", "f32", ""]]);
    case "gpu_surface_input": return nscjFields([["window_id", "u64", ""], ["label", "str", ""], ["kind", "enum", "GpuSurfaceInputKind"], ["timestamp_ns", "u64", ""], ["pointer_id", "u64", ""], ["x", "f32", ""], ["y", "f32", ""], ["button", "i32", ""], ["pressure", "f32", ""], ["delta_x", "f32", ""], ["delta_y", "f32", ""], ["scroll_is_detented", "bool", ""], ["key", "str", ""], ["text", "str", ""], ["composition_cursor", "optional-usize", ""], ["modifiers", "modifiers", ""], ["scale", "f32", ""]]);
    case "gpu_surface_scroll_driver": return nscjFields([["window_id", "u64", ""], ["label", "str", ""], ["driver_id", "u64", ""], ["offset_x", "f32", ""], ["offset_y", "f32", ""], ["timestamp_ns", "u64", ""]]);
    case "context_menu_action": return nscjFields([["window_id", "u64", ""], ["view_label", "str", ""], ["token", "u64", ""], ["item_id", "u32", ""]]);
    case "widget_context_menu_action": return nscjFields([["window_id", "u64", ""], ["label", "str", ""], ["id", "u64", ""], ["item_index", "u32", ""]]);
    case "widget_accessibility_action": return nscjFields([["window_id", "u64", ""], ["label", "str", ""], ["id", "u64", ""], ["action", "enum32", "WidgetAccessibilityActionKind"], ["text", "str", ""], ["selection", "optional-range", ""]]);
    case "app_start": return nscjFields([]);
    case "app_activated": return nscjFields([]);
    case "app_deactivated": return nscjFields([]);
    case "frame_requested": return nscjFields([]);
    case "app_shutdown": return nscjFields([]);
    case "wake": return nscjFields([]);
    default: throw new Error("unknown journal event schema");
  }
  switch (record) {
    case 1: return nscjFields([["protocol_fingerprint", "u64", ""], ["platform_name", "str", ""], ["app_name", "str", ""], ["recorded_at_wall_ms", "i64", ""], ["window_width", "f32", ""], ["window_height", "f32", ""], ["window_chrome_source", "enum", "WindowChromeSource"]]);
    case 4: return nscjFields([["event_ordinal", "u64", ""], ["frame_index", "u64", ""], ["fingerprint", "u64", ""]]);
    case 5: return nscjFields([["event_ordinal", "u64", ""], ["view_label", "str", ""], ["scale", "f32", ""], ["png_hash", "u64", ""], ["png_len", "u64", ""]]);
    case 6: return nscjFields([["event_count", "u64", ""], ["effect_count", "u64", ""], ["checkpoint_count", "u64", ""], ["screenshot_count", "u64", ""], ["window_chrome_count", "u64", ""]]);
    case 7: return nscjFields([["window_id", "u64", ""], ["chrome.insets.top", "f32", ""], ["chrome.insets.right", "f32", ""], ["chrome.insets.bottom", "f32", ""], ["chrome.insets.left", "f32", ""], ["chrome.buttons.x", "f32", ""], ["chrome.buttons.y", "f32", ""], ["chrome.buttons.width", "f32", ""], ["chrome.buttons.height", "f32", ""], ["chrome.form_factor", "enum", "FormFactor"], ["chrome.tabs_projected", "bool", ""]]);
    case 3: return nscjFields([["kind", "enum", "EffectResultKind"], ["key", "u64", ""], ["payload", "str", ""], ["stderr_tail", "str", ""], ["truncated", "bool", ""], ["dropped", "u32", ""], ["code", "i32", ""], ["exit_reason", "enum", "EffectExitReason"], ["output_truncated", "bool", ""], ["stderr_truncated", "bool", ""], ["status", "u16", ""], ["fetch_outcome", "enum", "EffectFetchOutcome"], ["file_op", "enum", "EffectFileOp"], ["file_event", "enum", "EffectFileEvent"], ["file_outcome", "enum", "EffectFileOutcome"], ["file_total", "u64", ""], ["file_mtime_ms", "i64", ""], ["file_exists", "bool", ""], ["file_rejected_admission", "bool", ""], ["clipboard_op", "enum", "EffectClipboardOp"], ["clipboard_outcome", "enum", "EffectClipboardOutcome"], ["timer_timestamp_ns", "u64", ""], ["timer_outcome", "enum", "EffectTimerOutcome"], ["clock_wall_ms", "i64", ""], ["audio_kind", "enum", "EffectAudioEventKind"], ["audio_position_ms", "u64", ""], ["audio_duration_ms", "u64", ""], ["audio_playing", "bool", ""], ["audio_buffering", "bool", ""], ["file_blob_hash", "bytes16", ""], ["file_blob_len", "u64", ""], ["audio_bands", "bytes32", ""], ["image_outcome", "enum", "EffectImageOutcome"], ["image_width", "u64", ""], ["image_height", "u64", ""], ["image_blob_hash", "bytes16", ""], ["image_blob_len", "u64", ""], ["channel_kind", "enum", "EffectChannelEventKind"], ["channel_dropped_total", "u32", ""], ["video_kind", "enum", "EffectVideoEventKind"], ["video_position_ms", "u64", ""], ["video_duration_ms", "u64", ""], ["video_playing", "bool", ""], ["video_buffering", "bool", ""], ["video_width", "u64", ""], ["video_height", "u64", ""], ["video_token", "u64", ""], ["video_source", "enum", "EffectVideoSource"], ["video_handled", "bool", ""], ["pty_kind", "enum", "EffectPtyEventKind"], ["pty_signal", "i32", ""], ["pty_dropped_writes", "u32", ""], ["pty_blob_hash", "bytes16", ""], ["pty_blob_len", "u64", ""], ["persist_outcome", "enum", "EffectPersistOutcome"], ["persist_blob_hash", "bytes16", ""], ["persist_blob_len", "u64", ""], ["db_blob_hash", "bytes16", ""], ["db_blob_len", "u64", ""], ["credentials_operation", "enum", "EffectCredentialsOperation"], ["credentials_outcome", "enum", "EffectCredentialsOutcome"], ["credentials_secret_len", "u64", ""], ["credentials_salt", "bytes16", ""], ["credentials_digest", "bytes32", ""]]);
    default: throw new Error("invalid journal record schema");
  }
}
function nscjEnumValid(domain: string, value: number): boolean {
  switch (domain) {
    case "ColorScheme": return value >= 0 && value <= 1;
    case "AudioEventKind": return value >= 0 && value <= 4;
    case "VideoEventKind": return value >= 0 && value <= 3;
    case "GpuSurfaceInputKind": return value >= 0 && value <= 14;
    case "EffectResultKind": return value >= 1 && value <= 20;
    case "EffectExitReason": return value >= 0 && value <= 4;
    case "EffectFetchOutcome": return value >= 0 && value <= 6;
    case "EffectFileOp": return value >= 0 && value <= 8;
    case "EffectFileEvent": return value >= 0 && value <= 2;
    case "EffectFileOutcome": return value >= 0 && value <= 8;
    case "EffectClipboardOp": return value >= 0 && value <= 1;
    case "EffectClipboardOutcome": return value >= 0 && value <= 3;
    case "EffectTimerOutcome": return value >= 0 && value <= 1;
    case "EffectAudioEventKind": return value >= 0 && value <= 5;
    case "EffectImageOutcome": return value >= 0 && value <= 14;
    case "EffectChannelEventKind": return value >= 0 && value <= 2;
    case "EffectVideoEventKind": return value >= 0 && value <= 4;
    case "EffectVideoSource": return value >= 0 && value <= 1;
    case "EffectPtyEventKind": return value >= 0 && value <= 2;
    case "EffectPersistOutcome": return value >= 0 && value <= 6;
    case "EffectCredentialsOperation": return value >= 0 && value <= 2;
    case "EffectCredentialsOutcome": return value >= 0 && value <= 6;
    case "WindowChromeSource": return value >= 0 && value <= 1;
    case "FormFactor": return value >= 0 && value <= 2;
    case "WidgetAccessibilityActionKind": return value >= 0 && value <= 13;
    default: throw new Error("unknown journal enum domain");
  }
}
function nscjWidth(kind: string): number {
  if (kind === "enum" || kind === "bool") return 1;
  if (kind === "u16") return 2;
  if (kind === "f32" || kind === "u32" || kind === "i32" || kind === "enum32") return 4;
  if (kind === "u64" || kind === "i64" || kind === "usize") return 8;
  if (kind === "bytes16") return 16;
  if (kind === "bytes32") return 32;
  throw new Error("invalid journal scalar storage");
}
class NscJournalCursor implements nscContracts.Acyclic {
  input: Uint8Array; slots: NscJournalSlot[]; chunks: Uint8Array[] = []; written: number = 0; entries: NscJournalSlot[] = [];
  at: number = 0; status: number = 0; decode: boolean; capacity: number; usizeBits: number;
  constructor(input: Uint8Array, slots: NscJournalSlot[], decode: boolean, capacity: number, usizeBits: number) {
    this.input = input; this.slots = slots; this.decode = decode; this.capacity = capacity; this.usizeBits = usizeBits;
  }
  slot(path: string): Uint8Array {
    for (const slot of this.slots) if (slot.path === path) return slot.bytes;
    throw new Error("missing native journal storage slot");
  }
  write(bytes: Uint8Array): void {
    if (this.status !== 0) return;
    if (bytes.length > this.capacity - this.written) { this.status = 2; return; }
    this.chunks.push(bytes); this.written += bytes.length;
  }
  read(length: number): Uint8Array {
    if (this.status !== 0) return new Uint8Array(0);
    if (length > this.input.length - this.at) { this.status = 1; return new Uint8Array(0); }
    const bytes = this.input.subarray(this.at, this.at + length); this.at += length; return bytes;
  }
  emit(path: string, source: Uint8Array): void {
    // The span descriptor borrows the original payload; no decoded text is retained.
    const bytes = new Uint8Array(8), w = new DataView(bytes.buffer);
    w.setUint32(0, source.byteOffset - this.input.byteOffset, true); w.setUint32(4, source.length, true);
    this.entries.push({ path, bytes });
  }
  scalar(path: string, kind: string, domain: string): number {
    if (this.status !== 0) return 0;
    const length = nscjWidth(kind);
    let bytes = this.decode ? this.read(length) : this.slot(path);
    if (!this.decode && kind === "usize" && bytes.length === 4) { const wide = new Uint8Array(8); wide.set(bytes); bytes = wide; }
    if (this.status !== 0) return 0;
    if (bytes.length !== length) throw new Error("invalid native journal scalar width");
    const w = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    let value = kind === "enum32" ? w.getInt32(0, true) : length === 1 ? bytes[0]! : length === 2 ? w.getUint16(0, true) : w.getUint32(0, true);
    if (this.decode && (kind === "bool" && value > 1 || (kind === "enum" || kind === "enum32") && !nscjEnumValid(domain, value) || kind === "usize" && this.usizeBits === 32 && w.getUint32(4, true) !== 0)) {
      this.status = 1; return 0;
    }
    if (this.decode) this.emit(path, bytes); else this.write(bytes);
    return value;
  }
  string(path: string): void {
    if (this.status !== 0) return;
    if (this.decode) {
      const prefix = this.read(4); if (this.status !== 0) return;
      const count = new DataView(prefix.buffer, prefix.byteOffset, 4).getUint32(0, true), bytes = this.read(count);
      if (this.status === 0) this.emit(path, bytes);
    } else {
      const bytes = this.slot(path), prefix = new Uint8Array(4);
      if (bytes.length > 4294967295) { this.status = 2; return; }
      new DataView(prefix.buffer).setUint32(0, bytes.length, true); this.write(prefix); this.write(bytes);
    }
  }
  field(field: NscJournalField): void {
    if (this.status !== 0) return;
    const path = field.path, kind = field.kind;
    if (kind === "str") this.string(path);
    else if (kind === "modifiers") {
      if (this.decode) {
        const bits = this.read(1); if (this.status !== 0) return;
        if (bits[0]! > 31) { this.status = 1; return; }
        this.emit(path, bits);
      } else {
        const names = ["primary", "command", "control", "option", "shift"]; let mask = 0;
        for (let i = 0; i < names.length; i++) if (this.slot(path + "." + names[i]!)[0] === 1) mask |= 1 << i;
        const bits = new Uint8Array(1); bits[0] = mask; this.write(bits);
      }
    } else if (kind === "optional-point" || kind === "optional-usize" || kind === "optional-range") {
      if (this.scalar(path, "bool", "") !== 0) {
        if (kind === "optional-point") { this.scalar(path + ".x", "f32", ""); this.scalar(path + ".y", "f32", ""); }
        else if (kind === "optional-range") { this.scalar(path + ".start", "usize", ""); this.scalar(path + ".end", "usize", ""); }
        else this.scalar(path + ".value", "usize", "");
      }
    } else if (kind === "paths") {
      let count = 0;
      if (this.decode) {
        const raw = this.read(2); if (this.status !== 0) return;
        count = new DataView(raw.buffer, raw.byteOffset, 2).getUint16(0, true);
        if (count > 32) { this.status = 1; return; }
        this.emit(path, raw);
      } else {
        const raw = this.slot(path), w = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
        count = w.getUint32(0, true);
        if (w.getUint32(4, true) !== 0 || count > 32) { this.status = 2; return; }
        const bytes = new Uint8Array(2); new DataView(bytes.buffer).setUint16(0, count, true); this.write(bytes);
      }
      for (let i = 0; i < count && this.status === 0; i++) this.string(path + "/" + i);
    } else this.scalar(path, kind, field.domain);
  }
}
/** Opcode 30, version 1: encode raw native slots or decode borrowed wire spans.
 * Result status 1 is corrupt input; 2 is output budget. Failed operations retain
 * their exact written prefix and all already-decoded dropped-path spans.
 */
export function sessionCodecPolicy(request: Uint8Array): Uint8Array {
  if (request.length < 24 || request[0] !== 30 || request[1] !== 1 || request[2]! > 1 || request[3]! < 1 || request[3]! > 7)
    throw new Error("invalid journal codec request");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), decode = request[2] === 1, record = request[3]!;
  const capacity = w.getUint32(4, true), usizeBits = w.getUint32(8, true), nameLength = w.getUint32(12, true), count = w.getUint32(16, true), payloadLength = w.getUint32(20, true);
  if (usizeBits !== 32 && usizeBits !== 64 || nameLength > 64 || count > 512 || decode && (nameLength !== 0 || count !== 0) || !decode && payloadLength !== 0 || 24 + nameLength > request.length)
    throw new Error("invalid journal codec storage bounds");
  let at = 24 + nameLength; const slots: NscJournalSlot[] = [];
  const text = new TextDecoder("utf-8", { ignoreBOM: true });
  let name = text.decode(request.subarray(24, at));
  for (let i = 0; i < count; i++) {
    if (at + 8 > request.length) throw new Error("truncated journal slot");
    const n = w.getUint32(at, true), length = w.getUint32(at + 4, true); at += 8;
    if (n > 256 || n > request.length - at || length > request.length - at - n) throw new Error("invalid journal slot extent");
    const path = text.decode(request.subarray(at, at + n)); at += n;
    for (const slot of slots) if (slot.path === path) throw new Error("duplicate journal slot");
    slots.push({ path, bytes: request.subarray(at, at + length) }); at += length;
  }
  if (payloadLength !== request.length - at) throw new Error("invalid journal payload extent");
  const input = request.subarray(at), cursor = new NscJournalCursor(input, slots, decode, capacity, usizeBits);
  let tag = 0;
  if (record === 2) {
    if (decode) {
      const value = cursor.read(1);
      if (cursor.status === 0) { tag = value[0]!; name = nscjEventName(tag); if (name === "") cursor.status = 1; }
    } else { tag = nscjEventTag(name); const value = new Uint8Array(1); value[0] = tag; cursor.write(value); }
  }
  let effectKind = 0;
  if (cursor.status === 0) {
    for (const field of nscjSchema(record, name)) {
      // The effect's kind-local suffixes preserve all earlier byte layouts.
      if (record === 3 && field.path.startsWith("persist_") && effectKind !== 16 || record === 3 && field.path.startsWith("db_") && effectKind !== 17 || record === 3 && field.path.startsWith("credentials_") && effectKind !== 18) continue;
      if (record === 3 && field.path === "kind") effectKind = cursor.scalar(field.path, field.kind, field.domain);
      else cursor.field(field);
      if (cursor.status !== 0) break;
    }
  }
  if (decode && cursor.status === 0 && cursor.at !== input.length) cursor.status = 1;
  const paths: Uint8Array[] = [];
  let bodyLength = decode ? 0 : cursor.written;
  if (decode) for (const entry of cursor.entries) {
    const path = new TextEncoder().encode(entry.path); paths.push(path); bodyLength += 12 + path.length;
  }
  const eventName = decode && record === 2 ? new TextEncoder().encode(name) : new Uint8Array(0);
  const result = new Uint8Array(16 + eventName.length + bodyLength), out = new DataView(result.buffer);
  out.setUint32(0, 1, true); out.setUint32(4, cursor.status, true); out.setUint32(8, decode ? cursor.entries.length : cursor.written, true); out.setUint32(12, eventName.length, true);
  result.set(eventName, 16);
  let outputAt = 16 + eventName.length;
  if (decode) for (let i = 0; i < cursor.entries.length; i++) {
    const entry = cursor.entries[i]!, path = paths[i]!;
    out.setUint32(outputAt, path.length, true); outputAt += 4;
    result.set(path, outputAt); outputAt += path.length;
    result.set(entry.bytes, outputAt); outputAt += 8;
  } else for (const chunk of cursor.chunks) { result.set(chunk, outputAt); outputAt += chunk.length; }
  return result;
}
