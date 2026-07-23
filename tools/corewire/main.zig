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
    const input_resolved = try std.fs.path.resolve(arena, &.{input});
    const paths = [_]?[]const u8{ out_path, facade_path };
    var resolved: [paths.len]?[]const u8 = .{ null, null };
    for (paths, 0..) |maybe_path, path_index| {
        const path = maybe_path orelse continue;
        resolved[path_index] = try std.fs.path.resolve(arena, &.{path});
    }
    for (resolved, 0..) |maybe_path, path_index| {
        const path = maybe_path orelse continue;
        if (std.mem.eql(u8, path, input_resolved)) {
            try stderr.print("corewire: output {s} names the sidecar itself — generating would destroy the input contract\n", .{path});
            try stderr.flush();
            std.process.exit(2);
        }
        for (resolved[path_index + 1 ..]) |maybe_other| {
            const other = maybe_other orelse continue;
            if (std.mem.eql(u8, path, other)) {
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

    if (out_path) |out| {
        try writeOutput(init, stderr, out, generated);
    }
    if (facade_path) |out| {
        try writeOutput(init, stderr, out, facade.?);
    }
}

fn writeOutput(init: std.process.Init, stderr: *std.Io.Writer, out: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(out)) |dir| {
        std.Io.Dir.cwd().createDirPath(init.io, dir) catch {};
    }
    std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out, .data = data }) catch |err| {
        try stderr.print("corewire: cannot write {s}: {t}\n", .{ out, err });
        try stderr.flush();
        std.process.exit(1);
    };
}
