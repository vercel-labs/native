//! Explicit capabilities for TypeScript-owned corewire entry coordination.
const std = @import("std");
const invocation = @import("invocation.zig");
const sidecar = @import("sidecar.zig");
const service = @import("service_contract.zig");
const filesystem = @import("filesystem_coordination.zig");
const PanicSink = *const fn (?*anyopaque, [*]const u8, usize, u64) callconv(.c) void;
extern fn nsc_profile_set_panic_sink(PanicSink, ?*anyopaque) void;
extern fn nsc_profile_init() void;
extern fn nsc_profile_collect() void;
extern fn nsc_profile_entry_policy([*]const u8, usize, *[*]const u8, *usize) void;
fn panicSink(_: ?*anyopaque, message: [*]const u8, len: usize, _: u64) callconv(.c) void {
    std.debug.print("corewire: entry coordination trapped: {s}\n", .{message[0..len]});
    std.process.exit(1);
}
fn call(comptime T: type, arena: std.mem.Allocator, operation: []const u8, facts: anytype) !T {
    const input = try std.json.Stringify.valueAlloc(arena, .{ .operation = operation, .payload = try std.json.Stringify.valueAlloc(arena, facts, .{}) }, .{});
    nsc_profile_set_panic_sink(panicSink, null);
    nsc_profile_init();
    defer nsc_profile_collect();
    var ptr: [*]const u8 = undefined;
    var len: usize = 0;
    nsc_profile_entry_policy(input.ptr, input.len, &ptr, &len);
    return std.json.parseFromSliceLeaky(T, arena, ptr[0..len], .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => @panic("corewire: malformed compiled entry response"),
    };
}
fn raw(arena: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    var values: std.json.Array = .init(arena);
    for (bytes) |byte| try values.append(.{ .integer = byte });
    return .{ .array = values };
}
pub fn diagnostics(arena: std.mem.Allocator, label: []const u8, entries: []const sidecar.Diagnostic) ![]const u8 {
    var values: std.json.Array = .init(arena);
    for (entries) |entry| {
        var value: std.json.ObjectMap = .{};
        try value.put(arena, "path", try raw(arena, entry.path));
        try value.put(arena, "message", try raw(arena, entry.message));
        try value.put(arena, "severity", .{ .string = @tagName(entry.severity) });
        try values.append(.{ .object = value });
    }
    return call([]const u8, arena, "diagnostics", .{ .label = try raw(arena, label), .entries = std.json.Value{ .array = values } });
}
const State = struct { phase: []const u8, mode: []const u8, cursor: usize, prior: usize, paths: usize, exit_code: u8, facade: ?usize, profile: ?usize };
const Observation = struct { plan: std.json.Value = .null, ok: bool = true, message: std.json.Value, exit_code: u8 = 0, paths: usize = 0, diagnostics: std.json.Value };
const Action = struct { kind: enum { plan, canonical_input, alias_paths, canonical_output, identity_input, identity_pair, aliases, read_core, read_service, decode_core, decode_service, relative_entry, basename_entry, project, diagnostic, flush, outputs, done }, cursor: usize, prior: usize, message: []const u8 };
fn planFacts(arena: std.mem.Allocator, plan: invocation.Plan) !std.json.Value {
    var value = try std.json.parseFromSliceLeaky(std.json.Value, arena, try std.json.Stringify.valueAlloc(arena, plan, .{}), .{ .allocate = .alloc_always });
    try value.object.put(arena, "error", try raw(arena, plan.@"error"));
    return value;
}
pub fn run(init: std.process.Init, args: []const []const u8, stderr: *std.Io.Writer) !u8 {
    const arena = init.arena.allocator();
    var state = try call(State, arena, "begin", .{});
    var observed = Observation{ .message = try raw(arena, ""), .diagnostics = try raw(arena, "") };
    var plan: invocation.Plan = undefined;
    var input: []const u8 = undefined;
    var canonical_input: []const u8 = undefined;
    var paths: []const []const u8 = undefined;
    var canonical: [][]const u8 = undefined;
    var identities: [][]bool = undefined;
    var source: []const u8 = undefined;
    var diags: sidecar.Diagnostics = .{ .arena = arena };
    var parsed: sidecar.Sidecar = undefined;
    var contract: ?service.Contract = null;
    var entry: invocation.Entry = .{};
    var result: ?invocation.CoreResult = null;
    while (true) {
        const step = try call(struct { state: State, action: Action }, arena, "step", .{ .state = state, .observation = observed });
        state = step.state;
        const action = step.action;
        observed = .{ .message = try raw(arena, ""), .diagnostics = try raw(arena, "") };
        switch (action.kind) {
            .plan => {
                plan = try invocation.plan(arena, args);
                observed.plan = try planFacts(arena, plan);
            },
            .canonical_input => {
                input = args[plan.input.?];
                canonical_input = try filesystem.canonicalSpelling(init.io, arena, input);
            },
            .alias_paths => {
                paths = try filesystem.aliasPaths(arena, plan, args);
                canonical = try arena.alloc([]const u8, paths.len);
                identities = try arena.alloc([]bool, paths.len);
                for (identities) |*row| {
                    row.* = try arena.alloc(bool, paths.len + 1);
                    @memset(row.*, false);
                }
                observed.paths = paths.len;
            },
            .canonical_output => canonical[action.cursor] = try filesystem.canonicalSpelling(init.io, arena, paths[action.cursor]),
            .identity_input => identities[action.cursor][0] = try filesystem.sameExistingFile(init.io, arena, canonical[action.cursor], canonical_input),
            .identity_pair => identities[action.cursor][action.prior + 1] = try filesystem.sameExistingFile(init.io, arena, canonical[action.cursor], canonical[action.prior]),
            .aliases => observed.message = try raw(arena, try invocation.aliases(arena, canonical_input, canonical, identities)),
            .read_core, .read_service => {
                input = args[plan.input.?];
                const limit = if (action.kind == .read_core) sidecar.max_sidecar_bytes else service.max_bytes;
                source = std.Io.Dir.cwd().readFileAlloc(init.io, input, arena, .limited(limit)) catch |err| blk: {
                    observed.ok = false;
                    const message = try call([]const u8, arena, "read_failure", .{ .path = try raw(arena, input), .@"error" = try raw(arena, @errorName(err)) });
                    observed.message = try raw(arena, message);
                    break :blk "";
                };
            },
            .decode_core => {
                parsed = sidecar.read(arena, source, &diags) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    error.Refused => blk: {
                        observed.ok = false;
                        observed.diagnostics = try raw(arena, try diagnostics(arena, input, diags.list.items));
                        break :blk undefined;
                    },
                };
            },
            .decode_service => {
                const decoded = try service.decode(arena, source);
                contract = decoded.contract;
                observed.ok = contract != null;
                observed.diagnostics = try raw(arena, if (decoded.intake_error.len != 0)
                    try call([]const u8, arena, "service_failure", .{ .@"error" = try raw(arena, decoded.intake_error) })
                else
                    decoded.diagnostics);
            },
            .relative_entry => {
                const facade_path = args[state.facade.?];
                const profile_dir = std.fs.path.dirname(args[state.profile.?]) orelse ".";
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const len = std.Io.Dir.cwd().realPath(init.io, &buffer) catch 0;
                const cwd = if (len == 0) "." else buffer[0..len];
                const related = try std.fs.path.relative(arena, cwd, init.environ_map, profile_dir, facade_path);
                entry = try entryFacts(arena, related, true, facade_path, profile_dir);
            },
            .basename_entry => entry = try entryFacts(arena, std.fs.path.basename(args[state.facade.?]), false, "", ""),
            .project => {
                result = try invocation.core(arena, parsed, plan, args, entry, source);
                for (result.?.diagnostics) |item| diags.flag(item.path, "{s}", .{item.message});
                observed.exit_code = result.?.exit_code;
                observed.message = try raw(arena, result.?.@"error");
                if (result.?.exit_code == 0 or result.?.@"error".len == 0)
                    observed.diagnostics = try raw(arena, try diagnostics(arena, input, diags.list.items));
            },
            .diagnostic => try stderr.writeAll(action.message),
            .flush => try stderr.flush(),
            .outputs => observed.exit_code = try filesystem.execute(init, stderr, plan, args, result, contract),
            .done => return state.exit_code,
        }
    }
}
fn entryFacts(arena: std.mem.Allocator, bytes: []const u8, relative: bool, facade: []const u8, directory: []const u8) !invocation.Entry {
    const result = try call(struct { text: []const u8, bytes: []const u8, utf8: bool, unrelated: bool, facade_path: []const u8, profile_directory: []const u8 }, arena, "entry", .{
        .bytes = try raw(arena, bytes),
        .relative = relative,
        .windows = std.fs.path.sep == std.fs.path.sep_windows,
        .absolute = std.fs.path.isAbsolute(bytes),
        .valid_utf8 = std.unicode.utf8ValidateSlice(bytes),
        .facade = try raw(arena, facade),
        .directory = try raw(arena, directory),
    });
    return .{ .text = result.text, .bytes = result.bytes, .utf8 = result.utf8, .unrelated = result.unrelated, .facade_path = result.facade_path, .profile_directory = result.profile_directory };
}

test "entry state, raw diagnostics and path facts survive alternating collection" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const state = try call(State, arena, "begin", .{});
    const observed = Observation{ .message = try raw(arena, ""), .diagnostics = try raw(arena, "") };
    const step = try call(struct { state: State, action: Action }, arena, "step", .{ .state = state, .observation = observed });
    const diagnostic = try diagnostics(arena, "input\xff", &.{.{ .path = "field", .message = "message\x80", .severity = .@"error" }});
    const path = try entryFacts(arena, "\xef\xbb\xbffacade.ts", true, "facade\xff", "dir\x80");
    const malformed = try entryFacts(arena, "facade\xff.ts", false, "", "");
    for (0..8) |_| {
        _ = try invocation.plan(arena, &.{ "corewire", "--bad" });
        _ = try call([]const u8, arena, "service_failure", .{ .@"error" = try raw(arena, "UnexpectedEndOfInput") });
        _ = try entryFacts(arena, "other.ts", true, "other", ".");
        try std.testing.expectEqualStrings("planned", step.state.phase);
        try std.testing.expectEqualStrings("core", state.mode);
        try std.testing.expectEqual(@as(@TypeOf(step.action.kind), .plan), step.action.kind);
        try std.testing.expectEqualStrings("input\xff: error: field: message\x80\n", diagnostic);
        try std.testing.expectEqualStrings("\xef\xbb\xbffacade.ts", path.text);
        try std.testing.expectEqualStrings(path.text, path.bytes);
        try std.testing.expectEqualStrings("facade\xff", path.facade_path);
        try std.testing.expectEqualStrings("dir\x80", path.profile_directory);
        try std.testing.expectEqualStrings("facade\xff.ts", malformed.bytes);
        try std.testing.expectEqualStrings("", malformed.text);
        try std.testing.expect(!malformed.utf8);
    }
}
