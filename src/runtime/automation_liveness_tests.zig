//! Pin the automation LIVENESS contract: a command landing in the
//! dropbox while the app is completely idle — no animations, no input,
//! no timers armed, nothing invalidated — must still be consumed
//! promptly, because the arrival watcher asks the platform loop for a
//! frame. The scripted platform below is an honest model of that idle
//! state: after startup it BLOCKS with no frame source of its own, and
//! the only thing that can release it is a cross-thread frame request.
//! Before the watcher existed this test would sit until its failure
//! deadline, exactly like a real `widget-click` against a quiet app
//! sat until the CLI's timeout.

const support = @import("test_support.zig");
const std = support.std;
const automation = support.automation;
const platform = support.platform;
const App = support.App;
const Runtime = support.Runtime;
const Event = support.Event;

/// How long the idle loop is willing to wait for the watcher's frame
/// request before declaring the liveness contract broken. Generous so a
/// loaded machine never flakes; the observed wake is a few watcher polls
/// (~5 ms each) at most.
const wake_failure_budget_ns: u64 = 10 * std.time.ns_per_s;

/// The bound the test ASSERTS on. Still far above the expected wake
/// (a few watcher poll intervals) but far below the failure budget, so
/// a wake that only happens by accident-of-scheduling shows up loud.
const wake_asserted_budget_ns: u64 = 2 * std.time.ns_per_s;

const IdleLoop = struct {
    null_platform: *platform.NullPlatform,
    /// The dropbox directory (randomized per run: this test is compiled
    /// into more than one test binary, and the aggregate build step runs
    /// them in parallel — a fixed path would let two copies of this very
    /// test delete each other's slot mid-run).
    automation_dir: []const u8,
    /// Nanoseconds of idle blocking before the watcher's frame request
    /// arrived (sleep-accumulated, so an upper bound on the real wait).
    woke_after_ns: u64 = 0,

    /// A platform run loop with NO frame source of its own: startup
    /// events, one startup frame, then a bare wait on the cross-thread
    /// frame-request counter. The command is queued AFTER the startup
    /// frame — from the loop's own thread, like a driver writing while
    /// the app idles — so nothing but the watcher can ever drain it.
    fn run(context: *anyopaque, handler: platform.EventHandler, handler_context: *anyopaque) anyerror!void {
        const self: *IdleLoop = @ptrCast(@alignCast(context));
        try handler(handler_context, .app_start);
        try handler(handler_context, .{ .surface_resized = self.null_platform.surface_value });
        try handler(handler_context, .frame_requested);

        var path_buffer: [128]u8 = undefined;
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{
            .sub_path = try std.fmt.bufPrint(&path_buffer, "{s}/command-1.txt", .{self.automation_dir}),
            .data = "menu-command app.probe\n",
        });

        var waited_ns: u64 = 0;
        while (self.null_platform.takeFrameRequest() == null) {
            if (waited_ns > wake_failure_budget_ns) return error.AutomationWakeNeverArrived;
            try std.Io.sleep(std.testing.io, std.Io.Duration.fromNanoseconds(std.time.ns_per_ms), .awake);
            waited_ns += std.time.ns_per_ms;
        }
        self.woke_after_ns = waited_ns;

        try handler(handler_context, .frame_requested);
        try handler(handler_context, .app_shutdown);
    }
};

const ProbeApp = struct {
    probed: bool = false,

    fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
        _ = runtime;
        const self: *ProbeApp = @ptrCast(@alignCast(context));
        if (event_value == .command and std.mem.eql(u8, event_value.command.name, "app.probe")) {
            self.probed = true;
        }
    }

    fn app(self: *ProbeApp) App {
        return .{
            .context = self,
            .name = "liveness-probe",
            .source = platform.WebViewSource.html("<p>idle</p>"),
            .event_fn = event,
        };
    }
};

test "idle app consumes an automation command promptly via the arrival watcher" {
    // Pid-suffixed: this test is compiled into more than one test binary
    // and the aggregate build step runs them in parallel; parallel copies
    // must not share a dropbox.
    var dir_buffer: [64]u8 = undefined;
    const automation_dir = try automation.watcher.testDirectory(&dir_buffer, ".zig-cache/test-automation-liveness");
    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(std.testing.io, automation_dir) catch {};
    try cwd.createDirPath(std.testing.io, automation_dir);
    defer cwd.deleteTree(std.testing.io, automation_dir) catch {};

    // Heap-hosted: NullPlatform and Runtime are both multi-megabyte.
    const null_platform = try std.heap.page_allocator.create(platform.NullPlatform);
    defer std.heap.page_allocator.destroy(null_platform);
    null_platform.* = platform.NullPlatform.init(.{});
    var idle_loop: IdleLoop = .{ .null_platform = null_platform, .automation_dir = automation_dir };

    // Keep the null platform's services (they carry their own context)
    // but replace the run loop with the idle one above.
    var platform_value = null_platform.platform();
    platform_value.run_fn = IdleLoop.run;
    platform_value.context = &idle_loop;

    const runtime = try std.heap.page_allocator.create(Runtime);
    defer std.heap.page_allocator.destroy(runtime);
    Runtime.initAt(runtime, .{
        .platform = platform_value,
        .automation = automation.Server.init(std.testing.io, automation_dir, "Liveness"),
    });

    var app_state: ProbeApp = .{};
    try runtime.run(app_state.app());

    // The command was dispatched through the real path (menu_command ->
    // command event), and the wake arrived promptly — not by luck at the
    // end of some long timeout.
    try std.testing.expect(app_state.probed);
    try std.testing.expect(idle_loop.woke_after_ns < wake_asserted_budget_ns);

    // The drain deleted the queue entry — that deletion IS the ack the
    // driver's await-consumption poll (the CLI's `delivered` report)
    // watches for.
    var path_buffer: [128]u8 = undefined;
    try std.testing.expectError(
        error.FileNotFound,
        cwd.openFile(std.testing.io, try std.fmt.bufPrint(&path_buffer, "{s}/command-1.txt", .{automation_dir}), .{}),
    );
}
