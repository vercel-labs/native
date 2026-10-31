//! Provenance for a compiled TypeScript view built for markup reload: the
//! decoder stamps each widget with where it was authored, and the response
//! the `provenance` verb writes is the one the native markup interpreter
//! writes for the same markup and model, ids included. Write-back then
//! edits the authored element from that span.
const std = @import("std");
const sdk = @import("native_sdk");
const canvas = sdk.canvas;
const core = @import("view_reload_core");
const decoder = @import("view_reload_decoder");
const Table = sdk.runtime.testing.markup_provenance.ProvenanceTable;

const Ui = canvas.Ui(core.Msg);
const source = @embedFile("view_reload/app.native");

fn ids(widget: canvas.Widget, out: *std.ArrayListUnmanaged(u64), arena: std.mem.Allocator) !void {
    try out.append(arena, widget.id);
    for (widget.children) |child| try ids(child, out, arena);
}

fn response(table: *const Table, id: u64, buffer: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try table.writeResponse(&writer, "view-reload-canvas", id);
    return writer.buffered();
}

/// The `span=a..b` start of the response's `node` line.
fn spanStart(text: []const u8) !usize {
    const node = text[std.mem.indexOf(u8, text, "\nnode ").?..];
    const at = std.mem.indexOf(u8, node, " span=").? + " span=".len;
    return std.fmt.parseUnsigned(usize, node[at..std.mem.indexOfPos(u8, node, at, "..").?], 10);
}

test "a reloading compiled view reports the interpreter's provenance and drives write-back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = core.initialModel();
    defer core.rt.frameReset();
    const hash = std.hash.Wyhash.hash(0, source);

    // The native markup interpreter over the same markup and committed model.
    const reference = try std.testing.allocator.create(Table);
    defer std.testing.allocator.destroy(reference);
    reference.* = .{ .allocator = std.testing.allocator };
    try reference.addFile("", "src/app.native", hash);
    reference.watching = true;
    var view = try canvas.MarkupView(core.Model, core.Msg).init(arena, source);
    var reference_ui = Ui.init(arena);
    reference_ui.provenance_sink = reference.sink();
    const interpreted = try reference_ui.finalize(try view.build(&reference_ui, core.snapshotModel()));

    // The compiled view: the decoder names the files, as the app commits them.
    const compiled_table = try std.testing.allocator.create(Table);
    defer std.testing.allocator.destroy(compiled_table);
    compiled_table.* = .{ .allocator = std.testing.allocator };
    var compiled_ui = Ui.init(arena);
    compiled_ui.provenance_sink = compiled_table.sink();
    const runtime_model: core.RuntimeModel = .{};
    const root = decoder.buildRuntime(&compiled_ui, &runtime_model);
    compiled_table.resetFiles();
    compiled_table.watching = true;
    const files = sdk.view_reload.view_files[0..sdk.view_reload.view_files_len];
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("", files[0].stamped);
    try std.testing.expectEqualStrings("src/app.native", files[0].disk);
    // The build hashed the bytes it compiled exactly as write-back hashes the file.
    try std.testing.expectEqual(hash, files[0].hash);
    for (files) |file| try compiled_table.addFile(file.stamped, file.disk, file.hash);
    const compiled = try compiled_ui.finalize(root);

    var interpreted_ids: std.ArrayListUnmanaged(u64) = .empty;
    var compiled_ids: std.ArrayListUnmanaged(u64) = .empty;
    try ids(interpreted.root, &interpreted_ids, arena);
    try ids(compiled.root, &compiled_ids, arena);
    try std.testing.expectEqualSlices(u64, interpreted_ids.items, compiled_ids.items);
    try std.testing.expectEqual(reference.records_len, compiled_table.records_len);
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    var templated = false;
    var looped = false;
    for (compiled_ids.items) |id| {
        const expected = try response(reference, id, &a);
        const actual = try response(compiled_table, id, &b);
        try std.testing.expectEqualStrings(expected, actual);
        templated = templated or std.mem.indexOf(u8, actual, "\nuse ") != null;
        looped = looped or std.mem.indexOf(u8, actual, "keys=") != null and std.mem.indexOf(u8, actual, "keys=\n") == null;
    }
    try std.testing.expect(templated and looped);

    // Write-back: set the button's text through the span the compiled view reported.
    const button = blk: {
        for (compiled.root.children) |child| if (child.kind == .button) break :blk child.id;
        return error.NoButton;
    };
    const button_response = try response(compiled_table, button, &b);
    try std.testing.expect(std.mem.indexOf(u8, button_response, "authored=markup watching=true root=src/app.native") != null);
    var diagnostic: canvas.ui_markup.MarkupErrorInfo = .{};
    const edited = try canvas.ui_markup.edit.applyChecked(arena, source, try spanStart(button_response), .{ .set_text = .{ .text = "Plus" } }, &diagnostic);
    try std.testing.expect(std.mem.indexOf(u8, edited, "<button on-press=\"increment\">Plus</button>") != null);
    try std.testing.expectEqual(source.len - "Add".len + "Plus".len, edited.len);
}
