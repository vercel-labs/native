//! Widget-identity proofs for the ejectable components.
//!
//! `native eject component <name>` copies the canonical sources next to
//! this file into an app. These tests are what keeps those copies
//! precisely: each builds the ejected form and the library form against
//! the same inputs and requires the two widget trees to be IDENTICAL —
//! every id, every field, every handler — so ejecting is never a visual
//! or behavioral change, only an ownership change. A library refactor
//! that drifts a composite's tree fails here until the canonical source
//! is updated to match.
//!
//! This file is its own test module (wired in build.zig as
//! `test-eject-components`, part of `zig build test`) because the
//! canonical Zig sources import `native_sdk` exactly as they will
//! inside an app — compiling them verbatim is half the proof.

const std = @import("std");
const testing = std.testing;
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;

const stepper_template = @embedFile("stepper.native");
const timeline_item_template = @embedFile("timeline-item.native");
const timeline_template = @embedFile("timeline.native");

/// A stand-in app model/message pair: the composites under test bind no
/// model state themselves (their inputs arrive as options/args), so an
/// empty model and one payload-carrying message tag cover the surface.
const Model = struct {};
const Msg = union(enum) { open: u32 };
const Ui = canvas.Ui(Msg);

test "ejected stepper markup builds the library stepper's exact tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const labels = [_][]const u8{ "Plan", "Work", "Ship" };
    // Every derived step state in one sweep: active in range (mixed
    // completed/active/pending), zero (nothing completed), and past the
    // end (everything completed).
    for ([_]usize{ 1, 0, labels.len }) |active| {
        var library_ui = Ui.init(arena);
        const library_steps = [_]Ui.StepperStep{
            .{ .label = labels[0] }, .{ .label = labels[1] }, .{ .label = labels[2] },
        };
        const library_tree = try library_ui.finalize(library_ui.stepper(.{
            .active = active,
            .key = canvas.uiKey("pipeline"),
            .global_key = canvas.uiKey("pipeline-global"),
            .semantics = .{ .label = "Pipeline" },
        }, &library_steps));

        const active_text = if (active == 0) "0" else if (active == 1) "1" else "3";
        const source = "<import src=\"components/stepper.native\"/>\n<use template=\"stepper\" active=\"" ++ active_text ++ "\" key=\"pipeline\" global_key=\"pipeline-global\" label=\"Pipeline\">" ++
            "<step>Plan</step><step>Work</step><step>Ship</step></use>";
        const files = [_]canvas.ui_markup.SourceFile{.{ .path = "components/stepper.native", .source = stepper_template }};
        var ejected_ui = Ui.init(arena);
        const ejected_tree = try buildMarkupTree(arena, &ejected_ui, source, &files);

        try testing.expectEqualDeep(library_tree.root, ejected_tree.root);
        try testing.expectEqualDeep(library_tree.handlers, ejected_tree.handlers);
    }
}

test "ejected stepper defaults preserve the library's unkeyed identity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = "<import src=\"components/stepper.native\"/>\n<use template=\"stepper\" active=\"1\"><step>Plan</step><step>Ship</step></use>";
    const files = [_]canvas.ui_markup.SourceFile{.{ .path = "components/stepper.native", .source = stepper_template }};
    var library_ui = Ui.init(arena);
    const labels = [_]Ui.StepperStep{ .{ .label = "Plan" }, .{ .label = "Ship" } };
    const library_tree = try library_ui.finalize(library_ui.stepper(.{ .active = 1 }, &labels));
    var ejected_ui = Ui.init(arena);
    const ejected_tree = try buildMarkupTree(arena, &ejected_ui, source, &files);
    try testing.expectEqualDeep(library_tree.root, ejected_tree.root);
}

test "ejected timeline-item markup builds the library item's exact tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The full visual shape: indicator variant, description, meta,
    // connector, and selection. The built-in element remains the typed
    // event boundary; template values do not invent callback values.
    var library_ui = Ui.init(arena);
    const library_tree = try library_ui.finalize(library_ui.timelineItem(.{
        .key = canvas.uiKey("item"),
        .global_key = canvas.uiKey("item-global"),
        .icon = "check",
        .variant = .primary,
        .title = "Build the release",
        .description = "Compile, test, and package the app",
        .meta = "2m 14s",
        .selected = true,
    }));

    const source = "<import src=\"components/timeline-item.native\"/>\n<use template=\"timeline-item\" title=\"Build the release\" description=\"Compile, test, and package the app\" meta=\"2m 14s\" icon=\"check\" variant=\"primary\" selected=\"true\" key=\"item\" global_key=\"item-global\" />";
    const files = [_]canvas.ui_markup.SourceFile{.{ .path = "components/timeline-item.native", .source = timeline_item_template }};
    var ejected_ui = Ui.init(arena);
    const ejected_tree = try buildMarkupTree(arena, &ejected_ui, source, &files);

    try testing.expectEqualDeep(library_tree.root, ejected_tree.root);
    try testing.expectEqualDeep(library_tree.handlers, ejected_tree.handlers);
    // The minimal shape: dot indicator (no badge content), title only,
    // no connector, no press — the other half of every conditional.
    var minimal_library_ui = Ui.init(arena);
    const minimal_library = try minimal_library_ui.finalize(minimal_library_ui.timelineItem(.{
        .title = "Queued",
        .connector = false,
    }));
    const minimal_source = "<import src=\"components/timeline-item.native\"/>\n<use template=\"timeline-item\" title=\"Queued\" connector=\"false\" />";
    const minimal_files = [_]canvas.ui_markup.SourceFile{.{ .path = "components/timeline-item.native", .source = timeline_item_template }};
    var minimal_ejected_ui = Ui.init(arena);
    const minimal_ejected = try buildMarkupTree(arena, &minimal_ejected_ui, minimal_source, &minimal_files);
    try testing.expectEqualDeep(minimal_library.root, minimal_ejected.root);
    try testing.expectEqualDeep(minimal_library.handlers, minimal_ejected.handlers);
}

/// Build a markup view over the test Model through the interpreter,
/// resolving imports from an embedded source set (the same loader shape
/// apps use for their import closures).
fn buildMarkupTree(arena: std.mem.Allocator, ui: *Ui, root_source: []const u8, files: []const canvas.ui_markup.SourceFile) !Ui.Tree {
    var set_loader = canvas.ui_markup.SourceSetLoader{ .set = files };
    var diagnostic: canvas.ui_markup.MarkupErrorInfo = .{};
    const document = canvas.ui_markup.resolveImports(arena, "app.native", root_source, set_loader.loader(), &diagnostic) catch |err| {
        std.debug.print("markup resolve failed: {s} ({s}:{d}:{d})\n", .{ diagnostic.message, diagnostic.path, diagnostic.line, diagnostic.column });
        return err;
    };
    var interpreter = canvas.MarkupView(Model, Msg).fromDocument(try canvas.ui_markup.canonicalize(arena, document));
    var model = Model{};
    return ui.finalize(try interpreter.build(ui, &model));
}

test "the ejected timeline template builds the library <timeline> element's exact tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Identical item children on both sides; only the container differs:
    // the built-in element versus the ejected template reached through
    // <use> (which inlines its body, so ids hash as if written in place).
    const items =
        \\  <timeline-item title="Cloned" description="Fetched the sources" icon="check" variant="primary" />
        \\  <timeline-item title="Building" meta="just now" connector="false" />
        \\
    ;
    const element_source = "<timeline gap=\"4\" label=\"Activity\" key=\"ledger\" global-key=\"ledger-global\">\n" ++ items ++ "</timeline>\n";
    const template_source = "<import src=\"components/timeline.native\"/>\n" ++
        "<use template=\"timeline\" gap=\"4\" label=\"Activity\" key=\"ledger\" global_key=\"ledger-global\">\n" ++ items ++ "</use>\n";
    const files = [_]canvas.ui_markup.SourceFile{
        .{ .path = "components/timeline.native", .source = timeline_template },
    };

    var element_ui = Ui.init(arena);
    const element_tree = try buildMarkupTree(arena, &element_ui, element_source, &files);
    var template_ui = Ui.init(arena);
    const template_tree = try buildMarkupTree(arena, &template_ui, template_source, &files);

    try testing.expectEqualDeep(element_tree.root, template_tree.root);
    try testing.expectEqualDeep(element_tree.handlers.len, template_tree.handlers.len);
    // Spot-check the facts the deep compare rests on: the container is
    // the list-role column the library builds, at the declared gap.
    try testing.expectEqual(canvas.WidgetKind.column, template_tree.root.kind);
    try testing.expectEqual(canvas.WidgetRole.list, template_tree.root.semantics.role);
    try testing.expectEqual(@as(f32, 4), template_tree.root.layout.gap);
    try testing.expectEqualStrings("Activity", template_tree.root.semantics.label);
    try testing.expectEqual(@as(usize, 2), template_tree.root.children.len);
}

test "the ejected timeline template's defaults match the library element's defaults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = "<timeline-item title=\"Only\" connector=\"false\" />";
    const element_source = "<timeline>" ++ items ++ "</timeline>";
    const template_source = "<import src=\"components/timeline.native\"/>\n" ++
        "<use template=\"timeline\">" ++ items ++ "</use>";
    const files = [_]canvas.ui_markup.SourceFile{
        .{ .path = "components/timeline.native", .source = timeline_template },
    };

    var element_ui = Ui.init(arena);
    const element_tree = try buildMarkupTree(arena, &element_ui, element_source, &files);
    var template_ui = Ui.init(arena);
    const template_tree = try buildMarkupTree(arena, &template_ui, template_source, &files);

    try testing.expectEqualDeep(element_tree.root, template_tree.root);
}
