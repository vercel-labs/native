const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const platform = @import("../platform/root.zig");

pub const AutomationNativeCommand = struct {
    name: []const u8,
    view_label: []const u8 = "",
};

pub const AutomationWidgetActionKind = enum {
    focus,
    press,
    toggle,
    increment,
    decrement,
    set_text,
    set_selection,
    set_composition,
    commit_composition,
    cancel_composition,
    select,
    drag,
    drop_files,
    dismiss,
};

pub const AutomationWidgetAction = struct {
    view_label: []const u8,
    id: canvas.ObjectId,
    action: AutomationWidgetActionKind,
    value: []const u8 = "",
};

pub const AutomationWidgetTarget = struct {
    view_label: []const u8,
    id: canvas.ObjectId,
};

pub const AutomationWidgetWheel = struct {
    target: AutomationWidgetTarget,
    delta_y: f32,
};

/// `widget-context-menu <view-label> <id> <item-index>`: invoke one of
/// the target widget's declared context-menu items. `item_index` is the
/// 0-based index into the widget's declared items, exactly as the
/// snapshot lists them (separators count).
pub const AutomationWidgetContextMenuItem = struct {
    target: AutomationWidgetTarget,
    item_index: usize,
};

pub const AutomationWidgetKey = struct {
    view_label: []const u8,
    key: []const u8,
    text: []const u8 = "",
    modifiers: AutomationKeyModifiers = .{},
};

/// Modifier chord for automation key dispatch, mirroring
/// `platform.ShortcutModifiers` field-for-field (automation stays
/// platform-agnostic; the dispatch layer copies these across).
pub const AutomationKeyModifiers = struct {
    shift: bool = false,
    control: bool = false,
    option: bool = false,
    command: bool = false,
    primary: bool = false,
};

const AutomationKeyChord = struct {
    key: []const u8,
    modifiers: AutomationKeyModifiers = .{},
};

/// Parse a `cmd+c` / `ctrl+shift+arrowleft` style chord. `cmd` sets both
/// `command` and `primary` so one spelling drives the primary shortcut on
/// every platform. A token without recognized modifier prefixes (including
/// a literal `+`) is passed through as the key unchanged.
fn parseAutomationKeyChord(token: []const u8) AutomationKeyChord {
    var modifiers = AutomationKeyModifiers{};
    var rest = token;
    while (std.mem.indexOfScalar(u8, rest, '+')) |separator| {
        if (separator == 0 or separator + 1 >= rest.len) break;
        const part = rest[0..separator];
        if (std.ascii.eqlIgnoreCase(part, "cmd") or std.ascii.eqlIgnoreCase(part, "meta") or std.ascii.eqlIgnoreCase(part, "super")) {
            modifiers.command = true;
            modifiers.primary = true;
        } else if (std.ascii.eqlIgnoreCase(part, "ctrl") or std.ascii.eqlIgnoreCase(part, "control")) {
            modifiers.control = true;
        } else if (std.ascii.eqlIgnoreCase(part, "alt") or std.ascii.eqlIgnoreCase(part, "option")) {
            modifiers.option = true;
        } else if (std.ascii.eqlIgnoreCase(part, "shift")) {
            modifiers.shift = true;
        } else {
            return .{ .key = token };
        }
        rest = rest[separator + 1 ..];
    }
    if (rest.len == 0) return .{ .key = token };
    return .{ .key = rest, .modifiers = modifiers };
}

pub const AutomationWidgetPointerDrag = struct {
    target: AutomationWidgetTarget,
    start_x_ratio: f32,
    end_x_ratio: f32,
    start_y_ratio: f32 = 0.5,
    end_y_ratio: f32 = 0.5,
};

const AutomationToken = struct {
    token: []const u8,
    rest: []const u8 = "",
};

pub const AutomationResizeCommand = struct {
    width: f32,
    height: f32,
    scale_factor: f32 = 1,
};

pub const AutomationScreenshotCommand = struct {
    view_label: []const u8,
    /// Render scale for the screenshot pixels. Defaults to 1 for
    /// deterministic output independent of the display's backing scale.
    scale: ?f32 = null,
};

pub fn parseAutomationCommandName(value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \n\r\t");
    if (trimmed.len == 0) return error.InvalidCommand;
    const separator = std.mem.indexOfAny(u8, trimmed, " \n\r\t") orelse return trimmed;
    return trimmed[0..separator];
}

/// `tray-action <item-id>`: the numeric dropdown item id printed by the
/// snapshot's `tray-item #N` lines (bare number, like widget ids).
pub fn parseAutomationTrayItemId(value: []const u8) !platform.TrayItemId {
    const trimmed = std.mem.trim(u8, value, " \n\r\t");
    if (trimmed.len == 0) return error.InvalidCommand;
    if (std.mem.indexOfAny(u8, trimmed, " \n\r\t") != null) return error.InvalidCommand;
    const id = std.fmt.parseInt(platform.TrayItemId, trimmed, 10) catch return error.InvalidCommand;
    if (id == 0) return error.InvalidCommand;
    return id;
}

pub fn parseAutomationViewLabel(value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \n\r\t");
    if (trimmed.len == 0) return error.InvalidCommand;
    return trimmed;
}

pub fn parseAutomationNativeCommand(value: []const u8) !AutomationNativeCommand {
    const trimmed = std.mem.trim(u8, value, " \n\r\t");
    if (trimmed.len == 0) return error.InvalidCommand;
    const separator = std.mem.indexOfAny(u8, trimmed, " \n\r\t") orelse return .{ .name = trimmed };
    const view_label = std.mem.trim(u8, trimmed[separator + 1 ..], " \n\r\t");
    return .{
        .name = trimmed[0..separator],
        .view_label = view_label,
    };
}

pub fn parseAutomationWidgetAction(value: []const u8) !AutomationWidgetAction {
    const view = takeAutomationToken(value) orelse return error.InvalidCommand;
    const id_part = takeAutomationToken(view.rest) orelse return error.InvalidCommand;
    const action_part = takeAutomationToken(id_part.rest) orelse return error.InvalidCommand;
    const id = std.fmt.parseInt(canvas.ObjectId, id_part.token, 10) catch return error.InvalidCommand;
    if (id == 0) return error.InvalidCommand;
    const action = automationWidgetActionKindFromString(action_part.token) orelse return error.InvalidCommand;
    const action_value = std.mem.trim(u8, action_part.rest, " \n\r\t");
    if (action == .set_selection and action_value.len == 0) return error.InvalidCommand;
    if (action == .drop_files and action_value.len == 0) return error.InvalidCommand;
    if (action != .set_text and
        action != .set_selection and
        action != .set_composition and
        action != .drag and
        action != .drop_files and
        action_value.len > 0) return error.InvalidCommand;
    return .{
        .view_label = view.token,
        .id = id,
        .action = action,
        .value = action_value,
    };
}

pub fn parseAutomationWidgetTarget(value: []const u8) !AutomationWidgetTarget {
    const view = takeAutomationToken(value) orelse return error.InvalidCommand;
    const id_part = takeAutomationToken(view.rest) orelse return error.InvalidCommand;
    if (takeAutomationToken(id_part.rest) != null) return error.InvalidCommand;
    const id = std.fmt.parseInt(canvas.ObjectId, id_part.token, 10) catch return error.InvalidCommand;
    if (id == 0) return error.InvalidCommand;
    return .{ .view_label = view.token, .id = id };
}

/// Target of a `provenance` query: a widget named by structural id
/// (`<view-label> <id>`), or by hit-test point in view-local points
/// (`<view-label> at <x> <y>`).
pub const AutomationProvenanceTarget = struct {
    view_label: []const u8,
    id: canvas.ObjectId = 0,
    point: ?geometry.PointF = null,
};

pub fn parseAutomationProvenanceTarget(value: []const u8) !AutomationProvenanceTarget {
    const view = takeAutomationToken(value) orelse return error.InvalidCommand;
    const first = takeAutomationToken(view.rest) orelse return error.InvalidCommand;
    if (std.mem.eql(u8, first.token, "at")) {
        const x_part = takeAutomationToken(first.rest) orelse return error.InvalidCommand;
        const y_part = takeAutomationToken(x_part.rest) orelse return error.InvalidCommand;
        if (takeAutomationToken(y_part.rest) != null) return error.InvalidCommand;
        const x = std.fmt.parseFloat(f32, x_part.token) catch return error.InvalidCommand;
        const y = std.fmt.parseFloat(f32, y_part.token) catch return error.InvalidCommand;
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return error.InvalidCommand;
        return .{ .view_label = view.token, .point = geometry.PointF.init(x, y) };
    }
    if (takeAutomationToken(first.rest) != null) return error.InvalidCommand;
    const id = std.fmt.parseInt(canvas.ObjectId, first.token, 10) catch return error.InvalidCommand;
    if (id == 0) return error.InvalidCommand;
    return .{ .view_label = view.token, .id = id };
}

pub fn parseAutomationWidgetWheel(value: []const u8) !AutomationWidgetWheel {
    const view = takeAutomationToken(value) orelse return error.InvalidCommand;
    const id_part = takeAutomationToken(view.rest) orelse return error.InvalidCommand;
    const delta_part = takeAutomationToken(id_part.rest) orelse return error.InvalidCommand;
    if (takeAutomationToken(delta_part.rest) != null) return error.InvalidCommand;
    const id = std.fmt.parseInt(canvas.ObjectId, id_part.token, 10) catch return error.InvalidCommand;
    if (id == 0) return error.InvalidCommand;
    const delta_y = std.fmt.parseFloat(f32, delta_part.token) catch return error.InvalidCommand;
    if (!std.math.isFinite(delta_y)) return error.InvalidCommand;
    return .{
        .target = .{ .view_label = view.token, .id = id },
        .delta_y = delta_y,
    };
}

pub fn parseAutomationWidgetContextMenuItem(value: []const u8) !AutomationWidgetContextMenuItem {
    const view = takeAutomationToken(value) orelse return error.InvalidCommand;
    const id_part = takeAutomationToken(view.rest) orelse return error.InvalidCommand;
    const item_part = takeAutomationToken(id_part.rest) orelse return error.InvalidCommand;
    if (takeAutomationToken(item_part.rest) != null) return error.InvalidCommand;
    const id = std.fmt.parseInt(canvas.ObjectId, id_part.token, 10) catch return error.InvalidCommand;
    if (id == 0) return error.InvalidCommand;
    const item_index = std.fmt.parseInt(usize, item_part.token, 10) catch return error.InvalidCommand;
    return .{
        .target = .{ .view_label = view.token, .id = id },
        .item_index = item_index,
    };
}

pub fn parseAutomationWidgetKey(value: []const u8) !AutomationWidgetKey {
    const view = takeAutomationToken(value) orelse return error.InvalidCommand;
    const key_part = takeAutomationToken(view.rest) orelse return error.InvalidCommand;
    const text = std.mem.trim(u8, key_part.rest, " \n\r\t");
    if (key_part.token.len == 0) return error.InvalidCommand;
    const chord = parseAutomationKeyChord(key_part.token);
    return .{ .view_label = view.token, .key = chord.key, .text = text, .modifiers = chord.modifiers };
}

pub fn parseAutomationWidgetPointerDrag(value: []const u8) !AutomationWidgetPointerDrag {
    const view = takeAutomationToken(value) orelse return error.InvalidCommand;
    const id_part = takeAutomationToken(view.rest) orelse return error.InvalidCommand;
    const start_x_part = takeAutomationToken(id_part.rest) orelse return error.InvalidCommand;
    const end_x_part = takeAutomationToken(start_x_part.rest) orelse return error.InvalidCommand;
    const start_y_part = takeAutomationToken(end_x_part.rest);
    const end_y_part = if (start_y_part) |part| takeAutomationToken(part.rest) else null;
    if (end_y_part) |part| {
        if (takeAutomationToken(part.rest) != null) return error.InvalidCommand;
    } else if (start_y_part != null) {
        return error.InvalidCommand;
    }

    const id = std.fmt.parseInt(canvas.ObjectId, id_part.token, 10) catch return error.InvalidCommand;
    if (id == 0) return error.InvalidCommand;
    const start_x_ratio = std.fmt.parseFloat(f32, start_x_part.token) catch return error.InvalidCommand;
    const end_x_ratio = std.fmt.parseFloat(f32, end_x_part.token) catch return error.InvalidCommand;
    const start_y_ratio = if (start_y_part) |part| std.fmt.parseFloat(f32, part.token) catch return error.InvalidCommand else 0.5;
    const end_y_ratio = if (end_y_part) |part| std.fmt.parseFloat(f32, part.token) catch return error.InvalidCommand else 0.5;
    if (!std.math.isFinite(start_x_ratio) or
        !std.math.isFinite(end_x_ratio) or
        !std.math.isFinite(start_y_ratio) or
        !std.math.isFinite(end_y_ratio)) return error.InvalidCommand;

    return .{
        .target = .{ .view_label = view.token, .id = id },
        .start_x_ratio = start_x_ratio,
        .end_x_ratio = end_x_ratio,
        .start_y_ratio = start_y_ratio,
        .end_y_ratio = end_y_ratio,
    };
}

pub fn parseAutomationScreenshotCommand(value: []const u8) !AutomationScreenshotCommand {
    const view = takeAutomationToken(value) orelse return error.InvalidCommand;
    const scale_part = takeAutomationToken(view.rest) orelse return AutomationScreenshotCommand{ .view_label = view.token };
    if (takeAutomationToken(scale_part.rest) != null) return error.InvalidCommand;
    const scale = std.fmt.parseFloat(f32, scale_part.token) catch return error.InvalidCommand;
    if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidCommand;
    return .{ .view_label = view.token, .scale = scale };
}

fn takeAutomationToken(value: []const u8) ?AutomationToken {
    const trimmed = std.mem.trim(u8, value, " \n\r\t");
    if (trimmed.len == 0) return null;
    const separator = std.mem.indexOfAny(u8, trimmed, " \n\r\t") orelse return .{ .token = trimmed };
    return .{
        .token = trimmed[0..separator],
        .rest = std.mem.trim(u8, trimmed[separator + 1 ..], " \n\r\t"),
    };
}

fn automationWidgetActionKindFromString(value: []const u8) ?AutomationWidgetActionKind {
    if (std.ascii.eqlIgnoreCase(value, "focus")) return .focus;
    if (std.ascii.eqlIgnoreCase(value, "press")) return .press;
    if (std.ascii.eqlIgnoreCase(value, "toggle")) return .toggle;
    if (std.ascii.eqlIgnoreCase(value, "increment")) return .increment;
    if (std.ascii.eqlIgnoreCase(value, "decrement")) return .decrement;
    if (std.ascii.eqlIgnoreCase(value, "set_text") or std.ascii.eqlIgnoreCase(value, "set-text")) return .set_text;
    if (std.ascii.eqlIgnoreCase(value, "set_selection") or std.ascii.eqlIgnoreCase(value, "set-selection")) return .set_selection;
    if (std.ascii.eqlIgnoreCase(value, "set_composition") or std.ascii.eqlIgnoreCase(value, "set-composition")) return .set_composition;
    if (std.ascii.eqlIgnoreCase(value, "commit_composition") or std.ascii.eqlIgnoreCase(value, "commit-composition")) return .commit_composition;
    if (std.ascii.eqlIgnoreCase(value, "cancel_composition") or std.ascii.eqlIgnoreCase(value, "cancel-composition")) return .cancel_composition;
    if (std.ascii.eqlIgnoreCase(value, "select")) return .select;
    if (std.ascii.eqlIgnoreCase(value, "drag")) return .drag;
    if (std.ascii.eqlIgnoreCase(value, "drop_files") or std.ascii.eqlIgnoreCase(value, "drop-files")) return .drop_files;
    if (std.ascii.eqlIgnoreCase(value, "dismiss")) return .dismiss;
    return null;
}

pub fn automationWidgetActionSupported(actions: canvas.WidgetActions, action: AutomationWidgetActionKind) bool {
    return switch (action) {
        .focus => actions.focus,
        .press => actions.press,
        .toggle => actions.toggle,
        .increment => actions.increment,
        .decrement => actions.decrement,
        .set_text => actions.set_text,
        .set_selection => actions.set_selection,
        .set_composition, .commit_composition, .cancel_composition => actions.set_text,
        .select => actions.select,
        .drag => actions.drag,
        .drop_files => actions.drop_files,
        .dismiss => actions.dismiss,
    };
}

pub fn parseAutomationDropPaths(value: []const u8, output: [][]const u8) ![]const []const u8 {
    var parts = std.mem.tokenizeAny(u8, value, " \n\r\t");
    var len: usize = 0;
    while (parts.next()) |path| {
        if (len >= output.len) return error.InvalidCommand;
        output[len] = path;
        len += 1;
    }
    if (len == 0) return error.InvalidCommand;
    return output[0..len];
}

pub fn parseAutomationTextSelection(value: []const u8) !canvas.TextSelection {
    var parts = std.mem.tokenizeAny(u8, value, " \n\r\t");
    const anchor_bytes = parts.next() orelse return error.InvalidCommand;
    const focus_bytes = parts.next() orelse return error.InvalidCommand;
    if (parts.next() != null) return error.InvalidCommand;
    return .{
        .anchor = std.fmt.parseInt(usize, anchor_bytes, 10) catch return error.InvalidCommand,
        .focus = std.fmt.parseInt(usize, focus_bytes, 10) catch return error.InvalidCommand,
    };
}

pub fn parseAutomationDragDelta(value: []const u8) !geometry.OffsetF {
    const trimmed = std.mem.trim(u8, value, " \n\r\t");
    if (trimmed.len == 0) return geometry.OffsetF.init(16, 0);
    var parts = std.mem.tokenizeAny(u8, trimmed, " \n\r\t");
    const dx_bytes = parts.next() orelse return error.InvalidCommand;
    const dy_bytes = parts.next() orelse return error.InvalidCommand;
    if (parts.next() != null) return error.InvalidCommand;
    const dx = std.fmt.parseFloat(f32, dx_bytes) catch return error.InvalidCommand;
    const dy = std.fmt.parseFloat(f32, dy_bytes) catch return error.InvalidCommand;
    if (!std.math.isFinite(dx) or !std.math.isFinite(dy)) return error.InvalidCommand;
    return geometry.OffsetF.init(dx, dy);
}

pub fn parseAutomationResizeCommand(value: []const u8) !AutomationResizeCommand {
    var parts = std.mem.tokenizeAny(u8, value, " \n\r\t");
    const width_bytes = parts.next() orelse return error.InvalidCommand;
    const height_bytes = parts.next() orelse return error.InvalidCommand;
    const scale_bytes = parts.next();
    if (parts.next() != null) return error.InvalidCommand;
    const width = std.fmt.parseFloat(f32, width_bytes) catch return error.InvalidCommand;
    const height = std.fmt.parseFloat(f32, height_bytes) catch return error.InvalidCommand;
    const scale_factor = if (scale_bytes) |bytes| std.fmt.parseFloat(f32, bytes) catch return error.InvalidCommand else 1;
    if (!std.math.isFinite(width) or !std.math.isFinite(height) or !std.math.isFinite(scale_factor)) return error.InvalidCommand;
    if (width <= 0 or height <= 0 or scale_factor <= 0) return error.InvalidCommand;
    return .{
        .width = width,
        .height = height,
        .scale_factor = scale_factor,
    };
}

test "runtime parses automation resize commands" {
    const resize = try parseAutomationResizeCommand("900 640");
    try std.testing.expectEqual(@as(f32, 900), resize.width);
    try std.testing.expectEqual(@as(f32, 640), resize.height);
    try std.testing.expectEqual(@as(f32, 1), resize.scale_factor);

    const scaled = try parseAutomationResizeCommand("900 640 2");
    try std.testing.expectEqual(@as(f32, 2), scaled.scale_factor);

    try std.testing.expectError(error.InvalidCommand, parseAutomationResizeCommand(""));
    try std.testing.expectError(error.InvalidCommand, parseAutomationResizeCommand("900"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationResizeCommand("0 640"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationResizeCommand("900 nan"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationResizeCommand("900 640 1 2"));
}

test "runtime parses automation screenshot commands" {
    const plain = try parseAutomationScreenshotCommand("inbox-canvas");
    try std.testing.expectEqualStrings("inbox-canvas", plain.view_label);
    try std.testing.expect(plain.scale == null);

    const scaled = try parseAutomationScreenshotCommand(" inbox-canvas 2 ");
    try std.testing.expectEqualStrings("inbox-canvas", scaled.view_label);
    try std.testing.expectEqual(@as(f32, 2), scaled.scale.?);

    try std.testing.expectError(error.InvalidCommand, parseAutomationScreenshotCommand(""));
    try std.testing.expectError(error.InvalidCommand, parseAutomationScreenshotCommand("inbox-canvas nope"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationScreenshotCommand("inbox-canvas 0"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationScreenshotCommand("inbox-canvas -1"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationScreenshotCommand("inbox-canvas nan"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationScreenshotCommand("inbox-canvas 2 3"));
}

test "runtime parses automation drag deltas" {
    const default_delta = try parseAutomationDragDelta("");
    try std.testing.expectEqual(@as(f32, 16), default_delta.dx);
    try std.testing.expectEqual(@as(f32, 0), default_delta.dy);

    const explicit_delta = try parseAutomationDragDelta("18 2");
    try std.testing.expectEqual(@as(f32, 18), explicit_delta.dx);
    try std.testing.expectEqual(@as(f32, 2), explicit_delta.dy);

    try std.testing.expectError(error.InvalidCommand, parseAutomationDragDelta("18"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationDragDelta("18 nope"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationDragDelta("18 2 3"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationDragDelta("nan 2"));
}

test "runtime parses automation text selections" {
    const selection = try parseAutomationTextSelection("1 4");
    try std.testing.expectEqual(@as(usize, 1), selection.anchor);
    try std.testing.expectEqual(@as(usize, 4), selection.focus);

    const reverse = try parseAutomationTextSelection("8 2");
    try std.testing.expectEqual(@as(usize, 8), reverse.anchor);
    try std.testing.expectEqual(@as(usize, 2), reverse.focus);

    try std.testing.expectError(error.InvalidCommand, parseAutomationTextSelection(""));
    try std.testing.expectError(error.InvalidCommand, parseAutomationTextSelection("1"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationTextSelection("-1 2"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationTextSelection("1 nope"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationTextSelection("1 2 3"));
}

test "runtime parses automation focus view labels" {
    const label = try parseAutomationViewLabel(" refresh-button \n");
    try std.testing.expectEqualStrings("refresh-button", label);
    try std.testing.expectError(error.InvalidCommand, parseAutomationViewLabel(""));
}

test "runtime parses automation widget actions" {
    const press = try parseAutomationWidgetAction("canvas 42 press");
    try std.testing.expectEqualStrings("canvas", press.view_label);
    try std.testing.expectEqual(@as(canvas.ObjectId, 42), press.id);
    try std.testing.expectEqual(AutomationWidgetActionKind.press, press.action);
    try std.testing.expectEqualStrings("", press.value);

    const set_text = try parseAutomationWidgetAction("canvas 7 set-text hello world");
    try std.testing.expectEqual(@as(canvas.ObjectId, 7), set_text.id);
    try std.testing.expectEqual(AutomationWidgetActionKind.set_text, set_text.action);
    try std.testing.expectEqualStrings("hello world", set_text.value);

    const set_text_underscore = try parseAutomationWidgetAction("canvas 7 set_text");
    try std.testing.expectEqual(AutomationWidgetActionKind.set_text, set_text_underscore.action);
    try std.testing.expectEqualStrings("", set_text_underscore.value);

    const set_selection = try parseAutomationWidgetAction("canvas 7 set-selection 1 4");
    try std.testing.expectEqual(AutomationWidgetActionKind.set_selection, set_selection.action);
    try std.testing.expectEqualStrings("1 4", set_selection.value);

    const set_selection_underscore = try parseAutomationWidgetAction("canvas 7 set_selection 4 1");
    try std.testing.expectEqual(AutomationWidgetActionKind.set_selection, set_selection_underscore.action);
    try std.testing.expectEqualStrings("4 1", set_selection_underscore.value);

    const set_composition = try parseAutomationWidgetAction("canvas 7 set-composition composing text");
    try std.testing.expectEqual(AutomationWidgetActionKind.set_composition, set_composition.action);
    try std.testing.expectEqualStrings("composing text", set_composition.value);

    const commit_composition = try parseAutomationWidgetAction("canvas 7 commit-composition");
    try std.testing.expectEqual(AutomationWidgetActionKind.commit_composition, commit_composition.action);

    const cancel_composition = try parseAutomationWidgetAction("canvas 7 cancel_composition");
    try std.testing.expectEqual(AutomationWidgetActionKind.cancel_composition, cancel_composition.action);

    const drag = try parseAutomationWidgetAction("canvas 2 drag");
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), drag.id);
    try std.testing.expectEqual(AutomationWidgetActionKind.drag, drag.action);
    try std.testing.expectEqualStrings("", drag.value);

    const drag_delta = try parseAutomationWidgetAction("canvas 2 drag 18 2");
    try std.testing.expectEqual(AutomationWidgetActionKind.drag, drag_delta.action);
    try std.testing.expectEqualStrings("18 2", drag_delta.value);

    const drop_files = try parseAutomationWidgetAction("canvas 9 drop-files /tmp/report.csv /tmp/chart.png");
    try std.testing.expectEqual(@as(canvas.ObjectId, 9), drop_files.id);
    try std.testing.expectEqual(AutomationWidgetActionKind.drop_files, drop_files.action);
    try std.testing.expectEqualStrings("/tmp/report.csv /tmp/chart.png", drop_files.value);

    const drop_files_underscore = try parseAutomationWidgetAction("canvas 9 drop_files /tmp/report.csv");
    try std.testing.expectEqual(AutomationWidgetActionKind.drop_files, drop_files_underscore.action);
    try std.testing.expectEqualStrings("/tmp/report.csv", drop_files_underscore.value);

    const dismiss = try parseAutomationWidgetAction("canvas 10 dismiss");
    try std.testing.expectEqual(@as(canvas.ObjectId, 10), dismiss.id);
    try std.testing.expectEqual(AutomationWidgetActionKind.dismiss, dismiss.action);
    try std.testing.expectEqualStrings("", dismiss.value);

    var drop_paths_buffer: [2][]const u8 = undefined;
    const drop_paths = try parseAutomationDropPaths(" /tmp/report.csv /tmp/chart.png ", drop_paths_buffer[0..]);
    try std.testing.expectEqual(@as(usize, 2), drop_paths.len);
    try std.testing.expectEqualStrings("/tmp/report.csv", drop_paths[0]);
    try std.testing.expectEqualStrings("/tmp/chart.png", drop_paths[1]);
    try std.testing.expectError(error.InvalidCommand, parseAutomationDropPaths("", drop_paths_buffer[0..]));

    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetAction(""));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetAction("canvas 0 press"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetAction("canvas nope press"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetAction("canvas 42 press extra"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetAction("canvas 42 set-selection"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetAction("canvas 42 commit-composition extra"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetAction("canvas 42 drop-files"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetAction("canvas 42 dismiss extra"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetAction("canvas 42 unknown"));
}

test "runtime parses automation tray item ids" {
    try std.testing.expectEqual(@as(platform.TrayItemId, 4), try parseAutomationTrayItemId("4"));
    try std.testing.expectEqual(@as(platform.TrayItemId, 12), try parseAutomationTrayItemId("  12  "));
    try std.testing.expectError(error.InvalidCommand, parseAutomationTrayItemId(""));
    try std.testing.expectError(error.InvalidCommand, parseAutomationTrayItemId("0"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationTrayItemId("open"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationTrayItemId("4 5"));
}

test "runtime parses automation widget click targets" {
    const target = try parseAutomationWidgetTarget("canvas 42");
    try std.testing.expectEqualStrings("canvas", target.view_label);
    try std.testing.expectEqual(@as(canvas.ObjectId, 42), target.id);

    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetTarget(""));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetTarget("canvas"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetTarget("canvas 0"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetTarget("canvas nope"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetTarget("canvas 42 extra"));
}

test "runtime parses automation provenance targets" {
    const by_id = try parseAutomationProvenanceTarget("canvas 42");
    try std.testing.expectEqualStrings("canvas", by_id.view_label);
    try std.testing.expectEqual(@as(canvas.ObjectId, 42), by_id.id);
    try std.testing.expect(by_id.point == null);

    const at_point = try parseAutomationProvenanceTarget("canvas at 120 64.5");
    try std.testing.expectEqualStrings("canvas", at_point.view_label);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), at_point.id);
    try std.testing.expectEqual(@as(f32, 120), at_point.point.?.x);
    try std.testing.expectEqual(@as(f32, 64.5), at_point.point.?.y);

    try std.testing.expectError(error.InvalidCommand, parseAutomationProvenanceTarget(""));
    try std.testing.expectError(error.InvalidCommand, parseAutomationProvenanceTarget("canvas"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationProvenanceTarget("canvas 0"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationProvenanceTarget("canvas at 10"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationProvenanceTarget("canvas at 10 nan"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationProvenanceTarget("canvas at 10 20 30"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationProvenanceTarget("canvas 42 extra"));
}

test "runtime parses automation widget wheel targets" {
    const wheel = try parseAutomationWidgetWheel("canvas 42 18.5");
    try std.testing.expectEqualStrings("canvas", wheel.target.view_label);
    try std.testing.expectEqual(@as(canvas.ObjectId, 42), wheel.target.id);
    try std.testing.expectEqual(@as(f32, 18.5), wheel.delta_y);

    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetWheel(""));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetWheel("canvas"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetWheel("canvas 0 18"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetWheel("canvas nope 18"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetWheel("canvas 42 nope"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetWheel("canvas 42 nan"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetWheel("canvas 42 18 extra"));
}

test "runtime parses automation widget context-menu items" {
    const item = try parseAutomationWidgetContextMenuItem("canvas 42 1");
    try std.testing.expectEqualStrings("canvas", item.target.view_label);
    try std.testing.expectEqual(@as(canvas.ObjectId, 42), item.target.id);
    try std.testing.expectEqual(@as(usize, 1), item.item_index);

    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetContextMenuItem(""));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetContextMenuItem("canvas"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetContextMenuItem("canvas 42"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetContextMenuItem("canvas 0 1"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetContextMenuItem("canvas nope 1"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetContextMenuItem("canvas 42 nope"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetContextMenuItem("canvas 42 1 extra"));
}

test "runtime parses automation widget key inputs" {
    const tab = try parseAutomationWidgetKey("canvas tab");
    try std.testing.expectEqualStrings("canvas", tab.view_label);
    try std.testing.expectEqualStrings("tab", tab.key);
    try std.testing.expectEqualStrings("", tab.text);

    const typed = try parseAutomationWidgetKey("canvas a a");
    try std.testing.expectEqualStrings("canvas", typed.view_label);
    try std.testing.expectEqualStrings("a", typed.key);
    try std.testing.expectEqualStrings("a", typed.text);

    const named_text = try parseAutomationWidgetKey("canvas space word value");
    try std.testing.expectEqualStrings("space", named_text.key);
    try std.testing.expectEqualStrings("word value", named_text.text);

    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetKey(""));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetKey("canvas"));
}

test "runtime parses automation widget key modifier chords" {
    const copy = try parseAutomationWidgetKey("canvas cmd+c");
    try std.testing.expectEqualStrings("c", copy.key);
    try std.testing.expect(copy.modifiers.command);
    try std.testing.expect(copy.modifiers.primary);
    try std.testing.expect(!copy.modifiers.shift);

    const extend = try parseAutomationWidgetKey("canvas ctrl+shift+arrowleft");
    try std.testing.expectEqualStrings("arrowleft", extend.key);
    try std.testing.expect(extend.modifiers.control);
    try std.testing.expect(extend.modifiers.shift);
    try std.testing.expect(!extend.modifiers.command);

    // Unrecognized prefixes and a literal plus pass through untouched.
    const literal_plus = try parseAutomationWidgetKey("canvas +");
    try std.testing.expectEqualStrings("+", literal_plus.key);
    try std.testing.expectEqualDeep(AutomationKeyModifiers{}, literal_plus.modifiers);
    const unknown = try parseAutomationWidgetKey("canvas foo+c");
    try std.testing.expectEqualStrings("foo+c", unknown.key);
}

test "runtime parses automation widget pointer drags" {
    const centered = try parseAutomationWidgetPointerDrag("canvas 42 0.25 0.82");
    try std.testing.expectEqualStrings("canvas", centered.target.view_label);
    try std.testing.expectEqual(@as(canvas.ObjectId, 42), centered.target.id);
    try std.testing.expectEqual(@as(f32, 0.25), centered.start_x_ratio);
    try std.testing.expectEqual(@as(f32, 0.82), centered.end_x_ratio);
    try std.testing.expectEqual(@as(f32, 0.5), centered.start_y_ratio);
    try std.testing.expectEqual(@as(f32, 0.5), centered.end_y_ratio);

    const diagonal = try parseAutomationWidgetPointerDrag("canvas 42 -0.1 1.1 0.2 0.9");
    try std.testing.expectEqual(@as(f32, -0.1), diagonal.start_x_ratio);
    try std.testing.expectEqual(@as(f32, 1.1), diagonal.end_x_ratio);
    try std.testing.expectEqual(@as(f32, 0.2), diagonal.start_y_ratio);
    try std.testing.expectEqual(@as(f32, 0.9), diagonal.end_y_ratio);

    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetPointerDrag(""));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetPointerDrag("canvas"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetPointerDrag("canvas 0 0.2 0.8"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetPointerDrag("canvas nope 0.2 0.8"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetPointerDrag("canvas 42 0.2"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetPointerDrag("canvas 42 nope 0.8"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetPointerDrag("canvas 42 0.2 nan"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetPointerDrag("canvas 42 0.2 0.8 0.5"));
    try std.testing.expectError(error.InvalidCommand, parseAutomationWidgetPointerDrag("canvas 42 0.2 0.8 0.5 0.5 extra"));
}
