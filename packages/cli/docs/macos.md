# Shipping a macOS app

`native build . --release` writes an app you can hand to someone: a `.app` Finder opens, signed
with the hardened runtime, and a `.dmg` with an Applications link. `native run . --release` does
the same and then runs the app from the bundle.

```console
$ native build . --release -o dist/Notes
$ ls dist
Notes.app   Notes-1.4.0.dmg
```

The identity, version and icon come from the app itself, as [the CLI reference](cli.md#release-builds)
describes: the page's web app manifest (or its `<title>` and `<link rel="icon">`), with
`NATIVE_APP_ID` and `NATIVE_APP_VERSION` overriding the manifest. The bundle holds them in
`Contents/Resources/.native/app.json`; `Info.plist` carries `CFBundleIdentifier`,
`CFBundleDisplayName`, `CFBundleShortVersionString`, `CFBundleVersion` and `CFBundleIconFile`.

## Signing

A release build is always signed. With `NATIVE_SIGN_IDENTITY` set to a Developer ID Application
identity, the signature is that identity's and carries a secure timestamp; with it unset the build
signs ad-hoc:

```console
$ NATIVE_SIGN_IDENTITY="Developer ID Application: Example Corp (TEAMID1234)" native build . --release
$ native build . --release        # ad-hoc
```

Either way the signature turns on the hardened runtime with an entitlements plist that grants no
exceptions (`compiler/package-macos.ts` writes it): the app runs its own compiled machine code and
loads only system libraries, so it needs no JIT, unsigned executable memory or library-validation
exception. An ad-hoc signed app runs on the Mac that built it; another Mac's Gatekeeper refuses it,
which is what notarization fixes.

## Notarization

Notarization is opt-in and reads its credentials from the environment, so nothing secret is in the
repository or the bundle. Set either a keychain profile, or all three App Store Connect values:

```console
$ NATIVE_NOTARY_KEYCHAIN_PROFILE=notary native build . --release
$ NATIVE_NOTARY_APPLE_ID=dev@example.com \
  NATIVE_NOTARY_PASSWORD=app-specific-password \
  NATIVE_NOTARY_TEAM_ID=TEAMID1234 native build . --release
```

A partial set is an error: the build stops before compiling rather than failing after a long
sign. Notarization needs a Developer ID identity too, so `NATIVE_SIGN_IDENTITY` must be set.

When credentials are present the build:

1. zips the `.app` with `ditto` and submits it to `xcrun notarytool submit --wait`; a rejection
   fails the build and prints notarytool's log;
2. staples the ticket to the `.app` with `xcrun stapler staple`, so it validates offline wherever
   the app is copied;
3. makes the `.dmg`, signs it with the same identity, submits and staples it the same way.

Without credentials the build still signs (ad-hoc or Developer ID) and writes the `.dmg`, printing
that notarization was skipped.

## The disk image

The `.dmg` is written beside the `.app`, named for the app's short name and version
(`Notes-1.4.0.dmg`). It holds the app and an `Applications` symlink, so a user drags the app to
Applications. `hdiutil create -format UDZO` makes it compressed; the volume is named
`<short name> <version>`.

## Checking a build

```console
$ codesign --verify --strict --verbose=2 dist/Notes.app
$ codesign -dv --verbose=4 dist/Notes.app
$ hdiutil verify dist/Notes-1.4.0.dmg
$ xcrun stapler validate dist/Notes.app     # when notarized
$ spctl -a -vvv -t exec dist/Notes.app      # when signed with a Developer ID
```

`codesign -dv` shows `flags=…(runtime)` for the hardened runtime and the identifier the manifest
set. An ad-hoc signature reads `Signature=adhoc` and `TeamIdentifier=not set`.
