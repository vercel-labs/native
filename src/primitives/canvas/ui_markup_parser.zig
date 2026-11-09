//! Copied runtime expression parser transport. Native supplies source/tree
//! storage and exact numeric literal conversion; the compiled owner chooses
//! grammar, requested spans, admission order, nodes and teaching diagnostics.
const std = @import("std");
const expr = @import("ui_markup_expr.zig");

pub fn parse(owner: expr.Policy, source: []const u8, tree: *expr.ExprTree, diagnostic: *expr.Diagnostic) bool {
    var input: [521]u8 = @splat(0);
    input[0] = 106;
    input[1] = 1;
    const len: usize = @min(source.len, 257);
    std.mem.writeInt(u16, input[2..4], @intCast(len), .little);
    const size = if (len > 256) 8 else 9 + len * 2;
    if (len <= 256) @memcpy(input[8 .. 8 + len], source);
    var numbers: [257]expr.Value = undefined;
    var output: [1296]u8 = undefined;
    // Each continuation admits one previously unseen literal. At most 64
    // nodes can be accepted, with one further numeric probe before overflow.
    for (0..66) |_| {
        const count = owner(input[0..size], &output);
        if (count < 16 or count > output.len or output[0] != 106 or output[1] != 1 or
            output[2] > 2 or output[4] > 64 or count != 16 + @as(usize, output[4]) * 20)
            @panic("invalid compiled expression parser response");
        for (output[12..16]) |byte| if (byte != 0) @panic("invalid parser reserved byte");
        if (output[2] == 2) {
            const start = word(&output, 8);
            const length = word(&output, 10);
            if (len > 256 or length == 0 or start >= len or length > len - start or input[8 + len + start] != 0)
                @panic("invalid compiled numeric span");
            const text = source[start .. start + length];
            const value: ?expr.Value = if (std.mem.indexOfScalar(u8, text, '.') != null) blk: {
                const value = std.fmt.parseFloat(f32, text) catch break :blk null;
                break :blk if (std.math.isFinite(value)) .{ .float = value } else null;
            } else blk: {
                const value = std.fmt.parseInt(i64, text, 10) catch break :blk null;
                break :blk .{ .integer = value };
            };
            input[8 + len + start] = if (value != null) 1 else 2;
            if (value) |number| numbers[start] = number;
            continue;
        }
        if (len <= 256) {
            tree.len = output[4];
            for (0..tree.len) |i| {
                const at = 16 + i * 20;
                const kind = output[at];
                const start = word(&output, at + 14);
                const length = word(&output, at + 16);
                if (kind > @intFromEnum(expr.NodeKind.call) or output[at + 1] > @intFromEnum(expr.FunctionId.pad) or
                    output[at + 2] > 4 or output[at + 3] > 1 or output[at + 10] > 1 or output[at + 11] != 0 or
                    word(&output, at + 18) != 0 or start > len or length > len - start or word(&output, at + 12) > len)
                    @panic("invalid compiled expression node");
                var node: expr.ExprNode = .{
                    .kind = @enumFromInt(kind),
                    .function = @enumFromInt(output[at + 1]),
                    .arg_count = output[at + 2],
                    .boolean = output[at + 3] == 1,
                    .lhs = output[at + 4],
                    .rhs = output[at + 5],
                    .comparison_operand = output[at + 10] == 1,
                    .offset = @intCast(word(&output, at + 12)),
                };
                if ((kind == 5 or kind == 6) and node.lhs >= i or
                    (kind >= 7 and kind <= 19) and (node.lhs >= i or node.rhs >= i))
                    @panic("invalid compiled expression operands");
                for (0..4) |a| {
                    node.args[a] = output[at + 6 + a];
                    if (a < node.arg_count and node.args[a] >= i) @panic("invalid compiled expression argument");
                }
                switch (node.kind) {
                    .literal_int, .literal_float => {
                        if (start >= len or input[8 + len + start] != 1) @panic("unadmitted expression literal");
                        const number = numbers[start];
                        if (node.kind == .literal_int) node.int = number.integer else node.float = number.float;
                    },
                    .binding, .literal_string => node.text = source[start .. start + length],
                    else => {},
                }
                tree.nodes[i] = node;
            }
        }
        if (output[2] == 1) {
            diagnostic.* = .{ .offset = word(&output, 6), .message = message(output[3]) };
            return false;
        }
        if (tree.len == 0 or output[5] >= tree.len) @panic("invalid compiled expression root");
        tree.root = output[5];
        return true;
    }
    @panic("compiled expression parser did not converge");
}

fn word(bytes: []const u8, at: usize) usize {
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

fn message(code: u8) []const u8 {
    if (code >= 32 and code < 32 + expr.function_specs.len) return expr.function_specs[code - 32].signature;
    return switch (code) {
        1 => expr.empty_expression_message,
        2 => expr.expression_too_long_message,
        3 => expr.expression_too_many_nodes_message,
        4 => expr.expression_too_deep_message,
        5 => expr.expression_too_many_args_message,
        6 => expr.comparison_chain_message,
        7 => expr.unterminated_string_message,
        8 => expr.integer_literal_overflow_message,
        9 => expr.number_literal_range_message,
        10 => expr.unknown_function_message,
        11 => expr.expected_operand_message,
        12 => expr.expected_operator_message,
        13 => expr.expected_close_paren_message,
        14 => expr.call_syntax_message,
        15 => expr.clock_function_message,
        else => @panic("invalid compiled parser diagnostic"),
    };
}
