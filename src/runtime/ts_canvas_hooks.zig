//! Typed canvas capabilities. Core helpers derive declarations; this host
//! resolves retained identities, copies bounded data and enters the renderer.
const std = @import("std");
const canvas = @import("canvas");
const geometry = @import("geometry");
const platform = @import("../platform/root.zig");

pub fn Hooks(comptime core: type, comptime Model: type, comptime App: type) type {
    return struct {
        // Stable native storage: no gradient points at a decoded helper arena.
        // One compiled core owns one live app per process.
        var stop_storage: [64][16]canvas.GradientStop = undefined;

        fn deref(raw: anytype) if (@typeInfo(@TypeOf(raw)) == .pointer) @typeInfo(@TypeOf(raw)).pointer.child else @TypeOf(raw) {
            return if (comptime @typeInfo(@TypeOf(raw)) == .pointer) raw.* else raw;
        }
        fn number(raw: anytype) f64 {
            return if (comptime @typeInfo(@TypeOf(raw)) == .int) @floatFromInt(raw) else raw;
        }
        fn scalar(raw: anytype) error{InvalidCanvasScalar}!f32 {
            const n = number(raw);
            if (!std.math.isFinite(n) or @abs(n) > std.math.floatMax(f32)) return error.InvalidCanvasScalar;
            return @floatCast(n);
        }
        fn color(raw_value: anytype) !canvas.Color {
            const raw = deref(raw_value);
            const result = canvas.Color{ .r = try scalar(raw.r), .g = try scalar(raw.g), .b = try scalar(raw.b), .a = try scalar(raw.a) };
            inline for (.{ "r", "g", "b", "a" }) |field| if (@field(result, field) < 0 or @field(result, field) > 1) return error.InvalidCanvasColor;
            return result;
        }
        fn rectangle(raw_value: anytype) !geometry.RectF {
            const raw = deref(raw_value);
            const rect = geometry.RectF{ .x = try scalar(raw.x), .y = try scalar(raw.y), .width = try scalar(raw.width), .height = try scalar(raw.height) };
            if (rect.width < 0 or rect.height < 0) return error.InvalidCanvasGeometry;
            return rect;
        }
        fn point(raw_value: anytype) !geometry.PointF {
            const raw = deref(raw_value);
            return .{ .x = try scalar(raw.x), .y = try scalar(raw.y) };
        }
        fn exactId(raw: []const u8) error{InvalidCanvasId}!u64 {
            if (raw.len == 0 or raw.len > 20 or (raw.len > 1 and raw[0] == '0')) return error.InvalidCanvasId;
            for (raw) |byte| if (byte < '0' or byte > '9') return error.InvalidCanvasId;
            return std.fmt.parseUnsigned(u64, raw, 10) catch error.InvalidCanvasId;
        }
        fn fill(raw_value: anytype, slot: usize) !canvas.Fill {
            const raw = deref(raw_value);
            return switch (raw) {
                .color => |value| .{ .color = try color(value) },
                .linear_gradient => |value| blk: {
                    const gradient = deref(value);
                    if (gradient.stops.len > 16) return error.CanvasGradientStopLimit;
                    for (gradient.stops, 0..) |raw_stop, index| {
                        const stop = deref(raw_stop);
                        const offset = try scalar(stop.offset);
                        if (offset < 0 or offset > 1) return error.InvalidCanvasGradientOffset;
                        stop_storage[slot][index] = .{ .offset = offset, .color = try color(stop.color) };
                    }
                    break :blk .{ .linear_gradient = .{ .start = try point(gradient.start), .end = try point(gradient.end), .stops = stop_storage[slot][0..gradient.stops.len] } };
                },
            };
        }
        fn contextColor(comptime T: type, value: canvas.Color) T {
            return .{ .r = value.r, .g = value.g, .b = value.b, .a = value.a };
        }

        pub fn chrome(model: *const Model, builder: *canvas.Builder, size: geometry.SizeF, tokens: canvas.DesignTokens) anyerror!void {
            const params = @typeInfo(@TypeOf(Model.canvasChrome)).@"fn".params;
            const Context = params[1].type.?;
            const context: Context = .{
                .width = size.width,
                .height = size.height,
                .background = contextColor(@FieldType(Context, "background"), tokens.colors.background),
                .surface = contextColor(@FieldType(Context, "surface"), tokens.colors.surface),
                .border = contextColor(@FieldType(Context, "border"), tokens.colors.border),
            };
            const commands = if (comptime params.len == 2) model.canvasChrome(context) else model.canvasChrome(context, core.rt.frameAllocator());
            if (commands.len > 64) return error.CanvasChromeCommandLimit;
            var ids: [64]u64 = undefined;
            for (commands, 0..) |raw_command, slot| {
                const command = deref(raw_command);
                switch (command) {
                    inline .rect, .rounded_rect => |raw| {
                        const value = deref(raw);
                        const id = try exactId(value.id);
                        for (ids[0..slot]) |previous| if (id == previous) return error.DuplicateCanvasChromeId;
                        ids[slot] = id;
                        const rect = try rectangle(value.rect);
                        const paint = try fill(value.fill, slot);
                        if (comptime @hasField(@TypeOf(value), "radius")) {
                            const radius = try scalar(value.radius);
                            if (radius < 0) return error.InvalidCanvasRadius;
                            try builder.fillRoundedRect(.{ .id = id, .rect = rect, .radius = canvas.Radius.all(radius), .fill = paint });
                        } else try builder.fillRect(.{ .id = id, .rect = rect, .fill = paint });
                    },
                }
            }
        }

        fn selectedWidget(widget: canvas.Widget, label: []const u8, occurrence: *usize) ?canvas.Widget {
            if (std.mem.eql(u8, widget.semantics.label, label)) {
                if (occurrence.* == 0) return widget;
                occurrence.* -= 1;
            }
            for (widget.children) |child| if (selectedWidget(child, label, occurrence)) |found| return found;
            return null;
        }
        fn transform(raw_value: anytype) !canvas.Affine {
            const raw = deref(raw_value);
            return .{ .a = try scalar(raw.a), .b = try scalar(raw.b), .c = try scalar(raw.c), .d = try scalar(raw.d), .tx = try scalar(raw.tx), .ty = try scalar(raw.ty) };
        }
        fn animation(raw_value: anytype, tree: *const App.Ui.Tree, start_ns: u64) !?canvas.CanvasRenderAnimation {
            const raw = deref(raw_value);
            const index = number(raw.index);
            const duration = number(raw.durationMs);
            if (!std.math.isFinite(index) or index < 0 or index > 4294967295 or @trunc(index) != index or
                !std.math.isFinite(duration) or duration < 0 or duration > 4294967295 or @trunc(duration) != duration) return error.InvalidCanvasAnimationInteger;
            var occurrence: usize = @intFromFloat(index);
            const widget = selectedWidget(tree.root, raw.label, &occurrence) orelse return null;
            const from_opacity = try scalar(raw.fromOpacity);
            const to_opacity = try scalar(raw.toOpacity);
            if (from_opacity < 0 or from_opacity > 1 or to_opacity < 0 or to_opacity > 1) return error.InvalidCanvasOpacity;
            return .{
                .id = canvas.widgetCommandPartId(.{ .widget_id = widget.id, .slot = if (std.mem.eql(u8, @tagName(raw.part), "fill")) 1 else 4 }),
                .start_ns = start_ns,
                .duration_ms = @intFromFloat(duration),
                .easing = std.meta.stringToEnum(canvas.Easing, @tagName(raw.easing)) orelse unreachable,
                .loop = std.meta.stringToEnum(canvas.CanvasRenderAnimationLoop, @tagName(raw.loop)) orelse unreachable,
                .from_opacity = from_opacity,
                .to_opacity = to_opacity,
                .from_transform = try transform(raw.fromTransform),
                .to_transform = try transform(raw.toTransform),
            };
        }
        pub fn animations(model: *const Model, tree: *const App.Ui.Tree, start_ns: u64, out: []canvas.CanvasRenderAnimation) usize {
            const params = @typeInfo(@TypeOf(Model.canvasAnimations)).@"fn".params;
            const declarations = if (comptime params.len == 1) model.canvasAnimations() else model.canvasAnimations(core.rt.frameAllocator());
            if (declarations.len > out.len) return 0;
            var count: usize = 0;
            for (declarations) |declaration| {
                const prepared = animation(declaration, tree, start_ns) catch return 0;
                const value = prepared orelse continue;
                var duplicate = false;
                for (out[0..count]) |previous| if (previous.id == value.id) { duplicate = true; };
                if (duplicate) return 0;
                out[count] = value;
                count += 1;
            }
            return count;
        }
        fn clock(value: u64) []const u8 {
            var buffer: [20]u8 = undefined;
            const bytes = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
            const result = core.rt.frameAlloc(u8, bytes.len);
            @memcpy(result, bytes);
            return result;
        }
        pub fn frame(model: *const Model, presented: platform.GpuFrame) ?core.Msg {
            const params = @typeInfo(@TypeOf(Model.canvasFrameMsg)).@"fn".params;
            const Frame = params[1].type.?;
            const observed: Frame = .{
                .width = presented.size.width,
                .height = presented.size.height,
                .timestampNs = clock(presented.timestamp_ns),
                .intervalNs = clock(presented.frame_interval_ns),
                .risk = std.meta.stringToEnum(@FieldType(Frame, "risk"), @tagName(presented.canvas_frame_profile_risk)) orelse unreachable,
                .workUnits = clock(presented.canvas_frame_profile_work_units),
                .commands = clock(presented.canvas_command_count),
                .batches = clock(presented.canvas_frame_batch_count),
                .representable = presented.canvas_frame_gpu_packet_representable,
                .dirtyRatio = presented.canvas_frame_profile_dirty_ratio,
            };
            const value = (if (comptime params.len == 2) model.canvasFrameMsg(observed) else model.canvasFrameMsg(observed, core.rt.frameAllocator())) orelse return null;
            switch (value) {
                inline else => |payload, tag| return @unionInit(core.Msg, @tagName(tag), payload),
            }
        }
    };
}
