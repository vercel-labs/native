//! system-monitor sampling: the OS commands one sampling tick spawns and
//! the pure parsers that turn their collected stdout into numbers.
//!
//! Everything here is `(bytes) -> struct` — no effects, no allocation, no
//! clock — so the whole module is exercised by fixture tests against
//! committed real command output (`src/fixtures/`). The effectful half
//! (timers, `fx.spawn`, in-flight bookkeeping) lives in `model.zig`.
//!
//! Portability (documented, honest): the process list is one shared
//! `ps axo pid=,pcpu=,pmem=,rss=,etime=,comm=` invocation — the exact
//! column set BSD ps (macOS) and procps ps (Linux) both accept. Memory
//! sampling switches at comptime: macOS parses `vm_stat` against an
//! `hw.memsize` total, Linux parses `/proc/meminfo` (which carries its own
//! total). Other targets get no sampler commands and the app says so in
//! the status bar instead of pretending.

const std = @import("std");
const builtin = @import("builtin");

/// Whether this build knows how to sample the host at all.
pub const supported = switch (builtin.os.tag) {
    .macos, .linux => true,
    else => false,
};

// ------------------------------------------------------------- commands

/// The shared process-list command. `=` after each column suppresses the
/// header row on both ps flavors; `comm` is last because it is the only
/// column that may contain spaces.
pub const ps_argv: []const []const u8 = &.{ "/bin/ps", "axo", "pid=,pcpu=,pmem=,rss=,etime=,comm=" };

/// The per-OS memory command (unused on unsupported targets).
pub const mem_argv: []const []const u8 = switch (builtin.os.tag) {
    .macos => &.{"/usr/bin/vm_stat"},
    else => &.{ "/bin/cat", "/proc/meminfo" },
};

/// One boot-time host-info command: core count (both) + total memory
/// (macOS only; Linux totals come with every /proc/meminfo sample).
pub const info_argv: []const []const u8 = switch (builtin.os.tag) {
    .macos => &.{ "/usr/sbin/sysctl", "-n", "hw.ncpu", "hw.memsize" },
    else => &.{"/usr/bin/nproc"},
};

// ------------------------------------------------------------ processes

/// Top-K process rows kept per sample. `ps ax` on a real desktop lists
/// 500-800 processes; the model keeps the K highest-CPU rows (an honest
/// top-K selection over the full output — never "the first K lines") plus
/// the exact total count and CPU sum across ALL rows.
pub const max_rows = 128;

/// Bytes kept of one process name (the basename of `comm`); longer names
/// are cut for display, never dropped.
pub const max_name_bytes = 48;

pub const Process = struct {
    pid: u32,
    /// Per-process CPU percent as ps reports it (100 = one full core).
    cpu: f32,
    /// Per-process share of physical memory, percent.
    mem: f32,
    /// Resident set size in KiB.
    rss_kb: u64,
    name_storage: [max_name_bytes]u8,
    name_len: usize,

    pub fn name(self: *const Process) []const u8 {
        return self.name_storage[0..self.name_len];
    }
};

pub const PsSample = struct {
    /// Exact number of parsed process rows (the "Processes" stat).
    process_count: u32 = 0,
    /// Sum of every row's %cpu. Divide by the core count for a 0-100
    /// machine load figure.
    cpu_sum: f32 = 0,
    /// Uptime in seconds, read from pid 1's `etime` (launchd/init started
    /// at boot, so its elapsed time IS the uptime — no wall-clock math).
    uptime_seconds: u64 = 0,
    /// Malformed lines skipped (loud, never silent).
    skipped_lines: u32 = 0,
    rows: [max_rows]Process = undefined,
    row_count: usize = 0,

    pub fn topRows(self: *const PsSample) []const Process {
        return self.rows[0..self.row_count];
    }
};

/// Parse whole `ps axo pid=,pcpu=,pmem=,rss=,etime=,comm=` output.
/// Keeps the top-`max_rows` rows by CPU: while the buffer is full each new
/// row replaces the current minimum only if it burns more CPU, so the
/// selection is exact regardless of ps output order.
pub fn parsePs(bytes: []const u8) PsSample {
    var sample = PsSample{};
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const row = parsePsLine(trimmed) orelse {
            sample.skipped_lines += 1;
            continue;
        };
        sample.process_count += 1;
        sample.cpu_sum += row.process.cpu;
        if (row.process.pid == 1) sample.uptime_seconds = row.etime_seconds;
        insertTopRow(&sample, row.process);
    }
    return sample;
}

const ParsedRow = struct {
    process: Process,
    etime_seconds: u64,
};

/// One ps row: five numeric columns, then `comm` as the untokenized rest
/// of the line (command paths may contain spaces — "Software Update.app").
fn parsePsLine(line: []const u8) ?ParsedRow {
    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    const pid_text = tokens.next() orelse return null;
    const cpu_text = tokens.next() orelse return null;
    const mem_text = tokens.next() orelse return null;
    const rss_text = tokens.next() orelse return null;
    const etime_text = tokens.next() orelse return null;
    const command = std.mem.trim(u8, line[tokens.index..], " \t");
    if (command.len == 0) return null;

    const pid = std.fmt.parseInt(u32, pid_text, 10) catch return null;
    const cpu = std.fmt.parseFloat(f32, cpu_text) catch return null;
    const mem = std.fmt.parseFloat(f32, mem_text) catch return null;
    const rss_kb = std.fmt.parseInt(u64, rss_text, 10) catch return null;
    const etime_seconds = parseEtime(etime_text) orelse return null;

    var process = Process{
        .pid = pid,
        .cpu = cpu,
        .mem = mem,
        .rss_kb = rss_kb,
        .name_storage = undefined,
        .name_len = 0,
    };
    const base = basename(command);
    process.name_len = @min(base.len, max_name_bytes);
    @memcpy(process.name_storage[0..process.name_len], base[0..process.name_len]);
    return .{ .process = process, .etime_seconds = etime_seconds };
}

fn insertTopRow(sample: *PsSample, process: Process) void {
    if (sample.row_count < max_rows) {
        sample.rows[sample.row_count] = process;
        sample.row_count += 1;
        return;
    }
    var min_index: usize = 0;
    for (sample.rows[1..], 1..) |row, index| {
        if (row.cpu < sample.rows[min_index].cpu) min_index = index;
    }
    if (process.cpu > sample.rows[min_index].cpu) sample.rows[min_index] = process;
}

/// `ps` elapsed time: `MM:SS`, `HH:MM:SS`, or `D-HH:MM:SS` (days can be
/// multi-digit). Returns seconds.
pub fn parseEtime(text: []const u8) ?u64 {
    var days: u64 = 0;
    var clock = text;
    if (std.mem.indexOfScalar(u8, text, '-')) |dash| {
        days = std.fmt.parseInt(u64, text[0..dash], 10) catch return null;
        clock = text[dash + 1 ..];
    }
    var parts: [3]u64 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, clock, ':');
    while (it.next()) |part| {
        if (count >= 3) return null;
        parts[count] = std.fmt.parseInt(u64, part, 10) catch return null;
        count += 1;
    }
    const clock_seconds = switch (count) {
        2 => parts[0] * 60 + parts[1],
        3 => parts[0] * 3600 + parts[1] * 60 + parts[2],
        else => return null,
    };
    return days * 86_400 + clock_seconds;
}

pub fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |index| {
        if (index + 1 < path.len) return path[index + 1 ..];
    }
    return path;
}

// --------------------------------------------------------------- memory

pub const MemSample = struct {
    /// Bytes in use. macOS counts active + wired + compressor-occupied
    /// pages (the "used" a person means: what is not reclaimable for
    /// free); Linux counts MemTotal - MemAvailable (the kernel's own
    /// availability estimate).
    used_bytes: u64 = 0,
    /// Total physical memory when the sample itself carries it
    /// (/proc/meminfo does; vm_stat does not — macOS totals come from the
    /// boot-time `hw.memsize` read). 0 = not in this sample.
    total_bytes: u64 = 0,
};

pub fn parseMemory(bytes: []const u8) ?MemSample {
    return switch (builtin.os.tag) {
        .macos => parseVmStat(bytes),
        else => parseMeminfo(bytes),
    };
}

/// macOS `vm_stat`: page counts at a page size declared on the banner
/// line. Used = active + wired down + occupied by compressor.
pub fn parseVmStat(bytes: []const u8) ?MemSample {
    var page_size: u64 = 0;
    var active: ?u64 = null;
    var wired: ?u64 = null;
    var compressor: ?u64 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "page size of ")) |index| {
            const rest = line[index + "page size of ".len ..];
            const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
            page_size = std.fmt.parseInt(u64, rest[0..end], 10) catch 0;
        } else if (std.mem.startsWith(u8, line, "Pages active:")) {
            active = trailingCount(line);
        } else if (std.mem.startsWith(u8, line, "Pages wired down:")) {
            wired = trailingCount(line);
        } else if (std.mem.startsWith(u8, line, "Pages occupied by compressor:")) {
            compressor = trailingCount(line);
        }
    }
    if (page_size == 0) return null;
    const pages = (active orelse return null) + (wired orelse return null) + (compressor orelse return null);
    return .{ .used_bytes = pages * page_size };
}

/// The trailing integer of a `Pages active:   794612.` line.
fn trailingCount(line: []const u8) ?u64 {
    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, line, " \t\r"), ".");
    const start = std.mem.lastIndexOfAny(u8, trimmed, " \t") orelse return null;
    return std.fmt.parseInt(u64, trimmed[start + 1 ..], 10) catch null;
}

/// Linux `/proc/meminfo`: `MemTotal:` and `MemAvailable:` in kB.
pub fn parseMeminfo(bytes: []const u8) ?MemSample {
    const total_kb = meminfoField(bytes, "MemTotal:") orelse return null;
    const available_kb = meminfoField(bytes, "MemAvailable:") orelse return null;
    if (available_kb > total_kb) return null;
    return .{
        .used_bytes = (total_kb - available_kb) * 1024,
        .total_bytes = total_kb * 1024,
    };
}

fn meminfoField(bytes: []const u8, key: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        var tokens = std.mem.tokenizeAny(u8, line[key.len..], " \t");
        const value = tokens.next() orelse return null;
        return std.fmt.parseInt(u64, value, 10) catch null;
    }
    return null;
}

// ------------------------------------------------------------ host info

pub const HostInfo = struct {
    cores: u32 = 0,
    /// Total physical memory; 0 on Linux (totals ride every meminfo
    /// sample instead).
    memory_bytes: u64 = 0,
};

/// macOS: two lines (`hw.ncpu`, `hw.memsize`). Linux: one line (`nproc`).
pub fn parseHostInfo(bytes: []const u8) ?HostInfo {
    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
    const cores_text = lines.next() orelse return null;
    const cores = std.fmt.parseInt(u32, std.mem.trim(u8, cores_text, " \t"), 10) catch return null;
    if (cores == 0) return null;
    var info = HostInfo{ .cores = cores };
    if (builtin.os.tag == .macos) {
        const mem_text = lines.next() orelse return null;
        info.memory_bytes = std.fmt.parseInt(u64, std.mem.trim(u8, mem_text, " \t"), 10) catch return null;
    }
    return info;
}
