//! The toolkit-owned iOS host sources as embedded bytes — the `ios_host`
//! module the CLI tooling imports. The host lives here (next to the
//! other platform hosts) and the CLI carries the bytes, so `native dev
//! --target ios` and `native package --target ios` emit the same host
//! wherever the binary runs.

pub const uikit_host_m = @embedFile("uikit_host.m");
pub const native_sdk_app_h = @embedFile("native_sdk_app.h");
pub const apple_image_fit_h = @embedFile("apple_image_fit.h");
