// The host a build links against: host/windows.cpp when the target is Windows, host/macos.m on
// macOS, and the headless host/linux.c elsewhere, plus the portable sources every host shares
// (the Web Audio engine and its decoders). Each is compiled to an object file the FFI manifest
// points scriptc at.
//
// A Windows target is the build host's own when native runs on Windows, and the one scriptc is
// cross-compiling for when SCRIPTC_TARGET names it. Either way scriptc links the app with zig, so
// the host is built with zig as well, for the target that link names.

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";

export const MACOS = process.platform === "darwin";
export const WINDOWS = process.platform === "win32";

/** The target scriptc builds for: SCRIPTC_TARGET when it is set, else this platform's own. */
export function buildTarget(): string | null {
  const target = process.env.SCRIPTC_TARGET;
  return target !== undefined && target.trim() !== "" ? target.trim() : null;
}

/** Whether a target names Windows, either the GNU or the MSVC flavor. */
export function isWindowsTarget(target: string | null): boolean {
  return target !== null && /windows/.test(target);
}

/** Whether this build makes a Windows executable. */
export function buildingWindows(platform: NodeJS.Platform = process.platform, target = buildTarget()): boolean {
  return platform === "win32" || isWindowsTarget(target);
}

/** The host source for this platform and target. */
export function hostSource(hostDir: string, platform: NodeJS.Platform = process.platform, target = buildTarget()): string {
  if (buildingWindows(platform, target)) return join(hostDir, "windows.cpp");
  return join(hostDir, platform === "darwin" ? "macos.m" : "linux.c");
}

/** The portable parts of the host: the Web Audio engine, its decoders, and the SVG filter
 *  pixel engine. */
export const HOST_COMMON_SOURCES = ["audio.c", "audio-decode.c", "stb_vorbis_impl.c", "svg-filter.c"];

/**
 * The compositor's shared core and the D3D11 backend, for a Windows target. macOS and Linux
 * include the core into their own host source; Windows compiles it into objects of its own, since
 * its host is C++ and the core is C.
 */
export const WINDOWS_COMPOSITOR_SOURCES = [
  "compositor/compositor.c",
  "compositor/layers.c",
  "compositor/tiles.c",
  "compositor/chunks.c",
  "compositor/d3d11.cpp",
];

/** Every source a build compiles into the host, the platform's own first. */
export function hostSources(hostDir: string, platform: NodeJS.Platform = process.platform,
                             target = buildTarget()): string[] {
  const sources = [hostSource(hostDir, platform, target), ...HOST_COMMON_SOURCES.map((name) => join(hostDir, name))];
  if (buildingWindows(platform, target)) {
    for (const name of WINDOWS_COMPOSITOR_SOURCES) sources.push(join(hostDir, name));
  }
  return sources;
}

/** The content of a host source and every file it includes by quoted path, in one digest. The
 *  macOS host includes the compositor's sources, so a change to metal.m is a change to it even
 *  though macos.m itself is byte for byte the same. */
export function hostSourceDigest(source: string): string {
  const hash = createHash("sha256");
  const seen = new Set<string>();
  const visit = (file: string): void => {
    const path = resolve(file);
    if (seen.has(path)) return;
    seen.add(path);
    const text = readFileSync(path, "utf8");
    hash.update(path).update("\0").update(text).update("\0");
    for (const match of text.matchAll(/^[ \t]*#[ \t]*include[ \t]*"([^"]+)"[ \t]*$/gm)) {
      const included = resolve(dirname(path), match[1]);
      if (existsSync(included)) visit(included);
    }
  };
  visit(source);
  return hash.digest("hex");
}

/** The import library a Windows build links for winsqlite3.dll, made from the .def beside the
 *  host sources with the toolchain's own dlltool. The DLL is Windows' own (Windows 10 and later
 *  ship it), and zig's sysroot carries no import library for it. */
export function windowsSqliteImportLibrary(hostDir: string, buildDir: string): string {
  const def = join(hostDir, "vendor", "winsqlite3.def");
  const lib = join(buildDir, "winsqlite3.a");
  if (existsSync(lib) && statSync(lib).mtimeMs >= statSync(def).mtimeMs) return lib;
  const made = spawnSync("zig", ["dlltool", "-d", def, "-l", lib]);
  if (made.error !== undefined || made.status !== 0 || !existsSync(lib)) {
    const why = made.error !== undefined ? made.error.message : `zig dlltool exited ${made.status}`;
    throw new Error(`failed to make the winsqlite3 import library: ${why}`);
  }
  return lib;
}

/** Whether a host source is the compositor's C++ backend, which needs the C++ toolchain. */
export function isCompositorBackend(hostSrc: string): boolean {
  return /compositor[\\/]d3d11\.cpp$/.test(hostSrc);
}

/** The compiler and flags for the compositor's C++ backend: the same toolchain the Windows host
 *  uses, since its objects link into the same program. */
export function hostCompositorCompileCommand(hostSrc: string, outObj: string, platform: NodeJS.Platform = process.platform,
                                             target = buildTarget()): { cc: string; args: string[] } {
  return windowsHostCommand(hostSrc, outObj, target);
}

/** The libraries the Linux host links, as names for the linker. */
export const LINUX_HOST_LIBRARIES = ["cairo", "freetype", "fontconfig", "harfbuzz", "png", "jpeg", "gif", "dbus-1", "asound", "EGL", "GL", "pthread", "sqlite3", "m"];

/** The libraries the Windows host links: Direct2D, DirectWrite, Direct3D 11 and the platform's own. */
export const WINDOWS_HOST_LIBRARIES = [
  "d2d1", "dwrite", "d3d11", "dxgi", "windowscodecs", "uuid", "user32", "gdi32", "ole32",
  "oleaut32", "shcore", "advapi32", "shell32", "uiautomationcore", "imm32",
];

/** Packages the Linux host's headers come from, through pkg-config. */
const LINUX_HOST_PACKAGES = ["cairo", "freetype2", "fontconfig", "harfbuzz", "libpng", "libjpeg", "libgif", "dbus-1", "alsa", "sqlite3", "egl", "gl"];

/** What a build tells the user to install when pkg-config itself is missing. */
const LINUX_HOST_INSTALL = "install build-essential (for cc), clang, pkg-config, libcairo2-dev, libfreetype-dev, libfontconfig-dev, libharfbuzz-dev, libpng-dev, libjpeg-dev, libgif-dev, libdbus-1-dev, libasound2-dev, libsqlite3-dev, libegl-dev and libgl-dev";

/** The compile flags those packages name. A release can ship a package's headers without a .pc
 *  file — Ubuntu 22.04's libgif-dev has no libgif.pc, while 24.04 and later ship one — and one
 *  such package fails the query for all of them. Its header is in the compiler's default include
 *  path, so the package contributes no flags; a dev package missing altogether then fails at its
 *  first include, which names the header. */
function linuxHostCflags(): string[] {
  const all = spawnSync("pkg-config", ["--cflags", ...LINUX_HOST_PACKAGES], { encoding: "utf8" });
  if (all.error !== undefined) throw new Error(`failed to run pkg-config; ${LINUX_HOST_INSTALL}`);
  if (all.status === 0) return all.stdout.trim().split(/\s+/).filter(Boolean);
  // The package without a .pc file fails the one query, so ask each on its own and take the flags
  // of the ones pkg-config names.
  const flags: string[] = [];
  for (const name of LINUX_HOST_PACKAGES) {
    const one = spawnSync("pkg-config", ["--cflags", name], { encoding: "utf8" });
    if (one.error !== undefined) throw new Error(`failed to run pkg-config; ${LINUX_HOST_INSTALL}`);
    if (one.status === 0) flags.push(...one.stdout.trim().split(/\s+/).filter(Boolean));
  }
  return [...new Set(flags)];
}

/** Whether a command is on the PATH, which decides how the Windows host is compiled. */
function onPath(command: string): boolean {
  const probe = process.platform === "win32"
    ? spawnSync("where.exe", [command], { stdio: "ignore" })
    : spawnSync("sh", ["-c", `command -v ${command}`], { stdio: "ignore" });
  return !probe.error && probe.status === 0;
}

/** The name of the generated header the macOS host includes, in the build directory. */
export const METAL_SHADER_HEADER = "native-metal-shaders.h";

/** The compositor's shaders, compiled for this Mac: the header the host compiles in carries the
 *  metallib and the source the app falls back to, and the key covers both. */
export interface MetalShaders {
  header: string;
  /** Digest of everything the header was made from; the host objects' key includes it. */
  key: string;
  /** Whether the header carries a metallib. Without one the app compiles at launch. */
  precompiled: boolean;
  /** What to tell the user when the build could not precompile the shaders. */
  note: string;
}

/** Whether the Mac's Xcode toolchain has the offline Metal compiler, `xcrun metal`. A Mac with
 *  only the command line tools has the compiler itself but no way to ask it for a metallib. */
function hasMetalTools(): boolean {
  for (const tool of ["metal", "metallib"]) {
    const probe = spawnSync("xcrun", ["--sdk", "macosx", "--find", tool], { encoding: "utf8" });
    if (probe.error !== undefined || probe.status !== 0 || probe.stdout.trim() === "") return false;
  }
  return true;
}

/** A C string literal for `text`, one source line at a time, which is what the generated header
 *  holds so a build without a metallib can still compile the shaders at launch. */
function cString(text: string): string {
  const lines = text.split("\n");
  return lines.map((line, i) => {
    let out = '"';
    for (const ch of line) {
      if (ch === "\\") out += "\\\\";
      else if (ch === '"') out += '\\"';
      else if (ch === "\t") out += "\\t";
      else if (ch >= " " && ch <= "~") out += ch;
      else out += "\\" + ch.codePointAt(0)!.toString(8).padStart(3, "0");
    }
    out += i === lines.length - 1 ? '"' : '\\n"';
    return out;
  }).join("\n  ");
}

/** The header's text for a metallib (which may be empty) and the shader source. */
function shaderHeader(bytes: Buffer | null, source: string): string {
  const byteLines: string[] = [];
  if (bytes === null) {
    byteLines.push("  0,");
  } else {
    for (let i = 0; i < bytes.length; i += 16) {
      byteLines.push("  " + Array.from(bytes.subarray(i, i + 16), (b) => "0x" + b.toString(16).padStart(2, "0")).join(", ") + ",");
    }
  }
  return [
    "// Generated by native from host/compositor/shaders.metal. Do not edit.",
    "#ifndef NATIVE_METAL_SHADERS_H",
    "#define NATIVE_METAL_SHADERS_H",
    "",
    "#include <stddef.h>",
    "",
    "// The compositor's shaders, compiled when the app was built. Empty when the build had no",
    "// Metal toolchain, in which case the source below is compiled at launch.",
    "static const unsigned char native_quad_metallib[] = {",
    ...byteLines,
    "};",
    `static const size_t native_quad_metallib_len = ${bytes === null ? 0 : bytes.length};`,
    "",
    "// The same shaders in source, for a build that could not carry the compiled form.",
    "static const char native_quad_shader_source[] =",
    "  " + cString(source) + ";",
    "",
    "#endif",
    "",
  ].join("\n");
}

/**
 * Compiles the compositor's Metal shaders into the build directory, as the header the host
 * includes. `xcrun metal` and `metallib` make the metallib when Xcode's toolchain is installed.
 * Without it, the Metal compiler every Mac has still produces one at build time: capture-shaders
 * takes the AIR library it writes. When neither can, the header carries only the source, and the
 * app compiles that at launch.
 */
export function prepareMetalShaders(hostDir: string, buildDir: string,
                                    platform: NodeJS.Platform = process.platform): MetalShaders | null {
  if (platform !== "darwin") return null;
  const shaderPath = join(hostDir, "compositor", "shaders.metal");
  const source = readFileSync(shaderPath, "utf8");
  const helperPath = join(hostDir, "compositor", "capture-shaders.m");
  const helperSource = readFileSync(helperPath, "utf8");
  const headerPath = join(buildDir, METAL_SHADER_HEADER);
  const metallibPath = join(buildDir, "native-metal-shaders.metallib");
  const keyPath = headerPath + ".key";
  const tools = hasMetalTools();
  // The toolchain belongs in the key: a build that had no Metal compiler is worth redoing once
  // one is installed, since the app then carries the shaders instead of compiling them.
  const key = createHash("sha256")
    .update(source).update("\0").update(helperSource).update("\0")
    .update(tools ? "xcrun" : "capture")
    .digest("hex");
  if (existsSync(headerPath) && existsSync(keyPath) && readFileSync(keyPath, "utf8") === key) {
    const header = readFileSync(headerPath, "utf8");
    const precompiled = /native_quad_metallib_len = [1-9]/.test(header);
    return {
      header,
      key: createHash("sha256").update(key).update(header).digest("hex"),
      precompiled,
      note: precompiled ? "" : "no Metal toolchain was available, so the compositor's shaders were not precompiled",
    };
  }
  mkdirSync(buildDir, { recursive: true });
  let bytes: Buffer | null = null;
  let note = "";
  if (tools) {
    const air = join(buildDir, "native-metal-shaders.air");
    const compiled = spawnSync("xcrun", ["--sdk", "macosx", "metal", "-c", shaderPath, "-o", air], { encoding: "utf8" });
    const linked = compiled.status === 0 && !compiled.error
      ? spawnSync("xcrun", ["--sdk", "macosx", "metallib", air, "-o", metallibPath], { encoding: "utf8" })
      : compiled;
    if (compiled.status === 0 && linked.status === 0 && !linked.error && existsSync(metallibPath)) {
      bytes = readFileSync(metallibPath);
    } else {
      note = `the Metal toolchain did not compile the shaders: ${(compiled.stderr || linked.stderr || "").trim() || "no output"}`;
    }
  }
  if (bytes === null) {
    // The Metal compiler is part of every Mac even where its command line tools are not. A small
    // helper compiles the source with it and takes the AIR metallib it writes.
    const helperBin = join(buildDir, "capture-shaders");
    const helper = spawnSync("clang", ["-fobjc-arc", "-O2", "-Wall", "-framework", "Metal", "-framework", "Foundation",
                                       helperPath, "-o", helperBin], { encoding: "utf8" });
    if (helper.status === 0 && !helper.error) {
      const captured = spawnSync(helperBin, [shaderPath, metallibPath], { encoding: "utf8" });
      if (captured.status === 0 && !captured.error && existsSync(metallibPath)) {
        bytes = readFileSync(metallibPath);
        note = "";
      } else if (note === "") {
        note = `the Metal compiler could not make the shaders' library: ${(captured.stderr || "").trim() || "no output"}`;
      }
    } else if (note === "") {
      note = `the shader capture helper did not build: ${(helper.stderr || "").trim() || "no output"}`;
    }
  }
  const header = shaderHeader(bytes, source);
  writeFileSync(headerPath, header);
  writeFileSync(keyPath, key);
  return {
    header,
    key: createHash("sha256").update(key).update(header).digest("hex"),
    precompiled: bytes !== null,
    note,
  };
}

/** The compiler and flags that build the host source. `includeDirs` are searched before the
 *  source's own directory, which is how the generated shader header reaches the macOS host. */
export function hostCompileCommand(hostSrc: string, outObj: string, platform: NodeJS.Platform = process.platform,
                                   target = buildTarget(), includeDirs: string[] = []): { cc: string; args: string[] } {
  if (buildingWindows(platform, target)) return windowsHostCommand(hostSrc, outObj, target);
  if (platform === "darwin") {
    return { cc: "clang", args: ["-c", "-O2", "-fobjc-arc", "-Wall", ...includeDirs.map((dir) => "-I" + dir), hostSrc, "-o", outObj] };
  }
  const flags: string[] = ["-c", "-O2", "-Wall"];
  // The video backend needs the FFmpeg headers from host/ffmpeg/prefix, which build.sh makes; a
  // tree without them still builds, with a video element that has no backend.
  const ffmpeg = join(dirname(hostSrc), "ffmpeg", "prefix");
  const ffmpegHeader = join(ffmpeg, "include", "libavformat", "avformat.h");
  if (existsSync(ffmpegHeader)) flags.push("-I" + join(ffmpeg, "include"));
  else flags.push("-DNATIVE_NO_FFMPEG");
  flags.push(...linuxHostCflags());
  flags.push(hostSrc, "-o", outObj);
  return { cc: "cc", args: flags };
}

/** The compiler and flags for one of the portable host sources: plain C, built with the same
 *  toolchain as the platform's own source so the objects link into one program. */
export function hostCommonCompileCommand(hostSrc: string, outObj: string, hostDir: string,
  platform: NodeJS.Platform = process.platform, target = buildTarget()): { cc: string; args: string[] } {
  if (buildingWindows(platform, target)) {
    if (!onPath("zig")) {
      throw new Error(`building for Windows needs zig on the PATH, because scriptc links Windows apps with it: install it from https://ziglang.org/download`);
    }
    const gnu = target === null || /-gnu$/.test(target);
    const triple = gnu ? "x86_64-windows-gnu" : "x86_64-windows-msvc";
    return { cc: "zig", args: ["cc", "-target", triple, "-c", "-O2", "-Wall", "-std=gnu11", "-I", hostDir, hostSrc, "-o", outObj] };
  }
  return {
    cc: MACOS ? "clang" : "cc",
    args: ["-c", "-O2", "-Wall", "-std=gnu11", "-I", hostDir, hostSrc, "-o", outObj],
  };
}

/** How the Windows host is compiled: the toolchain scriptc's own link is built with. */
function windowsHostCommand(hostSrc: string, outObj: string, target: string | null): { cc: string; args: string[] } {
  // scriptc links a Windows app with zig, for the GNU target, on every platform -- the link line
  // it runs is `zig cc -target x86_64-windows-gnu …` even when the build runs on Windows and the
  // target is its own. The host object has to come from the same toolchain: an MSVC-built object
  // asks the linker for libLIBCMT/libLIBCPMT, which a GNU link has no such archives for. So zig is
  // not a convenience here, it is what the link is made of, and cl alone cannot stand in for it.
  if (!onPath("zig")) {
    throw new Error(`building for Windows needs zig on the PATH, because scriptc links Windows apps with it: install it from https://ziglang.org/download`);
  }
  const gnu = target === null || /-gnu$/.test(target);
  const triple = gnu ? "x86_64-windows-gnu" : "x86_64-windows-msvc";
  return { cc: "zig", args: ["c++", "-target", triple, "-c", "-O2", "-Wall", "-fno-exceptions", "-fno-rtti", hostSrc, "-o", outObj] };
}

/** Points a manifest at the platform's libraries and frameworks. */
export function applyHostLink(manifest: { system_libraries?: string[]; frameworks?: string[] },
                              platform: NodeJS.Platform = process.platform, target = buildTarget()): void {
  if (buildingWindows(platform, target)) {
    // AppKit and the other frameworks belong to the macOS host.
    manifest.frameworks = [];
    manifest.system_libraries = [...WINDOWS_HOST_LIBRARIES];
    return;
  }
  if (platform === "darwin") return;
  manifest.frameworks = [];
  manifest.system_libraries = [...LINUX_HOST_LIBRARIES];
}
