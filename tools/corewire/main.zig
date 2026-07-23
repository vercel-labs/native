//! corewire — the contract-sidecar shim generator.
//!
//!   corewire --sidecar core.contract.json --out core_shim.zig
//!   corewire --sidecar core.contract.json --check
//!
//! Reads the JSON contract sidecar a core-mode compile emits beside the
//! compiled object, validates it (schema rules V1-V14, teaching
//! refusals with exact field paths on stderr), and writes the Zig
//! mirror module the app wiring imports (see emit.zig for what the
//! mirror carries). `--check` validates and stops — the checker-tier
//! entry point.
//!
//! The build stages the output beside tools/corewire/shim_rt.zig and
//! tools/corewire/core_abi.zig; the generated module imports both
//! relatively, the way transpiler output imports its staged rt.zig.

const std = @import("std");
const sidecar_mod = @import("sidecar.zig");
const emit_mod = @import("emit.zig");
const emit_facade_mod = @import("emit_facade.zig");

const usage =
    \\usage: corewire --sidecar <core.contract.json> (--out <core_shim.zig> | --facade <core_facade.ts> | --check)
    \\
    \\Generate the Zig mirror module (core_shim.zig) and/or the TypeScript
    \\projection (core_facade.ts) for a compiled core from its contract
    \\sidecar, or validate the sidecar alone (--check). --out and --facade
    \\combine; --check stands alone.
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    var sidecar_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var facade_path: ?[]const u8 = null;
    var check_only = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--sidecar") and index + 1 < args.len) {
            index += 1;
            sidecar_path = args[index];
        } else if (std.mem.eql(u8, arg, "--out") and index + 1 < args.len) {
            index += 1;
            out_path = args[index];
        } else if (std.mem.eql(u8, arg, "--facade") and index + 1 < args.len) {
            index += 1;
            facade_path = args[index];
        } else if (std.mem.eql(u8, arg, "--check")) {
            check_only = true;
        } else {
            try stderr.print("corewire: unknown argument \"{s}\"\n\n{s}", .{ arg, usage });
            try stderr.flush();
            std.process.exit(2);
        }
    }
    const input = sidecar_path orelse {
        try stderr.print("{s}", .{usage});
        try stderr.flush();
        std.process.exit(2);
    };
    // Either validate-only, or at least one generation target — never
    // both (a checker that writes files is not a checker).
    const generates = out_path != null or facade_path != null;
    if (generates == check_only) {
        try stderr.print("{s}", .{usage});
        try stderr.flush();
        std.process.exit(2);
    }
    // Distinct paths only: the two projections must not overwrite each
    // other, and no output may destroy the input contract. Compared
    // lexically normalized (cwd-resolved, `.`/`..` folded) — filesystem
    // identities beyond spelling (symlinks, hard links) stay the
    // caller's responsibility.
    const input_resolved = try canonicalSpelling(init.io, arena, input);
    // The staging PREFIX spellings join the checked set: outputs land
    // by rename from exclusively-created `<path>.corewire-tmp.<nonce>`
    // files, and a sidecar sitting on the prefix spelling is close
    // enough to a claimed name to refuse outright.
    const paths = [_]?[]const u8{
        out_path,
        facade_path,
        if (out_path) |path| try std.fmt.allocPrint(arena, "{s}.corewire-tmp", .{path}) else null,
        if (facade_path) |path| try std.fmt.allocPrint(arena, "{s}.corewire-tmp", .{path}) else null,
    };
    var resolved: [paths.len]?[]const u8 = @splat(null);
    for (paths, 0..) |maybe_path, path_index| {
        const path = maybe_path orelse continue;
        resolved[path_index] = try canonicalSpelling(init.io, arena, path);
    }
    for (resolved, 0..) |maybe_path, path_index| {
        const path = maybe_path orelse continue;
        // Case-insensitively: the default volumes on two of the three
        // desktop platforms fold case, so differently-cased spellings
        // of one file must count as aliases everywhere (refusing a
        // case-only distinction on a case-sensitive volume costs
        // nothing anyone wants).
        if (std.ascii.eqlIgnoreCase(path, input_resolved)) {
            try stderr.print("corewire: output {s} names the sidecar itself — generating would destroy the input contract\n", .{path});
            try stderr.flush();
            std.process.exit(2);
        }
        // Spelling checks cannot see every filesystem aliasing (Unicode
        // case folding, links), so ask the filesystem: an output whose
        // path already resolves to the sidecar's own file is the same
        // refusal, whatever the spelling.
        if (sameExistingFile(init.io, path, input_resolved)) {
            try stderr.print("corewire: output {s} resolves to the sidecar's own file — generating would destroy the input contract\n", .{path});
            try stderr.flush();
            std.process.exit(2);
        }
        for (resolved[path_index + 1 ..]) |maybe_other| {
            const other = maybe_other orelse continue;
            if (std.ascii.eqlIgnoreCase(path, other) or sameExistingFile(init.io, path, other)) {
                try stderr.print("corewire: --out and --facade name one file ({s}) — the second projection would overwrite the first\n", .{path});
                try stderr.flush();
                std.process.exit(2);
            }
        }
    }

    const source = std.Io.Dir.cwd().readFileAlloc(init.io, input, arena, .limited(sidecar_mod.max_sidecar_bytes)) catch |err| {
        try stderr.print("corewire: cannot read {s}: {t}\n", .{ input, err });
        try stderr.flush();
        std.process.exit(1);
    };

    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = sidecar_mod.read(arena, source, &diags) catch |err| switch (err) {
        error.Refused => {
            try diags.write(input, stderr);
            try stderr.flush();
            std.process.exit(1);
        },
        error.OutOfMemory => return err,
    };

    // `--check` runs the FULL pipeline (both projections) and discards
    // the text: a sidecar must never pass the checker and then refuse at
    // generate time (emitter-level rules — emission-name collisions
    // above all — are part of the contract's validity).
    const generated: []const u8 = emit_mod.emit(arena, parsed, &diags) catch |err| switch (err) {
        error.Refused => {
            try diags.write(input, stderr);
            try stderr.flush();
            std.process.exit(1);
        },
        error.OutOfMemory => return err,
    };
    const facade: ?[]const u8 = if (check_only or facade_path != null)
        emit_facade_mod.emitFacade(arena, parsed, &diags) catch |err| switch (err) {
            error.Refused => {
                try diags.write(input, stderr);
                try stderr.flush();
                std.process.exit(1);
            },
            error.OutOfMemory => return err,
        }
    else
        null;

    // Warnings (unknown additive fields) surface even on success.
    try diags.write(input, stderr);
    try stderr.flush();

    // Stage-then-commit: BOTH projections write completely into
    // exclusively-created staging files before either rename, so a
    // write failure can never leave a fresh shim beside a stale facade.
    // The two renames remain two filesystem operations — a failure
    // between them reports both files as a possibly skewed pair and the
    // nonzero exit makes the caller regenerate; concurrent invocations
    // aimed at ONE output path are the caller's serialization to
    // provide (the build graph never shares output directories between
    // steps).
    const shim_staged: ?[]const u8 = if (out_path) |out|
        stageOutput(init, stderr, out, generated) catch |err| switch (err) {
            error.Staging => std.process.exit(1),
            else => return err,
        }
    else
        null;
    const facade_staged: ?[]const u8 = if (facade_path) |out| blk: {
        // The shim staging file exists now, so a filesystem-level alias
        // of the two output paths (Unicode case folding, links) gets one
        // more net before any rename.
        if (out_path) |shim_out| {
            if (sameExistingFile(init.io, out, shim_out)) {
                if (shim_staged) |staged| std.Io.Dir.cwd().deleteFile(init.io, staged) catch {};
                try stderr.print("corewire: --facade {s} resolves to the --out file — the second projection would overwrite the first\n", .{out});
                try stderr.flush();
                std.process.exit(2);
            }
        }
        break :blk stageOutput(init, stderr, out, facade.?) catch |err| {
            // The sibling projection was already staged; leave no stray
            // staging file behind ANY failure shape.
            if (shim_staged) |staged| std.Io.Dir.cwd().deleteFile(init.io, staged) catch {};
            switch (err) {
                error.Staging => std.process.exit(1),
                else => return err,
            }
        };
    } else null;

    var committed_shim = false;
    if (out_path) |out| {
        std.Io.Dir.cwd().rename(shim_staged.?, std.Io.Dir.cwd(), out, init.io) catch |err| {
            std.Io.Dir.cwd().deleteFile(init.io, shim_staged.?) catch {};
            if (facade_staged) |staged| std.Io.Dir.cwd().deleteFile(init.io, staged) catch {};
            try stderr.print("corewire: cannot write {s}: {t}\n", .{ out, err });
            try stderr.flush();
            std.process.exit(1);
        };
        committed_shim = true;
    }
    if (facade_path) |out| {
        // The shim now EXISTS, so aliases no spelling check can see
        // (filesystem Unicode normalization above all) finally resolve:
        // a facade target that reaches the just-committed shim refuses
        // instead of replacing it.
        if (committed_shim and sameExistingFile(init.io, out, out_path.?)) {
            std.Io.Dir.cwd().deleteFile(init.io, facade_staged.?) catch {};
            try stderr.print("corewire: --facade {s} resolves to the file --out just wrote — the second projection would overwrite the first\n", .{out});
            try stderr.flush();
            std.process.exit(2);
        }
        std.Io.Dir.cwd().rename(facade_staged.?, std.Io.Dir.cwd(), out, init.io) catch |err| {
            std.Io.Dir.cwd().deleteFile(init.io, facade_staged.?) catch {};
            if (committed_shim) {
                try stderr.print("corewire: cannot write {s}: {t} — {s} was already replaced, so the two projections on disk may be from different generations; re-run to restore the pair\n", .{ out, err, out_path.? });
            } else {
                try stderr.print("corewire: cannot write {s}: {t}\n", .{ out, err });
            }
            try stderr.flush();
            std.process.exit(1);
        };
    }
}

/// A path spelling fit for alias comparison: components canonicalize
/// one at a time against the filesystem, so `..` applies to the REAL
/// parent (never lexically across a symlink), symlinked or case-folded
/// ancestors land on one spelling, and a not-yet-existing tail rides
/// verbatim — two spellings of one future file compare equal even
/// before the file exists.
fn canonicalSpelling(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    // Platform-aware parsing: the component iterator understands the
    // native roots and separators (drive and UNC spellings included),
    // so two spellings of one root land on one prefix.
    var components = std.fs.path.componentIterator(path);
    const root = components.root();
    if (root != null and !std.fs.path.isAbsolute(path)) {
        // A drive-RELATIVE spelling (C:foo) names a file under that
        // drive's own working directory, which this process cannot
        // resolve portably; folding it under the drive root would
        // manufacture false aliases against drive-absolute spellings.
        // Keep it lexical — the existence-based nets and rename landing
        // still guard the writes.
        return std.fs.path.resolve(arena, &.{path});
    }
    var base: []const u8 = if (root) |prefix|
        try arena.dupe(u8, prefix)
    else blk: {
        const len = std.Io.Dir.cwd().realPath(io, &buffer) catch break :blk try arena.dupe(u8, ".");
        break :blk try arena.dupe(u8, buffer[0..len]);
    };
    var exists = true;
    while (components.next()) |component| {
        if (std.mem.eql(u8, component.name, ".")) continue;
        if (std.mem.eql(u8, component.name, "..")) {
            // `base` carries no symlinks once canonical, so its lexical
            // parent IS its real parent; a `..` under a nonexistent
            // tail unwinds the tail it just added — and may land back
            // on EXISTING ground, so canonicalization must resume (a
            // symlink after the pop would otherwise ride unresolved).
            base = std.fs.path.dirname(base) orelse base;
            if (!exists) {
                if (std.Io.Dir.cwd().realPathFile(io, base, &buffer)) |len| {
                    base = try arena.dupe(u8, buffer[0..len]);
                    exists = true;
                } else |_| {}
            }
            continue;
        }
        const candidate = try std.fs.path.join(arena, &.{ base, component.name });
        if (exists) {
            if (std.Io.Dir.cwd().realPathFile(io, candidate, &buffer)) |len| {
                base = try arena.dupe(u8, buffer[0..len]);
                continue;
            } else |_| {
                exists = false;
            }
        }
        base = candidate;
    }
    return base;
}

/// Whether two paths currently resolve to one existing file, by asking
/// the filesystem for canonical paths: the alias net behind the lexical
/// checks (Unicode case folding, symlinks — a canonical path is unique
/// per volume, so distinct files can never compare equal). Nonexistent
/// paths are distinct. Hard links carry distinct canonical paths and
/// pass this check — harmless by construction, because outputs land by
/// rename (writeOutput), which replaces a directory entry and never
/// writes through one.
fn sameExistingFile(io: std.Io, a: []const u8, b: []const u8) bool {
    var buffer_a: [std.fs.max_path_bytes]u8 = undefined;
    var buffer_b: [std.fs.max_path_bytes]u8 = undefined;
    const len_a = std.Io.Dir.cwd().realPathFile(io, a, &buffer_a) catch return false;
    const len_b = std.Io.Dir.cwd().realPathFile(io, b, &buffer_b) catch return false;
    if (std.mem.eql(u8, buffer_a[0..len_a], buffer_b[0..len_b])) return true;
    // Distinct canonical paths can still name one DIRECTORY ENTRY where
    // a mount exposes a directory twice (bind mounts) — the case the
    // rename landing cannot save, because replacing the entry through
    // either spelling replaces it for both. A hard link is the
    // opposite: two entries for one file, and the rename replaces only
    // the named entry, so it must NOT trip this check. Same entry means
    // same parent directory and same on-disk basename; the portable
    // stat carries no device id, so parent identity is inferred from
    // full metadata agreement (a coincidental match across volumes
    // merely refuses a spelling nobody needs).
    const canon_a = buffer_a[0..len_a];
    const canon_b = buffer_b[0..len_b];
    if (!std.mem.eql(u8, std.fs.path.basename(canon_a), std.fs.path.basename(canon_b))) return false;
    const parent_a = std.fs.path.dirname(canon_a) orelse return false;
    const parent_b = std.fs.path.dirname(canon_b) orelse return false;
    const stat_a = std.Io.Dir.cwd().statFile(io, parent_a, .{}) catch return false;
    const stat_b = std.Io.Dir.cwd().statFile(io, parent_b, .{}) catch return false;
    return stat_a.inode == stat_b.inode and stat_a.kind == stat_b.kind and
        stat_a.size == stat_b.size and stat_a.nlink == stat_b.nlink and
        stat_a.mtime.nanoseconds == stat_b.mtime.nanoseconds and
        stat_a.ctime.nanoseconds == stat_b.ctime.nanoseconds;
}

/// Write `data` into an exclusively-created, uniquely-named staging
/// file beside `out` and return its path; the caller commits by rename.
/// Exclusive creation can never truncate an existing entry (whatever it
/// links to), and the unique suffix keeps concurrent invocations off
/// each other's bytes. Failures print their teaching and return
/// error.Staging so the caller can delete sibling staging files.
fn stageOutput(init: std.process.Init, stderr: *std.Io.Writer, out: []const u8, data: []const u8) ![]const u8 {
    if (std.fs.path.dirname(out)) |dir| {
        std.Io.Dir.cwd().createDirPath(init.io, dir) catch {};
    }
    const arena = init.arena.allocator();
    var nonce: [8]u8 = undefined;
    init.io.random(&nonce);
    const temp_path = try std.fmt.allocPrint(arena, "{s}.corewire-tmp.{x}", .{ out, &nonce });
    const staging = std.Io.Dir.cwd().createFile(init.io, temp_path, .{ .exclusive = true }) catch |err| {
        try stderr.print("corewire: cannot stage {s}: {t}\n", .{ temp_path, err });
        try stderr.flush();
        return error.Staging;
    };
    var write_failed = false;
    {
        defer staging.close(init.io);
        var buffer: [4096]u8 = undefined;
        var writer = staging.writerStreaming(init.io, &buffer);
        writer.interface.writeAll(data) catch {
            write_failed = true;
        };
        if (!write_failed) writer.interface.flush() catch {
            write_failed = true;
        };
    }
    if (write_failed) {
        std.Io.Dir.cwd().deleteFile(init.io, temp_path) catch {};
        try stderr.print("corewire: cannot write {s}\n", .{temp_path});
        try stderr.flush();
        return error.Staging;
    }
    return temp_path;
}
