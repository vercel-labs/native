//! system-monitor views. Markup-first where markup fits: the header bar
//! (brand, status line, theme chips) is a compiled `.zml` view. Everything
//! else is Zig because it needs what the closed markup grammar excludes —
//! vector icons paired with press handlers, the sparkline bar charts
//! (gpu-dashboard-style chart drawing built in a Zig view: one thin
//! token-tinted bar widget per sample, bottom-aligned in a fixed-width
//! row, so the charts live in the retained widget tree with layout,
//! theming, and automation for free), per-row native context menus, and
//! the modal SIGTERM confirmation overlaid through a z-stack root.

const std = @import("std");
const native_sdk = @import("native_sdk");
const model_mod = @import("model.zig");

const canvas = native_sdk.canvas;
const sampler = model_mod.sampler;

pub const Model = model_mod.Model;
pub const Msg = model_mod.Msg;
pub const Ui = canvas.Ui(Msg);

pub const header_markup = @embedFile("header.zml");
pub const CompiledHeaderView = canvas.CompiledMarkupView(Model, Msg, header_markup);

// ------------------------------------------------------- layout constants
// Precision layout, calculator-style: the sparkline geometry drives the
// tile width and the tile row drives the window. The tests assert the
// tiles land exactly on these frames.

pub const spark_samples = model_mod.history_len;
pub const spark_bar_width: f32 = 3;
pub const spark_bar_gap: f32 = 1;
pub const spark_height: f32 = 32;
pub const spark_width: f32 = spark_samples * spark_bar_width + (spark_samples - 1) * spark_bar_gap; // 239

pub const tile_padding: f32 = 14;
pub const tile_width: f32 = spark_width + tile_padding * 2; // 267
pub const tile_height: f32 = 132;
pub const tile_gap: f32 = 12;
pub const window_padding: f32 = 20;
pub const content_width: f32 = tile_width * 4 + tile_gap * 3; // 1104
pub const window_width: f32 = content_width + window_padding * 2; // 1144
pub const window_height: f32 = 720;

const table_row_height: f32 = 32;
const dialog_width: f32 = 420;

// ------------------------------------------------------------------ root

pub fn rootView(ui: *Ui, model: *const Model) Ui.Node {
    // A z-stack root: the app column fills the window; the confirmation
    // overlay (when armed) is a second child laid out over the same frame.
    if (model.confirmingKill()) {
        return ui.el(.stack, .{ .grow = 1 }, .{
            appView(ui, model),
            confirmOverlay(ui, model),
        });
    }
    return ui.el(.stack, .{ .grow = 1 }, .{appView(ui, model)});
}

fn appView(ui: *Ui, model: *const Model) Ui.Node {
    return ui.column(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        CompiledHeaderView.build(ui, model),
        ui.column(.{ .grow = 1, .padding = window_padding, .gap = 16 }, .{
            tilesView(ui, model),
            toolbarView(ui, model),
            tableView(ui, model),
        }),
        statusBarView(ui, model),
    });
}

// ------------------------------------------------------------ stat tiles

fn tilesView(ui: *Ui, model: *const Model) Ui.Node {
    return ui.row(.{ .gap = tile_gap, .semantics = .{ .label = "Stat tiles" } }, .{
        statTile(ui, .{
            .label = "CPU",
            .value = model.cpuValue(ui.arena),
            .detail = model.cpuDetail(ui.arena),
            .history = model.cpuHistory(),
            .scale = .fraction,
        }),
        statTile(ui, .{
            .label = "Memory",
            .value = model.memValue(ui.arena),
            .detail = model.memDetail(ui.arena),
            .history = model.memHistory(),
            .scale = .fraction,
        }),
        statTile(ui, .{
            .label = "Processes",
            .value = model.procValue(ui.arena),
            .detail = ui.fmt("top {d} by CPU shown", .{model_mod.max_table_rows}),
            .history = model.procHistory(),
            .scale = .window_band,
        }),
        uptimeTile(ui, model),
    });
}

/// How a stat's history maps to bar heights. `fraction` values are already
/// 0..1 of an absolute scale (percent of all cores / of total memory);
/// `window_band` normalizes against the window's own min..max range with a
/// visible floor (process counts have no natural ceiling and barely move —
/// an absolute scale would draw a featureless block; the band shows the
/// drift like a scope trace, documented in the README).
const SparkScale = enum { fraction, window_band };

const TileSpec = struct {
    label: []const u8,
    value: []const u8,
    detail: []const u8,
    history: []const f32,
    scale: SparkScale,
};

fn statTile(ui: *Ui, spec: TileSpec) Ui.Node {
    return ui.panel(.{
        .width = tile_width,
        .height = tile_height,
        .padding = tile_padding,
        .style_tokens = .{ .background = .surface, .radius = .lg, .border_color = .border },
        .semantics = .{ .label = ui.fmt("{s} tile", .{spec.label}) },
    }, ui.column(.{ .gap = 4 }, .{
        ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, spec.label),
        ui.paragraph(.{ .width = spark_width, .semantics = .{ .label = spec.value } }, &.{
            .{ .text = spec.value, .weight = .bold, .scale = 1.55 },
        }),
        // Explicit full-row width: the macOS packet rasterizer re-measures
        // text with its own font metrics, and a tight intrinsic box clips.
        ui.text(.{ .width = spark_width, .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, spec.detail),
        sparklineView(ui, spec.label, spec.history, spec.scale),
    }));
}

fn uptimeTile(ui: *Ui, model: *const Model) Ui.Node {
    return ui.panel(.{
        .width = tile_width,
        .height = tile_height,
        .padding = tile_padding,
        .style_tokens = .{ .background = .surface, .radius = .lg, .border_color = .border },
        .semantics = .{ .label = "Uptime tile" },
    }, ui.column(.{ .gap = 4 }, .{
        ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "Uptime"),
        ui.paragraph(.{ .width = spark_width, .semantics = .{ .label = model.uptimeValue(ui.arena) } }, &.{
            .{ .text = model.uptimeValue(ui.arena), .weight = .bold, .scale = 1.55 },
        }),
        ui.text(.{ .width = spark_width, .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "since boot (pid 1 elapsed time)"),
        ui.column(.{ .height = spark_height, .main = .end, .gap = 3 }, .{
            // Trailing spaces absorb the pipeline's per-multibyte-glyph
            // tail drop (see model.zig headerStatus note).
            ui.text(.{ .width = spark_width, .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, ui.fmt("{d} samples kept · {d} s cadence  ", .{
                model_mod.history_len, model_mod.sample_interval_ms / 1000,
            })),
        }),
    }));
}

// ------------------------------------------------------------ sparklines

const BarCell = struct {
    index: usize,
    height: f32,
};

/// One sparkline: a fixed-width, bottom-aligned row of thin bars, newest
/// at the right edge (bars fill leftward from the right as history
/// accumulates, the way a scope trace enters the screen). Bar count is
/// bounded by `history_len`; each bar is a token-tinted stack, so the
/// chart re-themes with the palette like every other widget.
fn sparklineView(ui: *Ui, label: []const u8, history: []const f32, scale: SparkScale) Ui.Node {
    const cells: []BarCell = ui.arena.alloc(BarCell, history.len) catch @constCast(&[_]BarCell{});
    var low: f32 = std.math.floatMax(f32);
    var high: f32 = 0;
    for (history) |value| {
        low = @min(low, value);
        high = @max(high, value);
    }
    for (cells, history, 0..) |*cell, value, index| {
        const fraction = switch (scale) {
            .fraction => std.math.clamp(value, 0, 1),
            // 0.2 floor + 0.8 band: a flat series reads as a steady mid
            // trace, and drift within the window fills the rest.
            .window_band => if (high > low) 0.2 + 0.8 * (value - low) / (high - low) else 0.5,
        };
        cell.* = .{ .index = index, .height = @max(1.5, fraction * spark_height) };
    }
    var chart = ui.row(.{
        .width = spark_width,
        .height = spark_height,
        .gap = spark_bar_gap,
        .cross = .end,
        .main = .end,
        .semantics = .{ .label = ui.fmt("{s} history", .{label}) },
    }, ui.each(cells, barKey, barView));
    // Fixed box: the row never resizes as samples arrive.
    chart.widget.layout.grow = 0;
    return chart;
}

fn barKey(cell: *const BarCell) canvas.UiKey {
    return canvas.uiKey(@as(u32, @intCast(cell.index)));
}

/// One bar. `.skeleton` on purpose: it is the one leaf that paints a
/// plain token-tinted rounded fill in a single command and is not a hit
/// target (`.stack` paints nothing at all; `.panel` would add a shadow,
/// a border, and hit-testing per bar — sixty of them, three times over).
fn barView(ui: *Ui, cell: *const BarCell) Ui.Node {
    return ui.el(.skeleton, .{
        .width = spark_bar_width,
        .height = cell.height,
        .style = .{ .radius = 1 },
        .style_tokens = .{ .background = .accent },
    }, .{});
}

// --------------------------------------------------------------- toolbar

fn toolbarView(ui: *Ui, model: *const Model) Ui.Node {
    return ui.row(.{ .gap = 10, .cross = .center, .semantics = .{ .label = "Table toolbar" } }, .{
        samplingChip(ui, model),
        ui.el(.search_field, .{
            .width = 260,
            .text = model.search(),
            .placeholder = "Filter by name or pid",
            .on_input = Ui.inputMsg(.search_edit),
            .semantics = .{ .label = "Filter processes" },
        }, .{}),
        if (model.searching())
            iconChip(ui, "x", "Clear", .clear_search, "Clear filter")
        else
            ui.el(.stack, .{}, .{}),
        ui.spacer(1),
        // Width slack: a tight intrinsic box wraps under the reference
        // renderer's metrics ("Sor/t").
        ui.text(.{ .width = 34, .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "Sort"),
        sortChips(ui, model),
        sortDirectionIcon(ui, model),
    });
}

/// Pause/resume: a pressable panel pairing the play/pause vector icon
/// with its verb (markup buttons carry text only, so this chip is a Zig
/// view by necessity — and the reason the toolbar is Zig). The inner text
/// leaf carries the same press handler: hit-testing resolves the deepest
/// hit-target under the pointer, and text is one — icons are not, so
/// icon clicks fall through to the panel's own handler.
fn samplingChip(ui: *Ui, model: *const Model) Ui.Node {
    const label: []const u8 = if (model.paused) "Resume" else "Pause";
    return ui.panel(.{
        .height = 30,
        .padding = 6,
        .on_press = .toggle_sampling,
        .style_tokens = if (model.paused)
            .{ .background = .accent, .radius = .md }
        else
            .{ .background = .surface_subtle, .radius = .md, .border_color = .border },
        .semantics = .{ .role = .button, .label = "Pause or resume sampling" },
    }, ui.row(.{ .gap = 6, .cross = .center }, .{
        if (model.paused)
            ui.icon(.{ .width = 14, .height = 14, .style_tokens = .{ .foreground = .accent_text } }, "play")
        else
            ui.icon(.{ .width = 14, .height = 14, .style_tokens = .{ .foreground = .text_muted } }, "pause"),
        ui.text(.{ .size = .sm, .on_press = .toggle_sampling, .style_tokens = if (model.paused) .{ .foreground = .accent_text } else .{} }, label),
    }));
}

fn iconChip(ui: *Ui, comptime icon_name: []const u8, label: []const u8, msg: Msg, semantic_label: []const u8) Ui.Node {
    return ui.panel(.{
        .height = 30,
        .padding = 6,
        .on_press = msg,
        .style_tokens = .{ .background = .surface_subtle, .radius = .md, .border_color = .border },
        .semantics = .{ .role = .button, .label = semantic_label },
    }, ui.row(.{ .gap = 6, .cross = .center }, .{
        ui.icon(.{ .width = 14, .height = 14, .style_tokens = .{ .foreground = .text_muted } }, icon_name),
        ui.text(.{ .size = .sm, .on_press = msg }, label),
    }));
}

fn sortChips(ui: *Ui, model: *const Model) Ui.Node {
    return ui.el(.toggle_group, .{ .gap = 2, .semantics = .{ .label = "Sort key" } }, .{
        sortChip(ui, model.sortedByCpu(), "CPU", .cpu),
        sortChip(ui, model.sortedByMem(), "Memory", .mem),
        sortChip(ui, model.sortedByPid(), "PID", .pid),
        sortChip(ui, model.sortedByName(), "Name", .name),
    });
}

fn sortChip(ui: *Ui, selected: bool, label: []const u8, key: model_mod.SortKey) Ui.Node {
    var node = ui.el(.toggle_button, .{
        .size = .sm,
        .selected = selected,
        .on_toggle = Msg{ .set_sort = key },
        .semantics = .{ .label = ui.fmt("Sort by {s}", .{label}) },
    }, .{});
    node.widget.text = label;
    return node;
}

fn sortDirectionIcon(ui: *Ui, model: *const Model) Ui.Node {
    const label: []const u8 = if (model.sort_descending) "Descending" else "Ascending";
    const options = Ui.ElementOptions{
        .width = 14,
        .height = 14,
        .style_tokens = .{ .foreground = .text_muted },
        .semantics = .{ .label = label },
    };
    return if (model.sort_descending)
        ui.icon(options, "chevron-down")
    else
        ui.icon(options, "chevron-up");
}

// ----------------------------------------------------------------- table

fn tableView(ui: *Ui, model: *const Model) Ui.Node {
    const rows = model.visibleRows(ui.arena);
    return ui.column(.{ .grow = 1, .gap = 6 }, .{
        tableHeading(ui, model, rows.len),
        if (rows.len == 0) emptyState(ui, model) else processList(ui, rows),
    });
}

fn tableHeading(ui: *Ui, model: *const Model, shown: usize) Ui.Node {
    const matches = model.matchCount(ui.arena);
    return ui.row(.{ .gap = 10, .cross = .center }, .{
        ui.paragraph(.{ .width = 130, .semantics = .{ .label = "Processes" } }, &.{
            .{ .text = "Processes", .weight = .bold, .scale = 1.2 },
        }),
        ui.el(.badge, .{ .variant = .secondary, .text = ui.fmt("{d} of {d}", .{ shown, matches }) }, .{}),
        ui.spacer(1),
        rightAlignedHint(ui, "right-click a row for SIGTERM (confirmed first) "),
    });
}

fn processList(ui: *Ui, rows: []const model_mod.TableRow) Ui.Node {
    return ui.scroll(.{ .grow = 1, .semantics = .{ .label = "Process table" } }, ui.column(.{ .gap = 2 }, .{
        columnHeadings(ui),
        ui.el(.list, .{ .gap = 2, .semantics = .{ .role = .list, .label = "Processes by CPU" } }, ui.each(rows, rowKey, rowView)),
    }));
}

fn columnHeadings(ui: *Ui) Ui.Node {
    return ui.row(.{ .height = 24, .padding = 8, .gap = 12, .cross = .center }, .{
        ui.text(.{ .width = 64, .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "PID"),
        ui.text(.{ .grow = 1, .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "Command"),
        alignedCell(ui, 64, "CPU %", .text_muted),
        alignedCell(ui, 84, "Memory", .text_muted),
    });
}

/// Right-aligned muted hint with ~20% width slack over the tight measure
/// (host-side font metrics differ; see `alignedCell`).
fn rightAlignedHint(ui: *Ui, text: []const u8) Ui.Node {
    var node = ui.text(.{ .width = 380, .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, text);
    node.widget.text_alignment = .end;
    return node;
}

fn rowKey(row: *const model_mod.TableRow) canvas.UiKey {
    return canvas.uiKey(row.pid);
}

/// One process row. The native context menu is the kill seam: Terminate
/// opens the confirmation dialog (never the signal directly), Copy Name
/// runs the clipboard effect.
fn rowView(ui: *Ui, row: *const model_mod.TableRow) Ui.Node {
    return ui.panel(.{
        .global_key = canvas.uiKey(row.pid),
        .height = table_row_height,
        .padding = 8,
        .context_menu = &.{
            .{ .label = "Terminate (SIGTERM)…", .msg = Msg{ .request_kill = row.pid } },
            .{ .separator = true },
            .{ .label = "Copy Name", .msg = Msg{ .copy_name = row.pid } },
        },
        .style_tokens = .{ .radius = .md },
        .semantics = .{ .role = .listitem, .label = ui.fmt("{s} pid {s}", .{ row.name, row.pid_text }) },
    }, ui.row(.{ .gap = 12, .cross = .center }, .{
        ui.text(.{ .width = 64, .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, row.pid_text),
        ui.text(.{ .grow = 1 }, row.name),
        alignedCell(ui, 64, row.cpu_text, .text),
        alignedCell(ui, 84, row.mem_text, .text_muted),
    }));
}

/// Right-aligned fixed-width numeric cell. The width carries slack over
/// the tight measure: the macOS packet rasterizer re-lays text out with
/// its own font metrics, so a tight box can wrap host-side.
fn alignedCell(ui: *Ui, width: f32, text: []const u8, tone: canvas.ColorTokenName) Ui.Node {
    var node = ui.text(.{ .width = width, .size = .sm, .style_tokens = .{ .foreground = tone } }, text);
    node.widget.text_alignment = .end;
    return node;
}

fn emptyState(ui: *Ui, model: *const Model) Ui.Node {
    return ui.panel(.{
        .padding = 24,
        .style_tokens = .{ .background = .surface, .radius = .lg, .border_color = .border },
        .semantics = .{ .label = "No processes match" },
    }, ui.column(.{ .gap = 6 }, .{
        if (model.samples_taken == 0)
            ui.text(.{}, "Waiting for the first sample…")
        else
            ui.text(.{}, ui.fmt("No matches for \"{s}\"", .{model.search()})),
        ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "Filter matches command names and pids."),
    }));
}

// ------------------------------------------------------------ status bar

fn statusBarView(ui: *Ui, model: *const Model) Ui.Node {
    const status = model.statusLine(ui.arena);
    return ui.column(.{}, .{
        ui.separator(.{}),
        ui.row(.{ .height = 30, .padding = 8, .cross = .center, .style_tokens = .{ .background = .surface } }, .{
            // Full-width box, not grow: the host rasterizer measures text
            // slightly wider than layout and a tight box clips the tail.
            ui.text(.{ .width = content_width, .size = .sm, .style_tokens = .{ .foreground = .text_muted }, .semantics = .{ .label = status } }, status),
        }),
    });
}

// ---------------------------------------------------------- kill confirm

/// The SIGTERM confirmation: a dimming scrim over the whole window with a
/// centered dialog. The scrim is pressable and cancels — clicking outside
/// the dialog never terminates anything.
fn confirmOverlay(ui: *Ui, model: *const Model) Ui.Node {
    const pending = model.pending_kill orelse unreachable;
    // A panel, not a column: layout containers paint nothing, and the
    // scrim must both dim the app and catch the cancel press. Radius and
    // stroke are zeroed so no window-edge chrome shows through the dim.
    return ui.panel(.{
        .grow = 1,
        .on_press = .cancel_kill,
        .style = .{ .background = canvas.Color.rgba8(9, 15, 17, 130), .radius = 0, .stroke_width = 0 },
        .semantics = .{ .label = "Confirm termination" },
    }, ui.column(.{ .grow = 1, .main = .center, .cross = .center }, .{
        ui.el(.dialog, .{
            .width = dialog_width,
            .padding = 20,
            // Absorb body presses so they never fall through to the
            // scrim's cancel (deepest handler on the hit route wins).
            .on_press = .dialog_pressed,
            .style_tokens = .{ .background = .surface, .radius = .lg, .border_color = .border },
            .semantics = .{ .role = .dialog, .label = "Send SIGTERM" },
        }, ui.column(.{ .gap = 12 }, .{
            ui.row(.{ .gap = 10, .cross = .center }, .{
                ui.icon(.{ .width = 20, .height = 20, .style_tokens = .{ .foreground = .warning } }, "alert"),
                ui.paragraph(.{ .grow = 1, .semantics = .{ .label = "Send SIGTERM?" } }, &.{
                    .{ .text = "Send SIGTERM?", .weight = .bold, .scale = 1.25 },
                }),
            }),
            ui.text(.{ .wrap = true }, ui.fmt("{s} (pid {d}) will be asked to quit.", .{ pending.name(), pending.pid })),
            ui.text(.{ .wrap = true, .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "SIGTERM is the polite request — the process may save, clean up, or decline. This app never sends SIGKILL."),
            ui.row(.{ .gap = 8, .main = .end }, .{
                ui.button(.{ .variant = .secondary, .on_press = .cancel_kill, .semantics = .{ .label = "Cancel termination" } }, "Cancel"),
                ui.button(.{ .variant = .destructive, .on_press = .confirm_kill, .semantics = .{ .label = "Confirm SIGTERM" } }, "Send SIGTERM"),
            }),
        })),
    }));
}
