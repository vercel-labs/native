//! Root module of a mobile embed static library compiled WITH a user app
//! (`zero_native.addMobileLib` wires the app's mobile entry as the `"app"`
//! import). Exports the `zero_native_app_*` C ABI answered by a
//! `UiAppHost` driving the app's UiApp on a gpu_surface canvas scene
//! (window 1, label "mobile-surface").

const zero_native = @import("zero-native");

comptime {
    zero_native.embed.exportMobileCApi(zero_native.embed.UiAppHost(@import("app")));
}
