const std = @import("std");
const zero_native = @import("zero_native");

pub fn build(b: *std.Build) void {
    // -Dmobile=true builds the mobile embed static library (the
    // `zero_native_app_*` C ABI compiled with this app's UiApp) instead of
    // the desktop executable; both register `target`/`optimize`, so the
    // choice is exclusive per invocation.
    const mobile = b.option(bool, "mobile", "Build the mobile embed static library instead of the desktop app") orelse false;
    if (mobile) {
        zero_native.addMobileLib(b, b.dependency("zero_native", .{}), .{ .name = "ui-inbox" });
    } else {
        zero_native.addApp(b, b.dependency("zero_native", .{}), .{ .name = "ui-inbox" });
    }
}
