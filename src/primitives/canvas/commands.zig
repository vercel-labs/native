const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const text_model = @import("text.zig");
const render_model = @import("render.zig");
const frame_model = @import("frame.zig");
const equality_model = @import("equality.zig");
const serialization = @import("serialization.zig");

const ObjectId = u64;
const Error = canvas.Error;

const Affine = drawing_model.Affine;
const Clip = drawing_model.Clip;
const FillRect = drawing_model.FillRect;
const StrokeRect = drawing_model.StrokeRect;
const FillRoundedRect = drawing_model.FillRoundedRect;
const Line = drawing_model.Line;
const FillPath = drawing_model.FillPath;
const StrokePath = drawing_model.StrokePath;
const DrawImage = drawing_model.DrawImage;
const Shadow = drawing_model.Shadow;
const Blur = drawing_model.Blur;
const DrawText = text_model.DrawText;
const GlyphAtlasEntry = text_model.GlyphAtlasEntry;
const GlyphAtlasPlan = text_model.GlyphAtlasPlan;
const GlyphAtlasPlanner = text_model.GlyphAtlasPlanner;
const TextLayoutOptions = text_model.TextLayoutOptions;
const TextLine = text_model.TextLine;
const TextLayoutPlan = text_model.TextLayoutPlan;
const TextLayoutPlanSet = text_model.TextLayoutPlanSet;
const TextLayoutPlanner = text_model.TextLayoutPlanner;
const RenderCommand = render_model.RenderCommand;
const RenderPlan = render_model.RenderPlan;
const RenderPlanner = render_model.RenderPlanner;
const RenderResource = render_model.RenderResource;
const RenderResourcePlan = render_model.RenderResourcePlan;
const RenderResourcePlanner = render_model.RenderResourcePlanner;
const VisualEffect = render_model.VisualEffect;
const VisualEffectPlan = render_model.VisualEffectPlan;
const VisualEffectPlanner = render_model.VisualEffectPlanner;
const CanvasFrameOptions = frame_model.CanvasFrameOptions;
const CanvasFrameStorage = frame_model.CanvasFrameStorage;
const CanvasFrame = frame_model.CanvasFrame;
const buildCanvasFrame = frame_model.buildCanvasFrame;
const commandsEqual = equality_model.commandsEqual;

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
            .stroke_rect => |value| drawing_model.strokeBounds(value.rect, value.stroke.width),
            .fill_rounded_rect => |value| value.rect.normalized(),
            .draw_line => |value| drawing_model.strokeBounds(geometry.RectF.fromPoints(value.from, value.to), value.stroke.width),
            .fill_path => |value| drawing_model.pathBounds(value.elements),
            .stroke_path => |value| if (drawing_model.pathBounds(value.elements)) |rect| drawing_model.strokeBounds(rect, value.stroke.width) else null,
            .draw_image => |value| value.dst.normalized(),
            .draw_text => |value| text_model.textBounds(value),
            .shadow => |value| drawing_model.shadowBounds(value),
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

pub const DisplayList = struct {
    commands: []const CanvasCommand = &.{},

    pub fn writeJson(self: DisplayList, writer: anytype) !void {
        try serialization.writeDisplayListJson(self, writer);
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

    pub fn resourcePlan(self: DisplayList, output: []RenderResource) Error!RenderResourcePlan {
        var planner = RenderResourcePlanner.init(output);
        return planner.build(self);
    }

    pub fn visualEffectPlan(self: DisplayList, output: []VisualEffect) Error!VisualEffectPlan {
        var planner = VisualEffectPlanner.init(output);
        return planner.build(self);
    }

    pub fn glyphAtlasPlan(self: DisplayList, output: []GlyphAtlasEntry) Error!GlyphAtlasPlan {
        var planner = GlyphAtlasPlanner.init(output);
        return planner.build(self);
    }

    pub fn textLayoutPlan(self: DisplayList, options: TextLayoutOptions, output: []TextLayoutPlan, lines: []TextLine) Error!TextLayoutPlanSet {
        var planner = TextLayoutPlanner.init(output, lines);
        return planner.build(self, options);
    }

    pub fn framePlan(self: DisplayList, previous: ?DisplayList, options: CanvasFrameOptions, storage: CanvasFrameStorage) Error!CanvasFrame {
        return buildCanvasFrame(previous, self, options, storage);
    }
};

fn diffDisplayLists(previous: DisplayList, next: DisplayList, output: []DiffChange) Error![]const DiffChange {
    try validateUniqueObjectIds(previous);
    try validateUniqueObjectIds(next);

    var len: usize = 0;
    if (previous.commands.len == 0 and next.commands.len == 0) return output[0..0];
    if (previous.commands.len == 0 or next.commands.len == 0) {
        const dirty_bounds = if (previous.commands.len == 0)
            displayListBoundsWithoutText(next)
        else
            displayListBoundsWithoutText(previous);
        try appendDiffChange(output, &len, .{
            .kind = .scene_changed,
            .dirty_bounds = dirty_bounds,
        });
        return output[0..len];
    }

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

fn displayListBoundsWithoutText(display_list: DisplayList) ?geometry.RectF {
    var result: ?geometry.RectF = null;
    for (display_list.commands) |command| {
        if (std.meta.activeTag(command) == .draw_text) return null;
        if (command.bounds()) |command_bounds| {
            result = if (result) |current| geometry.RectF.unionWith(current.normalized(), command_bounds.normalized()) else command_bounds;
        }
    }
    return result;
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

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}

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

    pub fn append(self: *Builder, command: CanvasCommand) error{DisplayListFull}!void {
        if (self.len >= self.commands.len) return error.DisplayListFull;
        self.commands[self.len] = command;
        self.len += 1;
    }

    pub fn pushClip(self: *Builder, clip: Clip) error{DisplayListFull}!void {
        try self.append(.{ .push_clip = clip });
    }

    pub fn popClip(self: *Builder) error{DisplayListFull}!void {
        try self.append(.pop_clip);
    }

    pub fn pushOpacity(self: *Builder, opacity: f32) error{DisplayListFull}!void {
        try self.append(.{ .push_opacity = opacity });
    }

    pub fn popOpacity(self: *Builder) error{DisplayListFull}!void {
        try self.append(.pop_opacity);
    }

    pub fn transform(self: *Builder, value: Affine) error{DisplayListFull}!void {
        try self.append(.{ .transform = value });
    }

    pub fn fillRect(self: *Builder, value: FillRect) error{DisplayListFull}!void {
        try self.append(.{ .fill_rect = value });
    }

    pub fn strokeRect(self: *Builder, value: StrokeRect) error{DisplayListFull}!void {
        try self.append(.{ .stroke_rect = value });
    }

    pub fn fillRoundedRect(self: *Builder, value: FillRoundedRect) error{DisplayListFull}!void {
        try self.append(.{ .fill_rounded_rect = value });
    }

    pub fn drawLine(self: *Builder, value: Line) error{DisplayListFull}!void {
        try self.append(.{ .draw_line = value });
    }

    pub fn fillPath(self: *Builder, value: FillPath) error{DisplayListFull}!void {
        try self.append(.{ .fill_path = value });
    }

    pub fn strokePath(self: *Builder, value: StrokePath) error{DisplayListFull}!void {
        try self.append(.{ .stroke_path = value });
    }

    pub fn drawImage(self: *Builder, value: DrawImage) error{DisplayListFull}!void {
        try self.append(.{ .draw_image = value });
    }

    pub fn drawText(self: *Builder, value: DrawText) error{DisplayListFull}!void {
        try self.append(.{ .draw_text = value });
    }

    pub fn shadow(self: *Builder, value: Shadow) error{DisplayListFull}!void {
        try self.append(.{ .shadow = value });
    }

    pub fn blur(self: *Builder, value: Blur) error{DisplayListFull}!void {
        try self.append(.{ .blur = value });
    }
};
