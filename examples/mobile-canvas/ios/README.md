# iOS simulator shim for mobile embed libraries

A minimal ObjC presentation shim (no `.xcodeproj`) that links any `zero_native.addMobileLib` static library and shows its canvas scene on the iOS simulator. Presentation only: a `CADisplayLink` pumps `zero_native_app_frame`, and each frame whose canvas revision changed is rendered over the ABI (`zero_native_app_render_pixels`, CPU reference renderer, RGBA8), swizzled to BGRA, uploaded with `MTLTexture replaceRegion`, and blit-copied to the `CAMetalLayer` drawable — mirroring the macOS raster path in `src/platform/macos/appkit_host.m`. Touch/IME forwarding and safe-area layout are later milestones.

## Run

```sh
# mobile-canvas on an "iPhone 15" simulator, screenshot + non-blank check
./run.sh

# ui-inbox through the same shim
./run.sh --example-dir ../../ui-inbox --build-arg -Dmobile=true

# options
./run.sh --device "iPhone 15 Pro"   # pick a simulator
./run.sh --build-only               # stop after the .app bundle
./run.sh --shutdown                 # shut the simulator down afterwards
```

The script cross-compiles the example's embed library (`zig build lib -Dtarget=aarch64-ios-simulator`), compiles `main.m` with the simulator SDK, assembles `build/<name>/<name>.app`, installs + launches it, and fails unless a screenshot samples as non-blank.

## Files

- `main.m` — UIWindow + CAMetalLayer view + display link + blit presenter.
- `zero_native_app.h` — the ABI subset the shim drives (layouts mirror `src/embed/types.zig`).
- `Info.plist.in` — bundle plist template (`__APP_NAME__`/`__BUNDLE_ID__` substituted by `run.sh`).
- `run.sh` — build, bundle, install, launch, screenshot, verify.
