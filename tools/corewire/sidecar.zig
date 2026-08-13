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
//! std-only: the generator is a build-time tool and the validation tests
//! run in the plain unit-test suite.

const std = @import("std");

/// The sidecar schema generation this reader implements.
pub const supported_format: i64 = 1;

/// The command-wire vocabulary generation the SDK's bridge speaks
/// (rt.zig `cmd_format_version`). A sidecar declaring a different
/// generation is refused at generate time.
pub const supported_wire_version: i64 = 6;

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
/// matching channel is wired.
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
// The schema's emitter self-check rules, enforced reader-side as far as
// a reader can without the compiled object:
//   V1  required fields + format fence   — the mapper (presence) and
//                                          mapRoot (format).
//   V2  hash encodings                   — the mapper's hash64.
//   V3  name uniqueness                  — validateNames.
//   V4  reference resolution + no
//       unreachable table entries        — validateReferences.
//   V5  acyclicity                       — validateAcyclic.
//   V6  tag density and arm bound        — validateMsg (density is
//       structural: tags are positions; the reader checks the bound).
//       Source declaration order itself is only checkable against the
//       source, i.e. by the emitter.
//   V7  descriptor consistency           — the mapper (classes) and
//                                          validateMsg (field names,
//                                          scalar shape).
//   V8  unbound lists resolve            — validateUnbound.
//   V9  channel wiring                   — validateChannels.
//   V10 integer-slot bijection           — validateIntegerSlots: the
//       one-to-one check both ways, plus structural resolution of every
//       leftover entry's path (unresolvable, wrong spelling, or the
//       grammar's slice-element gap each carry their own teaching).
//   V11 export attestation               — validateAbi checks the list
//       against the profile's canonical vocabulary and order; the
//       "exactly what the object exports" half needs the object and is
//       enforced at link/boot time by the generated shim.
//   V12 identity coherence               — a boot-time check: the
//       generated shim compares the sidecar's build_id against the
//       object's identity getter before the first dispatch.
//   V13 deterministic emission           — an emitter-side property;
//       the generator itself re-emits byte-identically from equal
//       input (pinned by a test).
//   V14 attestation honesty              — an emitter-side property a
//       reader cannot re-derive (the proof lives in the compiler; the
//       sidecar records verdicts).

fn validate(arena: std.mem.Allocator, sidecar: Sidecar, diags: *Diagnostics) error{OutOfMemory}!void {
    validateVersions(sidecar, diags);
    try validateNames(arena, sidecar, diags);
    // Reference checks assume the namespace is coherent; a broken
    // namespace already carries its own teachings.
    if (diags.hasErrors()) return;
    try validateReferences(arena, sidecar, diags);
    if (diags.hasErrors()) return;
    try validateAcyclic(arena, sidecar, diags);
    validateMsg(sidecar, diags);
    validateVoidPositions(sidecar, diags);
    validateUnbound(sidecar, diags);
    validateChannels(sidecar, diags);
    validateAbi(sidecar, diags);
    try validateIntegerSlots(arena, sidecar, diags);
}

fn validateVersions(sidecar: Sidecar, diags: *Diagnostics) void {
    if (sidecar.wire_version != supported_wire_version) {
        diags.flag("wire_version", "this SDK's command-wire vocabulary is generation {d}, the sidecar declares {d} — the compiled core's effect builders speak a different wire; upgrade the SDK or pin the compiler release that matches it", .{ supported_wire_version, sidecar.wire_version });
    }
    if (sidecar.abi_version != supported_abi_version) {
        diags.flag("abi_version", "this generator binds core ABI version {d}, the sidecar declares {d} — upgrade the SDK or pin the compiler release that matches it", .{ supported_abi_version, sidecar.abi_version });
    }
    if (sidecar.abi.snapshot_format != supported_snapshot_format) {
        diags.flag("abi.snapshot_format", "this generator decodes snapshot format {d}, the sidecar declares {d} — upgrade the SDK or pin the compiler release that matches it", .{ supported_snapshot_format, sidecar.abi.snapshot_format });
    }
}

const NameSet = std.StringArrayHashMapUnmanaged(void);

fn noteName(arena: std.mem.Allocator, set: *NameSet, name: []const u8, at: []const u8, what: []const u8, diags: *Diagnostics) error{OutOfMemory}!void {
    const entry = try set.getOrPut(arena, name);
    if (entry.found_existing) {
        diags.flag(at, "duplicate {s} \"{s}\" — V3 requires unique names here", .{ what, name });
    }
}

fn validateNames(arena: std.mem.Allocator, sidecar: Sidecar, diags: *Diagnostics) error{OutOfMemory}!void {
    // One namespace across structs + enums + unions.
    var table_names: NameSet = .empty;
    for (sidecar.types.structs, 0..) |entry, index| {
        try noteName(arena, &table_names, entry.name, pathOf(arena, "types.structs[{d}].name", .{index}), "type-table name", diags);
        var field_names: NameSet = .empty;
        for (entry.fields, 0..) |field, field_index| {
            try noteName(arena, &field_names, field.name, pathOf(arena, "types.structs[{d}].fields[{d}].name", .{ index, field_index }), "field name", diags);
        }
    }
    for (sidecar.types.enums, 0..) |entry, index| {
        try noteName(arena, &table_names, entry.name, pathOf(arena, "types.enums[{d}].name", .{index}), "type-table name", diags);
        var member_names: NameSet = .empty;
        for (entry.members, 0..) |member, member_index| {
            try noteName(arena, &member_names, member, pathOf(arena, "types.enums[{d}].members[{d}]", .{ index, member_index }), "enum member", diags);
        }
    }
    for (sidecar.types.unions, 0..) |entry, index| {
        try noteName(arena, &table_names, entry.name, pathOf(arena, "types.unions[{d}].name", .{index}), "type-table name", diags);
        var arm_names: NameSet = .empty;
        for (entry.arms, 0..) |arm, arm_index| {
            try noteName(arena, &arm_names, arm.name, pathOf(arena, "types.unions[{d}].arms[{d}].name", .{ index, arm_index }), "union arm", diags);
        }
    }
    var msg_arm_names: NameSet = .empty;
    for (sidecar.msg.arms, 0..) |arm, index| {
        try noteName(arena, &msg_arm_names, arm.name, pathOf(arena, "msg.arms[{d}].name", .{index}), "message arm", diags);
    }
    var helper_names: NameSet = .empty;
    for (sidecar.model_helpers, 0..) |helper, index| {
        try noteName(arena, &helper_names, helper.name, pathOf(arena, "model_helpers[{d}].name", .{index}), "helper name", diags);
    }
    var env_names: NameSet = .empty;
    for (sidecar.channels.env_msgs, 0..) |entry, index| {
        try noteName(arena, &env_names, entry.env, pathOf(arena, "channels.env_msgs[{d}].env", .{index}), "environment variable name", diags);
    }
}

fn pathOf(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(arena, fmt, args) catch "";
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

const Reach = struct {
    arena: std.mem.Allocator,
    types: Types,
    diags: *Diagnostics,
    seen: NameSet = .empty,
    /// The active visit's worklist, when a walk is in progress; a
    /// checkRef outside a walk visits directly.
    pending: ?*std.ArrayListUnmanaged([]const u8) = null,

    fn enqueue(self: *Reach, name: []const u8) error{OutOfMemory}!void {
        if (self.pending) |worklist| {
            try worklist.append(self.arena, name);
            return;
        }
        try self.visit(name);
    }

    fn checkRef(self: *Reach, ref: TypeRef, at: []const u8) error{OutOfMemory}!void {
        switch (ref) {
            .bool, .f64, .i64, .bytes, .void => {},
            .optional => |inner| try self.checkRef(inner.*, at),
            .slice => |elem| try self.checkRef(elem.*, at),
            .node, .value => |name| {
                if (findStruct(self.types, name) == null) {
                    self.wrongKind(name, .@"struct", at);
                    return;
                }
                try self.enqueue(name);
            },
            .enum_ref => |name| {
                if (findEnum(self.types, name) == null) {
                    self.wrongKind(name, .@"enum", at);
                    return;
                }
                try self.enqueue(name);
            },
            .union_ref => |name| {
                if (findUnion(self.types, name) == null) {
                    self.wrongKind(name, .@"union", at);
                    return;
                }
                try self.enqueue(name);
            },
        }
    }

    fn wrongKind(self: *Reach, name: []const u8, wanted: TableKind, at: []const u8) void {
        if (lookupKind(self.types, name)) |found| {
            self.diags.flag(at, "\"{s}\" names {s} {s} in the type table, but this reference requires {s} {s} — V4", .{
                name, articleOf(found), @tagName(found), articleOf(wanted), @tagName(wanted),
            });
        } else {
            self.diags.flag(at, "\"{s}\" names no entry in the type table (no struct, enum, or union declares it) — V4", .{name});
        }
    }

    /// Iterative: named-type chains can be as long as the document
    /// allows, so the walk carries its own worklist instead of the
    /// process stack (structural nesting within one reference stays
    /// recursive under the reader's 256-level bound).
    fn visit(self: *Reach, root: []const u8) error{OutOfMemory}!void {
        var worklist: std.ArrayListUnmanaged([]const u8) = .empty;
        try worklist.append(self.arena, root);
        while (worklist.pop()) |name| {
            const entry = try self.seen.getOrPut(self.arena, name);
            if (entry.found_existing) continue;
            self.pending = &worklist;
            defer self.pending = null;
            if (findStruct(self.types, name)) |record| {
                for (record.fields, 0..) |field, index| {
                    try self.checkRef(field.type, pathOf(self.arena, "types.structs.{s}.fields[{d}].type", .{ name, index }));
                }
                continue;
            }
            if (findUnion(self.types, name)) |tagged| {
                for (tagged.arms, 0..) |arm, index| {
                    try self.checkRef(arm.payload, pathOf(self.arena, "types.unions.{s}.arms[{d}].payload", .{ name, index }));
                }
                continue;
            }
            // Enums carry no references.
        }
    }
};

fn articleOf(kind: TableKind) []const u8 {
    return switch (kind) {
        .@"enum" => "an",
        .@"struct", .@"union" => "a",
    };
}

fn validateReferences(arena: std.mem.Allocator, sidecar: Sidecar, diags: *Diagnostics) error{OutOfMemory}!void {
    var reach = Reach{ .arena = arena, .types = sidecar.types, .diags = diags };

    // The roots: model, msg arms, helper signatures, channels (channel
    // arm names resolve against msg arms in validateChannels; they add
    // no type references of their own).
    if (findStruct(sidecar.types, sidecar.model) == null) {
        if (lookupKind(sidecar.types, sidecar.model)) |found| {
            diags.flag("model", "\"{s}\" names {s} {s} in the type table, but the model root must be a struct — V4", .{ sidecar.model, articleOf(found), @tagName(found) });
        } else {
            diags.flag("model", "\"{s}\" names no struct in the type table — V4", .{sidecar.model});
        }
    } else {
        try reach.visit(sidecar.model);
    }

    for (sidecar.msg.arms, 0..) |arm, index| {
        switch (arm.payload) {
            .void, .bytes, .number, .number_bytes => {},
            .record => |name| {
                if (findStruct(sidecar.types, name) == null) {
                    reach.wrongKind(name, .@"struct", pathOf(arena, "msg.arms[{d}].payload.name", .{index}));
                } else try reach.visit(name);
            },
            .union_ref => |name| {
                if (findUnion(sidecar.types, name) == null) {
                    reach.wrongKind(name, .@"union", pathOf(arena, "msg.arms[{d}].payload.name", .{index}));
                } else try reach.visit(name);
            },
            .enum_ref => |name| {
                if (findEnum(sidecar.types, name) == null) {
                    reach.wrongKind(name, .@"enum", pathOf(arena, "msg.arms[{d}].payload.name", .{index}));
                } else try reach.visit(name);
            },
            .scalar => |ref| try reach.checkRef(ref, pathOf(arena, "msg.arms[{d}].payload.type", .{index})),
        }
    }

    for (sidecar.model_helpers, 0..) |helper, index| {
        try reach.checkRef(helper.returns, pathOf(arena, "model_helpers[{d}].returns", .{index}));
        for (helper.params, 0..) |param, param_index| {
            try reach.checkRef(param, pathOf(arena, "model_helpers[{d}].params[{d}]", .{ index, param_index }));
        }
    }

    // The table lists exactly the reachable types — nothing else (V4's
    // unreachable-entry half).
    for (sidecar.types.structs, 0..) |entry, index| {
        if (!reach.seen.contains(entry.name)) {
            diags.flag(pathOf(arena, "types.structs[{d}]", .{index}), "\"{s}\" is unreachable from model, msg, model_helpers, and channels — the type table lists exactly the reachable types, nothing else (V4)", .{entry.name});
        }
    }
    for (sidecar.types.enums, 0..) |entry, index| {
        if (!reach.seen.contains(entry.name)) {
            diags.flag(pathOf(arena, "types.enums[{d}]", .{index}), "\"{s}\" is unreachable from model, msg, model_helpers, and channels — the type table lists exactly the reachable types, nothing else (V4)", .{entry.name});
        }
    }
    for (sidecar.types.unions, 0..) |entry, index| {
        if (!reach.seen.contains(entry.name)) {
            diags.flag(pathOf(arena, "types.unions[{d}]", .{index}), "\"{s}\" is unreachable from model, msg, model_helpers, and channels — the type table lists exactly the reachable types, nothing else (V4)", .{entry.name});
        }
    }
}

fn validateAcyclic(arena: std.mem.Allocator, sidecar: Sidecar, diags: *Diagnostics) error{OutOfMemory}!void {
    // Iterative colored depth-first walk with an explicit frame stack:
    // any back edge is a cycle, and named-type chains deeper than the
    // reader's bound refuse instead of exhausting every downstream
    // consumer's call stack (recursive state types are refused at
    // compile time by the emitter; a sidecar carrying one is malformed,
    // and nothing real chains hundreds of record types).
    const max_chain_depth = 256;
    const State = enum { unvisited, on_stack, done };
    var states: std.StringArrayHashMapUnmanaged(State) = .empty;
    var depths: std.StringArrayHashMapUnmanaged(usize) = .empty;

    const Frame = struct {
        name: []const u8,
        shape: EntryShape,
        next_edge: usize,
    };

    var roots: std.ArrayListUnmanaged([]const u8) = .empty;
    for (sidecar.types.structs) |entry| try roots.append(arena, entry.name);
    for (sidecar.types.unions) |entry| try roots.append(arena, entry.name);

    var depth_refused = false;
    for (roots.items) |root| {
        if ((states.get(root) orelse .unvisited) != .unvisited) continue;
        var stack: std.ArrayListUnmanaged(Frame) = .empty;
        try states.put(arena, root, .on_stack);
        try stack.append(arena, .{ .name = root, .shape = try entryShape(arena, sidecar.types, root), .next_edge = 0 });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.next_edge < top.shape.edges.len) {
                const child = top.shape.edges[top.next_edge].name;
                top.next_edge += 1;
                switch (states.get(child) orelse .unvisited) {
                    .on_stack => {
                        var cycle: std.ArrayListUnmanaged(u8) = .empty;
                        var started = false;
                        for (stack.items) |frame| {
                            if (!started and !std.mem.eql(u8, frame.name, child)) continue;
                            started = true;
                            try cycle.appendSlice(arena, frame.name);
                            try cycle.appendSlice(arena, " -> ");
                        }
                        try cycle.appendSlice(arena, child);
                        diags.flag("types", "the type reference graph has a cycle ({s}) — recursive state types are refused at compile time and can never be encoded (V5)", .{cycle.items});
                        return;
                    },
                    .done => {},
                    .unvisited => {
                        try states.put(arena, child, .on_stack);
                        try stack.append(arena, .{ .name = child, .shape = try entryShape(arena, sidecar.types, child), .next_edge = 0 });
                    },
                }
                continue;
            }
            // Post-order: the deepest fully expanded value tree under
            // this entry. Structural wrapping and named chains multiply
            // when counted separately, so the bound is on their sum —
            // the depth every downstream walk (encoders, emitters,
            // sample builders) actually recurses to.
            var deepest: usize = top.shape.leaf_levels;
            for (top.shape.edges) |edge| {
                deepest = @max(deepest, edge.wrap + (depths.get(edge.name) orelse 0));
            }
            const depth = deepest + 1;
            try depths.put(arena, top.name, depth);
            try states.put(arena, top.name, .done);
            if (depth > max_chain_depth and !depth_refused) {
                depth_refused = true;
                diags.flag("types", "the value tree under \"{s}\" expands deeper than {d} levels (record chains and optional/slice wrapping both count) — no real contract nests state this deep, and every consumer bounds its walks; flatten the state in the core source", .{ top.name, max_chain_depth });
            }
            _ = stack.pop();
        }
    }
}

/// One named-type edge leaving a table entry: the referenced name and
/// the structural levels (optional/slice) wrapped around the reference
/// at its use site.
const Edge = struct { name: []const u8, wrap: usize };

const EntryShape = struct {
    edges: []const Edge,
    /// The deepest purely structural member (no named reference): its
    /// wrapper count plus the leaf itself.
    leaf_levels: usize,
};

/// The shape of one table entry's members for depth accounting
/// (structural nesting within a reference is bounded by the reader, so
/// the collection recursion is bounded too).
fn entryShape(arena: std.mem.Allocator, types: Types, name: []const u8) error{OutOfMemory}!EntryShape {
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    var leaf_levels: usize = 0;
    if (findStruct(types, name)) |record| {
        for (record.fields) |field| try measureRef(arena, &edges, &leaf_levels, field.type, 0);
    } else if (findUnion(types, name)) |tagged| {
        for (tagged.arms) |arm| try measureRef(arena, &edges, &leaf_levels, arm.payload, 0);
    }
    return .{ .edges = edges.items, .leaf_levels = leaf_levels };
}

fn measureRef(arena: std.mem.Allocator, edges: *std.ArrayListUnmanaged(Edge), leaf_levels: *usize, ref: TypeRef, wrap: usize) error{OutOfMemory}!void {
    switch (ref) {
        .bool, .f64, .i64, .bytes, .void, .enum_ref => leaf_levels.* = @max(leaf_levels.*, wrap + 1),
        .optional => |inner| try measureRef(arena, edges, leaf_levels, inner.*, wrap + 1),
        .slice => |elem| try measureRef(arena, edges, leaf_levels, elem.*, wrap + 1),
        .node, .value, .union_ref => |edge| try edges.append(arena, .{ .name = edge, .wrap = wrap }),
    }
}

fn validateMsg(sidecar: Sidecar, diags: *Diagnostics) void {
    // Tags are positional and dense by construction — there is no
    // explicit tag field to get wrong. The reader checks the u8 bound,
    // and the floor: a valueless union or enum has no declarable mirror
    // form (`union(enum) {}` is not a type) and nothing could ever
    // dispatch or encode it.
    if (sidecar.msg.arms.len == 0) {
        diags.flag("msg.arms", "the message union declares no arms — a core with no messages cannot dispatch; declare at least one arm", .{});
    }
    if (sidecar.msg.arms.len > 256) {
        diags.flag("msg.arms", "{d} arms exceed the 256-arm bound (wire tags ride a u8) — V6", .{sidecar.msg.arms.len});
    }
    // The same u8 bound governs every tabled union (the canonical value
    // encoding carries a one-byte arm index), and the mirror's enums
    // ride enum(u8) with member index = wire value.
    for (sidecar.types.unions, 0..) |entry, index| {
        if (entry.arms.len == 0) {
            diags.flag(pathOfStatic(diags, "types.unions[{d}]", .{index}), "union \"{s}\" declares no arms — a valueless union has no mirror form; declare at least one arm", .{entry.name});
        }
        if (entry.arms.len > 256) {
            diags.flag(pathOfStatic(diags, "types.unions[{d}]", .{index}), "union \"{s}\" has {d} arms; encoded union values carry a one-byte declaration-order arm index (256 arms at most)", .{ entry.name, entry.arms.len });
        }
    }
    for (sidecar.types.enums, 0..) |entry, index| {
        if (entry.members.len == 0) {
            diags.flag(pathOfStatic(diags, "types.enums[{d}]", .{index}), "enum \"{s}\" declares no members — a valueless enum has no mirror form; declare at least one member", .{entry.name});
        }
        if (entry.members.len > 256) {
            diags.flag(pathOfStatic(diags, "types.enums[{d}]", .{index}), "enum \"{s}\" has {d} members; the mirror's enums ride a u8 tag with member index = wire value (256 members at most)", .{ entry.name, entry.members.len });
        }
    }
    for (sidecar.msg.arms, 0..) |arm, index| {
        switch (arm.payload) {
            .number_bytes => |desc| {
                if (std.mem.eql(u8, desc.number_field, desc.bytes_field)) {
                    diags.flag(pathOfStatic(diags, "msg.arms[{d}].payload", .{index}), "number_field and bytes_field are both \"{s}\" — the two field names must be distinct (V7)", .{desc.number_field});
                }
            },
            .scalar => |ref| switch (ref) {
                .void => diags.flag(pathOfStatic(diags, "msg.arms[{d}].payload.type", .{index}), "a scalar descriptor cannot carry void — bare arms use the void descriptor kind (V7)", .{}),
                .node, .value => diags.flag(pathOfStatic(diags, "msg.arms[{d}].payload.type", .{index}), "a scalar descriptor cannot carry a record — record payloads use the record descriptor kind (V7)", .{}),
                else => {},
            },
            else => {},
        }
    }
}

fn pathOfStatic(diags: *Diagnostics, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(diags.arena, fmt, args) catch "";
}

/// The void TypeRef means "no value" and exists for bare union arms
/// only (the schema's stated scope); anywhere else the mirror would
/// declare a valueless slot the snapshot encoding cannot carry.
fn validateVoidPositions(sidecar: Sidecar, diags: *Diagnostics) void {
    for (sidecar.types.structs, 0..) |entry, index| {
        for (entry.fields, 0..) |field, field_index| {
            flagVoid(field.type, pathOfStatic(diags, "types.structs[{d}].fields[{d}].type", .{ index, field_index }), diags);
        }
    }
    for (sidecar.types.unions, 0..) |entry, index| {
        for (entry.arms, 0..) |arm, arm_index| {
            // A bare void arm is the one sanctioned use; void NESTED
            // inside an arm's payload is not.
            if (arm.payload == .void) continue;
            flagVoid(arm.payload, pathOfStatic(diags, "types.unions[{d}].arms[{d}].payload", .{ index, arm_index }), diags);
        }
    }
    for (sidecar.model_helpers, 0..) |helper, index| {
        flagVoid(helper.returns, pathOfStatic(diags, "model_helpers[{d}].returns", .{index}), diags);
        for (helper.params, 0..) |param, param_index| {
            flagVoid(param, pathOfStatic(diags, "model_helpers[{d}].params[{d}]", .{ index, param_index }), diags);
        }
    }
    for (sidecar.msg.arms, 0..) |arm, index| {
        switch (arm.payload) {
            .scalar => |ref| flagVoid(ref, pathOfStatic(diags, "msg.arms[{d}].payload.type", .{index}), diags),
            else => {},
        }
    }
}

fn flagVoid(ref: TypeRef, at: []const u8, diags: *Diagnostics) void {
    switch (ref) {
        .void => diags.flag(at, "the void TypeRef carries no value and is legal only as a bare union arm payload — this slot needs a value type", .{}),
        .optional => |inner| flagVoid(inner.*, at, diags),
        .slice => |elem| flagVoid(elem.*, at, diags),
        else => {},
    }
}

fn validateUnbound(sidecar: Sidecar, diags: *Diagnostics) void {
    const model = findStruct(sidecar.types, sidecar.model) orelse return;
    // The opt-out vocabulary spans everything a view could bind on the
    // model: its fields AND its exported helpers (helpers surface as
    // bindable model methods, so an author can declare one
    // intentionally unbound). The schema's V8 wording says "field";
    // the reader accepts the helper case the dead-state lint actually
    // covers — see SCHEMA-GAPS.md.
    outer: for (sidecar.model_unbound, 0..) |name, index| {
        for (model.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) continue :outer;
        }
        for (sidecar.model_helpers) |helper| {
            if (std.mem.eql(u8, helper.name, name)) continue :outer;
        }
        diags.flag(pathOfStatic(diags, "model_unbound[{d}]", .{index}), "\"{s}\" is neither a field of the model struct \"{s}\" nor an exported helper (V8)", .{ name, sidecar.model });
    }
    outer: for (sidecar.msg.unbound, 0..) |name, index| {
        for (sidecar.msg.arms) |arm| {
            if (std.mem.eql(u8, arm.name, name)) continue :outer;
        }
        diags.flag(pathOfStatic(diags, "msg.unbound[{d}]", .{index}), "\"{s}\" is not an arm of the message union (V8)", .{name});
    }
}

pub fn findArm(msg: Msg, name: []const u8) ?*const MsgArm {
    for (msg.arms) |*arm| {
        if (std.mem.eql(u8, arm.name, name)) return arm;
    }
    return null;
}

fn exportListed(sidecar: Sidecar, suffix: []const u8) bool {
    return abiHasExport(sidecar.abi, suffix);
}

fn abiHasExport(abi: Abi, suffix: []const u8) bool {
    for (abi.exports) |entry| {
        if (std.mem.eql(u8, entry, suffix)) return true;
    }
    return false;
}

fn validateChannels(sidecar: Sidecar, diags: *Diagnostics) void {
    const record_channels = [_]struct { name: []const u8, arm: ?[]const u8 }{
        .{ .name = "appearance_msg", .arm = sidecar.channels.appearance_msg },
        .{ .name = "chrome_msg", .arm = sidecar.channels.chrome_msg },
    };
    for (record_channels) |channel| {
        const arm_name = channel.arm orelse continue;
        const at = pathOfStatic(diags, "channels.{s}", .{channel.name});
        const arm = findArm(sidecar.msg, arm_name) orelse {
            diags.flag(at, "\"{s}\" names no arm of the message union (V9)", .{arm_name});
            continue;
        };
        switch (arm.payload) {
            .record, .union_ref, .enum_ref, .scalar => {},
            else => diags.flag(at, "arm \"{s}\" has a {s} payload descriptor, but this channel requires the named-type family (record/union/enum/scalar) — the host constructs the arm's payload itself, so it must learn the shape from the type table (V9)", .{ arm_name, @tagName(arm.payload) }),
        }
    }

    outer: for (sidecar.channels.env_msgs, 0..) |entry, index| {
        const at = pathOfStatic(diags, "channels.env_msgs[{d}].msg", .{index});
        const arm = findArm(sidecar.msg, entry.msg) orelse {
            diags.flag(at, "\"{s}\" names no arm of the message union (V9)", .{entry.msg});
            continue :outer;
        };
        if (arm.payload != .bytes) {
            diags.flag(at, "arm \"{s}\" has a {s} payload descriptor, but environment channels deliver the variable's value as bytes, so the target arm's descriptor must be bytes (V9)", .{ entry.msg, @tagName(arm.payload) });
        }
    }

    const function_channels = [_]struct { name: []const u8, wired: bool }{
        .{ .name = "command_msg", .wired = sidecar.channels.command_msg },
        .{ .name = "frame_msg", .wired = sidecar.channels.frame_msg },
        .{ .name = "key_msg", .wired = sidecar.channels.key_msg },
        .{ .name = "pinch_msg", .wired = sidecar.channels.pinch_msg },
        .{ .name = "drop_msg", .wired = sidecar.channels.drop_msg },
    };
    for (function_channels) |channel| {
        const listed = exportListed(sidecar, channel.name);
        if (channel.wired and !listed) {
            diags.flag(pathOfStatic(diags, "channels.{s}", .{channel.name}), "the channel is declared wired but \"{s}\" is missing from abi.exports — presence is biconditional (V9)", .{channel.name});
        }
        if (!channel.wired and listed) {
            diags.flag("abi.exports", "\"{s}\" is listed but channels.{s} is false — presence is biconditional (V9)", .{ channel.name, channel.name });
        }
    }
}

fn validateAbi(sidecar: Sidecar, diags: *Diagnostics) void {
    // The list must be exactly: every unconditional suffix, then the
    // wired conditional suffixes, in the normative canonical order —
    // identity getters, mode-provided entries (set_panic_sink, init,
    // collect, frame_reset), then the entry-point map. The "and the
    // object exports nothing else" half needs the object and runs at
    // link time.
    var cursor: usize = 0;
    for (unconditional_exports) |suffix| {
        if (cursor < sidecar.abi.exports.len and std.mem.eql(u8, sidecar.abi.exports[cursor], suffix)) {
            cursor += 1;
        } else {
            diags.flag(pathOfStatic(diags, "abi.exports[{d}]", .{cursor}), "expected the unconditional export \"{s}\" here — abi.exports lists every unconditional suffix, then the wired channel entries, in the canonical order: identity getters (abi_version, build_id), the mode-provided entries (set_panic_sink, init, collect, frame_reset), then the entry-point map (V11)", .{suffix});
            return;
        }
    }
    for (conditional_exports) |suffix| {
        if (cursor < sidecar.abi.exports.len and std.mem.eql(u8, sidecar.abi.exports[cursor], suffix)) {
            cursor += 1;
        }
    }
    if (cursor < sidecar.abi.exports.len) {
        diags.flag(pathOfStatic(diags, "abi.exports[{d}]", .{cursor}), "\"{s}\" is not an export suffix of ABI version {d} (or is out of canonical order) — V11", .{ sidecar.abi.exports[cursor], supported_abi_version });
    }
}

pub const SlotPath = struct {
    path: []const u8,
    /// Whether any joined component itself contains a dot (the grammar
    /// cannot address such a slot unambiguously).
    components_dotted: bool,
};

fn dotted(names: []const []const u8) bool {
    for (names) |name| {
        if (std.mem.indexOfScalar(u8, name, '.') != null) return true;
    }
    return false;
}

/// The slot spellings V10's bijection is checked against: every i64
/// spelling in the sidecar, at its schema-defined slot path.
pub fn collectIntegerSlotPaths(arena: std.mem.Allocator, sidecar: Sidecar) error{OutOfMemory}![]const SlotPath {
    var paths: std.ArrayListUnmanaged(SlotPath) = .empty;
    for (sidecar.types.structs) |entry| {
        for (entry.fields) |field| {
            if (spellsInteger(field.type)) {
                try paths.append(arena, .{ .path = try std.fmt.allocPrint(arena, "{s}.{s}", .{ entry.name, field.name }), .components_dotted = dotted(&.{ entry.name, field.name }) });
            }
        }
    }
    for (sidecar.types.unions) |entry| {
        for (entry.arms) |arm| {
            if (spellsInteger(arm.payload)) {
                try paths.append(arena, .{ .path = try std.fmt.allocPrint(arena, "{s}.{s}", .{ entry.name, arm.name }), .components_dotted = dotted(&.{ entry.name, arm.name }) });
            }
        }
    }
    // The message-side path forms spell the union's AUTHORED name —
    // an app whose union is named Action spells its slots
    // `Action.<arm>`, never a literal `Msg` token.
    for (sidecar.msg.arms) |arm| {
        switch (arm.payload) {
            .number => |class| if (class == .i64) {
                try paths.append(arena, .{ .path = try std.fmt.allocPrint(arena, "{s}.{s}", .{ sidecar.msg.name, arm.name }), .components_dotted = dotted(&.{ sidecar.msg.name, arm.name }) });
            },
            .number_bytes => |desc| if (desc.number_class == .i64) {
                try paths.append(arena, .{ .path = try std.fmt.allocPrint(arena, "{s}.{s}.{s}", .{ sidecar.msg.name, arm.name, desc.number_field }), .components_dotted = dotted(&.{ sidecar.msg.name, arm.name, desc.number_field }) });
            },
            .scalar => |ref| if (spellsInteger(ref)) {
                try paths.append(arena, .{ .path = try std.fmt.allocPrint(arena, "{s}.{s}", .{ sidecar.msg.name, arm.name }), .components_dotted = dotted(&.{ sidecar.msg.name, arm.name }) });
            },
            else => {},
        }
    }
    for (sidecar.model_helpers) |helper| {
        if (spellsInteger(helper.returns)) {
            try paths.append(arena, .{ .path = try std.fmt.allocPrint(arena, "helpers.{s}.return", .{helper.name}), .components_dotted = dotted(&.{helper.name}) });
        }
        for (helper.params, 0..) |param, index| {
            if (spellsInteger(param)) {
                try paths.append(arena, .{ .path = try std.fmt.allocPrint(arena, "helpers.{s}.params[{d}]", .{ helper.name, index }), .components_dotted = dotted(&.{helper.name}) });
            }
        }
    }
    return paths.items;
}

/// Whether a TypeRef spells i64 at its own slot (through optionals; a
/// slice element is its own slot grammar problem and the schema defines
/// no path for it, so a slice of i64 cannot be attested — the emitter
/// spells such elements f64 until the schema grows a path form).
fn spellsInteger(ref: TypeRef) bool {
    return switch (ref) {
        .i64 => true,
        .optional => |inner| spellsInteger(inner.*),
        else => false,
    };
}

/// What an `integer_slots` entry's path names once resolved against the
/// sidecar's own tables under the format-1 slot-path grammar.
pub const SlotTarget = union(enum) {
    /// A slot the sidecar spells i64 — an attestable target.
    integer,
    /// A real slot, spelled or classed as described — not attestable.
    not_integer: []const u8,
    /// A sequence whose elements spell an integer: the format-1 grammar
    /// has no slice-element form, so no path can attest it.
    slice_element,
    /// No grammar form reaches a slot of this spelling.
    unresolved,
};

fn refSpelling(ref: TypeRef) []const u8 {
    return switch (ref) {
        .bool => "bool",
        .f64 => "f64",
        .i64 => "i64",
        .bytes => "bytes",
        .void => "void",
        .optional => |inner| refSpelling(inner.*),
        .slice => "a slice",
        .node, .value => "a record",
        .enum_ref => "an enum",
        .union_ref => "a union",
    };
}

fn wrapsInteger(ref: TypeRef) bool {
    return switch (ref) {
        .i64 => true,
        .optional => |inner| wrapsInteger(inner.*),
        .slice => |elem| wrapsInteger(elem.*),
        else => false,
    };
}

/// Classify the TypeRef a resolved path lands on: i64 through optionals
/// is the attestable shape; an integer buried under a slice is the
/// grammar's known gap; everything else is a real slot of another
/// spelling.
fn classifyRef(ref: TypeRef) SlotTarget {
    return switch (ref) {
        .i64 => .integer,
        .optional => |inner| classifyRef(inner.*),
        .slice => |elem| if (wrapsInteger(elem.*)) .slice_element else .{ .not_integer = "a slice" },
        else => .{ .not_integer = refSpelling(ref) },
    };
}

fn classifyNumberClass(class: NumberClass) SlotTarget {
    return switch (class) {
        .i64 => .integer,
        .f64 => .{ .not_integer = "f64" },
    };
}

/// Resolve one slot path against the sidecar's tables. The grammar's
/// forms, each segment the author's spelling: `<TypeName>.<field>` (a
/// struct field, or a non-msg union arm's payload),
/// `<msgName>.<arm>` (a scalar-number arm), `<msgName>.<arm>.<field>`
/// (a number_bytes arm's number field), `helpers.<name>.return`, and
/// `helpers.<name>.params[<index>]`.
pub fn resolveSlotPath(sidecar: Sidecar, path: []const u8) SlotTarget {
    var segments: [4][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |segment| {
        if (segment.len == 0) return .unresolved;
        if (count == segments.len) return .unresolved;
        segments[count] = segment;
        count += 1;
    }

    if (count == 3 and std.mem.eql(u8, segments[0], "helpers")) {
        for (sidecar.model_helpers) |helper| {
            if (!std.mem.eql(u8, helper.name, segments[1])) continue;
            if (std.mem.eql(u8, segments[2], "return")) return classifyRef(helper.returns);
            if (std.mem.startsWith(u8, segments[2], "params[") and std.mem.endsWith(u8, segments[2], "]")) {
                const digits = segments[2]["params[".len .. segments[2].len - 1];
                const index = std.fmt.parseInt(usize, digits, 10) catch return .unresolved;
                if (index >= helper.params.len) return .unresolved;
                return classifyRef(helper.params[index]);
            }
            return .unresolved;
        }
        return .unresolved;
    }

    if (std.mem.eql(u8, segments[0], sidecar.msg.name)) {
        if (count == 2) {
            if (findArm(sidecar.msg, segments[1])) |arm| {
                return switch (arm.payload) {
                    .number => |class| classifyNumberClass(class),
                    .scalar => |ref| classifyRef(ref),
                    .void => .{ .not_integer = "void" },
                    .bytes => .{ .not_integer = "bytes" },
                    .number_bytes => .{ .not_integer = "a number_bytes record (its number field is the slot)" },
                    .record => .{ .not_integer = "a record" },
                    .union_ref => .{ .not_integer = "a union" },
                    .enum_ref => .{ .not_integer = "an enum" },
                };
            }
        }
        if (count == 3) {
            if (findArm(sidecar.msg, segments[1])) |arm| {
                switch (arm.payload) {
                    .number_bytes => |desc| {
                        if (std.mem.eql(u8, segments[2], desc.number_field)) return classifyNumberClass(desc.number_class);
                        if (std.mem.eql(u8, segments[2], desc.bytes_field)) return .{ .not_integer = "bytes" };
                    },
                    else => {},
                }
            }
            return .unresolved;
        }
    }

    if (count == 2) {
        if (findStruct(sidecar.types, segments[0])) |record| {
            for (record.fields) |field| {
                if (std.mem.eql(u8, field.name, segments[1])) return classifyRef(field.type);
            }
            return .unresolved;
        }
        if (findUnion(sidecar.types, segments[0])) |tagged| {
            for (tagged.arms) |arm| {
                if (std.mem.eql(u8, arm.name, segments[1])) return classifyRef(arm.payload);
            }
            return .unresolved;
        }
    }
    return .unresolved;
}

fn validateIntegerSlots(arena: std.mem.Allocator, sidecar: Sidecar, diags: *Diagnostics) error{OutOfMemory}!void {
    const expected = try collectIntegerSlotPaths(arena, sidecar);

    // The path grammar joins components with dots, so a component
    // carrying its own dot would make two different slots spell one
    // path — the bijection would silently thin. Refuse the ambiguity at
    // its source.
    for (expected) |path| {
        if (path.components_dotted) {
            diags.flag("integer_slots", "the i64 slot at \"{s}\" involves a name containing '.', which the slot path grammar cannot address unambiguously — rename it in the core source (V10)", .{path.path});
        }
    }
    // Two DISTINCT slots spelling one path is the same ambiguity from
    // another direction (a message union named `helpers` whose
    // number_bytes field spells a helper's return slot, a table type
    // sharing the message union's name): the bijection would consume
    // entries interchangeably and one attestation would silently govern
    // both slots.
    for (expected, 0..) |path, index| {
        for (expected[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.path, path.path)) {
                diags.flag("integer_slots", "two distinct i64 slots spell the one path \"{s}\" — the slot-path grammar cannot address them separately, so their attestations cannot be told apart; rename one of the colliding surfaces in the core source (V10)", .{path.path});
            }
        }
    }
    if (diags.hasErrors()) return;

    // One-to-one both ways: every expected slot consumes exactly one
    // entry, and no entry is left over or spent twice.
    const consumed = try arena.alloc(bool, sidecar.integer_slots.len);
    @memset(consumed, false);
    outer: for (expected) |path| {
        for (sidecar.integer_slots, 0..) |slot, index| {
            if (!consumed[index] and std.mem.eql(u8, slot.slot, path.path)) {
                consumed[index] = true;
                continue :outer;
            }
        }
        diags.flag("integer_slots", "the sidecar spells \"{s}\" i64 but attests no integer_slots entry for it — every i64 spelling has exactly one entry (V10)", .{path.path});
    }
    for (sidecar.integer_slots, 0..) |slot, index| {
        if (consumed[index]) continue;
        var duplicate = false;
        for (sidecar.integer_slots[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.slot, slot.slot)) duplicate = true;
        }
        const at = pathOfStatic(diags, "integer_slots[{d}].slot", .{index});
        if (duplicate) {
            diags.flag(at, "duplicate entry for \"{s}\" — every i64 slot has exactly one entry (V10)", .{slot.slot});
            continue;
        }
        // The entry consumed nothing: resolve its path structurally so
        // the teaching names what actually went wrong instead of one
        // generic mismatch.
        switch (resolveSlotPath(sidecar, slot.slot)) {
            .integer => diags.flag(at, "\"{s}\" resolves to no slot the sidecar spells i64 — every entry must name a real i64 slot (V10)", .{slot.slot}),
            .not_integer => |spelling| diags.flag(at, "\"{s}\" resolves to a slot the sidecar spells {s}, not i64 — an attested integer class must sit on an i64 spelling (V10)", .{ slot.slot, spelling }),
            .slice_element => diags.flag(at, "\"{s}\" addresses a sequence — the format-1 slot-path grammar has no slice-element form, so slice elements are never integer-attested; the emitter spells them f64 and readers exempt them from the bijection (V10)", .{slot.slot}),
            .unresolved => diags.flag(at, "\"{s}\" resolves against none of the sidecar's own tables — slot paths name a record field or union arm (<Type>.<name>), a message payload (\"{s}.<arm>\" or \"{s}.<arm>.<numberField>\"), or a helper signature slot (helpers.<name>.return, helpers.<name>.params[<index>]) (V10)", .{ slot.slot, sidecar.msg.name, sidecar.msg.name }),
        }
    }
}

/// Restate a validated sidecar after applying record-slot f64 demotions.
/// Mutating the dynamic document instead of serializing the typed reader
/// preserves unknown additive fields for newer producers. The caller first
/// validates each path against the typed contract, so a miss here is internal
/// projection drift rather than user input.
pub fn projectF64SlotsJson(arena: std.mem.Allocator, source: []const u8, f64_slots: []const []const u8) ![]const u8 {
    if (f64_slots.len == 0) return source;

    var root = try std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{});
    const types = root.object.getPtr("types").?;
    const structs = types.object.getPtr("structs").?;
    for (f64_slots) |slot_path| {
        const dot = std.mem.indexOfScalar(u8, slot_path, '.') orelse return error.ProjectionDrift;
        const container = slot_path[0..dot];
        const field_name = slot_path[dot + 1 ..];
        var changed = false;
        for (structs.array.items) |*entry| {
            if (!std.mem.eql(u8, entry.object.get("name").?.string, container)) continue;
            const fields = entry.object.getPtr("fields").?;
            for (fields.array.items) |*field| {
                if (!std.mem.eql(u8, field.object.get("name").?.string, field_name)) continue;
                const ref = field.object.getPtr("type").?;
                const kind = ref.object.getPtr("kind").?;
                if (std.mem.eql(u8, kind.string, "optional")) {
                    const inner = ref.object.getPtr("inner").?;
                    inner.object.getPtr("kind").?.* = .{ .string = "f64" };
                } else {
                    kind.* = .{ .string = "f64" };
                }
                changed = true;
                break;
            }
            break;
        }
        if (!changed) return error.ProjectionDrift;
    }

    const attestations = root.object.getPtr("integer_slots").?;
    var index: usize = 0;
    while (index < attestations.array.items.len) {
        const slot = attestations.array.items[index].object.get("slot").?.string;
        const demoted = for (f64_slots) |candidate| {
            if (std.mem.eql(u8, slot, candidate)) break true;
        } else false;
        if (demoted) {
            _ = attestations.array.orderedRemove(index);
        } else {
            index += 1;
        }
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try json.write(root);
    try out.writer.writeByte('\n');
    return out.written();
}

// --------------------------------------------------------------- tests

const testing = std.testing;

/// A minimal valid sidecar the refusal tests perturb: one model struct,
/// two message arms, no helpers, no channels.
pub const minimal_valid_json =
    \\{
    \\  "format": 1,
    \\  "wire_version": 6,
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
    const source = try replaced(arena_state.allocator(), minimal_valid_json, "\"wire_version\": 6", "\"wire_version\": 7");
    try expectRefusal(source, "wire_version", "generation 6, the sidecar declares 7");
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
