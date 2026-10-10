//! deck views: the hardware fascia, split across two windows the way a
//! component hi-fi stack splits it — a fixed-size player (the main
//! window IS the rack unit) and a matching playlist unit declared
//! through `windows_fn` while the model says it is open.
//!
//! Both windows are CHROMELESS (no OS titlebar, no system buttons), so
//! each cap band carries the skin's OWN close and minimize keys — real
//! controls wired to the runtime's window-action effects, with proper
//! roles and labels; nothing decorative.
//!
//! Markup-first where markup fits (the playlist's status strip and the
//! spectrum analyzer chart are compiled `.native` views); everything else
//! is Zig because the fascia needs what the closed markup grammar
//! excludes — paragraph readouts at custom scales, per-row native
//! context menus, the registered-image cover leaf, and model-conditional
//! plate styling.
//!
//! Every color in this file is a design-token reference (`style_tokens`);
//! the widget skin lives in `theme.zig`, the sculpted hardware layer
//! (enamel, bevels, screws, scanlines, the segment readout, the volume
//! knob face) in `chrome.zig`, and EVERY shared dimension in
//! `layout.zig` — the one chassis table both this file and the chrome
//! pass machine against. The glass bays fill with the `background`
//! token (the smoked glass) so the chrome's inset bevels read as depth
//! into the enamel.
//!
//! Type: ONE face — Geist Pixel, the deck's registered primary — fills
//! both typography slots (theme.zig), so mono-flagged readouts and
//! plain text print in the same pixel face. Scales sit on the face's
//! design grid: readouts and captions at the half grid (scale 1.0), the
//! marquee at the full grid (scale 2.0, one font-pixel per device
//! pixel at 1x). The face is proportional; column alignment rides fixed
//! widths and text alignment, never an assumed pitch.
//!
//! Token registers, by material (see theme.zig): on GLASS, `accent` is
//! live phosphor, `success` the pale resting print, `info` the dim
//! engraving, `warning` the one amber. On ENAMEL, `text` is the
//! silkscreened ink and `text_muted` the lighter stamping.

const std = @import("std");
const native_sdk = @import("native_sdk");
const model_mod = @import("model.zig");
const theme = @import("theme.zig");

const canvas = native_sdk.canvas;

pub const Model = model_mod.Model;
pub const Msg = model_mod.Msg;
pub const Ui = canvas.Ui(Msg);

pub const statusbar_markup = @embedFile("statusbar.native");
pub const CompiledStatusBarView = canvas.CompiledMarkupView(Model, Msg, statusbar_markup);

/// The spectrum analyzer chart: a compiled `.native` fragment (one
/// `<chart>` with a single bar series binding a model fn — bars only,
/// no line riding their caps), built into the display bay's glass
/// beside the segment clock — the deck's ONE animated band.
pub const CompiledSpectrumView = canvas.CompiledMarkupView(Model, Msg, @embedFile("spectrum.native"));

/// The chassis layout table (see layout.zig): re-exported so app wiring
/// and the tests read the same constants the views are built from.
pub const layout = @import("layout.zig");
pub const window_width = layout.window_width;
pub const window_height = layout.window_height;
pub const playlist_width = layout.playlist_width;
pub const playlist_height = layout.playlist_height;

/// Scales on the pixel face's design grid (see theme.zig): 1.0 is the
/// half-grid body size — every caption and readout — and 2.0 is the
/// full grid, where one font-pixel is exactly one device pixel at 1x.
/// Nothing between: sizes off the grid render the pixel blocks as
/// anti-aliased mush, so hierarchy comes from the phosphor registers
/// and the one full-grid marquee.
const caption_scale: f32 = 1.0;
const readout_scale: f32 = 1.0;
const marquee_scale: f32 = 2.0;

// ------------------------------------------------------------ player root

pub fn rootView(ui: *Ui, model: *const Model) Ui.Node {
    // No root fill: the chrome pass paints the enamel chassis (warm
    // gradient, grain hairlines, machining) behind everything.
    return ui.column(.{ .grow = 1 }, .{
        capBand(ui, model),
        ui.column(.{ .grow = 1, .padding = layout.pad, .gap = layout.gap }, .{
            ui.row(.{ .gap = layout.gap, .height = layout.row1_height }, .{
                displayBay(ui, model),
                artBay(ui, model),
            }),
            seekRow(ui, model),
            transportRow(ui, model),
        }),
    });
}

/// The enamel cap band: the window's drag region, the skin's OWN window
/// keys, and the DECK stamp in one — the window IS the device and it
/// is chromeless, so the close and minimize keys here are the real
/// controls (wired to the window-action effects), not decoration. The
/// chrome draws the band and the key bevels; this row is transparent
/// and the stamp prints directly on the band's enamel. All x-positions
/// are layout-table constants (no OS chrome inset exists to track).
fn capBand(ui: *Ui, model: *const Model) Ui.Node {
    return ui.row(.{
        .height = layout.cap_height,
        .gap = layout.cap_gap,
        .cross = .center,
        .window_drag = true,
        .semantics = .{ .label = "Cap band" },
    }, .{
        // Leading margin: with the row gap, the close key lands at
        // layout.cap_close_x.
        ui.el(.stack, .{ .width = layout.pad - layout.cap_gap }, .{}),
        windowKey(ui, "x", Msg{ .close_window = .player }, "Close window"),
        windowKey(ui, "app:minimize", Msg{ .minimize_window = .player }, "Minimize window"),
        brandStamp(ui),
        ui.spacer(1),
        // The unit's model designation — hardware fascia lettering, not
        // framework branding (apps never self-brand their own chrome).
        ui.paragraph(.{}, &.{
            .{ .text = "STEREO DECK // MK-48", .monospace = true, .color = .text_muted, .scale = caption_scale },
        }),
        ui.row(.{ .gap = 4, .cross = .center }, .{
            ui.icon(.{
                .width = 9,
                .height = 9,
                .style_tokens = .{ .foreground = if (model.playing) .accent else .text_muted },
            }, "circle-dot"),
            ui.paragraph(.{ .semantics = .{ .label = "Power state" } }, &.{
                .{ .text = if (model.playing) "RUN" else "STBY", .monospace = true, .color = .text_muted, .scale = caption_scale },
            }),
        }),
        ui.el(.stack, .{ .width = layout.pad - layout.cap_gap }, .{}),
    });
}

/// One skin-native window key: a real button with a real verb behind it
/// (close or minimize through the runtime's window-action effects) —
/// the affordance-honesty bar for a chromeless window. Square enamel,
/// dark glyph; the chrome pass adds the raised bevel.
fn windowKey(ui: *Ui, icon: []const u8, msg: Msg, label: []const u8) Ui.Node {
    return ui.button(.{
        .variant = .outline,
        .width = layout.cap_key_size,
        .height = layout.cap_key_size,
        .icon = icon,
        .on_press = msg,
        .semantics = .{ .label = label },
    }, "");
}

/// The DECK stamp: silkscreened lettering directly on the cap band's
/// enamel — no plate, no box behind it (the letter-spaced tracking and
/// the bold ink are the whole brand). `layout.brand_width` cases it.
fn brandStamp(ui: *Ui) Ui.Node {
    var node = ui.paragraph(.{ .width = layout.brand_width, .semantics = .{ .label = "Brand" } }, &.{
        .{ .text = "D E C K", .weight = .bold, .monospace = true, .color = .text, .scale = caption_scale },
    });
    node.widget.text_alignment = .center;
    return node;
}

/// The display bay: the deck's ONE glass LED section — everything
/// phosphor lives here. Top row: clear glass for the chrome-drawn
/// seven-segment elapsed readout, with the spectrum chart (the one
/// animated band) beside it. Below: the rotating title marquee at the
/// full pixel grid, then the channel + timecode line (with the LIVE /
/// HOLD lamp) and the honest bitrate/size readout (with the SPECTRUM//32
/// engraving). No progress strip: the long-travel seek fader below the
/// glass is both the seek control AND the position readout — one
/// affordance, not two.
fn displayBay(ui: *Ui, model: *const Model) Ui.Node {
    return ui.panel(.{
        .width = layout.display_width,
        .padding = layout.glass_inset,
        .style_tokens = .{ .background = .background, .radius = .sm },
        .semantics = .{ .label = "Display bay" },
    }, ui.column(.{ .gap = layout.display_row_gap, .grow = 1 }, .{
        ui.row(.{ .gap = layout.gap, .height = layout.display_top_row_height }, .{
            // Clear glass: the chrome pass draws the sheared segment
            // digits here; the timecode line below is the AX-readable
            // echo of the same clock.
            ui.el(.stack, .{ .width = layout.segment_area_width, .semantics = .{ .label = "Segment readout" } }, .{}),
            CompiledSpectrumView.build(ui, model),
        }),
        // Failure stamps ride the marquee in signal amber — the one
        // attention hue — so a failed load is unmistakable on the
        // glass; the channel line below names the remedy.
        ui.paragraph(.{ .semantics = .{ .label = "Marquee" } }, &.{
            .{ .text = model.marqueeText(ui.arena), .monospace = true, .weight = .bold, .scale = marquee_scale, .color = if (model.mediaFailed()) .warning else if (model.idle()) .info else .accent },
        }),
        ui.row(.{ .cross = .center, .gap = layout.gap }, .{
            if (model.mediaFailed())
                // The remedy on the channel line, full display width.
                // Which remedy depends on which failure: prepare the
                // assets, or check the network.
                ui.paragraph(.{ .semantics = .{ .label = "Channel" } }, &.{
                    .{ .text = model.remedyText(), .monospace = true, .color = .warning, .scale = caption_scale },
                })
            else
                ui.paragraph(.{ .semantics = .{ .label = "Channel" } }, &.{
                    .{ .text = ui.fmt("{s}  {s} / {s}", .{
                        model.channelLabel(ui.arena),
                        model.elapsedLabel(ui.arena),
                        model.durationLabel(ui.arena),
                    }), .monospace = true, .color = .success, .scale = readout_scale },
                }),
            ui.spacer(1),
            ui.paragraph(.{}, &.{
                .{ .text = if (model.playing) "LIVE" else "HOLD", .monospace = true, .color = if (model.playing) .accent else .info, .scale = caption_scale },
            }),
        }),
        ui.row(.{ .cross = .center, .gap = layout.gap }, .{
            // The source line: bitrate + size computed from the
            // manifest's real bytes — see model.sourceLabel for why
            // nothing here is invented.
            ui.paragraph(.{ .semantics = .{ .label = "Source" } }, &.{
                .{ .text = model.sourceLabel(ui.arena), .monospace = true, .color = .info, .scale = caption_scale },
            }),
            ui.spacer(1),
            glassCaption(ui, "SPECTRUM//32"),
        }),
    }));
}

/// The art bay: the loaded record's committed cover in its own glass
/// window — real album art where the hardware would show the disc,
/// square at the glass row's full height. The cover id is 0 while
/// unregistered (the strict test decoder has no JPEG codec; live macOS
/// decodes through the platform codec) or while the deck is idle, and
/// the bay degrades to an engraved plate — a missing image can never
/// break the fascia.
fn artBay(ui: *Ui, model: *const Model) Ui.Node {
    const cover = model.nowCover();
    if (cover != 0) {
        var node = ui.image(.{
            .width = layout.art_size,
            .height = layout.row1_height,
            .image = cover,
            .semantics = .{ .label = "Art bay" },
        });
        node.widget.image_fit = .cover;
        return node;
    }
    return ui.panel(.{
        .width = layout.art_size,
        .height = layout.row1_height,
        .style_tokens = .{ .background = .background, .radius = .sm },
        .semantics = .{ .label = "Art bay" },
    }, ui.column(.{ .grow = 1, .main = .center, .cross = .center }, .{
        glassCaption(ui, if (model.idle()) "--" else "NO ART"),
    }));
}

/// The long-travel seek fader: the seek control AND the deck's position
/// affordance (the display carries the timecode; a second progress bar
/// would duplicate this fader's travel). Re-keyed per track so it takes
/// the source position once on every load (snaps home) — slider values
/// are runtime-owned between rebuilds, so an un-keyed fader would hold
/// its last drag across track changes. The explicit height matches the
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

/// The transport row: five chunky enamel keys with dark glyphs (prev /
/// play / pause / stop / next — the full hardware verbs, each mapping
/// to a real transport message), then the rotary volume block and the
/// labeled PL utility key. Widths and gaps come from the layout table;
/// the chrome pass accumulates the same numbers into its bevel and well
/// positions, and the table's comptime assert holds that the row fits
/// its container (a growing spacer — blank faceplate — pins the PL key
/// right-aligned at `layout.pl_x` by construction).
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
            .variant = .outline,
            .width = layout.btn_play_width,
            .height = layout.key_height,
            .icon = "play",
            .on_press = .transport_play,
            .semantics = .{ .label = "Play" },
        }, ""),
        ui.button(.{
            .variant = .outline,
            .width = layout.btn_pause_width,
            .height = layout.key_height,
            .icon = "pause",
            .disabled = !model.playing,
            .on_press = .transport_pause,
            .semantics = .{ .label = "Pause" },
        }, ""),
        ui.button(.{
            .variant = .outline,
            .width = layout.btn_stop_width,
            .height = layout.key_height,
            // The square stop glyph is the deck's own registered icon
            // (src/icons/stop.svg through the app: namespace) — the
            // built-in set carries no transport square.
            .icon = "app:stop",
            .disabled = model.idle(),
            .on_press = .stop,
            .semantics = .{ .label = "Stop" },
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
        // Fixed spacer past the transport well's bevel: clear enamel
        // before the open-air volume block (no pocket of its own).
        ui.el(.stack, .{ .width = layout.cluster_spacer }, .{}),
        monoCaption(ui, "VOL", layout.vol_caption_width, .start, .text_muted),
        // The rotary volume knob: the CONTROL is this real slider (drag,
        // arrow keys, automation, the focus ring all work); the chrome
        // pass draws the analog knob face with its position dot over the
        // same frame, angle derived from the same `volume_fraction` the
        // slider syncs — one value, two honest presentations.
        ui.el(.slider, .{
            .width = layout.knob_width,
            .height = layout.key_height,
            .value = model.volume_fraction,
            .on_change = .volume_changed,
            .semantics = .{ .label = "Volume" },
        }, .{}),
        // Blank faceplate grows between the volume block and the PL
        // key, pinning PL at the right margin.
        ui.spacer(1),
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

fn monoCaption(ui: *Ui, text: []const u8, width: f32, alignment: canvas.TextAlign, color: canvas.TextSpanColor) Ui.Node {
    var node = ui.paragraph(.{ .width = width }, &.{
        .{ .text = text, .monospace = true, .color = color, .scale = readout_scale },
    });
    node.widget.text_alignment = alignment;
    return node;
}

// ---------------------------------------------------------- playlist root

/// The playlist unit: a second model-declared window — enamel chassis
/// around one big smoked-glass playlist bay. ONE flat list of every
/// song — no album rail, no sub-collections; search narrows it and the
/// deck strip carries the loaded record's sleeve and the ON DECK stamp.
/// The ledger's flat order IS the play order (track end advances down
/// it). No chrome pass reaches secondary windows, so the enamel here is
/// widgets and tokens only: the root fills with the `surface` token and
/// the machining is panel plates and hairline separators.
pub fn playlistView(ui: *Ui, model: *const Model) Ui.Node {
    // The enamel chassis is a PANEL fill: plain layout containers carry
    // no chrome of their own (the renderer paints nothing for rows and
    // columns), so the one honest way to a painted surface is a surface
    // widget — the panel wraps the whole rack.
    return ui.panel(.{
        .grow = 1,
        .style_tokens = .{ .background = .surface },
        .semantics = .{ .label = "Rack chassis" },
    }, ui.column(.{ .grow = 1 }, .{
        playlistHeader(ui),
        ui.el(.separator, .{ .height = 1 }, .{}),
        ledgerView(ui, model),
        deckStrip(ui, model),
        CompiledStatusBarView.build(ui, model),
    }));
}

/// The rack's own cap strip: drag region, the skin's own window keys
/// (chromeless window, like the player), and the engraved unit label.
/// The close key racks the unit back in DECLARATIVELY — clearing
/// `playlist_open` is the real close, through the same reconcile the PL
/// key rides — and the minimize key is the real OS verb through the
/// window-action effect.
fn playlistHeader(ui: *Ui) Ui.Node {
    return ui.row(.{
        .height = layout.playlist_header_height,
        .gap = layout.cap_gap,
        .cross = .center,
        .window_drag = true,
        .semantics = .{ .label = "Playlist cap" },
    }, .{
        // Same leading margin as the player's cap band: the two units'
        // window keys align when the windows stack.
        ui.el(.stack, .{ .width = layout.pad - layout.cap_gap }, .{}),
        windowKey(ui, "x", Msg{ .close_window = .playlist }, "Close window"),
        windowKey(ui, "app:minimize", Msg{ .minimize_window = .playlist }, "Minimize window"),
        enamelCaption(ui, "PLAYLIST"),
        ui.spacer(1),
        enamelCaption(ui, "DECK MK-48 // 1U"),
        ui.el(.stack, .{ .width = layout.rack_pad }, .{}),
    });
}

/// The playlist bay: ONE flat list of every song on dark glass — a
/// dense phosphor table, no cards, no covers, and no per-row plates:
/// single hairline rules BETWEEN the rows (the first row carries none
/// above, the last none below). Each row is pressable (load/toggle) and
/// carries the native context menu. The caption row's fixed height
/// keeps the scroll viewport folding on a whole row (the layout table's
/// comptime assert holds it).
fn ledgerView(ui: *Ui, model: *const Model) Ui.Node {
    // The ledger is glass — the playlist IS a display on this machine —
    // so a panel (containers paint nothing) fills the bay with the
    // smoked-glass token.
    const rows = model.visibleTracks(ui.arena);
    // The bay's content column: the vertical rhythm keeps `rack_pad`
    // (the viewport fold assert in layout.zig depends on it) while the
    // x axis insets deeper (`ledger_inset_x`) so the rows — and the
    // hairline rules between them, children of this same column — keep
    // clear glass to the bay edges. Per-side padding is a direct layout
    // write; the element options carry only the uniform shorthand.
    var content = ui.column(.{ .grow = 1, .gap = layout.gap }, .{
        ui.row(.{ .height = layout.ledger_caption_height, .cross = .center, .gap = 8 }, .{
            glassCaption(ui, "TRACKS // LIBRARY"),
            ui.spacer(1),
            glassCaption(ui, ui.fmt("{d} TRK", .{rows.len})),
        }),
        if (rows.len == 0) emptyLedger(ui, model) else ui.scroll(.{
            .grow = 1,
            .semantics = .{ .label = "Track ledger" },
        }, ui.el(.list, .{
            .semantics = .{ .role = .list, .label = "Tracks" },
        }, ui.each(rows, trackKey, ledgerRow))),
    });
    content.widget.layout.padding = .{
        .top = layout.rack_pad,
        .bottom = layout.rack_pad,
        .left = layout.ledger_inset_x,
        .right = layout.ledger_inset_x,
    };
    return ui.panel(.{
        .grow = 1,
        .style_tokens = .{ .background = .background },
        .semantics = .{ .label = "Playlist bay" },
    }, content);
}

fn trackKey(row: *const model_mod.TrackRow) canvas.UiKey {
    return canvas.uiKey(@as(u32, row.id));
}

/// One ledger row, with its rule: every row but the first stacks a 1px
/// hairline ABOVE its plate, so the bay reads as one ruled glass table
/// — dividers between rows, never a box around each row.
fn ledgerRow(ui: *Ui, row: *const model_mod.TrackRow) Ui.Node {
    if (row.first) return ledgerRowPlate(ui, row);
    return ui.column(.{}, .{
        // The rule: the same phosphor-tinted lift the loaded row washes
        // in, one pixel tall — a hairline in the glass, not a border.
        ui.el(.panel, .{
            .height = layout.ledger_divider_height,
            .style_tokens = .{ .background = .surface_subtle },
        }, .{}),
        ledgerRowPlate(ui, row),
    });
}

fn ledgerRowPlate(ui: *Ui, row: *const model_mod.TrackRow) Ui.Node {
    return ui.panel(.{
        .global_key = canvas.uiKey(@as(u32, row.id)),
        .height = layout.ledger_row_height,
        .padding = 5,
        .on_press = Msg{ .play_track = row.id },
        // One item per row on purpose: the full ledger mounts every
        // catalog track, and one item per row keeps the mounted total
        // well inside the per-view context-menu budget.
        .context_menu = &.{
            .{ .label = "Copy Title", .msg = Msg{ .copy_title = row.id } },
        },
        // Rows are bare glass (the theme's default panel paints
        // nothing); the loaded row alone lifts on a phosphor-tinted
        // wash — the "current row" highlight of the bay.
        .style_tokens = if (row.now)
            .{ .background = .surface_subtle, .radius = .sm }
        else
            .{},
        .semantics = .{ .role = .listitem, .label = row.title },
    }, ui.row(.{ .gap = 8, .cross = .center }, .{
        ui.row(.{ .width = layout.ledger_number_width, .cross = .center }, .{
            if (row.now and row.playing)
                ui.icon(.{ .width = 11, .height = 11, .style_tokens = .{ .foreground = .accent } }, "play")
            else if (row.now)
                ui.icon(.{ .width = 11, .height = 11, .style_tokens = .{ .foreground = .info } }, "pause")
            else
                ui.paragraph(.{}, &.{
                    .{ .text = row.number, .monospace = true, .color = .info, .scale = readout_scale },
                }),
        }),
        // One-line ledger columns: elide a long title/artist behind a
        // trailing ellipsis at the column edge, never wrap onto the row
        // below. Titles print pale phosphor; the loaded row goes live.
        ui.text(.{ .grow = 1, .size = .sm, .wrap = false, .style_tokens = .{ .foreground = if (row.now) .accent else .success } }, row.title),
        ui.text(.{ .width = layout.ledger_artist_width, .size = .sm, .wrap = false, .style_tokens = .{ .foreground = .info } }, row.artist),
        monoCaption(ui, row.duration, layout.ledger_duration_width, .end, .info),
        // The overlay scrollbar's lane: keeps the duration digits clear
        // of the thumb (the row itself stays full width).
        ui.el(.stack, .{ .width = layout.ledger_scroll_lane }, .{}),
    }));
}

fn emptyLedger(ui: *Ui, model: *const Model) Ui.Node {
    return ui.panel(.{
        .padding = 16,
        .style_tokens = .{ .background = .background, .radius = .md },
        .semantics = .{ .label = "No tracks match" },
    }, ui.column(.{ .gap = 4 }, .{
        ui.paragraph(.{}, &.{
            .{ .text = "NO SIGNAL", .monospace = true, .color = .success },
        }),
        ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .info } }, ui.fmt("no matches for \"{s}\"", .{model.search()})),
    }));
}

/// The bottom deck strip: the loaded record's sleeve window at the
/// left, then the ON DECK stamp naming what is loaded — enamel
/// silkscreen, one line. The strip states only what the deck holds now:
/// the ledger above is the play order, so nothing else needs stating.
fn deckStrip(ui: *Ui, model: *const Model) Ui.Node {
    const track = model.nowTrack();
    return ui.row(.{ .gap = 8, .height = layout.deck_strip_height, .cross = .center, .padding = layout.deck_strip_pad, .semantics = .{ .label = "Deck strip" } }, .{
        // Leading margin: the sleeve aligns with the ledger content's
        // deeper x inset above (the strip's own padding is the rest).
        ui.el(.stack, .{ .width = layout.ledger_inset_x - layout.deck_strip_pad }, .{}),
        sleevePane(ui, model),
        enamelCaption(ui, "ON DECK //"),
        // The loaded title, stamped uppercase in the silkscreen ink
        // (hardware voice); idle wears the powered-on dashes. Elides at
        // the strip's edge, never wraps.
        if (track) |loaded|
            ui.text(.{ .grow = 1, .size = .sm, .wrap = false, .style_tokens = .{ .foreground = .text } }, upper(ui, loaded.title))
        else
            ui.text(.{ .grow = 1, .size = .sm, .wrap = false, .style_tokens = .{ .foreground = .text_muted } }, "--"),
        ui.el(.stack, .{ .width = layout.ledger_inset_x - layout.deck_strip_pad }, .{}),
    });
}

/// The sleeve window: the loaded record's committed cover in a small
/// glass pane — real album art where the hardware would show the disc.
/// Same degrade story as the player's art bay: a missing decode leaves
/// an engraved plate, never a hole. The pane is too small for lettering
/// at the pixel face's caption size, so the engraving is the powered-on
/// dashes in every fallback state; the player's full-size art bay
/// carries the NO ART stamp.
fn sleevePane(ui: *Ui, model: *const Model) Ui.Node {
    const cover = model.nowCover();
    if (cover != 0) {
        var node = ui.image(.{
            .width = layout.sleeve_size,
            .height = layout.sleeve_size,
            .image = cover,
            .semantics = .{ .label = "Sleeve" },
        });
        node.widget.image_fit = .cover;
        return node;
    }
    return ui.panel(.{
        .width = layout.sleeve_size,
        .height = layout.sleeve_size,
        .style_tokens = .{ .background = .background, .radius = .sm },
        .semantics = .{ .label = "Sleeve" },
    }, ui.column(.{ .grow = 1, .main = .center, .cross = .center }, .{
        glassCaption(ui, "--"),
    }));
}

// ---------------------------------------------------------------- shared

/// Engraved caption on GLASS: uppercase at the caption scale in the dim
/// phosphor register, natural advance — the pixel face's own spacing is
/// the honest stamping.
fn glassCaption(ui: *Ui, text: []const u8) Ui.Node {
    return ui.paragraph(.{}, &.{
        .{ .text = text, .monospace = true, .color = .info, .scale = caption_scale },
    });
}

/// Engraved caption on ENAMEL: the same stamp in the silkscreen gray.
fn enamelCaption(ui: *Ui, text: []const u8) Ui.Node {
    return ui.paragraph(.{}, &.{
        .{ .text = text, .monospace = true, .color = .text_muted, .scale = caption_scale },
    });
}

/// ASCII-uppercase into the build arena (library strings are ASCII).
fn upper(ui: *Ui, source: []const u8) []const u8 {
    const out = ui.arena.alloc(u8, source.len) catch return source;
    for (source, 0..) |byte, index| out[index] = std.ascii.toUpper(byte);
    return out;
}
