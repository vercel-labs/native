//! Explicit OS capabilities and owned-byte transport for compiled filesystem
//! coordination. Portable decisions live in filesystem_coordination.ts.
const std = @import("std");
const invocation = @import("invocation.zig");
const service = @import("service_contract.zig");
const projection = @import("service_projection.zig");
const PanicSink = *const fn (?*anyopaque, [*]const u8, usize, u64) callconv(.c) void;
extern fn nsc_profile_set_panic_sink(PanicSink, ?*anyopaque) void;
extern fn nsc_profile_init() void;
extern fn nsc_profile_collect() void;
extern fn nsc_profile_filesystem_policy([*]const u8, usize, *[*]const u8, *usize) void;

fn panicSink(_: ?*anyopaque, message: [*]const u8, len: usize, _: u64) callconv(.c) void {
    std.debug.print("corewire: filesystem coordination trapped: {s}\n", .{message[0..len]});
    std.process.exit(1);
}
fn call(comptime T: type, arena: std.mem.Allocator, facts: anytype) !T {
    const payload = try std.json.Stringify.valueAlloc(arena, facts, .{});
    const input = try std.json.Stringify.valueAlloc(arena, .{ .operation = facts.operation, .payload = payload }, .{});
    nsc_profile_set_panic_sink(panicSink, null);
    nsc_profile_init();
    defer nsc_profile_collect();
    var ptr: [*]const u8 = undefined;
    var len: usize = 0;
    nsc_profile_filesystem_policy(input.ptr, input.len, &ptr, &len);
    return std.json.parseFromSliceLeaky(T, arena, ptr[0..len], .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => @panic("corewire: malformed compiled filesystem response"),
    };
}
fn raw(arena: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    var array: std.json.Array = .init(arena);
    for (bytes) |byte| try array.append(.{ .integer = byte });
    return .{ .array = array };
}
fn optionalRaw(arena: std.mem.Allocator, bytes: ?[]const u8) !std.json.Value {
    return if (bytes) |value| raw(arena, value) else .null;
}
fn stateBase(arena: std.mem.Allocator, state: std.json.Value) ![]const u8 {
    const items = state.object.get("base").?.array.items;
    const bytes = try arena.alloc(u8, items.len);
    for (items, 0..) |item, i| bytes[i] = @intCast(item.integer);
    return bytes;
}
pub fn canonicalSpelling(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    var components = std.fs.path.componentIterator(path);
    const root = components.root();
    var cwd: ?[]const u8 = null;
    if (root == null) {
        if (std.Io.Dir.cwd().realPath(io, &buffer)) |len| cwd = try arena.dupe(u8, buffer[0..len]) else |_| {}
    }
    const begin = try call(struct { state: std.json.Value, resolve: bool }, arena, .{
        .operation = "path_begin",
        .root = try optionalRaw(arena, root),
        .absolute = std.fs.path.isAbsolute(path),
        .cwd = try optionalRaw(arena, cwd),
    });
    if (begin.resolve) return std.fs.path.resolve(arena, &.{path});
    var state = begin.state;
    while (components.next()) |component| {
        const plan = try call(struct { action: enum { keep, parent, join }, probe: bool }, arena, .{
            .operation = "path_component",
            .state = state,
            .component = try raw(arena, component.name),
        });
        if (plan.action == .keep) continue;
        const base = try stateBase(arena, state);
        const candidate = switch (plan.action) {
            .parent => std.fs.path.dirname(base) orelse base,
            .join => try std.fs.path.join(arena, &.{ base, component.name }),
            .keep => unreachable,
        };
        var canonical: ?[]const u8 = null;
        if (plan.probe) {
            if (std.Io.Dir.cwd().realPathFile(io, candidate, &buffer)) |len| canonical = try arena.dupe(u8, buffer[0..len]) else |_| {}
        }
        state = try call(std.json.Value, arena, .{
            .operation = "path_observed",
            .state = state,
            .action = @tagName(plan.action),
            .candidate = try raw(arena, candidate),
            .canonical = try optionalRaw(arena, canonical),
        });
    }
    return stateBase(arena, state);
}
const Identity = struct {
    canonical: std.json.Value,
    basename: std.json.Value,
    parent: std.json.Value,
    metadata: ?[]const []const u8 = null,
};
fn identity(arena: std.mem.Allocator, canonical: ?[]const u8) !Identity {
    return .{
        .canonical = try optionalRaw(arena, canonical),
        .basename = try raw(arena, if (canonical) |path| std.fs.path.basename(path) else ""),
        .parent = try optionalRaw(arena, if (canonical) |path| std.fs.path.dirname(path) else null),
    };
}
fn metadata(io: std.Io, arena: std.mem.Allocator, canonical: []const u8) !?[]const []const u8 {
    const stat = std.Io.Dir.cwd().statFile(io, std.fs.path.dirname(canonical).?, .{}) catch return null;
    const fields = try arena.alloc([]const u8, 6);
    fields[0] = try std.fmt.allocPrint(arena, "{d}", .{stat.inode});
    fields[1] = @tagName(stat.kind);
    fields[2] = try std.fmt.allocPrint(arena, "{d}", .{stat.size});
    fields[3] = try std.fmt.allocPrint(arena, "{d}", .{stat.nlink});
    fields[4] = try std.fmt.allocPrint(arena, "{d}", .{stat.mtime.nanoseconds});
    fields[5] = try std.fmt.allocPrint(arena, "{d}", .{stat.ctime.nanoseconds});
    return fields;
}
pub fn sameExistingFile(io: std.Io, arena: std.mem.Allocator, a: []const u8, b: []const u8) !bool {
    var buffer_a: [std.fs.max_path_bytes]u8 = undefined;
    var buffer_b: [std.fs.max_path_bytes]u8 = undefined;
    const len_a = std.Io.Dir.cwd().realPathFile(io, a, &buffer_a) catch return false;
    const len_b = std.Io.Dir.cwd().realPathFile(io, b, &buffer_b) catch return false;
    const canon_a = buffer_a[0..len_a];
    const canon_b = buffer_b[0..len_b];
    var left = try identity(arena, canon_a);
    var right = try identity(arena, canon_b);
    const plan = try call(struct { same: bool, stat: bool }, arena, .{ .operation = "identity_plan", .left = left, .right = right });
    if (!plan.stat) return plan.same;
    left.metadata = try metadata(io, arena, canon_a);
    // Preserve original early refusal before observing the second parent.
    if (left.metadata == null) return false;
    right.metadata = try metadata(io, arena, canon_b);
    return call(bool, arena, .{ .operation = "metadata_identity", .left = left, .right = right });
}
const Output = struct { kind: []const u8, flag: []const u8, path: std.json.Value, parent: std.json.Value, staged: std.json.Value };
fn outputs(arena: std.mem.Allocator, plan: invocation.Plan, args: []const []const u8) ![]const Output {
    const values = try arena.alloc(Output, plan.outputs.len);
    for (plan.outputs, 0..) |output, i| {
        const path = args[output.path_index];
        values[i] = .{ .kind = @tagName(output.kind), .flag = output.flag, .path = try raw(arena, path), .parent = try optionalRaw(arena, std.fs.path.dirname(path)), .staged = try raw(arena, "") };
    }
    return values;
}
pub fn aliasPaths(arena: std.mem.Allocator, plan: invocation.Plan, args: []const []const u8) ![]const []const u8 {
    return call([]const []const u8, arena, .{ .operation = "alias_paths", .outputs = try outputs(arena, plan, args) });
}
const Observation = struct { ok: bool = true, @"error": std.json.Value = .null, bytes: std.json.Value = .null, identity: bool = false };
const Action = struct { kind: enum { identity, mkdir, entropy, create, write, flush, close, delete, rename, generate, service_write, diagnostic, done }, index: usize, prior: usize, path: []const u8, projection: []const u8, message: []const u8 };
fn cleanupAfterDiagnosticFailure(init: std.process.Init, state_at_failure: std.json.Value) !void {
    const arena = init.arena.allocator();
    var state = state_at_failure;
    const observed = Observation{ .@"error" = try raw(arena, ""), .bytes = try raw(arena, "") };
    while (true) {
        const step = try call(struct { state: std.json.Value, action: Action }, arena, .{
            .operation = "output_step",
            .output_state = state,
            .observation = observed,
        });
        state = step.state;
        switch (step.action.kind) {
            .delete => std.Io.Dir.cwd().deleteFile(init.io, step.action.path) catch {},
            .done => return,
            else => unreachable,
        }
    }
}
pub fn execute(init: std.process.Init, stderr: *std.Io.Writer, plan: invocation.Plan, args: []const []const u8, core: ?invocation.CoreResult, contract: ?service.Contract) !u8 {
    const arena = init.arena.allocator();
    var state = try call(std.json.Value, arena, .{ .operation = "output_begin", .mode = @tagName(plan.mode), .outputs = try outputs(arena, plan, args) });
    var observed = Observation{ .@"error" = try raw(arena, ""), .bytes = try raw(arena, "") };
    var staging: ?std.Io.File = null;
    defer if (staging) |file| file.close(init.io);
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.File.Writer = undefined;
    const staged = try arena.alloc([]const u8, plan.outputs.len);
    var current: []const u8 = "";
    while (true) {
        const step = try call(struct { state: std.json.Value, action: Action }, arena, .{
            .operation = "output_step",
            .output_state = state,
            .observation = observed,
        });
        state = step.state;
        const action = step.action;
        observed = .{ .@"error" = try raw(arena, ""), .bytes = try raw(arena, "") };
        switch (action.kind) {
            .identity => observed.identity = try sameExistingFile(init.io, arena, action.path, args[plan.outputs[action.prior].path_index]),
            .mkdir => std.Io.Dir.cwd().createDirPath(init.io, action.path) catch {},
            .entropy => {
                var nonce: [8]u8 = undefined;
                init.io.random(&nonce);
                observed.bytes = try raw(arena, &nonce);
            },
            .create => {
                staging = std.Io.Dir.cwd().createFile(init.io, action.path, .{ .exclusive = true }) catch |err| blk: {
                    observed.ok = false;
                    observed.@"error" = try raw(arena, @errorName(err));
                    break :blk null;
                };
                if (staging) |file| {
                    staged[action.index] = action.path;
                    writer = file.writerStreaming(init.io, &buffer);
                }
            },
            .write => {
                const data = switch (plan.outputs[action.index].kind) {
                    .mirror => core.?.mirror,
                    .facade => core.?.facade,
                    .profile => core.?.profile,
                    .effective => core.?.effective,
                    else => unreachable,
                };
                writer.interface.writeAll(data) catch {
                    observed.ok = false;
                };
            },
            .flush => writer.interface.flush() catch {
                observed.ok = false;
            },
            .close => {
                staging.?.close(init.io);
                staging = null;
            },
            .delete => std.Io.Dir.cwd().deleteFile(init.io, action.path) catch {},
            .rename => std.Io.Dir.cwd().rename(staged[action.index], std.Io.Dir.cwd(), action.path, init.io) catch |err| {
                observed.ok = false;
                observed.@"error" = try raw(arena, @errorName(err));
            },
            .generate => {
                const input = try std.json.Stringify.valueAlloc(arena, contract.?, .{});
                const optimization = if (plan.optimization) |index| args[index] else "";
                current = try projection.generate(arena, input, action.projection, optimization);
            },
            .service_write => std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = action.path, .data = current }) catch |err| {
                observed.ok = false;
                observed.@"error" = try raw(arena, @errorName(err));
            },
            .diagnostic => {
                stderr.writeAll(action.message) catch |err| {
                    try cleanupAfterDiagnosticFailure(init, state);
                    return err;
                };
                stderr.flush() catch |err| {
                    try cleanupAfterDiagnosticFailure(init, state);
                    return err;
                };
            },
            .done => return @intCast(state.object.get("exit_code").?.integer),
        }
    }
}
