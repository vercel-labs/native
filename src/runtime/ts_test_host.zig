//! Private stdio protocol for @native-sdk/core/testing. Each process owns one
//! compiled core; all interaction, layout, effects and replay use the runtime.
const std = @import("std");
const sdk = @import("../root.zig");

const protocol_version = 1;
const max_request_bytes = 64 * 1024;
const max_response_bytes = 8 * 1024 * 1024;
const max_journal_bytes = 8 * 1024 * 1024;

const Request = struct {
    op: enum { start, snapshot, automation, menu, frame, host_result, timer, replay, close },
    width: u32 = 640,
    height: u32 = 480,
    wall_ms: i64 = 0,
    command: []const u8 = "",
    key: []const u8 = "0",
    ok: bool = true,
    bytes: []const u8 = "",
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
    const gpa = std.heap.page_allocator;
    const Host = struct {
        harness: *sdk.TestHarness(),
        state: *Adapter.App,
        clock: sdk.TestClock = .{},
        size: sdk.geometry.SizeF,
        frame_index: u64 = 0,

        fn create(config: Request, app_options: Adapter.Options) !*@This() {
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
            self.state = try Adapter.create(gpa, .{}, app_options);
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
            try json.objectField("widgets");
            try json.beginArray();
            for (snapshot_value.widgets) |widget| {
                try json.write(.{
                    .id = try std.fmt.bufPrint(&id_buffer, "{d}", .{widget.id}),
                    .view = widget.view_label,
                    .window = widget.window_id,
                    .role = widget.role,
                    .name = widget.name,
                    .text = widget.text_value,
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
            try json.endObject();
            try json.endObject();
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
            host = try Host.create(config, options);
            recorder.begin(.{ .platform_name = "test", .app_name = options.name, .window_width = @floatFromInt(config.width), .window_height = @floatFromInt(config.height) });
            host.?.harness.runtime.options.session_recorder = recorder;
            try host.?.harness.start(host.?.state.app());
            try host.?.frame(options.canvas_label);
        } else {
            const value = host orelse return error.NotStarted;
            if (replayed and request.op != .snapshot) return error.SessionAlreadyReplayed;
            switch (request.op) {
                .automation => try value.harness.runtime.dispatchAutomationCommand(value.state.app(), request.command),
                .menu => try value.harness.runtime.dispatchPlatformEvent(value.state.app(), .{ .menu_command = .{ .name = request.command, .window_id = 1 } }),
                .host_result => {
                    try value.state.effects.feedHostResult(try std.fmt.parseInt(u64, request.key, 10), request.ok, request.bytes);
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
                    host = try Host.create(config, options);
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
