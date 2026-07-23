//! Sidecar extraction from a compiled-at-comptime core module: reflect
//! a transpiler-emitted core's Model/Msg/helpers/channels into a
//! contract sidecar (core.contract.json, schema format 1).
//!
//! This is the conformance harness's fixture-scale producer. The
//! comparison loop is: transpiled types -> (this extractor) -> sidecar
//! -> (corewire) -> mirror types -> compared against the SAME
//! transpiled types by layout fingerprint and model-contract artifact.
//! Any infidelity in either hop lands in the comparison, because the
//! reference side is the real emitted module, never this extractor's
//! output — so tool-assisted sidecars prove the generator exactly as
//! hand-written ones do, at corpus scale.
//!
//! Identity fields are synthesized deterministically (a fixture sidecar
//! attests no real compile): hashes derive from the entry path and the
//! reflected surface, so re-runs are byte-identical (V13) and a fixture
//! edit moves them.

const std = @import("std");

pub fn emitMain(comptime core: type, comptime entry: []const u8, init: std.process.Init) !void {
    const json = comptime sidecarJson(core, entry);
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        var stderr_buffer: [256]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
        try stderr_writer.interface.print("usage: <extractor> <out path>\n", .{});
        try stderr_writer.interface.flush();
        std.process.exit(2);
    }
    if (std.fs.path.dirname(args[1])) |dir| {
        std.Io.Dir.cwd().createDirPath(init.io, dir) catch {};
    }
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = json });
}

pub fn sidecarJson(comptime core: type, comptime entry: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(20_000_000);

        // ---------------------------------------- phase 1: reach set
        var reach = ReachSet{};
        reach.collect(core.Model, "", "");
        for (@typeInfo(core.Msg).@"union".fields) |arm| {
            if (arm.type == void) continue;
            // The number_bytes family exists so the one ubiquitous
            // inline shape never needs a table entry — skip it here
            // exactly when payloadDescriptor classifies it that way.
            if (isNumberBytesShape(arm.type)) continue;
            reach.collect(arm.type, "Msg", arm.name);
        }
        for (@typeInfo(core.Model).@"struct".decls) |decl| {
            if (helperShape(core.Model, decl.name)) |helper| {
                reach.collect(helper.Return, "helpers", decl.name);
            }
        }

        // ------------------------------------- phase 2: emit sections
        var slots: []const u8 = "";
        var slot_count: usize = 0;

        var structs: []const u8 = "";
        var enums: []const u8 = "";
        var unions: []const u8 = "";
        var struct_count: usize = 0;
        var enum_count: usize = 0;
        var union_count: usize = 0;
        for (reach.entries) |item| {
            switch (@typeInfo(item.T)) {
                .@"struct" => |info| {
                    var fields: []const u8 = "";
                    for (info.fields, 0..) |field, index| {
                        if (index > 0) fields = fields ++ ", ";
                        fields = fields ++ "{\"name\": \"" ++ field.name ++ "\", \"type\": " ++ typeRefJson(field.type, item.name, field.name) ++ "}";
                        if (spellsI64(field.type)) {
                            appendSlot(&slots, &slot_count, item.name ++ "." ++ field.name);
                        }
                    }
                    if (struct_count > 0) structs = structs ++ ",\n      ";
                    structs = structs ++ "{\"name\": \"" ++ item.name ++ "\", \"fields\": [" ++ fields ++ "]}";
                    struct_count += 1;
                },
                .@"enum" => |info| {
                    var members: []const u8 = "";
                    for (info.fields, 0..) |member, index| {
                        if (index > 0) members = members ++ ", ";
                        members = members ++ "\"" ++ member.name ++ "\"";
                    }
                    if (enum_count > 0) enums = enums ++ ",\n      ";
                    enums = enums ++ "{\"name\": \"" ++ item.name ++ "\", \"members\": [" ++ members ++ "]}";
                    enum_count += 1;
                },
                .@"union" => |info| {
                    var arms: []const u8 = "";
                    for (info.fields, 0..) |arm, index| {
                        if (index > 0) arms = arms ++ ", ";
                        const payload = if (arm.type == void) "{\"kind\": \"void\"}" else typeRefJson(arm.type, item.name, arm.name);
                        arms = arms ++ "{\"name\": \"" ++ arm.name ++ "\", \"payload\": " ++ payload ++ "}";
                        if (arm.type != void and spellsI64(arm.type)) {
                            appendSlot(&slots, &slot_count, item.name ++ "." ++ arm.name);
                        }
                    }
                    if (union_count > 0) unions = unions ++ ",\n      ";
                    unions = unions ++ "{\"name\": \"" ++ item.name ++ "\", \"arms\": [" ++ arms ++ "]}";
                    union_count += 1;
                },
                else => @compileError("the type table cannot carry " ++ @typeName(item.T)),
            }
        }

        // Message arms with payload descriptors.
        var msg_arms: []const u8 = "";
        for (@typeInfo(core.Msg).@"union".fields, 0..) |arm, index| {
            if (index > 0) msg_arms = msg_arms ++ ",\n      ";
            const descriptor = payloadDescriptor(arm.type, arm.name, &slots, &slot_count);
            msg_arms = msg_arms ++ "{\"name\": \"" ++ arm.name ++ "\", \"payload\": " ++ descriptor ++ "}";
        }

        // Helpers, in Model-declaration (= export) order.
        var helpers: []const u8 = "";
        var helper_count: usize = 0;
        for (@typeInfo(core.Model).@"struct".decls) |decl| {
            const helper = helperShape(core.Model, decl.name) orelse continue;
            if (helper_count > 0) helpers = helpers ++ ",\n    ";
            var params: []const u8 = "";
            _ = &params; // Transpiled helpers take no extra parameters.
            if (spellsI64(helper.Return)) {
                appendSlot(&slots, &slot_count, "helpers." ++ decl.name ++ ".return");
            }
            helpers = helpers ++ "{\"name\": \"" ++ decl.name ++ "\", \"params\": [" ++ params ++ "], \"returns\": " ++
                typeRefJson(helper.Return, "helpers", decl.name) ++ ", \"arena\": " ++ (if (helper.arena) "true" else "false") ++ "}";
            helper_count += 1;
        }

        const model_unbound = unboundJson(core.Model);
        const msg_unbound = unboundJson(core.Msg);

        // Channels: export presence IS the wiring decision.
        const has_command = @hasDecl(core, "commandMsg");
        const has_frame = @hasDecl(core, "frameMsg");
        const has_key = @hasDecl(core, "keyMsg");
        const has_pinch = @hasDecl(core, "pinchMsg");
        var env_msgs: []const u8 = "";
        if (@hasDecl(core, "envMsgs")) {
            for (core.envMsgs, 0..) |env_entry, index| {
                if (index > 0) env_msgs = env_msgs ++ ", ";
                env_msgs = env_msgs ++ "{\"env\": \"" ++ env_entry.env ++ "\", \"msg\": \"" ++ env_entry.msg ++ "\"}";
            }
        }
        const appearance: []const u8 = if (@hasDecl(core, "appearanceMsg")) "\"" ++ core.appearanceMsg ++ "\"" else "null";
        const chrome: []const u8 = if (@hasDecl(core, "chromeMsg")) "\"" ++ core.chromeMsg ++ "\"" else "null";

        // Entry-shape flags, by return type — the same discrimination
        // the bridge applies to transpiled modules.
        const init_returns_cmd = @typeInfo(@typeInfo(@TypeOf(core.initialModel)).@"fn".return_type.?) != .pointer;
        const update_returns_cmd = @typeInfo(@typeInfo(@TypeOf(core.update)).@"fn".return_type.?) != .pointer;
        const has_subscriptions = @hasDecl(core, "subscriptions");

        var abi_exports: []const u8 =
            "\"abi_version\", \"build_id\", \"set_panic_sink\", \"init\", \"boot_cmd\", " ++
            "\"dispatch_void\", \"dispatch_bytes\", \"dispatch_number\", \"dispatch_number_bytes\", " ++
            "\"dispatch_bool\", \"dispatch_enum\", \"dispatch_record\", \"dispatch_text_input\", " ++
            "\"dispatch_scroll_state\", \"subscriptions\", \"frame_reset\", \"model_snapshot\", " ++
            "\"helper_call\", \"collect\"";
        if (has_command) abi_exports = abi_exports ++ ", \"command_msg\"";
        if (has_frame) abi_exports = abi_exports ++ ", \"frame_msg\"";
        if (has_key) abi_exports = abi_exports ++ ", \"key_msg\"";
        if (has_pinch) abi_exports = abi_exports ++ ", \"pinch_msg\"";

        const types_json =
            "{\n    \"structs\": [\n      " ++ structs ++ "\n    ],\n" ++
            "    \"enums\": [\n      " ++ enums ++ "\n    ],\n" ++
            "    \"unions\": [\n      " ++ unions ++ "\n    ]\n  }";

        // Deterministic synthesized identity: the fixture has no real
        // compile behind it, so hash the entry path and the reflected
        // surface (a fixture edit moves both values; re-runs reproduce
        // them exactly).
        const surface = types_json ++ msg_arms ++ helpers;
        const source_hash = std.hash.Wyhash.hash(0x5eed_c0de, entry);
        const build_id = std.hash.Wyhash.hash(0xb11d1d00, entry ++ surface);

        return "{\n" ++
            "  \"format\": 1,\n" ++
            "  \"wire_version\": 3,\n" ++
            "  \"abi_version\": 1,\n" ++
            "  \"compiler_version\": \"0.0.1\",\n" ++
            "  \"entry\": \"" ++ entry ++ "\",\n" ++
            "  \"source_hash\": \"" ++ std.fmt.comptimePrint("{x:0>16}", .{source_hash}) ++ "\",\n" ++
            "  \"build_id\": \"" ++ std.fmt.comptimePrint("{x:0>16}", .{build_id}) ++ "\",\n" ++
            "  \"types\": " ++ types_json ++ ",\n" ++
            "  \"model\": \"Model\",\n" ++
            "  \"model_helpers\": [" ++ (if (helper_count > 0) "\n    " ++ helpers ++ "\n  " else "") ++ "],\n" ++
            "  \"model_unbound\": [" ++ model_unbound ++ "],\n" ++
            "  \"msg\": {\n    \"name\": \"Msg\",\n    \"arms\": [\n      " ++ msg_arms ++ "\n    ],\n    \"unbound\": [" ++ msg_unbound ++ "]\n  },\n" ++
            "  \"init_returns_cmd\": " ++ boolJson(init_returns_cmd) ++ ",\n" ++
            "  \"update_returns_cmd\": " ++ boolJson(update_returns_cmd) ++ ",\n" ++
            "  \"has_subscriptions\": " ++ boolJson(has_subscriptions) ++ ",\n" ++
            "  \"channels\": {\n" ++
            "    \"command_msg\": " ++ boolJson(has_command) ++ ",\n" ++
            "    \"frame_msg\": " ++ boolJson(has_frame) ++ ",\n" ++
            "    \"key_msg\": " ++ boolJson(has_key) ++ ",\n" ++
            "    \"pinch_msg\": " ++ boolJson(has_pinch) ++ ",\n" ++
            "    \"appearance_msg\": " ++ appearance ++ ",\n" ++
            "    \"chrome_msg\": " ++ chrome ++ ",\n" ++
            "    \"env_msgs\": [" ++ env_msgs ++ "]\n" ++
            "  },\n" ++
            "  \"abi\": {\n    \"prefix\": \"nsc_core_\",\n    \"exports\": [" ++ abi_exports ++ "],\n    \"snapshot_format\": 1\n  },\n" ++
            "  \"integer_slots\": [" ++ (if (slot_count > 0) "\n    " ++ slots ++ "\n  " else "") ++ "],\n" ++
            "  \"deterministic\": true,\n" ++
            "  \"async_free\": true\n" ++
            "}\n";
    }
}

fn boolJson(comptime value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn appendSlot(comptime slots: *[]const u8, comptime count: *usize, comptime path: []const u8) void {
    if (count.* > 0) slots.* = slots.* ++ ",\n    ";
    slots.* = slots.* ++ "{\"slot\": \"" ++ path ++ "\", \"class\": \"i64\"}";
    count.* += 1;
}

/// Whether a mirror type spells i64 at its own slot (through
/// optionals). Slice elements have no slot-path grammar in schema v1
/// and are not attested.
fn spellsI64(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => T == i64,
        .optional => |info| spellsI64(info.child),
        else => false,
    };
}

const HelperShape = struct { Return: type, arena: bool };

/// Classify a Model decl as an exported helper: the zero-extra-arg form
/// `fn (*const Model) V` or the build-arena form
/// `fn (*const Model, std.mem.Allocator) V` — exactly the method shapes
/// the transpiler forwards onto Model.
fn helperShape(comptime Model: type, comptime decl_name: []const u8) ?HelperShape {
    const DeclType = @TypeOf(@field(Model, decl_name));
    const info = switch (@typeInfo(DeclType)) {
        .@"fn" => |fn_info| fn_info,
        else => return null,
    };
    if (info.params.len == 0 or info.params[0].type != *const Model) return null;
    if (info.return_type == null) return null;
    if (info.params.len == 1) return .{ .Return = info.return_type.?, .arena = false };
    if (info.params.len == 2 and info.params[1].type == std.mem.Allocator) {
        return .{ .Return = info.return_type.?, .arena = true };
    }
    return null;
}

fn unboundJson(comptime T: type) []const u8 {
    comptime {
        if (!@hasDecl(T, "view_unbound")) return "";
        var out: []const u8 = "";
        for (T.view_unbound, 0..) |name, index| {
            if (index > 0) out = out ++ ", ";
            out = out ++ "\"" ++ name ++ "\"";
        }
        return out;
    }
}

fn lastComponent(comptime full: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, full, '.')) |dot| return full[dot + 1 ..];
    return full;
}

/// The table name of a named or synthesized type at a reference site:
/// anonymous records take the schema's deterministic
/// `<Container>_<member>` pattern, named types keep the author's
/// spelling.
fn tableName(comptime T: type, comptime container: []const u8, comptime member: []const u8) []const u8 {
    const last = lastComponent(@typeName(T));
    if (std.mem.indexOf(u8, last, "__struct_") != null or std.mem.indexOf(u8, last, "__union_") != null) {
        return container ++ "_" ++ member;
    }
    return last;
}

fn isBytes(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |info| info.size == .slice and info.child == u8,
        else => false,
    };
}

/// The TypeRef JSON of a mirror type at a reference site (phase 2:
/// naming only; the reach set already carries every referenced entry).
fn typeRefJson(comptime T: type, comptime container: []const u8, comptime member: []const u8) []const u8 {
    if (T == bool) return "{\"kind\": \"bool\"}";
    if (T == f64) return "{\"kind\": \"f64\"}";
    if (T == i64) return "{\"kind\": \"i64\"}";
    if (isBytes(T)) return "{\"kind\": \"bytes\"}";
    switch (@typeInfo(T)) {
        .optional => |info| return "{\"kind\": \"optional\", \"inner\": " ++ typeRefJson(info.child, container, member) ++ "}",
        .pointer => |info| switch (info.size) {
            .slice => return "{\"kind\": \"slice\", \"elem\": " ++ typeRefJson(info.child, container, member) ++ "}",
            .one => return "{\"kind\": \"node\", \"name\": \"" ++ tableName(info.child, container, member) ++ "\"}",
            else => @compileError("no TypeRef form for " ++ @typeName(T)),
        },
        .@"struct" => return "{\"kind\": \"value\", \"name\": \"" ++ tableName(T, container, member) ++ "\"}",
        .@"enum" => return "{\"kind\": \"enum\", \"name\": \"" ++ tableName(T, container, member) ++ "\"}",
        .@"union" => return "{\"kind\": \"union\", \"name\": \"" ++ tableName(T, container, member) ++ "\"}",
        else => @compileError("no TypeRef form for " ++ @typeName(T)),
    }
}

/// The anonymous two-field number-plus-bytes record, in its emitted
/// field order (number first) — the shape the number_bytes descriptor
/// family carries without a table entry.
fn isNumberBytesShape(comptime T: type) bool {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => return false,
    };
    const anonymous = std.mem.indexOf(u8, lastComponent(@typeName(T)), "__struct_") != null;
    return anonymous and info.fields.len == 2 and
        (info.fields[0].type == f64 or info.fields[0].type == i64) and
        isBytes(info.fields[1].type);
}

/// The payload descriptor of one Msg arm, collecting integer slots for
/// the number-carrying families.
fn payloadDescriptor(comptime T: type, comptime arm_name: []const u8, comptime slots: *[]const u8, comptime slot_count: *usize) []const u8 {
    if (T == void) return "{\"kind\": \"void\"}";
    if (isBytes(T)) return "{\"kind\": \"bytes\"}";
    if (T == f64) return "{\"kind\": \"number\", \"class\": \"f64\"}";
    if (T == i64) {
        appendSlot(slots, slot_count, "Msg." ++ arm_name);
        return "{\"kind\": \"number\", \"class\": \"i64\"}";
    }
    if (T == bool) return "{\"kind\": \"scalar\", \"type\": {\"kind\": \"bool\"}}";
    switch (@typeInfo(T)) {
        .@"enum" => return "{\"kind\": \"enum\", \"name\": \"" ++ tableName(T, "Msg", arm_name) ++ "\"}",
        .@"union" => return "{\"kind\": \"union\", \"name\": \"" ++ tableName(T, "Msg", arm_name) ++ "\"}",
        .@"struct" => |info| {
            // The ubiquitous inline number-plus-bytes shape (fetch
            // {status, body}, collect-spawn {code, output}) rides the
            // dedicated two-field family instead of a synthesized
            // table entry — but only in its emitted field order
            // (number first); anything else stays a tabled record.
            if (isNumberBytesShape(T)) {
                const class = if (info.fields[0].type == i64) "i64" else "f64";
                if (info.fields[0].type == i64) {
                    appendSlot(slots, slot_count, "Msg." ++ arm_name ++ "." ++ info.fields[0].name);
                }
                return "{\"kind\": \"number_bytes\", \"number_field\": \"" ++ info.fields[0].name ++
                    "\", \"number_class\": \"" ++ class ++ "\", \"bytes_field\": \"" ++ info.fields[1].name ++ "\"}";
            }
            return "{\"kind\": \"record\", \"name\": \"" ++ tableName(T, "Msg", arm_name) ++ "\"}";
        },
        else => @compileError("no payload descriptor for Msg arm payload " ++ @typeName(T)),
    }
}

// ------------------------------------------------- phase 1: reach set

const ReachEntry = struct { T: type, name: []const u8 };

const ReachSet = struct {
    entries: []const ReachEntry = &.{},

    fn listed(comptime self: *const ReachSet, comptime T: type) bool {
        for (self.entries) |item| {
            if (item.T == T) return true;
        }
        return false;
    }

    /// Add every table-worthy type reachable from `T`, in first-visit
    /// order (deterministic; table order carries no meaning for a
    /// mirror — Zig declarations are order-free — and V4/V6 order
    /// checks are the emitter's, requiring the source).
    fn collect(comptime self: *ReachSet, comptime T: type, comptime container: []const u8, comptime member: []const u8) void {
        if (T == bool or T == f64 or T == i64 or isBytes(T)) return;
        switch (@typeInfo(T)) {
            .optional => |info| self.collect(info.child, container, member),
            .pointer => |info| switch (info.size) {
                .slice, .one => self.collect(info.child, container, member),
                else => @compileError("unreachable table shape " ++ @typeName(T)),
            },
            .@"struct" => |info| {
                if (self.listed(T)) return;
                const name = tableName(T, container, member);
                self.entries = self.entries ++ &[_]ReachEntry{.{ .T = T, .name = name }};
                for (info.fields) |field| self.collect(field.type, name, field.name);
            },
            .@"union" => |info| {
                if (self.listed(T)) return;
                const name = tableName(T, container, member);
                self.entries = self.entries ++ &[_]ReachEntry{.{ .T = T, .name = name }};
                for (info.fields) |field| {
                    if (field.type == void) continue;
                    self.collect(field.type, name, field.name);
                }
            },
            .@"enum" => {
                if (self.listed(T)) return;
                self.entries = self.entries ++ &[_]ReachEntry{.{ .T = T, .name = tableName(T, container, member) }};
            },
            else => @compileError("unreachable table shape " ++ @typeName(T)),
        }
    }
};

// --------------------------------------------------------------- tests

const testing = std.testing;

test "extraction of a small core produces a valid sidecar" {
    const Core = struct {
        pub const Role = enum(u8) { user = 0, assistant = 1 };
        pub const Turn = struct { id: i64, role: Role, text: []const u8 };
        pub const Model = struct {
            turns: []const *const Turn,
            nextId: i64,
            title: []const u8,

            pub fn turnCount(self: *const Model) i64 {
                return @intCast(self.turns.len);
            }
            pub const view_unbound = .{"nextId"};
        };
        pub const Msg = union(enum) {
            bump,
            rename: []const u8,
            fetched: struct { status: i64, body: []const u8 },
            role_set: Role,
        };
        pub const envMsgs = .{
            .{ .env = "APP_TITLE", .msg = "rename" },
        };
        pub fn initialModel() *const Model {
            unreachable;
        }
        pub const UpdateResult = struct { model: *const Model, cmd: []const u8 };
        pub fn update(model: *const Model, msg: Msg) UpdateResult {
            _ = model;
            _ = msg;
            unreachable;
        }
    };

    const json = comptime sidecarJson(Core, "src/core.ts");

    // The extracted document must satisfy the reader end to end.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sidecar_mod = @import("sidecar.zig");
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const sidecar = sidecar_mod.read(arena, json, &diags) catch |err| {
        for (diags.list.items) |item| {
            std.debug.print("  [{s}] {s}: {s}\n", .{ @tagName(item.severity), item.path, item.message });
        }
        return err;
    };
    try testing.expectEqualStrings("Model", sidecar.model);
    try testing.expectEqual(@as(usize, 4), sidecar.msg.arms.len);
    try testing.expect(sidecar.msg.arms[2].payload == .number_bytes);
    try testing.expectEqualStrings("status", sidecar.msg.arms[2].payload.number_bytes.number_field);
    try testing.expectEqual(@as(usize, 1), sidecar.model_helpers.len);
    try testing.expect(!sidecar.init_returns_cmd);
    try testing.expect(sidecar.update_returns_cmd);
    try testing.expect(!sidecar.has_subscriptions);
    try testing.expectEqual(@as(usize, 1), sidecar.channels.env_msgs.len);

    // Determinism: a second evaluation is byte-identical.
    try testing.expectEqualStrings(json, comptime sidecarJson(Core, "src/core.ts"));
}
