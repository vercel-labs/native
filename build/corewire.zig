//! Host-only corewire build shared by app builds and the SDK test graph.
const std = @import("std");

pub fn profileArchive(b: *std.Build, sdk: *std.Build, node: []const u8) std.Build.LazyPath {
    const source = b.addWriteFiles();
    _ = source.addCopyFile(sdk.path("tools/corewire/emit_profile.ts"), "emit_profile.ts");
    _ = source.addCopyFile(sdk.path("tools/corewire/emit_service.ts"), "emit_service.ts");
    _ = source.addCopyFile(sdk.path("tools/corewire/service_templates.ts"), "service_templates.ts");
    for ([_][]const u8{ "core_contract.ts", "core_projection.ts", "core_vocabulary.ts", "core_policy.ts", "core_emission.ts", "emit_mirror.ts", "emit_facade.ts", "mirror_templates.ts", "facade_templates.ts" }) |file| {
        _ = source.addCopyFile(sdk.path(b.fmt("tools/corewire/{s}", .{file})), file);
    }
    _ = source.addCopyFile(sdk.path("tools/corewire/profile_library.json"), "profile_library.json");
    const compile = b.addSystemCommand(&.{node});
    compile.setName("native corewire projections (scriptc)");
    compile.addFileArg(sdk.path("tools/corewire/build_profile.mjs"));
    compile.addFileInput(sdk.path("packages/core/scripts/compiler_command.mjs"));
    compile.addArg("--stage");
    compile.addDirectoryArg(source.getDirectory());
    compile.addArg("--manifest");
    compile.addFileArg(sdk.path("packages/core/package.json"));
    compile.addArgs(&.{
        "--host-platform",
        b.fmt("{t}-{t}-{t}", .{ b.graph.host.result.cpu.arch, b.graph.host.result.os.tag, b.graph.host.result.abi }),
        "--zig-exe",
        b.graph.zig_exe,
    });
    if (b.graph.environ_map.get("NATIVE_SDK_CORE_COMPILER")) |override| compile.addArgs(&.{ "--compiler", override });
    compile.addArg("--out");
    return compile.addOutputFileArg("libcorewire_profile.a");
}

pub fn linkProfile(mod: *std.Build.Module, archive: std.Build.LazyPath) void {
    mod.addObjectFile(archive);
    mod.link_libc = true;
    if (mod.resolved_target.?.result.os.tag == .windows) {
        mod.linkSystemLibrary("ws2_32", .{});
        mod.linkSystemLibrary("iphlpapi", .{});
        mod.linkSystemLibrary("advapi32", .{});
    }
}

pub fn executable(b: *std.Build, sdk: *std.Build, node: []const u8, optimize: std.builtin.OptimizeMode, use_llvm: ?bool) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = sdk.path("tools/corewire/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    linkProfile(mod, profileArchive(b, sdk, node));
    return b.addExecutable(.{ .name = "corewire", .root_module = mod, .use_llvm = use_llvm });
}
