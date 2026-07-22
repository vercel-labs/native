//! terminal: a recordable terminal embed at the example tier. The pty
//! effect vocabulary owns the transport (`fx.ptySpawn` and friends),
//! libghostty-vt owns cell state, damage, scrollback, and selection, and
//! the canvas paints the viewport as real text — theme-mapped ANSI-16,
//! exact 256-color and truecolor. Record a session and it replays
//! byte-identical offline: no shell runs, the journaled output batches
//! (bytes in the session blob store) and exit ARE the session.
//!
//! Keyboard-first by design: typing goes to the pty (committed text via
//! the IME-correct text channel; chords and specials through the
//! emulator's key encoder, so application cursor-key modes hold).
//! cmd/ctrl+shift+space arms cell selection (arrows move, shift+arrows
//! extend, B toggles block/line, cmd/ctrl+C copies, escape clears);
//! cmd/ctrl+arrows page the scrollback.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const vt = @import("ghostty-vt");
const grid = @import("grid.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "terminal-canvas";
const window_width: f32 = 980;
const window_height: f32 = 640;
pub const window_min_width: f32 = 640;
pub const window_min_height: f32 = 420;

/// The band the header row occupies and the grid sits below.
const header_height: f32 = 44;
const status_height: f32 = 28;
const grid_inset: f32 = 12;

/// The pty and clipboard keys (one keyed-effect space per app).
const shell_key: u64 = 1;
const clipboard_key: u64 = 2;

/// The command budget the grid may spend per rebuild: the view's 2048
/// minus headroom for the widget header/status and their chrome.
const grid_command_budget: usize = 1700;

/// The default interactive shell per platform — a deterministic pick so
/// a replayed update issues the identical spawn (reading $SHELL here
/// would be nondeterminism outside the effect boundary). macOS's login
/// shell has been zsh since Catalina; Linux uses `/bin/sh`, the only
/// interpreter POSIX guarantees present (a bare `/bin/bash` is absent on
/// Alpine and other minimal installs).
const default_shell: []const u8 = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/sh";

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Terminal canvas", .accessibility_label = "Terminal", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Terminal",
    .width = window_width,
    .height = window_height,
    .min_width = window_min_width,
    .min_height = window_min_height,
    .restore_state = false,
    .titlebar = .hidden_inset_tall,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const Phase = enum { starting, live, ended, failed };

pub const Model = struct {
    /// The emulator session, heap-owned (created in main/tests before
    /// the app starts); everything inside derives from journaled inputs.
    session: *grid.Session,
    phase: Phase = .starting,
    exit_code: i32 = 0,
    exit_reason: native_sdk.EffectExitReason = .exited,
    cols: u16 = 80,
    rows: u16 = 24,
    /// Keyboard selection mode (the caret the grid outlines).
    selecting: bool = false,
    /// Copy feedback for the status line, cleared by the next copy.
    copied_bytes: u64 = 0,
    /// Delivered output accounting for the status line (and the
    /// replay fingerprint: byte totals pin the fed stream).
    output_batches: u64 = 0,
    output_bytes: u64 = 0,
    /// Writes the pty refused over the session (reported on exit).
    dropped_writes: u32 = 0,
    /// The window's traffic-light inset so the header clears it.
    chrome_leading: f32 = 0,

    /// Input flows to the pty from the moment it is spawned — not only
    /// after the first output batch flips the phase to `.live`. A shell
    /// with an empty prompt and no startup banner never produces that
    /// first batch, and gating input on `.live` would strand it waiting
    /// for keystrokes it discards. Only an ended or failed session
    /// refuses input.
    pub fn acceptsInput(model: *const Model) bool {
        return model.phase == .starting or model.phase == .live;
    }
};

pub const Msg = union(enum) {
    shell: native_sdk.EffectPtyEvent,
    key: canvas.WidgetKeyboardEvent,
    text: canvas.WidgetKeyboardEvent,
    viewport: struct { cols: u16, rows: u16 },
    clipboard: native_sdk.EffectClipboardResult,
    chrome_changed: native_sdk.platform.WindowChrome,
    copy_selection,
    restart,
};

const TerminalApp = native_sdk.UiApp(Model, Msg);
const Fx = TerminalApp.Effects;

fn initFx(model: *Model, fx: *Fx) void {
    spawnShell(model, fx);
}

fn spawnShell(model: *Model, fx: *Fx) void {
    model.phase = .starting;
    fx.ptySpawn(.{
        .key = shell_key,
        .argv = &.{ default_shell, "-i" },
        .cols = model.cols,
        .rows = model.rows,
        .on_event = Fx.ptyMsg(.shell),
    });
}

pub fn update(model: *Model, msg: Msg, fx: *Fx) void {
    switch (msg) {
        .shell => |event| switch (event.kind) {
            .output => {
                model.phase = .live;
                model.output_batches += 1;
                model.output_bytes += event.bytes.len;
                model.session.feed(event.bytes);
                flushResponses(model, fx);
            },
            .exit => {
                model.phase = if (event.reason == .rejected or event.reason == .spawn_failed) .failed else .ended;
                model.exit_code = event.code;
                model.exit_reason = event.reason;
                model.dropped_writes = event.dropped_writes;
            },
        },
        .key => |event| handleKey(model, fx, event),
        .text => |event| {
            if (model.selecting or !model.acceptsInput()) return;
            if (event.text.len == 0) return;
            model.session.scrollToBottom();
            writeInput(fx, event.text);
        },
        .viewport => |size| {
            // Commit the new size only once the emulator actually took
            // it: on an allocation failure the model keeps its old
            // dimensions and the frame pump retries next frame, so the
            // emulator and the pty never disagree about the grid.
            if (!model.session.resize(size.cols, size.rows)) return;
            model.cols = size.cols;
            model.rows = size.rows;
            fx.ptyResize(shell_key, size.cols, size.rows);
        },
        .copy_selection => copySelection(model, fx),
        .clipboard => |result| {
            if (result.outcome != .ok) model.copied_bytes = 0;
        },
        .chrome_changed => |chrome| {
            model.chrome_leading = chrome.insets.left;
        },
        .restart => {
            // Restart ONLY a genuinely finished session. During
            // `.starting` (spawned, no output yet) or `.live` the pty
            // still holds the key, so respawning would collide on the
            // same key — a rejected exit that strands the running
            // original with no input.
            if (model.phase != .ended and model.phase != .failed) return;
            spawnShell(model, fx);
        },
    }
}

/// Write input to the pty in chunks no larger than the per-write bound:
/// a single committed-text event (a paste, or a long IME commit) can
/// exceed `max_effect_pty_write_bytes`, which `ptyWrite` refuses whole,
/// so splitting keeps every byte flowing. The pty is a byte stream, so
/// a split between two writes is invisible to the child.
fn writeInput(fx: *Fx, bytes: []const u8) void {
    const chunk = native_sdk.max_effect_pty_write_bytes;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + chunk, bytes.len);
        fx.ptyWrite(shell_key, bytes[offset..end]);
        offset = end;
    }
}

/// Terminal answers to queries (DSR, DA1) the last feed produced go
/// back to the pty — the emulator's write-back seam routed through the
/// same journaled command channel as typed input.
fn flushResponses(model: *Model, fx: *Fx) void {
    const pending = model.session.pendingResponses();
    if (pending.len > 0) fx.ptyWrite(shell_key, pending);
    model.session.clearResponses();
}

fn copySelection(model: *Model, fx: *Fx) void {
    const text = model.session.selectionText(model.session.gpa) orelse return;
    defer model.session.gpa.free(text);
    model.copied_bytes = text.len;
    fx.writeClipboard(.{
        .key = clipboard_key,
        .text = text,
        .on_result = Fx.clipboardMsg(.clipboard),
    });
    model.selecting = false;
    model.session.clearSelection();
}

// ------------------------------------------------------------- keyboard

fn onKey(event: canvas.WidgetKeyboardEvent) ?Msg {
    return .{ .key = event };
}

fn onText(event: canvas.WidgetKeyboardEvent) ?Msg {
    return .{ .text = event };
}

fn handleKey(model: *Model, fx: *Fx, event: canvas.WidgetKeyboardEvent) void {
    const mods = event.modifiers;
    const primary = mods.hasCommandModifier();
    const session = model.session;

    // App chords first: selection mode, copy, scrollback, restart.
    if (primary and mods.shift and keyIs(event.key, "space")) {
        if (model.selecting) {
            model.selecting = false;
            session.clearSelection();
        } else {
            model.selecting = true;
            session.beginSelection(false);
        }
        return;
    }
    if (primary and keyIs(event.key, "c") and (model.selecting or session.selectionActive())) {
        copySelection(model, fx);
        return;
    }
    if (primary and keyIs(event.key, "r") and (model.phase == .ended or model.phase == .failed)) {
        update(model, .restart, fx);
        return;
    }
    if (primary and keyIs(event.key, "arrowup")) {
        session.scrollLines(-if (mods.shift) @as(isize, model.rows) else 1);
        return;
    }
    if (primary and keyIs(event.key, "arrowdown")) {
        session.scrollLines(if (mods.shift) @as(isize, model.rows) else 1);
        return;
    }
    if (primary and keyIs(event.key, "home")) {
        session.scrollToTop();
        return;
    }
    if (primary and keyIs(event.key, "end")) {
        session.scrollToBottom();
        return;
    }

    if (model.selecting) {
        if (keyIs(event.key, "escape")) {
            model.selecting = false;
            session.clearSelection();
            return;
        }
        if (keyIs(event.key, "b")) {
            session.toggleSelectionBlock();
            return;
        }
        if (keyIs(event.key, "enter")) {
            copySelection(model, fx);
            return;
        }
        const step: i32 = 1;
        if (keyIs(event.key, "arrowleft")) return session.moveSelection(-step, 0, mods.shift);
        if (keyIs(event.key, "arrowright")) return session.moveSelection(step, 0, mods.shift);
        if (keyIs(event.key, "arrowup")) return session.moveSelection(0, -step, mods.shift);
        if (keyIs(event.key, "arrowdown")) return session.moveSelection(0, step, mods.shift);
        return;
    }

    if (!model.acceptsInput()) return;

    // Everything else is terminal input: specials and chords encode
    // through the emulator (application cursor-key mode, kitty
    // protocol, and modifier encodings all honored); plain printable
    // keys arrive through `.text` instead and are ignored here.
    const key = mapKey(event) orelse return;
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const encode_options: vt.input.KeyEncodeOptions = .fromTerminal(&session.term);
    _ = vt.input.encodeKey(&writer, .{
        .key = key.key,
        .action = .press,
        .mods = .{
            .shift = mods.shift,
            .ctrl = mods.control,
            .alt = mods.alt,
            .super = mods.super,
        },
        .utf8 = key.utf8,
        .unshifted_codepoint = key.unshifted,
    }, encode_options) catch return;
    if (writer.end == 0) return;
    session.scrollToBottom();
    fx.ptyWrite(shell_key, buffer[0..writer.end]);
}

fn keyIs(key: []const u8, name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, name);
}

const MappedKey = struct {
    key: vt.input.Key,
    utf8: []const u8 = "",
    unshifted: u21 = 0,
};

/// Host key names -> emulator key codes, for keys that do not commit
/// text (specials always; letters/digits only under a chord modifier,
/// where the text channel stays silent and the encoder must speak).
fn mapKey(event: canvas.WidgetKeyboardEvent) ?MappedKey {
    const key = event.key;
    const specials = [_]struct { name: []const u8, key: vt.input.Key }{
        .{ .name = "enter", .key = .enter },
        .{ .name = "tab", .key = .tab },
        .{ .name = "escape", .key = .escape },
        .{ .name = "backspace", .key = .backspace },
        .{ .name = "delete", .key = .delete },
        .{ .name = "arrowup", .key = .arrow_up },
        .{ .name = "arrowdown", .key = .arrow_down },
        .{ .name = "arrowleft", .key = .arrow_left },
        .{ .name = "arrowright", .key = .arrow_right },
        .{ .name = "home", .key = .home },
        .{ .name = "end", .key = .end },
        .{ .name = "pageup", .key = .page_up },
        .{ .name = "pagedown", .key = .page_down },
    };
    for (specials) |entry| {
        if (keyIs(key, entry.name)) return .{ .key = entry.key };
    }
    // Chorded character keys (ctrl+c, alt+f, ...): the text channel is
    // silent for these, so the encoder builds the control sequence.
    const chorded = event.modifiers.control or event.modifiers.alt or event.modifiers.super;
    if (!chorded) return null;
    if (key.len == 1) {
        const ch = key[0];
        if (ch >= 'a' and ch <= 'z') {
            const base = @intFromEnum(vt.input.Key.key_a);
            return .{
                .key = @enumFromInt(base + @as(c_int, ch - 'a')),
                .unshifted = ch,
            };
        }
        if (ch >= '0' and ch <= '9') {
            const base = @intFromEnum(vt.input.Key.digit_0);
            return .{
                .key = @enumFromInt(base + @as(c_int, ch - '0')),
                .unshifted = ch,
            };
        }
    }
    if (keyIs(key, "space")) return .{ .key = .space, .unshifted = ' ' };
    return null;
}

// ------------------------------------------------------------------ view

const TerminalUi = TerminalApp.Ui;

pub fn view(ui: *TerminalUi, model: *const Model) TerminalUi.Node {
    return ui.column(.{}, .{
        headerView(ui, model),
        // The grid region: layout space the chrome-painted terminal
        // fills beneath the widget tree.
        ui.panel(.{ .grow = 1, .semantics = .{ .label = "Terminal grid" } }, .{}),
        statusView(ui, model),
    });
}

fn textLeaf(ui: *TerminalUi, kind: canvas.WidgetKind, options: TerminalUi.ElementOptions, content: []const u8) TerminalUi.Node {
    var node = ui.el(kind, options, .{});
    node.widget.text = content;
    return node;
}

fn mutedText(ui: *TerminalUi, content: []const u8) TerminalUi.Node {
    return ui.paragraph(.{}, &.{.{ .text = content, .color = .text_muted, .scale = 0.92 }});
}

fn headerView(ui: *TerminalUi, model: *const Model) TerminalUi.Node {
    const phase_label = switch (model.phase) {
        .starting => "starting",
        .live => "live",
        .ended => "ended",
        .failed => "failed",
    };
    return ui.row(.{ .height = header_height, .padding = 10, .gap = 10, .cross = .center, .window_drag = true }, .{
        ui.el(.stack, .{ .width = model.chrome_leading }, .{}),
        ui.text(.{}, "Terminal"),
        textLeaf(ui, .badge, .{ .semantics = .{ .label = "Session state" } }, phase_label),
        ui.spacer(1),
        mutedText(ui, ui.fmt("{d}x{d}", .{ model.cols, model.rows })),
    });
}

fn statusView(ui: *TerminalUi, model: *const Model) TerminalUi.Node {
    return ui.row(.{ .height = status_height, .padding = 6, .gap = 12, .cross = .center }, .{
        mutedText(ui, statusText(ui, model)),
        ui.spacer(1),
        mutedText(ui, ui.fmt("{d} batches / {d} bytes", .{ model.output_batches, model.output_bytes })),
    });
}

fn statusText(ui: *TerminalUi, model: *const Model) []const u8 {
    if (model.selecting) {
        return "selecting - arrows move, shift extends, B block, enter copies, esc cancels";
    }
    return switch (model.phase) {
        .starting => "starting shell",
        .live => if (model.copied_bytes > 0)
            ui.fmt("copied {d} bytes", .{model.copied_bytes})
        else
            "cmd+shift+space selects - cmd+arrows scroll",
        .ended => ui.fmt("exited ({d}) - cmd+R restarts", .{model.exit_code}),
        .failed => "shell failed to start - cmd+R retries",
    };
}

/// The grid, painted as a variable-length chrome prefix beneath the
/// widget tree: real text through the canvas primitives, damage kept
/// row-shaped by stable command ids.
fn buildChrome(model: *const Model, builder: *canvas.Builder, size: geometry.SizeF, tokens: canvas.DesignTokens) anyerror!void {
    const frame = gridFrame(size);
    try grid.paint(model.session, builder, .{
        .frame = frame,
        .tokens = tokens,
        .running = model.phase == .live or model.phase == .starting,
        .selecting = model.selecting,
        .command_budget = grid_command_budget,
    });
}

fn gridFrame(size: geometry.SizeF) geometry.RectF {
    return geometry.RectF.init(
        grid_inset,
        header_height,
        @max(0, size.width - grid_inset * 2),
        @max(0, size.height - header_height - status_height),
    );
}

/// Frame pump: derive the grid the current canvas fits and dispatch a
/// resize Msg exactly when it changes (journaled, so replay resizes
/// identically).
fn onFrame(model: *const Model, frame: native_sdk.platform.GpuFrame) ?Msg {
    if (frame.size.width <= 0 or frame.size.height <= 0) return null;
    const inner = gridFrame(frame.size);
    const session = model.session;
    if (session.cell_width <= 0 or session.cell_height <= 0) return null;
    const proposed = grid.Session.clampGrid(
        @intFromFloat(@max(2, inner.width / session.cell_width)),
        @intFromFloat(@max(2, inner.height / session.cell_height)),
    );
    if (proposed.x == model.cols and proposed.y == model.rows) return null;
    return .{ .viewport = .{ .cols = proposed.x, .rows = proposed.y } };
}

fn onChrome(chrome: native_sdk.platform.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

// ------------------------------------------------------------------ main

pub fn appOptions() TerminalApp.Options {
    return .{
        .name = "terminal",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .init_fx = initFx,
        .update_fx = update,
        .view = view,
        .on_key = onKey,
        .on_text = onText,
        .on_frame = onFrame,
        .on_chrome = onChrome,
        .chrome = .{
            .prefix_commands = grid_command_budget,
            .variable_prefix = true,
            .build = buildChrome,
        },
    };
}

pub fn main(init: std.process.Init) !void {
    const session = try grid.Session.create(std.heap.page_allocator, init.io, 80, 24);
    defer session.destroy();
    const app_state = try std.heap.page_allocator.create(TerminalApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = TerminalApp.init(std.heap.page_allocator, .{ .session = session }, appOptions());
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "terminal",
        .window_title = "Terminal",
        .bundle_id = "dev.native_sdk.terminal",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
