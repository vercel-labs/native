//! calculator model: a classic immediate-execution four-function
//! calculator (the model every desk calculator uses: `2 + 3 × 4 =` is
//! `(2 + 3) × 4 = 20` — each operator applies the one before it; there is
//! no precedence). All arithmetic is f64; display formatting is honest
//! about it (see `formatValue`): integers print exactly up to 12 digits,
//! fractions round to at most 10 decimals for DISPLAY only (the model
//! keeps full precision), and anything non-finite or beyond the 12-digit
//! window prints in scientific notation or as "Error".
//!
//! Update is the plain TEA form — no effects, no timers, no I/O. The
//! whole app is a pure `(Model, Msg) -> Model` fold, which is the point:
//! this is the smallest real Native SDK app.
//!
//! Fixed capacities (loud by design):
//!   - 12 significant digits per typed entry (extra digits are ignored,
//!     exactly like a 12-digit desk calculator)
//!   - one pending operator + one remembered "repeat equals" operation

const std = @import("std");
const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;

// ---------------------------------------------------------------- engine

pub const Op = enum {
    add,
    subtract,
    multiply,
    divide,

    pub fn glyph(op: Op) []const u8 {
        return switch (op) {
            .add => "+",
            .subtract => "−",
            .multiply => "×",
            .divide => "÷",
        };
    }

    pub fn apply(op: Op, a: f64, b: f64) f64 {
        return switch (op) {
            .add => a + b,
            .subtract => a - b,
            .multiply => a * b,
            // 0/0 is NaN and x/0 is ±inf; both format as "Error".
            .divide => a / b,
        };
    }
};

/// Digits a user may type into one number: the classic 12-digit window.
pub const max_entry_digits = 12;

/// The number being typed, kept as the typed characters (not an f64) so
/// "0.10" round-trips exactly as typed and backspace is a char pop.
pub const Entry = struct {
    /// Digit and dot characters in typed order ("12.5"); the sign lives
    /// in `negative` so ± never rewrites the buffer.
    chars: [max_entry_digits + 1]u8 = undefined,
    len: usize = 0,
    negative: bool = false,

    pub fn reset(entry: *Entry) void {
        entry.len = 0;
        entry.negative = false;
    }

    pub fn digitCount(entry: *const Entry) usize {
        var count: usize = 0;
        for (entry.chars[0..entry.len]) |char| {
            if (char != '.') count += 1;
        }
        return count;
    }

    pub fn hasDot(entry: *const Entry) bool {
        return std.mem.indexOfScalar(u8, entry.chars[0..entry.len], '.') != null;
    }

    /// Append one digit. A lone "0" is replaced rather than extended
    /// (typing 0 0 7 shows 7, not 007); past 12 digits input is ignored.
    pub fn pushDigit(entry: *Entry, digit: u8) void {
        if (entry.digitCount() >= max_entry_digits) return;
        if (entry.len == 1 and entry.chars[0] == '0') {
            entry.chars[0] = '0' + digit;
            return;
        }
        entry.chars[entry.len] = '0' + digit;
        entry.len += 1;
    }

    /// Append the decimal point; a leading dot becomes "0." and a second
    /// dot is ignored.
    pub fn pushDot(entry: *Entry) void {
        if (entry.hasDot()) return;
        if (entry.len == 0) {
            entry.chars[0] = '0';
            entry.len = 1;
        }
        if (entry.len + 1 > entry.chars.len) return;
        entry.chars[entry.len] = '.';
        entry.len += 1;
    }

    pub fn pop(entry: *Entry) void {
        if (entry.len > 0) entry.len -= 1;
    }

    pub fn value(entry: *const Entry) f64 {
        var text_slice = entry.chars[0..entry.len];
        // A trailing dot ("12.") is still mid-entry; parse without it.
        if (text_slice.len > 0 and text_slice[text_slice.len - 1] == '.') {
            text_slice = text_slice[0 .. text_slice.len - 1];
        }
        const magnitude = if (text_slice.len == 0) 0 else std.fmt.parseFloat(f64, text_slice) catch 0;
        return if (entry.negative) -magnitude else magnitude;
    }

    /// The display form: sign + typed characters, "0" when empty.
    pub fn text(entry: *const Entry, arena: std.mem.Allocator) []const u8 {
        const digits: []const u8 = if (entry.len == 0) "0" else entry.chars[0..entry.len];
        if (!entry.negative) return arena.dupe(u8, digits) catch "0";
        return std.fmt.allocPrint(arena, "-{s}", .{digits}) catch "0";
    }
};

/// One completed calculation, kept as operands so the memory line
/// reformats from source values, never from stored strings.
pub const Calculation = struct {
    a: f64,
    op: Op,
    b: f64,
    failed: bool,
};

// ----------------------------------------------------------------- model

pub const Key = enum {
    d0,
    d1,
    d2,
    d3,
    d4,
    d5,
    d6,
    d7,
    d8,
    d9,
    dot,
    add,
    subtract,
    multiply,
    divide,
    equals,
    percent,
    negate,
    clear,
    backspace,
};

pub const Msg = union(enum) {
    // One void arm per calculator key: markup message payloads are
    // bindings, not literals, so each keypad button declares its own tag.
    d0,
    d1,
    d2,
    d3,
    d4,
    d5,
    d6,
    d7,
    d8,
    d9,
    dot,
    add,
    subtract,
    multiply,
    divide,
    equals,
    percent,
    negate,
    clear,
    /// Keyboard input through the expression field (the widget keyboard
    /// path): every typed character and backspace arrives here.
    typed: canvas.TextInputEvent,
    /// System appearance (scheme, contrast, reduced motion) flowing in
    /// through `on_appearance`; the app follows it live.
    set_appearance: native_sdk.Appearance,
};

pub const Model = struct {
    // Engine state.
    acc: f64 = 0,
    pending: ?Op = null,
    entry: Entry = .{},
    entry_active: bool = false,
    /// The standing value shown when nothing is being typed (a result,
    /// an operand echo, or 0 at boot).
    value: f64 = 0,
    err: bool = false,
    /// The last completed calculation (the memory line). Also holds the
    /// failing calculation while `err` is set.
    last: ?Calculation = null,
    /// Pressing = again repeats the last operation on the current value
    /// (classic behavior: 2 + 3 = = = walks 5, 8, 11).
    repeat: ?struct { op: Op, operand: f64 } = null,

    // Appearance state (the app follows the system; no in-window theme
    // control by design).
    appearance: native_sdk.Appearance = .{},

    // ------------------------------------------------------------ queries

    pub fn colorScheme(model: *const Model) native_sdk.ColorScheme {
        return model.appearance.color_scheme;
    }

    fn currentOperand(model: *const Model) f64 {
        return if (model.entry_active) model.entry.value() else model.value;
    }

    /// The big display line.
    pub fn displayText(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (model.err) return "Error";
        if (model.entry_active) return model.entry.text(arena);
        return fmtValue(arena, model.value);
    }

    /// The live expression (the text field's content): the pending
    /// operation as it builds, or the failing one while in error.
    pub fn expressionText(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (model.err) {
            const calc = model.last orelse return "";
            return std.fmt.allocPrint(arena, "{s} {s} {s}", .{
                fmtValue(arena, calc.a), calc.op.glyph(), fmtValue(arena, calc.b),
            }) catch "";
        }
        const op = model.pending orelse return "";
        if (model.entry_active) {
            return std.fmt.allocPrint(arena, "{s} {s} {s}", .{
                fmtValue(arena, model.acc), op.glyph(), model.entry.text(arena),
            }) catch "";
        }
        return std.fmt.allocPrint(arena, "{s} {s}", .{ fmtValue(arena, model.acc), op.glyph() }) catch "";
    }

    /// The memory line above the display: the last completed calculation.
    pub fn memoryText(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const calc = model.last orelse return "";
        const result: []const u8 = if (calc.failed) "Error" else fmtValue(arena, calc.op.apply(calc.a, calc.b));
        return std.fmt.allocPrint(arena, "{s} {s} {s} = {s}", .{
            fmtValue(arena, calc.a), calc.op.glyph(), fmtValue(arena, calc.b), result,
        }) catch "";
    }

    // Operator highlights for the keypad (`selected=` bindings).
    pub fn addPending(model: *const Model) bool {
        return model.pending == .add and !model.err;
    }
    pub fn subtractPending(model: *const Model) bool {
        return model.pending == .subtract and !model.err;
    }
    pub fn multiplyPending(model: *const Model) bool {
        return model.pending == .multiply and !model.err;
    }
    pub fn dividePending(model: *const Model) bool {
        return model.pending == .divide and !model.err;
    }

    // ------------------------------------------------------------ pressing

    pub fn press(model: *Model, key: Key) void {
        switch (key) {
            .d0 => model.pressDigit(0),
            .d1 => model.pressDigit(1),
            .d2 => model.pressDigit(2),
            .d3 => model.pressDigit(3),
            .d4 => model.pressDigit(4),
            .d5 => model.pressDigit(5),
            .d6 => model.pressDigit(6),
            .d7 => model.pressDigit(7),
            .d8 => model.pressDigit(8),
            .d9 => model.pressDigit(9),
            .dot => model.pressDot(),
            .add => model.pressOp(.add),
            .subtract => model.pressOp(.subtract),
            .multiply => model.pressOp(.multiply),
            .divide => model.pressOp(.divide),
            .equals => model.pressEquals(),
            .percent => model.pressPercent(),
            .negate => model.pressNegate(),
            .clear => model.clearAll(),
            .backspace => model.pressBackspace(),
        }
    }

    /// A digit clears an error and starts fresh (friendlier than the
    /// classic AC-only recovery; AC works too).
    fn pressDigit(model: *Model, digit: u8) void {
        if (model.err) model.clearAll();
        model.startEntryIfNeeded();
        model.entry.pushDigit(digit);
    }

    fn pressDot(model: *Model) void {
        if (model.err) model.clearAll();
        model.startEntryIfNeeded();
        model.entry.pushDot();
    }

    fn startEntryIfNeeded(model: *Model) void {
        if (model.entry_active) return;
        model.entry.reset();
        model.entry_active = true;
    }

    fn pressOp(model: *Model, op: Op) void {
        if (model.err) return;
        if (model.pending) |pending_op| {
            if (model.entry_active) {
                // Chain: apply the previous operator first (immediate
                // execution), then wait for the next operand.
                if (!model.commit(model.acc, pending_op, model.entry.value())) return;
            }
            // No operand typed: the press just switches the operator.
        } else {
            model.acc = model.currentOperand();
            model.value = model.acc;
        }
        model.pending = op;
        model.entry_active = false;
        model.repeat = null;
    }

    fn pressEquals(model: *Model) void {
        if (model.err) return;
        if (model.pending) |op| {
            // "5 + =" uses the display value as the missing operand,
            // exactly like a desk calculator.
            const operand = model.currentOperand();
            model.repeat = .{ .op = op, .operand = operand };
            model.pending = null;
            _ = model.commit(model.acc, op, operand);
            return;
        }
        if (model.repeat) |again| {
            _ = model.commit(model.currentOperand(), again.op, again.operand);
            return;
        }
        // Bare equals: normalize whatever is typed into the value.
        model.value = model.currentOperand();
        model.entry_active = false;
    }

    /// Apply one operation, record it as the memory line, and either
    /// adopt the result or enter the error state. Returns false on error.
    fn commit(model: *Model, a: f64, op: Op, b: f64) bool {
        const result = op.apply(a, b);
        const failed = !std.math.isFinite(result);
        model.last = .{ .a = a, .op = op, .b = b, .failed = failed };
        model.entry_active = false;
        if (failed) {
            model.err = true;
            model.pending = null;
            model.repeat = null;
            return false;
        }
        model.acc = result;
        model.value = result;
        return true;
    }

    /// Percent divides the current operand by 100 (documented model: no
    /// additive-percent special case).
    fn pressPercent(model: *Model) void {
        if (model.err) return;
        model.value = model.currentOperand() / 100;
        model.entry_active = false;
    }

    fn pressNegate(model: *Model) void {
        if (model.err) return;
        if (model.entry_active) {
            model.entry.negative = !model.entry.negative;
            return;
        }
        model.value = -model.value;
        if (model.pending == null) model.acc = model.value;
    }

    /// Backspace edits the number being typed; results and echoes are
    /// not editable (classic behavior).
    fn pressBackspace(model: *Model) void {
        if (model.err) return;
        if (!model.entry_active) return;
        model.entry.pop();
    }

    pub fn clearAll(model: *Model) void {
        model.acc = 0;
        model.pending = null;
        model.entry.reset();
        model.entry_active = false;
        model.value = 0;
        model.err = false;
        model.last = null;
        model.repeat = null;
    }

    // ------------------------------------------------------------ keyboard

    /// One typed character from the expression field. Unknown characters
    /// are ignored; the model-owned field text never shows them.
    pub fn applyChar(model: *Model, char: u21) void {
        switch (char) {
            '0'...'9' => model.press(@enumFromInt(@intFromEnum(Key.d0) + (char - '0'))),
            '.', ',' => model.press(.dot),
            '+' => model.press(.add),
            '-', '−' => model.press(.subtract),
            '*', 'x', 'X', '×' => model.press(.multiply),
            '/', '÷' => model.press(.divide),
            '%' => model.press(.percent),
            '=' => model.press(.equals),
            'c', 'C' => model.press(.clear),
            else => {},
        }
    }

    pub fn applyTyped(model: *Model, edit: canvas.TextInputEvent) void {
        switch (edit) {
            .insert_text => |text_bytes| {
                var iterator = std.unicode.Utf8Iterator{ .bytes = text_bytes, .i = 0 };
                while (iterator.nextCodepoint()) |char| model.applyChar(char);
            },
            .delete_backward, .delete_word_backward => model.press(.backspace),
            // Caret moves, selections, and forward deletes have no
            // calculator meaning; the field text is model-derived, so
            // ignoring them keeps it stable.
            else => {},
        }
    }
};

// ---------------------------------------------------------------- update

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .d0 => model.press(.d0),
        .d1 => model.press(.d1),
        .d2 => model.press(.d2),
        .d3 => model.press(.d3),
        .d4 => model.press(.d4),
        .d5 => model.press(.d5),
        .d6 => model.press(.d6),
        .d7 => model.press(.d7),
        .d8 => model.press(.d8),
        .d9 => model.press(.d9),
        .dot => model.press(.dot),
        .add => model.press(.add),
        .subtract => model.press(.subtract),
        .multiply => model.press(.multiply),
        .divide => model.press(.divide),
        .equals => model.press(.equals),
        .percent => model.press(.percent),
        .negate => model.press(.negate),
        .clear => model.press(.clear),
        .typed => |edit| model.applyTyped(edit),
        .set_appearance => |appearance| model.appearance = appearance,
    }
}

// ------------------------------------------------------------ formatting

/// Longest formatted value: sign + 12 integer digits + dot + 10 decimals,
/// or a scientific form — 32 bytes covers both with slack.
pub const max_value_chars = 32;

/// Honest f64 display formatting:
///   - non-finite -> "Error"
///   - integers with |v| < 1e12 print exactly ("84", "-2048")
///   - |v| >= 1e12 or 0 < |v| < 1e-9 print in scientific notation
///   - everything else prints with up to 10 decimals, trailing zeros
///     trimmed ("0.3", "3.1415926536") — display rounding only, the
///     model keeps full f64 precision
pub fn formatValue(buffer: []u8, value: f64) []const u8 {
    if (!std.math.isFinite(value)) return "Error";
    // Normalize negative zero for display.
    const v = if (value == 0) 0 else value;
    const magnitude = @abs(v);
    if (v == @trunc(v) and magnitude < 1e12) {
        return std.fmt.bufPrint(buffer, "{d:.0}", .{v}) catch "Error";
    }
    if (magnitude >= 1e12 or magnitude < 1e-9) {
        const printed = std.fmt.bufPrint(buffer, "{e:.6}", .{v}) catch return "Error";
        return trimScientific(printed);
    }
    const printed = std.fmt.bufPrint(buffer, "{d:.10}", .{v}) catch return "Error";
    return trimFraction(printed);
}

pub fn fmtValue(arena: std.mem.Allocator, value: f64) []const u8 {
    var buffer: [max_value_chars]u8 = undefined;
    return arena.dupe(u8, formatValue(&buffer, value)) catch "";
}

/// "0.3000000000" -> "0.3"; "3.0000000000" -> "3".
fn trimFraction(printed: []u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, printed, '.') orelse return printed;
    var end = printed.len;
    while (end > dot + 1 and printed[end - 1] == '0') end -= 1;
    if (end == dot + 1) end = dot;
    return printed[0..end];
}

/// "1.500000e12" -> "1.5e12"; "1.000000e15" -> "1e15".
fn trimScientific(printed: []u8) []const u8 {
    const e_index = std.mem.indexOfScalar(u8, printed, 'e') orelse return printed;
    const mantissa = trimFraction(printed[0..e_index]);
    const exponent = printed[e_index..];
    // The mantissa was trimmed in place; move the exponent up against it.
    std.mem.copyForwards(u8, printed[mantissa.len..], exponent);
    return printed[0 .. mantissa.len + exponent.len];
}
