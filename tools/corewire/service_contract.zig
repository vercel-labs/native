//! Reader/validator for services.contract.json (typed service seam).

const std = @import("std");

pub const max_bytes: usize = 4 * 1024 * 1024;
pub const supported_format: i64 = 3;
pub const supported_protocol: i64 = 3;

pub const TypeKind = enum { none, bool, f64, i64, bytes, optional, slice, record, @"enum", @"union" };

pub const TypeRef = struct {
    kind: TypeKind,
    inner: ?*const TypeRef = null,
    elem: ?*const TypeRef = null,
    name: ?[]const u8 = null,
};

pub const Field = struct { name: []const u8, type: TypeRef };
pub const RecordType = struct { name: []const u8, origin: []const u8, fields: []const Field };
pub const EnumType = struct { name: []const u8, origin: []const u8, members: []const []const u8 };
pub const UnionArm = struct { name: []const u8, fields: []const Field };
pub const UnionType = struct { name: []const u8, origin: []const u8, arms: []const UnionArm };
pub const Types = struct {
    records: []const RecordType,
    enums: []const EnumType,
    unions: []const UnionType,
};

pub const Package = struct {
    name: []const u8,
    version: []const u8,
    content_hash: []const u8,
};

pub const Operation = struct {
    name: []const u8,
    client: []const u8,
    module: []const u8,
    @"export": []const u8,
    request: TypeRef,
    result: TypeRef,
    deadline_ms: ?i64,
    cancellable: bool,
    stream: ?struct { chunk: TypeRef, in_flight: i64 },
    source_hash: []const u8,
};

pub const Contract = struct {
    format: i64,
    protocol_version: i64,
    compiler_version: []const u8,
    deterministic: bool,
    packages: []const Package,
    types: Types,
    operations: []const Operation,
};

pub const Error = error{ InvalidContract, OutOfMemory, WriteFailed };

pub fn read(arena: std.mem.Allocator, source: []const u8, writer: *std.Io.Writer) Error!Contract {
    const parsed = std.json.parseFromSliceLeaky(Contract, arena, source, .{ .ignore_unknown_fields = false }) catch |err| {
        try writer.print("corewire: services contract is not valid schema-2 JSON: {t}\n", .{err});
        return error.InvalidContract;
    };
    try @import("service_projection.zig").validate(arena, parsed, writer);
    return parsed;
}

test "service contract validates typed operations and authority attestation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const good =
        \\{"format":3,"protocol_version":3,"compiler_version":"1.2.3","deterministic":false,"packages":[],"types":{"records":[],"enums":[],"unions":[]},"operations":[{"name":"feeds.parse","client":"feedsParse","module":"src/services/feeds.ts","export":"parse","request":{"kind":"bytes"},"result":{"kind":"bytes"},"deadline_ms":null,"cancellable":false,"stream":null,"source_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
    ;
    var diagnostics: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&diagnostics);
    const contract = try read(arena, good, &writer);
    try std.testing.expectEqual(@as(usize, 1), contract.operations.len);
    try std.testing.expectEqualStrings("feeds.parse", contract.operations[0].name);

    const dollar =
        \\{"format":3,"protocol_version":3,"compiler_version":"1.2.3","deterministic":false,"packages":[],"types":{"records":[],"enums":[],"unions":[]},"operations":[{"name":"feeds.$parse","client":"feeds$parse","module":"src/services/feeds.ts","export":"$parse","request":{"kind":"bytes"},"result":{"kind":"bytes"},"deadline_ms":null,"cancellable":true,"stream":null,"source_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
    ;
    var dollar_diagnostics: [512]u8 = undefined;
    var dollar_writer = std.Io.Writer.fixed(&dollar_diagnostics);
    const dollar_contract = try read(arena, dollar, &dollar_writer);
    try std.testing.expectEqualStrings("$parse", dollar_contract.operations[0].@"export");

    const bad =
        \\{"format":3,"protocol_version":3,"compiler_version":"1.2.3","deterministic":true,"packages":[],"types":{"records":[],"enums":[],"unions":[]},"operations":[{"name":"feeds.parse","client":"feedsParse","module":"src/services/feeds.ts","export":"parse","request":{"kind":"bytes"},"result":{"kind":"bytes"},"deadline_ms":null,"cancellable":false,"stream":null,"source_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
    ;
    var bad_diagnostics: [512]u8 = undefined;
    var bad_writer = std.Io.Writer.fixed(&bad_diagnostics);
    try std.testing.expectError(error.InvalidContract, read(arena, bad, &bad_writer));
    try std.testing.expect(std.mem.indexOf(u8, bad_writer.buffered(), "deterministic=true") != null);

    const skewed =
        \\{"format":3,"protocol_version":3,"compiler_version":"1.2.3","deterministic":false,"packages":[],"types":{"records":[],"enums":[],"unions":[]},"operations":[{"name":"other.parse","client":"otherParse","module":"src/services/feeds.ts","export":"parse","request":{"kind":"bytes"},"result":{"kind":"bytes"},"deadline_ms":null,"cancellable":false,"stream":null,"source_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
    ;
    var skewed_diagnostics: [512]u8 = undefined;
    var skewed_writer = std.Io.Writer.fixed(&skewed_diagnostics);
    try std.testing.expectError(error.InvalidContract, read(arena, skewed, &skewed_writer));
    try std.testing.expect(std.mem.indexOf(u8, skewed_writer.buffered(), "does not match module basename") != null);
}
