//! End-to-end proof battery for examples/system-monitor-ts — the second
//! port: the spawn-showcase app authored in TypeScript + Native markup
//! with ZERO hand-written Zig. The build transpiles the example's REAL
//! core (examples/system-monitor-ts/src/core.ts) and this suite drives it
//! through `TsUiApp` with the example's SHIPPING markup (app.native,
//! staged beside this file) on the FAKE effects executor, so every spawn
//! parks for scripted answers instead of running the host's real `ps`:
//!
//!   - the boot probe cascade: sysctl answering selects macOS conventions
//!     (vm_stat), a refusal falls through to nproc (meminfo), and both
//!     failing is the honest "no sampler" state — never a pretend sample;
//!   - the sampling loop end to end: probe -> eager sample -> the Zig
//!     example's committed real `ps`/`vm_stat` captures through the
//!     collect-mode spawn path -> tiles, table, status line, and the
//!     NaN-padded f64 chart windows narrowed into the markup sparklines;
//!   - the Sub.timer cadence as a REAL platform timer: ticks spawn,
//!     mid-flight ticks are skipped and counted, pause reconciles the
//!     timer away and resume re-arms it with an eager sample;
//!   - the confirmed SIGTERM round trip: request copies the target out of
//!     the row, cancel never signals, confirm spawns exactly
//!     `/bin/kill -TERM <pid>`, and the exit lands as a status note;
//!   - search through the byte-splice text engine and the sort chips over
//!     the shipping toggle-group;
//!   - the constructed edge fixture: day-form etimes, un-pathed names
//!     with spaces, and a garbage line counted as a parse failure;
//!   - a recorded session (user input + scripted spawn results) replays
//!     byte-identically with zero host calls.
//!
//! Only this TEST wiring is Zig — the command mapper below exists so the
//! suite can dispatch payload-carrying Msgs through the journaled
//! menu-command path (the app itself dispatches them from markup).

const std = @import("std");
const native_sdk = @import("native_sdk");
const core = @import("ts_system_monitor_core");

const runtime_ns = native_sdk.runtime;
const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const Adapter = native_sdk.TsUiApp(core);
const App = Adapter.App;
const Bridge = Adapter.Host;

const app_markup = @embedFile("app.native");
const CompiledAppView = canvas.CompiledMarkupView(core.Model, core.Msg, app_markup);

// The Zig example's committed real captures (10 cores, 32 GiB) and its
// constructed edge fixture — shared truth, staged beside this root.
const sysctl_fixture = @embedFile("fixtures/sysctl.txt");
const ps_fixture = @embedFile("fixtures/ps.txt");
const vm_stat_fixture = @embedFile("fixtures/vm_stat.txt");
const ps_edge_fixture = @embedFile("fixtures/ps-edge.txt");

const canvas_label = "monitor-canvas";

/// The sample subscription's engine timer key: bridge timer slot 0. On
/// the fake executor the timer parks instead of arming a platform timer,
/// so the suite fires it through the engine's fake-fire seam (fires carry
/// timestamp 0 — the fake executor has no clock; the tick arm's payload
/// is unused by the core).
const sample_timer_key: u64 = runtime_ns.ts_core_timer_key_base + 0;

/// Bridge spawn stream keys are `base + slot`, slots reused in issue
/// order as streams retire: the boot probe takes slot 0; after it exits,
/// each sampling round parks ps on slot 0 and the memory command on
/// slot 1; the kill spawn takes the first free slot when it issues.
const spawn_key_0: u64 = runtime_ns.ts_core_spawn_key_base + 0;
const spawn_key_1: u64 = runtime_ns.ts_core_spawn_key_base + 1;

const app_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const app_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "System Monitor TS",
    .width = 1144,
    .height = 720,
    .views = &app_views,
}};
const app_scene: native_sdk.ShellConfig = .{ .windows = &app_windows };

/// TEST-ONLY command mapper (see the module comment).
fn testCommand(name: []const u8) ?core.Msg {
    if (std.mem.eql(u8, name, "mon.pause")) return .toggle_sampling;
    if (std.mem.eql(u8, name, "mon.sort.cpu")) return .sort_cpu;
    if (std.mem.eql(u8, name, "mon.sort.mem")) return .sort_mem;
    if (std.mem.eql(u8, name, "mon.sort.pid")) return .sort_pid;
    if (std.mem.eql(u8, name, "mon.sort.name")) return .sort_name;
    if (std.mem.eql(u8, name, "mon.cancel")) return .cancel_kill;
    if (std.mem.eql(u8, name, "mon.confirm")) return .confirm_kill;
    if (commandId(name, "mon.kill.")) |pid| return .{ .request_kill = pid };
    if (commandId(name, "mon.copy.")) |pid| return .{ .copy_name = pid };
    return null;
}

fn commandId(name: []const u8, prefix: []const u8) ?i64 {
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    return std.fmt.parseInt(i64, name[prefix.len..], 10) catch null;
}

fn appOptions() App.Options {
    return .{
        .name = "system-monitor-ts-e2e",
        .scene = app_scene,
        .canvas_label = canvas_label,
        // The comptime-compiled engine over the example's shipping markup
        // — the whole view tier of the app under test.
        .view = CompiledAppView.build,
        .on_command = testCommand,
    };
}

const Harness = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *App,
    app: native_sdk.App,
    clock: native_sdk.TestClock,

    fn create() !*Harness {
        return createFull(null, .{});
    }

    fn createChromed(chrome: native_sdk.WindowChrome) !*Harness {
        return createFull(null, chrome);
    }

    fn createRecorded(recorder: ?*runtime_ns.SessionRecorder) !*Harness {
        return createFull(recorder, .{});
    }

    /// Every harness runs the FAKE effects executor: the core's spawns
    /// park in fake slots for the scripted sampler feeds below, and the
    /// clipboard write parks for assertion — no host process, ever.
    fn createFull(recorder: ?*runtime_ns.SessionRecorder, chrome: native_sdk.WindowChrome) !*Harness {
        const self = try std.testing.allocator.create(Harness);
        errdefer std.testing.allocator.destroy(self);
        self.clock = .{};
        // 12:34:56 UTC into the day: the "sampled at" clock the status
        // line renders from the journaled Cmd.now stamp.
        self.clock.setWallMs(45_296_000);
        self.harness = try native_sdk.TestHarness().create(std.testing.allocator, .{
            .size = geometry.SizeF.init(1144, 720),
        });
        errdefer self.harness.destroy(std.testing.allocator);
        self.harness.null_platform.gpu_surfaces = true;
        self.harness.null_platform.window_chrome = chrome;
        self.harness.runtime.options.session_recorder = recorder;
        self.app_state = try std.testing.allocator.create(App);
        errdefer std.testing.allocator.destroy(self.app_state);
        self.app_state.* = Adapter.init(std.heap.page_allocator, .{}, appOptions());
        self.app_state.effects.executor = .fake;
        self.app_state.effects.clock = self.clock.clock();
        self.app = self.app_state.app();
        try self.harness.start(self.app);
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(1144, 720),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
        } });
        try std.testing.expect(self.app_state.installed);
        return self;
    }

    fn destroy(self: *Harness) void {
        self.app_state.deinit();
        std.testing.allocator.destroy(self.app_state);
        self.harness.destroy(std.testing.allocator);
        std.testing.allocator.destroy(self);
    }

    fn wake(self: *Harness) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .wake);
    }

    /// Feed one parked collect spawn its whole stdout and a clean exit,
    /// then drain the terminal into the core.
    fn spawnOutput(self: *Harness, key: u64, output: []const u8, code: i32) !void {
        try self.app_state.effects.feedOutput(key, output);
        try self.app_state.effects.feedExit(key, code);
        try self.wake();
    }

    /// End one parked spawn without a clean exit (the probe-cascade and
    /// stream-failure feeds).
    fn spawnEnd(self: *Harness, key: u64, reason: runtime_ns.EffectExitReason) !void {
        try self.app_state.effects.feedExitReason(key, 1, reason);
        try self.wake();
    }

    /// Run the boot probe to the macOS answer: the committed sysctl
    /// capture (10 cores, 32 GiB) selects vm_stat sampling and issues
    /// the eager first sample (ps on slot 0, vm_stat on slot 1).
    fn bootMac(self: *Harness) !void {
        try self.spawnOutput(spawn_key_0, sysctl_fixture, 0);
        try std.testing.expect(Bridge.model().phase == .ready);
        try std.testing.expectEqual(@as(usize, 2), self.app_state.effects.pendingSpawnCount());
    }

    /// Feed the eager sample the committed real captures.
    fn firstSample(self: *Harness) !void {
        try self.spawnOutput(spawn_key_0, ps_fixture, 0);
        try self.spawnOutput(spawn_key_1, vm_stat_fixture, 0);
    }

    fn menu(self: *Harness, name: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .menu_command = .{ .name = name, .window_id = 1 } });
    }

    fn hasText(self: *Harness, text: []const u8) bool {
        return findTextIn(self.app_state.tree.?.root, text);
    }

    fn findId(self: *Harness, kind: canvas.WidgetKind, text: []const u8) ?canvas.ObjectId {
        return findKindText(self.app_state.tree.?.root, kind, text);
    }

    fn findLabel(self: *Harness, label: []const u8) ?canvas.ObjectId {
        return findByLabel(self.app_state.tree.?.root, label);
    }

    /// Click a rendered widget through the automation verb — the same
    /// headless path `native automate` drives.
    fn click(self: *Harness, id: canvas.ObjectId) !void {
        var buffer: [96]u8 = undefined;
        const command = try std.fmt.bufPrint(&buffer, "widget-click {s} {d}", .{ canvas_label, id });
        try self.harness.runtime.dispatchAutomationCommand(self.app, command);
    }

    fn textInput(self: *Harness, text: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = canvas_label,
            .kind = .text_input,
            .text = text,
        } });
    }

    fn keyDown(self: *Harness, key: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = canvas_label,
            .kind = .key_down,
            .key = key,
        } });
    }

    fn fireSampleTimer(self: *Harness) !bool {
        self.app_state.effects.fireTimer(sample_timer_key) catch return false;
        try self.wake();
        return true;
    }

    fn sampleTimerArmed(self: *Harness) bool {
        return self.app_state.effects.pendingTimerCount() > 0;
    }
};

fn findKindText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.ObjectId {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget.id;
    for (widget.children) |child| {
        if (findKindText(child, kind, text)) |id| return id;
    }
    return null;
}

fn findTextIn(widget: canvas.Widget, text: []const u8) bool {
    if (std.mem.indexOf(u8, widget.text, text) != null) return true;
    for (widget.children) |child| {
        if (findTextIn(child, text)) return true;
    }
    return false;
}

fn findByLabel(widget: canvas.Widget, label: []const u8) ?canvas.ObjectId {
    if (std.mem.eql(u8, widget.semantics.label, label)) return widget.id;
    for (widget.children) |child| {
        if (findByLabel(child, label)) |id| return id;
    }
    return null;
}

fn collectChartWidgets(widget: canvas.Widget, out: *std.ArrayListUnmanaged(canvas.Widget), allocator: std.mem.Allocator) !void {
    if (widget.kind == .chart) try out.append(allocator, widget);
    for (widget.children) |child| {
        try collectChartWidgets(child, out, allocator);
    }
}

// ------------------------------------------------------------ boot probe

test "the boot probe cascades: sysctl selects vm_stat, nproc selects meminfo, both failing is the honest no-sampler state" {
    // macOS conventions: the committed sysctl capture answers the probe.
    {
        const h = try Harness.create();
        defer h.destroy();
        const probe = h.app_state.effects.pendingSpawnAt(0).?;
        try std.testing.expectEqual(spawn_key_0, probe.key);
        try std.testing.expectEqualStrings("/usr/sbin/sysctl", probe.argv[0]);
        try std.testing.expectEqual(runtime_ns.EffectOutputMode.collect, probe.output);
        try h.bootMac();
        try std.testing.expectEqual(@as(i64, 10), Bridge.model().cores);
        try std.testing.expectEqual(@as(i64, 34_359_738_368), Bridge.model().memTotalBytes);
        try std.testing.expect(Bridge.model().memCommand == .vmstat);
        // The eager sample: the shared ps line and the macOS memory command.
        const ps_request = h.app_state.effects.pendingSpawnAt(0).?;
        try std.testing.expectEqualStrings("/bin/ps", ps_request.argv[0]);
        try std.testing.expectEqualStrings("pid=,pcpu=,pmem=,rss=,etime=,comm=", ps_request.argv[2]);
        try std.testing.expectEqualStrings("/usr/bin/vm_stat", h.app_state.effects.pendingSpawnAt(1).?.argv[0]);
        // The sampling cadence armed a REAL platform timer.
        try std.testing.expect(h.sampleTimerArmed());
    }

    // Linux conventions: sysctl refuses the keys (non-zero exit), nproc
    // answers, and the memory command is /proc/meminfo.
    {
        const h = try Harness.create();
        defer h.destroy();
        try h.spawnOutput(spawn_key_0, "", 1);
        try std.testing.expect(Bridge.model().phase == .probing);
        const nproc = h.app_state.effects.pendingSpawnAt(0).?;
        try std.testing.expectEqualStrings("/usr/bin/nproc", nproc.argv[0]);
        try h.spawnOutput(spawn_key_0, "8\n", 0);
        try std.testing.expect(Bridge.model().phase == .ready);
        try std.testing.expectEqual(@as(i64, 8), Bridge.model().cores);
        try std.testing.expect(Bridge.model().memCommand == .meminfo);
        try std.testing.expectEqualStrings("/bin/cat", h.app_state.effects.pendingSpawnAt(1).?.argv[0]);
        try std.testing.expectEqualStrings("/proc/meminfo", h.app_state.effects.pendingSpawnAt(1).?.argv[1]);
        // A meminfo sample derives used = MemTotal - MemAvailable.
        try h.spawnOutput(spawn_key_1, "MemTotal:       16384000 kB\nMemAvailable:   12288000 kB\n", 0);
        try std.testing.expectEqual(@as(i64, 4_194_304_000), Bridge.model().memUsedBytes);
        try std.testing.expectEqual(@as(i64, 16_777_216_000), Bridge.model().memTotalBytes);
    }

    // No sampler: both probes fail to start; the app says so instead of
    // pretending, and no cadence ever arms.
    {
        const h = try Harness.create();
        defer h.destroy();
        try h.spawnEnd(spawn_key_0, .spawn_failed);
        try h.spawnEnd(spawn_key_0, .spawn_failed);
        try std.testing.expect(Bridge.model().phase == .unsupported);
        try std.testing.expect(!h.sampleTimerArmed());
        try std.testing.expect(h.hasText("This build has no sampler for the host OS — see the README."));
        try std.testing.expect(h.hasText("Sampling is not supported on this OS"));
    }
}

// -------------------------------------------------------- the first sample

test "the shipping markup renders the committed captures: tiles, sparklines, table, and the status line" {
    const h = try Harness.create();
    defer h.destroy();
    try h.bootMac();

    // Before the first sample lands the surfaces say so honestly.
    try std.testing.expect(h.hasText("Sampling…"));
    try std.testing.expect(h.hasText("Waiting for the first sample…"));
    try std.testing.expect(h.hasText("--"));

    try h.firstSample();

    // The stat tiles, exactly the Zig example's derivations over the same
    // captures: 561 processes, cpu_sum/10 cores, active+wired+compressor
    // pages at 16384 bytes against the probed 32 GiB, pid 1's etime.
    try std.testing.expectEqual(@as(i64, 561), Bridge.model().processCount);
    try std.testing.expectEqual(@as(i64, 46), Bridge.model().cpuPercentTenths);
    try std.testing.expect(h.hasText("4.6%"));
    try std.testing.expect(h.hasText("across 10 cores"));
    try std.testing.expect(h.hasText("15.1 GB"));
    try std.testing.expect(h.hasText("of 32.0 GB · 47%"));
    try std.testing.expect(h.hasText("561"));
    try std.testing.expect(h.hasText("02:49:06"));
    try std.testing.expect(h.hasText("Live · every 2 s"));

    // The status line carries the journaled Cmd.now stamp (the TestClock's
    // 12:34:56) — replayable by construction.
    try std.testing.expect(h.hasText("561 processes · sampled at 12:34:56 UTC"));

    // The table: 14 rows shown of 128 kept, top CPU first.
    try std.testing.expect(h.hasText("14 of 128"));
    try std.testing.expect(h.hasText("WindowServer"));
    try std.testing.expect(h.hasText("24.5"));

    // The sparkline charts: three markup <chart> elements binding the
    // core's f64 NaN-padded windows, narrowed into the f32 chart pipeline
    // — one sample in, 59 leading NaN gaps, the fraction on the right.
    var charts: std.ArrayListUnmanaged(canvas.Widget) = .empty;
    defer charts.deinit(std.testing.allocator);
    try collectChartWidgets(h.app_state.tree.?.root, &charts, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), charts.items.len);
    const cpu_series = charts.items[0].chart.series[0];
    try std.testing.expectEqual(@as(usize, 60), cpu_series.values.len);
    try std.testing.expect(std.math.isNan(cpu_series.values[0]));
    try std.testing.expect(std.math.isNan(cpu_series.values[58]));
    try std.testing.expectApproxEqAbs(@as(f32, 0.046), cpu_series.values[59], 0.0005);
    const proc_series = charts.items[2].chart.series[0];
    try std.testing.expectApproxEqAbs(@as(f32, 561), proc_series.values[59], 0.001);
}

test "the runtime markup interpreter builds the emitted model exactly like the compiled engine" {
    // The PRODUCT wiring runs app.native through the runtime interpreter
    // (hot reload); this suite compiles it at comptime. Hold the two
    // engines text-identical over the sampled model so the product path
    // can never drift from the tested one.
    const h = try Harness.create();
    defer h.destroy();
    try h.bootMac();
    try h.firstSample();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = h.app_state.model;
    const AppUi = canvas.Ui(core.Msg);
    var interpreter_view = try canvas.MarkupView(core.Model, core.Msg).init(arena, app_markup);
    var interpreter_ui = AppUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try interpreter_view.build(&interpreter_ui, &model));
    var compiled_ui = AppUi.init(arena);
    const compiled = try compiled_ui.finalize(CompiledAppView.build(&compiled_ui, &model));

    var interpreted_texts: std.ArrayListUnmanaged(u8) = .empty;
    defer interpreted_texts.deinit(std.testing.allocator);
    var compiled_texts: std.ArrayListUnmanaged(u8) = .empty;
    defer compiled_texts.deinit(std.testing.allocator);
    try collectTexts(interpreted.root, &interpreted_texts, std.testing.allocator);
    try collectTexts(compiled.root, &compiled_texts, std.testing.allocator);
    try std.testing.expectEqualStrings(interpreted_texts.items, compiled_texts.items);
    try std.testing.expect(std.mem.indexOf(u8, compiled_texts.items, "WindowServer") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled_texts.items, "4.6%") != null);
}

fn collectTexts(widget: canvas.Widget, out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    try out.appendSlice(allocator, widget.text);
    try out.append(allocator, '\n');
    for (widget.children) |child| {
        try collectTexts(child, out, allocator);
    }
}

// -------------------------------------------------------- cadence + pause

test "the sample cadence ticks, skips mid-flight, and pause reconciles the timer away" {
    const h = try Harness.create();
    defer h.destroy();
    try h.bootMac();
    try h.firstSample();

    // A timer fire with nothing in flight spawns the next round.
    try std.testing.expectEqual(@as(usize, 0), h.app_state.effects.pendingSpawnCount());
    try std.testing.expect(try h.fireSampleTimer());
    try std.testing.expectEqual(@as(usize, 2), h.app_state.effects.pendingSpawnCount());
    try std.testing.expect(Bridge.model().psInflight);

    // A tick that lands while the spawns still run is skipped and counted
    // — never two overlapping ps runs.
    try std.testing.expect(try h.fireSampleTimer());
    try std.testing.expectEqual(@as(usize, 2), h.app_state.effects.pendingSpawnCount());
    try std.testing.expectEqual(@as(i64, 1), Bridge.model().ticksSkipped);
    try h.spawnOutput(spawn_key_0, ps_fixture, 0);
    try h.spawnOutput(spawn_key_1, vm_stat_fixture, 0);
    try std.testing.expectEqual(@as(i64, 2), Bridge.model().samplesTaken);
    try std.testing.expect(h.hasText("1 ticks skipped"));

    // Pause through the shipping toolbar button: the subscription
    // reconciles away (a real platform timer cancellation), the label
    // flips, and the status reads paused.
    try h.click(h.findLabel("Pause or resume sampling").?);
    try std.testing.expect(Bridge.model().paused);
    try std.testing.expect(!h.sampleTimerArmed());
    try std.testing.expect(h.hasText("Paused"));
    try std.testing.expect(h.hasText("Resume"));

    // Resume re-arms the cadence AND samples eagerly on the same dispatch
    // (the Zig original's setSampling shape).
    try h.click(h.findLabel("Pause or resume sampling").?);
    try std.testing.expect(!Bridge.model().paused);
    try std.testing.expect(h.sampleTimerArmed());
    try std.testing.expectEqual(@as(usize, 2), h.app_state.effects.pendingSpawnCount());
    try h.spawnOutput(spawn_key_0, ps_fixture, 0);
    try h.spawnOutput(spawn_key_1, vm_stat_fixture, 0);
    try std.testing.expectEqual(@as(i64, 3), Bridge.model().samplesTaken);

    // A failed ps run is a status note, never a crash — and a truncated
    // collect routes the err arm, so a cut block never parses as whole.
    try std.testing.expect(try h.fireSampleTimer());
    try h.spawnEnd(spawn_key_0, .signaled);
    try std.testing.expect(h.hasText("ps failed (signaled)"));
    try h.spawnOutput(spawn_key_1, vm_stat_fixture, 0);
    try std.testing.expectEqual(@as(i64, 3), Bridge.model().samplesTaken);
}

// ------------------------------------------------------- search + sorting

test "search filters through the byte-splice engine and the sort chips reorder the table" {
    const h = try Harness.create();
    defer h.destroy();
    try h.bootMac();
    try h.firstSample();

    // Type into the shipping search field: the core's caret-aware engine
    // applies each event, and the table filters on names AND pid text.
    try h.click(h.findId(.search_field, "").?);
    try h.textInput("windowserver");
    try std.testing.expect(h.hasText("1 of 1"));
    try std.testing.expect(h.hasText("WindowServer"));
    try std.testing.expect(!h.hasText("logd"));
    for (0..12) |_| try h.keyDown("backspace");
    try std.testing.expect(h.hasText("14 of 128"));

    // A miss states its honest scope: search only sees the top-128
    // selection the sampler keeps, and the empty state says so.
    try h.textInput("zzzz");
    try std.testing.expect(h.hasText("No matches for \"zzzz\""));
    try std.testing.expect(h.hasText("Search sees the top 128 processes by CPU"));
    for (0..4) |_| try h.keyDown("backspace");
    try std.testing.expect(h.hasText("14 of 128"));

    // A pid query matches pid text (launchd is pid 1; "395" is
    // WindowServer's pid in the capture).
    try h.textInput("395");
    try std.testing.expect(h.hasText("WindowServer"));
    for (0..3) |_| try h.keyDown("backspace");

    // Sort by PID: ascending is the fresh key's natural direction, so
    // launchd (pid 1) leads; pressing the active chip flips it.
    try h.click(h.findLabel("Sort by PID").?);
    try std.testing.expect(Bridge.model().sortKey == .pid);
    try std.testing.expect(!Bridge.model().sortDescending);
    try std.testing.expect(h.hasText("launchd"));
    try h.click(h.findLabel("Sort by PID").?);
    try std.testing.expect(Bridge.model().sortDescending);

    // Back to CPU: descending again (biggest loads first).
    try h.click(h.findLabel("Sort by CPU").?);
    try std.testing.expect(Bridge.model().sortKey == .cpu);
    try std.testing.expect(Bridge.model().sortDescending);
}

test "the edge fixture parses like the original: day etimes, spaced names, one counted garbage line" {
    const h = try Harness.create();
    defer h.destroy();
    try h.bootMac();
    try h.spawnOutput(spawn_key_0, ps_edge_fixture, 0);
    try h.spawnOutput(spawn_key_1, vm_stat_fixture, 0);

    try std.testing.expectEqual(@as(i64, 5), Bridge.model().processCount);
    try std.testing.expectEqual(@as(i64, 1), Bridge.model().parseFailures);
    // pid 1's day-form etime IS the uptime: 3-02:49:06.
    try std.testing.expectEqual(@as(i64, 269_346), Bridge.model().uptimeSeconds);
    try std.testing.expect(h.hasText("3d 02:49"));
    // The un-pathed name with spaces survives whole.
    try std.testing.expect(h.hasText("Core Audio Driver (Example.driver)"));
    try std.testing.expect(h.hasText("1 parse failures"));
}

// ---------------------------------------------------------- kill round trip

test "the SIGTERM round trip: request copies the target, cancel never signals, confirm spawns /bin/kill" {
    const h = try Harness.create();
    defer h.destroy();
    try h.bootMac();
    try h.spawnOutput(spawn_key_0, ps_edge_fixture, 0);
    try h.spawnOutput(spawn_key_1, vm_stat_fixture, 0);

    // Request (the markup row's context-menu entry, dispatched here
    // through the journaled command path): the dialog names the copied
    // target — a later sample can never retarget it.
    try h.menu("mon.kill.842");
    try std.testing.expect(h.hasText("Send SIGTERM?"));
    try std.testing.expect(h.hasText("renderfarm-worker (pid 842) will be asked to quit."));
    try std.testing.expect(h.hasText("This app never sends SIGKILL."));

    // Cancel: the dialog leaves and NOTHING spawned.
    try h.click(h.findId(.button, "Cancel").?);
    try std.testing.expect(!h.hasText("Send SIGTERM?"));
    try std.testing.expectEqual(@as(usize, 0), h.app_state.effects.pendingSpawnCount());

    // Confirm: exactly `/bin/kill -TERM 842` in collect mode, and the
    // exit lands as the delivered note.
    try h.menu("mon.kill.842");
    try h.click(h.findId(.button, "Send SIGTERM").?);
    try std.testing.expect(!h.hasText("Send SIGTERM?"));
    const kill_request = h.app_state.effects.pendingSpawnAt(0).?;
    try std.testing.expectEqual(@as(usize, 3), kill_request.argv.len);
    try std.testing.expectEqualStrings("/bin/kill", kill_request.argv[0]);
    try std.testing.expectEqualStrings("-TERM", kill_request.argv[1]);
    try std.testing.expectEqualStrings("842", kill_request.argv[2]);
    try std.testing.expect(h.hasText("SIGTERM sent to renderfarm-worker (pid 842)…"));
    try h.spawnOutput(spawn_key_0, "", 0);
    try std.testing.expect(h.hasText("terminate request delivered"));

    // The delivered notice is a moment, not a state: the NEXT applied
    // sample (whose rows are the delivery's visible consequence)
    // retires it from the footer.
    try std.testing.expect(try h.fireSampleTimer());
    try h.spawnOutput(spawn_key_0, ps_edge_fixture, 0);
    try h.spawnOutput(spawn_key_1, vm_stat_fixture, 0);
    try std.testing.expect(!h.hasText("terminate request delivered"));

    // A refused kill (not your process) is a note, never a crash.
    try h.menu("mon.kill.842");
    try h.click(h.findId(.button, "Send SIGTERM").?);
    try h.spawnOutput(spawn_key_0, "", 1);
    try std.testing.expect(h.hasText("kill failed (code 1 — not your process?)"));

    // Failure is a state worth keeping: the next sample does NOT clear
    // the failed note (only the delivered notice is transient).
    try std.testing.expect(try h.fireSampleTimer());
    try h.spawnOutput(spawn_key_0, ps_edge_fixture, 0);
    try h.spawnOutput(spawn_key_1, vm_stat_fixture, 0);
    try std.testing.expect(h.hasText("kill failed (code 1 — not your process?)"));

    // A vanished pid refuses the request with a note — the dialog never
    // opens on a stale row.
    try h.menu("mon.kill.99999");
    try std.testing.expect(!h.hasText("Send SIGTERM?"));
    try std.testing.expect(h.hasText("pid 99999 is gone (it left the sample)"));

    // Copy Name parks on the clipboard channel — fire-and-forget.
    try h.menu("mon.copy.842");
    try std.testing.expectEqual(@as(usize, 1), h.app_state.effects.pendingClipboardCount());
    try std.testing.expectEqualStrings("renderfarm-worker", h.app_state.effects.pendingClipboardAt(0).?.text);
    try std.testing.expect(h.hasText("name copy requested"));
}

test "a sample already in flight at kill time cannot retire the delivered notice" {
    const h = try Harness.create();
    defer h.destroy();
    try h.bootMac();
    try h.spawnOutput(spawn_key_0, ps_edge_fixture, 0);
    try h.spawnOutput(spawn_key_1, vm_stat_fixture, 0);

    // Fire the cadence so the NEXT round is in flight: its `ps`
    // collected the row set BEFORE any kill below.
    try std.testing.expect(try h.fireSampleTimer());
    try std.testing.expect(Bridge.model().psInflight);

    // Confirm the kill while that round runs; ps and the memory command
    // hold slots 0 and 1, so the kill spawn parks on the next free slot
    // — find it by its argv rather than assuming the slot number.
    try h.menu("mon.kill.842");
    try h.click(h.findId(.button, "Send SIGTERM").?);
    var kill_key: u64 = 0;
    var index: usize = 0;
    while (h.app_state.effects.pendingSpawnAt(index)) |request| : (index += 1) {
        if (std.mem.eql(u8, request.argv[0], "/bin/kill")) kill_key = request.key;
    }
    try std.testing.expect(kill_key != 0);

    // Drain the delivered exit AND the stale ps exit in ONE batch before
    // any rebuild — the worst interleaving in the field: kill_done marks
    // the notice transient and the pre-termination rows land right
    // behind it in the same drain.
    try h.app_state.effects.feedOutput(kill_key, "");
    try h.app_state.effects.feedExit(kill_key, 0);
    try h.app_state.effects.feedOutput(spawn_key_0, ps_edge_fixture);
    try h.app_state.effects.feedExit(spawn_key_0, 0);
    try h.wake();

    // The stale rows applied, and the notice SURVIVED them into the
    // rendered footer — it must show for at least one full sample.
    try std.testing.expectEqual(@as(i64, 2), Bridge.model().samplesTaken);
    try std.testing.expect(h.hasText("terminate request delivered"));

    // The first sample LAUNCHED after the kill shows the delivery's
    // outcome, and retires the notice with it.
    try h.spawnOutput(spawn_key_1, vm_stat_fixture, 0);
    try std.testing.expect(try h.fireSampleTimer());
    try h.spawnOutput(spawn_key_0, ps_edge_fixture, 0);
    try std.testing.expect(!h.hasText("terminate request delivered"));
    try h.spawnOutput(spawn_key_1, vm_stat_fixture, 0);
}

// ----------------------------------------------------------------- chrome

test "the chromeMsg channel drives the hidden-inset header band" {
    const h = try Harness.createChromed(.{
        .insets = .{ .top = 56, .left = 78 },
        .buttons = geometry.RectF.init(12, 14, 54, 16),
    });
    defer h.destroy();

    // Delivered before the first view build: the header matches the band
    // and leads past the traffic lights.
    try std.testing.expectEqual(@as(f64, 78), Bridge.model().chromeLeading);
    try std.testing.expectEqual(@as(f64, 56), Bridge.model().headerHeight);
}

// ------------------------------------------------------- record / replay

const JournalBuffer = struct {
    bytes: [512 * 1024]u8 = undefined,
    len: usize = 0,

    fn sink(self: *JournalBuffer) runtime_ns.SessionRecorderSink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *JournalBuffer = @ptrCast(@alignCast(context));
        if (self.len + bytes.len > self.bytes.len) return error.NoSpaceLeft;
        @memcpy(self.bytes[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn journalBytes(self: *const JournalBuffer) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// A value snapshot of the committed monitor model (committed slices live
/// in the core's heap — copy what outlives a session).
const MonitorSnapshot = struct {
    phase: @TypeOf(Bridge.model().phase),
    cores: i64,
    samples_taken: i64,
    process_count: i64,
    cpu_percent_tenths: i64,
    mem_used_bytes: i64,
    uptime_seconds: i64,
    sampled_at_day_ms: i64,
    ticks_skipped: i64,
    parse_failures: i64,
    paused: bool,
    row_count: usize,

    fn take() MonitorSnapshot {
        const m = Bridge.model();
        return .{
            .phase = m.phase,
            .cores = m.cores,
            .samples_taken = m.samplesTaken,
            .process_count = m.processCount,
            .cpu_percent_tenths = m.cpuPercentTenths,
            .mem_used_bytes = m.memUsedBytes,
            .uptime_seconds = m.uptimeSeconds,
            .sampled_at_day_ms = m.sampledAtDayMs,
            .ticks_skipped = m.ticksSkipped,
            .parse_failures = m.parseFailures,
            .paused = m.paused,
            .row_count = m.rows.len,
        };
    }
};

/// One reference session: the boot probe, the eager sample from the
/// committed captures, a pause/resume round whose eager re-sample carries
/// the edge fixture, and a final pause — journaled user input plus
/// scripted spawn results. (The cadence's fake timer fires are covered by
/// the tick tests above; a recorded session drives its second round
/// through the resume path so every input rides the journal.)
fn recordSession(buffer: *JournalBuffer) !MonitorSnapshot {
    const recorder = try std.heap.page_allocator.create(runtime_ns.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = runtime_ns.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "system-monitor-ts-e2e", .window_width = 1144, .window_height = 720 });

    const h = try Harness.createRecorded(recorder);
    defer h.destroy();

    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);
    try h.bootMac();
    try h.firstSample();
    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);
    try h.menu("mon.pause");
    try h.menu("mon.pause");
    try h.spawnOutput(spawn_key_0, ps_edge_fixture, 0);
    try h.spawnOutput(spawn_key_1, vm_stat_fixture, 0);
    try h.menu("mon.pause");
    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);

    recorder.finish();
    try std.testing.expect(!recorder.failed);
    return MonitorSnapshot.take();
}

test "a recorded monitor session replays byte-identically with zero host calls" {
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    const recorded = try recordSession(buffer);
    try std.testing.expectEqual(@as(i64, 2), recorded.samples_taken);
    try std.testing.expectEqual(@as(i64, 5), recorded.process_count);
    try std.testing.expectEqual(@as(i64, 10), recorded.cores);
    try std.testing.expect(recorded.paused);

    // Determinism pin: the same driven session records byte-identical
    // journal bytes.
    const second = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(second);
    second.len = 0;
    const recorded_again = try recordSession(second);
    try std.testing.expectEqualDeep(recorded, recorded_again);
    try std.testing.expectEqualSlices(u8, buffer.journalBytes(), second.journalBytes());

    // Replay into a fresh app: the journaled spawn results feed the
    // re-issued (parked) samplers in recorded order — no subprocess, no
    // host calls.
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{
        .size = geometry.SizeF.init(1144, 720),
    });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = Adapter.init(std.heap.page_allocator, .{}, appOptions());
    defer app_state.deinit();

    const report = try runtime_ns.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
    });
    try std.testing.expect(report.ok());
    try std.testing.expect(report.events_replayed > 0);
    // The journaled effect results: the probe, two sample rounds (ps +
    // memory each), and the Cmd.now stamps ride the journal too.
    try std.testing.expect(report.effects_fed >= 5);
    try std.testing.expectEqualDeep(recorded, MonitorSnapshot.take());
}
