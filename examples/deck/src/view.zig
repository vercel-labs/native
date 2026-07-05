//! deck views: the hardware chrome, split across two windows the way the
//! original hardware split it — a small fixed player (the main window IS
//! the device) and a matching playlist rack unit declared through
//! `windows_fn` while the model says it is open.
//!
//! Markup-first where markup fits (the playlist's status strip is a
//! compiled `.zml` view); everything else is Zig because the faceplate
//! needs what the closed markup grammar excludes — the `ui.chart`
//! spectrum analyzer, mono paragraph readouts at custom scales, per-row
//! native context menus, the registered-texture image leaf, and
//! model-conditional plate styling.
//!
//! Every color in this file is a design-token reference (`style_tokens`);
//! the widget skin lives in `theme.zig`, the sculpted hardware layer
//! (bevels, wells, screws, scanlines, the segment readout) in
//! `chrome.zig`, and EVERY shared dimension in `layout.zig` — the one
//! chassis table both this file and the chrome pass machine against.
//! The glass panels fill with the `background` token (the case black) so
//! the chrome's inset bevels read as machining depth.

const std = @import("std");
const native_sdk = @import("native_sdk");
const model_mod = @import("model.zig");
const theme = @import("theme.zig");

const canvas = native_sdk.canvas;

pub const Model = model_mod.Model;
pub const Msg = model_mod.Msg;
pub const Ui = canvas.Ui(Msg);

pub const statusbar_markup = @embedFile("statusbar.zml");
pub const CompiledStatusBarView = canvas.CompiledMarkupView(Model, Msg, statusbar_markup);

/// The chassis layout table (see layout.zig): re-exported so app wiring
/// and the tests read the same constants the views are built from.
pub const layout = @import("layout.zig");
pub const window_width = layout.window_width;
pub const window_height = layout.window_height;
pub const playlist_width = layout.playlist_width;
pub const playlist_height = layout.playlist_height;

/// Every mono scale in the deck is pitch-snapped: the mono advance is
/// `canvas.mono_advance_em` (0.6 em), and at an arbitrary scale each
/// glyph's pen lands on a different subpixel phase — the anti-aliasing
/// then renders every stamp a little differently and the spacing reads
/// as bad kerning. Snapping the scale so the pitch is a whole pixel at
/// 1x keeps every glyph on the same phase at 1x AND at every integer
/// display scale, so the stampings come out even and deliberate.
fn monoScale(comptime target: f32) f32 {
    const em = canvas.mono_advance_em * theme.body_size;
    return @round(em * target) / em;
}

/// Engraved caption scale: uppercase mono at reduced size, everywhere a
/// panel is stamped. One scale, so the stampings read as one process
/// (5 px pitch at the 12 px body).
const caption_scale: f32 = monoScale(0.72);
/// Readout scale for mono numerals and short labels (the VFD's channel
/// line, VOL, ledger numbers and durations): 6 px pitch.
const readout_scale: f32 = monoScale(0.8);
/// The marquee's full-size mono: 7 px pitch.
const marquee_scale: f32 = monoScale(1.0);

// ------------------------------------------------------------ player root

pub fn rootView(ui: *Ui, model: *const Model) Ui.Node {
    // No root fill: the chrome pass paints the chassis (machined
    // gradient over the brushed-plate texture) behind everything.
    return ui.column(.{ .grow = 1 }, .{
        capBand(ui, model),
        ui.column(.{ .grow = 1, .padding = layout.pad, .gap = layout.gap }, .{
            ui.row(.{ .gap = layout.gap, .height = layout.row1_height }, .{
                vfdPanel(ui, model),
                spectrumPanel(ui, model),
            }),
            seekRow(ui, model),
            transportRow(ui, model),
        }),
    });
}

/// The gold cap band: the window's drag region and its brand plate in
/// one — the window IS the device, so the titlebar is machined gold
/// (chrome draws the band; this row is transparent). The leading spacer
/// clears the traffic lights by the live chrome inset.
fn capBand(ui: *Ui, model: *const Model) Ui.Node {
    return ui.row(.{
        .height = layout.cap_height,
        .gap = 8,
        .cross = .center,
        .window_drag = true,
        .semantics = .{ .label = "Cap band" },
    }, .{
        ui.el(.stack, .{ .width = model.chrome_leading + layout.pad }, .{}),
        ui.paragraph(.{ .semantics = .{ .label = "Brand" } }, &.{
            .{ .text = "D E C K", .weight = .bold, .scale = 1.02, .color = .accent_text },
        }),
        ui.spacer(1),
        ui.paragraph(.{}, &.{
            .{ .text = "MK·48 // NATIVE SDK", .monospace = true, .color = .accent_text, .scale = caption_scale },
        }),
        ui.row(.{ .gap = 4, .cross = .center }, .{
            ui.icon(.{
                .width = 9,
                .height = 9,
                .style_tokens = .{ .foreground = if (model.playing) .accent else .accent_text },
            }, "circle-dot"),
            ui.paragraph(.{ .semantics = .{ .label = "Power state" } }, &.{
                .{ .text = if (model.playing) "RUN" else "STBY", .monospace = true, .color = .accent_text, .scale = caption_scale },
            }),
        }),
        ui.el(.stack, .{ .width = layout.pad }, .{}),
    });
}

/// The VFD glass: the seven-segment elapsed readout (chrome-drawn into
/// the clear area reserved on the left), the rotating title marquee, the
/// channel/timecode echo line, and the phosphor progress strip. The
/// strip is the authoritative playback readout (a `.progress` leaf,
/// model-driven); the long-travel fader below the glass is the seek
/// CONTROL — slider positions are runtime-owned between rebuilds by
/// engine rule, so a scrubber that is also the readout would fight the
/// user's hand.
fn vfdPanel(ui: *Ui, model: *const Model) Ui.Node {
    return ui.panel(.{
        .width = layout.vfd_width,
        .padding = layout.glass_inset,
        .style_tokens = .{ .background = .background, .radius = .sm },
        .semantics = .{ .label = "VFD readout" },
    }, ui.column(.{ .gap = 5, .grow = 1 }, .{
        ui.row(.{ .gap = layout.gap, .grow = 1 }, .{
            // Clear glass: the chrome pass draws the sheared segment
            // digits here; the mono timecode line under the marquee is
            // the AX-readable echo of the same clock.
            ui.el(.stack, .{ .width = layout.segment_area_width, .semantics = .{ .label = "Segment readout" } }, .{}),
            ui.column(.{ .gap = 4, .grow = 1, .main = .center }, .{
                ui.paragraph(.{ .semantics = .{ .label = "Marquee" } }, &.{
                    .{ .text = model.marqueeText(ui.arena), .monospace = true, .weight = .bold, .scale = marquee_scale, .color = if (model.idle()) .text_muted else .accent },
                }),
                ui.paragraph(.{ .semantics = .{ .label = "Channel" } }, &.{
                    .{ .text = ui.fmt("{s}  {s} / {s}", .{
                        model.channelLabel(ui.arena),
                        model.elapsedLabel(ui.arena),
                        model.durationLabel(ui.arena),
                    }), .monospace = true, .color = .text_muted, .scale = readout_scale },
                }),
            }),
        }),
        ui.el(.progress, .{
            .height = 3,
            .value = model.progressFraction(),
            .semantics = .{ .label = "Progress" },
        }, .{}),
    }));
}

/// The live spectrum: one `.chart` widget over the model's 32
/// deterministic band levels — phosphor bars plus a paper-white
/// peak-trace line riding their caps.
fn spectrumPanel(ui: *Ui, model: *const Model) Ui.Node {
    const levels = model.spectrumLevels(ui.arena);
    const peaks = peakTrace(ui, levels);
    return ui.panel(.{
        .width = layout.spectrum_width,
        .padding = layout.glass_inset,
        .style_tokens = .{ .background = .background, .radius = .sm },
        .semantics = .{ .label = "Spectrum panel" },
    }, ui.column(.{ .gap = 4, .grow = 1 }, .{
        ui.chart(.{
            .grow = 1,
            .y_min = 0,
            .y_max = 1,
            .semantics = .{ .label = "Spectrum analyzer" },
        }, &.{
            .{ .kind = .bar, .values = levels, .color = .accent, .label = "spectrum" },
            .{ .kind = .line, .values = peaks, .color = .text, .label = "peaks" },
        }),
        ui.row(.{ .cross = .center }, .{
            engravedCaption(ui, "SPECTRUM//32"),
            ui.spacer(1),
            ui.paragraph(.{}, &.{
                .{ .text = if (model.playing) "LIVE" else "HOLD", .monospace = true, .color = if (model.playing) .accent else .text_muted, .scale = caption_scale },
            }),
        }),
    }));
}

/// The long-travel seek fader. Re-keyed per track so it takes the source
/// position once on every load (snaps home) — slider values are
/// runtime-owned between rebuilds, so an un-keyed fader would hold its
/// last drag across track changes. The explicit height matches the
/// chrome's glass frame, so the thumb rides inside the bevel.
fn seekRow(ui: *Ui, model: *const Model) Ui.Node {
    return ui.row(.{ .height = layout.seek_height, .cross = .center, .semantics = .{ .label = "Seek row" } }, .{
        ui.el(.slider, .{
            .key = canvas.uiKey(@as(u32, model.now orelse 0)),
            .grow = 1,
            .height = layout.seek_height,
            .value = model.progressFraction(),
            .disabled = model.idle(),
            .on_change = .seeked,
            .semantics = .{ .label = "Seek" },
        }, .{}),
    });
}

/// The machined control row: transport cluster, output block, and the
/// chunky PL key that racks the playlist window in and out. Widths and
/// gaps come from the layout table; the chrome pass accumulates the same
/// numbers into its bevel and well positions, and the table's comptime
/// assert holds that the row fits its container (the queue region grows,
/// so the PL key is right-aligned at `layout.pl_x` by construction).
fn transportRow(ui: *Ui, model: *const Model) Ui.Node {
    return ui.row(.{ .gap = layout.gap, .height = layout.transport_height, .cross = .center, .semantics = .{ .label = "Transport" } }, .{
        ui.button(.{
            .variant = .outline,
            .width = layout.btn_prev_width,
            .height = layout.key_height,
            .icon = "skip-back",
            .disabled = model.idle(),
            .on_press = .prev_track,
            .semantics = .{ .label = "Previous track" },
        }, ""),
        ui.button(.{
            .variant = .primary,
            .width = layout.btn_play_width,
            .height = layout.key_height,
            .icon = if (model.playing) "pause" else "play",
            .on_press = .toggle_play,
            .semantics = .{ .label = "Play or pause" },
        }, ""),
        ui.button(.{
            .variant = .outline,
            .width = layout.btn_next_width,
            .height = layout.key_height,
            .icon = "skip-forward",
            .disabled = model.idle(),
            .on_press = .next_track,
            .semantics = .{ .label = "Next track" },
        }, ""),
        // Fixed spacer between the wells (the recessed pockets need a
        // faceplate strip between their bevels).
        ui.el(.stack, .{ .width = layout.cluster_spacer }, .{}),
        monoCaption(ui, "VOL", layout.vol_caption_width, .start),
        ui.el(.slider, .{
            .width = layout.volume_width,
            .value = model.volume_fraction,
            .on_change = .volume_changed,
            .semantics = .{ .label = "Volume" },
        }, .{}),
        ui.el(.progress, .{
            .width = layout.meter_width,
            .value = model.outputLevel(ui.arena),
            .semantics = .{ .label = "Output level" },
        }, .{}),
        // The queue region grows, keeping the PL key pinned at the
        // right margin; the amber badge hugs the key when present.
        ui.row(.{ .grow = 1, .cross = .center, .main = .end }, .{
            if (model.hasQueue())
                ui.el(.badge, .{
                    .text = model.queueLabel(ui.arena),
                    .style_tokens = .{ .accent = .warning, .accent_foreground = .warning_text },
                    .semantics = .{ .label = "Queue badge" },
                }, .{})
            else
                ui.el(.stack, .{}, .{}),
        }),
        ui.el(.toggle_button, .{
            .width = layout.btn_pl_width,
            .height = layout.key_height,
            .text = "PL",
            .selected = model.playlist_open,
            .on_toggle = .toggle_playlist,
            .semantics = .{ .label = "Playlist window" },
        }, .{}),
    });
}

fn monoCaption(ui: *Ui, text: []const u8, width: f32, alignment: canvas.TextAlign) Ui.Node {
    var node = ui.paragraph(.{ .width = width }, &.{
        .{ .text = text, .monospace = true, .color = .text_muted, .scale = readout_scale },
    });
    node.widget.text_alignment = alignment;
    return node;
}

// ---------------------------------------------------------- playlist root

/// The playlist rack unit: a second model-declared window. ONE flat
/// list of every song — no album rail, no sub-collections; search
/// narrows it and the cue strip carries the queue. No chrome pass
/// reaches secondary windows, so the rack look here is widgets and
/// tokens only — the carbon-weave texture rides an `image` leaf behind
/// the content (the same registered-image channel the chrome uses), and
/// the machining is panel plates and hairline separators.
pub fn playlistView(ui: *Ui, model: *const Model) Ui.Node {
    var backdrop = ui.image(.{
        .width = layout.playlist_width,
        .height = layout.playlist_height,
        .image = model.texture_weave,
        .semantics = .{ .label = "Weave backdrop" },
    });
    backdrop.widget.image_fit = .cover;
    return ui.el(.stack, .{ .grow = 1 }, .{
        backdrop,
        ui.column(.{ .grow = 1 }, .{
            playlistHeader(ui),
            ui.el(.separator, .{ .height = 1 }, .{}),
            ledgerView(ui, model),
            cueStrip(ui, model),
            CompiledStatusBarView.build(ui, model),
        }),
    });
}

/// The rack's own cap strip: drag region plus engraved unit label. The
/// leading pad is the hardcoded compact-titlebar constant (secondary
/// windows have no chrome-inset hook yet).
fn playlistHeader(ui: *Ui) Ui.Node {
    return ui.row(.{
        .height = layout.playlist_header_height,
        .gap = 8,
        .cross = .center,
        .window_drag = true,
        .style_tokens = .{ .background = .surface },
        .semantics = .{ .label = "Playlist cap" },
    }, .{
        ui.el(.stack, .{ .width = layout.playlist_chrome_leading }, .{}),
        engravedCaption(ui, "PLAYLIST"),
        ui.spacer(1),
        engravedCaption(ui, "DECK MK-48 // 1U"),
        ui.el(.stack, .{ .width = layout.rack_pad }, .{}),
    });
}

/// The track ledger: ONE flat list of every song — a dense text table,
/// no cards, no covers. Each row is pressable (load/toggle) and carries
/// the native context menu. The caption row's fixed height keeps the
/// scroll viewport folding on a whole row (the layout table's comptime
/// assert holds it).
fn ledgerView(ui: *Ui, model: *const Model) Ui.Node {
    // The ledger is glass — the playlist IS a display on this machine —
    // so it fills with the case black.
    const rows = model.visibleTracks(ui.arena);
    return ui.column(.{ .grow = 1, .padding = layout.rack_pad, .gap = layout.gap, .style_tokens = .{ .background = .background } }, .{
        ui.row(.{ .height = layout.ledger_caption_height, .cross = .center, .gap = 8 }, .{
            engravedCaption(ui, "TRACKS // LIBRARY"),
            ui.spacer(1),
            engravedCaption(ui, ui.fmt("{d} TRK", .{rows.len})),
        }),
        if (rows.len == 0) emptyLedger(ui, model) else ui.scroll(.{
            .grow = 1,
            .semantics = .{ .label = "Track ledger" },
        }, ui.el(.list, .{
            .gap = layout.ledger_row_gap,
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
        .height = layout.ledger_row_height,
        .padding = 5,
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
    }, ui.row(.{ .gap = 8, .cross = .center }, .{
        ui.row(.{ .width = layout.ledger_number_width, .cross = .center }, .{
            if (row.now and row.playing)
                ui.icon(.{ .width = 11, .height = 11, .style_tokens = .{ .foreground = .accent } }, "play")
            else if (row.now)
                ui.icon(.{ .width = 11, .height = 11, .style_tokens = .{ .foreground = .text_muted } }, "pause")
            else
                ui.paragraph(.{}, &.{
                    .{ .text = row.number, .monospace = true, .color = .text_muted, .scale = readout_scale },
                }),
        }),
        // One-line ledger columns: clip a long title/artist at the
        // column edge, never wrap onto the row below.
        ui.text(.{ .grow = 1, .size = .sm, .wrap = false, .style_tokens = if (row.now) .{ .foreground = .accent } else .{} }, row.title),
        ui.text(.{ .width = layout.ledger_artist_width, .size = .sm, .wrap = false, .style_tokens = .{ .foreground = .text_muted } }, row.artist),
        // A fixed cue slot keeps the artist and duration columns aligned
        // whether or not the amber Q plate is present.
        ui.row(.{ .width = layout.ledger_cue_width, .cross = .center, .main = .end }, .{
            if (row.queued)
                ui.el(.badge, .{
                    .text = "Q",
                    .style_tokens = .{ .accent = .warning, .accent_foreground = .warning_text },
                }, .{})
            else
                ui.el(.stack, .{}, .{}),
        }),
        monoCaption(ui, row.duration, layout.ledger_duration_width, .end),
        // The overlay scrollbar's lane: keeps the duration digits clear
        // of the thumb (the plate itself stays full width).
        ui.el(.stack, .{ .width = layout.ledger_scroll_lane }, .{}),
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

/// The up-next cue strip: the queue as amber plates, in play order.
fn cueStrip(ui: *Ui, model: *const Model) Ui.Node {
    const queued = model.queueRows(ui.arena);
    return ui.row(.{ .gap = 6, .height = layout.cue_strip_height, .cross = .center, .padding = 4, .semantics = .{ .role = .list, .label = "Up next" } }, .{
        ui.el(.stack, .{ .width = layout.rack_pad - 4 }, .{}),
        engravedCaption(ui, "UP NEXT //"),
        if (queued.len == 0)
            ui.paragraph(.{}, &.{
                .{ .text = "QUEUE EMPTY", .monospace = true, .color = .text_muted, .scale = caption_scale },
            })
        else
            ui.el(.stack, .{}, .{}),
        ui.row(.{ .gap = 4, .cross = .center }, ui.each(queued, trackKey, cuePlate)),
        ui.spacer(1),
    });
}

fn cuePlate(ui: *Ui, row: *const model_mod.TrackRow) Ui.Node {
    return ui.el(.badge, .{
        .text = ui.fmt("{s} {s}", .{ row.number, upper(ui, row.title) }),
        .style_tokens = .{ .accent = .warning, .accent_foreground = .warning_text },
        .semantics = .{ .role = .listitem, .label = row.title },
    }, .{});
}

// ---------------------------------------------------------------- shared

/// Engraved caption: uppercase mono at the caption scale, natural
/// advance. (Round 1 letter-spaced these by interleaving spaces; the
/// interleave split digit groups and "//" marks and wrapped loudly in
/// narrow panels — the mono face's own spacing is the honest stamping.)
fn engravedCaption(ui: *Ui, text: []const u8) Ui.Node {
    return ui.paragraph(.{}, &.{
        .{ .text = text, .monospace = true, .color = .text_muted, .scale = caption_scale },
    });
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
