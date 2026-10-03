//! Native consumer of the optional compiled TypeScript view. This module
//! never evaluates bindings or reads the model. Tree data is copied before
//! scriptc's result arena resets; strings and nodes then live for this native
//! tree generation. Canonical event envelopes become ordinary journaled Msgs.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("core.zig");
pub const enabled = @hasDecl(core, "nativeView");
const Ui = sdk.canvas.Ui(core.Msg);

const Record = struct {
    end: usize,
    kind: enum { column, row, stack, separator, panel, badge, input, search_field, textarea, text, button, checkbox, switch_control, toggle, slider, status_bar, spacer, scroll, avatar, radio, radio_group, toggle_button, toggle_group, accordion, tabs, segmented_control, tree, list, list_item, select, dropdown_menu, menu_item, split, resizable },
    text: []const u8,
    placeholder: []const u8 = "",
    wrap: ?bool = null,
    submitOnEnter: bool = false,
    key: ?[]const u8 = null,
    keyInt: ?i64 = null,
    keySlot: usize = 0,
    globalKey: ?[]const u8 = null,
    globalKeyInt: ?i64 = null,
    gap: f32 = 0,
    padding: ?f32 = null,
    grow: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    minWidth: f32 = 0,
    resizeDuration: u32 = 0,
    resizeEasing: sdk.canvas.Easing = .standard,
    resizeOrigin: f32 = -1,
    value: f32 = 0,
    valueX: ?f32 = null,
    axis: ?sdk.canvas.ScrollAxes = null,
    overscroll: ?sdk.canvas.WidgetOverscroll = null,
    image: u64 = 0,
    icon: []const u8 = "",
    label: []const u8 = "",
    role: @FieldType(sdk.canvas.WidgetSemantics, "role") = .none,
    background: @FieldType(sdk.canvas.StyleTokenRefs, "background") = null,
    foreground: @FieldType(sdk.canvas.StyleTokenRefs, "foreground") = null,
    radius: @FieldType(sdk.canvas.StyleTokenRefs, "radius") = null,
    windowDrag: bool = false,
    main: @FieldType(Ui.ElementOptions, "main") = .start,
    cross: @FieldType(Ui.ElementOptions, "cross") = .stretch,
    size: @FieldType(Ui.ElementOptions, "size") = .default,
    variant: @FieldType(Ui.ElementOptions, "variant") = .default,
    checked: bool = false,
    disabled: bool = false,
    selected: bool = false,
    focusable: bool = false,
    expanded: ?bool = null,
    treeLevel: u16 = 0,
    listItemIndex: ?u32 = null,
    listItemCount: ?u32 = null,
    spanWeight: ?sdk.canvas.TextSpanWeight = null,
    spanColor: ?sdk.canvas.TextSpanColor = null,
    spanScale: ?f32 = null,
    codeLanguage: ?sdk.canvas.code.Language = null,
    codeLineDigits: ?u8 = null,
    codeAddedLines: ?[]const u8 = null,
    codeRemovedLines: ?[]const u8 = null,
    press: ?[]const u8 = null,
    hold: ?[]const u8 = null,
    toggle: ?[]const u8 = null,
    change: ?[]const u8 = null,
    drag: ?[]const u8 = null,
    scroll: ?u8 = null,
    input: ?u8 = null,
    valueChange: ?u8 = null,
    resize: ?u8 = null,
    submit: ?[]const u8 = null,
    dismiss: ?[]const u8 = null,
    anchor: ?sdk.canvas.WidgetAnchorPlacement = null,
    anchorAlignment: sdk.canvas.WidgetAnchorAlignment = .start,
    anchorOffset: f32 = 4,
};
const Tree = struct { format: u32, nodes: []const Record };

pub fn build(ui: *Ui, model: *const core.Model) Ui.Node {
    _ = model;
    return decode(ui, core.nativeView(ui.arena)) catch @panic("invalid compiled TypeScript view data");
}

pub fn buildWindow(ui: *Ui, model: *const core.Model, label: []const u8) Ui.Node {
    _ = model;
    return decode(ui, core.nativeWindowView(label, ui.arena)) catch @panic("invalid compiled TypeScript window view data");
}

fn decode(ui: *Ui, bytes: []const u8) !Ui.Node {
    if (bytes.len > 1024 * 1024) return error.ViewTooLarge;
    const tree = try std.json.parseFromSliceLeaky(Tree, ui.arena, bytes, .{ .allocate = .alloc_always });
    if (tree.format != 2 or tree.nodes.len == 0 or tree.nodes.len > 1024) return error.InvalidView;
    if (tree.nodes[0].end != tree.nodes.len) return error.InvalidView;
    return node(ui, tree.nodes, 0, tree.nodes.len, 0);
}

fn node(ui: *Ui, records: []const Record, index: usize, parent_end: usize, depth: usize) !Ui.Node {
    if (depth > 64) return error.ViewTooDeep;
    const value = records[index];
    if (value.end <= index or value.end > parent_end) return error.InvalidView;
    if (!std.math.isFinite(value.gap) or value.gap < 0 or !std.math.isFinite(value.grow) or value.grow < 0) return error.InvalidView;
    if (value.padding) |padding| if (!std.math.isFinite(padding) or padding < 0) return error.InvalidView;
    for ([_]f32{ value.width, value.height, value.minWidth }) |extent| if (!std.math.isFinite(extent) or extent < 0) return error.InvalidView;
    if (value.kind == .resizable and value.gap != 0) return error.InvalidView;
    if (value.resize != null and value.kind != .split) return error.InvalidView;
    if (!std.math.isFinite(value.resizeOrigin) or (value.resizeOrigin != -1 and (value.resizeOrigin < 0 or value.resizeOrigin > 1))) return error.InvalidView;
    if ((value.resizeDuration != 0 or value.resizeEasing != .standard or value.resizeOrigin != -1) and value.kind != .split) return error.InvalidView;
    if ((value.resizeEasing != .standard or value.resizeOrigin != -1) and value.resizeDuration == 0) return error.InvalidView;
    if (!std.math.isFinite(value.value)) return error.InvalidView;
    if ((value.valueX != null or value.axis != null or value.overscroll != null) and value.kind != .scroll) return error.InvalidView;
    if (value.valueX) |offset| if (!std.math.isFinite(offset)) return error.InvalidView;
    if (value.key != null and value.keyInt != null or value.globalKey != null and value.globalKeyInt != null) return error.InvalidView;
    if (value.keySlot > 1024 or value.keySlot != 0 and value.key == null and value.keyInt == null) return error.InvalidView;
    if (value.image > 9007199254740991) return error.InvalidView;
    for ([_]?i64{ value.keyInt, value.globalKeyInt }) |int| if (int) |key| if (key < -9007199254740991 or key > 9007199254740991) return error.InvalidView;
    const container = value.kind == .column or value.kind == .row or value.kind == .stack or value.kind == .scroll or value.kind == .panel or value.kind == .radio_group or value.kind == .toggle_group or value.kind == .accordion or value.kind == .tabs or value.kind == .tree or value.kind == .list or value.kind == .list_item or value.kind == .dropdown_menu or value.kind == .split or value.kind == .resizable;
    const tree_row = (value.kind == .column or value.kind == .row or value.kind == .panel) and value.role == .treeitem;
    if (value.role == .treeitem and !tree_row) return error.InvalidView;
    if (value.role == .tree and value.kind != .column and value.kind != .row and value.kind != .panel and value.kind != .scroll and value.kind != .tree) return error.InvalidView;
    if (!container and value.end != index + 1) return error.InvalidView;
    if (value.kind == .list_item and value.end != index + 1 and value.text.len != 0) return error.InvalidView;
    if (value.press != null and !tree_row and value.kind != .button and value.kind != .stack and value.kind != .radio and value.kind != .segmented_control and value.kind != .list_item and value.kind != .select and value.kind != .menu_item) return error.InvalidView;
    if (value.dismiss != null and value.kind != .dropdown_menu) return error.InvalidView;
    if (!std.math.isFinite(value.anchorOffset)) return error.InvalidView;
    if ((value.anchor != null or value.anchorAlignment != .start or value.anchorOffset != 4) and value.kind != .dropdown_menu) return error.InvalidView;
    if (value.anchor == null and (value.anchorAlignment != .start or value.anchorOffset != 4)) return error.InvalidView;
    if (value.toggle != null and !tree_row and value.kind != .checkbox and value.kind != .switch_control and value.kind != .toggle and value.kind != .radio and value.kind != .toggle_button and value.kind != .accordion) return error.InvalidView;
    if ((value.expanded != null or value.treeLevel != 0) and value.role != .treeitem) return error.InvalidView;
    if (value.change != null and value.kind != .radio and value.kind != .slider) return error.InvalidView;
    if (value.valueChange != null and (value.kind != .slider or value.change != null)) return error.InvalidView;
    if (value.scroll != null and value.kind != .scroll) return error.InvalidView;
    const text_entry = value.kind == .input or value.kind == .search_field or value.kind == .textarea;
    if (value.submitOnEnter and value.kind != .textarea) return error.InvalidView;
    if ((value.input != null or value.submit != null) and !text_entry) return error.InvalidView;
    if (value.placeholder.len != 0 and !text_entry and value.kind != .select) return error.InvalidView;
    if (value.wrap != null and value.kind != .text) return error.InvalidView;
    const paragraph = value.spanWeight != null or value.spanColor != null or value.spanScale != null;
    if (paragraph and value.kind != .text) return error.InvalidView;
    if (value.spanScale) |scale| if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidView;
    if (value.codeLanguage != null or value.codeLineDigits != null) {
        if (value.codeLanguage == null or value.codeLineDigits == null or value.kind != .textarea or
            value.codeLineDigits.? > 5 or value.placeholder.len != 0 or value.submitOnEnter or paragraph)
            return error.InvalidView;
    }
    var code_diff: ?sdk.canvas.CodeDiffLines = null;
    if (value.codeAddedLines != null or value.codeRemovedLines != null) {
        if (value.codeLanguage == null or value.codeAddedLines == null or value.codeRemovedLines == null) return error.InvalidView;
        const added = try codeLineMask(value.codeAddedLines.?);
        const removed = try codeLineMask(value.codeRemovedLines.?);
        if (added & removed != 0) return error.InvalidView;
        if (added != 0 or removed != 0) code_diff = .{ .added = added, .removed = removed };
    }
    if (value.listItemIndex) |item| if (value.listItemCount == null or item >= value.listItemCount.?) return error.InvalidView;
    var children: std.ArrayList(Ui.Node) = .empty;
    var child_index = index + 1;
    while (child_index < value.end) {
        try children.append(ui.arena, try node(ui, records, child_index, value.end, depth + 1));
        child_index = records[child_index].end;
    }
    if (value.kind == .split and children.items.len != 2) return error.InvalidView;
    const kind: sdk.canvas.WidgetKind = switch (value.kind) {
        .spacer => .stack,
        .scroll => .scroll_view,
        inline else => |tag| @field(sdk.canvas.WidgetKind, @tagName(tag)),
    };
    var result = ui.el(kind, .{
        .key = if (value.key) |key| try sdk.canvas.forSlotKey(ui.arena, .{ .str = key }, value.keySlot) else if (value.keyInt) |key| try sdk.canvas.forSlotKey(ui.arena, .{ .int = @bitCast(key) }, value.keySlot) else null,
        .global_key = if (value.globalKey) |key| .{ .str = key } else if (value.globalKeyInt) |key| .{ .int = @bitCast(key) } else null,
        .text = value.text,
        .placeholder = value.placeholder,
        .wrap = value.wrap,
        .submit_on_enter = value.submitOnEnter,
        .gap = value.gap,
        .padding = value.padding,
        .grow = value.grow,
        .width = value.width,
        .height = value.height,
        .min_width = value.minWidth,
        .resize_duration = value.resizeDuration,
        .resize_easing = value.resizeEasing,
        .resize_origin = value.resizeOrigin,
        .value = value.value,
        .value_x = value.valueX orelse 0,
        .axis = value.axis orelse .vertical,
        .overscroll = value.overscroll orelse .default,
        .image = value.image,
        .icon = value.icon,
        .window_drag = value.windowDrag,
        .semantics = .{ .role = value.role, .label = value.label, .focusable = value.focusable, .list_item_index = value.listItemIndex, .list_item_count = value.listItemCount },
        .style_tokens = .{ .background = value.background, .foreground = value.foreground, .radius = value.radius },
        .main = value.main,
        .cross = value.cross,
        .size = value.size,
        .variant = value.variant,
        .checked = value.checked,
        .disabled = value.disabled,
        .selected = value.selected,
        .expanded = value.expanded,
        .tree_level = value.treeLevel,
        .on_press = if (value.press) |bytes| try event(ui, bytes) else null,
        .on_hold = if (value.hold) |bytes| try event(ui, bytes) else null,
        .on_change = if (value.change) |bytes| try event(ui, bytes) else null,
        .on_toggle = if (value.toggle) |bytes| try event(ui, bytes) else null,
        .on_drag = if (value.drag) |bytes| try dragEvent(ui, bytes) else null,
        .on_scroll = if (value.scroll) |tag| try scrollEvent(tag) else null,
        .on_input = if (value.input) |tag| try inputEvent(tag) else null,
        .on_value = if (value.valueChange) |tag| try valueEvent(tag) else null,
        .on_resize = if (value.resize) |tag| try valueEvent(tag) else null,
        .on_submit = if (value.submit) |bytes| try event(ui, bytes) else null,
        .on_dismiss = if (value.dismiss) |bytes| try event(ui, bytes) else null,
        .anchor = value.anchor,
        .anchor_alignment = value.anchorAlignment,
        .anchor_offset = value.anchorOffset,
    }, children.items);
    if (comptime @hasDecl(core, "nativeTextPolicy")) {
        // Every primitive can carry composed semantics. Specialized callbacks
        // below also accept shared keyboard, semantic-control and action tags.
        result.widget.interaction_policy = core.nativeTextPolicy;
    }
    if (comptime @hasDecl(core, "nativeRadioPolicy")) {
        if (value.kind == .radio or value.kind == .radio_group) result.widget.interaction_policy = core.nativeRadioPolicy;
    }
    if (comptime @hasDecl(core, "nativeTabsPolicy")) {
        if (value.kind == .tabs or value.kind == .segmented_control) result.widget.interaction_policy = core.nativeTabsPolicy;
    }
    if (comptime @hasDecl(core, "nativeTreePolicy")) {
        if (value.kind == .tree or value.role == .tree or value.role == .treeitem) result.widget.interaction_policy = core.nativeTreePolicy;
    }
    if (comptime @hasDecl(core, "nativeListPolicy")) {
        if (value.kind == .list or value.kind == .list_item) result.widget.interaction_policy = core.nativeListPolicy;
    }
    if (comptime @hasDecl(core, "nativeMenuPolicy")) {
        if (value.kind == .dropdown_menu or value.kind == .menu_item) result.widget.interaction_policy = core.nativeMenuPolicy;
    }
    if (comptime @hasDecl(core, "nativeTogglePolicy")) {
        if (value.kind == .toggle_group or value.kind == .toggle_button or value.kind == .checkbox or value.kind == .switch_control or value.kind == .toggle) result.widget.interaction_policy = core.nativeTogglePolicy;
    }
    if (comptime @hasDecl(core, "nativeAccordionPolicy")) {
        if (value.kind == .accordion) result.widget.interaction_policy = core.nativeAccordionPolicy;
    }
    if (comptime @hasDecl(core, "nativeSliderPolicy")) {
        if (value.kind == .slider) result.widget.interaction_policy = core.nativeSliderPolicy;
    }
    if (comptime @hasDecl(core, "nativeSplitPolicy")) {
        if (value.kind == .split) result.widget.interaction_policy = core.nativeSplitPolicy;
    }
    if (comptime @hasDecl(core, "nativeResizablePolicy")) {
        if (value.kind == .resizable) result.widget.interaction_policy = core.nativeResizablePolicy;
    }
    if (comptime @hasDecl(core, "nativeScrollPolicy")) {
        if (value.kind == .scroll) {
            result.widget.runtime_flags.compiled_scroll_policy = true;
            result.widget.interaction_policy = if (value.role == .tree) scrollTreePolicy else core.nativeScrollPolicy;
        }
    }
    if (paragraph) {
        const spans = try ui.arena.alloc(sdk.canvas.TextSpan, 1);
        spans[0] = .{ .text = result.widget.text, .weight = value.spanWeight orelse .regular, .color = value.spanColor, .scale = value.spanScale orelse 0 };
        result.widget.spans = spans;
    }
    if (value.codeLanguage) |language| {
        const spans = try ui.arena.alloc(sdk.canvas.TextSpan, 1);
        spans[0] = .{ .text = result.widget.text, .monospace = true, .color = .syntax_plain };
        result.widget.spans = spans;
        result.widget.runtime_flags.code_editor = true;
        result.widget.code_language = language;
        result.widget.code_line_number_digits = value.codeLineDigits.?;
        if (code_diff) |lines| result.widget.setCodeDiffLines(lines);
        result.widget.text_no_wrap = true;
        result.widget.layout.clip_content = true;
    }
    return result;
}

/// Pack already parsed, unique line ordinals into the renderer's exact masks.
/// The compiled component owns text parsing; this checks untrusted tree data.
fn codeLineMask(lines: []const u8) !u128 {
    if (lines.len > sdk.canvas.code.max_diff_lines) return error.InvalidView;
    var mask: u128 = 0;
    for (lines) |line| {
        if (line == 0 or line > sdk.canvas.code.max_diff_lines) return error.InvalidView;
        const bit = @as(u128, 1) << @as(u7, @intCast(line - 1));
        if (mask & bit != 0) return error.InvalidView;
        mask |= bit;
    }
    return mask;
}

/// A scroll container can also own logical tree navigation. The explicit
/// scroll tag preserves both policies in one callback without tree scans.
fn scrollTreePolicy(request: []const u8, output: []u8) usize {
    if (comptime @hasDecl(core, "nativeScrollPolicy") and @hasDecl(core, "nativeTreePolicy")) {
        if (request.len > 0 and request[0] >= 128) return core.nativeScrollPolicy(request, output);
        return core.nativeTreePolicy(request, output);
    } else unreachable;
}

fn event(ui: *Ui, bytes: []const u8) !core.Msg {
    if (bytes.len < 2 or bytes[0] != 1 or bytes[1] >= @typeInfo(core.Msg).@"union".fields.len) return error.InvalidView;
    return core.nativeViewEvent(bytes, ui.arena) orelse error.InvalidView;
}

fn dragEvent(ui: *Ui, bytes: []const u8) !core.Msg {
    const msg = try event(ui, bytes);
    switch (msg) {
        inline else => |payload| {
            if (comptime !sdk.canvas.ui_markup_reflect.declaredWidgetDragDropRecord(@TypeOf(payload))) return error.InvalidView;
        },
    }
    return msg;
}

fn scrollEvent(tag: u8) !Ui.ScrollMsgFn {
    inline for (@typeInfo(core.Msg).@"union".fields, 0..) |field, index| {
        if (comptime sdk.canvas.ui_markup_reflect.declaredScrollStateRecord(field.type)) {
            if (tag == index) return Ui.translatedScrollMsg(@field(std.meta.Tag(core.Msg), field.name), field.type);
        }
    }
    return error.InvalidView;
}

fn inputEvent(tag: u8) !Ui.InputMsgFn {
    inline for (@typeInfo(core.Msg).@"union".fields, 0..) |field, index| {
        if (comptime sdk.canvas.ui_markup_reflect.declaredTextInputUnion(field.type)) {
            if (tag == index) return Ui.translatedInputMsg(@field(std.meta.Tag(core.Msg), field.name), field.type);
        }
    }
    return error.InvalidView;
}

fn valueEvent(tag: u8) !Ui.ValueMsgFn {
    inline for (@typeInfo(core.Msg).@"union".fields, 0..) |field, index| {
        if (comptime @typeInfo(field.type) == .float) {
            if (tag == index) return Ui.translatedValueMsg(@field(std.meta.Tag(core.Msg), field.name), field.type);
        }
    }
    return error.InvalidView;
}

test "compiled scrolls reject misplaced properties and incompatible channels" {
    if (comptime enabled) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = Ui.init(arena.allocator());
        for ([_][]const u8{
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"column\",\"text\":\"\",\"axis\":\"both\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"column\",\"text\":\"\",\"valueX\":2}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"column\",\"text\":\"\",\"overscroll\":\"none\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"scroll\",\"text\":\"\",\"scroll\":255}]}",
        }) |source| try std.testing.expectError(error.InvalidView, decode(&ui, source));
        if (comptime @hasDecl(core, "nativeScrollPolicy") and @hasDecl(core, "nativeTreePolicy")) {
            const source = "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"scroll\",\"text\":\"\",\"role\":\"tree\"}]}";
            const result = try decode(&ui, source);
            try std.testing.expect(result.widget.runtime_flags.compiled_scroll_policy);
            const offset = sdk.canvas.widgetCompiledScrollResult(result.widget, .{ .operation = 1, .current = 20.5, .viewport = 100, .content = 400, .delta = 30.25 }).?;
            try std.testing.expectEqual(@as(f32, 50.75), offset.dx);
            const tree_request = [_]u8{ 0, 0, 0, 1, 0, 255, 255, 2, 0, 0, 0 };
            var expected: [2]u8 = undefined;
            var actual: [2]u8 = undefined;
            try std.testing.expectEqual(core.nativeTreePolicy(&tree_request, &expected), result.widget.interaction_policy.?(&tree_request, &actual));
            try std.testing.expectEqualSlices(u8, &expected, &actual);
        }
    } else return error.SkipZigTest;
}

test "compiled sliders reject incompatible value channels" {
    if (comptime enabled) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = Ui.init(arena.allocator());
        for ([_][]const u8{
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"button\",\"text\":\"\",\"valueChange\":0}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"slider\",\"text\":\"\",\"valueChange\":255}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"slider\",\"text\":\"\",\"valueChange\":0,\"change\":[1,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":2,\"kind\":\"slider\",\"text\":\"\"},{\"end\":2,\"kind\":\"text\",\"text\":\"child\"}]}",
        }) |source| try std.testing.expectError(error.InvalidView, decode(&ui, source));
        inline for (@typeInfo(core.Msg).@"union".fields, 0..) |field, tag| {
            if (comptime @typeInfo(field.type) != .float) try std.testing.expectError(error.InvalidView, valueEvent(tag));
        }
    } else return error.SkipZigTest;
}

test "compiled splits reject malformed panes and resize channels" {
    if (comptime enabled) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = Ui.init(arena.allocator());
        for ([_][]const u8{
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"button\",\"text\":\"\",\"resize\":0}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"split\",\"text\":\"\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":2,\"kind\":\"split\",\"text\":\"\"},{\"end\":2,\"kind\":\"column\",\"text\":\"\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":3,\"kind\":\"split\",\"text\":\"\",\"resize\":255},{\"end\":2,\"kind\":\"column\",\"text\":\"\"},{\"end\":3,\"kind\":\"column\",\"text\":\"\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"column\",\"text\":\"\",\"minWidth\":-1}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"column\",\"text\":\"\",\"resizeDuration\":180}]}",
        }) |source| try std.testing.expectError(error.InvalidView, decode(&ui, source));
    } else return error.SkipZigTest;
}

test "compiled view strings belong to the native tree arena" {
    if (comptime enabled) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = Ui.init(arena.allocator());
        const source = "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"text\",\"text\":\"café\",\"key\":\"label\"}]}";
        const bytes = try std.testing.allocator.dupe(u8, source);
        defer std.testing.allocator.free(bytes);
        const result = try decode(&ui, bytes);
        @memset(bytes, 0);
        try std.testing.expectEqualStrings("café", result.widget.text);
        try std.testing.expectEqualStrings("label", result.key.?.str);
    } else return error.SkipZigTest;
}

test "compiled paragraph spans share owned text and validate primitive fields" {
    if (comptime enabled) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = Ui.init(arena.allocator());
        const source = "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"text\",\"text\":\"café\",\"spanWeight\":\"bold\",\"spanColor\":\"text_muted\",\"spanScale\":0.9}]}";
        const bytes = try std.testing.allocator.dupe(u8, source);
        defer std.testing.allocator.free(bytes);
        const result = try decode(&ui, bytes);
        @memset(bytes, 0);
        try std.testing.expectEqualStrings("café", result.widget.spans[0].text);
        try std.testing.expect(result.widget.spans[0].text.ptr == result.widget.text.ptr);
        try std.testing.expectEqual(.bold, result.widget.spans[0].weight);
        try std.testing.expectEqual(.text_muted, result.widget.spans[0].color.?);
        try std.testing.expectError(error.InvalidView, decode(&ui, "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"badge\",\"text\":\"\",\"spanWeight\":\"bold\"}]}"));
        try std.testing.expectError(error.InvalidView, decode(&ui, "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"text\",\"text\":\"\",\"spanScale\":-1}]}"));
        try std.testing.expectError(error.InvalidView, decode(&ui, "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"row\",\"text\":\"\",\"listItemIndex\":1,\"listItemCount\":1}]}"));
    } else return error.SkipZigTest;
}

test "compiled view negative integer slot keys match native iteration identities" {
    if (comptime enabled) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = Ui.init(arena.allocator());
        const result = try decode(&ui, "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"text\",\"text\":\"\",\"keyInt\":-7,\"keySlot\":1}]}");
        const expected = try sdk.canvas.forSlotKey(ui.arena, .{ .int = @bitCast(@as(i64, -7)) }, 1);
        try std.testing.expectEqualStrings(expected.str, result.key.?.str);
    } else return error.SkipZigTest;
}

test "compiled view message bytes belong to the native tree arena" {
    if (comptime enabled) {
        inline for (@typeInfo(core.Msg).@"union".fields, 0..) |field, tag| {
            if (comptime field.type == []const u8) {
                var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer arena.deinit();
                var ui = Ui.init(arena.allocator());
                var envelope = [_]u8{ 1, tag, 5, 0, 0, 0, 'c', 'a', 'f', 0xc3, 0xa9 };
                const msg = try event(&ui, &envelope);
                @memset(&envelope, 0);
                try std.testing.expectEqualStrings("café", @field(msg, field.name));
                return;
            }
        }
    }
    return error.SkipZigTest;
}

test "compiled view refuses bad versions, spans, kinds and geometry" {
    if (comptime enabled) {
        const cases = [_][]const u8{
            "{\"format\":1,\"nodes\":[]}",
            "{\"format\":2,\"nodes\":[]}",
            "{\"format\":2,\"nodes\":[{\"end\":0,\"kind\":\"text\",\"text\":\"\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":2,\"kind\":\"column\",\"text\":\"\"},{\"end\":3,\"kind\":\"text\",\"text\":\"\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":2,\"kind\":\"text\",\"text\":\"\"},{\"end\":2,\"kind\":\"text\",\"text\":\"\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"unknown\",\"text\":\"\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"text\",\"text\":\"\",\"gap\":-1}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"text\",\"text\":\"\",\"grow\":1e300}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"text\",\"text\":\"\",\"press\":[1,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"text\",\"text\":\"\",\"input\":0}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"input\",\"text\":\"\",\"input\":255}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"input\",\"text\":\"\",\"submit\":[0,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"panel\",\"text\":\"\",\"wrap\":true}]}",
            "{\"format\":2,\"nodes\":[{\"end\":2,\"kind\":\"list_item\",\"text\":\"Mixed\"},{\"end\":2,\"kind\":\"text\",\"text\":\"child\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"list_item\",\"text\":\"\",\"role\":\"treeitem\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"list\",\"text\":\"\",\"role\":\"tree\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"list_item\",\"text\":\"\",\"toggle\":[1,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"toggle_group\",\"text\":\"\",\"toggle\":[1,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"toggle_button\",\"text\":\"\",\"change\":[1,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":2,\"kind\":\"toggle_button\",\"text\":\"Mixed\"},{\"end\":2,\"kind\":\"text\",\"text\":\"child\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"checkbox\",\"text\":\"Setting\",\"press\":[1,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"checkbox\",\"text\":\"Setting\",\"change\":[1,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"switch_control\",\"text\":\"Setting\",\"press\":[1,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"switch_control\",\"text\":\"Setting\",\"change\":[1,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"toggle\",\"text\":\"Setting\",\"press\":[1,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"toggle\",\"text\":\"Setting\",\"change\":[1,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"accordion\",\"text\":\"Section\",\"press\":[1,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"accordion\",\"text\":\"Section\",\"change\":[1,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"accordion\",\"text\":\"Section\",\"placeholder\":\"Help\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"button\",\"text\":\"\",\"dismiss\":[1,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"panel\",\"text\":\"\",\"anchor\":\"below\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"dropdown_menu\",\"text\":\"\",\"anchorAlignment\":\"stretch\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"dropdown_menu\",\"text\":\"\",\"anchorOffset\":1e300}]}",
            "{\"format\":2,\"nodes\":[{\"end\":2,\"kind\":\"menu_item\",\"text\":\"Mixed\"},{\"end\":2,\"kind\":\"text\",\"text\":\"child\"}]}",
        };
        for (cases) |source| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var ui = Ui.init(arena.allocator());
            if (decode(&ui, source)) |_| return error.TestExpectedError else |_| {}
        }
    } else return error.SkipZigTest;
}

test "compiled resizable panels preserve initial minimum sizing and reject flow gap" {
    if (comptime enabled) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = Ui.init(arena.allocator());
        const source = "{\"format\":2,\"nodes\":[{\"end\":2,\"kind\":\"resizable\",\"text\":\"\",\"width\":260,\"height\":112,\"minWidth\":100},{\"end\":2,\"kind\":\"text\",\"text\":\"Research\"}]}";
        const result = try decode(&ui, source);
        try std.testing.expectEqual(sdk.canvas.WidgetKind.resizable, result.widget.kind);
        try std.testing.expectEqual(@as(f32, 260), result.widget.layout.min_size.width);
        try std.testing.expectEqual(@as(f32, 0), result.widget.layout.max_size.width);
        try std.testing.expect(result.widget.interaction_policy != null);
        for ([_][]const u8{
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"resizable\",\"text\":\"\",\"gap\":8}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"resizable\",\"text\":\"\",\"resize\":0}]}",
        }) |invalid| try std.testing.expectError(error.InvalidView, decode(&ui, invalid));
    } else return error.SkipZigTest;
}

test "compiled textareas preserve multiline Enter policy and text keyboard callback" {
    if (comptime enabled) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = Ui.init(arena.allocator());
        const result = try decode(&ui, "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"textarea\",\"text\":\"Café\\nnotes\",\"placeholder\":\"Write\",\"width\":420,\"height\":180,\"submitOnEnter\":true}]}");
        try std.testing.expectEqual(sdk.canvas.WidgetKind.textarea, result.widget.kind);
        try std.testing.expectEqualStrings("Café\nnotes", result.widget.text);
        try std.testing.expect(result.widget.submit_on_enter);
        try std.testing.expect(result.widget.interaction_policy != null);
        for ([_][]const u8{
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"input\",\"text\":\"\",\"submitOnEnter\":true}]}",
            "{\"format\":2,\"nodes\":[{\"end\":2,\"kind\":\"textarea\",\"text\":\"\"},{\"end\":2,\"kind\":\"text\",\"text\":\"child\"}]}",
        }) |invalid| try std.testing.expectError(error.InvalidView, decode(&ui, invalid));
    }
}

test "compiled code records preserve owned monospace source and reject misplaced metadata" {
    if (comptime enabled) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = Ui.init(arena.allocator());
        const result = try decode(&ui, "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"textarea\",\"text\":\"const café = 1;\\n\",\"codeLanguage\":\"typescript\",\"codeLineDigits\":1}]}");
        try std.testing.expect(result.widget.runtime_flags.code_editor);
        try std.testing.expect(result.widget.text_no_wrap and result.widget.layout.clip_content);
        try std.testing.expectEqual(sdk.canvas.code.Language.typescript, result.widget.code_language);
        try std.testing.expectEqual(@as(u8, 1), result.widget.code_line_number_digits);
        try std.testing.expect(result.widget.spans[0].monospace);
        try std.testing.expect(result.widget.spans[0].text.ptr == result.widget.text.ptr);
        try std.testing.expectEqualStrings("const café = 1;\n", result.widget.text);
        for ([_][]const u8{
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"text\",\"text\":\"\",\"codeLanguage\":\"plain\",\"codeLineDigits\":0}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"textarea\",\"text\":\"\",\"codeLanguage\":\"plain\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"textarea\",\"text\":\"\",\"codeLineDigits\":1}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"textarea\",\"text\":\"\",\"codeLanguage\":\"plain\",\"codeLineDigits\":6}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"textarea\",\"text\":\"\",\"codeLanguage\":\"plain\",\"codeLineDigits\":1,\"submitOnEnter\":true}]}",
        }) |invalid| try std.testing.expectError(error.InvalidView, decode(&ui, invalid));
    }
}

test "compiled code diff ordinals preserve every mask word and reject invalid tree metadata" {
    if (comptime enabled) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = Ui.init(arena.allocator());
        const bytes = try std.testing.allocator.dupe(u8, "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"textarea\",\"text\":\"café\\n日本\\n\",\"codeLanguage\":\"typescript\",\"codeLineDigits\":1,\"codeAddedLines\":[1,32,33,64,65,96,97,128],\"codeRemovedLines\":[2,31,34,63,66,95,98,127]}]}");
        defer std.testing.allocator.free(bytes);
        const result = try decode(&ui, bytes);
        @memset(bytes, 'x');
        var added: u128 = 0;
        var removed: u128 = 0;
        for ([_]u7{ 0, 31, 32, 63, 64, 95, 96, 127 }) |bit| added |= @as(u128, 1) << bit;
        for ([_]u7{ 1, 30, 33, 62, 65, 94, 97, 126 }) |bit| removed |= @as(u128, 1) << bit;
        try std.testing.expectEqualDeep(sdk.canvas.CodeDiffLines{ .added = added, .removed = removed }, result.widget.codeDiffLines().?);
        try std.testing.expectEqual(@as(u8, 1), result.widget.codeLineNumberDigits());
        try std.testing.expectEqualStrings("café\n日本\n", result.widget.text);
        const next = try decode(&ui, "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"textarea\",\"text\":\"other\",\"codeLanguage\":\"python\",\"codeLineDigits\":0,\"codeAddedLines\":[],\"codeRemovedLines\":[]}]}");
        try std.testing.expect(next.widget.codeDiffLines() == null);
        try std.testing.expectEqualDeep(sdk.canvas.CodeDiffLines{ .added = added, .removed = removed }, result.widget.codeDiffLines().?);
        for ([_][]const u8{
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"textarea\",\"text\":\"\",\"codeAddedLines\":[1],\"codeRemovedLines\":[]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"textarea\",\"text\":\"\",\"codeLanguage\":\"plain\",\"codeLineDigits\":0,\"codeAddedLines\":[1]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"textarea\",\"text\":\"\",\"codeLanguage\":\"plain\",\"codeLineDigits\":0,\"codeAddedLines\":[0],\"codeRemovedLines\":[]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"textarea\",\"text\":\"\",\"codeLanguage\":\"plain\",\"codeLineDigits\":0,\"codeAddedLines\":[129],\"codeRemovedLines\":[]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"textarea\",\"text\":\"\",\"codeLanguage\":\"plain\",\"codeLineDigits\":0,\"codeAddedLines\":[1,1],\"codeRemovedLines\":[]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"textarea\",\"text\":\"\",\"codeLanguage\":\"plain\",\"codeLineDigits\":0,\"codeAddedLines\":[128],\"codeRemovedLines\":[128]}]}",
        }) |invalid| try std.testing.expectError(error.InvalidView, decode(&ui, invalid));
        try std.testing.expectError(error.InvalidView, codeLineMask(&([_]u8{1} ** 129)));
    }
}
