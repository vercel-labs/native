//! core_facade.ts emission: the compiled-core ENTRY MODULE generated
//! from the same contract sidecar the Zig mirror derives from. One
//! sidecar, three projections — the host imports core_shim.zig, an
//! external core compiler consumes this module as its compile entry
//! (with the generated core_profile.json beside it), and the two sides
//! can never skew: types, declaration orders, number classes, wire
//! tags, and the canonical value encoding all derive from one artifact.
//!
//! The emitted module is the generated twin of a hand-written adapter:
//! it imports the AUTHOR'S core module (staged beside it, with its SDK
//! imports resolved to the staged ./sdk/ copies), owns the committed
//! model in module state, and exports the profile-declared dispatch
//! surface:
//!
//! - type re-exports for every named contract-table type, each from its
//!   own declaring module (the sidecar's origin facts) — the compiler's
//!   sidecar emitter reads the entry module's exported declarations;
//! - the exported-const channel conventions (appearanceMsg, chromeMsg,
//!   envMsgs) and the single name-resolved viewUnbound list;
//! - one exported wrapper per model helper, in declaration order (the
//!   compiled contract's model_helpers table and helper_call's index
//!   space both derive from it), with the inline wholeness proof on
//!   every i64-classed helper return;
//! - the designated shape-flag entries (init, coreUpdate, and — for a
//!   subscribing contract — coreSubscriptions), whose return shapes
//!   restate init_returns_cmd/update_returns_cmd/has_subscriptions;
//! - the ABI dispatch surface (boot_cmd, the nine dispatch entries, the
//!   wired channel entries, abi_subscriptions, model_snapshot, helper_call),
//!   decoding inbound payloads with the generated wire codec below and
//!   encoding results byte-identically to the transpiler lane;
//! - provable ingress everywhere a wire value crosses into an
//!   i64-classed slot: bind to a local, range-guard with ordered
//!   comparisons against +-(2^53 - 1) (which excludes NaN), and state
//!   wholeness with Math.trunc at the write.
//!
//! Deterministic: a pure function of the sidecar value, pinned by a
//! test. Everything module-internal lives in the reserved nscf name
//! space, which the fences below keep authored names out of.

const std = @import("std");
const sidecar_mod = @import("sidecar.zig");
const emit_mod = @import("emit.zig");

const Sidecar = sidecar_mod.Sidecar;
const TypeRef = sidecar_mod.TypeRef;
const IntegerClass = sidecar_mod.IntegerClass;

pub const Error = error{ Refused, OutOfMemory };

/// The exact-integer window an f64 carries, as the generated guards spell
/// it. Signed slots use `min_safe`; unsigned slots start at zero.
const max_safe = "9007199254740991";
const min_safe = "-9007199254740991";

fn integerLowerBound(class: IntegerClass) []const u8 {
    return if (class == .u64) "0" else min_safe;
}

/// The scroll-state field vocabulary (the mirror's routing twin in
/// emit.zig): a record arm carrying exactly these eight numeric fields
/// in either the TypeScript or canvas spelling also answers the dedicated
/// scroll entry. The ABI parameters use the TypeScript spellings.
const scroll_state_fields_ts = [_][]const u8{
    "offsetX",         "offsetY",
    "velocityX",       "velocityY",
    "viewportExtentX", "viewportExtentY",
    "contentExtentX",  "contentExtentY",
};
const scroll_state_fields_canvas = [_][]const u8{
    "offset_x",          "offset_y",
    "velocity_x",        "velocity_y",
    "viewport_extent_x", "viewport_extent_y",
    "content_extent_x",  "content_extent_y",
};

pub fn emitFacade(arena: std.mem.Allocator, sidecar: Sidecar, diags: *sidecar_mod.Diagnostics) Error![]const u8 {
    var emitter = FacadeEmitter{
        .arena = arena,
        .sidecar = sidecar,
        .diags = diags,
        .out = .empty,
    };
    try emitter.run();
    if (diags.hasErrors()) return error.Refused;
    return emitter.out.items;
}

/// TypeScript reserved words a declaration may not take (no quoting
/// escape exists on that side, unlike Zig's @"..." names).
const ts_reserved_words = [_][]const u8{
    "break",     "case",      "catch",  "class",   "const",      "continue",   "debugger",  "default",
    "delete",    "do",        "else",   "enum",    "export",     "extends",    "false",     "finally",
    "for",       "function",  "if",     "import",  "in",         "instanceof", "new",       "null",
    "return",    "super",     "switch", "this",    "throw",      "true",       "try",       "typeof",
    "var",       "void",      "while",  "with",    "let",        "static",     "yield",     "await",
    "interface", "type",      "number", "boolean", "string",     "object",     "undefined",
    // Intrinsic type keywords: a declaration under one would make every
    // reference bind the built-in, erasing the contract silently.
    "any",
    "unknown",   "never",     "bigint", "symbol",
    // Strict-mode reservations (modules are always strict).
     "implements", "package",    "private",   "protected",
    "public",    "arguments", "eval",
};

/// The value-space names this module itself exports; an authored helper
/// or type may not take one.
const fixed_exports = [_][]const u8{
    "init",                  "coreUpdate",        "coreSubscriptions", "boot_cmd",
    "dispatch_void",         "dispatch_bytes",    "dispatch_number",   "dispatch_number_bytes",
    "dispatch_bool",         "dispatch_enum",     "dispatch_record",   "dispatch_text_input",
    "dispatch_scroll_state", "abi_subscriptions", "model_snapshot",    "helper_call",
    "abi_command_msg",       "abi_frame_msg",     "abi_key_msg",       "abi_pinch_msg",
    "abi_drop_msg",          "appearanceMsg",     "chromeMsg",         "envMsgs",
    "viewUnbound",
};

/// Ambient VALUE bindings generated code calls directly. A model helper is
/// re-declared as an exported function in this module, so taking one of these
/// names would shadow the ambient and turn `Math.trunc`, `Buffer.from`, etc.
/// into member accesses on the wrapper itself.
const ambient_value_names = [_][]const u8{
    "Math", "Buffer", "Uint8Array", "Error", "String",
};

/// The wire-codec snippets, emitted exactly when generated code reaches
/// them (an unused module function is noise a strict compiler may
/// refuse). `use` marks dependencies transitively.
const Codec = enum {
    trap,
    read_u8,
    read_u32,
    read_f64,
    read_i64,
    read_i64_saturating,
    read_u64_saturating,
    read_bool,
    read_bytes_body,
    assert_consumed,
    sink,
    w_u8,
    w_u32,
    w_f64,
    w_i64,
    w_u64,
    w_bool,
    w_bytes,
    short_text,
    trunc_toward_zero,
    enum_index,
    ascii_string,
    cmd_encoder,
    sub_encoder,
};

const FacadeEmitter = struct {
    arena: std.mem.Allocator,
    sidecar: Sidecar,
    diags: *sidecar_mod.Diagnostics,
    out: std.ArrayListUnmanaged(u8),
    inlined: []const []const u8 = &.{},
    flattened: []const []const u8 = &.{},
    node_stored: []const []const u8 = &.{},
    used_codec: std.EnumSet(Codec) = .initEmpty(),
    /// Named types the generated code references in type position (the
    /// import list derives from it).
    referenced: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Whether the pinch channel's SDK vocabulary import is needed.
    needs_pinch_phase: bool = false,
    /// Whether the shared member-index teaching is needed.
    needs_member_trap: bool = false,
    /// Monotonic temp-name counter (unique const names inside one
    /// emitted function; reset at each function boundary).
    temp_counter: usize = 0,
    /// Deduped on-demand generation queues, drained by generatedTables.
    needed_enum_tables: std.ArrayListUnmanaged([]const u8) = .empty,
    needed_enum_indexes: std.ArrayListUnmanaged([]const u8) = .empty,
    needed_record_writers: std.ArrayListUnmanaged([]const u8) = .empty,
    needed_union_writers: std.ArrayListUnmanaged([]const u8) = .empty,
    needed_union_decoders: std.ArrayListUnmanaged([]const u8) = .empty,

    fn print(self: *FacadeEmitter, comptime fmt: []const u8, args: anytype) Error!void {
        const text = try std.fmt.allocPrint(self.arena, fmt, args);
        try self.out.appendSlice(self.arena, text);
    }

    fn raw(self: *FacadeEmitter, text: []const u8) Error!void {
        try self.out.appendSlice(self.arena, text);
    }

    fn use(self: *FacadeEmitter, id: Codec) void {
        if (self.used_codec.contains(id)) return;
        self.used_codec.insert(id);
        // Dependency closure: every snippet marks what its own body
        // calls, so the emitted set is always self-contained.
        const deps: []const Codec = switch (id) {
            .read_i64, .read_i64_saturating, .read_u64_saturating => &.{.read_u32},
            .read_u8, .read_u32, .read_f64, .read_bool, .read_bytes_body, .assert_consumed => &.{.trap},
            .w_u32 => &.{.sink},
            .w_u8, .w_f64, .w_bool => &.{.sink},
            .w_i64 => &.{ .w_u32, .trunc_toward_zero, .trap },
            .w_u64 => &.{ .w_u32, .trunc_toward_zero, .trap },
            .w_bytes => &.{.w_u32},
            .short_text => &.{ .sink, .trap },
            .enum_index => &.{.trap},
            .cmd_encoder => &.{ .w_u8, .w_f64, .w_bytes, .short_text, .enum_index, .trap },
            .sub_encoder => &.{ .w_u8, .w_f64, .short_text },
            else => &.{},
        };
        for (deps) |dep| self.use(dep);
    }

    /// Note a named type the generated code spells in type position.
    fn reference(self: *FacadeEmitter, name: []const u8) Error!void {
        // Current sidecars leave generated-only table names originless.
        // They either flatten at their sole reference site or validation
        // refuses them, so importing one would always name a nonexistent
        // authored export (generic monomorphizations are the common case).
        if (self.isGeneratedOnlyType(name)) return;
        if (!self.isExportedType(name)) return;
        if (nameListed(self.referenced.items, name)) return;
        try self.referenced.append(self.arena, name);
    }

    // ----------------------------------------------------- fact lookup

    /// The authored member name of a single-payload arm. Validation requires
    /// the fact everywhere emission consumes it; `value` remains only as an
    /// unreachable-safe spelling for bare/multi-field branches that compute
    /// this local before switching on their payload shape.
    fn memberOf(_: *FacadeEmitter, member: ?[]const u8) []const u8 {
        return member orelse "value";
    }

    /// The declaring module of a table type. Facade validation requires an
    /// origin for every authored table; the entry fallback is only for Msg,
    /// whose root designation is not duplicated in the type tables.
    fn originOf(self: *FacadeEmitter, name: []const u8) []const u8 {
        for (self.sidecar.types.structs) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.origin orelse self.entryBasename();
        }
        for (self.sidecar.types.enums) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.origin orelse self.entryBasename();
        }
        for (self.sidecar.types.unions) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.origin orelse self.entryBasename();
        }
        return self.entryBasename();
    }

    fn entryBasename(self: *FacadeEmitter) []const u8 {
        return std.fs.path.basenamePosix(self.sidecar.entry);
    }

    /// A table name synthesized by the transpiler rather than declared in
    /// an authored module. These names flatten at their one legal reference
    /// site or refuse; they are never imports or re-exports.
    fn isGeneratedOnlyType(self: *FacadeEmitter, name: []const u8) bool {
        if (std.mem.eql(u8, name, self.sidecar.model) or std.mem.eql(u8, name, self.sidecar.msg.name)) return false;
        for (self.sidecar.types.structs) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.origin == null;
        }
        for (self.sidecar.types.enums) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.origin == null;
        }
        for (self.sidecar.types.unions) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.origin == null;
        }
        return false;
    }

    fn isExportedType(self: *FacadeEmitter, name: []const u8) bool {
        if (std.mem.eql(u8, name, self.sidecar.model) or std.mem.eql(u8, name, self.sidecar.msg.name)) return true;
        for (self.sidecar.types.structs) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.exported;
        }
        for (self.sidecar.types.enums) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.exported;
        }
        for (self.sidecar.types.unions) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.exported;
        }
        return true;
    }

    fn slotClassAt(self: *FacadeEmitter, path: []const u8) ?IntegerClass {
        for (self.sidecar.integer_slots) |entry| {
            if (std.mem.eql(u8, entry.slot, path)) return entry.class;
        }
        return null;
    }

    fn slotClass(self: *FacadeEmitter, container: []const u8, member: []const u8) ?IntegerClass {
        const path = std.fmt.allocPrint(self.arena, "{s}.{s}", .{ container, member }) catch return null;
        return self.slotClassAt(path);
    }

    fn nestedSlotClass(self: *FacadeEmitter, container: []const u8, member: []const u8, field: []const u8) ?IntegerClass {
        const path = std.fmt.allocPrint(self.arena, "{s}.{s}.{s}", .{ container, member, field }) catch return null;
        return self.slotClassAt(path);
    }

    /// The integer writer for a slot: unsigned twin for u64-attested
    /// slots, two's complement otherwise.
    fn intWriter(self: *FacadeEmitter, container: []const u8, member: []const u8) []const u8 {
        if (self.slotClass(container, member)) |class| {
            if (class == .u64) {
                self.use(.w_u64);
                return "nscfWU64";
            }
        }
        self.use(.w_i64);
        return "nscfWI64";
    }

    // ------------------------------------------------------------- run

    fn run(self: *FacadeEmitter) Error!void {
        self.inlined = try emit_mod.inlinedTableNames(self.arena, self.sidecar);
        self.flattened = try self.flattenedTableNames();
        self.node_stored = try self.nodeStoredTableNames();
        self.validateFacadeFacts();
        try self.validateNames();
        self.validateOptionalDepth();
        if (self.diags.hasErrors()) return;

        // The body emits first into its own buffer so the import lists
        // (referenced types, used codec snippets) can assemble after the
        // walk; the final module is header + imports + body.
        var body_emitter = FacadeEmitter{
            .arena = self.arena,
            .sidecar = self.sidecar,
            .diags = self.diags,
            .out = .empty,
            .inlined = self.inlined,
            .flattened = self.flattened,
            .node_stored = self.node_stored,
        };
        const body = &body_emitter;
        try body.privateTypeDeclarations();
        try body.channelConsts();
        try body.unboundDecl();
        try body.helperWrappers();
        try body.entryPoints();
        try body.tagTable();
        try body.dispatchSurface();
        try body.channelEntries();
        try body.postCycle();
        try body.helperCall();
        try body.generatedTables();
        try body.codecSection();
        if (self.diags.hasErrors()) return;

        try self.header();
        try self.imports(body);
        try self.reexports();
        try self.out.appendSlice(self.arena, body.out.items);
    }

    // ------------------------------------------------------- fencing

    /// Facade/profile emission needs facts that format-1 readers keep
    /// optional for backward-compatible MIRROR generation. An older sidecar
    /// still generates core_shim.zig, but it cannot truthfully reconstruct
    /// authored module paths or payload property names; refuse instead of
    /// guessing an entry-module origin or a `value` member.
    fn validateFacadeFacts(self: *FacadeEmitter) void {
        const model = sidecar_mod.findStruct(self.sidecar.types, self.sidecar.model);
        if (model == null or model.?.origin == null) {
            self.diags.flag("types", "the model declaration carries no authored type-origin fact — this sidecar predates facade metadata; regenerate it with the current compiler before requesting --facade, --profile, or --check", .{});
        }
        for (self.sidecar.msg.arms) |arm| {
            if (self.msgArmNeedsMember(arm) and arm.member == null) {
                self.diags.flag("msg.arms", "arm \"{s}\" carries one payload but no authored member-name fact — this sidecar predates facade metadata; regenerate it with the current compiler", .{arm.name});
            }
        }
        for (self.sidecar.types.unions) |entry| {
            for (entry.arms) |arm| {
                if (arm.payload == .void or self.synthesizedRecordOf(arm.payload, entry.name, arm.name) != null) continue;
                if (arm.member == null) {
                    self.diags.flag("types.unions", "arm \"{s}\" of \"{s}\" carries one payload but no authored member-name fact — this sidecar predates facade metadata; regenerate it with the current compiler", .{ arm.name, entry.name });
                }
            }
        }
    }

    fn msgArmNeedsMember(self: *FacadeEmitter, arm: sidecar_mod.MsgArm) bool {
        return switch (arm.payload) {
            .void, .number_bytes => false,
            .record => self.synthesizedRecordOf(recordPayloadRef(arm.payload), self.sidecar.msg.name, arm.name) == null,
            else => true,
        };
    }

    fn validateNames(self: *FacadeEmitter) Error!void {
        // Declaration names (type-table entries and the message union)
        // must be plain TypeScript identifiers: TypeScript has no
        // quoted-declaration escape, and re-export lists take
        // identifiers verbatim.
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.sidecar.types.structs) |entry| try names.append(self.arena, entry.name);
        for (self.sidecar.types.enums) |entry| try names.append(self.arena, entry.name);
        for (self.sidecar.types.unions) |entry| try names.append(self.arena, entry.name);
        try names.append(self.arena, self.sidecar.msg.name);
        try names.append(self.arena, self.sidecar.model);

        for (names.items) |name| {
            if (pipelineIdentifierIssue(name, .declaration)) |issue| {
                self.diags.flag("types", "type name \"{s}\" {s} — the facade must stay declarable end to end (TypeScript source, then the compiled module, which takes identifiers verbatim); rename it in the core source", .{ name, issue });
            }
            // Ambient globals the generated module leans on: a
            // re-exported declaration under one would shadow them out
            // from under the codec.
            if (std.mem.eql(u8, name, "Uint8Array")) {
                self.diags.flag("types", "\"Uint8Array\" shadows the ambient byte type every encoder in the generated facade uses; rename the type in the core source", .{});
            }
            if (std.mem.eql(u8, name, "Buffer")) {
                self.diags.flag("types", "\"Buffer\" shadows the ambient buffer type the generated f64 codec uses; rename the type in the core source", .{});
            }
            if (self.sidecar.channels.pinch_msg and std.mem.eql(u8, name, "PinchPhase")) {
                self.diags.flag("types", "\"PinchPhase\" collides with the SDK vocabulary the wired pinch channel imports; rename the type in the core source", .{});
            }
            if (self.sidecar.channels.drop_msg and std.mem.eql(u8, name, "FileDropPoint")) {
                self.diags.flag("types", "\"FileDropPoint\" collides with the SDK vocabulary the wired file-drop channel imports; rename the type in the core source", .{});
            }
        }
        // Arm, member, and field names become the compiled module's
        // union members and struct fields verbatim.
        for (self.sidecar.msg.arms) |arm| {
            if (pipelineIdentifierIssue(arm.name, .member)) |issue| {
                self.diags.flag("msg.arms", "arm \"{s}\" {s} — the facade must stay declarable end to end; rename it in the core source", .{ arm.name, issue });
            }
            if (arm.member) |member| {
                if (std.mem.eql(u8, member, "kind")) {
                    self.diags.flag("msg.arms", "arm \"{s}\" names its payload member \"kind\", the discriminator's own spelling — the constructed arm object would declare it twice; rename the member in the core source", .{arm.name});
                }
            }
        }
        for (self.sidecar.types.unions) |entry| {
            for (entry.arms) |arm| {
                if (pipelineIdentifierIssue(arm.name, .member)) |issue| {
                    self.diags.flag("types.unions", "arm \"{s}\" of \"{s}\" {s} — the facade must stay declarable end to end; rename it in the core source", .{ arm.name, entry.name, issue });
                }
                if (arm.member) |member| {
                    if (std.mem.eql(u8, member, "kind")) {
                        self.diags.flag("types.unions", "arm \"{s}\" of \"{s}\" names its payload member \"kind\", the discriminator's own spelling; rename the member in the core source", .{ arm.name, entry.name });
                    }
                }
            }
        }
        for (self.sidecar.types.enums) |entry| {
            for (entry.members) |member| {
                if (pipelineIdentifierIssue(member, .member)) |issue| {
                    self.diags.flag("types.enums", "member \"{s}\" of \"{s}\" {s} — the facade must stay declarable end to end; rename it in the core source", .{ member, entry.name, issue });
                }
            }
            if (entry.members.len < 2) {
                self.diags.flag("types", "enum \"{s}\" has one member — a single string literal is not a union in the projected subset, so no source can author it; give the state a second member or fold it away in the core source", .{entry.name});
            }
        }
        for (self.sidecar.types.structs) |entry| {
            for (entry.fields) |field| {
                if (pipelineIdentifierIssue(field.name, .member)) |issue| {
                    self.diags.flag("types", "field \"{s}\" {s} — the facade must stay declarable end to end; rename it in the core source", .{ field.name, issue });
                }
                if (std.mem.startsWith(u8, field.name, "nsc_core_") or std.mem.startsWith(u8, field.name, "nscf")) {
                    self.diags.flag("types", "field \"{s}\" takes the facade's reserved nsc name space; rename it in the core source", .{field.name});
                }
            }
        }
        for (self.sidecar.msg.arms) |arm| {
            switch (arm.payload) {
                .number_bytes => |desc| {
                    for ([_][]const u8{ desc.number_field, desc.bytes_field }) |field_name| {
                        if (pipelineIdentifierIssue(field_name, .member)) |issue| {
                            self.diags.flag("msg.arms", "field \"{s}\" {s} — the facade must stay declarable end to end; rename it in the core source", .{ field_name, issue });
                        }
                        if (std.mem.eql(u8, field_name, "kind")) {
                            self.diags.flag("msg.arms", "arm \"{s}\" flattens a field spelled \"kind\" beside the message discriminator of the same name; rename the field in the core source", .{arm.name});
                        }
                        if (std.mem.startsWith(u8, field_name, "nsc_core_") or std.mem.startsWith(u8, field_name, "nscf")) {
                            self.diags.flag("msg.arms", "field \"{s}\" takes the facade's reserved nsc name space; rename it in the core source", .{field_name});
                        }
                    }
                },
                .record => {
                    if (self.synthesizedRecordOf(recordPayloadRef(arm.payload), self.sidecar.msg.name, arm.name)) |record| {
                        for (record.fields) |field| {
                            if (std.mem.eql(u8, field.name, "kind")) {
                                self.diags.flag("msg.arms", "arm \"{s}\" flattens a field spelled \"kind\" beside the message discriminator of the same name; rename the field in the core source", .{arm.name});
                            }
                        }
                    }
                },
                else => {},
            }
        }
        for (self.sidecar.types.unions) |entry| {
            for (entry.arms) |arm| {
                if (arm.payload == .void) continue;
                if (self.synthesizedRecordOf(arm.payload, entry.name, arm.name)) |record| {
                    for (record.fields) |field| {
                        if (std.mem.eql(u8, field.name, "kind")) {
                            self.diags.flag("types.unions", "arm \"{s}\" of \"{s}\" flattens a field spelled \"kind\" beside the arm discriminator of the same name; rename the field in the core source", .{ arm.name, entry.name });
                        }
                    }
                }
            }
        }
        // Helper names become this module's own exported wrapper
        // functions, and their aliases live in the nscf import space.
        for (self.sidecar.model_helpers) |helper| {
            if (!isTsIdentifier(helper.name) or pipelineIdentifierIssue(helper.name, .declaration) != null) {
                self.diags.flag("model_helpers", "helper \"{s}\" is not declarable as an exported function in both pipeline languages; rename it in the core source", .{helper.name});
                continue;
            }
            if (std.mem.startsWith(u8, helper.name, "nsc_core_") or std.mem.startsWith(u8, helper.name, "nscf")) {
                self.diags.flag("model_helpers", "helper \"{s}\" takes the facade's reserved nsc name space; rename it in the core source", .{helper.name});
            }
            for (fixed_exports) |fixed| {
                if (std.mem.eql(u8, helper.name, fixed)) {
                    self.diags.flag("model_helpers", "helper \"{s}\" collides with a declaration the generated facade itself must export; rename it in the core source", .{helper.name});
                }
            }
            for (ambient_value_names) |ambient| {
                if (std.mem.eql(u8, helper.name, ambient)) {
                    self.diags.flag("model_helpers", "helper \"{s}\" shadows an ambient value the generated facade calls; rename it in the core source", .{helper.name});
                }
            }
            if (helper.params.len > 0) {
                self.diags.flag("model_helpers", "helper \"{s}\" declares extra parameters — the generated dispatch surface carries model-only helpers (no producer emits parameters today); drop them in the core source", .{helper.name});
            }
        }
        for (self.sidecar.types.structs) |entry| try self.fenceDecl(entry.name);
        for (self.sidecar.types.enums) |entry| try self.fenceDecl(entry.name);
        for (self.sidecar.types.unions) |entry| try self.fenceDecl(entry.name);
        try self.fenceDecl(self.sidecar.msg.name);

        // An originless table name in a current sidecar is compiler-created,
        // not a TypeScript export the facade can import. Single-use inline
        // records disappear back into their arm literals; every other such
        // name (most notably a monomorphized generic like `Box__Item`) would
        // make the facade invalid, and the external library compiler cannot
        // project the authored generic contract surface either. Refuse at the
        // generator boundary instead of emitting a downstream failure.
        for (self.sidecar.types.structs) |entry| {
            if (self.isGeneratedOnlyType(entry.name) and !nameListed(self.flattened, entry.name)) {
                self.diags.flag("types", "compiler-generated table type \"{s}\" has no authored TypeScript declaration the facade can name — generic instantiations cannot cross the compiled-core contract surface yet; replace the contract-facing generic with an authored concrete record", .{entry.name});
            }
        }
        for (self.sidecar.types.enums) |entry| {
            if (self.isGeneratedOnlyType(entry.name)) {
                self.diags.flag("types", "compiler-generated table type \"{s}\" has no authored TypeScript declaration the facade can name — generic instantiations cannot cross the compiled-core contract surface yet; replace the contract-facing generic with an authored concrete type", .{entry.name});
            }
        }
        for (self.sidecar.types.unions) |entry| {
            if (self.isGeneratedOnlyType(entry.name)) {
                self.diags.flag("types", "compiler-generated table type \"{s}\" has no authored TypeScript declaration the facade can name — generic instantiations cannot cross the compiled-core contract surface yet; replace the contract-facing generic with an authored concrete union", .{entry.name});
            }
        }

        // Declaration form spells storage ONCE per record, so a record
        // referenced both by node and by value has no projection — one
        // declaration cannot say both. (The transpiled lane decides
        // storage per TYPE, so its contracts never mix; a hand contract
        // that does must split the type.)
        var value_refs: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.sidecar.types.structs) |entry| {
            for (entry.fields) |field| try noteValueRefs(&value_refs, self.arena, field.type);
        }
        for (self.sidecar.types.unions) |entry| {
            for (entry.arms) |arm| try noteValueRefs(&value_refs, self.arena, arm.payload);
        }
        for (self.sidecar.model_helpers) |helper| {
            try noteValueRefs(&value_refs, self.arena, helper.returns);
            for (helper.params) |param| try noteValueRefs(&value_refs, self.arena, param);
        }
        for (self.sidecar.msg.arms) |arm| {
            switch (arm.payload) {
                .scalar => |ref| try noteValueRefs(&value_refs, self.arena, ref),
                else => {},
            }
        }
        for (value_refs.items) |name| {
            if (nameListed(self.node_stored, name)) {
                self.diags.flag("types", "\"{s}\" is stored by reference at one site and by value at another — the projection states storage once per declaration, so one record cannot say both; split the type in the core source", .{name});
            }
        }

        // Value records the MODEL keeps carry scalar fields only, and
        // model sequences carry reference-stored records: the compiled
        // core commits by-value records shallowly, so heap-backed
        // fields would dangle across frames and by-value arrays have no
        // commit walk. Refuse here, where the teaching can name the
        // record, instead of emitting a facade its compiler refuses.
        try self.validateModelValueRecords();

        // The host-constructed channels build their event record's
        // fields DIRECTLY on the named arm, so the arm's record must
        // flatten into the arm literal (the single-use synthesized
        // shape). A shared named record would project as a nested
        // member no host construction can fill.
        if (self.sidecar.channels.appearance_msg) |arm_name| {
            try self.requireFlattenedChannelArm("channels.appearance_msg", arm_name);
        }
        if (self.sidecar.channels.chrome_msg) |arm_name| {
            try self.requireFlattenedChannelArm("channels.chrome_msg", arm_name);
        }
    }

    /// Walk the model tree and refuse the value-record shapes the
    /// compiled core cannot carry: a model-kept value record with a
    /// non-scalar field, and a model sequence of value records.
    fn validateModelValueRecords(self: *FacadeEmitter) Error!void {
        var visited: std.ArrayListUnmanaged([]const u8) = .empty;
        const model = sidecar_mod.findStruct(self.sidecar.types, self.sidecar.model) orelse return;
        for (model.fields) |field| {
            try self.visitModelRef(&visited, field.type);
        }
    }

    fn visitModelRef(self: *FacadeEmitter, visited: *std.ArrayListUnmanaged([]const u8), ref: TypeRef) Error!void {
        switch (ref) {
            .value => |name| {
                if (nameListed(visited.items, name)) return;
                try visited.append(self.arena, name);
                const entry = sidecar_mod.findStruct(self.sidecar.types, name) orelse return;
                for (entry.fields) |field| {
                    const scalar = switch (field.type) {
                        .f64, .i64, .bool, .enum_ref => true,
                        else => false,
                    };
                    if (!scalar) {
                        self.diags.flag("types", "\"{s}\" is a value-stored record the model keeps, but field \"{s}\" is not a scalar — the compiled projection commits value records shallowly, so heap-backed fields would dangle across frames; store \"{s}\" by reference in the core source", .{ name, field.name, name });
                        break;
                    }
                }
            },
            .node => |name| {
                if (nameListed(visited.items, name)) return;
                try visited.append(self.arena, name);
                const entry = sidecar_mod.findStruct(self.sidecar.types, name) orelse return;
                for (entry.fields) |field| {
                    try self.visitModelRef(visited, field.type);
                }
            },
            .union_ref => |name| {
                if (nameListed(visited.items, name)) return;
                try visited.append(self.arena, name);
                const entry = sidecar_mod.findUnion(self.sidecar.types, name) orelse return;
                for (entry.arms) |arm| {
                    try self.visitModelRef(visited, arm.payload);
                }
            },
            .slice => |elem| {
                const element = if (elem.* == .optional) elem.optional.* else elem.*;
                if (element == .value) {
                    self.diags.flag("types", "a model sequence holds \"{s}\" by value — sequences the model keeps carry reference-stored records (the compiled projection has no by-value sequence commit); store \"{s}\" by reference in the core source", .{ element.value, element.value });
                }
                try self.visitModelRef(visited, elem.*);
            },
            .optional => |inner| try self.visitModelRef(visited, inner.*),
            else => {},
        }
    }

    /// Refuse a host-constructed channel arm whose record does not
    /// flatten into its arm literal.
    fn requireFlattenedChannelArm(self: *FacadeEmitter, at: []const u8, arm_name: []const u8) Error!void {
        const arm = sidecar_mod.findArm(self.sidecar.msg, arm_name) orelse return;
        switch (arm.payload) {
            .record => |name| {
                if (nameListed(self.flattened, name)) return;
                self.diags.flag(at, "arm \"{s}\" carries the named record \"{s}\", which the projection cannot flatten into the arm (the host fills the event's fields directly on the arm) — declare the event's fields inline on the arm in the core source", .{ arm_name, name });
            },
            else => {},
        }
    }

    fn fenceDecl(self: *FacadeEmitter, name: []const u8) Error!void {
        if (name.len == 0) return;
        if (std.mem.startsWith(u8, name, "nsc_core_") or std.mem.startsWith(u8, name, "nscf")) {
            self.diags.flag("types", "\"{s}\" collides with the facade's reserved nsc name space; rename it in the core source", .{name});
            return;
        }
        for (fixed_exports) |decl| {
            if (std.mem.eql(u8, name, decl)) {
                self.diags.flag("types", "\"{s}\" collides with a declaration the generated facade itself must make; rename it in the core source", .{name});
            }
        }
    }

    /// TypeScript's null carries exactly one absence level, so a nested
    /// optional has no faithful projection (its own source language
    /// cannot author one either: `T | null | null` collapses).
    fn validateOptionalDepth(self: *FacadeEmitter) void {
        for (self.sidecar.types.structs, 0..) |entry, index| {
            for (entry.fields, 0..) |field, field_index| {
                self.flagNestedOptional(field.type, false, pathText(self.arena, "types.structs[{d}].fields[{d}].type", .{ index, field_index }));
            }
        }
        for (self.sidecar.types.unions, 0..) |entry, index| {
            for (entry.arms, 0..) |arm, arm_index| {
                self.flagNestedOptional(arm.payload, false, pathText(self.arena, "types.unions[{d}].arms[{d}].payload", .{ index, arm_index }));
            }
        }
        for (self.sidecar.model_helpers, 0..) |helper, index| {
            self.flagNestedOptional(helper.returns, false, pathText(self.arena, "model_helpers[{d}].returns", .{index}));
            for (helper.params, 0..) |param, param_index| {
                self.flagNestedOptional(param, false, pathText(self.arena, "model_helpers[{d}].params[{d}]", .{ index, param_index }));
            }
        }
        for (self.sidecar.msg.arms, 0..) |arm, index| {
            switch (arm.payload) {
                .scalar => |ref| self.flagNestedOptional(ref, false, pathText(self.arena, "msg.arms[{d}].payload.type", .{index})),
                else => {},
            }
        }
    }

    fn flagNestedOptional(self: *FacadeEmitter, ref: TypeRef, inside_optional: bool, at: []const u8) void {
        switch (ref) {
            .optional => |inner| {
                if (inside_optional) {
                    self.diags.flag(at, "a nested optional has no TypeScript projection — one null carries one absence level, and the source language cannot author a second; flatten the state in the core source", .{});
                    return;
                }
                self.flagNestedOptional(inner.*, true, at);
            },
            .slice => |elem| self.flagNestedOptional(elem.*, false, at),
            else => {},
        }
    }

    // ------------------------------------------- header and imports

    fn header(self: *FacadeEmitter) Error!void {
        try self.print(
            \\// Generated by corewire from this app's core.contract.json — the
            \\// compiled-core entry module. It imports the author's core module
            \\// (staged beside this file with its SDK imports resolved locally),
            \\// owns the committed model in module state, and exports the
            \\// profile-declared dispatch surface. Inbound payloads decode
            \\// through the generated wire codec below; returned Cmd/Sub data
            \\// encodes through the same codec's v3 wires — byte-identical to
            \\// the transpiler lane's output. The same sidecar generates the
            \\// host's Zig mirror (core_shim.zig), so the two sides carry one
            \\// set of types, wire tags, field orders, and byte encodings by
            \\// construction. Do not edit; regenerate from the sidecar.
            \\//
            \\// Contract identity: entry {s}, compiler {s}, build_id
            \\// {x:0>16}.
            \\
        , .{ try commentText(self.arena, self.sidecar.entry), try commentText(self.arena, self.sidecar.compiler_version), self.sidecar.build_id });
    }

    /// The import block: the author's behavioral exports under nscf
    /// aliases, the referenced contract types from their declaring
    /// modules, and the SDK effect types the codec spells.
    fn imports(self: *FacadeEmitter, body: *FacadeEmitter) Error!void {
        const entry_module = try self.importPath(self.entryBasename());
        // Behavioral value imports, all from the entry module.
        var values: std.ArrayListUnmanaged([]const u8) = .empty;
        try values.append(self.arena, "initialModel as nscfInitialModel");
        try values.append(self.arena, "update as nscfUpdate");
        if (self.sidecar.has_subscriptions) try values.append(self.arena, "subscriptions as nscfSubscriptions");
        if (self.sidecar.channels.command_msg) try values.append(self.arena, "commandMsg as nscfChanCommandMsg");
        if (self.sidecar.channels.frame_msg) try values.append(self.arena, "frameMsg as nscfChanFrameMsg");
        if (self.sidecar.channels.key_msg) try values.append(self.arena, "keyMsg as nscfChanKeyMsg");
        if (self.sidecar.channels.pinch_msg) try values.append(self.arena, "pinchMsg as nscfChanPinchMsg");
        if (self.sidecar.channels.drop_msg) try values.append(self.arena, "dropMsg as nscfChanDropMsg");
        for (self.sidecar.model_helpers) |helper| {
            try values.append(self.arena, try std.fmt.allocPrint(self.arena, "{s} as nscfH_{s}", .{ helper.name, helper.name }));
        }
        try self.raw("\nimport {\n");
        for (values.items) |item| try self.print("  {s},\n", .{item});
        try self.print("}} from {s};\n", .{entry_module});

        // Referenced contract types, grouped by declaring module in
        // first-reference order (Model and Msg lead).
        var groups: std.ArrayListUnmanaged(struct { origin: []const u8, names: std.ArrayListUnmanaged([]const u8) }) = .empty;
        var ordered: std.ArrayListUnmanaged([]const u8) = .empty;
        try ordered.append(self.arena, self.sidecar.model);
        try ordered.append(self.arena, self.sidecar.msg.name);
        for (body.referenced.items) |name| {
            if (!nameListed(ordered.items, name)) try ordered.append(self.arena, name);
        }
        for (ordered.items) |name| {
            const origin = self.originOf(name);
            const group = for (groups.items) |*candidate| {
                if (std.mem.eql(u8, candidate.origin, origin)) break candidate;
            } else blk: {
                try groups.append(self.arena, .{ .origin = origin, .names = .empty });
                break :blk &groups.items[groups.items.len - 1];
            };
            try group.names.append(self.arena, name);
        }
        for (groups.items) |group| {
            try self.raw("import type { ");
            for (group.names.items, 0..) |name, index| {
                try self.print("{s}{s}", .{ if (index == 0) "" else ", ", name });
            }
            try self.print(" }} from {s};\n", .{try self.importPath(group.origin)});
        }
        // The SDK effect vocabulary the codec spells.
        const needs_cmd = body.used_codec.contains(.cmd_encoder);
        const needs_sub = body.used_codec.contains(.sub_encoder);
        if (needs_cmd and needs_sub) {
            try self.raw("import type { Cmd as nscfCmd, Sub as nscfSub } from \"./sdk/core.ts\";\n");
        } else if (needs_cmd) {
            try self.raw("import type { Cmd as nscfCmd } from \"./sdk/core.ts\";\n");
        } else if (needs_sub) {
            try self.raw("import type { Sub as nscfSub } from \"./sdk/core.ts\";\n");
        }
        // The pinch channel's SDK vocabulary (declared in the SDK's
        // events module, outside the contract tables).
        if (body.needs_pinch_phase) {
            try self.raw("import type { PinchPhase } from \"./sdk/events.ts\";\n");
        }
        if (self.sidecar.channels.drop_msg) {
            try self.raw("import type { FileDropPoint } from \"./sdk/events.ts\";\n");
        }
        self.needs_pinch_phase = body.needs_pinch_phase;
    }

    fn importPath(self: *FacadeEmitter, origin: []const u8) Error![]const u8 {
        return std.fmt.allocPrint(self.arena, "\"./{s}\"", .{try tsString(self.arena, origin)});
    }

    /// Type re-exports: the contract type designations the compiler's
    /// sidecar section names — every named (non-synthesized) table type,
    /// re-exported verbatim from its own declaring module.
    fn reexports(self: *FacadeEmitter) Error!void {
        var ordered: std.ArrayListUnmanaged([]const u8) = .empty;
        try ordered.append(self.arena, self.sidecar.model);
        try ordered.append(self.arena, self.sidecar.msg.name);
        for (self.sidecar.types.structs) |entry| {
            if (nameListed(self.inlined, entry.name)) continue;
            if (self.isGeneratedOnlyType(entry.name)) continue;
            if (!entry.exported) continue;
            if (!nameListed(ordered.items, entry.name)) try ordered.append(self.arena, entry.name);
        }
        for (self.sidecar.types.enums) |entry| {
            if (self.isGeneratedOnlyType(entry.name)) continue;
            if (!entry.exported) continue;
            if (!nameListed(ordered.items, entry.name)) try ordered.append(self.arena, entry.name);
        }
        for (self.sidecar.types.unions) |entry| {
            if (self.isGeneratedOnlyType(entry.name)) continue;
            if (!entry.exported) continue;
            if (!nameListed(ordered.items, entry.name)) try ordered.append(self.arena, entry.name);
        }
        var groups: std.ArrayListUnmanaged(struct { origin: []const u8, names: std.ArrayListUnmanaged([]const u8) }) = .empty;
        for (ordered.items) |name| {
            const origin = self.originOf(name);
            const group = for (groups.items) |*candidate| {
                if (std.mem.eql(u8, candidate.origin, origin)) break candidate;
            } else blk: {
                try groups.append(self.arena, .{ .origin = origin, .names = .empty });
                break :blk &groups.items[groups.items.len - 1];
            };
            try group.names.append(self.arena, name);
        }
        try self.raw(
            \\
            \\// The contract type designations the sidecar section names — the
            \\// author's exported declarations re-exported verbatim. Private
            \\// reachable declarations have structural twins below instead: their
            \\// authored modules expose no name this facade can import.
            \\
        );
        for (groups.items) |group| {
            try self.raw("export type { ");
            for (group.names.items, 0..) |name, index| {
                try self.print("{s}{s}", .{ if (index == 0) "" else ", ", name });
            }
            try self.print(" }} from {s};\n", .{try self.importPath(group.origin)});
        }
    }

    /// Structural twins for authored table types their declaring modules do
    /// not export. They stay module-private too: generated readers/writers can
    /// name the contract shape without inventing a public authoring surface.
    fn privateTypeDeclarations(self: *FacadeEmitter) Error!void {
        var any = false;
        for (self.sidecar.types.structs) |entry| if (!entry.exported) {
            any = true;
            break;
        };
        if (!any) for (self.sidecar.types.enums) |entry| if (!entry.exported) {
            any = true;
            break;
        };
        if (!any) for (self.sidecar.types.unions) |entry| if (!entry.exported) {
            any = true;
            break;
        };
        if (!any) return;

        try self.raw(
            \\
            \\// Private contract-table declarations, reconstructed structurally
            \\// because their authored modules expose no importable designation.
            \\
        );
        for (self.sidecar.types.structs) |entry| {
            if (entry.exported) continue;
            try self.print("type {s} = {{\n", .{entry.name});
            for (entry.fields) |field| {
                try self.print("  readonly {s}: {s};\n", .{ try tsProp(self.arena, field.name), try self.spellRef(field.type) });
            }
            try self.raw("};\n\n");
        }
        for (self.sidecar.types.enums) |entry| {
            if (entry.exported) continue;
            try self.print("type {s} = ", .{entry.name});
            for (entry.members, 0..) |member, index| {
                try self.print("{s}\"{s}\"", .{ if (index == 0) "" else " | ", try tsString(self.arena, member) });
            }
            try self.raw(";\n\n");
        }
        for (self.sidecar.types.unions) |entry| {
            if (entry.exported) continue;
            try self.print("type {s} =\n", .{entry.name});
            for (entry.arms) |arm| {
                try self.print("  | {{ readonly kind: \"{s}\"", .{try tsString(self.arena, arm.name)});
                if (arm.payload != .void) {
                    if (self.synthesizedRecordOf(arm.payload, entry.name, arm.name)) |record| {
                        for (record.fields) |field| {
                            try self.print("; readonly {s}: {s}", .{ try tsProp(self.arena, field.name), try self.spellRef(field.type) });
                        }
                    } else {
                        try self.print("; readonly {s}: {s}", .{ try tsProp(self.arena, self.memberOf(arm.member)), try self.spellRef(arm.payload) });
                    }
                }
                try self.raw(" }\n");
            }
            try self.raw(";\n\n");
        }
    }

    // -------------------------------------- channel consts and unbound

    fn channelConsts(self: *FacadeEmitter) Error!void {
        if (self.sidecar.channels.appearance_msg == null and self.sidecar.channels.chrome_msg == null and self.sidecar.channels.env_msgs.len == 0) return;
        try self.raw(
            \\
            \\// The exported-const channel conventions must be DECLARED here (the
            \\// sidecar emitter reads the entry module's own declarations;
            \\// re-exports do not join its tables).
            \\
        );
        if (self.sidecar.channels.appearance_msg) |arm_name| {
            try self.print("\nexport const appearanceMsg = \"{s}\";\n", .{try tsString(self.arena, arm_name)});
        }
        if (self.sidecar.channels.chrome_msg) |arm_name| {
            try self.print("\nexport const chromeMsg = \"{s}\";\n", .{try tsString(self.arena, arm_name)});
        }
        if (self.sidecar.channels.env_msgs.len > 0) {
            try self.raw("\nexport const envMsgs = [\n");
            for (self.sidecar.channels.env_msgs) |entry| {
                try self.print("  {{ env: \"{s}\", msg: \"{s}\" }},\n", .{ try tsString(self.arena, entry.env), try tsString(self.arena, entry.msg) });
            }
            try self.raw("];\n");
        }
    }

    fn unboundDecl(self: *FacadeEmitter) Error!void {
        const model = sidecar_mod.findStruct(self.sidecar.types, self.sidecar.model).?;
        var field_unbound: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.sidecar.model_unbound) |name| {
            for (model.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    try field_unbound.append(self.arena, name);
                    break;
                }
            }
        }
        // Helper entries stay sidecar facts resolved by the compiler's
        // own name resolution: a helper name in the authored list
        // resolves against this module's exported wrappers.
        var helper_unbound: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.sidecar.model_unbound) |name| {
            for (self.sidecar.model_helpers) |helper| {
                if (std.mem.eql(u8, helper.name, name)) {
                    try helper_unbound.append(self.arena, name);
                    break;
                }
            }
        }
        // The authoring surface is ONE list resolved with the compiler's
        // Model-first precedence: fields, then helpers, then message arms.
        // A model-side homonym therefore projects faithfully, but an
        // unbound message arm shadowed by either model binding cannot be
        // named by this list. Refuse that direction instead of silently
        // marking the model binding and leaving the arm bound.
        for (self.sidecar.msg.unbound) |name| {
            const also_field = for (model.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) break true;
            } else false;
            const also_helper = for (self.sidecar.model_helpers) |helper| {
                if (std.mem.eql(u8, helper.name, name)) break true;
            } else false;
            if (also_field or also_helper) {
                self.diags.flag("msg.unbound", "\"{s}\" is an unbound message arm shadowed by a homonymous Model field or exported helper — the compiler resolves Model fields and helpers before message arms, so the projection's single unbound list cannot mark this arm; rename one side in the core source", .{name});
            }
        }
        if (self.diags.hasErrors()) return;
        if (field_unbound.items.len == 0 and helper_unbound.items.len == 0 and self.sidecar.msg.unbound.len == 0) return;
        try self.raw(
            \\
            \\// The unbound-list declaration, carried by the generator from the
            \\// author's own markings in the core module: message arms only the
            \\// host fires, and model fields and helpers only update logic reads.
            \\export const viewUnbound = [
            \\
        );
        for (self.sidecar.msg.unbound) |name| {
            try self.print("  \"{s}\",\n", .{try tsString(self.arena, name)});
        }
        for (field_unbound.items) |name| {
            try self.print("  \"{s}\",\n", .{try tsString(self.arena, name)});
        }
        for (helper_unbound.items) |name| {
            try self.print("  \"{s}\",\n", .{try tsString(self.arena, name)});
        }
        try self.raw("];\n");
    }

    // ------------------------------------------------- helper wrappers

    fn helperWrappers(self: *FacadeEmitter) Error!void {
        if (self.sidecar.model_helpers.len == 0) return;
        try self.raw(
            \\
            \\// The model helpers must be DECLARED here too, in declaration order
            \\// — the compiled contract's model_helpers table and helper_call's
            \\// index space both derive from it. Classed helper returns prove at
            \\// this boundary: bind the helper's value, range-guard it (an
            \\// ordered comparison excludes NaN), and state wholeness with
            \\// Math.trunc at the return.
            \\
        );
        for (self.sidecar.model_helpers) |helper| {
            const return_type = try self.spellRef(helper.returns);
            const is_int = helper.returns == .i64;
            const is_optional_int = helper.returns == .optional and helper.returns.optional.* == .i64;
            if (is_int or is_optional_int) {
                const class = self.nestedSlotClass("helpers", helper.name, "return") orelse .i64;
                if (is_optional_int) {
                    try self.print(
                        \\
                        \\export function {s}(model: {s}): {s} {{
                        \\  const nscfValue = nscfH_{s}(model);
                        \\  if (nscfValue === null) return null;
                        \\  if (nscfValue >= {s} && nscfValue <= {s}) return Math.trunc(nscfValue);
                        \\  nscfTrap("a helper return is NaN or outside its attested exact-integer range — the integer slot has no honest value for it");
                        \\}}
                        \\
                    , .{ helper.name, self.sidecar.model, return_type, helper.name, integerLowerBound(class), max_safe });
                } else {
                    try self.print(
                        \\
                        \\export function {s}(model: {s}): number {{
                        \\  const nscfValue = nscfH_{s}(model);
                        \\  if (nscfValue >= {s} && nscfValue <= {s}) return Math.trunc(nscfValue);
                        \\  nscfTrap("a helper return is NaN or outside its attested exact-integer range — the integer slot has no honest value for it");
                        \\}}
                        \\
                    , .{ helper.name, self.sidecar.model, helper.name, integerLowerBound(class), max_safe });
                }
                self.use(.trap);
            } else if (helper.returns == .slice) {
                try self.print(
                    \\
                    \\export function {s}(model: {s}): {s} {{
                    \\  return nscfH_{s}(model) as {s};
                    \\}}
                    \\
                , .{ helper.name, self.sidecar.model, return_type, helper.name, return_type });
            } else {
                try self.print(
                    \\
                    \\export function {s}(model: {s}): {s} {{
                    \\  return nscfH_{s}(model);
                    \\}}
                    \\
                , .{ helper.name, self.sidecar.model, return_type, helper.name });
            }
        }
    }

    // ---------------------------------------------------- entry points

    fn entryPoints(self: *FacadeEmitter) Error!void {
        try self.raw(
            \\
            \\// The designated shape-flag exports: the profile names init and
            \\// coreUpdate, and their return shapes restate the contract's
            \\// init_returns_cmd/update_returns_cmd flags.
            \\
        );
        if (self.sidecar.init_returns_cmd and self.sidecar.init_returns_bare) {
            self.use(.cmd_encoder);
            // The mixed author shape (`Model | [Model, Cmd<Msg>]`, the
            // documented idiom): the wrapper narrows — a tuple carries
            // its command, a bare model the empty command buffer.
            try self.print(
                \\
                \\export function init(): [{s}, Uint8Array] {{
                \\  const out = nscfInitialModel();
                \\  if (Array.isArray(out)) return [out[0], nscfCmdBytes(out[1])];
                \\  return [out, new Uint8Array(0)];
                \\}}
                \\
            , .{self.sidecar.model});
        } else if (self.sidecar.init_returns_cmd) {
            self.use(.cmd_encoder);
            try self.print(
                \\
                \\export function init(): [{s}, Uint8Array] {{
                \\  const pair = nscfInitialModel();
                \\  return [pair[0], nscfCmdBytes(pair[1])];
                \\}}
                \\
            , .{self.sidecar.model});
        } else {
            try self.print(
                \\
                \\export function init(): {s} {{
                \\  return nscfInitialModel();
                \\}}
                \\
            , .{self.sidecar.model});
        }
    }

    fn tagTable(self: *FacadeEmitter) Error!void {
        try self.raw(
            \\
            \\// Declaration-order wire tags (the contract sidecar is the tag
            \\// authority; a skewed table cannot survive the paired battery's
            \\// byte comparison or the mirror's boot fence).
            \\const nscfArmNames = [
            \\
        );
        for (self.sidecar.msg.arms) |arm| {
            try self.print("  \"{s}\",\n", .{try tsString(self.arena, arm.name)});
        }
        try self.raw("];\n\n");
        for (self.sidecar.msg.arms, 0..) |arm, tag| {
            try self.print("const nscfTag_{s} = {d};\n", .{ arm.name, tag });
        }
        self.use(.trap);
        try self.raw(
            \\
            \\function nscfTagOf(kind: string): number {
            \\  for (let i = 0; i < nscfArmNames.length; i++) {
            \\    if (nscfArmNames[i] === kind) return i;
            \\  }
            \\  nscfTrap("a command routes the unknown arm " + kind + " — the author module and this generated module disagree");
            \\}
            \\
        );
        if (self.sidecar.update_returns_cmd and self.sidecar.update_returns_bare) {
            self.use(.cmd_encoder);
            // The mixed author shape (`Model | [Model, Cmd<Msg>]`, the
            // documented idiom): the wrapper narrows — a tuple carries
            // its command, a bare model the empty command buffer.
            try self.print(
                \\
                \\export function coreUpdate(model: {s}, msg: {s}): [{s}, Uint8Array] {{
                \\  const out = nscfUpdate(model, msg);
                \\  if (Array.isArray(out)) return [out[0], nscfCmdBytes(out[1])];
                \\  return [out, new Uint8Array(0)];
                \\}}
                \\
            , .{ self.sidecar.model, self.sidecar.msg.name, self.sidecar.model });
        } else if (self.sidecar.update_returns_cmd) {
            self.use(.cmd_encoder);
            try self.print(
                \\
                \\export function coreUpdate(model: {s}, msg: {s}): [{s}, Uint8Array] {{
                \\  const pair = nscfUpdate(model, msg);
                \\  return [pair[0], nscfCmdBytes(pair[1])];
                \\}}
                \\
            , .{ self.sidecar.model, self.sidecar.msg.name, self.sidecar.model });
        } else {
            try self.print(
                \\
                \\export function coreUpdate(model: {s}, msg: {s}): {s} {{
                \\  return nscfUpdate(model, msg);
                \\}}
                \\
            , .{ self.sidecar.model, self.sidecar.msg.name, self.sidecar.model });
        }
        if (self.sidecar.has_subscriptions) {
            self.use(.sub_encoder);
            try self.print(
                \\
                \\export function coreSubscriptions(model: {s}): Uint8Array {{
                \\  return nscfSubBytes(nscfSubscriptions(model));
                \\}}
                \\
            , .{self.sidecar.model});
        }
    }

    // ------------------------------------------------ dispatch surface

    fn dispatchSurface(self: *FacadeEmitter) Error!void {
        self.use(.trap);
        try self.raw(
            \\
            \\// ------------------------------------------------ the dispatch surface
            \\// One committed model in module state; every dispatch entry runs one
            \\// update+commit and returns the cycle's command bytes.
            \\
            \\
        );
        if (self.sidecar.init_returns_cmd) {
            // Boot through the normalized init wrapper: the boot pair's
            // command already rides as bytes.
            try self.print("const nscfBootPair = init();\nlet nscfCommitted: {s} = nscfBootPair[0];\n", .{self.sidecar.model});
        } else {
            try self.print("let nscfCommitted: {s} = nscfInitialModel();\n", .{self.sidecar.model});
        }
        if (self.sidecar.update_returns_cmd) {
            try self.print(
                \\
                \\function nscfCommit(out: [{s}, Uint8Array]): Uint8Array {{
                \\  nscfCommitted = out[0];
                \\  return out[1];
                \\}}
                \\
            , .{self.sidecar.model});
        } else {
            try self.print(
                \\
                \\function nscfCommit(out: {s}): Uint8Array {{
                \\  nscfCommitted = out;
                \\  return new Uint8Array(0);
                \\}}
                \\
            , .{self.sidecar.model});
        }
        try self.raw(
            \\
            \\function nscfUnknownTag(entry: string, tag: number): never {
            \\  nscfTrap("tag " + tag + " does not name a " + entry + " message arm of this core — the host and this core disagree about the contract");
            \\}
            \\
        );
        if (self.sidecar.init_returns_cmd) {
            try self.raw(
                \\
                \\export function boot_cmd(): Uint8Array {
                \\  return nscfBootPair[1];
                \\}
                \\
            );
        } else {
            try self.raw(
                \\
                \\export function boot_cmd(): Uint8Array {
                \\  // init_returns_cmd is false for this contract: no boot command.
                \\  return new Uint8Array(0);
                \\}
                \\
            );
        }
        try self.dispatchVoid();
        try self.dispatchBytes();
        try self.dispatchNumber();
        try self.dispatchNumberBytes();
        try self.dispatchBool();
        try self.dispatchEnum();
        try self.dispatchRecord();
        try self.dispatchTextInput();
        try self.dispatchScrollState();
    }

    /// The dispatch expression committing one update cycle for a
    /// constructed arm object.
    fn commitLine(self: *FacadeEmitter, arm_object: []const u8) Error![]const u8 {
        return std.fmt.allocPrint(self.arena, "return nscfCommit(coreUpdate(nscfCommitted, {s}));", .{arm_object});
    }

    fn dispatchVoid(self: *FacadeEmitter) Error!void {
        try self.raw("\nexport function dispatch_void(tag: number): Uint8Array {\n");
        for (self.sidecar.msg.arms) |arm| {
            if (arm.payload != .void) continue;
            try self.print("  if (tag === nscfTag_{s}) {s}\n", .{ arm.name, try self.commitLine(try std.fmt.allocPrint(self.arena, "{{ kind: \"{s}\" }}", .{try tsString(self.arena, arm.name)})) });
        }
        try self.raw("  nscfUnknownTag(\"bare\", tag);\n}\n");
    }

    fn dispatchBytes(self: *FacadeEmitter) Error!void {
        try self.raw("\nexport function dispatch_bytes(tag: number, payload: Uint8Array): Uint8Array {\n");
        for (self.sidecar.msg.arms) |arm| {
            const carries_bytes = switch (arm.payload) {
                .bytes => true,
                .scalar => |ref| ref == .bytes,
                else => false,
            };
            if (!carries_bytes) continue;
            const object = try std.fmt.allocPrint(self.arena, "{{ kind: \"{s}\", {s}: payload }}", .{ try tsString(self.arena, arm.name), try tsProp(self.arena, self.memberOf(arm.member)) });
            try self.print("  if (tag === nscfTag_{s}) {s}\n", .{ arm.name, try self.commitLine(object) });
        }
        try self.raw("  nscfUnknownTag(\"bytes\", tag);\n}\n");
    }

    fn dispatchNumber(self: *FacadeEmitter) Error!void {
        try self.raw("\nexport function dispatch_number(tag: number, value: number): Uint8Array {\n");
        var f64_count: usize = 0;
        for (self.sidecar.msg.arms) |arm| {
            if (payloadNumberClass(arm.payload)) |class| {
                if (class == .f64) f64_count += 1;
            }
        }
        if (f64_count > 0) {
            try self.raw("  // These arms remain f64-classed in the contract: preserve the value\n  // exactly instead of routing it through the integer proof below.\n");
            for (self.sidecar.msg.arms) |arm| {
                if (payloadNumberClass(arm.payload) != .f64) continue;
                const object = try std.fmt.allocPrint(self.arena, "{{ kind: \"{s}\", {s}: value }}", .{ try tsString(self.arena, arm.name), try tsProp(self.arena, self.memberOf(arm.member)) });
                try self.print("  if (tag === nscfTag_{s}) {s}\n", .{ arm.name, try self.commitLine(object) });
            }
        }
        for (self.sidecar.msg.arms) |arm| {
            if (payloadNumberClass(arm.payload) != .i64) continue;
            const class = self.slotClass(self.sidecar.msg.name, arm.name) orelse .i64;
            const object = try std.fmt.allocPrint(self.arena, "{{ kind: \"{s}\", {s}: whole }}", .{ try tsString(self.arena, arm.name), try tsProp(self.arena, self.memberOf(arm.member)) });
            try self.print(
                \\  // This integer-classed arm proves in place: its attestation
                \\  // selects the signed or unsigned lower bound, the ordered
                \\  // comparisons exclude NaN, and Math.trunc states wholeness.
                \\  if (tag === nscfTag_{s}) {{
                \\    if (value >= {s} && value <= {s}) {{
                \\      const whole = Math.trunc(value);
                \\      return nscfCommit(coreUpdate(nscfCommitted, {s}));
                \\    }}
                \\    nscfTrap("a numeric dispatch value is NaN or outside its attested exact-integer range — the integer slot has no honest value for it");
                \\  }}
                \\
            , .{ arm.name, integerLowerBound(class), max_safe, object });
        }
        try self.raw("  nscfUnknownTag(\"number\", tag);\n}\n");
    }

    fn dispatchNumberBytes(self: *FacadeEmitter) Error!void {
        try self.raw("\nexport function dispatch_number_bytes(tag: number, value: number, payload: Uint8Array): Uint8Array {\n");
        for (self.sidecar.msg.arms) |arm| {
            switch (arm.payload) {
                .number_bytes => |desc| {
                    const kind = try tsString(self.arena, arm.name);
                    const number_prop = try tsProp(self.arena, desc.number_field);
                    const bytes_prop = try tsProp(self.arena, desc.bytes_field);
                    if (desc.number_class == .i64) {
                        const class = self.nestedSlotClass(self.sidecar.msg.name, arm.name, desc.number_field) orelse .i64;
                        try self.print(
                            \\  if (tag === nscfTag_{s}) {{
                            \\    // The number field is i64-classed: range-guard the raw f64 (an
                            \\    // ordered comparison excludes NaN) and state wholeness with
                            \\    // Math.trunc at the write.
                            \\    if (value >= {s} && value <= {s}) {{
                            \\      return nscfCommit(coreUpdate(nscfCommitted, {{ kind: "{s}", {s}: Math.trunc(value), {s}: payload }}));
                            \\    }}
                            \\    nscfTrap("a numeric dispatch value is NaN or outside its attested exact-integer range — the integer slot has no honest value for it");
                            \\  }}
                            \\
                        , .{ arm.name, integerLowerBound(class), max_safe, kind, number_prop, bytes_prop });
                    } else {
                        try self.print("  if (tag === nscfTag_{s}) return nscfCommit(coreUpdate(nscfCommitted, {{ kind: \"{s}\", {s}: value, {s}: payload }}));\n", .{ arm.name, kind, number_prop, bytes_prop });
                    }
                },
                else => {},
            }
        }
        try self.raw("  nscfUnknownTag(\"number-with-bytes\", tag);\n}\n");
    }

    fn dispatchBool(self: *FacadeEmitter) Error!void {
        try self.raw("\nexport function dispatch_bool(tag: number, value: number): Uint8Array {\n");
        for (self.sidecar.msg.arms) |arm| {
            switch (arm.payload) {
                .scalar => |ref| {
                    if (ref != .bool) continue;
                    const object = try std.fmt.allocPrint(self.arena, "{{ kind: \"{s}\", {s}: value !== 0 }}", .{ try tsString(self.arena, arm.name), try tsProp(self.arena, self.memberOf(arm.member)) });
                    try self.print("  if (tag === nscfTag_{s}) {s}\n", .{ arm.name, try self.commitLine(object) });
                },
                else => {},
            }
        }
        try self.raw("  nscfUnknownTag(\"boolean\", tag);\n}\n");
    }

    fn dispatchEnum(self: *FacadeEmitter) Error!void {
        try self.raw("\nexport function dispatch_enum(tag: number, member: number): Uint8Array {\n");
        for (self.sidecar.msg.arms) |arm| {
            switch (arm.payload) {
                .enum_ref => |name| {
                    try self.needEnumTable(name);
                    const object = try std.fmt.allocPrint(self.arena, "{{ kind: \"{s}\", {s}: nscfMembers{s}[member]! }}", .{ try tsString(self.arena, arm.name), try tsProp(self.arena, self.memberOf(arm.member)), name });
                    try self.print(
                        \\  if (tag === nscfTag_{s}) {{
                        \\    if (member >= nscfMembers{s}.length) nscfMember("{s}", member);
                        \\    {s}
                        \\  }}
                        \\
                    , .{ arm.name, name, try tsString(self.arena, name), try self.commitLine(object) });
                    self.needs_member_trap = true;
                },
                else => {},
            }
        }
        try self.raw("  nscfUnknownTag(\"enum\", tag);\n}\n");
    }

    fn dispatchRecord(self: *FacadeEmitter) Error!void {
        try self.raw("\nexport function dispatch_record(tag: number, fields: Uint8Array): Uint8Array {\n");
        for (self.sidecar.msg.arms) |arm| {
            switch (arm.payload) {
                .record => |name| {
                    const record = sidecar_mod.findStruct(self.sidecar.types, name) orelse continue;
                    try self.print("  if (tag === nscfTag_{s}) {{\n", .{arm.name});
                    if (self.synthesizedRecordOf(recordPayloadRef(arm.payload), self.sidecar.msg.name, arm.name) != null) {
                        try self.recordDecodeCommit(record, arm.name, null);
                    } else {
                        try self.recordDecodeCommit(record, arm.name, self.memberOf(arm.member));
                    }
                    try self.raw("  }\n");
                },
                .union_ref => |name| {
                    // The emitted contract may store this union's record
                    // payloads by reference, in which case the mirror
                    // routes the arm through the generic record entry;
                    // the canonical union encoding is the same either
                    // way.
                    try self.needUnionDecoder(name);
                    try self.print("  if (tag === nscfTag_{s}) return nscfCommit(coreUpdate(nscfCommitted, {{ kind: \"{s}\", {s}: nscfDecode{s}(fields) }}));\n", .{ arm.name, try tsString(self.arena, arm.name), try tsProp(self.arena, self.memberOf(arm.member)), name });
                },
                else => {},
            }
        }
        try self.raw("  nscfUnknownTag(\"record\", tag);\n}\n");
    }

    fn dispatchTextInput(self: *FacadeEmitter) Error!void {
        try self.raw("\nexport function dispatch_text_input(tag: number, event: Uint8Array): Uint8Array {\n");
        for (self.sidecar.msg.arms) |arm| {
            switch (arm.payload) {
                .union_ref => |name| {
                    try self.needUnionDecoder(name);
                    try self.print("  if (tag === nscfTag_{s}) return nscfCommit(coreUpdate(nscfCommitted, {{ kind: \"{s}\", {s}: nscfDecode{s}(event) }}));\n", .{ arm.name, try tsString(self.arena, arm.name), try tsProp(self.arena, self.memberOf(arm.member)), name });
                },
                else => {},
            }
        }
        try self.raw("  nscfUnknownTag(\"text-input\", tag);\n}\n");
    }

    fn dispatchScrollState(self: *FacadeEmitter) Error!void {
        try self.raw(
            \\
            \\export function dispatch_scroll_state(
            \\  tag: number,
            \\  offsetX: number,
            \\  offsetY: number,
            \\  velocityX: number,
            \\  velocityY: number,
            \\  viewportExtentX: number,
            \\  viewportExtentY: number,
            \\  contentExtentX: number,
            \\  contentExtentY: number,
            \\): Uint8Array {
            \\
        );
        for (self.sidecar.msg.arms) |arm| {
            switch (arm.payload) {
                .record => |name| {
                    const record = self.scrollShapedRecord(name) orelse continue;
                    // Construct the scroll record with the author's own
                    // field spellings, each fed by its axis parameter. An
                    // integer-attested axis proves against its own signed or
                    // unsigned range before Math.trunc states wholeness.
                    var fields_text: std.ArrayListUnmanaged(u8) = .empty;
                    var guards: std.ArrayListUnmanaged(u8) = .empty;
                    for (record.fields, 0..) |field, index| {
                        const param = scrollParamFor(field.name) orelse field.name;
                        const value = if (field.type == .i64) blk: {
                            const class = self.slotClass(record.name, field.name) orelse .i64;
                            if (guards.items.len > 0) try guards.appendSlice(self.arena, " && ");
                            try guards.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{s} >= {s} && {s} <= {s}", .{ param, integerLowerBound(class), param, max_safe }));
                            break :blk try std.fmt.allocPrint(self.arena, "Math.trunc({s})", .{param});
                        } else param;
                        if (index > 0) try fields_text.appendSlice(self.arena, ", ");
                        try fields_text.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{s}: {s}", .{ try tsProp(self.arena, field.name), value }));
                    }
                    const object = if (self.synthesizedRecordOf(recordPayloadRef(arm.payload), self.sidecar.msg.name, arm.name) != null)
                        // Inline message-arm records have no authored payload
                        // member: their fields sit beside `kind`, exactly as
                        // the generic record dispatch constructs them.
                        try std.fmt.allocPrint(self.arena, "{{ kind: \"{s}\", {s} }}", .{ try tsString(self.arena, arm.name), fields_text.items })
                    else
                        try std.fmt.allocPrint(self.arena, "{{ kind: \"{s}\", {s}: {{ {s} }} }}", .{ try tsString(self.arena, arm.name), try tsProp(self.arena, self.memberOf(arm.member)), fields_text.items });
                    if (guards.items.len == 0) {
                        try self.print("  if (tag === nscfTag_{s}) {s}\n", .{ arm.name, try self.commitLine(object) });
                    } else {
                        try self.print(
                            \\  if (tag === nscfTag_{s}) {{
                            \\    if ({s}) return nscfCommit(coreUpdate(nscfCommitted, {s}));
                            \\    nscfTrap("a scroll dispatch value is NaN or outside its attested exact-integer range — the integer slot has no honest value for it");
                            \\  }}
                            \\
                        , .{ arm.name, guards.items, object });
                        self.use(.trap);
                    }
                },
                else => {},
            }
        }
        try self.raw("  nscfUnknownTag(\"scroll-state\", tag);\n}\n");
    }

    /// The record behind a scroll-shaped arm payload: eight numeric
    /// fields spelling the two-axis vocabulary (the mirror's routing
    /// rule restated over sidecar data).
    fn scrollShapedRecord(self: *FacadeEmitter, name: []const u8) ?*const sidecar_mod.Struct {
        const entry = sidecar_mod.findStruct(self.sidecar.types, name) orelse return null;
        if (entry.fields.len != 8) return null;
        const spellings = [_][8][]const u8{ scroll_state_fields_ts, scroll_state_fields_canvas };
        for (spellings) |names| {
            var all_found = true;
            for (names) |expected| {
                for (entry.fields) |field| {
                    const numeric = field.type == .f64 or field.type == .i64;
                    if (std.mem.eql(u8, field.name, expected) and numeric) break;
                } else {
                    all_found = false;
                    break;
                }
            }
            if (all_found) return entry;
        }
        return null;
    }

    // ------------------------------------------------- channel entries

    fn channelEntries(self: *FacadeEmitter) Error!void {
        const chan = self.sidecar.channels;
        if (!(chan.command_msg or chan.frame_msg or chan.key_msg or chan.pinch_msg or chan.drop_msg)) return;
        self.use(.sink);
        self.use(.trap);
        try self.print(
            \\
            \\// --------------------------------------------- the ABI channel entries
            \\// Each answers the channel bytes envelope: [produced u8][tag u8]
            \\// [payload in the arm's canonical value encoding]. Byte 0 is 0
            \\// (nothing produced; the envelope is exactly two bytes) or 1.
            \\
            \\function nscfPackMsg(produced: {s} | null): Uint8Array {{
            \\  if (produced === null) return new Uint8Array(2);
            \\  const sink = nscfNewSink();
            \\  nscfMsgPayload(sink, produced);
            \\  const payload = nscfFinish(sink);
            \\  const out = new Uint8Array(2 + payload.length);
            \\  out[0] = 1;
            \\  out[1] = nscfTagOf(produced.kind);
            \\  for (let i = 0; i < payload.length; i++) out[2 + i] = payload[i]!;
            \\  return out;
            \\}}
            \\
        , .{self.sidecar.msg.name});
        try self.msgPayloadWriter();
        if (chan.key_msg or chan.command_msg) {
            self.use(.ascii_string);
        }
        if (chan.command_msg) {
            try self.raw(
                \\
                \\export function abi_command_msg(name: Uint8Array): Uint8Array {
                \\  return nscfPackMsg(nscfChanCommandMsg(nscfAsciiString(name)));
                \\}
                \\
            );
        }
        if (chan.frame_msg) {
            try self.raw(
                \\
                \\export function abi_frame_msg(width: number, height: number, timestampMs: number, intervalMs: number): Uint8Array {
                \\  return nscfPackMsg(nscfChanFrameMsg(nscfCommitted, {
                \\    width: width,
                \\    height: height,
                \\    timestampMs: timestampMs,
                \\    intervalMs: intervalMs,
                \\  }));
                \\}
                \\
            );
        }
        if (chan.key_msg) {
            try self.raw(
                \\
                \\export function abi_key_msg(
                \\  key: Uint8Array,
                \\  shift: number,
                \\  control: number,
                \\  alt: number,
                \\  superMod: number,
                \\): Uint8Array {
                \\  return nscfPackMsg(nscfChanKeyMsg({
                \\    key: nscfAsciiString(key),
                \\    shift: shift !== 0,
                \\    control: control !== 0,
                \\    alt: alt !== 0,
                \\    super: superMod !== 0,
                \\  }));
                \\}
                \\
            );
        }
        if (chan.pinch_msg) {
            self.needs_pinch_phase = true;
            self.use(.ascii_string);
            try self.raw(
                \\
                \\// The pinch phase table the channel's u32 member index reads back
                \\// through (the SDK's declared PinchPhase members, in order).
                \\const nscfPinchPhases: PinchPhase[] = ["begin", "change", "end"];
                \\
                \\export function abi_pinch_msg(
                \\  windowId: number,
                \\  label: Uint8Array,
                \\  phase: number,
                \\  scale: number,
                \\  x: number,
                \\  y: number,
                \\): Uint8Array {
                \\  if (phase >= nscfPinchPhases.length) nscfMember("PinchPhase", phase);
                \\  return nscfPackMsg(nscfChanPinchMsg({
                \\    windowId: windowId,
                \\    label: nscfAsciiString(label),
                \\    phase: nscfPinchPhases[phase]!,
                \\    scale: scale,
                \\    x: x,
                \\    y: y,
                \\  }));
                \\}
                \\
            );
            self.needs_member_trap = true;
        }
        if (chan.drop_msg) {
            self.use(.read_f64);
            self.use(.read_u32);
            self.use(.read_bool);
            self.use(.read_bytes_body);
            self.use(.assert_consumed);
            self.use(.ascii_string);
            try self.raw(
                \\
                \\export function abi_drop_msg(event: Uint8Array): Uint8Array {
                \\  let at = 0;
                \\  const windowId = nscfReadF64(event, at);
                \\  at += 8;
                \\  const viewLabelLen = nscfReadU32(event, at);
                \\  at += 4;
                \\  const viewLabel = nscfReadBytesBody(event, at, viewLabelLen);
                \\  at += viewLabelLen;
                \\  const pointPresent = nscfReadBool(event, at);
                \\  at += 1;
                \\  let point: FileDropPoint | null = null;
                \\  if (pointPresent) {
                \\    const x = nscfReadF64(event, at);
                \\    at += 8;
                \\    const y = nscfReadF64(event, at);
                \\    at += 8;
                \\    point = { x: x, y: y };
                \\  }
                \\  const pathCount = nscfReadU32(event, at);
                \\  at += 4;
                \\  const paths: Uint8Array[] = [];
                \\  for (let i = 0; i < pathCount; i++) {
                \\    const pathLen = nscfReadU32(event, at);
                \\    at += 4;
                \\    paths.push(nscfReadBytesBody(event, at, pathLen));
                \\    at += pathLen;
                \\  }
                \\  nscfAssertConsumed(event, at);
                \\  return nscfPackMsg(nscfChanDropMsg({
                \\    windowId: windowId,
                \\    viewLabel: nscfAsciiString(viewLabel),
                \\    point: point,
                \\    paths: paths,
                \\  }));
                \\}
                \\
            );
        }
    }

    /// The canonical payload encoding of any produced message, off the
    /// narrowed arm value — the envelope's tail must decode against the
    /// arm's mirror payload type, so field order and number classes
    /// follow the sidecar exactly.
    fn msgPayloadWriter(self: *FacadeEmitter) Error!void {
        try self.print("\nfunction nscfMsgPayload(sink: nscfSink, value: {s}): void {{\n", .{self.sidecar.msg.name});
        for (self.sidecar.msg.arms) |arm| {
            try self.print("  if (value.kind === \"{s}\") {{\n", .{try tsString(self.arena, arm.name)});
            const member = self.memberOf(arm.member);
            switch (arm.payload) {
                .void => {},
                .bytes => {
                    self.use(.w_bytes);
                    try self.print("    nscfWBytes(sink, {s});\n", .{try tsAccess(self.arena, "value", member)});
                },
                .number => |class| {
                    const access = try tsAccess(self.arena, "value", member);
                    if (class == .i64) {
                        try self.print("    {s}(sink, {s});\n", .{ self.intWriter(self.sidecar.msg.name, arm.name), access });
                    } else {
                        self.use(.w_f64);
                        try self.print("    nscfWF64(sink, {s});\n", .{access});
                    }
                },
                .number_bytes => |desc| {
                    // The mirror declares the number field first, so the
                    // number's bytes lead.
                    const number_access = try tsAccess(self.arena, "value", desc.number_field);
                    if (desc.number_class == .i64) {
                        const slot_member = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ arm.name, desc.number_field });
                        try self.print("    {s}(sink, {s});\n", .{ self.intWriter(self.sidecar.msg.name, slot_member), number_access });
                    } else {
                        self.use(.w_f64);
                        try self.print("    nscfWF64(sink, {s});\n", .{number_access});
                    }
                    self.use(.w_bytes);
                    try self.print("    nscfWBytes(sink, {s});\n", .{try tsAccess(self.arena, "value", desc.bytes_field)});
                },
                .record => |name| {
                    const record = sidecar_mod.findStruct(self.sidecar.types, name).?;
                    if (self.synthesizedRecordOf(recordPayloadRef(arm.payload), self.sidecar.msg.name, arm.name) != null) {
                        // Flattened beside kind: encode the record's
                        // fields off the narrowed arm in declaration
                        // order.
                        for (record.fields) |field| {
                            try self.fieldWriteStatements(field.type, try tsAccess(self.arena, "value", field.name), name, field.name, 2);
                        }
                    } else {
                        try self.needRecordWriter(name);
                        try self.print("    nscfWrite{s}(sink, {s});\n", .{ name, try tsAccess(self.arena, "value", member) });
                    }
                },
                .union_ref => |name| {
                    try self.needUnionWriter(name);
                    try self.print("    nscfWrite{s}(sink, {s});\n", .{ name, try tsAccess(self.arena, "value", member) });
                },
                .enum_ref => |name| {
                    try self.needEnumIndex(name);
                    self.use(.w_u32);
                    try self.print("    nscfWU32(sink, nscfIndex{s}({s}));\n", .{ name, try tsAccess(self.arena, "value", member) });
                },
                .scalar => |ref| {
                    const access = try tsAccess(self.arena, "value", member);
                    switch (ref) {
                        .bool => {
                            self.use(.w_bool);
                            try self.print("    nscfWBool(sink, {s});\n", .{access});
                        },
                        .f64 => {
                            self.use(.w_f64);
                            try self.print("    nscfWF64(sink, {s});\n", .{access});
                        },
                        .i64 => try self.print("    {s}(sink, {s});\n", .{ self.intWriter(self.sidecar.msg.name, arm.name), access }),
                        .bytes => {
                            self.use(.w_bytes);
                            try self.print("    nscfWBytes(sink, {s});\n", .{access});
                        },
                        else => self.diags.flag("msg.arms", "arm \"{s}\" carries a scalar payload outside the generated channel encoding (only bool, number, and bytes scalars have ABI entries); extend the generator before wiring it", .{arm.name}),
                    }
                },
            }
            try self.raw("    return;\n  }\n");
        }
        try self.raw("  nscfTrap(\"a channel produced a message outside the declared union — the value and the contract disagree\");\n}\n");
    }

    // ------------------------------------------------------ post-cycle

    fn postCycle(self: *FacadeEmitter) Error!void {
        try self.raw("\n// --------------------------------------------------------- post-cycle\n");
        if (self.sidecar.has_subscriptions) {
            try self.raw(
                \\
                \\export function abi_subscriptions(): Uint8Array {
                \\  return coreSubscriptions(nscfCommitted);
                \\}
                \\
            );
        } else {
            try self.raw(
                \\
                \\export function abi_subscriptions(): Uint8Array {
                \\  // has_subscriptions is false for this contract: always empty.
                \\  return new Uint8Array(0);
                \\}
                \\
            );
        }
        self.use(.sink);
        try self.needRecordWriter(self.sidecar.model);
        try self.print(
            \\
            \\// The canonical committed-model encoding (snapshot format {d}): the
            \\// model record's fields in declaration order, enums as u32 member
            \\// indices, optionals as a one-byte present flag plus the inner value
            \\// when present, records inline, slices as u32 count + elements — the
            \\// same bytes the transpiler lane's canonical encoder emits for this
            \\// model.
            \\export function model_snapshot(): Uint8Array {{
            \\  const sink = nscfNewSink();
            \\  nscfWrite{s}(sink, nscfCommitted);
            \\  return nscfFinish(sink);
            \\}}
            \\
        , .{ self.sidecar.abi.snapshot_format, self.sidecar.model });
    }

    fn helperCall(self: *FacadeEmitter) Error!void {
        self.use(.trap);
        if (self.sidecar.model_helpers.len == 0) {
            self.use(.assert_consumed);
            try self.raw(
                \\
                \\// This core declares no model helpers; the entry stays for the ABI's
                \\// fixed export set.
                \\export function helper_call(helper: number, args: Uint8Array): Uint8Array {
                \\  nscfAssertConsumed(args, 0);
                \\  nscfTrap("helper index " + helper + " does not name an exported model helper of this core — the host and this core disagree about the contract");
                \\}
                \\
            );
            return;
        }
        self.use(.assert_consumed);
        self.use(.sink);
        try self.raw(
            \\
            \\// ------------------------------------------------------- model helpers
            \\// Indexed by the contract's model_helpers order; results ride the
            \\// canonical value encoding of each helper's declared return type.
            \\export function helper_call(helper: number, args: Uint8Array): Uint8Array {
            \\  nscfAssertConsumed(args, 0);
            \\
        );
        for (self.sidecar.model_helpers, 0..) |helper, index| {
            try self.print("  if (helper === {d}) {{\n    const sink = nscfNewSink();\n    const nscfValue = {s}(nscfCommitted);\n", .{ index, helper.name });
            const slot_member = try std.fmt.allocPrint(self.arena, "{s}.return", .{helper.name});
            try self.fieldWriteStatements(helper.returns, "nscfValue", "helpers", slot_member, 2);
            try self.raw("    return nscfFinish(sink);\n  }\n");
        }
        try self.raw("  nscfTrap(\"helper index \" + helper + \" does not name an exported model helper of this core — the host and this core disagree about the contract\");\n}\n");
    }

    // ------------------------------------- generated writers/decoders

    fn needEnumTable(self: *FacadeEmitter, name: []const u8) Error!void {
        if (nameListed(self.needed_enum_tables.items, name)) return;
        try self.needed_enum_tables.append(self.arena, name);
        try self.reference(name);
    }

    fn needEnumIndex(self: *FacadeEmitter, name: []const u8) Error!void {
        try self.needEnumTable(name);
        if (nameListed(self.needed_enum_indexes.items, name)) return;
        try self.needed_enum_indexes.append(self.arena, name);
    }

    fn needRecordWriter(self: *FacadeEmitter, name: []const u8) Error!void {
        if (nameListed(self.needed_record_writers.items, name)) return;
        try self.needed_record_writers.append(self.arena, name);
        try self.reference(name);
    }

    fn needUnionWriter(self: *FacadeEmitter, name: []const u8) Error!void {
        if (nameListed(self.needed_union_writers.items, name)) return;
        try self.needed_union_writers.append(self.arena, name);
        try self.reference(name);
    }

    fn needUnionDecoder(self: *FacadeEmitter, name: []const u8) Error!void {
        if (nameListed(self.needed_union_decoders.items, name)) return;
        try self.needed_union_decoders.append(self.arena, name);
        try self.reference(name);
    }

    fn generatedTables(self: *FacadeEmitter) Error!void {
        var emitted_header = false;
        // Draining loop: a writer may need another writer or table.
        var enum_at: usize = 0;
        var enum_index_at: usize = 0;
        var record_at: usize = 0;
        var union_w_at: usize = 0;
        var union_d_at: usize = 0;
        while (enum_at < self.needed_enum_tables.items.len or
            enum_index_at < self.needed_enum_indexes.items.len or
            record_at < self.needed_record_writers.items.len or
            union_w_at < self.needed_union_writers.items.len or
            union_d_at < self.needed_union_decoders.items.len)
        {
            if (!emitted_header) {
                emitted_header = true;
                try self.raw(
                    \\
                    \\// ----------------------------------- generated tables and codecs
                    \\// Enum member tables (u32 member indices read back through them),
                    \\// canonical record/union writers, and standalone union decoders.
                    \\
                );
            }
            while (enum_at < self.needed_enum_tables.items.len) : (enum_at += 1) {
                try self.enumTable(self.needed_enum_tables.items[enum_at]);
            }
            while (enum_index_at < self.needed_enum_indexes.items.len) : (enum_index_at += 1) {
                try self.enumIndexFn(self.needed_enum_indexes.items[enum_index_at]);
            }
            while (record_at < self.needed_record_writers.items.len) : (record_at += 1) {
                try self.recordWriter(self.needed_record_writers.items[record_at]);
            }
            while (union_w_at < self.needed_union_writers.items.len) : (union_w_at += 1) {
                try self.unionWriter(self.needed_union_writers.items[union_w_at]);
            }
            while (union_d_at < self.needed_union_decoders.items.len) : (union_d_at += 1) {
                try self.unionDecoder(self.needed_union_decoders.items[union_d_at]);
            }
        }
        if (self.needs_member_trap) {
            self.use(.trap);
            try self.raw(
                \\
                \\function nscfMember(enumName: string, member: number): never {
                \\  nscfTrap("member index " + member + " does not name a " + enumName + " member — the host and this core disagree about the contract");
                \\}
                \\
            );
        }
    }

    fn enumTable(self: *FacadeEmitter, name: []const u8) Error!void {
        const entry = sidecar_mod.findEnum(self.sidecar.types, name).?;
        try self.print("\nconst nscfMembers{s}: {s}[] = [", .{ name, name });
        for (entry.members, 0..) |member, index| {
            try self.print("{s}\"{s}\"", .{ if (index == 0) "" else ", ", try tsString(self.arena, member) });
        }
        try self.raw("];\n");
    }

    fn enumIndexFn(self: *FacadeEmitter, name: []const u8) Error!void {
        self.use(.trap);
        try self.print(
            \\
            \\function nscfIndex{s}(value: {s}): number {{
            \\  for (let i = 0; i < nscfMembers{s}.length; i++) {{
            \\    if (nscfMembers{s}[i] === value) return i;
            \\  }}
            \\  nscfTrap("an enum slot carries an undeclared member — the author module and this generated module disagree");
            \\}}
            \\
        , .{ name, name, name, name });
    }

    /// Statements appending one value's canonical encoding to `sink`.
    /// `container`/`member` name the slot for the attested integer
    /// class; depth controls indentation and temp naming.
    fn fieldWriteStatements(self: *FacadeEmitter, ref: TypeRef, expr: []const u8, container: []const u8, member: []const u8, depth: usize) Error!void {
        const pad = try self.indentText(depth);
        switch (ref) {
            .bool => {
                self.use(.w_bool);
                try self.print("{s}nscfWBool(sink, {s});\n", .{ pad, expr });
            },
            .i64 => try self.print("{s}{s}(sink, {s});\n", .{ pad, self.intWriter(container, member), expr }),
            .f64 => {
                self.use(.w_f64);
                try self.print("{s}nscfWF64(sink, {s});\n", .{ pad, expr });
            },
            .bytes => {
                self.use(.w_bytes);
                try self.print("{s}nscfWBytes(sink, {s});\n", .{ pad, expr });
            },
            .void => {},
            .optional => |inner| {
                self.use(.w_bool);
                const temp = try std.fmt.allocPrint(self.arena, "nscfOpt{d}", .{self.temp_counter});
                self.temp_counter += 1;
                try self.print("{s}const {s} = {s};\n{s}if ({s} === null) {{\n{s}  nscfWBool(sink, false);\n{s}}} else {{\n{s}  nscfWBool(sink, true);\n", .{ pad, temp, expr, pad, temp, pad, pad, pad });
                try self.fieldWriteStatements(inner.*, temp, container, member, depth + 1);
                try self.print("{s}}}\n", .{pad});
            },
            .slice => |elem| {
                self.use(.w_u32);
                const index = try std.fmt.allocPrint(self.arena, "nscfIdx{d}", .{self.temp_counter});
                self.temp_counter += 1;
                try self.print("{s}nscfWU32(sink, {s}.length);\n{s}for (let {s} = 0; {s} < {s}.length; {s}++) {{\n", .{ pad, expr, pad, index, index, expr, index });
                try self.fieldWriteStatements(elem.*, try std.fmt.allocPrint(self.arena, "{s}[{s}]!", .{ expr, index }), container, member, depth + 1);
                try self.print("{s}}}\n", .{pad});
            },
            .node, .value => |name| {
                if (nameListed(self.flattened, name)) {
                    // A synthesized single-use record has no importable
                    // declaration: inline its fields at the site.
                    const record = sidecar_mod.findStruct(self.sidecar.types, name).?;
                    for (record.fields) |field| {
                        try self.fieldWriteStatements(field.type, try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ expr, field.name }), name, field.name, depth);
                    }
                } else {
                    try self.needRecordWriter(name);
                    try self.print("{s}nscfWrite{s}(sink, {s});\n", .{ pad, name, expr });
                }
            },
            .enum_ref => |name| {
                try self.needEnumIndex(name);
                self.use(.w_u32);
                try self.print("{s}nscfWU32(sink, nscfIndex{s}({s}));\n", .{ pad, name, expr });
            },
            .union_ref => |name| {
                try self.needUnionWriter(name);
                try self.print("{s}nscfWrite{s}(sink, {s});\n", .{ pad, name, expr });
            },
        }
    }

    fn recordWriter(self: *FacadeEmitter, name: []const u8) Error!void {
        const entry = sidecar_mod.findStruct(self.sidecar.types, name).?;
        self.use(.sink);
        self.temp_counter = 0;
        try self.print("\nfunction nscfWrite{s}(sink: nscfSink, value: {s}): void {{\n", .{ name, name });
        for (entry.fields) |field| {
            try self.fieldWriteStatements(field.type, try tsAccess(self.arena, "value", field.name), name, field.name, 1);
        }
        try self.raw("}\n");
    }

    fn unionWriter(self: *FacadeEmitter, name: []const u8) Error!void {
        const entry = sidecar_mod.findUnion(self.sidecar.types, name).?;
        self.use(.sink);
        self.use(.w_u8);
        self.use(.trap);
        self.temp_counter = 0;
        try self.print("\nfunction nscfWrite{s}(sink: nscfSink, value: {s}): void {{\n", .{ name, name });
        for (entry.arms, 0..) |arm, index| {
            try self.print("  if (value.kind === \"{s}\") {{\n    nscfWU8(sink, {d});\n", .{ try tsString(self.arena, arm.name), index });
            if (arm.payload != .void) {
                if (self.synthesizedRecordOf(arm.payload, entry.name, arm.name)) |record| {
                    for (record.fields) |field| {
                        try self.fieldWriteStatements(field.type, try tsAccess(self.arena, "value", field.name), record.name, field.name, 2);
                    }
                } else {
                    try self.fieldWriteStatements(arm.payload, try tsAccess(self.arena, "value", self.memberOf(arm.member)), entry.name, arm.name, 2);
                }
            }
            try self.raw("    return;\n  }\n");
        }
        try self.print("  nscfTrap(\"{s} carries an arm outside its declared union — the value and the contract disagree\");\n}}\n", .{try tsString(self.arena, name)});
    }

    // -------------------------------------------------------- decoding

    /// Locals-and-construction decode of one record from `bytes` at a
    /// running offset, committed as an arm of the message union.
    /// `member` is null for a flattened (synthesized) record whose
    /// fields construct beside `kind`, and the authored member spelling
    /// otherwise.
    fn recordDecodeCommit(self: *FacadeEmitter, record: *const sidecar_mod.Struct, arm_name: []const u8, member: ?[]const u8) Error!void {
        var decode = RecordDecode{ .emitter = self, .buf = "fields", .indent = 2 };
        try decode.run(record);
        self.use(.assert_consumed);
        try self.print("    nscfAssertConsumed(fields, {s});\n", .{decode.offsetText()});
        const construction = try decode.constructionText(record);
        const object = if (member) |m|
            try std.fmt.allocPrint(self.arena, "{{ kind: \"{s}\", {s}: {s} }}", .{ try tsString(self.arena, arm_name), try tsProp(self.arena, m), construction })
        else blk: {
            // Flattened: splice the record's fields beside kind.
            const inner = construction[1 .. construction.len - 1];
            break :blk try std.fmt.allocPrint(self.arena, "{{ kind: \"{s}\",{s}}}", .{ try tsString(self.arena, arm_name), inner });
        };
        if (decode.guards.items.len > 0) {
            try self.print("    if ({s}) {{\n      return nscfCommit(coreUpdate(nscfCommitted, {s}));\n    }}\n    nscfTrap(\"a decoded integer value is NaN or outside its attested exact-integer range — the integer slot has no honest value for it\");\n", .{ decode.guards.items, object });
            self.use(.trap);
        } else {
            try self.print("    return nscfCommit(coreUpdate(nscfCommitted, {s}));\n", .{object});
        }
    }

    /// A standalone decoder for a union payload arriving whole on a
    /// dispatch entry (`[arm u8][payload]`, fully consumed).
    fn unionDecoder(self: *FacadeEmitter, name: []const u8) Error!void {
        const entry = sidecar_mod.findUnion(self.sidecar.types, name).?;
        self.use(.trap);
        self.use(.assert_consumed);
        try self.print(
            \\
            \\function nscfDecode{s}(bytes: Uint8Array): {s} {{
            \\  if (bytes.length === 0) {{
            \\    nscfTrap("a dispatched union payload carries no arm byte — the host and this core disagree about the contract");
            \\  }}
            \\  const arm = bytes[0]!;
            \\
        , .{ name, name });
        for (entry.arms, 0..) |arm, index| {
            const kind = try tsString(self.arena, arm.name);
            try self.print("  if (arm === {d}) {{\n", .{index});
            if (arm.payload == .void) {
                try self.print("    nscfAssertConsumed(bytes, 1);\n    return {{ kind: \"{s}\" }};\n", .{kind});
            } else {
                var decode = RecordDecode{
                    .emitter = self,
                    .buf = "bytes",
                    .indent = 2,
                    .start = "1",
                    // Selection is a role of the COMPLETE text-input
                    // protocol, not an arm-name convention. Ordinary unions
                    // with a homonymous arm retain the normal exact-integer
                    // refusal instead of silently clamping their payload.
                    .saturating_selection = emit_mod.isTextInputUnion(self.sidecar, name) and std.mem.eql(u8, arm.name, "set_selection"),
                };
                var construction: []const u8 = undefined;
                if (self.synthesizedRecordOf(arm.payload, entry.name, arm.name)) |record| {
                    try decode.run(record);
                    const inner = try decode.constructionText(record);
                    construction = try std.fmt.allocPrint(self.arena, "{{ kind: \"{s}\",{s}}}", .{ kind, inner[1 .. inner.len - 1] });
                } else {
                    const field = sidecar_mod.Field{ .name = self.memberOf(arm.member), .type = arm.payload };
                    try decode.fieldLocal(field, entry.name, arm.name);
                    construction = try std.fmt.allocPrint(self.arena, "{{ kind: \"{s}\", {s}: {s} }}", .{ kind, try tsProp(self.arena, self.memberOf(arm.member)), decode.exprs.items[0].text });
                }
                try self.print("    nscfAssertConsumed(bytes, {s});\n", .{decode.offsetText()});
                if (decode.guards.items.len > 0) {
                    try self.print("    if ({s}) {{\n      return {s};\n    }}\n    nscfTrap(\"a decoded integer value is NaN or outside its attested exact-integer range — the integer slot has no honest value for it\");\n", .{ decode.guards.items, construction });
                } else {
                    try self.print("    return {s};\n", .{construction});
                }
            }
            try self.raw("  }\n");
        }
        try self.raw("  nscfTrap(\"a dispatched union payload carries a union arm index past the declared arms — the host and this core disagree about the contract\");\n}\n");
    }

    // -------------------------------------------------- codec section

    fn codecSection(self: *FacadeEmitter) Error!void {
        // Emitted in fixed dependency order; each snippet appears only
        // when generated code above reaches it.
        if (self.used_codec.count() == 0) return;
        try self.raw(
            \\
            \\// -------------------------------------------------- the wire codec
            \\// The canonical value encoding (little-endian, headerless,
            \\// schema-driven) plus the v3 command/subscription wire format the
            \\// host consumes — byte-identical to what the transpiler lane emits,
            \\// proven by the paired e2e batteries.
            \\
        );
        if (self.used_codec.contains(.trap)) {
            try self.raw(
                \\
                \\function nscfTrap(teaching: string): never {
                \\  throw new Error(teaching);
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.read_u8)) {
            try self.raw(
                \\
                \\function nscfReadU8(bytes: Uint8Array, at: number): number {
                \\  if (at >= bytes.length) {
                \\    nscfTrap("a dispatch payload ended mid-value — the host and this core disagree about a type's layout");
                \\  }
                \\  return bytes[at]!;
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.read_u32)) {
            try self.raw(
                \\
                \\function nscfReadU32(bytes: Uint8Array, at: number): number {
                \\  if (at + 4 > bytes.length) {
                \\    nscfTrap("a dispatch payload ended mid-value — the host and this core disagree about a type's layout");
                \\  }
                \\  return bytes[at]! + bytes[at + 1]! * 256 + bytes[at + 2]! * 65536 + bytes[at + 3]! * 16777216;
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.read_f64)) {
            try self.raw(
                \\
                \\function nscfReadF64(bytes: Uint8Array, at: number): number {
                \\  if (at + 8 > bytes.length) {
                \\    nscfTrap("a dispatch payload ended mid-value — the host and this core disagree about a type's layout");
                \\  }
                \\  const buf = Buffer.alloc(8);
                \\  for (let i = 0; i < 8; i++) {
                \\    buf[i] = bytes[at + i]!;
                \\  }
                \\  return buf.readDoubleLE(0);
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.read_i64)) {
            try self.raw(
                \\
                \\function nscfReadI64(bytes: Uint8Array, at: number): number {
                \\  const lo = nscfReadU32(bytes, at);
                \\  const hi = nscfReadU32(bytes, at + 4);
                \\  const hiSigned = hi >= 2147483648 ? hi - 4294967296 : hi;
                \\  const value = hiSigned * 4294967296 + lo;
                \\  if (value > 9007199254740991 || value < -9007199254740991) {
                \\    nscfTrap("an integer payload is at or past 2^53 — the f64 number model has no honest value for it");
                \\  }
                \\  return value;
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.read_i64_saturating)) {
            try self.raw(
                \\
                \\// An i64 payload saturated into the f64-exact window: values at or
                \\// past +-2^53 clamp to +-(2^53 - 1). Selection offsets ride this
                \\// reader because the host's select-all synthesizes the maxInt "to
                \\// the end" sentinel, which every consumer snaps to the text's
                \\// length.
                \\function nscfReadI64Saturating(bytes: Uint8Array, at: number): number {
                \\  const lo = nscfReadU32(bytes, at);
                \\  const hi = nscfReadU32(bytes, at + 4);
                \\  const hiSigned = hi >= 2147483648 ? hi - 4294967296 : hi;
                \\  const value = hiSigned * 4294967296 + lo;
                \\  if (value > 9007199254740991) return 9007199254740991;
                \\  if (value < -9007199254740991) return -9007199254740991;
                \\  return value;
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.read_u64_saturating)) {
            try self.raw(
                \\
                \\// A u64 payload saturated into the nonnegative f64-exact window.
                \\// Selection offsets use this twin when their sidecar slot is
                \\// unsigned: maxInt(usize) is all-one bits, not signed -1.
                \\function nscfReadU64Saturating(bytes: Uint8Array, at: number): number {
                \\  const lo = nscfReadU32(bytes, at);
                \\  const hi = nscfReadU32(bytes, at + 4);
                \\  if (hi > 2097151) return 9007199254740991;
                \\  return hi * 4294967296 + lo;
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.read_bool)) {
            try self.raw(
                \\
                \\function nscfReadBool(bytes: Uint8Array, at: number): boolean {
                \\  if (at >= bytes.length) {
                \\    nscfTrap("a dispatch payload ended mid-value — the host and this core disagree about a type's layout");
                \\  }
                \\  const raw = bytes[at]!;
                \\  if (raw > 1) {
                \\    nscfTrap("a dispatch payload carries a boolean discriminant past 1 — the host and this core disagree about a type's layout");
                \\  }
                \\  return raw === 1;
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.read_bytes_body)) {
            try self.raw(
                \\
                \\function nscfReadBytesBody(bytes: Uint8Array, at: number, len: number): Uint8Array {
                \\  if (at + len > bytes.length) {
                \\    nscfTrap("a dispatch payload ended mid-value — the host and this core disagree about a type's layout");
                \\  }
                \\  const out = new Uint8Array(len);
                \\  for (let i = 0; i < len; i++) {
                \\    out[i] = bytes[at + i]!;
                \\  }
                \\  return out;
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.assert_consumed)) {
            try self.raw(
                \\
                \\function nscfAssertConsumed(bytes: Uint8Array, at: number): void {
                \\  if (at !== bytes.length) {
                \\    nscfTrap("a dispatch payload carries bytes past the decoded value — the host and this core disagree about a type's layout");
                \\  }
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.trunc_toward_zero)) {
            try self.raw(
                \\
                \\// An i64-classed slot narrows core-side by truncation toward zero
                \\// (producers guarantee integer-classed values are exact below 2^53).
                \\function nscfTruncTowardZero(value: number): number {
                \\  return value < 0 ? -Math.floor(-value) : Math.floor(value);
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.sink)) {
            try self.raw(
                \\
                \\// A sink is a plain byte accumulator; nscfFinish snapshots it.
                \\type nscfSink = number[];
                \\
                \\function nscfNewSink(): nscfSink {
                \\  return [];
                \\}
                \\
                \\function nscfFinish(sink: nscfSink): Uint8Array {
                \\  const out = new Uint8Array(sink.length);
                \\  for (let i = 0; i < sink.length; i++) {
                \\    out[i] = sink[i]!;
                \\  }
                \\  return out;
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.w_u8)) {
            try self.raw(
                \\
                \\function nscfWU8(sink: nscfSink, value: number): void {
                \\  sink.push(value);
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.w_u32)) {
            try self.raw(
                \\
                \\function nscfWU32(sink: nscfSink, value: number): void {
                \\  sink.push(value % 256);
                \\  sink.push(Math.floor(value / 256) % 256);
                \\  sink.push(Math.floor(value / 65536) % 256);
                \\  sink.push(Math.floor(value / 16777216) % 256);
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.w_f64)) {
            try self.raw(
                \\
                \\function nscfWF64(sink: nscfSink, value: number): void {
                \\  const buf = Buffer.alloc(8);
                \\  buf.writeDoubleLE(value, 0);
                \\  for (let i = 0; i < 8; i++) {
                \\    sink.push(buf[i]!);
                \\  }
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.w_i64)) {
            try self.raw(
                \\
                \\// Two's-complement i64, exact for every integer within +-(2^53 - 1).
                \\function nscfWI64(sink: nscfSink, value: number): void {
                \\  if (value > 9007199254740991 || value < -9007199254740991 || value !== nscfTruncTowardZero(value)) {
                \\    nscfTrap("an integer slot carries a non-integer or out-of-range value — the i64 encoding has no honest bytes for it");
                \\  }
                \\  const hi = Math.floor(value / 4294967296);
                \\  const lo = value - hi * 4294967296;
                \\  const hiWire = hi < 0 ? hi + 4294967296 : hi;
                \\  nscfWU32(sink, lo);
                \\  nscfWU32(sink, hiWire);
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.w_u64)) {
            try self.raw(
                \\
                \\// The unsigned twin for u64-attested slots: 8-byte unsigned LE,
                \\// refusing negatives (a negative value has no honest unsigned
                \\// bytes).
                \\function nscfWU64(sink: nscfSink, value: number): void {
                \\  if (value > 9007199254740991 || value < 0 || value !== nscfTruncTowardZero(value)) {
                \\    nscfTrap("an unsigned integer slot carries a non-integer, negative, or out-of-range value — the u64 encoding has no honest bytes for it");
                \\  }
                \\  const hi = Math.floor(value / 4294967296);
                \\  const lo = value - hi * 4294967296;
                \\  nscfWU32(sink, lo);
                \\  nscfWU32(sink, hi);
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.w_bool)) {
            try self.raw(
                \\
                \\function nscfWBool(sink: nscfSink, value: boolean): void {
                \\  sink.push(value ? 1 : 0);
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.w_bytes)) {
            try self.raw(
                \\
                \\// A u32-length-prefixed bytes value (the canonical bytes encoding,
                \\// and the wire format's long-bytes field).
                \\function nscfWBytes(sink: nscfSink, bytes: Uint8Array): void {
                \\  nscfWU32(sink, bytes.length);
                \\  for (let i = 0; i < bytes.length; i++) {
                \\    sink.push(bytes[i]!);
                \\  }
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.short_text)) {
            try self.raw(
                \\
                \\function nscfTextBytes(text: string): Uint8Array {
                \\  const out = new Uint8Array(text.length);
                \\  for (let i = 0; i < text.length; i++) {
                \\    out[i] = text.charCodeAt(i);
                \\  }
                \\  return out;
                \\}
                \\
                \\// A u8-length-prefixed short text field (names, keys, labels).
                \\function nscfWShortText(sink: nscfSink, text: string): void {
                \\  const bytes = nscfTextBytes(text);
                \\  if (bytes.length > 255) {
                \\    nscfTrap("a command name or key is over 255 bytes — the wire's short-text fields cannot carry it");
                \\  }
                \\  sink.push(bytes.length);
                \\  for (let i = 0; i < bytes.length; i++) {
                \\    sink.push(bytes[i]!);
                \\  }
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.ascii_string)) {
            try self.raw(
                \\
                \\function nscfAsciiString(bytes: Uint8Array): string {
                \\  let out = "";
                \\  for (let i = 0; i < bytes.length; i++) out = out + String.fromCharCode(bytes[i]!);
                \\  return out;
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.enum_index)) {
            try self.raw(
                \\
                \\function nscfMemberIndex(members: string[], value: string, what: string): number {
                \\  for (let i = 0; i < members.length; i++) {
                \\    if (members[i] === value) return i;
                \\  }
                \\  nscfTrap("a command carries an unknown " + what + " member — the SDK and this generated module disagree");
                \\}
                \\
            );
        }
        if (self.used_codec.contains(.cmd_encoder)) {
            try self.cmdEncoder();
        }
        if (self.used_codec.contains(.sub_encoder)) {
            try self.subEncoder();
        }
    }

    /// The v3 command wire encoder — byte-for-byte the layouts the
    /// host's rt builds (wire.ts's encodeCmd, per-module).
    fn cmdEncoder(self: *FacadeEmitter) Error!void {
        const msg = self.sidecar.msg.name;
        try self.print(
            \\
            \\// ---------------------------------------------------- the cmd wire
            \\// Encoder for the inert Cmd data the author's update returns —
            \\// byte-for-byte the layouts the host's command decoder expects
            \\// (cmd_format_version 3). nscfTagOf maps a Msg arm name onto its
            \\// declaration-order wire tag.
            \\
            \\const nscfFetchMethods = ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD"];
            \\const nscfAudioVerbs = ["pause", "resume", "stop", "seek", "volume"];
            \\const nscfVideoVerbs = ["play", "pause", "stop", "seek", "volume", "muted", "loop"];
            \\
            \\function nscfEncodeCmd(sink: nscfSink, cmd: nscfCmd<{s}>): void {{
            \\
        , .{msg});
        try self.raw(
            \\  switch (cmd.op) {
            \\    case "none":
            \\      return;
            \\    case "persist":
            \\      nscfWU8(sink, 0x01);
            \\      return;
            \\    case "now":
            \\      nscfWU8(sink, 0x02);
            \\      nscfWU8(sink, nscfTagOf(cmd.msgKind));
            \\      return;
            \\    case "host": {
            \\      nscfWU8(sink, 0x03);
            \\      nscfWShortText(sink, cmd.name);
            \\      if (cmd.args.length > 255) {
            \\        nscfTrap("a host command carries over 255 scalar args — the wire's arg block cannot carry it");
            \\      }
            \\      nscfWU8(sink, cmd.args.length);
            \\      for (let i = 0; i < cmd.args.length; i++) {
            \\        nscfWF64(sink, cmd.args[i]!);
            \\      }
            \\      return;
            \\    }
            \\    case "host_bytes":
            \\      nscfWU8(sink, 0x04);
            \\      nscfWShortText(sink, cmd.name);
            \\      nscfWBytes(sink, cmd.payload);
            \\      return;
            \\    case "request":
            \\      nscfWU8(sink, 0x05);
            \\      nscfWShortText(sink, cmd.name);
            \\      nscfWShortText(sink, cmd.key);
            \\      nscfWU8(sink, nscfTagOf(cmd.okKind));
            \\      nscfWU8(sink, nscfTagOf(cmd.errKind));
            \\      nscfWBytes(sink, cmd.payload);
            \\      return;
            \\    case "cancel":
            \\      nscfWU8(sink, 0x06);
            \\      nscfWShortText(sink, cmd.key);
            \\      return;
            \\    case "read_file":
            \\      nscfWU8(sink, 0x07);
            \\      nscfWShortText(sink, cmd.key);
            \\      nscfWU8(sink, nscfTagOf(cmd.okKind));
            \\      nscfWU8(sink, nscfTagOf(cmd.errKind));
            \\      nscfWBytes(sink, cmd.path);
            \\      return;
            \\    case "write_file":
            \\      nscfWU8(sink, 0x08);
            \\      nscfWShortText(sink, cmd.key);
            \\      nscfWU8(sink, nscfTagOf(cmd.okKind));
            \\      nscfWU8(sink, nscfTagOf(cmd.errKind));
            \\      nscfWBytes(sink, cmd.path);
            \\      nscfWBytes(sink, cmd.bytes);
            \\      return;
            \\    case "fetch": {
            \\      nscfWU8(sink, 0x09);
            \\      nscfWShortText(sink, cmd.key);
            \\      nscfWU8(sink, nscfTagOf(cmd.okKind));
            \\      nscfWU8(sink, nscfTagOf(cmd.errKind));
            \\      nscfWU8(sink, nscfMemberIndex(nscfFetchMethods, cmd.method, "fetch method"));
            \\      nscfWU32(sink, cmd.timeoutMs);
            \\      nscfWBytes(sink, cmd.url);
            \\      if (cmd.headers.length > 255) {
            \\        nscfTrap("a fetch carries over 255 headers — the wire's header block cannot carry it");
            \\      }
            \\      nscfWU8(sink, cmd.headers.length);
            \\      for (let i = 0; i < cmd.headers.length; i++) {
            \\        const header = cmd.headers[i]!;
            \\        nscfWShortText(sink, header.name);
            \\        const value = header.value;
            \\        nscfWBytes(sink, typeof value === "string" ? nscfTextBytes(value) : value);
            \\      }
            \\      nscfWBytes(sink, cmd.body);
            \\      return;
            \\    }
            \\    case "clip_write":
            \\      nscfWU8(sink, 0x0a);
            \\      nscfWBytes(sink, cmd.bytes);
            \\      return;
            \\    case "clip_read":
            \\      nscfWU8(sink, 0x0b);
            \\      nscfWShortText(sink, cmd.key);
            \\      nscfWU8(sink, nscfTagOf(cmd.okKind));
            \\      nscfWU8(sink, nscfTagOf(cmd.errKind));
            \\      return;
            \\    case "delay":
            \\      nscfWU8(sink, 0x0c);
            \\      nscfWShortText(sink, cmd.key);
            \\      nscfWF64(sink, cmd.afterMs);
            \\      nscfWU8(sink, nscfTagOf(cmd.msgKind));
            \\      return;
            \\    case "spawn": {
            \\      nscfWU8(sink, 0x0d);
            \\      nscfWShortText(sink, cmd.key);
            \\      nscfWU8(sink, cmd.lineKind === "" ? 0xff : nscfTagOf(cmd.lineKind));
            \\      nscfWU8(sink, nscfTagOf(cmd.exitKind));
            \\      nscfWU8(sink, nscfTagOf(cmd.errKind));
            \\      nscfWU8(sink, cmd.collect ? 1 : 0);
            \\      if (cmd.argv.length === 0 || cmd.argv.length > 255) {
            \\        nscfTrap("a spawn carries no argv or over 255 argv entries — the wire's argv block cannot carry it");
            \\      }
            \\      nscfWU8(sink, cmd.argv.length);
            \\      for (let i = 0; i < cmd.argv.length; i++) {
            \\        nscfWBytes(sink, cmd.argv[i]!);
            \\      }
            \\      nscfWBytes(sink, cmd.stdin);
            \\      return;
            \\    }
            \\    case "audio_play":
            \\      nscfWU8(sink, 0x0e);
            \\      nscfWShortText(sink, cmd.key);
            \\      nscfWU8(sink, nscfTagOf(cmd.eventKind));
            \\      nscfWBytes(sink, cmd.path);
            \\      nscfWBytes(sink, cmd.url);
            \\      nscfWBytes(sink, cmd.cachePath);
            \\      nscfWF64(sink, cmd.expectedBytes);
            \\      return;
            \\    case "audio_ctl":
            \\      nscfWU8(sink, 0x0f);
            \\      nscfWShortText(sink, cmd.key);
            \\      nscfWU8(sink, nscfMemberIndex(nscfAudioVerbs, cmd.verb, "audio verb"));
            \\      nscfWF64(sink, cmd.value);
            \\      return;
            \\    case "window_show":
            \\      nscfWU8(sink, 0x10);
            \\      nscfWShortText(sink, cmd.label);
            \\      return;
            \\    case "webview_navigate":
            \\      nscfWU8(sink, 0x1e);
            \\      nscfWShortText(sink, cmd.label);
            \\      nscfWBytes(sink, cmd.url);
            \\      return;
            \\    case "quit_app":
            \\      nscfWU8(sink, 0x11);
            \\      return;
            \\    case "image_load":
            \\      nscfWU8(sink, 0x12);
            \\      nscfWF64(sink, cmd.id);
            \\      nscfWU8(sink, nscfTagOf(cmd.eventKind));
            \\      nscfWBytes(sink, cmd.path);
            \\      nscfWBytes(sink, cmd.url);
            \\      nscfWBytes(sink, cmd.cachePath);
            \\      nscfWF64(sink, cmd.expectedBytes);
            \\      return;
            \\    case "image_cancel":
            \\      nscfWU8(sink, 0x13);
            \\      nscfWF64(sink, cmd.id);
            \\      return;
            \\    case "image_unregister":
            \\      nscfWU8(sink, 0x14);
            \\      nscfWF64(sink, cmd.id);
            \\      return;
            \\    case "channel_open":
            \\      nscfWU8(sink, 0x15);
            \\      nscfWF64(sink, cmd.key);
            \\      nscfWU8(sink, nscfTagOf(cmd.eventKind));
            \\      return;
            \\    case "channel_close":
            \\      nscfWU8(sink, 0x16);
            \\      nscfWF64(sink, cmd.key);
            \\      return;
            \\    case "video_load": {
            \\      nscfWU8(sink, 0x17);
            \\      nscfWShortText(sink, cmd.key);
            \\      nscfWU8(sink, nscfTagOf(cmd.eventKind));
            \\      nscfWF64(sink, cmd.surface);
            \\      nscfWBytes(sink, cmd.path);
            \\      nscfWBytes(sink, cmd.url);
            \\      // Wire flags: bit0 = autoplay, bit1 = loop, bit2 = muted.
            \\      let flags = 0;
            \\      if (cmd.autoplay) flags = flags + 1;
            \\      if (cmd.loop) flags = flags + 2;
            \\      if (cmd.muted) flags = flags + 4;
            \\      nscfWU8(sink, flags);
            \\      return;
            \\    }
            \\    case "video_ctl":
            \\      nscfWU8(sink, 0x18);
            \\      nscfWShortText(sink, cmd.key);
            \\      nscfWU8(sink, nscfMemberIndex(nscfVideoVerbs, cmd.verb, "video verb"));
            \\      nscfWF64(sink, cmd.value);
            \\      return;
            \\    case "pty_spawn": {
            \\      nscfWU8(sink, 0x19);
            \\      nscfWShortText(sink, cmd.key);
            \\      nscfWU8(sink, nscfTagOf(cmd.eventKind));
            \\      nscfWF64(sink, cmd.cols);
            \\      nscfWF64(sink, cmd.rows);
            \\      nscfWShortText(sink, cmd.term);
            \\      if (cmd.argv.length === 0 || cmd.argv.length > 255) {
            \\        nscfTrap("a pty spawn carries no argv or over 255 argv entries — the wire's argv block cannot carry it");
            \\      }
            \\      nscfWU8(sink, cmd.argv.length);
            \\      for (let i = 0; i < cmd.argv.length; i++) {
            \\        nscfWBytes(sink, cmd.argv[i]!);
            \\      }
            \\      return;
            \\    }
            \\    case "pty_write":
            \\      nscfWU8(sink, 0x1a);
            \\      nscfWShortText(sink, cmd.key);
            \\      nscfWBytes(sink, cmd.bytes);
            \\      return;
            \\    case "pty_resize":
            \\      nscfWU8(sink, 0x1b);
            \\      nscfWShortText(sink, cmd.key);
            \\      nscfWF64(sink, cmd.cols);
            \\      nscfWF64(sink, cmd.rows);
            \\      return;
            \\    case "pty_kill":
            \\      nscfWU8(sink, 0x1c);
            \\      nscfWShortText(sink, cmd.key);
            \\      return;
            \\    case "show_notification":
            \\      nscfWU8(sink, 0x1d);
            \\      nscfWBytes(sink, cmd.title);
            \\      nscfWBytes(sink, cmd.subtitle);
            \\      nscfWBytes(sink, cmd.body);
            \\      return;
            \\    case "batch":
            \\      for (let i = 0; i < cmd.cmds.length; i++) {
            \\        nscfEncodeCmd(sink, cmd.cmds[i]!);
            \\      }
            \\      return;
            \\  }
            \\}
            \\
        );
        try self.print(
            \\
            \\function nscfCmdBytes(cmd: nscfCmd<{s}>): Uint8Array {{
            \\  const sink = nscfNewSink();
            \\  nscfEncodeCmd(sink, cmd);
            \\  return nscfFinish(sink);
            \\}}
            \\
        , .{msg});
    }

    fn subEncoder(self: *FacadeEmitter) Error!void {
        const msg = self.sidecar.msg.name;
        try self.print(
            \\
            \\// The v3 subscription wire (timer subscriptions).
            \\function nscfEncodeSub(sink: nscfSink, sub: nscfSub<{s}>): void {{
            \\  switch (sub.op) {{
            \\    case "none":
            \\      return;
            \\    case "timer":
            \\      nscfWU8(sink, 0x01);
            \\      nscfWShortText(sink, sub.key);
            \\      nscfWF64(sink, sub.everyMs);
            \\      nscfWU8(sink, nscfTagOf(sub.msgKind));
            \\      return;
            \\    case "batch":
            \\      for (let i = 0; i < sub.subs.length; i++) {{
            \\        nscfEncodeSub(sink, sub.subs[i]!);
            \\      }}
            \\      return;
            \\  }}
            \\}}
            \\
            \\function nscfSubBytes(sub: nscfSub<{s}>): Uint8Array {{
            \\  const sink = nscfNewSink();
            \\  nscfEncodeSub(sink, sub);
            \\  return nscfFinish(sink);
            \\}}
            \\
        , .{ msg, msg });
    }

    // ---------------------------------------------------- spellings

    /// The one TypeRef-to-TypeScript-spelling authority.
    fn spellRef(self: *FacadeEmitter, ref: TypeRef) Error![]const u8 {
        return switch (ref) {
            .bool => "boolean",
            .f64, .i64 => "number",
            .bytes => "Uint8Array",
            .void => "void",
            .optional => |inner| try std.fmt.allocPrint(self.arena, "{s} | null", .{try self.spellRef(inner.*)}),
            .slice => |elem| blk: {
                // Composite element spellings parenthesize: `number |
                // null[]` would type the null as the array.
                const spelled = try self.spellRef(elem.*);
                if (std.mem.indexOfAny(u8, spelled, " |") != null) {
                    break :blk try std.fmt.allocPrint(self.arena, "({s})[]", .{spelled});
                }
                break :blk try std.fmt.allocPrint(self.arena, "{s}[]", .{spelled});
            },
            // Reference storage is a layout fact of the host mirror;
            // TypeScript sees the record value either way.
            .node, .value, .enum_ref, .union_ref => |name| blk: {
                try self.reference(name);
                break :blk name;
            },
        };
    }

    fn indentText(self: *FacadeEmitter, depth: usize) Error![]const u8 {
        const text = try self.arena.alloc(u8, depth * 2);
        @memset(text, ' ');
        return text;
    }

    /// The struct behind a synthesized, inlined record reference at
    /// this site — the shape that flattens beside `kind`. VALUE
    /// references only: flattening is a by-value layout, so a
    /// node-stored payload keeps its named declaration however its
    /// name is spelled.
    fn synthesizedRecordOf(self: *FacadeEmitter, ref: TypeRef, container: []const u8, member: []const u8) ?*const sidecar_mod.Struct {
        const name = switch (ref) {
            .value => |n| n,
            else => return null,
        };
        if (!emit_mod.isSynthesizedRef(container, member, name) or !nameListed(self.inlined, name)) return null;
        const record = sidecar_mod.findStruct(self.sidecar.types, name) orelse return null;
        if (record.origin != null) return null;
        return record;
    }

    /// The synthesized single-use records this projection flattens into
    /// their one arm literal: neither a re-export nor a named writer
    /// ever spells them (the compiler re-derives the same names from
    /// the inline arms).
    fn flattenedTableNames(self: *FacadeEmitter) Error![]const []const u8 {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.sidecar.msg.arms) |arm| {
            switch (arm.payload) {
                .record => {
                    if (self.synthesizedRecordOf(recordPayloadRef(arm.payload), self.sidecar.msg.name, arm.name)) |record| {
                        try names.append(self.arena, record.name);
                    }
                },
                else => {},
            }
        }
        for (self.sidecar.types.unions) |entry| {
            for (entry.arms) |arm| {
                if (arm.payload == .void) continue;
                if (self.synthesizedRecordOf(arm.payload, entry.name, arm.name)) |record| {
                    try names.append(self.arena, record.name);
                }
            }
        }
        return names.items;
    }

    /// The record names the contract stores BY REFERENCE anywhere.
    fn nodeStoredTableNames(self: *FacadeEmitter) Error![]const []const u8 {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        // The model root is reference-stored by contract (no explicit
        // reference spells it), so it seeds the set: a `value`
        // reference to the root elsewhere is the mixed-storage case and
        // refuses like any other.
        try names.append(self.arena, self.sidecar.model);
        for (self.sidecar.types.structs) |entry| {
            for (entry.fields) |field| {
                try noteNodeRefs(&names, self.arena, field.type);
            }
        }
        for (self.sidecar.types.unions) |entry| {
            for (entry.arms) |arm| {
                try noteNodeRefs(&names, self.arena, arm.payload);
            }
        }
        for (self.sidecar.model_helpers) |helper| {
            try noteNodeRefs(&names, self.arena, helper.returns);
            for (helper.params) |param| try noteNodeRefs(&names, self.arena, param);
        }
        for (self.sidecar.msg.arms) |arm| {
            switch (arm.payload) {
                .scalar => |ref| try noteNodeRefs(&names, self.arena, ref),
                else => {},
            }
        }
        return names.items;
    }
};

/// Locals-then-construction decode of canonical bytes. The emitted mutable
/// cursor advances in the lexical branch that consumes each value, so
/// nonterminal optionals and variable-width composites compose naturally.
/// Integer locals join the nearest construction guard and state wholeness
/// with Math.trunc at the guarded write.
const RecordDecode = struct {
    emitter: *FacadeEmitter,
    buf: []const u8,
    indent: usize,
    start: []const u8 = "0",
    saturating_selection: bool = false,
    local_count: usize = 0,
    cursor_started: bool = false,
    guards: std.ArrayListUnmanaged(u8) = .empty,
    exprs: std.ArrayListUnmanaged(struct { name: []const u8, text: []const u8 }) = .empty,

    const Self = @This();

    fn arena(self: *Self) std.mem.Allocator {
        return self.emitter.arena;
    }

    fn offsetText(_: *Self) []const u8 {
        return "nscfAt";
    }

    fn nextLocal(self: *Self) Error![]const u8 {
        const name = try std.fmt.allocPrint(self.arena(), "nscfV{d}", .{self.local_count});
        self.local_count += 1;
        return name;
    }

    fn line(self: *Self, comptime fmt: []const u8, args: anytype) Error!void {
        const pad = try self.emitter.indentText(self.indent);
        try self.emitter.print("{s}", .{pad});
        try self.emitter.print(fmt, args);
    }

    fn ensureCursor(self: *Self) Error!void {
        if (self.cursor_started) return;
        self.cursor_started = true;
        try self.line("let nscfAt = {s};\n", .{self.start});
    }

    fn advance(self: *Self, amount: []const u8) Error!void {
        try self.line("nscfAt += {s};\n", .{amount});
    }

    fn advanceFixed(self: *Self, amount: usize) Error!void {
        try self.advance(try std.fmt.allocPrint(self.arena(), "{d}", .{amount}));
    }

    fn addGuard(self: *Self, guards: *std.ArrayListUnmanaged(u8), local: []const u8, class: IntegerClass) Error!void {
        if (guards.items.len > 0) try guards.appendSlice(self.arena(), " && ");
        try guards.appendSlice(self.arena(), try std.fmt.allocPrint(self.arena(), "{s} >= {s} && {s} <= {s}", .{ local, integerLowerBound(class), local, max_safe }));
    }

    fn guardedStatement(self: *Self, guards: []const u8, statement: []const u8) Error!void {
        if (guards.len == 0) {
            try self.line("{s}\n", .{statement});
            return;
        }
        try self.line("if ({s}) {{\n", .{guards});
        self.indent += 1;
        try self.line("{s}\n", .{statement});
        self.indent -= 1;
        try self.line("}} else {{\n", .{});
        self.indent += 1;
        try self.line("nscfTrap(\"a decoded integer value is NaN or outside its attested exact-integer range — the integer slot has no honest value for it\");\n", .{});
        self.indent -= 1;
        try self.line("}}\n", .{});
        self.emitter.use(.trap);
    }

    fn run(self: *Self, record: *const sidecar_mod.Struct) Error!void {
        try self.ensureCursor();
        for (record.fields) |field| try self.fieldLocal(field, record.name, field.name);
    }

    fn fieldLocal(self: *Self, field: sidecar_mod.Field, container: []const u8, member: []const u8) Error!void {
        try self.ensureCursor();
        const text = try self.decodeRef(field.type, field.name, container, member, &self.guards);
        try self.exprs.append(self.arena(), .{ .name = field.name, .text = text });
    }

    fn decodeRecord(self: *Self, record: *const sidecar_mod.Struct, guards: *std.ArrayListUnmanaged(u8)) Error![]const u8 {
        var parts: std.ArrayListUnmanaged(u8) = .empty;
        for (record.fields, 0..) |field, index| {
            const text = try self.decodeRef(field.type, field.name, record.name, field.name, guards);
            if (index > 0) try parts.appendSlice(self.arena(), ", ");
            try parts.appendSlice(self.arena(), try std.fmt.allocPrint(self.arena(), "{s}: {s}", .{ try tsProp(self.arena(), field.name), text }));
        }
        return try std.fmt.allocPrint(self.arena(), "{{ {s} }}", .{parts.items});
    }

    fn decodeUnion(self: *Self, name: []const u8) Error![]const u8 {
        const em = self.emitter;
        const entry = sidecar_mod.findUnion(em.sidecar.types, name) orelse {
            em.diags.flag("types", "\"{s}\" names no tabled union", .{name});
            return "undefined";
        };
        em.use(.read_u8);
        const tag = try self.nextLocal();
        try self.line("const {s} = nscfReadU8({s}, nscfAt);\n", .{ tag, self.buf });
        try self.advanceFixed(1);
        const local = try self.nextLocal();
        try self.line("let {s}: {s};\n", .{ local, name });
        for (entry.arms, 0..) |arm, index| {
            try self.line("{s}if ({s} === {d}) {{\n", .{ if (index == 0) "" else "else ", tag, index });
            self.indent += 1;
            var arm_guards: std.ArrayListUnmanaged(u8) = .empty;
            const object = if (arm.payload == .void)
                try std.fmt.allocPrint(self.arena(), "{{ kind: \"{s}\" }}", .{try tsString(self.arena(), arm.name)})
            else if (em.synthesizedRecordOf(arm.payload, entry.name, arm.name)) |record| blk: {
                const inner = try self.decodeRecord(record, &arm_guards);
                break :blk try std.fmt.allocPrint(self.arena(), "{{ kind: \"{s}\",{s}}}", .{ try tsString(self.arena(), arm.name), inner[1 .. inner.len - 1] });
            } else blk: {
                const value = try self.decodeRef(arm.payload, em.memberOf(arm.member), entry.name, arm.name, &arm_guards);
                break :blk try std.fmt.allocPrint(self.arena(), "{{ kind: \"{s}\", {s}: {s} }}", .{ try tsString(self.arena(), arm.name), try tsProp(self.arena(), em.memberOf(arm.member)), value });
            };
            try self.guardedStatement(arm_guards.items, try std.fmt.allocPrint(self.arena(), "{s} = {s};", .{ local, object }));
            self.indent -= 1;
            try self.line("}}\n", .{});
        }
        try self.line("else {{\n", .{});
        self.indent += 1;
        try self.line("nscfTrap(\"a dispatched union payload carries a union arm index past the declared arms — the host and this core disagree about the contract\");\n", .{});
        self.indent -= 1;
        try self.line("}}\n", .{});
        em.use(.trap);
        return local;
    }

    fn decodeRef(self: *Self, ref: TypeRef, field_name: []const u8, container: []const u8, member: []const u8, guards: *std.ArrayListUnmanaged(u8)) Error![]const u8 {
        const em = self.emitter;
        return switch (ref) {
            .f64 => blk: {
                em.use(.read_f64);
                const local = try self.nextLocal();
                try self.line("const {s} = nscfReadF64({s}, nscfAt);\n", .{ local, self.buf });
                try self.advanceFixed(8);
                break :blk local;
            },
            .i64 => blk: {
                const class = em.slotClass(container, member) orelse .i64;
                const selection_field = std.mem.eql(u8, field_name, "anchor") or std.mem.eql(u8, field_name, "focus");
                const reader: Codec = if (self.saturating_selection and selection_field)
                    if (class == .u64) .read_u64_saturating else .read_i64_saturating
                else
                    .read_i64;
                em.use(reader);
                const local = try self.nextLocal();
                const reader_name = switch (reader) {
                    .read_i64 => "nscfReadI64",
                    .read_i64_saturating => "nscfReadI64Saturating",
                    .read_u64_saturating => "nscfReadU64Saturating",
                    else => unreachable,
                };
                try self.line("const {s} = {s}({s}, nscfAt);\n", .{ local, reader_name, self.buf });
                try self.advanceFixed(8);
                try self.addGuard(guards, local, class);
                break :blk try std.fmt.allocPrint(self.arena(), "Math.trunc({s})", .{local});
            },
            .bool => blk: {
                em.use(.read_bool);
                const local = try self.nextLocal();
                try self.line("const {s} = nscfReadBool({s}, nscfAt);\n", .{ local, self.buf });
                try self.advanceFixed(1);
                break :blk local;
            },
            .bytes => blk: {
                em.use(.read_u32);
                em.use(.read_bytes_body);
                const len_local = try self.nextLocal();
                try self.line("const {s} = nscfReadU32({s}, nscfAt);\n", .{ len_local, self.buf });
                try self.advanceFixed(4);
                const local = try self.nextLocal();
                try self.line("const {s} = nscfReadBytesBody({s}, nscfAt, {s});\n", .{ local, self.buf, len_local });
                try self.advance(len_local);
                break :blk local;
            },
            .enum_ref => |name| blk: {
                em.use(.read_u32);
                try em.needEnumTable(name);
                em.needs_member_trap = true;
                const local = try self.nextLocal();
                try self.line("const {s} = nscfReadU32({s}, nscfAt);\n", .{ local, self.buf });
                try self.line("if ({s} >= nscfMembers{s}.length) nscfMember(\"{s}\", {s});\n", .{ local, name, try tsString(self.arena(), name), local });
                try self.advanceFixed(4);
                break :blk try std.fmt.allocPrint(self.arena(), "nscfMembers{s}[{s}]!", .{ name, local });
            },
            .node, .value => |name| blk: {
                const nested = sidecar_mod.findStruct(em.sidecar.types, name) orelse {
                    em.diags.flag("types", "\"{s}\" names no tabled record", .{name});
                    break :blk "undefined";
                };
                break :blk try self.decodeRecord(nested, guards);
            },
            .optional => |inner| blk: {
                em.use(.read_bool);
                const present = try self.nextLocal();
                try self.line("const {s} = nscfReadBool({s}, nscfAt);\n", .{ present, self.buf });
                try self.advanceFixed(1);
                const local = try self.nextLocal();
                try self.line("let {s}: {s} | null = null;\n", .{ local, try em.spellRef(inner.*) });
                try self.line("if ({s}) {{\n", .{present});
                self.indent += 1;
                var inner_guards: std.ArrayListUnmanaged(u8) = .empty;
                const value = try self.decodeRef(inner.*, field_name, container, member, &inner_guards);
                try self.guardedStatement(inner_guards.items, try std.fmt.allocPrint(self.arena(), "{s} = {s};", .{ local, value }));
                self.indent -= 1;
                try self.line("}}\n", .{});
                break :blk local;
            },
            .slice => |elem| blk: {
                em.use(.read_u32);
                const len_local = try self.nextLocal();
                try self.line("const {s} = nscfReadU32({s}, nscfAt);\n", .{ len_local, self.buf });
                try self.advanceFixed(4);
                const local = try self.nextLocal();
                try self.line("const {s}: {s} = [];\n", .{ local, try em.spellRef(ref) });
                const index = try self.nextLocal();
                try self.line("for (let {s} = 0; {s} < {s}; {s}++) {{\n", .{ index, index, len_local, index });
                self.indent += 1;
                var elem_guards: std.ArrayListUnmanaged(u8) = .empty;
                const value = try self.decodeRef(elem.*, field_name, container, member, &elem_guards);
                try self.guardedStatement(elem_guards.items, try std.fmt.allocPrint(self.arena(), "{s}.push({s});", .{ local, value }));
                self.indent -= 1;
                try self.line("}}\n", .{});
                break :blk local;
            },
            .union_ref => |name| try self.decodeUnion(name),
            .void => blk: {
                em.diags.flag("types", "a record field cannot carry void", .{});
                break :blk "undefined";
            },
        };
    }

    fn constructionText(self: *Self, record: *const sidecar_mod.Struct) Error![]const u8 {
        _ = record;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(self.arena(), "{ ");
        for (self.exprs.items, 0..) |entry, index| {
            if (index > 0) try out.appendSlice(self.arena(), ", ");
            try out.appendSlice(self.arena(), try std.fmt.allocPrint(self.arena(), "{s}: {s}", .{ try tsProp(self.arena(), entry.name), entry.text }));
        }
        try out.appendSlice(self.arena(), " }");
        return out.items;
    }
};

/// The scroll entry's parameter feeding an authored scroll field.
fn scrollParamFor(field_name: []const u8) ?[]const u8 {
    for (scroll_state_fields_ts, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, field_name) or std.mem.eql(u8, scroll_state_fields_canvas[index], field_name)) return candidate;
    }
    return null;
}

/// Collect the record names `ref` reaches through NODE references,
/// walking the optional/slice wrappers (a node behind an optional or a
/// sequence is node storage all the same).
fn noteNodeRefs(names: *std.ArrayListUnmanaged([]const u8), arena: std.mem.Allocator, ref: TypeRef) error{OutOfMemory}!void {
    switch (ref) {
        .node => |name| {
            if (!nameListed(names.items, name)) try names.append(arena, name);
        },
        .optional => |inner| try noteNodeRefs(names, arena, inner.*),
        .slice => |elem| try noteNodeRefs(names, arena, elem.*),
        else => {},
    }
}

/// The VALUE-reference twin of noteNodeRefs.
fn noteValueRefs(names: *std.ArrayListUnmanaged([]const u8), arena: std.mem.Allocator, ref: TypeRef) error{OutOfMemory}!void {
    switch (ref) {
        .value => |name| {
            if (!nameListed(names.items, name)) try names.append(arena, name);
        },
        .optional => |inner| try noteValueRefs(names, arena, inner.*),
        .slice => |elem| try noteValueRefs(names, arena, elem.*),
        else => {},
    }
}

/// A msg record payload as the TypeRef shape synthesizedRecordOf reads.
fn recordPayloadRef(payload: sidecar_mod.Payload) TypeRef {
    return switch (payload) {
        .record => |name| .{ .value = name },
        else => unreachable,
    };
}

/// The numeric ABI class of either spelling the sidecar accepts for a
/// one-number message payload. Dedicated descriptors are what current
/// extractors emit; scalar descriptors remain a valid format-1 alias and
/// must reach the same facade entry as the generated mirror.
fn payloadNumberClass(payload: sidecar_mod.Payload) ?sidecar_mod.NumberClass {
    return switch (payload) {
        .number => |class| class,
        .scalar => |ref| switch (ref) {
            .f64 => .f64,
            .i64 => .i64,
            else => null,
        },
        else => null,
    };
}

fn pathText(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(arena, fmt, args) catch "";
}

fn nameListed(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn commentText(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    const out = try arena.dupe(u8, text);
    for (out) |*char| {
        if (char.* < 0x20 or char.* == 0x7f) char.* = ' ';
    }
    // U+2028/U+2029 are line terminators to a TypeScript scanner: blank
    // their UTF-8 bytes so provenance text cannot end the comment early.
    var index: usize = 0;
    while (index + 2 < out.len) : (index += 1) {
        if (out[index] == 0xe2 and out[index + 1] == 0x80 and (out[index + 2] == 0xa8 or out[index + 2] == 0xa9)) {
            out[index] = ' ';
            out[index + 1] = ' ';
            out[index + 2] = ' ';
        }
    }
    return out;
}

/// Escape a name into a TS double-quoted string literal (arm names ride
/// string literals in the kind-tagged union). The scanner's line
/// terminators are LF, CR, LS (U+2028), and PS (U+2029) — all escaped
/// here (NEL U+0085 is ordinary text to the scanner); quotes and
/// backslashes escape byte-for-byte.
fn tsString(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        const char = text[index];
        if (char == 0xe2 and index + 2 < text.len and text[index + 1] == 0x80 and
            (text[index + 2] == 0xa8 or text[index + 2] == 0xa9))
        {
            const escape: []const u8 = if (text[index + 2] == 0xa8) "\\u2028" else "\\u2029";
            try out.appendSlice(arena, escape);
            index += 3;
            continue;
        }
        switch (char) {
            '"' => try out.appendSlice(arena, "\\\""),
            '\\' => try out.appendSlice(arena, "\\\\"),
            '\n' => try out.appendSlice(arena, "\\n"),
            '\r' => try out.appendSlice(arena, "\\r"),
            '\t' => try out.appendSlice(arena, "\\t"),
            else => try out.append(arena, char),
        }
        index += 1;
    }
    return out.items;
}

/// A property spelling: plain identifiers stay bare (reserved words
/// are legal property names); anything else quotes.
fn tsProp(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    if (isIdentifierFragment(name) and name.len > 0 and !(name[0] >= '0' and name[0] <= '9')) {
        return name;
    }
    return std.fmt.allocPrint(arena, "\"{s}\"", .{try tsString(arena, name)});
}

/// A property ACCESS: dot for plain spellings, brackets otherwise.
fn tsAccess(arena: std.mem.Allocator, base: []const u8, name: []const u8) error{OutOfMemory}![]const u8 {
    if (isIdentifierFragment(name) and name.len > 0 and !(name[0] >= '0' and name[0] <= '9')) {
        return std.fmt.allocPrint(arena, "{s}.{s}", .{ base, name });
    }
    return std.fmt.allocPrint(arena, "{s}[\"{s}\"]", .{ base, try tsString(arena, name) });
}

/// Why a name cannot survive the WHOLE pipeline, or null when it can:
/// the shared identifier charset (letters, digits, underscore), a
/// non-digit start, not the discard spelling, and no keyword or
/// primitive-type name of either language.
const NameRole = enum {
    declaration,
    member,
};

fn pipelineIdentifierIssue(name: []const u8, role: NameRole) ?[]const u8 {
    if (name.len == 0) return "is empty";
    if (std.mem.eql(u8, name, "_")) return "is the discard spelling in the compiled module";
    if (name[0] >= '0' and name[0] <= '9') return "starts with a digit";
    for (name) |char| {
        const ok = (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z') or
            (char >= '0' and char <= '9') or char == '_';
        if (!ok) return "uses characters outside the compiled module's identifier set (letters, digits, underscore)";
    }
    if (std.zig.Token.keywords.has(name)) return "is a keyword in the compiled module";
    if (std.zig.isPrimitive(name)) return "is a primitive type name in the compiled module";
    if (role == .declaration) {
        for (ts_reserved_words) |word| {
            if (std.mem.eql(u8, name, word)) return "is a reserved word in TypeScript";
        }
    }
    return null;
}

fn isIdentifierFragment(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |char| {
        const ok = (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z') or
            (char >= '0' and char <= '9') or char == '_' or char == '$';
        if (!ok) return false;
    }
    return true;
}

fn isTsIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] >= '0' and name[0] <= '9') return false;
    for (name) |char| {
        const ok = (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z') or
            (char >= '0' and char <= '9') or char == '_' or char == '$';
        if (!ok) return false;
    }
    for (ts_reserved_words) |word| {
        if (std.mem.eql(u8, name, word)) return false;
    }
    return true;
}

// --------------------------------------------------------------- tests

const testing = std.testing;

/// Most facade tests perturb sidecar_mod's deliberately LEGACY minimal
/// fixture. Upgrade its two authored facts here so unrelated refusal tests
/// exercise the current facade boundary; the dedicated legacy test below
/// calls emitFacade directly on the untouched fixture.
fn withCurrentFacadeFacts(arena: std.mem.Allocator, json: []const u8) ![]const u8 {
    var current = json;
    const model = "{\"name\": \"Model\", \"fields\":";
    if (std.mem.indexOf(u8, current, model) != null) {
        current = try std.mem.replaceOwned(u8, arena, current, model, "{\"name\": \"Model\", \"origin\": \"core.ts\", \"fields\":");
    }
    const label_arm = "{\"name\": \"label_set\", \"payload\": {\"kind\": \"bytes\"}}";
    if (std.mem.indexOf(u8, current, label_arm) != null) {
        current = try std.mem.replaceOwned(u8, arena, current, label_arm, "{\"name\": \"label_set\", \"member\": \"value\", \"payload\": {\"kind\": \"bytes\"}}");
    }
    return current;
}

fn facadeFromJson(arena: std.mem.Allocator, json: []const u8) ![]const u8 {
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = sidecar_mod.read(arena, try withCurrentFacadeFacts(arena, json), &diags) catch |err| {
        for (diags.list.items) |item| {
            std.debug.print("  [{s}] {s}: {s}\n", .{ @tagName(item.severity), item.path, item.message });
        }
        return err;
    };
    return emitFacade(arena, parsed, &diags) catch |err| {
        for (diags.list.items) |item| {
            std.debug.print("  [{s}] {s}: {s}\n", .{ @tagName(item.severity), item.path, item.message });
        }
        return err;
    };
}

fn expectFacadeRefusal(arena: std.mem.Allocator, json: []const u8, fragment: []const u8) !void {
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, try withCurrentFacadeFacts(arena, json), &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, fragment) != null) return;
    }
    std.debug.print("no refusal containing \"{s}\"; got:\n", .{fragment});
    for (diags.list.items) |item| {
        std.debug.print("  [{s}] {s}: {s}\n", .{ @tagName(item.severity), item.path, item.message });
    }
    return error.TestExpectedRefusal;
}

test "legacy sidecars remain mirror-readable but refuse facade projection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, sidecar_mod.minimal_valid_json, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
    var taught_origin = false;
    var taught_member = false;
    for (diags.list.items) |item| {
        if (std.mem.indexOf(u8, item.message, "type-origin fact") != null) taught_origin = true;
        if (std.mem.indexOf(u8, item.message, "member-name fact") != null) taught_member = true;
    }
    try testing.expect(taught_origin);
    try testing.expect(taught_member);
}

test "facade emission is deterministic and carries the adapter surface" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = try facadeFromJson(arena, sidecar_mod.minimal_valid_json);
    const second = try facadeFromJson(arena, sidecar_mod.minimal_valid_json);
    try testing.expectEqualStrings(first, second);
    // The author's behavioral exports import under nscf aliases from the
    // entry module; the contract types re-export from it.
    try testing.expect(std.mem.indexOf(u8, first, "initialModel as nscfInitialModel,") != null);
    try testing.expect(std.mem.indexOf(u8, first, "update as nscfUpdate,") != null);
    try testing.expect(std.mem.indexOf(u8, first, "} from \"./core.ts\";") != null);
    try testing.expect(std.mem.indexOf(u8, first, "export type { Model, Msg } from \"./core.ts\";") != null);
    // The designated shape-flag entries restate the contract's flags.
    try testing.expect(std.mem.indexOf(u8, first, "export function init(): Model {") != null);
    try testing.expect(std.mem.indexOf(u8, first, "export function coreUpdate(model: Model, msg: Msg): [Model, Uint8Array] {") != null);
    try testing.expect(std.mem.indexOf(u8, first, "coreSubscriptions") == null);
    // The dispatch surface: committed state, tag table, arm routing.
    try testing.expect(std.mem.indexOf(u8, first, "let nscfCommitted: Model = nscfInitialModel();") != null);
    try testing.expect(std.mem.indexOf(u8, first, "const nscfTag_bump = 0;") != null);
    try testing.expect(std.mem.indexOf(u8, first, "if (tag === nscfTag_bump) return nscfCommit(coreUpdate(nscfCommitted, { kind: \"bump\" }));") != null);
    try testing.expect(std.mem.indexOf(u8, first, "if (tag === nscfTag_label_set) return nscfCommit(coreUpdate(nscfCommitted, { kind: \"label_set\", value: payload }));") != null);
    // Post-cycle: the snapshot rides the generated model writer with
    // the attested integer class.
    try testing.expect(std.mem.indexOf(u8, first, "nscfWI64(sink, value.count);") != null);
    try testing.expect(std.mem.indexOf(u8, first, "export function abi_subscriptions(): Uint8Array {") != null);
    try testing.expect(std.mem.indexOf(u8, first, "export function subscriptions(): Uint8Array {") == null);
    try testing.expect(std.mem.indexOf(u8, first, "export function model_snapshot(): Uint8Array {") != null);
    // The unbound list restates the author's markings.
    try testing.expect(std.mem.indexOf(u8, first, "export const viewUnbound = [\n  \"label_set\",\n];") != null);
    // Unwired channels stay out of the module.
    try testing.expect(std.mem.indexOf(u8, first, "abi_frame_msg") == null);
    try testing.expect(std.mem.indexOf(u8, first, "nscfPackMsg") == null);
    // Facade-only types, tag constants, and SDK effect imports all live in
    // the lowercase reserved namespace, so authored capitalized names cannot
    // collide with them.
    try testing.expect(std.mem.indexOf(u8, first, "type nscfSink = number[];") != null);
    try testing.expect(std.mem.indexOf(u8, first, "import type { Cmd as nscfCmd }") != null);
    try testing.expect(std.mem.indexOf(u8, first, "NscfSink") == null);
    try testing.expect(std.mem.indexOf(u8, first, "NSCF_TAG_") == null);
}

test "member facts spell the author's payload property names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"toggle\", \"member\": \"taskId\", \"payload\": {\"kind\": \"number\", \"class\": \"i64\"}}",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"Msg.toggle\", \"class\": \"i64\"}");
    const generated = try facadeFromJson(arena, source);
    // The integer-classed arm proves in place with the authored member
    // spelling at the write.
    try testing.expect(std.mem.indexOf(u8, generated, "if (value >= -9007199254740991 && value <= 9007199254740991) {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "const whole = Math.trunc(value);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "{ kind: \"toggle\", taskId: whole }") != null);
    // The baseline's own member fact remains authoritative too.
    try testing.expect(std.mem.indexOf(u8, generated, "{ kind: \"label_set\", value: payload }") != null);
}

test "origin facts group re-exports by declaring module" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"structs\": [",
        "\"structs\": [\n      {\"name\": \"Turn\", \"origin\": \"domain/api.ts\", \"fields\": [{\"name\": \"id\", \"type\": {\"kind\": \"f64\"}}]},",
    );
    const with_field = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"node\", \"name\": \"Turn\"}}",
    );
    const generated = try facadeFromJson(arena, with_field);
    try testing.expect(std.mem.indexOf(u8, generated, "export type { Turn } from \"./domain/api.ts\";") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export type { Model, Msg } from \"./core.ts\";") != null);
    // The generated snapshot writer reaches the record through its
    // named writer, importing the type from its own module.
    try testing.expect(std.mem.indexOf(u8, generated, "import type { Turn } from \"./domain/api.ts\";") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "function nscfWriteTurn(sink: nscfSink, value: Turn): void {") != null);
}

test "private reachable types get structural twins instead of invalid imports" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"structs\": [",
        "\"structs\": [\n      {\"name\": \"Hidden\", \"origin\": \"core.ts\", \"exported\": false, \"fields\": [{\"name\": \"value\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"mode\", \"type\": {\"kind\": \"enum\", \"name\": \"HiddenMode\"}}, {\"name\": \"state\", \"type\": {\"kind\": \"union\", \"name\": \"HiddenState\"}}]},",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"enums\": []", "\"enums\": [{\"name\": \"HiddenMode\", \"origin\": \"core.ts\", \"exported\": false, \"members\": [\"one\", \"two\"]}]");
    source = try std.mem.replaceOwned(u8, arena, source, "\"unions\": []", "\"unions\": [{\"name\": \"HiddenState\", \"origin\": \"core.ts\", \"exported\": false, \"arms\": [{\"name\": \"off\", \"payload\": {\"kind\": \"void\"}}, {\"name\": \"on\", \"member\": \"level\", \"payload\": {\"kind\": \"f64\"}}]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"hidden\", \"type\": {\"kind\": \"node\", \"name\": \"Hidden\"}}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "import type { Model, Msg } from \"./core.ts\";") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "import type { Model, Msg, Hidden }") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "export type { Model, Msg, Hidden }") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "type Hidden = {\n  readonly value: number;\n  readonly mode: HiddenMode;\n  readonly state: HiddenState;\n};") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "type HiddenMode = \"one\" | \"two\";") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "type HiddenState =\n  | { readonly kind: \"off\" }\n  | { readonly kind: \"on\"; readonly level: number }") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "function nscfWriteHidden(sink: nscfSink, value: Hidden): void {") != null);
}

test "generated generic table names refuse before emitting invalid imports" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"Model\", \"fields\": [",
        "{\"name\": \"Model\", \"origin\": \"core.ts\", \"fields\": [",
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "\"structs\": [",
        "\"structs\": [\n      {\"name\": \"Item\", \"origin\": \"core.ts\", \"fields\": [{\"name\": \"value\", \"type\": {\"kind\": \"f64\"}}]},\n      {\"name\": \"Box__Item\", \"fields\": [{\"name\": \"item\", \"type\": {\"kind\": \"node\", \"name\": \"Item\"}}]},",
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"box\", \"type\": {\"kind\": \"node\", \"name\": \"Box__Item\"}}",
    );
    // The monomorphized name is not an authored export, and the external
    // library compiler cannot project the generic contract field either.
    // Refuse here instead of generating `import type { Box__Item }` and
    // deferring failure to the TypeScript/compiler boundary.
    try expectFacadeRefusal(arena, source, "generic instantiations cannot cross the compiled-core contract surface yet");
}

test "helpers wrap in declaration order with classed-return proofs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"summary\", \"params\": [], \"returns\": {\"kind\": \"bytes\"}, \"arena\": false}, {\"name\": \"rowCount\", \"params\": [], \"returns\": {\"kind\": \"i64\"}, \"arena\": false}]",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"helpers.rowCount.return\", \"class\": \"i64\"}");
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "summary as nscfH_summary,") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export function summary(model: Model): Uint8Array {") != null);
    // The classed return binds, guards, and truncs at the boundary.
    try testing.expect(std.mem.indexOf(u8, generated, "export function rowCount(model: Model): number {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "const nscfValue = nscfH_rowCount(model);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (nscfValue >= -9007199254740991 && nscfValue <= 9007199254740991) return Math.trunc(nscfValue);") != null);
    // helper_call indexes the declaration order and encodes each result
    // in its declared return encoding.
    try testing.expect(std.mem.indexOf(u8, generated, "if (helper === 0) {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (helper === 1) {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfWBytes(sink, nscfValue);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfWI64(sink, nscfValue);") != null);
}

test "nullable integer helper returns prove their present branch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"maybeCount\", \"params\": [], \"returns\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"i64\"}}, \"arena\": false}]",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"helpers.maybeCount.return\", \"class\": \"i64\"}");
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "export function maybeCount(model: Model): number | null {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (nscfValue === null) return null;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (nscfValue >= -9007199254740991 && nscfValue <= 9007199254740991) return Math.trunc(nscfValue);") != null);
}

test "wired channels emit abi entries and the generic payload packer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"key_msg\": false", "\"key_msg\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"frame_msg\": false", "\"frame_msg\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"helper_call\"]", "\"helper_call\", \"frame_msg\", \"key_msg\"]");
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "frameMsg as nscfChanFrameMsg,") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "keyMsg as nscfChanKeyMsg,") != null);
    // The frame gate receives the committed model; the key gate the
    // event record with the wire's 0-or-1 modifier conversion.
    try testing.expect(std.mem.indexOf(u8, generated, "export function abi_frame_msg(width: number, height: number, timestampMs: number, intervalMs: number): Uint8Array {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfPackMsg(nscfChanFrameMsg(nscfCommitted, {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "shift: shift !== 0,") != null);
    // The envelope: [produced u8][tag u8][canonical payload].
    try testing.expect(std.mem.indexOf(u8, generated, "if (produced === null) return new Uint8Array(2);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "out[1] = nscfTagOf(produced.kind);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "function nscfMsgPayload(sink: nscfSink, value: Msg): void {") != null);
    // The unwired channels stay out.
    try testing.expect(std.mem.indexOf(u8, generated, "abi_pinch_msg") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "abi_command_msg") == null);
}

test "scalar primitive message payload aliases share dispatch and channel encoders" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"label_set\", \"payload\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"blob\", \"member\": \"blob\", \"payload\": {\"kind\": \"scalar\", \"type\": {\"kind\": \"bytes\"}}}, {\"name\": \"ratio\", \"member\": \"ratio\", \"payload\": {\"kind\": \"scalar\", \"type\": {\"kind\": \"f64\"}}}, {\"name\": \"count_set\", \"member\": \"count\", \"payload\": {\"kind\": \"scalar\", \"type\": {\"kind\": \"i64\"}}}",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"unbound\": [\"label_set\"]", "\"unbound\": []");
    source = try std.mem.replaceOwned(u8, arena, source, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"Msg.count_set\", \"class\": \"i64\"}");
    source = try std.mem.replaceOwned(u8, arena, source, "\"key_msg\": false", "\"key_msg\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"helper_call\"]", "\"helper_call\", \"key_msg\"]");

    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "if (tag === nscfTag_blob) return nscfCommit(coreUpdate(nscfCommitted, { kind: \"blob\", blob: payload }));") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (tag === nscfTag_ratio) return nscfCommit(coreUpdate(nscfCommitted, { kind: \"ratio\", ratio: value }));") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (tag === nscfTag_count_set) {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfWBytes(sink, value.blob);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfWF64(sink, value.ratio);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfWI64(sink, value.count);") != null);
}

test "u64-attested slots ride the unsigned writer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}",
        "{\"slot\": \"Model.count\", \"class\": \"u64\"}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfWU64(sink, value.count);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "function nscfWU64(sink: nscfSink, value: number): void {") != null);
    const signed = try facadeFromJson(arena, sidecar_mod.minimal_valid_json);
    try testing.expect(std.mem.indexOf(u8, signed, "nscfWU64") == null);
}

test "u64 attestations set nonnegative proofs on every ingress shape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Payload\", \"origin\": \"core.ts\", \"fields\": [{\"name\": \"id\", \"type\": {\"kind\": \"i64\"}}]},");
    source = try std.mem.replaceOwned(u8, arena, source, "\"model_helpers\": []", "\"model_helpers\": [{\"name\": \"nextId\", \"params\": [], \"returns\": {\"kind\": \"i64\"}, \"arena\": false}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"id_set\", \"member\": \"value\", \"payload\": {\"kind\": \"number\", \"class\": \"i64\"}}, {\"name\": \"loaded\", \"member\": \"payload\", \"payload\": {\"kind\": \"record\", \"name\": \"Payload\"}}",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "{\"name\": \"label_set\", \"payload\": {\"kind\": \"bytes\"}}", "{\"name\": \"sized\", \"payload\": {\"kind\": \"number_bytes\", \"number_field\": \"size\", \"number_class\": \"i64\", \"bytes_field\": \"label\"}}");
    source = try std.mem.replaceOwned(u8, arena, source, "\"unbound\": [\"label_set\"]", "\"unbound\": [\"id_set\", \"loaded\", \"sized\"]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}",
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"Msg.id_set\", \"class\": \"u64\"}, {\"slot\": \"Msg.sized.size\", \"class\": \"u64\"}, {\"slot\": \"Payload.id\", \"class\": \"u64\"}, {\"slot\": \"helpers.nextId.return\", \"class\": \"u64\"}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "if (tag === nscfTag_id_set) {\n    if (value >= 0 && value <= 9007199254740991) {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (tag === nscfTag_sized) {\n    // The number field is i64-classed") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (value >= 0 && value <= 9007199254740991) {\n      return nscfCommit(coreUpdate(nscfCommitted, { kind: \"sized\"") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (nscfValue >= 0 && nscfValue <= 9007199254740991) return Math.trunc(nscfValue);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (nscfV0 >= 0 && nscfV0 <= 9007199254740991) {") != null);
}

test "an authored pattern-named record keeps its member and re-export" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Msg_loaded\", \"origin\": \"core.ts\", \"fields\": [{\"name\": \"status\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"ok\", \"type\": {\"kind\": \"bool\"}}]},");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"loaded\", \"member\": \"payload\", \"payload\": {\"kind\": \"record\", \"name\": \"Msg_loaded\"}}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "export type { Model, Msg, Msg_loaded } from \"./core.ts\";") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "{ kind: \"loaded\", payload: { status:") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "{ kind: \"loaded\", status:") == null);
}

test "a helper taking a fixed export's name refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"dispatch_void\", \"params\": [], \"returns\": {\"kind\": \"bytes\"}, \"arena\": false}]",
    );
    try expectFacadeRefusal(arena, source, "collides with a declaration the generated facade itself must export");
}

test "capitalized authored names no longer collide with facade internals" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"structs\": [",
        "\"structs\": [\n      {\"name\": \"NscfSink\", \"origin\": \"core.ts\", \"fields\": [{\"name\": \"id\", \"type\": {\"kind\": \"f64\"}}]},\n      {\"name\": \"Cmd\", \"origin\": \"core.ts\", \"fields\": [{\"name\": \"id\", \"type\": {\"kind\": \"f64\"}}]},",
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"sinkValue\", \"type\": {\"kind\": \"node\", \"name\": \"NscfSink\"}}, {\"name\": \"commandValue\", \"type\": {\"kind\": \"node\", \"name\": \"Cmd\"}}",
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"NSCF_TAG_bump\", \"params\": [], \"returns\": {\"kind\": \"bytes\"}, \"arena\": false}]",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "import type { Model, Msg, NscfSink, Cmd } from \"./core.ts\";") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "import type { Cmd as nscfCmd } from \"./sdk/core.ts\";") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export function NSCF_TAG_bump(model: Model): Uint8Array {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "const nscfTag_bump = 0;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "type nscfSink = number[];") != null);
}

test "a helper may not shadow an ambient facade value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"Math\", \"params\": [], \"returns\": {\"kind\": \"bytes\"}, \"arena\": false}]",
    );
    try expectFacadeRefusal(arena, source, "shadows an ambient value");
}

test "a payload member spelled kind refuses against the discriminator" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"label_set\", \"payload\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label_set\", \"member\": \"kind\", \"payload\": {\"kind\": \"bytes\"}}",
    );
    try expectFacadeRefusal(arena, source, "the discriminator's own spelling");
}

test "a type in the facade's reserved nsc name space refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"enums\": []", "\"enums\": [{\"name\": \"nscfHelper\", \"members\": [\"a\", \"b\"]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"enum\", \"name\": \"nscfHelper\"}}",
    );
    try expectFacadeRefusal(arena, source, "reserved nsc name space");
}

test "an unbound message arm shadowed by a homonymous model field refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"count\", \"payload\": {\"kind\": \"void\"}}",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"unbound\": [\"label_set\"]", "\"unbound\": [\"count\"]");
    try expectFacadeRefusal(arena, source, "resolves Model fields and helpers before message arms");
}

test "an unbound model field may share a name with a bound message arm" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"count\", \"payload\": {\"kind\": \"void\"}}",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"model_unbound\": []", "\"model_unbound\": [\"count\"]");
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "export const viewUnbound = [\n  \"label_set\",\n  \"count\",\n];") != null);
}

test "an unbound message arm shadowed by a homonymous helper refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"bump\", \"params\": [], \"returns\": {\"kind\": \"bool\"}, \"arena\": false}]",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"unbound\": [\"label_set\"]", "\"unbound\": [\"bump\"]");
    try expectFacadeRefusal(arena, source, "resolves Model fields and helpers before message arms");
}

test "nested optionals refuse in the projection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"f64\"}}}}",
    );
    try expectFacadeRefusal(arena, source, "one absence level");
}

test "a record referenced by node and value at once refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Item\", \"fields\": [{\"name\": \"x\", \"type\": {\"kind\": \"f64\"}}]},");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"live\", \"type\": {\"kind\": \"node\", \"name\": \"Item\"}}, {\"name\": \"cached\", \"type\": {\"kind\": \"value\", \"name\": \"Item\"}}",
    );
    try expectFacadeRefusal(arena, source, "storage once per declaration");
}

test "record dispatch decodes nonterminal optionals and nullable composites" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"structs\": [",
        "\"structs\": [\n      {\"name\": \"Payload\", \"origin\": \"core.ts\", \"fields\": [{\"name\": \"maybe\", \"type\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"f64\"}}}, {\"name\": \"tail\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"blob\", \"type\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"bytes\"}}}]},",
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"loaded\", \"member\": \"payload\", \"payload\": {\"kind\": \"record\", \"name\": \"Payload\"}}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "let nscfAt = 0;") != null);
    const optional_at = std.mem.indexOf(u8, generated, "let nscfV1: number | null = null;").?;
    const tail_at = std.mem.indexOfPos(u8, generated, optional_at, "nscfReadF64(fields, nscfAt)").?;
    try testing.expect(tail_at > optional_at);
    try testing.expect(std.mem.indexOf(u8, generated, "Uint8Array | null = null;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfReadBytesBody(fields, nscfAt,") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfAssertConsumed(fields, nscfAt);") != null);
}

test "record dispatch recursively decodes sequences and nested unions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"structs\": [",
        "\"structs\": [\n      {\"name\": \"Payload\", \"origin\": \"core.ts\", \"fields\": [{\"name\": \"values\", \"type\": {\"kind\": \"slice\", \"elem\": {\"kind\": \"f64\"}}}, {\"name\": \"choice\", \"type\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"union\", \"name\": \"Choice\"}}}]},",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"unions\": []", "\"unions\": [{\"name\": \"Choice\", \"origin\": \"core.ts\", \"arms\": [{\"name\": \"none\", \"payload\": {\"kind\": \"void\"}}, {\"name\": \"text\", \"member\": \"value\", \"payload\": {\"kind\": \"bytes\"}}]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"loaded\", \"member\": \"payload\", \"payload\": {\"kind\": \"record\", \"name\": \"Payload\"}}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, ": number[] = [];") != null);
    try testing.expect(std.mem.indexOf(u8, generated, ".push(") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfReadU8(fields, nscfAt)") != null);
    try testing.expect(std.mem.indexOf(u8, generated, ": Choice | null = null;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "{ kind: \"text\", value:") != null);
}

test "ordinary set_selection arms keep exact integer decoding" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"CaretRange\", \"origin\": \"core.ts\", \"fields\": [{\"name\": \"anchor\", \"type\": {\"kind\": \"i64\"}}, {\"name\": \"focus\", \"type\": {\"kind\": \"i64\"}}]},");
    source = try std.mem.replaceOwned(u8, arena, source, "\"unions\": []", "\"unions\": [{\"name\": \"Edit\", \"origin\": \"core.ts\", \"arms\": [{\"name\": \"clear\", \"payload\": {\"kind\": \"void\"}}, {\"name\": \"set_selection\", \"member\": \"selection\", \"payload\": {\"kind\": \"value\", \"name\": \"CaretRange\"}}]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"edited\", \"member\": \"edit\", \"payload\": {\"kind\": \"union\", \"name\": \"Edit\"}}",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"CaretRange.anchor\", \"class\": \"i64\"}, {\"slot\": \"CaretRange.focus\", \"class\": \"i64\"}");
    const generated = try facadeFromJson(arena, source);
    // The union decodes standalone on the record and text-input entries.
    try testing.expect(std.mem.indexOf(u8, generated, "function nscfDecodeEdit(bytes: Uint8Array): Edit {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "{ kind: \"edited\", edit: nscfDecodeEdit(fields) }") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "{ kind: \"edited\", edit: nscfDecodeEdit(event) }") != null);
    // This is not the complete text-input protocol, so a homonymous arm
    // retains the ordinary exact reader and rejects out-of-window integers.
    try testing.expect(std.mem.indexOf(u8, generated, "let nscfAt = 1;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfReadI64(bytes, nscfAt)") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfReadI64Saturating") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfReadU64Saturating") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "anchor: Math.trunc(") != null);
}

test "text-input selection saturates signed and unsigned select-all sentinels" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const records =
        \\      {"name": "Move", "origin": "core.ts", "fields": [
        \\        {"name": "direction", "type": {"kind": "enum", "name": "Dir"}},
        \\        {"name": "extend", "type": {"kind": "bool"}}
        \\      ]},
        \\      {"name": "Sel", "origin": "core.ts", "fields": [
        \\        {"name": "anchor", "type": {"kind": "i64"}},
        \\        {"name": "focus", "type": {"kind": "i64"}}
        \\      ]},
        \\      {"name": "Comp", "origin": "core.ts", "fields": [
        \\        {"name": "text", "type": {"kind": "bytes"}},
        \\        {"name": "cursor", "type": {"kind": "optional", "inner": {"kind": "i64"}}}
        \\      ]},
    ;
    const union_entry =
        \\"unions": [{"name": "Edit", "origin": "core.ts", "arms": [
        \\      {"name": "insert_text", "member": "text", "payload": {"kind": "bytes"}},
        \\      {"name": "delete_backward", "payload": {"kind": "void"}},
        \\      {"name": "delete_forward", "payload": {"kind": "void"}},
        \\      {"name": "delete_word_backward", "payload": {"kind": "void"}},
        \\      {"name": "delete_word_forward", "payload": {"kind": "void"}},
        \\      {"name": "clear", "payload": {"kind": "void"}},
        \\      {"name": "move_caret", "member": "move", "payload": {"kind": "value", "name": "Move"}},
        \\      {"name": "set_selection", "member": "selection", "payload": {"kind": "value", "name": "Sel"}},
        \\      {"name": "set_composition", "member": "composition", "payload": {"kind": "value", "name": "Comp"}},
        \\      {"name": "commit_composition", "payload": {"kind": "void"}},
        \\      {"name": "cancel_composition", "payload": {"kind": "void"}}
        \\    ]}]
    ;
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [\n", try std.fmt.allocPrint(arena, "\"structs\": [\n{s}\n", .{records}));
    source = try std.mem.replaceOwned(u8, arena, source, "\"enums\": []", "\"enums\": [{\"name\": \"Dir\", \"origin\": \"core.ts\", \"members\": [\"previous\", \"next\", \"previous_word\", \"next_word\", \"start\", \"end\"]}]");
    source = try std.mem.replaceOwned(u8, arena, source, "\"unions\": []", union_entry);
    source = try std.mem.replaceOwned(u8, arena, source, "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}", "{\"name\": \"edited\", \"member\": \"edit\", \"payload\": {\"kind\": \"union\", \"name\": \"Edit\"}}");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}",
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"Sel.anchor\", \"class\": \"u64\"}, {\"slot\": \"Sel.focus\", \"class\": \"i64\"}, {\"slot\": \"Comp.cursor\", \"class\": \"u64\"}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfReadU64Saturating(bytes, nscfAt)") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfReadI64Saturating(bytes, nscfAt)") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "function nscfReadU64Saturating(bytes: Uint8Array, at: number): number {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (hi > 2097151) return 9007199254740991;") != null);
}

test "scroll-shaped record arms answer the dedicated scroll entry" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"ScrollState\", \"origin\": \"core.ts\", \"fields\": [{\"name\": \"offsetX\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"offsetY\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"velocityX\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"velocityY\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"viewportExtentX\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"viewportExtentY\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"contentExtentX\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"contentExtentY\", \"type\": {\"kind\": \"f64\"}}]},");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"scrolled\", \"member\": \"scroll\", \"payload\": {\"kind\": \"record\", \"name\": \"ScrollState\"}}",
    );
    const generated = try facadeFromJson(arena, source);
    // Both routes: the generic record decode and the flat-scalar entry.
    try testing.expect(std.mem.indexOf(u8, generated, "if (tag === nscfTag_scrolled) return nscfCommit(coreUpdate(nscfCommitted, { kind: \"scrolled\", scroll: { offsetX: offsetX, offsetY: offsetY, velocityX: velocityX, velocityY: velocityY, viewportExtentX: viewportExtentX, viewportExtentY: viewportExtentY, contentExtentX: contentExtentX, contentExtentY: contentExtentY } }));") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfUnknownTag(\"scroll-state\", tag);") != null);

    var integer_source = try std.mem.replaceOwned(u8, arena, source, "{\"name\": \"offsetX\", \"type\": {\"kind\": \"f64\"}}", "{\"name\": \"offsetX\", \"type\": {\"kind\": \"i64\"}}");
    integer_source = try std.mem.replaceOwned(u8, arena, integer_source, "{\"name\": \"offsetY\", \"type\": {\"kind\": \"f64\"}}", "{\"name\": \"offsetY\", \"type\": {\"kind\": \"i64\"}}");
    integer_source = try std.mem.replaceOwned(u8, arena, integer_source, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"ScrollState.offsetX\", \"class\": \"u64\"}, {\"slot\": \"ScrollState.offsetY\", \"class\": \"i64\"}");
    const integer_generated = try facadeFromJson(arena, integer_source);
    try testing.expect(std.mem.indexOf(u8, integer_generated, "offsetX >= 0 && offsetX <= 9007199254740991 && offsetY >= -9007199254740991 && offsetY <= 9007199254740991") != null);
    try testing.expect(std.mem.indexOf(u8, integer_generated, "offsetX: Math.trunc(offsetX), offsetY: Math.trunc(offsetY)") != null);

    // The canvas snake_case vocabulary routes through the same ABI entry,
    // with each authored field fed by its corresponding camelCase ABI param.
    var snake_source = source;
    for (scroll_state_fields_ts, scroll_state_fields_canvas) |ts_name, canvas_name| {
        snake_source = try std.mem.replaceOwned(u8, arena, snake_source, ts_name, canvas_name);
    }
    const snake_generated = try facadeFromJson(arena, snake_source);
    try testing.expect(std.mem.indexOf(u8, snake_generated, "offset_x: offsetX, offset_y: offsetY, velocity_x: velocityX, velocity_y: velocityY") != null);

    // A current sidecar's originless pattern-named arm record is the
    // compiler's inline shape: scroll construction flattens beside kind
    // rather than inventing a `value` payload member.
    var inline_source = try std.mem.replaceOwned(u8, arena, source, "{\"name\": \"Model\", \"fields\": [", "{\"name\": \"Model\", \"origin\": \"core.ts\", \"fields\": [");
    inline_source = try std.mem.replaceOwned(u8, arena, inline_source, "ScrollState", "Msg_scrolled");
    inline_source = try std.mem.replaceOwned(u8, arena, inline_source, "{\"name\": \"Msg_scrolled\", \"origin\": \"core.ts\"", "{\"name\": \"Msg_scrolled\"");
    inline_source = try std.mem.replaceOwned(u8, arena, inline_source, "\"member\": \"scroll\", ", "");
    const inline_generated = try facadeFromJson(arena, inline_source);
    try testing.expect(std.mem.indexOf(u8, inline_generated, "{ kind: \"scrolled\", offsetX: offsetX, offsetY: offsetY") != null);
    try testing.expect(std.mem.indexOf(u8, inline_generated, "{ kind: \"scrolled\", value:") == null);
}
