//! Copied markup shape facts and explicit native conversion/glyph capabilities.
const std = @import("std");
const markup = @import("ui_markup.zig");
const elements = @import("ui_markup_elements.zig");
const scratch = std.heap.page_allocator;
pub const Request = struct {
    inner: elements.Request,
    pub fn init(mode: u8) Request {
        var inner = elements.Request.init(mode);
        inner.bytes.items[0] = 115;
        return .{ .inner = inner };
    }
    pub fn deinit(self: *Request) void {
        self.inner.deinit();
    }
    pub fn word(self: *Request, value: usize) void {
        self.inner.word(value);
    }
    pub fn words(self: *Request, values: []const usize) void {
        self.inner.words(values);
    }
    pub fn blob(self: *Request, value: []const u8) void {
        self.inner.blob(value);
    }
    pub fn names(self: *Request, value: []const []const u8) void {
        self.inner.names(value);
    }
    pub fn node(self: *Request, value: markup.MarkupNode, children: bool) void {
        self.inner.node(value, children);
    }
    pub fn decision(self: *Request, owner: markup.expr.Policy) elements.Record {
        var result = self.program(owner) catch @panic("markup shape transport allocation failed");
        defer result.deinit();
        const row = result.next() orelse @panic("missing markup shape decision");
        if (result.next() != null) @panic("extra markup shape decision");
        return row;
    }
    pub fn program(self: *Request, owner: markup.expr.Policy) error{OutOfMemory}!elements.Program {
        self.inner.bytes.items[3] = 0;
        var sizing: [16]u8 = undefined;
        if (owner(self.inner.bytes.items, &sizing) != sizing.len) @panic("invalid markup shape sizing");
        const count = header(&sizing, 0);
        const size = std.math.add(usize, 16, std.math.mul(usize, count, 48) catch return error.OutOfMemory) catch return error.OutOfMemory;
        const out = try scratch.alloc(u8, size);
        errdefer scratch.free(out);
        self.inner.bytes.items[3] = 1;
        if (owner(self.inner.bytes.items, out) != size or header(out, 1) != count) @panic("invalid markup shape program");
        return .{ .bytes = out };
    }
};
fn header(bytes: []const u8, phase: u8) usize {
    if (bytes.len < 16 or bytes[0] != 115 or bytes[1] != 1 or bytes[2] != phase) @panic("invalid markup shape header");
    for (bytes[3..8]) |byte| if (byte != 0) @panic("invalid markup shape reserved byte");
    return elements.number(bytes, 8);
}

fn appendNodes(nodes: *std.ArrayListUnmanaged(markup.MarkupNode), node: markup.MarkupNode) void {
    nodes.append(scratch, node) catch @panic("shape tree allocation failed");
    for (node.children) |child| appendNodes(nodes, child);
}
fn nodeCount(node: markup.MarkupNode) usize {
    var count: usize = 1;
    for (node.children) |child| count += nodeCount(child);
    return count;
}
fn location(node: markup.MarkupNode, attr: usize, offset: usize, text: bool, diagnostic_message: []const u8) markup.MarkupErrorInfo {
    var line = node.line;
    var column = node.column;
    if (attr != 0) {
        line = node.attrs[attr - 1].line;
        column = node.attrs[attr - 1].column;
    } else if (text) {
        for (node.text[0..offset]) |byte| {
            if (byte == '\n') {
                line += 1;
                column = 1;
            } else column += 1;
        }
    }
    return .{ .line = line, .column = column, .message = diagnostic_message, .path = node.src_path };
}
pub fn shape(owner: markup.expr.Policy, root: markup.MarkupNode, mode: u8) ?markup.MarkupErrorInfo {
    var nodes: std.ArrayListUnmanaged(markup.MarkupNode) = .empty;
    defer nodes.deinit(scratch);
    appendNodes(&nodes, root);
    var request = Request.init(mode);
    defer request.deinit();
    request.word(nodes.items.len);
    for (nodes.items, 0..) |node, index| {
        request.word(@intFromEnum(node.kind));
        request.blob(node.name);
        request.blob(node.text);
        request.word(node.attrs.len);
        for (node.attrs) |attr| {
            request.blob(attr.name);
            request.blob(attr.value);
        }
        request.word(node.children.len);
        var next = index + 1;
        for (node.children) |child| {
            request.word(next);
            next += nodeCount(child);
        }
    }
    request.names(&markup.span_weight_value_names);
    request.names(&markup.known_color_token_names);
    request.names(&markup.reactions_alignment_value_names);
    var program = request.program(owner) catch @panic("shape program allocation failed");
    defer program.deinit();
    while (program.next()) |step| {
        const node = nodes.items[step.fields[0]];
        const attr = step.fields[1];
        switch (step.action) {
            1, 4 => {
                const source = if (step.action == 1) node.attrs[attr - 1].value else node.text;
                const inner = source[step.fields[2]..][0..step.fields[3]];
                var tree: markup.expr.ExprTree = .{};
                var diagnostic: markup.expr.Diagnostic = .{};
                const parsed = markup.expr.parseWithPolicy(owner, inner, &tree, &diagnostic);
                const unknown: [markup.expr.max_expression_nodes]?markup.expr.ValueKind = @splat(null);
                const valid = if (parsed) blk: {
                    _ = checkTypes(owner, &tree, &unknown, &diagnostic) catch break :blk false;
                    break :blk true;
                } else false;
                const at_attr = if (step.action == 1 and step.fields[4] == 0) attr else 0;
                if (!valid) return location(node, at_attr, if (step.action == 4) step.fields[4] else 0, step.action == 4, diagnostic.message);
                if (step.action == 4) for (tree.nodes[0..tree.len]) |expr_node| {
                    if (expr_node.kind == .literal_string and firstUncovered(owner, expr_node.text) != null)
                        return location(node, 0, step.fields[4], true, markup.font_coverage_message);
                };
            },
            2 => {
                const multiplier = std.fmt.parseFloat(f32, node.attrs[attr - 1].value) catch
                    return location(node, attr, 0, false, markup.span_scale_value_message);
                if (!std.math.isFinite(multiplier) or multiplier <= 0)
                    return location(node, attr, 0, false, markup.span_scale_value_message);
            },
            5 => if (firstUncovered(owner, node.text)) |found| {
                return location(node, 0, found.offset, true, markup.font_coverage_message);
            },
            255 => return location(node, attr, step.fields[2], step.fields[3] == 1, message(step.code)),
            else => @panic("invalid shape capability"),
        }
    }
    return null;
}

pub fn firstUncovered(owner: markup.expr.Policy, text: []const u8) ?markup.UncoveredCodepoint {
    var request = Request.init(4);
    defer request.deinit();
    request.blob(text);
    var program = request.program(owner) catch @panic("coverage program allocation failed");
    defer program.deinit();
    while (program.next()) |step| {
        if (step.action != 3 and step.action != 255) @panic("invalid glyph coverage capability");
        const point: u21 = @intCast(step.fields[2]);
        if (step.action == 255 or !@import("font_coverage.zig").covers(point)) return .{
            .offset = step.fields[0],
            .bytes = text[step.fields[0]..][0..step.fields[1]],
            .codepoint = point,
        };
    }
    return null;
}

pub fn checkTypes(owner: markup.expr.Policy, tree: *const markup.expr.ExprTree, bindings: []const ?markup.expr.ValueKind, diagnostic: *markup.expr.Diagnostic) error{ExprType}!?markup.expr.ValueKind {
    var request = Request.init(3);
    defer request.deinit();
    request.words(&.{ tree.len, tree.root });
    for (tree.nodes[0..tree.len], 0..) |node, index| {
        request.words(&.{ @intFromEnum(node.kind), @intFromEnum(node.function), node.arg_count, node.lhs, node.rhs });
        for (node.args) |arg| request.word(arg);
        request.word(node.offset);
        request.word(if (node.kind == .binding) (if (bindings[index]) |kind| @as(usize, @intFromEnum(kind)) + 1 else 0) else 0);
    }
    const step = request.decision(owner);
    if (step.action == 255) {
        diagnostic.* = .{ .offset = @intCast(step.fields[1]), .message = typeMessage(step.code) };
        return error.ExprType;
    }
    if (step.action != 0 or step.fields[0] > 4) @panic("invalid structural expression kind");
    return if (step.fields[0] == 0) null else @enumFromInt(step.fields[0] - 1);
}
fn typeMessage(code: u8) []const u8 {
    if (code >= 32 and code < 32 + markup.expr.function_specs.len) return markup.expr.function_specs[code - 32].signature;
    return switch (code) {
        1 => markup.expr.negate_type_message,
        2 => markup.expr.logic_type_message,
        3 => markup.expr.arithmetic_type_message,
        4 => markup.expr.ordering_type_message,
        else => @panic("invalid structural expression diagnostic"),
    };
}
fn message(code: u8) []const u8 {
    return switch (code) {
        1 => markup.span_weight_value_message,
        3 => markup.unknown_color_token_message,
        4 => markup.style_token_literal_message,
        5 => markup.span_attr_message,
        6 => markup.span_content_message,
        7 => markup.text_leaf_single_run_message,
        8 => markup.font_coverage_message,
        9 => markup.context_menu_attrs_message,
        10 => markup.context_menu_empty_message,
        11 => markup.context_menu_children_message,
        12 => markup.context_menu_separator_message,
        13 => "for requires an each attribute",
        14 => "for requires an as attribute",
        15 => markup.for_children_message,
        16 => markup.context_menu_item_attr_message,
        17 => markup.context_menu_item_press_message,
        18 => markup.context_menu_item_label_message,
        19 => "invalid message expression: on-* takes a Msg tag (\"add\") or tag with one binding payload (\"toggle:{item.id}\")",
        20 => markup.invalid_expression_message,
        21 => markup.else_placement_message,
        22 => markup.unterminated_interpolation_message,
        23 => "if requires a test attribute",
        24 => markup.if_test_expression_message,
        25 => markup.reactions_attr_message,
        26 => markup.reactions_alignment_value_message,
        27 => markup.reactions_content_message,
        else => @panic("invalid markup shape diagnostic"),
    };
}
