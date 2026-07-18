//! Compile-cost guard: a deliberately huge `.native` document — well past
//! 16KB of realistically nested markup — must build through the compiled
//! engine without the test (or any app) raising `@setEvalBranchQuota`.
//! Before the fix, `canonicalizeComptime` sized its quota by recursively
//! measuring the tree INSIDE the quota argument, which evaluates under the
//! caller's default 1000-backwards-branch budget — so any document past
//! ~10KB failed to compile with "evaluation exceeded 1000 backwards
//! branches" while the runtime interpreter handled it fine. The document
//! now carries `source_bytes` from parse/resolve time (O(1) to read);
//! this fixture is the regression tripwire for the single-file path, and
//! the import fixture below pins the resolver's size accounting (the
//! merged document's `source_bytes` must cover imported template trees,
//! not just the root file).

const std = @import("std");
const canvas = @import("root.zig");
const compiled_view = @import("ui_markup_compiled.zig");

const Item = struct {
    id: u32,
    name: []const u8,
};

const Model = struct {
    title: []const u8 = "ops console",
    count: u32 = 3,
    items: []const Item = &.{},
};

const Msg = union(enum) {
    refresh,
    press: u32,
};

/// One realistic dashboard section, ~560 bytes of markup: a header row
/// with an interpolated title, a conditional status line, and a keyed-off
/// item list with per-item dispatch. Repeated enough times to put the
/// whole source safely past the old ~10KB comptime cliff.
fn sectionSource(comptime index: usize) []const u8 {
    return std.fmt.comptimePrint(
        \\  <panel padding="12">
        \\    <row gap="8" cross="center">
        \\      <badge radius="md">Section {d}</badge>
        \\      <text grow="1">{{title}} - block {d} of the oversized regression document, padded with realistic prose so the source passes the old comptime measurement cliff.</text>
        \\      <button size="sm" on-press="refresh">Reload</button>
        \\    </row>
        \\    <if test="{{count}}">
        \\      <text>block {d} has {{count}} pending updates</text>
        \\    </if>
        \\    <for each="items" as="it">
        \\      <row gap="6" cross="center">
        \\        <text grow="1">{{it.name}}</text>
        \\        <button size="sm" on-press="press:{{it.id}}">Open</button>
        \\      </row>
        \\    </for>
        \\  </panel>
        \\
    , .{ index, index, index });
}

fn hugeSource(comptime sections: usize) []const u8 {
    comptime {
        // Quota for the fixture GENERATOR only (comptime string
        // concatenation over ~20KB); the engine under test must get by on
        // its own derived quotas.
        @setEvalBranchQuota(1_000_000);
        var source: []const u8 = "<column gap=\"8\">\n  <text>{title}</text>\n";
        for (0..sections) |index| {
            source = source ++ sectionSource(index);
        }
        return source ++ "</column>\n";
    }
}

const huge_source = hugeSource(36);

fn testItems() []const Item {
    return &.{ .{ .id = 1, .name = "alpha" }, .{ .id = 2, .name = "beta" } };
}

test "a 16KB+ document compiles through the compiled engine without raising the eval-branch quota" {
    try std.testing.expect(huge_source.len >= 16_000);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ui = canvas.Ui(Msg).init(arena);
    const model: Model = .{ .items = testItems() };
    const tree = try ui.finalize(compiled_view.CompiledMarkupView(Model, Msg, huge_source).build(&ui, &model));

    // The whole document rendered: every section's badge, per-item
    // dispatch from the last section's list, and the conditional branch.
    var badges: usize = 0;
    countKind(tree.root, .badge, &badges);
    try std.testing.expectEqual(@as(usize, 36), badges);
    var buttons: usize = 0;
    countKind(tree.root, .button, &buttons);
    try std.testing.expectEqual(@as(usize, 36 + 36 * 2), buttons);
}

/// A component file carrying one huge template body. The root view is
/// tiny, so if import resolution failed to count imported sources into
/// the merged document's `source_bytes`, the canonicalize walk over the
/// spliced template tree would outrun its quota and this file would not
/// compile.
fn hugeTemplateSource(comptime rows: usize) []const u8 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var source: []const u8 = "<template name=\"big-panel\" args=\"heading\">\n  <column gap=\"4\">\n";
        for (0..rows) |index| {
            source = source ++ std.fmt.comptimePrint(
                \\    <row gap="6" cross="center">
                \\      <badge radius="md">{{heading}} {d}</badge>
                \\      <text grow="1">imported row {d}, padded with enough literal prose that the imported file alone crosses the old comptime measurement cliff.</text>
                \\    </row>
                \\
            , .{ index, index });
        }
        return source ++ "  </column>\n</template>\n";
    }
}

const huge_import_sources = [_]canvas.ui_markup.SourceFile{
    .{ .path = "view.native", .source =
    \\<import src="components/big.native"/>
    \\<column gap="8">
    \\  <use template="big-panel" heading="Imported" />
    \\</column>
    },
    .{ .path = "components/big.native", .source = hugeTemplateSource(72) },
};

test "a large imported template compiles through the compiled engine's import resolution" {
    try std.testing.expect(huge_import_sources[1].source.len >= 16_000);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Compiled = canvas.CompiledMarkupImports(Model, Msg, "view.native", &huge_import_sources);
    var ui = canvas.Ui(Msg).init(arena);
    const model: Model = .{};
    const tree = try ui.finalize(Compiled.build(&ui, &model));

    var badges: usize = 0;
    countKind(tree.root, .badge, &badges);
    try std.testing.expectEqual(@as(usize, 72), badges);
}

fn countKind(widget: canvas.Widget, kind: canvas.WidgetKind, total: *usize) void {
    if (widget.kind == kind) total.* += 1;
    for (widget.children) |child| countKind(child, kind, total);
}
