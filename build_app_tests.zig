const std = @import("std");

test {
    std.testing.refAllDecls(@import("build/app.zig"));
}
