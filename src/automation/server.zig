const std = @import("std");
const geometry = @import("geometry");
const protocol = @import("protocol.zig");
const snapshot = @import("snapshot.zig");

/// The dropbox protocol is filesystem-backed; targets without one
/// (freestanding wasm) publish and consume nothing. Comptime-known so
/// `std.Io.Dir.cwd()` (posix) is never analyzed on those targets.
const has_filesystem = switch (@import("builtin").os.tag) {
    .freestanding, .emscripten => false,
    else => true,
};

const snapshot_initial_capacity: usize = 16 * 1024;
const windows_initial_capacity: usize = 1024;

/// Longest possible queue entry name: `command-` + a u64 in decimal
/// (at most 20 digits) + `.txt`, comfortably under 64.
const max_queue_name_bytes: usize = 64;

pub const Server = struct {
    io: std.Io,
    directory: []const u8 = protocol.default_dir,
    title: []const u8 = "native-sdk",
    /// How long an incomplete queue entry (claimed name, line not fully
    /// written yet — no trailing newline) may sit at the head before the
    /// drain reaps it. A writer lands its whole line in ONE small write
    /// immediately after claiming the name, so the incomplete state is
    /// normally a microseconds-wide race the next frame resolves; an
    /// entry still incomplete after this long has a dead writer behind
    /// it, and leaving it in place would wedge the queue head forever
    /// (strict FIFO means the drain never skips past it). Overridable so
    /// tests can exercise the reap without real waiting.
    abandoned_entry_reap_ns: i128 = 2 * std.time.ns_per_s,

    pub fn init(io: std.Io, directory: []const u8, title: []const u8) Server {
        return .{ .io = io, .directory = directory, .title = title };
    }

    pub fn publish(self: Server, input_value: snapshot.Input) !void {
        if (!has_filesystem) return;
        var cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(self.io, self.directory);
        var writer = try std.Io.Writer.Allocating.initCapacity(std.heap.page_allocator, snapshot_initial_capacity);
        defer writer.deinit();
        try snapshot.writeText(input_value, &writer.writer);
        var path_buffer: [256]u8 = undefined;
        try writePath(self.io, self.path("snapshot.txt", &path_buffer), writer.written());
        var a11y_writer = try std.Io.Writer.Allocating.initCapacity(std.heap.page_allocator, snapshot_initial_capacity);
        defer a11y_writer.deinit();
        try snapshot.writeA11yText(input_value, &a11y_writer.writer);
        try writePath(self.io, self.path("accessibility.txt", &path_buffer), a11y_writer.written());
        var windows_writer = try std.Io.Writer.Allocating.initCapacity(std.heap.page_allocator, windows_initial_capacity);
        defer windows_writer.deinit();
        for (input_value.windows) |window| {
            try windows_writer.writer.print("window @w{d} \"{s}\" focused={any}\n", .{ window.id, window.title, window.focused });
        }
        try writePath(self.io, self.path("windows.txt", &path_buffer), windows_writer.written());
    }

    pub fn publishBridgeResponse(self: Server, response: []const u8) !void {
        if (!has_filesystem) return;
        var cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(self.io, self.directory);
        var path_buffer: [256]u8 = undefined;
        try writePath(self.io, self.path("bridge-response.txt", &path_buffer), response);
    }

    /// Response artifact for the `provenance` verb: the queried widget's
    /// authored-markup record, or the teaching error saying why there is
    /// none. One command in flight at a time, like the bridge response.
    pub fn publishProvenanceResponse(self: Server, response: []const u8) !void {
        if (!has_filesystem) return;
        var cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(self.io, self.directory);
        var path_buffer: [256]u8 = undefined;
        try writePath(self.io, self.path("provenance.txt", &path_buffer), response);
    }

    /// Write a view screenshot artifact (`screenshot-<label>.png`). The
    /// bytes land in a temporary file first and are renamed into place so
    /// pollers never observe a partially written PNG.
    pub fn publishScreenshot(self: Server, view_label: []const u8, png_bytes: []const u8) !void {
        if (!has_filesystem) return;
        var cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(self.io, self.directory);
        var name_buffer: [128]u8 = undefined;
        const name = try protocol.screenshotFileName(view_label, &name_buffer);
        var temp_name_buffer: [160]u8 = undefined;
        const temp_name = try std.fmt.bufPrint(&temp_name_buffer, "{s}.tmp", .{name});
        var path_buffer: [256]u8 = undefined;
        var temp_path_buffer: [256]u8 = undefined;
        const final_path = self.path(name, &path_buffer);
        const temp_path = self.path(temp_name, &temp_path_buffer);
        try writePath(self.io, temp_path, png_bytes);
        try std.Io.Dir.cwd().rename(temp_path, std.Io.Dir.cwd(), final_path, self.io);
    }

    /// Consume the OLDEST pending command in the dropbox queue — one
    /// entry per call, so the runtime's one-command-per-frame cadence is
    /// decided by the caller, not by how many commands landed. Deleting
    /// the entry file IS the consumption ack a writer polls for.
    ///
    /// EVERY complete entry is consumed (deleted), even one that cannot
    /// be dispatched: leaving an oversized or malformed line at the
    /// queue head would strand it forever — strict FIFO means nothing
    /// behind it could ever drain, and the arrival watcher would keep
    /// waking the loop for an entry the drain can never retire. Ack
    /// first, then report the failure as an error so the runtime records
    /// it where snapshots surface it.
    pub fn takeCommand(self: Server, buffer: []u8) !?protocol.Command {
        if (!has_filesystem) return null;
        var name_buffer: [max_queue_name_bytes]u8 = undefined;
        const name = self.queueHeadName(&name_buffer) orelse return null;
        var path_buffer: [256]u8 = undefined;
        const entry_path = self.path(name, &path_buffer);
        const bytes = readPath(self.io, entry_path, buffer) catch return null;
        if (bytes.len == buffer.len) {
            // The file filled the whole buffer, so the line on disk is at
            // least this long — oversized however it ends. Ack (delete)
            // and fail loudly rather than wedge the queue head.
            try deletePathAllowingVanished(self.io, entry_path);
            return error.CommandTooLarge;
        }
        if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') {
            // No trailing newline: the writer claimed the name but its
            // single line-write has not landed yet. Strict FIFO forbids
            // skipping ahead (a later complete entry must not dispatch
            // before this one), so take nothing this turn — the arrival
            // watcher wakes the loop again — and reap the entry only
            // once it has been abandoned long enough that no live writer
            // can still be behind it.
            self.reapAbandonedEntry(entry_path);
            return null;
        }
        try deletePathAllowingVanished(self.io, entry_path);
        const line = std.mem.trim(u8, bytes, " \n\r\t");
        // A whitespace-only entry is a writer bug with nothing to
        // dispatch; it was deleted above so it cannot block the queue.
        if (line.len == 0) return null;
        return try protocol.Command.parse(line);
    }

    /// True when the dropbox queue holds at least one entry. The same
    /// pending test `takeCommand` starts from, WITHOUT consuming: the
    /// arrival watcher polls this from its own thread and nudges the
    /// platform loop, and the drain on the loop thread stays the only
    /// consumer, so command order and the one-command-per-frame cadence
    /// are untouched. A name scan only — no entry content is read, so an
    /// entry mid-write costs at most a frame or two of wakes with a
    /// nothing-to-take drain, and an abandoned incomplete entry keeps
    /// waking the loop until the drain's reap retires it.
    pub fn hasPendingCommand(self: Server) bool {
        if (!has_filesystem) return false;
        var name_buffer: [max_queue_name_bytes]u8 = undefined;
        return self.queueHeadName(&name_buffer) != null;
    }

    /// The queue entry name with the LOWEST claim sequence, or null when
    /// the queue is empty. Lowest-first is the whole FIFO story: writers
    /// claim strictly increasing sequences, so the smallest number
    /// present is always the oldest unconsumed command. Every non-queue
    /// file in the dropbox (snapshots, response artifacts, a stale v5
    /// `command.txt`) fails the name parse and is invisible here.
    fn queueHeadName(self: Server, name_buffer: []u8) ?[]const u8 {
        var dir = std.Io.Dir.cwd().openDir(self.io, self.directory, .{ .iterate = true }) catch return null;
        defer dir.close(self.io);
        var head_sequence: ?u64 = null;
        var head_len: usize = 0;
        var iterator = dir.iterate();
        while (iterator.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const sequence = protocol.queueFileSequence(entry.name) orelse continue;
            if (head_sequence) |current| {
                if (sequence >= current) continue;
            }
            if (entry.name.len > name_buffer.len) continue;
            head_sequence = sequence;
            head_len = entry.name.len;
            @memcpy(name_buffer[0..entry.name.len], entry.name);
        }
        if (head_sequence == null) return null;
        return name_buffer[0..head_len];
    }

    /// Delete an incomplete queue-head entry once its writer is provably
    /// gone (mtime older than the reap budget). Best-effort on every
    /// step: a stat or delete failure just leaves the entry for a later
    /// turn, and the app under automation keeps running either way.
    fn reapAbandonedEntry(self: Server, entry_path: []const u8) void {
        const stat = std.Io.Dir.cwd().statFile(self.io, entry_path, .{}) catch return;
        const now_ns: i128 = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        if (now_ns <= 0) return;
        if (now_ns - stat.mtime.nanoseconds < self.abandoned_entry_reap_ns) return;
        std.Io.Dir.cwd().deleteFile(self.io, entry_path) catch {};
    }

    fn path(self: Server, name: []const u8, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ self.directory, name }) catch unreachable;
    }
};

fn writePath(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn readPath(io: std.Io, path: []const u8, buffer: []u8) ![]const u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return buffer[0..try file.readPositionalAll(io, buffer, 0)];
}

/// Delete a queue entry, tolerating one that already vanished (the
/// dropbox owner cleaned the directory between the head scan and here —
/// this drain is the only in-protocol deleter, so "already gone" only
/// ever means an external sweep, never a lost command). Any other delete
/// failure propagates: an undeletable head would redispatch the same
/// command every frame, and that must be loud.
fn deletePathAllowingVanished(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn resetTestDirectory(io: std.Io, path: []const u8) !void {
    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, path) catch {};
    try cwd.createDirPath(io, path);
}

test "server stores directory metadata" {
    const server = Server.init(std.testing.io, ".zig-cache/test-webview-automation", "Test");
    try std.testing.expectEqualStrings("Test", server.title);
}

test "server writes bridge response artifact" {
    const server = Server.init(std.testing.io, ".zig-cache/test-webview-automation", "Test");
    try server.publishBridgeResponse("{\"id\":\"1\",\"ok\":true}");

    var buffer: [128]u8 = undefined;
    var path_buffer: [256]u8 = undefined;
    const bytes = try readPath(std.testing.io, server.path("bridge-response.txt", &path_buffer), &buffer);
    try std.testing.expectEqualStrings("{\"id\":\"1\",\"ok\":true}", bytes);
}

test "server publishes large retained widget snapshots" {
    const directory = ".zig-cache/test-webview-automation-large-snapshot";
    try resetTestDirectory(std.testing.io, directory);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, directory) catch {};

    const windows = [_]snapshot.Window{.{
        .title = "Large Widget Snapshot",
        .bounds = geometry.RectF.init(0, 0, 1200, 760),
    }};
    var widgets: [80]snapshot.Widget = undefined;
    for (&widgets, 0..) |*widget, index| {
        widget.* = .{
            .view_label = "components-canvas",
            .id = 1000 + index,
            .role = "textbox",
            .name = "Retained component field with a descriptive accessible name",
            .text_value = "native-sdk retained widget snapshot payload",
            .bounds = geometry.RectF.init(@floatFromInt(index), @floatFromInt(index), 180, 28),
            .actions = .{ .focus = true, .set_text = true, .set_selection = true },
            .text_selection = .{ .start = 1, .end = 12 },
        };
    }

    const server = Server.init(std.testing.io, directory, "Large");
    try server.publish(.{
        .windows = &windows,
        .widgets = &widgets,
    });

    var path_buffer: [256]u8 = undefined;
    var buffer: [32 * 1024]u8 = undefined;
    const text = try readPath(std.testing.io, server.path("snapshot.txt", &path_buffer), &buffer);
    try std.testing.expect(text.len > 4 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, text, "widget @w1/components-canvas#1079") != null);

    const a11y = try readPath(std.testing.io, server.path("accessibility.txt", &path_buffer), &buffer);
    try std.testing.expect(a11y.len > 4 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, a11y, "@w1/components-canvas#1079 role=textbox") != null);
}

test "server writes screenshot artifacts atomically" {
    const directory = ".zig-cache/test-webview-automation-screenshot";
    try resetTestDirectory(std.testing.io, directory);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, directory) catch {};

    const server = Server.init(std.testing.io, directory, "Test");
    const png_bytes = "\x89PNG\r\n\x1a\nfake-png-payload";
    try server.publishScreenshot("inbox-canvas", png_bytes);

    var buffer: [64]u8 = undefined;
    var path_buffer: [256]u8 = undefined;
    const bytes = try readPath(std.testing.io, server.path("screenshot-inbox-canvas.png", &path_buffer), &buffer);
    try std.testing.expectEqualStrings(png_bytes, bytes);

    // No temporary file is left behind.
    var temp_buffer: [64]u8 = undefined;
    try std.testing.expectError(
        error.FileNotFound,
        readPath(std.testing.io, server.path("screenshot-inbox-canvas.png.tmp", &path_buffer), &temp_buffer),
    );

    // Republish overwrites the previous artifact.
    try server.publishScreenshot("inbox-canvas", "\x89PNG\r\n\x1a\nsecond");
    const second = try readPath(std.testing.io, server.path("screenshot-inbox-canvas.png", &path_buffer), &buffer);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\nsecond", second);
}

/// Write one queue entry (`command-<sequence>.txt`) the way the CLI
/// does: whole line, trailing newline, single write.
fn writeQueueEntry(io: std.Io, server: Server, sequence: u64, line: []const u8) !void {
    var name_buffer: [max_queue_name_bytes]u8 = undefined;
    const name = try protocol.queueFileName(sequence, &name_buffer);
    var path_buffer: [256]u8 = undefined;
    try writePath(io, server.path(name, &path_buffer), line);
}

fn queueEntryExists(io: std.Io, server: Server, sequence: u64) bool {
    var name_buffer: [max_queue_name_bytes]u8 = undefined;
    const name = protocol.queueFileName(sequence, &name_buffer) catch return false;
    var path_buffer: [256]u8 = undefined;
    var buffer: [protocol.max_command_bytes]u8 = undefined;
    _ = readPath(io, server.path(name, &path_buffer), &buffer) catch return false;
    return true;
}

test "server dispatches rapid-fire commands in arrival order, one per turn" {
    const directory = ".zig-cache/test-webview-automation-rapid-fire";
    try resetTestDirectory(std.testing.io, directory);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, directory) catch {};

    const server = Server.init(std.testing.io, directory, "Test");
    var command_buffer: [256]u8 = undefined;

    // The field reproduction: three commands land back-to-back BEFORE the
    // app drains any of them. The single-entry slot lost one of these to
    // an overwrite; the queue must dispatch all three, oldest first, one
    // per consumption turn.
    try writeQueueEntry(std.testing.io, server, 1, "menu-command app.first\n");
    try writeQueueEntry(std.testing.io, server, 2, "menu-command app.second\n");
    try writeQueueEntry(std.testing.io, server, 3, "menu-command app.third\n");

    const first = (try server.takeCommand(&command_buffer)).?;
    try std.testing.expectEqual(protocol.Action.menu_command, first.action);
    try std.testing.expectEqualStrings("app.first", first.value);
    // One per turn: consuming the head deletes ITS entry (the ack a
    // writer polls for) and leaves the younger two untouched.
    try std.testing.expect(!queueEntryExists(std.testing.io, server, 1));
    try std.testing.expect(queueEntryExists(std.testing.io, server, 2));
    try std.testing.expect(queueEntryExists(std.testing.io, server, 3));

    const second = (try server.takeCommand(&command_buffer)).?;
    try std.testing.expectEqualStrings("app.second", second.value);
    const third = (try server.takeCommand(&command_buffer)).?;
    try std.testing.expectEqualStrings("app.third", third.value);
    try std.testing.expect(try server.takeCommand(&command_buffer) == null);
    try std.testing.expect(!server.hasPendingCommand());
}

test "server consumes queued automation commands" {
    const directory = ".zig-cache/test-webview-automation-command";
    try resetTestDirectory(std.testing.io, directory);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, directory) catch {};

    const server = Server.init(std.testing.io, directory, "Test");
    var command_buffer: [256]u8 = undefined;

    // Sequence numbers restart whenever the queue drains empty (writers
    // pick max-present + 1), so ordering only ever compares COEXISTING
    // entries — queue the verbs with arbitrary gaps to pin that shape.
    try writeQueueEntry(std.testing.io, server, 1, "native-command app.refresh refresh-button\n");
    const native_command = (try server.takeCommand(&command_buffer)).?;
    try std.testing.expectEqual(protocol.Action.native_command, native_command.action);
    try std.testing.expectEqualStrings("app.refresh refresh-button", native_command.value);
    try std.testing.expect(try server.takeCommand(&command_buffer) == null);

    try writeQueueEntry(std.testing.io, server, 1, "focus-next\n");
    const focus_next = (try server.takeCommand(&command_buffer)).?;
    try std.testing.expectEqual(protocol.Action.focus_next_view, focus_next.action);
    try std.testing.expectEqualStrings("", focus_next.value);

    try writeQueueEntry(std.testing.io, server, 7, "widget-action canvas 2 press\n");
    const widget_action = (try server.takeCommand(&command_buffer)).?;
    try std.testing.expectEqual(protocol.Action.widget_action, widget_action.action);
    try std.testing.expectEqualStrings("canvas 2 press", widget_action.value);

    try writeQueueEntry(std.testing.io, server, 2, "widget-click canvas 2\n");
    const widget_click = (try server.takeCommand(&command_buffer)).?;
    try std.testing.expectEqual(protocol.Action.widget_click, widget_click.action);
    try std.testing.expectEqualStrings("canvas 2", widget_click.value);

    try writeQueueEntry(std.testing.io, server, 3, "widget-drag canvas 2 0.25 0.82\n");
    const widget_drag = (try server.takeCommand(&command_buffer)).?;
    try std.testing.expectEqual(protocol.Action.widget_drag, widget_drag.action);
    try std.testing.expectEqualStrings("canvas 2 0.25 0.82", widget_drag.value);

    try writeQueueEntry(std.testing.io, server, 4, "widget-key canvas tab\n");
    const widget_key = (try server.takeCommand(&command_buffer)).?;
    try std.testing.expectEqual(protocol.Action.widget_key, widget_key.action);
    try std.testing.expectEqualStrings("canvas tab", widget_key.value);

    try writeQueueEntry(std.testing.io, server, 5, "tray-action 11\n");
    const tray_action = (try server.takeCommand(&command_buffer)).?;
    try std.testing.expectEqual(protocol.Action.tray_action, tray_action.action);
    try std.testing.expectEqualStrings("11", tray_action.value);
}

test "server acks undispatchable command entries instead of stranding the queue" {
    const directory = ".zig-cache/test-webview-automation-bad-command";
    try resetTestDirectory(std.testing.io, directory);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, directory) catch {};

    const server = Server.init(std.testing.io, directory, "Test");
    var command_buffer: [256]u8 = undefined;

    // A malformed line is consumed (its entry deleted) with a loud
    // error, never left at the queue head to block everything behind it
    // — the command queued AFTER the bad one dispatches on the very next
    // turn.
    try writeQueueEntry(std.testing.io, server, 1, "no-such-verb whatever\n");
    try writeQueueEntry(std.testing.io, server, 2, "menu-command app.after-bad\n");
    try std.testing.expectError(error.InvalidCommand, server.takeCommand(&command_buffer));
    try std.testing.expect(!queueEntryExists(std.testing.io, server, 1));
    const after_bad = (try server.takeCommand(&command_buffer)).?;
    try std.testing.expectEqualStrings("app.after-bad", after_bad.value);

    // Same for a line larger than the caller's buffer.
    var oversized_buffer: [64]u8 = undefined;
    const oversized = "widget-key canvas " ++ "x" ** 256 ++ "\n";
    try writeQueueEntry(std.testing.io, server, 3, oversized);
    try std.testing.expectError(error.CommandTooLarge, server.takeCommand(&oversized_buffer));
    try std.testing.expect(!queueEntryExists(std.testing.io, server, 3));
    try std.testing.expect(try server.takeCommand(&command_buffer) == null);
}

test "server reports pending commands without consuming them" {
    const directory = ".zig-cache/test-webview-automation-pending";
    try resetTestDirectory(std.testing.io, directory);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, directory) catch {};

    const server = Server.init(std.testing.io, directory, "Test");
    var path_buffer: [256]u8 = undefined;

    // An empty dropbox is idle, and so is one holding only non-queue
    // files — response artifacts and, pointedly, a retired-v5 writer's
    // `command.txt` slot, which this protocol version must never consume
    // (acking it would tell that stale CLI its command dispatched).
    try std.testing.expect(!server.hasPendingCommand());
    try writePath(std.testing.io, server.path("command.txt", &path_buffer), "widget-click canvas 7\n");
    try writePath(std.testing.io, server.path("bridge-response.txt", &path_buffer), "{}");
    try std.testing.expect(!server.hasPendingCommand());
    var command_buffer: [256]u8 = undefined;
    try std.testing.expect(try server.takeCommand(&command_buffer) == null);

    // A queued entry is pending — and STAYS pending across probes; only
    // takeCommand (the loop-thread drain) consumes it.
    try writeQueueEntry(std.testing.io, server, 1, "widget-click canvas 7\n");
    try std.testing.expect(server.hasPendingCommand());
    try std.testing.expect(server.hasPendingCommand());
    const command = (try server.takeCommand(&command_buffer)).?;
    try std.testing.expectEqual(protocol.Action.widget_click, command.action);
    try std.testing.expect(!server.hasPendingCommand());
}

test "server defers an incomplete queue head and reaps it once abandoned" {
    const directory = ".zig-cache/test-webview-automation-incomplete";
    try resetTestDirectory(std.testing.io, directory);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, directory) catch {};

    var server = Server.init(std.testing.io, directory, "Test");
    var command_buffer: [256]u8 = undefined;

    // A head entry without its trailing newline is a writer mid-claim:
    // strict FIFO means the complete entry behind it must NOT jump the
    // queue, and a fresh incomplete entry must not be reaped.
    try writeQueueEntry(std.testing.io, server, 1, "menu-command app.first");
    try writeQueueEntry(std.testing.io, server, 2, "menu-command app.second\n");
    try std.testing.expect(try server.takeCommand(&command_buffer) == null);
    try std.testing.expect(queueEntryExists(std.testing.io, server, 1));
    // The name scan still reports pending, so the arrival watcher keeps
    // waking the loop until the head resolves.
    try std.testing.expect(server.hasPendingCommand());

    // The writer finishes its line: both dispatch, oldest first.
    try writeQueueEntry(std.testing.io, server, 1, "menu-command app.first\n");
    const first = (try server.takeCommand(&command_buffer)).?;
    try std.testing.expectEqualStrings("app.first", first.value);
    const second = (try server.takeCommand(&command_buffer)).?;
    try std.testing.expectEqualStrings("app.second", second.value);

    // A DEAD writer's incomplete claim (older than the reap budget —
    // forced to zero here so the test never sleeps) is deleted so the
    // queue heals instead of wedging forever.
    server.abandoned_entry_reap_ns = 0;
    try writeQueueEntry(std.testing.io, server, 4, "menu-command app.orpha");
    try writeQueueEntry(std.testing.io, server, 5, "menu-command app.alive\n");
    try std.testing.expect(try server.takeCommand(&command_buffer) == null);
    try std.testing.expect(!queueEntryExists(std.testing.io, server, 4));
    const alive = (try server.takeCommand(&command_buffer)).?;
    try std.testing.expectEqualStrings("app.alive", alive.value);
}
