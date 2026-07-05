//! system-monitor model: sampling state, stat history, the process table,
//! and the SIGTERM confirmation flow.
//!
//! The effects loop is the app: a repeating `fx.startTimer` tick spawns
//! `ps` and the per-OS memory command in `.collect` mode, each exit Msg
//! carries the whole stdout, and `update` parses it (`sampler.zig`) into
//! the model. Everything the views show that is computable — filtered and
//! sorted table rows, sparkline fractions, formatted sizes — is derived
//! per rebuild into the build arena, never stored.
//!
//! Fixed capacities (loud by design, documented in the README):
//!   - 60 samples of history per charted stat (2 s cadence = a 2-minute
//!     window), shifted in place
//!   - 128 top-CPU process rows kept per sample (`sampler.max_rows`);
//!     the total count and CPU sum still cover every process
//!   - 14 table rows shown (`max_table_rows`), 48-byte process names,
//!     32-byte search buffer, 160-byte status note
//!
//! Safety (the kill path): terminating a process sends SIGTERM — the
//! polite, catchable request — via `/bin/kill -TERM <pid>`, and only after
//! an explicit confirmation dialog that names the process and pid. There
//! is no SIGKILL anywhere in this app. The pid and name are copied into
//! the model when the dialog opens, so later samples (or a vanished
//! process) can never retarget a confirmation the user is reading.

const std = @import("std");
const native_sdk = @import("native_sdk");
pub const sampler = @import("sampler.zig");

const canvas = native_sdk.canvas;

pub const Effects = native_sdk.Effects(Msg);

// ------------------------------------------------------------ capacities

/// Sparkline history depth: 60 samples at the 2 s cadence = 2 minutes.
pub const history_len = 60;
/// Sampling cadence.
pub const sample_interval_ms: u32 = 2000;
/// Process rows the table shows (of the `sampler.max_rows` kept).
pub const max_table_rows = 14;
pub const max_search = 32;
pub const max_note = 160;

// Effect keys, model-owned identity. Timer keys are their own namespace.
pub const sample_timer_key: u64 = 1;
pub const ps_key: u64 = 2;
pub const mem_key: u64 = 3;
pub const info_key: u64 = 4;
pub const kill_key: u64 = 5;
pub const copy_key: u64 = 6;

// ----------------------------------------------------------------- types

pub const SortKey = enum { cpu, mem, pid, name };

pub const Msg = union(enum) {
    /// The repeating sample timer fired: spawn this tick's commands.
    tick: native_sdk.EffectTimer,
    /// Collected `ps` output (or its failure) arrived.
    ps_done: native_sdk.EffectExit,
    /// Collected memory-command output arrived.
    mem_done: native_sdk.EffectExit,
    /// Boot-time host info (core count, macOS total memory) arrived.
    info_done: native_sdk.EffectExit,
    /// Pause/resume sampling (cancels or restarts the repeating timer).
    toggle_sampling,
    search_edit: canvas.TextInputEvent,
    /// Controlled scroll: the process table's applied offset lands here
    /// and the view echoes it back, so a sample-tick rebuild mid-gesture
    /// can never reset the table.
    table_scrolled: canvas.ScrollState,
    /// Sort chip pressed: switch to this key, or flip direction when it
    /// is already active.
    set_sort: SortKey,
    /// Context menu: open the SIGTERM confirmation for this pid.
    request_kill: u32,
    cancel_kill,
    /// The dialog body absorbs presses (deepest handler wins), so a click
    /// inside the dialog never reaches the scrim's cancel underneath.
    dialog_pressed,
    /// Dialog confirmed: spawn `/bin/kill -TERM <pid>`.
    confirm_kill,
    kill_done: native_sdk.EffectExit,
    /// Context menu: copy the process name to the system clipboard.
    copy_name: u32,
    copied: native_sdk.EffectClipboardResult,
    set_appearance: native_sdk.Appearance,
    /// Toolbar gear: show/hide the settings WINDOW (model-declared —
    /// the window exists exactly while this flag is set).
    toggle_settings,
    /// The user closed the settings window (its close button): the
    /// model owns the consequence and clears the flag.
    settings_closed,
};

/// The confirmation target, copied out of the row at request time.
pub const PendingKill = struct {
    pid: u32,
    name_storage: [sampler.max_name_bytes]u8,
    name_len: usize,

    pub fn name(self: *const PendingKill) []const u8 {
        return self.name_storage[0..self.name_len];
    }
};

pub const Model = struct {
    // Sampling state.
    paused: bool = false,
    /// Sampling ticks skipped because the previous spawn had not exited
    /// yet (never overlap two ps runs; count the lag honestly).
    ticks_skipped: u32 = 0,
    ps_inflight: bool = false,
    mem_inflight: bool = false,
    samples_taken: u32 = 0,
    /// Wall-clock ms of the last applied ps sample (0 = none yet).
    sampled_at_ms: i64 = 0,
    /// Time seam (`native_sdk.Clock`) so tests drive the sample
    /// timestamps deterministically.
    clock: native_sdk.Clock = .system,

    // Host facts (boot-time info spawn; memory total may also ride the
    // Linux memory sample).
    cores: u32 = 0,
    mem_total_bytes: u64 = 0,

    // Latest sample.
    cpu_percent: f32 = 0,
    mem_used_bytes: u64 = 0,
    process_count: u32 = 0,
    uptime_seconds: u64 = 0,
    rows: [sampler.max_rows]sampler.Process = undefined,
    row_count: usize = 0,
    parse_failures: u32 = 0,

    // History, oldest first, shifted in place at capacity.
    cpu_history: [history_len]f32 = undefined,
    cpu_history_len: usize = 0,
    mem_history: [history_len]f32 = undefined,
    mem_history_len: usize = 0,
    proc_history: [history_len]f32 = undefined,
    proc_history_len: usize = 0,

    // Table state.
    search_buffer: canvas.TextBuffer(max_search) = .{},
    sort_key: SortKey = .cpu,
    sort_descending: bool = true,
    pending_kill: ?PendingKill = null,
    /// Controlled scroll offset for the process table: the model
    /// observes the applied offset and echoes it back.
    table_scroll: f32 = 0,

    // Status note + appearance (the app follows the system; no
    // in-window theme control by design).
    note_storage: [max_note]u8 = undefined,
    note_len: usize = 0,
    appearance: native_sdk.Appearance = .{},
    /// The settings window's open flag: `windows_fn` declares the
    /// window while this is set, so a Msg opens it and a Msg (or the
    /// user's close button, via `settings_closed`) closes it.
    settings_open: bool = false,

    // ------------------------------------------------------------ queries

    pub fn search(model: *const Model) []const u8 {
        return model.search_buffer.text();
    }

    pub fn searching(model: *const Model) bool {
        return model.search().len > 0;
    }

    pub fn note(model: *const Model) []const u8 {
        return model.note_storage[0..model.note_len];
    }

    pub fn setNote(model: *Model, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&model.note_storage, fmt, args) catch {
            model.note_len = 0;
            return;
        };
        model.note_len = written.len;
    }

    pub fn colorScheme(model: *const Model) native_sdk.ColorScheme {
        return model.appearance.color_scheme;
    }

    pub fn sampling(model: *const Model) bool {
        return !model.paused;
    }

    pub fn confirmingKill(model: *const Model) bool {
        return model.pending_kill != null;
    }

    /// Header status: what the monitor is doing right now.
    pub fn headerStatus(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (!sampler.supported) return "Sampling is not supported on this OS";
        if (model.paused) return "Paused";
        if (model.samples_taken == 0) return "Sampling…";
        return std.fmt.allocPrint(arena, "Live · every {d} s", .{sample_interval_ms / 1000}) catch "";
    }

    // Tile values, derived per rebuild.

    pub fn cpuValue(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (model.samples_taken == 0) return "--";
        return std.fmt.allocPrint(arena, "{d:.1}%", .{model.cpu_percent}) catch "--";
    }

    pub fn cpuDetail(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (model.cores == 0) return "of all cores";
        return std.fmt.allocPrint(arena, "across {d} cores", .{model.cores}) catch "";
    }

    pub fn memValue(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (model.mem_used_bytes == 0) return "--";
        return formatBytes(arena, model.mem_used_bytes);
    }

    pub fn memDetail(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (model.mem_total_bytes == 0) return "in use";
        return std.fmt.allocPrint(arena, "of {s} · {d:.0}%", .{
            formatBytes(arena, model.mem_total_bytes),
            model.memFraction() * 100,
        }) catch "";
    }

    pub fn memFraction(model: *const Model) f32 {
        if (model.mem_total_bytes == 0) return 0;
        const used: f64 = @floatFromInt(model.mem_used_bytes);
        const total: f64 = @floatFromInt(model.mem_total_bytes);
        return std.math.clamp(@as(f32, @floatCast(used / total)), 0, 1);
    }

    pub fn procValue(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (model.samples_taken == 0) return "--";
        return std.fmt.allocPrint(arena, "{d}", .{model.process_count}) catch "--";
    }

    pub fn uptimeValue(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (model.samples_taken == 0) return "--";
        return formatUptime(arena, model.uptime_seconds);
    }

    pub fn cpuHistory(model: *const Model) []const f32 {
        return model.cpu_history[0..model.cpu_history_len];
    }

    pub fn memHistory(model: *const Model) []const f32 {
        return model.mem_history[0..model.mem_history_len];
    }

    pub fn procHistory(model: *const Model) []const f32 {
        return model.proc_history[0..model.proc_history_len];
    }

    // Sort chip selection (used by the view's toggle buttons).
    pub fn sortedByCpu(model: *const Model) bool {
        return model.sort_key == .cpu;
    }
    pub fn sortedByMem(model: *const Model) bool {
        return model.sort_key == .mem;
    }
    pub fn sortedByPid(model: *const Model) bool {
        return model.sort_key == .pid;
    }
    pub fn sortedByName(model: *const Model) bool {
        return model.sort_key == .name;
    }

    /// The status-bar line: sample facts, then any activity note. Bounded
    /// composition into one arena buffer (parts past the cap drop whole,
    /// never mid-glyph).
    pub fn statusLine(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (!sampler.supported) return "This build has no sampler for the host OS — see the README.";
        const buffer = arena.alloc(u8, 320) catch return "";
        var len: usize = 0;
        if (model.samples_taken == 0) {
            appendPart(buffer, &len, "Waiting for the first sample…", .{});
        } else {
            appendPart(buffer, &len, "{d} processes · sampled at {s}", .{
                model.process_count, formatClockMs(arena, model.sampled_at_ms),
            });
            if (model.paused) appendPart(buffer, &len, " · paused", .{});
            if (model.ticks_skipped > 0) appendPart(buffer, &len, " · {d} ticks skipped", .{model.ticks_skipped});
            if (model.parse_failures > 0) appendPart(buffer, &len, " · {d} parse failures", .{model.parse_failures});
        }
        if (model.note_len > 0) appendPart(buffer, &len, " · {s}", .{model.note()});
        return buffer[0..len];
    }

    fn appendPart(buffer: []u8, len: *usize, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(buffer[len.*..], fmt, args) catch return;
        len.* += written.len;
    }

    /// Table rows: search-filtered, sorted by the active key/direction,
    /// cut to `max_table_rows`, derived into the build arena.
    pub fn visibleRows(model: *const Model, arena: std.mem.Allocator) []const TableRow {
        var matches: [sampler.max_rows]*const sampler.Process = undefined;
        var match_count: usize = 0;
        const query = model.search();
        for (model.rows[0..model.row_count]) |*row| {
            if (!rowMatches(row, query, arena)) continue;
            matches[match_count] = row;
            match_count += 1;
        }
        std.mem.sort(*const sampler.Process, matches[0..match_count], model, rowLessThan);

        const shown = @min(match_count, max_table_rows);
        const out = arena.alloc(TableRow, shown) catch return &.{};
        for (out, matches[0..shown]) |*slot, row| {
            slot.* = .{
                .pid = row.pid,
                .pid_text = std.fmt.allocPrint(arena, "{d}", .{row.pid}) catch "",
                .name = arena.dupe(u8, row.name()) catch "",
                .cpu_text = std.fmt.allocPrint(arena, "{d:.1}", .{row.cpu}) catch "",
                .mem_text = formatBytes(arena, row.rss_kb * 1024),
            };
        }
        return out;
    }

    pub fn matchCount(model: *const Model, arena: std.mem.Allocator) usize {
        var count: usize = 0;
        const query = model.search();
        for (model.rows[0..model.row_count]) |*row| {
            if (rowMatches(row, query, arena)) count += 1;
        }
        return count;
    }

    fn rowMatches(row: *const sampler.Process, query: []const u8, arena: std.mem.Allocator) bool {
        if (query.len == 0) return true;
        if (containsIgnoreCase(row.name(), query)) return true;
        const pid_text = std.fmt.allocPrint(arena, "{d}", .{row.pid}) catch return false;
        return std.mem.indexOf(u8, pid_text, query) != null;
    }

    /// Strict weak ordering (std.mem.sort asserts it): compare by the
    /// active key, break ties by pid (unique), then apply the direction.
    fn rowLessThan(model: *const Model, a: *const sampler.Process, b: *const sampler.Process) bool {
        const keyed = switch (model.sort_key) {
            .cpu => std.math.order(a.cpu, b.cpu),
            .mem => std.math.order(a.rss_kb, b.rss_kb),
            .pid => std.math.order(a.pid, b.pid),
            .name => orderIgnoreCase(a.name(), b.name()),
        };
        const order = if (keyed == .eq) std.math.order(a.pid, b.pid) else keyed;
        return switch (order) {
            .lt => !model.sort_descending,
            .gt => model.sort_descending,
            .eq => false,
        };
    }

    // ----------------------------------------------------------- mutation

    fn pushHistory(history: *[history_len]f32, len: *usize, value: f32) void {
        if (len.* == history_len) {
            std.mem.copyForwards(f32, history[0 .. history_len - 1], history[1..]);
            len.* = history_len - 1;
        }
        history[len.*] = value;
        len.* += 1;
    }

    fn applyPsSample(model: *Model, sample: sampler.PsSample) void {
        model.process_count = sample.process_count;
        model.uptime_seconds = sample.uptime_seconds;
        model.rows = sample.rows;
        model.row_count = sample.row_count;
        // Machine load: the summed per-process %cpu normalized by core
        // count (100 = every core saturated). Honest about the source:
        // ps %cpu is a per-process decaying average, so this is a smooth
        // load figure, not an instantaneous one.
        const cores: f32 = @floatFromInt(@max(model.cores, 1));
        model.cpu_percent = std.math.clamp(sample.cpu_sum / cores, 0, 100);
        model.samples_taken += 1;
        model.sampled_at_ms = model.clock.wallMs();
        if (sample.skipped_lines > 0) model.parse_failures += sample.skipped_lines;
        pushHistory(&model.cpu_history, &model.cpu_history_len, model.cpu_percent / 100);
        pushHistory(&model.proc_history, &model.proc_history_len, @floatFromInt(sample.process_count));
    }

    fn applyMemSample(model: *Model, sample: sampler.MemSample) void {
        model.mem_used_bytes = sample.used_bytes;
        if (sample.total_bytes > 0) model.mem_total_bytes = sample.total_bytes;
        pushHistory(&model.mem_history, &model.mem_history_len, model.memFraction());
    }
};

pub const TableRow = struct {
    pid: u32,
    pid_text: []const u8,
    name: []const u8,
    cpu_text: []const u8,
    mem_text: []const u8,
};

// ------------------------------------------------------------ formatting

/// Human-readable bytes: whole KB/MB below 10, one decimal GB above.
pub fn formatBytes(arena: std.mem.Allocator, bytes: u64) []const u8 {
    const value: f64 = @floatFromInt(bytes);
    if (bytes >= 1024 * 1024 * 1024) {
        return std.fmt.allocPrint(arena, "{d:.1} GB", .{value / (1024 * 1024 * 1024)}) catch "";
    }
    if (bytes >= 1024 * 1024) {
        return std.fmt.allocPrint(arena, "{d:.0} MB", .{value / (1024 * 1024)}) catch "";
    }
    return std.fmt.allocPrint(arena, "{d:.0} KB", .{value / 1024}) catch "";
}

/// Uptime: `4d 03:12` past a day, `03:12:45` under one.
pub fn formatUptime(arena: std.mem.Allocator, seconds: u64) []const u8 {
    const days = seconds / 86_400;
    const hours = (seconds % 86_400) / 3600;
    const minutes = (seconds % 3600) / 60;
    if (days > 0) {
        return std.fmt.allocPrint(arena, "{d}d {d:0>2}:{d:0>2}", .{ days, hours, minutes }) catch "";
    }
    return std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds % 60 }) catch "";
}

/// Wall-clock ms -> local-agnostic `HH:MM:SS` (UTC; the point is "how
/// fresh", not a calendar).
pub fn formatClockMs(arena: std.mem.Allocator, wall_ms: i64) []const u8 {
    const total_seconds = @divFloor(wall_ms, 1000);
    const day_seconds: u64 = @intCast(@mod(total_seconds, 86_400));
    return std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}:{d:0>2}", .{
        day_seconds / 3600, (day_seconds % 3600) / 60, day_seconds % 60,
    }) catch "";
}

fn orderIgnoreCase(a: []const u8, b: []const u8) std.math.Order {
    const shorter = @min(a.len, b.len);
    for (a[0..shorter], b[0..shorter]) |a_byte, b_byte| {
        const order = std.math.order(std.ascii.toLower(a_byte), std.ascii.toLower(b_byte));
        if (order != .eq) return order;
    }
    return std.math.order(a.len, b.len);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

// ---------------------------------------------------------------- update

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .tick => |timer| {
            if (timer.outcome != .fired) return;
            requestSample(model, fx);
        },
        .ps_done => |exit| {
            model.ps_inflight = false;
            if (exit.reason != .exited or exit.code != 0) {
                model.setNote("ps failed ({s}, code {d})", .{ @tagName(exit.reason), exit.code });
                return;
            }
            if (exit.output_truncated) model.parse_failures += 1;
            model.applyPsSample(sampler.parsePs(exit.output));
        },
        .mem_done => |exit| {
            model.mem_inflight = false;
            if (exit.reason != .exited or exit.code != 0) {
                model.setNote("memory sample failed ({s}, code {d})", .{ @tagName(exit.reason), exit.code });
                return;
            }
            const sample = sampler.parseMemory(exit.output) orelse {
                model.parse_failures += 1;
                return;
            };
            model.applyMemSample(sample);
        },
        .info_done => |exit| {
            if (exit.reason != .exited or exit.code != 0) return;
            const info = sampler.parseHostInfo(exit.output) orelse return;
            model.cores = info.cores;
            if (info.memory_bytes > 0) model.mem_total_bytes = info.memory_bytes;
        },
        .toggle_sampling => setSampling(model, fx, model.paused),
        .search_edit => |edit| model.search_buffer.apply(edit),
        .table_scrolled => |state| model.table_scroll = state.offset,
        .set_sort => |key| {
            if (model.sort_key == key) {
                model.sort_descending = !model.sort_descending;
            } else {
                model.sort_key = key;
                // Fresh keys start in their natural direction: biggest
                // first for the numeric loads, a-to-z and low pids first.
                model.sort_descending = key == .cpu or key == .mem;
            }
        },
        .request_kill => |pid| {
            for (model.rows[0..model.row_count]) |*row| {
                if (row.pid != pid) continue;
                var pending = PendingKill{ .pid = pid, .name_storage = undefined, .name_len = row.name_len };
                @memcpy(pending.name_storage[0..row.name_len], row.name());
                model.pending_kill = pending;
                return;
            }
            model.setNote("pid {d} is gone (it left the sample)", .{pid});
        },
        .cancel_kill => model.pending_kill = null,
        .dialog_pressed => {},
        .confirm_kill => {
            const pending = model.pending_kill orelse return;
            model.pending_kill = null;
            var pid_buffer: [12]u8 = undefined;
            const pid_text = std.fmt.bufPrint(&pid_buffer, "{d}", .{pending.pid}) catch return;
            // SIGTERM only — the graceful, catchable request. argv is
            // copied by fx.spawn at call time, so the stack buffer is safe.
            fx.spawn(.{
                .key = kill_key,
                .argv = &.{ "/bin/kill", "-TERM", pid_text },
                .output = .collect,
                .on_exit = Effects.exitMsg(.kill_done),
            });
            model.setNote("SIGTERM sent to {s} (pid {d})…", .{ pending.name(), pending.pid });
        },
        .kill_done => |exit| {
            if (exit.reason == .exited and exit.code == 0) {
                model.setNote("terminate request delivered", .{});
            } else {
                model.setNote("kill failed (code {d} — not your process?)", .{exit.code});
            }
        },
        .copy_name => |pid| {
            for (model.rows[0..model.row_count]) |*row| {
                if (row.pid != pid) continue;
                fx.writeClipboard(.{
                    .key = copy_key,
                    .text = row.name(),
                    .on_result = Effects.clipboardMsg(.copied),
                });
                return;
            }
        },
        .copied => |result| {
            if (result.outcome == .ok) {
                model.setNote("name copied", .{});
            } else {
                model.setNote("copy failed ({s})", .{@tagName(result.outcome)});
            }
        },
        .set_appearance => |appearance| model.appearance = appearance,
        .toggle_settings => model.settings_open = !model.settings_open,
        .settings_closed => model.settings_open = false,
    }
}

/// TEA init: host facts once, the repeating sample timer, and an eager
/// first sample so the window never sits empty for a full interval.
pub fn boot(model: *Model, fx: *Effects) void {
    if (!sampler.supported) return;
    fx.spawn(.{
        .key = info_key,
        .argv = sampler.info_argv,
        .output = .collect,
        .on_exit = Effects.exitMsg(.info_done),
    });
    setSampling(model, fx, true);
}

/// Pause/resume both drive the repeating timer; resuming also samples
/// immediately (starting an active key replaces the timer in place, so
/// this never double-registers).
fn setSampling(model: *Model, fx: *Effects, active: bool) void {
    model.paused = !active;
    if (active) {
        fx.startTimer(.{
            .key = sample_timer_key,
            .interval_ms = sample_interval_ms,
            .mode = .repeating,
            .on_fire = Effects.timerMsg(.tick),
        });
        requestSample(model, fx);
    } else {
        fx.cancelTimer(sample_timer_key);
    }
}

/// One sampling tick: spawn ps + the memory command in `.collect` mode.
/// A tick that lands while the previous spawns are still running is
/// skipped and counted — two overlapping ps runs would only add the load
/// this app is measuring.
fn requestSample(model: *Model, fx: *Effects) void {
    if (!sampler.supported) return;
    if (model.ps_inflight or model.mem_inflight) {
        model.ticks_skipped += 1;
        return;
    }
    model.ps_inflight = true;
    fx.spawn(.{
        .key = ps_key,
        .argv = sampler.ps_argv,
        .output = .collect,
        .on_exit = Effects.exitMsg(.ps_done),
    });
    model.mem_inflight = true;
    fx.spawn(.{
        .key = mem_key,
        .argv = sampler.mem_argv,
        .output = .collect,
        .on_exit = Effects.exitMsg(.mem_done),
    });
}
