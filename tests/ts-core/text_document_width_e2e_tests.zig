//! Actual compiled decisions against independent native document measurement,
//! with exact retained fields, complete call traces and frame reset ownership.
const std = @import("std");
const sdk = @import("native_sdk");
const c = sdk.canvas;
const core = @import("ts_persist_core");
const exact = @import("component_construction_e2e_tests.zig").exact;
const Trace = struct { batch: usize = 0, scalar: usize = 0, decline_at: usize = 0, invalid_at: usize = 0, calls: [32]u8 = @splat(0) };
fn record(t: *Trace, kind: u8, font: u64, size: f32, text: []const u8) void {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(&t.calls);
    h.update(&.{kind});
    h.update(std.mem.asBytes(&font));
    h.update(std.mem.asBytes(&size));
    h.update(text);
    h.final(&t.calls);
}
fn scalar(ctx: ?*anyopaque, font: u64, size: f32, text: []const u8) f32 {
    const t: *Trace = @ptrCast(@alignCast(ctx.?));
    t.scalar += 1;
    record(t, 2, font, size, text);
    return @as(f32, @floatFromInt(text.len)) * size * 0.1;
}
fn batch(ctx: ?*anyopaque, font: u64, size: f32, text: []const u8, out: []f32) bool {
    const t: *Trace = @ptrCast(@alignCast(ctx.?));
    t.batch += 1;
    record(t, 1, font, size, text);
    if (t.batch == t.decline_at) return false;
    for (text, 0..) |byte, i| out[i] = if (byte & 192 == 128) 0 else size * 0.1;
    if (t.batch == t.invalid_at) out[out.len - 1] = std.math.inf(f32);
    return true;
}
const Observation = struct { width: f32, generation: u64, font: u64, size_bits: u32, trace: Trace };
fn observe(widget: c.Widget, trace: Trace) Observation {
    return .{ .width = widget.code_content_width, .generation = widget.code_content_width_generation, .font = widget.code_content_width_font_id, .size_bits = widget.code_content_width_size_bits, .trace = trace };
}
test "compiled document width preserves complete longest-line results and provider order at every chunk boundary" {
    _ = core.initialModel();
    const storage = try std.testing.allocator.alloc(u8, 131077);
    defer std.testing.allocator.free(storage);
    const lengths = [_]usize{ 0, 1, 15, 65535, 65536, 65537, 131076, 131077 };
    for (lengths) |length| for (0..4) |newlines| {
        @memset(storage, 'x');
        if (newlines == 1 and length > 0) storage[length - 1] = '\n';
        if (newlines == 2) for ([_]usize{ 0, 65535, 131071 }) |at| {
            if (at < length) storage[at] = '\n';
        };
        if (newlines == 3) for (storage[0..length], 0..) |*byte, i| {
            if (i % 13 == 0) byte.* = '\n';
        };
        for (0..7) |provider_kind| {
            c.bumpTextMeasureGeneration();
            var expected: [3]Observation = undefined;
            var traces: [2]Trace = @splat(.{ .decline_at = if (provider_kind == 3) 2 else if (provider_kind == 5) 1 else 0, .invalid_at = if (provider_kind == 4) 2 else if (provider_kind == 6) 1 else 0 });
            for ([_]?c.text_document_policy.Policy{ null, core.nativeWindowPolicy }, 0..) |owner, lane| {
                const t = &traces[lane];
                var provider: c.TextMeasureProvider = .{ .context = t, .measure_fn = scalar, .measure_advances_fn = if (provider_kind >= 2) batch else null };
                var tokens: c.DesignTokens = .{ .text_measure = if (provider_kind == 0) null else &provider, .text_run_policy = owner };
                tokens.typography.mono_font_id = 0xf123456789abcdef;
                var widget: c.Widget = .{ .kind = .textarea, .text = storage[0..length], .text_no_wrap = true };
                widget.runtime_flags.code_editor = true;
                // Separate cache lifetimes without changing the copied global generation.
                for (0..3) |step| {
                    if (step == 2) {
                        widget.code_content_width_generation = 0;
                        tokens.typography.mono_font_id ^= 0x8000000000000000;
                    }
                    c.cacheTextInputContentWidthForWidget(&widget, tokens);
                    const got = observe(widget, t.*);
                    if (lane == 0) expected[step] = got else try exact(expected[step], got);
                    if (step == 1) try exact(expected[0].trace, t.*);
                    core.rt.frameReset();
                }
                // Evict the advance facts before switching lane, preserving the generation.
                // Changing provider identity makes every provider result lane-local.
            }
        }
    };
}

test "compiled document width exact cache words and diff union never alias a stale retained width" {
    _ = core.initialModel();
    var widget: c.Widget = .{ .kind = .textarea, .text_no_wrap = true };
    widget.runtime_flags.code_editor = true;
    widget.code_content_width_generation = c.textMeasureGeneration();
    widget.code_content_width_font_id = 0xf123456789abcdef;
    widget.code_content_width_size_bits = @bitCast(@as(f32, 13.25));
    const owner = core.nativeWindowPolicy;
    for ([_]f32{ 0, -0.0, 1, -1, std.math.nan(f32), std.math.inf(f32) }) |width| {
        widget.code_content_width = width;
        try std.testing.expectEqual(@as(u32, @intFromBool(width >= 0 and std.math.isFinite(width))), c.text_document_policy.cacheDecision(owner, widget, widget.code_content_width_font_id, 13.25, false));
    }
    widget.code_content_width = 1;
    try std.testing.expectEqual(@as(u32, 0), c.text_document_policy.cacheDecision(owner, widget, widget.code_content_width_font_id ^ 0x8000000000000000, 13.25, false));
    try std.testing.expectEqual(@as(u32, 0), c.text_document_policy.cacheDecision(owner, widget, widget.code_content_width_font_id, -0.0, false));
    widget.setCodeDiffLines(.{ .added = 0xffff000000000001, .removed = 0xffff000000000002 });
    const before = widget.codeDiffLines();
    const tokens: c.DesignTokens = .{ .text_run_policy = owner };
    c.cacheTextInputContentWidthForWidget(&widget, tokens);
    try exact(before, widget.codeDiffLines());
    try std.testing.expectEqual(@as(u32, 0), c.text_document_policy.cacheDecision(owner, widget, 0, 0, true));
    try std.testing.expectEqual(@as(u32, 0), c.text_document_policy.cacheDecision(owner, widget, 0, 0, false));
}

test "compiled document width preserves complete horizontal geometry and scalar fallbacks for raw bytes and diff editors" {
    _ = core.initialModel();
    for ([_][]const u8{ "", "abc\nlonger line\n", "\xff\x00café 🙂界\xe2\x80", "\n\n\n" }) |text| {
        for ([_]f32{ 0, -0.0, 0.125, 13.25, 1000 }) |size| {
            for (0..4) |configuration| {
                c.bumpTextMeasureGeneration();
                var traces: [2]Trace = @splat(.{});
                var expected: f32 = undefined;
                for ([_]?c.text_document_policy.Policy{ null, core.nativeWindowPolicy }, 0..) |owner, lane| {
                    const provider: c.TextMeasureProvider = .{ .context = &traces[lane], .measure_fn = scalar };
                    var tokens: c.DesignTokens = .{ .text_measure = &provider, .text_run_policy = owner };
                    tokens.typography.body_size = size;
                    var widget: c.Widget = .{ .kind = .textarea, .text = text, .text_no_wrap = configuration != 2, .frame = .{ .width = 70, .height = 80 }, .code_line_number_digits = 2 };
                    widget.runtime_flags.code_editor = configuration != 1;
                    if (configuration == 3) widget.setCodeDiffLines(.{ .added = 7, .removed = 9 });
                    const before = widget.codeDiffLines();
                    c.cacheTextInputContentWidthForWidget(&widget, tokens);
                    try exact(before, widget.codeDiffLines());
                    const width = c.textInputMaxHorizontalScrollOffsetForWidget(widget, tokens);
                    if (lane == 0) expected = width else {
                        try exact(expected, width);
                        try exact(traces[0], traces[1]);
                    }
                    core.rt.frameReset();
                }
            }
        }
    }
}

var adoption_calls: [3]usize = @splat(0);
var adoption_context: u8 = 0;
fn adoptionOwner(request: []const u8, result: []u8) usize {
    if (request[0] == 59) adoption_calls[request[2]] += 1;
    return core.nativeWindowPolicy(request, result);
}
fn rejectedAdoptionOwner(_: []const u8, _: []u8) usize {
    @panic("rejected layout must not invoke its owner");
}
fn adoptionApp() sdk.App {
    return .{ .context = &adoption_context, .name = "document-adoption", .source = sdk.WebViewSource.html("<h1>Document</h1>") };
}
test "compiled document width traversal owns first retained adoption before display tokens arrive" {
    _ = core.initialModel();
    const Ui = c.Ui(enum { unused });
    const reference = try sdk.TestHarness().create(std.testing.allocator, .{});
    defer reference.destroy(std.testing.allocator);
    const compiled = try sdk.TestHarness().create(std.testing.allocator, .{});
    defer compiled.destroy(std.testing.allocator);
    var expected: [2]c.WidgetLayoutNode = undefined;
    for ([_]?c.text_document_policy.Policy{ null, adoptionOwner }, 0..) |owner, lane| {
        adoption_calls = @splat(0);
        const h = if (lane == 0) reference else compiled;
        h.null_platform.gpu_surfaces = true;
        try h.start(adoptionApp());
        _ = try h.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(0, 0, 320, 100) });
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = Ui.init(arena.allocator());
        const tree = try ui.finalize(ui.code(.{ .editable = true, .wrap = false, .height = 75 }, "first\na longer line\n"));
        var nodes: [4]c.WidgetLayoutNode = undefined;
        const tokens: c.DesignTokens = .{ .text_run_policy = owner };
        const layout = try c.layoutWidgetTreeWithTokens(tree.root, .init(0, 0, 320, 100), tokens, &nodes);
        try std.testing.expect(h.runtime.views[0].widget_tokens.text_run_policy == null);
        var first_traversal_calls: usize = 0;
        for (0..2) |turn| {
            _ = try h.runtime.setCanvasWidgetLayout(1, "canvas", layout);
            const retained = h.runtime.views[0].widgetLayoutTree();
            try std.testing.expectEqual(@as(usize, 1), retained.nodes.len);
            try std.testing.expectEqual(owner, retained.text_run_policy);
            try std.testing.expectEqual(owner, h.runtime.views[0].widget_tokens.text_run_policy);
            if (lane == 0) expected[turn] = retained.nodes[0] else try exact(expected[turn], retained.nodes[0]);
            if (lane == 0) try std.testing.expectEqual([3]usize{ 0, 0, 0 }, adoption_calls) else {
                try std.testing.expect(adoption_calls[0] > 0 and adoption_calls[1] > 0 and adoption_calls[2] > 0);
                if (turn == 0) first_traversal_calls = adoption_calls[2] else try std.testing.expectEqual(first_traversal_calls, adoption_calls[2]);
            }
            core.rt.frameReset();
        }
        var rejected = layout;
        rejected.nodes = try arena.allocator().alloc(c.WidgetLayoutNode, h.runtime.views[0].widget_layout_nodes.len + 1);
        rejected.text_run_policy = rejectedAdoptionOwner;
        const before_rejection = adoption_calls;
        try std.testing.expectError(error.WidgetNodeLimitReached, h.runtime.setCanvasWidgetLayout(1, "canvas", rejected));
        try std.testing.expectEqual(owner, h.runtime.views[0].widget_tokens.text_run_policy);
        try std.testing.expectEqual(before_rejection, adoption_calls);
        try exact(expected[1], h.runtime.views[0].widgetLayoutTree().nodes[0]);
    }
}
