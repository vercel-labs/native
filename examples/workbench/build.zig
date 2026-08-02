// This example owns its build for exactly one reason: live `<terminal>`
// sessions. `terminal_sessions = true` makes the framework resolve the
// lazy ghostty pin from THIS build.zig.zon (with the app module's
// target/optimize and the safe import flags) — the consumer-safe seam,
// so scaffolded apps never traverse ghostty's dependency graph.
// Everything else is the standard app build.
const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("native_sdk", .{});
    const artifacts = native_sdk.addAppArtifacts(b, dep, .{
        .name = "workbench",
        .terminal_sessions = true,
    });

    // The toolkit's own terminal-session store tests run HERE, because
    // this is a build that WIRES the emulator: the toolkit package pins
    // none, so under its own `zig build test` those cases skip. Zig only
    // runs tests from a compilation's root module, so they get their own
    // test artifact — rooted at that file, carrying the framework
    // module's imports (`terminal_vt` among them, the enabled half).
    const sdk_mod = artifacts.tests.root_module.import_table.get("native_sdk").?;
    const session_tests = b.addTest(.{
        // Only the store's cases: a test root pulls in whatever its
        // imports declare, and the rest of the toolkit's suite belongs to
        // the toolkit's own `zig build test`.
        .filters = &.{"terminal_session_tests"},
        .root_module = b.createModule(.{
            .root_source_file = dep.path("src/terminal_session_tests_root.zig"),
            .target = sdk_mod.resolved_target,
            .optimize = sdk_mod.optimize orelse .Debug,
        }),
    });
    var imports = sdk_mod.import_table.iterator();
    while (imports.next()) |entry| {
        session_tests.root_module.addImport(entry.key_ptr.*, entry.value_ptr.*);
    }
    if (b.top_level_steps.get("test")) |test_step| {
        test_step.step.dependOn(&b.addRunArtifact(session_tests).step);
    }
}
