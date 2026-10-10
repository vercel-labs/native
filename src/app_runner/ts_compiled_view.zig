//! Native consumer of the optional compiled TypeScript view. This module
//! never evaluates bindings or reads the model. Tree data is copied before
//! scriptc's result arena resets; strings and nodes then live for this native
//! tree generation. Canonical event envelopes become ordinary journaled Msgs.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("core.zig");
pub const enabled = @hasDecl(core, "nativeView");
const Ui = sdk.canvas.Ui(core.Msg);

/// Raw text uses byte arrays only; JSON strings would silently admit a
/// second encoding and could replace malformed model bytes.
const ByteText = struct {
    bytes: []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !ByteText {
        const value = try std.json.innerParse(std.json.Value, allocator, source, options);
        const array = switch (value) {
            .array => |items| items.items,
            else => return error.UnexpectedToken,
        };
        const bytes = try allocator.alloc(u8, array.len);
        for (array, bytes) |item, *byte| {
            const number = switch (item) {
                .integer => |number| number,
                else => return error.UnexpectedToken,
            };
            if (number < 0 or number > 255) return error.Overflow;
            byte.* = @intCast(number);
        }
        return .{ .bytes = bytes };
    }
};

fn byteText(raw: ?ByteText, fallback: []const u8) []const u8 {
    return if (raw) |text| text.bytes else fallback;
}

const SpanRecord = struct {
    text: []const u8,
    textBytes: ?ByteText = null,
    weight: sdk.canvas.TextSpanWeight = .regular,
    color: ?sdk.canvas.TextSpanColor = null,
    scale: ?f32 = null,
    monospace: bool = false,
    italic: bool = false,
    underline: bool = false,
};

const ChartSeriesRecord = struct {
    kind: enum { line, bar },
    values: []const u32,
    color: sdk.canvas.ChartSeriesColor,
    fill: bool,
    label: ByteText,
};

const Record = struct {
    chartSeries: ?[]const ChartSeriesRecord = null,
    chartXLabels: ?[]const ByteText = null,
    chartYMin: ?u32 = null,
    chartYMax: ?u32 = null,
    chartGridLines: ?u8 = null,
    chartBaseline: ?bool = null,
    chartYLabels: ?bool = null,
    chartHoverDetails: ?bool = null,
    chartStrokeWidth: ?u32 = null,
    videoSrc: ?[]const u8 = null,
    videoControls: bool = false,
    videoAutoplay: bool = true,
    videoLoop: bool = false,
    videoMuted: bool = false,
    videoControl: sdk.canvas.VideoControlVerb = .none,
    zeroIntrinsic: ?bool = null,
    clipContent: ?bool = null,
    overflow: sdk.canvas.TextOverflow = .ellipsis,
    end: usize,
    kind: enum { image, combobox, bubble, table, data_grid, popover, menu_surface, data_row, data_cell, progress, skeleton, spinner, column, row, stack, grid, card, alert, dialog, drawer, sheet, separator, panel, badge, input, text_field, search_field, textarea, text, icon, button, checkbox, switch_control, toggle, slider, status_bar, spacer, scroll, avatar, radio, radio_group, button_group, breadcrumb, pagination, toggle_button, toggle_group, accordion, tabs, segmented_control, tree, list, list_item, select, dropdown_menu, menu_item, tooltip, split, resizable, media_surface, terminal, input_group, input_group_actions, code, chart, markdown },
    text: []const u8,
    textBytes: ?ByteText = null,
    placeholder: []const u8 = "",
    placeholderBytes: ?ByteText = null,
    command: []const u8 = "",
    wrap: ?bool = null,
    submitOnEnter: bool = false,
    key: ?[]const u8 = null,
    keyBytes: ?ByteText = null,
    keyInt: ?i64 = null,
    keySlot: usize = 0,
    globalKey: ?[]const u8 = null,
    globalKeyBytes: ?ByteText = null,
    globalKeyInt: ?i64 = null,
    columns: usize = 0,
    virtualized: bool = false,
    virtualItemExtent: f32 = 0,
    virtualWindow: ?usize = null,
    gap: f32 = 0,
    padding: ?f32 = null,
    paddingTop: ?f32 = null,
    paddingBottom: ?f32 = null,
    paddingLeft: ?f32 = null,
    paddingRight: ?f32 = null,
    grow: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    minWidth: f32 = 0,
    maxWidth: f32 = 0,
    resizeDuration: u32 = 0,
    resizeEasing: sdk.canvas.Easing = .standard,
    resizeOrigin: f32 = -1,
    value: f32 = 0,
    valueX: ?f32 = null,
    axis: ?sdk.canvas.ScrollAxes = null,
    overscroll: ?sdk.canvas.WidgetOverscroll = null,
    image: u64 = 0,
    imageLower: ?u32 = null,
    imageUpper: ?u32 = null,
    imageFit: ?sdk.canvas.ImageFit = null,
    pty: ?u64 = null,
    ptyBytes: ?ByteText = null,
    scrollback: ?u32 = null,
    terminal: ?u8 = null,
    icon: []const u8 = "",
    iconBytes: ?ByteText = null,
    iconPlacement: sdk.canvas.WidgetIconPlacement = .leading,
    label: []const u8 = "",
    labelBytes: ?ByteText = null,
    role: @FieldType(sdk.canvas.WidgetSemantics, "role") = .none,
    background: @FieldType(sdk.canvas.StyleTokenRefs, "background") = null,
    foreground: @FieldType(sdk.canvas.StyleTokenRefs, "foreground") = null,
    borderColor: @FieldType(sdk.canvas.StyleTokenRefs, "border_color") = null,
    focusRing: @FieldType(sdk.canvas.StyleTokenRefs, "focus_ring") = null,
    radius: @FieldType(sdk.canvas.StyleTokenRefs, "radius") = null,
    accent: @FieldType(sdk.canvas.StyleTokenRefs, "accent") = null,
    accentForeground: @FieldType(sdk.canvas.StyleTokenRefs, "accent_foreground") = null,
    backdropBlur: @FieldType(Ui.ElementOptions, "backdrop_blur_token") = null,
    quietHover: bool = false,
    windowDrag: bool = false,
    main: @FieldType(Ui.ElementOptions, "main") = .start,
    cross: @FieldType(Ui.ElementOptions, "cross") = .stretch,
    size: @FieldType(Ui.ElementOptions, "size") = .default,
    variant: @FieldType(Ui.ElementOptions, "variant") = .default,
    checked: bool = false,
    disabled: bool = false,
    selected: bool = false,
    focusable: bool = false,
    autofocus: bool = false,
    expanded: ?bool = null,
    treeLevel: u16 = 0,
    listItemIndex: ?u32 = null,
    listItemCount: ?u32 = null,
    spans: ?[]const SpanRecord = null,
    textAlignment: sdk.canvas.TextAlign = .start,
    spanWeight: ?sdk.canvas.TextSpanWeight = null,
    spanColor: ?sdk.canvas.TextSpanColor = null,
    spanScale: ?f32 = null,
    markdownRecipe: ?ByteText = null,
    markdownLink: ?u8 = null,
    markdownDetails: ?u8 = null,
    codeLanguage: ?sdk.canvas.code.Language = null,
    codeLineDigits: ?u8 = null,
    codeEditable: ?bool = null,
    codeNumbered: ?bool = null,
    codeAddedLines: ?[]const u8 = null,
    codeRemovedLines: ?[]const u8 = null,
    contextMenu: []const ContextMenuRecord = &.{},
    press: ?[]const u8 = null,
    doublePress: ?[]const u8 = null,
    hold: ?[]const u8 = null,
    hoverEnter: ?[]const u8 = null,
    hoverLeave: ?[]const u8 = null,
    reachEnd: ?[]const u8 = null,
    reachStart: ?[]const u8 = null,
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
    tooltipDelay: ?i32 = null,
};
const ContextMenuRecord = struct {
    label: []const u8,
    labelBytes: ?ByteText = null,
    press: ?[]const u8 = null,
    enabled: bool,
    separator: bool,
};
const Tree = struct { format: u32, nodes: []const Record };

const VirtualRequest = struct {
    id: []const u8,
    itemCount: usize,
    itemExtent: f32,
    gap: f32,
    overscan: usize,
    viewportFallback: f32,
    indexBase: u64,
    trailing: bool,
    estimateHelper: i64,
};
const VirtualRequests = struct { format: u32, requests: []const VirtualRequest };
const ResolvedVirtual = struct { options: Ui.VirtualListOptions, range: sdk.canvas.VirtualListRange };

fn virtualView(ui: *Ui, label: []const u8, video: []const u8) !Ui.Node {
    const bytes = core.nativeVirtualRequests(label, video, ui.arena);
    const requests = try std.json.parseFromSliceLeaky(VirtualRequests, ui.arena, bytes, .{ .allocate = .alloc_always });
    if (requests.format != 1 or requests.requests.len > sdk.canvas.max_virtual_windows) return error.InvalidView;
    const resolved = try ui.arena.alloc(ResolvedVirtual, requests.requests.len);
    const context = try ui.arena.alloc(u8, 8 + resolved.len * 96);
    std.mem.writeInt(u32, context[0..4], 1, .little);
    std.mem.writeInt(u32, context[4..8], @intCast(resolved.len), .little);
    for (requests.requests, resolved, 0..) |request, *target, index| {
        if (request.id.len == 0 or request.id.len > 256 or request.itemCount > 9007199254740991 or request.overscan > 9007199254740991 or request.indexBase > 9007199254740991 - request.itemCount) return error.InvalidView;
        for (requests.requests[0..index]) |prior| if (std.mem.eql(u8, prior.id, request.id)) return error.InvalidView;
        for ([_]f32{ request.itemExtent, request.gap, request.viewportFallback }) |extent| if (!std.math.isFinite(extent) or extent < 0) return error.InvalidView;
        if (request.estimateHelper < -1 or request.estimateHelper > std.math.maxInt(u32)) return error.InvalidView;
        if (request.estimateHelper == -1 and request.itemExtent == 0) return error.InvalidView;
        target.options = .{
            .id = request.id,
            .item_count = request.itemCount,
            .item_extent = request.itemExtent,
            .gap = request.gap,
            .overscan = request.overscan,
            .viewport_fallback = request.viewportFallback,
            .index_base = request.indexBase,
            .anchor = if (request.trailing) .trailing else .leading,
            .extent_estimate = if (request.estimateHelper >= 0) core.Model.virtualExtentEstimate else null,
            .extent_context = if (request.estimateHelper >= 0) @ptrFromInt(@as(usize, @intCast(request.estimateHelper)) + 1) else null,
        };
        target.range = ui.virtualWindow(target.options);
        const at = 8 + index * 96;
        inline for (@typeInfo(sdk.canvas.VirtualListRange).@"struct".fields, 0..) |field, offset| {
            const value = @field(target.range, field.name);
            const number: f64 = if (@typeInfo(field.type) == .int) @floatFromInt(value) else value;
            std.mem.writeInt(u64, context[at + offset * 8 ..][0..8], @bitCast(number), .little);
        }
    }
    return decodeVirtual(ui, core.nativeVirtualView(label, context, video, ui.arena), resolved);
}

/// Concrete callbacks for generated compiled-model apps; the legacy builders
/// retain their full Model signature for independent reference fixtures.
pub fn buildRuntime(ui: *Ui, model: *const core.RuntimeModel) Ui.Node {
    _ = model;
    return buildCommitted(ui);
}

pub fn buildRuntimeWindow(ui: *Ui, model: *const core.RuntimeModel, label: []const u8) Ui.Node {
    _ = model;
    return buildCommittedWindow(ui, label);
}

pub fn build(ui: *Ui, model: *const core.Model) Ui.Node {
    _ = model;
    return buildCommitted(ui);
}

fn buildCommitted(ui: *Ui) Ui.Node {
    var context: [20]u8 = undefined;
    if (comptime @hasDecl(core, "nativeVirtualRequests")) return virtualView(ui, "", videoContext(ui, &context)) catch @panic("invalid compiled virtual view data");
    const bytes = if (comptime @hasDecl(core, "nativeMediaView")) core.nativeMediaView(videoContext(ui, &context), ui.arena) else core.nativeView(ui.arena);
    return decode(ui, bytes) catch @panic("invalid compiled TypeScript view data");
}

pub fn buildWindow(ui: *Ui, model: *const core.Model, label: []const u8) Ui.Node {
    _ = model;
    return buildCommittedWindow(ui, label);
}

fn buildCommittedWindow(ui: *Ui, label: []const u8) Ui.Node {
    var context: [20]u8 = undefined;
    if (comptime @hasDecl(core, "nativeVirtualRequests")) return virtualView(ui, label, videoContext(ui, &context)) catch @panic("invalid compiled virtual window view data");
    const bytes = if (comptime @hasDecl(core, "nativeMediaWindowView")) core.nativeMediaWindowView(label, videoContext(ui, &context), ui.arena) else core.nativeWindowView(label, ui.arena);
    return decode(ui, bytes) catch @panic("invalid compiled TypeScript window view data");
}

fn videoContext(ui: *Ui, buffer: *[20]u8) []const u8 {
    const state = ui.video_state;
    buffer.* = @splat(0);
    buffer[0] = 1;
    buffer[1] = @as(u8, @intFromBool(state.active)) | (@as(u8, @intFromBool(state.playing)) << 1) | (@as(u8, @intFromBool(state.buffering)) << 2) | (@as(u8, @intFromBool(state.completed)) << 3);
    std.mem.writeInt(u64, buffer[4..12], @bitCast(@as(f64, @floatFromInt(state.position_ms))), .little);
    std.mem.writeInt(u64, buffer[12..20], @bitCast(@as(f64, @floatFromInt(state.duration_ms))), .little);
    return buffer;
}

fn decode(ui: *Ui, bytes: []const u8) !Ui.Node {
    return decodeVirtual(ui, bytes, &.{});
}

fn decodeVirtual(ui: *Ui, bytes: []const u8, virtuals: []const ResolvedVirtual) !Ui.Node {
    if (comptime @hasDecl(core, "nativeWindowPolicy")) {
        ui.construction_policy = core.nativeWindowPolicy;
        ui.composition_policy = core.nativeWindowPolicy;
        ui.code_content_policy = core.nativeWindowPolicy;
        ui.chart_content_policy = core.nativeWindowPolicy;
        ui.markdown_content_policy = core.nativeMarkdownPolicy;
    }
    // Numeric JSON byte arrays need up to four transport bytes per source
    // byte. Preserve the native retained-text budget at the decoder boundary.
    if (bytes.len > 4 * 1024 * 1024) return error.ViewTooLarge;
    const tree = std.json.parseFromSliceLeaky(Tree, ui.arena, bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidView,
    };
    if (tree.format != 2 or tree.nodes.len == 0 or tree.nodes.len > 1024) return error.InvalidView;
    if (tree.nodes[0].end != tree.nodes.len) return error.InvalidView;
    var seen: [sdk.canvas.max_virtual_windows]bool = @splat(false);
    for (tree.nodes) |record| if (record.virtualWindow) |window| {
        if (window >= virtuals.len or seen[window]) return error.InvalidView;
        seen[window] = true;
    };
    for (seen[0..virtuals.len]) |present| if (!present) return error.InvalidView;
    return node(ui, tree.nodes, 0, tree.nodes.len, 0, virtuals, null);
}

fn node(ui: *Ui, records: []const Record, index: usize, parent_end: usize, depth: usize, virtuals: []const ResolvedVirtual, parent_kind: ?@FieldType(Record, "kind")) !Ui.Node {
    if (depth > 64) return error.ViewTooDeep;
    var value = records[index];
    if (value.keyBytes != null and value.key != null or value.globalKeyBytes != null and value.globalKey != null) return error.InvalidView;
    value.text = byteText(value.textBytes, value.text);
    if (value.keyBytes) |bytes| value.key = bytes.bytes;
    if (value.globalKeyBytes) |bytes| value.globalKey = bytes.bytes;
    value.label = byteText(value.labelBytes, value.label);
    value.placeholder = byteText(value.placeholderBytes, value.placeholder);
    value.icon = byteText(value.iconBytes, value.icon);
    if (value.end <= index or value.end > parent_end) return error.InvalidView;
    if (!std.math.isFinite(value.gap) or value.gap < 0 or !std.math.isFinite(value.grow) or value.grow < 0) return error.InvalidView;
    if (value.padding) |padding| if (!std.math.isFinite(padding) or padding < 0) return error.InvalidView;
    for ([_]?f32{ value.paddingTop, value.paddingBottom, value.paddingLeft, value.paddingRight }) |side| if (side) |padding| if (!std.math.isFinite(padding) or padding < 0) return error.InvalidView;
    if ((value.kind == .code or value.kind == .input_group or value.kind == .input_group_actions) and
        (value.paddingTop != null or value.paddingBottom != null or value.paddingLeft != null or value.paddingRight != null)) return error.InvalidView;
    for ([_]f32{ value.width, value.height, value.minWidth, value.maxWidth }) |extent| if (!std.math.isFinite(extent) or extent < 0) return error.InvalidView;
    if (value.kind == .resizable and value.gap != 0) return error.InvalidView;
    if (value.resize != null and value.kind != .split) return error.InvalidView;
    if (!std.math.isFinite(value.resizeOrigin) or (value.resizeOrigin != -1 and (value.resizeOrigin < 0 or value.resizeOrigin > 1))) return error.InvalidView;
    if ((value.resizeDuration != 0 or value.resizeEasing != .standard or value.resizeOrigin != -1) and value.kind != .split) return error.InvalidView;
    if ((value.resizeEasing != .standard or value.resizeOrigin != -1) and value.resizeDuration == 0) return error.InvalidView;
    if (!std.math.isFinite(value.virtualItemExtent) or value.virtualItemExtent < 0) return error.InvalidView;
    if ((value.columns != 0 or value.virtualized or value.virtualItemExtent != 0) and value.kind != .grid) return error.InvalidView;
    if (value.columns > 9007199254740991) return error.InvalidView;
    if (!std.math.isFinite(value.value)) return error.InvalidView;
    if (value.virtualWindow) |window| if (value.kind != .scroll or window >= virtuals.len) return error.InvalidView;
    if ((value.reachEnd != null or value.reachStart != null) and value.kind != .scroll) return error.InvalidView;
    if ((value.valueX != null or value.axis != null or value.overscroll != null) and value.kind != .scroll) return error.InvalidView;
    if (value.valueX) |offset| if (!std.math.isFinite(offset)) return error.InvalidView;
    if (value.key != null and value.keyInt != null or value.globalKey != null and value.globalKeyInt != null) return error.InvalidView;
    if (value.keySlot > 1024 or value.keySlot != 0 and value.key == null and value.keyInt == null) return error.InvalidView;
    if (value.image > 9007199254740991) return error.InvalidView;
    if ((value.imageLower == null) != (value.imageUpper == null) or value.imageLower != null and value.image != 0) return error.InvalidView;
    if (value.imageLower != null and value.kind != .image and value.kind != .avatar) return error.InvalidView;
    if (value.imageFit != null and value.kind != .image) return error.InvalidView;
    if (value.kind == .image and (value.text.len != 0 or value.textBytes != null)) return error.InvalidView;
    for ([_]?i64{ value.keyInt, value.globalKeyInt }) |int| if (int) |key| if (key < -9007199254740991 or key > 9007199254740991) return error.InvalidView;
    const chart_metadata = value.chartSeries != null or value.chartXLabels != null or value.chartYMin != null or value.chartYMax != null or value.chartGridLines != null or value.chartBaseline != null or value.chartYLabels != null or value.chartHoverDetails != null or value.chartStrokeWidth != null;
    if (chart_metadata and value.kind != .chart) return error.InvalidView;
    if (value.kind == .chart and (value.chartSeries == null or value.chartXLabels == null or value.chartSeries.?.len == 0 or value.chartSeries.?.len > 64 or value.text.len != 0 or value.textBytes != null or value.role != .none or value.focusable or value.hold != null or value.drag != null or value.hoverEnter != null or value.hoverLeave != null or value.contextMenu.len != 0)) return error.InvalidView;
    const modal = value.kind == .dialog or value.kind == .drawer or value.kind == .sheet;
    const container = value.kind == .bubble or value.kind == .table or value.kind == .data_grid or value.kind == .popover or value.kind == .menu_surface or value.kind == .data_row or value.kind == .input_group or value.kind == .input_group_actions or modal or value.kind == .card or value.kind == .alert or value.kind == .grid or value.kind == .column or value.kind == .row or value.kind == .stack or value.kind == .scroll or value.kind == .panel or value.kind == .radio_group or value.kind == .button_group or value.kind == .breadcrumb or value.kind == .pagination or value.kind == .toggle_group or value.kind == .accordion or value.kind == .tabs or value.kind == .tree or value.kind == .list or value.kind == .list_item or value.kind == .dropdown_menu or value.kind == .split or value.kind == .resizable;
    const tree_row = (value.kind == .column or value.kind == .row or value.kind == .panel or value.kind == .list_item) and value.role == .treeitem;
    if (value.role == .treeitem and !tree_row) return error.InvalidView;
    if (value.role == .tree and value.kind != .column and value.kind != .row and value.kind != .panel and value.kind != .scroll and value.kind != .tree) return error.InvalidView;
    if (value.kind == .data_row and parent_kind != .table and parent_kind != .data_grid or value.kind == .data_cell and parent_kind != .data_row) return error.InvalidView;
    if (!container and value.end != index + 1) return error.InvalidView;
    if (value.kind == .list_item and value.end != index + 1 and value.text.len != 0) return error.InvalidView;
    if (value.dismiss != null and !modal and value.kind != .dropdown_menu and value.kind != .popover and value.kind != .menu_surface) return error.InvalidView;
    if (!std.math.isFinite(value.anchorOffset)) return error.InvalidView;
    if ((value.anchor != null or value.anchorAlignment != .start or value.anchorOffset != 4) and value.kind != .dropdown_menu and value.kind != .popover and value.kind != .menu_surface and value.kind != .tooltip) return error.InvalidView;
    if (value.tooltipDelay) |delay| if (value.kind != .tooltip or value.anchor == null or delay < 0) return error.InvalidView;
    if (value.anchor == null and (value.anchorAlignment != .start or value.anchorOffset != 4)) return error.InvalidView;
    if ((value.expanded != null or value.treeLevel != 0) and value.role != .treeitem) return error.InvalidView;
    if (value.change != null and !tree_row and value.kind != .radio and value.kind != .slider and value.kind != .list_item) return error.InvalidView;
    if (value.valueChange != null and (value.kind != .slider or value.change != null)) return error.InvalidView;
    if (value.scroll != null and value.kind != .scroll) return error.InvalidView;
    const text_entry = value.kind == .combobox or value.kind == .text_field or value.kind == .input or value.kind == .search_field or value.kind == .textarea or (value.kind == .code and value.codeEditable == true);
    if ((value.pty != null or value.ptyBytes != null or value.scrollback != null or value.terminal != null) and value.kind != .terminal) return error.InvalidView;
    if (value.pty != null and value.ptyBytes != null) return error.InvalidView;
    if (value.pty) |key| if (key > 9007199254740991) return error.InvalidView;
    if (value.kind == .terminal and (value.text.len != 0 or value.textBytes != null)) return error.InvalidView;
    if (value.autofocus and !text_entry and value.kind != .terminal) return error.InvalidView;
    if (value.submitOnEnter and value.kind != .textarea) return error.InvalidView;
    if (value.input != null and !text_entry) return error.InvalidView;
    if (value.submit != null and !text_entry and !tree_row) return error.InvalidView;
    if (value.placeholder.len != 0 and !text_entry and value.kind != .select) return error.InvalidView;
    if (value.wrap != null and value.kind != .text and value.kind != .code) return error.InvalidView;
    const legacy_paragraph = value.spanWeight != null or value.spanColor != null or value.spanScale != null;
    const paragraph = value.spans != null or legacy_paragraph;
    if (value.spans) |spans| {
        if (legacy_paragraph or value.text.len != 0 or value.wrap != null or spans.len == 0 or spans.len > 2048) return error.InvalidView;
        for (spans) |span| if (span.scale) |scale| if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidView;
    }
    if (paragraph and value.kind != .text) return error.InvalidView;
    if (value.spanScale) |scale| if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidView;
    if (value.kind == .markdown) {
        if (value.markdownRecipe == null or value.end != index + 1) return error.InvalidView;
        const defaults: Record = .{ .end = value.end, .kind = .markdown, .text = "" };
        inline for (@typeInfo(Record).@"struct".fields) |field| {
            if (comptime !std.mem.eql(u8, field.name, "end") and !std.mem.eql(u8, field.name, "kind") and !std.mem.eql(u8, field.name, "markdownRecipe") and !std.mem.eql(u8, field.name, "markdownLink") and !std.mem.eql(u8, field.name, "markdownDetails")) {
                const provided = @field(value, field.name);
                const expected = @field(defaults, field.name);
                if (comptime @typeInfo(field.type) == .pointer and @typeInfo(field.type).pointer.size == .slice) {
                    if (provided.len != expected.len) return error.InvalidView;
                } else if (!std.meta.eql(provided, expected)) return error.InvalidView;
            }
        }
        return stampCompound(try sdk.canvas.MarkdownContentPolicy.execute(core.Msg, ui, value.markdownRecipe.?.bytes, .{
            .on_link = if (value.markdownLink) |tag| try markdownLinkEvent(tag) else null,
            .on_details = if (value.markdownDetails) |tag| try markdownDetailsEvent(tag) else null,
        }));
    }
    if (value.markdownRecipe != null or value.markdownLink != null or value.markdownDetails != null) return error.InvalidView;
    if (value.kind == .code) {
        if (value.codeLanguage == null or value.codeEditable == null or value.codeNumbered == null or value.wrap == null or value.codeLineDigits != null or
            paragraph or value.placeholder.len != 0 or value.submitOnEnter or value.submit != null or value.contextMenu.len != 0 or value.autofocus or
            value.disabled or value.selected or value.checked or value.padding != null or value.gap != 0 or value.maxWidth != 0 or
            value.role != .none or value.focusable or value.windowDrag or value.image != 0 or value.icon.len != 0 or value.command.len != 0 or
            value.press != null or value.doublePress != null or value.hold != null or value.drag != null or value.hoverEnter != null or value.hoverLeave != null or
            value.background != null or value.foreground != null or value.borderColor != null or value.focusRing != null or value.radius != null)
            return error.InvalidView;
    } else if (value.codeEditable != null or value.codeNumbered != null) return error.InvalidView;
    if (value.kind != .code and (value.codeLanguage != null or value.codeLineDigits != null)) {
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
        try children.append(ui.arena, try node(ui, records, child_index, value.end, depth + 1, virtuals, value.kind));
        child_index = records[child_index].end;
    }
    if (value.kind == .split and children.items.len != 2) return error.InvalidView;
    if (value.kind == .code) {
        const added = try ui.arena.alloc(usize, if (value.codeAddedLines) |lines| lines.len else 0);
        const removed = try ui.arena.alloc(usize, if (value.codeRemovedLines) |lines| lines.len else 0);
        if (value.codeAddedLines) |lines| for (lines, added) |line, *slot| {
            slot.* = line;
        };
        if (value.codeRemovedLines) |lines| for (lines, removed) |line, *slot| {
            slot.* = line;
        };
        return stampCompound(ui.code(.{
            .key = if (value.key) |key| try sdk.canvas.forSlotKey(ui.arena, .{ .str = key }, value.keySlot) else if (value.keyInt) |key| try sdk.canvas.forSlotKey(ui.arena, .{ .int = @bitCast(key) }, value.keySlot) else null,
            .global_key = if (value.globalKey) |key| .{ .str = key } else if (value.globalKeyInt) |key| .{ .int = @bitCast(key) } else null,
            .width = value.width,
            .height = value.height,
            .min_width = value.minWidth,
            .grow = value.grow,
            .semantics = .{ .label = value.label },
            .language = value.codeLanguage.?,
            .wrap = value.wrap.?,
            .editable = value.codeEditable.?,
            .line_numbers = value.codeNumbered.?,
            .added_lines = added,
            .removed_lines = removed,
            .on_input = if (value.input) |tag| try inputEvent(tag) else null,
        }, value.text));
    }
    if (value.kind == .input_group_actions) {
        if (parent_kind != .input_group) return error.InvalidView;
        return stampCompound(ui.inputGroupActions(.{
            .key = if (value.key) |key| try sdk.canvas.forSlotKey(ui.arena, .{ .str = key }, value.keySlot) else if (value.keyInt) |key| try sdk.canvas.forSlotKey(ui.arena, .{ .int = @bitCast(key) }, value.keySlot) else null,
            .global_key = if (value.globalKey) |key| .{ .str = key } else if (value.globalKeyInt) |key| .{ .int = @bitCast(key) } else null,
            .gap = value.gap,
        }, children.items));
    }
    if (value.kind == .input_group) {
        if (children.items.len < 1 or children.items.len > 2 or children.items[0].widget.kind != .textarea) return error.InvalidView;
        if (children.items.len == 2 and records[records[index + 1].end].kind != .input_group_actions) return error.InvalidView;
        return stampCompound(ui.inputGroup(.{
            .key = if (value.key) |key| try sdk.canvas.forSlotKey(ui.arena, .{ .str = key }, value.keySlot) else if (value.keyInt) |key| try sdk.canvas.forSlotKey(ui.arena, .{ .int = @bitCast(key) }, value.keySlot) else null,
            .global_key = if (value.globalKey) |key| .{ .str = key } else if (value.globalKeyInt) |key| .{ .int = @bitCast(key) } else null,
            .width = value.width,
            .height = value.height,
            .min_width = value.minWidth,
            .grow = value.grow,
            .semantics = .{ .role = value.role, .label = value.label },
        }, children.items[0], if (children.items.len == 2) children.items[1] else null));
    }
    const kind: sdk.canvas.WidgetKind = switch (value.kind) {
        .input_group_actions, .code, .markdown => return error.InvalidView,
        .spacer => .stack,
        .scroll => .scroll_view,
        inline else => |tag| @field(sdk.canvas.WidgetKind, @tagName(tag)),
    };
    if (value.contextMenu.len > 32) return error.InvalidView;
    const non_hit_target = switch (value.kind) {
        .row, .column, .stack, .list, .grid, .split, .tree, .breadcrumb, .button_group, .pagination, .radio_group, .tabs, .toggle_group, .badge, .avatar, .tooltip, .separator, .spacer, .table, .data_grid, .data_row, .skeleton, .spinner, .icon => true,
        else => false,
    };
    if (value.quietHover and non_hit_target) return error.InvalidView;
    if (value.contextMenu.len > 0 and non_hit_target and value.press == null and value.doublePress == null and value.toggle == null and value.hold == null and value.drag == null) return error.InvalidView;
    const context_menu = try ui.arena.alloc(Ui.ContextMenuItem, value.contextMenu.len);
    for (value.contextMenu, context_menu) |raw_item, *slot| {
        var item = raw_item;
        item.label = byteText(item.labelBytes, item.label);
        if (item.separator and (item.label.len != 0 or item.press != null) or
            !item.separator and (item.label.len == 0 or item.press == null)) return error.InvalidView;
        slot.* = .{ .label = item.label, .msg = if (item.press) |bytes| try event(ui, bytes) else null, .enabled = item.enabled, .separator = item.separator };
    }
    var result = ui.el(kind, .{
        .style = .{ .quiet_hover = value.quietHover, .stroke_width = if (value.chartStrokeWidth) |bits| @as(f32, @bitCast(bits)) else null },
        .context_menu = context_menu,
        .key = if (value.key) |key| try sdk.canvas.forSlotKey(ui.arena, .{ .str = key }, value.keySlot) else if (value.keyInt) |key| try sdk.canvas.forSlotKey(ui.arena, .{ .int = @bitCast(key) }, value.keySlot) else null,
        .global_key = if (value.globalKey) |key| .{ .str = key } else if (value.globalKeyInt) |key| .{ .int = @bitCast(key) } else null,
        .text = value.text,
        .placeholder = value.placeholder,
        .command = value.command,
        .wrap = value.wrap,
        .overflow = value.overflow,
        .text_alignment = value.textAlignment,
        .submit_on_enter = value.submitOnEnter,
        .autofocus = value.autofocus,
        .columns = value.columns,
        .virtualized = value.virtualized,
        .virtual_item_extent = value.virtualItemExtent,
        .gap = value.gap,
        .padding = value.padding,
        .grow = value.grow,
        .width = value.width,
        .height = value.height,
        .min_width = value.minWidth,
        .max_width = value.maxWidth,
        .resize_duration = value.resizeDuration,
        .resize_easing = value.resizeEasing,
        .resize_origin = value.resizeOrigin,
        .value = value.value,
        .value_x = value.valueX orelse 0,
        .axis = value.axis orelse .vertical,
        .overscroll = value.overscroll orelse .default,
        .image = if (value.imageLower) |lower| @as(u64, lower) | (@as(u64, value.imageUpper.?) << 32) else value.image,
        .pty = value.pty orelse 0,
        .pty_name = if (value.ptyBytes) |key| key.bytes else "",
        .scrollback = value.scrollback orelse 0,
        .on_terminal = if (value.terminal) |tag| try terminalEvent(tag) else null,
        .icon = value.icon,
        .icon_placement = value.iconPlacement,
        .window_drag = value.windowDrag,
        .backdrop_blur_token = value.backdropBlur,
        .semantics = .{ .role = value.role, .label = value.label, .focusable = value.focusable, .list_item_index = value.listItemIndex, .list_item_count = value.listItemCount },
        .style_tokens = .{ .background = value.background, .foreground = value.foreground, .border_color = value.borderColor, .focus_ring = value.focusRing, .accent = value.accent, .accent_foreground = value.accentForeground, .radius = value.radius },
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
        .on_double_press = if (value.doublePress) |bytes| try event(ui, bytes) else null,
        .on_hold = if (value.hold) |bytes| try event(ui, bytes) else null,
        .on_hover_enter = if (value.hoverEnter) |bytes| try event(ui, bytes) else null,
        .on_hover_leave = if (value.hoverLeave) |bytes| try event(ui, bytes) else null,
        .on_reach_end = if (value.reachEnd) |bytes| try event(ui, bytes) else null,
        .on_reach_start = if (value.reachStart) |bytes| try event(ui, bytes) else null,
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
        .tooltip_delay = value.tooltipDelay orelse -1,
    }, children.items);
    if (value.kind == .avatar) result.widget.image_fit = .cover;
    if (value.imageFit) |fit| result.widget.image_fit = fit;
    if (value.paddingTop) |padding| result.widget.layout.padding.top = padding;
    if (value.paddingBottom) |padding| result.widget.layout.padding.bottom = padding;
    if (value.paddingLeft) |padding| result.widget.layout.padding.left = padding;
    if (value.paddingRight) |padding| result.widget.layout.padding.right = padding;
    if (value.virtualWindow) |window| {
        const resolved = virtuals[window];
        if (children.items.len != resolved.range.itemCount()) return error.InvalidView;
        for (children.items) |child| if (child.key == null and child.global_key == null) return error.InvalidView;
        var options = resolved.options;
        options.width = value.width;
        options.height = value.height;
        options.min_width = value.minWidth;
        options.grow = value.grow;
        options.padding = value.padding orelse 0;
        options.style_tokens = result.style_tokens;
        options.semantics = result.widget.semantics;
        options.overscroll = value.overscroll orelse .default;
        options.on_scroll = result.on_scroll;
        options.on_reach_end = result.on_reach_end;
        options.on_reach_start = result.on_reach_start;
        result = ui.virtualList(options, resolved.range, .{children.items});
    }
    if (value.videoSrc) |src| {
        if (src.len > 0) ui.video_declaration = .{ .src = src, .controls = value.videoControls, .autoplay = value.videoAutoplay, .loop = value.videoLoop, .muted = value.videoMuted };
    }
    result.widget.video_control = value.videoControl;
    if (value.zeroIntrinsic) |flag| result.widget.layout.zero_intrinsic = flag;
    if (value.clipContent) |flag| result.widget.layout.clip_content = flag;
    if (comptime @hasDecl(core, "nativeWindowPolicy")) result.widget.appearance_policy = core.nativeWindowPolicy;
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
        if ((value.kind == .list or value.kind == .list_item) and value.role != .tree and value.role != .treeitem) result.widget.interaction_policy = core.nativeListPolicy;
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
    if (value.kind == .chart) {
        const raw_series = value.chartSeries.?;
        const series = try ui.arena.alloc(sdk.canvas.ChartSeries, raw_series.len);
        for (raw_series, series) |raw, *entry| {
            if (raw.values.len > sdk.canvas.max_chart_points_per_series or raw.fill and raw.kind != .line) return error.InvalidView;
            const values = try ui.arena.alloc(f32, raw.values.len);
            for (raw.values, values) |bits, *sample| sample.* = @bitCast(bits);
            entry.* = .{ .kind = if (raw.kind == .bar) .bar else .line, .values = values, .color = raw.color, .fill = raw.fill, .label = raw.label.bytes };
        }
        const labels = try ui.arena.alloc([]const u8, value.chartXLabels.?.len);
        for (value.chartXLabels.?, labels) |raw, *label| label.* = raw.bytes;
        result.widget.chart = .{
            .series = series,
            .x_labels = labels,
            .y_min = if (value.chartYMin) |bits| @as(f32, @bitCast(bits)) else null,
            .y_max = if (value.chartYMax) |bits| @as(f32, @bitCast(bits)) else null,
            .grid_lines = value.chartGridLines orelse 0,
            .baseline = value.chartBaseline orelse false,
            .y_labels = value.chartYLabels orelse false,
            .hover_details = value.chartHoverDetails orelse false,
        };
    }
    if (value.spans) |runs| {
        // Rebase every run into one native-owned paragraph buffer. No pointer
        // into the compiled result arena survives this tree generation.
        var text_len: usize = 0;
        for (runs) |run| text_len += (byteText(run.textBytes, run.text)).len;
        const text_bytes = try ui.arena.alloc(u8, text_len);
        const spans = try ui.arena.alloc(sdk.canvas.TextSpan, runs.len);
        var offset: usize = 0;
        for (runs, spans) |raw_run, *span| {
            var run = raw_run;
            run.text = byteText(run.textBytes, run.text);
            @memcpy(text_bytes[offset .. offset + run.text.len], run.text);
            span.* = .{ .text = text_bytes[offset .. offset + run.text.len], .weight = run.weight, .color = run.color, .scale = run.scale orelse 0, .monospace = run.monospace, .italic = run.italic, .underline = run.underline };
            offset += run.text.len;
        }
        result.widget.text = text_bytes;
        result.widget.spans = spans;
    } else if (legacy_paragraph) {
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

test "compiled per-side padding keeps uniform defaults and rejects invalid extents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const node_value = try decode(&ui, "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"column\",\"text\":\"\",\"padding\":8,\"paddingTop\":2,\"paddingLeft\":16}]}" );
    try std.testing.expectEqualDeep(@TypeOf(node_value.widget.layout.padding){ .top = 2, .bottom = 8, .left = 16, .right = 8 }, node_value.widget.layout.padding);
    for ([_][]const u8{ "paddingTop", "paddingBottom", "paddingLeft", "paddingRight" }) |field| {
        const invalid = try std.fmt.allocPrint(arena.allocator(), "{{\"format\":2,\"nodes\":[{{\"end\":1,\"kind\":\"column\",\"text\":\"\",\"{s}\":-1}}]}}", .{field});
        try std.testing.expectError(error.InvalidView, decode(&ui, invalid));
        const group = try std.fmt.allocPrint(arena.allocator(), "{{\"format\":2,\"nodes\":[{{\"end\":2,\"kind\":\"input_group\",\"text\":\"\",\"{s}\":0}},{{\"end\":2,\"kind\":\"textarea\",\"text\":\"\"}}]}}", .{field});
        try std.testing.expectError(error.InvalidView, decode(&ui, group));
        const actions = try std.fmt.allocPrint(arena.allocator(), "{{\"format\":2,\"nodes\":[{{\"end\":3,\"kind\":\"input_group\",\"text\":\"\"}},{{\"end\":2,\"kind\":\"textarea\",\"text\":\"\"}},{{\"end\":3,\"kind\":\"input_group_actions\",\"text\":\"\",\"{s}\":0}}]}}", .{field});
        try std.testing.expectError(error.InvalidView, decode(&ui, actions));
    }
}

test "compiled image records preserve exact identities fit and independent native ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    for ([_]u64{ 0, 1, 4294967295, 4294967296, 9007199254740993, 9223372036854775808, std.math.maxInt(u64) }) |id| {
        const bytes = try std.fmt.allocPrint(arena.allocator(), "{{\"format\":2,\"nodes\":[{{\"end\":1,\"kind\":\"image\",\"text\":\"\",\"imageLower\":{d},\"imageUpper\":{d},\"imageFit\":\"cover\",\"width\":140,\"height\":140,\"label\":\"Art bay\"}}]}}", .{ @as(u32, @truncate(id)), id >> 32 });
        const retained = try decode(&ui, bytes);
        @memset(bytes, 'x');
        _ = try decode(&ui, "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"image\",\"text\":\"\",\"image\":7}]}" );
        var reference = Ui.init(arena.allocator());
        reference.construction_policy = ui.construction_policy;
        reference.composition_policy = ui.composition_policy;
        var expected = reference.image(.{ .image = id, .width = 140, .height = 140, .semantics = .{ .label = "Art bay" } });
        if (comptime @hasDecl(core, "nativeWindowPolicy")) expected.widget.appearance_policy = core.nativeWindowPolicy;
        if (comptime @hasDecl(core, "nativeTextPolicy")) expected.widget.interaction_policy = core.nativeTextPolicy;
        expected.widget.image_fit = .cover;
        try std.testing.expectEqualDeep(expected.widget, retained.widget);
    }
    for ([_][]const u8{
        "\"imageLower\":1", "\"imageUpper\":1", "\"imageLower\":0,\"imageUpper\":0,\"image\":1",
        "\"imageLower\":4294967296,\"imageUpper\":0", "\"imageLower\":0,\"imageUpper\":-1",
        "\"imageLower\":1.5,\"imageUpper\":0", "\"image\":9007199254740992", "\"imageFit\":\"invalid\"",
    }) |fields| {
        const bytes = try std.fmt.allocPrint(arena.allocator(), "{{\"format\":2,\"nodes\":[{{\"end\":1,\"kind\":\"image\",\"text\":\"\",{s}}}]}}", .{fields});
        try std.testing.expectError(error.InvalidView, decode(&ui, bytes));
    }
    for ([_][]const u8{
        "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"image\",\"text\":\"caption\"}]}",
        "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"image\",\"text\":\"\",\"textBytes\":[]}]}",
        "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"panel\",\"text\":\"\",\"imageLower\":0,\"imageUpper\":0}]}",
        "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"avatar\",\"text\":\"DK\",\"imageFit\":\"cover\"}]}",
    }) |bytes| try std.testing.expectError(error.InvalidView, decode(&ui, bytes));
}

test "compiled app Markdown rejects unrelated fields malformed bytes and incompatible routes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recipe = [_]u8{0} ** 80;
    recipe[0] = 1;
    recipe[4] = 1;
    recipe[16] = 3;
    @memset(recipe[48..52], 255);
    @memset(recipe[76..80], 255);
    const encoded = try std.json.Stringify.valueAlloc(arena.allocator(), recipe, .{});
    for ([_][]const u8{
        "\"textBytes\":[]",       "\"labelBytes\":[]",             "\"placeholderBytes\":[]", "\"placeholder\":\"x\"",   "\"command\":\"x\"",
        "\"wrap\":false",         "\"keyInt\":1",                  "\"globalKeyInt\":1",      "\"columns\":1",           "\"virtualized\":true",
        "\"padding\":0",          "\"minWidth\":1",                "\"maxWidth\":1",          "\"image\":1",             "\"icon\":\"x\"",
        "\"role\":\"group\"",     "\"foreground\":\"text_muted\"", "\"windowDrag\":true",     "\"main\":\"center\"",     "\"cross\":\"center\"",
        "\"checked\":true",       "\"disabled\":true",             "\"selected\":true",       "\"focusable\":true",      "\"spans\":[]",
        "\"spanScale\":1",        "\"textAlignment\":\"center\"",  "\"codeLineDigits\":1",    "\"videoAutoplay\":false", "\"clipContent\":true",
        "\"zeroIntrinsic\":true", "\"overflow\":\"clip\"",         "\"markdownLink\":255",    "\"markdownDetails\":255",
    }) |fields| {
        var ui = Ui.init(arena.allocator());
        const bytes = try std.fmt.allocPrint(arena.allocator(), "{{\"format\":2,\"nodes\":[{{\"end\":1,\"kind\":\"markdown\",\"text\":\"\",\"markdownRecipe\":{s},{s}}}]}}", .{ encoded, fields });
        try std.testing.expectError(error.InvalidView, decode(&ui, bytes));
    }
    for ([_][]const u8{ "null", "[1.0]", "[1.5]", "[-1]", "[256]", "[true]", "[\"1\"]" }) |invalid| {
        var ui = Ui.init(arena.allocator());
        const bytes = try std.fmt.allocPrint(arena.allocator(), "{{\"format\":2,\"nodes\":[{{\"end\":1,\"kind\":\"markdown\",\"text\":\"\",\"markdownRecipe\":{s}}}]}}", .{invalid});
        try std.testing.expectError(error.InvalidView, decode(&ui, bytes));
    }
    var ui = Ui.init(arena.allocator());
    const bytes = try std.fmt.allocPrint(arena.allocator(), "{{\"format\":2,\"nodes\":[{{\"end\":1,\"kind\":\"markdown\",\"text\":\"\",\"markdownRecipe\":{s}}}]}}", .{encoded});
    _ = try decode(&ui, bytes);
}

test "compiled app code rejects incomplete modes and unrelated renderer metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "\"codeNumbered\":false,\"wrap\":true",
        "\"codeEditable\":false,\"wrap\":true",
        "\"codeEditable\":false,\"codeNumbered\":false",
        "\"codeEditable\":false,\"codeNumbered\":false,\"wrap\":true,\"codeLineDigits\":1",
        "\"codeEditable\":false,\"codeNumbered\":false,\"wrap\":true,\"input\":0",
        "\"codeEditable\":true,\"codeNumbered\":false,\"wrap\":true,\"submitOnEnter\":true",
        "\"codeEditable\":false,\"codeNumbered\":false,\"wrap\":true,\"role\":\"group\"",
        "\"codeEditable\":false,\"codeNumbered\":false,\"wrap\":true,\"focusable\":true",
        "\"codeEditable\":false,\"codeNumbered\":false,\"wrap\":true,\"padding\":0",
        "\"codeEditable\":false,\"codeNumbered\":false,\"wrap\":true,\"image\":1",
        "\"codeEditable\":false,\"codeNumbered\":false,\"wrap\":true,\"codeAddedLines\":[1]",
        "\"codeEditable\":false,\"codeNumbered\":false,\"wrap\":true,\"codeAddedLines\":[1],\"codeRemovedLines\":[1]",
    }) |fields| {
        var ui = Ui.init(arena.allocator());
        const bytes = try std.fmt.allocPrint(arena.allocator(), "{{\"format\":2,\"nodes\":[{{\"end\":1,\"kind\":\"code\",\"text\":\"\",\"codeLanguage\":\"plain\",{s}}}]}}", .{fields});
        try std.testing.expectError(error.InvalidView, decode(&ui, bytes));
    }
}

// Compound records create their root after decoding the child primitives.
// Attach both owners exactly as the ordinary primitive decoder does.
fn stampCompound(node_value: Ui.Node) Ui.Node {
    var result = node_value;
    if (comptime @hasDecl(core, "nativeWindowPolicy")) result.widget.appearance_policy = core.nativeWindowPolicy;
    if (comptime @hasDecl(core, "nativeTextPolicy")) result.widget.interaction_policy = core.nativeTextPolicy;
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

fn terminalEvent(tag: u8) !Ui.TerminalMsgFn {
    inline for (@typeInfo(core.Msg).@"union".fields, 0..) |field, index| {
        if (comptime sdk.canvas.ui_markup_reflect.declaredTerminalStateRecord(field.type)) {
            if (tag == index) return Ui.translatedTerminalMsg(@field(std.meta.Tag(core.Msg), field.name), field.type);
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

fn markdownLinkEvent(tag: u8) !Ui.LinkMsgFn {
    inline for (@typeInfo(core.Msg).@"union".fields, 0..) |field, index| {
        if (comptime field.type == []const u8) if (tag == index) return Ui.linkMsg(@field(std.meta.Tag(core.Msg), field.name));
    }
    return error.InvalidView;
}
fn markdownDetailsEvent(tag: u8) !*const fn (usize) core.Msg {
    inline for (@typeInfo(core.Msg).@"union".fields, 0..) |field, index| {
        if (comptime @typeInfo(field.type) == .int or @typeInfo(field.type) == .float) {
            if (tag == index) return struct {
                fn make(ordinal: usize) core.Msg {
                    const value: field.type = if (comptime @typeInfo(field.type) == .int) @intCast(ordinal) else @floatFromInt(ordinal);
                    return @unionInit(core.Msg, field.name, value);
                }
            }.make;
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
        const source = "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"button\",\"text\":\"café\",\"command\":\"run.café\",\"key\":\"label\"}]}";
        const bytes = try std.testing.allocator.dupe(u8, source);
        defer std.testing.allocator.free(bytes);
        const result = try decode(&ui, bytes);
        @memset(bytes, 0);
        try std.testing.expectEqualStrings("café", result.widget.text);
        try std.testing.expectEqualStrings("label", result.key.?.str);
        try std.testing.expectEqualStrings("run.café", result.widget.command);
    } else return error.SkipZigTest;
}

test "compiled context menus reject malformed rows and preserve owned dispatch" {
    try testContextMenuRecords();
}

pub fn testContextMenuRecords() !void {
    if (comptime enabled) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = Ui.init(arena.allocator());
        for ([_][]const u8{
            "{\"label\":\"\",\"enabled\":true,\"separator\":false,\"press\":[1,0]}",
            "{\"label\":\"Missing handler\",\"enabled\":true,\"separator\":false}",
            "{\"label\":\"Bad handler\",\"enabled\":true,\"separator\":false,\"press\":[1,255]}",
            "{\"label\":\"Separator text\",\"enabled\":true,\"separator\":true}",
            "{\"label\":\"\",\"enabled\":true,\"separator\":true,\"press\":[1,0]}",
        }) |row| {
            const source = try std.fmt.allocPrint(ui.arena, "{{\"format\":2,\"nodes\":[{{\"end\":1,\"kind\":\"list_item\",\"text\":\"\",\"contextMenu\":[{s}]}}]}}", .{row});
            try std.testing.expectError(error.InvalidView, decode(&ui, source));
        }
        const oversized = try ui.arena.alloc(ContextMenuRecord, 33);
        @memset(oversized, .{ .label = "", .enabled = true, .separator = true });
        const records = [_]Record{.{ .end = 1, .kind = .list_item, .text = "", .contextMenu = oversized }};
        try std.testing.expectError(error.InvalidView, node(&ui, &records, 0, 1, 0, &.{}, null));
        inline for (@typeInfo(core.Msg).@"union".fields, 0..) |field, tag| {
            if (comptime field.type == void) {
                const source = try std.fmt.allocPrint(std.testing.allocator, "{{\"format\":2,\"nodes\":[{{\"end\":1,\"kind\":\"list_item\",\"text\":\"Task\",\"contextMenu\":[{{\"label\":\"Café\",\"press\":[1,{d}],\"enabled\":false,\"separator\":false}},{{\"label\":\"\",\"enabled\":true,\"separator\":true}}]}}]}}", .{tag});
                defer std.testing.allocator.free(source);
                const result = try decode(&ui, source);
                @memset(source, 0);
                const items = result.context_menu;
                try std.testing.expectEqual(@as(usize, 2), items.len);
                try std.testing.expectEqualStrings("Café", items[0].label);
                try std.testing.expectEqual(@as(core.Msg, @unionInit(core.Msg, field.name, {})), items[0].msg.?);
                try std.testing.expect(!items[0].enabled);
                try std.testing.expect(items[1].separator and items[1].msg == null);
                break;
            }
        }
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
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"text\",\"text\":\"\",\"press\":[0,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"text\",\"text\":\"\",\"input\":0}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"input\",\"text\":\"\",\"input\":255}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"input\",\"text\":\"\",\"submit\":[0,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"panel\",\"text\":\"\",\"wrap\":true}]}",
            "{\"format\":2,\"nodes\":[{\"end\":2,\"kind\":\"list_item\",\"text\":\"Mixed\"},{\"end\":2,\"kind\":\"text\",\"text\":\"child\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"text\",\"text\":\"\",\"role\":\"treeitem\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"list\",\"text\":\"\",\"role\":\"tree\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"list_item\",\"text\":\"\",\"toggle\":[0,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"toggle_group\",\"text\":\"\",\"toggle\":[0,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"toggle_button\",\"text\":\"\",\"change\":[1,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":2,\"kind\":\"toggle_button\",\"text\":\"Mixed\"},{\"end\":2,\"kind\":\"text\",\"text\":\"child\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"checkbox\",\"text\":\"Setting\",\"press\":[0,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"checkbox\",\"text\":\"Setting\",\"change\":[1,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"switch_control\",\"text\":\"Setting\",\"press\":[0,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"switch_control\",\"text\":\"Setting\",\"change\":[1,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"toggle\",\"text\":\"Setting\",\"press\":[0,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"toggle\",\"text\":\"Setting\",\"change\":[1,0]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"accordion\",\"text\":\"Section\",\"press\":[0,0]}]}",
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

// The native construction oracle supplies authored data. Compiled views also
// attach the appearance owner to every node; compare that callback explicitly
// instead of erasing it from the decoded tree.
fn withCompiledAppearance(reference: Ui.Node) Ui.Node {
    var result = reference;
    if (comptime @hasDecl(core, "nativeWindowPolicy")) result.widget.appearance_policy = core.nativeWindowPolicy;
    for (@constCast(result.nodes)) |*child| child.* = withCompiledAppearance(child.*);
    return result;
}

test "compiled tooltip records match native anchored and static primitives" {
    if (comptime enabled) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = Ui.init(arena.allocator());
        const source = "{\"format\":2,\"nodes\":[{\"end\":4,\"kind\":\"stack\",\"text\":\"\"},{\"end\":2,\"kind\":\"button\",\"text\":\"Run\"},{\"end\":3,\"kind\":\"tooltip\",\"text\":\"Run café\",\"anchor\":\"above\",\"anchorAlignment\":\"end\",\"anchorOffset\":8,\"tooltipDelay\":250},{\"end\":4,\"kind\":\"tooltip\",\"text\":\"Static hint\"}]}";
        const bytes = try std.testing.allocator.dupe(u8, source);
        defer std.testing.allocator.free(bytes);
        var actual = try decode(&ui, bytes);
        @memset(bytes, 0);
        var reference_ui = Ui.init(arena.allocator());
        const Reference = sdk.canvas.CompiledMarkupView(core.Model, core.Msg, "<stack><button>Run</button><tooltip anchor=\"above\" anchor-alignment=\"end\" anchor-offset=\"8\" tooltip-delay=\"250\">Run café</tooltip><tooltip>Static hint</tooltip></stack>");
        const model: core.Model = undefined;
        const expected = withCompiledAppearance(Reference.build(&reference_ui, &model));
        // The runtime-only callback differs by frontend; every authored
        // primitive field, child, owned string and anchor must match.
        actual.widget.interaction_policy = null;
        for (@constCast(actual.nodes)) |*child| child.widget.interaction_policy = null;
        const actual_tree = try ui.finalize(actual);
        const expected_tree = try reference_ui.finalize(expected);
        try std.testing.expectEqualDeep(expected_tree.root, actual_tree.root);
        try std.testing.expectEqualDeep(expected_tree.handlers, actual_tree.handlers);
        for ([_][]const u8{
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"button\",\"text\":\"\",\"tooltipDelay\":0}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"tooltip\",\"text\":\"\",\"tooltipDelay\":0}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"tooltip\",\"text\":\"\",\"anchor\":\"above\",\"tooltipDelay\":-1}]}",
        }) |invalid| try std.testing.expectError(error.InvalidView, decode(&ui, invalid));
    } else return error.SkipZigTest;
}

test "compiled modal records preserve caption constraints children and dismiss ownership" {
    try testModalRecords();
}

pub fn testModalRecords() !void {
    if (comptime enabled) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        inline for (@typeInfo(core.Msg).@"union".fields, 0..) |field, tag| {
            if (comptime field.type == void) {
                inline for (.{ sdk.canvas.WidgetKind.dialog, sdk.canvas.WidgetKind.drawer, sdk.canvas.WidgetKind.sheet }) |kind| {
                    var ui = Ui.init(arena.allocator());
                    const source = try std.fmt.allocPrint(
                        ui.arena,
                        "{{\"format\":2,\"nodes\":[{{\"end\":2,\"kind\":\"{s}\",\"text\":\"Café\",\"minWidth\":120,\"maxWidth\":420,\"height\":220,\"dismiss\":[1,{d}]}},{{\"end\":2,\"kind\":\"text\",\"text\":\"Owned content\"}}]}}",
                        .{ @tagName(kind), tag },
                    );
                    const bytes = try ui.arena.dupe(u8, source);
                    const actual = try decode(&ui, bytes);
                    @memset(bytes, 0);
                    var expected_ui = Ui.init(arena.allocator());
                    var child = expected_ui.text(.{}, "Owned content");
                    if (comptime @hasDecl(core, "nativeTextPolicy")) child.widget.interaction_policy = core.nativeTextPolicy;
                    var expected = expected_ui.el(kind, .{ .text = "Café", .min_width = 120, .max_width = 420, .height = 220, .on_dismiss = @unionInit(core.Msg, field.name, {}) }, .{child});
                    if (comptime @hasDecl(core, "nativeTextPolicy")) expected.widget.interaction_policy = core.nativeTextPolicy;
                    expected = withCompiledAppearance(expected);
                    try std.testing.expectEqualDeep(expected, actual);
                }
                break;
            }
        }
        var ui = Ui.init(arena.allocator());
        for ([_][]const u8{
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"dialog\",\"text\":\"\",\"maxWidth\":-1}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"sheet\",\"text\":\"\",\"dismiss\":[1,255]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"button\",\"text\":\"\",\"dismiss\":[1,0]}]}",
        }) |source| try std.testing.expectError(error.InvalidView, decode(&ui, source));
    } else return error.SkipZigTest;
}

pub fn testGridRecords() !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const bytes = try std.testing.allocator.dupe(u8, "{\"format\":2,\"nodes\":[{\"end\":2,\"kind\":\"grid\",\"text\":\"\",\"columns\":3,\"virtualized\":true,\"virtualItemExtent\":40,\"value\":24},{\"end\":2,\"kind\":\"text\",\"text\":\"Café\"}]}");
    defer std.testing.allocator.free(bytes);
    var actual = try decode(&ui, bytes);
    @memset(bytes, 'x');
    var reference_ui = Ui.init(arena.allocator());
    const expected = withCompiledAppearance(reference_ui.el(.grid, .{ .columns = 3, .virtualized = true, .virtual_item_extent = 40, .value = 24 }, .{reference_ui.text(.{}, "Café")}));
    actual.widget.interaction_policy = null;
    for (@constCast(actual.nodes)) |*child| child.widget.interaction_policy = null;
    const actual_tree = try ui.finalize(actual);
    const expected_tree = try reference_ui.finalize(expected);
    try std.testing.expectEqualDeep(expected_tree.root, actual_tree.root);
    try std.testing.expectEqualDeep(expected_tree.handlers, actual_tree.handlers);
    try std.testing.expectEqualStrings("Café", actual_tree.root.children[0].text);
    for ([_][]const u8{
        "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"row\",\"text\":\"\",\"columns\":2}]}",
        "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"text\",\"text\":\"\",\"virtualized\":true}]}",
        "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"grid\",\"text\":\"\",\"virtualItemExtent\":-1}]}",
        "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"grid\",\"text\":\"\",\"columns\":9007199254740992}]}",
    }) |invalid| try std.testing.expectError(error.InvalidView, decode(&ui, invalid));
}

pub fn testContentSurfaceRecords() !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    inline for (.{ sdk.canvas.WidgetKind.card, sdk.canvas.WidgetKind.alert }) |kind| {
        for ([_]?f32{ null, 0, 12 }) |padding| {
            for ([_]sdk.canvas.WidgetVariant{ .default, .destructive }) |variant| {
                var ui = Ui.init(arena.allocator());
                const spacing = if (padding) |value| try std.fmt.allocPrint(ui.arena, ",\"padding\":{d}", .{value}) else "";
                const source = try std.fmt.allocPrint(ui.arena, "{{\"format\":2,\"nodes\":[{{\"end\":2,\"kind\":\"{s}\",\"text\":\"Café\",\"width\":360,\"minWidth\":120,\"maxWidth\":420,\"variant\":\"{s}\"{s}}},{{\"end\":2,\"kind\":\"text\",\"text\":\"Owned content\"}}]}}", .{ @tagName(kind), @tagName(variant), spacing });
                const bytes = try ui.arena.dupe(u8, source);
                const actual = try decode(&ui, bytes);
                @memset(bytes, 0);
                var reference = Ui.init(arena.allocator());
                var child = reference.text(.{}, "Owned content");
                if (comptime @hasDecl(core, "nativeTextPolicy")) child.widget.interaction_policy = core.nativeTextPolicy;
                var expected = reference.el(kind, .{ .text = "Café", .width = 360, .min_width = 120, .max_width = 420, .padding = padding, .variant = variant }, .{child});
                if (comptime @hasDecl(core, "nativeTextPolicy")) expected.widget.interaction_policy = core.nativeTextPolicy;
                expected = withCompiledAppearance(expected);
                try std.testing.expectEqualDeep(expected, actual);
                const actual_tree = try ui.finalize(actual);
                const reference_tree = try reference.finalize(expected);
                try std.testing.expectEqualDeep(reference_tree.root, actual_tree.root);
                try std.testing.expectEqualDeep(reference_tree.handlers, actual_tree.handlers);
            }
        }
    }
    inline for (@typeInfo(core.Msg).@"union".fields, 0..) |field, tag| {
        if (field.type == void) {
            try testAuthoredPrimitiveRecords(@unionInit(core.Msg, field.name, {}), @intCast(tag));
            return;
        }
    }
}

fn testAuthoredPrimitiveRecords(press: core.Msg, tag: u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    inline for (.{ sdk.canvas.WidgetKind.bubble, .table, .data_row, .data_cell, .progress, .skeleton, .spinner, .text, .combobox }) |kind| {
        var ui = Ui.init(arena.allocator());
        const quiet = kind == .text or kind == .combobox or kind == .data_cell or kind == .bubble or kind == .progress;
        const record = try std.fmt.allocPrint(ui.arena, "{{\"end\":END,\"kind\":\"{s}\",\"text\":\"\",\"textBytes\":[65,0,255],\"iconBytes\":[112,0,255],\"iconPlacement\":\"trailing\",\"textAlignment\":\"end\",\"selected\":true,\"radius\":\"xl\",\"accent\":\"success\",\"accentForeground\":\"success_text\",\"quietHover\":{s},\"press\":[1,{d}]}}", .{ @tagName(kind), if (quiet) "true" else "false", tag });
        const wrapper = switch (kind) {
            .data_row => "{\"end\":2,\"kind\":\"table\",\"text\":\"\"},",
            .data_cell => "{\"end\":3,\"kind\":\"table\",\"text\":\"\"},{\"end\":3,\"kind\":\"data_row\",\"text\":\"\"},",
            else => "",
        };
        const count: usize = if (kind == .data_cell) 3 else if (kind == .data_row) 2 else 1;
        const ordinal = try std.fmt.allocPrint(ui.arena, "{d}", .{count});
        const resolved = try std.mem.replaceOwned(u8, ui.arena, record, "END", ordinal);
        const bytes = try std.fmt.allocPrint(ui.arena, "{{\"format\":2,\"nodes\":[{s}{s}]}}", .{ wrapper, resolved });
        const actual = try decode(&ui, bytes);
        @memset(bytes, 0);
        var reference = Ui.init(arena.allocator());
        var expected = stampCompound(reference.el(kind, .{
            .text = "A\x00\xff",
            .icon = "p\x00\xff",
            .icon_placement = .trailing,
            .text_alignment = .end,
            .selected = true,
            .style_tokens = .{ .radius = .xl, .accent = .success, .accent_foreground = .success_text },
            .style = .{ .quiet_hover = quiet },
            .on_press = press,
        }, .{}));
        if (kind == .data_cell) expected = stampCompound(reference.el(.data_row, .{}, .{expected}));
        if (kind == .data_row or kind == .data_cell) expected = stampCompound(reference.el(.table, .{}, .{expected}));
        try std.testing.expectEqualDeep(expected, actual);
        const actual_tree = try ui.finalize(actual);
        const reference_tree = try reference.finalize(expected);
        try std.testing.expectEqualDeep(reference_tree.root, actual_tree.root);
        try std.testing.expectEqualDeep(reference_tree.handlers, actual_tree.handlers);
    }
    var ui = Ui.init(arena.allocator());
    for ([_][]const u8{
        "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"data_row\",\"text\":\"\"}]}",
        "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"data_cell\",\"text\":\"\"}]}",
        "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"spinner\",\"text\":\"\",\"quietHover\":true}]}",
    }) |invalid| try std.testing.expectError(error.InvalidView, decode(&ui, invalid));
}

pub fn testInlineParagraphRecords() !void {
    if (comptime !enabled) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const source =
        \\{"format":2,"nodes":[{"end":1,"kind":"text","text":"","textAlignment":"end","size":"display","key":"readout","label":"Result","spans":[{"text":"Value"},{"text":" "},{"text":"café","weight":"medium","monospace":true,"italic":true,"underline":true,"scale":1.5,"color":"accent"},{"text":"."}]}]}
    ;
    const bytes = try std.testing.allocator.dupe(u8, source);
    defer std.testing.allocator.free(bytes);
    var actual = try decode(&ui, bytes);
    @memset(bytes, 0);
    var reference_ui = Ui.init(arena.allocator());
    const Reference = sdk.canvas.CompiledMarkupView(core.Model, core.Msg,
        \\<text text-alignment="end" size="display" key="readout" label="Result">Value <span weight="medium" mono="true" italic="true" underline="true" scale="1.5" foreground="accent">café</span>.</text>
    );
    const model: core.Model = undefined;
    const expected = withCompiledAppearance(Reference.build(&reference_ui, &model));
    actual.widget.interaction_policy = null;
    const actual_tree = try ui.finalize(actual);
    const expected_tree = try reference_ui.finalize(expected);
    try std.testing.expectEqualDeep(expected_tree.root, actual_tree.root);
    try std.testing.expectEqualDeep(expected_tree.handlers, actual_tree.handlers);
    try std.testing.expectEqualStrings("Value café.", actual.widget.text);
    var offset: usize = 0;
    for (actual.widget.spans) |span| {
        try std.testing.expect(span.text.ptr == actual.widget.text.ptr + offset);
        offset += span.text.len;
    }
    for ([_][]const u8{
        \\{"format":2,"nodes":[{"end":1,"kind":"button","text":"","spans":[{"text":"x"}]}]}
        ,
        \\{"format":2,"nodes":[{"end":1,"kind":"text","text":"hidden","spans":[{"text":"x"}]}]}
        ,
        \\{"format":2,"nodes":[{"end":1,"kind":"text","text":"","spans":[{"text":"x","scale":0}]}]}
        ,
        \\{"format":2,"nodes":[{"end":1,"kind":"text","text":"","spans":[{"text":"x","scale":-1}]}]}
        ,
        \\{"format":2,"nodes":[{"end":1,"kind":"text","text":"","spans":[{"text":"x","weight":"heavy"}]}]}
        ,
        \\{"format":2,"nodes":[{"end":1,"kind":"text","text":"","spans":[{"text":"x","color":"invalid"}]}]}
        ,
        \\{"format":2,"nodes":[{"end":1,"kind":"text","text":"","spans":[{"text":"x","extra":true}]}]}
        ,
        \\{"format":2,"nodes":[{"end":1,"kind":"text","text":"","spanWeight":"bold","spans":[{"text":"x"}]}]}
        ,
        \\{"format":2,"nodes":[{"end":1,"kind":"text","text":"","wrap":true,"spans":[{"text":"x"}]}]}
    }) |invalid| try std.testing.expectError(error.InvalidView, decode(&ui, invalid));
}

test "compiled byte text preserves owned labels placeholders spans and menus and rejects nonbytes" {
    try testByteTextRecords();
}

pub fn testByteTextRecords() !void {
    if (comptime enabled) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = Ui.init(arena.allocator());
        const source =
            \\{"format":2,"nodes":[{"end":4,"kind":"column","text":""},
            \\{"end":2,"kind":"button","text":"replacement","textBytes":[255,0,120],"icon":"replacement","iconBytes":[112,0,255],"label":"replacement","labelBytes":[195,0],"contextMenu":[{"label":"replacement","labelBytes":[254,0],"press":[1,MENU_TAG],"enabled":true,"separator":false}]},
            \\{"end":3,"kind":"textarea","text":"replacement","textBytes":[255],"placeholder":"replacement","placeholderBytes":[128,0]},
            \\{"end":4,"kind":"text","text":"","spans":[{"text":"replacement","textBytes":[255,0]}]}]}
        ;
        const tag = comptime blk: {
            for (@typeInfo(core.Msg).@"union".fields, 0..) |field, index| if (field.type == void) break :blk index;
            break :blk 255;
        };
        var tag_buffer: [3]u8 = undefined;
        const bytes = try std.mem.replaceOwned(u8, std.testing.allocator, source, "MENU_TAG", try std.fmt.bufPrint(&tag_buffer, "{d}", .{tag}));
        defer std.testing.allocator.free(bytes);
        const result = try ui.finalize(try decode(&ui, bytes));
        @memset(bytes, 0);
        try std.testing.expectEqualStrings("\xff\x00x", result.root.children[0].text);
        try std.testing.expectEqualStrings("p\x00\xff", result.root.children[0].icon);
        try std.testing.expectEqualStrings("\xc3\x00", result.root.children[0].semantics.label);
        try std.testing.expectEqualStrings("\xfe\x00", result.root.children[0].context_menu[0].label);
        try std.testing.expectEqualStrings("\xff", result.root.children[1].text);
        try std.testing.expectEqualStrings("\x80\x00", result.root.children[1].placeholder);
        try std.testing.expectEqualStrings("\xff\x00", result.root.children[2].text);
        try std.testing.expectEqualStrings("\xff\x00", result.root.children[2].spans[0].text);
        for ([_][]const u8{ "[256]", "[-1]", "[1.5]", "[true]", "[null]", "\"bad\"" }) |invalid| {
            for ([_][]const u8{ "textBytes", "iconBytes" }) |field| {
                const malformed = try std.fmt.allocPrint(ui.arena, "{{\"format\":2,\"nodes\":[{{\"end\":1,\"kind\":\"text\",\"text\":\"\",\"{s}\":{s}}}]}}", .{ field, invalid });
                try std.testing.expectError(error.InvalidView, decode(&ui, malformed));
            }
        }
    } else return error.SkipZigTest;
}

test "compiled byte keys own raw empty local and global identities and reject conflicting encodings" {
    try testByteKeyRecords();
}

pub fn testByteKeyRecords() !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const bytes = try ui.arena.dupe(u8,
        \\{"format":2,"nodes":[{"end":3,"kind":"column","text":"","keyBytes":[255,0,192,175]},
        \\{"end":2,"kind":"text","keyBytes":[],"text":"empty"},
        \\{"end":3,"kind":"text","globalKeyBytes":[128,0],"text":"global"}]}
    );
    const result = try decode(&ui, bytes);
    @memset(bytes, 0xA5);
    try std.testing.expectEqualStrings("\xff\x00\xc0\xaf", result.key.?.str);
    try std.testing.expectEqualStrings("", result.nodes[0].key.?.str);
    try std.testing.expectEqualStrings("\x80\x00", result.nodes[1].global_key.?.str);
    for ([_][]const u8{
        "\"keyBytes\":[],\"key\":\"ignored\"",             "\"keyBytes\":[],\"keyInt\":1",
        "\"globalKeyBytes\":[],\"globalKey\":\"ignored\"", "\"globalKeyBytes\":[],\"globalKeyInt\":1",
        "\"keyBytes\":[256]",                              "\"globalKeyBytes\":[-1]",
        "\"keyBytes\":[1.5]",                              "\"globalKeyBytes\":[true]",
    }) |fields| {
        const malformed = try std.fmt.allocPrint(ui.arena, "{{\"format\":2,\"nodes\":[{{\"end\":1,\"kind\":\"text\",\"text\":\"\",{s}}}]}}", .{fields});
        try std.testing.expectError(error.InvalidView, decode(&ui, malformed));
    }
}

pub fn testTerminalRecords() !void {
    if (comptime enabled) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = Ui.init(arena.allocator());
        for ([_][]const u8{
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"text\",\"text\":\"\",\"ptyBytes\":[115]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"terminal\",\"text\":\"authored\"}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"terminal\",\"text\":\"\",\"terminal\":255}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"terminal\",\"text\":\"\",\"pty\":9007199254740992}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"terminal\",\"text\":\"\",\"pty\":1,\"ptyBytes\":[115]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"terminal\",\"text\":\"\",\"ptyBytes\":[256]}]}",
            "{\"format\":2,\"nodes\":[{\"end\":1,\"kind\":\"terminal\",\"text\":\"\",\"scrollback\":4294967296}]}",
        }) |source| try std.testing.expectError(error.InvalidView, decode(&ui, source));
        inline for (@typeInfo(core.Msg).@"union".fields, 0..) |field, tag| {
            if (comptime !sdk.canvas.ui_markup_reflect.declaredTerminalStateRecord(field.type)) try std.testing.expectError(error.InvalidView, terminalEvent(tag));
        }
    } else return error.SkipZigTest;
}

test "compiled terminal records reject misplaced malformed and incompatible ownership channels" {
    try testTerminalRecords();
}

test "compiled grouped input records preserve complete owned primitive trees" {
    if (comptime enabled) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = Ui.init(arena.allocator());
        const bytes = try ui.arena.dupe(u8,
            \\{"format":2,"nodes":[{"end":4,"kind":"input_group","text":"","label":"Compose","width":360,"height":160},{"end":2,"kind":"textarea","text":"","textBytes":[67,0,255],"label":"Draft","borderColor":"accent"},{"end":4,"kind":"input_group_actions","text":"","gap":6},{"end":4,"kind":"button","text":"Send"}]}
        );
        const actual_node = try decode(&ui, bytes);
        @memset(bytes, 0);
        core.rt.frameReset();
        var reference = Ui.init(arena.allocator());
        const entry = reference.el(.textarea, .{ .text = "C\x00\xff", .semantics = .{ .label = "Draft" }, .style_tokens = .{ .border_color = .accent } }, .{});
        const expected_node = reference.inputGroup(.{ .width = 360, .height = 160, .semantics = .{ .label = "Compose" } }, entry, reference.inputGroupActions(.{}, .{reference.button(.{}, "Send")}));
        const expected_tree = try reference.finalize(compoundOwners(expected_node));
        const actual_tree = try ui.finalize(actual_node);
        try std.testing.expectEqualDeep(expected_tree.root, actual_tree.root);
        try std.testing.expectEqualDeep(expected_tree.handlers, actual_tree.handlers);
    } else return error.SkipZigTest;
}
fn compoundOwners(node_value: Ui.Node) Ui.Node {
    const result = stampCompound(node_value);
    for (@constCast(result.nodes)) |*child| child.* = compoundOwners(child.*);
    return result;
}

test "compiled grouped input refuses orphan actions invalid order and excess children" {
    if (comptime enabled) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = Ui.init(arena.allocator());
        for ([_][]const u8{
            \\{"format":2,"nodes":[{"end":1,"kind":"input_group_actions","text":""}]}
            ,
            \\{"format":2,"nodes":[{"end":1,"kind":"input_group","text":""}]}
            ,
            \\{"format":2,"nodes":[{"end":2,"kind":"input_group","text":""},{"end":2,"kind":"button","text":""}]}
            ,
            \\{"format":2,"nodes":[{"end":3,"kind":"input_group","text":""},{"end":2,"kind":"textarea","text":""},{"end":3,"kind":"button","text":""}]}
            ,
            \\{"format":2,"nodes":[{"end":4,"kind":"input_group","text":""},{"end":2,"kind":"textarea","text":""},{"end":3,"kind":"textarea","text":""},{"end":4,"kind":"input_group_actions","text":""}]}
            ,
        }) |invalid| try std.testing.expectError(error.InvalidView, decode(&ui, invalid));
    } else return error.SkipZigTest;
}

test "compiled app chart rejects misplaced metadata unbounded samples and invalid series records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "\"chartSeries\":[]",     "\"chartXLabels\":[]",     "\"chartYMin\":0",        "\"chartYMax\":0",
        "\"chartGridLines\":0",   "\"chartBaseline\":false", "\"chartYLabels\":false", "\"chartHoverDetails\":false",
        "\"chartStrokeWidth\":0",
    }) |fields| {
        var ui = Ui.init(arena.allocator());
        const bytes = try std.fmt.allocPrint(arena.allocator(), "{{\"format\":2,\"nodes\":[{{\"end\":1,\"kind\":\"column\",\"text\":\"\",{s}}}]}}", .{fields});
        try std.testing.expectError(error.InvalidView, decode(&ui, bytes));
    }
    for ([_][]const u8{
        "\"chartSeries\":[],\"chartXLabels\":[]",
        "\"chartSeries\":[{\"kind\":\"band\",\"values\":[],\"color\":\"accent\",\"fill\":false,\"label\":[]}],\"chartXLabels\":[]",
        "\"chartSeries\":[{\"kind\":\"bar\",\"values\":[null],\"color\":\"accent\",\"fill\":false,\"label\":[]}],\"chartXLabels\":[]",
        "\"chartSeries\":[{\"kind\":\"bar\",\"values\":[4294967296],\"color\":\"accent\",\"fill\":false,\"label\":[]}],\"chartXLabels\":[]",
        "\"chartSeries\":[{\"kind\":\"bar\",\"values\":[],\"color\":\"accent\",\"fill\":true,\"label\":[]}],\"chartXLabels\":[]",
        "\"chartSeries\":[{\"kind\":\"line\",\"values\":[],\"color\":\"accent\",\"fill\":false,\"label\":[256]}],\"chartXLabels\":[]",
    }) |fields| {
        var ui = Ui.init(arena.allocator());
        const bytes = try std.fmt.allocPrint(arena.allocator(), "{{\"format\":2,\"nodes\":[{{\"end\":1,\"kind\":\"chart\",\"text\":\"\",{s}}}]}}", .{fields});
        try std.testing.expectError(error.InvalidView, decode(&ui, bytes));
    }
    const values = try arena.allocator().alloc(u8, 2 * 257 - 1);
    for (values, 0..) |*byte, i| byte.* = if (i % 2 == 0) '0' else ',';
    var ui = Ui.init(arena.allocator());
    const bytes = try std.fmt.allocPrint(arena.allocator(), "{{\"format\":2,\"nodes\":[{{\"end\":1,\"kind\":\"chart\",\"text\":\"\",\"chartSeries\":[{{\"kind\":\"line\",\"values\":[{s}],\"color\":\"accent\",\"fill\":false,\"label\":[]}}],\"chartXLabels\":[]}}]}}", .{values});
    try std.testing.expectError(error.InvalidView, decode(&ui, bytes));
}
