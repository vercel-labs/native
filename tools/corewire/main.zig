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
const entry = @import("entry_coordination.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(init.io, &buffer);
    const code = try entry.run(init, args, &writer.interface);
    if (code != 0) std.process.exit(code);
}
