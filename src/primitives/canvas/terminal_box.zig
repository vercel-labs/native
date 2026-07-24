//! Geometric box-drawing: U+2500-259F synthesized as rects, lines, and
//! arcs at EXACT cell bounds, the way dedicated terminals render them.
//! Font glyphs are sized to the em box, not the padded cell, so borders
//! drawn from glyphs show seams between rows and columns; a synthesized
//! segment runs edge-to-edge and shares the same midline arithmetic in
//! every cell, so adjacent pieces join seamlessly at any size.
//!
//! Coverage: the full light/heavy line set (dashes render solid), the
//! pure-double lines and corners (corners as two NESTED L joins, the
//! double frame a terminal face draws), double tees/crosses with the
//! crossing bar riding through the joint rather than breaking (the one
//! simplification; mixed single-double variants fall back to their
//! single shapes), rounded corners as true quarter arcs, diagonals,
//! half lines, block elements, shades, and quadrants.

const std = @import("std");
const canvas = @import("root.zig");
const geometry = @import("geometry");

pub fn isBoxDrawing(cp: u21) bool {
    return cp >= 0x2500 and cp <= 0x259F;
}

/// A horizontal run of the SAME code point that draws one seamless
/// full-width piece can merge into a single command.
pub fn mergesHorizontally(cp: u21) bool {
    return switch (cp) {
        0x2500, 0x2501, 0x2550 => true, // ─ ━ ═
        0x2580...0x2588 => true, // ▀ and the lower blocks ▁..█
        0x2591, 0x2592, 0x2593, 0x2594 => true, // shades and ▔
        else => false,
    };
}

const Weight = enum { none, light, heavy, double };

const Sides = struct {
    up: Weight = .none,
    down: Weight = .none,
    left: Weight = .none,
    right: Weight = .none,
};

/// The two-bit weight patterns of the U+251C-254B tees and crosses
/// follow no single formula; explicit tables keep them honest.
fn lineSides(cp: u21) ?Sides {
    const L = Weight.light;
    const H = Weight.heavy;
    const D = Weight.double;
    return switch (cp) {
        0x2500, 0x254C => .{ .left = L, .right = L }, // ─ ╌
        0x2501, 0x254D => .{ .left = H, .right = H }, // ━ ╍
        0x2502, 0x254E => .{ .up = L, .down = L }, // │ ╎
        0x2503, 0x254F => .{ .up = H, .down = H }, // ┃ ╏
        0x2504, 0x2508 => .{ .left = L, .right = L }, // dashed ─
        0x2505, 0x2509 => .{ .left = H, .right = H }, // dashed ━
        0x2506, 0x250A => .{ .up = L, .down = L }, // dashed │
        0x2507, 0x250B => .{ .up = H, .down = H }, // dashed ┃
        0x250C => .{ .down = L, .right = L }, // ┌
        0x250D => .{ .down = L, .right = H }, // ┍
        0x250E => .{ .down = H, .right = L }, // ┎
        0x250F => .{ .down = H, .right = H }, // ┏
        0x2510 => .{ .down = L, .left = L }, // ┐
        0x2511 => .{ .down = L, .left = H }, // ┑
        0x2512 => .{ .down = H, .left = L }, // ┒
        0x2513 => .{ .down = H, .left = H }, // ┓
        0x2514 => .{ .up = L, .right = L }, // └
        0x2515 => .{ .up = L, .right = H }, // ┕
        0x2516 => .{ .up = H, .right = L }, // ┖
        0x2517 => .{ .up = H, .right = H }, // ┗
        0x2518 => .{ .up = L, .left = L }, // ┘
        0x2519 => .{ .up = L, .left = H }, // ┙
        0x251A => .{ .up = H, .left = L }, // ┚
        0x251B => .{ .up = H, .left = H }, // ┛
        0x251C => .{ .up = L, .down = L, .right = L }, // ├
        0x251D => .{ .up = L, .down = L, .right = H }, // ┝
        0x251E => .{ .up = H, .down = L, .right = L }, // ┞
        0x251F => .{ .up = L, .down = H, .right = L }, // ┟
        0x2520 => .{ .up = H, .down = H, .right = L }, // ┠
        0x2521 => .{ .up = H, .down = L, .right = H }, // ┡
        0x2522 => .{ .up = L, .down = H, .right = H }, // ┢
        0x2523 => .{ .up = H, .down = H, .right = H }, // ┣
        0x2524 => .{ .up = L, .down = L, .left = L }, // ┤
        0x2525 => .{ .up = L, .down = L, .left = H }, // ┥
        0x2526 => .{ .up = H, .down = L, .left = L }, // ┦
        0x2527 => .{ .up = L, .down = H, .left = L }, // ┧
        0x2528 => .{ .up = H, .down = H, .left = L }, // ┨
        0x2529 => .{ .up = H, .down = L, .left = H }, // ┩
        0x252A => .{ .up = L, .down = H, .left = H }, // ┪
        0x252B => .{ .up = H, .down = H, .left = H }, // ┫
        0x252C => .{ .left = L, .right = L, .down = L }, // ┬
        0x252D => .{ .left = H, .right = L, .down = L }, // ┭
        0x252E => .{ .left = L, .right = H, .down = L }, // ┮
        0x252F => .{ .left = H, .right = H, .down = L }, // ┯
        0x2530 => .{ .left = L, .right = L, .down = H }, // ┰
        0x2531 => .{ .left = H, .right = L, .down = H }, // ┱
        0x2532 => .{ .left = L, .right = H, .down = H }, // ┲
        0x2533 => .{ .left = H, .right = H, .down = H }, // ┳
        0x2534 => .{ .left = L, .right = L, .up = L }, // ┴
        0x2535 => .{ .left = H, .right = L, .up = L }, // ┵
        0x2536 => .{ .left = L, .right = H, .up = L }, // ┶
        0x2537 => .{ .left = H, .right = H, .up = L }, // ┷
        0x2538 => .{ .left = L, .right = L, .up = H }, // ┸
        0x2539 => .{ .left = H, .right = L, .up = H }, // ┹
        0x253A => .{ .left = L, .right = H, .up = H }, // ┺
        0x253B => .{ .left = H, .right = H, .up = H }, // ┻
        0x253C => .{ .up = L, .down = L, .left = L, .right = L }, // ┼
        0x253D => .{ .up = L, .down = L, .left = H, .right = L }, // ┽
        0x253E => .{ .up = L, .down = L, .left = L, .right = H }, // ┾
        0x253F => .{ .up = L, .down = L, .left = H, .right = H }, // ┿
        0x2540 => .{ .up = H, .down = L, .left = L, .right = L }, // ╀
        0x2541 => .{ .up = L, .down = H, .left = L, .right = L }, // ╁
        0x2542 => .{ .up = H, .down = H, .left = L, .right = L }, // ╂
        0x2543 => .{ .up = H, .down = L, .left = H, .right = L }, // ╃
        0x2544 => .{ .up = H, .down = L, .left = L, .right = H }, // ╄
        0x2545 => .{ .up = L, .down = H, .left = H, .right = L }, // ╅
        0x2546 => .{ .up = L, .down = H, .left = L, .right = H }, // ╆
        0x2547 => .{ .up = H, .down = L, .left = H, .right = H }, // ╇
        0x2548 => .{ .up = L, .down = H, .left = H, .right = H }, // ╈
        0x2549 => .{ .up = H, .down = H, .left = H, .right = L }, // ╉
        0x254A => .{ .up = H, .down = H, .left = L, .right = H }, // ╊
        0x254B => .{ .up = H, .down = H, .left = H, .right = H }, // ╋
        0x2550 => .{ .left = D, .right = D }, // ═
        0x2551 => .{ .up = D, .down = D }, // ║
        0x2552 => .{ .down = L, .right = D }, // ╒
        0x2553 => .{ .down = D, .right = L }, // ╓
        0x2554 => .{ .down = D, .right = D }, // ╔
        0x2555 => .{ .down = L, .left = D }, // ╕
        0x2556 => .{ .down = D, .left = L }, // ╖
        0x2557 => .{ .down = D, .left = D }, // ╗
        0x2558 => .{ .up = L, .right = D }, // ╘
        0x2559 => .{ .up = D, .right = L }, // ╙
        0x255A => .{ .up = D, .right = D }, // ╚
        0x255B => .{ .up = L, .left = D }, // ╛
        0x255C => .{ .up = D, .left = L }, // ╜
        0x255D => .{ .up = D, .left = D }, // ╝
        0x255E => .{ .up = L, .down = L, .right = D }, // ╞
        0x255F => .{ .up = D, .down = D, .right = L }, // ╟
        0x2560 => .{ .up = D, .down = D, .right = D }, // ╠
        0x2561 => .{ .up = L, .down = L, .left = D }, // ╡
        0x2562 => .{ .up = D, .down = D, .left = L }, // ╢
        0x2563 => .{ .up = D, .down = D, .left = D }, // ╣
        0x2564 => .{ .left = D, .right = D, .down = L }, // ╤
        0x2565 => .{ .left = L, .right = L, .down = D }, // ╥
        0x2566 => .{ .left = D, .right = D, .down = D }, // ╦
        0x2567 => .{ .left = D, .right = D, .up = L }, // ╧
        0x2568 => .{ .left = L, .right = L, .up = D }, // ╨
        0x2569 => .{ .left = D, .right = D, .up = D }, // ╩
        0x256A => .{ .up = L, .down = L, .left = D, .right = D }, // ╪
        0x256B => .{ .up = D, .down = D, .left = L, .right = L }, // ╫
        0x256C => .{ .up = D, .down = D, .left = D, .right = D }, // ╬
        0x2574 => .{ .left = L }, // ╴
        0x2575 => .{ .up = L }, // ╵
        0x2576 => .{ .right = L }, // ╶
        0x2577 => .{ .down = L }, // ╷
        0x2578 => .{ .left = H }, // ╸
        0x2579 => .{ .up = H }, // ╹
        0x257A => .{ .right = H }, // ╺
        0x257B => .{ .down = H }, // ╻
        0x257C => .{ .left = L, .right = H }, // ╼
        0x257D => .{ .up = L, .down = H }, // ╽
        0x257E => .{ .left = H, .right = L }, // ╾
        0x257F => .{ .up = H, .down = L }, // ╿
        else => null,
    };
}

/// Paint one box-drawing cell (or a merged horizontal run of the same
/// The MOST commands `paint` can emit for one code point — the per-cell
/// charge the grid painter's row preflight uses, kept adjacent to the
/// paint switch so the two cannot drift. Pure lines emit one bar (two
/// for a double), joints emit per side (two per double side), nested
/// double corners four, rounded corners a path plus its straight run,
/// the crossing diagonal two, quadrants one rect per lit quarter, and
/// every block/shade/fraction one.
pub fn maxCommands(cp: u21) usize {
    if (doubleCorner(cp) != null) return 4;
    if (lineSides(cp)) |sides| {
        // The pure-line shortcuts emit one bar (two for a double).
        if (sides.up == .none and sides.down == .none and sides.left == sides.right and sides.left != .none) {
            return if (sides.left == .double) 2 else 1;
        }
        if (sides.left == .none and sides.right == .none and sides.up == sides.down and sides.up != .none) {
            return if (sides.up == .double) 2 else 1;
        }
        var total: usize = 0;
        for ([_]Weight{ sides.up, sides.down, sides.left, sides.right }) |weight| {
            total += switch (weight) {
                .none => 0,
                .light, .heavy => 1,
                .double => 2,
            };
        }
        return total;
    }
    return switch (cp) {
        0x256D, 0x256E, 0x256F, 0x2570 => 2, // arc + straight run
        0x2573 => 2, // the crossing diagonal
        0x2596...0x259F => 3, // at most three lit quarters in the set
        else => 1, // lines, blocks, shades, fractions
    };
}

/// A pure-double corner's turn: which vertical and horizontal side the
/// two nested L joins open toward.
const DoubleCorner = struct { down: bool, right: bool };

fn doubleCorner(cp: u21) ?DoubleCorner {
    return switch (cp) {
        0x2554 => .{ .down = true, .right = true }, // ╔
        0x2557 => .{ .down = true, .right = false }, // ╗
        0x255A => .{ .down = false, .right = true }, // ╚
        0x255D => .{ .down = false, .right = false }, // ╝
        else => null,
    };
}

/// Two nested L joins: the OUTER horizontal bar (the one on the closed
/// side of the turn) meets the OUTER vertical bar at the outer
/// intersection and the inner pair meets at the inner one, so `╔═╗`
/// renders the double frame a terminal face draws — no bar rides
/// through the joint, no inward stubs. Four bars, four commands.
fn paintDoubleCorner(builder: *canvas.Builder, id_base: u64, keyed: bool, rect: geometry.RectF, corner: DoubleCorner, t: f32, color: canvas.Color) !void {
    const cx = rect.x + rect.width / 2;
    const cy = rect.y + rect.height / 2;
    // Bar centerlines: vertical bars at cx +- t, horizontal at cy +- t.
    // The OUTER pair sits opposite the openings (a down+right corner's
    // outer bars are the top horizontal and the left vertical).
    const outer_x = if (corner.right) cx - t else cx + t;
    const inner_x = if (corner.right) cx + t else cx - t;
    const outer_y = if (corner.down) cy - t else cy + t;
    const inner_y = if (corner.down) cy + t else cy - t;
    var id = id_base;
    // Horizontal bars run toward the horizontal opening, starting at
    // their matching vertical bar's far edge so each joint is solid.
    for ([2][2]f32{ .{ outer_y, outer_x }, .{ inner_y, inner_x } }) |pair| {
        const bar_y = pair[0];
        const from_x = pair[1];
        const x0 = if (corner.right) from_x - t / 2 else rect.x;
        const x1 = if (corner.right) rect.x + rect.width else from_x + t / 2;
        try builder.fillRect(.{
            .id = if (keyed) id else 0,
            .rect = geometry.RectF.init(x0, bar_y - t / 2, x1 - x0, t),
            .fill = .{ .color = color },
        });
        id +%= 1;
    }
    // Vertical bars run toward the vertical opening the same way.
    for ([2][2]f32{ .{ outer_x, outer_y }, .{ inner_x, inner_y } }) |pair| {
        const bar_x = pair[0];
        const from_y = pair[1];
        const y0 = if (corner.down) from_y - t / 2 else rect.y;
        const y1 = if (corner.down) rect.y + rect.height else from_y + t / 2;
        try builder.fillRect(.{
            .id = if (keyed) id else 0,
            .rect = geometry.RectF.init(bar_x - t / 2, y0, t, y1 - y0),
            .fill = .{ .color = color },
        });
        id +%= 1;
    }
}

/// seamless code point) as geometry filling `rect` edge-to-edge. Emits
/// at most four commands with ids `id_base..id_base+3`; `thickness` is
/// the light-line weight in canvas points.
pub fn paint(
    builder: *canvas.Builder,
    id_base: u64,
    rect: geometry.RectF,
    cp: u21,
    color: canvas.Color,
    thickness: f32,
) !void {
    const t = @max(1, thickness);
    const cx = rect.x + rect.width / 2;
    const cy = rect.y + rect.height / 2;
    // The anonymous-id convention (`widgetPartId` returns 0 for id 0):
    // a zero base emits EVERY command with id 0 — no derived 1..3 ids
    // that would collide across an identity-less grid's cells.
    const keyed = id_base != 0;

    // Pure-double corners draw as two NESTED L joins — the outer pair of
    // bars turning at the outer intersection, the inner pair at the
    // inner one — the shape a real terminal face draws, instead of both
    // bars riding through the joint (which reads as a hash crossing with
    // inward stubs).
    if (doubleCorner(cp)) |corner| {
        try paintDoubleCorner(builder, id_base, keyed, rect, corner, t, color);
        return;
    }

    if (lineSides(cp)) |sides| {
        var id = id_base;
        // Pure horizontals and verticals emit ONE edge-to-edge bar (two
        // for a double): the common border pieces cost a single command
        // and are seamless by construction.
        if (sides.up == .none and sides.down == .none and sides.left == sides.right and sides.left != .none) {
            _ = try paintSegment(builder, id, keyed, sides.left, t, .{ .x = rect.x, .y = cy, .len = rect.width, .horizontal = true }, color);
            return;
        }
        if (sides.left == .none and sides.right == .none and sides.up == sides.down and sides.up != .none) {
            _ = try paintSegment(builder, id, keyed, sides.up, t, .{ .x = cx, .y = rect.y, .len = rect.height, .horizontal = false }, color);
            return;
        }
        // Doubles draw as two parallel light lines at center +/- t; the
        // single weights draw one centered bar (heavy at double width).
        // Every segment overlaps the cell center so joints are solid,
        // and runs to the cell edge so neighbors abut exactly.
        if (sides.left != .none) id = try paintSegment(builder, id, keyed, sides.left, t, .{ .x = rect.x, .y = cy, .len = cx - rect.x + barHalf(sides.left, t), .horizontal = true }, color);
        if (sides.right != .none) id = try paintSegment(builder, id, keyed, sides.right, t, .{ .x = cx - barHalf(sides.right, t), .y = cy, .len = rect.x + rect.width - cx + barHalf(sides.right, t), .horizontal = true }, color);
        if (sides.up != .none) id = try paintSegment(builder, id, keyed, sides.up, t, .{ .x = cx, .y = rect.y, .len = cy - rect.y + barHalf(sides.up, t), .horizontal = false }, color);
        if (sides.down != .none) id = try paintSegment(builder, id, keyed, sides.down, t, .{ .x = cx, .y = cy - barHalf(sides.down, t), .len = rect.y + rect.height - cy + barHalf(sides.down, t), .horizontal = false }, color);
        return;
    }

    switch (cp) {
        // Rounded corners: a true quarter arc joining the two cell
        // edges through the center, the shape box-heavy TUIs lean on.
        0x256D, 0x256E, 0x256F, 0x2570 => {
            const r = @min(rect.width, rect.height) / 2;
            // Allocated from the builder's OWN path-element store, never
            // a stack local: `strokePath` retains the slice by reference
            // (it never copies), so a stack array would dangle the moment
            // this frame returns and the retained/diffed renderer read it
            // back as overwritten memory.
            const elements = try builder.allocPathElements(3);
            switch (cp) {
                // ╭ bottom edge to right edge
                0x256D => {
                    elements[0] = .{ .verb = .move_to, .points = .{ .{ .x = cx, .y = rect.y + rect.height }, geometry.PointF.zero(), geometry.PointF.zero() } };
                    elements[1] = .{ .verb = .line_to, .points = .{ .{ .x = cx, .y = cy + r / 2 }, geometry.PointF.zero(), geometry.PointF.zero() } };
                    elements[2] = .{ .verb = .quad_to, .points = .{ .{ .x = cx, .y = cy }, .{ .x = cx + r / 2, .y = cy }, geometry.PointF.zero() } };
                },
                // ╮ bottom edge to left edge
                0x256E => {
                    elements[0] = .{ .verb = .move_to, .points = .{ .{ .x = cx, .y = rect.y + rect.height }, geometry.PointF.zero(), geometry.PointF.zero() } };
                    elements[1] = .{ .verb = .line_to, .points = .{ .{ .x = cx, .y = cy + r / 2 }, geometry.PointF.zero(), geometry.PointF.zero() } };
                    elements[2] = .{ .verb = .quad_to, .points = .{ .{ .x = cx, .y = cy }, .{ .x = cx - r / 2, .y = cy }, geometry.PointF.zero() } };
                },
                // ╯ top edge to left edge
                0x256F => {
                    elements[0] = .{ .verb = .move_to, .points = .{ .{ .x = cx, .y = rect.y }, geometry.PointF.zero(), geometry.PointF.zero() } };
                    elements[1] = .{ .verb = .line_to, .points = .{ .{ .x = cx, .y = cy - r / 2 }, geometry.PointF.zero(), geometry.PointF.zero() } };
                    elements[2] = .{ .verb = .quad_to, .points = .{ .{ .x = cx, .y = cy }, .{ .x = cx - r / 2, .y = cy }, geometry.PointF.zero() } };
                },
                // ╰ top edge to right edge
                else => {
                    elements[0] = .{ .verb = .move_to, .points = .{ .{ .x = cx, .y = rect.y }, geometry.PointF.zero(), geometry.PointF.zero() } };
                    elements[1] = .{ .verb = .line_to, .points = .{ .{ .x = cx, .y = cy - r / 2 }, geometry.PointF.zero(), geometry.PointF.zero() } };
                    elements[2] = .{ .verb = .quad_to, .points = .{ .{ .x = cx, .y = cy }, .{ .x = cx + r / 2, .y = cy }, geometry.PointF.zero() } };
                },
            }
            try builder.strokePath(.{ .id = if (keyed) id_base else 0, .elements = elements, .stroke = .{ .fill = .{ .color = color }, .width = t }, .cap = .butt });
            // The straight remainder to the horizontal edge.
            const run: geometry.RectF = switch (cp) {
                0x256D => geometry.RectF.init(cx + r / 2, cy - t / 2, rect.x + rect.width - (cx + r / 2), t),
                0x256E => geometry.RectF.init(rect.x, cy - t / 2, cx - r / 2 - rect.x, t),
                0x256F => geometry.RectF.init(rect.x, cy - t / 2, cx - r / 2 - rect.x, t),
                else => geometry.RectF.init(cx + r / 2, cy - t / 2, rect.x + rect.width - (cx + r / 2), t),
            };
            try builder.fillRect(.{ .id = if (keyed) id_base +% 1 else 0, .rect = run, .fill = .{ .color = color } });
        },
        // Diagonals.
        0x2571 => try builder.drawLine(.{ .id = if (keyed) id_base else 0, .from = .{ .x = rect.x, .y = rect.y + rect.height }, .to = .{ .x = rect.x + rect.width, .y = rect.y }, .stroke = .{ .fill = .{ .color = color }, .width = t } }),
        0x2572 => try builder.drawLine(.{ .id = if (keyed) id_base else 0, .from = .{ .x = rect.x, .y = rect.y }, .to = .{ .x = rect.x + rect.width, .y = rect.y + rect.height }, .stroke = .{ .fill = .{ .color = color }, .width = t } }),
        0x2573 => {
            try builder.drawLine(.{ .id = if (keyed) id_base else 0, .from = .{ .x = rect.x, .y = rect.y + rect.height }, .to = .{ .x = rect.x + rect.width, .y = rect.y }, .stroke = .{ .fill = .{ .color = color }, .width = t } });
            try builder.drawLine(.{ .id = if (keyed) id_base +% 1 else 0, .from = .{ .x = rect.x, .y = rect.y }, .to = .{ .x = rect.x + rect.width, .y = rect.y + rect.height }, .stroke = .{ .fill = .{ .color = color }, .width = t } });
        },
        // Block elements: fractional rects, edge-to-edge.
        0x2580 => try fillFraction(builder, id_base, rect, color, 1, .top, 0.5),
        0x2581...0x2588 => try fillFraction(builder, id_base, rect, color, 1, .bottom, @as(f32, @floatFromInt(cp - 0x2580)) / 8.0),
        0x2589...0x258F => try fillFraction(builder, id_base, rect, color, 1, .left, @as(f32, @floatFromInt(0x2590 - cp)) / 8.0),
        0x2590 => try fillFraction(builder, id_base, rect, color, 1, .right, 0.5),
        0x2591 => try fillFraction(builder, id_base, rect, color, 0.25, .bottom, 1),
        0x2592 => try fillFraction(builder, id_base, rect, color, 0.5, .bottom, 1),
        0x2593 => try fillFraction(builder, id_base, rect, color, 0.75, .bottom, 1),
        0x2594 => try fillFraction(builder, id_base, rect, color, 1, .top, 0.125),
        0x2595 => try fillFraction(builder, id_base, rect, color, 1, .right, 0.125),
        // Quadrants: one rect per lit quarter.
        0x2596...0x259F => {
            const quads: u4 = switch (cp) { // bits: 1=upper-left 2=upper-right 4=lower-left 8=lower-right
                0x2596 => 0b0100, // ▖
                0x2597 => 0b1000, // ▗
                0x2598 => 0b0001, // ▘
                0x2599 => 0b1101, // ▙
                0x259A => 0b1001, // ▚
                0x259B => 0b0111, // ▛
                0x259C => 0b1011, // ▜
                0x259D => 0b0010, // ▝
                0x259E => 0b0110, // ▞
                else => 0b1110, // ▟
            };
            const hw = rect.width / 2;
            const hh = rect.height / 2;
            var id = id_base;
            if (quads & 0b0001 != 0) {
                try builder.fillRect(.{ .id = if (keyed) id else 0, .rect = geometry.RectF.init(rect.x, rect.y, hw, hh), .fill = .{ .color = color } });
                id +%= 1;
            }
            if (quads & 0b0010 != 0) {
                try builder.fillRect(.{ .id = if (keyed) id else 0, .rect = geometry.RectF.init(rect.x + hw, rect.y, hw, hh), .fill = .{ .color = color } });
                id +%= 1;
            }
            if (quads & 0b0100 != 0) {
                try builder.fillRect(.{ .id = if (keyed) id else 0, .rect = geometry.RectF.init(rect.x, rect.y + hh, hw, hh), .fill = .{ .color = color } });
                id +%= 1;
            }
            if (quads & 0b1000 != 0) {
                try builder.fillRect(.{ .id = if (keyed) id else 0, .rect = geometry.RectF.init(rect.x + hw, rect.y + hh, hw, hh), .fill = .{ .color = color } });
            }
        },
        else => {},
    }
}

const Fraction = enum { top, bottom, left, right };

fn fillFraction(builder: *canvas.Builder, id: u64, rect: geometry.RectF, color: canvas.Color, opacity: f32, side: Fraction, fraction: f32) !void {
    const shaded = canvas.Color.rgba(color.r, color.g, color.b, color.a * opacity);
    const filled: geometry.RectF = switch (side) {
        .top => geometry.RectF.init(rect.x, rect.y, rect.width, rect.height * fraction),
        .bottom => geometry.RectF.init(rect.x, rect.y + rect.height * (1 - fraction), rect.width, rect.height * fraction),
        .left => geometry.RectF.init(rect.x, rect.y, rect.width * fraction, rect.height),
        .right => geometry.RectF.init(rect.x + rect.width * (1 - fraction), rect.y, rect.width * fraction, rect.height),
    };
    try builder.fillRect(.{ .id = id, .rect = filled, .fill = .{ .color = shaded } });
}

const Segment = struct { x: f32, y: f32, len: f32, horizontal: bool };

/// The half-extent a crossing bar must overlap at the cell center so
/// perpendicular joints are solid.
fn barHalf(weight: Weight, t: f32) f32 {
    return switch (weight) {
        .none => 0,
        .light => t / 2,
        .heavy => t,
        .double => t * 1.5,
    };
}

fn paintSegment(builder: *canvas.Builder, id: u64, keyed: bool, weight: Weight, t: f32, seg: Segment, color: canvas.Color) !u64 {
    switch (weight) {
        .none => return id,
        .light, .heavy => {
            const w = if (weight == .heavy) t * 2 else t;
            const rect = if (seg.horizontal)
                geometry.RectF.init(seg.x, seg.y - w / 2, seg.len, w)
            else
                geometry.RectF.init(seg.x - w / 2, seg.y, w, seg.len);
            try builder.fillRect(.{ .id = if (keyed) id else 0, .rect = rect, .fill = .{ .color = color } });
            return id +% 1;
        },
        .double => {
            // Two parallel light bars at center +/- t: pure double runs
            // (═ ║ and the pure-double corners) join seamlessly because
            // every cell computes the same offsets.
            var next = id;
            for ([2]f32{ -t, t }) |offset| {
                const rect = if (seg.horizontal)
                    geometry.RectF.init(seg.x, seg.y + offset - t / 2, seg.len, t)
                else
                    geometry.RectF.init(seg.x + offset - t / 2, seg.y, t, seg.len);
                try builder.fillRect(.{ .id = if (keyed) next else 0, .rect = rect, .fill = .{ .color = color } });
                next +%= 1;
            }
            return next;
        },
    }
}
