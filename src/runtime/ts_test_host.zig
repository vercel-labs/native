//! Private stdio protocol for @native-sdk/core/testing. Each process owns one
//! compiled core; all interaction, layout, effects and replay use the runtime.
const std = @import("std");
const sdk = @import("../root.zig");

const protocol_version = 1;
const max_request_bytes = 64 * 1024;
const max_response_bytes = 8 * 1024 * 1024;
const max_journal_bytes = 8 * 1024 * 1024;

const Request = struct {
    op: enum { start, snapshot, automation, text_action, input, drop, menu, frame, window_close, host_result, db_result, stream_line, spawn_output, spawn_exit, fetch_response, timer, replay, close },
    width: u32 = 640,
    height: u32 = 480,
    wall_ms: i64 = 0,
    command: []const u8 = "",
    key: []const u8 = "0",
    ok: bool = true,
    bytes: []const u8 = "",
    db_kind: sdk.EffectDbResultKind = .done,
    db_outcome: sdk.EffectDbOutcome = .ok,
    db_bytes: []const u8 = &.{},
    stream_bytes: []const u8 = &.{},
    truncated: bool = false,
    dropped_before: u32 = 0,
    exit_code: i32 = 0,
    exit_reason: sdk.EffectExitReason = .exited,
    fetch_outcome: sdk.EffectFetchOutcome = .ok,
    http_status: u16 = 200,
    view: []const u8 = "",
    window: u64 = 1,
    widget: []const u8 = "0",
    text_action: enum { set_text, set_selection, set_composition, commit_composition, cancel_composition } = .set_text,
    text: []const u8 = "",
    input: enum { pointer_down, pointer_drag, pointer_up, pointer_cancel, scroll } = .pointer_down,
    x: f32 = 0,
    y: f32 = 0,
    delta_x: f32 = 0,
    delta_y: f32 = 0,
    shift: bool = false,
    paths: []const []const u8 = &.{},
};

const Journal = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *Journal = @ptrCast(@alignCast(context));
        if (self.bytes.items.len + bytes.len > max_journal_bytes) return error.JournalFull;
        try self.bytes.appendSlice(std.heap.page_allocator, bytes);
    }
};

pub fn run(comptime Adapter: type, init: std.process.Init, options: Adapter.Options) !void {
    try runWithCoreOptions(Adapter, init, options, .{});
}

/// Generated service result codecs remain active under the fake executor.
/// Tests feed serialized results without launching production transports.
pub fn runWithCoreOptions(comptime Adapter: type, init: std.process.Init, options: Adapter.Options, core_options: Adapter.CoreOptions) !void {
    const gpa = std.heap.page_allocator;
    const Host = struct {
        harness: *sdk.TestHarness(),
        state: *Adapter.App,
        clock: sdk.TestClock = .{},
        size: sdk.geometry.SizeF,
        frame_index: u64 = 0,

        fn create(config: Request, app_options: Adapter.Options, wiring: Adapter.CoreOptions) !*@This() {
            if (config.width == 0 or config.width > 8192 or config.height == 0 or config.height > 8192) return error.InvalidSurfaceSize;
            // Times cross JavaScript exactly; reject out-of-range input.
            if (config.wall_ms < -9007199254740991 or config.wall_ms > 9007199254740991) return error.InvalidClock;
            const self = try gpa.create(@This());
            errdefer gpa.destroy(self);
            self.* = .{
                .size = sdk.geometry.SizeF.init(@floatFromInt(config.width), @floatFromInt(config.height)),
                .harness = undefined,
                .state = undefined,
            };
            self.harness = try sdk.TestHarness().create(gpa, .{ .size = self.size });
            errdefer self.harness.destroy(gpa);
            self.harness.null_platform.gpu_surfaces = true;
            self.harness.null_platform.image_decode = true;
            self.state = try Adapter.create(gpa, wiring, app_options);
            self.state.effects.executor = .fake;
            self.clock.setWallMs(config.wall_ms);
            self.state.effects.clock = self.clock.clock();
            return self;
        }

        fn destroy(self: *@This()) void {
            self.state.destroy();
            self.harness.destroy(gpa);
            gpa.destroy(self);
        }

        fn frame(self: *@This(), label: []const u8) !void {
            self.frame_index += 1;
            try self.harness.runtime.dispatchPlatformEvent(self.state.app(), .{ .gpu_surface_frame = .{
                .label = label,
                .size = self.size,
                .scale_factor = 1,
                .frame_index = self.frame_index,
                .timestamp_ns = self.frame_index * 16_000_000,
            } });
            var windows: [sdk.platform.max_windows]sdk.platform.WindowInfo = undefined;
            for (self.harness.runtime.listWindows(&windows)) |window| {
                if (!window.open) continue;
                var views: [sdk.platform.max_views]sdk.platform.ViewInfo = undefined;
                for (self.harness.runtime.listViews(window.id, &views)) |view| {
                    if (view.kind != .gpu_surface or std.mem.eql(u8, view.label, label)) continue;
                    try self.harness.runtime.dispatchPlatformEvent(self.state.app(), .{ .gpu_surface_frame = .{
                        .window_id = window.id,
                        .label = view.label,
                        .size = sdk.geometry.SizeF.init(view.frame.width, view.frame.height),
                        .scale_factor = 1,
                        .frame_index = self.frame_index,
                        .timestamp_ns = self.frame_index * 16_000_000,
                    } });
                }
            }
            try self.harness.runtime.dispatchPlatformEvent(self.state.app(), .frame_requested);
        }

        fn snapshot(self: *@This(), recorder: *sdk.runtime.SessionRecorder, writer: *std.Io.Writer) !void {
            const snapshot_value = self.harness.runtime.automationSnapshot("Native test");
            var json: std.json.Stringify = .{ .writer = writer };
            try json.beginObject();
            try json.objectField("viewBackend");
            try json.write(Adapter.view_backend);
            try json.objectField("model");
            // Byte arrays stay lossless, including non-UTF8 and embedded NUL.
            json.options.emit_strings_as_arrays = true;
            try json.write(Adapter.Host.model().*);
            json.options.emit_strings_as_arrays = false;
            try json.objectField("fingerprint");
            var id_buffer: [32]u8 = undefined;
            try json.write(try std.fmt.bufPrint(&id_buffer, "{x}", .{self.harness.runtime.sessionStateFingerprint()}));
            try json.objectField("windows");
            try json.beginArray();
            var windows: [sdk.platform.max_windows]sdk.platform.WindowInfo = undefined;
            for (self.harness.runtime.listWindows(&windows)) |window| {
                if (!window.open) continue;
                try json.write(.{
                    .id = window.id,
                    .label = window.label,
                    .title = window.title,
                    .bounds = window.frame,
                    .focused = window.focused,
                    .hidden = window.hidden,
                });
            }
            try json.endArray();
            try json.objectField("widgets");
            try json.beginArray();
            for (snapshot_value.widgets) |widget| {
                const scroll = self.scrollState(widget.window_id, widget.view_label, widget.id);
                try json.write(.{
                    .id = try std.fmt.bufPrint(&id_buffer, "{d}", .{widget.id}),
                    .view = widget.view_label,
                    .window = widget.window_id,
                    .role = widget.role,
                    .name = widget.name,
                    .text = widget.text_value,
                    .value = if (widget.value) |value| @as(?f64, @floatCast(value)) else null,
                    .scroll = scroll,
                    .enabled = widget.enabled,
                    .focused = widget.focused,
                    .selected = widget.selected,
                    .bounds = widget.bounds,
                    .actions = widget.actions,
                });
            }
            try json.endArray();
            try json.objectField("effects");
            try json.beginObject();
            try json.objectField("recorded");
            try json.write(recorder.effect_count);
            try json.objectField("requests");
            try json.beginArray();
            for (0..self.state.effects.pendingHostCount()) |index| {
                const request = self.state.effects.pendingHostAt(index).?;
                try json.beginObject();
                try json.objectField("key");
                try json.write(try std.fmt.bufPrint(&id_buffer, "{d}", .{request.key}));
                try json.objectField("name");
                try json.write(request.name);
                try json.objectField("bytes");
                json.options.emit_strings_as_arrays = true;
                try json.write(request.payload);
                json.options.emit_strings_as_arrays = false;
                try json.endObject();
            }
            try json.endArray();
            try json.objectField("spawns");
            try json.beginArray();
            for (0..self.state.effects.pendingSpawnCount()) |index| {
                const request = self.state.effects.pendingSpawnAt(index).?;
                try json.beginObject();
                try json.objectField("key");
                try json.write(try std.fmt.bufPrint(&id_buffer, "{d}", .{request.key}));
                try json.objectField("output");
                try json.write(request.output);
                try json.objectField("maxLineBytes");
                try json.write(request.max_line_bytes);
                json.options.emit_strings_as_arrays = true;
                try json.objectField("argv");
                try json.write(request.argv);
                try json.objectField("stdin");
                try json.write(request.stdin);
                json.options.emit_strings_as_arrays = false;
                try json.endObject();
            }
            try json.endArray();
            try json.objectField("fetches");
            try json.beginArray();
            for (0..self.state.effects.pendingFetchCount()) |index| {
                const request = self.state.effects.pendingFetchAt(index).?;
                try json.beginObject();
                try json.objectField("key");
                try json.write(try std.fmt.bufPrint(&id_buffer, "{d}", .{request.key}));
                try json.objectField("method");
                try json.write(request.method);
                try json.objectField("response");
                try json.write(request.response);
                try json.objectField("maxLineBytes");
                try json.write(request.max_line_bytes);
                json.options.emit_strings_as_arrays = true;
                try json.objectField("url");
                try json.write(request.url);
                try json.objectField("headers");
                try json.write(request.headers);
                try json.objectField("body");
                try json.write(request.body);
                json.options.emit_strings_as_arrays = false;
                try json.endObject();
            }
            try json.endArray();
            try json.objectField("timers");
            try json.beginArray();
            for (0..self.state.effects.pendingTimerCount()) |index| {
                const timer = self.state.effects.pendingTimerAt(index).?;
                try json.write(.{
                    .key = try std.fmt.bufPrint(&id_buffer, "{d}", .{timer.key}),
                    .intervalMs = timer.interval_ms,
                    .mode = timer.mode,
                });
            }
            try json.endArray();
            try json.objectField("databases");
            try json.beginArray();
            for (0..self.state.effects.pendingDbCount()) |index| {
                const db = self.state.effects.pendingDbAt(index).?;
                const key = try std.fmt.bufPrint(&id_buffer, "{d}", .{db.key});
                var generation_buffer: [32]u8 = undefined;
                const generation = try std.fmt.bufPrint(&generation_buffer, "{d}", .{db.generation});
                try json.beginObject();
                try json.objectField("key");
                try json.write(key);
                try json.objectField("generation");
                try json.write(generation);
                try json.objectField("kind");
                try json.write(db.kind);
                try json.objectField("sql");
                try json.write(db.sql);
                try json.objectField("params");
                json.options.emit_strings_as_arrays = true;
                try json.write(db.params);
                json.options.emit_strings_as_arrays = false;
                try json.objectField("tables");
                try json.write(db.tables);
                try json.endObject();
            }
            try json.endArray();
            try json.endObject();
            try json.endObject();
        }

        fn scrollState(self: *@This(), window_id: u64, label: []const u8, id: u64) ?struct {
            offsetX: f64,
            offsetY: f64,
            velocityX: f64,
            velocityY: f64,
            viewportExtentX: f64,
            viewportExtentY: f64,
            contentExtentX: f64,
            contentExtentY: f64,
        } {
            for (self.harness.runtime.views[0..self.harness.runtime.view_count]) |*view| {
                if (!view.open or view.window_id != window_id or !std.mem.eql(u8, view.label, label)) continue;
                const state = view.canvasWidgetScrollStateById(id) orelse return null;
                return .{
                    .offsetX = state.offset_x,
                    .offsetY = state.offset_y,
                    .velocityX = state.velocity_x,
                    .velocityY = state.velocity_y,
                    .viewportExtentX = state.viewport_extent_x,
                    .viewportExtentY = state.viewport_extent_y,
                    .contentExtentX = state.content_extent_x,
                    .contentExtentY = state.content_extent_y,
                };
            }
            return null;
        }
    };

    var journal: Journal = .{};
    defer journal.bytes.deinit(gpa);
    const recorder = try gpa.create(sdk.runtime.SessionRecorder);
    defer gpa.destroy(recorder);
    recorder.* = sdk.runtime.SessionRecorder.init(.{ .context = &journal, .write_fn = Journal.write });
    var host: ?*Host = null;
    defer if (host) |value| value.destroy();
    var config: Request = undefined;
    var replayed = false;
    const input_buffer = try gpa.alloc(u8, max_request_bytes);
    defer gpa.free(input_buffer);
    var input = std.Io.File.stdin().reader(init.io, input_buffer);
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    const response_buffer = try gpa.alloc(u8, max_response_bytes);
    defer gpa.free(response_buffer);

    while (true) {
        const line = input.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        input.interface.toss(1); // takeDelimiterExclusive leaves the newline buffered.
        const parsed = try std.json.parseFromSlice(Request, gpa, line, .{});
        defer parsed.deinit();
        const request = parsed.value;
        if (request.op == .close) {
            if (host) |value| try value.harness.stop(value.state.app());
            try output.interface.writeAll("{\"protocol\":1,\"closed\":true}\n");
            try output.interface.flush();
            return;
        }
        var response = std.Io.Writer.fixed(response_buffer);
        try response.print("{{\"protocol\":{d},", .{protocol_version});
        // A failed dispatch is terminal: the parent rejects the pending request
        // with the exit status and stderr; it can never observe a partial reply.
        if (request.op == .start) {
            if (host != null) return error.AlreadyStarted;
            config = request;
            host = try Host.create(config, options, core_options);
            recorder.begin(.{ .platform_name = "test", .app_name = options.name, .window_width = @floatFromInt(config.width), .window_height = @floatFromInt(config.height) });
            host.?.harness.runtime.options.session_recorder = recorder;
            try host.?.harness.start(host.?.state.app());
            try host.?.frame(options.canvas_label);
        } else {
            const value = host orelse return error.NotStarted;
            if (replayed and request.op != .snapshot) return error.SessionAlreadyReplayed;
            switch (request.op) {
                .automation => try value.harness.runtime.dispatchAutomationCommand(value.state.app(), request.command),
                .text_action => try value.harness.runtime.dispatchAutomationWidgetAction(value.state.app(), .{
                    .view_label = request.view,
                    .id = try std.fmt.parseInt(u64, request.widget, 10),
                    .action = switch (request.text_action) {
                        inline else => |action| @field(@import("automation_commands.zig").AutomationWidgetActionKind, @tagName(action)),
                    },
                    .value = request.text,
                }),
                .input => {
                    for ([_]f32{ request.x, request.y, request.delta_x, request.delta_y }) |number| if (!std.math.isFinite(number)) return error.InvalidInput;
                    try value.harness.runtime.dispatchPlatformEvent(value.state.app(), .{ .gpu_surface_input = .{
                        .window_id = request.window,
                        .label = request.view,
                        .kind = switch (request.input) {
                            inline else => |kind| @field(sdk.platform.GpuSurfaceInputKind, @tagName(kind)),
                        },
                        .x = request.x,
                        .y = request.y,
                        .delta_x = request.delta_x,
                        .delta_y = request.delta_y,
                        .modifiers = .{ .shift = request.shift },
                        .timestamp_ns = value.frame_index * 16_000_000 + 1,
                    } });
                },
                .drop => try value.harness.runtime.dispatchPlatformEvent(value.state.app(), .{ .files_dropped = .{
                    .window_id = request.window,
                    .view_label = request.view,
                    .paths = request.paths,
                } }),
                .menu => try value.harness.runtime.dispatchPlatformEvent(value.state.app(), .{ .menu_command = .{ .name = request.command, .window_id = request.window } }),
                .window_close => {
                    const event = value.harness.null_platform.userCloseWindow(request.window) orelse return error.WindowNotFound;
                    try value.harness.runtime.dispatchPlatformEvent(value.state.app(), event);
                },
                .host_result => {
                    try value.state.effects.feedHostResult(try std.fmt.parseInt(u64, request.key, 10), request.ok, request.bytes);
                    try value.harness.runtime.dispatchPlatformEvent(value.state.app(), .wake);
                },
                .db_result => {
                    try value.state.effects.feedDbResult(try std.fmt.parseInt(u64, request.key, 10), request.db_kind, request.db_outcome, request.db_bytes);
                    try value.harness.runtime.dispatchPlatformEvent(value.state.app(), .wake);
                },
                .stream_line => {
                    try value.state.effects.feedLineWithMetadata(try std.fmt.parseInt(u64, request.key, 10), request.stream_bytes, request.truncated, request.dropped_before);
                    try value.harness.runtime.dispatchPlatformEvent(value.state.app(), .wake);
                },
                .spawn_exit => {
                    if (request.stream_bytes.len > 0) try value.state.effects.feedOutput(try std.fmt.parseInt(u64, request.key, 10), request.stream_bytes);
                    try value.state.effects.feedExitReason(try std.fmt.parseInt(u64, request.key, 10), request.exit_code, request.exit_reason);
                    try value.harness.runtime.dispatchPlatformEvent(value.state.app(), .wake);
                },
                .spawn_output => try value.state.effects.feedOutput(try std.fmt.parseInt(u64, request.key, 10), request.stream_bytes),
                .fetch_response => {
                    try value.state.effects.feedResponseOutcomeWithMetadata(try std.fmt.parseInt(u64, request.key, 10), request.fetch_outcome, request.http_status, request.stream_bytes, request.truncated, request.dropped_before);
                    try value.harness.runtime.dispatchPlatformEvent(value.state.app(), .wake);
                },
                .timer => {
                    const event = try value.state.effects.fakeTimerEvent(try std.fmt.parseInt(u64, request.key, 10), value.frame_index * 16_000_000);
                    try value.harness.runtime.dispatchPlatformEvent(value.state.app(), .{ .timer = event });
                },
                .replay => {
                    recorder.finish();
                    if (recorder.failed) return error.RecordingFailed;
                    const fingerprint = value.harness.runtime.sessionStateFingerprint();
                    const model_before = try std.json.Stringify.valueAlloc(gpa, Adapter.Host.model().*, .{ .emit_strings_as_arrays = true });
                    defer gpa.free(model_before);
                    value.destroy();
                    host = null;
                    host = try Host.create(config, options, core_options);
                    const report = try sdk.runtime.replaySession(&host.?.harness.runtime, host.?.state.app(), journal.bytes.items, .{
                        .verify = true,
                        .require_same_platform = false,
                    });
                    if (!report.ok() or fingerprint != host.?.harness.runtime.sessionStateFingerprint()) {
                        std.debug.print("native test replay: {d} mismatches, final {x} != {x}\n", .{ report.mismatch_count, fingerprint, host.?.harness.runtime.sessionStateFingerprint() });
                        for (report.mismatches[0..@min(report.mismatch_count, report.mismatches.len)]) |mismatch| {
                            std.debug.print("  {t} at event {d}, frame {d}: expected {x}, got {x}\n", .{ mismatch.kind, mismatch.event_ordinal, mismatch.frame_index, mismatch.expected, mismatch.actual });
                        }
                        return error.ReplayMismatch;
                    }
                    const model_after = try std.json.Stringify.valueAlloc(gpa, Adapter.Host.model().*, .{ .emit_strings_as_arrays = true });
                    defer gpa.free(model_after);
                    if (!std.mem.eql(u8, model_before, model_after)) return error.ReplayModelMismatch;
                    try response.writeAll("\"replay\":");
                    try std.json.Stringify.value(.{
                        .events = report.events_replayed,
                        .effects = report.effects_fed,
                        .checkpoints = report.checkpoints_verified,
                    }, .{}, &response);
                    try response.writeByte(',');
                    replayed = true;
                },
                .frame, .snapshot => {},
                .start, .close => unreachable,
            }
            if (request.op != .snapshot and request.op != .replay) try value.frame(options.canvas_label);
        }
        if (recorder.failed) return error.RecordingFailed;
        try response.writeAll("\"snapshot\":");
        try host.?.snapshot(recorder, &response);
        try response.writeAll("}\n");
        try output.interface.writeAll(response.buffered());
        try output.interface.flush();
    }
}
