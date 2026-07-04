//! soundboard views. Markup-first: the header and now-playing bars are
//! compiled `.zml` views (see header.zml / nowplaying.zml); this file holds
//! the Zig-only sections the closed markup grammar cannot express —
//! rounded-square cover images (`ElementOptions.image` outside the avatar),
//! the album grid's column count, per-track native context menus, and the
//! scaled paragraph heading on the album detail page — plus the root view
//! that composes all of it into one tree.

const std = @import("std");
const native_sdk = @import("native_sdk");
const model_mod = @import("model.zig");

const canvas = native_sdk.canvas;

pub const Model = model_mod.Model;
pub const Msg = model_mod.Msg;
pub const Ui = canvas.Ui(Msg);

pub const header_markup = @embedFile("header.zml");
pub const nowplaying_markup = @embedFile("nowplaying.zml");
pub const CompiledHeaderView = canvas.CompiledMarkupView(Model, Msg, header_markup);
pub const CompiledNowPlayingView = canvas.CompiledMarkupView(Model, Msg, nowplaying_markup);

const grid_columns: usize = 4;
const card_width: f32 = 240;
const cover_size: f32 = card_width - 24; // card padding x2
const card_height: f32 = cover_size + 68;
const detail_cover_size: f32 = 184;
const content_padding: f32 = 24;

pub fn rootView(ui: *Ui, model: *const Model) Ui.Node {
    return ui.column(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        CompiledHeaderView.build(ui, model),
        contentView(ui, model),
        CompiledNowPlayingView.build(ui, model),
    });
}

fn contentView(ui: *Ui, model: *const Model) Ui.Node {
    return switch (model.tab) {
        .albums => if (model.open_album) |album_id|
            albumDetailView(ui, model, album_id)
        else
            albumGridView(ui, model),
        .songs => songsView(ui, model),
    };
}

// ------------------------------------------------------------- album grid

fn albumGridView(ui: *Ui, model: *const Model) Ui.Node {
    const cells = model.visibleAlbums(ui.arena);
    return ui.scroll(.{ .grow = 1, .semantics = .{ .label = "Album grid" } }, ui.column(.{ .padding = content_padding, .gap = 18 }, .{
        sectionHeading(ui, "Albums", ui.fmt("{d} of {d}", .{ cells.len, model_mod.albums.len })),
        if (cells.len == 0) emptyState(ui, model) else albumGrid(ui, cells),
    }));
}

fn albumGrid(ui: *Ui, cells: []const model_mod.AlbumCell) Ui.Node {
    var node = ui.el(.grid, .{
        .gap = 16,
        .semantics = .{ .role = .list, .label = "Albums" },
    }, ui.each(cells, albumKey, albumCard));
    node.widget.layout.columns = grid_columns;
    return node;
}

fn albumKey(cell: *const model_mod.AlbumCell) canvas.UiKey {
    return canvas.uiKey(cell.id);
}

fn albumCard(ui: *Ui, cell: *const model_mod.AlbumCell) Ui.Node {
    return ui.panel(.{
        .width = card_width,
        .height = card_height,
        .padding = 12,
        .on_press = Msg{ .open_album = cell.id },
        .context_menu = &.{
            .{ .label = "Play Album", .msg = Msg{ .play_album = cell.id } },
            .{ .label = "Open Album", .msg = Msg{ .open_album = cell.id } },
        },
        .style_tokens = .{ .background = .surface, .radius = .lg, .border_color = .border },
        .semantics = .{ .role = .listitem, .label = ui.fmt("{s} by {s}", .{ cell.title, cell.artist }) },
    }, ui.column(.{ .gap = 8 }, .{
        ui.avatar(.{
            .image = cell.cover,
            .width = cover_size,
            .height = cover_size,
            .style = .{ .radius = 8 },
            .semantics = .{ .label = ui.fmt("{s} cover", .{cell.title}) },
        }, cell.initials),
        ui.row(.{ .gap = 8, .cross = .center }, .{
            ui.column(.{ .gap = 1, .grow = 1 }, .{
                ui.text(.{}, cell.title),
                ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, cell.artist),
            }),
            if (cell.playing)
                ui.el(.badge, .{ .variant = .primary, .text = "Playing" }, .{})
            else
                ui.el(.stack, .{}, .{}),
        }),
    }));
}

fn emptyState(ui: *Ui, model: *const Model) Ui.Node {
    return ui.panel(.{
        .padding = 24,
        .style_tokens = .{ .background = .surface, .radius = .lg, .border_color = .border },
        .semantics = .{ .label = "No albums match" },
    }, ui.column(.{ .gap = 6 }, .{
        ui.text(.{}, ui.fmt("No matches for \"{s}\"", .{model.search()})),
        ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "Try an album, artist, or song title."),
    }));
}

// ----------------------------------------------------------- album detail

fn albumDetailView(ui: *Ui, model: *const Model, album_id: u8) Ui.Node {
    const album = model_mod.albumById(album_id);
    const rows = model.albumTrackRows(ui.arena, album_id);
    return ui.scroll(.{ .grow = 1, .semantics = .{ .label = "Album detail" } }, ui.column(.{ .padding = content_padding, .gap = 18 }, .{
        ui.row(.{}, .{
            backButton(ui),
            ui.spacer(1),
        }),
        ui.row(.{ .gap = 20 }, .{
            ui.avatar(.{
                .image = model.coverFor(album.id),
                .width = detail_cover_size,
                .height = detail_cover_size,
                .style = .{ .radius = 10 },
                .semantics = .{ .label = ui.fmt("{s} cover", .{album.title}) },
            }, album.initials),
            ui.column(.{ .gap = 8, .grow = 1, .main = .end }, .{
                ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "Album"),
                ui.paragraph(.{ .semantics = .{ .label = album.title } }, &.{
                    .{ .text = album.title, .weight = .bold, .scale = 1.9 },
                }),
                ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, ui.fmt("{s} · {d} · {d} tracks", .{ album.artist, album.year, rows.len })),
                ui.row(.{ .gap = 8, .cross = .center }, .{
                    playAlbumButton(ui, album.id),
                    ui.spacer(1),
                }),
            }),
        }),
        trackList(ui, rows, "Album tracks"),
    }));
}

/// Icon+text buttons via the overlay idiom (the mirror of the hotspot
/// idiom notes uses): the button is the visual and the labeled hit
/// target, and a centered row of icon + text is stacked over it. Icons
/// and layout rows are never hit-tested, so presses there fall through
/// to the button; the label TEXT is a hit target, so it carries the same
/// on_press — either way the one message dispatches. The stack and text
/// widths carry slack over the tight text measure for the macOS packet
/// rasterizer's own font metrics (durationText's idiom).
fn backButton(ui: *Ui) Ui.Node {
    return ui.el(.stack, .{ .width = 156, .height = 28 }, .{
        ui.button(.{ .variant = .ghost, .size = .sm, .on_press = .close_album, .semantics = .{ .label = "Back to albums" } }, ""),
        ui.row(.{ .main = .center, .cross = .center, .gap = 6 }, .{
            ui.icon(.{ .width = 14, .height = 14, .style_tokens = .{ .foreground = .text_muted } }, "chevron-left"),
            ui.text(.{ .size = .sm, .width = 104, .on_press = .close_album }, "Back to albums"),
        }),
    });
}

fn playAlbumButton(ui: *Ui, album_id: u8) Ui.Node {
    return ui.el(.stack, .{ .width = 148, .height = 34 }, .{
        ui.button(.{ .variant = .primary, .on_press = Msg{ .play_album = album_id }, .semantics = .{ .label = "Play album" } }, ""),
        ui.row(.{ .main = .center, .cross = .center, .gap = 7 }, .{
            ui.icon(.{ .width = 14, .height = 14, .style_tokens = .{ .foreground = .accent_text } }, "play"),
            ui.text(.{ .size = .sm, .width = 86, .on_press = Msg{ .play_album = album_id }, .style_tokens = .{ .foreground = .accent_text } }, "Play album"),
        }),
    });
}

// ------------------------------------------------------------------ songs

fn songsView(ui: *Ui, model: *const Model) Ui.Node {
    const rows = model.visibleTracks(ui.arena);
    return ui.scroll(.{ .grow = 1, .semantics = .{ .label = "All songs" } }, ui.column(.{ .padding = content_padding, .gap = 18 }, .{
        sectionHeading(ui, "Songs", ui.fmt("{d} of {d}", .{ rows.len, model_mod.tracks.len })),
        if (rows.len == 0) emptyState(ui, model) else trackList(ui, rows, "Songs"),
    }));
}

// ------------------------------------------------------------- track rows

fn trackList(ui: *Ui, rows: []const model_mod.TrackRow, label: []const u8) Ui.Node {
    return ui.el(.list, .{
        .gap = 2,
        .semantics = .{ .role = .list, .label = label },
    }, ui.each(rows, trackKey, trackRowView));
}

fn trackKey(row: *const model_mod.TrackRow) canvas.UiKey {
    return canvas.uiKey(row.id);
}

/// One pressable track row. The native context menu is the Zig-only piece:
/// right/ctrl-click presents the OS menu and each item dispatches a typed
/// Msg exactly like a press.
fn trackRowView(ui: *Ui, row: *const model_mod.TrackRow) Ui.Node {
    return ui.panel(.{
        .global_key = canvas.uiKey(@as(u32, row.id)),
        .height = 44,
        .padding = 10,
        .on_press = Msg{ .play_track = row.id },
        // Two items per row on purpose: the per-view context-menu budget is
        // 128 items (canvas_limits), and the all-songs list mounts 48 rows.
        .context_menu = &.{
            .{ .label = "Play Next", .msg = Msg{ .queue_track = row.id } },
            .{ .label = "Copy Title", .msg = Msg{ .copy_title = row.id } },
        },
        .style_tokens = if (row.now)
            .{ .background = .surface_subtle, .radius = .md }
        else
            .{ .radius = .md },
        .semantics = .{ .role = .listitem, .label = row.title },
    }, ui.row(.{ .gap = 12, .cross = .center }, .{
        trackIndicator(ui, row),
        if (row.subtitle.len == 0)
            ui.text(.{ .grow = 1, .style_tokens = if (row.now) .{ .foreground = .accent } else .{} }, row.title)
        else
            ui.column(.{ .gap = 1, .grow = 1 }, .{
                ui.text(.{ .style_tokens = if (row.now) .{ .foreground = .accent } else .{} }, row.title),
                ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, row.subtitle),
            }),
        if (row.queued)
            ui.el(.badge, .{ .variant = .secondary, .text = "Up next" }, .{})
        else
            ui.el(.stack, .{}, .{}),
        durationText(ui, row.duration),
    }));
}

/// The leading track-row slot: a vector play icon on the playing row, a
/// muted pause icon on the loaded-but-paused row, and the track number
/// everywhere else. Icons are decoration (never hit-tested), so the row's
/// press handling is untouched; the fixed 24px slot keeps the number
/// column's alignment.
fn trackIndicator(ui: *Ui, row: *const model_mod.TrackRow) Ui.Node {
    if (!row.now) {
        return ui.text(.{ .width = 24, .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, row.number);
    }
    return ui.row(.{ .width = 24, .cross = .center }, .{
        if (row.playing)
            ui.icon(.{ .width = 14, .height = 14, .style_tokens = .{ .foreground = .accent } }, "play")
        else
            ui.icon(.{ .width = 14, .height = 14, .style_tokens = .{ .foreground = .text_muted } }, "pause"),
    });
}

/// Right-aligned fixed-width duration. The width carries slack on purpose:
/// the macOS packet rasterizer re-lays text out with its own font metrics,
/// so a tight intrinsic measure can wrap host-side.
fn durationText(ui: *Ui, duration: []const u8) Ui.Node {
    var node = ui.text(.{ .width = 44, .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, duration);
    node.widget.text_alignment = .end;
    return node;
}

// ---------------------------------------------------------------- shared

fn sectionHeading(ui: *Ui, title: []const u8, count: []const u8) Ui.Node {
    // The explicit width carries ~20% slack over the tight intrinsic
    // measure: the macOS packet rasterizer re-measures with its own font
    // stack, and a tight paragraph box wraps host-side ("Song\ns").
    const width = 14 * @as(f32, @floatFromInt(title.len)) + 12;
    return ui.row(.{ .gap = 10, .cross = .center }, .{
        ui.paragraph(.{ .width = width, .semantics = .{ .label = title } }, &.{
            .{ .text = title, .weight = .bold, .scale = 1.45 },
        }),
        ui.el(.badge, .{ .variant = .secondary, .text = count }, .{}),
        ui.spacer(1),
    });
}
