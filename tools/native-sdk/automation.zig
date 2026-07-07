const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("automation_protocol");
const ui_markup = @import("ui_markup");

const automation_dir = protocol.default_dir;

pub fn run(allocator: std.mem.Allocator, io: std.Io, environ_map: *std.process.Environ.Map, args: []const []const u8) !void {
    if (args.len == 0) return usage();
    const command = args[0];
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help")) {
        // Asked-for help is a success: print the command table and exit 0.
        printUsage();
        std.process.exit(0);
    }
    if (std.mem.eql(u8, command, "record")) {
        return runSessionLaunch(allocator, io, environ_map, args[1..], .record);
    } else if (std.mem.eql(u8, command, "replay")) {
        return runSessionLaunch(allocator, io, environ_map, args[1..], .replay);
    } else if (std.mem.eql(u8, command, "list")) {
        // windows.txt has no pid of its own; the snapshot in the same
        // dropbox vouches for (or condemns) the whole directory.
        try requireLiveSnapshotFile(allocator, io);
        try printFile(io, "windows.txt");
    } else if (std.mem.eql(u8, command, "snapshot")) {
        try requireLiveSnapshotFile(allocator, io);
        try printFile(io, "snapshot.txt");
    } else if (std.mem.eql(u8, command, "screenshot")) {
        if (args.len < 2 or args.len > 3) return usage();
        var name_buffer: [128]u8 = undefined;
        const name = protocol.screenshotFileName(args[1], &name_buffer) catch return usage();
        deleteAutomationFile(io, name);
        const value = try std.mem.join(allocator, " ", args[1..]);
        defer allocator.free(value);
        try sendCommand(allocator, io, "screenshot", value);
        try waitForScreenshot(io, name);
    } else if (std.mem.eql(u8, command, "reload")) {
        try sendCommand(allocator, io, "reload", "");
    } else if (std.mem.eql(u8, command, "resize")) {
        if (args.len < 3 or args.len > 4) return usage();
        const value = if (args.len == 4)
            try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ args[1], args[2], args[3] })
        else
            try std.fmt.allocPrint(allocator, "{s} {s}", .{ args[1], args[2] });
        defer allocator.free(value);
        try sendCommand(allocator, io, "resize", value);
    } else if (std.mem.eql(u8, command, "menu-command")) {
        if (args.len != 2) return usage();
        try sendCommand(allocator, io, "menu-command", args[1]);
    } else if (std.mem.eql(u8, command, "native-command")) {
        if (args.len < 2 or args.len > 3) return usage();
        if (args.len == 3) {
            const value = try std.fmt.allocPrint(allocator, "{s} {s}", .{ args[1], args[2] });
            defer allocator.free(value);
            try sendCommand(allocator, io, "native-command", value);
        } else {
            try sendCommand(allocator, io, "native-command", args[1]);
        }
    } else if (std.mem.eql(u8, command, "widget-action")) {
        if (args.len < 4) return usage();
        const value = try std.mem.join(allocator, " ", args[1..]);
        defer allocator.free(value);
        try sendCommand(allocator, io, "widget-action", value);
    } else if (std.mem.eql(u8, command, "widget-click")) {
        if (args.len != 3) return usage();
        const value = try std.fmt.allocPrint(allocator, "{s} {s}", .{ args[1], args[2] });
        defer allocator.free(value);
        try sendCommand(allocator, io, "widget-click", value);
    } else if (std.mem.eql(u8, command, "widget-hold")) {
        if (args.len != 3) return usage();
        const value = try std.fmt.allocPrint(allocator, "{s} {s}", .{ args[1], args[2] });
        defer allocator.free(value);
        try sendCommand(allocator, io, "widget-hold", value);
    } else if (std.mem.eql(u8, command, "widget-context-press")) {
        if (args.len != 3) return usage();
        const value = try std.fmt.allocPrint(allocator, "{s} {s}", .{ args[1], args[2] });
        defer allocator.free(value);
        try sendCommand(allocator, io, "widget-context-press", value);
    } else if (std.mem.eql(u8, command, "widget-context-menu")) {
        if (args.len != 4) return usage();
        const value = try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ args[1], args[2], args[3] });
        defer allocator.free(value);
        try sendCommand(allocator, io, "widget-context-menu", value);
    } else if (std.mem.eql(u8, command, "widget-drag")) {
        if (args.len != 5 and args.len != 7) return usage();
        const value = if (args.len == 7)
            try std.fmt.allocPrint(allocator, "{s} {s} {s} {s} {s} {s}", .{ args[1], args[2], args[3], args[4], args[5], args[6] })
        else
            try std.fmt.allocPrint(allocator, "{s} {s} {s} {s}", .{ args[1], args[2], args[3], args[4] });
        defer allocator.free(value);
        try sendCommand(allocator, io, "widget-drag", value);
    } else if (std.mem.eql(u8, command, "widget-wheel")) {
        if (args.len != 4) return usage();
        const value = try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ args[1], args[2], args[3] });
        defer allocator.free(value);
        try sendCommand(allocator, io, "widget-wheel", value);
    } else if (std.mem.eql(u8, command, "widget-key")) {
        if (args.len < 3) return usage();
        const value = try std.mem.join(allocator, " ", args[1..]);
        defer allocator.free(value);
        try sendCommand(allocator, io, "widget-key", value);
    } else if (std.mem.eql(u8, command, "shortcut")) {
        if (args.len != 2) return usage();
        try sendCommand(allocator, io, "shortcut", args[1]);
    } else if (std.mem.eql(u8, command, "tray-action")) {
        if (args.len != 2) return usage();
        try sendCommand(allocator, io, "tray-action", args[1]);
    } else if (std.mem.eql(u8, command, "focus")) {
        if (args.len != 2) return usage();
        try sendCommand(allocator, io, "focus", args[1]);
    } else if (std.mem.eql(u8, command, "focus-next")) {
        if (args.len != 1) return usage();
        try sendCommand(allocator, io, "focus-next", "");
    } else if (std.mem.eql(u8, command, "focus-previous")) {
        if (args.len != 1) return usage();
        try sendCommand(allocator, io, "focus-previous", "");
    } else if (std.mem.eql(u8, command, "profile")) {
        if (args.len != 2 or (!std.mem.eql(u8, args[1], "on") and !std.mem.eql(u8, args[1], "off"))) return usage();
        try sendCommand(allocator, io, "profile", args[1]);
    } else if (std.mem.eql(u8, command, "wait")) {
        try waitForFile(allocator, io, "snapshot.txt", "ready=true", .require_live_publisher);
    } else if (std.mem.eql(u8, command, "assert")) {
        try runAssert(allocator, io, args[1..]);
    } else if (std.mem.eql(u8, command, "bridge")) {
        if (args.len < 2) return usage();
        deleteAutomationFile(io, "bridge-response.txt");
        try sendCommand(allocator, io, "bridge", args[1]);
        try waitForFile(allocator, io, "bridge-response.txt", "", .any_publisher);
    } else if (std.mem.eql(u8, command, "provenance")) {
        // `provenance <view-label> <widget-id>` or
        // `provenance <view-label> at <x> <y>`.
        if (args.len != 3 and !(args.len == 5 and std.mem.eql(u8, args[2], "at"))) return usage();
        const value = try std.mem.join(allocator, " ", args[1..]);
        defer allocator.free(value);
        deleteAutomationFile(io, "provenance.txt");
        try sendCommand(allocator, io, "provenance", value);
        try waitForFile(allocator, io, "provenance.txt", "", .any_publisher);
    } else if (std.mem.eql(u8, command, "edit")) {
        try runEdit(allocator, io, args[1..]);
    } else {
        return usage();
    }
}

// ------------------------------------------------------------- write-back

/// `edit <view-label> <widget-id> <set-attr|remove-attr|set-text> ...`:
/// apply one minimal-diff edit operation to the markup file backing a
/// RUNNING widget. The flow is provenance -> refusal ladder -> checked
/// span edit -> whole-closure validation -> file write; the app's own
/// hot-reload watch then picks the change up (no reload command needed).
/// Refusals never touch the file: a Zig-authored widget, a file that
/// changed since the app loaded it, or an edit that fails validation all
/// stop with a teaching error.
fn runEdit(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    if (args.len < 4) return usage();
    const view_label = args[0];
    const widget_id = args[1];
    const op_name = args[2];
    var op: ui_markup.edit.EditOp = undefined;
    if (std.mem.eql(u8, op_name, "set-attr")) {
        if (args.len != 5) return usage();
        op = .{ .set_attr = .{ .name = args[3], .value = args[4] } };
    } else if (std.mem.eql(u8, op_name, "remove-attr")) {
        if (args.len != 4) return usage();
        op = .{ .remove_attr = .{ .name = args[3] } };
    } else if (std.mem.eql(u8, op_name, "set-text")) {
        const text = try std.mem.join(allocator, " ", args[3..]);
        // Leaked into the arena's lifetime below via the op; freed with
        // the arena at function end.
        op = .{ .set_text = .{ .text = text } };
    } else {
        return usage();
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 1. Provenance: where the running app says this widget was authored.
    const query = try std.fmt.allocPrint(arena, "{s} {s}", .{ view_label, widget_id });
    deleteAutomationFile(io, "provenance.txt");
    try sendCommand(allocator, io, "provenance", query);
    try waitForFileQuietly(allocator, io, "provenance.txt");
    var response_path: [256]u8 = undefined;
    const response = try readFile(arena, io, path(&response_path, "provenance.txt"));

    if (std.mem.startsWith(u8, response, "provenance error")) {
        return failEdit(response);
    }
    if (responseField(response, "authored=")) |authored| {
        if (!std.mem.eql(u8, authored, "markup")) return failEdit(response);
    } else return failEdit(response);
    const watching = responseField(response, "watching=") orelse "false";
    if (!std.mem.eql(u8, watching, "true")) {
        return failEdit("the app is not watching markup sources (no MarkupOptions.watch_path) - write-back needs the dev hot-reload watch so the edit can land in the running app\n");
    }
    const node_line = responseLine(response, "node ") orelse return failEdit(response);
    const file_path = responseField(node_line, "file=") orelse return failEdit(response);
    const hash_text = responseField(node_line, "hash=") orelse return failEdit(response);
    const span_text = responseField(node_line, "span=") orelse return failEdit(response);
    const root_path = responseField(response, "root=") orelse file_path;
    if (file_path.len == 0) return failEdit("provenance names no on-disk file for this widget's source - write-back has nothing to edit\n");
    const app_hash = std.fmt.parseUnsigned(u64, hash_text, 16) catch return failEdit(response);
    const span_start = std.fmt.parseUnsigned(usize, span_text[0 .. std.mem.indexOf(u8, span_text, "..") orelse return failEdit(response)], 10) catch return failEdit(response);

    // 2. Concurrent-modification guard: the app answered with the hash of
    // the bytes it LOADED; the file on disk must still be those bytes, or
    // the spans do not describe it and writing would clobber someone's
    // concurrent edit (or race a not-yet-reloaded save).
    const disk_source = readFile(arena, io, file_path) catch {
        std.debug.print("error: cannot read {s} - run this command from the app project's working directory (the same place the app runs from)\n", .{file_path});
        return error.AutomationCommandFailed;
    };
    if (std.hash.Wyhash.hash(0, disk_source) != app_hash) {
        std.debug.print(
            "error: {s} changed on disk since the app loaded it - the provenance spans no longer describe these bytes.\n" ++
                "       save your editor, let the app's hot-reload watch catch up (it polls every 500ms), and retry;\n" ++
                "       this command never overwrites concurrent edits.\n",
            .{file_path},
        );
        return error.AutomationCommandFailed;
    }

    // 3. The checked minimal-diff edit: parse, apply, reparse, validate,
    // and diff the trees - the file is written only when every other node
    // is provably untouched.
    var diagnostic: ui_markup.MarkupErrorInfo = .{};
    const edited = ui_markup.edit.applyChecked(arena, disk_source, span_start, op, &diagnostic) catch {
        std.debug.print("error: edit refused at {s}:{d}:{d}: {s}\n", .{ file_path, diagnostic.line, diagnostic.column, diagnostic.message });
        return error.AutomationCommandFailed;
    };

    // 4. Whole-closure validation: the single-file check cannot see
    // cross-file template wiring, so resolve the import closure from disk
    // with the edited bytes substituted and run the strict pass before
    // anything lands on disk.
    try validateEditedClosure(arena, io, root_path, file_path, edited);

    // 5. Write. The app's watch reloads within its poll interval;
    // `native automate assert` on the snapshot is the way to await the
    // repaint.
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = edited }) catch {
        std.debug.print("error: could not write {s}\n", .{file_path});
        return error.AutomationCommandFailed;
    };
    var summary_buffer: [512]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buffer, "edited {s} at byte {d} ({s}); the app's markup watch reloads it within 500ms\n", .{ file_path, span_start, op_name }) catch "edited\n";
    try emitPayload(io, &.{summary});
}

/// Poll for a response artifact without echoing it to stdout (the edit
/// flow consumes the provenance response internally).
fn waitForFileQuietly(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 300) : (attempts += 1) {
        var file_path: [256]u8 = undefined;
        const bytes = readFile(allocator, io, path(&file_path, name)) catch {
            try std.Io.sleep(io, std.Io.Duration.fromNanoseconds(100 * std.time.ns_per_ms), .awake);
            continue;
        };
        allocator.free(bytes);
        return;
    }
    return fail("timed out waiting for the provenance response");
}

fn failEdit(response: []const u8) error{AutomationCommandFailed} {
    std.debug.print("error: {s}", .{response});
    if (response.len == 0 or response[response.len - 1] != '\n') std.debug.print("\n", .{});
    return error.AutomationCommandFailed;
}

/// `<marker><value>` field from a key=value response (value ends at
/// whitespace; `message="..."` fields are not parsed here).
fn responseField(text: []const u8, marker: []const u8) ?[]const u8 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, marker)) |index| {
        search = index + marker.len;
        if (index > 0 and text[index - 1] != ' ' and text[index - 1] != '\n') continue;
        var end = search;
        while (end < text.len and text[end] != ' ' and text[end] != '\n') end += 1;
        return text[search..end];
    }
    return null;
}

/// The first line starting with `prefix`.
fn responseLine(text: []const u8, prefix: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, prefix)) return line;
    }
    return null;
}

/// Resolve the root file's import closure from disk with `edited_path`'s
/// bytes substituted, and run the strict validation pass - the cross-file
/// half of "ops validate before write".
fn validateEditedClosure(arena: std.mem.Allocator, io: std.Io, root_path: []const u8, edited_path: []const u8, edited: []const u8) !void {
    var loader = EditOverlayLoader{ .io = io, .edited_path = edited_path, .edited = edited };
    const root_source = if (std.mem.eql(u8, root_path, edited_path))
        edited
    else
        readFile(arena, io, root_path) catch {
            std.debug.print("error: cannot read the markup root {s} for closure validation\n", .{root_path});
            return error.AutomationCommandFailed;
        };
    var diagnostic: ui_markup.MarkupErrorInfo = .{};
    const document = ui_markup.resolveImports(arena, root_path, root_source, loader.loader(), &diagnostic) catch {
        std.debug.print("error: the edit would break the markup closure ({s}:{d}:{d}): {s}\n", .{ diagnostic.path, diagnostic.line, diagnostic.column, diagnostic.message });
        return error.AutomationCommandFailed;
    };
    if (ui_markup.validate(document)) |info| {
        std.debug.print("error: the edit would fail validation ({s}:{d}:{d}): {s}\n", .{ info.path, info.line, info.column, info.message });
        return error.AutomationCommandFailed;
    }
}

/// Disk loader with one path overridden by the edited bytes (validation
/// must see the closure AS IT WOULD BE after the write).
const EditOverlayLoader = struct {
    io: std.Io,
    edited_path: []const u8,
    edited: []const u8,

    fn loader(self: *EditOverlayLoader) ui_markup.ImportLoader {
        return .{ .context = @ptrCast(self), .load = load };
    }

    fn load(context: *const anyopaque, arena: std.mem.Allocator, load_path: []const u8) ?[]const u8 {
        const self: *const EditOverlayLoader = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, load_path, self.edited_path)) return self.edited;
        var file = std.Io.Dir.cwd().openFile(self.io, load_path, .{}) catch return null;
        defer file.close(self.io);
        const buffer = arena.alloc(u8, 256 * 1024) catch return null;
        const len = file.readPositionalAll(self.io, buffer, 0) catch return null;
        return buffer[0..len];
    }
};

const SessionLaunchMode = enum { record, replay };

/// `record --out <journal> -- <app command...>` and
/// `replay <journal> [--verify|--no-verify] -- <app command...>`:
/// launch the app with the session environment armed
/// (NATIVE_SDK_SESSION_RECORD / NATIVE_SDK_SESSION_REPLAY — the app
/// runner does the recording and replaying; this verb only launches).
/// Recording must arm at launch because replay re-runs the app's init:
/// a mid-session recording could never replay its init-time effects.
/// The child's exit code propagates, so `replay --verify` fails this
/// command when verification fails.
fn runSessionLaunch(allocator: std.mem.Allocator, io: std.Io, environ_map: *std.process.Environ.Map, args: []const []const u8, mode: SessionLaunchMode) !void {
    var journal_path: ?[]const u8 = null;
    var verify = true;
    var child_argv: []const []const u8 = &.{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            child_argv = args[index + 1 ..];
            break;
        } else if (mode == .record and std.mem.eql(u8, arg, "--out")) {
            index += 1;
            if (index >= args.len) return fail("record: --out requires a journal path");
            journal_path = args[index];
        } else if (mode == .replay and std.mem.eql(u8, arg, "--verify")) {
            verify = true;
        } else if (mode == .replay and std.mem.eql(u8, arg, "--no-verify")) {
            verify = false;
        } else if (journal_path == null and arg.len > 0 and arg[0] != '-') {
            journal_path = arg;
        } else {
            return usage();
        }
    }
    const journal = journal_path orelse return fail(if (mode == .record)
        "record: name the journal with --out <path> (before the -- app command)"
    else
        "replay: name the journal file (before the -- app command)");
    if (child_argv.len == 0) {
        return fail("name the app to launch after `--`, e.g.: native automate record --out session.journal -- ./zig-out/bin/my-app");
    }

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const keys = environ_map.keys();
    const values = environ_map.values();
    for (keys, values) |key, value| try env.put(key, value);
    switch (mode) {
        .record => try env.put("NATIVE_SDK_SESSION_RECORD", journal),
        .replay => {
            try env.put("NATIVE_SDK_SESSION_REPLAY", journal);
            try env.put("NATIVE_SDK_SESSION_VERIFY", if (verify) "1" else "0");
        },
    }

    var child = try std.process.spawn(io, .{
        .argv = child_argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = &env,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("{s}: the app exited with code {d}\n", .{ @tagName(mode), code });
                return error.AutomationCommandFailed;
            }
        },
        else => {
            std.debug.print("{s}: the app did not exit cleanly (the journal, if any, is unsealed and replay will refuse it)\n", .{@tagName(mode)});
            return error.AutomationCommandFailed;
        },
    }
}

/// Missing or malformed arguments: print the command table and exit 1 (a
/// misuse must never exit 0). Asked-for help goes through printUsage + exit
/// 0 in run() instead.
fn usage() noreturn {
    printUsage();
    std.process.exit(1);
}

fn printUsage() void {
    std.debug.print(
        \\usage: native automate <command>
        \\
        \\commands:
        \\  record --out <session.journal> -- <app command...>   (launch the app with session recording armed)
        \\  replay <session.journal> [--verify|--no-verify] -- <app command...>   (replay the journal headlessly and verify checkpoints)
        \\  list
        \\  snapshot
        \\  screenshot <view-label> [scale]   (renders the gpu_surface view's canvas to screenshot-<view-label>.png)
        \\  reload
        \\  resize <width> <height> [scale]
        \\  menu-command <id>
        \\  native-command <id> [view-label]
        \\  widget-action <view-label> <widget-id> <action> [value]
        \\  widget-click <view-label> <widget-id>   (ids are the bare number; snapshots print #id)
        \\  widget-hold <view-label> <widget-id>   (press-and-hold: arms and fires the on_hold timer, release suppressed)
        \\  widget-context-press <view-label> <widget-id>   (right-click: context menu, or on_hold when the route has none)
        \\  widget-context-menu <view-label> <widget-id> <item-index>   (invoke a declared context-menu item; snapshots list them as context_menu=[...])
        \\  widget-drag <view-label> <widget-id> <start-x-ratio> <end-x-ratio> [start-y-ratio end-y-ratio]
        \\  widget-wheel <view-label> <widget-id> <delta-y>
        \\  widget-key <view-label> <key> [text]
        \\  shortcut <id>
        \\  tray-action <item-id>   (status-item dropdown row; snapshots print tray-item #id)
        \\  focus <view-label>
        \\  focus-next
        \\  focus-previous
        \\  profile <on|off>   (per-stage frame timing; snapshots then carry a frame_profile line of rolling p50/p90s in us)
        \\  wait
        \\  assert [--absent] [--timeout-ms 30000] <pattern> [more patterns...]
        \\      (each pattern is a regex that must match snapshot.txt; --absent
        \\       inverts: every pattern must be gone. Polls until the timeout.)
        \\  bridge <request-json>
        \\  provenance <view-label> (<widget-id> | at <x> <y>)   (where a live widget was authored: file, byte span, line:column, template chain, iteration keys)
        \\  edit <view-label> <widget-id> set-attr <name> <value>   (write the change back into the widget's markup file; hot reload picks it up)
        \\  edit <view-label> <widget-id> remove-attr <name>
        \\  edit <view-label> <widget-id> set-text <text...>
        \\
    , .{});
}

fn sendCommand(allocator: std.mem.Allocator, io: std.Io, action: []const u8, value: []const u8) !void {
    const buffer = try allocator.alloc(u8, protocol.max_command_bytes);
    defer allocator.free(buffer);
    const line = try protocol.commandLine(action, value, buffer);
    // The automation dir is created by the RUNNING APP (built with
    // -Dautomation=true), never by this CLI: a queue written into a
    // freshly created dir would go to an app that does not exist —
    // classically, the wrong cwd — and silently do nothing. Refuse
    // loudly instead, naming the dir we looked at.
    try requireAutomationDir(io);
    // A live publisher already on another protocol makes the queue write
    // provably useless (or worse, misread) — refuse before writing.
    try requireCompatibleSnapshotIfPresent(allocator, io);
    // Claim a slot in the dropbox command queue: an exclusive create of
    // `command-<n>.txt`, so back-to-back (or fully concurrent) `native
    // automate` invocations can NEVER overwrite each other — the old
    // single-entry slot lost exactly that race...
    var name_buffer: [64]u8 = undefined;
    var dir_buffer: [1024]u8 = undefined;
    const name = enqueueCommand(io, automation_dir, line, &name_buffer, queue_attempt_budget) catch |err| {
        switch (err) {
            error.QueueStayedFull => std.debug.print(
                "error: refusing to send {s} - the command queue in {s} stayed full ({d} pending) for 10s\n" ++
                    "       (the app drains one command per presented frame; a queue that never drains\n" ++
                    "        means the app exited, froze, or stopped presenting - check `native automate\n" ++
                    "        wait` and that the snapshot's publisher_pid is your app)\n",
                .{ action, automationDirDescription(io, &dir_buffer), protocol.max_queued_commands },
            ),
            error.QueueUnwritable => std.debug.print(
                "error: could not write a command entry into {s}\n",
                .{automationDirDescription(io, &dir_buffer)},
            ),
        }
        return error.AutomationCommandFailed;
    };
    // ...and only report success once OUR entry was consumed (the app
    // deletes it after reading), so a dead/frozen app fails loudly here
    // instead of a "queued" line that went nowhere.
    awaitCommandConsumed(io, automation_dir, name, queue_attempt_budget) catch {
        std.debug.print(
            "error: the app never consumed {s} (still queued as {s}/{s} after 10s)\n" ++
                "       (the app drains one command per presented frame and deletes the entry as its\n" ++
                "        ack; a silent timeout here means the app exited, froze, or stopped presenting -\n" ++
                "        check `native automate wait` and the snapshot's publisher_pid)\n",
            .{ action, automationDirDescription(io, &dir_buffer), name },
        );
        return error.AutomationCommandFailed;
    };
    std.debug.print("delivered {s} -> {s}\n", .{ action, automationDirDescription(io, &dir_buffer) });
}

/// The shared patience of both queue waits: ~10s at 25ms per attempt.
/// Consumption normally takes one presented frame, so exhausting this
/// budget means the app is gone, frozen, or not presenting. Tests pass a
/// budget of 1 to pin the loud refusals without real waiting.
const queue_attempt_budget: usize = 400;

/// One pass over the dropbox queue from a writer's seat: how many
/// entries are pending, and which claim sequence a new command should
/// take (max present + 1). Sequences only order entries that COEXIST —
/// the app always consumes the lowest number present and deletes it —
/// so numbering restarting at 1 after the queue drains is fine.
const QueueState = struct {
    pending: usize = 0,
    next_sequence: u64 = 1,
};

fn scanQueue(io: std.Io, directory: []const u8) QueueState {
    var state: QueueState = .{};
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch return state;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const sequence = protocol.queueFileSequence(entry.name) orelse continue;
        state.pending += 1;
        if (sequence >= state.next_sequence) state.next_sequence = sequence + 1;
    }
    return state;
}

/// Land `line` in the dropbox command queue and return its entry name.
/// Diagnostics stay with the caller (sendCommand), which owns the
/// teaching messages for both errors.
///
/// Two honesty rules shape this writer:
/// - The claim is an EXCLUSIVE create: losing a name race to another
///   writer is a rescan-and-retry, never an overwrite, so no command can
///   be silently replaced before the app drains it.
/// - A FULL queue (`max_queued_commands` entries pending) is retried at
///   the consumption cadence up to the same ~10s budget as the
///   consumption wait, then refused loudly naming the depth. Retrying in
///   the writer keeps the protocol one-writer-one-file simple (no
///   overflow side-channel for the app to publish and both sides to
///   version), and the outcome stays deterministic: a live app drains
///   one command per presented frame, so a burst clears in milliseconds,
///   while a queue still full after 10s means the app stopped consuming
///   — which must be a loud error, never a dropped command.
fn enqueueCommand(io: std.Io, directory: []const u8, line: []const u8, name_buffer: []u8, attempt_budget: usize) error{ QueueStayedFull, QueueUnwritable }![]const u8 {
    var attempts: usize = 0;
    while (attempts < attempt_budget) : (attempts += 1) {
        const state = scanQueue(io, directory);
        if (state.pending >= protocol.max_queued_commands) {
            std.Io.sleep(io, std.Io.Duration.fromNanoseconds(25 * std.time.ns_per_ms), .awake) catch {};
            continue;
        }
        // The buffer always fits `command-<u64>.txt`; only a caller bug
        // could trip this.
        const name = protocol.queueFileName(state.next_sequence, name_buffer) catch unreachable;
        var entry_path: [256]u8 = undefined;
        std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = std.fmt.bufPrint(&entry_path, "{s}/{s}", .{ directory, name }) catch unreachable,
            .data = line,
            .flags = .{ .exclusive = true },
        }) catch |err| switch (err) {
            // Another writer claimed this sequence between our scan and
            // our create; rescan and take the next number.
            error.PathAlreadyExists => continue,
            else => return error.QueueUnwritable,
        };
        return name;
    }
    return error.QueueStayedFull;
}

/// Poll until the app deletes our queue entry — deletion IS the
/// consumption ack, so "the file is gone" means the runtime took the
/// line into its frame-boundary dispatch. ~10s budget at 25ms:
/// consumption normally takes one presented frame, so hitting the
/// timeout means the app is gone, frozen, or not presenting. A vanished
/// DIRECTORY counts as consumed for the same reason the old protocol
/// accepted a vanished slot: the dropbox owner swept it.
fn awaitCommandConsumed(io: std.Io, directory: []const u8, name: []const u8, attempt_budget: usize) error{NeverConsumed}!void {
    var attempts: usize = 0;
    while (attempts < attempt_budget) : (attempts += 1) {
        var entry_path: [256]u8 = undefined;
        const full_path = std.fmt.bufPrint(&entry_path, "{s}/{s}", .{ directory, name }) catch unreachable;
        var file = std.Io.Dir.cwd().openFile(io, full_path, .{}) catch return;
        file.close(io);
        std.Io.sleep(io, std.Io.Duration.fromNanoseconds(25 * std.time.ns_per_ms), .awake) catch {};
    }
    return error.NeverConsumed;
}

/// Error out (loudly, with the absolute path) when the automation dir
/// does not exist under the current cwd — the app creates it at start,
/// so its absence means no automation-enabled app runs HERE and the
/// command would be queued into the void.
fn requireAutomationDir(io: std.Io) error{AutomationCommandFailed}!void {
    var dir = std.Io.Dir.cwd().openDir(io, automation_dir, .{}) catch {
        var dir_buffer: [1024]u8 = undefined;
        std.debug.print(
            "error: no automation dir at {s}\n" ++
                "       (the app creates it on launch when built with -Dautomation=true;\n" ++
                "        run this command from the app project's working directory)\n",
            .{automationDirDescription(io, &dir_buffer)},
        );
        return error.AutomationCommandFailed;
    };
    dir.close(io);
}

/// The automation dir as an absolute path when the cwd resolves, the
/// relative default otherwise — for messages only.
fn automationDirDescription(io: std.Io, buffer: []u8) []const u8 {
    var cwd_buffer: [1024]u8 = undefined;
    const cwd_len = std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buffer) catch return automation_dir;
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ cwd_buffer[0..cwd_len], automation_dir }) catch automation_dir;
}

/// Payloads a script exists to parse — snapshot/window-list text, wait
/// output, bridge responses, screenshot artifact paths — go to STDOUT so
/// `automate snapshot > file` and `| grep` work; diagnostics and progress
/// stay on stderr (std.debug.print) throughout this file.
fn emitPayload(io: std.Io, chunks: []const []const u8) error{AutomationCommandFailed}!void {
    var buffer: [4096]u8 = undefined;
    // Streaming, not positional: the default `writer` pwrite()s from offset
    // 0, so consecutive invocations sharing one redirected stdout (e.g. a
    // smoke script's `{ ...; } > log`) would clobber each other's payloads.
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    for (chunks) |chunk| writer.interface.writeAll(chunk) catch return error.AutomationCommandFailed;
    writer.interface.flush() catch return error.AutomationCommandFailed;
}

fn printFile(io: std.Io, name: []const u8) !void {
    var file_path: [256]u8 = undefined;
    const bytes = readFile(std.heap.page_allocator, io, path(&file_path, name)) catch {
        var dir_buffer: [1024]u8 = undefined;
        std.debug.print("error: no app connected — nothing readable at {s}\n", .{automationDirDescription(io, &dir_buffer)});
        return error.AutomationCommandFailed;
    };
    defer std.heap.page_allocator.free(bytes);
    try emitPayload(io, &.{bytes});
}

// -------------------------------------------------- publisher liveness
//
// Dropbox files persist across builds and runs, so "a snapshot exists"
// never means "an app is publishing": an app rebuilt WITHOUT
// -Dautomation happily coexists with days-old files from an earlier
// run, and serving those as live state once cost a full misdiagnosis
// round. Every snapshot the framework writes carries the publisher's
// pid in its header; reads refuse the file loudly when that pid is
// gone (or the header predates the pid stamp).

const Liveness = enum { live, no_pid, dead_publisher };
const WaitPolicy = enum { require_live_publisher, any_publisher };

/// A numeric `<marker><n>` field from the snapshot header. Only accepts
/// the header field, not e.g. widget text echoing it: it must start a
/// line or follow a space.
fn headerField(bytes: []const u8, marker: []const u8) ?u32 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, search, marker)) |index| {
        search = index + marker.len;
        if (index > 0 and bytes[index - 1] != ' ' and bytes[index - 1] != '\n') continue;
        var end = search;
        while (end < bytes.len and std.ascii.isDigit(bytes[end])) end += 1;
        if (end == search) continue;
        return std.fmt.parseUnsigned(u32, bytes[search..end], 10) catch continue;
    }
    return null;
}

/// `publisher_pid=<n>` from the snapshot header, if present.
fn publisherPid(bytes: []const u8) ?u32 {
    return headerField(bytes, "publisher_pid=");
}

/// Like `headerField`, for values that overflow u32 (nanosecond fields).
fn headerField64(bytes: []const u8, marker: []const u8) ?u64 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, search, marker)) |index| {
        search = index + marker.len;
        if (index > 0 and bytes[index - 1] != ' ' and bytes[index - 1] != '\n') continue;
        var end = search;
        while (end < bytes.len and std.ascii.isDigit(bytes[end])) end += 1;
        if (end == search) continue;
        return std.fmt.parseUnsigned(u64, bytes[search..end], 10) catch continue;
    }
    return null;
}

// -------------------------------------------------- stale-instance guard
//
// A LIVE publisher can still be the WRONG app: an instance launched
// before the last rebuild keeps publishing plausible snapshots into the
// same dropbox, and every read then describes yesterday's binary (two
// full misdiagnosis rounds came from exactly this). The snapshot header
// carries `runtime_uptime_ns`, so the publisher's start time is
// `now - uptime`; when the newest binary in zig-out/bin was built AFTER
// the publisher started, the publisher cannot be that binary — warn
// loudly on every snapshot-interpreting verb (never fatal: running an
// older build on purpose is legitimate).
fn warnStaleInstanceIfDetectable(bytes: []const u8, io: std.Io) void {
    const uptime_ns = headerField64(bytes, "runtime_uptime_ns=") orelse return;
    const pid = publisherPid(bytes) orelse return;
    const now_ns: i128 = std.Io.Timestamp.now(io, .real).nanoseconds;
    if (now_ns <= 0) return;
    const started_ns: i128 = now_ns - @as(i128, uptime_ns);
    const newest = newestBinaryInZigOut(io) orelse return;
    // Two seconds of slack absorbs clock steps and the write/stat skew.
    if (newest.mtime_ns > started_ns + 2 * std.time.ns_per_s) {
        std.debug.print(
            "warning: the publishing app (pid {d}) started BEFORE zig-out/bin/{s} was last built -\n" ++
                "         this snapshot comes from an OLDER instance, not the binary you just built;\n" ++
                "         quit that instance (kill {d}) and relaunch, or its state will keep\n" ++
                "         impersonating the new build\n",
            .{ pid, newest.name, pid },
        );
    }
}

const NewestBinary = struct {
    name_storage: [128]u8 = undefined,
    name_len: usize = 0,
    mtime_ns: i128 = 0,

    fn name(self: *const NewestBinary) []const u8 {
        return self.name_storage[0..self.name_len];
    }
};

fn newestBinaryInZigOut(io: std.Io) ?struct { name: []const u8, mtime_ns: i128 } {
    const S = struct {
        var newest: NewestBinary = .{};
    };
    var dir = std.Io.Dir.cwd().openDir(io, "zig-out/bin", .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var found = false;
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        const mtime_ns: i128 = stat.mtime.nanoseconds;
        if (!found or mtime_ns > S.newest.mtime_ns) {
            found = true;
            S.newest.mtime_ns = mtime_ns;
            const len = @min(entry.name.len, S.newest.name_storage.len);
            @memcpy(S.newest.name_storage[0..len], entry.name[0..len]);
            S.newest.name_len = len;
        }
    }
    if (!found) return null;
    return .{ .name = S.newest.name(), .mtime_ns = S.newest.mtime_ns };
}

// ----------------------------------------------------- protocol handshake
//
// A stale `native` binary beside a fresh app (or the reverse) can drive
// the wrong dropbox name, misread the snapshot format, or speak an old
// command vocabulary — and every failure mode is SILENT (a days-old
// snapshot reads as plausible state; a stale binary once cost a whole
// misdiagnosis round).
// Both binaries bake `protocol.version` at their own build time and the
// app stamps its copy into every snapshot header; any read that would
// interpret snapshot state first proves both sides speak the same
// version, and refuses loudly — naming both versions — otherwise.

const ProtocolSkew = union(enum) {
    ok,
    /// The publisher stamps no `protocol=` field: it predates the
    /// handshake (or this CLI is from the future relative to the app).
    missing,
    /// The publisher's version, when it differs from this binary's.
    mismatch: u32,
};

/// `protocol=<n>` from the snapshot header, checked against this
/// binary's own baked-in `protocol.version`.
fn protocolSkew(bytes: []const u8) ProtocolSkew {
    const published = headerField(bytes, "protocol=") orelse return .missing;
    if (published == protocol.version) return .ok;
    return .{ .mismatch = published };
}

fn describeProtocolSkew(skew: ProtocolSkew, io: std.Io) void {
    var dir_buffer: [1024]u8 = undefined;
    const dir = automationDirDescription(io, &dir_buffer);
    switch (skew) {
        .ok => {},
        .mismatch => |published| std.debug.print(
            "error: automation protocol mismatch at {s}/snapshot.txt\n" ++
                "       the running app publishes protocol v{d} but this native binary speaks v{d} -\n" ++
                "       one of them is stale; rebuild the native CLI (zig build) and/or relaunch\n" ++
                "       the freshly built app so both share one protocol (compare `native version`\n" ++
                "       against your framework checkout, and delete stale zig-out binaries)\n",
            .{ dir, published, protocol.version },
        ),
        .missing => std.debug.print(
            "error: the automation snapshot at {s}/snapshot.txt carries no protocol version\n" ++
                "       its publisher predates the protocol handshake, so this native binary\n" ++
                "       (protocol v{d}) may misread it - rebuild and relaunch the app against the\n" ++
                "       current framework; if the app IS current, this native binary is the stale\n" ++
                "       side (an old zig-out copy?) - rebuild it and check `native version`\n",
            .{ dir, protocol.version },
        ),
    }
}

/// Refuse snapshot-interpreting reads when the publisher speaks a
/// different protocol than this binary. Only meaningful on a LIVE
/// publisher — stale files already fail the pid guard first.
fn requireProtocolMatch(bytes: []const u8, io: std.Io) error{AutomationCommandFailed}!void {
    const skew = protocolSkew(bytes);
    if (skew == .ok) return;
    describeProtocolSkew(skew, io);
    return error.AutomationCommandFailed;
}

/// Command-queue guard: sends stay permissive when no snapshot exists
/// yet (the app may still be starting) and when the publisher is dead
/// (the next read screams), but a LIVE publisher on another protocol is
/// a proven binary/dropbox skew.
fn requireCompatibleSnapshotIfPresent(allocator: std.mem.Allocator, io: std.Io) error{AutomationCommandFailed}!void {
    var file_path: [256]u8 = undefined;
    const bytes = readFile(allocator, io, path(&file_path, "snapshot.txt")) catch return;
    defer allocator.free(bytes);
    if (snapshotLiveness(bytes, pidIsAlive) != .live) return;
    try requireProtocolMatch(bytes, io);
    warnStaleInstanceIfDetectable(bytes, io);
}

/// Classify a snapshot's publisher against the live process table via
/// an injectable probe (tests pass their own).
fn snapshotLiveness(bytes: []const u8, alive: *const fn (u32) bool) Liveness {
    const pid = publisherPid(bytes) orelse return .no_pid;
    if (pid == 0) return .no_pid;
    return if (alive(pid)) .live else .dead_publisher;
}

/// True when `pid` names a running process. Signal 0 probes without
/// delivering; EPERM still proves existence. Pid reuse can in principle
/// vouch for the wrong process — accepted, the window is tiny and the
/// failure mode is the pre-#93 status quo. Windows has no cheap probe
/// from here; never false-alarm there.
fn pidIsAlive(pid: u32) bool {
    if (builtin.os.tag == .windows) return true;
    if (pid == 0) return false;
    std.posix.kill(@intCast(pid), @enumFromInt(0)) catch |err| return err == error.PermissionDenied;
    return true;
}

fn describeStaleness(liveness: Liveness, io: std.Io) void {
    var dir_buffer: [1024]u8 = undefined;
    const dir = automationDirDescription(io, &dir_buffer);
    switch (liveness) {
        .live => {},
        .dead_publisher => std.debug.print(
            "error: stale automation snapshot at {s}/snapshot.txt\n" ++
                "       its publisher is no longer running, so the file is left over from an\n" ++
                "       earlier run - relaunch the app built with -Dautomation=true (a live\n" ++
                "       publisher rewrites the snapshot with its own pid on every presented frame)\n",
            .{dir},
        ),
        .no_pid => std.debug.print(
            "error: stale automation snapshot at {s}/snapshot.txt\n" ++
                "       it carries no publisher_pid, so it predates the current publisher -\n" ++
                "       rebuild and relaunch the app with -Dautomation=true\n",
            .{dir},
        ),
    }
}

/// Refuse a read command outright when the dropbox's snapshot has no
/// live publisher. A missing snapshot falls through: the caller's own
/// no-app error (which names the directory) stays the message for that.
fn requireLiveSnapshotFile(allocator: std.mem.Allocator, io: std.Io) !void {
    var file_path: [256]u8 = undefined;
    const bytes = readFile(allocator, io, path(&file_path, "snapshot.txt")) catch return;
    defer allocator.free(bytes);
    const liveness = snapshotLiveness(bytes, pidIsAlive);
    if (liveness == .live) {
        try requireProtocolMatch(bytes, io);
        warnStaleInstanceIfDetectable(bytes, io);
        return;
    }
    describeStaleness(liveness, io);
    return error.AutomationCommandFailed;
}

fn waitForFile(allocator: std.mem.Allocator, io: std.Io, name: []const u8, marker: []const u8, policy: WaitPolicy) !void {
    // 30s to match the assert default: `wait` gates on a cold app start,
    // and a GTK/software-EGL launch on a loaded shared CI runner routinely
    // needs more than the 5s this used to allow.
    var last_liveness: Liveness = .live;
    var saw_file = false;
    var attempts: usize = 0;
    while (attempts < 300) : (attempts += 1) {
        var file_path: [256]u8 = undefined;
        const bytes = readFile(allocator, io, path(&file_path, name)) catch {
            try std.Io.sleep(io, std.Io.Duration.fromNanoseconds(100 * std.time.ns_per_ms), .awake);
            continue;
        };
        saw_file = true;
        if (marker.len == 0 or std.mem.indexOf(u8, bytes, marker) != null) {
            // A marker match in a stale file is yesterday's app looking
            // ready; keep polling for a live publisher instead.
            last_liveness = if (policy == .require_live_publisher) snapshotLiveness(bytes, pidIsAlive) else .live;
            if (last_liveness == .live) {
                defer allocator.free(bytes);
                // A LIVE publisher speaking the wrong protocol never gets
                // better by polling: fail fast, naming both versions.
                if (policy == .require_live_publisher) try requireProtocolMatch(bytes, io);
                warnStaleInstanceIfDetectable(bytes, io);
                return emitPayload(io, &.{bytes});
            }
        }
        allocator.free(bytes);
        try std.Io.sleep(io, std.Io.Duration.fromNanoseconds(100 * std.time.ns_per_ms), .awake);
    }
    if (!saw_file) {
        // The common cold-start miss: nothing was ever published here.
        // Name the two usual causes instead of a bare timeout — the app
        // was not built with -Dautomation=true, or this is the wrong cwd.
        var dir_buffer: [1024]u8 = undefined;
        std.debug.print(
            "error: timed out waiting for automation - no {s} ever appeared at {s}\n" ++
                "       (the app publishes it on every presented frame when built with\n" ++
                "        -Dautomation=true; check the app is running, that it was built with\n" ++
                "        -Dautomation=true, and that you run this from the app's directory)\n",
            .{ name, automationDirDescription(io, &dir_buffer) },
        );
        return error.AutomationCommandFailed;
    }
    describeStaleness(last_liveness, io);
    return fail("timed out waiting for automation");
}

fn waitForScreenshot(io: std.Io, name: []const u8) !void {
    // Screenshots are published atomically (write + rename), so existence
    // means the PNG is complete. Reference rendering large surfaces takes a
    // moment, so poll longer than text artifacts.
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        var file_path: [256]u8 = undefined;
        const screenshot_path = path(&file_path, name);
        if (std.Io.Dir.cwd().openFile(io, screenshot_path, .{})) |opened| {
            var file = opened;
            file.close(io);
            return emitPayload(io, &.{ screenshot_path, "\n" });
        } else |_| {}
        try std.Io.sleep(io, std.Io.Duration.fromNanoseconds(100 * std.time.ns_per_ms), .awake);
    }
    return fail("timed out waiting for screenshot");
}

fn deleteAutomationFile(io: std.Io, name: []const u8) void {
    var file_path: [256]u8 = undefined;
    std.Io.Dir.cwd().deleteFile(io, path(&file_path, name)) catch {};
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
}

fn path(buffer: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ automation_dir, name }) catch unreachable;
}

fn fail(message: []const u8) error{AutomationCommandFailed} {
    std.debug.print("error: {s}\n", .{message});
    return error.AutomationCommandFailed;
}

// ---------------------------------------------------------------- assert

const assert_poll_interval_ms = 100;
const assert_default_timeout_ms: u32 = 30_000;
const assert_tail_lines = 20;
const assert_max_patterns = 32;

const AssertSpec = struct {
    patterns: []const []const u8,
    absent: bool = false,
    timeout_ms: u32 = assert_default_timeout_ms,
};

const AssertParseError = error{
    MissingFlagValue,
    InvalidTimeout,
    NoPatterns,
    TooManyPatterns,
};

/// `assert [--absent] [--timeout-ms N] <pattern>...` — flags may appear
/// anywhere; everything else is a pattern. `patterns_buffer` holds the
/// positional slices, so no allocation happens here.
fn parseAssertArgs(args: []const []const u8, patterns_buffer: [][]const u8) AssertParseError!AssertSpec {
    var spec: AssertSpec = .{ .patterns = &.{} };
    var count: usize = 0;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--absent")) {
            spec.absent = true;
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            index += 1;
            if (index >= args.len) return error.MissingFlagValue;
            spec.timeout_ms = std.fmt.parseUnsigned(u32, args[index], 10) catch return error.InvalidTimeout;
        } else {
            if (count >= patterns_buffer.len) return error.TooManyPatterns;
            patterns_buffer[count] = arg;
            count += 1;
        }
    }
    if (count == 0) return error.NoPatterns;
    spec.patterns = patterns_buffer[0..count];
    return spec;
}

fn runAssert(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var patterns_buffer: [assert_max_patterns][]const u8 = undefined;
    const spec = parseAssertArgs(args, &patterns_buffer) catch |err| switch (err) {
        error.NoPatterns => return fail("assert needs at least one pattern (see: native automate)"),
        error.MissingFlagValue => return fail("--timeout-ms requires a value in milliseconds"),
        error.InvalidTimeout => return fail("--timeout-ms value must be a positive integer"),
        error.TooManyPatterns => return fail("too many assert patterns (max 32)"),
    };
    for (spec.patterns) |pattern| {
        validatePattern(pattern) catch {
            std.debug.print("error: invalid pattern: {s}\n", .{pattern});
            std.debug.print("       (supported: literals, . * + ? ^ $ [...] and \\d \\w \\s escapes)\n", .{});
            return error.AutomationCommandFailed;
        };
    }

    var elapsed_ms: u64 = 0;
    var snapshot: ?[]u8 = null;
    defer if (snapshot) |bytes| allocator.free(bytes);
    while (true) {
        if (snapshot) |bytes| {
            allocator.free(bytes);
            snapshot = null;
        }
        var file_path: [256]u8 = undefined;
        snapshot = readFile(allocator, io, path(&file_path, "snapshot.txt")) catch null;
        if (snapshot) |bytes| {
            // A live publisher on the wrong protocol can neither satisfy
            // nor refute assertions, and polling never fixes it.
            if (snapshotLiveness(bytes, pidIsAlive) == .live) try requireProtocolMatch(bytes, io);
            // A stale dropbox (dead or pid-less publisher) can neither
            // satisfy nor refute assertions — keep polling for live state.
            if (snapshotLiveness(bytes, pidIsAlive) == .live and assertSatisfied(bytes, spec.patterns, spec.absent)) {
                warnStaleInstanceIfDetectable(bytes, io);
                std.debug.print("assert ok: {d} pattern(s) {s} after {d}ms\n", .{
                    spec.patterns.len,
                    if (spec.absent) "absent" else "matched",
                    elapsed_ms,
                });
                return;
            }
        }
        if (elapsed_ms >= spec.timeout_ms) break;
        try std.Io.sleep(io, std.Io.Duration.fromNanoseconds(assert_poll_interval_ms * std.time.ns_per_ms), .awake);
        elapsed_ms += assert_poll_interval_ms;
    }

    // Timed out: name every unsatisfied pattern, then show where we looked
    // and the snapshot tail so CI logs carry the evidence.
    std.debug.print("error: automate assert failed after {d}ms\n", .{spec.timeout_ms});
    if (snapshot) |bytes| {
        const liveness = snapshotLiveness(bytes, pidIsAlive);
        if (liveness != .live) {
            describeStaleness(liveness, io);
            return error.AutomationCommandFailed;
        }
        for (spec.patterns) |pattern| {
            const matched = matchesPattern(pattern, bytes) catch false;
            if (spec.absent and matched) {
                std.debug.print("  still present: {s}\n", .{pattern});
            } else if (!spec.absent and !matched) {
                std.debug.print("  missing: {s}\n", .{pattern});
            }
        }
        const tail = textTail(bytes, assert_tail_lines);
        std.debug.print("--- snapshot.txt tail (last {d} lines) ---\n{s}", .{ assert_tail_lines, tail });
        if (tail.len == 0 or tail[tail.len - 1] != '\n') std.debug.print("\n", .{});
    } else {
        var dir_buffer: [1024]u8 = undefined;
        std.debug.print(
            "  no snapshot at {s}\n" ++
                "  (the app creates it on launch when built with -Dautomation=true;\n" ++
                "   run this command from the app project's working directory)\n",
            .{automationDirDescription(io, &dir_buffer)},
        );
    }
    return error.AutomationCommandFailed;
}

/// All patterns must match (or, with `absent`, none may match).
fn assertSatisfied(text: []const u8, patterns: []const []const u8, absent: bool) bool {
    for (patterns) |pattern| {
        const matched = matchesPattern(pattern, text) catch return false;
        if (matched == absent) return false;
    }
    return true;
}

/// The last `max_lines` lines of `text` (for failure output).
fn textTail(text: []const u8, max_lines: usize) []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    if (trimmed.len == 0) return text[0..0];
    var lines: usize = 0;
    var index = trimmed.len;
    while (index > 0) {
        index -= 1;
        if (trimmed[index] == '\n') {
            lines += 1;
            if (lines == max_lines) return text[index + 1 ..];
        }
    }
    return text;
}

// ------------------------------------------------------- pattern matching
//
// A small grep-style regex subset, so CI assertions do not need a shell
// pipeline: literals, `.` (any char but newline), postfix `*` `+` `?`,
// line anchors `^` and `$`, character classes `[abc]` / `[^a-z0-9]`, and
// the escapes `\d \D \w \W \s \S` plus escaped metacharacters (`\.`).
// No groups or alternation — assert takes multiple patterns instead.

const PatternError = error{InvalidPattern};

/// True when `pattern` matches anywhere in `text`.
fn matchesPattern(pattern: []const u8, text: []const u8) PatternError!bool {
    try validatePattern(pattern);
    var start: usize = 0;
    while (true) {
        if (matchHere(pattern, 0, text, start)) return true;
        if (start >= text.len) return false;
        start += 1;
    }
}

fn validatePattern(pattern: []const u8) PatternError!void {
    var index: usize = 0;
    var last_atom = false;
    while (index < pattern.len) {
        const ch = pattern[index];
        switch (ch) {
            '*', '+', '?' => {
                if (!last_atom) return error.InvalidPattern;
                last_atom = false;
                index += 1;
            },
            '^', '$' => {
                last_atom = false;
                index += 1;
            },
            else => {
                index = try atomEnd(pattern, index);
                last_atom = true;
            },
        }
    }
}

/// End index (exclusive) of the atom starting at `index`.
fn atomEnd(pattern: []const u8, index: usize) PatternError!usize {
    switch (pattern[index]) {
        '\\' => {
            if (index + 1 >= pattern.len) return error.InvalidPattern;
            return index + 2;
        },
        '[' => {
            var end = index + 1;
            if (end < pattern.len and pattern[end] == '^') end += 1;
            // A `]` directly after `[` or `[^` is a literal member.
            if (end < pattern.len and pattern[end] == ']') end += 1;
            while (end < pattern.len and pattern[end] != ']') {
                end += if (pattern[end] == '\\') @as(usize, 2) else 1;
            }
            if (end >= pattern.len) return error.InvalidPattern;
            return end + 1;
        },
        else => return index + 1,
    }
}

fn matchHere(pattern: []const u8, p: usize, text: []const u8, t: usize) bool {
    if (p >= pattern.len) return true;
    switch (pattern[p]) {
        '^' => {
            if (t == 0 or text[t - 1] == '\n') return matchHere(pattern, p + 1, text, t);
            return false;
        },
        '$' => {
            if (t == text.len or text[t] == '\n') return matchHere(pattern, p + 1, text, t);
            return false;
        },
        else => {},
    }
    const end = atomEnd(pattern, p) catch return false;
    const quantifier: u8 = if (end < pattern.len) pattern[end] else 0;
    switch (quantifier) {
        '*' => return matchRepeat(pattern, p, end, end + 1, text, t, 0),
        '+' => return matchRepeat(pattern, p, end, end + 1, text, t, 1),
        '?' => {
            if (t < text.len and atomMatches(pattern[p..end], text[t])) {
                if (matchHere(pattern, end + 1, text, t + 1)) return true;
            }
            return matchHere(pattern, end + 1, text, t);
        },
        else => {
            if (t < text.len and atomMatches(pattern[p..end], text[t])) {
                return matchHere(pattern, end, text, t + 1);
            }
            return false;
        },
    }
}

/// Greedy repetition with backtracking: consume as many atom matches as
/// possible, then retreat until the rest of the pattern matches.
fn matchRepeat(pattern: []const u8, atom_start: usize, atom_stop: usize, rest: usize, text: []const u8, t: usize, min: usize) bool {
    const atom = pattern[atom_start..atom_stop];
    var count: usize = 0;
    while (t + count < text.len and atomMatches(atom, text[t + count])) count += 1;
    while (true) {
        if (count >= min and matchHere(pattern, rest, text, t + count)) return true;
        if (count == 0) return false;
        count -= 1;
        if (count < min) return false;
    }
}

fn atomMatches(atom: []const u8, ch: u8) bool {
    if (atom.len == 1) {
        return switch (atom[0]) {
            '.' => ch != '\n',
            else => atom[0] == ch,
        };
    }
    if (atom[0] == '\\') return escapeMatches(atom[1], ch);
    if (atom[0] == '[') return classMatches(atom[1 .. atom.len - 1], ch);
    return false;
}

fn escapeMatches(escape: u8, ch: u8) bool {
    return switch (escape) {
        'd' => std.ascii.isDigit(ch),
        'D' => !std.ascii.isDigit(ch),
        'w' => std.ascii.isAlphanumeric(ch) or ch == '_',
        'W' => !(std.ascii.isAlphanumeric(ch) or ch == '_'),
        's' => std.ascii.isWhitespace(ch),
        'S' => !std.ascii.isWhitespace(ch),
        'n' => ch == '\n',
        't' => ch == '\t',
        else => escape == ch,
    };
}

/// `body` is the class content without brackets; supports leading `^`,
/// ranges (`a-z`), `\`-escapes, and a literal `]` as the first member.
fn classMatches(body: []const u8, ch: u8) bool {
    var negate = false;
    var index: usize = 0;
    if (index < body.len and body[index] == '^') {
        negate = true;
        index += 1;
    }
    var found = false;
    while (index < body.len) {
        const low: u8 = body[index];
        if (low == '\\' and index + 1 < body.len) {
            index += 1;
            if (escapeMatches(body[index], ch)) found = true;
            index += 1;
            continue;
        }
        index += 1;
        if (index + 1 < body.len and body[index] == '-') {
            const high = body[index + 1];
            if (ch >= low and ch <= high) found = true;
            index += 2;
        } else if (low == ch) {
            found = true;
        }
    }
    return found != negate;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "matchesPattern: literals and metacharacters" {
    try testing.expect(try matchesPattern("ready=true", "app foo\nready=true\n"));
    try testing.expect(!try matchesPattern("ready=true", "ready=false\n"));
    try testing.expect(try matchesPattern("count: \\d+", "status count: 42 open"));
    try testing.expect(!try matchesPattern("count: \\d+", "status count: none"));
    try testing.expect(try matchesPattern("role=button name=\"Reset\"", "widget #3 role=button name=\"Reset\"\n"));
    try testing.expect(try matchesPattern("gpu_.*=true", "gpu_nonblank=true"));
    try testing.expect(try matchesPattern("a.c", "abc"));
    try testing.expect(!try matchesPattern("a.c", "a\nc"));
}

test "matchesPattern: quantifiers backtrack" {
    try testing.expect(try matchesPattern("wo*rld", "wrld"));
    try testing.expect(try matchesPattern("wo+rld", "wooorld"));
    try testing.expect(!try matchesPattern("wo+rld", "wrld"));
    try testing.expect(try matchesPattern("colou?r", "color"));
    try testing.expect(try matchesPattern("colou?r", "colour"));
    try testing.expect(try matchesPattern("a.*b", "a x b y b"));
    try testing.expect(try matchesPattern(".*=true$", "gpu_nonblank=true"));
}

test "matchesPattern: line anchors work mid-file" {
    const snapshot = "app demo\nready=true dispatch_errors=0\nwindow main\n";
    try testing.expect(try matchesPattern("^ready=true", snapshot));
    try testing.expect(try matchesPattern("^window main$", snapshot));
    try testing.expect(!try matchesPattern("^main$", snapshot));
    try testing.expect(try matchesPattern("dispatch_errors=0$", snapshot));
}

test "matchesPattern: character classes" {
    try testing.expect(try matchesPattern("[0-9]+ open", "inbox 4 open"));
    try testing.expect(try matchesPattern("[a-z_]+=true", "gpu_nonblank=true"));
    try testing.expect(try matchesPattern("[^a]bc", "xbc"));
    try testing.expect(!try matchesPattern("[^a]bc", "abc"));
    try testing.expect(try matchesPattern("[]x]", "]"));
}

test "matchesPattern: invalid patterns are rejected" {
    try testing.expectError(error.InvalidPattern, matchesPattern("*x", "anything"));
    try testing.expectError(error.InvalidPattern, matchesPattern("a\\", "anything"));
    try testing.expectError(error.InvalidPattern, matchesPattern("[abc", "anything"));
    try testing.expectError(error.InvalidPattern, matchesPattern("^*", "anything"));
}

test "assertSatisfied: present and absent modes" {
    const snapshot = "ready=true\ngpu_nonblank=true\nwidget role=button name=\"Reset\"\n";
    const present = [_][]const u8{ "ready=true", "gpu_nonblank=true", "name=\"Reset\"" };
    try testing.expect(assertSatisfied(snapshot, &present, false));
    const with_missing = [_][]const u8{ "ready=true", "name=\"Delete\"" };
    try testing.expect(!assertSatisfied(snapshot, &with_missing, false));
    const gone = [_][]const u8{ "error event=", "panicked" };
    try testing.expect(assertSatisfied(snapshot, &gone, true));
    const still_there = [_][]const u8{"gpu_nonblank=true"};
    try testing.expect(!assertSatisfied(snapshot, &still_there, true));
}

test "parseAssertArgs: flags and patterns in any order" {
    var buffer: [assert_max_patterns][]const u8 = undefined;

    const plain = try parseAssertArgs(&.{ "ready=true", "count: 0" }, &buffer);
    try testing.expectEqual(@as(usize, 2), plain.patterns.len);
    try testing.expect(!plain.absent);
    try testing.expectEqual(assert_default_timeout_ms, plain.timeout_ms);

    const flagged = try parseAssertArgs(&.{ "--absent", "error event=", "--timeout-ms", "5000" }, &buffer);
    try testing.expect(flagged.absent);
    try testing.expectEqual(@as(u32, 5000), flagged.timeout_ms);
    try testing.expectEqualStrings("error event=", flagged.patterns[0]);

    try testing.expectError(error.NoPatterns, parseAssertArgs(&.{"--absent"}, &buffer));
    try testing.expectError(error.MissingFlagValue, parseAssertArgs(&.{ "x", "--timeout-ms" }, &buffer));
    try testing.expectError(error.InvalidTimeout, parseAssertArgs(&.{ "x", "--timeout-ms", "soon" }, &buffer));
}

fn alwaysAlive(pid: u32) bool {
    _ = pid;
    return true;
}

fn neverAlive(pid: u32) bool {
    _ = pid;
    return false;
}

test "publisherPid parses the header field only" {
    try testing.expectEqual(@as(?u32, 4242), publisherPid("ready=true frame=3 publisher_pid=4242\nwindow @w1\n"));
    try testing.expectEqual(@as(?u32, 7), publisherPid("publisher_pid=7\n"));
    // Pre-#93 snapshots carry no pid at all.
    try testing.expectEqual(@as(?u32, null), publisherPid("ready=true frame=3 runtime_uptime_ns=42\n"));
    // Widget text echoing the token mid-word is not the header field.
    try testing.expectEqual(@as(?u32, null), publisherPid("name=\"xpublisher_pid=9\""));
    try testing.expectEqual(@as(?u32, 9), publisherPid("text a\nname x publisher_pid=9\n"));
    try testing.expectEqual(@as(?u32, null), publisherPid("publisher_pid=abc\n"));
}

test "protocolSkew matches this binary's version and names the skew" {
    var ok_buffer: [64]u8 = undefined;
    const ok_snapshot = try std.fmt.bufPrint(&ok_buffer, "ready=true protocol={d} publisher_pid=4242\n", .{protocol.version});
    try testing.expectEqual(ProtocolSkew.ok, protocolSkew(ok_snapshot));

    var skewed_buffer: [64]u8 = undefined;
    const skewed_snapshot = try std.fmt.bufPrint(&skewed_buffer, "ready=true protocol={d} publisher_pid=4242\n", .{protocol.version + 1});
    try testing.expectEqual(ProtocolSkew{ .mismatch = protocol.version + 1 }, protocolSkew(skewed_snapshot));

    // Pre-handshake publishers stamp no protocol field at all.
    try testing.expectEqual(ProtocolSkew.missing, protocolSkew("ready=true frame=3 publisher_pid=4242\n"));
    // Widget text echoing the token mid-word is not the header field.
    try testing.expectEqual(ProtocolSkew.missing, protocolSkew("name=\"xprotocol=9\"\n"));
}

test "snapshotLiveness classifies both directions" {
    const live_snapshot = "ready=true publisher_pid=4242\n";
    try testing.expectEqual(Liveness.live, snapshotLiveness(live_snapshot, alwaysAlive));
    try testing.expectEqual(Liveness.dead_publisher, snapshotLiveness(live_snapshot, neverAlive));
    try testing.expectEqual(Liveness.no_pid, snapshotLiveness("ready=true frame=3\n", alwaysAlive));
    // pid 0 means the platform could not stamp one — unverifiable is stale.
    try testing.expectEqual(Liveness.no_pid, snapshotLiveness("ready=true publisher_pid=0\n", alwaysAlive));
}

test "pidIsAlive: own process is alive, pid 0 is not" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    const own: u32 = @intCast(@max(0, std.posix.system.getpid()));
    try testing.expect(pidIsAlive(own));
    try testing.expect(!pidIsAlive(0));
}

test "textTail keeps the last lines only" {
    try testing.expectEqualStrings("", textTail("", 3));
    try testing.expectEqualStrings("a\nb\n", textTail("a\nb\n", 3));
    try testing.expectEqualStrings("c\nd\ne\n", textTail("a\nb\nc\nd\ne\n", 3));
    try testing.expectEqualStrings("d\ne", textTail("c\nd\ne", 2));
}

/// Pid-suffixed scratch dropbox: these tests are compiled into more than
/// one test binary and the aggregate build step runs those binaries in
/// parallel, so a fixed path would let two copies race each other.
fn queueTestDirectory(buffer: []u8, comptime prefix: []const u8) ![]const u8 {
    const pid: u32 = switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .wasi, .freestanding, .emscripten => 0,
        else => @intCast(@max(0, std.posix.system.getpid())),
    };
    return std.fmt.bufPrint(buffer, prefix ++ "-{d}", .{pid});
}

test "scanQueue counts only queue entries and picks max-present + 1" {
    var dir_buffer: [64]u8 = undefined;
    const directory = try queueTestDirectory(&dir_buffer, ".zig-cache/test-native-cli-queue-scan");
    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(testing.io, directory) catch {};
    try cwd.createDirPath(testing.io, directory);
    defer cwd.deleteTree(testing.io, directory) catch {};

    // Empty queue: nothing pending, sequences start at 1.
    try testing.expectEqual(@as(usize, 0), scanQueue(testing.io, directory).pending);
    try testing.expectEqual(@as(u64, 1), scanQueue(testing.io, directory).next_sequence);

    // Gapped entries count; snapshots, response artifacts, and a
    // retired-v5 writer's `command.txt` slot are invisible to the queue.
    var path_buffer: [128]u8 = undefined;
    for ([_][]const u8{ "command-2.txt", "command-5.txt", "command.txt", "snapshot.txt" }) |name| {
        try cwd.writeFile(testing.io, .{
            .sub_path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ directory, name }),
            .data = "menu-command app.probe\n",
        });
    }
    const state = scanQueue(testing.io, directory);
    try testing.expectEqual(@as(usize, 2), state.pending);
    try testing.expectEqual(@as(u64, 6), state.next_sequence);
}

test "enqueueCommand claims the next sequence exclusively and refuses a full queue loudly" {
    var dir_buffer: [64]u8 = undefined;
    const directory = try queueTestDirectory(&dir_buffer, ".zig-cache/test-native-cli-queue-claim");
    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(testing.io, directory) catch {};
    try cwd.createDirPath(testing.io, directory);
    defer cwd.deleteTree(testing.io, directory) catch {};

    // Claim into a queue that already holds an entry: the new command
    // lands BEHIND it (higher sequence), preserving arrival order.
    var path_buffer: [128]u8 = undefined;
    try cwd.writeFile(testing.io, .{
        .sub_path = try std.fmt.bufPrint(&path_buffer, "{s}/command-3.txt", .{directory}),
        .data = "menu-command app.earlier\n",
    });
    var name_buffer: [64]u8 = undefined;
    const name = try enqueueCommand(testing.io, directory, "menu-command app.later\n", &name_buffer, queue_attempt_budget);
    try testing.expectEqualStrings("command-4.txt", name);
    var content_buffer: [64]u8 = undefined;
    var file = try cwd.openFile(testing.io, try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ directory, name }), .{});
    const content_len = try file.readPositionalAll(testing.io, &content_buffer, 0);
    file.close(testing.io);
    try testing.expectEqualStrings("menu-command app.later\n", content_buffer[0..content_len]);

    // The overflow pin: fill the queue to its bound and the writer
    // refuses (after its retry budget — 1 here so the test never really
    // waits) instead of overwriting or silently dropping anything.
    var sequence: u64 = 5;
    while (scanQueue(testing.io, directory).pending < protocol.max_queued_commands) : (sequence += 1) {
        try cwd.writeFile(testing.io, .{
            .sub_path = try std.fmt.bufPrint(&path_buffer, "{s}/command-{d}.txt", .{ directory, sequence }),
            .data = "menu-command app.filler\n",
        });
    }
    try testing.expectError(
        error.QueueStayedFull,
        enqueueCommand(testing.io, directory, "menu-command app.overflow\n", &name_buffer, 1),
    );
    // Nothing pending was disturbed by the refusal.
    try testing.expectEqual(protocol.max_queued_commands, scanQueue(testing.io, directory).pending);

    // Draining one entry frees a slot and the very next claim succeeds.
    try cwd.deleteFile(testing.io, try std.fmt.bufPrint(&path_buffer, "{s}/command-3.txt", .{directory}));
    const freed = try enqueueCommand(testing.io, directory, "menu-command app.freed\n", &name_buffer, queue_attempt_budget);
    try testing.expect(protocol.queueFileSequence(freed) != null);
}

test "awaitCommandConsumed returns on deletion and fails loudly on a stuck entry" {
    var dir_buffer: [64]u8 = undefined;
    const directory = try queueTestDirectory(&dir_buffer, ".zig-cache/test-native-cli-queue-consume");
    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(testing.io, directory) catch {};
    try cwd.createDirPath(testing.io, directory);
    defer cwd.deleteTree(testing.io, directory) catch {};

    // An entry the app already deleted (or that never existed — the
    // dropbox owner swept it) reads as consumed.
    try awaitCommandConsumed(testing.io, directory, "command-1.txt", 1);

    // An entry the app never touches fails once the budget is spent —
    // the CLI's honest signal that the command did NOT dispatch.
    var path_buffer: [128]u8 = undefined;
    try cwd.writeFile(testing.io, .{
        .sub_path = try std.fmt.bufPrint(&path_buffer, "{s}/command-2.txt", .{directory}),
        .data = "menu-command app.stuck\n",
    });
    try testing.expectError(
        error.NeverConsumed,
        awaitCommandConsumed(testing.io, directory, "command-2.txt", 1),
    );
}
