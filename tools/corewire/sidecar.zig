//! The contract-sidecar reader: parse `core.contract.json` (schema
//! format 1) into a typed value and validate it against the schema's
//! rules (V1-V14, as far as a reader can check them without the compiled
//! object in hand).
//!
//! The sidecar is the machine-readable contract a core-mode compile
//! emits beside the compiled object: the exported state type, the
//! message union with declaration-order wire tags, helper signatures,
//! channel declarations, and build identity. Its only consumers are the
//! shim generator (emit.zig turns it into a Zig mirror module) and the
//! checker; both refuse a malformed or unknown-generation sidecar
//! outright at tool time, with a teaching that names the exact field
//! path — never a silent skew that surfaces as wrong dispatch at
//! runtime.
//!
//! Forward compatibility (reader side, normative):
//! - Unknown FIELDS anywhere are ignored with a one-line warning naming
//!   the field, so additive emitter-side facts can ship before this
//!   reader learns them.
//! - An unknown `format` is refused whole-file: no partial reads of an
//!   unknown schema.
//! - An unknown enum VALUE inside a known field (a TypeRef kind, a
//!   payload-descriptor kind, a number class) is refused whole-file:
//!   half-understanding a message arm is how wrong dispatch ships.
//!
//! Native owns structural decoding. Semantic admission is compiled from
//! TypeScript and tested with the same host archive the generator uses.

const std = @import("std");

/// The sidecar schema generation this reader implements.
pub const supported_format: i64 = 1;

/// The command-wire vocabulary generation the SDK's bridge speaks
/// (rt.zig `cmd_format_version`). A sidecar declaring a different
/// generation is refused at generate time.
pub const supported_wire_version: i64 = 7;

/// The C-ABI generation of the core entry points this generator binds
/// (core_abi.zig `abi_version`).
pub const supported_abi_version: i64 = 2;

/// The snapshot-encoding generation the generated decoder implements.
pub const supported_snapshot_format: i64 = 1;

// ------------------------------------------------------------- schema

pub const TypeRef = union(enum) {
    bool,
    f64,
    i64,
    bytes,
    void,
    optional: *const TypeRef,
    slice: *const TypeRef,
    /// A named record stored by reference (`*const T` in the mirror).
    node: []const u8,
    /// A named record stored by value, inline.
    value: []const u8,
    enum_ref: []const u8,
    union_ref: []const u8,

    pub fn jsonStringify(self: TypeRef, json: *std.json.Stringify) !void {
        try json.beginObject();
        try json.objectField("kind");
        try json.write(switch (self) {
            .enum_ref => "enum",
            .union_ref => "union",
            else => @tagName(self),
        });
        switch (self) {
            .optional => |inner| {
                try json.objectField("inner");
                try json.write(inner.*);
            },
            .slice => |elem| {
                try json.objectField("elem");
                try json.write(elem.*);
            },
            .node, .value, .enum_ref, .union_ref => |name| {
                try json.objectField("name");
                try json.write(name);
            },
            else => {},
        }
        try json.endObject();
    }
};

pub const Field = struct {
    name: []const u8,
    type: TypeRef,
};

pub const Struct = struct {
    name: []const u8,
    /// The declaring module of the type, entry-relative (an additive
    /// origin fact; null on sidecars that predate it and for
    /// synthesized names, which are declared nowhere).
    origin: ?[]const u8 = null,
    /// Whether the declaring module exports this table designation under
    /// its own name. Absent on older sidecars, where true preserves the
    /// historical import/re-export behavior.
    exported: bool = true,
    fields: []const Field,
};

pub const Enum = struct {
    name: []const u8,
    origin: ?[]const u8 = null,
    exported: bool = true,
    members: []const []const u8,
};

pub const UnionArm = struct {
    name: []const u8,
    /// The authored member name of a single-payload arm (an additive
    /// fact; the payload descriptor erases the author's spelling, and a
    /// consumer constructing arm values needs it back). Null for bare
    /// and multi-field arms, and on sidecars that predate the fact.
    member: ?[]const u8 = null,
    payload: TypeRef,
};

pub const Union = struct {
    name: []const u8,
    origin: ?[]const u8 = null,
    exported: bool = true,
    arms: []const UnionArm,
};

pub const Types = struct {
    structs: []const Struct,
    enums: []const Enum,
    unions: []const Union,
};

pub const NumberClass = enum { f64, i64 };

/// The closed v1 payload-descriptor family for message arms.
pub const Payload = union(enum) {
    void,
    bytes,
    number: NumberClass,
    number_bytes: struct {
        number_field: []const u8,
        number_class: NumberClass,
        bytes_field: []const u8,
    },
    record: []const u8,
    union_ref: []const u8,
    enum_ref: []const u8,
    scalar: TypeRef,

    pub fn jsonStringify(self: Payload, json: *std.json.Stringify) !void {
        try json.beginObject();
        try json.objectField("kind");
        try json.write(@tagName(self));
        switch (self) {
            .number => |class| {
                try json.objectField("class");
                try json.write(@tagName(class));
            },
            .number_bytes => |desc| {
                try json.objectField("number_field");
                try json.write(desc.number_field);
                try json.objectField("number_class");
                try json.write(@tagName(desc.number_class));
                try json.objectField("bytes_field");
                try json.write(desc.bytes_field);
            },
            .record, .union_ref, .enum_ref => |name| {
                try json.objectField("name");
                try json.write(name);
            },
            .scalar => |ref| {
                try json.objectField("type");
                try json.write(ref);
            },
            else => {},
        }
        try json.endObject();
    }
};

pub const MsgArm = struct {
    name: []const u8,
    /// The authored member name of a single-payload arm (see
    /// UnionArm.member).
    member: ?[]const u8 = null,
    payload: Payload,
};

pub const Msg = struct {
    name: []const u8,
    arms: []const MsgArm,
    unbound: []const []const u8,
};

pub const Helper = struct {
    name: []const u8,
    params: []const TypeRef,
    returns: TypeRef,
    arena: bool,
};

pub const EnvMsg = struct {
    env: []const u8,
    msg: []const u8,
};

pub const Channels = struct {
    command_msg: bool,
    frame_msg: bool,
    key_msg: bool,
    pinch_msg: bool,
    drop_msg: bool,
    appearance_msg: ?[]const u8,
    chrome_msg: ?[]const u8,
    env_msgs: []const EnvMsg,
};

pub const Abi = struct {
    prefix: []const u8,
    exports: []const []const u8,
    snapshot_format: i64,
};

/// The resolved integer class an `integer_slots` entry attests. The
/// type table's one integer spelling is `i64`; the attestation refines
/// it — `u64` marks the slot's wire bytes as the unsigned twin (8-byte
/// unsigned LE instead of two's complement). `f64` never appears here:
/// it is the default class and is never attested.
pub const IntegerClass = enum { i64, u64 };

pub const IntegerSlot = struct {
    slot: []const u8,
    class: IntegerClass,
};

pub const Sidecar = struct {
    format: i64,
    wire_version: i64,
    abi_version: i64,
    compiler_version: []const u8,
    entry: []const u8,
    source_hash: u64,
    build_id: u64,
    /// Hash of the Model-reachable type graph only. Unlike build_id, Msg,
    /// channel, and helper-only edits do not move this persistence fence.
    model_fingerprint: u64,
    types: Types,
    model: []const u8,
    model_helpers: []const Helper,
    model_unbound: []const []const u8,
    msg: Msg,
    init_returns_cmd: bool,
    update_returns_cmd: bool,
    /// Whether initialModel/update may ALSO return the bare model (the
    /// documented mixed idiom, `Model | [Model, Cmd<Msg>]`). Additive,
    /// frontend-emitted facts: absent (an older document, or a
    /// compiler's co-emitted sidecar) means the pair shape is
    /// unconditional. The facade emitter keys its wrapper on them.
    init_returns_bare: bool = false,
    update_returns_bare: bool = false,
    has_subscriptions: bool,
    has_migrate: bool,
    channels: Channels,
    abi: Abi,
    integer_slots: []const IntegerSlot,
    deterministic: bool,
    async_free: bool,
};

// ----------------------------------------------------- ABI vocabulary

/// The unconditional export suffixes of ABI version 2, in the NORMATIVE
/// canonical order the sidecar's `abi.exports` must list them: the two
/// identity getters, then the mode-provided entries (sink registration,
/// init, collect, result reset), then the program's entry-point map
/// (core_abi.zig binds the matching extern signatures). The five
/// conditional channel-entry suffixes follow, present exactly when the
/// matching channel is wired, then the optional compiled view extensions.
pub const unconditional_exports = [_][]const u8{
    "abi_version",
    "build_id",
    "set_panic_sink",
    "init",
    "collect",
    "frame_reset",
    "boot_cmd",
    "dispatch_void",
    "dispatch_bytes",
    "dispatch_number",
    "dispatch_number_bytes",
    "dispatch_bool",
    "dispatch_enum",
    "dispatch_record",
    "dispatch_text_input",
    "dispatch_scroll_state",
    "subscriptions",
    "model_snapshot",
    "persist_snapshot",
    "restore_model",
    "migrate_model",
    "helper_call",
};

pub const conditional_exports = [_][]const u8{
    "command_msg",
    "frame_msg",
    "key_msg",
    "pinch_msg",
    "drop_msg",
    // Native SDK's opt-in compiled-view extension, after function channels.
    "native_view",
    "native_window_view",
    "native_radio_policy",
    "native_tabs_policy",
    "native_tree_policy",
    "native_list_policy",
    "native_menu_policy",
    "native_toggle_policy",
    "native_accordion_policy",
    "native_slider_policy",
    "native_split_policy",
    "native_scroll_policy",
    "native_resizable_policy",
    "native_text_policy",
    "native_timer_policy",
    "native_db_policy",
    "native_effect_policy",
    "native_stream_policy",
    "native_window_policy",
    "native_theme_policy",
    "native_status_policy",
};

// ------------------------------------------------------------ reading

pub const max_sidecar_bytes: usize = 16 * 1024 * 1024;

/// A refusal or warning, carried with the exact field path it names.
pub const Diagnostic = struct {
    /// Dotted/indexed path into the document ("msg.arms[4].payload").
    path: []const u8,
    message: []const u8,
    severity: enum { @"error", warning },
};

pub const Diagnostics = struct {
    arena: std.mem.Allocator,
    list: std.ArrayListUnmanaged(Diagnostic) = .empty,

    pub fn fail(self: *Diagnostics, path: []const u8, comptime fmt: []const u8, args: anytype) error{Refused} {
        self.push(.@"error", path, fmt, args);
        return error.Refused;
    }

    /// Record a refusal without unwinding, so validation can surface
    /// every finding of a pass instead of only the first.
    pub fn flag(self: *Diagnostics, path: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.push(.@"error", path, fmt, args);
    }

    pub fn warn(self: *Diagnostics, path: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.push(.warning, path, fmt, args);
    }

    fn push(self: *Diagnostics, severity: @FieldType(Diagnostic, "severity"), path: []const u8, comptime fmt: []const u8, args: anytype) void {
        // A diagnostic that cannot be recorded must never vanish — a
        // dropped refusal would let a malformed sidecar read as clean.
        // The tool runs on an arena; exhaustion here is terminal.
        const oom = "corewire: out of memory while recording a diagnostic";
        const message = std.fmt.allocPrint(self.arena, fmt, args) catch @panic(oom);
        const owned_path = self.arena.dupe(u8, path) catch @panic(oom);
        self.list.append(self.arena, .{ .path = owned_path, .message = message, .severity = severity }) catch @panic(oom);
    }

    pub fn hasErrors(self: *const Diagnostics) bool {
        for (self.list.items) |item| {
            if (item.severity == .@"error") return true;
        }
        return false;
    }

    pub fn write(self: *const Diagnostics, file_label: []const u8, writer: *std.Io.Writer) !void {
        for (self.list.items) |item| {
            const tag = switch (item.severity) {
                .@"error" => "error",
                .warning => "warning",
            };
            if (item.path.len > 0) {
                try writer.print("{s}: {s}: {s}: {s}\n", .{ file_label, tag, item.path, item.message });
            } else {
                try writer.print("{s}: {s}: {s}\n", .{ file_label, tag, item.message });
            }
        }
    }
};

/// Parse and validate a sidecar document. On `error.Refused` the
/// diagnostics carry every teaching; the caller prints them and stops.
/// All returned memory lives in the caller's arena.
pub fn read(arena: std.mem.Allocator, source: []const u8, diags: *Diagnostics) error{ Refused, OutOfMemory }!Sidecar {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{}) catch |err| switch (err) {
        // Memory pressure is not malformed input; keep the contract's
        // error meanings honest.
        error.OutOfMemory => return error.OutOfMemory,
        else => return diags.fail("", "the sidecar is not valid JSON — it should be the core.contract.json a core-mode compile writes beside the compiled object", .{}),
    };
    var mapper = Mapper{ .arena = arena, .diags = diags };
    const sidecar = try mapper.mapRoot(root);
    try validate(arena, sidecar, diags);
    if (diags.hasErrors()) return error.Refused;
    return sidecar;
}

// ------------------------------------------------- JSON -> schema map

const Mapper = struct {
    arena: std.mem.Allocator,
    diags: *Diagnostics,

    fn path(self: *Mapper, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.arena, fmt, args) catch "";
    }

    fn object(self: *Mapper, value: std.json.Value, at: []const u8) error{ Refused, OutOfMemory }!std.json.ObjectMap {
        return switch (value) {
            .object => |o| o,
            else => self.diags.fail(at, "expected an object, found {s}", .{jsonKindName(value)}),
        };
    }

    fn array(self: *Mapper, value: std.json.Value, at: []const u8) error{ Refused, OutOfMemory }!std.json.Array {
        return switch (value) {
            .array => |a| a,
            else => self.diags.fail(at, "expected an array, found {s}", .{jsonKindName(value)}),
        };
    }

    fn string(self: *Mapper, value: std.json.Value, at: []const u8) error{ Refused, OutOfMemory }![]const u8 {
        return switch (value) {
            .string => |s| s,
            else => self.diags.fail(at, "expected a string, found {s}", .{jsonKindName(value)}),
        };
    }

    /// The ABI prefix rides straight into exported symbol spellings
    /// (`@extern` names, linker entries), so it must be a symbol-safe
    /// spelling: ASCII letters, digits, and underscores, not starting
    /// with a digit. Anything else (an embedded NUL, unicode, spaces)
    /// cannot be represented faithfully as an object-file symbol name.
    fn symbolPrefix(self: *Mapper, value: std.json.Value, at: []const u8) error{ Refused, OutOfMemory }![]const u8 {
        const text = try self.nonEmptyString(value, at);
        for (text, 0..) |byte, index| {
            const ok = byte == '_' or std.ascii.isAlphabetic(byte) or (index > 0 and std.ascii.isDigit(byte));
            if (!ok) {
                return self.diags.fail(at, "byte 0x{x:0>2} at offset {d} cannot appear in a linker symbol name — the prefix is spelled verbatim into every exported symbol; use ASCII letters, digits, and underscores, not starting with a digit", .{ byte, index });
            }
        }
        return text;
    }

    fn nonEmptyString(self: *Mapper, value: std.json.Value, at: []const u8) error{ Refused, OutOfMemory }![]const u8 {
        const text = try self.string(value, at);
        if (text.len == 0) return self.diags.fail(at, "expected a non-empty string", .{});
        return text;
    }

    fn boolean(self: *Mapper, value: std.json.Value, at: []const u8) error{ Refused, OutOfMemory }!bool {
        return switch (value) {
            .bool => |flag| flag,
            else => self.diags.fail(at, "expected true or false, found {s}", .{jsonKindName(value)}),
        };
    }

    fn integer(self: *Mapper, value: std.json.Value, at: []const u8) error{ Refused, OutOfMemory }!i64 {
        return switch (value) {
            .integer => |int| int,
            else => self.diags.fail(at, "expected an integer, found {s}", .{jsonKindName(value)}),
        };
    }

    /// 64-bit hashes ride as strings of exactly 16 lowercase hex digits
    /// (JSON interchange cannot carry a u64 exactly) — V2.
    fn hash64(self: *Mapper, value: std.json.Value, at: []const u8) error{ Refused, OutOfMemory }!u64 {
        const text = switch (value) {
            .string => |s| s,
            .integer, .float => return self.diags.fail(at, "64-bit hashes are encoded as strings of exactly 16 lowercase hex digits, never JSON numbers (JSON cannot carry a u64 exactly)", .{}),
            else => return self.diags.fail(at, "expected a 16-lowercase-hex-digit string, found {s}", .{jsonKindName(value)}),
        };
        if (text.len != 16) {
            return self.diags.fail(at, "expected exactly 16 lowercase hex digits, found {d} characters (\"{s}\")", .{ text.len, text });
        }
        for (text) |char| {
            const ok = (char >= '0' and char <= '9') or (char >= 'a' and char <= 'f');
            if (!ok) return self.diags.fail(at, "expected lowercase hex digits only, found '{c}' in \"{s}\"", .{ char, text });
        }
        return std.fmt.parseInt(u64, text, 16) catch unreachable;
    }

    /// An OPTIONAL nonempty-string member: null when absent (additive
    /// facts older emitters do not write), refused when present but not
    /// a nonempty string.
    fn optionalString(self: *Mapper, map: std.json.ObjectMap, name: []const u8, at: []const u8) error{ Refused, OutOfMemory }!?[]const u8 {
        const value = map.get(name) orelse return null;
        return try self.nonEmptyString(value, self.path("{s}.{s}", .{ at, name }));
    }

    /// An additive boolean member with its compatibility default.
    fn optionalBoolean(self: *Mapper, map: std.json.ObjectMap, name: []const u8, at: []const u8, default: bool) error{ Refused, OutOfMemory }!bool {
        const value = map.get(name) orelse return default;
        return try self.boolean(value, self.path("{s}.{s}", .{ at, name }));
    }

    fn stringList(self: *Mapper, value: std.json.Value, at: []const u8) error{ Refused, OutOfMemory }![]const []const u8 {
        const items = try self.array(value, at);
        const out = try self.arena.alloc([]const u8, items.items.len);
        for (items.items, 0..) |item, index| {
            out[index] = try self.nonEmptyString(item, self.path("{s}[{d}]", .{ at, index }));
        }
        return out;
    }

    /// Fetch a required member; warn about (and skip) unknown members —
    /// the additive forward-compat rule.
    const Members = struct {
        mapper: *Mapper,
        map: std.json.ObjectMap,
        at: []const u8,
        known: []const []const u8,

        fn get(self: *const Members, name: []const u8) error{ Refused, OutOfMemory }!std.json.Value {
            return self.map.get(name) orelse self.mapper.diags.fail(
                self.mapper.path("{s}{s}{s}", .{ self.at, if (self.at.len > 0) "." else "", name }),
                "required field missing",
                .{},
            );
        }

        fn warnUnknown(self: *const Members) void {
            var it = self.map.iterator();
            outer: while (it.next()) |entry| {
                for (self.known) |name| {
                    if (std.mem.eql(u8, entry.key_ptr.*, name)) continue :outer;
                }
                self.mapper.diags.warn(
                    self.mapper.path("{s}{s}{s}", .{ self.at, if (self.at.len > 0) "." else "", entry.key_ptr.* }),
                    "unknown field ignored (an emitter newer than this reader may emit additive facts)",
                    .{},
                );
            }
        }
    };

    fn members(self: *Mapper, value: std.json.Value, at: []const u8, known: []const []const u8) error{ Refused, OutOfMemory }!Members {
        return .{ .mapper = self, .map = try self.object(value, at), .at = at, .known = known };
    }

    fn mapRoot(self: *Mapper, value: std.json.Value) error{ Refused, OutOfMemory }!Sidecar {
        const top = try self.members(value, "", &.{
            "format",            "wire_version",        "abi_version",       "compiler_version", "entry",
            "source_hash",       "build_id",            "model_fingerprint", "types",            "model",
            "model_helpers",     "model_unbound",       "msg",               "init_returns_cmd", "update_returns_cmd",
            "init_returns_bare", "update_returns_bare", "has_subscriptions", "has_migrate",      "channels",
            "abi",               "integer_slots",       "deterministic",     "async_free",
        });
        top.warnUnknown();

        // The format fence comes first: nothing else in an unknown
        // generation may be half-read.
        const format = try self.integer(try top.get("format"), "format");
        if (format != supported_format) {
            return self.diags.fail("format", "this reader implements sidecar format {d}, found {d} — upgrade the SDK tooling or pin the compiler release that matches it", .{ supported_format, format });
        }

        const abi = try self.mapAbi(try top.get("abi"));
        const channels = try self.mapChannels(try top.get("channels"), abiHasExport(abi, "drop_msg"));
        return .{
            .format = format,
            .wire_version = try self.integer(try top.get("wire_version"), "wire_version"),
            .abi_version = try self.integer(try top.get("abi_version"), "abi_version"),
            .compiler_version = try self.nonEmptyString(try top.get("compiler_version"), "compiler_version"),
            .entry = try self.nonEmptyString(try top.get("entry"), "entry"),
            .source_hash = try self.hash64(try top.get("source_hash"), "source_hash"),
            .build_id = try self.hash64(try top.get("build_id"), "build_id"),
            .model_fingerprint = try self.hash64(try top.get("model_fingerprint"), "model_fingerprint"),
            .types = try self.mapTypes(try top.get("types")),
            .model = try self.nonEmptyString(try top.get("model"), "model"),
            .model_helpers = try self.mapHelpers(try top.get("model_helpers")),
            .model_unbound = try self.stringList(try top.get("model_unbound"), "model_unbound"),
            .msg = try self.mapMsg(try top.get("msg")),
            .init_returns_cmd = try self.boolean(try top.get("init_returns_cmd"), "init_returns_cmd"),
            .update_returns_cmd = try self.boolean(try top.get("update_returns_cmd"), "update_returns_cmd"),
            .init_returns_bare = try self.optionalBoolean(top.map, "init_returns_bare", "", false),
            .update_returns_bare = try self.optionalBoolean(top.map, "update_returns_bare", "", false),
            .has_subscriptions = try self.boolean(try top.get("has_subscriptions"), "has_subscriptions"),
            .has_migrate = try self.boolean(try top.get("has_migrate"), "has_migrate"),
            .channels = channels,
            .abi = abi,
            .integer_slots = try self.mapIntegerSlots(try top.get("integer_slots")),
            .deterministic = try self.boolean(try top.get("deterministic"), "deterministic"),
            .async_free = try self.boolean(try top.get("async_free"), "async_free"),
        };
    }

    fn mapTypes(self: *Mapper, value: std.json.Value) error{ Refused, OutOfMemory }!Types {
        const table = try self.members(value, "types", &.{ "structs", "enums", "unions" });
        table.warnUnknown();
        return .{
            .structs = try self.mapStructs(try table.get("structs")),
            .enums = try self.mapEnums(try table.get("enums")),
            .unions = try self.mapUnions(try table.get("unions")),
        };
    }

    fn mapStructs(self: *Mapper, value: std.json.Value) error{ Refused, OutOfMemory }![]const Struct {
        const items = try self.array(value, "types.structs");
        const out = try self.arena.alloc(Struct, items.items.len);
        for (items.items, 0..) |item, index| {
            const at = self.path("types.structs[{d}]", .{index});
            // "synthesized" is an additive marker some emitters place on
            // records they named themselves. The current projection uses
            // `origin` as the authoritative authored-vs-synthesized fact and
            // retains the name-pattern fallback for old null-origin sidecars,
            // so this older marker remains accepted and unused.
            const entry = try self.members(item, at, &.{ "name", "origin", "exported", "synthesized", "fields" });
            entry.warnUnknown();
            const fields_value = try self.array(try entry.get("fields"), self.path("{s}.fields", .{at}));
            const fields = try self.arena.alloc(Field, fields_value.items.len);
            for (fields_value.items, 0..) |field_value, field_index| {
                const field_at = self.path("{s}.fields[{d}]", .{ at, field_index });
                const field = try self.members(field_value, field_at, &.{ "name", "type" });
                field.warnUnknown();
                fields[field_index] = .{
                    .name = try self.nonEmptyString(try field.get("name"), self.path("{s}.name", .{field_at})),
                    .type = try self.mapTypeRef(try field.get("type"), self.path("{s}.type", .{field_at})),
                };
            }
            out[index] = .{
                .name = try self.nonEmptyString(try entry.get("name"), self.path("{s}.name", .{at})),
                .origin = try self.optionalString(entry.map, "origin", at),
                .exported = try self.optionalBoolean(entry.map, "exported", at, true),
                .fields = fields,
            };
        }
        return out;
    }

    fn mapEnums(self: *Mapper, value: std.json.Value) error{ Refused, OutOfMemory }![]const Enum {
        const items = try self.array(value, "types.enums");
        const out = try self.arena.alloc(Enum, items.items.len);
        for (items.items, 0..) |item, index| {
            const at = self.path("types.enums[{d}]", .{index});
            const entry = try self.members(item, at, &.{ "name", "origin", "exported", "members" });
            entry.warnUnknown();
            out[index] = .{
                .name = try self.nonEmptyString(try entry.get("name"), self.path("{s}.name", .{at})),
                .origin = try self.optionalString(entry.map, "origin", at),
                .exported = try self.optionalBoolean(entry.map, "exported", at, true),
                .members = try self.stringList(try entry.get("members"), self.path("{s}.members", .{at})),
            };
        }
        return out;
    }

    fn mapUnions(self: *Mapper, value: std.json.Value) error{ Refused, OutOfMemory }![]const Union {
        const items = try self.array(value, "types.unions");
        const out = try self.arena.alloc(Union, items.items.len);
        for (items.items, 0..) |item, index| {
            const at = self.path("types.unions[{d}]", .{index});
            const entry = try self.members(item, at, &.{ "name", "origin", "exported", "arms" });
            entry.warnUnknown();
            const arms_value = try self.array(try entry.get("arms"), self.path("{s}.arms", .{at}));
            const arms = try self.arena.alloc(UnionArm, arms_value.items.len);
            for (arms_value.items, 0..) |arm_value, arm_index| {
                const arm_at = self.path("{s}.arms[{d}]", .{ at, arm_index });
                const arm = try self.members(arm_value, arm_at, &.{ "name", "member", "payload" });
                arm.warnUnknown();
                arms[arm_index] = .{
                    .name = try self.nonEmptyString(try arm.get("name"), self.path("{s}.name", .{arm_at})),
                    .member = try self.optionalString(arm.map, "member", arm_at),
                    .payload = try self.mapTypeRef(try arm.get("payload"), self.path("{s}.payload", .{arm_at})),
                };
            }
            out[index] = .{
                .name = try self.nonEmptyString(try entry.get("name"), self.path("{s}.name", .{at})),
                .origin = try self.optionalString(entry.map, "origin", at),
                .exported = try self.optionalBoolean(entry.map, "exported", at, true),
                .arms = arms,
            };
        }
        return out;
    }

    fn mapTypeRef(self: *Mapper, value: std.json.Value, at: []const u8) error{ Refused, OutOfMemory }!TypeRef {
        return self.mapTypeRefDepth(value, at, 0);
    }

    /// Structural nesting rides the recursion, so it is bounded: no
    /// real contract wraps a slot 256 levels deep, and past the bound a
    /// document is refused instead of exhausting the stack.
    const max_typeref_nesting = 256;

    fn mapTypeRefDepth(self: *Mapper, value: std.json.Value, at: []const u8, depth: usize) error{ Refused, OutOfMemory }!TypeRef {
        if (depth > max_typeref_nesting) {
            return self.diags.fail(at, "TypeRef nesting exceeds {d} levels — no real contract wraps a slot this deep; flatten the state in the core source", .{max_typeref_nesting});
        }
        const map = try self.object(value, at);
        const kind_value = map.get("kind") orelse return self.diags.fail(self.path("{s}.kind", .{at}), "required field missing (every TypeRef carries a kind discriminator)", .{});
        const kind = try self.string(kind_value, self.path("{s}.kind", .{at}));

        if (std.mem.eql(u8, kind, "bool")) {
            (try self.members(value, at, &.{"kind"})).warnUnknown();
            return .bool;
        }
        if (std.mem.eql(u8, kind, "f64")) {
            (try self.members(value, at, &.{"kind"})).warnUnknown();
            return .f64;
        }
        if (std.mem.eql(u8, kind, "i64")) {
            (try self.members(value, at, &.{"kind"})).warnUnknown();
            return .i64;
        }
        if (std.mem.eql(u8, kind, "bytes")) {
            (try self.members(value, at, &.{"kind"})).warnUnknown();
            return .bytes;
        }
        if (std.mem.eql(u8, kind, "void")) {
            (try self.members(value, at, &.{"kind"})).warnUnknown();
            return .void;
        }
        if (std.mem.eql(u8, kind, "optional")) {
            const entry = try self.members(value, at, &.{ "kind", "inner" });
            entry.warnUnknown();
            const inner = try self.arena.create(TypeRef);
            inner.* = try self.mapTypeRefDepth(try entry.get("inner"), self.path("{s}.inner", .{at}), depth + 1);
            return .{ .optional = inner };
        }
        if (std.mem.eql(u8, kind, "slice")) {
            const entry = try self.members(value, at, &.{ "kind", "elem" });
            entry.warnUnknown();
            const elem = try self.arena.create(TypeRef);
            elem.* = try self.mapTypeRefDepth(try entry.get("elem"), self.path("{s}.elem", .{at}), depth + 1);
            return .{ .slice = elem };
        }
        if (std.mem.eql(u8, kind, "node") or std.mem.eql(u8, kind, "value") or
            std.mem.eql(u8, kind, "enum") or std.mem.eql(u8, kind, "union"))
        {
            const entry = try self.members(value, at, &.{ "kind", "name" });
            entry.warnUnknown();
            const name = try self.nonEmptyString(try entry.get("name"), self.path("{s}.name", .{at}));
            if (std.mem.eql(u8, kind, "node")) return .{ .node = name };
            if (std.mem.eql(u8, kind, "value")) return .{ .value = name };
            if (std.mem.eql(u8, kind, "enum")) return .{ .enum_ref = name };
            return .{ .union_ref = name };
        }
        return self.diags.fail(self.path("{s}.kind", .{at}), "unknown TypeRef kind \"{s}\" — this reader is too old for this sidecar; upgrade the SDK tooling or pin the compiler release it was built for", .{kind});
    }

    fn mapNumberClass(self: *Mapper, value: std.json.Value, at: []const u8) error{ Refused, OutOfMemory }!NumberClass {
        const text = try self.string(value, at);
        if (std.mem.eql(u8, text, "f64")) return .f64;
        if (std.mem.eql(u8, text, "i64")) return .i64;
        return self.diags.fail(at, "unknown number class \"{s}\" — the v1 classes are \"f64\" and \"i64\"; this reader is too old for anything else", .{text});
    }

    /// The integer_slots class vocabulary is its own closed set:
    /// payload descriptors spell "f64"/"i64" (V7), attestations spell
    /// "i64"/"u64" — the unsigned class exists only as a per-slot
    /// verdict, never as a TypeRef or descriptor spelling.
    fn mapIntegerClass(self: *Mapper, value: std.json.Value, at: []const u8) error{ Refused, OutOfMemory }!IntegerClass {
        const text = try self.string(value, at);
        if (std.mem.eql(u8, text, "i64")) return .i64;
        if (std.mem.eql(u8, text, "u64")) return .u64;
        if (std.mem.eql(u8, text, "f64")) {
            return self.diags.fail(at, "integer_slots records the compiler's integer-class verdicts; class \"f64\" has no place here (f64 is the default class and is never attested)", .{});
        }
        return self.diags.fail(at, "unknown integer class \"{s}\" — the format-1 classes are \"i64\" and \"u64\"; this reader is too old for anything else", .{text});
    }

    fn mapHelpers(self: *Mapper, value: std.json.Value) error{ Refused, OutOfMemory }![]const Helper {
        const items = try self.array(value, "model_helpers");
        const out = try self.arena.alloc(Helper, items.items.len);
        for (items.items, 0..) |item, index| {
            const at = self.path("model_helpers[{d}]", .{index});
            const entry = try self.members(item, at, &.{ "name", "params", "returns", "arena" });
            entry.warnUnknown();
            const params_value = try self.array(try entry.get("params"), self.path("{s}.params", .{at}));
            const params = try self.arena.alloc(TypeRef, params_value.items.len);
            for (params_value.items, 0..) |param, param_index| {
                params[param_index] = try self.mapTypeRef(param, self.path("{s}.params[{d}]", .{ at, param_index }));
            }
            out[index] = .{
                .name = try self.nonEmptyString(try entry.get("name"), self.path("{s}.name", .{at})),
                .params = params,
                .returns = try self.mapTypeRef(try entry.get("returns"), self.path("{s}.returns", .{at})),
                .arena = try self.boolean(try entry.get("arena"), self.path("{s}.arena", .{at})),
            };
        }
        return out;
    }

    fn mapMsg(self: *Mapper, value: std.json.Value) error{ Refused, OutOfMemory }!Msg {
        const entry = try self.members(value, "msg", &.{ "name", "arms", "unbound" });
        entry.warnUnknown();
        const arms_value = try self.array(try entry.get("arms"), "msg.arms");
        const arms = try self.arena.alloc(MsgArm, arms_value.items.len);
        for (arms_value.items, 0..) |arm_value, index| {
            const at = self.path("msg.arms[{d}]", .{index});
            const arm = try self.members(arm_value, at, &.{ "name", "member", "payload" });
            arm.warnUnknown();
            arms[index] = .{
                .name = try self.nonEmptyString(try arm.get("name"), self.path("{s}.name", .{at})),
                .member = try self.optionalString(arm.map, "member", at),
                .payload = try self.mapPayload(try arm.get("payload"), self.path("{s}.payload", .{at})),
            };
        }
        return .{
            .name = try self.nonEmptyString(try entry.get("name"), "msg.name"),
            .arms = arms,
            .unbound = try self.stringList(try entry.get("unbound"), "msg.unbound"),
        };
    }

    fn mapPayload(self: *Mapper, value: std.json.Value, at: []const u8) error{ Refused, OutOfMemory }!Payload {
        const map = try self.object(value, at);
        const kind_value = map.get("kind") orelse return self.diags.fail(self.path("{s}.kind", .{at}), "required field missing (every payload descriptor carries a kind discriminator)", .{});
        const kind = try self.string(kind_value, self.path("{s}.kind", .{at}));

        if (std.mem.eql(u8, kind, "void")) {
            (try self.members(value, at, &.{"kind"})).warnUnknown();
            return .void;
        }
        if (std.mem.eql(u8, kind, "bytes")) {
            (try self.members(value, at, &.{"kind"})).warnUnknown();
            return .bytes;
        }
        if (std.mem.eql(u8, kind, "number")) {
            const entry = try self.members(value, at, &.{ "kind", "class" });
            entry.warnUnknown();
            return .{ .number = try self.mapNumberClass(try entry.get("class"), self.path("{s}.class", .{at})) };
        }
        if (std.mem.eql(u8, kind, "number_bytes")) {
            const entry = try self.members(value, at, &.{ "kind", "number_field", "number_class", "bytes_field" });
            entry.warnUnknown();
            return .{ .number_bytes = .{
                .number_field = try self.nonEmptyString(try entry.get("number_field"), self.path("{s}.number_field", .{at})),
                .number_class = try self.mapNumberClass(try entry.get("number_class"), self.path("{s}.number_class", .{at})),
                .bytes_field = try self.nonEmptyString(try entry.get("bytes_field"), self.path("{s}.bytes_field", .{at})),
            } };
        }
        if (std.mem.eql(u8, kind, "record") or std.mem.eql(u8, kind, "union") or std.mem.eql(u8, kind, "enum")) {
            const entry = try self.members(value, at, &.{ "kind", "name" });
            entry.warnUnknown();
            const name = try self.nonEmptyString(try entry.get("name"), self.path("{s}.name", .{at}));
            if (std.mem.eql(u8, kind, "record")) return .{ .record = name };
            if (std.mem.eql(u8, kind, "union")) return .{ .union_ref = name };
            return .{ .enum_ref = name };
        }
        if (std.mem.eql(u8, kind, "scalar")) {
            const entry = try self.members(value, at, &.{ "kind", "type" });
            entry.warnUnknown();
            return .{ .scalar = try self.mapTypeRef(try entry.get("type"), self.path("{s}.type", .{at})) };
        }
        return self.diags.fail(self.path("{s}.kind", .{at}), "unknown payload descriptor kind \"{s}\" — this reader is too old for this sidecar; upgrade the SDK tooling or pin the compiler release it was built for (half-understanding a message arm is how wrong dispatch ships)", .{kind});
    }

    fn mapChannels(self: *Mapper, value: std.json.Value, drop_default: bool) error{ Refused, OutOfMemory }!Channels {
        const entry = try self.members(value, "channels", &.{
            "command_msg", "frame_msg", "key_msg", "pinch_msg", "drop_msg", "appearance_msg", "chrome_msg", "env_msgs",
        });
        entry.warnUnknown();
        const env_value = try self.array(try entry.get("env_msgs"), "channels.env_msgs");
        const env_msgs = try self.arena.alloc(EnvMsg, env_value.items.len);
        for (env_value.items, 0..) |item, index| {
            const at = self.path("channels.env_msgs[{d}]", .{index});
            const env_entry = try self.members(item, at, &.{ "env", "msg" });
            env_entry.warnUnknown();
            env_msgs[index] = .{
                .env = try self.nonEmptyString(try env_entry.get("env"), self.path("{s}.env", .{at})),
                .msg = try self.nonEmptyString(try env_entry.get("msg"), self.path("{s}.msg", .{at})),
            };
        }
        return .{
            .command_msg = try self.boolean(try entry.get("command_msg"), "channels.command_msg"),
            .frame_msg = try self.boolean(try entry.get("frame_msg"), "channels.frame_msg"),
            .key_msg = try self.boolean(try entry.get("key_msg"), "channels.key_msg"),
            .pinch_msg = try self.boolean(try entry.get("pinch_msg"), "channels.pinch_msg"),
            // Additive over the pinned compiler's format-1 emitter: older
            // compilers preserve the profile-declared ABI export but do not
            // know this channel fact yet, so the export list is its honest
            // compatibility default. New frontend sidecars state it directly.
            .drop_msg = try self.optionalBoolean(entry.map, "drop_msg", "channels", drop_default),
            .appearance_msg = try self.armNameOrNull(try entry.get("appearance_msg"), "channels.appearance_msg"),
            .chrome_msg = try self.armNameOrNull(try entry.get("chrome_msg"), "channels.chrome_msg"),
            .env_msgs = env_msgs,
        };
    }

    fn armNameOrNull(self: *Mapper, value: std.json.Value, at: []const u8) error{ Refused, OutOfMemory }!?[]const u8 {
        return switch (value) {
            .null => null,
            .string => try self.nonEmptyString(value, at),
            else => self.diags.fail(at, "expected null or a message arm name string, found {s}", .{jsonKindName(value)}),
        };
    }

    fn mapAbi(self: *Mapper, value: std.json.Value) error{ Refused, OutOfMemory }!Abi {
        const entry = try self.members(value, "abi", &.{ "prefix", "exports", "snapshot_format" });
        entry.warnUnknown();
        return .{
            .prefix = try self.symbolPrefix(try entry.get("prefix"), "abi.prefix"),
            .exports = try self.stringList(try entry.get("exports"), "abi.exports"),
            .snapshot_format = try self.integer(try entry.get("snapshot_format"), "abi.snapshot_format"),
        };
    }

    fn mapIntegerSlots(self: *Mapper, value: std.json.Value) error{ Refused, OutOfMemory }![]const IntegerSlot {
        const items = try self.array(value, "integer_slots");
        const out = try self.arena.alloc(IntegerSlot, items.items.len);
        for (items.items, 0..) |item, index| {
            const at = self.path("integer_slots[{d}]", .{index});
            const entry = try self.members(item, at, &.{ "slot", "class" });
            entry.warnUnknown();
            out[index] = .{
                .slot = try self.nonEmptyString(try entry.get("slot"), self.path("{s}.slot", .{at})),
                .class = try self.mapIntegerClass(try entry.get("class"), self.path("{s}.class", .{at})),
            };
        }
        return out;
    }
};

fn jsonKindName(value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "a boolean",
        .integer => "a number",
        .float => "a number",
        .number_string => "a number",
        .string => "a string",
        .array => "an array",
        .object => "an object",
    };
}

// --------------------------------------------------------- validation
//
// Native mapping enforces required fields, format, hashes, and the closed
// TypeRef/payload vocabularies (V1, V2, structural V7). core_contract.ts owns
// versions, names, reachability, cycles/depth, message bounds/descriptors,
// void positions, unbound lists, channel wiring, integer-slot bijection and
// canonical ABI export order (V3-V11). The owned result boundary preserves
// diagnostic order and exact native i64 version spellings.
// Identity and exported-symbol coherence are proved by the generated shim
// at link/boot (V11-V12). Complete output conformance proves deterministic
// emission (V13); compiler attestations retain their original ownership (V14).

fn validate(arena: std.mem.Allocator, sidecar: Sidecar, diags: *Diagnostics) error{OutOfMemory}!void {
    _ = try @import("core_policy.zig").apply(arena, sidecar, "core", diags);
}

pub const TableKind = enum { @"struct", @"enum", @"union" };

pub fn lookupKind(types: Types, name: []const u8) ?TableKind {
    if (findStruct(types, name) != null) return .@"struct";
    if (findEnum(types, name) != null) return .@"enum";
    if (findUnion(types, name) != null) return .@"union";
    return null;
}

pub fn findStruct(types: Types, name: []const u8) ?*const Struct {
    for (types.structs) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

pub fn findEnum(types: Types, name: []const u8) ?*const Enum {
    for (types.enums) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

pub fn findUnion(types: Types, name: []const u8) ?*const Union {
    for (types.unions) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

pub fn findArm(msg: Msg, name: []const u8) ?*const MsgArm {
    for (msg.arms) |*arm| {
        if (std.mem.eql(u8, arm.name, name)) return arm;
    }
    return null;
}

pub fn abiHasExport(abi: Abi, suffix: []const u8) bool {
    for (abi.exports) |entry| {
        if (std.mem.eql(u8, entry, suffix)) return true;
    }
    return false;
}

/// Restate a validated sidecar after applying record-slot f64 demotions.
/// Mutating the dynamic document instead of serializing the typed reader
/// preserves unknown additive fields for newer producers. The caller first
/// validates each path against the typed contract, so a miss here is internal
/// projection drift rather than user input.
pub fn projectF64SlotsJson(arena: std.mem.Allocator, source: []const u8, f64_slots: []const []const u8) ![]const u8 {
    return @import("invocation.zig").effective(arena, source, f64_slots);
}

// --------------------------------------------------------------- tests

const testing = std.testing;

/// A minimal valid sidecar the refusal tests perturb: one model struct,
/// two message arms, no helpers, no channels.
pub const minimal_valid_json =
    \\{
    \\  "format": 1,
    \\  "wire_version": 7,
    \\  "abi_version": 2,
    \\  "compiler_version": "0.0.1",
    \\  "entry": "src/core.ts",
    \\  "source_hash": "00000000c0ffee00",
    \\  "build_id": "00000000b01dface",
    \\  "model_fingerprint": "00000000a11ce001",
    \\  "types": {
    \\    "structs": [
    \\      {"name": "Model", "fields": [
    \\        {"name": "count", "type": {"kind": "i64"}},
    \\        {"name": "label", "type": {"kind": "bytes"}}
    \\      ]}
    \\    ],
    \\    "enums": [],
    \\    "unions": []
    \\  },
    \\  "model": "Model",
    \\  "model_helpers": [],
    \\  "model_unbound": [],
    \\  "msg": {
    \\    "name": "Msg",
    \\    "arms": [
    \\      {"name": "bump", "payload": {"kind": "void"}},
    \\      {"name": "label_set", "payload": {"kind": "bytes"}}
    \\    ],
    \\    "unbound": ["label_set"]
    \\  },
    \\  "init_returns_cmd": false,
    \\  "update_returns_cmd": true,
    \\  "has_subscriptions": false,
    \\  "has_migrate": false,
    \\  "channels": {
    \\    "command_msg": false,
    \\    "frame_msg": false,
    \\    "key_msg": false,
    \\    "pinch_msg": false,
    \\    "drop_msg": false,
    \\    "appearance_msg": null,
    \\    "chrome_msg": null,
    \\    "env_msgs": []
    \\  },
    \\  "abi": {
    \\    "prefix": "nsc_core_",
    \\    "exports": ["abi_version", "build_id", "set_panic_sink", "init", "collect",
    \\      "frame_reset", "boot_cmd", "dispatch_void", "dispatch_bytes", "dispatch_number",
    \\      "dispatch_number_bytes", "dispatch_bool", "dispatch_enum", "dispatch_record",
    \\      "dispatch_text_input", "dispatch_scroll_state", "subscriptions", "model_snapshot",
    \\      "persist_snapshot", "restore_model", "migrate_model", "helper_call"],
    \\    "snapshot_format": 1
    \\  },
    \\  "integer_slots": [
    \\    {"slot": "Model.count", "class": "i64"}
    \\  ],
    \\  "deterministic": true,
    \\  "async_free": true
    \\}
;

test "compiled policy diagnostics and plan names remain owned across collect and init" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = Diagnostics{ .arena = arena };
    var parsed = try read(arena, minimal_valid_json, &diags);
    const policy = @import("core_policy.zig");
    parsed.types.structs = &.{
        .{ .name = "Model", .fields = &.{} },
        .{ .name = "Msg_insert", .fields = &.{
            .{ .name = "label", .type = .bytes },
            .{ .name = "active", .type = .bool },
        } },
    };
    parsed.msg.arms = &.{.{ .name = "insert", .payload = .{ .record = "Msg_insert" } }};
    const plan = try policy.evaluate(arena, parsed, "plan");
    try testing.expectEqualStrings("Msg_insert", plan.inlined[0]);
    try testing.expectEqualStrings("Msg_insert", plan.flattened[0]);
    try testing.expectEqualStrings("Model", plan.node_stored[0]);
    parsed.wire_version = std.math.maxInt(i64);
    const refused = try policy.evaluate(arena, parsed, "core");
    const before = try std.json.Stringify.valueAlloc(arena, refused, .{});
    try testing.expect(std.mem.indexOf(u8, before, "9223372036854775807") != null);
    for (0..12) |i| {
        parsed.wire_version = @intCast(i + 20);
        _ = try policy.evaluate(arena, parsed, if (i % 2 == 0) "core" else "facade");
    }
    const after = try std.json.Stringify.valueAlloc(arena, refused, .{});
    try testing.expectEqualStrings(before, after);
    try testing.expectEqualStrings("Msg_insert", plan.inlined[0]);
    try testing.expectEqualStrings("Msg_insert", plan.flattened[0]);
    try testing.expectEqualStrings("Model", plan.node_stored[0]);
}

test "drop_msg infers from the ABI export for older format-1 emitters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The pinned external compiler predates the additive channel flag but
    // preserves profile-declared exports in the authoritative ABI list.
    var source = try std.mem.replaceOwned(u8, arena, minimal_valid_json, "    \"drop_msg\": false,\n", "");
    source = try std.mem.replaceOwned(u8, arena, source, "\"helper_call\"]", "\"helper_call\", \"drop_msg\"]");
    var diags = Diagnostics{ .arena = arena };
    const parsed = try read(arena, source, &diags);
    try std.testing.expect(parsed.channels.drop_msg);
    try std.testing.expectEqual(@as(usize, 0), diags.list.items.len);
}

test "effective sidecar carries f64 demotions into its type table and attestations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const projected = try projectF64SlotsJson(arena, minimal_valid_json, &.{"Model.count"});
    var diags = Diagnostics{ .arena = arena };
    const parsed = try read(arena, projected, &diags);
    const model = findStruct(parsed.types, "Model").?;
    try testing.expect(model.fields[0].type == .f64);
    try testing.expectEqual(@as(usize, 0), parsed.integer_slots.len);
}

fn expectRefusal(source: []const u8, expected_path: []const u8, expected_fragment: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = Diagnostics{ .arena = arena };
    const result = read(arena, source, &diags);
    try testing.expectError(error.Refused, result);
    for (diags.list.items) |item| {
        if (item.severity != .@"error") continue;
        if (std.mem.eql(u8, item.path, expected_path) and std.mem.indexOf(u8, item.message, expected_fragment) != null) return;
    }
    std.debug.print("no refusal at \"{s}\" containing \"{s}\"; got:\n", .{ expected_path, expected_fragment });
    for (diags.list.items) |item| {
        std.debug.print("  [{s}] {s}: {s}\n", .{ @tagName(item.severity), item.path, item.message });
    }
    return error.TestExpectedRefusal;
}

fn expectRefusalContaining(source: []const u8, expected_fragment: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = Diagnostics{ .arena = arena };
    const result = read(arena, source, &diags);
    try testing.expectError(error.Refused, result);
    for (diags.list.items) |item| {
        if (item.severity != .@"error") continue;
        if (std.mem.indexOf(u8, item.message, expected_fragment) != null) return;
    }
    std.debug.print("no refusal containing \"{s}\"; got:\n", .{expected_fragment});
    for (diags.list.items) |item| {
        std.debug.print("  [{s}] {s}: {s}\n", .{ @tagName(item.severity), item.path, item.message });
    }
    return error.TestExpectedRefusal;
}

fn readValid(arena: std.mem.Allocator, source: []const u8) !Sidecar {
    var diags = Diagnostics{ .arena = arena };
    return read(arena, source, &diags) catch |err| {
        for (diags.list.items) |item| {
            std.debug.print("  [{s}] {s}: {s}\n", .{ @tagName(item.severity), item.path, item.message });
        }
        return err;
    };
}

fn replaced(arena: std.mem.Allocator, original: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    const count = std.mem.replacementSize(u8, original, needle, replacement);
    const out = try arena.alloc(u8, count);
    _ = std.mem.replace(u8, original, needle, replacement, out);
    return out;
}

test "the minimal sidecar reads clean" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sidecar = try readValid(arena, minimal_valid_json);
    try testing.expectEqualStrings("Model", sidecar.model);
    try testing.expectEqual(@as(usize, 2), sidecar.msg.arms.len);
    try testing.expectEqual(@as(u64, 0x00000000c0ffee00), sidecar.source_hash);
    try testing.expect(sidecar.msg.arms[0].payload == .void);
    try testing.expect(sidecar.msg.arms[1].payload == .bytes);
}

test "V1: an unknown format refuses whole-file with both versions named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(arena_state.allocator(), minimal_valid_json, "\"format\": 1", "\"format\": 2");
    try expectRefusal(source, "format", "implements sidecar format 1, found 2");
}

test "V1: a missing required field refuses with its path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(arena_state.allocator(), minimal_valid_json, "\"deterministic\": true,", "");
    try expectRefusal(source, "deterministic", "required field missing");
}

test "V2: a hash carried as a JSON number refuses with the encoding teaching" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(arena_state.allocator(), minimal_valid_json, "\"00000000b01dface\"", "12345");
    try expectRefusal(source, "build_id", "never JSON numbers");
}

test "V2: uppercase hex refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(arena_state.allocator(), minimal_valid_json, "\"00000000c0ffee00\"", "\"00000000C0FFEE00\"");
    try expectRefusal(source, "source_hash", "lowercase hex digits only");
}

test "V3: a duplicate type-table name refuses with the exact entry path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(arena_state.allocator(), minimal_valid_json, "\"enums\": []", "\"enums\": [{\"name\": \"Model\", \"members\": [\"a\"]}]");
    try expectRefusal(source, "types.enums[0].name", "duplicate type-table name \"Model\"");
}

test "V4: a dangling node reference names the missing entry" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(
        arena_state.allocator(),
        minimal_valid_json,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"node\", \"name\": \"Missing\"}}",
    );
    try expectRefusal(source, "types.structs.Model.fields[1].type", "\"Missing\" names no entry");
}

test "V4: an unreachable table entry refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(
        arena_state.allocator(),
        minimal_valid_json,
        "\"enums\": []",
        "\"enums\": [{\"name\": \"Orphan\", \"members\": [\"a\"]}]",
    );
    try expectRefusal(source, "types.enums[0]", "unreachable from model, msg, model_helpers, and channels");
}

test "V5: a reference cycle refuses with the cycle spelled out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(
        arena_state.allocator(),
        minimal_valid_json,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"node\", \"name\": \"Model\"}}",
    );
    try expectRefusal(source, "types", "Model -> Model");
}

test "V6: more than 256 arms refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var arms: std.ArrayListUnmanaged(u8) = .empty;
    for (0..257) |index| {
        if (index > 0) try arms.appendSlice(arena, ",\n");
        const one = try std.fmt.allocPrint(arena, "      {{\"name\": \"arm_{d}\", \"payload\": {{\"kind\": \"void\"}}}}", .{index});
        try arms.appendSlice(arena, one);
    }
    const source = try replaced(
        arena,
        minimal_valid_json,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}},\n      {\"name\": \"label_set\", \"payload\": {\"kind\": \"bytes\"}}",
        arms.items,
    );
    // The unbound list must still resolve.
    const patched = try replaced(arena, source, "\"unbound\": [\"label_set\"]", "\"unbound\": []");
    try expectRefusal(patched, "msg.arms", "exceed the 256-arm bound");
}

test "valueless message unions, tabled unions, and enums refuse" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const no_arms = try replaced(
        arena,
        minimal_valid_json,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}},\n      {\"name\": \"label_set\", \"payload\": {\"kind\": \"bytes\"}}",
        "",
    );
    const patched = try replaced(arena, no_arms, "\"unbound\": [\"label_set\"]", "\"unbound\": []");
    try expectRefusal(patched, "msg.arms", "declares no arms");

    const empty_enum = try replaced(
        arena,
        minimal_valid_json,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"enum\", \"name\": \"Hollow\"}}",
    );
    const with_enum = try replaced(arena, empty_enum, "\"enums\": []", "\"enums\": [{\"name\": \"Hollow\", \"members\": []}]");
    try expectRefusal(with_enum, "types.enums[0]", "declares no members");
}

test "a tabled union past the one-byte arm bound refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var arms: std.ArrayListUnmanaged(u8) = .empty;
    for (0..257) |index| {
        if (index > 0) try arms.appendSlice(arena, ", ");
        const one = try std.fmt.allocPrint(arena, "{{\"name\": \"arm_{d}\", \"payload\": {{\"kind\": \"void\"}}}}", .{index});
        try arms.appendSlice(arena, one);
    }
    const union_entry = try std.fmt.allocPrint(arena, "\"unions\": [{{\"name\": \"Wide\", \"arms\": [{s}]}}]", .{arms.items});
    const with_union = try replaced(arena, minimal_valid_json, "\"unions\": []", union_entry);
    // Reference it so the reachability rule is satisfied.
    const source = try replaced(
        arena,
        with_union,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"union\", \"name\": \"Wide\"}}",
    );
    try expectRefusal(source, "types.unions[0]", "one-byte declaration-order arm index");
}

test "V7: number_bytes with matching field names refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(
        arena_state.allocator(),
        minimal_valid_json,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"number_bytes\", \"number_field\": \"x\", \"number_class\": \"i64\", \"bytes_field\": \"x\"}}",
    );
    const patched = try replaced(arena_state.allocator(), source, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"Msg.bump.x\", \"class\": \"i64\"}");
    try expectRefusal(patched, "msg.arms[0].payload", "must be distinct");
}

test "V7: an unknown number class refuses as reader-too-old" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(
        arena_state.allocator(),
        minimal_valid_json,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"number\", \"class\": \"i128\"}}",
    );
    try expectRefusal(source, "msg.arms[0].payload.class", "unknown number class \"i128\"");
}

test "the void TypeRef outside a bare union arm refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(
        arena_state.allocator(),
        minimal_valid_json,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"void\"}}",
    );
    try expectRefusal(source, "types.structs[0].fields[1].type", "legal only as a bare union arm payload");
}

test "V8: model_unbound accepts exported helper names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A helper the author declared intentionally unbound: the opt-out
    // vocabulary spans everything a view could bind, methods included.
    const with_helper = try replaced(
        arena,
        minimal_valid_json,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"summary\", \"params\": [], \"returns\": {\"kind\": \"bytes\"}, \"arena\": false}]",
    );
    const source = try replaced(arena, with_helper, "\"model_unbound\": []", "\"model_unbound\": [\"summary\", \"count\"]");
    const sidecar = try readValid(arena, source);
    try testing.expectEqual(@as(usize, 2), sidecar.model_unbound.len);
}

test "V8: an unbound name that resolves nowhere refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(arena_state.allocator(), minimal_valid_json, "\"model_unbound\": []", "\"model_unbound\": [\"ghost\"]");
    try expectRefusal(source, "model_unbound[0]", "\"ghost\" is neither a field of the model struct");
}

test "V9: an env channel targeting a non-bytes arm refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(
        arena_state.allocator(),
        minimal_valid_json,
        "\"env_msgs\": []",
        "\"env_msgs\": [{\"env\": \"APP_MODE\", \"msg\": \"bump\"}]",
    );
    try expectRefusal(source, "channels.env_msgs[0].msg", "must be bytes");
}

test "V9: a wired function channel missing from abi.exports refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(arena_state.allocator(), minimal_valid_json, "\"key_msg\": false", "\"key_msg\": true");
    try expectRefusal(source, "channels.key_msg", "missing from abi.exports");
}

test "V10: a dotted name in an i64 slot path refuses as unaddressable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // `A` with field `B.C` would spell the same path as `A.B` with
    // field `C`; the grammar cannot tell them apart.
    var source = try replaced(arena, minimal_valid_json, "{\"name\": \"count\", \"type\": {\"kind\": \"i64\"}}", "{\"name\": \"cou.nt\", \"type\": {\"kind\": \"i64\"}}");
    source = try replaced(arena, source, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "{\"slot\": \"Model.cou.nt\", \"class\": \"i64\"}");
    try expectRefusal(source, "integer_slots", "cannot address unambiguously");
}

test "V10: an i64 spelling without an integer_slots entry refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(arena_state.allocator(), minimal_valid_json, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "");
    try expectRefusal(source, "integer_slots", "spells \"Model.count\" i64 but attests no integer_slots entry");
}

test "V10: an entry on a slot of another spelling refuses with that spelling named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(
        arena_state.allocator(),
        minimal_valid_json,
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}",
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"Model.label\", \"class\": \"i64\"}",
    );
    try expectRefusal(source, "integer_slots[1].slot", "resolves to a slot the sidecar spells bytes, not i64");
}

test "V10: an unresolvable slot path refuses with the grammar's forms" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ghost = try replaced(
        arena,
        minimal_valid_json,
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}",
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"Ghost.count\", \"class\": \"i64\"}",
    );
    try expectRefusal(ghost, "integer_slots[1].slot", "resolves against none of the sidecar's own tables");
    // An element-indexing spelling has no grammar form either — the
    // format-1 grammar cannot address inside a sequence.
    const indexed = try replaced(
        arena,
        minimal_valid_json,
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}",
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"Model.ids[0]\", \"class\": \"i64\"}",
    );
    try expectRefusal(indexed, "integer_slots[1].slot", "resolves against none of the sidecar's own tables");
    // A missing helper signature slot is the same refusal.
    const helper = try replaced(
        arena,
        minimal_valid_json,
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}",
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"helpers.rowCount.return\", \"class\": \"i64\"}",
    );
    try expectRefusal(helper, "integer_slots[1].slot", "resolves against none of the sidecar's own tables");
}

test "V10: a slot path landing on a slice refuses as the grammar's element gap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A slice of i64 is a legal spelling (its elements are exempt from
    // the bijection), but no entry may claim it: the grammar has no
    // slice-element form, so the checker refuses rather than
    // half-supporting element attestation.
    var source = try replaced(
        arena,
        minimal_valid_json,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}, {\"name\": \"ids\", \"type\": {\"kind\": \"slice\", \"elem\": {\"kind\": \"i64\"}}}",
    );
    source = try replaced(
        arena,
        source,
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}",
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"Model.ids\", \"class\": \"i64\"}",
    );
    try expectRefusal(source, "integer_slots[1].slot", "no slice-element form");
}

test "V10: a duplicate entry refuses with the exact index" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(
        arena_state.allocator(),
        minimal_valid_json,
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}",
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"Model.count\", \"class\": \"u64\"}",
    );
    try expectRefusal(source, "integer_slots[1].slot", "duplicate entry for \"Model.count\"");
}

test "V10: the u64 class is accepted and carried" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try replaced(arena, minimal_valid_json, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "{\"slot\": \"Model.count\", \"class\": \"u64\"}");
    const sidecar = try readValid(arena, source);
    try testing.expectEqual(@as(usize, 1), sidecar.integer_slots.len);
    try testing.expectEqual(IntegerClass.u64, sidecar.integer_slots[0].class);
}

test "V10: class f64 in integer_slots refuses (the default class is never attested)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(arena_state.allocator(), minimal_valid_json, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "{\"slot\": \"Model.count\", \"class\": \"f64\"}");
    try expectRefusal(source, "integer_slots[0].class", "never attested");
}

test "V10: an unknown integer class refuses as reader-too-old" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(arena_state.allocator(), minimal_valid_json, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "{\"slot\": \"Model.count\", \"class\": \"i128\"}");
    try expectRefusal(source, "integer_slots[0].class", "unknown integer class \"i128\"");
}

test "V10: message-side slot paths spell the union's authored name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try replaced(arena, minimal_valid_json, "\"name\": \"Msg\"", "\"name\": \"Event\"");
    source = try replaced(
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"tick\", \"payload\": {\"kind\": \"number\", \"class\": \"i64\"}}",
    );
    // The authored spelling resolves.
    const authored = try replaced(
        arena,
        source,
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}",
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"Event.tick\", \"class\": \"i64\"}",
    );
    const sidecar = try readValid(arena, authored);
    try testing.expectEqual(@as(usize, 2), sidecar.integer_slots.len);
    // A literal `Msg` token does not: the grammar's message forms use
    // the designated union's own name.
    const literal = try replaced(
        arena,
        source,
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}",
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"Msg.tick\", \"class\": \"i64\"}",
    );
    try expectRefusal(literal, "integer_slots", "spells \"Event.tick\" i64 but attests no integer_slots entry");
}

test "V10: two distinct slots spelling one path refuse as unaddressable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A message union named "helpers" whose number_bytes arm "peak"
    // declares its number field "return", beside an exported helper
    // "peak" returning i64: both slots spell "helpers.peak.return", so
    // no attestation can be told apart from the other's.
    var source = try replaced(arena, minimal_valid_json, "\"name\": \"Msg\"", "\"name\": \"helpers\"");
    source = try replaced(
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"peak\", \"payload\": {\"kind\": \"number_bytes\", \"number_field\": \"return\", \"number_class\": \"i64\", \"bytes_field\": \"body\"}}",
    );
    source = try replaced(
        arena,
        source,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"peak\", \"params\": [], \"returns\": {\"kind\": \"i64\"}, \"arena\": false}]",
    );
    source = try replaced(
        arena,
        source,
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}",
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"helpers.peak.return\", \"class\": \"i64\"}, {\"slot\": \"helpers.peak.return\", \"class\": \"u64\"}",
    );
    try expectRefusal(source, "integer_slots", "two distinct i64 slots spell the one path \"helpers.peak.return\"");
}

test "V10: an empty integer_slots list is valid when nothing spells i64" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The f64-only sequencing: an emitter predating integer inference
    // spells every numeric slot f64 and attests the empty list.
    var source = try replaced(arena, minimal_valid_json, "{\"name\": \"count\", \"type\": {\"kind\": \"i64\"}}", "{\"name\": \"count\", \"type\": {\"kind\": \"f64\"}}");
    source = try replaced(arena, source, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "");
    const sidecar = try readValid(arena, source);
    try testing.expectEqual(@as(usize, 0), sidecar.integer_slots.len);
}

test "V11: an unknown export suffix refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(arena_state.allocator(), minimal_valid_json, "\"helper_call\"]", "\"helper_call\", \"mystery_entry\"]");
    try expectRefusal(source, "abi.exports[22]", "not an export suffix of ABI version 2");
}

test "V11: the optional native view extension is unique and follows channels" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try replaced(arena, minimal_valid_json, "\"helper_call\"]", "\"helper_call\", \"native_view\"]");
    const valid = try readValid(arena, source);
    try testing.expect(abiHasExport(valid.abi, "native_view"));
    const windows = try replaced(arena, source, "\"native_view\"]", "\"native_view\", \"native_window_view\"]");
    const window_valid = try readValid(arena, windows);
    try testing.expect(abiHasExport(window_valid.abi, "native_window_view"));
    const policy = try replaced(arena, windows, "\"native_window_view\"]", "\"native_window_view\", \"native_radio_policy\"]");
    const policy_valid = try readValid(arena, policy);
    try testing.expect(abiHasExport(policy_valid.abi, "native_radio_policy"));
    const tabs = try replaced(arena, policy, "\"native_radio_policy\"]", "\"native_radio_policy\", \"native_tabs_policy\"]");
    const tabs_valid = try readValid(arena, tabs);
    try testing.expect(abiHasExport(tabs_valid.abi, "native_tabs_policy"));
    const tree = try replaced(arena, tabs, "\"native_tabs_policy\"]", "\"native_tabs_policy\", \"native_tree_policy\"]");
    const tree_valid = try readValid(arena, tree);
    try testing.expect(abiHasExport(tree_valid.abi, "native_tree_policy"));
    const list = try replaced(arena, tree, "\"native_tree_policy\"]", "\"native_tree_policy\", \"native_list_policy\"]");
    const list_valid = try readValid(arena, list);
    try testing.expect(abiHasExport(list_valid.abi, "native_list_policy"));
    const menu = try replaced(arena, list, "\"native_list_policy\"]", "\"native_list_policy\", \"native_menu_policy\"]");
    const menu_valid = try readValid(arena, menu);
    try testing.expect(abiHasExport(menu_valid.abi, "native_menu_policy"));
    const toggle = try replaced(arena, menu, "\"native_menu_policy\"]", "\"native_menu_policy\", \"native_toggle_policy\"]");
    const toggle_valid = try readValid(arena, toggle);
    try testing.expect(abiHasExport(toggle_valid.abi, "native_toggle_policy"));
    const accordion = try replaced(arena, toggle, "\"native_toggle_policy\"]", "\"native_toggle_policy\", \"native_accordion_policy\"]");
    const accordion_valid = try readValid(arena, accordion);
    try testing.expect(abiHasExport(accordion_valid.abi, "native_accordion_policy"));
    const slider = try replaced(arena, accordion, "\"native_accordion_policy\"]", "\"native_accordion_policy\", \"native_slider_policy\"]");
    const slider_valid = try readValid(arena, slider);
    try testing.expect(abiHasExport(slider_valid.abi, "native_slider_policy"));
    const split = try replaced(arena, slider, "\"native_slider_policy\"]", "\"native_slider_policy\", \"native_split_policy\"]");
    const split_valid = try readValid(arena, split);
    try testing.expect(abiHasExport(split_valid.abi, "native_split_policy"));
    const scroll = try replaced(arena, split, "\"native_split_policy\"]", "\"native_split_policy\", \"native_scroll_policy\"]");
    const scroll_valid = try readValid(arena, scroll);
    try testing.expect(abiHasExport(scroll_valid.abi, "native_scroll_policy"));
    const resizable = try replaced(arena, scroll, "\"native_scroll_policy\"]", "\"native_scroll_policy\", \"native_resizable_policy\"]");
    const resizable_valid = try readValid(arena, resizable);
    try testing.expect(abiHasExport(resizable_valid.abi, "native_resizable_policy"));
    const text = try replaced(arena, resizable, "\"native_resizable_policy\"]", "\"native_resizable_policy\", \"native_text_policy\"]");
    const text_valid = try readValid(arena, text);
    try testing.expect(abiHasExport(text_valid.abi, "native_text_policy"));
    const timer = try replaced(arena, text, "\"native_text_policy\"]", "\"native_text_policy\", \"native_timer_policy\"]");
    const timer_valid = try readValid(arena, timer);
    try testing.expect(abiHasExport(timer_valid.abi, "native_timer_policy"));
    const db = try replaced(arena, timer, "\"native_timer_policy\"]", "\"native_timer_policy\", \"native_db_policy\"]");
    const db_valid = try readValid(arena, db);
    try testing.expect(abiHasExport(db_valid.abi, "native_db_policy"));
    const effect = try replaced(arena, db, "\"native_db_policy\"]", "\"native_db_policy\", \"native_effect_policy\"]");
    const effect_valid = try readValid(arena, effect);
    try testing.expect(abiHasExport(effect_valid.abi, "native_effect_policy"));
    const effect_duplicate = try replaced(arena, effect, "\"native_effect_policy\"]", "\"native_effect_policy\", \"native_effect_policy\"]");
    try expectRefusal(effect_duplicate, "abi.exports[39]", "out of canonical order");
    const window = try replaced(arena, db, "\"native_db_policy\"]", "\"native_db_policy\", \"native_window_policy\"]");
    const window_policy_valid = try readValid(arena, window);
    try testing.expect(abiHasExport(window_policy_valid.abi, "native_window_policy"));
    const window_policy_duplicate = try replaced(arena, window, "\"native_window_policy\"]", "\"native_window_policy\", \"native_window_policy\"]");
    try expectRefusal(window_policy_duplicate, "abi.exports[39]", "out of canonical order");
    const theme = try replaced(arena, db, "\"native_db_policy\"]", "\"native_db_policy\", \"native_theme_policy\"]");
    const theme_valid = try readValid(arena, theme);
    try testing.expect(abiHasExport(theme_valid.abi, "native_theme_policy"));
    const theme_duplicate = try replaced(arena, theme, "\"native_theme_policy\"]", "\"native_theme_policy\", \"native_theme_policy\"]");
    try expectRefusal(theme_duplicate, "abi.exports[39]", "out of canonical order");
    const status = try replaced(arena, db, "\"native_db_policy\"]", "\"native_db_policy\", \"native_status_policy\"]");
    const status_valid = try readValid(arena, status);
    try testing.expect(abiHasExport(status_valid.abi, "native_status_policy"));
    const status_duplicate = try replaced(arena, status, "\"native_status_policy\"]", "\"native_status_policy\", \"native_status_policy\"]");
    try expectRefusal(status_duplicate, "abi.exports[39]", "out of canonical order");
    const db_duplicate = try replaced(arena, db, "\"native_db_policy\"]", "\"native_db_policy\", \"native_db_policy\"]");
    try expectRefusal(db_duplicate, "abi.exports[38]", "out of canonical order");
    const timer_duplicate = try replaced(arena, timer, "\"native_timer_policy\"]", "\"native_timer_policy\", \"native_timer_policy\"]");
    try expectRefusal(timer_duplicate, "abi.exports[37]", "out of canonical order");
    const text_duplicate = try replaced(arena, text, "\"native_text_policy\"]", "\"native_text_policy\", \"native_text_policy\"]");
    try expectRefusal(text_duplicate, "abi.exports[36]", "out of canonical order");
    const resizable_duplicate = try replaced(arena, resizable, "\"native_resizable_policy\"]", "\"native_resizable_policy\", \"native_resizable_policy\"]");
    try expectRefusal(resizable_duplicate, "abi.exports[35]", "out of canonical order");
    const scroll_duplicate = try replaced(arena, scroll, "\"native_scroll_policy\"]", "\"native_scroll_policy\", \"native_scroll_policy\"]");
    try expectRefusal(scroll_duplicate, "abi.exports[34]", "out of canonical order");
    const split_duplicate = try replaced(arena, split, "\"native_split_policy\"]", "\"native_split_policy\", \"native_split_policy\"]");
    try expectRefusal(split_duplicate, "abi.exports[33]", "out of canonical order");
    const slider_duplicate = try replaced(arena, slider, "\"native_slider_policy\"]", "\"native_slider_policy\", \"native_slider_policy\"]");
    try expectRefusal(slider_duplicate, "abi.exports[32]", "out of canonical order");
    const accordion_duplicate = try replaced(arena, accordion, "\"native_accordion_policy\"]", "\"native_accordion_policy\", \"native_accordion_policy\"]");
    try expectRefusal(accordion_duplicate, "abi.exports[31]", "out of canonical order");
    const toggle_duplicate = try replaced(arena, toggle, "\"native_toggle_policy\"]", "\"native_toggle_policy\", \"native_toggle_policy\"]");
    try expectRefusal(toggle_duplicate, "abi.exports[30]", "out of canonical order");
    const menu_duplicate = try replaced(arena, menu, "\"native_menu_policy\"]", "\"native_menu_policy\", \"native_menu_policy\"]");
    try expectRefusal(menu_duplicate, "abi.exports[29]", "out of canonical order");
    const list_duplicate = try replaced(arena, list, "\"native_list_policy\"]", "\"native_list_policy\", \"native_list_policy\"]");
    try expectRefusal(list_duplicate, "abi.exports[28]", "out of canonical order");
    const tree_duplicate = try replaced(arena, tree, "\"native_tree_policy\"]", "\"native_tree_policy\", \"native_tree_policy\"]");
    try expectRefusal(tree_duplicate, "abi.exports[27]", "out of canonical order");
    const tabs_duplicate = try replaced(arena, tabs, "\"native_tabs_policy\"]", "\"native_tabs_policy\", \"native_tabs_policy\"]");
    try expectRefusal(tabs_duplicate, "abi.exports[26]", "out of canonical order");
    const policy_duplicate = try replaced(arena, policy, "\"native_radio_policy\"]", "\"native_radio_policy\", \"native_radio_policy\"]");
    try expectRefusal(policy_duplicate, "abi.exports[25]", "out of canonical order");
    const window_duplicate = try replaced(arena, windows, "\"native_window_view\"]", "\"native_window_view\", \"native_window_view\"]");
    try expectRefusal(window_duplicate, "abi.exports[24]", "out of canonical order");
    const duplicate = try replaced(arena, source, "\"native_view\"]", "\"native_view\", \"native_view\"]");
    try expectRefusal(duplicate, "abi.exports[23]", "out of canonical order");
    const reordered = try replaced(arena, source, "\"helper_call\", \"native_view\"", "\"native_view\", \"helper_call\"");
    try expectRefusal(reordered, "abi.exports[21]", "expected the unconditional export");
}

test "V11: a missing unconditional export refuses with the expected suffix" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(arena_state.allocator(), minimal_valid_json, "\"init\", \"collect\",", "\"init\",");
    try expectRefusal(source, "abi.exports[4]", "expected the unconditional export \"collect\"");
}

test "unknown TypeRef kinds refuse as reader-too-old" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(arena_state.allocator(), minimal_valid_json, "{\"kind\": \"bytes\"}}", "{\"kind\": \"decimal128\"}}");
    try expectRefusal(source, "types.structs[0].fields[1].type.kind", "unknown TypeRef kind \"decimal128\"");
}

test "unknown payload descriptor kinds refuse as reader-too-old" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(
        arena_state.allocator(),
        minimal_valid_json,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"tensor\"}}",
    );
    try expectRefusal(source, "msg.arms[0].payload.kind", "unknown payload descriptor kind \"tensor\"");
}

test "wire and abi version mismatches refuse with both values named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = try replaced(arena_state.allocator(), minimal_valid_json, "\"wire_version\": 7", "\"wire_version\": 8");
    try expectRefusal(source, "wire_version", "generation 7, the sidecar declares 8");
}

test "unknown fields warn and are ignored" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try replaced(arena, minimal_valid_json, "\"deterministic\": true,", "\"deterministic\": true,\n  \"novel_fact\": 7,");
    var diags = Diagnostics{ .arena = arena };
    _ = try read(arena, source, &diags);
    try testing.expect(!diags.hasErrors());
    var warned = false;
    for (diags.list.items) |item| {
        if (item.severity == .warning and std.mem.eql(u8, item.path, "novel_fact")) warned = true;
    }
    try testing.expect(warned);
}

test "structural nesting past the bound refuses instead of exhausting the stack" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var wrapped: std.ArrayListUnmanaged(u8) = .empty;
    const wraps = 300;
    var index: usize = 0;
    while (index < wraps) : (index += 1) {
        try wrapped.appendSlice(arena, "{\"kind\": \"optional\", \"inner\": ");
    }
    try wrapped.appendSlice(arena, "{\"kind\": \"bool\"}");
    index = 0;
    while (index < wraps) : (index += 1) {
        try wrapped.append(arena, '}');
    }
    const source = try replaced(arena, minimal_valid_json, "{\"kind\": \"i64\"}", wrapped.items);
    try expectRefusalContaining(source, "nesting exceeds 256 levels");
}

test "record chains past the depth bound refuse with a teaching" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Chain0 -> Chain1 -> ... : acyclic and small on disk, but deeper
    // than any bounded consumer can walk.
    var chain: std.ArrayListUnmanaged(u8) = .empty;
    const links = 300;
    var index: usize = 0;
    while (index < links) : (index += 1) {
        const entry = if (index + 1 < links)
            try std.fmt.allocPrint(arena, "{{\"name\": \"Chain{d}\", \"fields\": [{{\"name\": \"next\", \"type\": {{\"kind\": \"value\", \"name\": \"Chain{d}\"}}}}]}},\n", .{ index, index + 1 })
        else
            try std.fmt.allocPrint(arena, "{{\"name\": \"Chain{d}\", \"fields\": [{{\"name\": \"leaf\", \"type\": {{\"kind\": \"i64\"}}}}]}},\n", .{index});
        try chain.appendSlice(arena, entry);
    }
    var source = try replaced(
        arena,
        minimal_valid_json,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}, {\"name\": \"head\", \"type\": {\"kind\": \"value\", \"name\": \"Chain0\"}}",
    );
    const model_open = "{\"name\": \"Model\", \"fields\": [";
    source = try replaced(arena, source, model_open, try std.fmt.allocPrint(arena, "{s}{s}", .{ chain.items, model_open }));
    try expectRefusalContaining(source, "expands deeper than 256 levels");
}

test "compound wrapping and chaining refuse on expanded depth" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 16 records chained through 32 slice wrappers each: chain length
    // and per-reference nesting both sit far under their own bounds,
    // but the expanded value tree is ~528 levels deep.
    var chain: std.ArrayListUnmanaged(u8) = .empty;
    const links = 16;
    const wraps = 32;
    var index: usize = 0;
    while (index < links) : (index += 1) {
        var wrapped: std.ArrayListUnmanaged(u8) = .empty;
        var level: usize = 0;
        while (level < wraps) : (level += 1) {
            try wrapped.appendSlice(arena, "{\"kind\": \"slice\", \"elem\": ");
        }
        if (index + 1 < links) {
            try wrapped.appendSlice(arena, try std.fmt.allocPrint(arena, "{{\"kind\": \"value\", \"name\": \"Deep{d}\"}}", .{index + 1}));
        } else {
            try wrapped.appendSlice(arena, "{\"kind\": \"i64\"}");
        }
        level = 0;
        while (level < wraps) : (level += 1) {
            try wrapped.append(arena, '}');
        }
        try chain.appendSlice(arena, try std.fmt.allocPrint(arena, "{{\"name\": \"Deep{d}\", \"fields\": [{{\"name\": \"next\", \"type\": {s}}}]}},\n", .{ index, wrapped.items }));
    }
    var source = try replaced(
        arena,
        minimal_valid_json,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}, {\"name\": \"head\", \"type\": {\"kind\": \"value\", \"name\": \"Deep0\"}}",
    );
    const model_open = "{\"name\": \"Model\", \"fields\": [";
    source = try replaced(arena, source, model_open, try std.fmt.allocPrint(arena, "{s}{s}", .{ chain.items, model_open }));
    try expectRefusalContaining(source, "expands deeper than 256 levels");
}

test "an abi prefix with symbol-unsafe bytes refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nul = try replaced(arena, minimal_valid_json, "\"prefix\": \"nsc_core_\"", "\"prefix\": \"nsc_core_\\u0000\"");
    try expectRefusal(nul, "abi.prefix", "cannot appear in a linker symbol name");
    const digit = try replaced(arena, minimal_valid_json, "\"prefix\": \"nsc_core_\"", "\"prefix\": \"9core_\"");
    try expectRefusal(digit, "abi.prefix", "cannot appear in a linker symbol name");
    const space = try replaced(arena, minimal_valid_json, "\"prefix\": \"nsc_core_\"", "\"prefix\": \"nsc core \"");
    try expectRefusal(space, "abi.prefix", "cannot appear in a linker symbol name");
}
