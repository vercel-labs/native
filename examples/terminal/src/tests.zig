//! Terminal example tests: the emulator round trip (real cell state,
//! damage, palette honesty), the keyboard encoding paths, and the
//! acceptance story — a session recorded against the scriptable fake
//! pty replays fingerprint-identical offline, no shell present.

const std = @import("std");
const native_sdk = @import("native_sdk");
const vt = @import("ghostty-vt");
const app = @import("main.zig");
const grid = @import("grid.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;


fn createSession(cols: u16, rows: u16) !*grid.Session {
    return grid.Session.create(std.heap.page_allocator, testing.io, cols, rows);
}

test "the emulator round-trips output into real cell state" {
    const session = try createSession(40, 6);
    defer session.destroy();
    session.feed("hello \x1b[1;31mworld\x1b[0m\r\n$ ");
    const text = try session.plainText(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "hello world") != null);
    try testing.expect(std.mem.indexOf(u8, text, "$") != null);
}

test "wide CJK cells occupy two columns with a spacer tail" {
    const session = try createSession(20, 4);
    defer session.destroy();
    session.feed("\xe4\xbd\xa0\xe5\xa5\xbd!"); // 你好!
    try session.render.update(session.gpa, &session.term);
    const row = session.render.row_data.get(0);
    const first = row.cells.get(0);
    try testing.expectEqual(vt.page.Cell.Wide.wide, first.raw.wide);
    try testing.expectEqual(vt.page.Cell.Wide.spacer_tail, row.cells.get(1).raw.wide);
    // The '!' lands in column 4 — width semantics held.
    try testing.expectEqual(@as(u21, '!'), row.cells.get(4).raw.codepoint());
}

test "scrollback windows the viewport and the indicator reports it" {
    const session = try createSession(20, 4);
    defer session.destroy();
    var line: [16]u8 = undefined;
    for (0..30) |index| {
        session.feed(std.fmt.bufPrint(&line, "line {d}\r\n", .{index}) catch unreachable);
    }
    var bar = session.scrollbar();
    try testing.expect(bar.total > bar.len);
    const bottom_offset = bar.offset;
    session.scrollLines(-8);
    bar = session.scrollbar();
    try testing.expect(bar.offset < bottom_offset);
    session.scrollToBottom();
    bar = session.scrollbar();
    try testing.expectEqual(bottom_offset, bar.offset);
}

test "keyboard selection selects real text, line and block alike" {
    const session = try createSession(20, 5);
    defer session.destroy();
    session.feed("alpha beta\r\ngamma delta\r\n");
    // Anchor at the cursor (row 2), then walk up-left onto the text.
    session.beginSelection(false);
    session.moveSelection(0, -2, false);
    session.moveSelection(4, 0, true);
    const text = session.selectionText(testing.allocator) orelse return error.TestExpectedSelection;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("alpha", text);

    // Block mode: a 2x2 rectangle across both rows.
    session.clearSelection();
    session.beginSelection(false);
    session.moveSelection(0, -2, false);
    session.toggleSelectionBlock();
    session.moveSelection(1, 1, true);
    const block = session.selectionText(testing.allocator) orelse return error.TestExpectedSelection;
    defer testing.allocator.free(block);
    try testing.expect(std.mem.indexOf(u8, block, "al") != null);
    try testing.expect(std.mem.indexOf(u8, block, "ga") != null);
}

test "the grid paints real text runs with theme-derived ANSI and exact truecolor" {
    const session = try createSession(30, 4);
    defer session.destroy();
    session.feed("plain \x1b[31mred\x1b[0m \x1b[38;2;10;200;30mexact\x1b[0m\r\n");

    var commands: [512]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    const tokens: canvas.DesignTokens = .{};
    try grid.paint(session, &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = tokens,
        .running = true,
        .selecting = false,
    });
    const list = builder.displayList();

    var saw_plain = false;
    var saw_red = false;
    var saw_exact = false;
    for (list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (std.mem.indexOf(u8, text.text, "plain") != null) {
                    saw_plain = true;
                    // Default fg is the theme text token.
                    try testing.expectEqual(tokens.colors.text.r, text.color.r);
                }
                if (std.mem.eql(u8, text.text, "red")) {
                    saw_red = true;
                    // ANSI red derives from the destructive token while
                    // the emulator palette entry is untouched.
                    try testing.expectApproxEqAbs(tokens.colors.destructive.r, text.color.r, 0.01);
                }
                if (std.mem.eql(u8, text.text, "exact")) {
                    saw_exact = true;
                    // Truecolor passes through exactly.
                    try testing.expectApproxEqAbs(@as(f32, 10.0 / 255.0), text.color.r, 0.002);
                    try testing.expectApproxEqAbs(@as(f32, 200.0 / 255.0), text.color.g, 0.002);
                }
            },
            else => {},
        }
    }
    try testing.expect(saw_plain);
    try testing.expect(saw_red);
    try testing.expect(saw_exact);
}

test "inverse video paints text in the background color, not on itself" {
    const session = try createSession(20, 3);
    defer session.destroy();
    // Default colors, reverse-video on: the text must read as the theme
    // background painted over the theme foreground, never foreground on
    // an identical foreground (invisible).
    session.feed("\x1b[7mREV\x1b[0m\r\n");

    var commands: [256]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    const tokens: canvas.DesignTokens = .{};
    try grid.paint(session, &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = tokens,
        .running = true,
        .selecting = false,
    });
    var saw_rev = false;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |text| if (std.mem.eql(u8, text.text, "REV")) {
                saw_rev = true;
                // Text is the background token; distinctly not the fg.
                try testing.expectApproxEqAbs(tokens.colors.background.r, text.color.r, 0.01);
                try testing.expect(text.color.r != tokens.colors.text.r);
            },
            else => {},
        }
    }
    try testing.expect(saw_rev);
}

test "the grid never emits past its command budget" {
    const session = try createSession(80, 24);
    defer session.destroy();
    // A worst case for run-merging: alternate the foreground every cell
    // so no two adjacent cells share a style and every cell is its own
    // run. The budget must still hold.
    var line: [512]u8 = undefined;
    for (0..24) |_| {
        var w: usize = 0;
        for (0..80) |col| {
            const code: u8 = if (col % 2 == 0) 31 else 32;
            w += (std.fmt.bufPrint(line[w..], "\x1b[{d}mX", .{code}) catch break).len;
        }
        session.feed(line[0..w]);
        session.feed("\r\n");
    }
    var commands: [2048]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try grid.paint(session, &builder, .{
        .frame = geometry.RectF.init(0, 0, 900, 560),
        .tokens = .{},
        .running = true,
        .selecting = false,
        .command_budget = 1700,
    });
    try testing.expect(builder.displayList().commands.len <= 1700);
}

test "an OSC 4 palette override is honored even when it equals the default RGB" {
    const session = try createSession(20, 3);
    defer session.destroy();
    const default_red = vt.color.default[1];
    // OSC 4: set ANSI 1 (red) to EXACTLY the emulator's default red RGB,
    // then print red text. RGB equality with the default must not fool
    // the renderer into substituting the theme color — the override
    // mask says the program chose it.
    var seq: [64]u8 = undefined;
    session.feed(std.fmt.bufPrint(&seq, "\x1b]4;1;rgb:{x:0>2}/{x:0>2}/{x:0>2}\x07", .{ default_red.r, default_red.g, default_red.b }) catch unreachable);
    session.feed("\x1b[31mR\x1b[0m\r\n");

    var commands: [256]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    const tokens: canvas.DesignTokens = .{};
    try grid.paint(session, &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = tokens,
        .running = true,
        .selecting = false,
    });
    var saw = false;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |text| if (std.mem.eql(u8, text.text, "R")) {
                saw = true;
                // The live (overridden) RGB, not the theme destructive.
                try testing.expectApproxEqAbs(@as(f32, @floatFromInt(default_red.r)) / 255.0, text.color.r, 0.004);
                try testing.expect(text.color.r != tokens.colors.destructive.r);
            },
            else => {},
        }
    }
    try testing.expect(saw);
}

test "grid clamping trades rows for columns inside the cell budget" {
    const clamped = grid.Session.clampGrid(4000, 4000);
    try testing.expect(@as(usize, clamped.x) <= grid.max_cols);
    try testing.expect(@as(usize, clamped.y) <= grid.max_rows);
    try testing.expect(@as(usize, clamped.x) * @as(usize, clamped.y) <= grid.max_cells);
    const tiny = grid.Session.clampGrid(1, 1);
    try testing.expectEqual(@as(u16, 2), tiny.x);
    try testing.expectEqual(@as(u16, 2), tiny.y);
}

// ------------------------------------------------- record/replay pinned

const TerminalApp = native_sdk.UiApp(app.Model, app.Msg);

const JournalBuffer = struct {
    bytes: [512 * 1024]u8 = undefined,
    len: usize = 0,

    fn sink(self: *JournalBuffer) native_sdk.runtime.SessionRecorderSink {
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

/// Drive one recorded terminal session against the scriptable fake pty:
/// spawn (init_fx), a prompt, typed input (echoed by the script), and
/// the exit. Returns the recorded model and the state fingerprint.
const RecordedTerminalSession = struct {
    fingerprint: u64,
    screen: [256]u8 = undefined,
    screen_len: usize = 0,
};

fn recordTerminalSession(
    gpa: std.mem.Allocator,
    buffer: *JournalBuffer,
    store: *native_sdk.runtime.session_blobs.MemoryBlobStore,
) !RecordedTerminalSession {
    const recorder = try std.heap.page_allocator.create(native_sdk.runtime.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = native_sdk.runtime.SessionRecorder.init(buffer.sink());
    recorder.blob_sink = store.sink();
    recorder.begin(.{ .platform_name = "test", .app_name = "terminal", .window_width = 980, .window_height = 640 });

    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.session_recorder = recorder;

    const session = try createSession(80, 24);
    defer session.destroy();
    const app_state = try gpa.create(TerminalApp);
    defer gpa.destroy(app_state);
    app_state.* = TerminalApp.init(std.heap.page_allocator, .{ .session = session }, app.appOptions());
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const app_iface = app_state.app();

    try harness.start(app_iface);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
        .label = "terminal-canvas",
        .size = geometry.SizeF.init(980, 640),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);

    // init_fx spawned the shell against the fake pty.
    try testing.expectEqual(@as(usize, 1), app_state.effects.pendingPtyCount());

    // The scripted shell: prompt, then a typed command's echo + output.
    try app_state.effects.feedPtyOutput(1, "demo$ ");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    try testing.expectEqual(app.Phase.live, app_state.model.phase);

    // Focus the surface with a click (a real session focuses on first
    // click/key), then type: committed text routes to the app as
    // target-less text.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .pointer_down,
        .x = 200,
        .y = 200,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .text_input,
        .text = "ls",
    } });
    try testing.expectEqualStrings("ls", app_state.effects.ptyWrittenBytes(1));
    try app_state.effects.feedPtyOutput(1, "ls\r\nREADME.md  src\r\ndemo$ ");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);

    // The session ends.
    try app_state.effects.feedPtyExit(1, 0, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    try testing.expectEqual(app.Phase.ended, app_state.model.phase);

    recorder.finish();
    try testing.expect(!recorder.failed);

    var result: RecordedTerminalSession = .{
        .fingerprint = harness.runtime.sessionStateFingerprint(),
    };
    const screen = try session.plainText(gpa);
    defer gpa.free(screen);
    result.screen_len = @min(screen.len, result.screen.len);
    @memcpy(result.screen[0..result.screen_len], screen[0..result.screen_len]);
    return result;
}

test "typing reaches the pty before the first output batch (empty-prompt shell)" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;

    const session = try createSession(80, 24);
    defer session.destroy();
    const app_state = try gpa.create(TerminalApp);
    defer gpa.destroy(app_state);
    app_state.* = TerminalApp.init(std.heap.page_allocator, .{ .session = session }, app.appOptions());
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const app_iface = app_state.app();

    try harness.start(app_iface);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
        .label = "terminal-canvas",
        .size = geometry.SizeF.init(980, 640),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);

    // The shell spawned (init_fx) but produced NO output — phase is
    // still .starting, never .live. Typing must still reach the pty.
    try testing.expectEqual(app.Phase.starting, app_state.model.phase);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .pointer_down,
        .x = 200,
        .y = 200,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .text_input,
        .text = "whoami",
    } });
    try testing.expectEqualStrings("whoami", app_state.effects.ptyWrittenBytes(1));
}

fn startFocusedTerminal(gpa: std.mem.Allocator, harness: anytype) !*TerminalApp {
    harness.null_platform.gpu_surfaces = true;
    const session = try createSession(80, 24);
    const app_state = try gpa.create(TerminalApp);
    app_state.* = TerminalApp.init(std.heap.page_allocator, .{ .session = session }, app.appOptions());
    app_state.effects.executor = .fake;
    const app_iface = app_state.app();
    try harness.start(app_iface);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
        .label = "terminal-canvas",
        .size = geometry.SizeF.init(980, 640),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    // Focus the surface with a click.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .pointer_down,
        .x = 200,
        .y = 200,
    } });
    return app_state;
}

test "IME: a preedit is provisional; only the commit reaches the pty" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer app_state.model.session.destroy();
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Compose Japanese: the preedit must NOT reach the pty (provisional).
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .ime_set_composition,
        .text = "\xe3\x81\x8b", // か
    } });
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(1));

    // The host commits the marked text UNCHANGED — an empty commit; the
    // composed bytes come from the buffered preedit and reach the pty.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .ime_commit_composition,
        .text = "",
    } });
    try testing.expectEqualStrings("\xe3\x81\x8b", app_state.effects.ptyWrittenBytes(1));
}

test "a command-chorded text event never types a literal character into the pty" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer app_state.model.session.destroy();
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Some hosts emit a text_input alongside a Ctrl/Cmd shortcut. The
    // chord is not typing: the runtime's text gate (the focused-widget
    // rule, applied target-less too) must stop the literal "c" — the
    // child sees the ENCODED control byte from the key channel only,
    // never the chord plus a stray character.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .text_input,
        .key = "c",
        .text = "c",
        .modifiers = .{ .control = true },
    } });
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(1));

    // Unmodified typing still flows.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .text_input,
        .text = "c",
    } });
    try testing.expectEqualStrings("c", app_state.effects.ptyWrittenBytes(1));
}

test "typing carried on the key event reaches the pty - the no-separate-text-event host shape" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer app_state.model.session.destroy();
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Hosts without a separate text event for plain typing deliver the
    // printable on the key_down itself; the committed-text channel must
    // carry it to the pty or typing is silently lost there.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "j",
        .text = "j",
    } });
    try testing.expectEqualStrings("j", app_state.effects.ptyWrittenBytes(1));
}

test "chorded punctuation and function keys encode their control sequences" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer app_state.model.session.destroy();
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Ctrl+\ is SIGQUIT to a terminal user — chorded punctuation has no
    // text-channel fallback, so the encoder must speak or the control
    // byte is silently lost. The emulator's legacy encoding maps it to
    // the FS control byte (0x1C).
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "\\",
        .modifiers = .{ .control = true },
    } });
    try testing.expectEqualStrings("\x1c", app_state.effects.ptyWrittenBytes(1));

    // Ctrl+[ rides the emulator's fixterms CSI-u encoding (the ESC
    // chord stays distinguishable from a bare Escape press) — the same
    // bytes the emulator's own terminal sends for this chord.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "[",
        .modifiers = .{ .control = true },
    } });
    try testing.expectEqualStrings("\x1c\x1b[91;5u", app_state.effects.ptyWrittenBytes(1));

    // F1 encodes its escape sequence (ESC O P) — function keys commit
    // no text, so the encoder is their only road to the child.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "f1",
    } });
    try testing.expectEqualStrings("\x1c\x1b[91;5u\x1bOP", app_state.effects.ptyWrittenBytes(1));
}

test "a primary-aliased Ctrl chord still encodes its C0 byte" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer app_state.model.session.destroy();
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Hosts whose PRIMARY modifier is Ctrl report a bare Ctrl chord
    // with BOTH bits set; the runtime folds primary into `super`. The
    // encoder must still see a clean Ctrl+C and emit ETX (0x03) — a
    // stray super would demote it to a CSI-u chord the foreground shell
    // never treats as an interrupt.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "c",
        .modifiers = .{ .control = true, .primary = true },
    } });
    try testing.expectEqualStrings("\x03", app_state.effects.ptyWrittenBytes(1));
}

test "retained replies keep accumulating while further output feeds - the buffer grows" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer app_state.model.session.destroy();
    defer app_state.deinit();
    const session = app_state.model.session;

    // The outbound ring is full and the child keeps pipelining DSR
    // queries — more reply bytes than the buffer's initial capacity.
    // Every reply must accumulate (the buffer grows), none dropped:
    // clearing or dropping would strand a child blocked on an answer.
    app_state.model.outbound_len = app_state.model.outbound_buffer.len;
    const burst = "\x1b[6n" ** 6000; // ~36 KiB of replies, > 16 KiB initial
    session.feed(burst);
    app.moveResponsesToOutbound(&app_state.model, &app_state.effects);
    try testing.expectEqual(@as(u32, 0), session.responses_dropped);
    try testing.expect(session.pendingResponses().len > grid.Session.response_capacity);

    // The ring drains; the whole accumulated batch moves and clears.
    app_state.model.outbound_len = 0;
    app.moveResponsesToOutbound(&app_state.model, &app_state.effects);
    try testing.expectEqual(@as(usize, 0), session.pendingResponses().len);
    try testing.expectEqual(@as(u64, 0), app_state.model.outbound_dropped);
}

test "a query reply refused by a full ring is retained and retried, never cleared" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer app_state.model.session.destroy();
    defer app_state.deinit();

    // The child pipelines a DSR query; its reply waits in the
    // emulator's buffer. With the pending ring full RIGHT NOW, the move
    // must leave the reply IN PLACE — clearing it would strand a child
    // blocked on the answer.
    app_state.model.session.feed("\x1b[6n");
    const reply_len = app_state.model.session.pendingResponses().len;
    try testing.expect(reply_len > 0);
    app_state.model.outbound_len = app_state.model.outbound_buffer.len;
    app.moveResponsesToOutbound(&app_state.model, &app_state.effects);
    try testing.expectEqual(reply_len, app_state.model.session.pendingResponses().len);
    try testing.expectEqual(@as(u64, 0), app_state.model.outbound_dropped);

    // The ring drains (the child read); the retry moves the reply whole
    // and it reaches the pty.
    app_state.model.outbound_len = 0;
    app.moveResponsesToOutbound(&app_state.model, &app_state.effects);
    try testing.expectEqual(@as(usize, 0), app_state.model.session.pendingResponses().len);
    const written = app_state.effects.ptyWrittenBytes(1);
    try testing.expectEqual(reply_len, written.len);
    try testing.expect(std.mem.startsWith(u8, written, "\x1b["));
}

test "a payload the outbound ring cannot hold whole is dropped whole, never torn" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer app_state.model.session.destroy();
    defer app_state.deinit();
    const app_iface = app_state.app();

    // One committed payload larger than the whole pending ring: a
    // prefix cut at the ring edge could tear an escape sequence, so
    // admission is all-or-nothing — dropped whole and counted, nothing
    // queued, nothing written.
    const oversized = try gpa.alloc(u8, app_state.model.outbound_buffer.len + 1);
    defer gpa.free(oversized);
    @memset(oversized, 'z');
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .text_input,
        .text = oversized,
    } });
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(1));
    try testing.expectEqual(@as(u64, oversized.len), app_state.model.outbound_dropped);

    // The stream is intact past the drop: the next keystroke flows.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .text_input,
        .text = "ok",
    } });
    try testing.expectEqualStrings("ok", app_state.effects.ptyWrittenBytes(1));
}

test "reset clears the previous session's palette and dynamic color overrides" {
    const session = try createSession(80, 24);
    defer session.destroy();

    // A shell overrides a palette slot (OSC 4) and the dynamic colors
    // (OSC 10/11/12), then exits.
    session.feed("\x1b]4;1;rgb:ff/00/00\x07");
    session.feed("\x1b]10;rgb:12/34/56\x07");
    session.feed("\x1b]11;rgb:65/43/21\x07");
    session.feed("\x1b]12;rgb:ab/cd/ef\x07");
    try testing.expect(session.term.colors.palette.mask.count() > 0);
    try testing.expect(session.term.colors.foreground.override != null);
    try testing.expect(session.term.colors.background.override != null);
    try testing.expect(session.term.colors.cursor.override != null);

    // The restart reset drops every override — the next shell starts on
    // the theme's colors, never tinted by the session that ended.
    session.reset();
    try testing.expectEqual(@as(usize, 0), session.term.colors.palette.mask.count());
    try testing.expect(session.term.colors.foreground.override == null);
    try testing.expect(session.term.colors.background.override == null);
    try testing.expect(session.term.colors.cursor.override == null);
}

test "restart during starting is a no-op - the original session is not duplicated" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer app_state.model.session.destroy();
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Still .starting (no output yet), one live pty. Cmd+R must not
    // respawn onto the occupied key.
    try testing.expectEqual(app.Phase.starting, app_state.model.phase);
    try testing.expectEqual(@as(usize, 1), app_state.effects.pendingPtyCount());
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "r",
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(app.Phase.starting, app_state.model.phase);
    try testing.expectEqual(@as(usize, 1), app_state.effects.pendingPtyCount());
}

test "a recorded terminal session replays byte-identical offline - no shell present" {
    const gpa = testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    var store = native_sdk.runtime.session_blobs.MemoryBlobStore.init(gpa);
    defer store.deinit();

    const recorded = try recordTerminalSession(gpa, buffer, &store);
    try testing.expect(std.mem.indexOf(u8, recorded.screen[0..recorded.screen_len], "README.md") != null);

    // Replay into a FRESH emulator and app: the journal (events) plus
    // the blob store (output bytes) are the whole world.
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    const session = try createSession(80, 24);
    defer session.destroy();
    const app_state = try gpa.create(TerminalApp);
    defer gpa.destroy(app_state);
    app_state.* = TerminalApp.init(std.heap.page_allocator, .{ .session = session }, app.appOptions());
    defer app_state.deinit();

    const report = try native_sdk.runtime.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
        .blobs = store.source(),
    });
    try testing.expect(report.ok());
    try testing.expect(report.checkpoints_verified > 0);
    // No process ran: the replayed spawn parked, four journaled
    // results fed (two output batches, the typed input's write-admission
    // verdict, one exit).
    try testing.expectEqual(@as(u64, 4), report.effects_fed);
    try testing.expectEqual(recorded.fingerprint, harness.runtime.sessionStateFingerprint());

    // The replayed emulator rebuilt the identical screen from the
    // blob-store bytes — byte-identical, offline.
    const screen = try session.plainText(gpa);
    defer gpa.free(screen);
    try testing.expectEqualStrings(recorded.screen[0..recorded.screen_len], screen[0..recorded.screen_len]);
    try testing.expectEqual(app.Phase.ended, app_state.model.phase);
}
