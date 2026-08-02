# Code Signing

Sign and notarize your Native SDK app for distribution.

## macOS signing

Sign the bundle with a Developer ID:

```bash
native package --target macos --signing identity --identity "Developer ID Application: Your Name"
```

Signing modes:

<table>
  <thead>
    <tr>
      <th>Mode</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>none</code></td>
      <td>No signing (default)</td>
    </tr>
    <tr>
      <td><code>adhoc</code></td>
      <td>Ad-hoc signing for local testing</td>
    </tr>
    <tr>
      <td><code>identity</code></td>
      <td>Sign with a named identity (requires <code>--identity</code>)</td>
    </tr>
  </tbody>
</table>

## What Gatekeeper shows for an ad-hoc package

An ad-hoc signature carries no developer identity, so Gatekeeper cannot verify who built the app. What that means in practice depends on whether the copy carries the quarantine attribute:

- **Downloaded through a browser** (or anything else that sets quarantine): the first launch shows the standard dialog — macOS "cannot check it for malicious software" / cannot verify the app "is free of malware". This is not an error in the package; it is Gatekeeper's honest answer for any app without a notarized Developer ID signature. The user can still run it: right-click (or Control-click) the app in Finder, choose **Open**, and the dialog gains an **Open** button that launches the app and remembers the choice.
- **Copied over scp, USB, rsync, or a local build**: these transfers set no quarantine attribute, so the app launches directly with no dialog at all.

Either way the signature itself is valid — `codesign --verify --strict` passes on every package the toolkit signs, and the packaging test suite pins that (`zig build test-package-signing`). If Gatekeeper ever calls a package "damaged" instead of showing the dialog above, the bundle was modified after signing (a broken resource seal), which is a real defect — not the expected ad-hoc experience.

For distribution without any dialog, sign with a Developer ID (`--signing identity`) and notarize; see below.

## Signing flags

<table>
  <thead>
    <tr>
      <th>Flag</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>--signing</code></td>
      <td>Signing mode: <code>none</code>, <code>adhoc</code>, or <code>identity</code></td>
    </tr>
    <tr>
      <td><code>--identity</code></td>
      <td>Code signing identity name</td>
    </tr>
    <tr>
      <td><code>--entitlements</code></td>
      <td>Path to entitlements file (e.g. <code>assets/native-sdk.entitlements</code>)</td>
    </tr>
    <tr>
      <td><code>--team-id</code></td>
      <td>Apple Developer Team ID</td>
    </tr>
  </tbody>
</table>

## Notarization

The framework repository includes a `zig build notarize` helper for local release testing:

```bash
zig build notarize
```

Generated apps should use `native package --target macos --signing identity ...` unless they add their own `notarize` build step. This helper does not invoke `xcrun notarytool` directly. After the signed package is created, submit it for notarization manually:

```bash
xcrun notarytool submit zig-out/package/your-app.zip --apple-id "you@example.com" --team-id "TEAMID" --password "@keychain:AC_PASSWORD" --wait
xcrun stapler staple zig-out/package/your-app.app
```

## Chromium apps

Chromium packages include `Chromium Embedded Framework.framework` inside the `.app`. Sign and notarize the final package after CEF has been bundled so the app binary, helper executables, and embedded framework are covered by the same distribution identity.

```bash
native cef install --version <pinned-version>
zig build
native package --target macos --signing identity --identity "Developer ID Application: Your Name"
hdiutil create -volname "Your App" -srcfolder zig-out/package/your-app.app -ov -format UDZO zig-out/package/your-app.dmg
```

Use `.web_engine = "chromium"` and `.cef = .{ .dir = "third_party/cef/macos", .auto_install = false }` in `app.zon` for the normal signing path. `-Dweb-engine`, `--web-engine`, `-Dcef-dir`, and `--cef-dir` remain available for temporary overrides.

If Gatekeeper rejects the app, check that the CEF framework is present in `Contents/Frameworks`, that every nested helper is signed, and that the package was rebuilt after any CEF version change.

## DMG creation

Create a distributable disk image:

```bash
zig build dmg
```

## Entitlements

The project includes `assets/native-sdk.entitlements` as a starting point. Customize it for your app's needs (e.g. network access, file system access, camera).
