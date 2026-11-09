const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

extern fn native_swift_proof_create_view() callconv(.c) *anyopaque;
extern fn native_swift_proof_release_view(view: *anyopaque) callconv(.c) void;

const views = [_]native_sdk.ShellView{
    .{ .label = "content", .kind = .stack, .fill = true },
};
const windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Swift Toolchain Proof",
    .width = 480,
    .height = 280,
    .views = &views,
}};
const scene: native_sdk.ShellConfig = .{ .windows = &windows };

const ProofApp = struct {
    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "swift-toolchain-proof",
            .scene_fn = sceneFn,
            .start_fn = start,
        };
    }

    fn sceneFn(_: *anyopaque) anyerror!native_sdk.ShellConfig {
        return scene;
    }

    fn start(_: *anyopaque, _: *native_sdk.Runtime) anyerror!void {
        // Phase 1 proves construction and C-ABI ownership. Adoption into the
        // stack is intentionally deferred to the hosted-window phases.
        createAndReleaseHostingView();
    }
};

fn createAndReleaseHostingView() void {
    const view = native_swift_proof_create_view();
    native_swift_proof_release_view(view);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and std.mem.eql(u8, args[1], "--swift-proof-smoke")) {
        createAndReleaseHostingView();
        std.debug.print("swift-toolchain-proof: NSHostingView created and released\n", .{});
        return;
    }

    var proof = ProofApp{};
    try runner.runWithOptions(proof.app(), .{
        .app_name = "swift-toolchain-proof",
        .window_title = "Swift Toolchain Proof",
        .bundle_id = "dev.native_sdk.swift_toolchain_proof",
        .default_frame = native_sdk.geometry.RectF.init(0, 0, 480, 280),
    }, init);
}

test "Swift C ABI returns a retained NSHostingView object" {
    createAndReleaseHostingView();
}
