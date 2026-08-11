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
//! (emit_profile.zig). `--check` validates and stops — the checker-tier
//! entry point.
//!
//! The build stages the output beside tools/corewire/shim_rt.zig and
//! tools/corewire/core_abi.zig; the generated module imports both
//! relatively, the way transpiler output imports its staged rt.zig.

const std = @import("std");
const sidecar_mod = @import("sidecar.zig");
const emit_mod = @import("emit.zig");
const emit_facade_mod = @import("emit_facade.zig");
const emit_profile_mod = @import("emit_profile.zig");
const service_contract_mod = @import("service_contract.zig");
const emit_service_mod = @import("emit_service.zig");

const usage =
    \\usage: corewire --sidecar <core.contract.json> (--out <core_shim.zig> | --facade <core_facade.ts> | --profile <core_profile.json> | --effective-sidecar <effective.contract.json> | --check) [--f64-slot <path>]...
    \\
    \\Generate the Zig mirror module (core_shim.zig), the TypeScript
    \\projection (core_facade.ts), the library-mode compiler profile
    \\(core_profile.json), and/or the effective sidecar after projection
    \\overrides for a compiled core, or validate the input sidecar alone
    \\(--check). Generation outputs combine; --check stands alone.
    \\
    \\--f64-slot <path> carries the named attested integer slot as f64 for
    \\this whole invocation (facade, profile, and mirror alike): a slot
    \\whose values reach the f64-exact boundary (2^53) has no honest i64
    \\declaration on the compiled side, so the caller states the demotion
    \\explicitly and every projection stays consistent. The path must name
    \\an attested slot — a misspelling would silently demote nothing.
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    if (try serviceProjection(init, args, stderr)) return;

    var sidecar_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var facade_path: ?[]const u8 = null;
    var profile_path: ?[]const u8 = null;
    var effective_sidecar_path: ?[]const u8 = null;
    var check_only = false;
    var f64_slots: std.ArrayListUnmanaged([]const u8) = .empty;
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
        } else if (std.mem.eql(u8, arg, "--profile") and index + 1 < args.len) {
            index += 1;
            profile_path = args[index];
        } else if (std.mem.eql(u8, arg, "--effective-sidecar") and index + 1 < args.len) {
            index += 1;
            effective_sidecar_path = args[index];
        } else if (std.mem.eql(u8, arg, "--f64-slot") and index + 1 < args.len) {
            index += 1;
            try f64_slots.append(arena, args[index]);
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
    const generates = out_path != null or facade_path != null or profile_path != null or effective_sidecar_path != null;
    if (generates == check_only) {
        try stderr.print("{s}", .{usage});
        try stderr.flush();
        std.process.exit(2);
    }
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
                try stderr.print("corewire: two outputs name one file ({s}) — the later projection would overwrite the earlier\n", .{path});
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
    var parsed = sidecar_mod.read(arena, source, &diags) catch |err| switch (err) {
        error.Refused => {
            try diags.write(input, stderr);
            try stderr.flush();
            std.process.exit(1);
        },
        error.OutOfMemory => return err,
    };

    // Caller-stated f64 demotions apply to the parsed contract before
    // any projection, so the facade's encoders, the profile's
    // declarations, and the attestation list stay consistent by
    // construction: the slot's type-table spelling rewrites to f64 and
    // its attestation entry drops.
    if (f64_slots.items.len > 0) {
        var kept: std.ArrayListUnmanaged(sidecar_mod.IntegerSlot) = .empty;
        for (f64_slots.items) |slot_path| {
            const listed = for (parsed.integer_slots) |slot| {
                if (std.mem.eql(u8, slot.slot, slot_path)) break true;
            } else false;
            if (!listed) {
                try stderr.print("corewire: --f64-slot {s} names no attested integer slot of this contract — a misspelling would silently demote nothing; check the contract's integer_slots\n", .{slot_path});
                try stderr.flush();
                std.process.exit(2);
            }
            if (!demoteSlotToF64(parsed, slot_path)) {
                try stderr.print("corewire: --f64-slot {s} does not name a record field slot (Container.field) — only record-field slots demote today; a message-arm or helper slot demotion needs its own emitter support\n", .{slot_path});
                try stderr.flush();
                std.process.exit(2);
            }
        }
        for (parsed.integer_slots) |slot| {
            const demoted = for (f64_slots.items) |slot_path| {
                if (std.mem.eql(u8, slot.slot, slot_path)) break true;
            } else false;
            if (!demoted) try kept.append(arena, slot);
        }
        parsed.integer_slots = kept.items;
    }

    // `--check` runs the FULL pipeline (every projection) and discards
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
    // The profile targets the facade module as its entry, so emitting a
    // profile runs the facade emitter's own refusal checks even when no
    // facade file is written — a sidecar must never yield a profile
    // whose referenced facade then refuses to generate.
    const facade: ?[]const u8 = if (check_only or facade_path != null or profile_path != null)
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
    // The profile names the facade module as its entry, resolved
    // against the profile file's own directory (the compilation root):
    // when both are generated in one invocation the emitted spelling is
    // the --facade path made profile-relative, and the conventional
    // name otherwise.
    const profile: ?[]const u8 = if (check_only or profile_path != null) blk: {
        const entry = if (facade_path != null and profile_path != null)
            profileRelativeEntry(init, stderr, profile_path.?, facade_path.?) catch |err| switch (err) {
                error.Unrelatable => std.process.exit(2),
                else => return err,
            }
        else if (facade_path) |path|
            std.fs.path.basename(path)
        else
            emit_profile_mod.default_entry;
        // The profile is a JSON document, and JSON text carries UTF-8
        // only: a filename with other bytes would not survive the trip
        // through any conforming consumer, so it refuses here instead
        // of naming a file nothing can find.
        if (!std.unicode.utf8ValidateSlice(entry)) {
            try stderr.print("corewire: the profile's entry spelling \"{s}\" is not valid UTF-8 — the profile is a JSON document and JSON text carries UTF-8 only; rename the facade file\n", .{entry});
            try stderr.flush();
            std.process.exit(2);
        }
        break :blk emit_profile_mod.emitProfile(arena, parsed, entry, &diags) catch |err| switch (err) {
            error.Refused => {
                try diags.write(input, stderr);
                try stderr.flush();
                std.process.exit(1);
            },
            error.OutOfMemory => return err,
        };
    } else null;

    // The staged contract twin: preserve the input document's complete
    // additive vocabulary while applying the same explicit demotions the
    // typed projections above consumed. This is the sidecar that truthfully
    // belongs beside a generated facade/profile pair.
    const effective_sidecar: ?[]const u8 = if (effective_sidecar_path != null)
        try sidecar_mod.projectF64SlotsJson(arena, source, f64_slots.items)
    else
        null;

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
        outputs_buffer[output_count] = .{ .flag = "--facade", .path = path, .data = facade.? };
        output_count += 1;
    }
    if (profile_path) |path| {
        outputs_buffer[output_count] = .{ .flag = "--profile", .path = path, .data = profile.? };
        output_count += 1;
    }
    if (effective_sidecar_path) |path| {
        outputs_buffer[output_count] = .{ .flag = "--effective-sidecar", .path = path, .data = effective_sidecar.? };
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
fn serviceProjection(init: std.process.Init, args: []const []const u8, stderr: *std.Io.Writer) !bool {
    var input: ?[]const u8 = null;
    var host_out: ?[]const u8 = null;
    var registry_out: ?[]const u8 = null;
    var saw_service_flag = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--services-sidecar") and index + 1 < args.len) {
            saw_service_flag = true;
            index += 1;
            input = args[index];
        } else if (std.mem.eql(u8, arg, "--service-host-main") and index + 1 < args.len) {
            saw_service_flag = true;
            index += 1;
            host_out = args[index];
        } else if (std.mem.eql(u8, arg, "--service-registry") and index + 1 < args.len) {
            saw_service_flag = true;
            index += 1;
            registry_out = args[index];
        } else if (saw_service_flag) {
            try stderr.print("corewire: unknown service projection argument \"{s}\"\n", .{arg});
            try stderr.flush();
            std.process.exit(2);
        }
    }
    if (!saw_service_flag) return false;
    const sidecar_path = input orelse {
        try stderr.print("usage: corewire --services-sidecar <services.contract.json> --service-host-main <service_host_main.ts> --service-registry <services.zig>\n", .{});
        try stderr.flush();
        std.process.exit(2);
    };
    if (host_out == null and registry_out == null) {
        try stderr.print("corewire: the service projection needs --service-host-main and/or --service-registry\n", .{});
        try stderr.flush();
        std.process.exit(2);
    }
    if (host_out != null and registry_out != null and std.ascii.eqlIgnoreCase(host_out.?, registry_out.?)) {
        try stderr.print("corewire: the service host and registry outputs name one file\n", .{});
        try stderr.flush();
        std.process.exit(2);
    }
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
    if (host_out) |path| {
        const generated = try emit_service_mod.emitHost(arena, contract);
        std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = generated }) catch |err| {
            try stderr.print("corewire: cannot write {s}: {t}\n", .{ path, err });
            try stderr.flush();
            std.process.exit(1);
        };
    }
    if (registry_out) |path| {
        const generated = try emit_service_mod.emitRegistry(arena, contract);
        std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = generated }) catch |err| {
            try stderr.print("corewire: cannot write {s}: {t}\n", .{ path, err });
            try stderr.flush();
            std.process.exit(1);
        };
    }
    try stderr.flush();
    return true;
}

/// Rewrite one record-field slot's type-table spelling from i64 to f64
/// (through one optional wrapper). Returns false when the path is not a
/// `Container.field` record slot whose field spells i64.
fn demoteSlotToF64(sidecar: sidecar_mod.Sidecar, slot_path: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, slot_path, '.') orelse return false;
    const container = slot_path[0..dot];
    const field_name = slot_path[dot + 1 ..];
    if (std.mem.indexOfScalar(u8, field_name, '.') != null) return false;
    for (sidecar.types.structs) |entry| {
        if (!std.mem.eql(u8, entry.name, container)) continue;
        for (entry.fields) |*field| {
            if (!std.mem.eql(u8, field.name, field_name)) continue;
            const mutable: *sidecar_mod.Field = @constCast(field);
            switch (field.type) {
                .i64 => {
                    mutable.type = .f64;
                    return true;
                },
                .optional => |inner| {
                    if (inner.* != .i64) return false;
                    const mutable_inner: *sidecar_mod.TypeRef = @constCast(inner);
                    mutable_inner.* = .f64;
                    return true;
                },
                else => return false,
            }
        }
    }
    return false;
}

/// The facade path as the profile's entry spelling: relative to the
/// profile file's directory (the compilation root a profile consumer
/// resolves against), POSIX separators. A pair that cannot relate
/// (distinct roots) refuses with a teaching — a wrong spelling would
/// point the consumer at a file that does not exist.
fn profileRelativeEntry(init: std.process.Init, stderr: *std.Io.Writer, profile_path: []const u8, facade_path: []const u8) ![]const u8 {
    const arena = init.arena.allocator();
    const profile_dir = std.fs.path.dirname(profile_path) orelse ".";
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.Io.Dir.cwd().realPath(init.io, &buffer) catch 0;
    const cwd: []const u8 = if (cwd_len == 0) "." else buffer[0..cwd_len];
    // The environment rides along for the Windows resolver: a
    // drive-RELATIVE spelling (C:foo) resolves against that drive's own
    // working directory, which lives in the environment.
    const related = try std.fs.path.relative(arena, cwd, init.environ_map, profile_dir, facade_path);
    // Paths on distinct roots have no relative spelling (the resolver
    // hands back an absolute path instead): a profile consumer resolves
    // the entry against the profile's directory, so an unreachable
    // facade refuses rather than emitting a spelling that names nothing.
    if (related.len == 0 or std.fs.path.isAbsolute(related)) {
        try stderr.print("corewire: --facade {s} has no path relative to the --profile directory {s} — the profile's entry must reach the facade from beside the profile; emit them under one root\n", .{ facade_path, profile_dir });
        try stderr.flush();
        return error.Unrelatable;
    }
    // Separator conversion is a WINDOWS translation only: on POSIX a
    // backslash is an ordinary filename byte and must ride verbatim.
    if (std.fs.path.sep != std.fs.path.sep_windows) return related;
    const posix = try arena.dupe(u8, related);
    for (posix) |*char| {
        if (char.* == std.fs.path.sep_windows) char.* = std.fs.path.sep_posix;
    }
    return posix;
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
