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

const usage =
    \\usage: corewire --sidecar <core.contract.json> (--out <core_shim.zig> | --check)
    \\
    \\Generate the Zig mirror module (core_shim.zig) for a compiled core
    \\from its contract sidecar, or validate the sidecar alone (--check).
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
    // Exactly one mode: validate-only or generate.
    if ((out_path == null) == !check_only) {
        try stderr.print("{s}", .{usage});
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

    // `--check` runs the FULL pipeline and discards the text: a sidecar
    // must never pass the checker and then refuse at generate time
    // (emitter-level rules — emission-name collisions above all — are
    // part of the contract's validity).
    const generated: []const u8 = emit_mod.emit(arena, parsed, &diags) catch |err| switch (err) {
        error.Refused => {
            try diags.write(input, stderr);
            try stderr.flush();
            std.process.exit(1);
        },
        error.OutOfMemory => return err,
    };

    // Warnings (unknown additive fields) surface even on success.
    try diags.write(input, stderr);
    try stderr.flush();

    if (out_path) |out| {
        if (std.fs.path.dirname(out)) |dir| {
            std.Io.Dir.cwd().createDirPath(init.io, dir) catch {};
        }
        std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out, .data = generated }) catch |err| {
            try stderr.print("corewire: cannot write {s}: {t}\n", .{ out, err });
            try stderr.flush();
            std.process.exit(1);
        };
    }
}
