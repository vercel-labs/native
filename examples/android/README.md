# Android Example

A minimal Android mobile shell that embeds a zero-native static library through JNI. The example keeps a native Android header above a WebView workspace and routes native navigation/header actions through the zero-native command path.

Android views own the mobile shell layout: native header sizing, density-aware resize events, touch forwarding, and the `WebView` workspace. The zero-native runtime is driven through JNI calls into the C ABI.

## Build the native library

Build or package an Android static library from the repository root, then copy it into this example:

```bash
zig build lib -Dtarget=aarch64-linux-android
mkdir -p examples/android/app/src/main/cpp/lib
cp zig-out/lib/libzero-native.a examples/android/app/src/main/cpp/lib/libzero-native.a
```

The CMake project expects the library at `app/src/main/cpp/lib/libzero-native.a` and the C header at `app/src/main/cpp/zero_native.h`.

## Run

Open `examples/android` in Android Studio, or build from the command line with a configured Android SDK:

```bash
./gradlew :app:assembleDebug
```

Install on an emulator or device:

```bash
./gradlew :app:installDebug
```

## Files

- `app/src/main/java/dev/zero_native/examples/android/MainActivity.kt` hosts native Android chrome, a WebView workspace, a `SurfaceView`, and the JNI bridge.
- `app/src/main/cpp/zero_native_jni.c` forwards JNI calls to the zero-native C ABI.
- `app/src/main/cpp/CMakeLists.txt` imports `libzero-native.a` and builds the JNI shared library.
- `app.zon` records the mobile example metadata for zero-native tooling.

## Host lifecycle

- `onCreate` loads the JNI library, creates the native shell, then starts the zero-native app.
- `onResume` and `onPause` forward activation lifecycle with `zero_native_app_activate` and `zero_native_app_deactivate`.
- `surfaceChanged` forwards size, display density, and the Android `Surface`, then requests a frame.
- The native Back and Refresh buttons call `nativeCommand` with stable mobile command IDs, update status from `zero_native_app_last_command_count`, and request a frame.
- The Android system Back action dispatches `mobile.back` through the same command path.
- `onTouchEvent` forwards pointer id, phase, position, and pressure.
- `surfaceDestroyed` and `onDestroy` stop and destroy the app.

The generic desktop `ShellView` runtime is not mapped to Android `ViewGroup` yet; native mobile chrome is implemented directly in Kotlin in this example.
