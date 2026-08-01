//! The framework-owned terminal sessions behind `<terminal pty={key}>`.
//!
//! The element contract (see `canvas.terminal_grid`): the app owns a pty
//! effect key (`fx.ptySpawn` named it) and binds it to a `<terminal>`;
//! the RUNTIME owns the emulator behind that key. This module is that
//! ownership — a per-app store of libghostty-vt sessions keyed by pty
//! key, publishing each session's viewport as a resolved
//! `canvas.TerminalGrid` snapshot for the widget painter, and carrying
//! the input model the example tier hand-wires:
//!
//! - Output feeds arrive through the effects engine's pty tap (the same
//!   delivery instant the app's Msg is built, live and replay alike), so
//!   the emulator state derives entirely from journaled inputs and a
//!   recorded session replays byte-identical.
//! - Emulator query answers (DSR, DA1, XTVERSION) and focused keyboard
//!   input travel back through the JOURNALED pty write path via the
//!   gateway the app loop installs — admission verdicts are executor
//!   truth, so replay takes the identical retain/drop path.
//! - The app loop derives cols/rows from the element's laid-out frame
//!   (`canvas.terminalCellMetrics` + `canvas.clampTerminalGrid`, the
//!   painter's own sizing seam) and reconciles them here; the session
//!   resizes the emulator and pushes `ptyResize` so the child sees
//!   SIGWINCH.
//! - Scrollback follows the scroll `value` source-wins rule: the bound
//!   `scrollback` applies when the DECLARED value changes between
//!   builds; the runtime-owned position stands otherwise, and every
//!   applied view-state change reports back through `on-terminal` as a
//!   `canvas.TerminalState`.
//!
//! The emulator dependency is comptime-gated through the `terminal_vt`
//! seam (see `terminal_vt_stub.zig`): with the stub wired the store
//! compiles to inert no-ops and `<terminal>` renders the honest empty
//! surface — scaffolded and consumer builds never traverse ghostty's
//! dependency graph.

const std = @import("std");
const builtin = @import("builtin");
const canvas = @import("canvas");
const effects = @import("effects.zig");
const term_vt = @import("terminal_vt");

pub const enabled = term_vt.enabled;

/// One session per pty slot: the effects engine's own table bound.
pub const max_sessions: usize = effects.max_effect_ptys;

/// The journaled pty verbs the store drives, type-erased so this module
/// never names the Msg-generic engine: the app loop wraps its engine.
/// `write` is `Effects.ptyWrite` (all-or-nothing, verdict-journaling);
/// `resize` is `Effects.ptyResize`.
pub const PtyGateway = struct {
    context: *anyopaque,
    write: *const fn (context: *anyopaque, key: u64, bytes: []const u8) bool,
    resize: *const fn (context: *anyopaque, key: u64, cols: u16, rows: u16) void,
};

/// One pointer event already translated into the terminal's padded
/// content box. Coordinates remain unclamped so a captured drag beyond
/// an edge extends to that edge; the session maps them onto its live
/// emulator grid using the same cell metrics the snapshot painter uses.
pub const PointerSelectionEvent = struct {
    phase: canvas.WidgetPointerPhase,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    click_count: u8 = 1,
};

pub const PointerSelectionResult = struct {
    changed: bool = false,
    selection_active: bool = false,
};

pub const TerminalSessions = if (enabled) EnabledStore else DisabledStore;

/// The stub-build store: every entry point compiles against the same
/// signatures and answers "no session" — `<terminal>` stays the honest
/// empty surface and the app loop's call sites stay unconditional.
const DisabledStore = struct {
    pub fn init(backing: std.mem.Allocator) DisabledStore {
        _ = backing;
        return .{};
    }
    pub fn deinit(self: *DisabledStore) void {
        _ = self;
    }
    pub fn setGateway(self: *DisabledStore, gateway: PtyGateway) void {
        _ = self;
        _ = gateway;
    }
    pub fn beginBuild(self: *DisabledStore, tokens: canvas.DesignTokens) void {
        _ = self;
        _ = tokens;
    }
    pub fn lookup(self: *DisabledStore) ?canvas.TerminalGridLookup {
        _ = self;
        return null;
    }
    pub fn notePtyEvent(self: *DisabledStore, event: *const effects.EffectPtyEvent) void {
        _ = self;
        _ = event;
    }
    pub fn hasSession(self: *const DisabledStore, pty: u64) bool {
        _ = self;
        _ = pty;
        return false;
    }
    pub fn keyEvent(self: *DisabledStore, pty: u64, keyboard: canvas.WidgetKeyboardEvent) bool {
        _ = self;
        _ = pty;
        _ = keyboard;
        return false;
    }
    pub fn textInput(self: *DisabledStore, pty: u64, text: []const u8) bool {
        _ = self;
        _ = pty;
        _ = text;
        return false;
    }
    pub fn pasteInput(self: *DisabledStore, pty: u64, text: []const u8) bool {
        _ = self;
        _ = pty;
        _ = text;
        return false;
    }
    pub fn wheel(self: *DisabledStore, pty: u64, delta_y: f32) bool {
        _ = self;
        _ = pty;
        _ = delta_y;
        return false;
    }
    pub fn pointerSelection(self: *DisabledStore, pty: u64, event: PointerSelectionEvent) PointerSelectionResult {
        _ = self;
        _ = pty;
        _ = event;
        return .{};
    }
    pub fn reconcile(self: *DisabledStore, pty: u64, bound_scrollback: u32, cols: u16, rows: u16) ?canvas.TerminalState {
        _ = self;
        _ = pty;
        _ = bound_scrollback;
        _ = cols;
        _ = rows;
        return null;
    }
    pub fn currentState(self: *DisabledStore, pty: u64) ?canvas.TerminalState {
        _ = self;
        _ = pty;
        return null;
    }
    pub fn refreshDirty(self: *DisabledStore) bool {
        _ = self;
        return false;
    }
    pub fn flushPending(self: *DisabledStore) bool {
        _ = self;
        return false;
    }
};

const vt = if (enabled) term_vt.vt else struct {};

const EnabledStore = struct {
    allocator: std.mem.Allocator,
    /// The `std.Io` libghostty-vt's Terminal wants at init. Heap-owned
    /// for a stable address; built on first session create so apps with
    /// no `<terminal>` pay nothing.
    threaded: ?*std.Io.Threaded = null,
    entries: [max_sessions]Entry = @splat(.{}),
    gateway: ?PtyGateway = null,
    /// The tokens the CURRENT build resolves snapshots with, stamped by
    /// `beginBuild` (the palette's theme mapping needs them). Valid for
    /// the duration of one build — exactly the window `resolve` runs in.
    tokens: canvas.DesignTokens = .{},

    const Entry = struct {
        key: u64 = 0,
        session: ?*Session = null,
    };

    pub fn init(backing: std.mem.Allocator) EnabledStore {
        return .{ .allocator = backing };
    }

    pub fn deinit(self: *EnabledStore) void {
        for (&self.entries) |*entry| {
            if (entry.session) |session| session.destroy();
            entry.* = .{};
        }
        if (self.threaded) |threaded| {
            threaded.deinit();
            self.allocator.destroy(threaded);
            self.threaded = null;
        }
    }

    pub fn setGateway(self: *EnabledStore, gateway: PtyGateway) void {
        self.gateway = gateway;
    }

    pub fn beginBuild(self: *EnabledStore, tokens: canvas.DesignTokens) void {
        self.tokens = tokens;
    }

    /// The builder seam (`Ui.terminal_lookup`): finalize resolves each
    /// bound pty key through this to the session's published snapshot,
    /// creating the session on first sight — binding the key IS the
    /// request for a framework-owned emulator behind it.
    pub fn lookup(self: *EnabledStore) ?canvas.TerminalGridLookup {
        return .{ .context = @ptrCast(self), .resolve = resolveOpaque };
    }

    fn resolveOpaque(context: *anyopaque, pty: u64) ?*const canvas.TerminalGrid {
        const self: *EnabledStore = @ptrCast(@alignCast(context));
        const session = self.ensureSession(pty) orelse return null;
        if (session.snapshot_dirty) {
            session.rebuildSnapshot(self.tokens) catch return &session.grid;
        }
        return &session.grid;
    }

    fn io(self: *EnabledStore) ?std.Io {
        if (self.threaded == null) {
            const threaded = self.allocator.create(std.Io.Threaded) catch return null;
            threaded.* = std.Io.Threaded.init(self.allocator, .{});
            self.threaded = threaded;
        }
        return self.threaded.?.io();
    }

    fn find(self: *EnabledStore, pty: u64) ?*Session {
        if (pty == 0) return null;
        for (&self.entries) |*entry| {
            if (entry.key == pty) return entry.session;
        }
        return null;
    }

    fn ensureSession(self: *EnabledStore, pty: u64) ?*Session {
        if (pty == 0) return null;
        if (self.find(pty)) |session| return session;
        for (&self.entries) |*entry| {
            if (entry.session != null) continue;
            const session_io = self.io() orelse return null;
            const session = Session.create(self.allocator, session_io, 80, 24) catch return null;
            entry.* = .{ .key = pty, .session = session };
            return session;
        }
        return null;
    }

    pub fn hasSession(self: *const EnabledStore, pty: u64) bool {
        if (pty == 0) return false;
        for (&self.entries) |*entry| {
            if (entry.key == pty and entry.session != null) return true;
        }
        return false;
    }

    /// The effects engine's pty tap: every delivered pty event — live
    /// drain and replay feed alike — passes through here at the same
    /// instant the app's Msg is built, so the emulator's inputs are
    /// exactly the journaled stream.
    pub fn notePtyEvent(self: *EnabledStore, event: *const effects.EffectPtyEvent) void {
        const session = self.find(event.key) orelse return;
        switch (event.kind) {
            .output => {
                // Output for a session that already ENDED is the first
                // batch of a NEW spawn reusing the key (the key freed at
                // exit delivery): hard-reset the emulator first so the
                // new shell starts from a clean terminal — no leftover
                // modes, scrollback, palette overrides, or a partial
                // escape sequence mid-parse from its predecessor.
                if (session.ended) session.resetForRespawn();
                session.feedOutput(self.gateway, event.key, event.bytes);
                session.snapshot_dirty = true;
            },
            .exit => {
                session.ended = true;
                session.grid.running = false;
                // The child is gone: queued bytes can never land — drop
                // them counted, and clear retained emulator replies (the
                // same outbound loss), or the frame flush would retry
                // them against the dead key until a respawn.
                session.outbound_dropped += session.outbound_len;
                session.outbound_dropped += session.response_len;
                session.outbound_head = 0;
                session.outbound_len = 0;
                session.clearResponses();
                session.snapshot_dirty = true;
            },
            // Write-admission verdicts are journal-only replay machinery;
            // the engine never delivers one as an event.
            .write => {},
        }
    }

    /// Focused-terminal key input: specials and chords encode through
    /// the emulator (application cursor-key mode, the kitty protocol,
    /// and modifier encodings all honored); plain printable presses
    /// arrive through the committed-text channel and are consumed here
    /// silently — the editable-text convention, so an app-level key
    /// fallback can never fire while the user is typing. Releases feed
    /// the encoder too (kitty event reporting; silent in legacy modes).
    /// Returns whether the terminal consumed the key.
    pub fn keyEvent(self: *EnabledStore, pty: u64, keyboard: canvas.WidgetKeyboardEvent) bool {
        const session = self.find(pty) orelse return false;
        if (!session.acceptsInput()) return false;
        const action: KeyAction = if (keyboard.phase == .key_up) .release else .press;
        if (keyboard.phase != .key_up and keyboard.phase != .key_down) return false;
        session.clearSelectionForInput();
        session.encodeKeyEvent(self.gateway, pty, keyboard, action);
        return true;
    }

    /// Focused-terminal committed text (IME results included): the
    /// typing channel. Returns whether the session took it.
    pub fn textInput(self: *EnabledStore, pty: u64, text: []const u8) bool {
        const session = self.find(pty) orelse return false;
        if (!session.acceptsInput()) return false;
        if (text.len == 0) return true;
        session.clearSelectionForInput();
        // Typing snaps the viewport to the live screen (every terminal's
        // rule); the cells only change when the echo comes back, so the
        // snapshot re-resolves only when the viewport actually moved.
        const before = session.scrollbarState().offset;
        session.scrollToBottom();
        if (session.scrollbarState().offset != before) session.snapshot_dirty = true;
        session.sendCommittedText(self.gateway, pty, text);
        return true;
    }

    /// Clipboard paste is terminal input with distinct protocol
    /// semantics, never just a multi-byte typing commit. Encode against
    /// the emulator's live bracketed-paste mode, normalize unbracketed
    /// newlines like xterm, and strip control bytes that could inject
    /// terminal commands. Returns whether a live session consumed the
    /// paste; an ended or unknown session declines without writing.
    pub fn pasteInput(self: *EnabledStore, pty: u64, text: []const u8) bool {
        const session = self.find(pty) orelse return false;
        if (!session.acceptsInput()) return false;
        if (text.len == 0) return true;
        session.clearSelectionForInput();
        const before = session.scrollbarState().offset;
        session.scrollToBottom();
        if (session.scrollbarState().offset != before) session.snapshot_dirty = true;

        const options: vt.input.PasteOptions = .fromTerminal(&session.term);
        var mutable: ?[]u8 = null;
        const encoded = vt.input.encodePaste(text, options) catch |err| switch (err) {
            error.MutableRequired => encoded: {
                const copy = session.gpa.dupe(u8, text) catch {
                    session.outbound_dropped += text.len;
                    return true;
                };
                mutable = copy;
                break :encoded vt.input.encodePaste(copy, options);
            },
        };
        defer if (mutable) |copy| session.gpa.free(copy);
        session.enqueueTransientSlices(self.gateway, pty, &encoded);
        return true;
    }

    /// Wheel scrollback over a bound terminal: natural direction, like
    /// every terminal — swiping the content down reveals history.
    /// Deltas accumulate into whole rows against the session's current
    /// cell height. Returns whether the viewport moved.
    pub fn wheel(self: *EnabledStore, pty: u64, delta_y: f32) bool {
        const session = self.find(pty) orelse return false;
        session.wheel_accum += delta_y;
        const cell_h = @max(1, session.cell_height);
        const rows = @trunc(session.wheel_accum / cell_h);
        if (rows == 0) return false;
        session.wheel_accum -= rows * cell_h;
        const before = session.scrollbarState().offset;
        session.scrollLines(-@as(isize, @intFromFloat(rows)));
        if (session.scrollbarState().offset == before) return false;
        session.snapshot_dirty = true;
        // The runtime moved the position: remember it as the value the
        // app will echo back, so the echo never reads as a model-driven
        // scroll (the source-wins compare in `reconcile`).
        session.last_bound_scrollback = session.currentState().scrollback;
        return true;
    }

    /// Primary-pointer terminal selection. The emulator owns the
    /// tracked pins and selection serialization; the canvas runtime
    /// supplies only the gesture and the content-box geometry.
    pub fn pointerSelection(self: *EnabledStore, pty: u64, event: PointerSelectionEvent) PointerSelectionResult {
        const session = self.find(pty) orelse return .{};
        const result = session.pointerSelection(event);
        if (result.changed) session.snapshot_dirty = true;
        return result;
    }

    /// The per-build view-state reconcile the app loop runs against the
    /// element's laid-out extent: applies a CHANGED declared scrollback
    /// (source wins), resizes the emulator and pushes `ptyResize` when
    /// the layout-derived grid moved, and returns the post-change
    /// `canvas.TerminalState` when it differs from the last one
    /// reported — the `on-terminal` dispatch trigger.
    pub fn reconcile(self: *EnabledStore, pty: u64, bound_scrollback: u32, cols: u16, rows: u16) ?canvas.TerminalState {
        const session = self.ensureSession(pty) orelse return null;
        var changed = false;
        if (bound_scrollback != session.last_bound_scrollback) {
            // The DECLARED value moved between builds: the model scrolled
            // programmatically (an unchanged echo compares equal and the
            // runtime-owned position stands).
            session.last_bound_scrollback = bound_scrollback;
            if (session.applyScrollback(bound_scrollback)) changed = true;
        }
        if (cols != session.cols() or rows != session.rows()) {
            if (session.resize(cols, rows)) {
                changed = true;
                if (self.gateway) |gateway| {
                    gateway.resize(gateway.context, pty, cols, rows);
                }
                // A resize is the child reading and redrawing: push any
                // pending outbound the freed FIFO will now take.
                session.flushOutbound(self.gateway, pty);
            }
        }
        if (changed) {
            session.snapshot_dirty = true;
            // The snapshot must speak for the applied change before the
            // caller re-emits the display list.
            session.rebuildSnapshot(self.tokens) catch {};
        }
        // The key is stamped HERE, at the store's public seam, because
        // this is where it is known: a `Session` is found BY key and
        // does not carry one, and every path that reaches an app —
        // reconcile and the wheel — comes through these two functions.
        var state = session.currentState();
        state.pty = pty;
        if (session.last_reported == null or !stateEql(session.last_reported.?, state)) {
            session.last_reported = state;
            return state;
        }
        return null;
    }

    pub fn currentState(self: *EnabledStore, pty: u64) ?canvas.TerminalState {
        const session = self.find(pty) orelse return null;
        var state = session.currentState();
        state.pty = pty;
        session.last_reported = state;
        return state;
    }

    /// Rebuild any dirty published snapshots in place (with the last
    /// build's tokens) so a display-list re-emission paints the current
    /// emulator state. Returns whether anything was dirty — the
    /// caller's re-emit trigger.
    pub fn refreshDirty(self: *EnabledStore) bool {
        var any = false;
        for (&self.entries) |*entry| {
            const session = entry.session orelse continue;
            if (!session.snapshot_dirty) continue;
            any = true;
            session.rebuildSnapshot(self.tokens) catch {};
        }
        return any;
    }

    /// The frame-tick flush: a child that read without echoing freed
    /// FIFO room no output event announces, so pending outbound (typed
    /// keys a full ring retained, emulator replies) drains here. A
    /// no-op when nothing is pending — no journal traffic. Returns
    /// whether any bytes moved.
    pub fn flushPending(self: *EnabledStore) bool {
        var moved = false;
        for (&self.entries) |*entry| {
            const session = entry.session orelse continue;
            if (session.ended) continue;
            if (session.outbound_len == 0 and session.response_len == 0) continue;
            const before = session.outbound_len + session.response_len;
            session.moveResponsesToOutbound(self.gateway, entry.key);
            session.flushOutbound(self.gateway, entry.key);
            if (session.outbound_len + session.response_len != before) moved = true;
        }
        return moved;
    }

    fn stateEql(a: canvas.TerminalState, b: canvas.TerminalState) bool {
        return a.scrollback == b.scrollback and a.history == b.history and
            a.cols == b.cols and a.rows == b.rows;
    }
};

const KeyAction = if (enabled) vt.input.KeyAction else enum { press, release };

/// The pending-outbound ring size, matched to the example tier: 4x the
/// pty's 64 KiB stdin FIFO, so only a paste or reply burst far larger
/// than this, into a child that never reads, reaches the counted drop
/// path.
const outbound_buffer_bytes: usize = 256 * 1024;

/// One live emulator session (enabled builds only). Heap-owned by the
/// store; everything inside derives from journaled inputs — fed pty
/// bytes, layout-derived resizes, and input events — so a replayed
/// session rebuilds byte-identical.
const Session = if (enabled) struct {
    gpa: std.mem.Allocator,
    term: vt.Terminal,
    stream: vt.TerminalStream,
    render: vt.RenderState,

    /// Emulator answers to queries (DSR, DA1, XTVERSION, ...) produced
    /// while feeding output, drained after every feed slice and written
    /// back to the pty through the outbound ring. Grown to fit up to
    /// the ring's own ceiling; a reply past it drops WHOLE and counted
    /// (never cut, which would desync the child's parser).
    response_buffer: []u8 = &.{},
    response_len: usize = 0,
    responses_dropped: u32 = 0,

    /// Pending outbound bytes toward the child's stdin — typed keys,
    /// IME commits, AND emulator query replies, one stream-ordered ring
    /// drained as the pty's stdin FIFO accepts them (the example tier's
    /// lossless-write design, verbatim).
    outbound_buffer: []u8,
    outbound_head: usize = 0,
    outbound_len: usize = 0,
    outbound_dropped: u64 = 0,

    /// The published snapshot the widget painter borrows (stable
    /// address: the painter's borrowed-pointer lifetime contract).
    grid: canvas.TerminalGrid,
    rows_buf: [canvas.max_terminal_rows]canvas.TerminalRow = @splat(.{}),
    cells_buf: []canvas.TerminalCell = &.{},
    cluster_buf: []u8 = &.{},
    screen_text: []const u8 = &.{},
    selection_text: ?[:0]const u8 = null,
    snapshot_dirty: bool = true,

    /// Ghostty's gesture owns a tracked press pin across output and
    /// viewport movement, so a drag continues selecting the same text
    /// even when the page list shifts underneath it.
    selection_gesture: vt.SelectionGesture = .init,

    /// Session lifecycle: exactly one exit ends every spawn; output on
    /// an ended session is a new spawn reusing the key.
    ended: bool = false,

    /// View state for the source-wins scrollback echo and the
    /// `on-terminal` change compare.
    last_bound_scrollback: u32 = 0,
    last_reported: ?canvas.TerminalState = null,
    wheel_accum: f32 = 0,
    /// Cell metrics at the last snapshot's tokens, shared by wheel
    /// delta-to-rows and pointer-to-cell selection.
    cell_width: f32 = 8,
    cell_height: f32 = 18,
    /// Physical macOS natural-editing keys whose press bypassed kitty
    /// reporting as legacy shell bytes. Their matching release must be
    /// swallowed by key identity even if Command/Option came up first.
    macos_natural_keys_held: u8 = 0,

    /// Query-answer buffer's initial size and growth ceiling — the
    /// example tier's bounds verbatim (the ceiling matches the ring:
    /// replies past it could never enqueue whole anyway).
    const response_capacity: usize = 16 * 1024;
    const response_capacity_max: usize = outbound_buffer_bytes;

    /// Output feeds in sub-slices no larger than this, draining answers
    /// after each, so a burst of pipelined query replies cannot outrun
    /// the response buffer within one feed (a reply can be several
    /// times its triggering query; see the example tier's derivation).
    const feed_slice_bytes: usize = response_capacity / 16;

    fn create(gpa: std.mem.Allocator, session_io: std.Io, initial_cols: u16, initial_rows: u16) !*Session {
        const session = try gpa.create(Session);
        errdefer gpa.destroy(session);
        session.* = .{
            .gpa = gpa,
            .term = try vt.Terminal.init(session_io, gpa, .{
                .cols = @intCast(@min(initial_cols, canvas.max_terminal_cols)),
                .rows = @intCast(@min(initial_rows, canvas.max_terminal_rows)),
                .max_scrollback = 1_000_000,
            }),
            .stream = undefined,
            .render = .empty,
            .outbound_buffer = &.{},
            .grid = .{
                .background = canvas.Color.rgba(0, 0, 0, 1),
                .foreground = canvas.Color.rgba(1, 1, 1, 1),
                .cursor_color = canvas.Color.rgba(1, 1, 1, 1),
                .selection_color = canvas.Color.rgba(1, 1, 1, 1),
            },
        };
        errdefer session.term.deinit(gpa);
        session.response_buffer = try gpa.alloc(u8, response_capacity);
        errdefer gpa.free(session.response_buffer);
        session.outbound_buffer = try gpa.alloc(u8, outbound_buffer_bytes);
        errdefer gpa.free(session.outbound_buffer);
        session.stream = .initAlloc(gpa, .init(&session.term));
        session.installStreamEffects();
        return session;
    }

    /// Wire the stream handler's effect callbacks — only `write_pty`
    /// (query answers routed back toward the pty); everything else
    /// stays null (the emulator's read-only defaults).
    fn installStreamEffects(session: *Session) void {
        session.stream.handler.effects = .{
            .bell = null,
            .clipboard_write = null,
            .color_scheme = null,
            .device_attributes = null,
            .enquiry = null,
            .size = null,
            .title_changed = null,
            .pwd_changed = null,
            .write_pty = writePtyResponse,
            .xtversion = null,
        };
    }

    fn destroy(session: *Session) void {
        const gpa = session.gpa;
        session.selection_gesture.deinit(&session.term);
        session.render.deinit(gpa);
        session.stream.deinit();
        session.term.deinit(gpa);
        gpa.free(session.response_buffer);
        gpa.free(session.outbound_buffer);
        if (session.cells_buf.len > 0) gpa.free(session.cells_buf);
        if (session.cluster_buf.len > 0) gpa.free(session.cluster_buf);
        if (session.screen_text.len > 0) gpa.free(session.screen_text);
        if (session.selection_text) |text| gpa.free(text);
        gpa.destroy(session);
    }

    fn acceptsInput(session: *const Session) bool {
        return !session.ended;
    }

    /// Hard-reset for a spawn reusing the key: clears the screen,
    /// scrollback, modes, palette overrides, and — by rebuilding the
    /// stream — any partial escape sequence left mid-parse.
    fn resetForRespawn(session: *Session) void {
        // Drop the tracked gesture pin before the RIS recycles the
        // screen/page list it belongs to.
        session.selection_gesture.reset(&session.term);
        session.term.fullReset();
        // A RIS leaves the OSC color state alone: overrides from the
        // ended shell must not tint the new one.
        session.term.colors.foreground.override = null;
        session.term.colors.background.override = null;
        session.term.colors.cursor.override = null;
        session.term.colors.palette.resetAll();
        session.stream.deinit();
        session.stream = .initAlloc(session.gpa, .init(&session.term));
        session.installStreamEffects();
        session.response_len = 0;
        session.responses_dropped = 0;
        session.outbound_head = 0;
        session.outbound_len = 0;
        session.outbound_dropped = 0;
        session.wheel_accum = 0;
        session.macos_natural_keys_held = 0;
        session.ended = false;
        session.grid.running = true;
        session.snapshot_dirty = true;
    }

    // ------------------------------------------------------ output feed

    /// Feed one pty output batch and return the emulator's query answers
    /// toward the child, in bounded sub-slices so pipelined replies can
    /// never outrun the response buffer within one feed. The VT stream
    /// keeps parser state across slices, so splitting mid-escape-sequence
    /// is invisible.
    fn feedOutput(session: *Session, gateway: ?PtyGateway, key: u64, bytes: []const u8) void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = @min(offset + feed_slice_bytes, bytes.len);
            session.stream.nextSlice(bytes[offset..end]);
            session.moveResponsesToOutbound(gateway, key);
            offset = end;
        }
        if (bytes.len == 0) session.moveResponsesToOutbound(gateway, key);
        // The child produced output, so it is reading: push pending
        // outbound the freed FIFO will now take.
        session.flushOutbound(gateway, key);
    }

    fn writePtyResponse(handler: *vt.TerminalStream.Handler, bytes: [:0]const u8) void {
        const session: *Session = @alignCast(@fieldParentPtr("term", handler.terminal));
        const needed = session.response_len + bytes.len;
        if (needed > session.response_buffer.len) {
            if (needed > response_capacity_max) {
                session.responses_dropped +|= 1;
                return;
            }
            var new_cap = @max(session.response_buffer.len * 2, response_capacity);
            while (new_cap < needed) new_cap *= 2;
            if (new_cap > response_capacity_max) new_cap = response_capacity_max;
            if (session.gpa.realloc(session.response_buffer, new_cap)) |grown| {
                session.response_buffer = grown;
            } else |_| {
                session.responses_dropped +|= 1;
                return;
            }
        }
        @memcpy(session.response_buffer[session.response_len..needed], bytes);
        session.response_len += bytes.len;
    }

    fn clearResponses(session: *Session) void {
        session.response_len = 0;
    }

    /// Move the emulator's query answers into the pending outbound ring
    /// in stream order, then flush. Replies are DURABLE (the response
    /// buffer holds them): a ring too full right now leaves them in
    /// place for the next output, resize, or frame — never a discarded
    /// answer the child may be blocked on, never a torn escape sequence.
    fn moveResponsesToOutbound(session: *Session, gateway: ?PtyGateway, key: u64) void {
        if (session.response_len > 0) {
            if (!session.enqueueOutbound(gateway, key, session.response_buffer[0..session.response_len])) return;
        }
        session.clearResponses();
    }

    /// Append outbound bytes in stream order, then flush what the pty's
    /// stdin FIFO will take. Admission is ALL-OR-NOTHING (a control
    /// sequence cut mid-way would feed the child malformed input): true
    /// means the payload is DISPOSED (queued whole, or impossible and
    /// counted); false means it does not fit RIGHT NOW and the caller
    /// retains it.
    fn enqueueOutbound(session: *Session, gateway: ?PtyGateway, key: u64, bytes: []const u8) bool {
        const cap = session.outbound_buffer.len;
        if (bytes.len > cap) {
            session.outbound_dropped += bytes.len;
            return true;
        }
        if (bytes.len > cap - session.outbound_len) {
            session.flushOutbound(gateway, key);
            if (bytes.len > cap - session.outbound_len) return false;
        }
        for (bytes, 0..) |byte, i| {
            session.outbound_buffer[(session.outbound_head + session.outbound_len + i) % cap] = byte;
        }
        session.outbound_len += bytes.len;
        session.flushOutbound(gateway, key);
        return true;
    }

    /// Enqueue a TRANSIENT payload (typed text, an encoded key): the
    /// event's bytes do not outlive the dispatch, so a right-now refusal
    /// counts as dropped instead of silent loss. Stdin order comes
    /// first: a query reply retained behind a full ring is OLDER than
    /// this keystroke and must reach the child before it.
    fn enqueueTransient(session: *Session, gateway: ?PtyGateway, key: u64, bytes: []const u8) void {
        session.moveResponsesToOutbound(gateway, key);
        if (session.response_len > 0) {
            session.outbound_dropped += bytes.len;
            return;
        }
        if (!session.enqueueOutbound(gateway, key, bytes)) {
            session.outbound_dropped += bytes.len;
        }
    }

    /// Paste encoding is a vector (optional bracket, payload, optional
    /// bracket) but admission is atomic: never enqueue an opening
    /// bracket without its payload and closing bracket when a
    /// back-pressured child has nearly filled the ring.
    fn enqueueTransientSlices(session: *Session, gateway: ?PtyGateway, key: u64, slices: []const []const u8) void {
        session.moveResponsesToOutbound(gateway, key);
        var total: usize = 0;
        for (slices) |bytes| total += bytes.len;
        if (session.response_len > 0) {
            session.outbound_dropped += total;
            return;
        }

        const cap = session.outbound_buffer.len;
        if (total > cap) {
            session.outbound_dropped += total;
            return;
        }
        if (total > cap - session.outbound_len) session.flushOutbound(gateway, key);
        if (total > cap - session.outbound_len) {
            session.outbound_dropped += total;
            return;
        }

        var offset = session.outbound_len;
        for (slices) |bytes| {
            for (bytes) |byte| {
                session.outbound_buffer[(session.outbound_head + offset) % cap] = byte;
                offset += 1;
            }
        }
        session.outbound_len += total;
        session.flushOutbound(gateway, key);
    }

    /// Push as much pending outbound as the pty's stdin FIFO will
    /// accept, in per-write-bound chunks through the JOURNALED write
    /// path. A refused chunk stays in the ring for the next output,
    /// resize, or frame — a non-reading child pauses the stream instead
    /// of losing its tail.
    fn flushOutbound(session: *Session, gateway: ?PtyGateway, key: u64) void {
        const gw = gateway orelse return;
        const cap = session.outbound_buffer.len;
        while (session.outbound_len > 0) {
            const run_to_end = cap - session.outbound_head;
            const n = @min(
                effects.max_effect_pty_write_bytes,
                @min(session.outbound_len, run_to_end),
            );
            if (!gw.write(gw.context, key, session.outbound_buffer[session.outbound_head .. session.outbound_head + n])) break;
            session.outbound_head = (session.outbound_head + n) % cap;
            session.outbound_len -= n;
        }
    }

    // -------------------------------------------------------- geometry

    fn cols(session: *const Session) u16 {
        return @intCast(session.term.cols);
    }

    fn rows(session: *const Session) u16 {
        return @intCast(session.term.rows);
    }

    /// Resize the emulator grid (reflow included). Returns whether the
    /// grid now matches the request; an allocation failure returns
    /// false so the caller leaves the pty untouched and retries on the
    /// next build — the emulator and the pty never disagree.
    fn resize(session: *Session, new_cols: u16, new_rows: u16) bool {
        const c: vt.size.CellCountInt = @intCast(std.math.clamp(@as(usize, new_cols), 2, canvas.max_terminal_cols));
        const r: vt.size.CellCountInt = @intCast(std.math.clamp(@as(usize, new_rows), 2, canvas.max_terminal_rows));
        if (c == session.term.cols and r == session.term.rows) return true;
        session.term.resize(session.gpa, .{ .cols = c, .rows = r }) catch return false;
        return true;
    }

    // ------------------------------------------------------- scrollback

    fn scrollLines(session: *Session, delta: isize) void {
        session.term.screens.active.pages.scroll(.{ .delta_row = delta });
    }

    fn scrollToBottom(session: *Session) void {
        session.term.screens.active.pages.scroll(.{ .active = {} });
    }

    fn scrollbarState(session: *Session) vt.PageList.Scrollbar {
        return session.term.screens.active.pages.scrollbar();
    }

    // ------------------------------------------------ pointer selection

    /// Default terminal word boundaries, matching Ghostty's standard
    /// selection gesture. Kept local because the pinned vt module
    /// exports SelectionGesture but not its codepoint-policy module.
    const word_boundaries = [_]u21{
        0,   ' ', '\t', '\'', '"',
        '│',
        '`', '|', ':',  ';',  ',',
        '(', ')', '[',  ']',  '{',
        '}', '<', '>',  '$',
    };

    fn pointerSelection(session: *Session, event: PointerSelectionEvent) PointerSelectionResult {
        if (!std.math.isFinite(event.x) or !std.math.isFinite(event.y) or
            !std.math.isFinite(event.width) or !std.math.isFinite(event.height) or
            session.cell_width <= 0 or session.cell_height <= 0)
        {
            return .{};
        }

        const screen = session.term.screens.active;
        switch (event.phase) {
            .down => {
                const pin = session.pointerPin(event) orelse return .{};
                session.selection_gesture.reset(&session.term);
                const behavior: vt.SelectionGesture.Behavior = if (event.click_count >= 3)
                    .line
                else if (event.click_count == 2)
                    .word
                else
                    .cell;
                // The runtime already derives and journals click_count.
                // Force all gesture slots to that behavior and omit a
                // timestamp, avoiding a second, divergent click clock
                // inside the emulator.
                const behaviors = [3]vt.SelectionGesture.Behavior{ behavior, behavior, behavior };
                const selected = session.selection_gesture.press(&session.term, .{
                    .time = null,
                    .pin = pin,
                    .xpos = event.x,
                    .ypos = event.y,
                    .max_distance = @max(1, session.cell_width),
                    .repeat_interval = 0,
                    .word_boundary_codepoints = &word_boundaries,
                    .behaviors = &behaviors,
                }) catch {
                    screen.clearSelection();
                    return .{ .changed = true };
                };
                if (selected) |selection| {
                    screen.select(selection) catch screen.clearSelection();
                } else {
                    // A plain press collapses the previous selection;
                    // crossing the drag threshold establishes the new
                    // range on the following move/up.
                    screen.clearSelection();
                }
                return .{
                    .changed = true,
                    .selection_active = screen.selection != null,
                };
            },
            .move => {
                const changed = session.applyPointerDrag(event);
                return .{
                    .changed = changed,
                    .selection_active = screen.selection != null,
                };
            },
            .up => {
                const pin = session.pointerPin(event);
                const changed = session.applyPointerDrag(event);
                session.selection_gesture.release(&session.term, .{ .pin = pin });
                return .{
                    .changed = changed,
                    .selection_active = screen.selection != null,
                };
            },
            .cancel => {
                session.selection_gesture.reset(&session.term);
                return .{ .selection_active = screen.selection != null };
            },
            .hover, .wheel => return .{ .selection_active = screen.selection != null },
        }
    }

    fn applyPointerDrag(session: *Session, event: PointerSelectionEvent) bool {
        const pin = session.pointerPin(event) orelse return false;
        const selection = session.selection_gesture.drag(&session.term, .{
            .pin = pin,
            .xpos = event.x,
            .ypos = event.y,
            .rectangle = false,
            .word_boundary_codepoints = &word_boundaries,
            .geometry = .{
                .columns = session.cols(),
                .cell_width = @intFromFloat(@max(1, @round(session.cell_width))),
                .padding_left = 0,
                .screen_height = @intFromFloat(@max(1, @round(event.height))),
            },
        }) orelse return false;
        session.term.screens.active.select(selection) catch return false;
        return true;
    }

    fn pointerPin(session: *Session, event: PointerSelectionEvent) ?vt.Pin {
        const cols_count = session.cols();
        const rows_count = session.rows();
        if (cols_count == 0 or rows_count == 0) return null;
        const max_x = @as(f32, @floatFromInt(cols_count - 1));
        const max_y = @as(f32, @floatFromInt(rows_count - 1));
        const cell_x = std.math.clamp(@floor(event.x / session.cell_width), 0, max_x);
        const cell_y = std.math.clamp(@floor(event.y / session.cell_height), 0, max_y);
        return session.term.screens.active.pages.pin(.{ .viewport = .{
            .x = @intFromFloat(cell_x),
            .y = @intFromFloat(cell_y),
        } });
    }

    /// Any input sent to the child dismisses the pointer selection,
    /// matching terminal convention. Cmd/Ctrl+C is intercepted before
    /// `keyEvent` while a selection exists, so copy never reaches this
    /// clearing path.
    fn clearSelectionForInput(session: *Session) void {
        session.selection_gesture.reset(&session.term);
        if (session.term.screens.active.selection == null) return;
        session.term.screens.active.clearSelection();
        session.snapshot_dirty = true;
    }

    /// Scroll to an offset-from-bottom (the `TerminalState.scrollback`
    /// shape). Returns whether the viewport moved.
    fn applyScrollback(session: *Session, target: u32) bool {
        const bar = session.scrollbarState();
        const history: u32 = @intCast(bar.total -| bar.len);
        const clamped = @min(target, history);
        const current: u32 = @intCast((bar.total -| bar.len) -| bar.offset);
        if (clamped == current) return false;
        const delta: isize = @as(isize, @intCast(clamped)) - @as(isize, @intCast(current));
        session.scrollLines(-delta);
        return true;
    }

    fn currentState(session: *Session) canvas.TerminalState {
        const bar = session.scrollbarState();
        const history: u32 = @intCast(bar.total -| bar.len);
        return .{
            .scrollback = @intCast(history -| @as(u32, @intCast(bar.offset))),
            .history = history,
            .cols = session.cols(),
            .rows = session.rows(),
        };
    }

    // --------------------------------------------------------- keyboard

    /// Encode one key transition and push the bytes toward the child.
    /// macOS natural-text arrow gestures use the platform's conventional
    /// shell bindings; everything else follows the emulator's encoder
    /// (C0 chords, CSI-u exceptions, application cursor-key modes, kitty
    /// event reporting for releases).
    fn encodeKeyEvent(session: *Session, gateway: ?PtyGateway, pty_key: u64, event: canvas.WidgetKeyboardEvent, action: vt.input.KeyAction) void {
        const natural_key_mask = macosNaturalTextKeyMask(event.key);
        if (action == .release and natural_key_mask != 0 and
            (session.macos_natural_keys_held & natural_key_mask) != 0)
        {
            session.macos_natural_keys_held &= ~natural_key_mask;
            return;
        }
        // A fresh press supersedes any stale held bit (focus loss or a
        // host-generated press with no matching release). A natural
        // press below immediately re-arms it, including auto-repeat.
        if (action == .press and natural_key_mask != 0) {
            session.macos_natural_keys_held &= ~natural_key_mask;
        }
        if (macosNaturalTextSequence(event)) |sequence| {
            // Natural-text bindings consume the whole gesture. In
            // particular, a child using kitty event reporting must not
            // receive a release for a modified arrow whose press arrived
            // as legacy editing bytes.
            if (action == .release) return;
            session.macos_natural_keys_held |= natural_key_mask;
            const before = session.scrollbarState().offset;
            session.scrollToBottom();
            if (session.scrollbarState().offset != before) session.snapshot_dirty = true;
            session.enqueueTransient(gateway, pty_key, sequence);
            return;
        }
        const mods = event.modifiers;
        const key = mapKey(event) orelse blk: {
            // A release of a plain printable never maps (its PRESS came
            // through the text channel): synthesize the codepoint-keyed
            // event so kitty event reporting hears the release too.
            if (action != .release) return;
            break :blk mapPrintable(event.key) orelse return;
        };
        var buffer: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        const encode_options: vt.input.KeyEncodeOptions = .fromTerminal(&session.term);
        // The runtime folds the platform's PRIMARY modifier into
        // `super`. On macOS primary IS the GUI key, so the fold is
        // harmless — but on hosts whose primary is Ctrl, a bare Ctrl
        // chord arrives as ctrl+super and the encoder would skip its C0
        // byte (Ctrl+C must deliver ETX). Undo the alias: super counts
        // only when Ctrl is not the key raising it.
        const encoder_super = mods.super and !mods.control;
        _ = vt.input.encodeKey(&writer, .{
            .key = key.key,
            .action = action,
            .mods = .{
                .shift = mods.shift,
                .ctrl = mods.control,
                .alt = mods.alt,
                .super = encoder_super,
            },
            .utf8 = key.utf8,
            .unshifted_codepoint = key.unshifted,
        }, encode_options) catch return;
        if (writer.end == 0) return;
        const before = session.scrollbarState().offset;
        session.scrollToBottom();
        if (session.scrollbarState().offset != before) session.snapshot_dirty = true;
        session.enqueueTransient(gateway, pty_key, buffer[0..writer.end]);
    }

    fn macosNaturalTextKeyMask(key: []const u8) u8 {
        if (comptime builtin.os.tag != .macos) return 0;
        if (std.ascii.eqlIgnoreCase(key, "arrowleft")) return 1 << 0;
        if (std.ascii.eqlIgnoreCase(key, "arrowright")) return 1 << 1;
        if (std.ascii.eqlIgnoreCase(key, "backspace")) return 1 << 2;
        return 0;
    }

    /// Match macOS terminals' "natural text editing" bindings. These are
    /// exact bare-modifier gestures: shifted or combined chords continue
    /// through the key encoder so terminal applications can distinguish
    /// them. The raw bindings intentionally bypass negotiated kitty
    /// reporting, just as Ghostty's own default keybinds do.
    fn macosNaturalTextSequence(event: canvas.WidgetKeyboardEvent) ?[]const u8 {
        if (comptime builtin.os.tag != .macos) return null;
        const mods = event.modifiers;
        if (mods.shift or mods.control) return null;
        if (mods.alt and !mods.super) {
            if (std.ascii.eqlIgnoreCase(event.key, "arrowleft")) return "\x1bb";
            if (std.ascii.eqlIgnoreCase(event.key, "arrowright")) return "\x1bf";
        }
        if (mods.super and !mods.alt) {
            if (std.ascii.eqlIgnoreCase(event.key, "arrowleft")) return "\x01";
            if (std.ascii.eqlIgnoreCase(event.key, "arrowright")) return "\x05";
            // The physical macOS Delete key is normalized as Backspace.
            if (std.ascii.eqlIgnoreCase(event.key, "backspace")) return "\x15";
        }
        return null;
    }

    /// Committed text reaches the child through the emulator's key
    /// encoder when it is a single scalar (byte-identical under legacy
    /// modes, the negotiated CSI-u form when a TUI enabled the kitty
    /// protocol's report-all mode); multi-scalar commits (IME words,
    /// paste) stay raw text, the protocol's rule for composed input.
    fn sendCommittedText(session: *Session, gateway: ?PtyGateway, pty_key: u64, text: []const u8) void {
        single: {
            const len = std.unicode.utf8ByteSequenceLength(text[0]) catch break :single;
            if (text.len != len) break :single;
            const cp = std.unicode.utf8Decode(text[0..len]) catch break :single;
            var buffer: [128]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            _ = vt.input.encodeKey(&writer, .{
                .key = .unidentified,
                .action = .press,
                .utf8 = text,
                .unshifted_codepoint = cp,
            }, .fromTerminal(&session.term)) catch break :single;
            if (writer.end == 0) break :single;
            session.enqueueTransient(gateway, pty_key, buffer[0..writer.end]);
            return;
        }
        session.enqueueTransient(gateway, pty_key, text);
    }

    const MappedKey = struct {
        key: vt.input.Key,
        utf8: []const u8 = "",
        unshifted: u21 = 0,
    };

    /// A plain printable's codepoint-keyed event, for RELEASE encoding
    /// only: its press travels the committed-text channel, but kitty
    /// event reporting still owes the child the release. No text rides
    /// a release.
    fn mapPrintable(key: []const u8) ?MappedKey {
        if (key.len == 0) return null;
        const len = std.unicode.utf8ByteSequenceLength(key[0]) catch return null;
        if (key.len != len) return null;
        const cp = std.unicode.utf8Decode(key[0..len]) catch return null;
        return .{ .key = .unidentified, .unshifted = cp };
    }

    /// Host key names -> emulator key codes: specials always;
    /// letters/digits/punctuation only under a chord modifier, where the
    /// text channel stays silent and the encoder must speak.
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
            if (std.ascii.eqlIgnoreCase(key, entry.name)) return .{ .key = entry.key };
        }
        // Chorded character keys (ctrl+c, alt+f, ...): the text channel
        // is silent for these, so the encoder builds the control
        // sequence. Alt is a chord EXCEPT on macOS (Option composes
        // text); Ctrl+Alt together on Windows is AltGr and composes.
        const altgr = event.modifiers.control and event.modifiers.alt and builtin.os.tag == .windows;
        const alt_is_chord = event.modifiers.alt and builtin.os.tag != .macos;
        const chorded = (event.modifiers.control or event.modifiers.super or alt_is_chord) and !altgr;
        if (!chorded) return null;
        if (key.len == 1) {
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
            // Chorded punctuation carries real control meaning (Ctrl+[
            // is the ESC chord, Ctrl+\ is SIGQUIT) with no text-channel
            // fallback — an unmapped key here is silently lost input.
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
        if (std.ascii.eqlIgnoreCase(key, "space")) return .{ .key = .space, .utf8 = " ", .unshifted = ' ' };
        return null;
    }

    // --------------------------------------------------------- snapshot

    /// Rebuild the published `canvas.TerminalGrid` from the emulator's
    /// render state, colors RESOLVED per the painter's contract: the
    /// theme-derived ANSI-16 story (untouched palette entries derive
    /// from the active tokens; an OSC-restyled slot wins verbatim),
    /// exact 256-color and truecolor pass-through, inverse/faint/
    /// invisible folded in, and a spacer cell's background pre-resolved
    /// to extend its wide primary's.
    fn rebuildSnapshot(session: *Session, tokens: canvas.DesignTokens) !void {
        const gpa = session.gpa;
        // Push the theme colors into the emulator's DEFAULTS (never the
        // OSC overrides) so ghostty itself composes the final
        // foreground/background/cursor: an application's OSC 10/11/12
        // override wins, and DECSCNM swaps whichever pair is in effect.
        session.term.colors.foreground.default = themeRgb(tokens.colors.text);
        session.term.colors.background.default = themeRgb(tokens.colors.background);
        session.term.colors.cursor.default = themeRgb(tokens.colors.accent);
        const metrics = canvas.terminalCellMetrics(tokens);
        session.cell_width = metrics.width;
        session.cell_height = metrics.height;

        try session.render.update(gpa, &session.term);
        const rs = &session.render;
        const palette = Palette.init(tokens, &rs.colors, &session.term.colors.palette);

        const row_count = @min(rs.row_data.len, canvas.max_terminal_rows);
        var col_count: usize = 0;
        var cluster_bytes: usize = 0;
        var index: usize = 0;
        while (index < row_count) : (index += 1) {
            const row = rs.row_data.get(index);
            col_count = @max(col_count, row.cells.len);
            var x: usize = 0;
            while (x < row.cells.len) : (x += 1) {
                cluster_bytes += cellClusterBytes(row.cells.get(x));
            }
        }
        // Widen before multiplying: `@min` against a comptime bound
        // REFINES its result type to the bound's range (u7-by-u9 here),
        // and the product does not fit the refined peer type.
        const cell_count = @as(usize, row_count) * @as(usize, @min(col_count, canvas.max_terminal_cols));
        if (session.cells_buf.len < cell_count) {
            if (session.cells_buf.len > 0) gpa.free(session.cells_buf);
            session.cells_buf = &.{};
            session.cells_buf = try gpa.alloc(canvas.TerminalCell, cell_count);
        }
        if (session.cluster_buf.len < cluster_bytes) {
            if (session.cluster_buf.len > 0) gpa.free(session.cluster_buf);
            session.cluster_buf = &.{};
            session.cluster_buf = try gpa.alloc(u8, cluster_bytes);
        }

        var cell_index: usize = 0;
        var cluster_len: usize = 0;
        var y: usize = 0;
        while (y < row_count) : (y += 1) {
            const row = rs.row_data.get(y);
            const cols_here = @min(row.cells.len, canvas.max_terminal_cols);
            const row_start = cell_index;
            var prev_bg: ?canvas.Color = null;
            var x: usize = 0;
            while (x < cols_here) : (x += 1) {
                const cell = row.cells.get(x);
                var out: canvas.TerminalCell = .{ .fg = palette.foreground };
                out.wide = switch (cell.raw.wide) {
                    .wide => .wide,
                    .spacer_tail, .spacer_head => .spacer,
                    else => .narrow,
                };
                // A wide glyph's style lives on its PRIMARY cell only:
                // the spacer tail extends the primary's background, or a
                // styled wide character would paint over half its width.
                out.bg = if (cell.raw.wide == .spacer_tail)
                    prev_bg
                else
                    cellBackground(cell, &palette);
                prev_bg = out.bg;
                var cp: u21 = switch (cell.raw.content_tag) {
                    .codepoint, .codepoint_grapheme => cell.raw.content.codepoint.data,
                    else => 0,
                };
                if (out.wide == .spacer) cp = 0;
                if (cp != 0 and cell.raw.style_id != 0) {
                    const style = cell.style;
                    out.fg = palette.resolveFg(style);
                    out.underline = style.flags.underline != .none;
                    if (style.flags.invisible) cp = 0;
                }
                out.cp = cp;
                // Box-drawing cells render as geometry from `cp` alone;
                // their cluster stays empty (the painter's contract).
                if (cp != 0 and !canvas.terminal_box.isBoxDrawing(cp)) {
                    const start = cluster_len;
                    cluster_len += std.unicode.utf8Encode(cp, session.cluster_buf[cluster_len..]) catch 0;
                    if (cell.raw.content_tag == .codepoint_grapheme) {
                        for (cell.grapheme) |extra| {
                            cluster_len += std.unicode.utf8Encode(extra, session.cluster_buf[cluster_len..]) catch 0;
                        }
                    }
                    out.cluster = session.cluster_buf[start..cluster_len];
                }
                session.cells_buf[cell_index] = out;
                cell_index += 1;
            }
            session.rows_buf[y] = .{
                .cells = session.cells_buf[row_start..cell_index],
                .selection = if (row.selection) |selection| .{
                    @intCast(selection[0]),
                    @intCast(selection[1]),
                } else null,
            };
        }

        // The viewport as plain text: the widget's semantic content and
        // the fingerprint's text-coverage layer. Unknown beats stale on
        // failure — empty never reads as "same as before".
        const text = session.term.plainString(gpa) catch blk: {
            break :blk @as(?[]const u8, null);
        };
        if (session.screen_text.len > 0) gpa.free(session.screen_text);
        session.screen_text = text orelse &.{};

        // Clipboard text comes from the emulator's selection formatter,
        // not byte offsets into `screen_text`: this preserves soft-wrap,
        // wide-cell, word, and line semantics exactly.
        if (session.selection_text) |selection| gpa.free(selection);
        session.selection_text = if (session.term.screens.active.selection) |selection|
            session.term.screens.active.selectionString(gpa, .{
                .sel = selection,
                .trim = true,
            }) catch null
        else
            null;

        const bar = session.scrollbarState();
        session.grid = .{
            .rows = session.rows_buf[0..row_count],
            .background = rgbToColor(rs.colors.background),
            .foreground = rgbToColor(rs.colors.foreground),
            .cursor_color = if (rs.colors.cursor) |cur| rgbToColor(cur) else tokens.colors.accent,
            .selection_color = tokens.colors.accent,
            .cursor = if (rs.cursor.visible) cursor: {
                const viewport = rs.cursor.viewport orelse break :cursor null;
                break :cursor .{
                    .x = @intCast(viewport.x),
                    .y = @intCast(viewport.y),
                    .shape = switch (rs.cursor.visual_style) {
                        .bar => .bar,
                        .underline => .underline,
                        else => .block,
                    },
                };
            } else null,
            .running = !session.ended,
            .select_head = null,
            .scrollbar = .{
                .offset = @intCast(bar.offset),
                .len = @intCast(bar.len),
                .total = @intCast(bar.total),
            },
            .screen_text = session.screen_text,
            .selection_text = if (session.selection_text) |selection| selection else "",
            .selection_active = session.term.screens.active.selection != null,
        };
        session.snapshot_dirty = false;
    }

    /// UTF-8 byte need of one cell's cluster, mirroring the snapshot
    /// loop's emissions exactly (spacers, invisible cells, and
    /// box-drawing cells contribute nothing).
    fn cellClusterBytes(cell: anytype) usize {
        if (cell.raw.wide == .spacer_tail or cell.raw.wide == .spacer_head) return 0;
        const cp: u21 = switch (cell.raw.content_tag) {
            .codepoint, .codepoint_grapheme => cell.raw.content.codepoint.data,
            else => 0,
        };
        if (cp == 0) return 0;
        if (cell.raw.style_id != 0 and cell.style.flags.invisible) return 0;
        if (canvas.terminal_box.isBoxDrawing(cp)) return 0;
        var n: usize = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
        if (cell.raw.content_tag == .codepoint_grapheme) {
            for (cell.grapheme) |extra| {
                n += std.unicode.utf8CodepointSequenceLength(extra) catch 1;
            }
        }
        return n;
    }

    /// A theme token color (f32 rgba 0..1) as the emulator's 8-bit RGB.
    fn themeRgb(color: canvas.Color) vt.color.RGB {
        return .{
            .r = @intFromFloat(std.math.clamp(color.r, 0, 1) * 255 + 0.5),
            .g = @intFromFloat(std.math.clamp(color.g, 0, 1) * 255 + 0.5),
            .b = @intFromFloat(std.math.clamp(color.b, 0, 1) * 255 + 0.5),
        };
    }

    fn cellBackground(cell: anytype, palette: *const Palette) ?canvas.Color {
        switch (cell.raw.content_tag) {
            .bg_color_palette => return palette.indexed(cell.raw.content.color_palette.data),
            .bg_color_rgb => {
                const rgb = cell.raw.content.color_rgb;
                return canvas.Color.rgb8(rgb.r, rgb.g, rgb.b);
            },
            else => {},
        }
        if (cell.raw.style_id == 0) return null;
        const style = cell.style;
        if (style.flags.inverse) {
            return palette.resolveFgRaw(style);
        }
        return switch (style.bg_color) {
            .none => null,
            .palette => |index| palette.indexed(index),
            .rgb => |rgb| canvas.Color.rgb8(rgb.r, rgb.g, rgb.b),
        };
    }
} else struct {
    fn unused() void {}
};

// ------------------------------------------------------------- palette

fn rgbToColor(rgb: anytype) canvas.Color {
    return canvas.Color.rgb8(rgb.r, rgb.g, rgb.b);
}

/// The theme mapping, stated plainly: where the emulator's palette entry
/// still holds its DEFAULT value, the ANSI-16 slot derives from the
/// active theme tokens so a themed app and its terminal read as one
/// surface. The moment a program restyles an entry (OSC 4), the
/// programmed color wins verbatim — and the cube (16..231), the
/// grayscale ramp (232..255), and truecolor always pass through exactly.
/// (The example tier's palette, promoted with the session store.)
const Palette = if (enabled) struct {
    background: canvas.Color,
    foreground: canvas.Color,
    ansi: [16]canvas.Color,
    /// The emulator's live palette WITH its override mask, so an
    /// explicit OSC 4 set is honored even when it equals the default
    /// RGB — the mask, not RGB equality, decides "untouched".
    dynamic: *const vt.color.DynamicPalette,

    fn init(tokens: canvas.DesignTokens, terminal_colors: *const vt.RenderState.Colors, dynamic: *const vt.color.DynamicPalette) Palette {
        const colors = tokens.colors;
        const dark = colors.background.r + colors.background.g + colors.background.b < 1.5;
        const dim: f32 = if (dark) 0.85 else 1.0;
        const bright: f32 = if (dark) 1.0 else 0.8;
        return .{
            .background = rgbToColor(terminal_colors.background),
            .foreground = rgbToColor(terminal_colors.foreground),
            .dynamic = dynamic,
            .ansi = .{
                // 0-7: black, red, green, yellow, blue, magenta, cyan, white.
                blend(colors.text, colors.background, if (dark) 0.35 else 0.95),
                scale(colors.destructive, dim),
                scale(colors.success, dim),
                scale(colors.warning, dim),
                scale(canvas.Color.rgb8(37, 99, 235), dim),
                scale(canvas.Color.rgb8(147, 51, 234), dim),
                scale(canvas.Color.rgb8(8, 145, 178), dim),
                blend(colors.text, colors.background, if (dark) 0.75 else 0.35),
                // 8-15: the bright ramp.
                blend(colors.text, colors.background, if (dark) 0.5 else 0.75),
                scale(colors.destructive, bright),
                scale(colors.success, bright),
                scale(colors.warning, bright),
                scale(canvas.Color.rgb8(59, 130, 246), bright),
                scale(canvas.Color.rgb8(168, 85, 247), bright),
                scale(canvas.Color.rgb8(34, 211, 238), bright),
                colors.text,
            },
        };
    }

    fn indexed(palette: *const Palette, index: u8) canvas.Color {
        if (index < 16 and !palette.dynamic.mask.isSet(index)) {
            return palette.ansi[index];
        }
        const live = palette.dynamic.current[index];
        return canvas.Color.rgb8(live.r, live.g, live.b);
    }

    fn resolveFg(palette: *const Palette, style: vt.Style) canvas.Color {
        if (style.flags.inverse) {
            // Inverse paints the text in the cell's BACKGROUND color
            // (the theme background when the cell chose none) — the
            // opposite of `cellBackground`, which paints the swapped
            // foreground behind it.
            return palette.resolveBgRaw(style);
        }
        var color = palette.resolveFgRaw(style);
        if (style.flags.faint) color = blend(color, palette.background, 0.5);
        return color;
    }

    fn resolveFgRaw(palette: *const Palette, style: vt.Style) canvas.Color {
        return switch (style.fg_color) {
            .none => palette.foreground,
            .palette => |index| palette.indexed(index),
            .rgb => |rgb| canvas.Color.rgb8(rgb.r, rgb.g, rgb.b),
        };
    }

    fn resolveBgRaw(palette: *const Palette, style: vt.Style) canvas.Color {
        return switch (style.bg_color) {
            .none => palette.background,
            .palette => |index| palette.indexed(index),
            .rgb => |rgb| canvas.Color.rgb8(rgb.r, rgb.g, rgb.b),
        };
    }

    fn blend(a: canvas.Color, b: canvas.Color, t: f32) canvas.Color {
        return canvas.Color.rgba(
            a.r + (b.r - a.r) * t,
            a.g + (b.g - a.g) * t,
            a.b + (b.b - a.b) * t,
            1,
        );
    }

    fn scale(color: canvas.Color, factor: f32) canvas.Color {
        return canvas.Color.rgba(
            @min(1, color.r * factor),
            @min(1, color.g * factor),
            @min(1, color.b * factor),
            1,
        );
    }
} else struct {};
