const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const HelloApp = struct {
    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "hello",
            .source = native_sdk.WebViewSource.html(
                \\<!doctype html>
                \\<html>
                \\<body style="font-family: -apple-system, system-ui, sans-serif; padding: 2rem;">
                \\  <h1>Hello from Native SDK</h1>
                \\  <p>This app is rendered by the platform WebView.</p>
                \\</body>
                \\</html>
            ),
        };
    }
};

pub fn main(init: std.process.Init) !void {
    var app = HelloApp{};
    try runner.runWithOptions(app.app(), .{
        .app_name = "hello",
        .window_title = "Hello",
        .bundle_id = "dev.native_sdk.hello",
    }, init);
}

test "hello app uses inline HTML source" {
    var state = HelloApp{};
    const app = state.app();
    try std.testing.expectEqualStrings("hello", app.name);
    try std.testing.expectEqual(native_sdk.WebViewSourceKind.html, app.source.kind);
    try std.testing.expect(std.mem.indexOf(u8, app.source.bytes, "Hello from Native SDK") != null);
}
