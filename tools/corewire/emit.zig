//! core_shim.zig emission: turn a validated contract sidecar into the
//! Zig mirror module the app wiring imports in place of transpiler
//! output.
//!
//! The mirror is the load-bearing move of the whole design: every seam
//! that reflects over an app core at comptime — the markup engines, the
//! adapter's channel stamping, the bridge's tag table, the
//! model-contract emit — keeps its `@typeInfo` worldview because the
//! generated module declares REAL Zig types with the sidecar's field
//! names, declaration order, and type spellings. Fidelity rules, each
//! matching the transpiler's emission so the reflecting seams cannot
//! tell the two lanes apart:
//!
//! - bytes spell `[]const u8`; numbers spell `f64` or `i64` per the
//!   sidecar's per-slot class; enums are `enum(u8)` with explicit
//!   declaration-order values; node references spell `*const T`.
//! - The message union is `union(enum)` in sidecar arm order — the arm
//!   index IS the wire tag.
//! - Synthesized type-table names (the schema's `<Container>_<member>`
//!   pattern for tabled anonymous records) are emitted INLINE at their
//!   one reference site, exactly where the transpiler emits an inline
//!   struct — a named top-level declaration would change nothing for
//!   layout but everything for `@typeName`-carrying artifacts.
//! - Exported helpers become Model methods (`fn (self: *const Model)`,
//!   plus the build-arena form) forwarding to the core's helper_call
//!   entry; `view_unbound` tuples mirror the unbound lists.
//!
//! Executable surface: dispatch stubs route each arm through the ABI
//! entry its payload descriptor selects, the snapshot decoder
//! materializes the committed model into a mirror value after every
//! dispatch, and the boot path runs the identity fence before anything
//! else. All extern references live in core_abi.zig (staged beside the
//! output), so ABI ratification cannot touch this emitter.

const std = @import("std");
const sidecar_mod = @import("sidecar.zig");

const Sidecar = sidecar_mod.Sidecar;
const TypeRef = sidecar_mod.TypeRef;
const Payload = sidecar_mod.Payload;

/// The eleven text-input event tags the markup engines recognize
/// structurally; a union payload carrying exactly these dispatches
/// through the ABI's text_input entry.
const text_input_event_tags = [_][]const u8{
    "insert_text",         "delete_backward",    "delete_forward",     "delete_word_backward",
    "delete_word_forward", "clear",              "move_caret",         "set_selection",
    "set_composition",     "commit_composition", "cancel_composition",
};

/// The scroll-state field vocabulary, TS spelling (the emitted-core
/// mirror keeps the author's names) and the canvas spelling.
const scroll_state_fields_ts = [_][]const u8{ "offset", "velocity", "viewportExtent", "contentExtent" };
const scroll_state_fields_canvas = [_][]const u8{ "offset", "velocity", "viewport_extent", "content_extent" };

pub const Error = error{ Refused, OutOfMemory };

/// Emit the complete core_shim.zig source. Deterministic: a pure
/// function of the sidecar value (V13's generator-side counterpart,
/// pinned by a test).
pub fn emit(arena: std.mem.Allocator, sidecar: Sidecar, diags: *sidecar_mod.Diagnostics) Error![]const u8 {
    var emitter = Emitter{
        .arena = arena,
        .sidecar = sidecar,
        .diags = diags,
        .out = .empty,
    };
    try emitter.run();
    if (diags.hasErrors()) return error.Refused;
    return emitter.out.items;
}

const Emitter = struct {
    arena: std.mem.Allocator,
    sidecar: Sidecar,
    diags: *sidecar_mod.Diagnostics,
    out: std.ArrayListUnmanaged(u8),
    /// Table entries emitted inline at their single reference site
    /// (see inlinedNames).
    inlined: []const []const u8 = &.{},

    fn print(self: *Emitter, comptime fmt: []const u8, args: anytype) Error!void {
        const text = try std.fmt.allocPrint(self.arena, fmt, args);
        try self.out.appendSlice(self.arena, text);
    }

    fn raw(self: *Emitter, text: []const u8) Error!void {
        try self.out.appendSlice(self.arena, text);
    }

    fn run(self: *Emitter) Error!void {
        try self.validateEmissionNames();
        self.validateChannelShapes();
        if (self.diags.hasErrors()) return;
        self.inlined = try self.inlinedNames();
        try self.header();
        try self.mirrorTypes();
        try self.modelStruct();
        try self.msgUnion();
        try self.wiringAliases();
        try self.tagTable();
        try self.entryPoints();
        try self.channels();
        try self.helperPlumbing();
        try self.snapshotPlumbing();
    }

    // -------------------------------------------- emission-name space
    //
    // The generated module declares more than the mirror types: the rt
    // block, the tag table, the entry points, and (per wired channel)
    // the fixed event-record vocabulary. A sidecar whose own names
    // collide with those declarations would generate a module that
    // cannot compile — refuse at tool time with the exact name instead.

    fn validateEmissionNames(self: *Emitter) Error!void {
        var reserved: std.ArrayListUnmanaged([]const u8) = .empty;
        try reserved.appendSlice(self.arena, &.{
            "std",           "shim_rt",         "core_abi",         "abi",
            "rt",            "msg_tags",        "boot",             "initialModel",
            "update",        "commitModelRoot", "sidecar_build_id", "sidecar_abi_version",
            "deterministic", "async_free",      "snapshotModel",    "referenceAttestedExports",
        });
        // Parameter and local names the generated bodies bind: a
        // module-level type under any of them would be shadowed, which
        // the compiler refuses.
        try reserved.appendSlice(self.arena, &.{
            "T",       "n",          "model",     "msg",      "payload",  "encoded",
            "cmd_ptr", "cmd_len",    "subs_ptr",  "subs_len", "snap_ptr", "snap_len",
            "out",     "out_ptr",    "out_len",   "tag",      "tag_name", "name",
            "frame",   "key",        "pinch",     "value",    "self",     "index",
            "args",    "args_tuple", "allocator", "fields",   "next",     "helper_args",
        });
        for (self.sidecar.model_helpers) |helper| {
            for (helper.params, 0..) |_, param_index| {
                try reserved.append(self.arena, try std.fmt.allocPrint(self.arena, "p{d}", .{param_index}));
            }
        }
        // The host layer wires channels by PROBING these declaration
        // names (`@hasDecl` — export presence IS the wiring decision),
        // so they are off limits even when the channel is absent: a
        // mere type under one of these names would falsely activate
        // the channel and then fail as a non-function.
        try reserved.appendSlice(self.arena, &.{
            "subscriptions", "commandMsg",    "frameMsg",  "keyMsg",
            "pinchMsg",      "appearanceMsg", "chromeMsg", "envMsgs",
        });
        // The wiring aliases (wiringAliases) claim the host layer's
        // fixed spellings whenever the sidecar's own names differ.
        if (!std.mem.eql(u8, self.sidecar.model, "Model")) try reserved.append(self.arena, "Model");
        if (!std.mem.eql(u8, self.sidecar.msg.name, "Msg")) try reserved.append(self.arena, "Msg");
        // Optional glue reserves its name only when it is emitted.
        if (self.sidecar.model_helpers.len > 0) try reserved.append(self.arena, "callHelper");
        const chan = self.sidecar.channels;
        if (chan.command_msg or chan.frame_msg or chan.key_msg or chan.pinch_msg) {
            try reserved.append(self.arena, "msgFromWire");
        }
        if (self.sidecar.init_returns_cmd) try reserved.append(self.arena, "InitResult");
        if (self.sidecar.update_returns_cmd) try reserved.append(self.arena, "UpdateResult");
        if (self.sidecar.channels.frame_msg) try reserved.append(self.arena, "FrameEvent");
        if (self.sidecar.channels.key_msg) try reserved.append(self.arena, "KeyEvent");
        if (self.sidecar.channels.pinch_msg) try reserved.appendSlice(self.arena, &.{ "PinchEvent", "PinchPhase" });

        const table_names = try self.allTableNames();
        for (table_names) |name| {
            if (nameListed(reserved.items, name)) {
                self.diags.flag("types", "type name \"{s}\" collides with a declaration the generated shim itself must make; rename the type in the core source", .{name});
            }
        }
        if (nameListed(reserved.items, self.sidecar.msg.name) or nameListed(table_names, self.sidecar.msg.name)) {
            self.diags.flag("msg.name", "message union name \"{s}\" collides with another declaration of the generated shim; rename the union in the core source", .{self.sidecar.msg.name});
        }
        // Helper methods share the model struct's member namespace with
        // its fields — and "view_unbound" is the opt-out tuple's
        // spelling, which every reflecting consumer reads as data, so a
        // helper must never take it. A helper may not take a reserved
        // name either: methods shadow file-scope declarations inside
        // the struct, so a helper named after generated glue (callHelper
        // above all) would capture the glue's own call sites.
        for (self.sidecar.model_helpers) |helper| {
            if (nameListed(reserved.items, helper.name)) {
                self.diags.flag("model_helpers", "helper \"{s}\" collides with a declaration the generated shim itself must make (methods shadow file-scope names inside the model struct); rename the helper in the core source", .{helper.name});
            }
            // The same shadowing applies to the mirror's own type
            // declarations: a field spelled `row: Row` inside the model
            // struct resolves Row to a method of that name first.
            if (nameListed(table_names, helper.name) or std.mem.eql(u8, helper.name, self.sidecar.msg.name)) {
                self.diags.flag("model_helpers", "helper \"{s}\" shadows the type of the same name inside the model struct, where field types resolve; rename one in the core source", .{helper.name});
            }
        }
        if (sidecar_mod.findStruct(self.sidecar.types, self.sidecar.model)) |model| {
            for (self.sidecar.model_helpers) |helper| {
                if (std.mem.eql(u8, helper.name, "view_unbound")) {
                    self.diags.flag("model_helpers", "helper \"view_unbound\" takes the unbound-list declaration's spelling — the contract reflection reads that name as the opt-out tuple; rename the helper in the core source", .{});
                }
                for (model.fields) |field| {
                    if (std.mem.eql(u8, helper.name, field.name)) {
                        self.diags.flag("model_helpers", "helper \"{s}\" collides with the model field of the same name — the mirror declares helpers as model methods, one member namespace; rename one in the core source", .{helper.name});
                    }
                }
            }
            if (self.sidecar.model_unbound.len > 0) {
                for (model.fields) |field| {
                    if (std.mem.eql(u8, field.name, "view_unbound")) {
                        self.diags.flag("model_unbound", "the model field \"view_unbound\" collides with the unbound-list declaration the mirror must make; rename the field in the core source", .{});
                    }
                }
            }
        }
        if (self.sidecar.msg.unbound.len > 0) {
            for (self.sidecar.msg.arms) |arm| {
                if (std.mem.eql(u8, arm.name, "view_unbound")) {
                    self.diags.flag("msg.unbound", "the message arm \"view_unbound\" collides with the unbound-list declaration the mirror must make; rename the arm in the core source", .{});
                }
            }
        }
    }

    // ------------------------------------------- channel arm shapes
    //
    // The appearance and chrome channels have no function entry point:
    // the host constructs the named arm's record itself, so the arm
    // must carry the exact structural vocabulary the adapter builds by
    // field name. The adapter re-proves this at comptime over the
    // mirror; checking here moves the teaching to tool time instead of
    // a compile error inside generated wiring.

    fn validateChannelShapes(self: *Emitter) void {
        if (self.sidecar.channels.appearance_msg) |arm_name| {
            const teaching = "the appearance arm must carry exactly {{ colorScheme: a light/dark enum, reduceMotion: bool, highContrast: bool }} — the host builds this record by field name";
            const record = self.channelArmRecord(arm_name) orelse {
                self.diags.flag("channels.appearance_msg", teaching, .{});
                return;
            };
            if (!self.isAppearanceRecord(record)) {
                self.diags.flag("channels.appearance_msg", teaching, .{});
            }
        }
        if (self.sidecar.channels.chrome_msg) |arm_name| {
            const teaching = "the chrome arm must carry exactly {{ insets: top/right/bottom/left numbers, buttons: x/y/width/height numbers, tabsProjected: bool }} — the host builds this record by field name";
            const record = self.channelArmRecord(arm_name) orelse {
                self.diags.flag("channels.chrome_msg", teaching, .{});
                return;
            };
            if (!self.isChromeRecord(record)) {
                self.diags.flag("channels.chrome_msg", teaching, .{});
            }
        }
    }

    fn channelArmRecord(self: *Emitter, arm_name: []const u8) ?*const sidecar_mod.Struct {
        const arm = sidecar_mod.findArm(self.sidecar.msg, arm_name) orelse return null;
        return switch (arm.payload) {
            .record => |name| sidecar_mod.findStruct(self.sidecar.types, name),
            else => null,
        };
    }

    fn isAppearanceRecord(self: *Emitter, record: *const sidecar_mod.Struct) bool {
        if (record.fields.len != 3) return false;
        var scheme_ok = false;
        var reduce_ok = false;
        var contrast_ok = false;
        for (record.fields) |field| {
            if (std.mem.eql(u8, field.name, "colorScheme")) {
                const members = switch (field.type) {
                    .enum_ref => |name| (sidecar_mod.findEnum(self.sidecar.types, name) orelse return false).members,
                    else => return false,
                };
                if (members.len != 2) return false;
                var light = false;
                var dark = false;
                for (members) |member| {
                    if (std.mem.eql(u8, member, "light")) light = true;
                    if (std.mem.eql(u8, member, "dark")) dark = true;
                }
                scheme_ok = light and dark;
            } else if (std.mem.eql(u8, field.name, "reduceMotion")) {
                reduce_ok = field.type == .bool;
            } else if (std.mem.eql(u8, field.name, "highContrast")) {
                contrast_ok = field.type == .bool;
            }
        }
        return scheme_ok and reduce_ok and contrast_ok;
    }

    fn isChromeRecord(self: *Emitter, record: *const sidecar_mod.Struct) bool {
        if (record.fields.len != 3) return false;
        var insets_ok = false;
        var buttons_ok = false;
        var tabs_ok = false;
        for (record.fields) |field| {
            if (std.mem.eql(u8, field.name, "insets")) {
                insets_ok = self.isNumericRecord(field.type, &.{ "top", "right", "bottom", "left" });
            } else if (std.mem.eql(u8, field.name, "buttons")) {
                buttons_ok = self.isNumericRecord(field.type, &.{ "x", "y", "width", "height" });
            } else if (std.mem.eql(u8, field.name, "tabsProjected")) {
                tabs_ok = field.type == .bool;
            }
        }
        return insets_ok and buttons_ok and tabs_ok;
    }

    fn isNumericRecord(self: *Emitter, ref: TypeRef, names: []const []const u8) bool {
        const record = self.recordOf(ref) orelse return false;
        if (record.fields.len != names.len) return false;
        outer: for (names) |name| {
            for (record.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    if (!isNumericRef(field.type)) return false;
                    continue :outer;
                }
            }
            return false;
        }
        return true;
    }

    fn allTableNames(self: *Emitter) Error![]const []const u8 {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.sidecar.types.structs) |entry| try names.append(self.arena, entry.name);
        for (self.sidecar.types.enums) |entry| try names.append(self.arena, entry.name);
        for (self.sidecar.types.unions) |entry| try names.append(self.arena, entry.name);
        return names.items;
    }

    // ------------------------------------------------------- preamble

    fn header(self: *Emitter) Error!void {
        try self.print(
            \\//! Generated by corewire from this app's core.contract.json — the
            \\//! host-side mirror of a compiled TypeScript core. Every type below
            \\//! reproduces the compiled core's contract exactly (field names,
            \\//! declaration order, number classes), so the markup engines, the
            \\//! adapter, the bridge, and the model-contract step reflect over it
            \\//! the way they reflect over transpiler output. Do not edit;
            \\//! regenerate from the sidecar.
            \\//!
            \\//! Compiled core identity: entry {s}, compiler {s},
            \\//! build_id {x:0>16} (checked against the object's exported getter
            \\//! before the first dispatch).
            \\
            \\const std = @import("std");
            \\const shim_rt = @import("shim_rt.zig");
            \\const core_abi = @import("core_abi.zig");
            \\const abi = core_abi.Bindings("{f}");
            \\
            \\/// The sidecar's identity facts, restated for the boot-time pairing
            \\/// fence (the out-of-graph backstop: a cached or hand-copied core
            \\/// must never dispatch against another build's tag order).
            \\pub const sidecar_build_id: u64 = 0x{x:0>16};
            \\pub const sidecar_abi_version: u32 = {d};
            \\
            \\/// The compiler's module-graph attestations, restated so host
            \\/// policy can gate on them: record/replay arms only against a
            \\/// deterministic core, and loop-free-core policies read
            \\/// async_free. Computed facts of the compiled graph — the sidecar
            \\/// records verdicts, never hopes.
            \\pub const deterministic: bool = {};
            \\pub const async_free: bool = {};
            \\
            \\/// The kernel surface the host layer drives, forwarded to the shim
            \\/// arena and the core's own frame reset (one cycle boundary for
            \\/// both sides).
            \\pub const rt = struct {{
            \\    pub const Cmd = []const u8;
            \\    pub const Sub = []const u8;
            \\    pub const cmd_none: Cmd = &.{{}};
            \\    pub const sub_none: Sub = &.{{}};
            \\    pub fn frameAlloc(comptime T: type, n: usize) []T {{
            \\        return shim_rt.frameAlloc(T, n);
            \\    }}
            \\    pub fn frameCreate(comptime T: type, value: T) *T {{
            \\        return shim_rt.frameCreate(T, value);
            \\    }}
            \\    pub fn frameReset() void {{
            \\        shim_rt.frameReset();
            \\        abi.frame_reset();
            \\    }}
            \\    pub fn resetAll() void {{
            \\        shim_rt.resetAll();
            \\    }}
            \\}};
            \\
        , .{
            commentText(self.arena, self.sidecar.entry),
            commentText(self.arena, self.sidecar.compiler_version),
            self.sidecar.build_id,
            std.zig.fmtString(self.sidecar.abi.prefix),
            self.sidecar.build_id,
            self.sidecar.abi_version,
            self.sidecar.deterministic,
            self.sidecar.async_free,
        });
    }

    // --------------------------------------------------- mirror types

    /// Inline a table entry only when the pattern matches AND the entry
    /// is referenced exactly once in the whole sidecar: an authored type
    /// that merely spells like the pattern but is shared across sites
    /// stays a named top-level declaration (inlining it at one site
    /// would leave the others dangling).
    fn inlinedNames(self: *Emitter) Error![]const []const u8 {
        return inlinedTableNames(self.arena, self.sidecar);
    }

    fn mirrorTypes(self: *Emitter) Error!void {
        const inlined = self.inlined;
        for (self.sidecar.types.enums) |entry| {
            // The 256-member bound is validated by the reader
            // (sidecar.zig) before emission ever runs.
            try self.print("\npub const {f} = enum(u8) {{", .{ident(entry.name)});
            for (entry.members, 0..) |member, index| {
                try self.print("\n    {f} = {d},", .{ ident(member), index });
            }
            try self.raw("\n};\n");
        }
        for (self.sidecar.types.structs) |entry| {
            if (std.mem.eql(u8, entry.name, self.sidecar.model)) continue;
            if (nameListed(inlined, entry.name)) continue;
            try self.print("\npub const {f} = struct {{", .{ident(entry.name)});
            for (entry.fields) |field| {
                try self.print("\n    {f}: {s},", .{ ident(field.name), try self.spellRef(field.type, entry.name, field.name) });
            }
            try self.raw("\n};\n");
        }
        for (self.sidecar.types.unions) |entry| {
            if (nameListed(inlined, entry.name)) continue;
            try self.print("\npub const {f} = union(enum) {{", .{ident(entry.name)});
            for (entry.arms) |arm| {
                if (arm.payload == .void) {
                    try self.print("\n    {f},", .{ident(arm.name)});
                } else {
                    try self.print("\n    {f}: {s},", .{ ident(arm.name), try self.spellRef(arm.payload, entry.name, arm.name) });
                }
            }
            try self.raw("\n};\n");
        }
    }

    /// The one TypeRef-to-Zig-spelling authority. `container`/`member`
    /// name the reference site so synthesized entries inline here.
    fn spellRef(self: *Emitter, ref: TypeRef, container: []const u8, member: []const u8) Error![]const u8 {
        return switch (ref) {
            .bool => "bool",
            .f64 => "f64",
            .i64 => "i64",
            .bytes => "[]const u8",
            .void => "void",
            .optional => |inner| try std.fmt.allocPrint(self.arena, "?{s}", .{try self.spellRef(inner.*, container, member)}),
            .slice => |elem| try std.fmt.allocPrint(self.arena, "[]const {s}", .{try self.spellRef(elem.*, container, member)}),
            .node => |name| try std.fmt.allocPrint(self.arena, "*const {s}", .{try self.spellNamed(name, container, member)}),
            .value => |name| try self.spellNamed(name, container, member),
            .enum_ref, .union_ref => |name| try std.fmt.allocPrint(self.arena, "{f}", .{ident(name)}),
        };
    }

    fn spellNamed(self: *Emitter, name: []const u8, container: []const u8, member: []const u8) Error![]const u8 {
        if (!isSynthesizedRef(container, member, name) or !nameListed(self.inlined, name)) {
            return std.fmt.allocPrint(self.arena, "{f}", .{ident(name)});
        }
        const entry = sidecar_mod.findStruct(self.sidecar.types, name) orelse
            return std.fmt.allocPrint(self.arena, "{f}", .{ident(name)});
        var text: std.ArrayListUnmanaged(u8) = .empty;
        try text.appendSlice(self.arena, "struct {");
        for (entry.fields, 0..) |field, index| {
            if (index > 0) try text.appendSlice(self.arena, ",");
            const piece = try std.fmt.allocPrint(self.arena, " {f}: {s}", .{ ident(field.name), try self.spellRef(field.type, entry.name, field.name) });
            try text.appendSlice(self.arena, piece);
        }
        try text.appendSlice(self.arena, " }");
        return text.items;
    }

    // ---------------------------------------------------------- model

    fn modelStruct(self: *Emitter) Error!void {
        const model = sidecar_mod.findStruct(self.sidecar.types, self.sidecar.model) orelse {
            self.diags.flag("model", "\"{s}\" names no struct in the type table", .{self.sidecar.model});
            return;
        };
        try self.print("\npub const {f} = struct {{", .{ident(model.name)});
        for (model.fields) |field| {
            try self.print("\n    {f}: {s},", .{ ident(field.name), try self.spellRef(field.type, model.name, field.name) });
        }
        if (self.sidecar.model_helpers.len > 0) try self.raw("\n");
        for (self.sidecar.model_helpers, 0..) |helper, index| {
            const returns = try self.spellRef(helper.returns, "helpers", helper.name);
            if (helper.arena) {
                // The build-arena scalar form: the view build hands its
                // arena; the decoded result lives there.
                try self.print("\n    pub fn {f}(self: *const {f}, arena: std.mem.Allocator) {s} {{\n        _ = self;\n        return callHelper({s}, {d}, &.{{}}, arena);\n    }}", .{ ident(helper.name), ident(model.name), returns, returns, index });
                if (helper.params.len > 0) {
                    self.diags.flag("model_helpers", "helper \"{s}\": the arena form takes no extra parameters (the arena is the second parameter by contract)", .{helper.name});
                }
                continue;
            }
            if (helper.params.len == 0) {
                try self.print("\n    pub fn {f}(self: *const {f}) {s} {{\n        _ = self;\n        return callHelper({s}, {d}, &.{{}}, shim_rt.frameAllocator());\n    }}", .{ ident(helper.name), ident(model.name), returns, returns, index });
            } else {
                // Extra parameters cross as their canonical encodings,
                // concatenated in order (a tuple encodes as exactly
                // that).
                var params: std.ArrayListUnmanaged(u8) = .empty;
                var tuple: std.ArrayListUnmanaged(u8) = .empty;
                for (helper.params, 0..) |param, param_index| {
                    const spelled = try self.spellRef(param, "helpers", helper.name);
                    try params.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, ", p{d}: {s}", .{ param_index, spelled }));
                    if (param_index > 0) try tuple.appendSlice(self.arena, ", ");
                    try tuple.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "p{d}", .{param_index}));
                }
                try self.print("\n    pub fn {f}(self: *const {f}{s}) {s} {{\n        _ = self;\n        const args_tuple = .{{ {s} }};\n        const args = shim_rt.encodeAlloc(@TypeOf(args_tuple), args_tuple, shim_rt.frameAllocator());\n        return callHelper({s}, {d}, args, shim_rt.frameAllocator());\n    }}", .{ ident(helper.name), ident(model.name), params.items, returns, tuple.items, returns, index });
            }
        }
        try self.unboundDecl(self.sidecar.model_unbound);
        try self.raw("\n};\n");
    }

    fn unboundDecl(self: *Emitter, names: []const []const u8) Error!void {
        if (names.len == 0) return;
        try self.raw("\n\n    pub const view_unbound = .{");
        for (names, 0..) |name, index| {
            if (index > 0) try self.raw(",");
            try self.print(" \"{f}\"", .{std.zig.fmtString(name)});
        }
        try self.raw(" };");
    }

    // ------------------------------------------------------------ msg

    fn msgUnion(self: *Emitter) Error!void {
        try self.print("\npub const {f} = union(enum) {{", .{ident(self.sidecar.msg.name)});
        for (self.sidecar.msg.arms) |arm| {
            switch (arm.payload) {
                .void => try self.print("\n    {f},", .{ident(arm.name)}),
                .bytes => try self.print("\n    {f}: []const u8,", .{ident(arm.name)}),
                .number => |class| try self.print("\n    {f}: {s},", .{ ident(arm.name), @tagName(class) }),
                // The two-field family carries no field-order fact; the
                // mirror declares the number field first, the emitted
                // convention of every producer of this shape. A record
                // declared bytes-first must ride the record family (its
                // table entry carries order explicitly) — see
                // SCHEMA-GAPS.md.
                .number_bytes => |desc| try self.print("\n    {f}: struct {{ {f}: {s}, {f}: []const u8 }},", .{ ident(arm.name), ident(desc.number_field), @tagName(desc.number_class), ident(desc.bytes_field) }),
                .record => |name| try self.print("\n    {f}: {s},", .{ ident(arm.name), try self.spellNamed(name, self.sidecar.msg.name, arm.name) }),
                .union_ref, .enum_ref => |name| try self.print("\n    {f}: {f},", .{ ident(arm.name), ident(name) }),
                .scalar => |ref| try self.print("\n    {f}: {s},", .{ ident(arm.name), try self.spellRef(ref, self.sidecar.msg.name, arm.name) }),
            }
        }
        try self.unboundDecl(self.sidecar.msg.unbound);
        try self.raw("\n};\n");
    }

    /// The host wiring names its roots by fixed spelling — the staged
    /// main re-exports `core.Model` and `core.Msg`, and the adapter and
    /// bridge reflect those decls — so a sidecar whose own names differ
    /// gets aliases (same types; aliases are transparent to every
    /// reflecting consumer).
    fn wiringAliases(self: *Emitter) Error!void {
        if (!std.mem.eql(u8, self.sidecar.model, "Model")) {
            try self.print("\n/// The host wiring's spelling for the root state type.\npub const Model = {f};\n", .{ident(self.sidecar.model)});
        }
        if (!std.mem.eql(u8, self.sidecar.msg.name, "Msg")) {
            try self.print("\n/// The host wiring's spelling for the message union.\npub const Msg = {f};\n", .{ident(self.sidecar.msg.name)});
        }
    }

    fn tagTable(self: *Emitter) Error!void {
        try self.raw(
            \\
            \\/// Declaration-order wire tags: the arm's index in this table IS
            \\/// its wire tag (dense, u8). The sidecar is the tag authority; the
            \\/// compiled object's lowering assigns the same order, and the
            \\/// boot-time build_id fence proves both came from one compile.
            \\pub const msg_tags = [_][]const u8{
        );
        for (self.sidecar.msg.arms) |arm| {
            try self.print("\n    \"{f}\",", .{std.zig.fmtString(arm.name)});
        }
        try self.raw("\n};\n");
        try self.print(
            \\
            \\comptime {{
            \\    // The union and the tag table are emitted from one arm list;
            \\    // hold them equal anyway so a hand edit cannot skew dispatch.
            \\    const fields = @typeInfo({f}).@"union".fields;
            \\    if (fields.len != msg_tags.len) @compileError("core_shim: msg_tags and the message union disagree — regenerate from the sidecar");
            \\    for (fields, msg_tags) |field, tag_name| {{
            \\        if (!std.mem.eql(u8, field.name, tag_name)) @compileError("core_shim: msg_tags and the message union disagree — regenerate from the sidecar");
            \\    }}
            \\}}
            \\
        , .{ident(self.sidecar.msg.name)});
    }

    // --------------------------------------------------- entry points

    fn entryPoints(self: *Emitter) Error!void {
        const model_name = try std.fmt.allocPrint(self.arena, "{f}", .{ident(self.sidecar.model)});

        // Boot. Export attestation first (V11's link-time half: the
        // bindings resolve lazily, so referencing every attested
        // symbol here turns a missing export into a LINK failure
        // instead of a latent hole), then identity (pure getters, the
        // staleness fence), then the sink, then init — the ABI's
        // required ordering.
        try self.raw(
            \\
            \\fn boot() void {
            \\    referenceAttestedExports();
            \\    shim_rt.verifyIdentity(abi.abi_version_fn(), abi.build_id(), sidecar_abi_version, sidecar_build_id);
            \\    abi.set_panic_sink(shim_rt.panicSink, null);
            \\    abi.init();
            \\}
            \\
            \\/// The sidecar's abi.exports list is a biconditional attestation:
            \\/// every listed symbol exists in the object, and the object
            \\/// exports nothing else under the prefix. Referencing each listed
            \\/// symbol makes the LINKER prove the "exists" direction against
            \\/// the real binary. The "nothing else" direction is not provable
            \\/// from the consumer side — a linker ignores unreferenced extra
            \\/// exports, and this generator never opens the object — so it
            \\/// belongs to the producer's conformance suite, which probes the
            \\/// object's full symbol table at compile time.
            \\fn referenceAttestedExports() void {
            \\
        );
        for (self.sidecar.abi.exports) |suffix| {
            const binding = if (std.mem.eql(u8, suffix, "abi_version")) "abi_version_fn" else suffix;
            try self.print("    std.mem.doNotOptimizeAway(abi.{f});\n", .{ident(binding)});
        }
        try self.raw("}\n");

        if (self.sidecar.init_returns_cmd) {
            try self.print(
                \\
                \\pub const InitResult = struct {{ model: *const {s}, cmd: rt.Cmd }};
                \\
                \\pub fn initialModel() InitResult {{
                \\    boot();
                \\    var cmd_ptr: [*]const u8 = undefined;
                \\    var cmd_len: usize = 0;
                \\    abi.boot_cmd(&cmd_ptr, &cmd_len);
                \\    return .{{ .model = snapshotModel(), .cmd = cmd_ptr[0..cmd_len] }};
                \\}}
                \\
            , .{model_name});
        } else {
            try self.print(
                \\
                \\pub fn initialModel() *const {s} {{
                \\    boot();
                \\    return snapshotModel();
                \\}}
                \\
            , .{model_name});
        }

        if (self.sidecar.update_returns_cmd) {
            try self.print(
                \\
                \\pub const UpdateResult = struct {{ model: *const {s}, cmd: rt.Cmd }};
                \\
                \\pub fn update(model: *const {s}, msg: {f}) UpdateResult {{
                \\
            , .{ model_name, model_name, ident(self.sidecar.msg.name) });
        } else {
            try self.print(
                \\
                \\pub fn update(model: *const {s}, msg: {f}) *const {s} {{
                \\
            , .{ model_name, ident(self.sidecar.msg.name), model_name });
        }
        try self.raw(
            \\    // The compiled core owns the committed state; the mirror root
            \\    // the host passes is a decoded copy, so only tag and payload
            \\    // cross the boundary.
            \\    _ = model;
            \\    var cmd_ptr: [*]const u8 = undefined;
            \\    var cmd_len: usize = 0;
            \\    switch (msg) {
            \\
        );
        for (self.sidecar.msg.arms, 0..) |arm, tag| {
            try self.dispatchArm(arm, tag);
        }
        try self.raw("    }\n");
        if (self.sidecar.update_returns_cmd) {
            try self.raw("    return .{ .model = snapshotModel(), .cmd = cmd_ptr[0..cmd_len] };\n}\n");
        } else {
            try self.raw("    _ = cmd_ptr;\n    _ = cmd_len;\n    return snapshotModel();\n}\n");
        }

        if (self.sidecar.has_subscriptions) {
            try self.print(
                \\
                \\pub fn subscriptions(model: *const {s}) rt.Sub {{
                \\    // The core derives subscriptions from its own committed
                \\    // model; the mirror root only satisfies the signature the
                \\    // host layer expects.
                \\    _ = model;
                \\    var subs_ptr: [*]const u8 = undefined;
                \\    var subs_len: usize = 0;
                \\    abi.subscriptions(&subs_ptr, &subs_len);
                \\    return subs_ptr[0..subs_len];
                \\}}
                \\
            , .{model_name});
        }

        try self.print(
            \\
            \\/// Commit happens inside every dispatch entry core-side; the
            \\/// decoded mirror is already the committed value, so the frame-end
            \\/// commit is identity here.
            \\pub fn commitModelRoot(next: *const {s}) *const {s} {{
            \\    return next;
            \\}}
            \\
        , .{ model_name, model_name });
    }

    fn dispatchArm(self: *Emitter, arm: sidecar_mod.MsgArm, tag: usize) Error!void {
        const name = try std.fmt.allocPrint(self.arena, "{f}", .{ident(arm.name)});
        switch (arm.payload) {
            .void => try self.print("        .{s} => abi.dispatch_void({d}, &cmd_ptr, &cmd_len),\n", .{ name, tag }),
            .bytes => try self.print("        .{s} => |payload| abi.dispatch_bytes({d}, payload.ptr, payload.len, &cmd_ptr, &cmd_len),\n", .{ name, tag }),
            .number => |class| switch (class) {
                .f64 => try self.print("        .{s} => |payload| abi.dispatch_number({d}, payload, &cmd_ptr, &cmd_len),\n", .{ name, tag }),
                .i64 => try self.print("        .{s} => |payload| abi.dispatch_number({d}, shim_rt.exactF64(payload), &cmd_ptr, &cmd_len),\n", .{ name, tag }),
            },
            .number_bytes => |desc| {
                const number_expr = switch (desc.number_class) {
                    .f64 => try std.fmt.allocPrint(self.arena, "payload.{f}", .{ident(desc.number_field)}),
                    .i64 => try std.fmt.allocPrint(self.arena, "shim_rt.exactF64(payload.{f})", .{ident(desc.number_field)}),
                };
                try self.print("        .{s} => |payload| abi.dispatch_number_bytes({d}, {s}, payload.{f}.ptr, payload.{f}.len, &cmd_ptr, &cmd_len),\n", .{ name, tag, number_expr, ident(desc.bytes_field), ident(desc.bytes_field) });
            },
            .enum_ref => try self.print("        .{s} => |payload| abi.dispatch_enum({d}, @intCast(@intFromEnum(payload)), &cmd_ptr, &cmd_len),\n", .{ name, tag }),
            .union_ref => |type_name| {
                if (self.isTextInputUnion(type_name)) {
                    try self.print("        .{s} => |payload| {{\n            const encoded = shim_rt.encodeAlloc(@TypeOf(payload), payload, shim_rt.frameAllocator());\n            abi.dispatch_text_input({d}, encoded.ptr, encoded.len, &cmd_ptr, &cmd_len);\n        }},\n", .{ name, tag });
                } else {
                    try self.print("        .{s} => |payload| {{\n            const encoded = shim_rt.encodeAlloc(@TypeOf(payload), payload, shim_rt.frameAllocator());\n            abi.dispatch_record({d}, encoded.ptr, encoded.len, &cmd_ptr, &cmd_len);\n        }},\n", .{ name, tag });
                }
            },
            .record => |type_name| {
                if (self.scrollStateFields(type_name)) |fields| {
                    var scalars: std.ArrayListUnmanaged(u8) = .empty;
                    for (fields, 0..) |field, index| {
                        if (index > 0) try scalars.appendSlice(self.arena, ", ");
                        const record = sidecar_mod.findStruct(self.sidecar.types, type_name).?;
                        const expr = switch (record.fields[field].type) {
                            .i64 => try std.fmt.allocPrint(self.arena, "shim_rt.exactF64(payload.{f})", .{ident(record.fields[field].name)}),
                            else => try std.fmt.allocPrint(self.arena, "payload.{f}", .{ident(record.fields[field].name)}),
                        };
                        try scalars.appendSlice(self.arena, expr);
                    }
                    try self.print("        .{s} => |payload| abi.dispatch_scroll_state({d}, {s}, &cmd_ptr, &cmd_len),\n", .{ name, tag, scalars.items });
                } else {
                    try self.print("        .{s} => |payload| {{\n            const encoded = shim_rt.encodeAlloc(@TypeOf(payload), payload, shim_rt.frameAllocator());\n            abi.dispatch_record({d}, encoded.ptr, encoded.len, &cmd_ptr, &cmd_len);\n        }},\n", .{ name, tag });
                }
            },
            .scalar => |ref| switch (ref) {
                .bool => try self.print("        .{s} => |payload| abi.dispatch_bool({d}, @intFromBool(payload), &cmd_ptr, &cmd_len),\n", .{ name, tag }),
                .f64 => try self.print("        .{s} => |payload| abi.dispatch_number({d}, payload, &cmd_ptr, &cmd_len),\n", .{ name, tag }),
                .i64 => try self.print("        .{s} => |payload| abi.dispatch_number({d}, shim_rt.exactF64(payload), &cmd_ptr, &cmd_len),\n", .{ name, tag }),
                .bytes => try self.print("        .{s} => |payload| abi.dispatch_bytes({d}, payload.ptr, payload.len, &cmd_ptr, &cmd_len),\n", .{ name, tag }),
                else => self.diags.flag("msg.arms", "arm \"{s}\": ABI version 1 has no dispatch entry for this scalar shape (bool, number, and bytes scalars only)", .{arm.name}),
            },
        }
    }

    /// A union payload declaring the text-input event shape routes
    /// through the dedicated dispatch entry — the same structural
    /// recognition the markup engines apply (ui_markup_reflect's
    /// declaredTextInputUnion, restated over sidecar data): exactly the
    /// eleven tags, insert_text a bytes payload, the seven verb arms
    /// void, move_caret a caret-move record, set_selection a numeric
    /// anchor/focus record, set_composition a bytes-text plus optional
    /// numeric cursor record. Anything short of the full shape is an
    /// ordinary union payload on the record entry.
    fn isTextInputUnion(self: *Emitter, type_name: []const u8) bool {
        const entry = sidecar_mod.findUnion(self.sidecar.types, type_name) orelse return false;
        if (entry.arms.len != text_input_event_tags.len) return false;
        outer: for (text_input_event_tags) |tag_name| {
            for (entry.arms) |arm| {
                if (std.mem.eql(u8, arm.name, tag_name)) continue :outer;
            }
            return false;
        }
        for (entry.arms) |arm| {
            if (std.mem.eql(u8, arm.name, "insert_text")) {
                if (arm.payload != .bytes) return false;
            } else if (std.mem.eql(u8, arm.name, "move_caret")) {
                if (!self.isCaretMoveRecord(arm.payload)) return false;
            } else if (std.mem.eql(u8, arm.name, "set_selection")) {
                if (!self.isSelectionRecord(arm.payload)) return false;
            } else if (std.mem.eql(u8, arm.name, "set_composition")) {
                if (!self.isCompositionRecord(arm.payload)) return false;
            } else if (arm.payload != .void) {
                return false;
            }
        }
        return true;
    }

    /// A BY-VALUE record reference, for the structural vocabularies the
    /// host constructs by field name (channel records) or the engines
    /// match without pointer transparency (text-input payload records):
    /// a `node` reference mirrors as `*const T`, which neither
    /// consumer's shape accepts, so it must not satisfy these checks.
    fn recordOf(self: *Emitter, ref: TypeRef) ?*const sidecar_mod.Struct {
        return switch (ref) {
            .value => |name| sidecar_mod.findStruct(self.sidecar.types, name),
            else => null,
        };
    }

    fn isNumericRef(ref: TypeRef) bool {
        return ref == .f64 or ref == .i64;
    }

    fn isCaretMoveRecord(self: *Emitter, ref: TypeRef) bool {
        const record = self.recordOf(ref) orelse return false;
        if (record.fields.len != 2) return false;
        const caret_members = [_][]const u8{ "previous", "next", "previous_word", "next_word", "start", "end" };
        var direction_ok = false;
        var extend_ok = false;
        for (record.fields) |field| {
            if (std.mem.eql(u8, field.name, "extend")) {
                extend_ok = field.type == .bool;
            } else if (std.mem.eql(u8, field.name, "direction")) {
                const members = switch (field.type) {
                    .enum_ref => |name| (sidecar_mod.findEnum(self.sidecar.types, name) orelse return false).members,
                    else => return false,
                };
                if (members.len != caret_members.len) return false;
                outer: for (caret_members) |member| {
                    for (members) |declared| {
                        if (std.mem.eql(u8, declared, member)) continue :outer;
                    }
                    return false;
                }
                direction_ok = true;
            }
        }
        return direction_ok and extend_ok;
    }

    fn isSelectionRecord(self: *Emitter, ref: TypeRef) bool {
        const record = self.recordOf(ref) orelse return false;
        if (record.fields.len != 2) return false;
        var anchor_ok = false;
        var focus_ok = false;
        for (record.fields) |field| {
            if (std.mem.eql(u8, field.name, "anchor")) anchor_ok = isNumericRef(field.type);
            if (std.mem.eql(u8, field.name, "focus")) focus_ok = isNumericRef(field.type);
        }
        return anchor_ok and focus_ok;
    }

    fn isCompositionRecord(self: *Emitter, ref: TypeRef) bool {
        const record = self.recordOf(ref) orelse return false;
        if (record.fields.len != 2) return false;
        var text_ok = false;
        var cursor_ok = false;
        for (record.fields) |field| {
            if (std.mem.eql(u8, field.name, "text")) text_ok = field.type == .bytes;
            if (std.mem.eql(u8, field.name, "cursor")) {
                cursor_ok = switch (field.type) {
                    .optional => |inner| isNumericRef(inner.*),
                    else => false,
                };
            }
        }
        return text_ok and cursor_ok;
    }

    /// Declaration-order field indexes of a scroll-state record, in the
    /// ABI entry's parameter order (offset, velocity, viewport extent,
    /// content extent) — or null when the record is not that shape.
    fn scrollStateFields(self: *Emitter, type_name: []const u8) ?[4]usize {
        const entry = sidecar_mod.findStruct(self.sidecar.types, type_name) orelse return null;
        if (entry.fields.len != 4) return null;
        const spellings = [_][4][]const u8{ scroll_state_fields_ts, scroll_state_fields_canvas };
        for (spellings) |names| {
            var indexes: [4]usize = undefined;
            var all_found = true;
            for (names, 0..) |field_name, position| {
                indexes[position] = for (entry.fields, 0..) |field, index| {
                    const numeric = field.type == .f64 or field.type == .i64;
                    if (std.mem.eql(u8, field.name, field_name) and numeric) break index;
                } else {
                    all_found = false;
                    break;
                };
                if (!all_found) break;
            }
            if (all_found) return indexes;
        }
        return null;
    }

    // -------------------------------------------------------- channels

    fn channels(self: *Emitter) Error!void {
        const chan = self.sidecar.channels;
        const any_fn_channel = chan.command_msg or chan.frame_msg or chan.key_msg or chan.pinch_msg;

        if (chan.command_msg) {
            try self.print(
                \\
                \\/// Menus, shortcuts, and chrome tabs dispatch through the core's
                \\/// exported command mapper.
                \\pub fn commandMsg(name: []const u8) ?{f} {{
                \\    var out: core_abi.CoreMsg = undefined;
                \\    if (abi.command_msg(name.ptr, name.len, &out) == 0) return null;
                \\    return msgFromWire(out.tag, out.payload[0..out.payload_len]);
                \\}}
                \\
            , .{ident(self.sidecar.msg.name)});
        }
        if (chan.frame_msg) {
            try self.print(
                \\
                \\/// The presented-frame channel's record: canvas points plus the
                \\/// frame clock in fractional milliseconds. The adapter builds it
                \\/// by field name, exactly as for transpiler output.
                \\pub const FrameEvent = struct {{
                \\    width: f64,
                \\    height: f64,
                \\    timestampMs: f64,
                \\    intervalMs: f64,
                \\}};
                \\
                \\pub fn frameMsg(model: *const {f}, frame: FrameEvent) ?{f} {{
                \\    _ = model;
                \\    var out: core_abi.CoreMsg = undefined;
                \\    if (abi.frame_msg(frame.width, frame.height, frame.timestampMs, frame.intervalMs, &out) == 0) return null;
                \\    return msgFromWire(out.tag, out.payload[0..out.payload_len]);
                \\}}
                \\
            , .{ ident(self.sidecar.model), ident(self.sidecar.msg.name) });
        }
        if (chan.key_msg) {
            try self.print(
                \\
                \\/// The key-fallback channel's record: the lowercased key name
                \\/// plus the four modifier booleans.
                \\pub const KeyEvent = struct {{
                \\    key: []const u8,
                \\    shift: bool,
                \\    control: bool,
                \\    alt: bool,
                \\    super: bool,
                \\}};
                \\
                \\pub fn keyMsg(key: KeyEvent) ?{f} {{
                \\    var out: core_abi.CoreMsg = undefined;
                \\    if (abi.key_msg(key.key.ptr, key.key.len, @intFromBool(key.shift), @intFromBool(key.control), @intFromBool(key.alt), @intFromBool(key.super), &out) == 0) return null;
                \\    return msgFromWire(out.tag, out.payload[0..out.payload_len]);
                \\}}
                \\
            , .{ident(self.sidecar.msg.name)});
        }
        if (chan.pinch_msg) {
            try self.print(
                \\
                \\pub const PinchPhase = enum(u8) {{ begin = 0, change = 1, end = 2 }};
                \\
                \\/// The pinch channel's record: window/view source identity, the
                \\/// multiplicative magnification delta, and the view-local anchor.
                \\pub const PinchEvent = struct {{
                \\    windowId: f64,
                \\    label: []const u8,
                \\    phase: PinchPhase,
                \\    scale: f64,
                \\    x: f64,
                \\    y: f64,
                \\}};
                \\
                \\pub fn pinchMsg(pinch: PinchEvent) ?{f} {{
                \\    var out: core_abi.CoreMsg = undefined;
                \\    if (abi.pinch_msg(pinch.windowId, pinch.label.ptr, pinch.label.len, @intCast(@intFromEnum(pinch.phase)), pinch.scale, pinch.x, pinch.y, &out) == 0) return null;
                \\    return msgFromWire(out.tag, out.payload[0..out.payload_len]);
                \\}}
                \\
            , .{ident(self.sidecar.msg.name)});
        }

        if (chan.appearance_msg) |arm_name| {
            try self.print("\n/// The arm the host fills with the structural appearance record.\npub const appearanceMsg = \"{f}\";\n", .{std.zig.fmtString(arm_name)});
        }
        if (chan.chrome_msg) |arm_name| {
            try self.print("\n/// The arm the host fills with the structural window-chrome record.\npub const chromeMsg = \"{f}\";\n", .{std.zig.fmtString(arm_name)});
        }
        if (chan.env_msgs.len > 0) {
            try self.raw(
                \\
                \\/// The launch-time environment channel: each variable present at
                \\/// launch dispatches one journaled Msg on its bytes arm, right
                \\/// after the boot command. The core itself never reads the
                \\/// environment; replay carries the recorded values.
                \\pub const envMsgs = .{
                \\
            );
            for (chan.env_msgs) |entry| {
                try self.print("    .{{ .env = \"{f}\", .msg = \"{f}\" }},\n", .{ std.zig.fmtString(entry.env), std.zig.fmtString(entry.msg) });
            }
            try self.raw("};\n");
        }

        if (any_fn_channel) {
            try self.print(
                \\
                \\/// Decode a channel entry's encoded message: the wire tag picks
                \\/// the arm, the payload rides the canonical value encoding of
                \\/// that arm's mirror payload type.
                \\fn msgFromWire(tag: u8, payload: []const u8) {f} {{
                \\    switch (tag) {{
                \\
            , .{ident(self.sidecar.msg.name)});
            for (self.sidecar.msg.arms, 0..) |arm, tag| {
                if (arm.payload == .void) {
                    try self.print("        {d} => {{\n            shim_rt.assertVoidPayload(payload);\n            return .{f};\n        }},\n", .{ tag, ident(arm.name) });
                } else {
                    try self.print("        {d} => return .{{ .{f} = shim_rt.decodeExact(@FieldType({f}, \"{f}\"), payload, shim_rt.frameAllocator()) }},\n", .{ tag, ident(arm.name), ident(self.sidecar.msg.name), std.zig.fmtString(arm.name) });
                }
            }
            try self.raw(
                \\        else => @panic("the compiled core handed back a message tag past the declared arms — the core and its contract sidecar disagree; rebuild the app so both come from one compile"),
                \\    }
                \\}
                \\
            );
        }
    }

    // ----------------------------------------------------- helper glue

    fn helperPlumbing(self: *Emitter) Error!void {
        if (self.sidecar.model_helpers.len == 0) return;
        try self.raw(
            \\
            \\/// Call the compiled core's exported helper at `index` (the
            \\/// sidecar's model_helpers order IS the call index) and decode the
            \\/// result. An unknown index traps core-side through the panic
            \\/// sink; there is no status to check. Results are read-arena
            \\/// resident, the same until-next-dispatch lifetime view builds get
            \\/// from transpiler output.
            \\fn callHelper(comptime T: type, index: u32, args: []const u8, allocator: std.mem.Allocator) T {
            \\    var out_ptr: [*]const u8 = undefined;
            \\    var out_len: usize = 0;
            \\    abi.helper_call(index, args.ptr, args.len, &out_ptr, &out_len);
            \\    return shim_rt.decodeExact(T, out_ptr[0..out_len], allocator);
            \\}
            \\
        );
    }

    // -------------------------------------------------- snapshot glue

    fn snapshotPlumbing(self: *Emitter) Error!void {
        try self.print(
            \\
            \\/// Decode the committed model from the core's snapshot buffer
            \\/// (canonical value encoding of the root record, snapshot format
            \\/// {d}). The decoded mirror lives in the shim's model arena until
            \\/// the next snapshot — it must survive frame resets, exactly as the
            \\/// transpiler lane's committed heap does.
            \\fn snapshotModel() *const {f} {{
            \\    var snap_ptr: [*]const u8 = undefined;
            \\    var snap_len: usize = 0;
            \\    abi.model_snapshot(&snap_ptr, &snap_len);
            \\    return shim_rt.decodeSnapshot({f}, snap_ptr[0..snap_len]);
            \\}}
            \\
        , .{ self.sidecar.abi.snapshot_format, ident(self.sidecar.model), ident(self.sidecar.model) });
    }
};

// ------------------------------------------------- shared analysis
//
// Both projections of the sidecar — the Zig mirror and the TypeScript
// facade — must agree on which table entries are synthesized anonymous
// records, or the two sides would declare different type surfaces for
// one contract.

/// A table entry whose name follows the schema's synthesized pattern
/// for a reference site (`<Container>_<member>`).
///
/// The sidecar carries no synthesized-vs-authored marker, so a
/// single-use AUTHORED type that happens to spell exactly
/// `<Container>_<member>` at its one reference site is indistinguishable
/// from a synthesized entry and inlines too — layout, fingerprint, and
/// binding surface stay identical either way; only `@typeName`-carrying
/// artifacts see the difference. The bias must run this direction: real
/// synthesized records (the common case, pinned by the conformance
/// corpus) MUST inline to mirror the emitted module. Closing the
/// ambiguity needs a schema fact (see SCHEMA-GAPS.md).
pub fn isSynthesizedRef(container: []const u8, member: []const u8, name: []const u8) bool {
    if (name.len != container.len + 1 + member.len) return false;
    return std.mem.startsWith(u8, name, container) and
        name[container.len] == '_' and
        std.mem.endsWith(u8, name, member);
}

/// The table entries emitted inline at their single reference site:
/// pattern-matching names referenced exactly once in the whole sidecar.
pub fn inlinedTableNames(arena: std.mem.Allocator, sidecar: Sidecar) error{OutOfMemory}![]const []const u8 {
    var candidates: std.ArrayListUnmanaged([]const u8) = .empty;
    for (sidecar.types.structs) |entry| {
        for (entry.fields) |field| {
            try noteCandidate(&candidates, arena, entry.name, field.name, field.type);
        }
    }
    for (sidecar.types.unions) |entry| {
        for (entry.arms) |arm| {
            try noteCandidate(&candidates, arena, entry.name, arm.name, arm.payload);
        }
    }
    for (sidecar.msg.arms) |arm| {
        switch (arm.payload) {
            .record => |name| if (isSynthesizedRef(sidecar.msg.name, arm.name, name)) {
                try candidates.append(arena, name);
            },
            else => {},
        }
    }
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (candidates.items) |name| {
        if (referenceCount(sidecar, name) == 1) try names.append(arena, name);
    }
    return names.items;
}

fn noteCandidate(names: *std.ArrayListUnmanaged([]const u8), arena: std.mem.Allocator, container: []const u8, member: []const u8, ref: TypeRef) error{OutOfMemory}!void {
    switch (ref) {
        .optional => |inner| try noteCandidate(names, arena, container, member, inner.*),
        .slice => |elem| try noteCandidate(names, arena, container, member, elem.*),
        .node, .value => |name| if (isSynthesizedRef(container, member, name)) {
            try names.append(arena, name);
        },
        else => {},
    }
}

/// How many reference sites name a table entry, across the whole
/// sidecar (model root, table fields and arms, msg descriptors, helper
/// signatures).
pub fn referenceCount(sidecar: Sidecar, name: []const u8) usize {
    var count: usize = 0;
    if (std.mem.eql(u8, sidecar.model, name)) count += 1;
    for (sidecar.types.structs) |entry| {
        for (entry.fields) |field| count += refNames(field.type, name);
    }
    for (sidecar.types.unions) |entry| {
        for (entry.arms) |arm| count += refNames(arm.payload, name);
    }
    for (sidecar.msg.arms) |arm| {
        switch (arm.payload) {
            .record, .union_ref, .enum_ref => |payload_name| {
                if (std.mem.eql(u8, payload_name, name)) count += 1;
            },
            .scalar => |ref| count += refNames(ref, name),
            else => {},
        }
    }
    for (sidecar.model_helpers) |helper| {
        count += refNames(helper.returns, name);
        for (helper.params) |param| count += refNames(param, name);
    }
    return count;
}

fn refNames(ref: TypeRef, name: []const u8) usize {
    return switch (ref) {
        .optional => |inner| refNames(inner.*, name),
        .slice => |elem| refNames(elem.*, name),
        .node, .value, .enum_ref, .union_ref => |ref_name| @intFromBool(std.mem.eql(u8, ref_name, name)),
        else => 0,
    };
}

fn nameListed(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

/// Sidecar strings quoted inside the generated module's comments:
/// control characters would break the comment line, so they become
/// spaces (comments are provenance, never load-bearing).
fn commentText(arena: std.mem.Allocator, text: []const u8) []const u8 {
    const out = arena.dupe(u8, text) catch return "";
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

// -------------------------------------------------- identifier safety

/// Emit a sidecar name as a Zig identifier, `@"..."`-quoting anything
/// that is not a plain identifier (keywords, leading digits, exotic
/// characters) — the author's spelling survives either way, and every
/// reflecting consumer reads the unquoted name.
const Ident = struct {
    name: []const u8,

    pub fn format(self: Ident, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (isPlainIdentifier(self.name)) {
            try writer.writeAll(self.name);
        } else {
            try writer.print("@\"{f}\"", .{std.zig.fmtString(self.name)});
        }
    }
};

fn ident(name: []const u8) Ident {
    return .{ .name = name };
}

fn isPlainIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    // `_` is the discard token, not a declarable identifier.
    if (std.mem.eql(u8, name, "_")) return false;
    if (name[0] >= '0' and name[0] <= '9') return false;
    for (name) |char| {
        const ok = (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z') or
            (char >= '0' and char <= '9') or char == '_';
        if (!ok) return false;
    }
    if (std.zig.Token.keywords.has(name)) return false;
    // Primitive type names shadow poorly; quote them too.
    if (std.zig.isPrimitive(name)) return false;
    return true;
}

// --------------------------------------------------------------- tests

const testing = std.testing;

fn emitFromJson(arena: std.mem.Allocator, json: []const u8) ![]const u8 {
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = sidecar_mod.read(arena, json, &diags) catch |err| {
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        diags.write("sidecar", &writer) catch {};
        std.debug.print("{s}", .{writer.buffered()});
        return err;
    };
    return emit(arena, parsed, &diags) catch |err| {
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        diags.write("sidecar", &writer) catch {};
        std.debug.print("{s}", .{writer.buffered()});
        return err;
    };
}

test "emission is deterministic and carries the mirror surface" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = try emitFromJson(arena, sidecar_mod.minimal_valid_json);
    const second = try emitFromJson(arena, sidecar_mod.minimal_valid_json);
    try testing.expectEqualStrings(first, second);
    try testing.expect(std.mem.indexOf(u8, first, "pub const Model = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, first, "count: i64,") != null);
    try testing.expect(std.mem.indexOf(u8, first, "pub const Msg = union(enum) {") != null);
    try testing.expect(std.mem.indexOf(u8, first, "label_set: []const u8,") != null);
    try testing.expect(std.mem.indexOf(u8, first, "abi.dispatch_void(0,") != null);
    try testing.expect(std.mem.indexOf(u8, first, "abi.dispatch_bytes(1,") != null);
    // A bare-model init emits the pointer-returning shape.
    try testing.expect(std.mem.indexOf(u8, first, "pub fn initialModel() *const Model {") != null);
    try testing.expect(std.mem.indexOf(u8, first, "pub const UpdateResult = struct { model: *const Model, cmd: rt.Cmd };") != null);
}

test "the emitted shim parses as Zig" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try emitFromJson(arena, sidecar_mod.minimal_valid_json);
    const source_z = try arena.dupeZ(u8, source);
    const tree = try std.zig.Ast.parse(arena, source_z, .zig);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "a type name colliding with a shim declaration refuses with a teaching" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The model root renamed to "rt": layout-legal, but the generated
    // module must also declare its kernel block under that name.
    const renamed = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"Model\"", "\"rt\"");
    const with_slot = try std.mem.replaceOwned(u8, arena, renamed, "\"slot\": \"Model.count\"", "\"slot\": \"rt.count\"");
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, with_slot, &diags);
    try testing.expectError(error.Refused, emit(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "collides with a declaration") != null) found = true;
    }
    try testing.expect(found);
}

test "a shared authored type spelling like a synthesized name stays a top-level declaration" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // "Model_user" is referenced from BOTH Model.user (where the
    // synthesized pattern matches) and Model.backup: inlining it at the
    // first site would leave the second dangling.
    const source =
        \\{
        \\  "format": 1, "wire_version": 3, "abi_version": 1,
        \\  "compiler_version": "0.0.1", "entry": "src/core.ts",
        \\  "source_hash": "00000000c0ffee00", "build_id": "00000000b01dface",
        \\  "types": {
        \\    "structs": [
        \\      {"name": "Model_user", "fields": [{"name": "id", "type": {"kind": "f64"}}]},
        \\      {"name": "Model", "fields": [
        \\        {"name": "user", "type": {"kind": "value", "name": "Model_user"}},
        \\        {"name": "backup", "type": {"kind": "value", "name": "Model_user"}}
        \\      ]}
        \\    ],
        \\    "enums": [], "unions": []
        \\  },
        \\  "model": "Model", "model_helpers": [], "model_unbound": [],
        \\  "msg": {"name": "Msg", "arms": [{"name": "bump", "payload": {"kind": "void"}}], "unbound": []},
        \\  "init_returns_cmd": false, "update_returns_cmd": true, "has_subscriptions": false,
        \\  "channels": {"command_msg": false, "frame_msg": false, "key_msg": false, "pinch_msg": false,
        \\    "appearance_msg": null, "chrome_msg": null, "env_msgs": []},
        \\  "abi": {"prefix": "nsc_core_", "exports": ["abi_version", "build_id", "set_panic_sink", "init",
        \\    "boot_cmd", "dispatch_void", "dispatch_bytes", "dispatch_number", "dispatch_number_bytes",
        \\    "dispatch_bool", "dispatch_enum", "dispatch_record", "dispatch_text_input",
        \\    "dispatch_scroll_state", "subscriptions", "frame_reset", "model_snapshot", "helper_call",
        \\    "collect"], "snapshot_format": 1},
        \\  "integer_slots": [], "deterministic": true, "async_free": true
        \\}
    ;
    const generated = try emitFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const Model_user = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "user: Model_user,") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "backup: Model_user,") != null);
}

test "exotic strings in names and env entries emit as valid Zig" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"env_msgs\": []",
        "\"env_msgs\": [{\"env\": \"APP\\\"MODE\\\\X\", \"msg\": \"label_set\"}]",
    );
    const parsed = try sidecar_mod.read(arena, source, &diags);
    const generated = try emit(arena, parsed, &diags);
    const source_z = try arena.dupeZ(u8, generated);
    const tree = try std.zig.Ast.parse(arena, source_z, .zig);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
    try testing.expect(std.mem.indexOf(u8, generated, "APP\\\"MODE\\\\X") != null);
}

test "channel glue speaks the sidecar's message union name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Rename the union to "Event" and wire the key channel.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"name\": \"Msg\"", "\"name\": \"Event\"");
    source = try std.mem.replaceOwned(u8, arena, source, "\"key_msg\": false", "\"key_msg\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"collect\"]", "\"collect\", \"key_msg\"]");
    const generated = try emitFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const Event = union(enum) {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub fn keyMsg(key: KeyEvent) ?Event {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "fn msgFromWire(tag: u8, payload: []const u8) Event {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "@FieldType(Event, \"label_set\")") != null);
    const source_z = try arena.dupeZ(u8, generated);
    const tree = try std.zig.Ast.parse(arena, source_z, .zig);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "optional glue names are reserved only when the glue is emitted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // No helpers and no function channels: a reachable type named
    // "callHelper" collides with nothing the shim declares.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"enums\": []", "\"enums\": [{\"name\": \"callHelper\", \"members\": [\"on\", \"off\"]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"enum\", \"name\": \"callHelper\"}}",
    );
    const generated = try emitFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const callHelper = enum(u8) {") != null);
}

test "UpdateResult reserves only when the cmd-returning update emits it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"update_returns_cmd\": true", "\"update_returns_cmd\": false");
    source = try std.mem.replaceOwned(u8, arena, source, "\"enums\": []", "\"enums\": [{\"name\": \"UpdateResult\", \"members\": [\"a\"]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"enum\", \"name\": \"UpdateResult\"}}",
    );
    const generated = try emitFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const UpdateResult = enum(u8) {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub fn update(model: *const Model, msg: Msg) *const Model {") != null);
}

test "a helper taking a generated glue name refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Methods shadow file-scope declarations inside the model struct: a
    // helper named callHelper would capture the forwarders' own calls.
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"callHelper\", \"params\": [], \"returns\": {\"kind\": \"bool\"}, \"arena\": false}]",
    );
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emit(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "shadow file-scope names") != null) found = true;
    }
    try testing.expect(found);
}

test "a helper named view_unbound refuses with a teaching" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"view_unbound\", \"params\": [], \"returns\": {\"kind\": \"bool\"}, \"arena\": false}]",
    );
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emit(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "opt-out tuple") != null) found = true;
    }
    try testing.expect(found);
}

test "a text-input-named union without the payload shapes rides the record entry" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Eleven right names, wrong insert_text payload (void): the markup
    // predicate would not bind this as text input, so dispatch must
    // not route it to the text_input entry either.
    var arms: std.ArrayListUnmanaged(u8) = .empty;
    const tags = [_][]const u8{
        "insert_text",         "delete_backward",    "delete_forward",     "delete_word_backward",
        "delete_word_forward", "clear",              "move_caret",         "set_selection",
        "set_composition",     "commit_composition", "cancel_composition",
    };
    for (tags, 0..) |tag, index| {
        if (index > 0) try arms.appendSlice(arena, ", ");
        const one = try std.fmt.allocPrint(arena, "{{\"name\": \"{s}\", \"payload\": {{\"kind\": \"void\"}}}}", .{tag});
        try arms.appendSlice(arena, one);
    }
    const union_entry = try std.fmt.allocPrint(arena, "\"unions\": [{{\"name\": \"NotTextInput\", \"arms\": [{s}]}}]", .{arms.items});
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"unions\": []", union_entry);
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"union\", \"name\": \"NotTextInput\"}}",
    );
    const generated = try emitFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "abi.dispatch_record(0,") != null);
    // No arm may route through the text-input entry (the attestation
    // block still references the symbol; only dispatch matters here).
    try testing.expect(std.mem.indexOf(u8, generated, "abi.dispatch_text_input(0,") == null);
}

test "boot references every attested export so the link proves the set" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const generated = try emitFromJson(arena, sidecar_mod.minimal_valid_json);
    try testing.expect(std.mem.indexOf(u8, generated, "fn referenceAttestedExports() void {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "std.mem.doNotOptimizeAway(abi.collect);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "std.mem.doNotOptimizeAway(abi.abi_version_fn);") != null);
    // Unwired channel entries are NOT attested and must not be
    // referenced (their absence in the object is the valid state).
    try testing.expect(std.mem.indexOf(u8, generated, "doNotOptimizeAway(abi.key_msg)") == null);
}

test "sidecar-selected root names get the wiring's fixed spellings as aliases" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"Model\"", "\"State\"");
    source = try std.mem.replaceOwned(u8, arena, source, "\"slot\": \"Model.count\"", "\"slot\": \"State.count\"");
    source = try std.mem.replaceOwned(u8, arena, source, "\"name\": \"Msg\"", "\"name\": \"Event\"");
    const generated = try emitFromJson(arena, source);
    // The host wiring re-exports core.Model/core.Msg by those exact
    // spellings; the aliases keep a renamed contract compilable.
    try testing.expect(std.mem.indexOf(u8, generated, "pub const Model = State;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const Msg = Event;") != null);
    // The default names alias nothing (a self-alias would not compile).
    const default_generated = try emitFromJson(arena, sidecar_mod.minimal_valid_json);
    try testing.expect(std.mem.indexOf(u8, default_generated, "pub const Model = Model;") == null);
    try testing.expect(std.mem.indexOf(u8, default_generated, "pub const Msg = Msg;") == null);
}

test "channel detection names are reserved even when the channel is absent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // channels.frame_msg is false in the minimal sidecar, but the host
    // probes the DECL name — a type called frameMsg would falsely wire
    // the channel and then fail as a non-function.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"enums\": []", "\"enums\": [{\"name\": \"frameMsg\", \"members\": [\"a\"]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"enum\", \"name\": \"frameMsg\"}}",
    );
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emit(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "\"frameMsg\" collides") != null) found = true;
    }
    try testing.expect(found);
}

test "a chrome arm holding its insets by reference refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The host constructs the chrome record BY VALUE field by field; a
    // node (by-reference) insets record cannot take that construction.
    const source =
        \\{
        \\  "format": 1, "wire_version": 3, "abi_version": 1,
        \\  "compiler_version": "0.0.1", "entry": "src/core.ts",
        \\  "source_hash": "00000000c0ffee00", "build_id": "00000000b01dface",
        \\  "types": {
        \\    "structs": [
        \\      {"name": "Model", "fields": [{"name": "chromeTop", "type": {"kind": "f64"}}]},
        \\      {"name": "Insets", "fields": [
        \\        {"name": "top", "type": {"kind": "f64"}}, {"name": "right", "type": {"kind": "f64"}},
        \\        {"name": "bottom", "type": {"kind": "f64"}}, {"name": "left", "type": {"kind": "f64"}}
        \\      ]},
        \\      {"name": "Buttons", "fields": [
        \\        {"name": "x", "type": {"kind": "f64"}}, {"name": "y", "type": {"kind": "f64"}},
        \\        {"name": "width", "type": {"kind": "f64"}}, {"name": "height", "type": {"kind": "f64"}}
        \\      ]},
        \\      {"name": "Msg_chrome_changed", "fields": [
        \\        {"name": "insets", "type": {"kind": "node", "name": "Insets"}},
        \\        {"name": "buttons", "type": {"kind": "value", "name": "Buttons"}},
        \\        {"name": "tabsProjected", "type": {"kind": "bool"}}
        \\      ]}
        \\    ],
        \\    "enums": [], "unions": []
        \\  },
        \\  "model": "Model", "model_helpers": [], "model_unbound": [],
        \\  "msg": {"name": "Msg", "arms": [
        \\    {"name": "chrome_changed", "payload": {"kind": "record", "name": "Msg_chrome_changed"}}
        \\  ], "unbound": []},
        \\  "init_returns_cmd": false, "update_returns_cmd": true, "has_subscriptions": false,
        \\  "channels": {"command_msg": false, "frame_msg": false, "key_msg": false, "pinch_msg": false,
        \\    "appearance_msg": null, "chrome_msg": "chrome_changed", "env_msgs": []},
        \\  "abi": {"prefix": "nsc_core_", "exports": ["abi_version", "build_id", "set_panic_sink", "init",
        \\    "boot_cmd", "dispatch_void", "dispatch_bytes", "dispatch_number", "dispatch_number_bytes",
        \\    "dispatch_bool", "dispatch_enum", "dispatch_record", "dispatch_text_input",
        \\    "dispatch_scroll_state", "subscriptions", "frame_reset", "model_snapshot", "helper_call",
        \\    "collect"], "snapshot_format": 1},
        \\  "integer_slots": [], "deterministic": true, "async_free": true
        \\}
    ;
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emit(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "insets: top/right/bottom/left numbers") != null) found = true;
    }
    try testing.expect(found);
}

test "the shim restates the module-graph attestations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const generated = try emitFromJson(arena, sidecar_mod.minimal_valid_json);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const deterministic: bool = true;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const async_free: bool = true;") != null);
}

test "number_bytes mirrors number-first; other orders ride the record family" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Family 4 carries no order fact, so the mirror emits the one
    // order every producer of this shape declares (SCHEMA-GAPS.md
    // records the missing fact and its closure). A bytes-first record
    // is still fully expressible: the record family's table entry
    // carries order explicitly — the documented route, pinned here.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Msg_loaded\", \"fields\": [{\"name\": \"body\", \"type\": {\"kind\": \"bytes\"}}, {\"name\": \"status\", \"type\": {\"kind\": \"f64\"}}]},");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"loaded\", \"payload\": {\"kind\": \"record\", \"name\": \"Msg_loaded\"}}",
    );
    const generated = try emitFromJson(arena, source);
    // Declared order preserved exactly: bytes first, number second.
    try testing.expect(std.mem.indexOf(u8, generated, "loaded: struct { body: []const u8, status: f64 },") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "abi.dispatch_record(0,") != null);
}

test "a single-use pattern-named record inlines to mirror the emitted module" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The sidecar carries no synthesized-vs-authored marker
    // (SCHEMA-GAPS.md records the missing fact), so a unique-reference
    // pattern match MUST inline: this is the shape every real
    // anonymous record in the conformance corpus takes, and a named
    // declaration here would fail every fixture's artifact comparison.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Msg_loaded\", \"fields\": [{\"name\": \"status\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"ok\", \"type\": {\"kind\": \"bool\"}}]},");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"loaded\", \"payload\": {\"kind\": \"record\", \"name\": \"Msg_loaded\"}}",
    );
    const generated = try emitFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "loaded: struct { status: f64, ok: bool },") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const Msg_loaded") == null);
}

test "keywords and exotic names are quoted" {
    try testing.expect(!isPlainIdentifier("error"));
    try testing.expect(!isPlainIdentifier("test"));
    try testing.expect(!isPlainIdentifier("u8"));
    try testing.expect(!isPlainIdentifier("1abc"));
    try testing.expect(!isPlainIdentifier("_"));
    try testing.expect(isPlainIdentifier("_x"));
    try testing.expect(isPlainIdentifier("super"));
    try testing.expect(isPlainIdentifier("chatScrollTop"));
}

test "an appearance channel on a wrong-shaped arm refuses with a teaching" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // An enum payload passes the schema's named-type-family rule (V9)
    // but the host cannot build the appearance record into it.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"enums\": []", "\"enums\": [{\"name\": \"Phase\", \"members\": [\"a\", \"b\"]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"enum\", \"name\": \"Phase\"}}",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"appearance_msg\": null", "\"appearance_msg\": \"bump\"");
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emit(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "colorScheme: a light/dark enum") != null) found = true;
    }
    try testing.expect(found);
}
