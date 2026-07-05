// This example owns its build: the -Dmobile `lib` step builds the mobile embed static library that the iOS/Android host shims consume, which the generated app graph does not provide.
const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    // -Dmobile=true builds the mobile embed static library (the
    // `native_sdk_app_*` C ABI compiled with this app's UiApp) instead of
    // the desktop executable; both register `target`/`optimize`, so the
    // choice is exclusive per invocation.
    const mobile = b.option(bool, "mobile", "Build the mobile embed static library instead of the desktop app") orelse false;
    if (mobile) {
        native_sdk.addMobileLib(b, b.dependency("native_sdk", .{}), .{ .name = "ui-inbox" });
    } else {
        native_sdk.addApp(b, b.dependency("native_sdk", .{}), .{ .name = "ui-inbox" });
    }
}
