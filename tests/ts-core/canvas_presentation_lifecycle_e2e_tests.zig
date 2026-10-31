const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const p = sdk.runtime.testing.presentation_lifecycle_policy;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls: [13]usize = @splat(0);
fn observed(request: []const u8, output: []u8) usize {
    if (request[0] == 77) calls[request[2]] += 1;
    return core.nativeWindowPolicy(request, output);
}
const sizes = [_]usize{ 0, 1, 119, 120, 0xffffffff, 0x100000000, 9007199254740993, std.math.maxInt(usize) };
test "compiled presentation lifecycle preserves complete admission scratch and image decisions" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var programs: usize = 0;
    for (0..16) |flags| for (sizes) |commands| for (sizes) |capacity| {
        const f = p.Facts{ .requires_render = flags & 1 != 0, .view_exists = flags & 2 != 0, .software = flags & 4 != 0, .packet_service = flags & 8 != 0, .command_capacity = commands, .packet_capacity = capacity };
        const requested = !f.view_exists or !f.software;
        const offered = requested and commands > 0 and capacity > 0;
        const result = p.plan(.start, f, observed);
        const expected: p.Program = .{
            .instruction = if (!f.requires_render) .skipped else if (offered and f.packet_service) .packet else .pixels,
            .refusal = if (f.requires_render and offered and !f.packet_service) .missing_service else .none,
            .use_scratch = false,
            .should_log = false,
            .overflow = false,
            .fallback_count = 0,
            .logged_count = 0,
            .detail_bytes = 0,
        };
        try exact(expected, result);
        try exact(if (requested) p.Instruction.packet else .pixels, p.plan(.requested, f, observed).instruction);
        programs += 2;
        core.rt.frameReset();
    };
    for (sizes) |available| for (sizes) |needed| for ([_]bool{ false, true }) |render| {
        const got = p.plan(.pixels, .{ .requires_render = render, .scratch_capacity = available, .pixel_bytes = needed }, observed);
        try exact(if (render) p.Instruction.pixels else .skipped, got.instruction);
        try exact(render and available >= needed, got.use_scratch);
        programs += 1;
    };
    for (sizes) |index| for (sizes) |count| for (0..4) |flags| {
        const got = p.plan(.image_action, .{ .image_index = index, .image_count = count, .image_upload = flags & 1 != 0, .image_index_present = flags & 2 != 0 }, observed);
        try exact(if (flags == 3 and index < count) p.Instruction.observe_image else .skipped, got.instruction);
        programs += 1;
    };
    for (sizes) |width| for (sizes) |height| for (sizes) |bytes| {
        const got = p.plan(.image, .{ .image_width = width, .image_height = height, .image_bytes = bytes }, observed);
        try exact(if (width > 0 and height > 0 and bytes > 0) p.Instruction.upload else .skipped, got.instruction);
        programs += 1;
    };
    for ([_]bool{ false, true }) |ok| {
        const f = p.Facts{ .ok = ok, .representable = ok, .requires_render = ok, .retained_pixels = ok, .current = ok };
        try exact(if (ok) p.Instruction.upload else .pixels, p.plan(.built, f, observed).instruction);
        try exact(if (ok) p.Instruction.encode else .pixels, p.plan(.uploaded, f, observed).instruction);
        try exact(if (ok) p.Instruction.done else .pixels, p.plan(.encoded, f, observed).instruction);
        try exact(if (ok) p.Instruction.gather else .invalidate, p.plan(.baseline, f, observed).instruction);
        try exact(if (ok) p.Instruction.adopt else .invalidate, p.plan(.gathered, f, observed).instruction);
        try exact(p.Instruction.upload, p.plan(.direct, f, observed).instruction);
        try exact(if (ok) p.Refusal.missing_service else .unsupported_command, p.plan(.direct, f, observed).refusal);
        try exact(if (ok) p.Instruction.done else .skipped, p.plan(.rendering, f, observed).instruction);
        programs += 8;
    }
    const saved = p.plan(.pixels, .{ .requires_render = true, .scratch_capacity = 9007199254740993, .pixel_bytes = 9007199254740992 }, observed);
    const borrowed = core.rt.frameAlloc(u8, 32);
    @memset(borrowed, 0x5a);
    _ = p.plan(.image, .{ .image_width = 1, .image_height = 1, .image_bytes = 4 }, observed);
    try std.testing.expect(std.mem.allEqual(u8, borrowed, 0x5a));
    core.rt.frameReset();
    try std.testing.expect(saved.use_scratch);
    std.debug.print("Complete presentation lifecycle programs: {d}\n", .{programs});
}

const DiagnosticView = struct {
    open: bool = true,
    window_id: sdk.platform.WindowId = 1,
    label: []const u8 = "canvas",
    gpu_present_fallback_reason: sdk.platform.GpuPresentFallbackReason = .none,
    gpu_present_fallback_needed_bytes: usize = 0,
    gpu_present_fallback_limit_bytes: usize = 0,
    gpu_present_fallback_command_kind_storage: [32]u8 = @splat(0xa5),
    gpu_present_fallback_command_kind_len: usize = 0,
    gpu_present_fallback_frame_count: usize = 0,
    gpu_present_fallback_logged_count: usize = 0,
};
const Diagnostics = struct { views: [1]DiagnosticView = .{.{}}, view_count: usize = 1 };
test "compiled presentation lifecycle preserves complete native fallback diagnostics and untouched tails" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const reasons = std.meta.tags(sdk.platform.GpuPresentFallbackReason);
    const detail = "draw_text_layout_with_an_entirely_unrepresentable_command";
    var programs: usize = 0;
    for (sizes[0 .. sizes.len - 1]) |count| for (sizes[0 .. sizes.len - 1]) |logged| for (reasons) |before| for (reasons) |after| {
        if ((builtin.mode == .Debug or builtin.mode == .ReleaseSafe) and count != 0 and before == after and count + 1 < logged) continue;
        var expected = Diagnostics{};
        expected.views[0].gpu_present_fallback_frame_count = count;
        expected.views[0].gpu_present_fallback_logged_count = logged;
        expected.views[0].gpu_present_fallback_reason = before;
        var actual = expected;
        sdk.runtime.testing.referencePresentationFallback(&expected, 1, "canvas", .{ .reason = after, .needed_bytes = 9007199254740993, .limit_bytes = 0x100000000, .command_kind = detail });
        sdk.runtime.testing.compiledPresentationFallback(&actual, 1, "canvas", .{ .reason = after, .needed_bytes = 9007199254740993, .limit_bytes = 0x100000000, .command_kind = detail }, observed);
        try exact(expected, actual);
        core.rt.frameReset();
        try exact(expected, actual);
        programs += 1;
    };
    var missing = Diagnostics{};
    const saved = missing;
    sdk.runtime.testing.compiledPresentationFallback(&missing, 9, "missing", .{ .reason = .missing_service }, observed);
    try exact(saved, missing);
    std.debug.print("Complete fallback diagnostic programs: {d}\n", .{programs});
}
test "compiled presentation lifecycle preserves checked counter overflow and release wrapping verdicts" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const checked = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
    const max: usize = std.math.maxInt(usize);
    const full = p.plan(.fallback, .{ .fallback_count = max, .logged_count = 0, .previous_reason = .missing_service, .reason = .missing_service }, observed);
    try exact(checked, full.overflow);
    try exact(if (checked) max else @as(usize, 0), full.fallback_count);
    const below = p.plan(.fallback, .{ .fallback_count = 1, .logged_count = max, .previous_reason = .missing_service, .reason = .missing_service }, observed);
    try exact(checked, below.overflow);
    const change = p.plan(.fallback, .{ .fallback_count = 1, .logged_count = max, .previous_reason = .missing_service, .reason = .unsupported_command }, observed);
    try std.testing.expect(!change.overflow and change.should_log);
    const first = p.plan(.fallback, .{ .logged_count = max }, observed);
    try std.testing.expect(!first.overflow and first.should_log);
}
