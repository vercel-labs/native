//! system-monitor tests: fixture-based parsers against committed real
//! command output, the whole sampling loop through the fake effects
//! executor (repeating timer, collect-mode spawns, in-flight tick
//! skipping, pause/resume), TestClock-driven sample timestamps and the
//! 60-sample history ring, sort/search/kill flows through typed tree
//! dispatch, theming, markup engine parity, automation snapshot
//! assertions, and the precision tile layout.

const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");
const model_mod = @import("model.zig");
const sampler = @import("sampler.zig");
const theme = @import("theme.zig");
const view_mod = @import("view.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;
const builtin = @import("builtin");

const Model = main.Model;
const Msg = main.Msg;
const Ui = view_mod.Ui;
const App = main.MonitorApp;

const ps_fixture = @embedFile("fixtures/ps.txt");
const ps_edge_fixture = @embedFile("fixtures/ps-edge.txt");
const vm_stat_fixture = @embedFile("fixtures/vm_stat.txt");
const sysctl_fixture = @embedFile("fixtures/sysctl.txt");

// Facts about the committed real capture (see fixtures/README note in the
// example README): 561 system rows, pid 1 at 02:49:06, %cpu summing 45.7.
const fixture_process_count = 561;
const fixture_uptime_seconds: u64 = 2 * 3600 + 49 * 60 + 6;
const fixture_cpu_sum: f32 = 45.7;
// vm_stat capture: (794612 active + 136740 wired + 58043 compressor)
// pages of 16384 bytes.
const fixture_mem_used: u64 = (794_612 + 136_740 + 58_043) * 16_384;
const fixture_mem_total: u64 = 34_359_738_368;
const fixture_cores: u32 = 10;

// ------------------------------------------------------------- tree utils

fn buildTree(arena: std.mem.Allocator, model: *const Model) !Ui.Tree {
    var ui = Ui.init(arena);
    return ui.finalizeWithTokens(view_mod.rootView(&ui, model), main.tokensFromModel(model));
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

fn findByKind(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.Widget {
    if (widget.kind == kind) return widget;
    for (widget.children) |child| {
        if (findByKind(child, kind)) |found| return found;
    }
    return null;
}

fn findByLabel(widget: canvas.Widget, label: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findByLabel(child, label)) |found| return found;
    }
    return null;
}

fn findTextContaining(widget: canvas.Widget, needle: []const u8) ?canvas.Widget {
    if (widget.kind == .text and std.mem.indexOf(u8, widget.text, needle) != null) return widget;
    for (widget.children) |child| {
        if (findTextContaining(child, needle)) |found| return found;
    }
    return null;
}

fn countListItems(widget: canvas.Widget) usize {
    var total: usize = 0;
    // Process rows are table rows on the table register (the header
    // data_row carries no per-process label, so exclude it by kind+label).
    if (widget.kind == .data_row and widget.semantics.label.len > 0) total += 1;
    for (widget.children) |child| total += countListItems(child);
    return total;
}

// -------------------------------------------------------------- fixtures

test "parsePs digests the committed real ps capture" {
    const sample = sampler.parsePs(ps_fixture);
    try testing.expectEqual(@as(u32, fixture_process_count), sample.process_count);
    try testing.expectEqual(@as(u32, 0), sample.skipped_lines);
    try testing.expectEqual(fixture_uptime_seconds, sample.uptime_seconds);
    try testing.expectApproxEqAbs(fixture_cpu_sum, sample.cpu_sum, 0.05);

    // Top-K selection is exact: every kept row burns at least as much CPU
    // as every dropped one, which for this capture means the minimum kept
    // value is the K-th highest overall — and pid 1 parsed cleanly.
    try testing.expectEqual(@as(usize, sampler.max_rows), sample.row_count);
    var kept_min: f32 = std.math.floatMax(f32);
    for (sample.topRows()) |row| kept_min = @min(kept_min, row.cpu);
    var above_or_equal: usize = 0;
    var lines = std.mem.splitScalar(u8, ps_fixture, '\n');
    while (lines.next()) |line| {
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        _ = tokens.next() orelse continue;
        const cpu_text = tokens.next() orelse continue;
        const cpu = std.fmt.parseFloat(f32, cpu_text) catch continue;
        if (cpu >= kept_min) above_or_equal += 1;
    }
    try testing.expect(above_or_equal >= sampler.max_rows);
}

test "parsePs edge cases: day etimes, spaces in comm, garbage lines" {
    const sample = sampler.parsePs(ps_edge_fixture);
    try testing.expectEqual(@as(u32, 5), sample.process_count);
    try testing.expectEqual(@as(u32, 1), sample.skipped_lines);
    // pid 1 with a day-form etime: 3 days + 02:49:06.
    try testing.expectEqual(@as(u64, 3 * 86_400 + fixture_uptime_seconds), sample.uptime_seconds);
    try testing.expectApproxEqAbs(@as(f32, 102.9), sample.cpu_sum, 0.01);

    var names: [8][]const u8 = undefined;
    var count: usize = 0;
    for (sample.topRows()) |*row| {
        names[count] = row.name();
        count += 1;
    }
    try testing.expectEqual(@as(usize, 5), count);
    // comm is the untokenized rest of the line: paths with spaces keep
    // their basename, un-pathed names keep their spaces whole.
    try testing.expect(containsName(names[0..count], "suhelperd"));
    try testing.expect(containsName(names[0..count], "Core Audio Driver (Example.driver)"));
    try testing.expect(containsName(names[0..count], "renderfarm-worker"));
}

fn containsName(names: []const []const u8, wanted: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, wanted)) return true;
    }
    return false;
}

test "top-K keeps the highest-CPU rows regardless of output order" {
    // 200 synthetic rows with ascending cpu (0.0 .. 19.9): the kept set
    // must be exactly the last 128 (cpu >= 7.2).
    var buffer: [200 * 48]u8 = undefined;
    var len: usize = 0;
    for (0..200) |index| {
        const line = std.fmt.bufPrint(buffer[len..], "  {d}  {d:.1}  0.0  100 01:00 /bin/worker-{d}\n", .{
            index + 2, @as(f32, @floatFromInt(index)) / 10.0, index,
        }) catch unreachable;
        len += line.len;
    }
    const sample = sampler.parsePs(buffer[0..len]);
    try testing.expectEqual(@as(u32, 200), sample.process_count);
    try testing.expectEqual(@as(usize, sampler.max_rows), sample.row_count);
    for (sample.topRows()) |row| {
        try testing.expect(row.cpu >= 7.2 - 0.001);
    }
}

test "parseEtime handles every ps elapsed-time form" {
    try testing.expectEqual(@as(?u64, 42), sampler.parseEtime("00:42"));
    try testing.expectEqual(@as(?u64, 3723), sampler.parseEtime("1:02:03"));
    try testing.expectEqual(@as(?u64, 86_400 + 1), sampler.parseEtime("1-00:00:01"));
    try testing.expectEqual(@as(?u64, 12 * 86_400 + 23 * 3600 + 59 * 60 + 59), sampler.parseEtime("12-23:59:59"));
    try testing.expectEqual(@as(?u64, null), sampler.parseEtime("nonsense"));
    try testing.expectEqual(@as(?u64, null), sampler.parseEtime("1:2:3:4"));
}

test "parseVmStat computes used bytes from the committed real capture" {
    const sample = sampler.parseVmStat(vm_stat_fixture).?;
    try testing.expectEqual(fixture_mem_used, sample.used_bytes);
    try testing.expectEqual(@as(u64, 0), sample.total_bytes);
    try testing.expect(sampler.parseVmStat("no banner here") == null);
}

test "parseMeminfo reads totals and availability (Linux path, pure)" {
    // Constructed in /proc/meminfo's documented shape (no Linux capture
    // machine here — stated honestly in the README).
    const meminfo =
        \\MemTotal:       16323412 kB
        \\MemFree:         1250840 kB
        \\MemAvailable:    9034612 kB
        \\Buffers:          422044 kB
    ;
    const sample = sampler.parseMeminfo(meminfo).?;
    try testing.expectEqual(@as(u64, 16_323_412 * 1024), sample.total_bytes);
    try testing.expectEqual(@as(u64, (16_323_412 - 9_034_612) * 1024), sample.used_bytes);
    try testing.expect(sampler.parseMeminfo("MemTotal: 10 kB") == null);
}

test "parseHostInfo reads the committed sysctl capture" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const info = sampler.parseHostInfo(sysctl_fixture).?;
    try testing.expectEqual(fixture_cores, info.cores);
    try testing.expectEqual(fixture_mem_total, info.memory_bytes);
}

// -------------------------------------------------------------- app utils

const surface_size = geometry.SizeF.init(main.window_width, main.window_height);

const LiveApp = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *App,
    app: native_sdk.App,

    fn start() !LiveApp {
        const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = surface_size });
        errdefer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;

        const app_state = try testing.allocator.create(App);
        errdefer testing.allocator.destroy(app_state);
        app_state.* = App.init(std.heap.page_allocator, .{}, main.monitorOptions());
        app_state.effects.executor = .fake;
        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = main.canvas_label,
            .size = surface_size,
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        return .{ .harness = harness, .app_state = app_state, .app = app };
    }

    fn stop(self: LiveApp) void {
        self.app_state.deinit();
        testing.allocator.destroy(self.app_state);
        self.harness.destroy(testing.allocator);
    }

    fn dispatch(self: LiveApp, msg: Msg) !void {
        try self.app_state.dispatch(&self.harness.runtime, 1, msg);
    }

    fn wake(self: LiveApp) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .wake);
    }

    /// Feed one collect spawn's whole stdout and exit 0, then drain.
    fn finishSpawn(self: LiveApp, key: u64, output: []const u8) !void {
        try self.app_state.effects.feedLine(key, output);
        try self.app_state.effects.feedExit(key, 0);
        try self.wake();
    }

    fn spawnByKey(self: LiveApp, key: u64) ?model_mod.Effects.SpawnRequest {
        var index: usize = 0;
        while (self.app_state.effects.pendingSpawnAt(index)) |request| : (index += 1) {
            if (request.key == key) return request;
        }
        return null;
    }
};

/// Update with a throwaway fake effects channel for pure model tests.
fn apply(model: *Model, msg: Msg) void {
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(model, msg, &fx);
}

// --------------------------------------------------------------- sampling

test "boot arms the sampler: host info, the repeating timer, an eager sample" {
    if (!sampler.supported) return error.SkipZigTest;
    const live = try LiveApp.start();
    defer live.stop();
    const effects = &live.app_state.effects;

    // The repeating 2 s timer and all three collect spawns are requested.
    const timer = effects.pendingTimerAt(0).?;
    try testing.expectEqual(model_mod.sample_timer_key, timer.key);
    try testing.expectEqual(@as(u64, model_mod.sample_interval_ms), timer.interval_ms);

    const info = live.spawnByKey(model_mod.info_key).?;
    try testing.expectEqual(canvas_collect, info.output);
    const ps = live.spawnByKey(model_mod.ps_key).?;
    try testing.expectEqualStrings("/bin/ps", ps.argv[0]);
    try testing.expectEqualStrings("axo", ps.argv[1]);
    try testing.expect(live.spawnByKey(model_mod.mem_key) != null);
    try testing.expect(live.app_state.model.ps_inflight);
    try testing.expect(live.app_state.model.mem_inflight);
}

const canvas_collect = native_sdk.EffectOutputMode.collect;

test "a full sample lands: fixtures through the collect exits, TestClock timestamps" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const live = try LiveApp.start();
    defer live.stop();
    const model = &live.app_state.model;

    var test_clock = native_sdk.TestClock{};
    test_clock.setWallMs(1_000_000); // 00:16:40 UTC
    live.app_state.effects.clock = test_clock.clock();

    // Host info first so the CPU figure normalizes by real cores.
    try live.finishSpawn(model_mod.info_key, sysctl_fixture);
    try testing.expectEqual(fixture_cores, model.cores);
    try testing.expectEqual(fixture_mem_total, model.mem_total_bytes);

    try live.finishSpawn(model_mod.ps_key, ps_fixture);
    try testing.expectEqual(@as(u32, fixture_process_count), model.process_count);
    try testing.expectEqual(fixture_uptime_seconds, model.uptime_seconds);
    try testing.expectApproxEqAbs(fixture_cpu_sum / @as(f32, fixture_cores), model.cpu_percent, 0.05);
    try testing.expectEqual(@as(i64, 1_000_000), model.sampled_at_ms);
    try testing.expectEqual(@as(usize, 1), model.cpu_history_len);
    try testing.expectEqual(@as(usize, 1), model.proc_history_len);
    try testing.expect(!model.ps_inflight);

    try live.finishSpawn(model_mod.mem_key, vm_stat_fixture);
    try testing.expectEqual(fixture_mem_used, model.mem_used_bytes);
    try testing.expectApproxEqAbs(@as(f32, 0.4718), model.memFraction(), 0.001);
    try testing.expectEqual(@as(usize, 1), model.mem_history_len);

    // The status line derives the facts, including the TestClock stamp.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const status = model.statusLine(arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, status, "561 processes") != null);
    try testing.expect(std.mem.indexOf(u8, status, "00:16:40") != null);

    // The next tick spawns a fresh pair; a tick while they are in flight
    // is skipped and counted, never overlapped.
    try live.app_state.effects.fireTimer(model_mod.sample_timer_key);
    try live.wake();
    try testing.expect(model.ps_inflight);
    try testing.expect(live.spawnByKey(model_mod.ps_key) != null);
    try testing.expect(live.spawnByKey(model_mod.mem_key) != null);
    try live.app_state.effects.fireTimer(model_mod.sample_timer_key);
    try live.wake();
    try testing.expectEqual(@as(u32, 1), model.ticks_skipped);
}

test "pause cancels the repeating timer; resume re-arms and samples eagerly" {
    if (!sampler.supported) return error.SkipZigTest;
    const live = try LiveApp.start();
    defer live.stop();
    const model = &live.app_state.model;
    const effects = &live.app_state.effects;

    try testing.expect(model.sampling());
    try live.dispatch(.toggle_sampling);
    try testing.expect(model.paused);
    try testing.expectEqual(@as(usize, 0), effects.pendingTimerCount());
    try testing.expectError(error.EffectNotFound, effects.fireTimer(model_mod.sample_timer_key));

    // Resume: the timer re-arms (start on an active key replaces in
    // place) and an eager sample is requested — here the boot spawns are
    // still in flight, so it lands as a counted skip instead of overlap.
    try live.dispatch(.toggle_sampling);
    try testing.expect(!model.paused);
    try testing.expectEqual(@as(usize, 1), effects.pendingTimerCount());
    try testing.expectEqual(@as(u32, 1), model.ticks_skipped);
}

test "the history ring holds exactly 60 samples, oldest shifted out" {
    var model = Model{};
    model.cores = 1;
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    for (0..model_mod.history_len + 5) |index| {
        var line_buffer: [64]u8 = undefined;
        const output = std.fmt.bufPrint(&line_buffer, "  1  {d}.0  0.1  100 00:10 /sbin/launchd", .{index % 90}) catch unreachable;
        main.update(&model, .{ .ps_done = .{ .key = model_mod.ps_key, .code = 0, .output = output } }, &fx);
    }
    try testing.expectEqual(@as(usize, model_mod.history_len), model.cpu_history_len);
    try testing.expectEqual(@as(u32, model_mod.history_len + 5), model.samples_taken);
    // Oldest first: sample #5 (cpu 5%) now leads; the newest is #64.
    try testing.expectApproxEqAbs(@as(f32, 0.05), model.cpu_history[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 64.0 / 100.0), model.cpu_history[model_mod.history_len - 1], 0.0001);

    // The sparkline is ONE chart widget over the full sample window
    // (the pre-primitive design was sixty bar widgets): a zero-baseline
    // bar series pinned to the 0..1 core-fraction domain, padded with
    // leading NaN while the ring fills so the trace enters from the
    // right.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const tree = try buildTree(arena_state.allocator(), &model);
    const chart = findByLabel(tree.root, "CPU history").?;
    try testing.expectEqual(@as(usize, 0), chart.children.len);
    try testing.expectEqual(@as(usize, 1), chart.chart.series.len);
    try testing.expectEqual(native_sdk.canvas.ChartSeriesKind.bar, chart.chart.series[0].kind);
    try testing.expectEqual(@as(usize, model_mod.history_len), chart.chart.series[0].values.len);
    try testing.expectEqual(@as(?f32, 0), chart.chart.y_min);
    try testing.expectEqual(@as(?f32, 1), chart.chart.y_max);
    // Newest sample at the right edge; a full ring has no NaN padding.
    try testing.expectApproxEqAbs(@as(f32, 64.0 / 100.0), chart.chart.series[0].values[model_mod.history_len - 1], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.05), chart.chart.series[0].values[0], 0.0001);
}

test "a filling history ring pads the sparkline with leading missing samples" {
    var model = Model{};
    model.cores = 1;
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    for (0..5) |_| {
        main.update(&model, .{ .ps_done = .{ .key = model_mod.ps_key, .code = 0, .output = "  1  50.0  0.1  100 00:10 /sbin/launchd" } }, &fx);
    }

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const tree = try buildTree(arena_state.allocator(), &model);
    const chart = findByLabel(tree.root, "CPU history").?;
    const values = chart.chart.series[0].values;
    try testing.expectEqual(@as(usize, model_mod.history_len), values.len);
    // Leading slots are NaN (drawn as nothing), the 5 real samples sit at
    // the right edge — the scope-trace entry the bar design had.
    try testing.expect(std.math.isNan(values[0]));
    try testing.expect(std.math.isNan(values[model_mod.history_len - 6]));
    try testing.expectApproxEqAbs(@as(f32, 0.5), values[model_mod.history_len - 1], 0.0001);
}

// ----------------------------------------------------------- table logic

fn edgeModel() Model {
    var model = Model{};
    model.cores = 4;
    apply(&model, .{ .ps_done = .{ .key = model_mod.ps_key, .code = 0, .output = ps_edge_fixture } });
    return model;
}

test "sort toggles switch keys and flip direction through the widget path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model = edgeModel();

    // Default: CPU descending — the busiest process leads.
    var rows = model.visibleRows(arena);
    try testing.expectEqualStrings("renderfarm-worker", rows[0].name);

    // Press the active CPU chip: direction flips to ascending.
    var tree = try buildTree(arena, &model);
    const cpu_chip = findByText(tree.root, .toggle_button, "CPU").?;
    apply(&model, tree.msgFor(cpu_chip.id, .toggle).?);
    try testing.expect(!model.sort_descending);
    rows = model.visibleRows(arena);
    try testing.expectEqualStrings("0.0", rows[0].cpu_text);

    // Press Name: a fresh key starts in its natural direction (a-to-z).
    tree = try buildTree(arena, &model);
    const name_chip = findByText(tree.root, .toggle_button, "Name").?;
    apply(&model, tree.msgFor(name_chip.id, .toggle).?);
    try testing.expectEqual(model_mod.SortKey.name, model.sort_key);
    try testing.expect(!model.sort_descending);
    rows = model.visibleRows(arena);
    try testing.expectEqualStrings("Core Audio Driver (Example.driver)", rows[0].name);

    // Memory sorts by resident size, biggest first.
    apply(&model, .{ .set_sort = .mem });
    try testing.expect(model.sort_descending);
    rows = model.visibleRows(arena);
    try testing.expectEqualStrings("renderfarm-worker", rows[0].name);

    // PID ascending puts launchd first.
    apply(&model, .{ .set_sort = .pid });
    rows = model.visibleRows(arena);
    try testing.expectEqualStrings("1", rows[0].pid_text);
}

test "search filters by name and pid through typed dispatch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model = edgeModel();

    var tree = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, 5), countListItems(tree.root));

    // Type into the filter field: the edit dispatches through on_input.
    const field = findByKind(tree.root, .search_field).?;
    apply(&model, tree.msgForTextEdit(field.id, .{ .insert_text = "render" }).?);
    try testing.expectEqualStrings("render", model.search());
    tree = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, 1), countListItems(tree.root));

    // Digits match pids: "204" hits 1204 and 2048.
    model.search_buffer = canvas.TextBuffer(model_mod.max_search).init("204");
    try testing.expectEqual(@as(usize, 2), model.matchCount(arena));

    // Clear restores everything. The filter field carries the BUILT-IN
    // trailing clear affordance (no external chip): the press stamps a
    // `.clear` edit through the same on-input channel keystrokes use.
    tree = try buildTree(arena, &model);
    const searching_field = findByKind(tree.root, .search_field).?;
    apply(&model, tree.msgForTextEdit(searching_field.id, .clear).?);
    try testing.expectEqualStrings("", model.search());
    tree = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, 5), countListItems(tree.root));
    try testing.expect(findByLabel(tree.root, "Clear filter") == null);

    // No matches renders the empty state instead of a list.
    model.search_buffer = canvas.TextBuffer(model_mod.max_search).init("zzzz");
    tree = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, 0), countListItems(tree.root));
    try testing.expect(findByLabel(tree.root, "No processes match") != null);
}

test "the process rows are table rows and the table scroll is controlled" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model = edgeModel();

    // Rows are real table rows (data_row > data_cell): the engine owns
    // the chrome — full-width hover wash, hairline separators, no
    // per-row card boxes.
    var tree = try buildTree(arena, &model);
    const row = findByLabel(tree.root, "renderfarm-worker pid 842").?;
    try testing.expectEqual(canvas.WidgetKind.data_row, row.kind);
    try testing.expect(findByText(row, .data_cell, "renderfarm-worker") != null);

    // The scroll echoes the model-owned offset: the applied offset lands
    // in the model and the next build carries it.
    apply(&model, .{ .table_scrolled = .{ .offset = 66 } });
    try testing.expectEqual(@as(f32, 66), model.table_scroll);
    tree = try buildTree(arena, &model);
    const scroll = findByKind(tree.root, .scroll_view).?;
    try testing.expectEqual(@as(f32, 66), scroll.value);
}

// -------------------------------------------------------------- kill flow

test "terminate flows context menu -> confirmation -> /bin/kill -TERM" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model = edgeModel();
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // The context menu's first item opens the confirmation — never the
    // signal directly. The separator index is inert.
    var tree = try buildTree(arena, &model);
    const row = findByLabel(tree.root, "renderfarm-worker pid 842").?;
    try testing.expect(tree.msgForContextMenu(row.id, 1) == null);
    main.update(&model, tree.msgForContextMenu(row.id, 0).?, &fx);
    try testing.expect(model.confirmingKill());
    try testing.expectEqual(@as(usize, 0), fx.pendingSpawnCount());

    // The dialog names the process and pid; the scrim and dialog carry
    // their labels; Cancel closes without any spawn.
    tree = try buildTree(arena, &model);
    try testing.expect(findByLabel(tree.root, "Confirm termination") != null);
    try testing.expect(findByText(tree.root, .text, "renderfarm-worker (pid 842) will be asked to quit.") != null);
    const cancel = findByText(tree.root, .button, "Cancel").?;
    main.update(&model, tree.msgForPointer(cancel.id, .up).?, &fx);
    try testing.expect(!model.confirmingKill());
    try testing.expectEqual(@as(usize, 0), fx.pendingSpawnCount());
    tree = try buildTree(arena, &model);
    try testing.expect(findByLabel(tree.root, "Confirm termination") == null);

    // Confirm: exactly `/bin/kill -TERM <pid>` — SIGTERM, nothing else.
    main.update(&model, .{ .request_kill = 842 }, &fx);
    tree = try buildTree(arena, &model);
    const confirm = findByText(tree.root, .button, "Send SIGTERM").?;
    main.update(&model, tree.msgForPointer(confirm.id, .up).?, &fx);
    try testing.expect(!model.confirmingKill());
    const request = fx.pendingSpawnAt(0).?;
    try testing.expectEqual(model_mod.kill_key, request.key);
    try testing.expectEqual(@as(usize, 3), request.argv.len);
    try testing.expectEqualStrings("/bin/kill", request.argv[0]);
    try testing.expectEqualStrings("-TERM", request.argv[1]);
    try testing.expectEqualStrings("842", request.argv[2]);

    // Exit outcomes land in the status note, success and failure alike.
    try fx.feedExit(model_mod.kill_key, 0);
    // Drain through a live-style poll is not available on a bare fx; the
    // exit Msg is asserted through the app-level test below.

    // Pressing the dialog body must NOT cancel (the press-absorber arm).
    main.update(&model, .{ .request_kill = 842 }, &fx);
    tree = try buildTree(arena, &model);
    const dialog = findByKind(tree.root, .dialog).?;
    main.update(&model, tree.msgForPointer(dialog.id, .up).?, &fx);
    try testing.expect(model.confirmingKill());

    // A pid that left the sample cannot arm the dialog.
    model.pending_kill = null;
    main.update(&model, .{ .request_kill = 99_999 }, &fx);
    try testing.expect(!model.confirmingKill());
    try testing.expect(std.mem.indexOf(u8, model.note(), "gone") != null);
}

test "kill and copy exits land as status notes through the live loop" {
    if (!sampler.supported) return error.SkipZigTest;
    const live = try LiveApp.start();
    defer live.stop();
    const model = &live.app_state.model;

    apply(model, .{ .ps_done = .{ .key = model_mod.ps_key, .code = 0, .output = ps_edge_fixture } });
    try live.dispatch(.{ .request_kill = 842 });
    try live.dispatch(.confirm_kill);
    try testing.expect(std.mem.indexOf(u8, model.note(), "SIGTERM sent to renderfarm-worker (pid 842)") != null);
    try live.app_state.effects.feedExit(model_mod.kill_key, 0);
    try live.wake();
    try testing.expect(std.mem.indexOf(u8, model.note(), "delivered") != null);

    // A failing kill (not your process) is a note, never fatal.
    try live.dispatch(.{ .request_kill = 1 });
    try live.dispatch(.confirm_kill);
    try live.app_state.effects.feedExit(model_mod.kill_key, 1);
    try live.wake();
    try testing.expect(std.mem.indexOf(u8, model.note(), "kill failed") != null);

    // Copy Name runs the clipboard effect with the process name.
    try live.dispatch(.{ .copy_name = 842 });
    const clip = live.app_state.effects.pendingClipboardAt(0).?;
    try testing.expectEqual(model_mod.copy_key, clip.key);
    try testing.expectEqualStrings("renderfarm-worker", clip.text);
    try live.app_state.effects.feedClipboardResult(model_mod.copy_key, .ok, "");
    try live.wake();
    try testing.expect(std.mem.indexOf(u8, model.note(), "name copied") != null);
}

// ---------------------------------------------------------------- theming

test "the system appearance drives the ops tokens live" {
    if (!sampler.supported) return error.SkipZigTest;
    const live = try LiveApp.start();
    defer live.stop();
    const app_state = live.app_state;

    try testing.expectEqualDeep(theme.light_colors, main.tokensFromModel(&app_state.model).colors);

    // The OS flips to dark; the app follows it — there is no in-window
    // theme control by design.
    try live.harness.runtime.dispatchPlatformEvent(live.app, .{ .appearance_changed = .{ .color_scheme = .dark } });
    try testing.expectEqualDeep(theme.dark_colors, (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);

    try live.harness.runtime.dispatchPlatformEvent(live.app, .{ .appearance_changed = .{ .color_scheme = .light } });
    try testing.expectEqualDeep(theme.light_colors, (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);

    // High contrast falls back to the framework palette (accessibility
    // beats brand).
    try live.harness.runtime.dispatchPlatformEvent(live.app, .{ .appearance_changed = .{ .color_scheme = .dark, .high_contrast = true } });
    try testing.expectEqualDeep(canvas.ColorTokens.highContrastDark(), (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);
}

// ----------------------------------------------------------------- markup

test "markup engine parity: the header builds identical trees" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    apply(&model, .{ .set_appearance = .{ .color_scheme = .dark } });

    // The header imports its status-line component, so the interpreter
    // side resolves the same embedded source set the compiled engine
    // merged at comptime — both engines see one document.
    var set_loader = canvas.ui_markup.SourceSetLoader{ .set = &view_mod.header_markup_files };
    var diagnostic: canvas.ui_markup.MarkupErrorInfo = .{};
    const header_document = try canvas.ui_markup.resolveImports(arena, "header.native", view_mod.header_markup, set_loader.loader(), &diagnostic);
    var interpreter = canvas.MarkupView(Model, Msg).fromDocument(try canvas.ui_markup.canonicalize(arena, header_document));
    var compiled_ui = Ui.init(arena);
    const compiled = try compiled_ui.finalize(view_mod.CompiledHeaderView.build(&compiled_ui, &model));
    var interpreted_ui = Ui.init(arena);
    const interpreted = try interpreted_ui.finalize(try interpreter.build(&interpreted_ui, &model));

    var compiled_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer compiled_ids.deinit(testing.allocator);
    var interpreted_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer interpreted_ids.deinit(testing.allocator);
    try collectIds(compiled.root, &compiled_ids, testing.allocator);
    try collectIds(interpreted.root, &interpreted_ids, testing.allocator);
    try testing.expectEqualSlices(canvas.ObjectId, interpreted_ids.items, compiled_ids.items);
    try testing.expectEqual(interpreted.handlers.len, compiled.handlers.len);
}

fn collectIds(widget: canvas.Widget, ids: *std.ArrayListUnmanaged(canvas.ObjectId), allocator: std.mem.Allocator) !void {
    try ids.append(allocator, widget.id);
    for (widget.children) |child| try collectIds(child, ids, allocator);
}

// -------------------------------------------------------------- precision

test "the stat tiles land on exact frames and the tree stays in budget" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = edgeModel();
    // Full history = the widest tree this app ever mounts.
    for (0..model_mod.history_len) |_| {
        apply(&model, .{ .ps_done = .{ .key = model_mod.ps_key, .code = 0, .output = ps_edge_fixture } });
        apply(&model, .{ .mem_done = .{ .key = model_mod.mem_key, .code = 0, .output = vm_stat_fixture } });
    }
    if (builtin.os.tag != .macos) {
        // parseMemory switches per OS; keep the layout test portable.
        model.mem_history_len = model_mod.history_len;
        for (&model.mem_history) |*value| value.* = 0.5;
    }

    const tree = try buildTree(arena_state.allocator(), &model);
    var nodes: [1024]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, main.window_width, main.window_height), &nodes);
    try testing.expect(layout.nodes.len > 0);
    // The chart retrofit collapsed 3 sparklines x 60 bar widgets into 3
    // chart leaves; the whole app now mounts in a fraction of the old
    // 640-node worst case.
    try testing.expect(layout.nodes.len < 460);

    const labels = [_][]const u8{ "CPU tile", "Memory tile", "Processes tile", "Uptime tile" };
    var seen: usize = 0;
    for (layout.nodes) |node| {
        for (labels, 0..) |label, index| {
            if (!std.mem.eql(u8, node.widget.semantics.label, label)) continue;
            seen += 1;
            const expected_x = view_mod.window_padding + @as(f32, @floatFromInt(index)) * (view_mod.tile_width + view_mod.tile_gap);
            try testing.expectEqual(expected_x, node.frame.x);
            try testing.expectEqual(view_mod.tile_width, node.frame.width);
            try testing.expectEqual(view_mod.tile_height, node.frame.height);
            try testing.expect(node.frame.x + node.frame.width <= main.window_width - view_mod.window_padding + 0.5);
        }
    }
    try testing.expectEqual(@as(usize, 4), seen);

    // Sparkline charts land exactly on the designed box.
    for (layout.nodes) |node| {
        if (!std.mem.eql(u8, node.widget.semantics.label, "CPU history")) continue;
        try testing.expectEqual(view_mod.spark_width, node.frame.width);
        try testing.expectEqual(view_mod.spark_height, node.frame.height);
    }
}

test "layout audit sweep: nothing clips, overlaps, or escapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = edgeModel();
    // Full history = the widest tree this app ever mounts.
    for (0..model_mod.history_len) |_| {
        apply(&model, .{ .ps_done = .{ .key = model_mod.ps_key, .code = 0, .output = ps_edge_fixture } });
        apply(&model, .{ .mem_done = .{ .key = model_mod.mem_key, .code = 0, .output = vm_stat_fixture } });
    }
    if (builtin.os.tag != .macos) {
        model.mem_history_len = model_mod.history_len;
        for (&model.mem_history) |*value| value.* = 0.5;
    }

    // The main window: machined tile geometry, so the floor is the
    // designed content size itself (declared on the window).
    const tree = try buildTree(arena_state.allocator(), &model);
    try canvas.expectLayoutAuditSweepClean(testing.allocator, tree.root, .{
        .tokens = main.tokensFromModel(&model),
        .min_size = geometry.SizeF.init(main.window_min_width, main.window_min_height),
        .default_size = geometry.SizeF.init(main.window_width, main.window_height),
    });

    // The settings window ships fixed-size; audit it at exactly that.
    model.settings_open = true;
    var ui = Ui.init(arena_state.allocator());
    const settings = try ui.finalizeWithTokens(view_mod.settingsView(&ui, &model), main.tokensFromModel(&model));
    const settings_size = geometry.SizeF.init(main.settings_window_width, main.settings_window_height);
    try canvas.expectLayoutAuditSweepClean(testing.allocator, settings.root, .{
        .tokens = main.tokensFromModel(&model),
        .min_size = settings_size,
        .default_size = settings_size,
        .large_size = settings_size,
    });
}

test "a11y audit sweep: every interactive widget is named, reachable, and unambiguous" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = edgeModel();
    for (0..model_mod.history_len) |_| {
        apply(&model, .{ .ps_done = .{ .key = model_mod.ps_key, .code = 0, .output = ps_edge_fixture } });
        apply(&model, .{ .mem_done = .{ .key = model_mod.mem_key, .code = 0, .output = vm_stat_fixture } });
    }
    if (builtin.os.tag != .macos) {
        model.mem_history_len = model_mod.history_len;
        for (&model.mem_history) |*value| value.* = 0.5;
    }

    const tree = try buildTree(arena_state.allocator(), &model);
    try canvas.expectA11yAuditSweepClean(testing.allocator, tree.root, .{
        .tokens = main.tokensFromModel(&model),
        .min_size = geometry.SizeF.init(main.window_min_width, main.window_min_height),
        .default_size = geometry.SizeF.init(main.window_width, main.window_height),
    });

    // The settings window, at its fixed size.
    model.settings_open = true;
    var ui = Ui.init(arena_state.allocator());
    const settings = try ui.finalizeWithTokens(view_mod.settingsView(&ui, &model), main.tokensFromModel(&model));
    const settings_size = geometry.SizeF.init(main.settings_window_width, main.settings_window_height);
    try canvas.expectA11yAuditSweepClean(testing.allocator, settings.root, .{
        .tokens = main.tokensFromModel(&model),
        .min_size = settings_size,
        .default_size = settings_size,
        .large_size = settings_size,
    });
}

// -------------------------------------------------------------- snapshots

test "automation snapshot names the tiles and drives pause/resume" {
    if (!sampler.supported) return error.SkipZigTest;
    const live = try LiveApp.start();
    defer live.stop();
    const model = &live.app_state.model;

    var snapshot = live.harness.runtime.automationSnapshot("System Monitor");
    for ([_][]const u8{ "CPU tile", "Memory tile", "Processes tile", "Uptime tile", "Pause or resume sampling", "Filter processes", "Sort by CPU", "Sort by Memory" }) |name| {
        try testing.expect(snapshotByName(snapshot, name) != null);
    }

    // Click the sampling chip through the automation widget path: the
    // timer cancels; a second click re-arms it.
    const chip = snapshotByName(snapshot, "Pause or resume sampling").?;
    var command_buffer: [96]u8 = undefined;
    const press = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ main.canvas_label, chip.id });
    try live.harness.runtime.dispatchAutomationCommand(live.app, press);
    try testing.expect(model.paused);
    try testing.expectEqual(@as(usize, 0), live.app_state.effects.pendingTimerCount());
    snapshot = live.harness.runtime.automationSnapshot("System Monitor");
    const resumed_chip = snapshotByName(snapshot, "Pause or resume sampling").?;
    const press_again = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ main.canvas_label, resumed_chip.id });
    try live.harness.runtime.dispatchAutomationCommand(live.app, press_again);
    try testing.expect(!model.paused);
    try testing.expectEqual(@as(usize, 1), live.app_state.effects.pendingTimerCount());
}

fn snapshotByName(snapshot: native_sdk.automation.snapshot.Input, name: []const u8) ?native_sdk.automation.snapshot.Widget {
    for (snapshot.widgets) |widget| {
        if (std.mem.eql(u8, widget.name, name)) return widget;
    }
    return null;
}

// ------------------------------------------------------- settings window

fn settingsWindowInfo(live: LiveApp) ?native_sdk.WindowInfo {
    var buffer: [16]native_sdk.WindowInfo = undefined;
    for (live.harness.runtime.listWindows(&buffer)) |info| {
        if (std.mem.eql(u8, info.label, main.settings_window_label)) return info;
    }
    return null;
}

fn settingsWidgetIdByLabel(live: LiveApp, window_id: u64, label: []const u8) !?canvas.ObjectId {
    const layout = try live.harness.runtime.canvasWidgetLayout(window_id, main.settings_canvas_label);
    for (layout.nodes) |node| {
        if (std.mem.eql(u8, node.widget.semantics.label, label)) return node.widget.id;
    }
    return null;
}

test "the settings window opens by the settings command, drives sampling from its own canvas, and round-trips close" {
    if (!sampler.supported) return error.SkipZigTest;
    const live = try LiveApp.start();
    defer live.stop();
    const model = &live.app_state.model;
    try testing.expect(settingsWindowInfo(live) == null);

    // Open through the REAL command path: the registered settings
    // shortcut id via the automation shortcut channel — the same
    // platform event a primary+comma keypress (or the app-menu Settings
    // item) emits, resolved through `main.command`.
    var command_buffer: [96]u8 = undefined;
    try live.harness.runtime.dispatchAutomationCommand(live.app, "shortcut " ++ main.cmd_settings);
    try testing.expect(model.settings_open);
    const info = settingsWindowInfo(live) orelse return error.TestUnexpectedResult;
    try testing.expect(info.open);
    try testing.expectEqualStrings("Settings", info.title);

    // Reissuing the command while open is idempotent: opening is not a
    // toggle, so the window stays declared.
    try live.harness.runtime.dispatchAutomationCommand(live.app, "shortcut " ++ main.cmd_settings);
    try testing.expect(model.settings_open);

    // The settings canvas installs on its own first frame.
    try live.harness.runtime.dispatchPlatformEvent(live.app, .{ .gpu_surface_frame = .{
        .window_id = info.id,
        .label = main.settings_canvas_label,
        .size = geometry.SizeF.init(main.settings_window_width, main.settings_window_height),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 2_000_000,
        .nonblank = true,
    } });

    // Pause sampling INSIDE the settings window — the form row's switch,
    // by automation verb addressed at the settings canvas label: one
    // dispatch updates both windows (same model), live, no Apply step.
    // Appearance is not a setting — the system scheme reaches BOTH
    // canvases through on_appearance.
    const pause_id = (try settingsWidgetIdByLabel(live, info.id, "Pause or resume sampling")) orelse return error.TestUnexpectedResult;
    const pause_press = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ main.settings_canvas_label, pause_id });
    try live.harness.runtime.dispatchAutomationCommand(live.app, pause_press);
    try testing.expect(model.paused);
    try live.harness.runtime.dispatchPlatformEvent(live.app, .{ .appearance_changed = .{ .color_scheme = .dark } });
    try testing.expectEqualDeep(theme.dark_colors, (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);
    try testing.expectEqualDeep(theme.dark_colors, (try live.harness.runtime.canvasWidgetDesignTokens(info.id, main.settings_canvas_label)).colors);

    // The snapshot enumerates both windows.
    const snapshot = live.harness.runtime.automationSnapshot("System Monitor");
    try testing.expectEqual(@as(usize, 2), snapshot.windows.len);

    // Close by Msg: the model stops declaring the window and the
    // reconcile closes it — no user-close Msg fires.
    try live.dispatch(.settings_closed);
    try testing.expect(!model.settings_open);
    const closed = settingsWindowInfo(live);
    try testing.expect(closed == null or !closed.?.open);

    // Reopen (same label), then close as the USER (the fake host tears
    // the window down like the real delegates do and reports it gone):
    // the open=false event dispatches `.settings_closed` and the model
    // clears its flag — the window stays closed.
    try live.harness.runtime.dispatchAutomationCommand(live.app, "shortcut " ++ main.cmd_settings);
    try testing.expect(model.settings_open);
    const reopened = settingsWindowInfo(live) orelse return error.TestUnexpectedResult;
    const close_event = live.harness.null_platform.userCloseWindow(reopened.id).?;
    try live.harness.runtime.dispatchPlatformEvent(live.app, close_event);
    try testing.expect(!model.settings_open);
    const user_closed = settingsWindowInfo(live);
    try testing.expect(user_closed == null or !user_closed.?.open);
}

test "the settings command maps to .open_settings and the platform shortcut event drives it" {
    // One code path for every settings entry point: the shortcut id (and
    // any menu item carrying it) resolves through `main.command`.
    try testing.expectEqual(@as(?Msg, .open_settings), main.command(main.cmd_settings));
    try testing.expect(main.command("monitor.unknown") == null);

    if (!sampler.supported) return error.SkipZigTest;
    const live = try LiveApp.start();
    defer live.stop();
    const model = &live.app_state.model;

    // The platform shortcut event — what a real primary+comma keypress
    // emits for the registered id — lands as `.open_settings`.
    try live.harness.runtime.dispatchPlatformEvent(live.app, .{ .shortcut = .{
        .id = main.cmd_settings,
        .key = ",",
        .window_id = 1,
    } });
    try testing.expect(model.settings_open);
    try testing.expect(settingsWindowInfo(live) != null);

    // Opening is idempotent, not a toggle: a second press keeps it open.
    try live.harness.runtime.dispatchPlatformEvent(live.app, .{ .shortcut = .{
        .id = main.cmd_settings,
        .key = ",",
        .window_id = 1,
    } });
    try testing.expect(model.settings_open);
}

test "the settings window is one grouped form row: a live switch, no title copy, no window instructions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    model.settings_open = true;

    var ui = Ui.init(arena);
    const tree = try ui.finalizeWithTokens(view_mod.settingsView(&ui, &model), main.tokensFromModel(&model));

    // The one setting is a real switch, on while sampling is live, and
    // it drives the SAME `.toggle_sampling` dispatch the toolbar button
    // uses — changes apply immediately, no Apply/OK ceremony (and no
    // button of that kind exists here).
    const sampling_switch = findByKind(tree.root, .switch_control) orelse return error.TestUnexpectedResult;
    try testing.expect(sampling_switch.state.selected);
    try testing.expect(findByKind(tree.root, .button) == null);
    apply(&model, tree.msgFor(sampling_switch.id, .toggle).?);
    try testing.expect(model.paused);

    var paused_ui = Ui.init(arena);
    const paused_tree = try paused_ui.finalizeWithTokens(view_mod.settingsView(&paused_ui, &model), main.tokensFromModel(&model));
    try testing.expect(!findByKind(paused_tree.root, .switch_control).?.state.selected);

    // The window's titlebar owns the "Settings" title and the window
    // needs no instructions about being a window: no in-content title,
    // no close-this-window copy.
    try testing.expect(findByText(tree.root, .text, "Settings") == null);
    try testing.expect(findByLabel(tree.root, "Settings title") == null);
    try testing.expect(findTextContaining(tree.root, "Close this window") == null);
    try testing.expect(findTextContaining(tree.root, "close button") == null);
}

test "the toolbar renders one control height and carries no settings button" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = edgeModel();
    const tree = try buildTree(arena_state.allocator(), &model);

    // Settings opens via the app menu / shortcut only: nothing in the
    // main window's tree offers it.
    try testing.expect(findByLabel(tree.root, "Open settings window") == null);
    try testing.expect(findByText(tree.root, .text, "Settings") == null);

    // Every control in the toolbar row sits on one size register, so
    // the row renders exactly one control height.
    var nodes: [1024]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, main.window_width, main.window_height), &nodes);
    const control_labels = [_][]const u8{ "Pause or resume sampling", "Filter processes", "Sort by CPU", "Sort by Memory", "Sort by PID", "Sort by Name" };
    var height: ?f32 = null;
    var seen: usize = 0;
    for (layout.nodes) |node| {
        for (control_labels) |label| {
            if (!std.mem.eql(u8, node.widget.semantics.label, label)) continue;
            seen += 1;
            if (height) |expected| {
                try testing.expectEqual(expected, node.frame.height);
            } else {
                height = node.frame.height;
            }
        }
    }
    try testing.expectEqual(control_labels.len, seen);

    // The pause control is a real button on the control scale, not a
    // hand-sized panel.
    const pause = findByLabel(tree.root, "Pause or resume sampling").?;
    try testing.expectEqual(canvas.WidgetKind.button, pause.kind);
}

// -------------------------------------------------------- showcase shots

// Env-gated screenshot renderer (skipped everywhere by default, never in
// CI): replays real `ps`/`vm_stat` output captured beforehand into
// /tmp/system-monitor-samples/ through the normal update path, then
// renders the canvas OFFSCREEN through the deterministic reference
// renderer via the automation screenshot artifact — no live window, no
// screen access. To use:
//
//   mkdir -p /tmp/system-monitor-samples
//   for i in $(seq 0 59); do
//     ps axo pid=,pcpu=,pmem=,rss=,etime=,comm= > /tmp/system-monitor-samples/ps-$i.txt
//     vm_stat > /tmp/system-monitor-samples/vm-$i.txt
//     sleep 1
//   done
//   SYSTEM_MONITOR_SHOTS=1 zig build test -Dplatform=null
//
// PNGs land in /tmp/system-monitor-shots/{dark,light}-artifacts/.
test "render showcase screenshots from replayed real samples (env-gated)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (!envGateSet("SYSTEM_MONITOR_SHOTS")) return error.SkipZigTest;
    const io = std.testing.io;

    const live = try LiveApp.start();
    defer live.stop();
    const model = &live.app_state.model;

    // Host facts from the committed capture (same machine).
    apply(model, .{ .info_done = .{ .key = model_mod.info_key, .code = 0, .output = sysctl_fixture } });

    var index: usize = 0;
    while (index < model_mod.history_len) : (index += 1) {
        var path_buffer: [128]u8 = undefined;
        const ps_path = try std.fmt.bufPrint(&path_buffer, "/tmp/system-monitor-samples/ps-{d}.txt", .{index});
        const ps_bytes = try readWholeFile(io, ps_path);
        defer testing.allocator.free(ps_bytes);
        apply(model, .{ .ps_done = .{ .key = model_mod.ps_key, .code = 0, .output = ps_bytes } });

        const vm_path = try std.fmt.bufPrint(&path_buffer, "/tmp/system-monitor-samples/vm-{d}.txt", .{index});
        const vm_bytes = try readWholeFile(io, vm_path);
        defer testing.allocator.free(vm_bytes);
        apply(model, .{ .mem_done = .{ .key = model_mod.mem_key, .code = 0, .output = vm_bytes } });
    }
    try testing.expectEqual(@as(usize, model_mod.history_len), model.cpu_history_len);

    // Dark, then light, each into its own artifact directory; scale 2 for
    // crisp pixels. No present between theme change and capture on
    // purpose: a dispatch re-emits the display list with the re-derived
    // tokens, and offscreen screenshots clear with those LIVE tokens (the
    // old contract cleared with the last PRESENTED color and needed a
    // frame per theme; this test now proves the fix).
    try live.harness.runtime.dispatchPlatformEvent(live.app, .{ .appearance_changed = .{ .color_scheme = .dark } });
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/system-monitor-shots/dark-artifacts", "System Monitor");
    try live.harness.runtime.dispatchAutomationCommand(live.app, "screenshot monitor-canvas 2");

    try live.harness.runtime.dispatchPlatformEvent(live.app, .{ .appearance_changed = .{ .color_scheme = .light } });
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/system-monitor-shots/light-artifacts", "System Monitor");
    try live.harness.runtime.dispatchAutomationCommand(live.app, "screenshot monitor-canvas 2");

    // The SIGTERM confirmation over the live table (its own artifact).
    try live.dispatch(.{ .request_kill = model.rows[0].pid });
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/system-monitor-shots/dialog-artifacts", "System Monitor");
    try live.harness.runtime.dispatchAutomationCommand(live.app, "screenshot monitor-canvas 2");
}

fn readWholeFile(io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(testing.allocator, .limited(8 * 1024 * 1024));
}

/// Env-gated dump switch. `std.c.getenv` needs libc, which this test
/// build only links on targets whose platform layer pulls it in; when
/// libc is absent the gate reads as unset and the gated test skips.
fn envGateSet(name: [*:0]const u8) bool {
    if (comptime !@import("builtin").link_libc) return false;
    return std.c.getenv(name) != null;
}

test "chrome geometry pads the header and matches its height to the tall band" {
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var model = model_mod.Model{};
    try testing.expectEqual(model_mod.header_natural_height, model.header_height);

    // The tall hidden-inset band arrives through on_chrome: the header
    // pads past the traffic lights and matches the band's height so its
    // centered controls share the lights' centerline.
    const chrome: native_sdk.WindowChrome = .{
        .insets = .{ .top = 52, .left = 78 },
        .buttons = native_sdk.geometry.RectF.init(20, 19, 52, 14),
    };
    const msg = main.onChrome(chrome) orelse return error.TestUnexpectedResult;
    model_mod.update(&model, msg, &fx);
    try testing.expectEqual(@as(f32, 78), model.chrome_leading);
    try testing.expectEqual(@max(model_mod.header_natural_height, 52), model.header_height);

    // A band taller than the natural header grows the header with it.
    const tall = main.onChrome(.{ .insets = .{ .top = 72, .left = 78 } }) orelse return error.TestUnexpectedResult;
    model_mod.update(&model, tall, &fx);
    try testing.expectEqual(@as(f32, 72), model.header_height);

    // Fullscreen zeroes the chrome: the pad collapses and the height
    // falls back to the header's natural floor.
    const cleared = main.onChrome(.{}) orelse return error.TestUnexpectedResult;
    model_mod.update(&model, cleared, &fx);
    try testing.expectEqual(@as(f32, 0), model.chrome_leading);
    try testing.expectEqual(model_mod.header_natural_height, model.header_height);

    // The scene declares the matching titlebar so the platform actually
    // hides the OS bar this header replaces.
    try testing.expectEqual(.hidden_inset_tall, main.shell_scene.windows[0].titlebar);
}

test "the uptime value paragraph moved to markup unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    model_mod.update(&model, .{ .ps_done = .{ .key = model_mod.ps_key, .code = 0, .output = ps_fixture } }, &fx);

    // The markup fragment (a <text> with one bold <span>) builds the
    // exact widget the builder paragraph produced: same kind, same
    // concatenated text, same span list, same heading size and width,
    // same accessible label — so the tile renders pixel-identical.
    var markup_ui = Ui.init(arena);
    const markup_node = view_mod.UptimeValueView.build(&markup_ui, &model);

    var hand_ui = Ui.init(arena);
    const hand_node = hand_ui.paragraph(.{
        .width = view_mod.spark_width,
        .size = .heading,
        .semantics = .{ .label = model.uptimeValue(hand_ui.arena) },
    }, &.{
        .{ .text = model.uptimeValue(hand_ui.arena), .weight = .bold },
    });

    try testing.expectEqual(canvas.WidgetKind.text, markup_node.widget.kind);
    try testing.expectEqualStrings(hand_node.widget.text, markup_node.widget.text);
    try testing.expectEqualStrings(model.uptimeValue(arena), markup_node.widget.text);
    try testing.expect(canvas.text_spans.textSpansEqual(hand_node.widget.spans, markup_node.widget.spans));
    try testing.expectEqual(canvas.TextSpanWeight.bold, markup_node.widget.spans[0].weight);
    try testing.expectEqual(hand_node.widget.layout.min_size, markup_node.widget.layout.min_size);
    try testing.expectEqual(hand_node.widget.layout.max_size, markup_node.widget.layout.max_size);
    try testing.expectEqual(view_mod.spark_width, markup_node.widget.layout.min_size.width);
    try testing.expectEqual(canvas.WidgetSize.heading, markup_node.widget.size);
    try testing.expectEqualStrings(hand_node.widget.semantics.label, markup_node.widget.semantics.label);
    // One text run for assistive tech: spans stay visual.
    try testing.expectEqual(@as(usize, 0), markup_node.nodes.len);
}
