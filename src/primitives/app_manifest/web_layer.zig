//! The web-layer inference contract: the ONE definition of when an app
//! ships the embedded web layer. An app is WEB when it declares web use
//! (a `.frontend` block, the `"webview"` capability, a `.shell` webview
//! view) or the RESOLVED web engine is Chromium; otherwise it is
//! native-only and the platform host compiles without the embedded
//! layer. `.webview_layer = "include"|"exclude"` overrides the
//! inference — and an exclude that contradicts a web declaration is a
//! refused conflict, never a silently broken app.
//!
//! Every boundary consumes this file and feeds it the inputs that
//! boundary owns:
//!
//! - The standard build graph (build/app.zig) sees `-Dweb-engine` and
//!   `-Dweb-layer`: its resolved engine is the flag orelse app.zon, its
//!   effective layer setting is the flag orelse app.zon, and a conflict
//!   is a configure-time error.
//! - The CLI (src/tooling/manifest.zig `webLayer`/`webLayerResolved`,
//!   consumed by src/tooling/package.zig) sees `--web-engine` and the
//!   package verb's `--web-layer`: each flag beats its app.zon field the
//!   same way the `-D` options do in the build graph, and a conflict
//!   refuses the package. Both standard graph shapes (build/app.zig and
//!   the generated template's build.zig) forward their RESOLVED layer
//!   decision to `native package` as `--web-layer include|exclude`, so a
//!   graph-driven package never re-infers what the graph already decided
//!   and the packaged artifact structurally agrees with the exe.
//! - The app runner (src/app_runner/root.zig) evaluates the contract at
//!   comptime over the app.zon import. It NEVER sees the `-Dweb-engine`
//!   flag, so its engine input is the manifest's own engine: the
//!   runner's guard fires on every manifest-visible web declaration,
//!   while an engine resolved to Chromium by flag alone stays a
//!   configure-time error in the build graph, which does see the flag.

const std = @import("std");
const types = @import("types.zig");

pub const WebEngine = types.WebEngine;
pub const WebViewLayer = types.WebViewLayer;

/// A web declaration: one reason an app needs the embedded web layer.
/// Scanning stops at the first hit, in this order, so teaching messages
/// stay deterministic.
pub const Declaration = enum {
    frontend,
    capability,
    shell_webview,
    chromium_engine,
    /// Not a manifest field: a lenient parse (the build graph reading
    /// app.zon it may not fully understand) could not read the manifest
    /// at all. Absence of proof is not proof of a native-only app, so an
    /// unreadable manifest counts as a web declaration — over-inclusion
    /// costs binary size, a wrong exclusion breaks declared webviews.
    unreadable_manifest,

    /// The teaching-message half of a declaration, shared so every
    /// boundary names the same cause the same way.
    pub fn text(self: Declaration) []const u8 {
        return switch (self) {
            .frontend => "a .frontend block",
            .capability => "the \"webview\" capability",
            .shell_webview => "a .shell webview view",
            .chromium_engine => "the Chromium web engine",
            .unreadable_manifest => "an app.zon the build graph could not parse",
        };
    }

    fn reason(self: Declaration) Reason {
        return switch (self) {
            .frontend => .frontend,
            .capability => .capability,
            .shell_webview => .shell_webview,
            .chromium_engine => .chromium_engine,
            .unreadable_manifest => .unreadable_manifest,
        };
    }
};

/// Why the web layer is (or is not) in the build, for verdict lines.
pub const Reason = enum {
    inferred_native_only,
    declared_exclude,
    capability,
    frontend,
    shell_webview,
    chromium_engine,
    declared_include,
    unreadable_manifest,
};

pub const Decision = struct {
    enabled: bool,
    reason: Reason,
};

pub const Error = error{WebViewLayerConflict};

/// The decision half of the contract: `include` forces the layer on,
/// `auto` infers it from the declarations, and `exclude` promises a
/// native-only app — so an exclude alongside any web declaration is a
/// contradiction this returns as an error for the boundary to report,
/// never resolved silently in either direction.
pub fn decide(setting: WebViewLayer, declaration: ?Declaration) Error!Decision {
    return switch (setting) {
        .include => .{ .enabled = true, .reason = .declared_include },
        .exclude => if (declaration != null) error.WebViewLayerConflict else .{ .enabled = false, .reason = .declared_exclude },
        .auto => if (declaration) |value| .{ .enabled = true, .reason = value.reason() } else .{ .enabled = false, .reason = .inferred_native_only },
    };
}

/// The full inference over manifest-shaped data plus the resolved
/// engine and the effective layer setting (override orelse manifest).
pub fn infer(manifest: anytype, resolved_engine: WebEngine, setting: WebViewLayer) Error!Decision {
    return decide(setting, webDeclaration(manifest, resolved_engine));
}

/// The first web declaration for a build: the manifest scan, then the
/// RESOLVED engine. Boundaries that resolve an engine flag pass the
/// resolved value; boundaries without one (validation, the runner) pass
/// the manifest's own engine.
pub fn webDeclaration(manifest: anytype, resolved_engine: WebEngine) ?Declaration {
    return foldEngine(manifestDeclaration(manifest), resolved_engine);
}

/// Fold the resolved engine into an already-computed manifest scan, for
/// boundaries (the build graph) that scan at parse time and resolve the
/// engine later.
pub fn foldEngine(declaration: ?Declaration, resolved_engine: WebEngine) ?Declaration {
    if (declaration) |value| return value;
    return if (resolved_engine == .chromium) .chromium_engine else null;
}

/// The manifest half of the scan, duck-typed so every boundary feeds
/// the shape it has: the runner's comptime app.zon import (fields may
/// be absent, lists are tuples), a lenient build-graph parse and the
/// CLI's parsed metadata (string kinds, slice lists), and the typed
/// `Manifest` (Capability unions, ViewKind enums). The engine is NOT
/// part of this scan — pass the resolved engine to `webDeclaration`.
pub fn manifestDeclaration(manifest: anytype) ?Declaration {
    if (declaresFrontend(manifest)) return .frontend;
    if (declaresWebviewCapability(manifest)) return .capability;
    if (declaresShellWebviewView(manifest)) return .shell_webview;
    return null;
}

pub fn parseWebEngine(value: []const u8) ?WebEngine {
    if (std.mem.eql(u8, value, "system")) return .system;
    if (std.mem.eql(u8, value, "chromium")) return .chromium;
    return null;
}

pub fn parseWebViewLayer(value: []const u8) ?WebViewLayer {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "include")) return .include;
    if (std.mem.eql(u8, value, "exclude")) return .exclude;
    return null;
}

fn declaresFrontend(manifest: anytype) bool {
    if (comptime !@hasField(@TypeOf(manifest), "frontend")) return false;
    const frontend = manifest.frontend;
    const T = @TypeOf(frontend);
    if (comptime T == @TypeOf(null)) return false;
    if (comptime @typeInfo(T) == .optional) return frontend != null;
    // A ZON `.frontend = .{ ... }` block: present means declared.
    return true;
}

fn declaresWebviewCapability(manifest: anytype) bool {
    if (comptime !@hasField(@TypeOf(manifest), "capabilities")) return false;
    return anyElement(manifest.capabilities, isWebviewName);
}

fn declaresShellWebviewView(manifest: anytype) bool {
    if (comptime !@hasField(@TypeOf(manifest), "shell")) return false;
    const shell = manifest.shell;
    if (comptime !@hasField(@TypeOf(shell), "windows")) return false;
    return anyElement(shell.windows, windowHasWebviewView);
}

fn windowHasWebviewView(window: anytype) bool {
    if (comptime !@hasField(@TypeOf(window), "views")) return false;
    return anyElement(window.views, viewIsWebview);
}

fn viewIsWebview(view: anytype) bool {
    if (comptime !@hasField(@TypeOf(view), "kind")) return false;
    return isWebviewName(view.kind);
}

/// Whether a capability or view kind names the webview: an enum tag
/// (`ViewKind`), a tagged-union tag (`Capability`), or string data (the
/// ZON import and parsed-metadata shapes).
fn isWebviewName(value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .@"enum" => value == .webview,
        .@"union" => std.meta.activeTag(value) == .webview,
        else => std.mem.eql(u8, value, "webview"),
    };
}

/// Whether any element of `list` matches. Slices and arrays iterate at
/// runtime; ZON tuples iterate inline so the whole scan stays usable in
/// the runner's comptime evaluation.
fn anyElement(list: anytype, comptime match: anytype) bool {
    switch (@typeInfo(@TypeOf(list))) {
        .pointer, .array => {
            for (list) |element| {
                if (match(element)) return true;
            }
            return false;
        },
        .@"struct" => |info| {
            if (comptime info.fields.len == 0) return false;
            inline for (list) |element| {
                if (match(element)) return true;
            }
            return false;
        },
        else => return false,
    }
}

// ---------------------------------------------------------------------------
// Contract matrix: every boundary shape, every inference row.
// ---------------------------------------------------------------------------

/// The typed-Manifest shape (what validation.zig scans).
const typed = struct {
    const webview_capability = [_]types.Capability{.webview};
    const canvas_capabilities = [_]types.Capability{ .native_views, .gpu_surfaces };
    const webview_views = [_]types.ShellView{.{ .label = "content", .kind = .webview }};
    const toolbar_views = [_]types.ShellView{.{ .label = "bar", .kind = .toolbar }};
    const webview_windows = [_]types.ShellWindow{.{ .label = "main", .views = &webview_views }};
    const toolbar_windows = [_]types.ShellWindow{.{ .label = "main", .views = &toolbar_views }};
};

/// The parsed-metadata shape (what the CLI's manifest tooling scans):
/// string kinds, slice lists, an optional frontend block.
const MetadataShape = struct {
    const View = struct { kind: []const u8 };
    const Window = struct { views: []const View = &.{} };
    capabilities: []const []const u8 = &.{},
    frontend: ?struct {} = null,
    shell: struct { windows: []const Window = &.{} } = .{},
};

test "web-layer contract matrix agrees across boundary shapes" {
    // Each row runs the scan over three shapes of the same manifest —
    // the runner's comptime ZON import (tuples, absent fields), the
    // typed Manifest, and the CLI's parsed metadata — and every shape
    // must produce the same declaration. The build graph's lenient
    // parse is the metadata shape with narrower fields, and its adapter
    // (build/app.zig resolveWebLayer) is `foldEngine` + `decide`, both
    // exercised below.

    // Canvas-only: nothing declared, native-only under auto.
    try std.testing.expectEqual(null, manifestDeclaration(.{ .capabilities = .{ "native_views", "gpu_surfaces" } }));
    try std.testing.expectEqual(null, manifestDeclaration(types.Manifest{
        .identity = .{ .id = "dev.example.canvas", .name = "canvas" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .capabilities = &typed.canvas_capabilities,
    }));
    try std.testing.expectEqual(null, manifestDeclaration(MetadataShape{ .capabilities = &.{ "native_views", "gpu_surfaces" } }));
    {
        const decision = try infer(.{}, .system, .auto);
        try std.testing.expect(!decision.enabled);
        try std.testing.expectEqual(Reason.inferred_native_only, decision.reason);
    }

    // The "webview" capability.
    try std.testing.expectEqual(Declaration.capability, manifestDeclaration(.{ .capabilities = .{"webview"} }));
    try std.testing.expectEqual(Declaration.capability, manifestDeclaration(types.Manifest{
        .identity = .{ .id = "dev.example.a", .name = "a" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .capabilities = &typed.webview_capability,
    }));
    try std.testing.expectEqual(Declaration.capability, manifestDeclaration(MetadataShape{ .capabilities = &.{"webview"} }));

    // A .frontend block.
    try std.testing.expectEqual(Declaration.frontend, manifestDeclaration(.{ .frontend = .{ .dist = "frontend/dist" } }));
    try std.testing.expectEqual(Declaration.frontend, manifestDeclaration(types.Manifest{
        .identity = .{ .id = "dev.example.b", .name = "b" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .frontend = .{},
    }));
    try std.testing.expectEqual(Declaration.frontend, manifestDeclaration(MetadataShape{ .frontend = .{} }));

    // A .shell webview view (and a webview-free shell stays native).
    try std.testing.expectEqual(Declaration.shell_webview, manifestDeclaration(.{ .shell = .{ .windows = .{.{ .views = .{.{ .kind = "webview" }} }} } }));
    try std.testing.expectEqual(Declaration.shell_webview, manifestDeclaration(types.Manifest{
        .identity = .{ .id = "dev.example.c", .name = "c" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shell = .{ .windows = &typed.webview_windows },
    }));
    try std.testing.expectEqual(Declaration.shell_webview, manifestDeclaration(MetadataShape{ .shell = .{ .windows = &.{.{ .views = &.{.{ .kind = "webview" }} }} } }));
    try std.testing.expectEqual(null, manifestDeclaration(types.Manifest{
        .identity = .{ .id = "dev.example.d", .name = "d" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shell = .{ .windows = &typed.toolbar_windows },
    }));

    // The Chromium engine is web intent wherever it was resolved: from
    // app.zon (every boundary sees it) or from a flag (`-Dweb-engine` /
    // `--web-engine`, seen by the build graph and the CLI; the runner
    // never sees flags and covers only the manifest engine — the split
    // this file's module doc pins down).
    try std.testing.expectEqual(Declaration.chromium_engine, webDeclaration(.{}, .chromium));
    try std.testing.expectEqual(Declaration.chromium_engine, foldEngine(null, .chromium));
    {
        const decision = try infer(.{}, .chromium, .auto);
        try std.testing.expect(decision.enabled);
        try std.testing.expectEqual(Reason.chromium_engine, decision.reason);
    }

    // A vestigial explicit `.web_engine = "system"` is NOT web intent.
    try std.testing.expectEqual(null, webDeclaration(.{ .web_engine = "system" }, .system));
    try std.testing.expectEqual(WebEngine.system, parseWebEngine("system"));

    // Explicit overrides win in both directions.
    {
        const included = try infer(.{}, .system, .include);
        try std.testing.expect(included.enabled);
        try std.testing.expectEqual(Reason.declared_include, included.reason);
        const excluded = try infer(.{}, .system, .exclude);
        try std.testing.expect(!excluded.enabled);
        try std.testing.expectEqual(Reason.declared_exclude, excluded.reason);
    }

    // Exclude + any web declaration is a refused conflict — including
    // an engine resolved to Chromium with a web-free manifest.
    try std.testing.expectError(error.WebViewLayerConflict, infer(.{ .capabilities = .{"webview"} }, .system, .exclude));
    try std.testing.expectError(error.WebViewLayerConflict, infer(.{}, .chromium, .exclude));
    try std.testing.expectError(error.WebViewLayerConflict, decide(.exclude, .unreadable_manifest));

    // The package boundary's forwarded resolution: the build graphs hand
    // `native package` their computed decision as `--web-layer
    // include|exclude`, and replaying that setting through `decide` must
    // reproduce the same enabled-ness for every row the graph can reach
    // — forwarding the resolution is lossless, so the exe and the
    // package it lands in can never disagree about the web layer.
    const forward_settings = [_]WebViewLayer{ .auto, .include, .exclude };
    const forward_declarations = [_]?Declaration{ null, .capability, .chromium_engine };
    for (forward_settings) |setting| {
        for (forward_declarations) |declaration| {
            // A refused conflict never configures, so the graph has
            // nothing to forward for that row.
            const original = decide(setting, declaration) catch continue;
            const replayed = try decide(if (original.enabled) .include else .exclude, declaration);
            try std.testing.expectEqual(original.enabled, replayed.enabled);
        }
    }

    // The runner's comptime evaluation: the same scan over a ZON-import
    // shape, forced through comptime.
    comptime {
        if (manifestDeclaration(.{ .capabilities = .{ "native_views", "gpu_surfaces" } }) != null) @compileError("canvas manifest must scan native-only");
        if (manifestDeclaration(.{ .capabilities = .{"webview"} }) != Declaration.capability) @compileError("webview capability must scan as a declaration");
        if (webDeclaration(.{ .web_engine = "chromium" }, parseWebEngine("chromium").?) != Declaration.chromium_engine) @compileError("manifest chromium engine must scan as a declaration");
    }
}

test "web-layer declarations carry the shared teaching text" {
    try std.testing.expectEqualStrings("a .frontend block", Declaration.frontend.text());
    try std.testing.expectEqualStrings("the \"webview\" capability", Declaration.capability.text());
    try std.testing.expectEqualStrings("a .shell webview view", Declaration.shell_webview.text());
    try std.testing.expectEqualStrings("the Chromium web engine", Declaration.chromium_engine.text());
}
