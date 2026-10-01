//! Native consumer of the optional compiled TypeScript view. This module
//! never evaluates bindings or reads the model. Tree data is copied before
//! scriptc's result arena resets; strings and nodes then live for this native
//! tree generation. Event tags become the ordinary typed, journaled Msgs.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("core.zig");
pub const enabled = @hasDecl(core, "nativeView");
const Ui = sdk.canvas.Ui(core.Msg);

const Record = struct {
    end: usize,
    kind: enum { column, row, text, button, switch_control, status_bar },
    text: []const u8,
    key: ?[]const u8 = null,
    gap: f32 = 0,
    padding: ?f32 = null,
    grow: f32 = 0,
    main: @FieldType(Ui.ElementOptions, "main") = .start,
    cross: @FieldType(Ui.ElementOptions, "cross") = .stretch,
    size: @FieldType(Ui.ElementOptions, "size") = .default,
    variant: @FieldType(Ui.ElementOptions, "variant") = .default,
    checked: bool = false,
    disabled: bool = false,
    press: ?u8 = null,
    toggle: ?u8 = null,
};
const Tree = struct { format: u32, nodes: []const Record };

pub fn build(ui: *Ui, model: *const core.Model) Ui.Node {
    _ = model;
    return decode(ui, core.nativeView(ui.arena)) catch @panic("invalid compiled TypeScript view data");
}

fn decode(ui: *Ui, bytes: []const u8) !Ui.Node {
    if (bytes.len > 1024 * 1024) return error.ViewTooLarge;
    const tree = try std.json.parseFromSliceLeaky(Tree, ui.arena, bytes, .{ .allocate = .alloc_always });
    if (tree.format != 1 or tree.nodes.len == 0 or tree.nodes.len > 1024) return error.InvalidView;
    if (tree.nodes[0].end != tree.nodes.len) return error.InvalidView;
    return node(ui, tree.nodes, 0, tree.nodes.len, 0);
}

fn node(ui: *Ui, records: []const Record, index: usize, parent_end: usize, depth: usize) !Ui.Node {
    if (depth > 64) return error.ViewTooDeep;
    const value = records[index];
    if (value.end <= index or value.end > parent_end) return error.InvalidView;
    if (!std.math.isFinite(value.gap) or value.gap < 0 or !std.math.isFinite(value.grow) or value.grow < 0) return error.InvalidView;
    if (value.padding) |padding| if (!std.math.isFinite(padding) or padding < 0) return error.InvalidView;
    const container = value.kind == .column or value.kind == .row;
    if (!container and value.end != index + 1) return error.InvalidView;
    if (value.press != null and value.kind != .button) return error.InvalidView;
    if (value.toggle != null and value.kind != .switch_control) return error.InvalidView;
    var children: std.ArrayList(Ui.Node) = .empty;
    var child_index = index + 1;
    while (child_index < value.end) {
        try children.append(ui.arena, try node(ui, records, child_index, value.end, depth + 1));
        child_index = records[child_index].end;
    }
    const kind: sdk.canvas.WidgetKind = switch (value.kind) {
        inline else => |tag| @field(sdk.canvas.WidgetKind, @tagName(tag)),
    };
    return ui.el(kind, .{
        .key = if (value.key) |key| .{ .str = key } else null,
        .text = value.text,
        .gap = value.gap,
        .padding = value.padding,
        .grow = value.grow,
        .main = value.main,
        .cross = value.cross,
        .size = value.size,
        .variant = value.variant,
        .checked = value.checked,
        .disabled = value.disabled,
        .on_press = if (value.press) |tag| core.nativeViewEvent(tag) else null,
        .on_toggle = if (value.toggle) |tag| core.nativeViewEvent(tag) else null,
    }, children.items);
}

test "compiled view strings belong to the native tree arena" {
    if (comptime enabled) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = Ui.init(arena.allocator());
        const source = "{\"format\":1,\"nodes\":[{\"end\":1,\"kind\":\"text\",\"text\":\"café\",\"key\":\"label\"}]}";
        const bytes = try std.testing.allocator.dupe(u8, source);
        defer std.testing.allocator.free(bytes);
        const result = try decode(&ui, bytes);
        @memset(bytes, 0);
        try std.testing.expectEqualStrings("café", result.widget.text);
        try std.testing.expectEqualStrings("label", result.key.?.str);
    } else return error.SkipZigTest;
}

test "compiled view refuses bad versions, spans, kinds and geometry" {
    if (comptime enabled) {
        const cases = [_][]const u8{
            "{\"format\":2,\"nodes\":[]}",
            "{\"format\":1,\"nodes\":[]}",
            "{\"format\":1,\"nodes\":[{\"end\":0,\"kind\":\"text\",\"text\":\"\"}]}",
            "{\"format\":1,\"nodes\":[{\"end\":2,\"kind\":\"column\",\"text\":\"\"},{\"end\":3,\"kind\":\"text\",\"text\":\"\"}]}",
            "{\"format\":1,\"nodes\":[{\"end\":2,\"kind\":\"text\",\"text\":\"\"},{\"end\":2,\"kind\":\"text\",\"text\":\"\"}]}",
            "{\"format\":1,\"nodes\":[{\"end\":1,\"kind\":\"unknown\",\"text\":\"\"}]}",
            "{\"format\":1,\"nodes\":[{\"end\":1,\"kind\":\"text\",\"text\":\"\",\"gap\":-1}]}",
            "{\"format\":1,\"nodes\":[{\"end\":1,\"kind\":\"text\",\"text\":\"\",\"grow\":1e300}]}",
            "{\"format\":1,\"nodes\":[{\"end\":1,\"kind\":\"text\",\"text\":\"\",\"press\":0}]}",
        };
        for (cases) |source| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var ui = Ui.init(arena.allocator());
            if (decode(&ui, source)) |_| return error.TestExpectedError else |_| {}
        }
    } else return error.SkipZigTest;
}
