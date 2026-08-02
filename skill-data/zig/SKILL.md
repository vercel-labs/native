---
name: zig
description: Zig 0.16 idioms for Native SDK code, indexed by compile error. Load when `zig build` fails on std APIs with errors like "struct 'fs' has no member named 'cwd'", "struct 'array_list.Aligned(u8,null)' has no member named 'init'", "struct 'std' has no member named 'io'", "no member named 'GeneralPurposeAllocator'", "no member named 'getEnvMap'", or "invalid format string" - the signature of code written for Zig 0.15 or earlier. Covers main(std.process.Init), std.Io file IO and writers, ArrayList, process spawning, environment, clocks and sleep, sockets, custom formatting, and build.zig module shapes, each as this SDK writes them.
---

# Zig 0.16 for Native SDK code

The Native SDK requires Zig 0.16.0 (`minimum_zig_version` in `build.zig.zon`; the CLI pins the same version and offers a checksum-verified download into `~/.native/toolchains/` when the `zig` on PATH does not match). Training data and older guides teach Zig 0.15 idioms, and 0.16 moved everything that touches the outside world — files, stdout, clocks, sleeping, process spawning, sockets — behind an explicit `std.Io` value, while containers became allocator-per-call. Each section below is headed by the exact compile error the old idiom produces, so search this file by error text.

Two rules resolve most failures:

- Operations on the outside world take a `std.Io` first (or right after the receiver). Get one from `init.io` in `main(init: std.process.Init)`, from `std.testing.io` in tests, or from `std.Io.Threaded` in code with no `Init` to thread through.
- Containers are unmanaged: initialize with `.empty` and pass the allocator to every mutating call.

In a UiApp, `update` never sees an `Io` — persistence, subprocesses, HTTP, clocks, and timers go through the typed effects channel (`fx.readFile`, `fx.spawn`, `fx.fetch`, `fx.wallMs`, `fx.startTimer`; see `native skills get native-ui`). Raw `std.Io` belongs in `main`, tests, and standalone tools. And because Zig analyzes lazily, a 0.15-ism can hide in code only one build path references: run BOTH `zig build` and `zig build test` before calling a change done.

## error: struct 'heap' has no member named 'GeneralPurposeAllocator' — allocators come from `main(init: std.process.Init)`

Zig 0.15 and earlier:

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
}
```

Zig 0.16: `main` takes `std.process.Init`, which carries the process-wide allocators, the `Io`, the environment, and the args — nothing to construct or deinit:

```zig
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;                       // general purpose, leak-checked in Debug
    const arena = init.arena.allocator();       // process-lifetime arena, freed on exit
    const io = init.io;                         // the Io every std call below wants
    const args = try init.minimal.args.toSlice(arena);
    if (init.environ_map.get("HOME")) |home| { ... }
}
```

The CLI's own entry point is the live reference: `tools/native-sdk/main.zig`. Generated apps already have this shape — `main(init: std.process.Init)` passes `init` through to `runner.runWithOptions(app, options, init)` and `init.io` to the markup hot-reload watcher (see any `examples/*/src/main.zig`). `std.heap.page_allocator` still exists for allocations that live for the whole process. Library code that cannot take an `Init` builds its own `Io`: `var threaded = std.Io.Threaded.init(allocator, .{});` then `threaded.io()` (`src/platform/macos/root.zig`).

## error: struct 'fs' has no member named 'cwd' — file IO moved to `std.Io.Dir`

`std.fs.cwd()`, `std.fs.File`, and `std.fs.selfExePath` are gone (`std.fs` retains only `path` helpers and deprecated aliases). The directory handle is `std.Io.Dir`, and every operation takes `io` right after the receiver:

```zig
const cwd = std.Io.Dir.cwd();
const content = try cwd.readFileAlloc(io, "app.zon", allocator, .limited(1024 * 1024));
defer allocator.free(content);
try cwd.writeFile(io, .{ .sub_path = "out.txt", .data = bytes });
var file = try cwd.openFile(io, path, .{});
defer file.close(io);
try cwd.deleteTree(io, "zig-out/tmp");
```

Note the `readFileAlloc` argument order (`io`, path, allocator, limit) and the size limit as `std.Io.Limit` — `.limited(n)` or `.unlimited`. Live references: `tools/native-sdk/skills.zig` (readFileAlloc), `src/tooling/manifest.zig` (openFile), `src/tooling/cef.zig` tests (writeFile with `std.testing.io`). Path buffers size with `std.Io.Dir.max_path_bytes`. For the executable's own path, `std.fs.selfExePath(&buf)` became `std.process.executablePath(io, &buf)`, returning the length (`tools/native-sdk/skills.zig`).

## error: struct 'std' has no member named 'io' — writers are `std.Io.Writer`, stdout is `std.Io.File.stdout()`

`std.io.getStdOut().writer()` and `std.io.fixedBufferStream` are gone. Stdout takes `io` plus a caller-owned buffer, and the printable interface lives one field deep:

```zig
var stdout_buffer: [4096]u8 = undefined;
var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
const stdout = &stdout_writer.interface;
defer stdout.flush() catch {};
try stdout.print("{s}\n", .{message});
```

Forgetting `flush()` means no output — the buffer is yours. `std.debug.print` is unchanged and needs no `io`; prefer it for diagnostics. The `fixedBufferStream` replacement is a fixed writer over a stack buffer, and the written bytes come back from `buffered()`:

```zig
var buf: [256]u8 = undefined;
var writer = std.Io.Writer.fixed(&buf);
try writer.print("n={d}", .{42});
const written = writer.buffered();
```

For building a string of unknown size, use an allocating writer instead of an ArrayList writer: `var w = std.Io.Writer.Allocating.init(allocator); defer w.deinit();` then print through `w.writer` (`src/automation/server.zig`). One-shot formatting still has `std.fmt.bufPrint` and `std.fmt.allocPrint`, unchanged. Functions that accept a writer take `*std.Io.Writer`, not `anytype` (`tools/native-sdk/skills.zig`; fixed-writer reference: `src/tooling/doctor.zig`).

## error: struct 'array_list.Aligned(u8,null)' has no member named 'init' — ArrayList is unmanaged

`std.ArrayList(T).init(allocator)` is gone; the list no longer stores its allocator. Initialize with `.empty` and pass the allocator to every call that can allocate or free:

```zig
var list: std.ArrayList(u8) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 'a');
try list.appendSlice(allocator, "bc");
const owned = try list.toOwnedSlice(allocator);
```

This is everywhere in the SDK — `src/tooling/templates.zig` builds every generated file this way, `tools/native-sdk/skills.zig` collects skills this way. Passing a managed-style call (`list.append('a')`) fails with "member function expected 2 argument(s), found 1". `std.StringHashMap`/`std.AutoHashMap` still have managed `.init(allocator)` forms; only explicitly `Unmanaged` maps take `.empty` (`tools/native-sdk/markup_lsp.zig`).

## error: invalid format string 's' for type — enums print with `{t}`, format methods with `{f}`

`{s}` is for strings only. Enums and tagged unions print their tag name with `{t}` (equivalent to `@tagName`, which also still works):

```zig
std.debug.print("native {t}: `zig build` step failed (exit code {d})\n", .{ verb, code });
```

(`src/tooling/verbs.zig`.) Custom format methods changed shape twice over: the old four-parameter signature no longer compiles (`error: struct 'fmt' has no member named 'FormatOptions'`), and `{}` no longer calls a `format` method at all — it prints the default field dump silently. Declare the 0.16 signature and print with `{f}`:

```zig
pub fn format(self: Point, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("({d},{d})", .{ self.x, self.y });
}
// call site
try writer.print("{f}\n", .{point});
```

## error: struct 'time' has no member named 'sleep' / 'milliTimestamp' — clocks live on Io

`std.time` keeps only the unit constants (`ns_per_ms`, `ms_per_s`, ...) and epoch helpers. Sleeping and reading clocks take `io` and typed durations:

```zig
try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);
const now_ns: i128 = std.Io.Timestamp.now(io, .real).nanoseconds;
```

(`src/runtime/automation_liveness_tests.zig`, `src/automation/server.zig`.) In app code, do not reach for either: `native_sdk.nowMs()` / `native_sdk.monotonicMs()` are the facade, `fx.wallMs()` is the journaled read inside `update`, and `model.clock` is the testable seam — the native-ui skill's Time section owns that pattern.

## error: struct 'process.Child' has no member named 'init' — spawning is `std.process.spawn(io, ...)`

The two-step `Child.init` + `child.spawn()` collapsed into one call, and lifecycle methods take `io`:

```zig
var child = try std.process.spawn(io, .{
    .argv = &.{ "npm", "run", "build" },
    .stdin = .ignore,
    .stdout = .inherit,
    .stderr = .inherit,
});
const term = try child.wait(io);   // child.kill(io) to stop it
```

(`src/tooling/verbs.zig`, `src/tooling/dev.zig` — the latter also shows passing a custom environment via `.environ_map`.) Inside a UiApp, spawn through the effects channel (`fx.spawn`) instead — it is bounded, journaled, and delivers exit/output as Msgs.

## error: struct 'process' has no member named 'getEnvMap' / 'argsAlloc' — environment and args come from Init

`std.process.getEnvMap`, `argsAlloc`, and `argsWithAllocator` are gone. `main` already has both: `init.environ_map` (a `*std.process.Environ.Map`) and `init.minimal.args.toSlice(allocator)` (`tools/native-sdk/main.zig`). Building an environment from scratch — for a child process, or in tests — is `var env = std.process.Environ.Map.init(allocator); defer env.deinit(); try env.put("KEY", "value");` (`src/tooling/dev.zig`).

## error: struct 'mem' has no member named 'trimRight' / 'trimLeft' — renamed `trimEnd` / `trimStart`

The directional trims renamed to match the JS/string convention; arguments are unchanged:

```zig
const line = std.mem.trimEnd(u8, raw, "\r\n");     // was trimRight
const body = std.mem.trimStart(u8, line, " \t");   // was trimLeft
const both = std.mem.trim(u8, text, " ");          // unchanged
```

## error: struct 'std' has no member named 'net' — sockets live on `std.Io.net`

`std.net.Address` became `std.Io.net.IpAddress`, and connect/listen take `io`: `std.Io.net.IpAddress.resolve(io, host, port)`, then `IpAddress.connect(&address, io, .{ .mode = .stream, .protocol = .tcp })`; stream readers/writers follow the buffered-writer shape (`std.Io.net.Stream.writer(stream, io, &buffer)` then `.interface`). Live reference: `src/tooling/dev.zig` (`waitUntilReady`/`httpReady`). App-level HTTP belongs in `fx.fetch`, not hand-rolled sockets.

## error: no field named 'root_source_file' in struct 'Build.ExecutableOptions' — build.zig artifacts take modules

Zero-config apps have no `build.zig` — the CLI owns the build graph, so this only appears in apps that ejected or scaffolded `--full`. Artifacts take a module, and the module owns root source, target, and optimize:

```zig
const exe = b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
const tests = b.addTest(.{ .root_module = app_mod });
```

The generated ejected `build.zig` is the reference shape (`native eject`, emitted by `src/tooling/templates.zig`); the SDK's own `build.zig` uses the same pattern throughout.

## Reading files and streams incrementally

`file.reader()` with no arguments is gone. A reader takes `io` and a buffer, and the stream interface lives on `.interface`:

```zig
var read_buffer: [4096]u8 = undefined;
var reader = file.reader(io, &read_buffer);
const bytes = try reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
const line = try reader.interface.takeDelimiterExclusive('\n');
```

(`src/tooling/manifest.zig` for allocRemaining, `src/tooling/toolchain.zig` for line reading from stdin.) For whole-file reads, prefer `readFileAlloc` above.

## Tests: the Io is `std.testing.io`

Tests never construct an `Io` — `std.testing.io` is the canonical one, next to `std.testing.allocator`:

```zig
test "reads the manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app.zon", .data = source });
    const content = try tmp.dir.readFileAlloc(std.testing.io, "app.zon", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(content);
}
```

(`src/tooling/cef.zig` and `src/tooling/manifest.zig` tests.) Model/Msg/update tests need no `Io` at all — the markup-view testing pattern in the native-ui skill is pure.

## Unchanged — do not "migrate" these

`std.fmt.bufPrint` / `allocPrint` / `parseInt` / `parseFloat`, `std.mem.*`, `std.debug.print`, `std.heap.page_allocator`, `std.time.ns_per_*` and `ms_per_*` constants, `@embedFile`, `std.testing.expect*`, and managed `std.StringHashMap` / `std.AutoHashMap` all work as before. If code using only these fails, the problem is elsewhere.
