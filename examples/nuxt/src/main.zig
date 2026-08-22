const std = @import("std");
const runner = @import("runner");
const zero_native = @import("zero-native");

pub const panic = std.debug.FullPanic(zero_native.debug.capturePanic);

const App = struct {
    env_map: *std.process.Environ.Map,

    fn app(self: *@This()) zero_native.App {
        return .{
            .context = self,
            .name = "nuxt-example",
            .source = zero_native.frontend.productionSource(.{ .dist = "frontend/.output/public" }),
            .source_fn = source,
        };
    }

    fn source(context: *anyopaque) anyerror!zero_native.WebViewSource {
        const self: *@This() = @ptrCast(@alignCast(context));
        return zero_native.frontend.sourceFromEnv(self.env_map, .{
            .dist = "frontend/.output/public",
            .entry = "index.html",
        });
    }
};

const dev_origins = [_][]const u8{ "zero://app", "zero://inline", "http://127.0.0.1:3000" };

pub fn main(init: std.process.Init) !void {
    var app = App{ .env_map = init.environ_map };
    try runner.runWithOptions(app.app(), .{
        .app_name = "Nuxt Example",
        .window_title = "Nuxt Example",
        .bundle_id = "dev.zero_native.nuxt-example",
        .icon_path = "assets/icon.icns",
        .security = .{
            .navigation = .{ .allowed_origins = &dev_origins },
        },
    }, init);
}

test "production source points at Nuxt build output" {
    const source = zero_native.frontend.productionSource(.{ .dist = "frontend/.output/public" });
    try std.testing.expectEqual(zero_native.WebViewSourceKind.assets, source.kind);
    try std.testing.expectEqualStrings("frontend/.output/public", source.asset_options.?.root_path);
}
