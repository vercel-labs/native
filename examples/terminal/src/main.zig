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

/// Display-list text bytes held back from the grid for the header and
/// status widgets, which draw into the same per-view text store. Their
/// text is a handful of fixed labels plus a few formatted counters —
/// well under 1 KiB — so 4 KiB is a generous margin that still leaves
/// the grid far more than its clamped cell count can fill.
const grid_text_reserve: usize = 4096;

/// The pending-outbound ring size. Generous headroom (4x the pty's
/// 64 KiB stdin FIFO) so only a paste or reply burst far larger than
/// this, into a child that never reads, reaches the drop path — and even
/// then the drop is counted and shown, never silent.
const outbound_buffer_bytes: usize = 256 * 1024;

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

    /// Pending outbound bytes toward the child's stdin — typed keys,
    /// pastes, AND emulator query replies, in one stream-ordered ring
    /// drained as the pty's 64 KiB stdin FIFO accepts them. A single
    /// queue is why nothing is lost: `ptyWrite` reports acceptance (it
    /// alone knows the byte- and record-ring limits), so a refused write
    /// is retried from here rather than dropped, and a reply cannot be
    /// discarded before it lands. Ordering is the child's own stdin
    /// order — a keystroke after a paste, a reply after the output that
    /// provoked it — exactly what a real terminal delivers.
    outbound_buffer: [outbound_buffer_bytes]u8 = undefined,
    outbound_head: usize = 0,
    outbound_len: usize = 0,
    /// Bytes dropped because the pending ring was full (a paste far
    /// larger than the ring, or a reply burst, into a child that never
    /// reads). Surfaced on the status line — never a silent loss.
    outbound_dropped: u64 = 0,

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
    /// The frame pump asks the update loop (which holds `fx`) to push
    /// more pending outbound bytes now that a frame elapsed — the child
    /// may have read and freed FIFO space without producing output to
    /// trigger a flush.
    flush_outbound,
};

const TerminalApp = native_sdk.UiApp(Model, Msg);
const Fx = TerminalApp.Effects;

fn initFx(model: *Model, fx: *Fx) void {
    spawnShell(model, fx);
}

fn spawnShell(model: *Model, fx: *Fx) void {
    model.phase = .starting;
    // Leave selection mode: reset() clears the emulator's selection, so
    // a lingering `selecting` flag would show a caret over no selection
    // AND make the new shell reject all typed text until Escape.
    model.selecting = false;
    // Drop any bytes still queued for the session that just ended — a
    // restarted shell must not receive the dead one's unsent keystrokes.
    model.outbound_head = 0;
    model.outbound_len = 0;
    model.outbound_dropped = 0;
    // Hard-reset the emulator so a restarted shell starts from a clean
    // terminal — no leftover mode (application-cursor, reverse video),
    // scrollback, palette override, or partial escape sequence from the
    // session that just ended. (A no-op on the first spawn.)
    model.session.reset();
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
                feedOutput(model, fx, event.bytes);
                // The child produced output, so it is reading: its stdin
                // FIFO likely has room now — push any pending outbound.
                flushOutbound(model, fx);
            },
            .exit => {
                model.phase = if (event.reason == .rejected or event.reason == .spawn_failed) .failed else .ended;
                model.exit_code = event.code;
                model.exit_reason = event.reason;
                model.dropped_writes = event.dropped_writes;
                // The child is gone: bytes still queued can never land, so
                // drop them rather than spin retrying against a dead key
                // (a restart resets these anyway).
                model.outbound_head = 0;
                model.outbound_len = 0;
            },
            // Write-admission verdicts are journal-only (replay
            // machinery); the engine never delivers one as an event.
            .write => unreachable,
        },
        .key => |event| handleKey(model, fx, event),
        .text => |event| {
            if (model.selecting or !model.acceptsInput()) return;
            if (event.text.len == 0) return;
            model.session.scrollToBottom();
            enqueueOutbound(model, fx, event.text);
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
            flushOutbound(model, fx);
        },
        .flush_outbound => flushOutbound(model, fx),
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

/// Append outbound bytes (typed keys, pastes, or query replies) to the
/// pending ring in stream order, then flush what the pty's stdin FIFO
/// will take. A large payload is not submitted all at once: `flushOutbound`
/// paces it as the child reads, so the tail is never dropped. Admission
/// is ALL-OR-NOTHING: a payload the ring cannot hold whole is dropped
/// whole and counted — a query reply or encoded key cut mid-sequence
/// would feed the child a malformed control sequence, which is worse
/// than a counted loss. Reaching the drop at all means the child ignored
/// 256 KiB of pending input; the count is surfaced, never silent.
fn enqueueOutbound(model: *Model, fx: *Fx, bytes: []const u8) void {
    const cap = model.outbound_buffer.len;
    if (bytes.len > cap - model.outbound_len) {
        model.outbound_dropped += bytes.len;
        return;
    }
    for (bytes, 0..) |byte, i| {
        model.outbound_buffer[(model.outbound_head + model.outbound_len + i) % cap] = byte;
    }
    model.outbound_len += bytes.len;
    flushOutbound(model, fx);
}

/// Push as much pending outbound as the pty's stdin FIFO will accept, in
/// per-write-bound chunks. `ptyWrite` reports acceptance — it alone knows
/// the byte- and record-ring limits — so a refused chunk stays in the
/// ring and is retried on the next output, resize, or frame: a
/// non-reading child pauses the stream instead of losing its tail, and a
/// reply is never removed before it actually lands.
fn flushOutbound(model: *Model, fx: *Fx) void {
    const cap = model.outbound_buffer.len;
    while (model.outbound_len > 0) {
        const run_to_end = cap - model.outbound_head;
        const n = @min(
            native_sdk.max_effect_pty_write_bytes,
            @min(model.outbound_len, run_to_end),
        );
        if (!fx.ptyWrite(shell_key, model.outbound_buffer[model.outbound_head .. model.outbound_head + n])) break;
        model.outbound_head = (model.outbound_head + n) % cap;
        model.outbound_len -= n;
    }
}

/// Feed one pty output batch and return the emulator's query answers to
/// the child. A batch can be many times the response buffer, and a
/// pathological all-query batch (thousands of pipelined DSR/DA1 requests)
/// could produce more replies than the buffer holds in one pass — so the
/// batch is fed in sub-slices no larger than the response buffer, with
/// the answers drained after each. The VT stream keeps parser state
/// across slices, so splitting mid-escape-sequence is invisible; each
/// query's reply is well under a slice's worth of input, so the buffer
/// never overflows and no reply is dropped. This keeps the write-back
/// lossless: a child that blocks on a DSR answer never hangs.
fn feedOutput(model: *Model, fx: *Fx, bytes: []const u8) void {
    const slice_bytes = grid.Session.feed_slice_bytes;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + slice_bytes, bytes.len);
        model.session.feed(bytes[offset..end]);
        moveResponsesToOutbound(model, fx);
        offset = end;
    }
    // A zero-length batch never reaches here (the engine coalesces only
    // non-empty reads), but a batch that produced no output still drains
    // any answer a prior partial sequence completed.
    if (bytes.len == 0) moveResponsesToOutbound(model, fx);
}

/// Move the emulator's query answers (DSR, DA1, ...) into the pending
/// outbound ring, in stream order after whatever input preceded them,
/// then flush. Routing them through the SAME ring as typed input is what
/// makes them lossless: a reply refused by a full FIFO stays queued and
/// retries, never cleared before it lands (which would hang a child
/// blocking on it). The sub-sliced feed keeps each move well under the
/// emulator's reply buffer; a pending ring too full to take the batch
/// whole drops it whole into `outbound_dropped` (all-or-nothing
/// admission) — counted, never a torn escape sequence.
fn moveResponsesToOutbound(model: *Model, fx: *Fx) void {
    const pending = model.session.pendingResponses();
    if (pending.len > 0) enqueueOutbound(model, fx, pending);
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
    // Through the pending ring like committed text, so an encoded key
    // typed while a paste is still draining lands after it in the stream.
    enqueueOutbound(model, fx, buffer[0..writer.end]);
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
        .{ .name = "insert", .key = .insert },
        // Function keys produce no committed text, so the encoder must
        // build their escape sequences or the child never sees them.
        .{ .name = "f1", .key = .f1 },
        .{ .name = "f2", .key = .f2 },
        .{ .name = "f3", .key = .f3 },
        .{ .name = "f4", .key = .f4 },
        .{ .name = "f5", .key = .f5 },
        .{ .name = "f6", .key = .f6 },
        .{ .name = "f7", .key = .f7 },
        .{ .name = "f8", .key = .f8 },
        .{ .name = "f9", .key = .f9 },
        .{ .name = "f10", .key = .f10 },
        .{ .name = "f11", .key = .f11 },
        .{ .name = "f12", .key = .f12 },
    };
    for (specials) |entry| {
        if (keyIs(key, entry.name)) return .{ .key = entry.key };
    }
    // Chorded character keys (ctrl+c, alt+f, ...): the text channel is
    // silent for these, so the encoder builds the control sequence.
    // Alt is a chord EXCEPT on macOS, where Option is a compose key —
    // Option+F commits the composed `ƒ` through the text channel, so
    // encoding an Alt-F escape here too would double the input (the
    // child would see both). On macOS, Option composes; everywhere else
    // Alt is Meta (ESC prefix, no composed text).
    const alt_is_chord = event.modifiers.alt and builtin.os.tag != .macos;
    const chorded = event.modifiers.control or event.modifiers.super or alt_is_chord;
    if (!chorded) return null;
    if (key.len == 1) {
        // The emulator's encoder expects the pressed CHARACTER as UTF-8
        // alongside the logical key — the shape its host normally
        // supplies — and derives the chord bytes from it: legacy C0
        // sequences (Ctrl+C -> 0x03, Ctrl+\ -> 0x1C) where they exist,
        // and the fixterms CSI-u encoding for the exceptions (Ctrl+[,
        // Ctrl+I, Ctrl+M keep their unchorded bytes unambiguous).
        const ch = key[0];
        const utf8 = key[0..1];
        if (ch >= 'a' and ch <= 'z') {
            const base = @intFromEnum(vt.input.Key.key_a);
            return .{
                .key = @enumFromInt(base + @as(c_int, ch - 'a')),
                .utf8 = utf8,
                .unshifted = ch,
            };
        }
        if (ch >= '0' and ch <= '9') {
            const base = @intFromEnum(vt.input.Key.digit_0);
            return .{
                .key = @enumFromInt(base + @as(c_int, ch - '0')),
                .utf8 = utf8,
                .unshifted = ch,
            };
        }
        // Chorded punctuation carries real control meaning a terminal
        // user expects — Ctrl+[ is the ESC chord, Ctrl+\ is SIGQUIT,
        // Ctrl+] exits telnet — and has no text-channel fallback, so an
        // unmapped key here is silently lost input.
        const punctuation = [_]struct { ch: u8, key: vt.input.Key }{
            .{ .ch = '[', .key = .bracket_left },
            .{ .ch = ']', .key = .bracket_right },
            .{ .ch = '\\', .key = .backslash },
            .{ .ch = ';', .key = .semicolon },
            .{ .ch = '\'', .key = .quote },
            .{ .ch = ',', .key = .comma },
            .{ .ch = '.', .key = .period },
            .{ .ch = '/', .key = .slash },
            .{ .ch = '-', .key = .minus },
            .{ .ch = '=', .key = .equal },
            .{ .ch = '`', .key = .backquote },
        };
        for (punctuation) |entry| {
            if (ch == entry.ch) return .{ .key = entry.key, .utf8 = utf8, .unshifted = entry.ch };
        }
    }
    if (keyIs(key, "space")) return .{ .key = .space, .utf8 = " ", .unshifted = ' ' };
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
    // The right-hand fact is the output tally; if a query reply ever
    // overflowed the write-back buffer, or a paste overran the pending
    // ring (both kept at zero in practice by the sub-sliced feed and the
    // large capacity-paced ring), say so plainly rather than let a byte
    // vanish silently.
    const replies_dropped = model.session.responses_dropped;
    const outbound_dropped = model.outbound_dropped;
    const tally = if (replies_dropped > 0 or outbound_dropped > 0)
        ui.fmt("{d} batches / {d} bytes - {d} replies, {d} outbound dropped", .{ model.output_batches, model.output_bytes, replies_dropped, outbound_dropped })
    else
        ui.fmt("{d} batches / {d} bytes", .{ model.output_batches, model.output_bytes });
    return ui.row(.{ .height = status_height, .padding = 6, .gap = 12, .cross = .center }, .{
        mutedText(ui, statusText(ui, model)),
        ui.spacer(1),
        mutedText(ui, tally),
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
        .text_reserve = grid_text_reserve,
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
    if (proposed.x == model.cols and proposed.y == model.rows) {
        // No resize this frame: if bytes are still queued (a large paste
        // draining, or a child that read without echoing), nudge the
        // update loop to push more now that the FIFO may have freed.
        if (model.outbound_len > 0) return .flush_outbound;
        return null;
    }
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
