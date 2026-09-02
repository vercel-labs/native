const std = @import("std");
const ui_markup = @import("ui_markup");
const markup_lsp = @import("markup_lsp");

/// Re-exported for the `native check` verb's src/ walk: true for `.native`.
pub const hasMarkupExtension = ui_markup.hasMarkupExtension;

pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    if (args.len >= 1 and (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "help"))) {
        // Asked-for help is a success: print it and exit 0.
        usage();
        return;
    }
    if (args.len >= 1 and std.mem.eql(u8, args[0], "lsp")) {
        return runLsp(allocator, io);
    }
    if (args.len >= 1 and std.mem.eql(u8, args[0], "dump")) {
        return runDump(allocator, io, args[1..]);
    }
    if (args.len < 1 or !std.mem.eql(u8, args[0], "check")) {
        usage();
        return error.MarkupCommandFailed;
    }
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(allocator);
    var strict = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--strict")) {
            strict = true;
            continue;
        }
        try files.append(allocator, arg);
    }
    if (files.items.len == 0) {
        std.debug.print("error: markup check requires a file path\n", .{});
        return error.MarkupCommandFailed;
    }

    const outcome = try checkFiles(allocator, io, files.items, .{});
    // Exit directly: the diagnostics above are the whole story, and a
    // returned error would bury them under the CLI's own return trace.
    if (outcome.failures > 0) std.process.exit(1);
    if (strict and outcome.warnings > 0) {
        std.debug.print("{d} warning{s} promoted to errors (--strict)\n", .{ outcome.warnings, if (outcome.warnings == 1) "" else "s" });
        std.process.exit(1);
    }
}

pub const CheckOutcome = struct {
    failures: usize = 0,
    warnings: usize = 0,
    /// True when a fresh model contract backed the pass (bindings,
    /// iterables, messages, and expression types were checked against the
    /// app's actual Model/Msg, not just structurally).
    contract_checked: bool = false,
};

pub const CheckOptions = struct {
    /// Shared import boundary for every checked file. Callers that need one
    /// common boundary can set this explicitly; the standalone markup
    /// command leaves it null so each explicitly named file remains rooted
    /// at its own directory.
    import_root: ?[]const u8 = null,
    /// Optional per-file import boundary. App-wide checks use this to keep
    /// secondary-window markup rooted at `src/windows` while the main view
    /// and ordinary components remain rooted at `src`.
    import_root_for_file: ?*const fn (file_path: []const u8) []const u8 = null,
};

/// Match the generated TypeScript app resolvers: the main view uses the
/// app-wide `src/` root, while every secondary-window file uses the narrower
/// `src/windows/` root. Accept both host path separator spellings because
/// app-wide checks receive paths from a filesystem walk. The first `src`
/// segment is the app source root; looking for any later `src/windows`
/// substring would misclassify e.g. `src/components/src/windows/card.native`.
pub fn importRootForFile(file_path: []const u8) []const u8 {
    var segment_start: usize = 0;
    var index: usize = 0;
    while (index <= file_path.len) : (index += 1) {
        if (index != file_path.len and file_path[index] != '/' and file_path[index] != '\\') continue;

        const segment = file_path[segment_start..index];
        if (std.mem.eql(u8, segment, "src")) {
            const src_end = index;
            var next_start = index;
            while (next_start < file_path.len and (file_path[next_start] == '/' or file_path[next_start] == '\\')) next_start += 1;
            var next_end = next_start;
            while (next_end < file_path.len and file_path[next_end] != '/' and file_path[next_end] != '\\') next_end += 1;
            if (next_start < next_end and std.mem.eql(u8, file_path[next_start..next_end], "windows")) {
                return file_path[0..next_end];
            }
            return file_path[0..src_end];
        }
        segment_start = index + 1;
    }
    return "src";
}

/// The `check` body shared by `native markup check` and `native check`:
/// structural validation of every file, plus — when the working directory
/// is an app with a FRESH model-contract artifact — the model-aware
/// contract pass and the dead-state lint. A missing, stale, or unreadable
/// artifact degrades to structural checking with a note, never a false
/// pass.
pub fn checkFiles(allocator: std.mem.Allocator, io: std.Io, files: []const []const u8, options: CheckOptions) !CheckOutcome {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    std.debug.assert(options.import_root == null or options.import_root_for_file == null);

    var outcome = CheckOutcome{};
    var contract_value: ?ui_markup.contract.Contract = null;
    // The degraded structural-only modes share one loud, consistent line in
    // both `native check` and `native markup check`. The refresh command is
    // `native test` (which works in every app shape); an app that owns its
    // build.zig can also run the underlying `zig build model-contract` step.
    const refresh_hint: []const u8 = if (fileExists(io, "build.zig")) "run `native test` (or `zig build model-contract`)" else "run `native test`";
    switch (discoverContract(arena, io)) {
        .no_app => {},
        .missing => std.debug.print(
            "model contract: not yet built - bindings and app: icon names checked structurally only; {s} to enable typed checks\n",
            .{refresh_hint},
        ),
        .unreadable => std.debug.print(
            "model contract: {s} could not be parsed (it may come from a different toolkit version) - bindings and app: icon names checked structurally only; {s} to rebuild it\n",
            .{ ui_markup.contract.default_artifact_path, refresh_hint },
        ),
        .stale => std.debug.print(
            "model contract: {s} is stale (the app's core sources changed since it was emitted) - bindings and app: icon names checked structurally only; {s} to refresh it\n",
            .{ ui_markup.contract.default_artifact_path, refresh_hint },
        ),
        .ok => |parsed| contract_value = parsed,
    }

    var usage_state: ?ui_markup.contract.Usage = null;
    if (contract_value) |*parsed| {
        usage_state = try ui_markup.contract.Usage.init(arena, parsed);
    }
    var views_checked: usize = 0;
    // Basenames every `@embedFile("...")` under src/ references, gathered
    // once per run on the first failing file (a passing run never pays
    // for the scan).
    var embedded_basenames: ?[]const []const u8 = null;
    for (files) |file_path| {
        const import_root = if (options.import_root_for_file) |root_for_file|
            root_for_file(file_path)
        else
            options.import_root;
        const checked = checkFile(allocator, io, file_path, .{
            .contract = if (contract_value) |*parsed| parsed else null,
            .usage = if (usage_state) |*live_usage| live_usage else null,
            .arena = arena,
            .import_root = import_root,
        }) catch {
            outcome.failures += 1;
            printOrphanHint(arena, io, file_path, &embedded_basenames);
            continue;
        };
        if (checked.had_view) views_checked += 1;
        outcome.warnings += checked.warnings;
    }
    if (contract_value != null) outcome.contract_checked = true;

    // The reverse direction — model state and Msg tags no view binds —
    // only reads once every view has contributed its bindings, and only
    // when the forward pass is clean (errors already fail the run).
    if (outcome.failures == 0 and views_checked > 0) {
        if (contract_value) |*parsed| {
            const warnings = try ui_markup.contract.deadState(arena, parsed, &usage_state.?);
            for (warnings) |warning| {
                std.debug.print("warning: {s}\n", .{warning.message});
            }
            outcome.warnings += warnings.len;
        }
    }
    return outcome;
}

/// After a markup file fails inside an app directory, say out loud when
/// NOTHING under src/ embeds it: a failing file no Zig source references
/// is usually a refactor leftover, and fixing its errors is wasted work.
/// The embed scan runs once per check run, on the first failure. On the
/// TypeScript track (src/core.ts is the app core) the scan proves
/// nothing — the generated wiring embeds src/app.native from OUTSIDE the
/// app tree, so "nothing embeds this" is a false signal that once cost a
/// user their view.
fn printOrphanHint(arena: std.mem.Allocator, io: std.Io, file_path: []const u8, cache: *?[]const []const u8) void {
    if (!fileExists(io, "app.json") and !fileExists(io, "app.zon")) return;
    const ts_track = fileExists(io, "src/core.ts");
    const basenames: []const []const u8 = if (ts_track) &.{} else cache.* orelse blk: {
        const collected = collectEmbeddedBasenames(arena, io) catch return;
        cache.* = collected;
        break :blk collected;
    };
    const note = orphanNote(ts_track, basenames, std.fs.path.basename(file_path)) orelse return;
    std.debug.print("{s}: {s}\n", .{ file_path, note });
}

/// The orphan-hint disposition, separated from IO so tests can pin it.
/// Zig track: hint only when no `@embedFile` under src/ names the failing
/// file. TS track: `@embedFile` is not a concept the app tree owns, so
/// the leftover heuristic never fires; the one wired view (src/app.native)
/// instead gets a keep-your-view note, because the old hint led an agent
/// to delete it.
fn orphanNote(ts_track: bool, embedded_basenames: []const []const u8, failing_basename: []const u8) ?[]const u8 {
    if (ts_track) {
        if (std.mem.eql(u8, failing_basename, "app.native")) {
            return "note: src/app.native is this app's view, wired to src/core.ts automatically - fix the errors above; do not delete it";
        }
        return null;
    }
    for (embedded_basenames) |name| {
        if (std.mem.eql(u8, name, failing_basename)) return null;
    }
    return "note: no Zig source under src/ embeds this file - if it is a leftover, delete it; otherwise embed it with @embedFile";
}

test "orphanNote: TS track never suggests deleting the wired view" {
    // Pin the TS-track text: it must reassure, never say "delete", and
    // never mention @embedFile (a Zig-track concept the TS tree does not
    // own). The scaffold-era hint led an agent to delete src/app.native.
    const note = orphanNote(true, &.{}, "app.native") orelse return error.TestExpectedNote;
    try std.testing.expectEqualStrings(
        "note: src/app.native is this app's view, wired to src/core.ts automatically - fix the errors above; do not delete it",
        note,
    );
    try std.testing.expect(std.mem.indexOf(u8, note, "delete it; otherwise") == null);
    try std.testing.expect(std.mem.indexOf(u8, note, "@embedFile") == null);
}

test "orphanNote: TS track stays silent for other markup files" {
    // The embed scan proves nothing on the TS track, so no leftover
    // verdict is honest there.
    try std.testing.expectEqual(@as(?[]const u8, null), orphanNote(true, &.{}, "extra.native"));
}

test "orphanNote: Zig track hints only for unembedded files" {
    const embedded = [_][]const u8{"app.native"};
    try std.testing.expectEqual(@as(?[]const u8, null), orphanNote(false, &embedded, "app.native"));
    const note = orphanNote(false, &embedded, "leftover.native") orelse return error.TestExpectedNote;
    try std.testing.expect(std.mem.indexOf(u8, note, "@embedFile") != null);
}

test "importRootForFile preserves the secondary-window boundary" {
    try std.testing.expectEqualStrings("src", importRootForFile("src/app.native"));
    try std.testing.expectEqualStrings("src", importRootForFile("src/components/card.native"));
    try std.testing.expectEqualStrings("src/windows", importRootForFile("src/windows/settings.native"));
    try std.testing.expectEqualStrings("src/windows", importRootForFile("src/windows/components/shared.native"));
    try std.testing.expectEqualStrings("src/windows", importRootForFile("src/windows\\components\\shared.native"));
    try std.testing.expectEqualStrings("src", importRootForFile("src/components/src/windows/card.native"));
    try std.testing.expectEqualStrings("/project/src", importRootForFile("/project/src/components/src/windows/card.native"));
}

test "resolver paths normalize filesystem separators" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings(
        "src/windows/settings.native",
        try normalizeResolverPath(arena_state.allocator(), "src\\windows\\settings.native"),
    );
}

test "app-wide checking applies the secondary-window boundary per file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "src/windows/components");
    try tmp.dir.createDirPath(io, "src/shared");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/windows/settings.native",
        .data = "<import src=\"components/shared.native\"/>\n<column />",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/windows/components/shared.native",
        .data = "<template name=\"shared\"><text>shared</text></template>\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/shared/common.native",
        .data = "<template name=\"common\"><text>common</text></template>\n",
    });

    var root_buffer: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    var window_path_buffer: [320]u8 = undefined;
    const window_path = try std.fmt.bufPrint(&window_path_buffer, "{s}/src/windows/settings.native", .{root});
    var main_path_buffer: [320]u8 = undefined;
    const main_path = try std.fmt.bufPrint(&main_path_buffer, "{s}/src/shared/common.native", .{root});
    const files = [_][]const u8{ window_path, main_path };
    const outcome = try checkFiles(std.testing.allocator, io, &files, .{
        .import_root_for_file = importRootForFile,
    });
    try std.testing.expectEqual(@as(usize, 0), outcome.failures);

    try tmp.dir.writeFile(io, .{
        .sub_path = "src/windows/settings.native",
        .data = "<import src=\"../shared/common.native\"/>\n<column />",
    });
    const escaped = try checkFiles(std.testing.allocator, io, &files, .{
        .import_root_for_file = importRootForFile,
    });
    try std.testing.expectEqual(@as(usize, 1), escaped.failures);
}

test "app-wide checking preserves src as the component import root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "src/components");
    try tmp.dir.createDirPath(io, "src/shared");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/components/card.native",
        .data =
        \\<import src="../shared/base.native"/>
        \\<template name="card"><column><use template="base" /></column></template>
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/shared/base.native",
        .data = "<template name=\"base\"><text>shared</text></template>\n",
    });

    var root_buffer: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, ".zig-cache/tmp/{s}/src", .{tmp.sub_path[0..]});
    var path_buffer: [320]u8 = undefined;
    const component_path = try std.fmt.bufPrint(&path_buffer, "{s}/components/card.native", .{root});
    const checked = try checkFile(std.testing.allocator, io, component_path, .{
        .arena = std.testing.allocator,
        .import_root = root,
    });
    try std.testing.expect(!checked.had_view);

    // An explicitly named standalone component keeps its own directory as
    // the root; reaching a sibling remains an escape in that narrower mode.
    try std.testing.expectError(error.MarkupImport, checkFile(std.testing.allocator, io, component_path, .{
        .arena = std.testing.allocator,
    }));
}

/// The basename of every `@embedFile("...")` argument across the .zig
/// sources under src/, each file read once.
fn collectEmbeddedBasenames(arena: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var root = std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true }) catch return out.items;
    defer root.close(io);
    var walker = try root.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const full_path = try std.fs.path.join(arena, &.{ "src", entry.path });
        const source = readFile(arena, io, full_path) catch continue;
        const marker = "@embedFile(";
        var rest = source;
        while (std.mem.indexOf(u8, rest, marker)) |start| {
            rest = rest[start + marker.len ..];
            if (rest.len == 0 or rest[0] != '"') continue;
            const close = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse break;
            try out.append(arena, std.fs.path.basename(rest[1..close]));
            rest = rest[close + 1 ..];
        }
    }
    return out.items;
}

const ContractState = union(enum) {
    no_app,
    missing,
    unreadable,
    stale,
    ok: ui_markup.contract.Contract,
};

/// Look for the app's contract artifact next to the working directory's
/// app.zon and prove it fresh (the artifact carries a hash over the app's
/// Zig sources; any drift degrades to structural checking).
fn discoverContract(arena: std.mem.Allocator, io: std.Io) ContractState {
    if (!fileExists(io, "app.json") and !fileExists(io, "app.zon")) return .no_app;
    const source = readFile(arena, io, ui_markup.contract.default_artifact_path) catch return .missing;
    const parsed = ui_markup.contract.parseArtifact(arena, source) catch return .unreadable;
    if (parsed.format != ui_markup.contract.format_version) return .unreadable;
    const current = ui_markup.contract.hashSourceDir(arena, io, parsed.source_root) catch return .stale;
    if (current != parsed.source_hash) return .stale;
    return .{ .ok = parsed };
}

fn fileExists(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn runLsp(allocator: std.mem.Allocator, io: std.Io) !void {
    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    var server = markup_lsp.Server.init(allocator, &stdin_reader.interface, &stdout_writer.interface);
    defer server.deinit();
    try server.run();
}

/// `native markup dump <file.native> [--out doc.nsui]`: resolve, validate,
/// and canonicalize a view, encode it as NSUI (the canonical binary), and
/// print the JSON inspection view DERIVED FROM THE DECODED BINARY — what
/// you read is what the artifact of record says, not what the source
/// said. `--out` additionally writes the binary artifact.
fn runDump(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var file_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--out")) {
            index += 1;
            if (index >= args.len) {
                std.debug.print("error: --out requires a path\n", .{});
                return error.MarkupCommandFailed;
            }
            out_path = args[index];
            continue;
        }
        if (file_path != null) {
            std.debug.print("error: markup dump takes one file\n", .{});
            return error.MarkupCommandFailed;
        }
        file_path = args[index];
    }
    const path = file_path orelse {
        std.debug.print("usage: native markup dump <file.native> [--out doc.nsui]\n", .{});
        return error.MarkupCommandFailed;
    };

    const source = readFile(allocator, io, path) catch |err| {
        std.debug.print("error: {s}: unable to read file ({s})\n", .{ path, @errorName(err) });
        return err;
    };
    defer allocator.free(source);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var disk_loader = DiskLoader{ .io = io };
    var diagnostic: ui_markup.MarkupErrorInfo = .{};
    const document = ui_markup.resolveImports(arena, path, source, disk_loader.loader(), &diagnostic) catch |err| {
        const info_path = if (diagnostic.path.len > 0) diagnostic.path else path;
        std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ info_path, diagnostic.line, diagnostic.column, diagnostic.message });
        return err;
    };
    if (ui_markup.validate(document)) |info| {
        const info_path = if (info.path.len > 0) info.path else path;
        std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ info_path, info.line, info.column, info.message });
        return error.MarkupInvalid;
    }
    const canonical = try ui_markup.canonicalize(arena, document);

    var codec_diagnostic: ui_markup.binary.CodecDiagnostic = .{};
    const bytes = ui_markup.binary.encode(arena, canonical, .{}, &codec_diagnostic) catch |err| {
        std.debug.print("error: {s}: {s}\n", .{ path, codec_diagnostic.message });
        return err;
    };
    if (out_path) |artifact_path| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = artifact_path, .data = bytes });
    }
    // The JSON view derives from the DECODED binary, round-tripping the
    // artifact so the dump can never show something the bytes do not say.
    const decoded = ui_markup.binary.decode(arena, bytes, &codec_diagnostic) catch |err| {
        std.debug.print("error: {s}: {s}\n", .{ path, codec_diagnostic.message });
        return err;
    };
    const hash = ui_markup.binary.documentHash(arena, decoded) catch |err| {
        std.debug.print("error: {s}: {s}\n", .{ path, codec_diagnostic.message });
        return err;
    };
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    try ui_markup.binary.writeJson(decoded, hash, &stdout_writer.interface);
    try stdout_writer.interface.flush();
}

const FileCheckContext = struct {
    contract: ?*const ui_markup.contract.Contract = null,
    usage: ?*ui_markup.contract.Usage = null,
    /// Session arena for contract-check messages, which outlive the
    /// per-file arena (the dead-state summary prints after all files).
    arena: std.mem.Allocator,
    import_root: ?[]const u8 = null,
};

const FileCheckResult = struct {
    had_view: bool = false,
    warnings: usize = 0,
};

fn checkFile(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, context: FileCheckContext) !FileCheckResult {
    const source = readFile(allocator, io, file_path) catch |err| {
        std.debug.print("error: {s}: unable to read file ({s})\n", .{ file_path, @errorName(err) });
        return err;
    };
    defer allocator.free(source);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    // Filesystem walks use the host separator, while markup resolver paths
    // are deliberately canonicalized with forward slashes. Keep the path
    // used to read the root file above, but normalize the resolver inputs so
    // Windows imports have the same dirname/root semantics as release builds.
    const resolver_file_path = try normalizeResolverPath(arena_state.allocator(), file_path);
    const resolver_import_root = if (context.import_root) |root|
        try normalizeResolverPath(arena_state.allocator(), root)
    else
        null;

    // Resolve the import closure from disk. Standalone checks root at the
    // checked file's directory; app-wide `native check` supplies the app's
    // shared `src/` root so independently checked component files preserve
    // the same sibling-import boundary as src/app.native.
    var disk_loader = DiskLoader{ .io = io };
    var diagnostic: ui_markup.MarkupErrorInfo = .{};
    const document = (if (resolver_import_root) |root|
        ui_markup.resolveImportsFromRoot(arena_state.allocator(), root, resolver_file_path, source, disk_loader.loader(), &diagnostic)
    else
        ui_markup.resolveImports(arena_state.allocator(), resolver_file_path, source, disk_loader.loader(), &diagnostic)) catch |err| {
        const path = if (diagnostic.path.len > 0) diagnostic.path else file_path;
        std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ path, diagnostic.line, diagnostic.column, diagnostic.message });
        printStaleBinaryHint(diagnostic.message);
        return err;
    };
    if (ui_markup.validate(document)) |info| {
        // A11y findings are independent per control, so one failing run
        // reports ALL of them (fix everything in one pass). Every other
        // validation error keeps the first-error behavior: the tree is
        // structurally broken, and later findings would be noise.
        if (isA11yErrorMessage(info.message)) {
            var a11y_error_storage: [ui_markup.max_a11y_warnings]ui_markup.MarkupErrorInfo = undefined;
            const findings = ui_markup.collectA11yErrors(document, &a11y_error_storage);
            if (findings.len > 0) {
                for (findings) |finding| {
                    const finding_path = if (finding.path.len > 0) finding.path else file_path;
                    std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ finding_path, finding.line, finding.column, finding.message });
                }
                return error.MarkupInvalid;
            }
        }
        const info_path = if (info.path.len > 0) info.path else file_path;
        // The position-into-source refinements (tofu codepoint, vocabulary
        // suggestion) read the ROOT file's source; an error inside an
        // imported file still reports its own path:line:column.
        const position_in_root = info.path.len == 0 or std.mem.eql(u8, info.path, resolver_file_path);
        // The tofu guard's position points at the exact character; name
        // the codepoint so the fix is one glance.
        if (position_in_root and info.message.ptr == ui_markup.font_coverage_message.ptr) {
            if (codepointAt(source, info.line, info.column)) |found| {
                std.debug.print("{s}:{d}:{d}: error: {s} (found \"{s}\" U+{X:0>4})\n", .{ info_path, info.line, info.column, info.message, found.bytes, found.codepoint });
                return error.MarkupInvalid;
            }
        }
        // A vocabulary miss teaches best when it names the token and its
        // nearest valid spelling: the validator's message is a static
        // string, but the checker holds the source and the position.
        if (position_in_root) {
            if (vocabularySuggestion(source, info)) |extra| {
                std.debug.print("{s}:{d}:{d}: error: {s} \"{s}\"", .{ info_path, info.line, info.column, info.message, extra.token });
                if (extra.suggestion) |suggestion| {
                    std.debug.print(" (did you mean \"{s}\"?)\n", .{suggestion});
                } else {
                    std.debug.print("\n", .{});
                }
                printStaleBinaryHint(info.message);
                return error.MarkupInvalid;
            }
        }
        std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ info_path, info.line, info.column, info.message });
        printStaleBinaryHint(info.message);
        return error.MarkupInvalid;
    }
    // The model-aware pass, when a fresh contract artifact is in hand:
    // bindings, iterables, message tags, and expression types against the
    // app's actual Model/Msg. Component files (no view root) check
    // through the views that import them, where argument kinds exist.
    if (context.contract) |contract_value| {
        if (try ui_markup.contract.checkDocument(context.arena, document, contract_value, context.usage)) |info| {
            const info_path = if (info.path.len > 0) info.path else file_path;
            std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ info_path, info.line, info.column, info.message });
            return error.MarkupInvalid;
        }
    }
    // The a11y lint's warning half (unnamed images, redundant labels):
    // the view degrades but stays operable, so these report without
    // failing the file; --strict promotes them like every warning.
    var warning_storage: [ui_markup.max_a11y_warnings]ui_markup.MarkupErrorInfo = undefined;
    const a11y_warnings = ui_markup.collectA11yWarnings(document, &warning_storage);
    for (a11y_warnings) |info| {
        const info_path = if (info.path.len > 0) info.path else file_path;
        std.debug.print("{s}:{d}:{d}: warning: {s}\n", .{ info_path, info.line, info.column, info.message });
    }
    std.debug.print("{s}: ok\n", .{file_path});
    return .{ .had_view = document.root != null, .warnings = a11y_warnings.len };
}

fn normalizeResolverPath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, path, '\\') == null) return path;
    const normalized = try arena.dupe(u8, path);
    for (normalized) |*character| {
        if (character.* == '\\') character.* = '/';
    }
    return normalized;
}

/// True when a validation error is one of the a11y lint's error-class
/// findings — the only validation errors that are independent per node,
/// so the checker reports all of them at once instead of one per re-run.
fn isA11yErrorMessage(message: []const u8) bool {
    const a11y_error_messages = [_][]const u8{
        ui_markup.a11y_unlabeled_control_message,
        ui_markup.a11y_icon_only_message,
        ui_markup.a11y_unlabeled_editable_message,
        ui_markup.a11y_unlabeled_radiogroup_message,
        ui_markup.a11y_unknown_role_message,
        ui_markup.a11y_container_role_message,
    };
    for (a11y_error_messages) |candidate| {
        if (std.mem.eql(u8, message, candidate)) return true;
    }
    return false;
}

/// Import loading for the checker: resolver paths are already joined
/// against the checked file's path, so they read relative to the process
/// cwd exactly like the file argument itself.
const DiskLoader = struct {
    io: std.Io,

    fn loader(self: *DiskLoader) ui_markup.ImportLoader {
        return .{ .context = @ptrCast(self), .load = load };
    }

    fn load(context: *const anyopaque, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const self: *const DiskLoader = @ptrCast(@alignCast(context));
        var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return null;
        defer file.close(self.io);
        var read_buffer: [4096]u8 = undefined;
        var reader = file.reader(self.io, &read_buffer);
        return reader.interface.allocRemaining(arena, .limited(1024 * 1024)) catch null;
    }
};

const VocabularySuggestion = struct { token: []const u8, suggestion: ?[]const u8 };

fn vocabularySuggestion(source: []const u8, info: ui_markup.MarkupErrorInfo) ?VocabularySuggestion {
    // The expression library is a closed vocabulary too: name the unknown
    // function and its nearest valid spelling. The validator's position
    // points at the attribute (or the interpolation's brace), so the
    // offending call sits at or after it on the rest of the source.
    if (std.mem.eql(u8, info.message, ui_markup.expr.unknown_function_message)) {
        const rest = sourceFrom(source, info.line, info.column) orelse return null;
        const token = ui_markup.expr.firstUnknownFunction(rest) orelse return null;
        return .{ .token = token, .suggestion = nearestName(token, &ui_markup.expr.known_function_names) };
    }
    const names: []const []const u8 = if (std.mem.eql(u8, info.message, "unknown attribute"))
        &ui_markup.known_option_attrs
    else if (std.mem.eql(u8, info.message, "unknown element"))
        &ui_markup.known_element_names
    else
        return null;
    const token = tokenAt(source, info.line, info.column) orelse return null;
    return .{ .token = token, .suggestion = nearestName(token, names) };
}

/// The source from a 1-based line/column to the end (columns count bytes,
/// matching the parser's positions).
fn sourceFrom(source: []const u8, line: usize, column: usize) ?[]const u8 {
    if (line == 0 or column == 0) return null;
    var current_line: usize = 1;
    var index: usize = 0;
    while (index < source.len and current_line < line) : (index += 1) {
        if (source[index] == '\n') current_line += 1;
    }
    if (current_line != line) return null;
    const start = index + (column - 1);
    if (start >= source.len) return null;
    return source[start..];
}

/// The identifier ([a-z0-9-_]) starting at a 1-based line/column.
fn tokenAt(source: []const u8, line: usize, column: usize) ?[]const u8 {
    if (line == 0 or column == 0) return null;
    var current_line: usize = 1;
    var index: usize = 0;
    while (index < source.len and current_line < line) : (index += 1) {
        if (source[index] == '\n') current_line += 1;
    }
    if (current_line != line) return null;
    var start = index + (column - 1);
    if (start >= source.len) return null;
    // Element positions point at the "<" itself; the name starts after it.
    if (source[start] == '<') start += 1;
    if (start >= source.len) return null;
    var end = start;
    while (end < source.len) : (end += 1) {
        const c = source[end];
        const identifier = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!identifier) break;
    }
    if (end == start) return null;
    return source[start..end];
}

/// Closest vocabulary name within edit distance 2 - close enough to be a
/// typo, far enough to avoid nonsense suggestions.
fn nearestName(token: []const u8, names: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = 3;
    for (names) |name| {
        const distance = editDistance(token, name) orelse continue;
        if (distance < best_distance) {
            best_distance = distance;
            best = name;
        }
    }
    return best;
}

/// Bounded Levenshtein distance; null when either side is too long for
/// the fixed buffer (vocabulary names are short).
fn editDistance(a: []const u8, b: []const u8) ?usize {
    if (b.len > 63) return null;
    var previous: [64]usize = undefined;
    var current: [64]usize = undefined;
    for (0..b.len + 1) |j| previous[j] = j;
    for (a, 0..) |a_char, i| {
        current[0] = i + 1;
        for (b, 0..) |b_char, j| {
            const substitution_cost: usize = if (a_char == b_char) 0 else 1;
            current[j + 1] = @min(
                previous[j] + substitution_cost,
                @min(current[j] + 1, previous[j + 1] + 1),
            );
        }
        @memcpy(previous[0 .. b.len + 1], current[0 .. b.len + 1]);
    }
    return previous[b.len];
}

/// The stale-binary markup-vocabulary case: "unknown element/attribute" from an OLD
/// `native` binary checking NEW syntax looks exactly like an authoring
/// mistake — a stale zig-out binary cost a misdiagnosis round this way.
/// When the diagnosis is a vocabulary miss, say the other explanation
/// out loud.
fn printStaleBinaryHint(message: []const u8) void {
    const vocabulary_miss = std.mem.startsWith(u8, message, "unknown element") or
        std.mem.startsWith(u8, message, "unknown attribute") or
        std.mem.startsWith(u8, message, "unknown event attribute");
    if (!vocabulary_miss) return;
    std.debug.print(
        "       (if this syntax is newer than this binary, your `native` binary may be\n" ++
            "        stale - rebuild it from the current toolkit checkout and compare\n" ++
            "        `native version`)\n",
        .{},
    );
}

const FoundCodepoint = struct { bytes: []const u8, codepoint: u21 };

/// Decode the codepoint at a 1-based line/column (columns count bytes,
/// matching the parser's positions).
fn codepointAt(source: []const u8, line: usize, column: usize) ?FoundCodepoint {
    if (line == 0 or column == 0) return null;
    var current_line: usize = 1;
    var index: usize = 0;
    while (index < source.len and current_line < line) : (index += 1) {
        if (source[index] == '\n') current_line += 1;
    }
    if (current_line != line) return null;
    const offset = index + (column - 1);
    if (offset >= source.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(source[offset]) catch return null;
    if (offset + len > source.len) return null;
    const codepoint = std.unicode.utf8Decode(source[offset .. offset + len]) catch return null;
    return .{ .bytes = source[offset .. offset + len], .codepoint = codepoint };
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
}

fn usage() void {
    std.debug.print(
        \\usage: native markup check <file.native> [more files...] [--strict]
        \\       native markup dump <file.native> [--out doc.nsui]
        \\       native markup lsp
        \\
        \\check: parses and validates markup views: grammar, expression forms,
        \\elements, attributes, structure tags, imports (checking a view
        \\follows its <import> closure; a file that is all templates is a
        \\valid component file), font coverage (literal text outside the
        \\bundled face renders as tofu boxes on reference paths - the error
        \\names the character; register a covering font and bind the text
        \\from the model, or use icons or plain words), and accessibility
        \\(unnamed interactive controls or radiogroups, icon-only controls
        \\without labels, and role misuse are errors - a screen reader user is blocked;
        \\unnamed images and redundant labels are warnings).
        \\
        \\Inside an app directory with a fresh zig-out/model-contract.zon
        \\(refresh it with `native test`), the check also verifies
        \\bindings, iterables, message tags, and expression types against
        \\the app's actual Model/Msg, verifies app: icon references
        \\against the registered icon table (pub const app_icons on the
        \\app root), and reports model state and Msg tags
        \\no view uses as warnings (--strict promotes warnings to failures;
        \\opt update-only names out with pub const view_unbound on Model or
        \\Msg). A missing or stale artifact degrades to structural checking
        \\with a note - never a false pass; binding paths are then validated
        \\against your Model/Msg when the app builds.
        \\
        \\dump: resolves and validates a view, encodes the canonical NSUI
        \\binary (schema-versioned, registry codes, byte-range spans), and
        \\prints the JSON inspection view derived from the decoded binary;
        \\--out also writes the .nsui artifact.
        \\
        \\lsp: speaks the Language Server Protocol over stdio (diagnostics,
        \\completion, hover) for .native files; wire it into your editor's LSP
        \\client (see editors/native-markup/README.md).
        \\
    , .{});
}
