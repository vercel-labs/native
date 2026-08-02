//! TypeScript-core plumbing for the `native` CLI: tree detection (which
//! core does this app carry?), the transpiler-checker pass `native check`
//! runs over src/core.ts, and the node dev-harness `native dev --core`
//! launches. The build graph re-derives the same detection in
//! build/app.zig; the CLI checks first so a both-cores tree fails with one
//! clean teaching message instead of a build panic.
//!
//! Multi-file cores: src/core.ts stays the detection root AND the entry
//! module, but a core may split into modules under src/ (relative imports
//! with real .ts filenames) plus SDK library modules
//! ("@native-sdk/core/text"). The transpiler walks that import graph
//! itself, so `native check` reports diagnostics with each module's own
//! path, and `native dev --core` runs the same graph under node (relative
//! imports are real files; the resolver hook maps only the SDK names).

const std = @import("std");
const buildgraph = @import("buildgraph.zig");
const process_tree = @import("process_tree.zig");

pub const Error = error{
    BothCores,
    MissingTsCore,
    MissingNode,
    MissingTranspiler,
    BrokenToolchainInstall,
    ToolchainVersionMismatch,
    CoreCheckFailed,
    DevHostFailed,
};

/// Which core the app tree carries: `src/core.ts` is a TypeScript core,
/// `src/main.zig` a Zig one. Both at once is a teaching error (the tree is
/// the truth; there is no language flag or config to consult). Other Zig
/// files under src/ never affect detection — and neither does anything
/// else in the tree: a package.json (the TS scaffold's editor surface, or
/// a stray one in a Zig app) is not a language marker.
pub const CoreTree = enum { zig, ts, both, neither };

pub fn detect(io: std.Io) CoreTree {
    return detectAt(io, ".");
}

/// `detect` against an explicit app root instead of the process cwd.
pub fn detectAt(io: std.Io, app_root: []const u8) CoreTree {
    var ts_buffer: [1024]u8 = undefined;
    var zig_buffer: [1024]u8 = undefined;
    const ts_path = std.fmt.bufPrint(&ts_buffer, "{s}/src/core.ts", .{app_root}) catch return .neither;
    const zig_path = std.fmt.bufPrint(&zig_buffer, "{s}/src/main.zig", .{app_root}) catch return .neither;
    const has_ts = buildgraph.fileExists(io, ts_path);
    const has_zig = buildgraph.fileExists(io, zig_path);
    if (has_ts and has_zig) return .both;
    if (has_ts) return .ts;
    if (has_zig) return .zig;
    return .neither;
}

/// The one both-cores teaching message, shared by every verb that detects.
pub fn failBothCores() Error {
    std.debug.print(
        \\this app declares two cores: src/core.ts (TypeScript) and src/main.zig (Zig).
        \\An app has exactly one core - the tree is the truth. Keep src/core.ts and delete
        \\src/main.zig, or keep src/main.zig and delete src/core.ts. (Other Zig files
        \\under src/ are fine either way.)
        \\
    , .{});
    return error.BothCores;
}

fn nodeMissing() Error {
    std.debug.print(
        \\TypeScript app cores need node on PATH (the @native-sdk/core transpiler and the
        \\core dev-harness run under it; the binary you ship carries no JS runtime).
        \\Install Node.js 22.15+ (on the 23 line: 23.5+) - https://nodejs.org or
        \\`brew install node` - and re-run.
        \\
    , .{});
    return error.MissingNode;
}

fn transpilerPath(allocator: std.mem.Allocator, io: std.Io, framework_root: []const u8, comptime sub: []const u8) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ framework_root, "packages", "core", sub });
    errdefer allocator.free(path);
    if (!buildgraph.fileExists(io, path)) {
        std.debug.print("the Native SDK at {s} is missing packages/core/{s} - is the checkout (or npm install) complete?\n", .{ framework_root, sub });
        return error.MissingTranspiler;
    }
    return path;
}

/// The layout-neutral runner for the transpiler tier's .ts modules
/// (build/ts_run.mjs): a pass-through on a repo checkout, and the type
/// stripper for the npm-installed layout, where the same modules sit
/// inside node_modules and node refuses its builtin stripping. Every
/// node invocation of a packages/core .ts module goes through it.
fn tsRunnerPath(allocator: std.mem.Allocator, io: std.Io, framework_root: []const u8) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ framework_root, "build", "ts_run.mjs" });
    errdefer allocator.free(path);
    if (!buildgraph.fileExists(io, path)) {
        std.debug.print("the Native SDK at {s} is missing build/ts_run.mjs - is the checkout (or npm install) complete?\n", .{framework_root});
        return error.MissingTranspiler;
    }
    return path;
}

/// The install command the repo-checkout teaching names. `--include=dev`
/// is correctness, not style: @typescript/typescript6 is packages/core's
/// devDependency, and a plain `npm ci` under ambient production npm config
/// (NODE_ENV=production, `omit=dev` in an npmrc) skips devDependencies
/// while exiting 0 — the named command would "succeed" and install
/// nothing.
pub const npm_ci_teaching_command = "npm ci --include=dev";

/// Whether the transpiler's TypeScript compiler (@typescript/old, the
/// exactly pinned npm alias of the real `typescript` package) RESOLVES
/// from the transpiler's own home — node's ancestor node_modules walk
/// from `<framework_root>/packages/core` upward — at the SDK's exactly
/// pinned VERSION.
///
/// Validation tracks ONLY what runtime loads, from the same origin
/// runtime resolves from. Both runtime importers resolve the ALIAS from
/// inside packages/core: typed_ast.ts imports "@typescript/old" directly
/// (the one file that imports the checker provider), and
/// build/ts_run.mjs's load hook does `createRequire(targetPath)` against
/// a packages/core/src module. Node walking from
/// packages/core/src/<module>.ts would consult src's own node_modules
/// first, but src/ is our source directory and never carries one, so
/// packages/core is the walk origin that mirrors both — every layout
/// that works for node passes here and none that fails does:
///   - repo checkout: packages/core/node_modules (nearest, after `npm ci`)
///   - npm-installed CLI: the alias npm installed alongside the package
///     (nested under the CLI on global prefixes, hoisted to the project
///     root on local ones, pnpm's sibling node_modules)
///
/// The @typescript/typescript6 wrapper is deliberately NOT probed:
/// nothing imports it at run time (typed_ast.ts bypasses its one-line
/// re-export on purpose — see the comment there), so holding the
/// wrapper's resolution — or the alias's version as seen FROM the
/// wrapper's origin — against the pin can only FALSE-REJECT healthy
/// trees. npm's own conflict shape hoists a consumer's conflicting
/// `@typescript/old` at the project root (where it wins the walk from a
/// hoisted wrapper) while our exact pin lands nested under the CLI — and
/// that nested copy is precisely what runtime loads from packages/core;
/// a consumer's own shadowing wrapper install must not sway the verdict
/// either. The wrapper stays a DECLARED dependency in both manifests
/// (continuity semantics, and it keeps npm shipping the package) — it is
/// just not what validation vouches for.
///
/// Resolvable means the alias's manifest AND its entrypoint are present
/// and its installed version equals the pin — see
/// `aliasedCompilerVersion` for the probe details (node's error shape,
/// the mid-extraction slivers). The pin is read from the framework's own
/// packages/core/package.json (the `npm:typescript@X.Y.Z` alias suffix
/// in devDependencies — `parseAliasedCompilerPin`), never hardcoded, so
/// a version bump stays a one-file change; check-version-sync keeps that
/// manifest and the CLI's dependencies in lockstep. Kept in lockstep with
/// its deliberate twin for direct `zig build` runs,
/// build/app.zig's tsToolchainResolution.
pub const ToolchainResolution = union(enum) {
    resolved,
    unresolved,
    /// The aliased compiler resolves, but at a version other than the
    /// SDK's exact pin (a conflicting consumer-tree `@typescript/old`
    /// shadowing ours). Both strings are allocator-owned.
    version_mismatch: Mismatch,

    pub const Mismatch = struct {
        resolved: []const u8,
        pinned: []const u8,

        pub fn deinit(self: Mismatch, allocator: std.mem.Allocator) void {
            allocator.free(self.resolved);
            allocator.free(self.pinned);
        }
    };
};

fn transpilerResolution(allocator: std.mem.Allocator, io: std.Io, framework_root: []const u8) ToolchainResolution {
    // The pin first: a framework tree whose packages/core/package.json is
    // missing or pinless is not a tree this gate can vouch for (the file
    // ships in every layout), so it concludes unresolved and the layout
    // teachings act.
    const pinned = pinnedCompilerVersion(allocator, io, framework_root) orelse return .unresolved;
    const core_dir = std.fs.path.join(allocator, &.{ framework_root, "packages", "core" }) catch {
        allocator.free(pinned);
        return .unresolved;
    };
    defer allocator.free(core_dir);
    const resolved = aliasedCompilerVersion(allocator, io, core_dir) orelse {
        allocator.free(pinned);
        return .unresolved;
    };
    if (std.mem.eql(u8, resolved, pinned)) {
        allocator.free(resolved);
        allocator.free(pinned);
        return .resolved;
    }
    return .{ .version_mismatch = .{ .resolved = resolved, .pinned = pinned } };
}

/// `transpilerResolution` folded to the yes/no most callers (and the
/// layout tests) want: a version mismatch is NOT a resolvable toolchain.
fn transpilerResolves(allocator: std.mem.Allocator, io: std.Io, framework_root: []const u8) bool {
    switch (transpilerResolution(allocator, io, framework_root)) {
        .resolved => return true,
        .unresolved => return false,
        .version_mismatch => |mismatch| {
            mismatch.deinit(allocator);
            return false;
        },
    }
}

/// How runtime's `import "@typescript/old"` resolves, by node's walk FROM
/// `origin_dir` upward: the nearest ancestor
/// `node_modules/@typescript/old` wins (skipping ancestors that are
/// themselves a node_modules directory, as node does). Callers pass
/// packages/core — the origin typed_ast.ts and ts_run.mjs resolve the
/// alias from (see `transpilerResolution`). The walk must be a real
/// ancestor walk, not a fixed-sibling probe: npm hoists the alias to the
/// install root on flat layouts (project-local installs) and nests it
/// under the CLI on version conflicts, and both are ancestor hits of
/// packages/core. Resolvable means the alias's manifest AND its
/// entrypoint — the alias is the real `typescript` package, whose
/// `"main"` is ./lib/typescript.js (no `"exports"`): node reads
/// `<candidate>/package.json` for the entrypoint and then loads that
/// file, so a bare directory — an interrupted `npm ci`, a pruned or
/// half-cleaned node_modules — is MODULE_NOT_FOUND at run time, and a
/// manifest WITHOUT its entrypoint is a real npm failure shape too
/// (extraction is not atomic; package.json rides first in the tarball,
/// so a mid-extraction crash lands exactly that sliver). Hardcoding
/// lib/typescript.js is safe: the alias is exactly pinned
/// (`npm:typescript@X.Y.Z` in both manifests plus the lockfile) and
/// drift-checked by check-version-sync, so the entrypoint cannot move
/// under us. The walk mirrors node's error shape: a candidate WITHOUT
/// package.json lets node keep walking upward, but a manifest whose
/// "main" fails to load THROWS rather than consulting a deeper ancestor,
/// so that candidate concludes unresolvable here too.
///
/// Returns the resolved alias's installed VERSION (allocator-owned) so the
/// caller can hold it against the SDK's pin — resolving is not the whole
/// bar (see `transpilerResolution`). A resolvable-looking alias
/// whose manifest carries no version field returns null: every real npm
/// install writes one, so its absence is a hand-rolled or corrupt sliver,
/// not a compiler to vouch for.
fn aliasedCompilerVersion(allocator: std.mem.Allocator, io: std.Io, origin_dir: []const u8) ?[]const u8 {
    var dir: []const u8 = origin_dir;
    while (true) {
        if (!std.mem.eql(u8, std.fs.path.basename(dir), "node_modules")) {
            const manifest_path = std.fs.path.join(allocator, &.{ dir, "node_modules", "@typescript", "old", "package.json" }) catch return null;
            defer allocator.free(manifest_path);
            if (std.Io.Dir.cwd().statFile(io, manifest_path, .{})) |_| {
                const entrypoint = std.fs.path.join(allocator, &.{ dir, "node_modules", "@typescript", "old", "lib", "typescript.js" }) catch return null;
                defer allocator.free(entrypoint);
                _ = std.Io.Dir.cwd().statFile(io, entrypoint, .{}) catch return null;
                const manifest = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(64 * 1024)) catch return null;
                defer allocator.free(manifest);
                const version = parsePackageVersion(manifest) orelse return null;
                return allocator.dupe(u8, version) catch null;
            } else |_| {}
        }
        dir = std.fs.path.dirname(dir) orelse return null;
    }
}

/// Extract the exactly pinned compiler version from a packages/core
/// manifest: the `"@typescript/old": "npm:typescript@X.Y.Z"` devDependency
/// entry's version suffix. A targeted scan like `parsePackageVersion`, and
/// deliberately strict about the alias shape: anything but the exact
/// `npm:typescript@X.Y.Z` form is a manifest check-version-sync would
/// reject, so this parser vouches for nothing else.
pub fn parseAliasedCompilerPin(manifest_json: []const u8) ?[]const u8 {
    const key = "\"@typescript/old\"";
    const value_prefix = "npm:typescript@";
    const key_at = std.mem.indexOf(u8, manifest_json, key) orelse return null;
    var rest = manifest_json[key_at + key.len ..];
    rest = std.mem.trimStart(u8, rest, " \t\r\n");
    if (rest.len == 0 or rest[0] != ':') return null;
    rest = std.mem.trimStart(u8, rest[1..], " \t\r\n");
    if (rest.len == 0 or rest[0] != '"') return null;
    rest = rest[1..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const value = rest[0..end];
    if (!std.mem.startsWith(u8, value, value_prefix)) return null;
    const pin = value[value_prefix.len..];
    // Exact X.Y.Z only, mirroring check-version-sync's pin-shape check: a
    // range after the @ is not a pin, and comparing an installed version
    // against one would "mismatch" every tree.
    if (pin.len == 0) return null;
    for (pin) |c| {
        if (!std.ascii.isDigit(c) and c != '.') return null;
    }
    if (std.mem.count(u8, pin, ".") != 2) return null;
    return pin;
}

/// The version the framework pins its aliased compiler to, read from its
/// own packages/core/package.json (allocator-owned), or null when the
/// manifest is missing or carries no exact alias pin.
fn pinnedCompilerVersion(allocator: std.mem.Allocator, io: std.Io, framework_root: []const u8) ?[]const u8 {
    const path = std.fs.path.join(allocator, &.{ framework_root, "packages", "core", "package.json" }) catch return null;
    defer allocator.free(path);
    const manifest = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch return null;
    defer allocator.free(manifest);
    const pin = parseAliasedCompilerPin(manifest) orelse return null;
    return allocator.dupe(u8, pin) catch null;
}

/// The teaching for a REPO CHECKOUT whose toolchain resolves nowhere (a
/// clone whose `npm ci` hasn't happened yet, or whose node_modules was
/// deleted): name the one command, fail the verb cleanly. The gate never
/// runs npm itself — the tree stays exactly as the user left it.
/// Non-checkout layouts route to `toolchainInstallBroken` instead: naming
/// `npm ci` there would teach mutating an npm-owned tree.
fn transpilerDepsMissing(framework_root: []const u8) Error {
    std.debug.print(
        \\the @native-sdk/core transpiler's dependencies are not installed
        \\(its TypeScript compiler, @typescript/old, resolves nowhere). Fix with:
        \\  cd {s}/packages/core && {s}
        \\
    , .{ framework_root, npm_ci_teaching_command });
    return error.MissingTranspiler;
}

/// The teaching for an npm-installed CLI whose toolchain resolves nowhere:
/// @typescript/old is a regular dependency of @native-sdk/cli, so npm
/// installs it in the same transaction as the package — its absence
/// means the install itself is broken (interrupted install, a pruned
/// node_modules, an overzealous cleaner). The fix is reinstalling the CLI,
/// never `npm ci` inside the installed package: that would silently mutate
/// npm-owned files and mask the breakage instead of curing it.
fn toolchainInstallBroken(framework_root: []const u8) Error {
    std.debug.print(
        \\the @native-sdk/cli install at
        \\  {s}
        \\is missing its TypeScript toolchain (@typescript/old). npm installs
        \\that dependency in the same transaction as the CLI, so this install is
        \\broken - reinstall @native-sdk/cli (e.g. re-run `npm install`, or
        \\`npm install -g @native-sdk/cli` for a global install).
        \\
    , .{framework_root});
    return error.BrokenToolchainInstall;
}

/// The teaching for a toolchain whose aliased compiler RESOLVES at the
/// wrong version: the walk from packages/core — runtime's own origin —
/// found an `@typescript/old` that is not the SDK's exact pin, so the
/// compiler the transpiler would actually load is one the SDK never
/// vouched for (a consumer's conflicting `@typescript/old` winning
/// nearest-wins over ours). Neither layout teaching fits (an install
/// command changes nothing), so this one names both versions and the
/// conflict instead.
fn compilerVersionMismatch(resolved: []const u8, pinned: []const u8) Error {
    std.debug.print(
        \\the transpiler's TypeScript compiler resolves at the wrong version:
        \\@typescript/old resolves to typescript {s}, but the SDK pins npm:typescript@{s}.
        \\Another package in this tree pins a conflicting @typescript/old - align it with
        \\the SDK's pin (or remove it) and reinstall, so the SDK's exact pin is the copy
        \\that resolves.
        \\
    , .{ resolved, pinned });
    return error.ToolchainVersionMismatch;
}

fn dirExists(io: std.Io, path: []const u8) bool {
    var cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// The one gate every verb that reaches the transpiler runs (`native
/// check`, `native dev --core`, and the build-graph verbs before they
/// spawn `zig build`): the compiler must RESOLVE from packages/core — at
/// the exactly pinned version (see `transpilerResolution`). The
/// npm-installed CLI always resolves — @typescript/old is a regular
/// dependency installed in the same transaction — and a repo
/// checkout resolves after its one `npm ci --include=dev`. The gate NEVER
/// runs npm itself, on any layout: it only splits the teaching when
/// resolution fails. Which teaching is decided by `packages/core/test/`:
/// the published payload deliberately omits it (copy-framework.js stages
/// packages/core entry-by-entry without test/, and check-framework-sync.js
/// pins that exclusion; @native-sdk/core's own tarball is pinned to
/// `files: ["sdk"]` by test/package_manifest.test.ts) while every repo
/// checkout carries it. Checkouts are taught the install command;
/// non-checkout layouts are taught the reinstall — running `npm ci` there
/// would mutate an npm-owned tree.
pub fn ensureResolvedTranspiler(allocator: std.mem.Allocator, io: std.Io, framework_root: []const u8) !void {
    switch (transpilerResolution(allocator, io, framework_root)) {
        .resolved => return,
        // The wrong-VERSION shape gets its own teaching on every layout:
        // the layout split below prescribes installs, and no install fixes
        // a conflicting consumer pin shadowing ours.
        .version_mismatch => |mismatch| {
            defer mismatch.deinit(allocator);
            return compilerVersionMismatch(mismatch.resolved, mismatch.pinned);
        },
        .unresolved => {},
    }
    const test_dir = try std.fs.path.join(allocator, &.{ framework_root, "packages", "core", "test" });
    defer allocator.free(test_dir);
    if (!dirExists(io, test_dir)) return toolchainInstallBroken(framework_root);
    // Teach the command against the RESOLVED absolute path: the checkout
    // root may have been reached through a relative NATIVE_SDK_PATH or a
    // symlinked binary, and the one command must paste-and-run from any
    // cwd.
    const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, framework_root, allocator) catch
        return transpilerDepsMissing(framework_root);
    defer allocator.free(resolved);
    return transpilerDepsMissing(resolved);
}

/// `native check` over a TypeScript core: run the transpiler (checker +
/// emitter) on src/core.ts — and, through it, the core's whole import
/// graph under src/ — and surface its NS diagnostics verbatim — they
/// are the teaching layer, nothing wraps them (each diagnostic carries
/// the owning module's path). The emitted Zig lands in .native/check/ (a
/// scratch product, gitignored with the rest of .native/). Exit 0 =
/// typechecked, subset-clean, emitted.
pub fn checkCore(allocator: std.mem.Allocator, io: std.Io, base_env: *std.process.Environ.Map, framework_root: []const u8) !void {
    const cli_path = try transpilerPath(allocator, io, framework_root, "src/cli.ts");
    defer allocator.free(cli_path);
    const runner_path = try tsRunnerPath(allocator, io, framework_root);
    defer allocator.free(runner_path);
    try ensureResolvedTranspiler(allocator, io, framework_root);
    try std.Io.Dir.cwd().createDirPath(io, ".native/check");

    var child = std.process.spawn(io, .{
        .argv = &.{ "node", runner_path, cli_path, "src/core.ts", "-o", ".native/check/core.zig" },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = base_env,
    }) catch return nodeMissing();
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    // The transpiler's own diagnostics are already on screen; name the
    // failing pass without burying them.
    std.debug.print("native check: src/core.ts failed the @native-sdk/core checker (diagnostics above)\n", .{});
    return error.CoreCheckFailed;
}

pub const DevHostOptions = struct {
    base_env: *std.process.Environ.Map,
    /// NDJSON message script; null = interactive stdin.
    script: ?[]const u8 = null,
    /// Re-run the harness whenever any module of the core changes.
    /// Requires a script (a re-run replays it against the edited core).
    watch: bool = false,
};

/// `native dev --core`: the node dev-harness over src/core.ts — the
/// core-logic loop (dispatch messages, watch the model and effect
/// transcript), not a renderer. Watch mode rides `node --watch`.
pub fn runDevHost(allocator: std.mem.Allocator, io: std.Io, framework_root: []const u8, options: DevHostOptions) !void {
    if (!buildgraph.fileExists(io, "src/core.ts")) {
        std.debug.print("no src/core.ts here - `native dev --core` runs the TypeScript core-logic loop\n", .{});
        return error.MissingTsCore;
    }
    const devhost_path = try transpilerPath(allocator, io, framework_root, "src/devhost.ts");
    defer allocator.free(devhost_path);
    const runner_path = try tsRunnerPath(allocator, io, framework_root);
    defer allocator.free(runner_path);
    // The harness runs the transpiler tier under node, so it needs the
    // TypeScript toolchain to resolve exactly like check/build do.
    try ensureResolvedTranspiler(allocator, io, framework_root);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "node");
    if (options.watch) {
        if (options.script == null) {
            std.debug.print("`native dev --core --watch` needs --script <msgs.ndjson>: each re-run replays the script against the edited core\n", .{});
            return error.DevHostFailed;
        }
        try argv.append(allocator, "--watch");
    }
    try argv.append(allocator, runner_path);
    try argv.append(allocator, devhost_path);
    try argv.append(allocator, "src/core.ts");
    if (options.script) |script| {
        try argv.appendSlice(allocator, &.{ "--script", script });
    }

    std.debug.print("native dev --core: the core-logic loop under node (update/effects, virtual clock) - not a renderer; `native dev` runs the app\n", .{});
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = options.base_env,
        .pgid = if (process_tree.supported) process_tree.spawnPgid() else null,
    }) catch return nodeMissing();
    const group_pid: i32 = if (process_tree.supported) process_tree.groupId(&child) else 0;
    if (group_pid > 0) process_tree.own(group_pid);
    defer if (group_pid > 0) process_tree.releaseAndKill(group_pid);
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    std.debug.print("native dev --core: the harness exited abnormally\n", .{});
    return error.DevHostFailed;
}

// ------------------------------------------------------- editor package
//
// Stock editor TypeScript (VS Code et al.) resolves `@native-sdk/core`
// the only way editors know: node_modules. Until the package is published
// to npm, the CLI materializes `node_modules/@native-sdk/core` inside the
// app itself — a plain COPY (never a symlink; cache paths get GC'd) of
// exactly the files the published artifact will contain (package.json plus
// the `files: ["sdk"]` allowlist: sdk/core.ts, sdk/text.ts, sdk/events.ts,
// and the ambient bytes-text method surface core.ts references).
// The copy is
// EDITOR-AND-VERSIONING SURFACE ONLY: builds transpile against the SDK
// checkout's own sources and never read node_modules — delete it and
// `native build|dev|check|test` still work; the next check/dev/build puts
// it back. Once the real package is published, a user-run `npm install`
// overwrites the copy with identical content; the refresh below compares
// the one `version` field, sees it current, and never touches it again.

/// Where the editor copy lives inside an app.
pub const editor_package_dir = "node_modules/@native-sdk/core";

/// The published artifact's files, relative to packages/core (and to the
/// materialized copy): package.json plus its `files: ["sdk"]` allowlist.
/// packages/core/test/package_manifest.test.ts pins the manifest to this
/// shape, so copy and tarball cannot drift apart.
const editor_package_files = [_][]const u8{ "package.json", "sdk/core.ts", "sdk/text.ts", "sdk/events.ts", "sdk/bytes_text_methods.d.ts" };

/// Extract the top-level "version" of a package.json. A targeted scan, not
/// a JSON parse: both inputs are our own manifest and npm's byte-identical
/// install of it, where the first "version" key is the package version.
pub fn parsePackageVersion(manifest_json: []const u8) ?[]const u8 {
    const key = "\"version\"";
    const key_at = std.mem.indexOf(u8, manifest_json, key) orelse return null;
    var rest = manifest_json[key_at + key.len ..];
    rest = std.mem.trimStart(u8, rest, " \t\r\n");
    if (rest.len == 0 or rest[0] != ':') return null;
    rest = std.mem.trimStart(u8, rest[1..], " \t\r\n");
    if (rest.len == 0 or rest[0] != '"') return null;
    rest = rest[1..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    if (end == 0) return null;
    return rest[0..end];
}

/// The version of the SDK's bundled @native-sdk/core package
/// (packages/core/package.json). Caller frees.
pub fn bundledSdkVersion(allocator: std.mem.Allocator, io: std.Io, framework_root: []const u8) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ framework_root, "packages", "core", "package.json" });
    defer allocator.free(path);
    const manifest = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch
        return error.MissingTranspiler;
    defer allocator.free(manifest);
    const version = parsePackageVersion(manifest) orelse return error.MissingTranspiler;
    return allocator.dupe(u8, version);
}

/// How an app's editor copy compares to the SDK's bundled package.
pub const EditorPackageStatus = struct {
    /// The SDK-bundled @native-sdk/core version (owned).
    bundled: []const u8,
    /// The app copy's version, or null when the copy is missing or
    /// incomplete (owned when present).
    installed: ?[]const u8,

    pub fn fresh(self: EditorPackageStatus) bool {
        const installed = self.installed orelse return false;
        return std.mem.eql(u8, installed, self.bundled);
    }

    pub fn deinit(self: EditorPackageStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.bundled);
        if (self.installed) |installed| allocator.free(installed);
    }
};

/// Compare `<app_root>/node_modules/@native-sdk/core` against the SDK's
/// bundled package. Cheap by design (the refresh trigger runs on every
/// check/dev/build): two one-field manifest reads plus two stats.
pub fn editorPackageStatus(allocator: std.mem.Allocator, io: std.Io, framework_root: []const u8, app_root: []const u8) !EditorPackageStatus {
    const bundled = try bundledSdkVersion(allocator, io, framework_root);
    errdefer allocator.free(bundled);

    const installed: ?[]const u8 = read: {
        const manifest_path = try std.fs.path.join(allocator, &.{ app_root, editor_package_dir, "package.json" });
        defer allocator.free(manifest_path);
        const manifest = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(64 * 1024)) catch break :read null;
        defer allocator.free(manifest);
        const version = parsePackageVersion(manifest) orelse break :read null;
        // A manifest without its sdk/ sources is an incomplete copy (a
        // half-deleted tree), not a fresh install at that version.
        for (editor_package_files[1..]) |sub_path| {
            const file_path = try std.fs.path.join(allocator, &.{ app_root, editor_package_dir, sub_path });
            defer allocator.free(file_path);
            if (!buildgraph.fileExists(io, file_path)) break :read null;
        }
        break :read try allocator.dupe(u8, version);
    };
    return .{ .bundled = bundled, .installed = installed };
}

pub const EnsureOutcome = enum { fresh, materialized };

/// Make `<app_root>/node_modules/@native-sdk/core` a current copy of the
/// SDK's bundled package: leave a version-matching copy alone (that is the
/// post-publish `npm install` handoff — npm's content is identical, so the
/// CLI recognizes the version and stops rewriting), (re)materialize
/// otherwise.
pub fn ensureEditorPackage(allocator: std.mem.Allocator, io: std.Io, framework_root: []const u8, app_root: []const u8) !EnsureOutcome {
    const status = try editorPackageStatus(allocator, io, framework_root, app_root);
    defer status.deinit(allocator);
    if (status.fresh()) return .fresh;

    for (editor_package_files) |sub_path| {
        const source_path = try std.fs.path.join(allocator, &.{ framework_root, "packages", "core", sub_path });
        defer allocator.free(source_path);
        const data = std.Io.Dir.cwd().readFileAlloc(io, source_path, allocator, .limited(4 * 1024 * 1024)) catch
            return error.MissingTranspiler;
        defer allocator.free(data);
        const dest_path = try std.fs.path.join(allocator, &.{ app_root, editor_package_dir, sub_path });
        defer allocator.free(dest_path);
        if (std.fs.path.dirname(dest_path)) |parent| {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest_path, .data = data });
    }
    return .materialized;
}

/// The self-heal hook `native check|dev|build|test` run over a TS app (cwd
/// = the app root): refresh the editor copy when missing or stale, say so
/// in one line, and never fail the verb — the copy is editor surface, and
/// build truth must not depend on it in either direction.
pub fn selfHealEditorPackage(allocator: std.mem.Allocator, io: std.Io, framework_root: []const u8) void {
    const outcome = ensureEditorPackage(allocator, io, framework_root, ".") catch return;
    if (outcome == .materialized) {
        std.debug.print("refreshed node_modules/@native-sdk/core (editor types for stock tsc; builds never read it)\n", .{});
    }
}

test "core tree detection reads the tree, not config" {
    const io = std.testing.io;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-ts-core-detect";
    cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/src");

    // Empty tree: neither.
    {
        var dir = try cwd.openDir(io, root, .{});
        defer dir.close(io);
        // detect() reads the process cwd; probe the predicate parts instead.
    }
    try std.testing.expect(!buildgraph.fileExists(io, root ++ "/src/core.ts"));
    try cwd.writeFile(io, .{ .sub_path = root ++ "/src/core.ts", .data = "// ts" });
    try std.testing.expect(buildgraph.fileExists(io, root ++ "/src/core.ts"));
    try cwd.writeFile(io, .{ .sub_path = root ++ "/src/main.zig", .data = "// zig" });
    try std.testing.expect(buildgraph.fileExists(io, root ++ "/src/main.zig"));
    cwd.deleteTree(io, root) catch {};
}

test "a stray package.json is not a language marker: detection keys on the core files only" {
    const io = std.testing.io;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-ts-core-detect-residue";
    cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/src");
    defer cwd.deleteTree(io, root) catch {};

    // A Zig app that grew a package.json (frontend tooling, a stray npm
    // init) is still a Zig app.
    try cwd.writeFile(io, .{ .sub_path = root ++ "/src/main.zig", .data = "// zig" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/package.json", .data = "{ \"name\": \"stray\" }" });
    try std.testing.expectEqual(CoreTree.zig, detectAt(io, root));

    // And a TS app whose editor surface (package.json, node_modules) was
    // deleted is still a TS app.
    try cwd.deleteFile(io, root ++ "/src/main.zig");
    try cwd.deleteFile(io, root ++ "/package.json");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/src/core.ts", .data = "// ts" });
    try std.testing.expectEqual(CoreTree.ts, detectAt(io, root));
}

test "package.json version extraction" {
    try std.testing.expectEqualStrings("0.0.1", parsePackageVersion(
        \\{
        \\  "name": "@native-sdk/core",
        \\  "private": true,
        \\  "version": "0.0.1"
        \\}
    ).?);
    try std.testing.expectEqualStrings("1.2.3", parsePackageVersion("{\"version\":\"1.2.3\"}").?);
    try std.testing.expect(parsePackageVersion("{}") == null);
    try std.testing.expect(parsePackageVersion("{\"version\": 3}") == null);
    try std.testing.expect(parsePackageVersion("{\"version\": \"\"}") == null);
}

// The materialize -> self-heal -> npm-install handoff lifecycle, against a
// fake SDK checkout so the pinned versions are the test's own.
test "editor package: materialize, heal, and the npm-install handoff" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-ts-editor-package";
    const sdk = root ++ "/sdk-checkout";
    const app = root ++ "/app";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    try cwd.createDirPath(io, sdk ++ "/packages/core/sdk");
    try cwd.createDirPath(io, app ++ "/src");
    try cwd.writeFile(io, .{ .sub_path = sdk ++ "/packages/core/package.json", .data = "{ \"name\": \"@native-sdk/core\", \"version\": \"0.0.9\" }" });
    try cwd.writeFile(io, .{ .sub_path = sdk ++ "/packages/core/sdk/core.ts", .data = "// core module" });
    try cwd.writeFile(io, .{ .sub_path = sdk ++ "/packages/core/sdk/text.ts", .data = "// text module" });
    try cwd.writeFile(io, .{ .sub_path = sdk ++ "/packages/core/sdk/events.ts", .data = "// events module" });
    try cwd.writeFile(io, .{ .sub_path = sdk ++ "/packages/core/sdk/bytes_text_methods.d.ts", .data = "// ambient text methods" });

    const bundled = try bundledSdkVersion(allocator, io, sdk);
    defer allocator.free(bundled);
    try std.testing.expectEqualStrings("0.0.9", bundled);

    // Missing copy: materialized, and the full artifact lands.
    try std.testing.expectEqual(EnsureOutcome.materialized, try ensureEditorPackage(allocator, io, sdk, app));
    try std.testing.expect(buildgraph.fileExists(io, app ++ "/node_modules/@native-sdk/core/package.json"));
    try std.testing.expect(buildgraph.fileExists(io, app ++ "/node_modules/@native-sdk/core/sdk/core.ts"));
    try std.testing.expect(buildgraph.fileExists(io, app ++ "/node_modules/@native-sdk/core/sdk/text.ts"));
    try std.testing.expect(buildgraph.fileExists(io, app ++ "/node_modules/@native-sdk/core/sdk/events.ts"));
    try std.testing.expect(buildgraph.fileExists(io, app ++ "/node_modules/@native-sdk/core/sdk/bytes_text_methods.d.ts"));

    // Current copy: untouched (this is also the post-publish handoff — a
    // real `npm install` writes identical content at the same version, so
    // user-owned node_modules stop being rewritten). Prove "untouched"
    // through a sentinel edit the refresh must NOT undo.
    try cwd.writeFile(io, .{ .sub_path = app ++ "/node_modules/@native-sdk/core/sdk/core.ts", .data = "// same version, npm-owned bytes" });
    try std.testing.expectEqual(EnsureOutcome.fresh, try ensureEditorPackage(allocator, io, sdk, app));
    const untouched = try cwd.readFileAlloc(io, app ++ "/node_modules/@native-sdk/core/sdk/core.ts", allocator, .limited(1024));
    defer allocator.free(untouched);
    try std.testing.expectEqualStrings("// same version, npm-owned bytes", untouched);

    // Version skew (SDK moved on): refreshed to the bundled content.
    try cwd.writeFile(io, .{ .sub_path = sdk ++ "/packages/core/package.json", .data = "{ \"name\": \"@native-sdk/core\", \"version\": \"0.1.0\" }" });
    try std.testing.expectEqual(EnsureOutcome.materialized, try ensureEditorPackage(allocator, io, sdk, app));
    const refreshed = try cwd.readFileAlloc(io, app ++ "/node_modules/@native-sdk/core/sdk/core.ts", allocator, .limited(1024));
    defer allocator.free(refreshed);
    try std.testing.expectEqualStrings("// core module", refreshed);
    {
        const status = try editorPackageStatus(allocator, io, sdk, app);
        defer status.deinit(allocator);
        try std.testing.expect(status.fresh());
    }

    // A half-deleted copy (manifest present, sdk/ gone) heals too.
    try cwd.deleteFile(io, app ++ "/node_modules/@native-sdk/core/sdk/text.ts");
    try std.testing.expectEqual(EnsureOutcome.materialized, try ensureEditorPackage(allocator, io, sdk, app));
    try std.testing.expect(buildgraph.fileExists(io, app ++ "/node_modules/@native-sdk/core/sdk/text.ts"));
}

// --------------------------------------------- toolchain resolution
//
// The resolution gate never spawns anything — it is stats plus teachings —
// so the tests exercise it directly against fixture trees: the walk across
// every layout npm produces, each partial-extraction sliver the predicate
// must refuse, and the two teachings the layouts split into. "Nothing ran
// npm" is asserted structurally: the gate has no runner to inject, and the
// checkout fixtures prove their node_modules stayed exactly as staged.

test "the checkout teaching's npm command survives production npm config" {
    // `--include=dev` must ride the named command: without it, ambient
    // NODE_ENV=production (or omit=dev) makes `npm ci` skip the
    // devDependency the install exists for — exit 0, nothing on disk.
    try std.testing.expect(std.mem.indexOf(u8, npm_ci_teaching_command, "--include=dev") != null);
}

/// The minimal manifest of the @typescript/typescript6 WRAPPER a fake
/// COMPLETED install also lands (npm keeps installing it as a declared
/// dependency). The gate never probes it — validation tracks only the
/// aliased real compiler runtime loads — so tests land it exactly where
/// they model complete installs, to prove its presence or absence never
/// sways the verdict.
const fake_toolchain_manifest = "{ \"name\": \"@typescript/typescript6\", \"version\": \"0.0.2\", \"main\": \"./lib/typescript.js\" }";

/// The wrapper entrypoint bytes its manifest's "main" names.
const fake_toolchain_entrypoint = "// fake typescript.js";

/// The minimal manifest of the aliased REAL compiler (@typescript/old is
/// `npm:typescript@X.Y.Z`, so the installed manifest names `typescript`)
/// — the package the gate probes, because it is the one runtime imports.
/// The resolvability predicate (like node) requires BOTH the manifest and
/// its entrypoint; half-written trees — bare directories, manifests
/// without their entrypoint — are staged in the tests themselves. Its
/// version matches `fake_pin_manifest`'s exact pin, so a fully staged
/// fake compiler passes the version check too.
const fake_compiler_manifest = "{ \"name\": \"typescript\", \"version\": \"9.9.9\", \"main\": \"./lib/typescript.js\" }";

/// The same compiler at a version the fake SDK never pinned: the
/// conflicting-consumer-tree shape the version check exists to refuse.
const fake_conflicting_compiler_manifest = "{ \"name\": \"typescript\", \"version\": \"1.2.3\", \"main\": \"./lib/typescript.js\" }";

/// The aliased compiler's entrypoint bytes.
const fake_compiler_entrypoint = "// fake real typescript.js";

/// A fake framework's packages/core/package.json: the file the resolution
/// gate reads its exact compiler pin from (the `npm:typescript@X.Y.Z`
/// alias suffix), matching `fake_compiler_manifest`'s version.
const fake_pin_manifest = "{ \"name\": \"@native-sdk/core\", \"version\": \"0.0.9\", \"devDependencies\": { \"@typescript/old\": \"npm:typescript@9.9.9\" } }";

/// Land a fake framework root's own pin manifest (packages/core/package.json).
fn landFakePinManifest(io: std.Io, framework_root: []const u8) bool {
    var buffer: [512]u8 = undefined;
    const dir = std.fmt.bufPrint(&buffer, "{s}/packages/core", .{framework_root}) catch return false;
    var cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch return false;
    var manifest_buffer: [512]u8 = undefined;
    const manifest = std.fmt.bufPrint(&manifest_buffer, "{s}/package.json", .{dir}) catch return false;
    cwd.writeFile(io, .{ .sub_path = manifest, .data = fake_pin_manifest }) catch return false;
    return true;
}

/// Land one fake-but-complete package (lib/ directory, manifest,
/// lib/typescript.js entrypoint) at `dir`'s
/// node_modules/@typescript/<package_name>.
fn landFakePackage(io: std.Io, dir: []const u8, comptime package_name: []const u8, manifest_data: []const u8, entrypoint_data: []const u8) bool {
    var buffer: [512]u8 = undefined;
    const package = std.fmt.bufPrint(&buffer, "{s}/node_modules/@typescript/" ++ package_name, .{dir}) catch return false;
    var cwd = std.Io.Dir.cwd();
    var lib_buffer: [512]u8 = undefined;
    const lib = std.fmt.bufPrint(&lib_buffer, "{s}/lib", .{package}) catch return false;
    cwd.createDirPath(io, lib) catch return false;
    var manifest_buffer: [512]u8 = undefined;
    const manifest = std.fmt.bufPrint(&manifest_buffer, "{s}/package.json", .{package}) catch return false;
    cwd.writeFile(io, .{ .sub_path = manifest, .data = manifest_data }) catch return false;
    var entry_buffer: [512]u8 = undefined;
    const entrypoint = std.fmt.bufPrint(&entry_buffer, "{s}/typescript.js", .{lib}) catch return false;
    cwd.writeFile(io, .{ .sub_path = entrypoint, .data = entrypoint_data }) catch return false;
    return true;
}

/// Land a fake COMPLETE install under `dir`'s node_modules: the wrapper
/// (still a declared dependency, so npm always lands it) AND the aliased
/// real compiler, as npm's dedupe lands them — siblings under one
/// node_modules. Only the compiler decides resolution; the wrapper rides
/// along so complete-install fixtures stay shaped like real trees.
fn landFakeToolchain(io: std.Io, dir: []const u8) bool {
    if (!landFakePackage(io, dir, "typescript6", fake_toolchain_manifest, fake_toolchain_entrypoint)) return false;
    return landFakePackage(io, dir, "old", fake_compiler_manifest, fake_compiler_entrypoint);
}

test "toolchain resolution: the nested install (repo checkout) resolves, partial extractions do not" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-ts-toolchain-nested";
    const sdk = root ++ "/sdk-checkout";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    try cwd.createDirPath(io, sdk ++ "/packages/core");
    try std.testing.expect(!transpilerResolves(allocator, io, sdk));
    // The gate reads its exact compiler pin from the framework's own
    // packages/core/package.json; every real layout ships it.
    try std.testing.expect(landFakePinManifest(io, sdk));
    try std.testing.expect(!transpilerResolves(allocator, io, sdk));
    // The COMPLETE wrapper — manifest, entrypoint, the works — changes
    // nothing: nothing imports @typescript/typescript6 at run time, so
    // validation does not probe it. Only the aliased real compiler
    // counts.
    try std.testing.expect(landFakePackage(io, sdk ++ "/packages/core", "typescript6", fake_toolchain_manifest, fake_toolchain_entrypoint));
    try std.testing.expect(!transpilerResolves(allocator, io, sdk));
    // A bare compiler DIRECTORY (an interrupted extraction, a pruned
    // install) is not resolvable: node needs the package's manifest.
    try cwd.createDirPath(io, sdk ++ "/packages/core/node_modules/@typescript/old");
    try std.testing.expect(!transpilerResolves(allocator, io, sdk));
    // A manifest WITHOUT its entrypoint is the mid-extraction crash shape
    // (package.json rides first in the tarball): still not resolvable —
    // node would read "main" and fail loading it.
    try cwd.writeFile(io, .{ .sub_path = sdk ++ "/packages/core/node_modules/@typescript/old/package.json", .data = fake_compiler_manifest });
    try std.testing.expect(!transpilerResolves(allocator, io, sdk));
    try cwd.createDirPath(io, sdk ++ "/packages/core/node_modules/@typescript/old/lib");
    try cwd.writeFile(io, .{ .sub_path = sdk ++ "/packages/core/node_modules/@typescript/old/lib/typescript.js", .data = fake_compiler_entrypoint });
    try std.testing.expect(transpilerResolves(allocator, io, sdk));
}

test "toolchain resolution: the hoisted install (npm project layout) resolves by ancestor walk" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-ts-toolchain-hoisted";
    // The npm local-install shape: the CLI package and its dependencies
    // are SIBLINGS under the project's node_modules — nothing sits inside
    // the CLI package itself.
    const sdk = root ++ "/proj/node_modules/@native-sdk/cli";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    try cwd.createDirPath(io, sdk ++ "/packages/core");
    try std.testing.expect(landFakePinManifest(io, sdk));
    try std.testing.expect(!transpilerResolves(allocator, io, sdk));
    // The hoisted wrapper — even complete — is not what validation
    // tracks: nothing imports it at run time.
    try std.testing.expect(landFakePackage(io, root ++ "/proj", "typescript6", fake_toolchain_manifest, fake_toolchain_entrypoint));
    try std.testing.expect(!transpilerResolves(allocator, io, sdk));
    // A bare compiler directory on the hoisted layout is a broken
    // install, not a resolvable compiler — the manifest is the bar here
    // too...
    try cwd.createDirPath(io, root ++ "/proj/node_modules/@typescript/old");
    try std.testing.expect(!transpilerResolves(allocator, io, sdk));
    // ...and a manifest without its entrypoint (the mid-extraction crash
    // shape) is still broken, not resolvable.
    try cwd.writeFile(io, .{ .sub_path = root ++ "/proj/node_modules/@typescript/old/package.json", .data = fake_compiler_manifest });
    try std.testing.expect(!transpilerResolves(allocator, io, sdk));
    // npm hoists @typescript/old to the install root on flat layouts — an
    // ANCESTOR of the CLI's packages/core, not a fixed sibling: the walk
    // from the runtime origin must reach it.
    try cwd.createDirPath(io, root ++ "/proj/node_modules/@typescript/old/lib");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/proj/node_modules/@typescript/old/lib/typescript.js", .data = fake_compiler_entrypoint });
    try std.testing.expect(transpilerResolves(allocator, io, sdk));

    // And the global-prefix shape: the compiler nested inside the CLI
    // package's own node_modules (npm -g) resolves as a nearer ancestor
    // of packages/core — with nothing hoisted at the install root at all.
    cwd.deleteTree(io, root ++ "/proj/node_modules/@typescript/old") catch {};
    try std.testing.expect(!transpilerResolves(allocator, io, sdk));
    try std.testing.expect(landFakePackage(io, sdk, "old", fake_compiler_manifest, fake_compiler_entrypoint));
    try std.testing.expect(transpilerResolves(allocator, io, sdk));
}

test "toolchain gate: a resolvable tree passes silently, a checkout teaches the one npm ci and runs nothing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-ts-toolchain-gate";
    const sdk = root ++ "/sdk-checkout";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    // test/ marks the layout a repo checkout (the published payload
    // deliberately omits it): the teaching names `npm ci --include=dev`.
    try cwd.createDirPath(io, sdk ++ "/packages/core/test");
    try std.testing.expect(landFakePinManifest(io, sdk));

    // An uninstalled checkout: the teaching error — and NOTHING was
    // spawned, structurally: the gate has no installer to call, and the
    // tree it inspected stayed exactly as staged (no node_modules
    // appeared).
    try std.testing.expectError(error.MissingTranspiler, ensureResolvedTranspiler(allocator, io, sdk));
    try std.testing.expect(!dirExists(io, sdk ++ "/packages/core/node_modules"));

    // A partial extraction (the wrapper landed, the aliased compiler —
    // the package runtime actually imports — did not) is taught the same
    // way, and left byte-for-byte in place, never "repaired".
    try std.testing.expect(landFakePackage(io, sdk ++ "/packages/core", "typescript6", fake_toolchain_manifest, fake_toolchain_entrypoint));
    try std.testing.expectError(error.MissingTranspiler, ensureResolvedTranspiler(allocator, io, sdk));
    try std.testing.expect(!dirExists(io, sdk ++ "/packages/core/node_modules/@typescript/old"));

    // A complete install passes silently.
    try std.testing.expect(landFakePackage(io, sdk ++ "/packages/core", "old", fake_compiler_manifest, fake_compiler_entrypoint));
    try ensureResolvedTranspiler(allocator, io, sdk);
}

test "toolchain gate: an npm-payload layout teaches the reinstall, never npm ci" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-ts-toolchain-npm-payload";
    // The npm-installed CLI's shape: packages/core carries the lockfile
    // (the payload deliberately ships it) but NO test/ directory — the
    // staging excludes it, and that absence is the layout signal.
    const sdk = root ++ "/proj/node_modules/@native-sdk/cli";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, sdk ++ "/packages/core");
    try std.testing.expect(landFakePinManifest(io, sdk));
    try cwd.writeFile(io, .{ .sub_path = sdk ++ "/packages/core/package-lock.json", .data = "{ \"lockfileVersion\": 3 }" });

    // A missing toolchain here is a broken install: the reinstall
    // teaching, and the npm-owned tree untouched (no node_modules
    // appeared anywhere the gate looked).
    try std.testing.expectError(error.BrokenToolchainInstall, ensureResolvedTranspiler(allocator, io, sdk));
    try std.testing.expect(!dirExists(io, sdk ++ "/packages/core/node_modules"));

    // The same verdict for each partial-extraction sliver of the
    // compiler: a hoisted bare directory, then its
    // manifest-without-entrypoint completion — both broken installs to
    // teach, never trees to repair.
    try cwd.createDirPath(io, root ++ "/proj/node_modules/@typescript/old");
    try std.testing.expectError(error.BrokenToolchainInstall, ensureResolvedTranspiler(allocator, io, sdk));
    try cwd.writeFile(io, .{ .sub_path = root ++ "/proj/node_modules/@typescript/old/package.json", .data = fake_compiler_manifest });
    try std.testing.expectError(error.BrokenToolchainInstall, ensureResolvedTranspiler(allocator, io, sdk));

    // A complete hoisted install (compiler plus the wrapper npm still
    // ships) passes silently.
    try std.testing.expect(landFakeToolchain(io, root ++ "/proj"));
    try ensureResolvedTranspiler(allocator, io, sdk);
}

test "aliased compiler pin extraction is strict about the npm:typescript@X.Y.Z shape" {
    try std.testing.expectEqualStrings("9.9.9", parseAliasedCompilerPin(fake_pin_manifest).?);
    try std.testing.expectEqualStrings("6.0.3", parseAliasedCompilerPin(
        \\{
        \\  "devDependencies": {
        \\    "@typescript/old": "npm:typescript@6.0.3",
        \\    "@typescript/typescript6": "6.0.2"
        \\  }
        \\}
    ).?);
    // Ranges, bare versions, and empty pins are shapes check-version-sync
    // rejects; the gate must not vouch for them either.
    try std.testing.expect(parseAliasedCompilerPin("{ \"@typescript/old\": \"npm:typescript@^6\" }") == null);
    try std.testing.expect(parseAliasedCompilerPin("{ \"@typescript/old\": \"npm:typescript@6.0\" }") == null);
    try std.testing.expect(parseAliasedCompilerPin("{ \"@typescript/old\": \"6.0.3\" }") == null);
    try std.testing.expect(parseAliasedCompilerPin("{ \"@typescript/old\": \"npm:typescript@\" }") == null);
    try std.testing.expect(parseAliasedCompilerPin("{}") == null);
}

test "toolchain version pin: a compiler resolved at the wrong version teaches the mismatch, on both layouts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-ts-toolchain-version";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    // Checkout layout: a complete nested install whose aliased compiler is
    // NOT the pinned version (pin 9.9.9, installed 1.2.3). Resolvability
    // alone would pass this tree; the version check must refuse it with
    // the mismatch teaching, not the npm-ci teaching — no install command
    // fixes a resolved-but-wrong compiler.
    const checkout = root ++ "/sdk-checkout";
    try cwd.createDirPath(io, checkout ++ "/packages/core/test");
    try std.testing.expect(landFakePinManifest(io, checkout));
    try std.testing.expect(landFakePackage(io, checkout ++ "/packages/core", "typescript6", fake_toolchain_manifest, fake_toolchain_entrypoint));
    try std.testing.expect(landFakePackage(io, checkout ++ "/packages/core", "old", fake_conflicting_compiler_manifest, fake_compiler_entrypoint));
    try std.testing.expect(!transpilerResolves(allocator, io, checkout));
    try std.testing.expectError(error.ToolchainVersionMismatch, ensureResolvedTranspiler(allocator, io, checkout));

    // npm layout, the conflict shape npm itself produces: the consumer's
    // own conflicting @typescript/old hoisted at the project root, while
    // the SDK's exact pin lands nested under the CLI. Runtime resolves
    // the alias from packages/core and loads the NESTED exact pin — so
    // the gate, walking from the same origin, must PASS this healthy
    // tree. (Holding the hoisted wrapper's origin against the pin here
    // was the false rejection the walk origin exists to prevent.)
    const cli = root ++ "/proj/node_modules/@native-sdk/cli";
    try cwd.createDirPath(io, cli ++ "/packages/core");
    try std.testing.expect(landFakePinManifest(io, cli));
    try cwd.writeFile(io, .{ .sub_path = cli ++ "/packages/core/package-lock.json", .data = "{ \"lockfileVersion\": 3 }" });
    try std.testing.expect(landFakePackage(io, root ++ "/proj", "typescript6", fake_toolchain_manifest, fake_toolchain_entrypoint));
    try std.testing.expect(landFakePackage(io, root ++ "/proj", "old", fake_conflicting_compiler_manifest, fake_compiler_entrypoint));
    try std.testing.expect(landFakePackage(io, cli, "old", fake_compiler_manifest, fake_compiler_entrypoint));
    try std.testing.expect(transpilerResolves(allocator, io, cli));
    try ensureResolvedTranspiler(allocator, io, cli);

    // A consumer's own shadowing WRAPPER changes nothing either way:
    // validation tracks only the compiler runtime loads, so the verdict
    // is identical with the hoisted wrapper deleted outright.
    try cwd.deleteTree(io, root ++ "/proj/node_modules/@typescript/typescript6");
    try ensureResolvedTranspiler(allocator, io, cli);

    // A genuinely wrong compiler AT the packages/core origin still
    // teaches the mismatch: with the CLI's nested exact pin gone, the
    // conflicting hoisted copy is what the walk from packages/core — and
    // node at run time — resolves, and no install command fixes a
    // resolved-but-wrong compiler.
    try cwd.deleteTree(io, cli ++ "/node_modules/@typescript/old");
    try std.testing.expect(!transpilerResolves(allocator, io, cli));
    try std.testing.expectError(error.ToolchainVersionMismatch, ensureResolvedTranspiler(allocator, io, cli));

    // Align the hoisted copy with the pin and the same tree passes.
    try cwd.writeFile(io, .{ .sub_path = root ++ "/proj/node_modules/@typescript/old/package.json", .data = fake_compiler_manifest });
    try ensureResolvedTranspiler(allocator, io, cli);
}

// The copy the CLI materializes IS the future published artifact: the
// bundled manifest must carry the exports/files shape editors resolve
// through (pinned in full by packages/core/test/package_manifest.test.ts;
// this cross-check keeps the Zig side honest about the file list it
// copies). Runs against the real repo checkout.
test "the bundled @native-sdk/core manifest matches the materialized file list" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const manifest = std.Io.Dir.cwd().readFileAlloc(io, "packages/core/package.json", allocator, .limited(64 * 1024)) catch return error.SkipZigTest;
    defer allocator.free(manifest);
    try std.testing.expect(parsePackageVersion(manifest) != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"files\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"./sdk/core.ts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"./text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"./sdk/text.ts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"./events\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"./sdk/events.ts\"") != null);
    for (editor_package_files[1..]) |sub_path| {
        var path_buffer: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "packages/core/{s}", .{sub_path});
        try std.testing.expect(buildgraph.fileExists(io, path));
    }
}
