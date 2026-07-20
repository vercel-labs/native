//! Registry integrity: the laws that make ui_schema.zig's codes safe to
//! persist. Uniqueness and nonzero-ness are enforced at comptime inside
//! the registry itself; these tests pin STABILITY — a code, once
//! assigned, is never renumbered and its name is never respelled, because
//! serialized documents, document hashes, and structural ids reference
//! codes (and the version rules treat a rename as a semantic change).

const std = @import("std");
const schema = @import("ui_schema.zig");
const testing = std.testing;

// The fingerprint definition lives in the registry itself
// (schema.tableFingerprint) so this test and `zig build print-pins`
// share one statement of it.
const tableFingerprint = schema.tableFingerprint;

test "registry codes are stable: assigned at birth, never renumbered or renamed" {
    // If one of these fingerprints changed, an EXISTING entry was
    // renumbered, renamed, or removed. Codes are what serialized
    // documents and hashes reference: add new entries under fresh codes
    // (append or slot them anywhere — order carries no meaning) and pin
    // the new fingerprint ONLY for additions; renames/renumbers are
    // schema-version-bump events, not silent edits.
    try testing.expectEqual(@as(usize, 67), schema.elements.len);
    try testing.expectEqual(@as(usize, 81), schema.attrs.len);
    try testing.expectEqual(@as(usize, 10), schema.events.len);
    // The element table runs through the span composite (64), the
    // bubble-reactions composite (65), the media surface (66), and the
    // runtime-image leaf (67).
    try testing.expectEqual(
        @as(u64, 0x2a68661a562f0565),
        tableFingerprint(schema.ElementInfo, &schema.elements),
    );
    // The attr table runs through the split layout-tween attributes
    // resize-duration (71) and resize-easing (72), the chart axis/hover
    // attributes x-labels (73), y-labels (74), and hover-details (75),
    // the later span additions scale (76) and underline (77), the
    // split enter-from attribute resize-origin (78), the quiet-surface
    // hover knob quiet-hover (79), the anchored-tooltip hover-intent
    // delay tooltip-delay (80), and the media-surface producer
    // rendezvous surface (81).
    try testing.expectEqual(
        @as(u64, 0x046479d29c4f0c5e),
        tableFingerprint(schema.AttrInfo, &schema.attrs),
    );
    try testing.expectEqual(
        @as(u64, 0x5c2d94636ea4cf1a),
        tableFingerprint(schema.EventInfo, &schema.events),
    );
}

test "registry lookups resolve by name and by code" {
    const button = schema.elementByName("button").?;
    try testing.expectEqual(@as(u16, 29), button.code);
    try testing.expect(schema.elementByCode(29).? == button);
    try testing.expect(button.takes_text and button.icon_attr and button.hit_target);

    const gap = schema.attrByName("gap").?;
    try testing.expectEqual(schema.ValueClass.number, gap.class);
    try testing.expect(schema.attrByCode(gap.code).? == gap);

    const scroll = schema.eventByName("scroll").?;
    try testing.expectEqual(schema.EventPayload.scroll_state, scroll.payload);
    try testing.expectEqualStrings("scroll", scroll.only_on_element.?);
    try testing.expect(schema.eventByCode(scroll.code).? == scroll);

    try testing.expect(schema.elementByName("not-an-element") == null);
    try testing.expect(schema.elementByCode(0) == null);
    try testing.expect(schema.attrByCode(0) == null);
    try testing.expect(schema.eventByCode(0) == null);
}

test "registry composites carry rule hooks and no widget kind; plain elements the reverse" {
    for (schema.elements) |entry| {
        if (entry.rule_hook != null) {
            try testing.expectEqual(@as(usize, 0), entry.widget_kind.len);
        } else {
            try testing.expect(entry.widget_kind.len > 0);
        }
    }
}

test "registry event scoping names registry elements" {
    for (schema.events) |entry| {
        if (entry.only_on_element) |element_name| {
            try testing.expect(schema.elementByName(element_name) != null);
        }
    }
}

test "derived name lists mirror the registry" {
    // The derivations are the vocabulary every consumer reads; hold them
    // to the registry's own predicates.
    try testing.expectEqual(@as(usize, 55), schema.element_names.len);
    for (schema.element_names) |name| {
        try testing.expect(schema.elementByName(name).?.rule_hook == null);
    }
    for (schema.text_leaf_element_names) |name| {
        try testing.expect(schema.elementByName(name).?.takes_text);
    }
    for (schema.text_or_children_element_names) |name| {
        const entry = schema.elementByName(name).?;
        // The flag refines a text leaf; it never stands alone.
        try testing.expect(entry.takes_children and entry.takes_text);
    }
    for (schema.non_hit_target_element_names) |name| {
        try testing.expect(!schema.elementByName(name).?.hit_target);
    }
    for (schema.stack_container_element_names) |name| {
        try testing.expect(schema.elementByName(name).?.stacks_children);
    }
    for (schema.dismiss_element_names) |name| {
        try testing.expect(schema.elementByName(name).?.dismissible);
    }
    for (schema.option_attr_names) |name| {
        try testing.expectEqual(schema.AttrGroup.option, schema.attrByName(name).?.group);
    }
    for (schema.rendered_text_attr_names) |name| {
        try testing.expect(schema.attrByName(name).?.rendered_text);
    }
    try testing.expectEqual(schema.events.len, schema.event_names.len);
    for (schema.event_names, 0..) |name, index| {
        try testing.expectEqualStrings(schema.events[index].name, name);
    }
    for (schema.option_field_pairs) |pair| {
        const entry = schema.attrByName(pair.markup).?;
        try testing.expectEqualStrings(entry.field, pair.zig);
        try testing.expect(entry.field.len > 0);
    }
}
