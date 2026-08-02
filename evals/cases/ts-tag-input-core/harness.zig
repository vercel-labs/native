//! Behavioral harness for ts-tag-input-core. The grader copies this next to
//! the transpiled core.zig and the rt kernel, then runs `zig test harness.zig`.
//! Asserts the byte-level parsing semantics from the prompt: comma split,
//! space trim, empty drop, case-insensitive dedupe, ordered append, draft
//! clearing, and removal by id.

const std = @import("std");
const core = @import("core.zig");
const rt = core.rt;

fn freshModel() *const core.Model {
    rt.resetAll();
    const committed = core.commitModelRoot(core.initialModel());
    rt.frameReset();
    return committed;
}

fn dispatch(model: *const core.Model, msg: core.Msg) *const core.Model {
    const next = core.update(model, msg);
    const committed = core.commitModelRoot(next);
    rt.frameReset();
    return committed;
}

fn submitText(model: *const core.Model, text: []const u8) *const core.Model {
    const after_edit = dispatch(model, .{ .draft_edit = text });
    return dispatch(after_edit, .submit);
}

test "starts empty" {
    const model = freshModel();
    try std.testing.expect(model.tags.len == 0);
    try std.testing.expect(model.draft.len == 0);
    try std.testing.expect(core.tagCount(model) == 0);
}

test "submit splits on commas, trims spaces, drops empties, keeps order and casing" {
    var model = freshModel();
    model = submitText(model, "alpha, Beta ,,   gamma  ");
    try std.testing.expect(core.tagCount(model) == 3);
    try std.testing.expect(std.mem.eql(u8, model.tags[0].name, "alpha"));
    try std.testing.expect(std.mem.eql(u8, model.tags[1].name, "Beta"));
    try std.testing.expect(std.mem.eql(u8, model.tags[2].name, "gamma"));
    try std.testing.expect(model.draft.len == 0);
    // Fresh, distinct ids.
    try std.testing.expect(model.tags[0].id != model.tags[1].id);
    try std.testing.expect(model.tags[1].id != model.tags[2].id);
    try std.testing.expect(model.tags[0].id != model.tags[2].id);
}

test "dedupe is case-insensitive, against existing tags and within one submit" {
    var model = freshModel();
    model = submitText(model, "alpha, Beta");
    model = submitText(model, "ALPHA, delta, DELTA, beta");
    try std.testing.expect(core.tagCount(model) == 3);
    try std.testing.expect(std.mem.eql(u8, model.tags[2].name, "delta"));
}

test "submitting only separators and spaces clears the draft and adds nothing" {
    var model = freshModel();
    model = submitText(model, " , ,   ");
    try std.testing.expect(core.tagCount(model) == 0);
    try std.testing.expect(model.draft.len == 0);
}

test "hasTag matches case-insensitively; remove deletes exactly one tag" {
    var model = freshModel();
    model = submitText(model, "alpha, Beta, gamma");
    try std.testing.expect(core.hasTag(model, "beta"));
    try std.testing.expect(core.hasTag(model, "ALPHA"));
    try std.testing.expect(!core.hasTag(model, "zeta"));

    const first = model.tags[0].id;
    model = dispatch(model, .{ .remove = first });
    try std.testing.expect(core.tagCount(model) == 2);
    try std.testing.expect(!core.hasTag(model, "alpha"));
    try std.testing.expect(core.hasTag(model, "gamma"));
}
