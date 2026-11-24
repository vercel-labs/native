# Shipping a Linux app

`native build . --release` writes two artifacts beside the executable: a `.deb` a package manager
installs, and an AppImage someone runs from a download folder. Both carry a `.desktop` entry and
the app's icon.

```console
$ native build . --release -o dist/notes
$ ls dist
notes  notes.resources  notes_2.1.0_amd64.deb  notes-2.1.0-x86_64.AppImage
```

The executable and its `<executable>.resources` directory are the bundle the plain build already
writes; `--release` adds the package files around it. `native run . --release` packages and then
runs the app.

## Host libraries

The Linux host links the system's graphics, text, audio, storage and IPC libraries. A machine that
builds or runs the app needs them; on Debian and Ubuntu:

```console
$ sudo apt-get install libcairo2 libfreetype6 libfontconfig1 libharfbuzz0b libpng16-16 \
    libjpeg62-turbo libgif7 libdbus-1-3 libasound2 libsqlite3-0 libegl1 libgl1
```

On Ubuntu 24.04 and later the ALSA package is `libasound2t64`, and the JPEG one `libjpeg-turbo8`.

Building needs their headers, `pkg-config`, a C compiler for the host's own source (the `cc`
`build-essential` provides) and `clang`, which scriptc links every app with:

```console
$ sudo apt-get install build-essential clang pkg-config libcairo2-dev libfreetype-dev \
    libfontconfig-dev libharfbuzz-dev libpng-dev libjpeg-dev libgif-dev libdbus-1-dev \
    libasound2-dev libsqlite3-dev libegl-dev libgl-dev
```

The `.deb` names no `Depends` because the library package names differ across distributions;
install them with the package, or let your distribution's packaging add the right names.

## What packaging reads

The app's name, version and icon come from the same facts the app itself carries, in this order:

1. `.native/app.json` in the bundle, written by every bundled build that carries the app's identity.
2. The page's web app manifest (`name`, `short_name`, `version`, `icons`), or its `<title>` and
   `<link rel="icon">` for an app without one.
3. The executable's own name and version `1.0.0`, with a generated icon, for an app that names
   none of this.

The icon must be a PNG; it is installed at its own size in the hicolor theme and in
`/usr/share/pixmaps`, and a generated 256×256 icon stands in when the app has none.

## The .deb

The package is written directly (`compiler/package-linux.ts` builds the ar and tar.gz members),
so `dpkg-deb` isn't needed to make it. It installs:

| Path | What |
| --- | --- |
| `/opt/<package>/<package>` | the executable |
| `/opt/<package>/<package>.resources/` | the images, styles and page tables the app reads |
| `/usr/bin/<package>` | a symlink to the executable |
| `/usr/share/applications/<package>.desktop` | the desktop entry |
| `/usr/share/icons/hicolor/<size>/apps/<package>.png` | the icon at its own size |
| `/usr/share/pixmaps/<package>.png` | the icon for launchers that don't use the theme |

The package name is the app's name in lowercase with hyphens (`Release Notes` is
`release-notes`), and the version is `major.minor.patch`. Inspection:

```console
$ dpkg-deb -I dist/notes_2.1.0_amd64.deb
$ dpkg-deb -c dist/notes_2.1.0_amd64.deb
$ sudo dpkg -i dist/notes_2.1.0_amd64.deb
$ notes
```

## The AppImage

The AppImage is an AppDir holding `AppRun`, the desktop entry, the icon and the executable under
`usr/bin`. It is assembled by `appimagetool`, which isn't part of the SDK: install it (from
[AppImage/appimagetool](https://github.com/AppImage/appimagetool/releases)) and put it on `PATH`,
or point `APPIMAGETOOL` at it. `mksquashfs` must be available too (`squashfs-tools` on Debian).

```console
$ APPIMAGETOOL=/path/to/appimagetool native build . --release
$ chmod +x notes-2.1.0-x86_64.AppImage
$ ./notes-2.1.0-x86_64.AppImage
```

The AppDir is laid out as an installed app, so an extraction shows what a desktop sees:

```console
$ ./notes-2.1.0-x86_64.AppImage --appimage-extract
$ ls squashfs-root
AppRun  notes.desktop  notes.png  usr
$ NATIVE_STEPS='print #h' squashfs-root/AppRun
```

The AppImage still uses the system libraries above; it packages the app, not those libraries.
