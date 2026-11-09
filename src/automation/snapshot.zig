const std = @import("std");
const geometry = @import("geometry");
const app_manifest = @import("app_manifest");
const platform = @import("../platform/root.zig");
const protocol = @import("protocol.zig");

pub const max_windows: usize = platform.max_windows;
pub const max_views: usize = platform.max_windows + platform.max_views + platform.max_webviews;
// Mirrors `canvas_limits.max_canvas_widget_nodes_per_view` (this module
// cannot import the runtime); a lockstep test in
// canvas_widget_layout_tests.zig fails if they drift, so snapshots never
// silently truncate widget enumeration below the node budget.
pub const max_widgets_per_view: usize = 1024;
pub const max_widgets: usize = platform.max_views * max_widgets_per_view;

pub const Window = struct {
    id: platform.WindowId = 1,
    title: []const u8,
    bounds: geometry.RectF,
    focused: bool = true,
};

pub const Diagnostics = struct {
    frame_index: u64 = 0,
    command_count: usize = 0,
    runtime_uptime_ns: u64 = 0,
    /// Pid of the publishing app. Dropbox files persist across builds
    /// and runs, so the CLI checks this against the live process table
    /// before trusting a snapshot: a dead (or absent) publisher means
    /// the file is a leftover — served loudly as "stale", never as
    /// current state. 0 means the platform exposes no
    /// pid; the CLI treats that as unverifiable-and-stale too.
    publisher_pid: u32 = 0,
    /// Lifetime count of handler/update errors dispatch caught and
    /// degraded instead of terminating the app; the most recent ones
    /// ride in `Input.errors`.
    dispatch_error_count: u64 = 0,
    /// Trace records dropped because a sink was full or failing —
    /// logging failures never take dispatch down.
    dropped_trace_records: u64 = 0,
    /// Whether the app armed a markup hot-reload watch this run.
    /// Published as `markup_watch=armed|off` so a dev loop can prove —
    /// without bisecting — that editing a .native source will (or will
    /// not) reload the running app.
    markup_watch_armed: bool = false,
};

/// One stage of the runtime's per-stage frame profile (`profile on`):
/// nearest-rank percentiles over the rolling sample window plus the
/// lifetime sample count. `name` references the stage enum's static tag
/// name, so entries are plain values.
pub const FrameProfileStage = struct {
    name: []const u8 = "",
    p50_us: u64 = 0,
    p90_us: u64 = 0,
    max_us: u64 = 0,
    /// Lifetime samples recorded for this stage since enable.
    count: u64 = 0,
};

/// The frame profile as one snapshot line's worth of data: present only
/// while profiling is on (the runtime stamps stage slices into
/// runtime-owned storage; this only references it).
pub const FrameProfile = struct {
    stages: []const FrameProfileStage = &.{},
};

/// One degraded dispatch failure: a handler or update error the runtime
/// caught, recorded, and continued past (never a process exit). `event`
/// and `error_name` reference static strings (event names and
/// `@errorName` data), so records are plain values. `detail` is a small
/// owned copy of failure context — for automation commands, the command
/// arguments, so the snapshot's error line names the widget a failed
/// verb targeted.
pub const DispatchError = struct {
    timestamp_ns: u64 = 0,
    event_storage: [max_dispatch_error_event_bytes]u8 = undefined,
    event_len: u8 = 0,
    error_name: []const u8 = "",
    detail_storage: [max_dispatch_error_detail_bytes]u8 = undefined,
    detail_len: u8 = 0,

    /// The event name is INLINE storage like `detail`, never a borrowed
    /// slice: records are copied by value into a ring that outlives any
    /// caller's buffer, so a name passed from stack or reusable storage
    /// must be owned at record time.
    pub fn event(self: *const DispatchError) []const u8 {
        return self.event_storage[0..self.event_len];
    }

    pub fn setEvent(self: *DispatchError, text: []const u8) void {
        const len = @min(text.len, self.event_storage.len);
        @memcpy(self.event_storage[0..len], text[0..len]);
        self.event_len = @intCast(len);
    }

    pub fn detail(self: *const DispatchError) []const u8 {
        return self.detail_storage[0..self.detail_len];
    }

    pub fn setDetail(self: *DispatchError, text: []const u8) void {
        const len = @min(text.len, self.detail_storage.len);
        @memcpy(self.detail_storage[0..len], text[0..len]);
        self.detail_len = @intCast(len);
    }
};

/// Event-name bytes kept per degraded dispatch error (a truncated copy,
/// owned by the record — the ring outlives every caller's buffer).
pub const max_dispatch_error_event_bytes: usize = 64;

/// Detail context kept per degraded dispatch error (a truncated copy of
/// the failing automation command's arguments).
pub const max_dispatch_error_detail_bytes: usize = 48;

pub const WidgetActions = struct {
    focus: bool = false,
    press: bool = false,
    toggle: bool = false,
    increment: bool = false,
    decrement: bool = false,
    set_text: bool = false,
    set_selection: bool = false,
    select: bool = false,
    drag: bool = false,
    drop_files: bool = false,
    dismiss: bool = false,

    pub fn isEmpty(self: WidgetActions) bool {
        return !self.focus and
            !self.press and
            !self.toggle and
            !self.increment and
            !self.decrement and
            !self.set_text and
            !self.set_selection and
            !self.select and
            !self.drag and
            !self.drop_files and
            !self.dismiss;
    }
};

pub const TextRange = struct {
    start: usize = 0,
    end: usize = 0,
};

pub const WidgetScroll = struct {
    present: bool = false,
    offset: f32 = 0,
    viewport_extent: f32 = 0,
    content_extent: f32 = 0,
};

pub const WidgetVirtualRange = struct {
    present: bool = false,
    start_index: u32 = 0,
    end_index: u32 = 0,
    first_visible_index: u32 = 0,
    last_visible_index: u32 = 0,
    rendered_count: u32 = 0,
};

pub const WidgetList = struct {
    present: bool = false,
    item_index: u32 = 0,
    item_count: u32 = 0,
};

/// One declared context-menu item on a widget, as the snapshot lists it.
/// The list position IS the index `widget-context-menu` invokes
/// (separators keep their slots).
pub const WidgetContextMenuItem = struct {
    label: []const u8 = "",
    enabled: bool = true,
    separator: bool = false,
};

pub const Widget = struct {
    window_id: platform.WindowId = 1,
    view_label: []const u8 = "",
    id: u64 = 0,
    role: []const u8 = "",
    name: []const u8 = "",
    parent_id: ?u64 = null,
    value: ?f32 = null,
    text_value: []const u8 = "",
    placeholder: []const u8 = "",
    grid_row_index: ?usize = null,
    grid_column_index: ?usize = null,
    grid_row_count: ?usize = null,
    grid_column_count: ?usize = null,
    list: WidgetList = .{},
    scroll: WidgetScroll = .{},
    virtual_range: WidgetVirtualRange = .{},
    bounds: geometry.RectF = .{},
    focused: bool = false,
    enabled: bool = true,
    hovered: bool = false,
    pressed: bool = false,
    selected: bool = false,
    expanded: ?bool = null,
    required: bool = false,
    read_only: bool = false,
    invalid: bool = false,
    actions: WidgetActions = .{},
    text_selection: ?TextRange = null,
    text_composition: ?TextRange = null,
    /// The widget's declared context-menu items in declared order —
    /// what a right-click presents (natively, or through the anchored
    /// fallback surface) and what `widget-context-menu` invokes by
    /// index.
    context_menu: []const WidgetContextMenuItem = &.{},
};

/// One status-item dropdown row as the runtime last applied it. Slices
/// reference the runtime's bounded tray storage (labels/commands are
/// copied there on every create/update), so snapshot inputs are plain
/// values.
pub const TrayItem = struct {
    id: platform.TrayItemId = 0,
    label: []const u8 = "",
    command: []const u8 = "",
    separator: bool = false,
    enabled: bool = true,
    detail: []const u8 = "",
    role: platform.TrayItemRole = .command,
    key: []const u8 = "",
    modifiers: platform.ShortcutModifiers = .{},
    segmented: ?platform.TraySegmentedRow = null,
    metric: ?platform.TrayMetricRow = null,
    chart: ?platform.TrayChartRow = null,
};

/// The live status item (tray): current button title + dropdown items.
/// The macOS menu bar is outside every window capture, so this is the
/// only automation-visible evidence a model-driven tray exists.
pub const Tray = struct {
    id: platform.StatusItemId = platform.primary_status_item_id,
    visible: bool = true,
    title: []const u8 = "",
    items: []const TrayItem = &.{},
};

/// Live audio playback state (the effects channel's single player), as
/// the runtime last mirrored it. Speakers are outside every window
/// capture, so `state=` and the advancing `position_ms` are the
/// automation-visible evidence music is actually playing. `buffering`
/// (a stalled stream — un-paused yet silent) prints as its own state,
/// and `source` names where the bytes come from (local file, verified
/// cache entry, network stream), so the resolution order is provable
/// from the snapshot alone.
pub const Audio = struct {
    key: u64 = 0,
    playing: bool = false,
    buffering: bool = false,
    source: []const u8 = "local",
    position_ms: u64 = 0,
    duration_ms: u64 = 0,
    /// Real spectrum analysis evidence: how many `.spectrum` band
    /// reports this playback has delivered (moving while playing,
    /// holding on pause — zero forever on a host that cannot analyze)
    /// and the latest band bytes, printed as hex so magnitude variation
    /// is provable from the snapshot alone.
    spectrum_events: u64 = 0,
    spectrum_bands: []const u8 = &.{},
};

/// Live video playback state (the effects channel's single player), as
/// the runtime last mirrored it — the audio snapshot's twin. The
/// advancing `position_ms` and the `.loaded` dimensions are the
/// automation-visible evidence a video is actually decoding; `surface`
/// names the media-surface texture channel its frames feed. Like the
/// media-surface texture itself, this line prints in the FULL snapshot
/// only, never the a11y text session fingerprints hash — playback
/// transport is journaled effect truth, not tree state, so a replay
/// with no producer stays fingerprint-identical by construction.
pub const Video = struct {
    key: u64 = 0,
    surface: u64 = 0,
    playing: bool = false,
    buffering: bool = false,
    looping: bool = false,
    muted: bool = false,
    source: []const u8 = "local",
    position_ms: u64 = 0,
    duration_ms: u64 = 0,
    width: u64 = 0,
    height: u64 = 0,
};

pub const Input = struct {
    /// Compiled byte serializer; borrowed storage and writer I/O stay native.
    serialization_policy: ?*const fn ([]const u8, []u8) usize = null,
    windows: []const Window,
    views: []const platform.ViewInfo = &.{},
    widgets: []const Widget = &.{},
    /// Static command and app-menu catalogs configured on the runtime.
    /// These receipts let automation prove generated/ejected runners
    /// loaded their manifest declarations before injecting command-source
    /// events that cannot drive an OS menu tracking loop directly.
    commands: []const app_manifest.Command = &.{},
    menus: []const platform.Menu = &.{},
    diagnostics: Diagnostics = .{},
    /// Per-stage frame timing, non-null while `profile on` is active —
    /// printed as the `frame_profile` line right after the header.
    frame_profile: ?FrameProfile = null,
    /// Per-view widget budgets (`canvas_limits.max_canvas_widget_*`),
    /// stamped by the runtime so gpu_surface view lines can report
    /// `widget_nodes=current/budget` headroom.
    widget_node_budget: usize = 0,
    widget_semantics_budget: usize = 0,
    widget_context_menu_item_budget: usize = 0,
    /// Per-frame text-layout budgets (`canvas_limits.max_canvas_text_
    /// layouts_per_view` / `..._lines_per_view`), stamped by the runtime
    /// so gpu_surface view lines report `text_layout_plans=current/budget`
    /// headroom.
    text_layout_plan_budget: usize = 0,
    text_layout_line_budget: usize = 0,
    /// Every live status item, keyed by its stable identifier.
    trays: []const Tray = &.{},
    /// Live audio playback, when the app started any (null once stopped
    /// or failed — an idle player is honest, not zeroed-out noise).
    audio: ?Audio = null,
    /// Live video playback, same contract as `audio`.
    video: ?Video = null,
    /// The most recent degraded dispatch errors, oldest first (bounded
    /// ring; `diagnostics.dispatch_error_count` is the lifetime total).
    errors: []const DispatchError = &.{},
    source: ?platform.WebViewSource = null,
};

pub fn writeText(input: Input, writer: anytype) !void {
    if (input.serialization_policy == null) return @import("snapshot_reference.zig").writeText(input, writer);
    try @import("snapshot_serialization.zig").write(input, writer, .full);
}

pub fn writeA11yText(input: Input, writer: anytype) !void {
    if (input.serialization_policy == null) return @import("snapshot_reference.zig").writeA11yText(input, writer);
    try @import("snapshot_serialization.zig").write(input, writer, .accessibility);
}

pub fn writeWindowsText(input: Input, writer: anytype) !void {
    if (input.serialization_policy == null) return @import("snapshot_reference.zig").writeWindowsText(input, writer);
    try @import("snapshot_serialization.zig").write(input, writer, .windows);
}

test "snapshot emits window and source" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const windows = [_]Window{.{ .title = "Test", .bounds = geometry.RectF.init(0, 0, 100, 100) }};
    const views = [_]platform.ViewInfo{.{ .label = "main", .kind = .webview, .frame = geometry.RectF.init(0, 0, 100, 100), .role = "webview", .text = "Main content", .focused = true }};
    try writeText(.{
        .windows = &windows,
        .views = &views,
        .diagnostics = .{ .runtime_uptime_ns = 42, .publisher_pid = 4242 },
        .source = platform.WebViewSource.html("<h1>Hello</h1>"),
    }, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "ready=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "runtime_uptime_ns=42") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "publisher_pid=4242") != null);
    var protocol_field_buffer: [32]u8 = undefined;
    const protocol_field = try std.fmt.bufPrint(&protocol_field_buffer, "protocol=0x{x:0>16} ", .{protocol.fingerprint});
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), protocol_field) != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "@w1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "view @w1/main kind=webview") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "accessibility_label=\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "text=\"Main content\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "focused=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "source kind=html") != null);
}

test "snapshot emits the frame_profile line only while profiling" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const windows = [_]Window{.{ .title = "Test", .bounds = geometry.RectF.init(0, 0, 100, 100) }};
    const stages = [_]FrameProfileStage{
        .{ .name = "rebuild", .p50_us = 120, .p90_us = 340, .max_us = 900, .count = 12 },
        .{ .name = "encode", .p50_us = 8, .p90_us = 15, .max_us = 22, .count = 60 },
    };
    try writeText(.{
        .windows = &windows,
        .frame_profile = .{ .stages = &stages },
    }, &writer);
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "\nframe_profile rebuild_p50_us=120 rebuild_p90_us=340 rebuild_max_us=900 rebuild_n=12 encode_p50_us=8 encode_p90_us=15 encode_max_us=22 encode_n=60\n") != null);

    // Profiling off -> no frame_profile line.
    var off_buffer: [512]u8 = undefined;
    var off_writer = std.Io.Writer.fixed(&off_buffer);
    try writeText(.{ .windows = &windows }, &off_writer);
    try std.testing.expect(std.mem.indexOf(u8, off_writer.buffered(), "frame_profile") == null);
}

test "snapshot emits tray title and typed dropdown items" {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const windows = [_]Window{.{ .title = "Test", .bounds = geometry.RectF.init(0, 0, 100, 100) }};
    const segments = [_]platform.TraySegmentOption{
        .{ .id = 20, .label = "Day", .command = "range.day", .selected = true },
        .{ .id = 21, .label = "Week", .command = "range.week", .enabled = false },
    };
    const chart_values = [_]f32{ 0.25, 0.5, 1 };
    const items = [_]TrayItem{
        .{ .id = 1, .label = "Refresh", .command = "app.refresh" },
        .{ .role = .hero, .metric = .{ .primary_text = "2,494 requests", .secondary_text = "Today · production", .accessibility_label = "2,494 requests today in production" } },
        .{ .separator = true },
        .{ .id = 10, .label = "Fix crash on resize", .command = "issue.select.0", .enabled = false, .detail = "warning ⚠", .role = .agent, .key = "q", .modifiers = .{ .command = true } },
        .{ .role = .segmented, .segmented = .{ .options = &segments } },
        .{ .role = .chart, .chart = .{ .values = &chart_values, .min_value = 0, .max_value = 1, .leading_caption = "CPU", .trailing_summary = "50%", .accessibility_label = "CPU history, 50 percent" } },
    };
    try writeText(.{
        .windows = &windows,
        .trays = &.{.{ .id = 7, .title = "ZN 3", .visible = false, .items = &items }},
    }, &writer);
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "\ntray #7 title=\"ZN 3\" visible=false items=6\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  tray-item #1 label=\"Refresh\" command=\"app.refresh\" enabled=true detail=\"\" role=command key=\"\" modifiers=(primary=false,command=false,control=false,option=false,shift=false)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  tray-item separator\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  tray-item #0 role=metric primary=\"2,494 requests\" secondary=\"Today · production\" accessibility=\"2,494 requests today in production\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  tray-item #10 label=\"Fix crash on resize\" command=\"issue.select.0\" enabled=false detail=\"warning ⚠\" role=agent key=\"q\" modifiers=(primary=false,command=true,control=false,option=false,shift=false)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  tray-item #0 role=segmented options=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "    tray-segment #20 label=\"Day\" command=\"range.day\" selected=true enabled=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  tray-item #0 role=chart caption=\"CPU\" summary=\"50%\" accessibility=\"CPU history, 50 percent\" domain=(0,1) values=0.25,0.5,1\n") != null);

    // No tray -> no tray lines.
    var empty_buffer: [512]u8 = undefined;
    var empty_writer = std.Io.Writer.fixed(&empty_buffer);
    try writeText(.{ .windows = &windows }, &empty_writer);
    try std.testing.expect(std.mem.indexOf(u8, empty_writer.buffered(), "tray") == null);
}

test "snapshot escapes hostile typed tray row text" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const windows = [_]Window{.{ .title = "Test", .bounds = geometry.RectF.init(0, 0, 100, 100) }};
    const segments = [_]platform.TraySegmentOption{.{
        .id = 20,
        .label = "Day\"\nnext\\",
        .command = "range.\"day\n",
    }};
    const chart_values = [_]f32{0.5};
    const items = [_]TrayItem{
        .{ .role = .segmented, .segmented = .{ .options = &segments } },
        .{ .role = .hero, .metric = .{
            .primary_text = "2\"\nrequests",
            .secondary_text = "Today\r\\production",
            .accessibility_label = "metric\t\x01",
        } },
        .{ .role = .chart, .chart = .{
            .values = &chart_values,
            .leading_caption = "CPU\"\n",
            .trailing_summary = "50%\\\r",
            .accessibility_label = "chart\t\x7f",
        } },
    };
    try writeText(.{
        .windows = &windows,
        .trays = &.{.{ .items = &items }},
    }, &writer);
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "tray-segment #20 label=\"Day\\\"\\nnext\\\\\" command=\"range.\\\"day\\n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "role=metric primary=\"2\\\"\\nrequests\" secondary=\"Today\\r\\\\production\" accessibility=\"metric\\t\\u0001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "role=chart caption=\"CPU\\\"\\n\" summary=\"50%\\\\\\r\" accessibility=\"chart\\t\\u007f\"") != null);
    // Header, window, tray, segmented wrapper, segment, metric, and chart:
    // hostile values inject no additional line-oriented records.
    try std.testing.expectEqual(@as(usize, 7), std.mem.count(u8, text, "\n"));
}

test "snapshot emits configured command and app-menu catalogs" {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const windows = [_]Window{.{ .title = "Test", .bounds = geometry.RectF.init(0, 0, 100, 100) }};
    const commands = [_]app_manifest.Command{
        .{ .id = "app.refresh", .title = "Refresh" },
    };
    const items = [_]platform.MenuItem{
        .{ .label = "Refresh", .command = "app.refresh", .key = "r", .modifiers = .{ .primary = true } },
        .{ .separator = true },
    };
    const menus = [_]platform.Menu{
        .{ .title = "View", .items = &items },
    };
    try writeText(.{
        .windows = &windows,
        .commands = &commands,
        .menus = &menus,
    }, &writer);
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "\ncommand id=\"app.refresh\" title=\"Refresh\" enabled=true checked=false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "app-menu title=\"View\" items=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  app-menu-item label=\"Refresh\" command=\"app.refresh\" enabled=true checked=false key=\"r\" modifiers=(primary=true,command=false,control=false,option=false,shift=false)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  app-menu-item separator\n") != null);
}

test "snapshot escapes hostile command and app-menu catalog text" {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const windows = [_]Window{.{ .title = "Test", .bounds = geometry.RectF.init(0, 0, 100, 100) }};
    const commands = [_]app_manifest.Command{
        .{ .id = "app.\"quoted", .title = "Line 1\nLine 2\\tail\t\x01\x7f Café" },
    };
    const items = [_]platform.MenuItem{
        .{ .label = "Open \"now\"\rnext\\", .command = "app.\"run", .key = "r\t" },
    };
    const menus = [_]platform.Menu{
        .{ .title = "Tools\"\nInjected", .items = &items },
    };
    try writeText(.{
        .windows = &windows,
        .commands = &commands,
        .menus = &menus,
    }, &writer);
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "\ncommand id=\"app.\\\"quoted\" title=\"Line 1\\nLine 2\\\\tail\\t\\u0001\\u007f Café\" enabled=true checked=false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "app-menu title=\"Tools\\\"\\nInjected\" items=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  app-menu-item label=\"Open \\\"now\\\"\\rnext\\\\\" command=\"app.\\\"run\" enabled=true checked=false key=\"r\\t\" modifiers=(primary=false,command=false,control=false,option=false,shift=false)\n") != null);
    // Header, window, command, menu, and item: hostile values inject no
    // additional records into the line-oriented snapshot.
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, text, "\n"));
}

test "accessibility snapshot uses visible view text as name" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const windows = [_]Window{.{ .title = "Test", .bounds = geometry.RectF.init(0, 0, 100, 100) }};
    const views = [_]platform.ViewInfo{.{ .label = "status", .kind = .statusbar, .frame = geometry.RectF.init(0, 80, 100, 20), .role = "status", .text = "Ready" }};
    try writeA11yText(.{
        .windows = &windows,
        .views = &views,
    }, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "@w1/status role=status name=\"Ready\"") != null);
}

test "accessibility snapshot prefers explicit accessibility label" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const windows = [_]Window{.{ .title = "Test", .bounds = geometry.RectF.init(0, 0, 100, 100) }};
    const views = [_]platform.ViewInfo{.{ .label = "refresh-icon", .kind = .icon_button, .frame = geometry.RectF.init(0, 0, 30, 30), .role = "button", .accessibility_label = "Refresh workspace", .text = "R" }};
    try writeA11yText(.{
        .windows = &windows,
        .views = &views,
    }, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "@w1/refresh-icon role=button name=\"Refresh workspace\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "name=\"R\"") == null);
}

test "snapshot emits GPU surface frame proof" {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const windows = [_]Window{.{ .title = "Test", .bounds = geometry.RectF.init(0, 0, 100, 100) }};
    const views = [_]platform.ViewInfo{.{
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 100, 100),
        .gpu_size = geometry.SizeF.init(320, 180),
        .gpu_scale_factor = 2,
        .gpu_backend = .metal,
        .gpu_pixel_format = .bgra8_unorm,
        .gpu_present_mode = .timer,
        .gpu_alpha_mode = .@"opaque",
        .gpu_color_space = .srgb,
        .gpu_vsync = true,
        .gpu_status = .ready,
        .gpu_present_path = .packet,
        .gpu_present_fallback_reason = .json_overflow,
        .gpu_present_fallback_needed_bytes = 218347,
        .gpu_present_fallback_limit_bytes = 131072,
        .gpu_present_fallback_frame_count = 12,
        .gpu_present_packet_mode = .patch,
        .gpu_present_patch_bytes = 2412,
        .gpu_present_patch_upsert_count = 3,
        .gpu_present_patch_evict_count = 1,
        .gpu_present_retained_command_count = 402,
        .gpu_frame_index = 4,
        .gpu_timestamp_ns = 99,
        .gpu_frame_interval_ns = 8,
        .gpu_input_event_count = 7,
        .gpu_input_timestamp_ns = 80,
        .gpu_input_latency_ns = 19,
        .gpu_input_latency_budget_ns = 16,
        .gpu_input_latency_budget_exceeded_count = 1,
        .gpu_input_latency_budget_ok = false,
        .gpu_first_frame_latency_ns = 24,
        .gpu_first_frame_latency_budget_ns = 150,
        .gpu_first_frame_latency_budget_exceeded_count = 0,
        .gpu_first_frame_latency_budget_ok = true,
        .gpu_frame_nonblank = true,
        .gpu_occluded = true,
        .gpu_sample_color = 0xff336699,
        .canvas_revision = 2,
        .canvas_command_count = 5,
        .canvas_frame_requires_render = true,
        .canvas_frame_full_repaint = true,
        .canvas_frame_batch_count = 3,
        .canvas_frame_encoder_command_count = 8,
        .canvas_frame_encoder_cache_action_count = 2,
        .canvas_frame_encoder_bind_pipeline_count = 3,
        .canvas_frame_encoder_draw_batch_count = 3,
        .canvas_frame_pipeline_count = 2,
        .canvas_frame_pipeline_upload_count = 1,
        .canvas_frame_pipeline_retain_count = 1,
        .canvas_frame_pipeline_evict_count = 0,
        .canvas_frame_path_geometry_count = 3,
        .canvas_frame_path_geometry_vertex_count = 18,
        .canvas_frame_path_geometry_index_count = 24,
        .canvas_frame_path_geometry_upload_count = 2,
        .canvas_frame_path_geometry_retain_count = 1,
        .canvas_frame_path_geometry_evict_count = 0,
        .canvas_frame_image_count = 2,
        .canvas_frame_image_upload_count = 1,
        .canvas_frame_image_retain_count = 1,
        .canvas_frame_image_evict_count = 0,
        .canvas_frame_layer_count = 3,
        .canvas_frame_layer_opacity_count = 1,
        .canvas_frame_layer_clip_count = 1,
        .canvas_frame_layer_transform_count = 1,
        .canvas_frame_layer_upload_count = 2,
        .canvas_frame_layer_retain_count = 1,
        .canvas_frame_layer_evict_count = 0,
        .canvas_frame_resource_count = 2,
        .canvas_frame_resource_upload_count = 1,
        .canvas_frame_resource_retain_count = 1,
        .canvas_frame_resource_evict_count = 0,
        .canvas_frame_visual_effect_count = 3,
        .canvas_frame_visual_effect_shadow_count = 2,
        .canvas_frame_visual_effect_blur_count = 1,
        .canvas_frame_visual_effect_upload_count = 2,
        .canvas_frame_visual_effect_retain_count = 1,
        .canvas_frame_visual_effect_evict_count = 0,
        .canvas_frame_glyph_atlas_entry_count = 4,
        .canvas_frame_glyph_atlas_upload_count = 2,
        .canvas_frame_glyph_atlas_retain_count = 2,
        .canvas_frame_glyph_atlas_evict_count = 0,
        .canvas_frame_text_layout_count = 2,
        .canvas_frame_text_layout_line_count = 4,
        .canvas_frame_text_layout_upload_count = 1,
        .canvas_frame_text_layout_retain_count = 1,
        .canvas_frame_text_layout_evict_count = 0,
        .canvas_frame_gpu_packet_command_count = 5,
        .canvas_frame_gpu_packet_cache_action_count = 7,
        .canvas_frame_gpu_packet_cached_resource_command_count = 4,
        .canvas_frame_gpu_packet_unsupported_command_count = 0,
        .canvas_frame_gpu_packet_representable = true,
        .canvas_frame_change_count = 0,
        .canvas_frame_budget_exceeded_count = 2,
        .canvas_frame_budget_ok = false,
        .canvas_frame_dirty_bounds = geometry.RectF.init(0, 0, 320, 180),
        .canvas_frame_profile_work_units = 42,
        .canvas_frame_profile_risk = .high,
        .canvas_frame_profile_surface_area = 57600,
        .canvas_frame_profile_dirty_area = 32000,
        .canvas_frame_profile_dirty_ratio = 0.5555556,
        .widget_context_menu_item_count = 124,
        .cursor = .text,
    }};
    try writeText(.{
        .windows = &windows,
        .views = &views,
        .widget_context_menu_item_budget = 512,
        .text_layout_plan_budget = 2048,
        .text_layout_line_budget = 8192,
    }, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_size=320x180") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_scale=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_backend=metal") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_pixel_format=bgra8_unorm") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_present_mode=timer") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_alpha_mode=opaque") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_color_space=srgb") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_vsync=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_status=ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_present_path=packet") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "present_fallback=json_overflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "present_fallback_needed=218347") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "present_fallback_limit=131072") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "present_fallback_command=\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "present_fallback_frames=12") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "present_mode=patch") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "present_patch_bytes=2412") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "present_patch_upserts=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "present_patch_evicts=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "present_retained_commands=402") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_frame=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_timestamp_ns=99") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_frame_interval_ns=8") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_input_count=7") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_input_timestamp_ns=80") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_input_latency_ns=19") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_input_latency_budget_ns=16") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_input_latency_budget_exceeded=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_input_latency_budget_ok=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_first_frame_latency_ns=24") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_first_frame_latency_budget_ns=150") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_first_frame_latency_budget_exceeded=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_first_frame_latency_budget_ok=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_nonblank=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_occluded=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gpu_sample=0xff336699") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_revision=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_commands=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_requires_render=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_full_repaint=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_batches=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_encoder_commands=8") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_encoder_pipeline_binds=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_pipelines=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_pipeline_uploads=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_path_geometries=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_path_vertices=18") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_path_indices=24") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_path_uploads=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_path_retains=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_images=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_image_uploads=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_image_retains=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_layers=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_opacity_layers=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_clip_layers=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_transform_layers=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_layer_uploads=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_resources=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_uploads=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_retains=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_evicts=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_effects=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_shadows=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_blurs=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_effect_uploads=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_effect_retains=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_glyphs=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_glyph_uploads=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_glyph_retains=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_text_layouts=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_text_lines=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_text_uploads=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_text_retains=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_gpu_packet_commands=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_gpu_packet_cache_actions=7") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_gpu_packet_cached_resources=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_gpu_packet_unsupported=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_gpu_packet_representable=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_changes=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_budget_exceeded=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_budget_ok=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_dirty=(0,0 320x180)") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_profile_work_units=42") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_profile_risk=high") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_profile_surface_area=57600") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "canvas_frame_profile_dirty_area=32000") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "context_menu_items=124/512") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "text_layout_plans=2/2048") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "text_layout_lines=4/8192") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "widget_cursor=text") != null);
}

test "snapshot emits widget semantics" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const windows = [_]Window{.{ .title = "Test", .bounds = geometry.RectF.init(0, 0, 100, 100) }};
    const views = [_]platform.ViewInfo{.{ .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, 100, 100), .role = "canvas" }};
    const widgets = [_]Widget{
        .{
            .window_id = 1,
            .view_label = "canvas",
            .id = 42,
            .role = "button",
            .name = "Run query",
            .parent_id = 7,
            .text_value = "deploy",
            .placeholder = "Search deployments",
            .grid_row_index = 1,
            .grid_column_index = 2,
            .grid_row_count = 4,
            .grid_column_count = 5,
            .list = .{
                .present = true,
                .item_index = 3,
                .item_count = 9,
            },
            .scroll = .{
                .present = true,
                .offset = 12.0,
                .viewport_extent = 80.0,
                .content_extent = 180.0,
            },
            .virtual_range = .{
                .present = true,
                .start_index = 2,
                .end_index = 7,
                .first_visible_index = 3,
                .last_visible_index = 5,
                .rendered_count = 5,
            },
            .bounds = geometry.RectF.init(10, 12, 80, 32),
            .focused = true,
            .hovered = true,
            .pressed = true,
            .selected = true,
            .expanded = true,
            .required = true,
            .read_only = true,
            .invalid = true,
            .actions = .{ .focus = true, .press = true, .set_selection = true, .drag = true, .drop_files = true, .dismiss = true },
            .text_selection = .{ .start = 4, .end = 4 },
            .text_composition = .{ .start = 0, .end = 3 },
        },
        .{
            .window_id = 1,
            .view_label = "canvas",
            .id = 43,
            .role = "button",
            .name = "Disabled",
            .bounds = geometry.RectF.init(10, 48, 80, 32),
            .enabled = false,
            .expanded = false,
        },
    };
    try writeText(.{
        .windows = &windows,
        .views = &views,
        .widgets = &widgets,
    }, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "widget @w1/canvas#42 role=button name=\"Run query\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "parent=#7") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "text=\"deploy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "placeholder=\"Search deployments\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "grid=[row_index=1,column_index=2,row_count=4,column_count=5]") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "list=[index=3,count=9]") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "scroll=[offset=12,viewport=80,content=180]") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "virtual=[start=2,end=7,first=3,last=5,rendered=5]") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "state=[focused,hovered,pressed,selected,expanded,required,read_only,invalid]") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "@w1/canvas#43 role=button name=\"Disabled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "state=[disabled,collapsed]") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "actions=[focus,press,set_selection,drag,drop_files,dismiss]") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "selection=4..4") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "composition=0..3") != null);

    var a11y_buffer: [2048]u8 = undefined;
    var a11y_writer = std.Io.Writer.fixed(&a11y_buffer);
    try writeA11yText(.{
        .windows = &windows,
        .views = &views,
        .widgets = &widgets,
    }, &a11y_writer);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "a11y root=@w1 nodes=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#42 role=button name=\"Run query\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "parent=#7") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "text=\"deploy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "grid=[row_index=1,column_index=2,row_count=4,column_count=5]") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "list=[index=3,count=9]") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "scroll=[offset=12,viewport=80,content=180]") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "state=[focused,hovered,pressed,selected,expanded,required,read_only,invalid]") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "@w1/canvas#43 role=button name=\"Disabled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "state=[disabled,collapsed]") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "actions=[focus,press,set_selection,drag,drop_files,dismiss]") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "selection=4..4") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "composition=0..3") != null);
}
