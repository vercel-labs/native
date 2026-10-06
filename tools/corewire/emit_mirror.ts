// The host mirror projection of the compiled core's complete contract.
import type { TypeRef, MsgArm } from "./core_contract.ts";
import { findRecord, usesVirtualExtentHelpers } from "./core_contract.ts";
import { projectionPlan, validateMirror } from "./core_projection.ts";
import { CodeWriter, commentText, zigString, zigIdent, synthesized, scrollIndexes, isTextInputUnion } from "./core_emission.ts";
import type { EmissionInput, EmissionContract, EmissionResult } from "./core_emission.ts";
import * as text from "./mirror_templates.ts";

export function emitMirror(input: EmissionInput): EmissionResult {
  const diagnostics = validateMirror(input.sidecar);
  if (diagnostics.length > 0) return { output: "", diagnostics };
  for (const arm of input.sidecar.msg.arms) {
    if (arm.payload.kind === "scalar" && !["bool", "f64", "i64", "bytes"].includes(arm.payload.type!.kind)) {
      diagnostics.push({ path: "msg.arms", message: `arm "${arm.name}": ABI version 1 has no dispatch entry for this scalar shape (bool, number, and bytes scalars only)` });
    }
  }
  if (diagnostics.length > 0) return { output: "", diagnostics };
  const writer = new MirrorEmitter(input);
  writer.run();
  return { output: writer.out, diagnostics };
}
class MirrorEmitter extends CodeWriter {
  input: EmissionInput;
  s: EmissionContract;
  inlined: string[];
  constructor(input: EmissionInput) {
    super(); this.input = input; this.s = input.sidecar;
    this.inlined = projectionPlan(this.s).inlined;
  }
  run(): void {
    this.header(); this.mirrorTypes(); this.modelStruct(); this.msgUnion(); this.wiringAliases();
    this.tagTable(); this.entryPoints(); this.channels(); this.helperPlumbing(); this.snapshotPlumbing();
  }
  header(): void {
    this.print(text.header, [commentText(this.s.entry), commentText(this.s.compiler_version),
      this.input.build_id_hex, zigString(this.s.abi.prefix), this.input.build_id_hex,
      this.input.model_fingerprint_hex, this.input.abi_text, this.input.snapshot_text,
      String(this.s.deterministic), String(this.s.async_free)]);
  }
  attestedClass(slot: string): string | null {
    for (const entry of this.s.integer_slots) if (entry.slot === slot) return entry.class;
    return null;
  }
  integerSpelling(slot: string | null): string { return slot === null ? "i64" : this.attestedClass(slot) ?? "i64"; }
  exactCall(slot: string, inner: string): string {
    return "shim_rt." + (this.attestedClass(slot) === "u64" ? "exactF64Unsigned" : "exactF64") + "(" + inner + ")";
  }
  slotPath(container: string, member: string): string { return container + "." + member; }
  numberBytesSlot(arm: string, field: string): string { return this.s.msg.name + "." + arm + "." + field; }
  numberSpelling(className: string, slot: string): string { return className === "f64" ? "f64" : this.integerSpelling(slot); }
  mirrorTypes(): void {
    for (const entry of this.s.types.enums) {
      this.print("\npub const {f} = enum(u8) {{", [zigIdent(entry.name)]);
      for (let i = 0; i < entry.members.length; i++) this.print("\n    {f} = {d},", [zigIdent(entry.members[i]), String(i)]);
      this.raw("\n};\n");
    }
    for (const entry of this.s.types.structs) {
      if (entry.name === this.s.model || this.inlined.includes(entry.name)) continue;
      this.print("\npub const {f} = struct {{", [zigIdent(entry.name)]);
      for (const f of entry.fields) this.print("\n    {f}: {s},", [zigIdent(f.name), this.spellRef(f.type, entry.name, f.name, this.slotPath(entry.name, f.name))]);
      this.raw("\n};\n");
    }
    for (const entry of this.s.types.unions) {
      if (this.inlined.includes(entry.name)) continue;
      this.print("\npub const {f} = union(enum) {{", [zigIdent(entry.name)]);
      for (const a of entry.arms) {
        if (a.payload.kind === "void") this.print("\n    {f},", [zigIdent(a.name)]);
        else this.print("\n    {f}: {s},", [zigIdent(a.name), this.spellRef(a.payload, entry.name, a.name, this.slotPath(entry.name, a.name))]);
      }
      this.raw("\n};\n");
    }
  }
  spellRef(ref: TypeRef, container: string, member: string, slot: string | null): string {
    switch (ref.kind) {
      case "bool": return "bool";
      case "f64": return "f64";
      case "i64": return this.integerSpelling(slot);
      case "bytes": return "[]const u8";
      case "void": return "void";
      case "optional": return "?" + this.spellRef(ref.inner!, container, member, slot);
      case "slice": return "[]const " + this.spellRef(ref.elem!, container, member, null);
      case "node": return "*const " + this.spellNamed(ref.name!, container, member);
      case "value": return this.spellNamed(ref.name!, container, member);
      case "enum": case "union": return zigIdent(ref.name!);
      default: throw new Error("unknown mirror type");
    }
  }
  spellNamed(name: string, container: string, member: string): string {
    if (!synthesized(container, member, name) || !this.inlined.includes(name)) return zigIdent(name);
    const entry = findRecord(this.s, name);
    if (entry === null) return zigIdent(name);
    let out = "struct {";
    for (let i = 0; i < entry.fields.length; i++) {
      const f = entry.fields[i];
      if (i > 0) out += ",";
      out += " " + zigIdent(f.name) + ": " + this.spellRef(f.type, entry.name, f.name, this.slotPath(entry.name, f.name));
    }
    return out + " }";
  }
  modelStruct(): void {
    const model = findRecord(this.s, this.s.model);
    if (model === null) throw new Error("validated model missing");
    this.print("\npub const {f} = struct {{", [zigIdent(model.name)]);
    for (const f of model.fields) this.print("\n    {f}: {s},", [zigIdent(f.name), this.spellRef(f.type, model.name, f.name, this.slotPath(model.name, f.name))]);
    if (this.s.model_helpers.length > 0) this.raw("\n");
    for (let i = 0; i < this.s.model_helpers.length; i++) {
      const h = this.s.model_helpers[i];
      const returns = this.spellRef(h.returns, "helpers", h.name, "helpers." + h.name + ".return");
      if (h.arena && h.params.length === 0) {
        this.print("\n    pub fn {f}(self: *const {f}, arena: std.mem.Allocator) {s} {{\n        _ = self;\n        return callHelper({s}, {d}, &.{{}}, arena);\n    }}",
          [zigIdent(h.name), zigIdent(model.name), returns, returns, String(i)]);
      } else if (h.params.length === 0) {
        this.print("\n    pub fn {f}(self: *const {f}) {s} {{\n        _ = self;\n        return callHelper({s}, {d}, &.{{}}, shim_rt.frameAllocator());\n    }}",
          [zigIdent(h.name), zigIdent(model.name), returns, returns, String(i)]);
      } else {
        let params = "", tuple = "";
        for (let j = 0; j < h.params.length; j++) {
          const spelled = this.spellRef(h.params[j], "helpers", h.name, "helpers." + h.name + ".params[" + j + "]");
          params += ", p" + j + ": " + spelled;
          if (j > 0) tuple += ", ";
          tuple += "p" + j;
        }
        if (h.arena) params += ", arena: std.mem.Allocator";
        this.print("\n    pub fn {f}(self: *const {f}{s}) {s} {{\n        _ = self;\n        const args_tuple = .{{ {s} }};\n        const args = shim_rt.encodeAlloc(@TypeOf(args_tuple), args_tuple, shim_rt.frameAllocator());\n        return callHelper({s}, {d}, args, {s});\n    }}",
          [zigIdent(h.name), zigIdent(model.name), params, returns, tuple, returns, String(i), h.arena ? "arena" : "shim_rt.frameAllocator()"]);
      }
    }
    // Native markup and its Debug interpreter need the same stable helpers
    // even when the compiled TypeScript view ABI is absent.
    if (usesVirtualExtentHelpers(this.s)) this.virtualEstimates();
    this.unboundDecl(this.s.model_unbound); this.raw("\n};\n");
  }
  virtualEstimates(): void {
    this.raw('\n    /// Stable compiled helper identities; retained tables hold no model or arena pointer.\n    pub fn virtualExtentHelper(name: []const u8) ?u32 {\n');
    const helpers = this.s.model_helpers.map((helper, index) => ({ helper, index })).filter(({ helper }) => helper.params.length === 1 && ["i64", "f64"].includes(helper.params[0].kind) && ["i64", "f64"].includes(helper.returns.kind));
    for (const { helper, index } of helpers) this.print('        if (std.mem.eql(u8, name, "{f}")) return {d};\n', [zigString(helper.name), String(index)]);
    this.raw('        return null;\n    }\n\n    pub fn virtualExtentEstimate(context: ?*const anyopaque, index: u64) f32 {\n        if (index > 9007199254740991) @panic("virtual extent index exceeds safe integers");\n        const helper: u32 = @intCast(@intFromPtr(context orelse @panic("missing virtual extent identity")) - 1);\n        var args: [8]u8 = undefined;\n        defer abi.frame_reset();\n        const value: f64 = switch (helper) {\n');
    for (const { helper, index } of helpers) {
      const parameter = this.spellRef(helper.params[0], "helpers", helper.name, "helpers." + helper.name + ".params[0]");
      const encoded = helper.params[0].kind === "i64" ? "@as(" + parameter + ", @intCast(index))" : "@as(f64, @floatFromInt(index))";
      this.print('            {d} => blk: {{\n                std.mem.writeInt(u64, &args, @bitCast({s}), .little);\n                break :blk {s}callHelper({s}, {d}, &args, shim_rt.frameAllocator()){s};\n            }},\n', [String(index), encoded, helper.returns.kind === "i64" ? "@floatFromInt(" : "", this.spellRef(helper.returns, "helpers", helper.name, "helpers." + helper.name + ".return"), String(index), helper.returns.kind === "i64" ? ")" : ""]);
    }
    this.raw('            else => @panic("invalid virtual extent helper"),\n        };\n        if (!std.math.isFinite(value) or value < 0 or value > std.math.floatMax(f32)) @panic("invalid virtual extent result");\n        return @floatCast(value);\n    }\n');
  }
  unboundDecl(names: string[]): void {
    if (names.length === 0) return;
    this.raw("\n\n    pub const view_unbound = .{");
    for (let i = 0; i < names.length; i++) { if (i > 0) this.raw(","); this.print(' "{f}"', [zigString(names[i])]); }
    this.raw(" };");
  }
  msgUnion(): void {
    this.print("\npub const {f} = union(enum) {{", [zigIdent(this.s.msg.name)]);
    for (const arm of this.s.msg.arms) {
      const p = arm.payload, name = zigIdent(arm.name);
      switch (p.kind) {
        case "void": this.print("\n    {f},", [name]); break;
        case "bytes": this.print("\n    {f}: []const u8,", [name]); break;
        case "number": this.print("\n    {f}: {s},", [name, this.numberSpelling(p.class!, this.slotPath(this.s.msg.name, arm.name))]); break;
        case "number_bytes":
          this.print("\n    {f}: struct {{ {f}: {s}, {f}: []const u8 }},", [name, zigIdent(p.number_field!),
            this.numberSpelling(p.number_class!, this.numberBytesSlot(arm.name, p.number_field!)), zigIdent(p.bytes_field!)]); break;
        case "record": this.print("\n    {f}: {s},", [name, this.spellNamed(p.name!, this.s.msg.name, arm.name)]); break;
        case "union_ref": case "enum_ref": this.print("\n    {f}: {f},", [name, zigIdent(p.name!)]); break;
        case "scalar": this.print("\n    {f}: {s},", [name, this.spellRef(p.type!, this.s.msg.name, arm.name, this.slotPath(this.s.msg.name, arm.name))]); break;
        default: throw new Error("unknown mirror payload");
      }
    }
    this.unboundDecl(this.s.msg.unbound); this.raw("\n};\n");
  }
  wiringAliases(): void {
    if (this.s.model !== "Model") this.print("\n/// The host wiring's spelling for the root state type.\npub const Model = {f};\n", [zigIdent(this.s.model)]);
    if (this.s.msg.name !== "Msg") this.print("\n/// The host wiring's spelling for the message union.\npub const Msg = {f};\n", [zigIdent(this.s.msg.name)]);
  }
  tagTable(): void {
    let nameBytes = 0;
    for (const arm of this.s.msg.arms) nameBytes += new TextEncoder().encode(arm.name).length;
    const quota = Math.min(4294967295, 100000 + this.s.msg.arms.length * 1024 + nameBytes * 256);
    this.raw(text.tagTablePrelude);
    for (const arm of this.s.msg.arms) this.print('\n    "{f}",', [zigString(arm.name)]);
    this.raw("\n};\n"); this.print(text.tagTableFence, [String(quota), zigIdent(this.s.msg.name)]);
  }
  entryPoints(): void {
    const model = zigIdent(this.s.model), msg = zigIdent(this.s.msg.name);
    this.raw(text.exportAttestation);
    for (const suffix of this.s.abi.exports) this.print("    std.mem.doNotOptimizeAway(abi.{f});\n", [zigIdent(suffix === "abi_version" ? "abi_version_fn" : suffix)]);
    this.raw("}\n");
    this.print(this.s.init_returns_cmd ? text.bootWithCommand : text.bootModel, [model]);
    this.print(this.s.update_returns_cmd ? text.updateWithCommand : text.updateModel,
      this.s.update_returns_cmd ? [model, model, msg] : [model, msg, model]);
    this.raw(text.dispatchPrelude);
    for (let i = 0; i < this.s.msg.arms.length; i++) this.dispatchArm(this.s.msg.arms[i], i);
    this.raw("    }\n");
    this.raw(this.s.update_returns_cmd ? "    return .{ .model = snapshotModel(), .cmd = cmd_ptr[0..cmd_len] };\n}\n" : "    return snapshotModel();\n}\n");
    if (this.s.has_subscriptions) this.print(text.subscriptions, [model]);
    this.print(text.commitModelRoot, [model, model]);
  }
  dispatchArm(arm: MsgArm, tag: number): void {
    const p = arm.payload, name = zigIdent(arm.name), t = String(tag);
    const direct = (entry: string, value: string): void => {
      this.print("        .{s} => |payload| abi.{s}({d}, {s}, &cmd_ptr, &cmd_len),\n", [name, entry, t, value]);
    };
    if (p.kind === "void") this.print("        .{s} => abi.dispatch_void({d}, &cmd_ptr, &cmd_len),\n", [name, t]);
    else if (p.kind === "bytes") direct("dispatch_bytes", "payload.ptr, payload.len");
    else if (p.kind === "number") direct("dispatch_number", p.class === "f64" ? "payload" : this.exactCall(this.slotPath(this.s.msg.name, arm.name), "payload"));
    else if (p.kind === "number_bytes") {
      let number = "payload." + zigIdent(p.number_field!);
      if (p.number_class === "i64") number = this.exactCall(this.numberBytesSlot(arm.name, p.number_field!), number);
      direct("dispatch_number_bytes", number + ", payload." + zigIdent(p.bytes_field!) + ".ptr, payload." + zigIdent(p.bytes_field!) + ".len");
    } else if (p.kind === "enum_ref") direct("dispatch_enum", "@intCast(@intFromEnum(payload))");
    else if (p.kind === "scalar") {
      if (p.type!.kind === "bool") direct("dispatch_bool", "@intFromBool(payload)");
      else if (p.type!.kind === "f64") direct("dispatch_number", "payload");
      else if (p.type!.kind === "i64") direct("dispatch_number", this.exactCall(this.slotPath(this.s.msg.name, arm.name), "payload"));
      else if (p.type!.kind === "bytes") direct("dispatch_bytes", "payload.ptr, payload.len");
      else throw new Error("unsupported validated scalar payload");
    } else {
      const indexes = p.kind === "record" ? scrollIndexes(this.s, p.name!) : null;
      if (indexes !== null) {
        const r = findRecord(this.s, p.name!)!;
        const scalars: string[] = [];
        for (const index of indexes) {
          const f = r.fields[index]; let value = "payload." + zigIdent(f.name);
          if (f.type.kind === "i64") value = this.exactCall(this.slotPath(r.name, f.name), value);
          scalars.push(value);
        }
        direct("dispatch_scroll_state", scalars.join(", "));
      } else {
        const entry = p.kind === "union_ref" && isTextInputUnion(this.s, p.name!) ? "dispatch_text_input" : "dispatch_record";
        this.print("        .{s} => |payload| {{\n            const encoded = shim_rt.encodeAlloc(@TypeOf(payload), payload, shim_rt.frameAllocator());\n            abi.{s}({d}, encoded.ptr, encoded.len, &cmd_ptr, &cmd_len);\n        }},\n", [name, entry, t]);
      }
    }
  }
  channels(): void {
    const c = this.s.channels, model = zigIdent(this.s.model), msg = zigIdent(this.s.msg.name);
    const hasView = this.s.abi.exports.includes("native_view");
    if (hasView) {
      this.raw(text.nativeView);
      this.print("pub fn nativeViewEvent(envelope: []const u8, arena: std.mem.Allocator) ?{f} {{\n    return decodeMsgEnvelope(envelope, arena);\n}}\n", [msg]);
    }
    const extensions = [
      { name: "native_virtual_requests", code: text.nativeVirtualRequests }, { name: "native_virtual_view", code: text.nativeVirtualView },
      { name: "native_media_view", code: text.nativeMediaView }, { name: "native_media_window_view", code: text.nativeMediaWindowView },
      { name: "native_window_view", code: text.nativeWindowView }, { name: "native_radio_policy", code: text.nativeRadioPolicy },
      { name: "native_tabs_policy", code: text.nativeTabsPolicy }, { name: "native_tree_policy", code: text.nativeTreePolicy },
      { name: "native_list_policy", code: text.nativeListPolicy }, { name: "native_menu_policy", code: text.nativeMenuPolicy },
      { name: "native_toggle_policy", code: text.nativeTogglePolicy }, { name: "native_accordion_policy", code: text.nativeAccordionPolicy },
      { name: "native_slider_policy", code: text.nativeSliderPolicy }, { name: "native_split_policy", code: text.nativeSplitPolicy },
      { name: "native_scroll_policy", code: text.nativeScrollPolicy }, { name: "native_resizable_policy", code: text.nativeResizablePolicy },
      { name: "native_text_policy", code: text.nativeTextPolicy }, { name: "native_timer_policy", code: text.nativeTimerPolicy },
      { name: "native_db_policy", code: text.nativeDbPolicy }, { name: "native_effect_policy", code: text.nativeEffectPolicy },
      { name: "native_stream_policy", code: text.nativeStreamPolicy }, { name: "native_window_policy", code: text.nativeWindowPolicy },
      { name: "native_theme_policy", code: text.nativeThemePolicy }, { name: "native_status_policy", code: text.nativeStatusPolicy },
    ];
    for (const e of extensions) if (this.s.abi.exports.includes(e.name)) this.raw(e.code);
    if (c.command_msg) this.print(text.commandChannel, [msg]);
    if (c.frame_msg) this.print(text.frameChannel, [model, msg]);
    if (c.key_msg) this.print(text.keyChannel, [msg]);
    if (c.pinch_msg) this.print(text.pinchChannel, [msg]);
    if (c.drop_msg) this.print(text.dropChannel, [msg]);
    if (c.appearance_msg !== null) this.print('\n/// The arm the host fills with the structural appearance record.\npub const appearanceMsg = "{f}";\n', [zigString(c.appearance_msg)]);
    if (c.chrome_msg !== null) this.print('\n/// The arm the host fills with the structural window-chrome record.\npub const chromeMsg = "{f}";\n', [zigString(c.chrome_msg)]);
    if (c.env_msgs.length > 0) {
      this.raw(text.envMessageTypes);
      for (const e of c.env_msgs) this.print('    .{{ .env = "{f}", .msg = "{f}" }},\n', [zigString(e.env), zigString(e.msg)]);
      this.raw("};\n");
    }
    if (c.command_msg || c.frame_msg || c.key_msg || c.pinch_msg || c.drop_msg || hasView) {
      this.print(text.decodeMessagePrelude, [msg, msg]);
      for (let i = 0; i < this.s.msg.arms.length; i++) {
        const a = this.s.msg.arms[i];
        if (a.payload.kind === "void") this.print("        {d} => {{\n            shim_rt.assertVoidPayload(header.payload);\n            return .{f};\n        }},\n", [String(i), zigIdent(a.name)]);
        else this.print('        {d} => return .{{ .{f} = shim_rt.decodeExact(@FieldType({f}, "{f}"), header.payload, arena) }},\n', [String(i), zigIdent(a.name), msg, zigString(a.name)]);
      }
      this.raw(text.decodeMessageEnd);
    }
  }
  helperPlumbing(): void { if (this.s.model_helpers.length > 0) this.raw(text.helperPlumbing); }
  snapshotPlumbing(): void { this.print(text.snapshotPlumbing, [this.input.snapshot_text, zigIdent(this.s.model), zigIdent(this.s.model), zigIdent(this.s.model)]); }
}
