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
    kind: enum { column, row, stack, separator, panel, badge, input, search_field, text, button, switch_control, status_bar, spacer, scroll, avatar, radio, radio_group, tabs, segmented_control, tree, list, list_item, select, dropdown_menu, menu_item },
    text: []const u8,
    placeholder: []const u8 = "",
    wrap: ?bool = null,
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
    value: f32 = 0,
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
    press: ?[]const u8 = null,
    toggle: ?[]const u8 = null,
    change: ?[]const u8 = null,
    drag: ?[]const u8 = null,
    scroll: ?u8 = null,
    input: ?u8 = null,
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
    for ([_]f32{ value.width, value.height }) |extent| if (!std.math.isFinite(extent) or extent < 0) return error.InvalidView;
    if (!std.math.isFinite(value.value)) return error.InvalidView;
    if (value.key != null and value.keyInt != null or value.globalKey != null and value.globalKeyInt != null) return error.InvalidView;
    if (value.keySlot > 1024 or value.keySlot != 0 and value.key == null and value.keyInt == null) return error.InvalidView;
    if (value.image > 9007199254740991) return error.InvalidView;
    for ([_]?i64{ value.keyInt, value.globalKeyInt }) |int| if (int) |key| if (key < -9007199254740991 or key > 9007199254740991) return error.InvalidView;
    const container = value.kind == .column or value.kind == .row or value.kind == .stack or value.kind == .scroll or value.kind == .panel or value.kind == .radio_group or value.kind == .tabs or value.kind == .tree or value.kind == .list or value.kind == .list_item or value.kind == .dropdown_menu;
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
    if (value.toggle != null and !tree_row and value.kind != .switch_control and value.kind != .radio) return error.InvalidView;
    if ((value.expanded != null or value.treeLevel != 0) and value.role != .treeitem) return error.InvalidView;
    if (value.change != null and value.kind != .radio) return error.InvalidView;
    if (value.scroll != null and value.kind != .scroll) return error.InvalidView;
    const text_entry = value.kind == .input or value.kind == .search_field;
    if ((value.input != null or value.submit != null) and !text_entry) return error.InvalidView;
    if (value.placeholder.len != 0 and !text_entry and value.kind != .select) return error.InvalidView;
    if (value.wrap != null and value.kind != .text) return error.InvalidView;
    const paragraph = value.spanWeight != null or value.spanColor != null or value.spanScale != null;
    if (paragraph and value.kind != .text) return error.InvalidView;
    if (value.spanScale) |scale| if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidView;
    if (value.listItemIndex) |item| if (value.listItemCount == null or item >= value.listItemCount.?) return error.InvalidView;
    var children: std.ArrayList(Ui.Node) = .empty;
    var child_index = index + 1;
    while (child_index < value.end) {
        try children.append(ui.arena, try node(ui, records, child_index, value.end, depth + 1));
        child_index = records[child_index].end;
    }
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
        .gap = value.gap,
        .padding = value.padding,
        .grow = value.grow,
        .width = value.width,
        .height = value.height,
        .value = value.value,
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
        .on_change = if (value.change) |bytes| try event(ui, bytes) else null,
        .on_toggle = if (value.toggle) |bytes| try event(ui, bytes) else null,
        .on_drag = if (value.drag) |bytes| try dragEvent(ui, bytes) else null,
        .on_scroll = if (value.scroll) |tag| try scrollEvent(tag) else null,
        .on_input = if (value.input) |tag| try inputEvent(tag) else null,
        .on_submit = if (value.submit) |bytes| try event(ui, bytes) else null,
        .on_dismiss = if (value.dismiss) |bytes| try event(ui, bytes) else null,
        .anchor = value.anchor,
        .anchor_alignment = value.anchorAlignment,
        .anchor_offset = value.anchorOffset,
    }, children.items);
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
    if (paragraph) {
        const spans = try ui.arena.alloc(sdk.canvas.TextSpan, 1);
        spans[0] = .{ .text = result.widget.text, .weight = value.spanWeight orelse .regular, .color = value.spanColor, .scale = value.spanScale orelse 0 };
        result.widget.spans = spans;
    }
    return result;
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
