//! Native structural and owned-byte adapter for compiled service generation.
const std = @import("std");
const service = @import("service_contract.zig");
const projection = @import("service_projection.zig");

fn generate(arena: std.mem.Allocator, contract: service.Contract, name: []const u8) ![]const u8 {
    const input = try std.json.Stringify.valueAlloc(arena, contract, .{});
    defer arena.free(input);
    return projection.generate(arena, input, name, "");
}
pub fn emitHost(arena: std.mem.Allocator, contract: service.Contract) ![]const u8 {
    return generate(arena, contract, "host");
}
pub fn emitRegistry(arena: std.mem.Allocator, contract: service.Contract) ![]const u8 {
    return generate(arena, contract, "registry");
}
pub fn emitClient(arena: std.mem.Allocator, contract: service.Contract) ![]const u8 {
    return generate(arena, contract, "client");
}
pub fn emitInprocMain(arena: std.mem.Allocator, contract: service.Contract) ![]const u8 {
    return generate(arena, contract, "inproc");
}
pub fn emitInprocProfile(arena: std.mem.Allocator, optimization: ?[]const u8) ![]const u8 {
    return projection.generate(arena, "{}", "profile", optimization orelse "");
}

test "service projection derives host dispatch and registry from one contract" {
    const bytes_type: service.TypeRef = .{ .kind = .bytes };
    const optional_bytes: service.TypeRef = .{ .kind = .optional, .inner = &bytes_type };
    const slice_optional_bytes: service.TypeRef = .{ .kind = .slice, .elem = &optional_bytes };
    const operations = [_]service.Operation{
        .{
            .name = "feeds.parse",
            .client = "feedsParse",
            .module = "src/services/feeds.ts",
            .@"export" = "parse",
            .request = .{ .kind = .bytes },
            .result = .{ .kind = .bytes },
            .deadline_ms = null,
            .cancellable = false,
            .stream = null,
            .source_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        },
        .{
            .name = "feeds.$refresh",
            .client = "feeds$refresh",
            .module = "src/services/feeds.ts",
            .@"export" = "$refresh",
            .request = .{ .kind = .none },
            .result = .{ .kind = .bytes },
            .deadline_ms = null,
            .cancellable = true,
            .stream = null,
            .source_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        },
        .{
            .name = "feeds.nested",
            .client = "feedsNested",
            .module = "src/services/feeds.ts",
            .@"export" = "nested",
            .request = slice_optional_bytes,
            .result = slice_optional_bytes,
            .deadline_ms = null,
            .cancellable = false,
            .stream = null,
            .source_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        },
    };
    const contract: service.Contract = .{
        .format = 3,
        .protocol_version = 3,
        .compiler_version = "1.2.3",
        .deterministic = false,
        .packages = &.{},
        .types = .{ .records = &.{}, .enums = &.{}, .unions = &.{} },
        .operations = &operations,
    };

    const host = try emitHost(std.testing.allocator, contract);
    defer std.testing.allocator.free(host);
    try std.testing.expect(std.mem.indexOf(u8, host, "const request = payload") != null);
    try std.testing.expect(std.mem.indexOf(u8, host, "serviceOp0(request)") != null);
    try std.testing.expect(std.mem.indexOf(u8, host, "serviceOp1(cancellation(cancelPath))") != null);
    try std.testing.expect(std.mem.indexOf(u8, host, "import { $refresh as serviceOp1 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, host, "PROTOCOL_VERSION = 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, host, "CONTRACT_FINGERPRINT = new Uint8Array([") != null);

    const host_hash = std.crypto.hash.sha2.Sha256.hash;
    var before: [32]u8 = undefined;
    host_hash(host, &before, .{});

    const inproc = try emitInprocMain(std.testing.allocator, contract);
    defer std.testing.allocator.free(inproc);
    try std.testing.expect(std.mem.indexOf(u8, inproc, "export function dispatch(operation: number, payload: Uint8Array, cancelPathBytes: Uint8Array, streamPathBytes: Uint8Array): Uint8Array") != null);
    try std.testing.expect(std.mem.indexOf(u8, inproc, "export function contractFingerprint(): Uint8Array") != null);
    try std.testing.expect(std.mem.indexOf(u8, inproc, "serviceOp0(request)") != null);
    try std.testing.expect(std.mem.indexOf(u8, inproc, "serviceOp1(cancellation(cancelPath))") != null);
    try std.testing.expect(std.mem.indexOf(u8, inproc, "import { $refresh as serviceOp1 }") != null);
    // The facade returns its status byte in-band; no stdio protocol rides it.
    try std.testing.expect(std.mem.indexOf(u8, inproc, "writeHello") == null);
    try std.testing.expect(std.mem.indexOf(u8, inproc, "requestId") == null);

    const profile = try emitInprocProfile(std.testing.allocator, "release");
    defer std.testing.allocator.free(profile);
    try std.testing.expect(std.mem.indexOf(u8, profile, "\"prefix\": \"nsc_svc_\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "\"localize_runtime\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "\"instance_per_thread\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "\"entry\": \"service_inproc_main.ts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "\"optimization\": \"release\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "\"symbol\": \"nsc_svc_dispatch\"") != null);

    const registry = try emitRegistry(std.testing.allocator, contract);
    defer std.testing.allocator.free(registry);
    try std.testing.expect(std.mem.indexOf(u8, registry, "pub const inproc_symbol_prefix = \"nsc_svc_\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry, ".name = \"feeds.parse\", .index = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry, "0 => true") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry, "copyServiceBytes(bytes)") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry, "pub const compiler_version = \"1.2.3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry, "pub const contract_fingerprint = [_]u8{") != null);

    const client = try emitClient(std.testing.allocator, contract);
    defer std.testing.allocator.free(client);
    try std.testing.expect(std.mem.indexOf(u8, client, "request: readonly (Uint8Array | null)[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, client, "ServiceRoute<Msg, readonly (Uint8Array | null)[]>") != null);
    // The first result remains owned by its caller after four more init /
    // collect cycles, including a different projection and crypto handles.
    var after: [32]u8 = undefined;
    host_hash(host, &after, .{});
    try std.testing.expectEqualSlices(u8, &before, &after);
}
