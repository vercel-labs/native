//! The markup expression core: one grammar, one type discipline, one
//! evaluator shared by the runtime interpreter, the comptime-compiled
//! engine, and `native markup check` (grammar reference:
//! skill-data/native-ui/SKILL.md).
//!
//! Expressions are PURE and TOTAL by construction. Pure: the only inputs
//! are literals and binding values the engines resolve before evaluation —
//! no effects, no clock, no user-defined functions (the library below is
//! closed; extending it is a toolkit change, never an app change). Total:
//! parsing builds a bounded post-order node array (every child index is
//! smaller than its parent's), so evaluation is a single forward loop over
//! at most `max_expression_nodes` nodes — termination is structural, not a
//! property anyone has to prove per expression.
//!
//! Engine seam: the parser and type checker are comptime-callable and
//! allocation-free (fixed arrays). Each engine resolves the tree's binding
//! nodes to `Value`s its own way (interpreter: scope chain at runtime;
//! compiled engine: comptime-unrolled field access), then hands them to the
//! ONE `eval` below — identical inputs through identical arithmetic and
//! formatting code, so results (floats included) are bit-for-bit equal
//! across engines by construction.
//!
//! Type discipline: teaching errors over silent coercion. Arithmetic and
//! ordering take numbers only (a string minus a number is an error, never a
//! NaN); `and`/`or`/`not` take booleans; `++` joins anything by formatting
//! it exactly like text interpolation; `==`/`!=` compare any two values
//! (different types are simply not equal, except int/float which compare
//! numerically). Division always produces a float and division by zero is
//! an error — wrap with `round()`/`floor()` for whole-number contexts and
//! guard divisors in the model. There is no short-circuit: both sides of
//! `and`/`or` always evaluate (expressions are pure, so only errors are
//! observable, and the checker stays simple).

const std = @import("std");

// ------------------------------------------------------------------ values

/// A resolved binding or expression value. Enums resolve to their tag name
/// so equality against enum-typed loop variables and literals works
/// uniformly. This is the interpreter's `Value` (re-exported there); it
/// lives here so the evaluator and both engines share one definition.
pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f32,
    boolean: bool,

    /// Equality across values: same-type values compare directly, integers
    /// and floats compare numerically (the integer converts to f32, so
    /// magnitudes past 2^24 compare at f32 precision), and any other type
    /// mix is simply not equal — never an error, matching how enum tags
    /// and selection states have always compared.
    pub fn eql(a: Value, b: Value) bool {
        return switch (a) {
            .string => |sa| b == .string and std.mem.eql(u8, sa, b.string),
            .integer => |ia| switch (b) {
                .integer => |ib| ia == ib,
                .float => |fb| @as(f32, @floatFromInt(ia)) == fb,
                else => false,
            },
            .float => |fa| switch (b) {
                .float => |fb| fa == fb,
                .integer => |ib| fa == @as(f32, @floatFromInt(ib)),
                else => false,
            },
            .boolean => |ba| b == .boolean and ba == b.boolean,
        };
    }

    pub fn truthy(self: Value) bool {
        return switch (self) {
            .boolean => |value| value,
            .integer => |value| value != 0,
            .float => |value| value != 0,
            .string => |value| value.len > 0,
        };
    }
};

pub const ValueKind = enum { string, integer, float, boolean };

pub fn kindOf(value: Value) ValueKind {
    return switch (value) {
        .string => .string,
        .integer => .integer,
        .float => .float,
        .boolean => .boolean,
    };
}

/// Append a value as display text — THE deterministic formatting for text
/// interpolation and `++` concatenation, shared by both engines (float
/// formatting is std.fmt's shortest-round-trip decimal, identical on every
/// platform).
pub fn appendValue(out: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, value: Value) error{OutOfMemory}!void {
    var buffer: [64]u8 = undefined;
    switch (value) {
        .string => |text| try out.appendSlice(arena, text),
        .integer => |int| try out.appendSlice(arena, std.fmt.bufPrint(&buffer, "{d}", .{int}) catch return error.OutOfMemory),
        .float => |float| try out.appendSlice(arena, std.fmt.bufPrint(&buffer, "{d}", .{float}) catch return error.OutOfMemory),
        .boolean => |boolean| try out.appendSlice(arena, if (boolean) "true" else "false"),
    }
}

// ------------------------------------------------------------------ bounds

/// Complexity bounds, taught one-past in tests: fixed, documented, loud.
/// They exist so a hostile or generated expression can never make parsing,
/// checking, or evaluation grow past a small constant — the same budget
/// philosophy as the per-view canvas limits.
pub const max_expression_bytes = 256;
pub const max_expression_nodes = 64;
pub const max_expression_depth = 16;
pub const max_expression_call_args = 4;

// ---------------------------------------------------------------- messages

pub const empty_expression_message = "empty expression";
pub const expression_too_long_message = "expression is too long (over 256 bytes) - name the logic as a model fn";
pub const expression_too_many_nodes_message = "expression is too complex (over 64 terms) - name the logic as a model fn";
pub const expression_too_deep_message = "expression nests too deeply (over 16 levels) - flatten it or name the logic as a model fn";
pub const expression_too_many_args_message = "too many arguments in a call (over 4)";
pub const comparison_chain_message = "comparisons do not chain - split a < b < c into a < b and b < c";
pub const unterminated_string_message = "unterminated string - expression strings use single quotes ('done') and have no escapes";
pub const integer_literal_overflow_message = "integer literal does not fit in 64 bits";
pub const number_literal_range_message = "number literal is out of range";
pub const unknown_function_message = "unknown expression function - the library is closed (fixed, thousands, percent, date, time, datetime, upper, lower, trim, min, max, abs, round, floor, ceil, plural, pad); anything else is a model fn";
pub const clock_function_message = "reading the clock is an effect - expressions only format model data; keep a timestamp field that update/fx maintains and format it with date()/time()/datetime()";
pub const expected_operand_message = "expected a value: a number, 'string', true/false, a binding path, a function call, or ( )";
pub const expected_operator_message = "expected an operator (+ - * / ++ == != < <= > >= and or) or the end of the expression";
pub const expected_close_paren_message = "expected ')'";
pub const call_syntax_message = "expected ',' or ')' in the argument list";

pub const arithmetic_type_message = "arithmetic takes numbers on both sides - strings never coerce (join text with ++, or fix the model type)";
pub const ordering_type_message = "< <= > >= order numbers only - compare strings with ==, or order in a model fn";
pub const logic_type_message = "and/or/not take booleans - write the comparison out (count > 0)";
pub const negate_type_message = "unary minus takes a number";
pub const division_by_zero_message = "division by zero - guard with an if, or clamp the divisor in the model";
pub const integer_overflow_message = "integer overflow in expression arithmetic";
pub const non_finite_message = "expression arithmetic produced a non-finite number - clean the value in the model";
pub const digits_range_message = "digits must be a whole number between 0 and 6";
pub const timestamp_range_message = "timestamp is outside the formattable range (years 1-9999)";
pub const round_range_message = "round/floor/ceil result does not fit in a whole number";
pub const abs_overflow_message = "abs overflows on the most negative integer";

// --------------------------------------------------------------- functions

/// The closed, curated function library. Every function is pure and total;
/// the set is part of the toolkit's contract, so growing it is a toolkit
/// change with tests and docs, never an app-side extension.
pub const FunctionId = enum {
    fixed,
    thousands,
    percent,
    date,
    time,
    datetime,
    upper,
    lower,
    trim,
    min,
    max,
    abs,
    round,
    floor,
    ceil,
    plural,
    // Appended, never reordered: additive growth keeps existing ids stable.
    pad,
};

pub const FunctionSpec = struct {
    id: FunctionId,
    name: []const u8,
    min_args: u8,
    max_args: u8,
    /// The teaching signature used by arity and argument-type errors.
    signature: []const u8,
};

pub const function_specs = [_]FunctionSpec{
    .{ .id = .fixed, .name = "fixed", .min_args = 2, .max_args = 2, .signature = "fixed takes (number, digits) with digits 0-6 and returns a string with exactly that many decimals" },
    .{ .id = .thousands, .name = "thousands", .min_args = 1, .max_args = 1, .signature = "thousands takes one whole number (round() a float first) and returns it with , separators" },
    .{ .id = .percent, .name = "percent", .min_args = 1, .max_args = 2, .signature = "percent takes (fraction) or (fraction, digits) with digits 0-6 - 0.42 formats as 42%" },
    .{ .id = .date, .name = "date", .min_args = 1, .max_args = 1, .signature = "date takes one unix timestamp in seconds (a model integer) and formats it as YYYY-MM-DD in UTC" },
    .{ .id = .time, .name = "time", .min_args = 1, .max_args = 1, .signature = "time takes one unix timestamp in seconds (a model integer) and formats it as HH:MM in UTC" },
    .{ .id = .datetime, .name = "datetime", .min_args = 1, .max_args = 1, .signature = "datetime takes one unix timestamp in seconds (a model integer) and formats it as YYYY-MM-DD HH:MM in UTC" },
    .{ .id = .upper, .name = "upper", .min_args = 1, .max_args = 1, .signature = "upper takes one string (ASCII letters map; other characters pass through unchanged)" },
    .{ .id = .lower, .name = "lower", .min_args = 1, .max_args = 1, .signature = "lower takes one string (ASCII letters map; other characters pass through unchanged)" },
    .{ .id = .trim, .name = "trim", .min_args = 1, .max_args = 1, .signature = "trim takes one string and removes leading/trailing whitespace" },
    .{ .id = .min, .name = "min", .min_args = 2, .max_args = 2, .signature = "min takes two numbers" },
    .{ .id = .max, .name = "max", .min_args = 2, .max_args = 2, .signature = "max takes two numbers" },
    .{ .id = .abs, .name = "abs", .min_args = 1, .max_args = 1, .signature = "abs takes one number" },
    .{ .id = .round, .name = "round", .min_args = 1, .max_args = 1, .signature = "round takes one number and returns the nearest whole number" },
    .{ .id = .floor, .name = "floor", .min_args = 1, .max_args = 1, .signature = "floor takes one number and returns the nearest whole number at or below it" },
    .{ .id = .ceil, .name = "ceil", .min_args = 1, .max_args = 1, .signature = "ceil takes one number and returns the nearest whole number at or above it" },
    .{ .id = .plural, .name = "plural", .min_args = 3, .max_args = 3, .signature = "plural takes (count, singular, plural) - a count of exactly 1 picks the singular" },
    .{ .id = .pad, .name = "pad", .min_args = 2, .max_args = 2, .signature = "pad takes (whole number, width) with width 0-6 (round() a float first) and zero-pads on the left to width digits - a - sign does not count toward width" },
};

pub fn findFunction(name: []const u8) ?FunctionSpec {
    for (function_specs) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

/// Names that read like clock access get the effects teaching error
/// instead of the generic unknown-function message: the current time is an
/// effect, and its home is the model.
fn clockLikeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "now") or std.mem.eql(u8, name, "today");
}

// ------------------------------------------------------------------- trees

pub const NodeKind = enum {
    literal_int,
    literal_float,
    literal_string,
    literal_bool,
    binding,
    negate,
    logical_not,
    add,
    subtract,
    multiply,
    divide,
    concat,
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    logical_and,
    logical_or,
    call,
};

pub const ExprNode = struct {
    kind: NodeKind,
    /// Binding path or string-literal bytes (slices the expression source).
    text: []const u8 = "",
    int: i64 = 0,
    float: f32 = 0,
    boolean: bool = false,
    /// Child indices (post-order: always smaller than this node's index).
    /// Unary operators use `lhs` only.
    lhs: u16 = 0,
    rhs: u16 = 0,
    function: FunctionId = .fixed,
    args: [max_expression_call_args]u16 = @splat(0),
    arg_count: u8 = 0,
    /// A binding used directly as a comparison operand: arena-computed
    /// scalar fns are rejected there (compare source fields, or bind a
    /// bool-returning fn), exactly like the original `{a == b}` rule.
    comparison_operand: bool = false,
    /// Byte offset in the expression source, for diagnostics.
    offset: u16 = 0,
};

pub const ExprTree = struct {
    nodes: [max_expression_nodes]ExprNode = undefined,
    len: u16 = 0,
    root: u16 = 0,
};

pub const Diagnostic = struct {
    offset: usize = 0,
    message: []const u8 = "",
};

// ------------------------------------------------------------------ parser

/// Parse an expression (the text INSIDE `{...}`) into `tree`. Returns
/// false with `diagnostic` set on any syntax or bounds failure. Works at
/// runtime and comptime (fixed arrays, no allocation).
pub fn parse(source: []const u8, tree: *ExprTree, diagnostic: *Diagnostic) bool {
    if (source.len > max_expression_bytes) {
        diagnostic.* = .{ .offset = 0, .message = expression_too_long_message };
        return false;
    }
    tree.len = 0;
    var parser = ExprParser{ .source = source, .tree = tree, .diagnostic = diagnostic };
    const root = parser.parseOr() catch return false;
    parser.skipWhitespace();
    if (parser.index < source.len) {
        diagnostic.* = .{ .offset = parser.index, .message = expected_operator_message };
        return false;
    }
    tree.root = root;
    return true;
}

const ExprParseError = error{ExprSyntax};

const ExprParser = struct {
    source: []const u8,
    tree: *ExprTree,
    diagnostic: *Diagnostic,
    index: usize = 0,
    depth: usize = 0,

    fn fail(self: *ExprParser, offset: usize, message: []const u8) ExprParseError {
        self.diagnostic.* = .{ .offset = offset, .message = message };
        return error.ExprSyntax;
    }

    fn addNode(self: *ExprParser, node: ExprNode) ExprParseError!u16 {
        if (self.tree.len >= max_expression_nodes) {
            return self.fail(node.offset, expression_too_many_nodes_message);
        }
        self.tree.nodes[self.tree.len] = node;
        self.tree.len += 1;
        return self.tree.len - 1;
    }

    fn enter(self: *ExprParser, offset: usize) ExprParseError!void {
        self.depth += 1;
        if (self.depth > max_expression_depth) {
            return self.fail(offset, expression_too_deep_message);
        }
    }

    fn leave(self: *ExprParser) void {
        self.depth -= 1;
    }

    fn skipWhitespace(self: *ExprParser) void {
        while (self.index < self.source.len) : (self.index += 1) {
            switch (self.source[self.index]) {
                ' ', '\t', '\r', '\n' => {},
                else => return,
            }
        }
    }

    fn peekByte(self: *const ExprParser) ?u8 {
        if (self.index >= self.source.len) return null;
        return self.source[self.index];
    }

    fn startsWithAt(self: *const ExprParser, token: []const u8) bool {
        return std.mem.startsWith(u8, self.source[self.index..], token);
    }

    /// Match a keyword operator (`and`, `or`, `not`) at the cursor: the
    /// token must end at a non-identifier byte so `android` stays a path.
    fn matchKeyword(self: *ExprParser, keyword: []const u8) bool {
        if (!self.startsWithAt(keyword)) return false;
        const end = self.index + keyword.len;
        if (end < self.source.len and identifierByte(self.source[end])) return false;
        self.index = end;
        return true;
    }

    fn matchToken(self: *ExprParser, token: []const u8) bool {
        if (!self.startsWithAt(token)) return false;
        self.index += token.len;
        return true;
    }

    fn parseOr(self: *ExprParser) ExprParseError!u16 {
        try self.enter(self.index);
        defer self.leave();
        var left = try self.parseAnd();
        while (true) {
            self.skipWhitespace();
            const offset = self.index;
            if (!self.matchKeyword("or")) break;
            const right = try self.parseAnd();
            left = try self.addNode(.{ .kind = .logical_or, .lhs = left, .rhs = right, .offset = @intCast(offset) });
        }
        return left;
    }

    fn parseAnd(self: *ExprParser) ExprParseError!u16 {
        var left = try self.parseNot();
        while (true) {
            self.skipWhitespace();
            const offset = self.index;
            if (!self.matchKeyword("and")) break;
            const right = try self.parseNot();
            left = try self.addNode(.{ .kind = .logical_and, .lhs = left, .rhs = right, .offset = @intCast(offset) });
        }
        return left;
    }

    fn parseNot(self: *ExprParser) ExprParseError!u16 {
        self.skipWhitespace();
        const offset = self.index;
        if (self.matchKeyword("not")) {
            try self.enter(offset);
            defer self.leave();
            const operand = try self.parseNot();
            return self.addNode(.{ .kind = .logical_not, .lhs = operand, .offset = @intCast(offset) });
        }
        return self.parseComparison();
    }

    fn parseComparison(self: *ExprParser) ExprParseError!u16 {
        const left = try self.parseAdditive();
        self.skipWhitespace();
        const offset = self.index;
        const kind: NodeKind = blk: {
            if (self.matchToken("==")) break :blk .equal;
            if (self.matchToken("!=")) break :blk .not_equal;
            if (self.matchToken("<=")) break :blk .less_equal;
            if (self.matchToken(">=")) break :blk .greater_equal;
            if (self.matchToken("<")) break :blk .less;
            if (self.matchToken(">")) break :blk .greater;
            return left;
        };
        const right = try self.parseAdditive();
        // Direct binding operands of a comparison reject arena-computed
        // scalars (the engines read this flag when resolving).
        self.markComparisonOperand(left);
        self.markComparisonOperand(right);
        self.skipWhitespace();
        if (self.comparisonAhead()) {
            return self.fail(self.index, comparison_chain_message);
        }
        return self.addNode(.{ .kind = kind, .lhs = left, .rhs = right, .offset = @intCast(offset) });
    }

    fn comparisonAhead(self: *const ExprParser) bool {
        const rest = self.source[self.index..];
        if (std.mem.startsWith(u8, rest, "==")) return true;
        if (std.mem.startsWith(u8, rest, "!=")) return true;
        if (std.mem.startsWith(u8, rest, "<")) return true;
        if (std.mem.startsWith(u8, rest, ">")) return true;
        return false;
    }

    fn markComparisonOperand(self: *ExprParser, index: u16) void {
        if (self.tree.nodes[index].kind == .binding) {
            self.tree.nodes[index].comparison_operand = true;
        }
    }

    fn parseAdditive(self: *ExprParser) ExprParseError!u16 {
        var left = try self.parseMultiplicative();
        while (true) {
            self.skipWhitespace();
            const offset = self.index;
            const kind: NodeKind = blk: {
                if (self.matchToken("++")) break :blk .concat;
                if (self.matchToken("+")) break :blk .add;
                if (self.matchToken("-")) break :blk .subtract;
                break;
            };
            const right = try self.parseMultiplicative();
            left = try self.addNode(.{ .kind = kind, .lhs = left, .rhs = right, .offset = @intCast(offset) });
        }
        return left;
    }

    fn parseMultiplicative(self: *ExprParser) ExprParseError!u16 {
        var left = try self.parseUnary();
        while (true) {
            self.skipWhitespace();
            const offset = self.index;
            const kind: NodeKind = blk: {
                if (self.matchToken("*")) break :blk .multiply;
                if (self.matchToken("/")) break :blk .divide;
                break;
            };
            const right = try self.parseUnary();
            left = try self.addNode(.{ .kind = kind, .lhs = left, .rhs = right, .offset = @intCast(offset) });
        }
        return left;
    }

    fn parseUnary(self: *ExprParser) ExprParseError!u16 {
        self.skipWhitespace();
        const offset = self.index;
        if (self.matchToken("-")) {
            try self.enter(offset);
            defer self.leave();
            const operand = try self.parseUnary();
            return self.addNode(.{ .kind = .negate, .lhs = operand, .offset = @intCast(offset) });
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *ExprParser) ExprParseError!u16 {
        self.skipWhitespace();
        const offset = self.index;
        const byte = self.peekByte() orelse return self.fail(offset, if (offset == 0) empty_expression_message else expected_operand_message);
        if (byte == '(') {
            self.index += 1;
            const inner = try self.parseOr();
            self.skipWhitespace();
            if (!self.matchToken(")")) return self.fail(self.index, expected_close_paren_message);
            return inner;
        }
        if (byte == '\'') return self.parseString(offset);
        if (byte >= '0' and byte <= '9') return self.parseNumber(offset);
        if (identifierStartByte(byte)) return self.parseIdentifier(offset);
        return self.fail(offset, expected_operand_message);
    }

    fn parseString(self: *ExprParser, offset: usize) ExprParseError!u16 {
        self.index += 1;
        const start = self.index;
        while (self.index < self.source.len) : (self.index += 1) {
            if (self.source[self.index] == '\'') {
                const text = self.source[start..self.index];
                self.index += 1;
                return self.addNode(.{ .kind = .literal_string, .text = text, .offset = @intCast(offset) });
            }
        }
        return self.fail(offset, unterminated_string_message);
    }

    fn parseNumber(self: *ExprParser, offset: usize) ExprParseError!u16 {
        const start = self.index;
        while (self.index < self.source.len and self.source[self.index] >= '0' and self.source[self.index] <= '9') {
            self.index += 1;
        }
        var is_float = false;
        if (self.index + 1 < self.source.len and self.source[self.index] == '.' and
            self.source[self.index + 1] >= '0' and self.source[self.index + 1] <= '9')
        {
            is_float = true;
            self.index += 1;
            while (self.index < self.source.len and self.source[self.index] >= '0' and self.source[self.index] <= '9') {
                self.index += 1;
            }
        }
        const text = self.source[start..self.index];
        if (is_float) {
            const value = std.fmt.parseFloat(f32, text) catch {
                return self.fail(offset, number_literal_range_message);
            };
            if (!std.math.isFinite(value)) return self.fail(offset, number_literal_range_message);
            return self.addNode(.{ .kind = .literal_float, .float = value, .offset = @intCast(offset) });
        }
        const value = std.fmt.parseInt(i64, text, 10) catch {
            return self.fail(offset, integer_literal_overflow_message);
        };
        return self.addNode(.{ .kind = .literal_int, .int = value, .offset = @intCast(offset) });
    }

    fn parseIdentifier(self: *ExprParser, offset: usize) ExprParseError!u16 {
        const start = self.index;
        while (self.index < self.source.len and pathByte(self.source[self.index])) {
            self.index += 1;
        }
        const token = self.source[start..self.index];
        if (std.mem.eql(u8, token, "true")) {
            return self.addNode(.{ .kind = .literal_bool, .boolean = true, .offset = @intCast(offset) });
        }
        if (std.mem.eql(u8, token, "false")) {
            return self.addNode(.{ .kind = .literal_bool, .boolean = false, .offset = @intCast(offset) });
        }
        self.skipWhitespace();
        if (self.peekByte() == '(') {
            if (std.mem.indexOfScalar(u8, token, '.') != null) {
                return self.fail(offset, unknown_function_message);
            }
            return self.parseCall(offset, token);
        }
        if (!isBindingPath(token)) return self.fail(offset, expected_operand_message);
        return self.addNode(.{ .kind = .binding, .text = token, .offset = @intCast(offset) });
    }

    fn parseCall(self: *ExprParser, offset: usize, name: []const u8) ExprParseError!u16 {
        const spec = findFunction(name) orelse {
            if (clockLikeName(name)) return self.fail(offset, clock_function_message);
            return self.fail(offset, unknown_function_message);
        };
        self.index += 1; // consume '('
        try self.enter(offset);
        defer self.leave();
        var args: [max_expression_call_args]u16 = @splat(0);
        var arg_count: u8 = 0;
        self.skipWhitespace();
        if (!self.matchToken(")")) {
            while (true) {
                if (arg_count >= max_expression_call_args) {
                    return self.fail(self.index, expression_too_many_args_message);
                }
                args[arg_count] = try self.parseOr();
                arg_count += 1;
                self.skipWhitespace();
                if (self.matchToken(",")) continue;
                if (self.matchToken(")")) break;
                return self.fail(self.index, call_syntax_message);
            }
        }
        if (arg_count < spec.min_args or arg_count > spec.max_args) {
            return self.fail(offset, spec.signature);
        }
        return self.addNode(.{
            .kind = .call,
            .function = spec.id,
            .args = args,
            .arg_count = arg_count,
            .offset = @intCast(offset),
        });
    }
};

fn identifierStartByte(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or byte == '_';
}

fn identifierByte(byte: u8) bool {
    return identifierStartByte(byte) or (byte >= '0' and byte <= '9');
}

fn pathByte(byte: u8) bool {
    return identifierByte(byte) or byte == '.';
}

/// A dotted binding path (`item.field`): the same rule the markup grammar
/// applies to bare `{path}` bindings.
pub fn isBindingPath(text: []const u8) bool {
    if (text.len == 0) return false;
    var segment_start = true;
    for (text) |byte| {
        if (segment_start) {
            if (!identifierStartByte(byte)) return false;
            segment_start = false;
            continue;
        }
        if (byte == '.') {
            segment_start = true;
            continue;
        }
        if (!identifierByte(byte)) return false;
    }
    return !segment_start;
}

// ------------------------------------------------------------ type checker

/// Static type discipline over a parsed tree. `binding_kinds` is indexed
/// by node: engines fill the kind for each `.binding` node (null when the
/// type is only runtime-known, e.g. through an optional; `native markup
/// check` passes all-null because it has no model). Unknown kinds flow
/// through as null; definite mismatches return `error.ExprType` with the
/// SAME message `eval` reports at runtime, so the compiled engine's compile
/// errors, the interpreter's build diagnostics, and the checker teach with
/// one voice. Returns the expression's result kind, or null when it is
/// only runtime-known. Comptime-callable and allocation-free.
pub fn checkTypes(tree: *const ExprTree, binding_kinds: []const ?ValueKind, diagnostic: *Diagnostic) error{ExprType}!?ValueKind {
    var kinds: [max_expression_nodes]?ValueKind = @splat(null);
    var index: usize = 0;
    while (index < tree.len) : (index += 1) {
        const node = tree.nodes[index];
        kinds[index] = try checkNode(tree, node, index, binding_kinds, &kinds, diagnostic);
    }
    return kinds[tree.root];
}

fn checkNode(
    tree: *const ExprTree,
    node: ExprNode,
    index: usize,
    binding_kinds: []const ?ValueKind,
    kinds: *[max_expression_nodes]?ValueKind,
    diagnostic: *Diagnostic,
) error{ExprType}!?ValueKind {
    _ = tree;
    switch (node.kind) {
        .literal_int => return .integer,
        .literal_float => return .float,
        .literal_string => return .string,
        .literal_bool => return .boolean,
        .binding => return binding_kinds[index],
        .negate => {
            const operand = kinds[node.lhs];
            if (definitelyNotNumber(operand)) return failType(diagnostic, node.offset, negate_type_message);
            return operand;
        },
        .logical_not => {
            if (definitelyNotBoolean(kinds[node.lhs])) return failType(diagnostic, node.offset, logic_type_message);
            return .boolean;
        },
        .add, .subtract, .multiply => {
            const left = kinds[node.lhs];
            const right = kinds[node.rhs];
            if (definitelyNotNumber(left) or definitelyNotNumber(right)) {
                return failType(diagnostic, node.offset, arithmetic_type_message);
            }
            if (left == null or right == null) return null;
            if (left.? == .integer and right.? == .integer) return .integer;
            return .float;
        },
        .divide => {
            if (definitelyNotNumber(kinds[node.lhs]) or definitelyNotNumber(kinds[node.rhs])) {
                return failType(diagnostic, node.offset, arithmetic_type_message);
            }
            return .float;
        },
        .concat => return .string,
        .equal, .not_equal => return .boolean,
        .less, .less_equal, .greater, .greater_equal => {
            if (definitelyNotNumber(kinds[node.lhs]) or definitelyNotNumber(kinds[node.rhs])) {
                return failType(diagnostic, node.offset, ordering_type_message);
            }
            return .boolean;
        },
        .logical_and, .logical_or => {
            if (definitelyNotBoolean(kinds[node.lhs]) or definitelyNotBoolean(kinds[node.rhs])) {
                return failType(diagnostic, node.offset, logic_type_message);
            }
            return .boolean;
        },
        .call => return checkCall(node, kinds, diagnostic),
    }
}

fn checkCall(node: ExprNode, kinds: *[max_expression_nodes]?ValueKind, diagnostic: *Diagnostic) error{ExprType}!?ValueKind {
    const signature = signatureFor(node.function);
    switch (node.function) {
        .fixed => {
            if (definitelyNotNumber(kinds[node.args[0]])) return failType(diagnostic, node.offset, signature);
            if (definitelyNotKind(kinds[node.args[1]], .integer)) return failType(diagnostic, node.offset, signature);
            return .string;
        },
        .percent => {
            if (definitelyNotNumber(kinds[node.args[0]])) return failType(diagnostic, node.offset, signature);
            if (node.arg_count > 1 and definitelyNotKind(kinds[node.args[1]], .integer)) {
                return failType(diagnostic, node.offset, signature);
            }
            return .string;
        },
        .thousands, .date, .time, .datetime => {
            if (definitelyNotKind(kinds[node.args[0]], .integer)) return failType(diagnostic, node.offset, signature);
            return .string;
        },
        .upper, .lower, .trim => {
            if (definitelyNotKind(kinds[node.args[0]], .string)) return failType(diagnostic, node.offset, signature);
            return .string;
        },
        .min, .max => {
            const left = kinds[node.args[0]];
            const right = kinds[node.args[1]];
            if (definitelyNotNumber(left) or definitelyNotNumber(right)) {
                return failType(diagnostic, node.offset, signature);
            }
            if (left == null or right == null) return null;
            if (left.? == .integer and right.? == .integer) return .integer;
            return .float;
        },
        .abs => {
            const operand = kinds[node.args[0]];
            if (definitelyNotNumber(operand)) return failType(diagnostic, node.offset, signature);
            return operand;
        },
        .round, .floor, .ceil => {
            if (definitelyNotNumber(kinds[node.args[0]])) return failType(diagnostic, node.offset, signature);
            return .integer;
        },
        .plural => {
            if (definitelyNotKind(kinds[node.args[0]], .integer)) return failType(diagnostic, node.offset, signature);
            if (definitelyNotKind(kinds[node.args[1]], .string)) return failType(diagnostic, node.offset, signature);
            if (definitelyNotKind(kinds[node.args[2]], .string)) return failType(diagnostic, node.offset, signature);
            return .string;
        },
        .pad => {
            // The value takes whole numbers like thousands; the width is an
            // integer exactly like fixed's digits argument.
            if (definitelyNotKind(kinds[node.args[0]], .integer)) return failType(diagnostic, node.offset, signature);
            if (definitelyNotKind(kinds[node.args[1]], .integer)) return failType(diagnostic, node.offset, signature);
            return .string;
        },
    }
}

fn signatureFor(id: FunctionId) []const u8 {
    for (function_specs) |spec| {
        if (spec.id == id) return spec.signature;
    }
    unreachable;
}

fn definitelyNotNumber(kind: ?ValueKind) bool {
    const known = kind orelse return false;
    return known != .integer and known != .float;
}

fn definitelyNotBoolean(kind: ?ValueKind) bool {
    const known = kind orelse return false;
    return known != .boolean;
}

fn definitelyNotKind(kind: ?ValueKind, expected: ValueKind) bool {
    const known = kind orelse return false;
    return known != expected;
}

fn failType(diagnostic: *Diagnostic, offset: u16, message: []const u8) error{ExprType} {
    diagnostic.* = .{ .offset = offset, .message = message };
    return error.ExprType;
}

// --------------------------------------------------------------- evaluator

pub const EvalOutcome = union(enum) {
    value: Value,
    /// A value-dependent failure with its teaching message (division by
    /// zero, overflow, a runtime type mismatch the static pass could not
    /// see). The interpreter turns it into a build diagnostic; the
    /// compiled engine latches `ui.failed`.
    fail: []const u8,
};

/// Evaluate a parsed tree. `values` is indexed by node: the caller fills
/// every `.binding` node's slot before the call (each engine resolves
/// bindings its own way); this loop fills the rest bottom-up — post-order
/// construction makes one forward pass total, with no recursion. `arena`
/// backs string results (concat and the formatting functions); everything
/// they produce lives exactly as long as the built view.
pub fn eval(tree: *const ExprTree, values: *[max_expression_nodes]Value, arena: std.mem.Allocator) error{OutOfMemory}!EvalOutcome {
    var index: usize = 0;
    while (index < tree.len) : (index += 1) {
        const node = tree.nodes[index];
        values[index] = switch (node.kind) {
            .literal_int => .{ .integer = node.int },
            .literal_float => .{ .float = node.float },
            .literal_string => .{ .string = node.text },
            .literal_bool => .{ .boolean = node.boolean },
            .binding => continue, // resolved by the caller
            .negate => switch (values[node.lhs]) {
                .integer => |int| blk: {
                    if (int == std.math.minInt(i64)) return .{ .fail = integer_overflow_message };
                    break :blk .{ .integer = -int };
                },
                .float => |float| .{ .float = -float },
                else => return .{ .fail = negate_type_message },
            },
            .logical_not => switch (values[node.lhs]) {
                .boolean => |value| .{ .boolean = !value },
                else => return .{ .fail = logic_type_message },
            },
            .add, .subtract, .multiply => switch (try arithmetic(node.kind, values[node.lhs], values[node.rhs])) {
                .value => |value| value,
                .fail => |message| return .{ .fail = message },
            },
            .divide => blk: {
                const left = asFloat(values[node.lhs]) orelse return .{ .fail = arithmetic_type_message };
                const right = asFloat(values[node.rhs]) orelse return .{ .fail = arithmetic_type_message };
                if (right == 0) return .{ .fail = division_by_zero_message };
                const result = left / right;
                if (!std.math.isFinite(result)) return .{ .fail = non_finite_message };
                break :blk .{ .float = result };
            },
            .concat => blk: {
                var out: std.ArrayListUnmanaged(u8) = .empty;
                try appendValue(&out, arena, values[node.lhs]);
                try appendValue(&out, arena, values[node.rhs]);
                break :blk .{ .string = out.items };
            },
            .equal => .{ .boolean = Value.eql(values[node.lhs], values[node.rhs]) },
            .not_equal => .{ .boolean = !Value.eql(values[node.lhs], values[node.rhs]) },
            .less, .less_equal, .greater, .greater_equal => blk: {
                const left = asFloat(values[node.lhs]) orelse return .{ .fail = ordering_type_message };
                const right = asFloat(values[node.rhs]) orelse return .{ .fail = ordering_type_message };
                break :blk .{ .boolean = switch (node.kind) {
                    .less => left < right,
                    .less_equal => left <= right,
                    .greater => left > right,
                    else => left >= right,
                } };
            },
            .logical_and, .logical_or => blk: {
                // No short-circuit: expressions are pure, so both sides
                // always evaluate (only errors are observable).
                const left = values[node.lhs];
                const right = values[node.rhs];
                if (left != .boolean or right != .boolean) return .{ .fail = logic_type_message };
                break :blk .{ .boolean = if (node.kind == .logical_and)
                    left.boolean and right.boolean
                else
                    left.boolean or right.boolean };
            },
            .call => switch (try evalCall(node, values, arena)) {
                .value => |value| value,
                .fail => |message| return .{ .fail = message },
            },
        };
    }
    return .{ .value = values[tree.root] };
}

fn arithmetic(kind: NodeKind, left: Value, right: Value) error{OutOfMemory}!EvalOutcome {
    if (left == .integer and right == .integer) {
        const a = left.integer;
        const b = right.integer;
        const result = switch (kind) {
            .add => @addWithOverflow(a, b),
            .subtract => @subWithOverflow(a, b),
            else => @mulWithOverflow(a, b),
        };
        if (result[1] != 0) return .{ .fail = integer_overflow_message };
        return .{ .value = .{ .integer = result[0] } };
    }
    const a = asFloat(left) orelse return .{ .fail = arithmetic_type_message };
    const b = asFloat(right) orelse return .{ .fail = arithmetic_type_message };
    const result = switch (kind) {
        .add => a + b,
        .subtract => a - b,
        else => a * b,
    };
    if (!std.math.isFinite(result)) return .{ .fail = non_finite_message };
    return .{ .value = .{ .float = result } };
}

fn asFloat(value: Value) ?f32 {
    return switch (value) {
        .integer => |int| @floatFromInt(int),
        .float => |float| float,
        else => null,
    };
}

// ----------------------------------------------------------- the functions

fn evalCall(node: ExprNode, values: *[max_expression_nodes]Value, arena: std.mem.Allocator) error{OutOfMemory}!EvalOutcome {
    const signature = signatureFor(node.function);
    const a = values[node.args[0]];
    switch (node.function) {
        .fixed => {
            const digits = digitsArg(values[node.args[1]]) orelse return .{ .fail = digits_range_message };
            return formatFixed(arena, a, digits, "", signature);
        },
        .percent => {
            const digits: usize = if (node.arg_count > 1)
                digitsArg(values[node.args[1]]) orelse return .{ .fail = digits_range_message }
            else
                0;
            const fraction = asFloat(a) orelse return .{ .fail = signature };
            const scaled = fraction * 100;
            if (!std.math.isFinite(scaled)) return .{ .fail = non_finite_message };
            return formatFixed(arena, .{ .float = scaled }, digits, "%", signature);
        },
        .thousands => {
            if (a != .integer) return .{ .fail = signature };
            return .{ .value = .{ .string = try formatThousands(arena, a.integer) } };
        },
        .date, .time, .datetime => {
            if (a != .integer) return .{ .fail = signature };
            return formatTimestamp(arena, node.function, a.integer);
        },
        .upper, .lower => {
            if (a != .string) return .{ .fail = signature };
            const out = try arena.dupe(u8, a.string);
            for (out) |*byte| {
                byte.* = if (node.function == .upper) std.ascii.toUpper(byte.*) else std.ascii.toLower(byte.*);
            }
            return .{ .value = .{ .string = out } };
        },
        .trim => {
            if (a != .string) return .{ .fail = signature };
            return .{ .value = .{ .string = std.mem.trim(u8, a.string, " \t\r\n") } };
        },
        .min, .max => {
            const b = values[node.args[1]];
            if (a == .integer and b == .integer) {
                const picked = if (node.function == .min) @min(a.integer, b.integer) else @max(a.integer, b.integer);
                return .{ .value = .{ .integer = picked } };
            }
            const fa = asFloat(a) orelse return .{ .fail = signature };
            const fb = asFloat(b) orelse return .{ .fail = signature };
            if (std.math.isNan(fa) or std.math.isNan(fb)) return .{ .fail = non_finite_message };
            return .{ .value = .{ .float = if (node.function == .min) @min(fa, fb) else @max(fa, fb) } };
        },
        .abs => switch (a) {
            .integer => |int| {
                if (int == std.math.minInt(i64)) return .{ .fail = abs_overflow_message };
                return .{ .value = .{ .integer = @intCast(@abs(int)) } };
            },
            .float => |float| {
                if (std.math.isNan(float)) return .{ .fail = non_finite_message };
                return .{ .value = .{ .float = @abs(float) } };
            },
            else => return .{ .fail = signature },
        },
        .round, .floor, .ceil => switch (a) {
            .integer => return .{ .value = a },
            .float => |float| {
                if (!std.math.isFinite(float)) return .{ .fail = non_finite_message };
                const shifted = switch (node.function) {
                    .round => @round(float),
                    .floor => @floor(float),
                    else => @ceil(float),
                };
                if (shifted < -9007199254740992.0 or shifted > 9007199254740992.0) {
                    return .{ .fail = round_range_message };
                }
                return .{ .value = .{ .integer = @intFromFloat(shifted) } };
            },
            else => return .{ .fail = signature },
        },
        .plural => {
            if (a != .integer) return .{ .fail = signature };
            const singular = values[node.args[1]];
            const plural_form = values[node.args[2]];
            if (singular != .string or plural_form != .string) return .{ .fail = signature };
            return .{ .value = .{ .string = if (a.integer == 1) singular.string else plural_form.string } };
        },
        .pad => {
            const width = digitsArg(values[node.args[1]]) orelse return .{ .fail = digits_range_message };
            if (a != .integer) return .{ .fail = signature };
            return .{ .value = .{ .string = try formatPadded(arena, a.integer, width) } };
        },
    }
}

fn digitsArg(value: Value) ?usize {
    if (value != .integer) return null;
    if (value.integer < 0 or value.integer > 6) return null;
    return @intCast(value.integer);
}

/// Fixed-decimal formatting: integers print exactly (digits of zeros
/// appended); floats round through std.fmt's deterministic decimal
/// renderer. `suffix` is the percent sign channel.
fn formatFixed(arena: std.mem.Allocator, value: Value, digits: usize, suffix: []const u8, signature: []const u8) error{OutOfMemory}!EvalOutcome {
    var buffer: [80]u8 = undefined;
    const body = switch (value) {
        .integer => |int| std.fmt.bufPrint(&buffer, "{d}", .{int}) catch return error.OutOfMemory,
        .float => |float| blk: {
            if (!std.math.isFinite(float)) return .{ .fail = non_finite_message };
            break :blk std.fmt.float.render(&buffer, float, .{ .mode = .decimal, .precision = digits }) catch {
                return .{ .fail = non_finite_message };
            };
        },
        else => return .{ .fail = signature },
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, body);
    if (value == .integer and digits > 0) {
        try out.append(arena, '.');
        try out.appendNTimes(arena, '0', digits);
    }
    try out.appendSlice(arena, suffix);
    return .{ .value = .{ .string = out.items } };
}

fn formatThousands(arena: std.mem.Allocator, value: i64) error{OutOfMemory}![]const u8 {
    var buffer: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return error.OutOfMemory;
    const negative = digits.len > 0 and digits[0] == '-';
    const body = if (negative) digits[1..] else digits;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (negative) try out.append(arena, '-');
    for (body, 0..) |byte, index| {
        if (index > 0 and (body.len - index) % 3 == 0) try out.append(arena, ',');
        try out.append(arena, byte);
    }
    return out.items;
}

/// Zero-pad a whole number on the left to `width` digits: pad(7, 2) is
/// "07". The sign precedes the zeros and does not count toward the width
/// (pad(-7, 3) is "-007"), and a number wider than `width` prints in full.
fn formatPadded(arena: std.mem.Allocator, value: i64, width: usize) error{OutOfMemory}![]const u8 {
    var buffer: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return error.OutOfMemory;
    const negative = digits.len > 0 and digits[0] == '-';
    const body = if (negative) digits[1..] else digits;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (negative) try out.append(arena, '-');
    if (body.len < width) try out.appendNTimes(arena, '0', width - body.len);
    try out.appendSlice(arena, body);
    return out.items;
}

/// Format a unix timestamp (seconds) in UTC. Formatting a MODEL timestamp
/// is pure — the same input always renders the same text on every machine.
/// Reading the current time is an effect and lives in the model/fx loop,
/// which the parser teaches at `now()`.
fn formatTimestamp(arena: std.mem.Allocator, function: FunctionId, seconds: i64) error{OutOfMemory}!EvalOutcome {
    const days = @divFloor(seconds, 86_400);
    const second_of_day: u32 = @intCast(@mod(seconds, 86_400));
    const date_parts = civilFromDays(days) orelse return .{ .fail = timestamp_range_message };
    const year: u32 = @intCast(date_parts.year);
    const hour = second_of_day / 3600;
    const minute = (second_of_day % 3600) / 60;
    var buffer: [24]u8 = undefined;
    const text = switch (function) {
        .date => std.fmt.bufPrint(&buffer, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, date_parts.month, date_parts.day }) catch unreachable,
        .time => std.fmt.bufPrint(&buffer, "{d:0>2}:{d:0>2}", .{ hour, minute }) catch unreachable,
        else => std.fmt.bufPrint(&buffer, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ year, date_parts.month, date_parts.day, hour, minute }) catch unreachable,
    };
    return .{ .value = .{ .string = try arena.dupe(u8, text) } };
}

const CivilDate = struct { year: i64, month: u32, day: u32 };

/// Days-since-epoch to a proleptic Gregorian civil date (the classic
/// era-based algorithm). Null outside years 1-9999, which keeps the
/// formatted width fixed and refuses astronomically wrong model data.
fn civilFromDays(days: i64) ?CivilDate {
    const shifted = days + 719_468;
    const era = @divFloor(shifted, 146_097);
    const day_of_era: u32 = @intCast(shifted - era * 146_097);
    const year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    const year = @as(i64, year_of_era) + era * 400;
    const day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    const month_index = (5 * day_of_year + 2) / 153;
    const day = day_of_year - (153 * month_index + 2) / 5 + 1;
    const month = if (month_index < 10) month_index + 3 else month_index - 9;
    const civil_year = if (month <= 2) year + 1 else year;
    if (civil_year < 1 or civil_year > 9999) return null;
    return .{ .year = civil_year, .month = month, .day = day };
}

// ---------------------------------------------------- tooling helpers

/// The first token in `source` that reads as a function call to a name
/// outside the closed library: `native markup check` uses it to attach a
/// did-you-mean to the unknown-function error (the validator itself stays
/// allocation-free, so it cannot format the name into its message).
pub fn firstUnknownFunction(source: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < source.len) {
        const byte = source[index];
        if (byte == '\'') {
            // Skip string literals so quoted parens cannot fake a call.
            const close = std.mem.indexOfScalarPos(u8, source, index + 1, '\'') orelse return null;
            index = close + 1;
            continue;
        }
        if (identifierStartByte(byte)) {
            const start = index;
            while (index < source.len and pathByte(source[index])) index += 1;
            const token = source[start..index];
            var rest = index;
            while (rest < source.len and (source[rest] == ' ' or source[rest] == '\t')) rest += 1;
            if (rest < source.len and source[rest] == '(' and std.mem.indexOfScalar(u8, token, '.') == null) {
                if (findFunction(token) == null and !clockLikeName(token)) return token;
            }
            continue;
        }
        index += 1;
    }
    return null;
}

/// The names of the closed function library, for did-you-mean suggestions.
pub const known_function_names = blk: {
    var names: [function_specs.len][]const u8 = undefined;
    for (function_specs, 0..) |spec, index| names[index] = spec.name;
    break :blk names;
};
