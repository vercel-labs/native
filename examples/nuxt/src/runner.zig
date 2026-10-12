const std = @import("std");
const build_options = @import("build_options");
const zero_native = @import("zero-native");

pub const StdoutTraceSink = struct {
    pub fn sink(self: *StdoutTraceSink) zero_native.trace.Sink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, record: zero_native.trace.Record) zero_native.trace.WriteError!void {
        _ = context;
        if (!shouldTrace(record)) return;
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        zero_native.trace.formatText(record, &writer) catch return error.OutOfSpace;
        std.debug.print("{s}\n", .{writer.buffered()});
    }
};

pub const RunOptions = struct {
    app_name: []const u8,
    window_title: []const u8 = "",
    bundle_id: []const u8,
    icon_path: []const u8 = "assets/icon.icns",
    bridge: ?zero_native.BridgeDispatcher = null,
    builtin_bridge: zero_native.BridgePolicy = .{},
    security: zero_native.SecurityPolicy = .{},

    fn appInfo(self: RunOptions) zero_native.AppInfo {
        return .{
            .app_name = self.app_name,
            .window_title = self.window_title,
            .bundle_id = self.bundle_id,
            .icon_path = self.icon_path,
        };
    }
};

pub fn runWithOptions(app: zero_native.App, options: RunOptions, init: std.process.Init) !void {
    if (build_options.debug_overlay) {
        std.debug.print("debug-overlay=true backend={s} web-engine={s} trace={s}\n", .{ build_options.platform, build_options.web_engine, build_options.trace });
    }
    if (comptime std.mem.eql(u8, build_options.platform, "macos")) {
        try runMacos(app, options, init);
    } else if (comptime std.mem.eql(u8, build_options.platform, "linux")) {
        try runLinux(app, options, init);
    } else if (comptime std.mem.eql(u8, build_options.platform, "windows")) {
        try runWindows(app, options, init);
    } else {
        try runNull(app, options, init);
    }
}

fn runNull(app: zero_native.App, options: RunOptions, init: std.process.Init) !void {
    var buffers: StateBuffers = undefined;
    var app_info = options.appInfo();
    const store = prepareStateStore(init.io, init.environ_map, &app_info, &buffers);
    var null_platform = zero_native.NullPlatform.initWithOptions(.{}, webEngine(), app_info);
    var trace_sink = StdoutTraceSink{};
    var log_buffers: zero_native.debug.LogPathBuffers = .{};
    const log_setup = zero_native.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    if (log_setup) |setup| zero_native.debug.installPanicCapture(init.io, setup.paths);
    var file_trace_sink: zero_native.debug.FileTraceSink = undefined;
    var fanout_sinks: [2]zero_native.trace.Sink = undefined;
    var fanout_sink: zero_native.debug.FanoutTraceSink = undefined;
    var runtime_trace_sink = trace_sink.sink();
    if (log_setup) |setup| {
        file_trace_sink = zero_native.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
        fanout_sinks = .{ trace_sink.sink(), file_trace_sink.sink() };
        fanout_sink = .{ .sinks = &fanout_sinks };
        runtime_trace_sink = fanout_sink.sink();
    }
    var runtime = zero_native.Runtime.init(.{
        .platform = null_platform.platform(),
        .trace_sink = runtime_trace_sink,
        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
        .bridge = options.bridge,
        .builtin_bridge = options.builtin_bridge,
        .security = options.security,
        .automation = if (build_options.automation) zero_native.automation.Server.init(init.io, ".zig-cache/zero-native-automation", app_info.resolvedWindowTitle()) else null,
        .window_state_store = store,
    });

    try runtime.run(app);
}

fn runMacos(app: zero_native.App, options: RunOptions, init: std.process.Init) !void {
    var buffers: StateBuffers = undefined;
    var app_info = options.appInfo();
    const store = prepareStateStore(init.io, init.environ_map, &app_info, &buffers);
    var mac_platform = try zero_native.platform.macos.MacPlatform.initWithOptions(zero_native.geometry.SizeF.init(720, 480), webEngine(), app_info);
    defer mac_platform.deinit();
    var trace_sink = StdoutTraceSink{};
    var log_buffers: zero_native.debug.LogPathBuffers = .{};
    const log_setup = zero_native.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    if (log_setup) |setup| zero_native.debug.installPanicCapture(init.io, setup.paths);
    var file_trace_sink: zero_native.debug.FileTraceSink = undefined;
    var fanout_sinks: [2]zero_native.trace.Sink = undefined;
    var fanout_sink: zero_native.debug.FanoutTraceSink = undefined;
    var runtime_trace_sink = trace_sink.sink();
    if (log_setup) |setup| {
        file_trace_sink = zero_native.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
        fanout_sinks = .{ trace_sink.sink(), file_trace_sink.sink() };
        fanout_sink = .{ .sinks = &fanout_sinks };
        runtime_trace_sink = fanout_sink.sink();
    }
    var runtime = zero_native.Runtime.init(.{
        .platform = mac_platform.platform(),
        .trace_sink = runtime_trace_sink,
        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
        .bridge = options.bridge,
        .builtin_bridge = options.builtin_bridge,
        .security = options.security,
        .automation = if (build_options.automation) zero_native.automation.Server.init(init.io, ".zig-cache/zero-native-automation", app_info.resolvedWindowTitle()) else null,
        .window_state_store = store,
    });

    try runtime.run(app);
}

fn runLinux(app: zero_native.App, options: RunOptions, init: std.process.Init) !void {
    var buffers: StateBuffers = undefined;
    var app_info = options.appInfo();
    const store = prepareStateStore(init.io, init.environ_map, &app_info, &buffers);
    var linux_platform = try zero_native.platform.linux.LinuxPlatform.initWithOptions(zero_native.geometry.SizeF.init(720, 480), webEngine(), app_info);
    defer linux_platform.deinit();
    var trace_sink = StdoutTraceSink{};
    var log_buffers: zero_native.debug.LogPathBuffers = .{};
    const log_setup = zero_native.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    if (log_setup) |setup| zero_native.debug.installPanicCapture(init.io, setup.paths);
    var file_trace_sink: zero_native.debug.FileTraceSink = undefined;
    var fanout_sinks: [2]zero_native.trace.Sink = undefined;
    var fanout_sink: zero_native.debug.FanoutTraceSink = undefined;
    var runtime_trace_sink = trace_sink.sink();
    if (log_setup) |setup| {
        file_trace_sink = zero_native.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
        fanout_sinks = .{ trace_sink.sink(), file_trace_sink.sink() };
        fanout_sink = .{ .sinks = &fanout_sinks };
        runtime_trace_sink = fanout_sink.sink();
    }
    var runtime = zero_native.Runtime.init(.{
        .platform = linux_platform.platform(),
        .trace_sink = runtime_trace_sink,
        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
        .bridge = options.bridge,
        .builtin_bridge = options.builtin_bridge,
        .security = options.security,
        .automation = if (build_options.automation) zero_native.automation.Server.init(init.io, ".zig-cache/zero-native-automation", app_info.resolvedWindowTitle()) else null,
        .window_state_store = store,
    });

    try runtime.run(app);
}

fn runWindows(app: zero_native.App, options: RunOptions, init: std.process.Init) !void {
    var buffers: StateBuffers = undefined;
    var app_info = options.appInfo();
    const store = prepareStateStore(init.io, init.environ_map, &app_info, &buffers);
    var windows_platform = try zero_native.platform.windows.WindowsPlatform.initWithOptions(zero_native.geometry.SizeF.init(720, 480), webEngine(), app_info);
    defer windows_platform.deinit();
    var trace_sink = StdoutTraceSink{};
    var log_buffers: zero_native.debug.LogPathBuffers = .{};
    const log_setup = zero_native.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    if (log_setup) |setup| zero_native.debug.installPanicCapture(init.io, setup.paths);
    var file_trace_sink: zero_native.debug.FileTraceSink = undefined;
    var fanout_sinks: [2]zero_native.trace.Sink = undefined;
    var fanout_sink: zero_native.debug.FanoutTraceSink = undefined;
    var runtime_trace_sink = trace_sink.sink();
    if (log_setup) |setup| {
        file_trace_sink = zero_native.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
        fanout_sinks = .{ trace_sink.sink(), file_trace_sink.sink() };
        fanout_sink = .{ .sinks = &fanout_sinks };
        runtime_trace_sink = fanout_sink.sink();
    }
    var runtime = zero_native.Runtime.init(.{
        .platform = windows_platform.platform(),
        .trace_sink = runtime_trace_sink,
        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
        .bridge = options.bridge,
        .builtin_bridge = options.builtin_bridge,
        .security = options.security,
        .automation = if (build_options.automation) zero_native.automation.Server.init(init.io, ".zig-cache/zero-native-automation", app_info.resolvedWindowTitle()) else null,
        .window_state_store = store,
    });

    try runtime.run(app);
}

fn shouldTrace(record: zero_native.trace.Record) bool {
    if (comptime std.mem.eql(u8, build_options.trace, "off")) return false;
    if (comptime std.mem.eql(u8, build_options.trace, "all")) return true;
    if (comptime std.mem.eql(u8, build_options.trace, "events")) return true;
    return std.mem.indexOf(u8, record.name, build_options.trace) != null;
}

fn webEngine() zero_native.WebEngine {
    if (comptime std.mem.eql(u8, build_options.web_engine, "chromium")) return .chromium;
    return .system;
}

const StateBuffers = struct {
    state_dir: [1024]u8 = undefined,
    file_path: [1200]u8 = undefined,
    read: [8192]u8 = undefined,
    restored_windows: [zero_native.platform.max_windows]zero_native.WindowOptions = undefined,
};

fn prepareStateStore(io: std.Io, env_map: *std.process.Environ.Map, app_info: *zero_native.AppInfo, buffers: *StateBuffers) ?zero_native.window_state.Store {
    const paths = zero_native.window_state.defaultPaths(&buffers.state_dir, &buffers.file_path, app_info.bundle_id, zero_native.debug.envFromMap(env_map)) catch return null;
    const store = zero_native.window_state.Store.init(io, paths.state_dir, paths.file_path);
    if (app_info.main_window.restore_state) {
        if (store.loadWindow(app_info.main_window.label, &buffers.read) catch null) |saved| {
            app_info.main_window.default_frame = saved.frame;
        }
    }
    return store;
}
