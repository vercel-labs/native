const std = @import("std");
const geometry = @import("geometry");
const json = @import("json");

pub const Error = error{
    DisplayListFull,
    DiffListFull,
    DuplicateObjectId,
    RenderListFull,
    RenderStackOverflow,
    RenderStackUnderflow,
    WidgetDepthExceeded,
    WidgetLayoutListFull,
    WidgetSemanticsListFull,
};

pub const ObjectId = u64;
pub const ImageId = u64;
pub const FontId = u64;

pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn rgb8(r: u8, g: u8, b: u8) Color {
        return rgba8(r, g, b, 255);
    }

    pub fn rgba8(r: u8, g: u8, b: u8, a: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = @as(f32, @floatFromInt(a)) / 255.0,
        };
    }
};

pub const Affine = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    tx: f32 = 0,
    ty: f32 = 0,

    pub fn identity() Affine {
        return .{};
    }

    pub fn translate(x: f32, y: f32) Affine {
        return .{ .tx = x, .ty = y };
    }

    pub fn scale(x: f32, y: f32) Affine {
        return .{ .a = x, .d = y };
    }

    pub fn multiply(self: Affine, other: Affine) Affine {
        return .{
            .a = self.a * other.a + self.c * other.b,
            .b = self.b * other.a + self.d * other.b,
            .c = self.a * other.c + self.c * other.d,
            .d = self.b * other.c + self.d * other.d,
            .tx = self.a * other.tx + self.c * other.ty + self.tx,
            .ty = self.b * other.tx + self.d * other.ty + self.ty,
        };
    }

    pub fn transformPoint(self: Affine, point: geometry.PointF) geometry.PointF {
        return .{
            .x = self.a * point.x + self.c * point.y + self.tx,
            .y = self.b * point.x + self.d * point.y + self.ty,
        };
    }

    pub fn transformRect(self: Affine, rect: geometry.RectF) geometry.RectF {
        const normalized = rect.normalized();
        return boundsFromPoints(&.{
            self.transformPoint(normalized.topLeft()),
            self.transformPoint(normalized.topRight()),
            self.transformPoint(normalized.bottomLeft()),
            self.transformPoint(normalized.bottomRight()),
        }) orelse geometry.RectF.zero();
    }
};

pub const Radius = struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_right: f32 = 0,
    bottom_left: f32 = 0,

    pub fn all(value: f32) Radius {
        return .{
            .top_left = value,
            .top_right = value,
            .bottom_right = value,
            .bottom_left = value,
        };
    }
};

pub const GradientStop = struct {
    offset: f32,
    color: Color,
};

pub const LinearGradient = struct {
    start: geometry.PointF,
    end: geometry.PointF,
    stops: []const GradientStop = &.{},
};

pub const Fill = union(enum) {
    color: Color,
    linear_gradient: LinearGradient,
};

pub const Stroke = struct {
    fill: Fill,
    width: f32 = 1,
};

pub const Clip = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    radius: Radius = .{},
};

pub const FillRect = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    fill: Fill,
};

pub const StrokeRect = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    radius: Radius = .{},
    stroke: Stroke,
};

pub const FillRoundedRect = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    radius: Radius,
    fill: Fill,
};

pub const Line = struct {
    id: ObjectId = 0,
    from: geometry.PointF,
    to: geometry.PointF,
    stroke: Stroke,
};

pub const PathVerb = enum {
    move_to,
    line_to,
    quad_to,
    cubic_to,
    close,
};

pub const PathElement = struct {
    verb: PathVerb,
    points: [3]geometry.PointF = [_]geometry.PointF{geometry.PointF.zero()} ** 3,
};

pub const FillPath = struct {
    id: ObjectId = 0,
    elements: []const PathElement = &.{},
    fill: Fill,
};

pub const StrokePath = struct {
    id: ObjectId = 0,
    elements: []const PathElement = &.{},
    stroke: Stroke,
};

pub const ImageFit = enum {
    stretch,
    contain,
    cover,
};

pub const DrawImage = struct {
    id: ObjectId = 0,
    image_id: ImageId,
    src: ?geometry.RectF = null,
    dst: geometry.RectF,
    opacity: f32 = 1,
    fit: ImageFit = .stretch,
};

pub const Glyph = struct {
    id: u32,
    x: f32,
    y: f32,
    advance: f32 = 0,
};

pub const DrawText = struct {
    id: ObjectId = 0,
    font_id: FontId = 0,
    size: f32,
    origin: geometry.PointF,
    color: Color,
    text: []const u8 = "",
    glyphs: []const Glyph = &.{},
};

pub const Shadow = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    radius: Radius = .{},
    offset: geometry.OffsetF = .{},
    blur: f32 = 0,
    spread: f32 = 0,
    color: Color,
};

pub const Blur = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    radius: f32 = 0,
};

pub const CanvasCommand = union(enum) {
    push_clip: Clip,
    pop_clip,
    push_opacity: f32,
    pop_opacity,
    transform: Affine,
    fill_rect: FillRect,
    stroke_rect: StrokeRect,
    fill_rounded_rect: FillRoundedRect,
    draw_line: Line,
    fill_path: FillPath,
    stroke_path: StrokePath,
    draw_image: DrawImage,
    draw_text: DrawText,
    shadow: Shadow,
    blur: Blur,

    pub fn objectId(self: CanvasCommand) ?ObjectId {
        const id = switch (self) {
            .push_clip => |value| value.id,
            .fill_rect => |value| value.id,
            .stroke_rect => |value| value.id,
            .fill_rounded_rect => |value| value.id,
            .draw_line => |value| value.id,
            .fill_path => |value| value.id,
            .stroke_path => |value| value.id,
            .draw_image => |value| value.id,
            .draw_text => |value| value.id,
            .shadow => |value| value.id,
            .blur => |value| value.id,
            .pop_clip, .push_opacity, .pop_opacity, .transform => 0,
        };
        return if (id == 0) null else id;
    }

    pub fn bounds(self: CanvasCommand) ?geometry.RectF {
        return switch (self) {
            .push_clip => |value| value.rect.normalized(),
            .pop_clip, .push_opacity, .pop_opacity, .transform => null,
            .fill_rect => |value| value.rect.normalized(),
            .stroke_rect => |value| strokeBounds(value.rect, value.stroke.width),
            .fill_rounded_rect => |value| value.rect.normalized(),
            .draw_line => |value| strokeBounds(geometry.RectF.fromPoints(value.from, value.to), value.stroke.width),
            .fill_path => |value| pathBounds(value.elements),
            .stroke_path => |value| if (pathBounds(value.elements)) |rect| strokeBounds(rect, value.stroke.width) else null,
            .draw_image => |value| value.dst.normalized(),
            .draw_text => |value| textBounds(value),
            .shadow => |value| shadowBounds(value),
            .blur => |value| value.rect.normalized().inflate(geometry.InsetsF.all(nonNegative(value.radius))),
        };
    }
};

pub const CommandRef = struct {
    index: usize,
    command: CanvasCommand,
};

pub const DiffKind = enum {
    added,
    removed,
    changed,
    scene_changed,
};

pub const DiffChange = struct {
    kind: DiffKind,
    id: ?ObjectId = null,
    previous_index: ?usize = null,
    next_index: ?usize = null,
    dirty_bounds: ?geometry.RectF = null,
};

pub const max_render_state_stack: usize = 32;

pub const RenderState = struct {
    opacity: f32 = 1,
    clip: ?geometry.RectF = null,
    transform: Affine = .{},
};

pub const RenderCommand = struct {
    command: CanvasCommand,
    id: ?ObjectId = null,
    opacity: f32 = 1,
    clip: ?geometry.RectF = null,
    bounds: geometry.RectF,
};

pub const RenderPlan = struct {
    commands: []const RenderCommand = &.{},
    bounds: ?geometry.RectF = null,

    pub fn commandCount(self: RenderPlan) usize {
        return self.commands.len;
    }
};

pub const Density = enum {
    compact,
    regular,
    spacious,
};

pub const Easing = enum {
    linear,
    standard,
    emphasized,
    spring,
};

pub const ColorTokens = struct {
    background: Color = Color.rgb8(255, 255, 255),
    surface: Color = Color.rgb8(255, 255, 255),
    surface_subtle: Color = Color.rgb8(248, 250, 252),
    surface_pressed: Color = Color.rgb8(241, 245, 249),
    text: Color = Color.rgb8(15, 23, 42),
    text_muted: Color = Color.rgb8(100, 116, 139),
    border: Color = Color.rgba8(15, 23, 42, 28),
    accent: Color = Color.rgb8(24, 24, 27),
    accent_text: Color = Color.rgb8(255, 255, 255),
    focus_ring: Color = Color.rgb8(37, 99, 235),
    shadow: Color = Color.rgba8(15, 23, 42, 38),
    disabled: Color = Color.rgb8(226, 232, 240),
};

pub const TypographyTokens = struct {
    font_id: FontId = 0,
    body_size: f32 = 14,
    label_size: f32 = 12,
    title_size: f32 = 20,
    button_size: f32 = 14,
};

pub const SpacingTokens = struct {
    xs: f32 = 4,
    sm: f32 = 8,
    md: f32 = 12,
    lg: f32 = 16,
    xl: f32 = 24,
};

pub const RadiusTokens = struct {
    sm: f32 = 4,
    md: f32 = 6,
    lg: f32 = 8,
    xl: f32 = 12,
};

pub const StrokeTokens = struct {
    hairline: f32 = 1,
    regular: f32 = 1,
    focus: f32 = 2,
};

pub const ShadowToken = struct {
    y: f32 = 8,
    blur: f32 = 24,
    spread: f32 = -10,
};

pub const ShadowTokens = struct {
    none: ShadowToken = .{ .y = 0, .blur = 0, .spread = 0 },
    sm: ShadowToken = .{ .y = 6, .blur = 16, .spread = -8 },
    md: ShadowToken = .{ .y = 14, .blur = 36, .spread = -16 },
};

pub const BlurTokens = struct {
    none: f32 = 0,
    sm: f32 = 8,
    md: f32 = 16,
};

pub const MotionTokens = struct {
    fast_ms: u32 = 120,
    normal_ms: u32 = 180,
    slow_ms: u32 = 260,
    easing: Easing = .standard,
    spring: SpringToken = .{},
};

pub const SpringToken = struct {
    mass: f32 = 1,
    stiffness: f32 = 220,
    damping: f32 = 28,
};

pub const LayerTokens = struct {
    base: i32 = 0,
    floating: i32 = 100,
    overlay: i32 = 200,
    modal: i32 = 300,
};

pub const DesignTokens = struct {
    colors: ColorTokens = .{},
    typography: TypographyTokens = .{},
    spacing: SpacingTokens = .{},
    radius: RadiusTokens = .{},
    stroke: StrokeTokens = .{},
    shadow: ShadowTokens = .{},
    blur: BlurTokens = .{},
    motion: MotionTokens = .{},
    layer: LayerTokens = .{},
    density: Density = .regular,
};

pub const WidgetKind = enum {
    stack,
    row,
    column,
    panel,
    text,
    button,
    progress,
};

pub const WidgetState = struct {
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,
    disabled: bool = false,
    selected: bool = false,
};

pub const WidgetLayoutStyle = struct {
    padding: geometry.InsetsF = .{},
    gap: f32 = 0,
    grow: f32 = 0,
    min_size: geometry.SizeF = .{},
};

pub const WidgetRole = enum {
    none,
    group,
    text,
    button,
    progressbar,
};

pub const WidgetSemantics = struct {
    role: WidgetRole = .none,
    label: []const u8 = "",
    value: ?f32 = null,
    hidden: bool = false,
    focusable: bool = false,
};

pub const Widget = struct {
    id: ObjectId = 0,
    kind: WidgetKind,
    frame: geometry.RectF = .{},
    text: []const u8 = "",
    value: f32 = 0,
    state: WidgetState = .{},
    layout: WidgetLayoutStyle = .{},
    semantics: WidgetSemantics = .{},
    children: []const Widget = &.{},
};

pub const max_widget_depth: usize = 32;

pub const WidgetLayoutNode = struct {
    widget: Widget,
    frame: geometry.RectF,
    depth: usize,
    parent_index: ?usize = null,
};

pub const WidgetHit = struct {
    id: ObjectId,
    kind: WidgetKind,
    bounds: geometry.RectF,
    depth: usize,
    index: usize,
    state: WidgetState,
};

pub const WidgetSemanticsNode = struct {
    id: ObjectId,
    role: WidgetRole,
    label: []const u8,
    value: ?f32 = null,
    bounds: geometry.RectF,
    state: WidgetState,
    focusable: bool = false,
    parent_index: ?usize = null,
};

pub const WidgetLayoutTree = struct {
    nodes: []const WidgetLayoutNode = &.{},

    pub fn nodeCount(self: WidgetLayoutTree) usize {
        return self.nodes.len;
    }

    pub fn findById(self: WidgetLayoutTree, id: ObjectId) ?WidgetLayoutNode {
        if (id == 0) return null;
        for (self.nodes) |node| {
            if (node.widget.id == id) return node;
        }
        return null;
    }

    pub fn hitTest(self: WidgetLayoutTree, point: geometry.PointF) ?WidgetHit {
        return hitTestWidgetLayout(self, point);
    }

    pub fn collectSemantics(self: WidgetLayoutTree, output: []WidgetSemanticsNode) Error![]const WidgetSemanticsNode {
        return collectWidgetSemantics(self, output);
    }

    pub fn emitDisplayList(self: WidgetLayoutTree, builder: *Builder, tokens: DesignTokens) Error!void {
        return emitWidgetLayout(builder, self, tokens);
    }
};

pub const DisplayList = struct {
    commands: []const CanvasCommand = &.{},

    pub fn writeJson(self: DisplayList, writer: anytype) !void {
        try writer.writeAll("{\"commands\":[");
        for (self.commands, 0..) |command, index| {
            if (index > 0) try writer.writeByte(',');
            try writeCommandJson(command, writer);
        }
        try writer.writeAll("]}");
    }

    pub fn commandCount(self: DisplayList) usize {
        return self.commands.len;
    }

    pub fn findCommandById(self: DisplayList, id: ObjectId) ?CommandRef {
        if (id == 0) return null;
        for (self.commands, 0..) |command, index| {
            if (command.objectId()) |command_id| {
                if (command_id == id) return .{ .index = index, .command = command };
            }
        }
        return null;
    }

    pub fn bounds(self: DisplayList) ?geometry.RectF {
        var result: ?geometry.RectF = null;
        for (self.commands) |command| {
            if (command.bounds()) |command_bounds| {
                result = unionOptionalBounds(result, command_bounds);
            }
        }
        return result;
    }

    pub fn diff(previous: DisplayList, next: DisplayList, output: []DiffChange) Error![]const DiffChange {
        return diffDisplayLists(previous, next, output);
    }

    pub fn renderPlan(self: DisplayList, output: []RenderCommand) Error!RenderPlan {
        var planner = RenderPlanner.init(output);
        return planner.build(self);
    }
};

pub const Builder = struct {
    commands: []CanvasCommand,
    len: usize = 0,

    pub fn init(commands: []CanvasCommand) Builder {
        return .{ .commands = commands };
    }

    pub fn reset(self: *Builder) void {
        self.len = 0;
    }

    pub fn displayList(self: *const Builder) DisplayList {
        return .{ .commands = self.commands[0..self.len] };
    }

    pub fn append(self: *Builder, command: CanvasCommand) Error!void {
        if (self.len >= self.commands.len) return error.DisplayListFull;
        self.commands[self.len] = command;
        self.len += 1;
    }

    pub fn pushClip(self: *Builder, clip: Clip) Error!void {
        try self.append(.{ .push_clip = clip });
    }

    pub fn popClip(self: *Builder) Error!void {
        try self.append(.pop_clip);
    }

    pub fn pushOpacity(self: *Builder, opacity: f32) Error!void {
        try self.append(.{ .push_opacity = opacity });
    }

    pub fn popOpacity(self: *Builder) Error!void {
        try self.append(.pop_opacity);
    }

    pub fn transform(self: *Builder, value: Affine) Error!void {
        try self.append(.{ .transform = value });
    }

    pub fn fillRect(self: *Builder, value: FillRect) Error!void {
        try self.append(.{ .fill_rect = value });
    }

    pub fn strokeRect(self: *Builder, value: StrokeRect) Error!void {
        try self.append(.{ .stroke_rect = value });
    }

    pub fn fillRoundedRect(self: *Builder, value: FillRoundedRect) Error!void {
        try self.append(.{ .fill_rounded_rect = value });
    }

    pub fn drawLine(self: *Builder, value: Line) Error!void {
        try self.append(.{ .draw_line = value });
    }

    pub fn fillPath(self: *Builder, value: FillPath) Error!void {
        try self.append(.{ .fill_path = value });
    }

    pub fn strokePath(self: *Builder, value: StrokePath) Error!void {
        try self.append(.{ .stroke_path = value });
    }

    pub fn drawImage(self: *Builder, value: DrawImage) Error!void {
        try self.append(.{ .draw_image = value });
    }

    pub fn drawText(self: *Builder, value: DrawText) Error!void {
        try self.append(.{ .draw_text = value });
    }

    pub fn shadow(self: *Builder, value: Shadow) Error!void {
        try self.append(.{ .shadow = value });
    }

    pub fn blur(self: *Builder, value: Blur) Error!void {
        try self.append(.{ .blur = value });
    }
};

pub fn emitWidgetTree(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    try emitWidgetDepth(builder, widget, tokens, 0);
}

pub fn layoutWidgetTree(widget: Widget, bounds: geometry.RectF, output: []WidgetLayoutNode) Error!WidgetLayoutTree {
    var len: usize = 0;
    _ = try layoutWidgetDepth(widget, bounds.normalized(), null, 0, output, &len);
    return .{ .nodes = output[0..len] };
}

pub fn emitWidgetLayout(builder: *Builder, layout: WidgetLayoutTree, tokens: DesignTokens) Error!void {
    for (layout.nodes) |node| {
        const widget = widgetWithFrame(node.widget, node.frame);
        switch (widget.kind) {
            .stack, .row, .column => {},
            .panel => try emitPanelWidgetChrome(builder, widget, tokens),
            .text => try emitTextWidget(builder, widget, tokens),
            .button => try emitButtonWidget(builder, widget, tokens),
            .progress => try emitProgressWidget(builder, widget, tokens),
        }
    }
}

pub const RenderPlanner = struct {
    commands: []RenderCommand,
    len: usize = 0,
    state: RenderState = .{},
    bounds_value: ?geometry.RectF = null,
    clip_stack: [max_render_state_stack]?geometry.RectF = undefined,
    clip_stack_len: usize = 0,
    opacity_stack: [max_render_state_stack]f32 = undefined,
    opacity_stack_len: usize = 0,

    pub fn init(commands: []RenderCommand) RenderPlanner {
        return .{ .commands = commands };
    }

    pub fn reset(self: *RenderPlanner) void {
        self.len = 0;
        self.state = .{};
        self.bounds_value = null;
        self.clip_stack_len = 0;
        self.opacity_stack_len = 0;
    }

    pub fn build(self: *RenderPlanner, display_list: DisplayList) Error!RenderPlan {
        self.reset();
        for (display_list.commands) |command| {
            try self.consume(command);
        }
        return .{
            .commands = self.commands[0..self.len],
            .bounds = self.bounds_value,
        };
    }

    fn consume(self: *RenderPlanner, command: CanvasCommand) Error!void {
        switch (command) {
            .push_clip => |clip| try self.pushClip(clip),
            .pop_clip => try self.popClip(),
            .push_opacity => |opacity| try self.pushOpacity(opacity),
            .pop_opacity => try self.popOpacity(),
            .transform => |transform| self.state.transform = self.state.transform.multiply(transform),
            else => try self.appendDrawCommand(command),
        }
    }

    fn pushClip(self: *RenderPlanner, clip: Clip) Error!void {
        if (self.clip_stack_len >= self.clip_stack.len) return error.RenderStackOverflow;
        self.clip_stack[self.clip_stack_len] = self.state.clip;
        self.clip_stack_len += 1;

        const transformed_clip = self.state.transform.transformRect(clip.rect);
        self.state.clip = if (self.state.clip) |existing|
            geometry.RectF.intersection(existing, transformed_clip)
        else
            transformed_clip;
    }

    fn popClip(self: *RenderPlanner) Error!void {
        if (self.clip_stack_len == 0) return error.RenderStackUnderflow;
        self.clip_stack_len -= 1;
        self.state.clip = self.clip_stack[self.clip_stack_len];
    }

    fn pushOpacity(self: *RenderPlanner, opacity: f32) Error!void {
        if (self.opacity_stack_len >= self.opacity_stack.len) return error.RenderStackOverflow;
        self.opacity_stack[self.opacity_stack_len] = self.state.opacity;
        self.opacity_stack_len += 1;
        self.state.opacity *= std.math.clamp(opacity, 0, 1);
    }

    fn popOpacity(self: *RenderPlanner) Error!void {
        if (self.opacity_stack_len == 0) return error.RenderStackUnderflow;
        self.opacity_stack_len -= 1;
        self.state.opacity = self.opacity_stack[self.opacity_stack_len];
    }

    fn appendDrawCommand(self: *RenderPlanner, command: CanvasCommand) Error!void {
        if (self.state.opacity <= 0) return;
        const command_bounds = command.bounds() orelse return;
        const transformed_bounds = self.state.transform.transformRect(command_bounds);
        const clipped_bounds = if (self.state.clip) |clip|
            geometry.RectF.intersection(clip, transformed_bounds)
        else
            transformed_bounds;
        if (clipped_bounds.isEmpty()) return;
        if (self.len >= self.commands.len) return error.RenderListFull;

        self.commands[self.len] = .{
            .command = command,
            .id = command.objectId(),
            .opacity = self.state.opacity,
            .clip = self.state.clip,
            .bounds = clipped_bounds,
        };
        self.len += 1;
        self.bounds_value = unionOptionalBounds(self.bounds_value, clipped_bounds);
    }
};

fn emitWidgetDepth(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    if (depth >= max_widget_depth) return error.WidgetDepthExceeded;

    switch (widget.kind) {
        .stack, .row, .column => try emitWidgetChildren(builder, widget.children, tokens, depth),
        .panel => try emitPanelWidget(builder, widget, tokens, depth),
        .text => try emitTextWidget(builder, widget, tokens),
        .button => try emitButtonWidget(builder, widget, tokens),
        .progress => try emitProgressWidget(builder, widget, tokens),
    }
}

fn emitWidgetChildren(builder: *Builder, children: []const Widget, tokens: DesignTokens, depth: usize) Error!void {
    for (children) |child| {
        try emitWidgetDepth(builder, child, tokens, depth + 1);
    }
}

fn emitPanelWidget(builder: *Builder, widget: Widget, tokens: DesignTokens, depth: usize) Error!void {
    try emitPanelWidgetChrome(builder, widget, tokens);
    try emitWidgetChildren(builder, widget.children, tokens, depth);
}

fn emitPanelWidgetChrome(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const radius = Radius.all(tokens.radius.lg);
    const shadow_token = tokens.shadow.sm;
    if (shadow_token.y != 0 or shadow_token.blur != 0 or shadow_token.spread != 0) {
        try builder.shadow(.{
            .id = widgetPartId(widget.id, 1),
            .rect = widget.frame,
            .radius = radius,
            .offset = .{ .dx = 0, .dy = shadow_token.y },
            .blur = shadow_token.blur,
            .spread = shadow_token.spread,
            .color = tokens.colors.shadow,
        });
    }

    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .fill = .{ .color = tokens.colors.surface },
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 3),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = .{ .color = tokens.colors.border },
            .width = tokens.stroke.hairline,
        },
    });
}

fn emitTextWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 1),
        .font_id = tokens.typography.font_id,
        .size = tokens.typography.body_size,
        .origin = textOrigin(widget.frame, tokens.typography.body_size, 0),
        .color = if (widget.state.disabled) tokens.colors.text_muted else tokens.colors.text,
        .text = widget.text,
    });
}

fn emitButtonWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const radius = Radius.all(tokens.radius.md);
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = .{ .color = buttonFillColor(tokens, widget.state) },
    });
    try builder.strokeRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = widget.frame,
        .radius = radius,
        .stroke = .{
            .fill = .{ .color = tokens.colors.border },
            .width = tokens.stroke.regular,
        },
    });
    if (widget.state.focused) {
        try builder.strokeRect(.{
            .id = widgetPartId(widget.id, 3),
            .rect = widget.frame,
            .radius = radius,
            .stroke = .{
                .fill = .{ .color = tokens.colors.focus_ring },
                .width = tokens.stroke.focus,
            },
        });
    }
    try builder.drawText(.{
        .id = widgetPartId(widget.id, 4),
        .font_id = tokens.typography.font_id,
        .size = tokens.typography.button_size,
        .origin = textOrigin(widget.frame, tokens.typography.button_size, tokens.spacing.md),
        .color = buttonTextColor(tokens, widget.state),
        .text = widget.text,
    });
}

fn emitProgressWidget(builder: *Builder, widget: Widget, tokens: DesignTokens) Error!void {
    const radius = Radius.all(@min(tokens.radius.md, widget.frame.height * 0.5));
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 1),
        .rect = widget.frame,
        .radius = radius,
        .fill = .{ .color = tokens.colors.surface_pressed },
    });
    try builder.fillRoundedRect(.{
        .id = widgetPartId(widget.id, 2),
        .rect = geometry.RectF.init(widget.frame.x, widget.frame.y, widget.frame.width * std.math.clamp(widget.value, 0, 1), widget.frame.height),
        .radius = radius,
        .fill = .{ .color = tokens.colors.accent },
    });
}

fn widgetPartId(id: ObjectId, slot: ObjectId) ObjectId {
    if (id == 0) return 0;
    const base = id *% 16;
    const part = base +% slot;
    return if (part == 0) id else part;
}

fn textOrigin(frame: geometry.RectF, size: f32, inset: f32) geometry.PointF {
    return geometry.PointF.init(
        frame.x + inset,
        frame.y + @max(size, (frame.height + size * 0.5) * 0.5),
    );
}

fn buttonFillColor(tokens: DesignTokens, state: WidgetState) Color {
    if (state.disabled) return tokens.colors.disabled;
    if (state.pressed or state.selected) return tokens.colors.accent;
    if (state.hovered) return tokens.colors.surface_subtle;
    return tokens.colors.surface;
}

fn buttonTextColor(tokens: DesignTokens, state: WidgetState) Color {
    if (state.disabled) return tokens.colors.text_muted;
    if (state.pressed or state.selected) return tokens.colors.accent_text;
    return tokens.colors.text;
}

fn layoutWidgetDepth(
    widget: Widget,
    frame: geometry.RectF,
    parent_index: ?usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
) Error!usize {
    if (depth >= max_widget_depth) return error.WidgetDepthExceeded;
    if (len.* >= output.len) return error.WidgetLayoutListFull;

    const index = len.*;
    output[index] = .{
        .widget = widgetWithFrame(widget, frame),
        .frame = frame,
        .depth = depth,
        .parent_index = parent_index,
    };
    len.* += 1;

    const content = frame.inset(widget.layout.padding);
    switch (widget.kind) {
        .row => try layoutAxisChildren(widget.children, content, .horizontal, index, depth, output, len, widget.layout.gap),
        .column => try layoutAxisChildren(widget.children, content, .vertical, index, depth, output, len, widget.layout.gap),
        .stack, .panel => {
            for (widget.children) |child| {
                _ = try layoutWidgetDepth(child, stackChildFrame(content, child), index, depth + 1, output, len);
            }
        },
        .text, .button, .progress => {},
    }

    return index;
}

const LayoutAxis = enum {
    horizontal,
    vertical,
};

fn layoutAxisChildren(
    children: []const Widget,
    content: geometry.RectF,
    axis: LayoutAxis,
    parent_index: usize,
    depth: usize,
    output: []WidgetLayoutNode,
    len: *usize,
    gap: f32,
) Error!void {
    if (children.len == 0) return;

    const available_extent = switch (axis) {
        .horizontal => content.width,
        .vertical => content.height,
    };
    const cross_extent = switch (axis) {
        .horizontal => content.height,
        .vertical => content.width,
    };
    const clamped_gap = nonNegative(gap);
    const total_gap = clamped_gap * @as(f32, @floatFromInt(children.len - 1));
    var fixed_extent: f32 = 0;
    var grow_total: f32 = 0;
    for (children) |child| {
        const grow = nonNegative(child.layout.grow);
        if (grow > 0) {
            grow_total += grow;
        } else {
            fixed_extent += preferredMainExtent(child, axis);
        }
    }

    const remaining = @max(0, available_extent - fixed_extent - total_gap);
    var cursor: f32 = switch (axis) {
        .horizontal => content.x,
        .vertical => content.y,
    };

    for (children) |child| {
        const grow = nonNegative(child.layout.grow);
        const main_extent = if (grow > 0 and grow_total > 0)
            @max(minMainExtent(child, axis), remaining * grow / grow_total)
        else
            preferredMainExtent(child, axis);
        const cross = preferredCrossExtent(child, axis, cross_extent);
        const child_frame = switch (axis) {
            .horizontal => geometry.RectF.init(cursor, content.y + child.frame.y, main_extent, cross),
            .vertical => geometry.RectF.init(content.x + child.frame.x, cursor, cross, main_extent),
        };
        _ = try layoutWidgetDepth(child, child_frame, parent_index, depth + 1, output, len);
        cursor += main_extent + clamped_gap;
    }
}

fn stackChildFrame(content: geometry.RectF, child: Widget) geometry.RectF {
    const width = if (child.frame.width > 0) child.frame.width else content.width;
    const height = if (child.frame.height > 0) child.frame.height else content.height;
    return geometry.RectF.init(
        content.x + child.frame.x,
        content.y + child.frame.y,
        @max(child.layout.min_size.width, width),
        @max(child.layout.min_size.height, height),
    );
}

fn preferredMainExtent(widget: Widget, axis: LayoutAxis) f32 {
    const value = switch (axis) {
        .horizontal => widget.frame.width,
        .vertical => widget.frame.height,
    };
    return @max(minMainExtent(widget, axis), nonNegative(value));
}

fn preferredCrossExtent(widget: Widget, axis: LayoutAxis, available: f32) f32 {
    const value = switch (axis) {
        .horizontal => widget.frame.height,
        .vertical => widget.frame.width,
    };
    const min_value = switch (axis) {
        .horizontal => widget.layout.min_size.height,
        .vertical => widget.layout.min_size.width,
    };
    return @max(min_value, if (value > 0) value else available);
}

fn minMainExtent(widget: Widget, axis: LayoutAxis) f32 {
    return switch (axis) {
        .horizontal => nonNegative(widget.layout.min_size.width),
        .vertical => nonNegative(widget.layout.min_size.height),
    };
}

fn hitTestWidgetLayout(layout: WidgetLayoutTree, point: geometry.PointF) ?WidgetHit {
    var index = layout.nodes.len;
    while (index > 0) {
        index -= 1;
        const node = layout.nodes[index];
        if (!isHitTarget(node.widget)) continue;
        if (!node.frame.normalized().containsPoint(point)) continue;
        return .{
            .id = node.widget.id,
            .kind = node.widget.kind,
            .bounds = node.frame,
            .depth = node.depth,
            .index = index,
            .state = node.widget.state,
        };
    }
    return null;
}

fn collectWidgetSemantics(layout: WidgetLayoutTree, output: []WidgetSemanticsNode) Error![]const WidgetSemanticsNode {
    var len: usize = 0;
    var semantic_stack: [max_widget_depth]?usize = [_]?usize{null} ** max_widget_depth;

    for (layout.nodes) |node| {
        if (node.depth >= max_widget_depth) return error.WidgetDepthExceeded;
        var cursor = node.depth + 1;
        while (cursor < semantic_stack.len) : (cursor += 1) {
            semantic_stack[cursor] = null;
        }

        const role = semanticRole(node.widget);
        if (node.widget.semantics.hidden or role == .none or node.widget.id == 0) continue;
        if (len >= output.len) return error.WidgetSemanticsListFull;

        const parent_index = nearestSemanticParent(semantic_stack[0..node.depth]);
        output[len] = .{
            .id = node.widget.id,
            .role = role,
            .label = semanticLabel(node.widget),
            .value = semanticValue(node.widget),
            .bounds = node.frame,
            .state = node.widget.state,
            .focusable = node.widget.semantics.focusable or defaultFocusable(node.widget),
            .parent_index = parent_index,
        };
        semantic_stack[node.depth] = len;
        len += 1;
    }

    return output[0..len];
}

fn nearestSemanticParent(stack: []const ?usize) ?usize {
    var index = stack.len;
    while (index > 0) {
        index -= 1;
        if (stack[index]) |semantic_index| return semantic_index;
    }
    return null;
}

fn semanticRole(widget: Widget) WidgetRole {
    if (widget.semantics.role != .none) return widget.semantics.role;
    return switch (widget.kind) {
        .stack, .row, .column, .panel => .group,
        .text => .text,
        .button => .button,
        .progress => .progressbar,
    };
}

fn semanticLabel(widget: Widget) []const u8 {
    if (widget.semantics.label.len > 0) return widget.semantics.label;
    return widget.text;
}

fn semanticValue(widget: Widget) ?f32 {
    if (widget.semantics.value) |value| return value;
    return switch (widget.kind) {
        .progress => widget.value,
        else => null,
    };
}

fn defaultFocusable(widget: Widget) bool {
    return switch (widget.kind) {
        .button => !widget.state.disabled,
        else => false,
    };
}

fn isHitTarget(widget: Widget) bool {
    if (widget.id == 0 or widget.state.disabled) return false;
    return switch (widget.kind) {
        .row, .column, .stack => false,
        .panel, .text, .button, .progress => true,
    };
}

fn widgetWithFrame(widget: Widget, frame: geometry.RectF) Widget {
    var copy = widget;
    copy.frame = frame;
    return copy;
}

fn diffDisplayLists(previous: DisplayList, next: DisplayList, output: []DiffChange) Error![]const DiffChange {
    try validateUniqueObjectIds(previous);
    try validateUniqueObjectIds(next);

    var len: usize = 0;
    if (!unkeyedCommandsEqual(previous, next)) {
        try appendDiffChange(output, &len, .{
            .kind = .scene_changed,
            .dirty_bounds = unionOptionalBounds(previous.bounds(), next.bounds()),
        });
    }

    for (previous.commands, 0..) |previous_command, previous_index| {
        const id = previous_command.objectId() orelse continue;
        const next_ref = next.findCommandById(id) orelse {
            try appendDiffChange(output, &len, .{
                .kind = .removed,
                .id = id,
                .previous_index = previous_index,
                .dirty_bounds = previous_command.bounds(),
            });
            continue;
        };

        if (previous_index != next_ref.index or !commandsEqual(previous_command, next_ref.command)) {
            try appendDiffChange(output, &len, .{
                .kind = .changed,
                .id = id,
                .previous_index = previous_index,
                .next_index = next_ref.index,
                .dirty_bounds = unionOptionalBounds(previous_command.bounds(), next_ref.command.bounds()),
            });
        }
    }

    for (next.commands, 0..) |next_command, next_index| {
        const id = next_command.objectId() orelse continue;
        if (previous.findCommandById(id) == null) {
            try appendDiffChange(output, &len, .{
                .kind = .added,
                .id = id,
                .next_index = next_index,
                .dirty_bounds = next_command.bounds(),
            });
        }
    }

    return output[0..len];
}

fn appendDiffChange(output: []DiffChange, len: *usize, change: DiffChange) Error!void {
    if (len.* >= output.len) return error.DiffListFull;
    output[len.*] = change;
    len.* += 1;
}

fn validateUniqueObjectIds(display_list: DisplayList) Error!void {
    for (display_list.commands, 0..) |command, index| {
        const id = command.objectId() orelse continue;
        var cursor = index + 1;
        while (cursor < display_list.commands.len) : (cursor += 1) {
            if (display_list.commands[cursor].objectId()) |other_id| {
                if (other_id == id) return error.DuplicateObjectId;
            }
        }
    }
}

fn unkeyedCommandsEqual(previous: DisplayList, next: DisplayList) bool {
    var previous_index: usize = 0;
    var next_index: usize = 0;
    while (true) {
        const previous_command = nextUnkeyedCommand(previous, &previous_index);
        const next_command = nextUnkeyedCommand(next, &next_index);
        if (previous_command == null and next_command == null) return true;
        if (previous_command == null or next_command == null) return false;
        if (!commandsEqual(previous_command.?, next_command.?)) return false;
    }
}

fn nextUnkeyedCommand(display_list: DisplayList, index: *usize) ?CanvasCommand {
    while (index.* < display_list.commands.len) : (index.* += 1) {
        const command = display_list.commands[index.*];
        if (command.objectId() == null) {
            index.* += 1;
            return command;
        }
    }
    return null;
}

fn unionOptionalBounds(a: ?geometry.RectF, b: ?geometry.RectF) ?geometry.RectF {
    if (a) |rect_a| {
        if (b) |rect_b| return geometry.RectF.unionWith(rect_a.normalized(), rect_b.normalized());
        return rect_a.normalized();
    }
    if (b) |rect_b| return rect_b.normalized();
    return null;
}

fn boundsFromPoints(points: []const geometry.PointF) ?geometry.RectF {
    if (points.len == 0) return null;
    var min_x = points[0].x;
    var min_y = points[0].y;
    var max_x = points[0].x;
    var max_y = points[0].y;
    for (points[1..]) |point| {
        min_x = @min(min_x, point.x);
        min_y = @min(min_y, point.y);
        max_x = @max(max_x, point.x);
        max_y = @max(max_y, point.y);
    }
    return geometry.RectF.init(min_x, min_y, max_x - min_x, max_y - min_y);
}

fn strokeBounds(rect: geometry.RectF, width: f32) geometry.RectF {
    return rect.normalized().inflate(geometry.InsetsF.all(nonNegative(width) * 0.5));
}

fn shadowBounds(value: Shadow) geometry.RectF {
    const spread = nonNegative(@abs(value.spread));
    const blur_radius = nonNegative(value.blur);
    return value.rect
        .normalized()
        .translate(value.offset)
        .inflate(geometry.InsetsF.all(spread + blur_radius));
}

fn pathBounds(elements: []const PathElement) ?geometry.RectF {
    var has_point = false;
    var min_x: f32 = 0;
    var min_y: f32 = 0;
    var max_x: f32 = 0;
    var max_y: f32 = 0;
    for (elements) |element| {
        const point_count: usize = switch (element.verb) {
            .move_to, .line_to => 1,
            .quad_to => 2,
            .cubic_to => 3,
            .close => 0,
        };
        for (element.points[0..point_count]) |point| {
            if (!has_point) {
                has_point = true;
                min_x = point.x;
                min_y = point.y;
                max_x = point.x;
                max_y = point.y;
            } else {
                min_x = @min(min_x, point.x);
                min_y = @min(min_y, point.y);
                max_x = @max(max_x, point.x);
                max_y = @max(max_y, point.y);
            }
        }
    }
    if (!has_point) return null;
    return geometry.RectF.init(min_x, min_y, max_x - min_x, max_y - min_y);
}

fn textBounds(value: DrawText) ?geometry.RectF {
    if (value.glyphs.len == 0 and value.text.len == 0) return null;

    var min_x = value.origin.x;
    var max_x = value.origin.x;
    if (value.glyphs.len > 0) {
        min_x = value.origin.x + value.glyphs[0].x;
        max_x = min_x + estimatedGlyphAdvance(value.glyphs[0], value.size);
        for (value.glyphs[1..]) |glyph| {
            const glyph_x = value.origin.x + glyph.x;
            min_x = @min(min_x, glyph_x);
            max_x = @max(max_x, glyph_x + estimatedGlyphAdvance(glyph, value.size));
        }
    } else {
        max_x = value.origin.x + @as(f32, @floatFromInt(value.text.len)) * value.size * 0.5;
    }

    return geometry.RectF.init(
        min_x,
        value.origin.y - value.size,
        @max(value.size * 0.25, max_x - min_x),
        value.size * 1.25,
    );
}

fn estimatedGlyphAdvance(glyph: Glyph, size: f32) f32 {
    return @max(size * 0.25, glyph.advance);
}

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}

fn commandsEqual(a: CanvasCommand, b: CanvasCommand) bool {
    return switch (a) {
        .push_clip => |value| switch (b) {
            .push_clip => |other| clipsEqual(value, other),
            else => false,
        },
        .pop_clip => switch (b) {
            .pop_clip => true,
            else => false,
        },
        .push_opacity => |value| switch (b) {
            .push_opacity => |other| value == other,
            else => false,
        },
        .pop_opacity => switch (b) {
            .pop_opacity => true,
            else => false,
        },
        .transform => |value| switch (b) {
            .transform => |other| affinesEqual(value, other),
            else => false,
        },
        .fill_rect => |value| switch (b) {
            .fill_rect => |other| fillRectsEqual(value, other),
            else => false,
        },
        .stroke_rect => |value| switch (b) {
            .stroke_rect => |other| strokeRectsEqual(value, other),
            else => false,
        },
        .fill_rounded_rect => |value| switch (b) {
            .fill_rounded_rect => |other| fillRoundedRectsEqual(value, other),
            else => false,
        },
        .draw_line => |value| switch (b) {
            .draw_line => |other| linesEqual(value, other),
            else => false,
        },
        .fill_path => |value| switch (b) {
            .fill_path => |other| fillPathsEqual(value, other),
            else => false,
        },
        .stroke_path => |value| switch (b) {
            .stroke_path => |other| strokePathsEqual(value, other),
            else => false,
        },
        .draw_image => |value| switch (b) {
            .draw_image => |other| drawImagesEqual(value, other),
            else => false,
        },
        .draw_text => |value| switch (b) {
            .draw_text => |other| drawTextsEqual(value, other),
            else => false,
        },
        .shadow => |value| switch (b) {
            .shadow => |other| shadowsEqual(value, other),
            else => false,
        },
        .blur => |value| switch (b) {
            .blur => |other| blursEqual(value, other),
            else => false,
        },
    };
}

fn clipsEqual(a: Clip, b: Clip) bool {
    return a.id == b.id and rectsEqual(a.rect, b.rect) and radiiEqual(a.radius, b.radius);
}

fn fillRectsEqual(a: FillRect, b: FillRect) bool {
    return a.id == b.id and rectsEqual(a.rect, b.rect) and fillsEqual(a.fill, b.fill);
}

fn strokeRectsEqual(a: StrokeRect, b: StrokeRect) bool {
    return a.id == b.id and rectsEqual(a.rect, b.rect) and radiiEqual(a.radius, b.radius) and strokesEqual(a.stroke, b.stroke);
}

fn fillRoundedRectsEqual(a: FillRoundedRect, b: FillRoundedRect) bool {
    return a.id == b.id and rectsEqual(a.rect, b.rect) and radiiEqual(a.radius, b.radius) and fillsEqual(a.fill, b.fill);
}

fn linesEqual(a: Line, b: Line) bool {
    return a.id == b.id and pointsEqual(a.from, b.from) and pointsEqual(a.to, b.to) and strokesEqual(a.stroke, b.stroke);
}

fn fillPathsEqual(a: FillPath, b: FillPath) bool {
    return a.id == b.id and pathElementsEqual(a.elements, b.elements) and fillsEqual(a.fill, b.fill);
}

fn strokePathsEqual(a: StrokePath, b: StrokePath) bool {
    return a.id == b.id and pathElementsEqual(a.elements, b.elements) and strokesEqual(a.stroke, b.stroke);
}

fn drawImagesEqual(a: DrawImage, b: DrawImage) bool {
    return a.id == b.id and
        a.image_id == b.image_id and
        optionalRectsEqual(a.src, b.src) and
        rectsEqual(a.dst, b.dst) and
        a.opacity == b.opacity and
        a.fit == b.fit;
}

fn drawTextsEqual(a: DrawText, b: DrawText) bool {
    return a.id == b.id and
        a.font_id == b.font_id and
        a.size == b.size and
        pointsEqual(a.origin, b.origin) and
        colorsEqual(a.color, b.color) and
        std.mem.eql(u8, a.text, b.text) and
        glyphsEqual(a.glyphs, b.glyphs);
}

fn shadowsEqual(a: Shadow, b: Shadow) bool {
    return a.id == b.id and
        rectsEqual(a.rect, b.rect) and
        radiiEqual(a.radius, b.radius) and
        offsetsEqual(a.offset, b.offset) and
        a.blur == b.blur and
        a.spread == b.spread and
        colorsEqual(a.color, b.color);
}

fn blursEqual(a: Blur, b: Blur) bool {
    return a.id == b.id and rectsEqual(a.rect, b.rect) and a.radius == b.radius;
}

fn fillsEqual(a: Fill, b: Fill) bool {
    return switch (a) {
        .color => |value| switch (b) {
            .color => |other| colorsEqual(value, other),
            else => false,
        },
        .linear_gradient => |value| switch (b) {
            .linear_gradient => |other| linearGradientsEqual(value, other),
            else => false,
        },
    };
}

fn strokesEqual(a: Stroke, b: Stroke) bool {
    return a.width == b.width and fillsEqual(a.fill, b.fill);
}

fn linearGradientsEqual(a: LinearGradient, b: LinearGradient) bool {
    return pointsEqual(a.start, b.start) and pointsEqual(a.end, b.end) and gradientStopsEqual(a.stops, b.stops);
}

fn gradientStopsEqual(a: []const GradientStop, b: []const GradientStop) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.offset != right.offset or !colorsEqual(left.color, right.color)) return false;
    }
    return true;
}

fn pathElementsEqual(a: []const PathElement, b: []const PathElement) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.verb != right.verb) return false;
        if (!pointsEqual(left.points[0], right.points[0])) return false;
        if (!pointsEqual(left.points[1], right.points[1])) return false;
        if (!pointsEqual(left.points[2], right.points[2])) return false;
    }
    return true;
}

fn glyphsEqual(a: []const Glyph, b: []const Glyph) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.id != right.id or left.x != right.x or left.y != right.y or left.advance != right.advance) return false;
    }
    return true;
}

fn rectsEqual(a: geometry.RectF, b: geometry.RectF) bool {
    return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
}

fn optionalRectsEqual(a: ?geometry.RectF, b: ?geometry.RectF) bool {
    if (a) |left| {
        if (b) |right| return rectsEqual(left, right);
        return false;
    }
    return b == null;
}

fn pointsEqual(a: geometry.PointF, b: geometry.PointF) bool {
    return a.x == b.x and a.y == b.y;
}

fn offsetsEqual(a: geometry.OffsetF, b: geometry.OffsetF) bool {
    return a.dx == b.dx and a.dy == b.dy;
}

fn colorsEqual(a: Color, b: Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

fn radiiEqual(a: Radius, b: Radius) bool {
    return a.top_left == b.top_left and
        a.top_right == b.top_right and
        a.bottom_right == b.bottom_right and
        a.bottom_left == b.bottom_left;
}

fn affinesEqual(a: Affine, b: Affine) bool {
    return a.a == b.a and
        a.b == b.b and
        a.c == b.c and
        a.d == b.d and
        a.tx == b.tx and
        a.ty == b.ty;
}

fn writeCommandJson(command: CanvasCommand, writer: anytype) !void {
    try writer.writeAll("{\"op\":");
    try json.writeString(writer, @tagName(command));
    switch (command) {
        .push_clip => |value| {
            try writer.print(",\"id\":{d},\"rect\":", .{value.id});
            try writeRectJson(value.rect, writer);
            try writer.writeAll(",\"radius\":");
            try writeRadiusJson(value.radius, writer);
        },
        .pop_clip, .pop_opacity => {},
        .push_opacity => |value| try writer.print(",\"opacity\":{d}", .{value}),
        .transform => |value| {
            try writer.writeAll(",\"matrix\":");
            try writeAffineJson(value, writer);
        },
        .fill_rect => |value| {
            try writer.print(",\"id\":{d},\"rect\":", .{value.id});
            try writeRectJson(value.rect, writer);
            try writer.writeAll(",\"fill\":");
            try writeFillJson(value.fill, writer);
        },
        .stroke_rect => |value| {
            try writer.print(",\"id\":{d},\"rect\":", .{value.id});
            try writeRectJson(value.rect, writer);
            try writer.writeAll(",\"radius\":");
            try writeRadiusJson(value.radius, writer);
            try writer.writeAll(",\"stroke\":");
            try writeStrokeJson(value.stroke, writer);
        },
        .fill_rounded_rect => |value| {
            try writer.print(",\"id\":{d},\"rect\":", .{value.id});
            try writeRectJson(value.rect, writer);
            try writer.writeAll(",\"radius\":");
            try writeRadiusJson(value.radius, writer);
            try writer.writeAll(",\"fill\":");
            try writeFillJson(value.fill, writer);
        },
        .draw_line => |value| {
            try writer.print(",\"id\":{d},\"from\":", .{value.id});
            try writePointJson(value.from, writer);
            try writer.writeAll(",\"to\":");
            try writePointJson(value.to, writer);
            try writer.writeAll(",\"stroke\":");
            try writeStrokeJson(value.stroke, writer);
        },
        .fill_path => |value| {
            try writer.print(",\"id\":{d},\"path\":", .{value.id});
            try writePathJson(value.elements, writer);
            try writer.writeAll(",\"fill\":");
            try writeFillJson(value.fill, writer);
        },
        .stroke_path => |value| {
            try writer.print(",\"id\":{d},\"path\":", .{value.id});
            try writePathJson(value.elements, writer);
            try writer.writeAll(",\"stroke\":");
            try writeStrokeJson(value.stroke, writer);
        },
        .draw_image => |value| {
            try writer.print(",\"id\":{d},\"image\":{d},\"dst\":", .{ value.id, value.image_id });
            try writeRectJson(value.dst, writer);
            try writer.writeAll(",\"src\":");
            if (value.src) |src| {
                try writeRectJson(src, writer);
            } else {
                try writer.writeAll("null");
            }
            try writer.print(",\"opacity\":{d},\"fit\":", .{value.opacity});
            try json.writeString(writer, @tagName(value.fit));
        },
        .draw_text => |value| {
            try writer.print(",\"id\":{d},\"font\":{d},\"size\":{d},\"origin\":", .{ value.id, value.font_id, value.size });
            try writePointJson(value.origin, writer);
            try writer.writeAll(",\"color\":");
            try writeColorJson(value.color, writer);
            try writer.writeAll(",\"text\":");
            try json.writeString(writer, value.text);
            try writer.writeAll(",\"glyphs\":");
            try writeGlyphsJson(value.glyphs, writer);
        },
        .shadow => |value| {
            try writer.print(",\"id\":{d},\"rect\":", .{value.id});
            try writeRectJson(value.rect, writer);
            try writer.writeAll(",\"radius\":");
            try writeRadiusJson(value.radius, writer);
            try writer.print(",\"offset\":[{d},{d}],\"blur\":{d},\"spread\":{d},\"color\":", .{ value.offset.dx, value.offset.dy, value.blur, value.spread });
            try writeColorJson(value.color, writer);
        },
        .blur => |value| {
            try writer.print(",\"id\":{d},\"rect\":", .{value.id});
            try writeRectJson(value.rect, writer);
            try writer.print(",\"radius\":{d}", .{value.radius});
        },
    }
    try writer.writeByte('}');
}

fn writeRectJson(rect: geometry.RectF, writer: anytype) !void {
    try writer.print("[{d},{d},{d},{d}]", .{ rect.x, rect.y, rect.width, rect.height });
}

fn writePointJson(point: geometry.PointF, writer: anytype) !void {
    try writer.print("[{d},{d}]", .{ point.x, point.y });
}

fn writeColorJson(color: Color, writer: anytype) !void {
    try writer.print("[{d},{d},{d},{d}]", .{ color.r, color.g, color.b, color.a });
}

fn writeRadiusJson(radius: Radius, writer: anytype) !void {
    try writer.print("[{d},{d},{d},{d}]", .{ radius.top_left, radius.top_right, radius.bottom_right, radius.bottom_left });
}

fn writeAffineJson(matrix: Affine, writer: anytype) !void {
    try writer.print("[{d},{d},{d},{d},{d},{d}]", .{ matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty });
}

fn writeFillJson(fill: Fill, writer: anytype) !void {
    switch (fill) {
        .color => |color| {
            try writer.writeAll("{\"kind\":\"color\",\"color\":");
            try writeColorJson(color, writer);
            try writer.writeByte('}');
        },
        .linear_gradient => |gradient| {
            try writer.writeAll("{\"kind\":\"linear_gradient\",\"start\":");
            try writePointJson(gradient.start, writer);
            try writer.writeAll(",\"end\":");
            try writePointJson(gradient.end, writer);
            try writer.writeAll(",\"stops\":[");
            for (gradient.stops, 0..) |stop, index| {
                if (index > 0) try writer.writeByte(',');
                try writer.print("{{\"offset\":{d},\"color\":", .{stop.offset});
                try writeColorJson(stop.color, writer);
                try writer.writeByte('}');
            }
            try writer.writeAll("]}");
        },
    }
}

fn writeStrokeJson(stroke: Stroke, writer: anytype) !void {
    try writer.writeAll("{\"width\":");
    try writer.print("{d}", .{stroke.width});
    try writer.writeAll(",\"fill\":");
    try writeFillJson(stroke.fill, writer);
    try writer.writeByte('}');
}

fn writePathJson(elements: []const PathElement, writer: anytype) !void {
    try writer.writeByte('[');
    for (elements, 0..) |element, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"verb\":");
        try json.writeString(writer, @tagName(element.verb));
        try writer.writeAll(",\"points\":[");
        const point_count: usize = switch (element.verb) {
            .move_to, .line_to => 1,
            .quad_to => 2,
            .cubic_to => 3,
            .close => 0,
        };
        for (element.points[0..point_count], 0..) |point, point_index| {
            if (point_index > 0) try writer.writeByte(',');
            try writePointJson(point, writer);
        }
        try writer.writeAll("]}");
    }
    try writer.writeByte(']');
}

fn writeGlyphsJson(glyphs: []const Glyph, writer: anytype) !void {
    try writer.writeByte('[');
    for (glyphs, 0..) |glyph, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{{\"id\":{d},\"x\":{d},\"y\":{d},\"advance\":{d}}}", .{ glyph.id, glyph.x, glyph.y, glyph.advance });
    }
    try writer.writeByte(']');
}

test "widget layout resolves row sizing and emits laid out commands" {
    const row_children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(0, 0, 80, 32),
            .text = "Run",
        },
        .{
            .id = 3,
            .kind = .progress,
            .frame = geometry.RectF.init(0, 0, 0, 8),
            .value = 0.5,
            .layout = .{ .grow = 1, .min_size = geometry.SizeF.init(40, 8) },
        },
        .{
            .id = 4,
            .kind = .text,
            .frame = geometry.RectF.init(0, 0, 60, 20),
            .text = "Ready",
        },
    };
    const panel_children = [_]Widget{
        .{
            .kind = .row,
            .frame = geometry.RectF.init(0, 0, 0, 40),
            .layout = .{ .gap = 8 },
            .children = &row_children,
        },
    };
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .layout = .{ .padding = geometry.InsetsF.all(12) },
        .children = &panel_children,
    };

    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 300, 80), &nodes);
    try std.testing.expectEqual(@as(usize, 5), layout.nodeCount());
    try expectLayoutFrame(layout, 1, geometry.RectF.init(0, 0, 300, 80));
    try expectLayoutFrame(layout, 2, geometry.RectF.init(12, 12, 80, 32));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(100, 12, 120, 8));
    try expectLayoutFrame(layout, 4, geometry.RectF.init(228, 12, 60, 20));

    var commands: [12]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 9), display_list.commandCount());
    switch (display_list.commands[7]) {
        .fill_rounded_rect => |fill| try expectRect(geometry.RectF.init(100, 12, 60, 8), fill.rect),
        else => return error.TestUnexpectedResult,
    }
}

test "widget layout hit testing prefers deepest topmost enabled target" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(8, 8, 90, 32),
            .text = "Disabled",
            .state = .{ .disabled = true },
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(16, 16, 90, 32),
            .text = "Active",
        },
    };
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &children,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 140, 80), &nodes);
    const active_hit = layout.hitTest(geometry.PointF.init(24, 24)).?;
    try std.testing.expectEqual(@as(ObjectId, 3), active_hit.id);
    try std.testing.expectEqual(WidgetKind.button, active_hit.kind);

    const panel_hit = layout.hitTest(geometry.PointF.init(10, 10)).?;
    try std.testing.expectEqual(@as(ObjectId, 1), panel_hit.id);
    try std.testing.expect(layout.hitTest(geometry.PointF.init(200, 10)) == null);
}

test "widget layout collects accessibility semantics" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(10, 10, 100, 32),
            .text = "Run",
            .semantics = .{ .label = "Run query" },
        },
        .{
            .id = 3,
            .kind = .progress,
            .frame = geometry.RectF.init(10, 52, 160, 8),
            .value = 0.75,
        },
        .{
            .id = 4,
            .kind = .text,
            .frame = geometry.RectF.init(10, 68, 120, 20),
            .text = "Hidden note",
            .semantics = .{ .hidden = true },
        },
    };
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .semantics = .{ .label = "Dashboard card" },
        .children = &children,
    };

    var nodes: [6]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 240, 120), &nodes);
    var semantics_buffer: [4]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);

    try std.testing.expectEqual(@as(usize, 3), semantics.len);
    try std.testing.expectEqual(WidgetRole.group, semantics[0].role);
    try std.testing.expectEqualStrings("Dashboard card", semantics[0].label);
    try std.testing.expect(semantics[0].parent_index == null);

    try std.testing.expectEqual(WidgetRole.button, semantics[1].role);
    try std.testing.expectEqualStrings("Run query", semantics[1].label);
    try std.testing.expectEqual(@as(?usize, 0), semantics[1].parent_index);
    try std.testing.expect(semantics[1].focusable);

    try std.testing.expectEqual(WidgetRole.progressbar, semantics[2].role);
    try std.testing.expectEqual(@as(?f32, 0.75), semantics[2].value);
    try expectRect(geometry.RectF.init(10, 52, 160, 8), semantics[2].bounds);
}

test "widget layout reports fixed buffer errors" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .text, .text = "One" },
        .{ .id = 3, .kind = .text, .text = "Two" },
    };
    const root = Widget{ .id = 1, .kind = .stack, .children = &children };

    var small_nodes: [2]WidgetLayoutNode = undefined;
    try std.testing.expectError(error.WidgetLayoutListFull, layoutWidgetTree(root, geometry.RectF.init(0, 0, 100, 100), &small_nodes));

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 100, 100), &nodes);
    var small_semantics: [1]WidgetSemanticsNode = undefined;
    try std.testing.expectError(error.WidgetSemanticsListFull, layout.collectSemantics(&small_semantics));
}

test "widget tree emits panel button text and progress commands" {
    const tokens: DesignTokens = .{};
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(16, 16, 120, 36),
            .text = "Launch",
        },
        .{
            .id = 3,
            .kind = .text,
            .frame = geometry.RectF.init(16, 64, 200, 20),
            .text = "Frames stay retained",
        },
        .{
            .id = 4,
            .kind = .progress,
            .frame = geometry.RectF.init(16, 96, 160, 8),
            .value = 0.25,
        },
    };
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .frame = geometry.RectF.init(0, 0, 240, 128),
        .children = &children,
    };

    var commands: [12]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, root, tokens);

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 9), display_list.commandCount());
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(1, 1)), display_list.commands[0].objectId());
    try std.testing.expect(display_list.commands[0] == .shadow);
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(1, 2)), display_list.commands[1].objectId());
    try std.testing.expect(display_list.commands[1] == .fill_rounded_rect);
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(2, 1)), display_list.commands[3].objectId());
    try std.testing.expect(display_list.commands[3] == .fill_rounded_rect);

    switch (display_list.commands[5]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(2, 4)), text.id);
            try std.testing.expectEqualStrings("Launch", text.text);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[6]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(3, 1)), text.id);
            try std.testing.expectEqualStrings("Frames stay retained", text.text);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[8]) {
        .fill_rounded_rect => |fill| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(4, 2)), fill.id);
            try expectRect(geometry.RectF.init(16, 96, 40, 8), fill.rect);
            try expectFillColor(tokens.colors.accent, fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget emitter applies button state tokens" {
    const tokens = DesignTokens{
        .colors = .{
            .accent = Color.rgb8(10, 20, 30),
            .accent_text = Color.rgb8(240, 241, 242),
            .focus_ring = Color.rgb8(1, 2, 3),
        },
        .stroke = .{ .focus = 3 },
    };
    const button = Widget{
        .id = 7,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 140, 40),
        .text = "Pressed",
        .state = .{ .pressed = true, .focused = true },
    };

    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, button, tokens);

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 4), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.accent, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(7, 3)), stroke.id);
            try std.testing.expectEqual(@as(f32, 3), stroke.stroke.width);
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .draw_text => |text| try std.testing.expectEqualDeep(tokens.colors.accent_text, text.color),
        else => return error.TestUnexpectedResult,
    }
}

test "widget emitter reports depth and display list overflow" {
    var tiny_commands: [2]CanvasCommand = undefined;
    var tiny_builder = Builder.init(&tiny_commands);
    try std.testing.expectError(error.DisplayListFull, emitWidgetTree(&tiny_builder, .{
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 120, 36),
        .text = "Overflow",
    }, .{}));

    var widgets: [max_widget_depth + 1]Widget = undefined;
    var index = widgets.len;
    while (index > 0) {
        index -= 1;
        widgets[index] = .{
            .kind = .stack,
            .children = if (index + 1 < widgets.len) widgets[index + 1 .. index + 2] else &.{},
        };
    }

    var commands: [1]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try std.testing.expectError(error.WidgetDepthExceeded, emitWidgetTree(&builder, widgets[0], .{}));
}

test "builder records replayable commands" {
    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);

    try builder.pushClip(.{ .id = 1, .rect = geometry.RectF.init(0, 0, 320, 240), .radius = Radius.all(8) });
    try builder.pushOpacity(0.75);
    try builder.fillRoundedRect(.{
        .id = 2,
        .rect = geometry.RectF.init(12, 16, 180, 96),
        .radius = Radius.all(12),
        .fill = .{ .color = Color.rgb8(17, 24, 39) },
    });
    try builder.popOpacity();
    try builder.popClip();

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 5), display_list.commandCount());
    try std.testing.expect(display_list.commands[0] == .push_clip);
    try std.testing.expect(display_list.commands[2] == .fill_rounded_rect);
}

test "builder reports fixed buffer overflow" {
    var commands: [1]CanvasCommand = undefined;
    var builder = Builder.init(&commands);

    try builder.pushOpacity(1);
    try std.testing.expectError(error.DisplayListFull, builder.popOpacity());
}

test "display list finds commands and computes conservative bounds" {
    const path = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(5, 5), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .cubic_to, .points = .{ geometry.PointF.init(15, 30), geometry.PointF.init(20, 0), geometry.PointF.init(35, 35) } },
        .{ .verb = .close },
    };

    var commands: [3]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try builder.strokeRect(.{
        .id = 1,
        .rect = geometry.RectF.init(10, 10, 100, 40),
        .stroke = .{ .fill = .{ .color = Color.rgb8(0, 0, 0) }, .width = 4 },
    });
    try builder.fillPath(.{
        .id = 2,
        .elements = &path,
        .fill = .{ .color = Color.rgb8(255, 255, 255) },
    });
    try builder.shadow(.{
        .id = 3,
        .rect = geometry.RectF.init(20, 20, 40, 20),
        .offset = .{ .dx = 0, .dy = 8 },
        .blur = 12,
        .spread = -4,
        .color = Color.rgba8(0, 0, 0, 64),
    });

    const display_list = builder.displayList();
    const path_ref = display_list.findCommandById(2).?;
    try std.testing.expectEqual(@as(usize, 1), path_ref.index);
    try std.testing.expectEqual(@as(?ObjectId, 2), path_ref.command.objectId());
    try std.testing.expect(display_list.findCommandById(99) == null);

    try expectRect(geometry.RectF.init(8, 8, 104, 44), display_list.commands[0].bounds());
    try expectRect(geometry.RectF.init(5, 0, 30, 35), display_list.commands[1].bounds());
    try expectRect(geometry.RectF.init(4, 12, 72, 52), display_list.commands[2].bounds());
    try expectRect(geometry.RectF.init(4, 0, 108, 64), display_list.bounds());
}

test "display list diffs changed added removed and unkeyed scene commands" {
    const previous_commands = [_]CanvasCommand{
        .{ .push_opacity = 1 },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 100, 100), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(120, 0, 40, 40), .fill = .{ .color = Color.rgb8(17, 24, 39) } } },
        .{ .draw_image = .{ .id = 3, .image_id = 8, .dst = geometry.RectF.init(180, 0, 32, 32) } },
    };
    const next_commands = [_]CanvasCommand{
        .{ .push_opacity = 0.5 },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(10, 0, 100, 100), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(120, 0, 40, 40), .fill = .{ .color = Color.rgb8(17, 24, 39) } } },
        .{ .blur = .{ .id = 4, .rect = geometry.RectF.init(220, 0, 24, 24), .radius = 6 } },
    };

    var changes: [8]DiffChange = undefined;
    const diff = try DisplayList.diff(.{ .commands = &previous_commands }, .{ .commands = &next_commands }, &changes);
    try std.testing.expectEqual(@as(usize, 4), diff.len);
    try std.testing.expectEqual(DiffKind.scene_changed, diff[0].kind);
    try std.testing.expectEqual(@as(?ObjectId, null), diff[0].id);
    try std.testing.expect(diff[0].dirty_bounds != null);
    try std.testing.expectEqual(DiffKind.changed, diff[1].kind);
    try std.testing.expectEqual(@as(?ObjectId, 1), diff[1].id);
    try std.testing.expectEqual(@as(?usize, 1), diff[1].previous_index);
    try std.testing.expectEqual(@as(?usize, 1), diff[1].next_index);
    try expectRect(geometry.RectF.init(0, 0, 110, 100), diff[1].dirty_bounds);
    try std.testing.expectEqual(DiffKind.removed, diff[2].kind);
    try std.testing.expectEqual(@as(?ObjectId, 3), diff[2].id);
    try expectRect(geometry.RectF.init(180, 0, 32, 32), diff[2].dirty_bounds);
    try std.testing.expectEqual(DiffKind.added, diff[3].kind);
    try std.testing.expectEqual(@as(?ObjectId, 4), diff[3].id);
    try expectRect(geometry.RectF.init(214, -6, 36, 36), diff[3].dirty_bounds);
}

test "display list diff ignores unchanged keyed commands" {
    const commands = [_]CanvasCommand{
        .{ .fill_rounded_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(8, 8, 120, 40),
            .radius = Radius.all(10),
            .fill = .{ .color = Color.rgb8(15, 23, 42) },
        } },
    };

    var changes: [1]DiffChange = undefined;
    const diff = try DisplayList.diff(.{ .commands = &commands }, .{ .commands = &commands }, &changes);
    try std.testing.expectEqual(@as(usize, 0), diff.len);
}

test "display list diff rejects duplicate object ids" {
    const commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 10, 10), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .{ .blur = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 10, 10), .radius = 4 } },
    };

    var changes: [2]DiffChange = undefined;
    try std.testing.expectError(error.DuplicateObjectId, DisplayList.diff(.{ .commands = &commands }, .{}, &changes));
}

test "affine transforms points and conservative rect bounds" {
    const transform = Affine.translate(10, 5).multiply(Affine.scale(2, 3));
    try std.testing.expectEqualDeep(geometry.PointF.init(14, 14), transform.transformPoint(geometry.PointF.init(2, 3)));
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 5, 20, 15), transform.transformRect(geometry.RectF.init(0, 0, 10, 5)));
}

test "render plan resolves transform clip and opacity state" {
    const commands = [_]CanvasCommand{
        .{ .push_clip = .{ .id = 90, .rect = geometry.RectF.init(10, 10, 50, 50) } },
        .{ .push_opacity = 0.5 },
        .{ .transform = Affine.translate(10, 0) },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 30, 30), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .pop_opacity,
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(0, 0, 4, 4), .fill = .{ .color = Color.rgb8(0, 0, 0) } } },
        .pop_clip,
        .{ .fill_rect = .{ .id = 3, .rect = geometry.RectF.init(0, 0, 4, 4), .fill = .{ .color = Color.rgb8(17, 24, 39) } } },
    };

    var render_commands: [4]RenderCommand = undefined;
    const plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    try std.testing.expectEqual(@as(usize, 2), plan.commandCount());

    try std.testing.expectEqual(@as(?ObjectId, 1), plan.commands[0].id);
    try std.testing.expectEqual(@as(f32, 0.5), plan.commands[0].opacity);
    try expectRect(geometry.RectF.init(10, 10, 50, 50), plan.commands[0].clip);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 10, 30, 20), plan.commands[0].bounds);

    try std.testing.expectEqual(@as(?ObjectId, 3), plan.commands[1].id);
    try std.testing.expectEqual(@as(f32, 1), plan.commands[1].opacity);
    try std.testing.expect(plan.commands[1].clip == null);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 0, 4, 4), plan.commands[1].bounds);
    try expectRect(geometry.RectF.init(10, 0, 30, 30), plan.bounds);
}

test "render plan reports output and stack errors" {
    const draw_commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 10, 10), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
    };
    var empty_render_commands: [0]RenderCommand = .{};
    try std.testing.expectError(error.RenderListFull, (DisplayList{ .commands = &draw_commands }).renderPlan(&empty_render_commands));

    const bad_clip_commands = [_]CanvasCommand{.pop_clip};
    var render_commands: [1]RenderCommand = undefined;
    try std.testing.expectError(error.RenderStackUnderflow, (DisplayList{ .commands = &bad_clip_commands }).renderPlan(&render_commands));

    const bad_opacity_commands = [_]CanvasCommand{.pop_opacity};
    try std.testing.expectError(error.RenderStackUnderflow, (DisplayList{ .commands = &bad_opacity_commands }).renderPlan(&render_commands));
}

test "display list serializes deterministically" {
    const stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = Color.rgb8(59, 130, 246) },
    };
    const glyphs = [_]Glyph{
        .{ .id = 42, .x = 12, .y = 28, .advance = 9 },
        .{ .id = 43, .x = 21, .y = 28, .advance = 8 },
    };

    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try builder.fillRect(.{
        .id = 10,
        .rect = geometry.RectF.init(0, 0, 360, 180),
        .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(0, 0),
            .end = geometry.PointF.init(360, 180),
            .stops = &stops,
        } },
    });
    try builder.shadow(.{
        .id = 11,
        .rect = geometry.RectF.init(24, 24, 220, 96),
        .radius = Radius.all(16),
        .offset = .{ .dx = 0, .dy = 18 },
        .blur = 42,
        .spread = -8,
        .color = Color.rgba8(15, 23, 42, 48),
    });
    try builder.drawText(.{
        .id = 12,
        .font_id = 7,
        .size = 17,
        .origin = geometry.PointF.init(32, 52),
        .color = Color.rgb8(15, 23, 42),
        .text = "Hi",
        .glyphs = &glyphs,
    });

    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try builder.displayList().writeJson(&writer);

    const expected =
        "{\"commands\":[{\"op\":\"fill_rect\",\"id\":10,\"rect\":[0,0,360,180],\"fill\":{\"kind\":\"linear_gradient\",\"start\":[0,0],\"end\":[360,180],\"stops\":[{\"offset\":0,\"color\":[1,1,1,1]},{\"offset\":1,\"color\":[0.23137255,0.50980395,0.9647059,1]}]}},{\"op\":\"shadow\",\"id\":11,\"rect\":[24,24,220,96],\"radius\":[16,16,16,16],\"offset\":[0,18],\"blur\":42,\"spread\":-8,\"color\":[0.05882353,0.09019608,0.16470589,0.1882353]},{\"op\":\"draw_text\",\"id\":12,\"font\":7,\"size\":17,\"origin\":[32,52],\"color\":[0.05882353,0.09019608,0.16470589,1],\"text\":\"Hi\",\"glyphs\":[{\"id\":42,\"x\":12,\"y\":28,\"advance\":9},{\"id\":43,\"x\":21,\"y\":28,\"advance\":8}]}]}";
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

fn expectRect(expected: geometry.RectF, actual: ?geometry.RectF) !void {
    try std.testing.expect(actual != null);
    try std.testing.expectEqualDeep(expected, actual.?);
}

fn expectLayoutFrame(layout: WidgetLayoutTree, id: ObjectId, expected: geometry.RectF) !void {
    const node = layout.findById(id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualDeep(expected, node.frame);
}

fn expectFillColor(expected: Color, actual: Fill) !void {
    switch (actual) {
        .color => |color| try std.testing.expectEqualDeep(expected, color),
        else => return error.TestUnexpectedResult,
    }
}
