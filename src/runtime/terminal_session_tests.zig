//! Terminal session store tests: the runtime-owned emulator behind a
//! bound pty key — snapshot publication through the lookup seam, the
//! journaled write-back path (key encoding, committed text, query
//! answers), layout-driven resize, the scrollback source-wins echo, and
//! the respawn reset. Every input arrives the way the runtime delivers
//! it (tap events, reconcile calls), so these are the element contract's
//! tests, not emulator internals'. Skipped wholesale when the
//! `terminal_vt` seam carries the stub.

const std = @import("std");
const builtin = @import("builtin");
const canvas = @import("canvas");
const effects = @import("effects.zig");
const terminal_session = @import("terminal_session.zig");

const testing = std.testing;
const TerminalSessions = terminal_session.TerminalSessions;

const TestGateway = struct {
    gpa: std.mem.Allocator,
    written: std.ArrayList(u8) = .empty,
    resized: ?struct { cols: u16, rows: u16 } = null,
    resize_count: usize = 0,
    accept: bool = true,

    fn deinit(self: *TestGateway) void {
        self.written.deinit(self.gpa);
    }

    fn writeFn(context: *anyopaque, key: u64, bytes: []const u8) bool {
        const self: *TestGateway = @ptrCast(@alignCast(context));
        _ = key;
        if (!self.accept) return false;
        self.written.appendSlice(self.gpa, bytes) catch return false;
        return true;
    }

    fn resizeFn(context: *anyopaque, key: u64, cols: u16, rows: u16) void {
        const self: *TestGateway = @ptrCast(@alignCast(context));
        _ = key;
        self.resized = .{ .cols = cols, .rows = rows };
        self.resize_count += 1;
    }

    fn gateway(self: *TestGateway) terminal_session.PtyGateway {
        return .{ .context = @ptrCast(self), .write = writeFn, .resize = resizeFn };
    }
};

/// Resolve the published grid the way finalize does: through the
/// installed lookup, creating the session on first sight of the key.
fn resolveGrid(store: *TerminalSessions, pty: u64) ?*const canvas.TerminalGrid {
    const lookup = store.lookup() orelse return null;
    return lookup.resolve(lookup.context, pty);
}

fn feedOutput(store: *TerminalSessions, pty: u64, bytes: []const u8) void {
    const event: effects.EffectPtyEvent = .{ .key = pty, .kind = .output, .bytes = bytes };
    store.notePtyEvent(&event);
}

fn feedExit(store: *TerminalSessions, pty: u64) void {
    const event: effects.EffectPtyEvent = .{ .key = pty, .kind = .exit, .code = 0 };
    store.notePtyEvent(&event);
}

fn gridText(grid: *const canvas.TerminalGrid) []const u8 {
    return grid.screen_text;
}

test "binding a pty key publishes a live grid that carries fed output as real cells" {
    if (comptime !terminal_session.enabled) return error.SkipZigTest;
    var store = TerminalSessions.init(testing.allocator);
    defer store.deinit();
    store.beginBuild(.{});

    // First resolve creates the session (binding IS the request); the
    // fresh grid is a running, empty surface.
    const grid = resolveGrid(&store, 7) orelse return error.TestExpectedGrid;
    try testing.expect(grid.running);

    feedOutput(&store, 7, "hello \x1b[1;31mworld\x1b[0m\r\n$ ");
    const refreshed = resolveGrid(&store, 7) orelse return error.TestExpectedGrid;
    try testing.expect(std.mem.indexOf(u8, gridText(refreshed), "hello world") != null);
    try testing.expect(std.mem.indexOf(u8, gridText(refreshed), "$") != null);
    // The snapshot's rows carry resolved cells: find the 'h' at 0,0.
    try testing.expect(refreshed.rows.len > 0);
    try testing.expectEqual(@as(u21, 'h'), refreshed.rows[0].cells[0].cp);
    try testing.expectEqualStrings("h", refreshed.rows[0].cells[0].cluster);
    // A default (untouched) ANSI-31 red resolves through the theme's
    // destructive token, the palette-honesty story.
    const tokens: canvas.DesignTokens = .{};
    const red_cell = refreshed.rows[0].cells[6];
    try testing.expectEqual(@as(u21, 'w'), red_cell.cp);
    try testing.expectApproxEqAbs(tokens.colors.destructive.r, red_cell.fg.r, 0.2);
}

test "pointer gestures select terminal cells words and lines for clipboard copy" {
    if (comptime !terminal_session.enabled) return error.SkipZigTest;
    var store = TerminalSessions.init(testing.allocator);
    defer store.deinit();
    var gw = TestGateway{ .gpa = testing.allocator };
    defer gw.deinit();
    store.setGateway(gw.gateway());
    store.beginBuild(.{});
    _ = store.reconcile(8, 0, 20, 4) orelse return error.TestExpectedState;
    feedOutput(&store, 8, "alpha beta\r\ngamma delta");
    _ = resolveGrid(&store, 8) orelse return error.TestExpectedGrid;

    // Default tokens resolve to 8x18 cells. A primary drag from the
    // first cell through the fifth selects "alpha".
    _ = store.pointerSelection(8, .{
        .phase = .down,
        .x = 2,
        .y = 5,
        .width = 160,
        .height = 72,
    });
    const drag = store.pointerSelection(8, .{
        .phase = .move,
        .x = 39,
        .y = 5,
        .width = 160,
        .height = 72,
    });
    try testing.expect(drag.changed);
    try testing.expect(drag.selection_active);
    const release = store.pointerSelection(8, .{
        .phase = .up,
        .x = 39,
        .y = 5,
        .width = 160,
        .height = 72,
    });
    try testing.expect(release.selection_active);
    var grid = resolveGrid(&store, 8) orelse return error.TestExpectedGrid;
    try testing.expectEqualStrings("alpha", grid.selection_text);
    try testing.expectEqualDeep(@as(?[2]u16, .{ 0, 4 }), grid.rows[0].selection);

    // The runtime's journaled click count chooses Ghostty's standard
    // word and line behaviors without a second click clock.
    _ = store.pointerSelection(8, .{
        .phase = .down,
        .x = 60,
        .y = 5,
        .width = 160,
        .height = 72,
        .click_count = 2,
    });
    grid = resolveGrid(&store, 8) orelse return error.TestExpectedGrid;
    try testing.expectEqualStrings("beta", grid.selection_text);

    _ = store.pointerSelection(8, .{
        .phase = .down,
        .x = 18,
        .y = 5,
        .width = 160,
        .height = 72,
        .click_count = 3,
    });
    grid = resolveGrid(&store, 8) orelse return error.TestExpectedGrid;
    try testing.expectEqualStrings("alpha beta", grid.selection_text);

    // Input sent to the child dismisses the live selection. Cmd/Ctrl+C
    // is intercepted by the app loop before it reaches this path.
    try testing.expect(store.textInput(8, "x"));
    grid = resolveGrid(&store, 8) orelse return error.TestExpectedGrid;
    try testing.expect(!grid.selection_active);
    try testing.expectEqualStrings("", grid.selection_text);
}

test "committed text and encoded keys reach the pty through the gateway in stdin order" {
    if (comptime !terminal_session.enabled) return error.SkipZigTest;
    var store = TerminalSessions.init(testing.allocator);
    defer store.deinit();
    var gw = TestGateway{ .gpa = testing.allocator };
    defer gw.deinit();
    store.setGateway(gw.gateway());
    store.beginBuild(.{});
    _ = resolveGrid(&store, 3) orelse return error.TestExpectedGrid;

    try testing.expect(store.textInput(3, "ls"));
    try testing.expect(store.keyEvent(3, .{ .phase = .key_down, .key = "enter" }));
    try testing.expectEqualStrings("ls\r", gw.written.items);

    // Ctrl+C encodes the C0 interrupt byte, never a literal 'c'.
    gw.written.clearRetainingCapacity();
    try testing.expect(store.keyEvent(3, .{
        .phase = .key_down,
        .key = "c",
        .modifiers = .{ .control = true },
    }));
    try testing.expectEqualStrings("\x03", gw.written.items);

    // A plain printable key_down is consumed silently (its press
    // travels the committed-text channel) — nothing doubles.
    gw.written.clearRetainingCapacity();
    try testing.expect(store.keyEvent(3, .{ .phase = .key_down, .key = "a" }));
    try testing.expectEqualStrings("", gw.written.items);

    if (comptime builtin.os.tag == .macos) {
        // Natural text navigation follows macOS terminal conventions:
        // Option moves by words and Command moves to line boundaries.
        // These bindings intentionally remain legacy bytes after a TUI
        // enables kitty reporting, and their releases stay consumed.
        feedOutput(&store, 3, "\x1b[>11u");
        try testing.expect(store.keyEvent(3, .{
            .phase = .key_down,
            .key = "arrowleft",
            .modifiers = .{ .alt = true },
        }));
        try testing.expect(store.keyEvent(3, .{
            .phase = .key_up,
            .key = "arrowleft",
        }));
        try testing.expect(store.keyEvent(3, .{
            .phase = .key_down,
            .key = "arrowright",
            .modifiers = .{ .alt = true },
        }));
        try testing.expect(store.keyEvent(3, .{
            .phase = .key_up,
            .key = "arrowright",
        }));
        try testing.expect(store.keyEvent(3, .{
            .phase = .key_down,
            .key = "arrowleft",
            .modifiers = .{ .super = true },
        }));
        try testing.expect(store.keyEvent(3, .{
            .phase = .key_up,
            .key = "arrowleft",
        }));
        try testing.expect(store.keyEvent(3, .{
            .phase = .key_down,
            .key = "arrowright",
            .modifiers = .{ .super = true },
        }));
        try testing.expect(store.keyEvent(3, .{
            .phase = .key_up,
            .key = "arrowright",
        }));
        try testing.expect(store.keyEvent(3, .{
            .phase = .key_down,
            .key = "backspace",
            .modifiers = .{ .super = true },
        }));
        try testing.expect(store.keyEvent(3, .{
            .phase = .key_up,
            .key = "backspace",
        }));
        try testing.expectEqualStrings("\x1bb\x1bf\x01\x05\x15", gw.written.items);
    }
}

test "clipboard paste uses terminal paste encoding and ended sessions refuse it" {
    if (comptime !terminal_session.enabled) return error.SkipZigTest;
    var store = TerminalSessions.init(testing.allocator);
    defer store.deinit();
    var gw = TestGateway{ .gpa = testing.allocator };
    defer gw.deinit();
    store.setGateway(gw.gateway());
    store.beginBuild(.{});
    _ = resolveGrid(&store, 3) orelse return error.TestExpectedGrid;

    // Unbracketed paste follows xterm: LF becomes CR and dangerous
    // control bytes are spaces, never injected verbatim.
    try testing.expect(store.pasteInput(3, "echo one\necho two\x03\x1b"));
    try testing.expectEqualStrings("echo one\recho two  ", gw.written.items);

    // The child enables mode 2004. The next paste is framed against
    // that live emulator mode, with its multiline payload preserved.
    gw.written.clearRetainingCapacity();
    feedOutput(&store, 3, "\x1b[?2004h");
    try testing.expect(store.pasteInput(3, "alpha\nbeta"));
    try testing.expectEqualStrings("\x1b[200~alpha\nbeta\x1b[201~", gw.written.items);

    // A parked session is no longer an input target. In particular,
    // the clipboard payload does not escape through any fallback.
    gw.written.clearRetainingCapacity();
    feedExit(&store, 3);
    try testing.expect(!store.pasteInput(3, "late"));
    try testing.expectEqualStrings("", gw.written.items);
}

test "a refused write is retained in the ring and drains on the frame flush" {
    if (comptime !terminal_session.enabled) return error.SkipZigTest;
    var store = TerminalSessions.init(testing.allocator);
    defer store.deinit();
    var gw = TestGateway{ .gpa = testing.allocator };
    defer gw.deinit();
    store.setGateway(gw.gateway());
    store.beginBuild(.{});
    _ = resolveGrid(&store, 3) orelse return error.TestExpectedGrid;

    // The pty refuses (a child that stopped reading): the bytes stay
    // queued, not dropped.
    gw.accept = false;
    try testing.expect(store.textInput(3, "queued"));
    try testing.expectEqualStrings("", gw.written.items);

    // The child resumes reading: the frame flush drains the ring.
    gw.accept = true;
    try testing.expect(store.flushPending());
    try testing.expectEqualStrings("queued", gw.written.items);
    // Nothing pending anymore: the flush is a no-op.
    try testing.expect(!store.flushPending());
}

test "reconcile resizes the emulator, pushes ptyResize, and reports the state once" {
    if (comptime !terminal_session.enabled) return error.SkipZigTest;
    var store = TerminalSessions.init(testing.allocator);
    defer store.deinit();
    var gw = TestGateway{ .gpa = testing.allocator };
    defer gw.deinit();
    store.setGateway(gw.gateway());
    store.beginBuild(.{});

    // The reconcile creates the session too (a layout pass can land
    // before the first paint's resolve).
    const state = store.reconcile(9, 0, 100, 30) orelse return error.TestExpectedState;
    try testing.expectEqual(@as(u16, 100), state.cols);
    try testing.expectEqual(@as(u16, 30), state.rows);
    try testing.expectEqual(@as(u16, 100), gw.resized.?.cols);
    try testing.expectEqual(@as(u16, 30), gw.resized.?.rows);
    // The same layout reconciles to the same state: nothing new to
    // report, no second dispatch.
    try testing.expectEqual(@as(?canvas.TerminalState, null), store.reconcile(9, 0, 100, 30));
    try testing.expectEqual(@as(usize, 1), gw.resize_count);

    // The emulator grid moved with the pty: the published snapshot's
    // rows match.
    const grid = resolveGrid(&store, 9) orelse return error.TestExpectedGrid;
    try testing.expectEqual(@as(usize, 30), grid.rows.len);
}

test "every reported state names its pty, so N mounted terminals stay distinguishable" {
    if (comptime !terminal_session.enabled) return error.SkipZigTest;
    var store = TerminalSessions.init(testing.allocator);
    defer store.deinit();
    var gw = TestGateway{ .gpa = testing.allocator };
    defer gw.deinit();
    store.setGateway(gw.gateway());
    store.beginBuild(.{});

    // Two panes with the SAME geometry: without the key their states
    // are byte-identical, which is exactly the case an app cannot
    // attribute. `on-terminal` takes a bare Msg tag — an authored
    // payload is refused — so the payload is the app's only channel.
    const first = store.reconcile(11, 0, 80, 24) orelse return error.TestExpectedState;
    const second = store.reconcile(12, 0, 80, 24) orelse return error.TestExpectedState;
    try testing.expectEqual(@as(u64, 11), first.pty);
    try testing.expectEqual(@as(u64, 12), second.pty);
    try testing.expectEqual(first.scrollback, second.scrollback);
    try testing.expectEqual(first.cols, second.cols);

    // The wheel path reports through `currentState`, and carries the
    // key too — the pane the pointer was over, not "some pane".
    var line: [16]u8 = undefined;
    for (0..30) |index| {
        feedOutput(&store, 12, std.fmt.bufPrint(&line, "line {d}\r\n", .{index}) catch unreachable);
    }
    try testing.expect(store.wheel(12, 18 * 3));
    const scrolled = store.currentState(12) orelse return error.TestExpectedState;
    try testing.expectEqual(@as(u64, 12), scrolled.pty);
    try testing.expectEqual(@as(u32, 3), scrolled.scrollback);

    // The untouched pane still reports its own key and its own
    // (unmoved) position.
    const untouched = store.currentState(11) orelse return error.TestExpectedState;
    try testing.expectEqual(@as(u64, 11), untouched.pty);
    try testing.expectEqual(@as(u32, 0), untouched.scrollback);
}

test "wheel scrollback windows the viewport and the declared echo follows source-wins" {
    if (comptime !terminal_session.enabled) return error.SkipZigTest;
    var store = TerminalSessions.init(testing.allocator);
    defer store.deinit();
    var gw = TestGateway{ .gpa = testing.allocator };
    defer gw.deinit();
    store.setGateway(gw.gateway());
    store.beginBuild(.{});
    _ = store.reconcile(5, 0, 20, 4) orelse return error.TestExpectedState;
    var line: [16]u8 = undefined;
    for (0..30) |index| {
        feedOutput(&store, 5, std.fmt.bufPrint(&line, "line {d}\r\n", .{index}) catch unreachable);
    }

    // Positive delta reveals history (natural direction); one session
    // cell height per row.
    try testing.expect(store.wheel(5, 18 * 3));
    const scrolled = store.currentState(5) orelse return error.TestExpectedState;
    try testing.expectEqual(@as(u32, 3), scrolled.scrollback);
    try testing.expect(scrolled.history >= scrolled.scrollback);

    // The app echoes the reported value back: an unchanged declaration
    // never moves the runtime-owned position.
    try testing.expectEqual(@as(?canvas.TerminalState, null), store.reconcile(5, scrolled.scrollback, 20, 4));
    const held = store.currentState(5) orelse return error.TestExpectedState;
    try testing.expectEqual(@as(u32, 3), held.scrollback);

    // A model-driven change (the declaration MOVED between builds)
    // wins: scroll programmatically back to the live screen.
    const pinned = store.reconcile(5, 0, 20, 4) orelse return error.TestExpectedState;
    try testing.expectEqual(@as(u32, 0), pinned.scrollback);
}

test "typing while scrolled back snaps the viewport to the live screen" {
    if (comptime !terminal_session.enabled) return error.SkipZigTest;
    var store = TerminalSessions.init(testing.allocator);
    defer store.deinit();
    var gw = TestGateway{ .gpa = testing.allocator };
    defer gw.deinit();
    store.setGateway(gw.gateway());
    store.beginBuild(.{});
    _ = store.reconcile(5, 0, 20, 4) orelse return error.TestExpectedState;
    var line: [16]u8 = undefined;
    for (0..30) |index| {
        feedOutput(&store, 5, std.fmt.bufPrint(&line, "line {d}\r\n", .{index}) catch unreachable);
    }
    try testing.expect(store.wheel(5, 18 * 4));
    try testing.expect((store.currentState(5) orelse return error.TestExpectedState).scrollback > 0);
    try testing.expect(store.textInput(5, "x"));
    try testing.expectEqual(@as(u32, 0), (store.currentState(5) orelse return error.TestExpectedState).scrollback);
}

test "an exit parks the session and output on the reused key resets to a clean terminal" {
    if (comptime !terminal_session.enabled) return error.SkipZigTest;
    var store = TerminalSessions.init(testing.allocator);
    defer store.deinit();
    var gw = TestGateway{ .gpa = testing.allocator };
    defer gw.deinit();
    store.setGateway(gw.gateway());
    store.beginBuild(.{});
    _ = resolveGrid(&store, 2) orelse return error.TestExpectedGrid;

    feedOutput(&store, 2, "old session content\r\n");
    feedExit(&store, 2);
    const ended = resolveGrid(&store, 2) orelse return error.TestExpectedGrid;
    try testing.expect(!ended.running);
    // An ended session refuses input (the key is free; a respawn owns it).
    try testing.expect(!store.textInput(2, "late"));
    try testing.expect(!store.keyEvent(2, .{ .phase = .key_down, .key = "enter" }));

    // A new spawn reused the key: its first output resets the emulator
    // before feeding, so the old screen and modes never leak in.
    feedOutput(&store, 2, "fresh prompt $ ");
    const fresh = resolveGrid(&store, 2) orelse return error.TestExpectedGrid;
    try testing.expect(fresh.running);
    try testing.expect(std.mem.indexOf(u8, gridText(fresh), "fresh prompt") != null);
    try testing.expect(std.mem.indexOf(u8, gridText(fresh), "old session") == null);
}

test "emulator query answers write back to the pty through the ring" {
    if (comptime !terminal_session.enabled) return error.SkipZigTest;
    var store = TerminalSessions.init(testing.allocator);
    defer store.deinit();
    var gw = TestGateway{ .gpa = testing.allocator };
    defer gw.deinit();
    store.setGateway(gw.gateway());
    store.beginBuild(.{});
    _ = resolveGrid(&store, 4) orelse return error.TestExpectedGrid;

    // A DSR cursor-position report: the emulator answers and the answer
    // reaches the child (a blocked `read` on the reply never hangs).
    feedOutput(&store, 4, "\x1b[6n");
    try testing.expect(std.mem.indexOf(u8, gw.written.items, "\x1b[") != null);
    try testing.expect(std.mem.indexOf(u8, gw.written.items, "R") != null);
}

test "the wide-cell spacer extends its primary's background in the published snapshot" {
    if (comptime !terminal_session.enabled) return error.SkipZigTest;
    var store = TerminalSessions.init(testing.allocator);
    defer store.deinit();
    store.beginBuild(.{});
    _ = resolveGrid(&store, 6) orelse return error.TestExpectedGrid;
    // Red background behind a double-width glyph (界): the emulator
    // styles only the primary cell, so the snapshot must pre-resolve
    // the spacer's background per the painter's contract.
    feedOutput(&store, 6, "\x1b[41m\xe7\x95\x8c\x1b[0m\r\n");
    const grid = resolveGrid(&store, 6) orelse return error.TestExpectedGrid;
    const row = grid.rows[0];
    try testing.expectEqual(canvas.TerminalWide.wide, row.cells[0].wide);
    try testing.expectEqual(canvas.TerminalWide.spacer, row.cells[1].wide);
    try testing.expect(row.cells[0].bg != null);
    try testing.expect(row.cells[1].bg != null);
    try testing.expectEqual(row.cells[0].bg.?.r, row.cells[1].bg.?.r);
}
