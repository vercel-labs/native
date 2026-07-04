//! deck views: the hardware chrome. Markup-first where markup fits (the
//! status strip is a compiled `.zml` view); everything else is Zig because
//! the faceplate needs what the closed markup grammar excludes — the
//! `ui.chart` spectrum analyzer, mono paragraph readouts at custom scales,
//! per-row native context menus, and model-conditional plate styling.
//!
//! Every color in this file is a design-token reference (`style_tokens`);
//! the widget skin lives in `theme.zig` and the sculpted hardware layer
//! (bevels, wells, screws, scanlines, the segment readout) in
//! `chrome.zig`, which draws at the layout constants exported below.
//! The glass panels fill with the `background` token (the case black) so
//! the chrome's inset bevels read as machining depth.

const std = @import("std");
const native_sdk = @import("native_sdk");
const model_mod = @import("model.zig");

const canvas = native_sdk.canvas;

pub const Model = model_mod.Model;
pub const Msg = model_mod.Msg;
pub const Ui = canvas.Ui(Msg);

pub const statusbar_markup = @embedFile("statusbar.zml");
pub const CompiledStatusBarView = canvas.CompiledMarkupView(Model, Msg, statusbar_markup);

// ------------------------------------------------------- layout constants
// Shared with `chrome.zig`: the sculpted chrome pass draws its bevels,
// wells, scanlines, and the segment readout at these exact coordinates,
// so the machining hugs the widgets.

pub const faceplate_height: f32 = 180;
pub const faceplate_pad: f32 = 14;
pub const brand_width: f32 = 104;
pub const panel_gap: f32 = 14;
pub const row1_height: f32 = 96;
pub const transport_height: f32 = 30;
pub const transport_y: f32 = faceplate_pad + row1_height + 10;
pub const btn_prev_width: f32 = 40;
pub const btn_play_width: f32 = 56;
pub const btn_next_width: f32 = 40;
pub const spectrum_width: f32 = 270;
pub const rail_width: f32 = 236;
pub const statusbar_height: f32 = 39; // 38 strip + 1 separator
pub const perf_queue_height: f32 = 24;
const vfd_padding: f32 = 12;
const ledger_row_height: f32 = 27;
const rail_row_height: f32 = 30;

// ------------------------------------------------------------------ root

pub fn rootView(ui: *Ui, model: *const Model) Ui.Node {
    // No root fill: the chrome pass paints the chassis (base fill plus
    // the brushed hairline texture) behind everything.
    return ui.column(.{ .grow = 1 }, .{
        faceplateView(ui, model),
        switch (model.view) {
            .library => libraryView(ui, model),
            .performance => performanceView(ui, model),
        },
        CompiledStatusBarView.build(ui, model),
    });
}

// ------------------------------------------------------------- faceplate

fn faceplateView(ui: *Ui, model: *const Model) Ui.Node {
    // The plate itself (machined gradient, gold cap band, bevels, ridge
    // band, corner screws) is chrome; the widgets sit in its pockets.
    // A column, not a panel: panels always fill their background token
    // and this strip must stay transparent so the chrome's machined
    // gradient, ridge band, and screws show through.
    return ui.column(.{
        .height = faceplate_height,
        .padding = faceplate_pad,
        .gap = 10,
        .semantics = .{ .label = "Faceplate" },
    }, .{
        ui.row(.{ .gap = panel_gap, .height = row1_height }, .{
            brandPlate(ui, model),
            vfdPanel(ui, model),
            spectrumPanel(ui, model, 0),
        }),
        transportRow(ui, model),
    });
}

fn brandPlate(ui: *Ui, model: *const Model) Ui.Node {
    // "DECK" sits engraved into the chrome-drawn gold plate (dark glyphs
    // on brushed gold); the rest is chassis engraving.
    return ui.column(.{ .width = brand_width, .gap = 4 }, .{
        ui.row(.{ .height = 28, .main = .center, .cross = .center }, .{
            ui.paragraph(.{ .semantics = .{ .label = "Brand" } }, &.{
                .{ .text = "D E C K", .weight = .bold, .scale = 1.2, .color = .accent_text },
            }),
        }),
        ui.paragraph(.{}, &.{
            .{ .text = spaced(ui, "NATIVE SDK"), .monospace = true, .color = .text_muted, .scale = 0.72 },
        }),
        ui.spacer(1),
        ui.paragraph(.{}, &.{
            .{ .text = "MK·48", .monospace = true, .color = .text_muted, .scale = 0.82 },
        }),
        ui.row(.{ .gap = 5, .cross = .center }, .{
            ui.icon(.{
                .width = 10,
                .height = 10,
                .style_tokens = .{ .foreground = if (model.playing) .accent else .text_muted },
            }, "circle-dot"),
            ui.paragraph(.{ .semantics = .{ .label = "Power state" } }, &.{
                .{ .text = if (model.playing) "RUN" else "STBY", .monospace = true, .color = if (model.playing) .accent else .text_muted, .scale = 0.82 },
            }),
        }),
    });
}

/// The VFD glass: a recessed readout — channel line, big mono title,
/// artist, the timecode block, and the phosphor progress strip. The strip
/// is the authoritative playback readout (a `.progress` leaf, model-
/// driven); the fader in the transport row is the matching CONTROL —
/// slider positions are runtime-owned between rebuilds by engine rule, so
/// a scrubber that is also the readout would fight the user's hand.
fn vfdPanel(ui: *Ui, model: *const Model) Ui.Node {
    // The right block leaves clear glass at the top: the chrome pass
    // draws the seven-segment elapsed readout there (sheared hexagon
    // paths with a glow stroke); the small mono line under it is the
    // AX-readable echo of the same clock.
    return ui.panel(.{
        .grow = 1,
        .padding = vfd_padding,
        .style_tokens = .{ .background = .background, .radius = .sm },
        .semantics = .{ .label = "VFD readout" },
    }, ui.column(.{ .gap = 6, .grow = 1 }, .{
        ui.row(.{ .gap = 12, .grow = 1 }, .{
            ui.column(.{ .gap = 4, .grow = 1 }, .{
                ui.paragraph(.{ .semantics = .{ .label = "Channel" } }, &.{
                    .{ .text = model.channelLabel(ui.arena), .monospace = true, .color = .text_muted, .scale = 0.86 },
                }),
                ui.paragraph(.{ .semantics = .{ .label = "Now playing title" } }, &.{
                    .{ .text = upper(ui, model.nowPlayingTitle()), .monospace = true, .weight = .bold, .scale = 1.6, .color = if (model.idle()) .text_muted else .accent },
                }),
                ui.paragraph(.{ .semantics = .{ .label = "Now playing artist" } }, &.{
                    .{ .text = model.nowPlayingArtist(), .monospace = true, .color = .text_muted, .scale = 0.92 },
                }),
            }),
            ui.column(.{ .width = 132, .gap = 2, .main = .end, .cross = .end }, .{
                ui.paragraph(.{ .semantics = .{ .label = "Elapsed" } }, &.{
                    .{ .text = ui.fmt("{s} / {s}", .{ model.elapsedLabel(ui.arena), model.durationLabel(ui.arena) }), .monospace = true, .color = .text_muted, .scale = 0.86 },
                }),
            }),
        }),
        ui.el(.progress, .{
            .height = 4,
            .value = model.progressFraction(),
            .semantics = .{ .label = "Progress" },
        }, .{}),
    }));
}

/// The live spectrum: one `.chart` widget over the model's 32 deterministic
/// band levels, drawn through the vector path pipeline in the phosphor
/// token — bars for the bands plus a paper-white peak trace riding their
/// caps (the classic peak-hold line). `grow` > 0 lets the PERF face scale
/// it full-height.
fn spectrumChart(ui: *Ui, model: *const Model, grow: f32, grid_lines: u8) Ui.Node {
    const levels = model.spectrumLevels(ui.arena);
    const peaks = peakTrace(ui, levels);
    return ui.chart(.{
        .grow = grow,
        .height = if (grow > 0) 0 else 74,
        .y_min = 0,
        .y_max = 1,
        .grid_lines = grid_lines,
        .semantics = .{ .label = "Spectrum analyzer" },
    }, &.{
        .{
            .kind = .bar,
            .values = levels,
            .color = .accent,
            .label = "spectrum",
        },
        .{
            .kind = .line,
            .values = peaks,
            .color = .text,
            .label = "peaks",
        },
    });
}

fn spectrumPanel(ui: *Ui, model: *const Model, grow: f32) Ui.Node {
    return ui.panel(.{
        .width = if (grow > 0) 0 else spectrum_width,
        .grow = grow,
        .padding = 10,
        .style_tokens = .{ .background = .background, .radius = .sm },
        .semantics = .{ .label = "Spectrum panel" },
    }, ui.column(.{ .gap = 6, .grow = 1 }, .{
        spectrumChart(ui, model, if (grow > 0) 1 else 0, if (grow > 0) 4 else 0),
        ui.row(.{ .cross = .center }, .{
            ui.paragraph(.{}, &.{
                .{ .text = spaced(ui, "SPECTRUM//32"), .monospace = true, .color = .text_muted, .scale = 0.74 },
            }),
            ui.spacer(1),
            ui.paragraph(.{}, &.{
                .{ .text = if (model.playing) "L I V E" else "H O L D", .monospace = true, .color = if (model.playing) .accent else .text_muted, .scale = 0.74 },
            }),
        }),
    }));
}

/// The machined control row: transport cluster, the long-travel seek bar
/// with mono timecode, and the output block (fader + meter).
fn transportRow(ui: *Ui, model: *const Model) Ui.Node {
    // Chunky sculpted keys: the chrome pass draws raised bevel edges on
    // each of the three transport keys and recessed wells behind the
    // cluster and the output block.
    return ui.row(.{ .gap = 10, .height = transport_height, .cross = .center, .semantics = .{ .label = "Transport" } }, .{
        ui.button(.{
            .variant = .outline,
            .width = btn_prev_width,
            .height = transport_height,
            .icon = "skip-back",
            .disabled = model.idle(),
            .on_press = .prev_track,
            .semantics = .{ .label = "Previous track" },
        }, ""),
        ui.button(.{
            .variant = .primary,
            .width = btn_play_width,
            .height = transport_height,
            .icon = if (model.playing) "pause" else "play",
            .on_press = .toggle_play,
            .semantics = .{ .label = "Play or pause" },
        }, ""),
        ui.button(.{
            .variant = .outline,
            .width = btn_next_width,
            .height = transport_height,
            .icon = "skip-forward",
            .disabled = model.idle(),
            .on_press = .next_track,
            .semantics = .{ .label = "Next track" },
        }, ""),
        // Timecode and the true progress readout live on the VFD; this
        // fader is the seek CONTROL. Re-keyed per track so it takes the
        // source position once on every load (snaps home) — slider values
        // are runtime-owned between rebuilds, so an un-keyed fader would
        // hold its last drag across track changes.
        ui.el(.slider, .{
            .key = canvas.uiKey(@as(u32, model.now orelse 0)),
            .grow = 1,
            .value = model.progressFraction(),
            .disabled = model.idle(),
            .on_change = .seeked,
            .semantics = .{ .label = "Seek" },
        }, .{}),
        ui.el(.separator, .{ .width = 1, .height = 18 }, .{}),
        monoCaption(ui, "VOL", 26, .start),
        ui.el(.slider, .{
            .width = 86,
            .value = model.volume_fraction,
            .on_change = .volume_changed,
            .semantics = .{ .label = "Volume" },
        }, .{}),
        ui.el(.progress, .{
            .width = 54,
            .value = model.outputLevel(ui.arena),
            .semantics = .{ .label = "Output level" },
        }, .{}),
    });
}

fn monoCaption(ui: *Ui, text: []const u8, width: f32, alignment: canvas.TextAlign) Ui.Node {
    var node = ui.paragraph(.{ .width = width }, &.{
        .{ .text = text, .monospace = true, .color = .text_muted, .scale = 0.86 },
    });
    node.widget.text_alignment = alignment;
    return node;
}

// ------------------------------------------------------------- library face

fn libraryView(ui: *Ui, model: *const Model) Ui.Node {
    return ui.row(.{ .grow = 1 }, .{
        railView(ui, model),
        ui.el(.separator, .{ .width = 1 }, .{}),
        ledgerView(ui, model),
    });
}

/// The channel bank: one plate per album (plus ALL), never search-filtered.
fn railView(ui: *Ui, model: *const Model) Ui.Node {
    const cells = model.railCells(ui.arena);
    return ui.column(.{ .width = rail_width, .padding = 10, .gap = 8 }, .{
        engravedCaption(ui, "CHANNEL BANK"),
        ui.el(.list, .{
            .gap = 2,
            .semantics = .{ .role = .list, .label = "Channel bank" },
        }, ui.each(cells, railKey, railCell)),
        ui.spacer(1),
        // The spec engraving block: dense chassis stamping where a lesser
        // machine would leave whitespace.
        ui.column(.{ .gap = 3 }, .{
            engravedCaption(ui, "MODEL MK-48 // 2U"),
            engravedCaption(ui, "SN 0048-1979-DK"),
            engravedCaption(ui, "OUT 2X16W / 8 OHM"),
        }),
    });
}

fn railKey(cell: *const model_mod.RailCell) canvas.UiKey {
    return canvas.uiKey(@as(u32, cell.id));
}

fn railCell(ui: *Ui, cell: *const model_mod.RailCell) Ui.Node {
    return ui.panel(.{
        .height = rail_row_height,
        .padding = 7,
        .on_press = Msg{ .select_album = cell.id },
        // Machined plates on the brushed chassis; the selected channel
        // lights its edge.
        .style_tokens = if (cell.selected)
            .{ .background = .surface_subtle, .border_color = .accent, .radius = .sm }
        else
            .{ .background = .surface, .radius = .sm },
        .semantics = .{ .role = .listitem, .label = cell.title },
    }, ui.row(.{ .gap = 8, .cross = .center }, .{
        ui.paragraph(.{ .width = 20 }, &.{
            .{ .text = cell.number, .monospace = true, .color = if (cell.selected) .accent else .text_muted, .scale = 0.86 },
        }),
        ui.text(.{ .grow = 1, .style_tokens = if (cell.selected) .{ .foreground = .text } else .{ .foreground = .text_muted } }, cell.title),
        if (cell.live)
            ui.icon(.{ .width = 10, .height = 10, .style_tokens = .{ .foreground = .accent } }, "circle-dot")
        else
            ui.paragraph(.{}, &.{
                .{ .text = cell.meta, .monospace = true, .color = .text_muted, .scale = 0.8 },
            }),
    }));
}

/// The track ledger: a dense text table, no cards, no covers. Each row is
/// pressable (load/toggle) and carries the native context menu.
fn ledgerView(ui: *Ui, model: *const Model) Ui.Node {
    // The ledger is glass too — the playlist IS a display on this
    // machine — so it fills with the case black; the chrome pass frames
    // it with an inset bevel.
    const rows = model.visibleTracks(ui.arena);
    const bank = if (model.selected_album == 0) "ALL" else upper(ui, model_mod.albumById(model.selected_album).title);
    return ui.column(.{ .grow = 1, .padding = 10, .gap = 8, .style_tokens = .{ .background = .background } }, .{
        ui.row(.{ .cross = .center, .gap = 8 }, .{
            engravedCaption(ui, ui.fmt("TRACKS // {s}", .{bank})),
            ui.spacer(1),
            engravedCaption(ui, ui.fmt("{d} TRK", .{rows.len})),
        }),
        if (rows.len == 0) emptyLedger(ui, model) else ui.scroll(.{
            .grow = 1,
            .semantics = .{ .label = "Track ledger" },
        }, ui.el(.list, .{
            .gap = 1,
            .semantics = .{ .role = .list, .label = "Tracks" },
        }, ui.each(rows, trackKey, ledgerRow))),
    });
}

fn trackKey(row: *const model_mod.TrackRow) canvas.UiKey {
    return canvas.uiKey(@as(u32, row.id));
}

fn ledgerRow(ui: *Ui, row: *const model_mod.TrackRow) Ui.Node {
    return ui.panel(.{
        .global_key = canvas.uiKey(@as(u32, row.id)),
        .height = ledger_row_height,
        .padding = 6,
        .on_press = Msg{ .play_track = row.id },
        // Two items per row on purpose: the per-view context-menu budget
        // is 128 items and the full ledger mounts 48 rows.
        .context_menu = &.{
            .{ .label = "Play Next", .msg = Msg{ .queue_track = row.id } },
            .{ .label = "Copy Title", .msg = Msg{ .copy_title = row.id } },
        },
        .style_tokens = if (row.now)
            .{ .background = .surface_subtle, .radius = .sm }
        else
            .{ .radius = .sm },
        .semantics = .{ .role = .listitem, .label = row.title },
    }, ui.row(.{ .gap = 10, .cross = .center }, .{
        ui.row(.{ .width = 16, .cross = .center }, .{
            if (row.now and row.playing)
                ui.icon(.{ .width = 11, .height = 11, .style_tokens = .{ .foreground = .accent } }, "play")
            else if (row.now)
                ui.icon(.{ .width = 11, .height = 11, .style_tokens = .{ .foreground = .text_muted } }, "pause")
            else
                ui.paragraph(.{}, &.{
                    .{ .text = row.number, .monospace = true, .color = .text_muted, .scale = 0.86 },
                }),
        }),
        ui.text(.{ .grow = 1, .style_tokens = if (row.now) .{ .foreground = .accent } else .{} }, row.title),
        ui.text(.{ .width = 168, .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, row.artist),
        // A fixed cue slot keeps the artist and duration columns aligned
        // whether or not the amber Q plate is present.
        ui.row(.{ .width = 24, .cross = .center, .main = .end }, .{
            if (row.queued)
                ui.el(.badge, .{
                    .text = "Q",
                    .style_tokens = .{ .background = .warning, .foreground = .warning_text },
                }, .{})
            else
                ui.el(.stack, .{}, .{}),
        }),
        monoCaption(ui, row.duration, 38, .end),
    }));
}

fn emptyLedger(ui: *Ui, model: *const Model) Ui.Node {
    return ui.panel(.{
        .padding = 16,
        .style_tokens = .{ .background = .surface, .radius = .md, .border_color = .border },
        .semantics = .{ .label = "No tracks match" },
    }, ui.column(.{ .gap = 4 }, .{
        ui.paragraph(.{}, &.{
            .{ .text = "NO SIGNAL", .monospace = true, .color = .text_muted },
        }),
        ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, ui.fmt("no matches for \"{s}\"", .{model.search()})),
    }));
}

// --------------------------------------------------------- performance face

/// The PERF face: the analyzer fills the deck, the queue reads as amber
/// cue plates underneath.
fn performanceView(ui: *Ui, model: *const Model) Ui.Node {
    const queued = model.queueRows(ui.arena);
    return ui.column(.{ .grow = 1, .padding = 14, .gap = 10, .semantics = .{ .label = "Performance face" } }, .{
        spectrumPanel(ui, model, 1),
        ui.row(.{ .gap = 6, .height = perf_queue_height, .cross = .center, .semantics = .{ .role = .list, .label = "Up next" } }, .{
            engravedCaption(ui, "UP NEXT //"),
            if (queued.len == 0)
                ui.paragraph(.{}, &.{
                    .{ .text = "QUEUE EMPTY", .monospace = true, .color = .text_muted, .scale = 0.8 },
                })
            else
                ui.el(.stack, .{}, .{}),
            ui.row(.{ .gap = 4, .cross = .center }, ui.each(queued, trackKey, cuePlate)),
            ui.spacer(1),
        }),
    });
}

fn cuePlate(ui: *Ui, row: *const model_mod.TrackRow) Ui.Node {
    return ui.el(.badge, .{
        .text = ui.fmt("{s} {s}", .{ row.number, upper(ui, row.title) }),
        .style_tokens = .{ .background = .warning, .foreground = .warning_text },
        .semantics = .{ .role = .listitem, .label = row.title },
    }, .{});
}

// ---------------------------------------------------------------- shared

fn engravedCaption(ui: *Ui, text: []const u8) Ui.Node {
    // Letter-spaced mono caps: the bitmap-face feel without pretending
    // to own a bitmap font.
    return ui.paragraph(.{}, &.{
        .{ .text = spaced(ui, text), .monospace = true, .color = .text_muted, .scale = 0.76 },
    });
}

/// Letter-spaces ASCII text by interleaving spaces (build-arena copy).
fn spaced(ui: *Ui, source: []const u8) []const u8 {
    if (source.len == 0) return source;
    const out = ui.arena.alloc(u8, source.len * 2 - 1) catch return source;
    for (source, 0..) |byte, index| {
        out[index * 2] = byte;
        if (index * 2 + 1 < out.len) out[index * 2 + 1] = ' ';
    }
    return out;
}

/// The peak-hold trace: each band's cap, a hair above the bar. Arena
/// exhaustion degrades to tracing the bars exactly — never a build error.
fn peakTrace(ui: *Ui, levels: []const f32) []const f32 {
    const out = ui.arena.alloc(f32, levels.len) catch return levels;
    for (levels, out) |level, *peak| peak.* = @min(1, level + 0.04);
    return out;
}

/// ASCII-uppercase into the build arena (library strings are ASCII).
fn upper(ui: *Ui, source: []const u8) []const u8 {
    const out = ui.arena.alloc(u8, source.len) catch return source;
    for (source, 0..) |byte, index| out[index] = std.ascii.toUpper(byte);
    return out;
}
