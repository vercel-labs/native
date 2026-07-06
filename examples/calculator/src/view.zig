//! calculator views. Markup-first: the whole keypad is a compiled
//! `.native` view; this file holds the sections the closed markup grammar
//! cannot express — the drag band (the hidden-inset titlebar's
//! `window_drag` region: empty by design, the window has no chrome) and
//! the display block, whose result paragraph needs monospace and weight
//! spans the closed markup grammar does not carry (its SIZE is the
//! display typography rung, shared with markup) — plus the root view
//! composing all three.
//!
//! The display's expression line is a real `text_field` and it is the
//! app's keyboard seam: focusing it (click, or Tab) routes every typed
//! character through the widget keyboard path as `TextInputEvent`s that
//! `update` parses as calculator keys, backspace edits the entry, and
//! enter submits as equals. The field's text is model-derived (the live
//! expression), so unknown characters can never appear in it.

const std = @import("std");
const native_sdk = @import("native_sdk");
const model_mod = @import("model.zig");

const canvas = native_sdk.canvas;

pub const Model = model_mod.Model;
pub const Msg = model_mod.Msg;
pub const Ui = canvas.Ui(Msg);

pub const keypad_markup = @embedFile("keypad.native");
pub const CompiledKeypadView = canvas.CompiledMarkupView(Model, Msg, keypad_markup);

// Keypad metrics (kept in lockstep with keypad.native; the layout test
// asserts the rendered frames match these numbers exactly).
pub const key_width: f32 = 66;
pub const key_height: f32 = 54;
pub const key_gap: f32 = 8;
pub const zero_width: f32 = key_width * 2 + key_gap; // 140
pub const content_width: f32 = key_width * 4 + key_gap * 3; // 288
pub const window_padding: f32 = 16;

/// The drag band under the hidden-inset titlebar: tall enough to clear
/// the window controls in the leading corner.
pub const band_height: f32 = 24;

// The big result line renders at the display typography rung; the theme
// tunes the rung to the keypad geometry (`theme.display_size`).

// ----------------------------------------------------------------- root

pub fn rootView(ui: *Ui, model: *const Model) Ui.Node {
    return ui.column(.{
        .padding = window_padding,
        .gap = 14,
        .grow = 1,
        .style_tokens = .{ .background = .background },
    }, .{
        dragBand(ui),
        displayView(ui, model),
        CompiledKeypadView.build(ui, model),
    });
}

/// The chromeless top band: the window drag region (hidden-inset
/// titlebar). Deliberately empty — no logo, no label; the identity is
/// the readout and the key rhythm, and the window controls own the
/// leading corner.
fn dragBand(ui: *Ui) Ui.Node {
    return ui.row(.{
        .height = band_height,
        .window_drag = true,
        .semantics = .{ .label = "Window drag area" },
    }, .{
        ui.spacer(1),
    });
}

// ---------------------------------------------------------------- display

/// Memory line, expression field, and the big result — all sitting
/// directly on the window background so the digits carry the design.
fn displayView(ui: *Ui, model: *const Model) Ui.Node {
    return ui.column(.{ .gap = 4, .semantics = .{ .label = "Display" } }, .{
        memoryLine(ui, model),
        expressionField(ui, model),
        resultLine(ui, model),
    });
}

/// The last completed calculation, right-aligned and quiet, in the same
/// mono as the result so digits stack column-over-column. The explicit
/// height keeps the layout steady while it is empty.
fn memoryLine(ui: *Ui, model: *const Model) Ui.Node {
    var node = ui.paragraph(.{
        .width = content_width,
        .height = 18,
        .size = .sm,
        .style_tokens = .{ .foreground = .text_muted },
        .semantics = .{ .label = "Last calculation" },
    }, &.{
        .{ .text = model.memoryText(ui.arena), .monospace = true },
    });
    node.widget.text_alignment = .end;
    return node;
}

/// The live expression and the keyboard seam (see the module doc). The
/// field blends into the background until focused, when the accent
/// focus ring shows exactly where keystrokes go. No placeholder: an
/// empty expression line is quiet, not chatty.
fn expressionField(ui: *Ui, model: *const Model) Ui.Node {
    return ui.el(.text_field, .{
        .width = content_width,
        .height = 32,
        .text = model.expressionText(ui.arena),
        .on_input = Ui.inputMsg(.typed),
        .on_submit = .equals,
        .style_tokens = .{ .background = .background, .border_color = .background },
        .semantics = .{ .label = "Expression" },
    }, .{});
}

/// The result: one mono span at the display rung, right-aligned. The
/// explicit width spans the whole content column — it is the alignment
/// box that keeps the right-aligned result flush with the keypad edge.
/// Its semantic label IS the value, so assistive tech (and the
/// automation snapshot) reads the result directly.
fn resultLine(ui: *Ui, model: *const Model) Ui.Node {
    const value = model.displayText(ui.arena);
    var node = ui.paragraph(.{
        .width = content_width,
        .size = .display,
        .semantics = .{ .label = value },
    }, &.{
        .{ .text = value, .weight = .medium, .monospace = true },
    });
    node.widget.text_alignment = .end;
    return node;
}
