const support = @import("test_support.zig");
const std = support.std;
const geometry = support.geometry;
const canvas = support.canvas;
const automation = support.automation;
const platform = support.platform;
const App = support.App;
const TestHarness = support.TestHarness;
const max_canvas_commands_per_view = support.max_canvas_commands_per_view;
const canvasFrameScratchStorage = support.canvasFrameScratchStorage;
const CanvasPresentationMode = support.CanvasPresentationMode;
const CanvasPresentationResult = support.CanvasPresentationResult;

// ---------------------------------------------------------------------------
// Reference retained-store host: a Zig twin of the AppKit host's command
// dictionary (appkit_host.m, presentGpuPacketObject) that applies the v2
// binary wire byte-for-byte. It retains each command's ENCODED bytes
// keyed by retain key plus the draw-order vector, so the golden test can
// compare "state after a sequence of patches" against "state after a full
// re-present" at the wire-byte level — stronger than any field-wise
// comparison, and immune to a decoder papering over drift.

const TestRetainedHost = struct {
    allocator: std.mem.Allocator,
    commands: std.AutoHashMap(u64, []u8),
    order: std.ArrayList(u64),
    generation: u64 = 0,
    valid: bool = false,

    fn init(allocator: std.mem.Allocator) TestRetainedHost {
        return .{
            .allocator = allocator,
            .commands = std.AutoHashMap(u64, []u8).init(allocator),
            .order = .empty,
        };
    }

    fn deinit(self: *TestRetainedHost) void {
        var it = self.commands.valueIterator();
        while (it.next()) |bytes| self.allocator.free(bytes.*);
        self.commands.deinit();
        self.order.deinit(self.allocator);
    }

    fn clearCommands(self: *TestRetainedHost) void {
        var it = self.commands.valueIterator();
        while (it.next()) |bytes| self.allocator.free(bytes.*);
        self.commands.clearRetainingCapacity();
        self.order.clearRetainingCapacity();
    }

    fn putCommand(self: *TestRetainedHost, key: u64, bytes: []const u8) !void {
        const copy = try self.allocator.dupe(u8, bytes);
        if (try self.commands.fetchPut(key, copy)) |previous| self.allocator.free(previous.value);
    }

    /// Apply one wire payload the way the AppKit host does: keyed `clear`
    /// under a nonzero generation rebuilds the store, `patch` edits it
    /// (refusals drop it), anything else invalidates it.
    fn apply(self: *TestRetainedHost, payload: []const u8) !void {
        var cursor = BinaryCursor{ .bytes = payload };
        try cursor.expectBytes("NSGP");
        try std.testing.expectEqual(@as(u8, canvas.binary_packet_version), try cursor.readU8());
        const load_action = try cursor.readU8();
        const flags = try cursor.readU8();
        _ = try cursor.readU8(); // reserved
        const generation = try cursor.readU64();
        if (flags & 0x01 != 0) try cursor.skip(16); // scissor
        if (flags & 0x02 != 0) { // v3 dirty rect list
            const dirty_rect_count = try cursor.readU32();
            try std.testing.expect(dirty_rect_count >= 1);
            try std.testing.expect(dirty_rect_count <= canvas.max_canvas_frame_dirty_rects);
            try cursor.skip(@as(usize, dirty_rect_count) * 16);
        }
        // images + image actions
        const image_count = try cursor.readU32();
        try cursor.skip(@as(usize, image_count) * 24);
        const action_count = try cursor.readU32();
        try cursor.skip(@as(usize, action_count) * 21);

        switch (load_action) {
            2 => { // clear: keyed full present rebuilds the store
                const command_count = try cursor.readU32();
                self.clearCommands();
                for (0..command_count) |_| {
                    const key = try cursor.readU64();
                    const command_bytes = try cursor.command();
                    try self.putCommand(key, command_bytes);
                    try self.order.append(self.allocator, key);
                }
                self.generation = generation;
                self.valid = generation != 0;
                if (!self.valid) self.clearCommands();
            },
            3 => { // patch: edit script against the retained store
                try std.testing.expect(self.valid);
                try std.testing.expectEqual(self.generation, generation);
                const evict_count = try cursor.readU32();
                for (0..evict_count) |_| {
                    const key = try cursor.readU64();
                    const removed = self.commands.fetchRemove(key) orelse return error.PatchEvictMissing;
                    self.allocator.free(removed.value);
                }
                const upsert_count = try cursor.readU32();
                for (0..upsert_count) |_| {
                    const key = try cursor.readU64();
                    const command_bytes = try cursor.command();
                    try self.putCommand(key, command_bytes);
                }
                const order_count = try cursor.readU32();
                try std.testing.expectEqual(self.commands.count(), order_count);
                self.order.clearRetainingCapacity();
                for (0..order_count) |_| {
                    const key = try cursor.readU64();
                    if (!self.commands.contains(key)) return error.PatchOrderMissing;
                    try self.order.append(self.allocator, key);
                }
            },
            else => { // load subset (or unknown): the glass moved past the store
                self.valid = false;
                self.clearCommands();
                return;
            },
        }
        try std.testing.expectEqual(payload.len, cursor.offset);
    }

    /// Byte-for-byte equality of retained state (order + per-key encoded
    /// command bytes).
    fn expectEqualState(self: *const TestRetainedHost, other: *const TestRetainedHost) !void {
        try std.testing.expect(self.valid and other.valid);
        try std.testing.expectEqual(self.commands.count(), other.commands.count());
        try std.testing.expectEqualSlices(u64, self.order.items, other.order.items);
        for (self.order.items) |key| {
            const mine = self.commands.get(key) orelse return error.RetainedKeyMissing;
            const theirs = other.commands.get(key) orelse return error.RetainedKeyMissing;
            try std.testing.expectEqualSlices(u8, mine, theirs);
        }
    }
};

/// Bounds-checked reader over the v2 wire with a structural command
/// skipper, so the retained store can slice each command's exact encoded
/// bytes without decoding their content.
const BinaryCursor = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn expectBytes(self: *BinaryCursor, expected: []const u8) !void {
        if (self.offset + expected.len > self.bytes.len) return error.Truncated;
        try std.testing.expectEqualSlices(u8, expected, self.bytes[self.offset..][0..expected.len]);
        self.offset += expected.len;
    }

    fn skip(self: *BinaryCursor, count: usize) !void {
        if (self.offset + count > self.bytes.len) return error.Truncated;
        self.offset += count;
    }

    fn readU8(self: *BinaryCursor) !u8 {
        if (self.offset + 1 > self.bytes.len) return error.Truncated;
        defer self.offset += 1;
        return self.bytes[self.offset];
    }

    fn readU32(self: *BinaryCursor) !u32 {
        if (self.offset + 4 > self.bytes.len) return error.Truncated;
        defer self.offset += 4;
        return std.mem.readInt(u32, self.bytes[self.offset..][0..4], .little);
    }

    fn readU64(self: *BinaryCursor) !u64 {
        if (self.offset + 8 > self.bytes.len) return error.Truncated;
        defer self.offset += 8;
        return std.mem.readInt(u64, self.bytes[self.offset..][0..8], .little);
    }

    /// Skip one encoded command, returning its exact byte slice.
    fn command(self: *BinaryCursor) ![]const u8 {
        const start = self.offset;
        _ = try self.readU8(); // kind
        const flags = try self.readU8();
        try self.skip(16 + 4 + 4 + 1); // bounds + opacity + stroke_width + cap
        if (flags & 0x01 != 0) try self.skip(8); // id
        if (flags & 0x02 != 0) try self.skip(16); // clip
        if (flags & 0x04 != 0) try self.skip(24); // transform
        if (flags & 0x08 != 0) { // shape
            switch (try self.readU8()) {
                1 => try self.skip(16),
                2 => try self.skip(32),
                3 => try self.skip(36),
                4 => try self.skip(20),
                5 => {
                    const element_count = try self.readU32();
                    for (0..element_count) |_| {
                        const verb = try self.readU8();
                        const point_count: usize = switch (verb) {
                            0, 1 => 1,
                            2 => 2,
                            3 => 3,
                            4 => 0,
                            else => return error.UnknownShapeVerb,
                        };
                        try self.skip(point_count * 8);
                    }
                },
                else => return error.UnknownShapeTag,
            }
        }
        if (flags & 0x10 != 0) { // paint
            switch (try self.readU8()) {
                1 => try self.skip(16),
                2 => {
                    try self.skip(16); // start + end
                    const stop_count = try self.readU32();
                    try self.skip(@as(usize, stop_count) * 20);
                },
                else => return error.UnknownPaintTag,
            }
        }
        if (flags & 0x20 != 0) { // image
            try self.skip(8); // image id
            const has_src = try self.readU8();
            if (has_src != 0) try self.skip(16);
            try self.skip(16 + 4 + 1 + 1 + 16); // dst + opacity + fit + sampling + radius
        }
        if (flags & 0x40 != 0) { // text
            try self.skip(8 + 4 + 8 + 16); // font + size + origin + color
            const text_len = try self.readU32();
            try self.skip(text_len);
            const has_layout = try self.readU8();
            if (has_layout != 0) {
                try self.skip(4 + 4 + 1 + 1); // max width + line height + wrap + align
                const has_lines = try self.readU8();
                if (has_lines != 0) {
                    const line_count = try self.readU32();
                    for (0..line_count) |_| {
                        try self.skip(4 + 4); // x + baseline
                        const line_len = try self.readU32();
                        try self.skip(line_len);
                    }
                }
            }
        }
        if (flags & 0x80 != 0) { // effect
            switch (try self.readU8()) {
                1 => try self.skip(64),
                2 => try self.skip(20),
                else => return error.UnknownEffectTag,
            }
        }
        return self.bytes[start..self.offset];
    }
};

// ---------------------------------------------------------------------------
// Shared fixtures

const PatchHarnessApp = struct {
    fn app(self: *@This()) App {
        return .{ .context = self, .name = "gpu-canvas-patch", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
    }
};

const patch_surface_width: f32 = 320;
const patch_surface_height: f32 = 240;

fn createPatchHarness(app_state: *PatchHarnessApp) !*TestHarness() {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    errdefer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_packet_binary = true;
    try harness.start(app_state.app());
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, patch_surface_width, patch_surface_height),
    });
    return harness;
}

const PresentBuffers = struct {
    gpu_commands: []canvas.CanvasGpuCommand,
    packet_buffer: []u8,
    pixels: []u8,
    scratch: []u8,

    fn init(allocator: std.mem.Allocator) !PresentBuffers {
        const pixel_len: usize = @as(usize, @intFromFloat(patch_surface_width)) * @as(usize, @intFromFloat(patch_surface_height)) * 4;
        return .{
            .gpu_commands = try allocator.alloc(canvas.CanvasGpuCommand, max_canvas_commands_per_view),
            .packet_buffer = try allocator.alloc(u8, platform.max_gpu_surface_packet_binary_bytes),
            .pixels = try allocator.alloc(u8, pixel_len),
            .scratch = try allocator.alloc(u8, pixel_len),
        };
    }

    fn deinit(self: *PresentBuffers, allocator: std.mem.Allocator) void {
        allocator.free(self.gpu_commands);
        allocator.free(self.packet_buffer);
        allocator.free(self.pixels);
        allocator.free(self.scratch);
    }
};

fn presentFrame(harness: anytype, buffers: *PresentBuffers, frame_index: u64) !CanvasPresentationResult {
    return harness.runtime.presentNextCanvasFrame(1, "canvas", .{
        .frame_index = frame_index,
        .timestamp_ns = frame_index * 16_000,
        .surface_size = geometry.SizeF.init(patch_surface_width, patch_surface_height),
        .scale = 1,
    }, canvasFrameScratchStorage(&harness.runtime), buffers.gpu_commands, buffers.packet_buffer, buffers.pixels, buffers.scratch, canvas.Color.rgb8(15, 23, 42), null);
}

fn lastBinaryPayload(harness: anytype) []const u8 {
    return harness.null_platform.gpu_surface_packet_present_binary_storage[0..harness.null_platform.gpu_surface_packet_present_binary_len];
}

/// A message-list-shaped scene: per message a keyed bubble rect and a
/// keyed wrapped text run, plus one unkeyed separator line near the top
/// (the synthetic-key degradation case rides the golden script too).
fn buildScriptScene(
    step: usize,
    message_count: usize,
    scroll_offset: f32,
    text_storage: *[16][64]u8,
    commands: *[40]canvas.CanvasCommand,
) []const canvas.CanvasCommand {
    var count: usize = 0;
    commands[count] = .{ .draw_line = .{
        .from = geometry.PointF.init(8, 4 - scroll_offset),
        .to = geometry.PointF.init(patch_surface_width - 8, 4 - scroll_offset),
        .stroke = .{ .width = 1, .fill = .{ .color = canvas.Color.rgb8(71, 85, 105) } },
    } };
    count += 1;
    for (0..message_count) |row| {
        const y: f32 = @as(f32, @floatFromInt(row)) * 28 + 12 - scroll_offset;
        commands[count] = .{ .fill_rounded_rect = .{
            .id = @intCast(1_000 + row),
            .rect = geometry.RectF.init(8, y, patch_surface_width - 16, 24),
            .radius = canvas.Radius.all(6),
            // The "toggle": message 0's bubble flips color from step 1 on.
            .fill = .{ .color = if (row == 0 and step >= 1) canvas.Color.rgb8(37, 99, 235) else canvas.Color.rgb8(30, 41, 59) },
        } };
        count += 1;
        const text = std.fmt.bufPrint(&text_storage[row], "message {d} body{s}", .{
            row,
            // The "text edit": message 1's body grows a suffix from step 3 on.
            if (row == 1 and step >= 3) " (edited)" else "",
        }) catch unreachable;
        commands[count] = .{ .draw_text = .{
            .id = @intCast(2_000 + row),
            .font_id = 1,
            .size = 13,
            .origin = geometry.PointF.init(16, y + 16),
            .color = canvas.Color.rgb8(226, 232, 240),
            .text = text,
            .text_layout = .{ .max_width = patch_surface_width - 32, .line_height = 15, .wrap = .word },
        } };
        count += 1;
    }
    return commands[0..count];
}

// ---------------------------------------------------------------------------

test "golden: a scripted patch sequence leaves host retained state identical to full re-presents" {
    // Two engines drive the SAME scripted interaction (toggle, scroll
    // step, text edit, message eviction+insertion). Engine A's host
    // applies patches; engine B's host refuses them, so every B present
    // is a full keyed rebuild. After every step the two retained stores
    // must match byte-for-byte — command encodings AND draw order.
    var app_a: PatchHarnessApp = .{};
    const harness_a = try createPatchHarness(&app_a);
    defer harness_a.destroy(std.testing.allocator);
    var app_b: PatchHarnessApp = .{};
    const harness_b = try createPatchHarness(&app_b);
    defer harness_b.destroy(std.testing.allocator);
    harness_b.null_platform.gpu_surface_packet_binary_patch = false;

    var buffers = try PresentBuffers.init(std.testing.allocator);
    defer buffers.deinit(std.testing.allocator);

    var host_a = TestRetainedHost.init(std.testing.allocator);
    defer host_a.deinit();
    var host_b = TestRetainedHost.init(std.testing.allocator);
    defer host_b.deinit();

    var text_storage_a: [16][64]u8 = undefined;
    var text_storage_b: [16][64]u8 = undefined;
    var commands_a: [40]canvas.CanvasCommand = undefined;
    var commands_b: [40]canvas.CanvasCommand = undefined;

    // step 0: baseline; 1: toggle; 2: scroll step; 3: text edit;
    // 4: evict message 5, keep the rest (list shrinks).
    const steps = [_]struct { message_count: usize, scroll: f32 }{
        .{ .message_count = 6, .scroll = 0 },
        .{ .message_count = 6, .scroll = 0 },
        .{ .message_count = 6, .scroll = 12 },
        .{ .message_count = 6, .scroll = 12 },
        .{ .message_count = 5, .scroll = 12 },
    };

    for (steps, 0..) |step, step_index| {
        _ = try harness_a.runtime.setCanvasDisplayList(1, "canvas", .{
            .commands = buildScriptScene(step_index, step.message_count, step.scroll, &text_storage_a, &commands_a),
        });
        _ = try harness_b.runtime.setCanvasDisplayList(1, "canvas", .{
            .commands = buildScriptScene(step_index, step.message_count, step.scroll, &text_storage_b, &commands_b),
        });

        const result_a = try presentFrame(harness_a, &buffers, 10 + step_index);
        try std.testing.expectEqual(CanvasPresentationMode.gpu_packet, result_a.mode);
        try host_a.apply(lastBinaryPayload(harness_a));
        const result_b = try presentFrame(harness_b, &buffers, 10 + step_index);
        try std.testing.expectEqual(CanvasPresentationMode.gpu_packet, result_b.mode);
        try host_b.apply(lastBinaryPayload(harness_b));

        // A patches after its baseline — except the scroll step, where
        // EVERY command moved and a patch would exceed the full present,
        // so the engine deliberately re-baselines. B rebuilds every step.
        const expected_action: u8 = if (step_index == 0 or step_index == 2) 2 else canvas.binary_packet_load_action_patch;
        try std.testing.expectEqual(expected_action, harness_a.null_platform.gpu_surface_packet_present_binary_load_action);
        try std.testing.expectEqual(@as(u8, 2), harness_b.null_platform.gpu_surface_packet_present_binary_load_action);

        try host_a.expectEqualState(&host_b);
    }

    // The eviction step really evicted: message 5's bubble + text keys
    // are gone from the patched store.
    try std.testing.expect(host_a.commands.get(1_005) == null);
    try std.testing.expect(host_a.commands.get(2_005) == null);
    try std.testing.expect(harness_a.runtime.views[0].gpu_present_patch_evict_count >= 2);
}

test "patch presents carry only the change and the snapshot reports the mode" {
    var app_state: PatchHarnessApp = .{};
    const harness = try createPatchHarness(&app_state);
    defer harness.destroy(std.testing.allocator);
    var buffers = try PresentBuffers.init(std.testing.allocator);
    defer buffers.deinit(std.testing.allocator);

    var text_storage: [16][64]u8 = undefined;
    var commands: [40]canvas.CanvasCommand = undefined;
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{
        .commands = buildScriptScene(0, 6, 0, &text_storage, &commands),
    });
    const baseline = try presentFrame(harness, &buffers, 20);
    try std.testing.expectEqual(CanvasPresentationMode.gpu_packet, baseline.mode);
    const full_bytes = harness.null_platform.gpu_surface_packet_present_binary_len;
    try std.testing.expectEqual(@as(u8, 2), harness.null_platform.gpu_surface_packet_present_binary_load_action);
    try std.testing.expectEqual(platform.GpuPresentPacketMode.full, harness.runtime.views[0].gpu_present_packet_mode);
    try std.testing.expect(harness.runtime.views[0].canvas_packet_baseline_valid);

    // One toggled bubble color = one upsert riding a small patch.
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{
        .commands = buildScriptScene(1, 6, 0, &text_storage, &commands),
    });
    const toggled = try presentFrame(harness, &buffers, 21);
    try std.testing.expectEqual(CanvasPresentationMode.gpu_packet, toggled.mode);
    try std.testing.expectEqual(canvas.binary_packet_load_action_patch, harness.null_platform.gpu_surface_packet_present_binary_load_action);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_packet_present_binary_patch_count);
    const view = &harness.runtime.views[0];
    try std.testing.expectEqual(platform.GpuPresentPacketMode.patch, view.gpu_present_packet_mode);
    try std.testing.expectEqual(@as(usize, 1), view.gpu_present_patch_upsert_count);
    try std.testing.expectEqual(@as(usize, 0), view.gpu_present_patch_evict_count);
    try std.testing.expect(view.gpu_present_patch_bytes > 0);
    try std.testing.expect(view.gpu_present_patch_bytes < full_bytes);
    try std.testing.expectEqual(platform.GpuPresentFallbackReason.none, view.gpu_present_fallback_reason);

    // The automation snapshot line carries the incremental telemetry.
    var snapshot_buffer: [32768]u8 = undefined;
    var snapshot_writer = std.Io.Writer.fixed(&snapshot_buffer);
    try automation.snapshot.writeText(harness.runtime.automationSnapshot("Patch"), &snapshot_writer);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_writer.buffered(), "present_mode=patch") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_writer.buffered(), "present_patch_upserts=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_writer.buffered(), "present_retained_commands=13") != null);
}

test "rebuild dirty bounds derive from the patch edit script, not the window" {
    // A Msg-driven rebuild replaces the whole display list; the presented
    // summary cannot compare content, so historically the frame's dirty
    // bounds degraded to the full window even when the retained-patch
    // diff knew exactly one command changed. With a valid baseline the
    // planner now derives dirty bounds from that SAME edit script.
    var app_state: PatchHarnessApp = .{};
    const harness = try createPatchHarness(&app_state);
    defer harness.destroy(std.testing.allocator);
    var buffers = try PresentBuffers.init(std.testing.allocator);
    defer buffers.deinit(std.testing.allocator);

    // 72 keyed rects in a 8-wide grid.
    var rects: [72]canvas.CanvasCommand = undefined;
    const buildGrid = struct {
        fn rectAt(index: usize) geometry.RectF {
            const col: f32 = @floatFromInt(index % 8);
            const row: f32 = @floatFromInt(index / 8);
            return geometry.RectF.init(col * 38 + 2, row * 24 + 2, 30, 18);
        }
    };
    for (&rects, 0..) |*command, index| {
        command.* = .{ .fill_rect = .{
            .id = @intCast(3_000 + index),
            .rect = buildGrid.rectAt(index),
            .fill = .{ .color = canvas.Color.rgb8(30, 41, 59) },
        } };
    }
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &rects });
    const baseline = try presentFrame(harness, &buffers, 60);
    try std.testing.expectEqual(CanvasPresentationMode.gpu_packet, baseline.mode);
    try std.testing.expect(harness.runtime.views[0].canvas_packet_baseline_valid);

    // Rebuild with ONE color change: dirty is that command's rect, the
    // present is a one-upsert patch, and the wire scissor matches.
    rects[13].fill_rect.fill = .{ .color = canvas.Color.rgb8(37, 99, 235) };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &rects });
    const toggled = try presentFrame(harness, &buffers, 61);
    try std.testing.expectEqual(CanvasPresentationMode.gpu_packet, toggled.mode);
    try std.testing.expectEqualDeep(buildGrid.rectAt(13), toggled.frame.dirty_bounds.?);
    try std.testing.expectEqual(platform.GpuPresentPacketMode.patch, harness.runtime.views[0].gpu_present_packet_mode);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].gpu_present_patch_upsert_count);

    // Rebuild that MOVES a command: dirty covers old and new extents.
    const moved_from = buildGrid.rectAt(20);
    const moved_to = geometry.RectF.init(moved_from.x + 60, moved_from.y + 30, 30, 18);
    rects[20].fill_rect.rect = moved_to;
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &rects });
    const moved = try presentFrame(harness, &buffers, 62);
    try std.testing.expectEqualDeep(geometry.RectF.unionWith(moved_from, moved_to), moved.frame.dirty_bounds.?);

    // Identical rebuild (revision bumps, content does not): the edit
    // script is empty, so nothing presents at all.
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &rects });
    const unchanged = try presentFrame(harness, &buffers, 63);
    try std.testing.expectEqual(CanvasPresentationMode.skipped, unchanged.mode);

    // Reordering unchanged commands defeats a bounds union (overlap
    // pixels depend on z-order): refinement refuses and the frame keeps
    // the conservative summary dirty covering the keyed scene.
    const swap = rects[0];
    rects[0] = rects[1];
    rects[1] = swap;
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &rects });
    const reordered = try presentFrame(harness, &buffers, 64);
    try std.testing.expect(reordered.frame.dirty_bounds != null);
    try std.testing.expect(reordered.frame.dirty_bounds.?.width > 200);
    try std.testing.expect(reordered.frame.dirty_bounds.?.height > 100);
}

test "rebuild dirty bounds derive from the edit script on small command lists too" {
    // Refinement must have NO minimum command count: the index-vs-scan
    // floor elsewhere trades lookup cost with byte-identical results,
    // but refusing refinement changes the dirty AREA — a scene one
    // command under a floor would pay a full-window re-raster on every
    // Msg rebuild exactly where the derivation is cheapest. A real app
    // regressed this way when a styling round shrank its retained plan
    // from 64 to 62 commands and every click's present became a
    // full-surface repaint.
    var app_state: PatchHarnessApp = .{};
    const harness = try createPatchHarness(&app_state);
    defer harness.destroy(std.testing.allocator);
    var buffers = try PresentBuffers.init(std.testing.allocator);
    defer buffers.deinit(std.testing.allocator);

    // 12 keyed rects — far below any index floor — in a 4-wide grid
    // that fits the 320x240 harness surface.
    var rects: [12]canvas.CanvasCommand = undefined;
    const buildRow = struct {
        fn rectAt(index: usize) geometry.RectF {
            const col: f32 = @floatFromInt(index % 4);
            const row: f32 = @floatFromInt(index / 4);
            return geometry.RectF.init(col * 44 + 2, row * 24 + 2, 36, 20);
        }
    };
    for (&rects, 0..) |*command, index| {
        command.* = .{ .fill_rect = .{
            .id = @intCast(5_000 + index),
            .rect = buildRow.rectAt(index),
            .fill = .{ .color = canvas.Color.rgb8(30, 41, 59) },
        } };
    }
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &rects });
    const baseline = try presentFrame(harness, &buffers, 70);
    try std.testing.expectEqual(CanvasPresentationMode.gpu_packet, baseline.mode);
    try std.testing.expect(harness.runtime.views[0].canvas_packet_baseline_valid);

    // Rebuild with ONE color change: dirty is that command's rect, not
    // the window, and the present is a one-upsert patch.
    rects[7].fill_rect.fill = .{ .color = canvas.Color.rgb8(37, 99, 235) };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &rects });
    const toggled = try presentFrame(harness, &buffers, 71);
    try std.testing.expectEqual(CanvasPresentationMode.gpu_packet, toggled.mode);
    try std.testing.expectEqualDeep(buildRow.rectAt(7), toggled.frame.dirty_bounds.?);
    try std.testing.expectEqual(platform.GpuPresentPacketMode.patch, harness.runtime.views[0].gpu_present_packet_mode);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.views[0].gpu_present_patch_upsert_count);
}

test "a host that refuses patches gets a full resync in the same frame" {
    var app_state: PatchHarnessApp = .{};
    const harness = try createPatchHarness(&app_state);
    defer harness.destroy(std.testing.allocator);
    var buffers = try PresentBuffers.init(std.testing.allocator);
    defer buffers.deinit(std.testing.allocator);

    var text_storage: [16][64]u8 = undefined;
    var commands: [40]canvas.CanvasCommand = undefined;
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{
        .commands = buildScriptScene(0, 4, 0, &text_storage, &commands),
    });
    _ = try presentFrame(harness, &buffers, 30);
    try std.testing.expect(harness.runtime.views[0].canvas_packet_baseline_valid);

    // Model retained state loss: the host refuses the patch; the SAME
    // frame must land as a full keyed present on the packet path (no
    // pixel fallback), with the refusal recorded in the running
    // fallback-frame counter and the sticky reason cleared by the
    // successful resync.
    harness.null_platform.gpu_surface_packet_binary_patch = false;
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{
        .commands = buildScriptScene(1, 4, 0, &text_storage, &commands),
    });
    const resynced = try presentFrame(harness, &buffers, 31);
    try std.testing.expectEqual(CanvasPresentationMode.gpu_packet, resynced.mode);
    try std.testing.expectEqual(@as(u8, 2), harness.null_platform.gpu_surface_packet_present_binary_load_action);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_present_count);
    const view = &harness.runtime.views[0];
    try std.testing.expectEqual(platform.GpuPresentPacketMode.full, view.gpu_present_packet_mode);
    try std.testing.expectEqual(platform.GpuPresentFallbackReason.none, view.gpu_present_fallback_reason);
    try std.testing.expectEqual(@as(usize, 1), view.gpu_present_fallback_frame_count);
    try std.testing.expectEqual(platform.GpuPresentPath.packet, view.gpu_present_path);

    // Patches recover the moment the host applies them again (a text
    // edit touching one command; a scroll-everything step would
    // deliberately re-baseline instead).
    harness.null_platform.gpu_surface_packet_binary_patch = true;
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{
        .commands = buildScriptScene(3, 4, 0, &text_storage, &commands),
    });
    _ = try presentFrame(harness, &buffers, 32);
    try std.testing.expectEqual(canvas.binary_packet_load_action_patch, harness.null_platform.gpu_surface_packet_present_binary_load_action);
    try std.testing.expectEqual(platform.GpuPresentPacketMode.patch, view.gpu_present_packet_mode);
}

test "a patch that outgrows the transport buffer resolves to a full present" {
    // When ALMOST every command changes, the patch (upserts + the
    // order vector) encodes larger than the keyed full present; a
    // transport buffer sized exactly for the full encode forces the
    // patch-overflow branch, and the frame must land as a FULL packet
    // present — never a pixel fallback, never a truncated patch.
    // (When EVERY command changes the engine skips the patch attempt
    // outright — the golden test's scroll step pins that heuristic.)
    var app_state: PatchHarnessApp = .{};
    const harness = try createPatchHarness(&app_state);
    defer harness.destroy(std.testing.allocator);
    var buffers = try PresentBuffers.init(std.testing.allocator);
    defer buffers.deinit(std.testing.allocator);

    var rects: [12]canvas.CanvasCommand = undefined;
    for (0..rects.len) |index| {
        rects[index] = .{ .fill_rect = .{
            .id = @intCast(100 + index),
            .rect = geometry.RectF.init(@floatFromInt(index * 8), 8, 8, 8),
            .fill = .{ .color = canvas.Color.rgb8(30, 41, 59) },
        } };
    }
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &rects });
    _ = try presentFrame(harness, &buffers, 40);
    const full_bytes = harness.null_platform.gpu_surface_packet_present_binary_len;

    // Change all but one rect's color: same encoded size per command, so
    // the full present still fits the exact-size buffer while the patch
    // (11 of 12 re-encoded + the order vector on top) cannot.
    for (0..rects.len - 1) |index| {
        rects[index].fill_rect.fill = .{ .color = canvas.Color.rgb8(37, 99, 235) };
    }
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &rects });
    const exact_buffer = try std.testing.allocator.alloc(u8, full_bytes);
    defer std.testing.allocator.free(exact_buffer);
    const result = try harness.runtime.presentNextCanvasFrame(1, "canvas", .{
        .frame_index = 41,
        .timestamp_ns = 41 * 16_000,
        .surface_size = geometry.SizeF.init(patch_surface_width, patch_surface_height),
        .scale = 1,
    }, canvasFrameScratchStorage(&harness.runtime), buffers.gpu_commands, exact_buffer, buffers.pixels, buffers.scratch, canvas.Color.rgb8(15, 23, 42), null);
    try std.testing.expectEqual(CanvasPresentationMode.gpu_packet, result.mode);
    try std.testing.expectEqual(@as(u8, 2), harness.null_platform.gpu_surface_packet_present_binary_load_action);
    try std.testing.expectEqual(platform.GpuPresentPacketMode.full, harness.runtime.views[0].gpu_present_packet_mode);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_present_count);
}

test "a JSON present invalidates the retained baseline so the next binary present is full" {
    var app_state: PatchHarnessApp = .{};
    const harness = try createPatchHarness(&app_state);
    defer harness.destroy(std.testing.allocator);
    var buffers = try PresentBuffers.init(std.testing.allocator);
    defer buffers.deinit(std.testing.allocator);

    var text_storage: [16][64]u8 = undefined;
    var commands: [40]canvas.CanvasCommand = undefined;
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{
        .commands = buildScriptScene(0, 3, 0, &text_storage, &commands),
    });
    _ = try presentFrame(harness, &buffers, 50);
    try std.testing.expect(harness.runtime.views[0].canvas_packet_baseline_valid);

    // Binary host disappears for a frame: the JSON present bypasses the
    // retained protocol, so the baseline drops on the engine side too.
    harness.null_platform.gpu_surface_packet_binary = false;
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{
        .commands = buildScriptScene(1, 3, 0, &text_storage, &commands),
    });
    _ = try presentFrame(harness, &buffers, 51);
    try std.testing.expect(!harness.runtime.views[0].canvas_packet_baseline_valid);
    try std.testing.expectEqual(platform.GpuPresentPacketMode.full, harness.runtime.views[0].gpu_present_packet_mode);

    // Binary returns: the next present must be a FULL rebuild, not a
    // patch against state the host no longer holds.
    harness.null_platform.gpu_surface_packet_binary = true;
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{
        .commands = buildScriptScene(2, 3, 4, &text_storage, &commands),
    });
    _ = try presentFrame(harness, &buffers, 52);
    try std.testing.expectEqual(@as(u8, 2), harness.null_platform.gpu_surface_packet_present_binary_load_action);
    try std.testing.expect(harness.runtime.views[0].canvas_packet_baseline_valid);
}

test "chat-transcript-shaped interactions ride small patches" {
    // The 200-message transcript shape from the heavy-frame packet test,
    // driven through the interactions that dominate a chat view: a
    // hover/toggle color flip, a single text edit, and a message append.
    // Each must ride a patch that is a small fraction of the full
    // present; a scroll step (every command moves) deliberately
    // re-baselines with a full present instead of shipping a
    // bigger-than-full patch.
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-chat-patch", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_packet_binary = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    const surface_width: f32 = 480;
    const row_count: usize = 200;
    const row_height: f32 = 16;
    const surface_height: f32 = @as(f32, @floatFromInt(row_count)) * row_height + 64;
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, surface_width, surface_height),
    });

    var text_storage: [row_count][144]u8 = undefined;
    var glyph_storage: [row_count][40]canvas.Glyph = undefined;
    var command_storage: [row_count * 2]canvas.CanvasCommand = undefined;

    const Scene = struct {
        fn build(
            texts: *[row_count][144]u8,
            glyphs: *[row_count][40]canvas.Glyph,
            commands: *[row_count * 2]canvas.CanvasCommand,
            visible_rows: usize,
            scroll: f32,
            toggled_row: ?usize,
            edited_row: ?usize,
        ) []const canvas.CanvasCommand {
            var count: usize = 0;
            for (0..visible_rows) |row| {
                const text = std.fmt.bufPrint(&texts[row], "message {d:0>4}: the quick brown fox jumps over the lazy dog while the transcript keeps growing line after line{s}", .{
                    row,
                    if (edited_row != null and edited_row.? == row) " (edited)" else "",
                }) catch unreachable;
                for (0..glyphs[row].len) |glyph_index| {
                    glyphs[row][glyph_index] = .{
                        .id = @intCast(32 + (glyph_index * 7 + row) % 90),
                        .x = @floatFromInt(glyph_index * 7),
                        .y = 0,
                        .advance = 7,
                        .text_start = glyph_index,
                        .text_len = 1,
                    };
                }
                const y: f32 = @as(f32, @floatFromInt(row)) * row_height + 8 - scroll;
                commands[count] = .{ .fill_rounded_rect = .{
                    .id = @intCast(10_000 + row),
                    .rect = geometry.RectF.init(8, y - 4, surface_width - 16, row_height - 2),
                    .radius = canvas.Radius.all(6),
                    .fill = .{ .color = if (toggled_row != null and toggled_row.? == row) canvas.Color.rgb8(37, 99, 235) else canvas.Color.rgb8(30, 41, 59) },
                } };
                count += 1;
                commands[count] = .{ .draw_text = .{
                    .id = @intCast(20_000 + row),
                    .font_id = 1,
                    .size = 13,
                    .origin = geometry.PointF.init(16, y + 8),
                    .color = canvas.Color.rgb8(226, 232, 240),
                    .text = text,
                    .glyphs = &glyphs[row],
                    .text_layout = .{ .max_width = surface_width - 40, .line_height = 15, .wrap = .word },
                } };
                count += 1;
            }
            return commands[0..count];
        }
    };

    const gpu_commands = try std.testing.allocator.alloc(canvas.CanvasGpuCommand, max_canvas_commands_per_view);
    defer std.testing.allocator.free(gpu_commands);
    const packet_buffer = try std.testing.allocator.alloc(u8, platform.max_gpu_surface_packet_binary_bytes);
    defer std.testing.allocator.free(packet_buffer);
    const pixel_len: usize = @as(usize, @intFromFloat(surface_width)) * @as(usize, @intFromFloat(surface_height)) * 4;
    const pixels = try std.testing.allocator.alloc(u8, pixel_len);
    defer std.testing.allocator.free(pixels);
    const scratch = try std.testing.allocator.alloc(u8, pixel_len);
    defer std.testing.allocator.free(scratch);

    const present = struct {
        fn frame(h: anytype, gpu: []canvas.CanvasGpuCommand, buffer: []u8, px: []u8, sc: []u8, w: f32, hgt: f32, frame_index: u64) !CanvasPresentationResult {
            return h.runtime.presentNextCanvasFrame(1, "canvas", .{
                .frame_index = frame_index,
                .timestamp_ns = frame_index * 16_000,
                .surface_size = geometry.SizeF.init(w, hgt),
                .scale = 1,
            }, canvasFrameScratchStorage(&h.runtime), gpu, buffer, px, sc, canvas.Color.rgb8(15, 23, 42), null);
        }
    };

    // Baseline: 199 messages, full keyed present.
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{
        .commands = Scene.build(&text_storage, &glyph_storage, &command_storage, 199, 0, null, null),
    });
    _ = try present.frame(harness, gpu_commands, packet_buffer, pixels, scratch, surface_width, surface_height, 60);
    const full_bytes = harness.null_platform.gpu_surface_packet_present_binary_len;
    try std.testing.expectEqual(@as(u8, 2), harness.null_platform.gpu_surface_packet_present_binary_load_action);
    const view = &harness.runtime.views[0];

    // (a) One bubble toggled — a switch/hover-shaped frame.
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{
        .commands = Scene.build(&text_storage, &glyph_storage, &command_storage, 199, 0, 3, null),
    });
    _ = try present.frame(harness, gpu_commands, packet_buffer, pixels, scratch, surface_width, surface_height, 61);
    try std.testing.expectEqual(platform.GpuPresentPacketMode.patch, view.gpu_present_packet_mode);
    try std.testing.expectEqual(@as(usize, 1), view.gpu_present_patch_upsert_count);
    const toggle_patch_bytes = view.gpu_present_patch_bytes;
    try std.testing.expect(toggle_patch_bytes * 10 < full_bytes);

    // (b) One text edit.
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{
        .commands = Scene.build(&text_storage, &glyph_storage, &command_storage, 199, 0, 3, 7),
    });
    _ = try present.frame(harness, gpu_commands, packet_buffer, pixels, scratch, surface_width, surface_height, 62);
    try std.testing.expectEqual(platform.GpuPresentPacketMode.patch, view.gpu_present_packet_mode);
    try std.testing.expectEqual(@as(usize, 1), view.gpu_present_patch_upsert_count);
    const edit_patch_bytes = view.gpu_present_patch_bytes;
    try std.testing.expect(edit_patch_bytes * 10 < full_bytes);

    // (c) One message appended — the dominant chat-transcript frame shape.
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{
        .commands = Scene.build(&text_storage, &glyph_storage, &command_storage, 200, 0, 3, 7),
    });
    _ = try present.frame(harness, gpu_commands, packet_buffer, pixels, scratch, surface_width, surface_height, 63);
    try std.testing.expectEqual(platform.GpuPresentPacketMode.patch, view.gpu_present_packet_mode);
    try std.testing.expectEqual(@as(usize, 2), view.gpu_present_patch_upsert_count);
    const append_patch_bytes = view.gpu_present_patch_bytes;
    try std.testing.expect(append_patch_bytes * 10 < full_bytes);

    // (d) A scroll step moves every command: the engine re-baselines with
    // a full present rather than shipping a bigger-than-full patch.
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{
        .commands = Scene.build(&text_storage, &glyph_storage, &command_storage, 200, row_height, 3, 7),
    });
    _ = try present.frame(harness, gpu_commands, packet_buffer, pixels, scratch, surface_width, surface_height, 64);
    try std.testing.expectEqual(platform.GpuPresentPacketMode.full, view.gpu_present_packet_mode);
    try std.testing.expectEqual(@as(u8, 2), harness.null_platform.gpu_surface_packet_present_binary_load_action);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_present_count);

    // ...and patches resume on the next sparse change.
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{
        .commands = Scene.build(&text_storage, &glyph_storage, &command_storage, 200, row_height, 5, 7),
    });
    _ = try present.frame(harness, gpu_commands, packet_buffer, pixels, scratch, surface_width, surface_height, 65);
    try std.testing.expectEqual(platform.GpuPresentPacketMode.patch, view.gpu_present_packet_mode);
}

test "command fingerprints cover every encoded field" {
    // The patch differ trusts fingerprints as "byte-identical wire
    // encoding": a field that encodes but does not hash would ship stale
    // pixels. One mutation per encoded field must change the
    // fingerprint.
    const stops = [_]canvas.GradientStop{
        .{ .offset = 0, .color = canvas.Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = canvas.Color.rgb8(37, 99, 235) },
    };
    const glyphs = [_]canvas.Glyph{.{ .id = 4, .x = 1, .y = 2, .advance = 7 }};
    const base = canvas.CanvasGpuCommand{
        .command_index = 3,
        .id = 41,
        .kind = .draw_text,
        .bounds = geometry.RectF.init(1, 2, 3, 4),
        .opacity = 0.5,
        .stroke_width = 2,
        .clip = geometry.RectF.init(0, 0, 10, 10),
        .transform = canvas.Affine.translate(1, 1),
        .shape = .{ .rect = geometry.RectF.init(5, 5, 6, 6) },
        .paint = .{ .linear_gradient = .{ .start = geometry.PointF.init(0, 0), .end = geometry.PointF.init(1, 1), .stops = &stops } },
        .image = .{ .image_id = 9, .dst = geometry.RectF.init(0, 0, 4, 4) },
        .text = .{ .font_id = 1, .size = 13, .origin = geometry.PointF.init(2, 12), .color = canvas.Color.rgb8(1, 2, 3), .text = "hello", .glyphs = &glyphs, .text_layout = .{ .max_width = 100, .line_height = 15, .wrap = .word } },
        .effect = .{ .shadow = .{ .rect = geometry.RectF.init(0, 0, 4, 4), .blur = 2 } },
    };
    const base_fingerprint = canvas.canvasGpuCommandFingerprint(base);

    var changed = base;
    changed.kind = .fill_rect_solid;
    try std.testing.expect(canvas.canvasGpuCommandFingerprint(changed) != base_fingerprint);
    changed = base;
    changed.bounds = geometry.RectF.init(1, 2, 3, 5);
    try std.testing.expect(canvas.canvasGpuCommandFingerprint(changed) != base_fingerprint);
    changed = base;
    changed.opacity = 0.75;
    try std.testing.expect(canvas.canvasGpuCommandFingerprint(changed) != base_fingerprint);
    changed = base;
    changed.stroke_width = 3;
    try std.testing.expect(canvas.canvasGpuCommandFingerprint(changed) != base_fingerprint);
    changed = base;
    changed.cap = .round;
    try std.testing.expect(canvas.canvasGpuCommandFingerprint(changed) != base_fingerprint);
    changed = base;
    changed.id = 42;
    try std.testing.expect(canvas.canvasGpuCommandFingerprint(changed) != base_fingerprint);
    changed = base;
    changed.clip = geometry.RectF.init(0, 0, 11, 10);
    try std.testing.expect(canvas.canvasGpuCommandFingerprint(changed) != base_fingerprint);
    changed = base;
    changed.transform = canvas.Affine.translate(2, 1);
    try std.testing.expect(canvas.canvasGpuCommandFingerprint(changed) != base_fingerprint);
    changed = base;
    changed.shape = .{ .rect = geometry.RectF.init(5, 5, 7, 6) };
    try std.testing.expect(canvas.canvasGpuCommandFingerprint(changed) != base_fingerprint);
    changed = base;
    changed.paint = .{ .color = canvas.Color.rgb8(1, 1, 1) };
    try std.testing.expect(canvas.canvasGpuCommandFingerprint(changed) != base_fingerprint);
    changed = base;
    changed.image = .{ .image_id = 10, .dst = geometry.RectF.init(0, 0, 4, 4) };
    try std.testing.expect(canvas.canvasGpuCommandFingerprint(changed) != base_fingerprint);
    changed = base;
    changed.text.?.text = "hellp";
    try std.testing.expect(canvas.canvasGpuCommandFingerprint(changed) != base_fingerprint);
    changed = base;
    changed.text.?.color = canvas.Color.rgb8(1, 2, 4);
    try std.testing.expect(canvas.canvasGpuCommandFingerprint(changed) != base_fingerprint);
    changed = base;
    changed.text.?.text_layout = .{ .max_width = 101, .line_height = 15, .wrap = .word };
    try std.testing.expect(canvas.canvasGpuCommandFingerprint(changed) != base_fingerprint);
    const changed_glyphs = [_]canvas.Glyph{.{ .id = 5, .x = 1, .y = 2, .advance = 7 }};
    changed = base;
    changed.text.?.glyphs = &changed_glyphs;
    try std.testing.expect(canvas.canvasGpuCommandFingerprint(changed) != base_fingerprint);
    changed = base;
    changed.effect = .{ .shadow = .{ .rect = geometry.RectF.init(0, 0, 4, 4), .blur = 3 } };
    try std.testing.expect(canvas.canvasGpuCommandFingerprint(changed) != base_fingerprint);

    // Keyed commands retain under their ObjectId; unkeyed commands get a
    // synthetic key that changes when their index or content moves.
    try std.testing.expectEqual(@as(u64, 41), canvas.canvasGpuPacketCommandKey(base, base_fingerprint));
    var unkeyed = base;
    unkeyed.id = null;
    const unkeyed_fingerprint = canvas.canvasGpuCommandFingerprint(unkeyed);
    const synthetic = canvas.canvasGpuPacketCommandKey(unkeyed, unkeyed_fingerprint);
    var moved = unkeyed;
    moved.command_index = 4;
    try std.testing.expect(canvas.canvasGpuPacketCommandKey(moved, unkeyed_fingerprint) != synthetic);
}

test "the stroke end-cap rides the binary command encoding" {
    // The command model's cap channel must survive the wire: the host
    // strokes the checkbox mark's open polyline with the caps the
    // reference renderer rasterizes, so a dropped byte here is silent
    // cross-engine divergence. The cap sits at a fixed offset — key u64,
    // kind u8, flags u8, bounds f32[4], opacity f32, stroke_width f32 —
    // pinned against the host decoder's layout.
    const elements = [_]canvas.PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(4, 8), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(7, 11), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(12, 5), geometry.PointF.zero(), geometry.PointF.zero() } },
    };
    var command = canvas.CanvasGpuCommand{
        .command_index = 0,
        .id = 7,
        .kind = .stroke_path,
        .bounds = geometry.RectF.init(4, 5, 8, 6),
        .shape = .{ .path = &elements },
        .paint = .{ .color = canvas.Color.rgb8(255, 255, 255) },
        .stroke_width = 2,
        .cap = .round,
    };
    const cap_offset = 8 + 1 + 1 + 16 + 4 + 4;

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try canvas.writeCanvasGpuCommandBinaryKeyed(7, command, &writer);
    try std.testing.expectEqual(@as(u8, 1), writer.buffered()[cap_offset]);

    command.cap = .butt;
    var butt_writer = std.Io.Writer.fixed(&buffer);
    try canvas.writeCanvasGpuCommandBinaryKeyed(7, command, &butt_writer);
    try std.testing.expectEqual(@as(u8, 0), butt_writer.buffered()[cap_offset]);
}

test "pixel presents adopt a dirty-refinement baseline only for opted-in hosts and never feed patches" {
    // The mobile embed host presents through the CPU pixel path only and
    // opts in (`Options.pixel_present_retained_baseline`): pixel presents
    // then keep the keyed mirror alive so a one-command rebuild's dirty
    // bounds refine to that command. The mirror is marked pixel-adopted,
    // and a packet present that arrives against it must resync FULL —
    // no host ever retained a dictionary for a pixel present.
    var app_state: PatchHarnessApp = .{};
    const harness = try createPatchHarness(&app_state);
    defer harness.destroy(std.testing.allocator);
    var buffers = try PresentBuffers.init(std.testing.allocator);
    defer buffers.deinit(std.testing.allocator);
    harness.runtime.options.pixel_present_retained_baseline = true;

    // 72 keyed rects (past the small-list refinement gate) in a 8-wide grid.
    var rects: [72]canvas.CanvasCommand = undefined;
    const buildGrid = struct {
        fn rectAt(index: usize) geometry.RectF {
            const col: f32 = @floatFromInt(index % 8);
            const row: f32 = @floatFromInt(index / 8);
            return geometry.RectF.init(col * 38 + 2, row * 24 + 2, 30, 18);
        }
    };
    for (&rects, 0..) |*command, index| {
        command.* = .{ .fill_rect = .{
            .id = @intCast(3_000 + index),
            .rect = buildGrid.rectAt(index),
            .fill = .{ .color = canvas.Color.rgb8(30, 41, 59) },
        } };
    }
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &rects });
    _ = try harness.runtime.presentNextCanvasFramePixels(1, "canvas", .{
        .frame_index = 70,
        .timestamp_ns = 70 * 16_000,
        .surface_size = geometry.SizeF.init(patch_surface_width, patch_surface_height),
        .scale = 1,
    }, canvasFrameScratchStorage(&harness.runtime), buffers.pixels, buffers.scratch, canvas.Color.rgb8(15, 23, 42));
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_present_count);
    try std.testing.expect(harness.runtime.views[0].canvas_packet_baseline_valid);
    try std.testing.expect(harness.runtime.views[0].canvas_packet_baseline_pixels);

    // One changed rect: the next PIXEL present's dirty bounds are that
    // command's rect (the pixel-adopted mirror refined them), so a
    // mobile host uploads the rect, not the surface.
    rects[13].fill_rect.fill = .{ .color = canvas.Color.rgb8(37, 99, 235) };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &rects });
    const toggled = try harness.runtime.presentNextCanvasFramePixels(1, "canvas", .{
        .frame_index = 71,
        .timestamp_ns = 71 * 16_000,
        .surface_size = geometry.SizeF.init(patch_surface_width, patch_surface_height),
        .scale = 1,
    }, canvasFrameScratchStorage(&harness.runtime), buffers.pixels, buffers.scratch, canvas.Color.rgb8(15, 23, 42));
    try std.testing.expect(!toggled.full_repaint);
    try std.testing.expectEqualDeep(buildGrid.rectAt(13), toggled.dirty_bounds.?);
    try std.testing.expectEqualDeep(buildGrid.rectAt(13), harness.null_platform.gpu_surface_present_dirty_bounds.?);

    // A packet present against the pixel-adopted mirror resyncs FULL —
    // the patch gate refuses it even though the baseline is valid.
    rects[14].fill_rect.fill = .{ .color = canvas.Color.rgb8(220, 38, 38) };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &rects });
    const packet_resync = try presentFrame(harness, &buffers, 72);
    try std.testing.expectEqual(CanvasPresentationMode.gpu_packet, packet_resync.mode);
    try std.testing.expectEqual(@as(u8, 2), harness.null_platform.gpu_surface_packet_present_binary_load_action);
    try std.testing.expectEqual(platform.GpuPresentPacketMode.full, harness.runtime.views[0].gpu_present_packet_mode);
    try std.testing.expect(!harness.runtime.views[0].canvas_packet_baseline_pixels);

    // The packet-adopted baseline behaves exactly as before: the next
    // one-command change rides a patch.
    rects[15].fill_rect.fill = .{ .color = canvas.Color.rgb8(22, 163, 74) };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &rects });
    _ = try presentFrame(harness, &buffers, 73);
    try std.testing.expectEqual(canvas.binary_packet_load_action_patch, harness.null_platform.gpu_surface_packet_present_binary_load_action);
    try std.testing.expectEqual(platform.GpuPresentPacketMode.patch, harness.runtime.views[0].gpu_present_packet_mode);
}
