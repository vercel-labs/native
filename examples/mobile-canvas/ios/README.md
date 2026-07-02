# iOS simulator shim for mobile embed libraries

A minimal ObjC shim (no `.xcodeproj`) that links any `zero_native.addMobileLib` static library and shows its canvas scene on the iOS simulator. Presentation: a `CADisplayLink` pumps `zero_native_app_frame`, and each frame whose canvas revision changed is rendered over the ABI (`zero_native_app_render_pixels`, CPU reference renderer, RGBA8), swizzled to BGRA, uploaded with `MTLTexture replaceRegion`, and blit-copied to the `CAMetalLayer` drawable — mirroring the macOS raster path in `src/platform/macos/appkit_host.m`. Input: UITouch sequences forward through the ABI touch/scroll exports (tap presses widgets, over-slop pans scroll through the existing scroll reconciliation), the system keyboard shows/hides off `zero_native_app_text_input_state` (textbox focus = first responder), and UITextInput marked text maps onto the `zero_native_app_ime` composition path desktop hosts use. Safe-area layout is a later milestone.

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

## Verify input (hardware-true)

```sh
# ui-inbox: injected tap grows the list, textbox focus raises the system
# keyboard, typed text lands in the model, drag-scroll moves the offset
./verify_input.sh
./verify_input.sh --device "iPhone 15 Pro" --shutdown
```

`verify_input.sh` launches the app with `ZERO_NATIVE_AUTOMATION=1` (the shim points the runtime's automation snapshots into the app's data container via `zero_native_app_set_automation_dir`), compiles `InputUITests.m` into an XCUITest bundle hosted by the stock `XCTRunner.app` (generated `.xctestrun`, `xcodebuild test-without-building` — still no `.xcodeproj`), injects real system touch/keyboard events, and asserts model state between steps against `snapshot.txt`.

## Files

- `main.m` — UIWindow + CAMetalLayer view + display link + blit presenter + touch forwarding + UIKeyInput/UITextInput keyboard and IME bridge.
- `zero_native_app.h` — the ABI subset the shim drives (layouts mirror `src/embed/types.zig`).
- `Info.plist.in` — bundle plist template (`__APP_NAME__`/`__BUNDLE_ID__` substituted by `run.sh`).
- `run.sh` — build, bundle, install, launch, screenshot, verify.
- `InputUITests.m` / `verify_input.sh` — real input injection + snapshot-asserted M3 verification.
