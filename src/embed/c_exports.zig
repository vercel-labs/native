//! Root module of the default embeddable static library (`zig build lib`):
//! exports the `zero_native_app_*` C ABI answered by the fixed WebView
//! shell host. Libraries compiled with a user app use
//! `app_exports.zig` (via `zero_native.addMobileLib`) instead.

const zero_native = @import("zero-native");

comptime {
    zero_native.embed.exportMobileCApi(zero_native.embed.MobileHostApp);
}
