//! Copied import programs and explicit source/tree/arena capabilities.
//! No source pointer or allocator handle crosses the compiled boundary.
const std = @import("std");
const m = @import("ui_markup.zig");
const scratch = std.heap.page_allocator;
const Stamp = *const fn (std.mem.Allocator, m.MarkupNode, []const u8) error{OutOfMemory}!m.MarkupNode;

const Packet = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    fn init(stage: u8) !Packet {
        var self: Packet = .{};
        errdefer self.deinit();
        try self.bytes.appendSlice(scratch, &.{ 108, 1, stage, 0 });
        return self;
    }
    fn deinit(self: *Packet) void {
        self.bytes.deinit(scratch);
    }
    fn word(self: *Packet, value: usize) !void {
        if (value > 9007199254740991) @panic("import transport integer exceeds exact range");
        var raw: [8]u8 = undefined;
        std.mem.writeInt(u64, &raw, @bitCast(@as(f64, @floatFromInt(value))), .little);
        try self.bytes.appendSlice(scratch, &raw);
    }
    fn blob(self: *Packet, value: []const u8) !void {
        try self.word(value.len);
        try self.bytes.appendSlice(scratch, value);
    }
    fn decimal(self: *Packet, value: usize) !void {
        var buffer: [40]u8 = undefined;
        try self.blob(std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable);
    }
    fn run(self: *const Packet, owner: m.expr.Policy) !Program {
        const capacity = std.math.add(usize, 512, std.math.mul(usize, self.bytes.items.len, 2) catch return error.OutOfMemory) catch return error.OutOfMemory;
        const output = try scratch.alloc(u8, capacity);
        errdefer scratch.free(output);
        const size = owner(self.bytes.items, output);
        if (size < 32 or size > capacity or output[0] != 108 or output[1] != 1 or output[2] != self.bytes.items[2] or output[3] == 0 or output[3] > 15)
            @panic("invalid compiled import response");
        for (output[4..8]) |b| if (b != 0) @panic("invalid import reserved bytes");
        return .{ .storage = output, .bytes = output[0..size], .action = output[3], .a = number(output, 8), .b = number(output, 16), .c = number(output, 24) };
    }
};
fn number(bytes: []const u8, at: usize) usize {
    if (at > bytes.len or bytes.len - at < 8) @panic("short import integer");
    const value: f64 = @bitCast(std.mem.readInt(u64, bytes[at..][0..8], .little));
    if (!std.math.isFinite(value) or value < 0 or value > 9007199254740991 or value != @trunc(value) or value >= @as(f64, @floatFromInt(std.math.maxInt(usize))))
        @panic("invalid compiled import integer");
    return @intFromFloat(value);
}
const Program = struct {
    storage: []u8,
    bytes: []const u8,
    action: u8,
    a: usize,
    b: usize,
    c: usize,
    fn deinit(self: *Program) void {
        scratch.free(self.storage);
    }
    fn payload(self: Program) []const u8 {
        return self.bytes[32..];
    }
    fn formatted(self: Program, arena: std.mem.Allocator) ![]const u8 {
        var out = try std.Io.Writer.Allocating.initCapacity(arena, self.b);
        defer out.deinit();
        const bytes = self.payload();
        var at: usize = 0;
        for (0..self.a) |_| {
            const length = number(bytes, at);
            at += 8;
            if (length > bytes.len - at) @panic("short formatted import chunk");
            out.writer.writeAll(bytes[at..][0..length]) catch return error.OutOfMemory;
            at += length;
        }
        if (at != bytes.len) @panic("trailing formatted import chunks");
        return out.toOwnedSlice();
    }
};

pub fn resolve(owner: m.expr.Policy, arena: std.mem.Allocator, root_dir: []const u8, root_name: []const u8, source: []const u8, loader: m.ImportLoader, diagnostic: *m.MarkupErrorInfo, stamp: Stamp) m.ResolveError!m.MarkupDocument {
    var resolver: Resolver = .{ .owner = owner, .arena = arena, .root_dir = root_dir, .loader = loader, .diagnostic = diagnostic, .stamp = stamp };
    const root = try resolver.visit(root_name, source, 0);
    return .{ .imports = &.{}, .templates = resolver.templates.items, .root = root, .source_bytes = resolver.source_bytes };
}
const Resolver = struct {
    owner: m.expr.Policy,
    arena: std.mem.Allocator,
    root_dir: []const u8,
    loader: m.ImportLoader,
    diagnostic: *m.MarkupErrorInfo,
    stamp: Stamp,
    templates: std.ArrayListUnmanaged(m.MarkupNode) = .empty,
    visited: std.ArrayListUnmanaged([]const u8) = .empty,
    chain: [m.max_import_depth][]const u8 = undefined,
    file_count: usize = 0,
    source_bytes: usize = 0,

    fn visit(self: *Resolver, path: []const u8, source: []const u8, depth: usize) m.ResolveError!?m.MarkupNode {
        if (depth >= self.chain.len) @panic("invalid compiled import recursion");
        self.chain[depth] = path;
        self.source_bytes += source.len;
        var parser = m.Parser.init(self.arena, source);
        const document = parser.parseWithPolicy(self.owner) catch |err| {
            if (err == error.MarkupSyntax) {
                self.diagnostic.* = parser.diagnostic;
                self.diagnostic.path = path;
            }
            return err;
        };
        var phase: usize = 0;
        var cursor: usize = 0;
        while (true) {
            var packet = try Packet.init(2);
            defer packet.deinit();
            for ([_]usize{ phase, cursor, document.imports.len, document.templates.len, @intFromBool(document.root != null), depth }) |value| try packet.word(value);
            var program = try packet.run(self.owner);
            defer program.deinit();
            switch (program.action) {
                9 => {
                    if (program.a >= document.imports.len or program.b != 0 or program.c != program.a + 1) @panic("invalid import selection");
                    try self.importFile(path, document.imports[program.a], depth);
                    phase = program.b;
                    cursor = program.c;
                },
                10 => {
                    if (program.a >= document.templates.len or program.b != 1 or program.c != program.a + 1) @panic("invalid template selection");
                    try self.template(path, document.templates[program.a]);
                    phase = program.b;
                    cursor = program.c;
                },
                11 => return self.fail(path, document.root orelse @panic("missing rejected import root"), message(program.a)),
                12 => return try self.stamp(self.arena, document.root orelse @panic("missing selected import root"), path),
                13 => return null,
                else => @panic("invalid compiled visit action"),
            }
        }
    }
    fn fail(self: *Resolver, path: []const u8, node: m.MarkupNode, text: []const u8) m.ResolveError {
        self.diagnostic.* = .{ .line = node.line, .column = node.column, .message = text, .path = path };
        return error.MarkupImport;
    }
    fn importFile(self: *Resolver, path: []const u8, node: m.MarkupNode, depth: usize) m.ResolveError!void {
        var shape = try Packet.init(0);
        defer shape.deinit();
        try shape.blob(self.root_dir);
        try shape.blob(path);
        try shape.word(m.max_import_path_len);
        try shape.word(node.children.len);
        try shape.word(node.attrs.len);
        for (node.attrs) |attribute| {
            try shape.blob(attribute.name);
            try shape.blob(attribute.value);
        }
        var selected = try shape.run(self.owner);
        defer selected.deinit();
        switch (selected.action) {
            1 => return self.fail(path, node, message(selected.a)),
            2 => {
                if (selected.b >= node.attrs.len) @panic("invalid import attribute selection");
                const attribute = node.attrs[selected.b];
                self.diagnostic.* = .{ .line = attribute.line, .column = attribute.column, .message = message(selected.a), .path = path };
                return error.MarkupImport;
            },
            3 => {
                if (node.children.len == 0) @panic("missing rejected import child");
                return self.fail(path, node.children[0], message(selected.a));
            },
            4 => {},
            else => @panic("invalid compiled import path action"),
        }
        // Keep the reference path duplication before every graph decision,
        // including dedupe and cycle failures.
        if (selected.payload().len > m.max_import_path_len) @panic("oversized compiled import path");
        const resolved = try self.arena.dupe(u8, selected.payload());
        var admission = try Packet.init(1);
        defer admission.deinit();
        try admission.blob(resolved);
        for ([_]usize{ depth, self.file_count, depth + 1 }) |value| try admission.word(value);
        for (self.chain[0 .. depth + 1]) |link| try admission.blob(link);
        try admission.word(self.visited.items.len);
        for (self.visited.items) |seen| try admission.blob(seen);
        var program = try admission.run(self.owner);
        defer program.deinit();
        switch (program.action) {
            1 => return self.fail(path, node, message(program.a)),
            5 => {
                var out: std.ArrayListUnmanaged(u8) = .empty;
                const bytes = program.payload();
                var at: usize = 0;
                for (0..program.a) |_| {
                    const length = number(bytes, at);
                    at += 8;
                    if (length > bytes.len - at) @panic("short import diagnostic chunk");
                    try out.appendSlice(self.arena, bytes[at..][0..length]);
                    at += length;
                }
                if (at != bytes.len) @panic("trailing import diagnostic chunks");
                return self.fail(path, node, out.items);
            },
            6 => return,
            7, 8 => {
                if (program.a != self.file_count + 1) @panic("invalid import file counter");
                self.file_count = program.a;
                if (program.action == 8) return self.fail(path, node, m.import_count_message);
            },
            else => @panic("invalid import admission action"),
        }
        const child_source = self.loader.load(self.loader.context, self.arena, resolved) orelse {
            var missing = try Packet.init(4);
            defer missing.deinit();
            try missing.blob(resolved);
            var text = try missing.run(self.owner);
            defer text.deinit();
            if (text.action != 15) @panic("invalid missing import diagnostic");
            return self.fail(path, node, try text.formatted(self.arena));
        };
        _ = try self.visit(resolved, child_source, depth + 1);
        try self.visited.append(self.arena, resolved);
    }
    fn template(self: *Resolver, path: []const u8, node: m.MarkupNode) m.ResolveError!void {
        var packet = try Packet.init(3);
        defer packet.deinit();
        const name = node.attr("name");
        try packet.word(self.templates.items.len);
        try packet.word(@intFromBool(name != null));
        try packet.blob(name orelse "");
        for (self.templates.items) |existing| {
            const prior = existing.attr("name");
            try packet.word(@intFromBool(prior != null));
            try packet.blob(prior orelse "");
            try packet.blob(existing.src_path);
            try packet.decimal(existing.line);
            try packet.decimal(existing.column);
        }
        var program = try packet.run(self.owner);
        defer program.deinit();
        switch (program.action) {
            1 => return self.fail(path, node, message(program.a)),
            15 => return self.fail(path, node, try program.formatted(self.arena)),
            14 => try self.templates.append(self.arena, try self.stamp(self.arena, node, path)),
            else => @panic("invalid template admission action"),
        }
    }
};
fn message(code: usize) []const u8 {
    return switch (code) {
        1 => m.import_children_message,
        2 => m.import_attrs_message,
        3 => m.import_src_message,
        4 => m.import_src_too_long_message,
        5 => m.import_src_absolute_message,
        6 => m.import_src_separator_message,
        7 => m.import_src_extension_message,
        8 => m.import_src_escape_message,
        9 => m.import_depth_message,
        10 => m.import_count_message,
        11 => m.max_templates_message,
        12 => m.import_view_root_message,
        else => @panic("invalid compiled import diagnostic"),
    };
}
