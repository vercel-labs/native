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
    var failed = false;
    if (parsed.format != supported_format) {
        try writer.print("corewire: services contract format is {d}, expected {d}\n", .{ parsed.format, supported_format });
        failed = true;
    }
    if (parsed.protocol_version != supported_protocol) {
        try writer.print("corewire: service protocol is {d}, expected {d}\n", .{ parsed.protocol_version, supported_protocol });
        failed = true;
    }
    if (parsed.deterministic) {
        try writer.print("corewire: a service contract may not attest deterministic=true — ambient authority is the service class's visible distinction\n", .{});
        failed = true;
    }
    if (!exactVersion(parsed.compiler_version)) {
        try writer.print("corewire: services contract compiler_version \"{s}\" is not an exact X.Y.Z pin\n", .{parsed.compiler_version});
        failed = true;
    }
    if (parsed.operations.len == 0) {
        try writer.print("corewire: services contract contains no operations\n", .{});
        failed = true;
    }
    for (parsed.operations, 0..) |op, index| {
        if (!operationName(op.name)) {
            try writer.print("corewire: operations[{d}].name \"{s}\" is not <module>.<export>\n", .{ index, op.name });
            failed = true;
        }
        if (!identifier(op.client)) {
            try writer.print("corewire: operations[{d}].client \"{s}\" is not a TypeScript identifier\n", .{ index, op.client });
            failed = true;
        }
        if (!std.mem.startsWith(u8, op.module, "src/services/") or !std.mem.endsWith(u8, op.module, ".ts") or std.mem.indexOf(u8, op.module, "..") != null) {
            try writer.print("corewire: operations[{d}].module \"{s}\" is not a safe src/services/*.ts path\n", .{ index, op.module });
            failed = true;
        }
        if (!identifier(op.@"export")) {
            try writer.print("corewire: operations[{d}].export \"{s}\" is not a TypeScript identifier\n", .{ index, op.@"export" });
            failed = true;
        }
        if (!nameMatchesDeclaration(op)) {
            try writer.print("corewire: operations[{d}].name \"{s}\" does not match module basename \"{s}\" and export \"{s}\"\n", .{ index, op.name, std.fs.path.basename(op.module), op.@"export" });
            failed = true;
        }
        if (op.source_hash.len != 64 or !allHex(op.source_hash)) {
            try writer.print("corewire: operations[{d}].source_hash is not a lowercase SHA-256 hex digest\n", .{index});
            failed = true;
        }
        if (op.result.kind == .none) {
            try writer.print("corewire: operations[{d}].result may not be void\n", .{index});
            failed = true;
        }
        if (!validTypeRef(op.request) or !validTypeRef(op.result)) {
            try writer.print("corewire: operations[{d}] carries an invalid type reference\n", .{index});
            failed = true;
        }
        if (op.deadline_ms) |deadline| {
            if (deadline < 1 or deadline > 86_400_000) {
                try writer.print("corewire: operations[{d}].deadline_ms is outside 1..86400000\n", .{index});
                failed = true;
            }
        }
        if (op.stream) |stream| {
            if (!validTypeRef(stream.chunk) or stream.chunk.kind == .none or stream.in_flight < 1 or stream.in_flight > 64) {
                try writer.print("corewire: operations[{d}].stream must carry an encodable chunk and a 1..64 in_flight cap\n", .{index});
                failed = true;
            }
        }
        for (parsed.operations[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, op.name)) {
                try writer.print("corewire: duplicate service operation name \"{s}\"\n", .{op.name});
                failed = true;
            }
        }
    }
    for (parsed.packages, 0..) |package_entry, index| {
        if (!npmPackageName(package_entry.name) or !exactVersion(package_entry.version) or package_entry.content_hash.len != 64 or !allHex(package_entry.content_hash)) {
            try writer.print("corewire: packages[{d}] must carry name, exact version, and a lowercase SHA-256 content_hash\n", .{index});
            failed = true;
        }
        for (parsed.packages[0..index]) |earlier| if (std.mem.eql(u8, earlier.name, package_entry.name)) {
            try writer.print("corewire: duplicate service package \"{s}\"\n", .{package_entry.name});
            failed = true;
        };
    }
    if (failed) return error.InvalidContract;
    return parsed;
}

fn validTypeRef(ref: TypeRef) bool {
    return switch (ref.kind) {
        .none, .bool, .f64, .i64, .bytes => ref.inner == null and ref.elem == null and ref.name == null,
        .optional => ref.inner != null and ref.elem == null and ref.name == null and validTypeRef(ref.inner.?.*),
        .slice => ref.elem != null and ref.inner == null and ref.name == null and validTypeRef(ref.elem.?.*),
        .record, .@"enum", .@"union" => ref.name != null and ref.name.?.len > 0 and ref.inner == null and ref.elem == null,
    };
}

fn exactVersion(value: []const u8) bool {
    var parts = std.mem.splitScalar(u8, value, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        for (part) |byte| if (!std.ascii.isDigit(byte)) return false;
        count += 1;
    }
    return count == 3;
}

fn npmPackageName(value: []const u8) bool {
    if (value.len == 0) return false;
    const plain = struct {
        fn valid(name: []const u8) bool {
            if (name.len == 0) return false;
            for (name) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-')) return false;
            return true;
        }
    }.valid;
    if (value[0] != '@') return plain(value);
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return false;
    return slash > 1 and slash + 1 < value.len and
        std.mem.indexOfScalar(u8, value[slash + 1 ..], '/') == null and
        plain(value[1..slash]) and plain(value[slash + 1 ..]);
}

fn operationName(value: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, value, '.') orelse return false;
    return dot > 0 and identifier(value[dot + 1 ..]);
}

fn nameMatchesDeclaration(op: Operation) bool {
    const basename = std.fs.path.basename(op.module);
    if (!std.mem.endsWith(u8, basename, ".ts")) return false;
    const module_name = basename[0 .. basename.len - ".ts".len];
    if (op.name.len != module_name.len + 1 + op.@"export".len) return false;
    return std.mem.eql(u8, op.name[0..module_name.len], module_name) and
        op.name[module_name.len] == '.' and
        std.mem.eql(u8, op.name[module_name.len + 1 ..], op.@"export");
}

fn identifier(value: []const u8) bool {
    if (value.len == 0 or !(std.ascii.isAlphabetic(value[0]) or value[0] == '_' or value[0] == '$')) return false;
    for (value[1..]) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$')) return false;
    return true;
}

fn allHex(value: []const u8) bool {
    for (value) |byte| if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return false;
    return true;
}

test "service contract validates typed operations and authority attestation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const good =
        \\{"format":3,"protocol_version":3,"compiler_version":"0.0.29","deterministic":false,"packages":[],"types":{"records":[],"enums":[],"unions":[]},"operations":[{"name":"feeds.parse","client":"feedsParse","module":"src/services/feeds.ts","export":"parse","request":{"kind":"bytes"},"result":{"kind":"bytes"},"deadline_ms":null,"cancellable":false,"stream":null,"source_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
    ;
    var diagnostics: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&diagnostics);
    const contract = try read(arena, good, &writer);
    try std.testing.expectEqual(@as(usize, 1), contract.operations.len);
    try std.testing.expectEqualStrings("feeds.parse", contract.operations[0].name);

    const dollar =
        \\{"format":3,"protocol_version":3,"compiler_version":"0.0.29","deterministic":false,"packages":[],"types":{"records":[],"enums":[],"unions":[]},"operations":[{"name":"feeds.$parse","client":"feeds$parse","module":"src/services/feeds.ts","export":"$parse","request":{"kind":"bytes"},"result":{"kind":"bytes"},"deadline_ms":null,"cancellable":true,"stream":null,"source_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
    ;
    var dollar_diagnostics: [512]u8 = undefined;
    var dollar_writer = std.Io.Writer.fixed(&dollar_diagnostics);
    const dollar_contract = try read(arena, dollar, &dollar_writer);
    try std.testing.expectEqualStrings("$parse", dollar_contract.operations[0].@"export");

    const bad =
        \\{"format":3,"protocol_version":3,"compiler_version":"0.0.29","deterministic":true,"packages":[],"types":{"records":[],"enums":[],"unions":[]},"operations":[{"name":"feeds.parse","client":"feedsParse","module":"src/services/feeds.ts","export":"parse","request":{"kind":"bytes"},"result":{"kind":"bytes"},"deadline_ms":null,"cancellable":false,"stream":null,"source_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
    ;
    var bad_diagnostics: [512]u8 = undefined;
    var bad_writer = std.Io.Writer.fixed(&bad_diagnostics);
    try std.testing.expectError(error.InvalidContract, read(arena, bad, &bad_writer));
    try std.testing.expect(std.mem.indexOf(u8, bad_writer.buffered(), "deterministic=true") != null);

    const skewed =
        \\{"format":3,"protocol_version":3,"compiler_version":"0.0.29","deterministic":false,"packages":[],"types":{"records":[],"enums":[],"unions":[]},"operations":[{"name":"other.parse","client":"otherParse","module":"src/services/feeds.ts","export":"parse","request":{"kind":"bytes"},"result":{"kind":"bytes"},"deadline_ms":null,"cancellable":false,"stream":null,"source_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
    ;
    var skewed_diagnostics: [512]u8 = undefined;
    var skewed_writer = std.Io.Writer.fixed(&skewed_diagnostics);
    try std.testing.expectError(error.InvalidContract, read(arena, skewed, &skewed_writer));
    try std.testing.expect(std.mem.indexOf(u8, skewed_writer.buffered(), "does not match module basename") != null);
}
