//! Root module of a mobile embed static library compiled WITH a user app
//! (`native_sdk.addMobileLib` wires the app's mobile entry as the `"app"`
//! import). Exports the `native_sdk_app_*` C ABI answered by a
//! `UiAppHost` driving the app's UiApp on a gpu_surface canvas scene
//! (window 1, label "mobile-surface").

const native_sdk = @import("native_sdk");
const mobile_build_options = @import("mobile_build_options");

comptime {
    native_sdk.embed.exportMobileCApi(native_sdk.embed.UiAppHostWithRecordStore(
        @import("app"),
        mobile_build_options.store_capability,
    ));
}
