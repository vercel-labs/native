//! corewire — the contract-sidecar shim generator.
//!
//!   corewire --sidecar core.contract.json --out core_shim.zig
//!   corewire --sidecar core.contract.json --facade core_facade.ts --profile core_profile.json --effective-sidecar effective.contract.json
//!   corewire --sidecar core.contract.json --check
//!
//! Reads the JSON contract sidecar a core-mode compile emits beside the
//! compiled object, validates it (schema rules V1-V14, teaching
//! refusals with exact field paths on stderr), and writes the Zig
//! mirror module the app wiring imports (see emit.zig for what the
//! mirror carries). `--facade` writes the TypeScript projection,
//! `--profile` the library-mode compiler profile that builds it
//! (scriptc-compiled emit_profile.ts). `--check` validates and stops — the checker-tier
//! entry point.
//!
//! The build stages the output beside tools/corewire/shim_rt.zig and
//! tools/corewire/core_abi.zig; the generated module imports both
//! relatively, the way transpiler output imports its staged rt.zig.

const std = @import("std");
const sidecar_mod = @import("sidecar.zig");
const invocation_mod = @import("invocation.zig");
const service_contract_mod = @import("service_contract.zig");
const emit_service_mod = @import("emit_service.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const invocation = try invocation_mod.plan(arena, args);
    if (invocation.exit_code != 0) {
        try stderr.writeAll(invocation.@"error");
        try stderr.flush();
        std.process.exit(invocation.exit_code);
    }
    if (invocation.mode == .service) return serviceProjection(init, args, invocation, stderr);
    const input = args[invocation.input.?];
    var out_path: ?[]const u8 = null;
    var facade_path: ?[]const u8 = null;
    var profile_path: ?[]const u8 = null;
    var effective_sidecar_path: ?[]const u8 = null;
    for (invocation.outputs) |out| switch (out.kind) {
        .mirror => out_path = args[out.path_index],
        .facade => facade_path = args[out.path_index],
        .profile => profile_path = args[out.path_index],
        .effective => effective_sidecar_path = args[out.path_index],
        else => unreachable,
    };
    // Distinct paths only: the projections must not overwrite each
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
        profile_path,
        effective_sidecar_path,
        if (out_path) |path| try std.fmt.allocPrint(arena, "{s}.corewire-tmp", .{path}) else null,
        if (facade_path) |path| try std.fmt.allocPrint(arena, "{s}.corewire-tmp", .{path}) else null,
        if (profile_path) |path| try std.fmt.allocPrint(arena, "{s}.corewire-tmp", .{path}) else null,
        if (effective_sidecar_path) |path| try std.fmt.allocPrint(arena, "{s}.corewire-tmp", .{path}) else null,
    };
    var resolved: [paths.len]?[]const u8 = @splat(null);
    for (paths, 0..) |maybe_path, path_index| {
        const path = maybe_path orelse continue;
        resolved[path_index] = try canonicalSpelling(init.io, arena, path);
    }
    var canonical_paths: std.ArrayList([]const u8) = .empty;
    for (resolved) |path| if (path) |value| try canonical_paths.append(arena, value);
    const identities = try arena.alloc([]const bool, canonical_paths.items.len);
    for (canonical_paths.items, 0..) |path, i| {
        const row = try arena.alloc(bool, canonical_paths.items.len + 1);
        @memset(row, false);
        row[0] = sameExistingFile(init.io, path, input_resolved);
        for (canonical_paths.items[i + 1 ..], i + 1..) |other, j| row[j + 1] = sameExistingFile(init.io, path, other);
        identities[i] = row;
    }
    const alias_diagnostic = try invocation_mod.aliases(arena, input_resolved, canonical_paths.items, identities);
    if (alias_diagnostic.len != 0) {
        try stderr.writeAll(alias_diagnostic);
        try stderr.flush();
        std.process.exit(2);
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

    // OS-relative entry facts are computed here; compiled coordination
    // decides when to enforce them, after mirror/facade admission.
    var entry: invocation_mod.Entry = .{};
    if (facade_path != null and profile_path != null) {
        const profile_dir = std.fs.path.dirname(profile_path.?) orelse ".";
        entry = try profileRelativeEntry(init, profile_dir, facade_path.?);
    } else if (facade_path) |path| {
        const name = std.fs.path.basename(path);
        entry = .{ .text = if (std.unicode.utf8ValidateSlice(name)) name else "", .utf8 = std.unicode.utf8ValidateSlice(name), .bytes = name };
    }
    const result = try invocation_mod.core(arena, parsed, invocation, args, entry, source);
    for (result.diagnostics) |diagnostic| diags.flag(diagnostic.path, "{s}", .{diagnostic.message});
    if (result.exit_code != 0) {
        if (result.@"error".len != 0) try stderr.writeAll(result.@"error") else try diags.write(input, stderr);
        try stderr.flush();
        std.process.exit(result.exit_code);
    }
    const generated = result.mirror;
    const facade = result.facade;
    const profile = result.profile;
    const effective_sidecar = result.effective;

    // Warnings (unknown additive fields) surface even on success.
    try diags.write(input, stderr);
    try stderr.flush();

    // Stage-then-commit: ALL projections write completely into
    // exclusively-created staging files before any rename, so a write
    // failure can never leave a fresh shim beside a stale sibling. The
    // renames remain separate filesystem operations — a failure between
    // them reports the files as a possibly skewed set and the nonzero
    // exit makes the caller regenerate; concurrent invocations aimed at
    // ONE output path are the caller's serialization to provide (the
    // build graph never shares output directories between steps).
    const Output = struct {
        flag: []const u8,
        path: []const u8,
        data: []const u8,
        staged: []const u8 = "",
    };
    var outputs_buffer: [4]Output = undefined;
    var output_count: usize = 0;
    if (out_path) |path| {
        outputs_buffer[output_count] = .{ .flag = "--out", .path = path, .data = generated };
        output_count += 1;
    }
    if (facade_path) |path| {
        outputs_buffer[output_count] = .{ .flag = "--facade", .path = path, .data = facade };
        output_count += 1;
    }
    if (profile_path) |path| {
        outputs_buffer[output_count] = .{ .flag = "--profile", .path = path, .data = profile };
        output_count += 1;
    }
    if (effective_sidecar_path) |path| {
        outputs_buffer[output_count] = .{ .flag = "--effective-sidecar", .path = path, .data = effective_sidecar };
        output_count += 1;
    }
    const outputs = outputs_buffer[0..output_count];

    for (outputs, 0..) |*output, output_index| {
        // Earlier staging files exist now, so a filesystem-level alias
        // of two output paths (Unicode case folding, links) gets one
        // more net before any rename.
        for (outputs[0..output_index]) |earlier| {
            if (sameExistingFile(init.io, output.path, earlier.path)) {
                for (outputs[0..output_index]) |staged| std.Io.Dir.cwd().deleteFile(init.io, staged.staged) catch {};
                try stderr.print("corewire: {s} {s} resolves to the {s} file — the later projection would overwrite the earlier\n", .{ output.flag, output.path, earlier.flag });
                try stderr.flush();
                std.process.exit(2);
            }
        }
        output.staged = stageOutput(init, stderr, output.path, output.data) catch |err| {
            // Sibling projections were already staged; leave no stray
            // staging file behind ANY failure shape.
            for (outputs[0..output_index]) |staged| std.Io.Dir.cwd().deleteFile(init.io, staged.staged) catch {};
            switch (err) {
                error.Staging => std.process.exit(1),
                else => return err,
            }
        };
    }

    for (outputs, 0..) |output, output_index| {
        // Committed outputs now EXIST, so aliases no spelling check can
        // see (filesystem Unicode normalization above all) finally
        // resolve: a target that reaches a just-committed sibling
        // refuses instead of replacing it.
        for (outputs[0..output_index]) |earlier| {
            if (sameExistingFile(init.io, output.path, earlier.path)) {
                for (outputs[output_index..]) |staged| std.Io.Dir.cwd().deleteFile(init.io, staged.staged) catch {};
                try stderr.print("corewire: {s} {s} resolves to the file {s} just wrote — the later projection would overwrite the earlier\n", .{ output.flag, output.path, earlier.flag });
                try stderr.flush();
                std.process.exit(2);
            }
        }
        std.Io.Dir.cwd().rename(output.staged, std.Io.Dir.cwd(), output.path, init.io) catch |err| {
            for (outputs[output_index..]) |staged| std.Io.Dir.cwd().deleteFile(init.io, staged.staged) catch {};
            if (output_index > 0) {
                try stderr.print("corewire: cannot write {s}: {t} — earlier projections were already replaced, so the outputs on disk may be from different generations; re-run to restore the set\n", .{ output.path, err });
            } else {
                try stderr.print("corewire: cannot write {s}: {t}\n", .{ output.path, err });
            }
            try stderr.flush();
            std.process.exit(1);
        };
    }
}

/// The service contract is a distinct schema from core.contract.json. Keep
/// its projection mode explicit so neither reader can accidentally accept a
/// document from the other class.
fn serviceProjection(init: std.process.Init, args: []const []const u8, invocation: invocation_mod.Plan, stderr: *std.Io.Writer) !void {
    const sidecar_path = args[invocation.input.?];
    const optimization = if (invocation.optimization) |index| args[index] else null;
    const arena = init.arena.allocator();
    const source = std.Io.Dir.cwd().readFileAlloc(init.io, sidecar_path, arena, .limited(service_contract_mod.max_bytes)) catch |err| {
        try stderr.print("corewire: cannot read {s}: {t}\n", .{ sidecar_path, err });
        try stderr.flush();
        std.process.exit(1);
    };
    const contract = service_contract_mod.read(arena, source, stderr) catch |err| switch (err) {
        error.InvalidContract => {
            try stderr.flush();
            std.process.exit(1);
        },
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.WriteFailed,
    };
    // The planner owns output selection and order. Native keeps the
    // original sequential write behavior, including partial service outputs.
    for (invocation.outputs) |out| {
        const path = args[out.path_index];
        const generated = switch (out.kind) {
            .host => try emit_service_mod.emitHost(arena, contract),
            .registry => try emit_service_mod.emitRegistry(arena, contract),
            .client => try emit_service_mod.emitClient(arena, contract),
            .inproc_main => try emit_service_mod.emitInprocMain(arena, contract),
            .inproc_profile => try emit_service_mod.emitInprocProfile(arena, optimization),
            else => unreachable,
        };
        std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = generated }) catch |err| {
            try stderr.print("corewire: cannot write {s}: {t}\n", .{ path, err });
            try stderr.flush();
            std.process.exit(1);
        };
    }
    try stderr.flush();
}

/// The facade path as the profile's entry spelling: relative to the
/// profile file's directory (the compilation root a profile consumer
/// resolves against), POSIX separators. A pair that cannot relate
/// (distinct roots) refuses with a teaching — a wrong spelling would
/// point the consumer at a file that does not exist.
fn profileRelativeEntry(init: std.process.Init, profile_dir: []const u8, facade_path: []const u8) !invocation_mod.Entry {
    const arena = init.arena.allocator();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.Io.Dir.cwd().realPath(init.io, &buffer) catch 0;
    const cwd: []const u8 = if (cwd_len == 0) "." else buffer[0..cwd_len];
    const related = try std.fs.path.relative(arena, cwd, init.environ_map, profile_dir, facade_path);
    const posix = try arena.dupe(u8, related);
    if (std.fs.path.sep == std.fs.path.sep_windows) for (posix) |*char| {
        if (char.* == std.fs.path.sep_windows) char.* = std.fs.path.sep_posix;
    };
    const valid = std.unicode.utf8ValidateSlice(posix);
    return .{ .text = if (valid) posix else "", .bytes = posix, .utf8 = valid, .unrelated = related.len == 0 or std.fs.path.isAbsolute(related), .facade_path = facade_path, .profile_directory = profile_dir };
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
