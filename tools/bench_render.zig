//! Render macro-benchmark: scripted, deterministic scenarios through the
//! REAL engine pipeline — UiApp + Runtime + the null platform with
//! binary packet presents enabled, so the retained/patch protocol, the
//! frame planner, and the wire encoders all run exactly as they do under
//! a live host. Measures end-to-end latency per interaction (input
//! dispatch through present) and per-stage attribution via the runtime's
//! frame profile (`rebuild`/`layout`/`reconcile`/`emit`/`plan`/`patch`/
//! `encode`/`present`).
//!
//! What it deliberately does NOT measure: the macOS host's CoreText
//! rasterization and Metal upload (the `host_decode`/`host_draw` stages)
//! — those need a live window; use `native automate profile on` against
//! a running app (or the gpu smokes) for that half. The engine-side
//! `present` stage here is the null platform's packet recorder, so its
//! cost is the wire handoff floor, not a paint.
//!
//! Run:
//!
//!   zig build bench-render -Doptimize=ReleaseFast
//!
//! Deterministic inputs (fixed fixtures, synthetic timestamps, estimator
//! text metrics); wall-clock durations are the measurement. Medians and
//! p90s over N warm iterations after warmup; rows where p90 > 2.5x p50
//! are flagged `noisy` so one descheduled iteration cannot pass as a
//! regression (or an improvement).
//!
//! Ratchet mode:
//!
//!   zig build bench-render -Doptimize=ReleaseFast -- --check tools/bench-render-budgets.txt
//!
//! Runs the whole suite `check_passes` times, takes the MEDIAN e2e p50
//! per scenario across passes (one descheduled pass cannot fail the
//! gate), and compares against the committed per-scenario budgets.
//! Budgets carry ~30%+ headroom over healthy numbers: this mode exists
//! to catch order-of-magnitude regressions and accidental O(n^2)
//! reintroductions, not machine noise — see the budgets file for the
//! per-scenario rationale. Refuses to run outside ReleaseFast (budgets
//! are calibrated for it). Every scenario must have a budget and every
//! budget must name a scenario, so renames cannot silently un-gate.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const runtime_mod = native_sdk.runtime;

const Harness = native_sdk.TestHarness();
const FrameProfileStage = runtime_mod.FrameProfileStage;
const stage_values = std.enums.values(FrameProfileStage);

const canvas_label = "bench-canvas";
const surface_width: f32 = 1200;
const surface_height: f32 = 800;
const frame_interval_ns: u64 = 16_666_667;

const warmup_iterations: usize = 8;
const measured_iterations: usize = 40;
const first_frame_iterations: usize = 12;

const gpa = std.heap.page_allocator;

// --------------------------------------------------------------- series

const max_series_samples = 256;

const Series = struct {
    samples: [max_series_samples]u64 = undefined,
    len: usize = 0,

    fn push(self: *Series, value: u64) void {
        if (self.len >= self.samples.len) return;
        self.samples[self.len] = value;
        self.len += 1;
    }

    /// Nearest-rank percentile in microseconds.
    fn percentileUs(self: *const Series, percentile: usize) u64 {
        if (self.len == 0) return 0;
        var sorted: [max_series_samples]u64 = undefined;
        @memcpy(sorted[0..self.len], self.samples[0..self.len]);
        std.sort.pdq(u64, sorted[0..self.len], {}, std.sort.asc(u64));
        const rank = (self.len * percentile + 99) / 100;
        return sorted[@max(rank, 1) - 1] / std.time.ns_per_us;
    }
};

const StageStats = struct {
    p50_us: u64 = 0,
    p90_us: u64 = 0,
    count: u64 = 0,
    window: usize = 0,
};

const ScenarioReport = struct {
    name: []const u8,
    detail: []const u8,
    iterations: usize,
    e2e_p50_us: u64,
    e2e_p90_us: u64,
    stages: [stage_values.len]StageStats,

    fn noisy(self: *const ScenarioReport) bool {
        return self.e2e_p90_us > (self.e2e_p50_us * 5) / 2;
    }
};

fn captureStages(runtime: *native_sdk.Runtime) [stage_values.len]StageStats {
    var stages: [stage_values.len]StageStats = undefined;
    inline for (stage_values, 0..) |stage, index| {
        const stats = runtime.frame_profile.stats(stage);
        stages[index] = .{ .p50_us = stats.p50_us, .p90_us = stats.p90_us, .count = stats.total, .window = stats.window_len };
    }
    return stages;
}

// ------------------------------------------------------------- scaffold

const bench_shell_views = [_]native_sdk.ShellView{.{
    .label = canvas_label,
    .kind = .gpu_surface,
    .fill = true,
}};
const bench_shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "bench",
    .width = surface_width,
    .height = surface_height,
    .restore_state = false,
    .views = &bench_shell_views,
}};
const bench_scene: native_sdk.ShellConfig = .{ .windows = &bench_shell_windows };

/// Harness + app pair driving one fixture through the real event loop.
fn Bench(comptime AppT: type) type {
    return struct {
        const Self = @This();

        harness: *Harness,
        app: *AppT,
        frame_index: u64 = 0,
        timestamp_ns: u64 = 1_000_000_000,

        fn create(options: AppT.Options) !Self {
            const harness = try Harness.create(gpa, .{ .size = geometry.SizeF.init(surface_width, surface_height) });
            harness.null_platform.gpu_surfaces = true;
            // The production macOS transport: compact binary packets over
            // the retained/patch protocol.
            harness.null_platform.gpu_surface_packet_binary = true;
            // Production runners disable the per-frame diagnostics
            // preview (a second, unrecorded frame plan per present);
            // mirror them so the baseline measures the shipped path.
            harness.runtime.options.gpu_surface_frame_diagnostics = false;
            const app = try gpa.create(AppT);
            app.* = AppT.init(gpa, .{}, options);
            var self = Self{ .harness = harness, .app = app };
            try harness.start(app.app());
            // Install frame: first present builds the retained baseline.
            try self.frame();
            return self;
        }

        fn destroy(self: *Self) void {
            self.app.deinit();
            gpa.destroy(self.app);
            self.harness.destroy(gpa);
        }

        fn runtime(self: *Self) *native_sdk.Runtime {
            return &self.harness.runtime;
        }

        /// One presented frame with advancing synthetic clocks.
        fn frame(self: *Self) !void {
            self.frame_index += 1;
            self.timestamp_ns += frame_interval_ns;
            try self.harness.runtime.dispatchPlatformEvent(self.app.app(), .{ .gpu_surface_frame = .{
                .label = canvas_label,
                .size = geometry.SizeF.init(surface_width, surface_height),
                .scale_factor = 2,
                .frame_index = self.frame_index,
                .timestamp_ns = self.timestamp_ns,
                .nonblank = true,
            } });
        }

        fn automation(self: *Self, comptime format: []const u8, args: anytype) !void {
            var buffer: [192]u8 = undefined;
            const line = try std.fmt.bufPrint(&buffer, format, args);
            try self.harness.runtime.dispatchAutomationCommand(self.app.app(), line);
        }

        fn timer(self: *Self, id: u64) !void {
            try self.harness.runtime.dispatchPlatformEvent(self.app.app(), .{ .timer = .{
                .id = id,
                .timestamp_ns = self.timestamp_ns,
            } });
        }
    };
}

fn findWidgetByKind(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.Widget {
    if (widget.kind == kind) return widget;
    for (widget.children) |child| {
        if (findWidgetByKind(child, kind)) |found| return found;
    }
    return null;
}

// ------------------------------------ fixture: big form (~930 widgets)

const big_form_rows = 28;
const big_form_columns = 32;
const big_form_items = big_form_rows * big_form_columns;

const BigItem = struct {
    title: []const u8,
};

var big_item_title_storage: [big_form_items][12]u8 = undefined;
var big_items: [big_form_items]BigItem = undefined;
var big_rows: [big_form_rows][]const BigItem = undefined;

fn initBigFormFixture() void {
    for (0..big_form_items) |index| {
        const title = std.fmt.bufPrint(&big_item_title_storage[index], "it {d}", .{index}) catch unreachable;
        big_items[index] = .{ .title = title };
    }
    for (0..big_form_rows) |row| {
        big_rows[row] = big_items[row * big_form_columns .. (row + 1) * big_form_columns];
    }
}

const BigFormMsg = union(enum) {
    toggle_flag,
    submit,
};

const BigFormModel = struct {
    flag: bool = false,
};

fn bigFormUpdate(model: *BigFormModel, msg: BigFormMsg) void {
    switch (msg) {
        .toggle_flag => model.flag = !model.flag,
        .submit => {},
    }
}

const BigFormApp = native_sdk.UiApp(BigFormModel, BigFormMsg);
const BigFormUi = BigFormApp.Ui;

fn bigItemKey(item: *const BigItem) canvas.UiKey {
    return canvas.uiKey(item.title);
}

fn bigItemView(ui: *BigFormUi, flag: bool, item: *const BigItem) BigFormUi.Node {
    _ = flag;
    // Definite width: 32 items x (34 + 2 gap) fits the 1200pt surface,
    // so layout never logs overflow (stderr writes would distort the
    // measurement).
    return ui.listItem(.{ .width = 34, .height = 22 }, item.title);
}

fn bigRowKey(row: *const []const BigItem) canvas.UiKey {
    return canvas.uiKey(row.*[0].title);
}

fn bigRowView(ui: *BigFormUi, flag: bool, row: *const []const BigItem) BigFormUi.Node {
    return ui.row(.{ .height = 24, .gap = 2 }, ui.eachCtx(flag, row.*, bigItemKey, bigItemView));
}

fn bigFormTextLeaf(ui: *BigFormUi, kind: canvas.WidgetKind, options: BigFormUi.ElementOptions, content: []const u8) BigFormUi.Node {
    var node = ui.el(kind, options, .{});
    node.widget.text = content;
    return node;
}

fn bigFormView(ui: *BigFormUi, model: *const BigFormModel) BigFormUi.Node {
    return ui.column(.{ .padding = 8, .gap = 4 }, .{
        ui.row(.{ .height = 32, .gap = 12, .cross = .center }, .{
            bigFormTextLeaf(ui, .text_field, .{
                .width = 260,
                .semantics = .{ .label = "Bench field" },
                .on_submit = BigFormMsg.submit,
            }, "seed"),
            bigFormTextLeaf(ui, .switch_control, .{
                .checked = model.flag,
                .value = if (model.flag) 1 else 0,
                .semantics = .{ .label = "Bench toggle" },
                .on_toggle = BigFormMsg.toggle_flag,
            }, "Flag"),
            ui.spacer(1),
        }),
        ui.column(.{ .grow = 1, .gap = 2 }, ui.eachCtx(model.flag, big_rows[0..], bigRowKey, bigRowView)),
    });
}

fn bigFormOptions() BigFormApp.Options {
    return .{
        .name = "bench-big-form",
        .scene = bench_scene,
        .canvas_label = canvas_label,
        .update = bigFormUpdate,
        .view = bigFormView,
    };
}

// -------------------------------------- fixture: markdown transcript

const transcript_messages = 200;

var transcript_storage: [transcript_messages][192]u8 = undefined;
var transcript_sources: [transcript_messages][]const u8 = undefined;

fn initTranscriptFixture() void {
    for (0..transcript_messages) |index| {
        // Two inline spans per message (bold speaker + prose) keeps 200
        // messages inside `max_canvas_widget_spans_per_view` (1024).
        transcript_sources[index] = std.fmt.bufPrint(
            &transcript_storage[index],
            "**speaker-{d}**: reply {d} lands the retained-canvas fix for pass {d}, wrapping to a second line on narrow panes.",
            .{ index % 7, index, index % 13 },
        ) catch unreachable;
    }
}

const TranscriptMsg = union(enum) {
    scrolled: canvas.ScrollState,
};

const TranscriptModel = struct {
    offset: f32 = 0,
};

fn transcriptUpdate(model: *TranscriptModel, msg: TranscriptMsg) void {
    switch (msg) {
        .scrolled => |scroll| model.offset = scroll.offset_y,
    }
}

const TranscriptApp = native_sdk.UiApp(TranscriptModel, TranscriptMsg);
const TranscriptUi = TranscriptApp.Ui;
const TranscriptMarkdown = canvas.markdown.Markdown(TranscriptMsg);

fn transcriptMessageKey(source: *const []const u8) canvas.UiKey {
    return canvas.uiKey(source.*);
}

fn transcriptMessageView(ui: *TranscriptUi, context: void, source: *const []const u8) TranscriptUi.Node {
    _ = context;
    return TranscriptMarkdown.view(ui, source.*, .{});
}

fn transcriptView(ui: *TranscriptUi, model: *const TranscriptModel) TranscriptUi.Node {
    return ui.scroll(.{
        .grow = 1,
        .value = model.offset,
        .on_scroll = TranscriptUi.scrollMsg(.scrolled),
        .semantics = .{ .label = "Transcript" },
    }, ui.column(.{ .gap = 10, .padding = 12 }, ui.eachCtx({}, transcript_sources[0..], transcriptMessageKey, transcriptMessageView)));
}

fn transcriptOptions() TranscriptApp.Options {
    return .{
        .name = "bench-transcript",
        .scene = bench_scene,
        .canvas_label = canvas_label,
        .update = transcriptUpdate,
        .view = transcriptView,
    };
}

// -------------------- fixture: measured-text chat (provider path)

// The provider-path regression class: a live text measure provider
// (CoreText on macOS) turns every text measurement into a host call, so
// the interesting number is measured CALLS per interaction, not just
// wall time. This fixture mirrors the profiled hot case — a focused
// input above a couple dozen wrapped chat messages, full TEA rebuild
// per keystroke — against a counting synthetic provider with
// kerning-ish per-cluster advances (additive, like the class the
// batched-seam parity law covers). The scenario asserts a hard cap on
// provider calls per keystroke: the pre-batching seam measured every
// growing line prefix once per cluster (tens of thousands of calls per
// keystroke at this fixture size), the batched seam plus the retained
// caches keep steady-state typing to a handful.

const measured_chat_messages = 24;

var measured_chat_storage: [measured_chat_messages][192]u8 = undefined;
var measured_chat_sources: [measured_chat_messages][]const u8 = undefined;

fn initMeasuredChatFixture() void {
    for (0..measured_chat_messages) |index| {
        measured_chat_sources[index] = std.fmt.bufPrint(
            &measured_chat_storage[index],
            "**voice-{d}**: message {d} in the measured transcript wraps across several lines at pane width, with `inline code` and *emphasis* mixed in for span variety.",
            .{ index % 5, index },
        ) catch unreachable;
    }
}

const MeasuredCounters = struct {
    unit_calls: u64 = 0,
    /// Bytes measured through the per-prefix seam. THE ratchet metric:
    /// the convicted regression class measures the growing line prefix
    /// once per cluster, which is quadratic in BYTES while staying
    /// modest in calls — the healthy steady state is a handful of
    /// whole-slice widths per frame (line bounds and label widths), so
    /// bytes separate the two regimes by orders of magnitude where raw
    /// call counts blur them.
    unit_bytes: u64 = 0,
    batch_calls: u64 = 0,

    fn total(self: MeasuredCounters) u64 {
        return self.unit_calls + self.batch_calls;
    }
};

var measured_counters: MeasuredCounters = .{};

/// Kerning-ish synthetic advance: varies per cluster lead byte and byte
/// length so cumulative widths are irregular like shaped text, while
/// staying additive — the class the batched seam contract covers.
fn measuredClusterAdvance(font_id: u64, size: f32, cluster: []const u8) f32 {
    const lead: f32 = @floatFromInt(cluster[0] % 13);
    const len: f32 = @floatFromInt(cluster.len);
    const font: f32 = @floatFromInt(font_id % 5);
    return size * (0.31 + lead * 0.037 + len * 0.041 + font * 0.011);
}

fn measuredMeasureText(context: ?*anyopaque, font_id: u64, size: f32, text: []const u8) f32 {
    _ = context;
    measured_counters.unit_calls += 1;
    measured_counters.unit_bytes += text.len;
    var width: f32 = 0;
    var index: usize = 0;
    while (index < text.len) {
        const next = @min(text.len, index + canvas.utf8SequenceLength(text[index]));
        width += measuredClusterAdvance(font_id, size, text[index..next]);
        index = next;
    }
    return width;
}

fn measuredMeasureTextAdvances(context: ?*anyopaque, font_id: u64, size: f32, text: []const u8, advances: []f32) bool {
    _ = context;
    measured_counters.batch_calls += 1;
    var index: usize = 0;
    while (index < text.len) {
        const next = @min(text.len, index + canvas.utf8SequenceLength(text[index]));
        advances[index] = measuredClusterAdvance(font_id, size, text[index..next]);
        @memset(advances[index + 1 .. next], 0);
        index = next;
    }
    return true;
}

const MeasuredChatMsg = union(enum) {
    typed,
    scrolled: canvas.ScrollState,
};

const measured_chat_draft_capacity = 96;

const MeasuredChatModel = struct {
    offset: f32 = 0,
    draft: [measured_chat_draft_capacity]u8 = @splat('m'),
    draft_len: usize = 4,
    typed: u32 = 0,
};

/// Each keystroke is a MODEL edit (a bound composer), so the whole view
/// rebuilds — the convicted path: every mounted wrapped paragraph gets
/// its height re-asked and its runs re-emitted per keystroke, changed
/// or not. The draft cycles inside its capacity so every iteration is
/// an identical steady-state edit.
fn measuredChatUpdate(model: *MeasuredChatModel, msg: MeasuredChatMsg) void {
    switch (msg) {
        .typed => {
            model.typed += 1;
            model.draft[model.draft_len % measured_chat_draft_capacity] = 'a' + @as(u8, @intCast(model.typed % 26));
            model.draft_len = (model.draft_len % measured_chat_draft_capacity) + 1;
        },
        .scrolled => |scroll| model.offset = scroll.offset_y,
    }
}

const MeasuredChatApp = native_sdk.UiApp(MeasuredChatModel, MeasuredChatMsg);
const MeasuredChatUi = MeasuredChatApp.Ui;
const MeasuredChatMarkdown = canvas.markdown.Markdown(MeasuredChatMsg);

fn measuredChatMessageKey(source: *const []const u8) canvas.UiKey {
    return canvas.uiKey(source.*);
}

fn measuredChatMessageView(ui: *MeasuredChatUi, context: void, source: *const []const u8) MeasuredChatUi.Node {
    _ = context;
    return MeasuredChatMarkdown.view(ui, source.*, .{});
}

fn measuredChatTextLeaf(ui: *MeasuredChatUi, kind: canvas.WidgetKind, options: MeasuredChatUi.ElementOptions, content: []const u8) MeasuredChatUi.Node {
    var node = ui.el(kind, options, .{});
    node.widget.text = content;
    return node;
}

fn measuredChatView(ui: *MeasuredChatUi, model: *const MeasuredChatModel) MeasuredChatUi.Node {
    return ui.column(.{ .padding = 12, .gap = 8 }, .{
        ui.scroll(.{
            .grow = 1,
            .value = model.offset,
            .on_scroll = MeasuredChatUi.scrollMsg(.scrolled),
            .semantics = .{ .label = "Measured transcript" },
        }, ui.column(.{ .gap = 10 }, ui.eachCtx({}, measured_chat_sources[0..], measuredChatMessageKey, measuredChatMessageView))),
        measuredChatTextLeaf(ui, .text_field, .{
            .height = 32,
            .semantics = .{ .label = "Composer" },
        }, ui.fmt("{s}", .{model.draft[0..model.draft_len]})),
    });
}

fn measuredChatOptions() MeasuredChatApp.Options {
    return .{
        .name = "bench-measured-chat",
        .scene = bench_scene,
        .canvas_label = canvas_label,
        .update = measuredChatUpdate,
        .view = measuredChatView,
    };
}

// ------------------------------------------ fixture: chart dashboard

const chart_points = 120;
const chart_timer_id: u64 = 7;

const ChartMsg = union(enum) {
    tick,
};

const ChartModel = struct {
    values: [chart_points]f32 = @splat(0),
    ticks: u32 = 0,
};

fn chartUpdate(model: *ChartModel, msg: ChartMsg) void {
    switch (msg) {
        .tick => {
            model.ticks += 1;
            std.mem.copyForwards(f32, model.values[0 .. chart_points - 1], model.values[1..chart_points]);
            const phase: f32 = @floatFromInt(model.ticks % 97);
            model.values[chart_points - 1] = 40 + 30 * @sin(phase * 0.13) + 5 * @cos(phase * 0.41);
        },
    }
}

const ChartApp = native_sdk.UiApp(ChartModel, ChartMsg);
const ChartUi = ChartApp.Ui;

fn chartView(ui: *ChartUi, model: *const ChartModel) ChartUi.Node {
    const series = [_]canvas.ChartSeries{.{
        .kind = .line,
        .fill = true,
        .label = "throughput",
        .values = &model.values,
    }};
    return ui.column(.{ .padding = 24, .gap = 16 }, .{
        ui.text(.{}, "Bench dashboard"),
        ui.chart(.{ .width = 640, .height = 220, .grid_lines = 4, .baseline = true }, ui.arena.dupe(canvas.ChartSeries, &series) catch &.{}),
        ui.text(.{ .size = .sm }, ui.fmt("ticks {d}", .{model.ticks})),
    });
}

fn chartOnTimer(id: u64, timestamp_ns: u64) ?ChartMsg {
    _ = timestamp_ns;
    if (id == chart_timer_id) return .tick;
    return null;
}

fn chartOptions() ChartApp.Options {
    return .{
        .name = "bench-chart",
        .scene = bench_scene,
        .canvas_label = canvas_label,
        .update = chartUpdate,
        .view = chartView,
        .on_timer = chartOnTimer,
    };
}

// -------------------------------------- fixture: large markdown doc

const doc_blocks = 56;
var doc_storage: [32 * 1024]u8 = undefined;
var doc_len: usize = 0;
/// Mutable tail the edit Msg appends to, so every re-render has a real
/// content change to diff/patch.
var doc_tail_len: usize = 0;

fn initDocFixture() void {
    var writer = std.Io.Writer.fixed(&doc_storage);
    writer.writeAll("# Bench document\n\nA README-sized fixture: headings, prose, lists, code.\n\n") catch unreachable;
    for (0..doc_blocks / 4) |section| {
        writer.print("## Section {d}\n\n", .{section}) catch unreachable;
        writer.print("Paragraph {d} covers the retained canvas pipeline: display lists diff into patches, *unchanged* text runs skip `layoutTextRun`, and the host retains the keyed command dictionary between frames so steady-state cost tracks what changed.\n\n", .{section}) catch unreachable;
        writer.print("- item one for section {d} with `code` span\n- item two with **bold** emphasis\n- item three linking #12{d}\n\n", .{ section, section }) catch unreachable;
        writer.writeAll("```zig\nconst frame = try planCanvasFrame(options, storage);\n```\n\n") catch unreachable;
    }
    writer.writeAll("Tail: ") catch unreachable;
    doc_len = writer.buffered().len;
}

const DocMsg = union(enum) {
    edit,
};

const DocModel = struct {
    revision: u32 = 0,
};

fn docUpdate(model: *DocModel, msg: DocMsg) void {
    switch (msg) {
        .edit => {
            model.revision += 1;
            if (doc_len + doc_tail_len < doc_storage.len) {
                doc_storage[doc_len + doc_tail_len] = 'a' + @as(u8, @intCast(model.revision % 26));
                doc_tail_len += 1;
            }
        },
    }
}

const DocApp = native_sdk.UiApp(DocModel, DocMsg);
const DocUi = DocApp.Ui;
const DocMarkdown = canvas.markdown.Markdown(DocMsg);

fn docView(ui: *DocUi, model: *const DocModel) DocUi.Node {
    _ = model;
    return ui.scroll(.{ .grow = 1 }, ui.column(.{ .padding = 16 }, DocMarkdown.view(ui, doc_storage[0 .. doc_len + doc_tail_len], .{})));
}

fn docOptions() DocApp.Options {
    return .{
        .name = "bench-doc",
        .scene = bench_scene,
        .canvas_label = canvas_label,
        .update = docUpdate,
        .view = docView,
    };
}

// ------------------------------------------------------------ scenarios

/// Generic measured loop: warmup, profile reset, N timed iterations.
fn measure(
    comptime name: []const u8,
    comptime detail: []const u8,
    bench: anytype,
    iterations: usize,
    step: anytype,
) !ScenarioReport {
    bench.runtime().frame_profile.enabled = true;
    for (0..warmup_iterations) |_| try step.run(bench);
    bench.runtime().frame_profile.reset();
    var e2e = Series{};
    for (0..iterations) |_| {
        const begin = native_sdk.monotonicNanoseconds();
        try step.run(bench);
        e2e.push(native_sdk.monotonicNanoseconds() -| begin);
    }
    return .{
        .name = name,
        .detail = detail,
        .iterations = iterations,
        .e2e_p50_us = e2e.percentileUs(50),
        .e2e_p90_us = e2e.percentileUs(90),
        .stages = captureStages(bench.runtime()),
    };
}

fn widgetIdByKind(bench: anytype, kind: canvas.WidgetKind) !canvas.ObjectId {
    const tree = bench.app.tree orelse return error.FixtureNotInstalled;
    const widget = findWidgetByKind(tree.root, kind) orelse return error.FixtureWidgetMissing;
    return widget.id;
}

fn scenarioKeystroke() !ScenarioReport {
    var bench = try Bench(BigFormApp).create(bigFormOptions());
    defer bench.destroy();
    const field_id = try widgetIdByKind(&bench, .text_field);
    try bench.automation("widget-action {s} {d} focus", .{ canvas_label, field_id });
    try bench.frame();
    const step = struct {
        fn run(b: *Bench(BigFormApp)) !void {
            try b.automation("widget-key {s} a a", .{canvas_label});
            try b.frame();
        }
    };
    return measure(
        "keystroke-big-view",
        "typed char into focused field, ~930-widget view",
        &bench,
        measured_iterations,
        step,
    );
}

fn scenarioToggle() !ScenarioReport {
    var bench = try Bench(BigFormApp).create(bigFormOptions());
    defer bench.destroy();
    const toggle_id = try widgetIdByKind(&bench, .switch_control);
    var buffer: [96]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "widget-click {s} {d}", .{ canvas_label, toggle_id });
    toggle_click_line = line;
    const step = struct {
        fn run(b: *Bench(BigFormApp)) !void {
            try b.harness.runtime.dispatchAutomationCommand(b.app.app(), toggle_click_line);
            try b.frame();
        }
    };
    return measure(
        "toggle-big-view",
        "switch click -> Msg -> full TEA rebuild, ~930 widgets",
        &bench,
        measured_iterations,
        step,
    );
}

var toggle_click_line: []const u8 = "";
var wheel_line: []const u8 = "";

fn scenarioTranscriptScroll() !ScenarioReport {
    var bench = try Bench(TranscriptApp).create(transcriptOptions());
    defer bench.destroy();
    const scroll_id = try widgetIdByKind(&bench, .scroll_view);
    var buffer: [96]u8 = undefined;
    wheel_line = try std.fmt.bufPrint(&buffer, "widget-wheel {s} {d} 96", .{ canvas_label, scroll_id });
    const step = struct {
        fn run(b: *Bench(TranscriptApp)) !void {
            try b.harness.runtime.dispatchAutomationCommand(b.app.app(), wheel_line);
            try b.frame();
        }
    };
    return measure(
        "scroll-transcript",
        "wheel step through 200-message markdown transcript",
        &bench,
        measured_iterations,
        step,
    );
}

/// The two provider-call caps guarding the batched seam and its caches.
/// Both counters are deterministic (synthetic provider, scripted
/// interactions), so the caps sit close to the measured signatures:
///
/// - Per-prefix BYTES per keystroke — healthy 3355 (whole-slice widths
///   only: per-frame line bounds and label widths over the retained
///   runs); with the batched seam disabled 17465 (prefix re-measures
///   come back for the composer and elided labels even though the wrap
///   cache still absorbs the paragraphs); pre-batching, hundreds of
///   thousands. Bytes rather than calls: a whole-line bounds measure
///   and a one-cluster prefix step are one call each, so the quadratic
///   class multiplies bytes by orders of magnitude while call counts
///   blur.
/// - Batched CALLS per keystroke — healthy 1 (the composer's changed
///   text; everything else hits the retained advance and wrap caches);
///   a broken cache (always-miss keying, generation stuck bumping)
///   refetches every mounted paragraph every rebuild (tens per
///   keystroke) while keeping per-prefix bytes low, which is why the
///   byte cap alone cannot see it.
const measured_chat_unit_byte_cap_per_keystroke: u64 = 8_000;
const measured_chat_batch_call_cap_per_keystroke: u64 = 20;

fn scenarioMeasuredKeystroke() !ScenarioReport {
    var bench = try Bench(MeasuredChatApp).create(measuredChatOptions());
    defer bench.destroy();
    // Install the counting provider the way platforms install CoreText:
    // on the runtime, before the measured interactions (tokens re-stamp
    // it on the next rebuild). The provider value lives on the runtime,
    // so its pointer identity is stable across frames like a real host's.
    bench.runtime().text_measure_provider = .{
        .measure_fn = measuredMeasureText,
        .measure_advances_fn = measuredMeasureTextAdvances,
    };
    // One rebuild with the provider installed so the first measured
    // iteration is steady-state, not the cold token flip.
    try bench.app.dispatch(&bench.harness.runtime, 1, .typed);
    try bench.frame();
    const step = struct {
        fn run(b: *Bench(MeasuredChatApp)) !void {
            // The composer edit dispatches the way UiApp dispatches
            // command Msgs: model change -> full TEA rebuild -> present.
            try b.app.dispatch(&b.harness.runtime, 1, .typed);
            try b.frame();
        }
    };
    const before = measured_counters;
    const report = try measure(
        "keystroke-measured-text",
        "typed char over 24 wrapped messages, live measure provider",
        &bench,
        measured_iterations,
        step,
    );
    // The snapshot above precedes `measure`, whose window is warmup plus
    // measured iterations — every one an identical steady-state
    // keystroke, so the per-iteration average over the whole window is
    // the honest per-keystroke number (the first-ever keystroke's cold
    // fetches amortize into it and still fit the cap with room).
    const iterations: u64 = @intCast(warmup_iterations + measured_iterations);
    const calls_per_keystroke = (measured_counters.total() - before.total()) / iterations;
    const unit_bytes_per_keystroke = (measured_counters.unit_bytes - before.unit_bytes) / iterations;
    std.debug.print(
        "bench-render: keystroke-measured-text per keystroke: {d} provider calls ({d} batched + {d} per-prefix), {d} per-prefix bytes (cap {d})\n",
        .{
            calls_per_keystroke,
            measured_counters.batch_calls - before.batch_calls,
            measured_counters.unit_calls - before.unit_calls,
            unit_bytes_per_keystroke,
            measured_chat_unit_byte_cap_per_keystroke,
        },
    );
    if (unit_bytes_per_keystroke > measured_chat_unit_byte_cap_per_keystroke) {
        std.debug.print(
            "bench-render: keystroke-measured-text measured {d} per-prefix bytes per keystroke (cap {d}) — the batched measurement seam regressed\n",
            .{ unit_bytes_per_keystroke, measured_chat_unit_byte_cap_per_keystroke },
        );
        return error.MeasuredTextByteCapExceeded;
    }
    const batch_calls_per_keystroke = (measured_counters.batch_calls - before.batch_calls) / iterations;
    if (batch_calls_per_keystroke > measured_chat_batch_call_cap_per_keystroke) {
        std.debug.print(
            "bench-render: keystroke-measured-text made {d} batched provider calls per keystroke (cap {d}) — the advance or wrap cache regressed\n",
            .{ batch_calls_per_keystroke, measured_chat_batch_call_cap_per_keystroke },
        );
        return error.MeasuredTextBatchCapExceeded;
    }
    return report;
}

fn scenarioChartTick() !ScenarioReport {
    var bench = try Bench(ChartApp).create(chartOptions());
    defer bench.destroy();
    const step = struct {
        fn run(b: *Bench(ChartApp)) !void {
            try b.timer(chart_timer_id);
            try b.frame();
        }
    };
    return measure(
        "chart-tick",
        "timer Msg shifts 120-pt series, chart re-render",
        &bench,
        measured_iterations,
        step,
    );
}

fn scenarioDocEdit() !ScenarioReport {
    var bench = try Bench(DocApp).create(docOptions());
    defer bench.destroy();
    const step = struct {
        fn run(b: *Bench(DocApp)) !void {
            // Drive the edit Msg through the real automation channel:
            // shortcut -> on_command has no mapping here, so dispatch the
            // Msg directly the way UiApp does for commands.
            try b.app.dispatch(&b.harness.runtime, 1, .edit);
            try b.frame();
        }
    };
    return measure(
        "markdown-doc-edit",
        "append char to README-sized doc, full markdown re-render",
        &bench,
        measured_iterations,
        step,
    );
}

fn scenarioFirstFrame() !ScenarioReport {
    var e2e = Series{};
    var stages: [stage_values.len]StageStats = undefined;
    for (&stages) |*entry| entry.* = .{};
    var stage_series: [stage_values.len]Series = undefined;
    for (&stage_series) |*series| series.* = .{};

    for (0..first_frame_iterations) |_| {
        const begin = native_sdk.monotonicNanoseconds();
        var bench = try BenchFirstFrame.create();
        e2e.push(native_sdk.monotonicNanoseconds() -| begin);
        // One install per harness: each stage's single-sample p50 IS the
        // sample; accumulate across iterations.
        inline for (stage_values, 0..) |stage, index| {
            const stats = bench.runtime().frame_profile.stats(stage);
            if (stats.window_len > 0) stage_series[index].push(stats.p50_us * std.time.ns_per_us);
        }
        bench.destroy();
    }
    inline for (0..stage_values.len) |index| {
        stages[index] = .{
            .p50_us = stage_series[index].percentileUs(50),
            .p90_us = stage_series[index].percentileUs(90),
            .count = stage_series[index].len,
            .window = stage_series[index].len,
        };
    }
    return .{
        .name = "first-frame",
        .detail = "create app+runtime -> install -> first present (~930 widgets)",
        .iterations = first_frame_iterations,
        .e2e_p50_us = e2e.percentileUs(50),
        .e2e_p90_us = e2e.percentileUs(90),
        .stages = stages,
    };
}

/// First-frame variant of `Bench`: profiling is enabled BEFORE the
/// install frame so the startup path is attributed.
const BenchFirstFrame = struct {
    harness: *Harness,
    app: *BigFormApp,

    fn create() !BenchFirstFrame {
        const harness = try Harness.create(gpa, .{ .size = geometry.SizeF.init(surface_width, surface_height) });
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.gpu_surface_packet_binary = true;
        harness.runtime.options.gpu_surface_frame_diagnostics = false;
        harness.runtime.frame_profile.enabled = true;
        const app = try gpa.create(BigFormApp);
        app.* = BigFormApp.init(gpa, .{}, bigFormOptions());
        try harness.start(app.app());
        try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(surface_width, surface_height),
            .scale_factor = 2,
            .frame_index = 1,
            .timestamp_ns = 1_000_000_000,
            .nonblank = true,
        } });
        if (!app.installed) return error.FixtureNotInstalled;
        return .{ .harness = harness, .app = app };
    }

    fn runtime(self: *BenchFirstFrame) *native_sdk.Runtime {
        return &self.harness.runtime;
    }

    fn destroy(self: *BenchFirstFrame) void {
        self.app.deinit();
        gpa.destroy(self.app);
        self.harness.destroy(gpa);
    }
};

// --------------------------------------------------------------- report

fn printReports(reports: []const ScenarioReport) void {
    std.debug.print("\nbench-render: end-to-end (us per interaction; {d} iterations after {d} warmup; first-frame {d} iterations)\n\n", .{
        measured_iterations,
        warmup_iterations,
        first_frame_iterations,
    });
    std.debug.print("{s:<22} {s:>10} {s:>10}  {s}\n", .{ "scenario", "p50_us", "p90_us", "notes" });
    for (reports) |report| {
        std.debug.print("{s:<22} {s:>10} {s:>10}  {s}{s}\n", .{
            report.name,
            fmtUs(report.e2e_p50_us),
            fmtUs(report.e2e_p90_us),
            report.detail,
            if (report.noisy()) " [noisy]" else "",
        });
    }

    std.debug.print("\nper-stage breakdown (p50/p90 us per invocation, xN = samples in the measured window; '-' = stage did not run)\n\n", .{});
    std.debug.print("{s:<22}", .{"scenario"});
    inline for (stage_values) |stage| {
        std.debug.print(" {s:>17}", .{@tagName(stage)});
    }
    std.debug.print("\n", .{});
    for (reports) |report| {
        std.debug.print("{s:<22}", .{report.name});
        for (report.stages) |stage| {
            if (stage.count == 0) {
                std.debug.print(" {s:>17}", .{"-"});
            } else {
                var cell: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&cell, "{d}/{d} x{d}", .{ stage.p50_us, stage.p90_us, stage.window }) catch "?";
                std.debug.print(" {s:>17}", .{text});
            }
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("\n", .{});
}

var fmt_us_storage: [8][24]u8 = undefined;
var fmt_us_index: usize = 0;

fn fmtUs(value: u64) []const u8 {
    fmt_us_index = (fmt_us_index + 1) % fmt_us_storage.len;
    return std.fmt.bufPrint(&fmt_us_storage[fmt_us_index], "{d}", .{value}) catch "?";
}

// ---------------------------------------------------------- check mode

const scenario_count = 7;
const check_passes = 3;

fn runAllScenarios() ![scenario_count]ScenarioReport {
    var reports: [scenario_count]ScenarioReport = undefined;
    reports[0] = try scenarioFirstFrame();
    reports[1] = try scenarioKeystroke();
    reports[2] = try scenarioToggle();
    reports[3] = try scenarioTranscriptScroll();
    reports[4] = try scenarioChartTick();
    reports[5] = try scenarioDocEdit();
    reports[6] = try scenarioMeasuredKeystroke();
    return reports;
}

const Budget = struct {
    name: []const u8,
    p50_budget_us: u64,
    matched: bool = false,
};

const max_budgets = 16;

/// Budgets file: `<scenario-name> <p50-budget-us>` per line; blank lines
/// and `#` comments ignored.
fn parseBudgets(content: []const u8, storage: *[max_budgets]Budget) ![]Budget {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        const value_text = fields.next() orelse {
            std.debug.print("bench-render --check: budget line missing a value: '{s}'\n", .{line});
            return error.InvalidBudgetsFile;
        };
        if (fields.next() != null) {
            std.debug.print("bench-render --check: budget line has trailing fields: '{s}'\n", .{line});
            return error.InvalidBudgetsFile;
        }
        const value = std.fmt.parseInt(u64, value_text, 10) catch {
            std.debug.print("bench-render --check: budget value is not an integer of microseconds: '{s}'\n", .{line});
            return error.InvalidBudgetsFile;
        };
        if (count >= storage.len) return error.TooManyBudgets;
        storage[count] = .{ .name = name, .p50_budget_us = value };
        count += 1;
    }
    if (count == 0) {
        std.debug.print("bench-render --check: budgets file declared no budgets\n", .{});
        return error.InvalidBudgetsFile;
    }
    return storage[0..count];
}

fn medianOf(values: []u64) u64 {
    std.sort.pdq(u64, values, {}, std.sort.asc(u64));
    return values[(values.len - 1) / 2];
}

fn runCheck(init: std.process.Init, budgets_path: []const u8) !void {
    if (builtin.mode != .ReleaseFast) {
        std.debug.print("bench-render --check: budgets are calibrated for ReleaseFast; rebuild with -Doptimize=ReleaseFast (got {s})\n", .{@tagName(builtin.mode)});
        return error.WrongOptimizeMode;
    }
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const content = std.Io.Dir.cwd().readFileAlloc(init.io, budgets_path, arena_state.allocator(), .limited(64 * 1024)) catch |err| {
        std.debug.print("bench-render --check: cannot read budgets file '{s}': {s}\n", .{ budgets_path, @errorName(err) });
        return err;
    };
    var budget_storage: [max_budgets]Budget = undefined;
    const budgets = try parseBudgets(content, &budget_storage);

    // Median across passes: one descheduled pass (or one lucky one)
    // cannot decide the verdict on a loaded box.
    var passes: [check_passes][scenario_count]ScenarioReport = undefined;
    for (&passes, 0..) |*pass, pass_index| {
        pass.* = try runAllScenarios();
        std.debug.print("bench-render --check: pass {d}/{d}:", .{ pass_index + 1, check_passes });
        for (pass.*) |report| std.debug.print(" {s}={d}us", .{ report.name, report.e2e_p50_us });
        std.debug.print("\n", .{});
    }

    var failures: usize = 0;
    std.debug.print("\nbench-render --check: median e2e p50 of {d} passes vs budgets ({s})\n\n", .{ check_passes, budgets_path });
    std.debug.print("{s:<22} {s:>10} {s:>10}  {s}\n", .{ "scenario", "p50_us", "budget_us", "verdict" });
    for (0..scenario_count) |scenario_index| {
        const name = passes[0][scenario_index].name;
        var samples: [check_passes]u64 = undefined;
        for (passes, 0..) |pass, pass_index| samples[pass_index] = pass[scenario_index].e2e_p50_us;
        const median = medianOf(&samples);
        const budget: ?*Budget = for (budgets) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) break entry;
        } else null;
        if (budget) |entry| {
            entry.matched = true;
            const over = median > entry.p50_budget_us;
            if (over) failures += 1;
            std.debug.print("{s:<22} {d:>10} {d:>10}  {s}\n", .{ name, median, entry.p50_budget_us, if (over) "FAIL" else "ok" });
        } else {
            failures += 1;
            std.debug.print("{s:<22} {d:>10} {s:>10}  {s}\n", .{ name, median, "-", "FAIL (no budget declared)" });
        }
    }
    for (budgets) |entry| {
        if (!entry.matched) {
            failures += 1;
            std.debug.print("{s:<22} {s:>10} {d:>10}  FAIL (budget names no scenario — renamed?)\n", .{ entry.name, "-", entry.p50_budget_us });
        }
    }
    std.debug.print("\n", .{});
    if (failures > 0) {
        std.debug.print("bench-render --check: {d} budget check(s) failed\n", .{failures});
        return error.BudgetExceeded;
    }
    std.debug.print("bench-render --check: all scenarios within budget\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var args_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer args_arena.deinit();
    const args = try init.minimal.args.toSlice(args_arena.allocator());
    var budgets_path: ?[]const u8 = null;
    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        if (std.mem.eql(u8, args[arg_index], "--check")) {
            arg_index += 1;
            if (arg_index >= args.len) {
                std.debug.print("bench-render: --check requires a budgets file path\n", .{});
                return error.InvalidArguments;
            }
            budgets_path = args[arg_index];
        } else {
            std.debug.print("bench-render: unknown argument '{s}' (usage: bench-render [--check <budgets-file>])\n", .{args[arg_index]});
            return error.InvalidArguments;
        }
    }

    initBigFormFixture();
    initTranscriptFixture();
    initDocFixture();
    initMeasuredChatFixture();

    if (budgets_path) |path| return runCheck(init, path);

    const reports = try runAllScenarios();
    printReports(&reports);
}
