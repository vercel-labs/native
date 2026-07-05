pub const templates = @import("templates.zig");
pub const manifest = @import("manifest.zig");
pub const raw_manifest = @import("raw_manifest.zig");
pub const assets = @import("assets.zig");
pub const codesign = @import("codesign.zig");
pub const doctor = @import("doctor.zig");
pub const package = @import("package.zig");
pub const dev = @import("dev.zig");
pub const cef = @import("cef.zig");
pub const web_engine = @import("web_engine.zig");
pub const buildgraph = @import("buildgraph.zig");
pub const toolchain = @import("toolchain.zig");
pub const verbs = @import("verbs.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
