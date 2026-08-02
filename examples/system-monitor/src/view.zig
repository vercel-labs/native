//! system-monitor views. Markup-first where markup fits: the header bar
//! (status line holding the trailing corner) and the three sparkline
//! charts (one `<chart>` per tile: token-tinted bar/area series binding
//! the model's NaN-padded sample windows) are compiled `.native` views.
//! Everything else is Zig because it needs what the closed markup
//! grammar excludes — the tiles' bold-span stat paragraphs (sized by the
//! heading typography rung), per-row native context menus, and the modal
//! SIGTERM confirmation overlaid through a z-stack root; the toolbar and
//! table ride along in Zig so the whole working surface composes in one
//! place.
//!
//! Control sizing rule: every control in a row shares ONE size register
//! (the toolbar is all `.sm` — button, filter field, sort toggles), so
//! the row renders one height. Ad-hoc pixel heights on pressable panels
//! never match the control scale; compose rows from real controls.

const std = @import("std");
const native_sdk = @import("native_sdk");
const model_mod = @import("model.zig");

const canvas = native_sdk.canvas;
const sampler = model_mod.sampler;

pub const Model = model_mod.Model;
pub const Msg = model_mod.Msg;
pub const Ui = canvas.Ui(Msg);

pub const header_markup = @embedFile("header.native");
/// The header's import closure: the embedded source set feeds the
/// compiled engine, the interpreter parity test, and the hot-reload
/// baseline, so all three see the same document.
pub const header_markup_files = [_]canvas.ui_markup.SourceFile{
    .{ .path = "header.native", .source = header_markup },
    .{ .path = "header_status.native", .source = @embedFile("header_status.native") },
};
pub const CompiledHeaderView = canvas.CompiledMarkupImports(Model, Msg, "header.native", &header_markup_files);

// The sparkline charts, one compiled markup fragment per stat tile:
// each is a single `<chart>` whose series binds the model's NaN-padded
// window (cpuSpark/memSpark/procSpark), built into the Zig tile chrome
// as an ordinary child.
pub const CpuSparkView = canvas.CompiledMarkupView(Model, Msg, @embedFile("spark_cpu.native"));
pub const MemSparkView = canvas.CompiledMarkupView(Model, Msg, @embedFile("spark_mem.native"));
pub const ProcSparkView = canvas.CompiledMarkupView(Model, Msg, @embedFile("spark_proc.native"));

// The uptime tile's hero stat: a markup span paragraph (`<text>` with a
// bold `<span>` run), compiled like the sparks and composed into the Zig
// tile. The tests hold it widget-for-widget equal to the builder
// paragraph it replaced (ui.paragraph with one bold span).
pub const UptimeValueView = canvas.CompiledMarkupView(Model, Msg, @embedFile("uptime_value.native"));

// ------------------------------------------------------- layout constants
// Precision layout, calculator-style: the sparkline geometry drives the
// tile width and the tile row drives the window. The tests assert the
// tiles land exactly on these frames (the spark_*.native charts carry
// the same 239x32 box as literals; the frame tests hold the two equal).
// The 239 width is inherited from the pre-primitive bar geometry
// (60 x 3px bars + 59 x 1px gaps), kept so the window layout is
// byte-stable across the chart retrofit.

pub const spark_samples = model_mod.history_len;
pub const spark_height: f32 = 32;
pub const spark_width: f32 = spark_samples * 4 - 1; // 239

pub const tile_padding: f32 = 14;
pub const tile_width: f32 = spark_width + tile_padding * 2; // 267
// Budgeted from the tile column at rest: sm label line (16.25) + the
// heading-rung stat line (28 x 1.25 = 35) + sm detail line (16.25) +
// spark (32) + three 4px gaps + 14px padding twice = 139.5, kept on
// the even-number rhythm.
pub const tile_height: f32 = 140;
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
            .spark = CpuSparkView.build(ui, model),
        }),
        statTile(ui, .{
            .label = "Memory",
            .value = model.memValue(ui.arena),
            .detail = model.memDetail(ui.arena),
            .spark = MemSparkView.build(ui, model),
        }),
        statTile(ui, .{
            .label = "Processes",
            .value = model.procValue(ui.arena),
            .detail = ui.fmt("top {d} by CPU shown", .{model_mod.max_table_rows}),
            .spark = ProcSparkView.build(ui, model),
        }),
        uptimeTile(ui, model),
    });
}

const TileSpec = struct {
    label: []const u8,
    value: []const u8,
    detail: []const u8,
    /// The tile's sparkline: a compiled markup `<chart>` fragment built
    /// against the model, placed as an ordinary child.
    spark: Ui.Node,
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
        ui.paragraph(.{ .width = spark_width, .size = .heading, .semantics = .{ .label = spec.value } }, &.{
            .{ .text = spec.value, .weight = .bold },
        }),
        ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, spec.detail),
        spec.spark,
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
        UptimeValueView.build(ui, model),
        // One-line tile caption: elide at the tile width, never wrap
        // over the caption line below.
        ui.text(.{ .width = spark_width, .size = .sm, .wrap = false, .style_tokens = .{ .foreground = .text_muted } }, "since boot (pid 1 elapsed time)"),
        ui.column(.{ .height = spark_height, .main = .end, .gap = 3 }, .{
            ui.text(.{ .width = spark_width, .size = .sm, .wrap = false, .style_tokens = .{ .foreground = .text_muted } }, ui.fmt("{d} samples kept · {d} s cadence", .{
                model_mod.history_len, model_mod.sample_interval_ms / 1000,
            })),
        }),
    }));
}

// --------------------------------------------------------------- toolbar

// Settings has no toolbar button: it opens through the app menu and its
// standard keyboard shortcut (primary+comma), mapped in main.zig's
// `command`.
fn toolbarView(ui: *Ui, model: *const Model) Ui.Node {
    return ui.row(.{ .gap = 10, .cross = .center, .semantics = .{ .label = "Table toolbar" } }, .{
        pauseButton(ui, model),
        // The search field carries the built-in trailing clear
        // affordance whenever it holds text — no external Clear chip.
        ui.el(.search_field, .{
            .size = .sm,
            .width = 260,
            .text = model.search(),
            .placeholder = "Filter by name or pid",
            .on_input = Ui.inputMsg(.search_edit),
            .semantics = .{ .label = "Filter processes" },
        }, .{}),
        ui.spacer(1),
        ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "Sort"),
        sortChips(ui, model),
        sortDirectionIcon(ui, model),
    });
}

// ------------------------------------------------- settings window view

/// The settings WINDOW's whole canvas: a model-declared secondary
/// window (`windows_fn` declares it while `settings_open` is set), so
/// this view rebuilds from the same model as the main canvas — flipping
/// the sampling switch here updates both windows on the same dispatch,
/// live, with no Apply step. Appearance is not a setting: the app
/// follows the system, so both windows retheme together through
/// `on_appearance`.
///
/// The register is the standard grouped settings form: one row per
/// setting — label and description leading, the control trailing. The
/// window's titlebar carries the "Settings" title, so the content
/// repeats no title and explains no window mechanics.
pub fn settingsView(ui: *Ui, model: *const Model) Ui.Node {
    return ui.column(.{
        .grow = 1,
        .padding = 20,
        .style_tokens = .{ .background = .background },
        .semantics = .{ .label = "Settings window" },
    }, .{
        ui.row(.{ .gap = 12, .cross = .center }, .{
            ui.column(.{ .grow = 1, .gap = 2 }, .{
                ui.text(.{}, "Sampling"),
                ui.text(.{ .size = .sm, .wrap = false, .style_tokens = .{ .foreground = .text_muted } }, ui.fmt("{d} samples kept · one every {d} s while live", .{
                    model_mod.history_len, model_mod.sample_interval_ms / 1000,
                })),
            }),
            ui.el(.switch_control, .{
                .selected = model.sampling(),
                .on_toggle = .toggle_sampling,
                .semantics = .{ .label = "Pause or resume sampling" },
            }, .{}),
        }),
    });
}

/// Pause/resume: a real button on the toolbar's `.sm` register, with the
/// play/pause icon drawn inline before the verb (icon + label are one
/// widget, so both follow the control's states together).
fn pauseButton(ui: *Ui, model: *const Model) Ui.Node {
    return ui.button(.{
        .size = .sm,
        .variant = .outline,
        .icon = if (model.paused) "play" else "pause",
        .on_press = .toggle_sampling,
        .semantics = .{ .label = "Pause or resume sampling" },
    }, if (model.paused) "Resume" else "Pause");
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
        if (rows.len == 0) emptyState(ui, model) else processList(ui, model, rows),
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
        rightAlignedHint(ui, "right-click a row for SIGTERM (confirmed first)"),
    });
}

/// The table is the REAL table register: `table` > `data_row` >
/// `data_cell`, so the engine owns the chrome — hairline separators
/// under every row but the last (the header's line comes free), a
/// full-width hover wash per row, no outer box, no cell gridlines. The
/// scroll is CONTROLLED (the model stores the applied offset and echoes
/// it back), so the 2 s sample rebuild can never reset the table
/// mid-gesture.
fn processList(ui: *Ui, model: *const Model, rows: []const model_mod.TableRow) Ui.Node {
    return ui.scroll(.{
        .grow = 1,
        .value = model.table_scroll,
        .on_scroll = Ui.scrollMsg(.table_scrolled),
        .semantics = .{ .label = "Process table" },
    }, ui.el(.table, .{ .semantics = .{ .label = "Processes by CPU" } }, .{
        columnHeadings(ui),
        ui.each(rows, rowKey, rowView),
    }));
}

/// The muted small header row; numeric columns right-align like the
/// values under them.
fn columnHeadings(ui: *Ui) Ui.Node {
    return ui.el(.data_row, .{ .height = 32, .gap = 12, .cross = .center }, .{
        ui.el(.data_cell, .{ .text = "PID", .width = 80, .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, .{}),
        ui.el(.data_cell, .{ .text = "Command", .grow = 1, .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, .{}),
        ui.el(.data_cell, .{ .text = "CPU %", .width = 80, .size = .sm, .text_alignment = .end, .style_tokens = .{ .foreground = .text_muted } }, .{}),
        ui.el(.data_cell, .{ .text = "Memory", .width = 100, .size = .sm, .text_alignment = .end, .style_tokens = .{ .foreground = .text_muted } }, .{}),
    });
}

/// Right-aligned muted hint. The explicit width is the alignment box:
/// `text_alignment = .end` needs a frame wider than the content to have
/// an edge to align against.
fn rightAlignedHint(ui: *Ui, text: []const u8) Ui.Node {
    // Width-constrained one-line hint: elide rather than wrap over the
    // table header below.
    var node = ui.text(.{ .width = 380, .size = .sm, .wrap = false, .style_tokens = .{ .foreground = .text_muted } }, text);
    node.widget.text_alignment = .end;
    return node;
}

fn rowKey(row: *const model_mod.TableRow) canvas.UiKey {
    return canvas.uiKey(row.pid);
}

/// One process row on the table register: a `data_row` whose hover wash
/// the engine paints full-width, with `data_cell` columns (fixed widths
/// keep the numeric right edges aligned regardless of digit count). The
/// native context menu is the kill seam: Terminate opens the
/// confirmation dialog (never the signal directly), Copy Name runs the
/// clipboard effect.
fn rowView(ui: *Ui, row: *const model_mod.TableRow) Ui.Node {
    return ui.el(.data_row, .{
        .global_key = canvas.uiKey(row.pid),
        .height = table_row_height,
        .gap = 12,
        .cross = .center,
        .context_menu = &.{
            .{ .label = "Terminate (SIGTERM)…", .msg = Msg{ .request_kill = row.pid } },
            .{ .separator = true },
            .{ .label = "Copy Name", .msg = Msg{ .copy_name = row.pid } },
        },
        .semantics = .{ .label = ui.fmt("{s} pid {s}", .{ row.name, row.pid_text }) },
    }, .{
        ui.el(.data_cell, .{ .text = row.pid_text, .width = 80, .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, .{}),
        ui.el(.data_cell, .{ .text = row.name, .grow = 1 }, .{}),
        ui.el(.data_cell, .{ .text = row.cpu_text, .width = 80, .size = .sm, .text_alignment = .end }, .{}),
        ui.el(.data_cell, .{ .text = row.mem_text, .width = 100, .size = .sm, .text_alignment = .end, .style_tokens = .{ .foreground = .text_muted } }, .{}),
    });
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
        // The honest scope hint: search only sees the top-K-by-CPU
        // selection the sampler keeps (`sampler.max_rows`), so a miss
        // may simply be a quiet process outside it.
        if (model.samples_taken == 0)
            ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "Filter matches command names and pids.")
        else
            ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, ui.fmt("Search sees the top {d} processes by CPU — filter matches command names and pids.", .{sampler.max_rows})),
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

/// The SIGTERM confirmation: a centered dialog whose modal chrome
/// paints the scrim (token-driven dim + backdrop blur across the whole
/// window). The full-bleed panel underneath is the cancel catcher —
/// clicking outside the dialog never terminates anything.
fn confirmOverlay(ui: *Ui, model: *const Model) Ui.Node {
    const pending = model.pending_kill orelse unreachable;
    // A panel, not a column: the catcher must claim the press route
    // itself, and a fully transparent zero-radius fill paints nothing
    // while keeping the whole window pressable (the dialog chrome owns
    // the visible scrim).
    return ui.panel(.{
        .grow = 1,
        .on_press = .cancel_kill,
        .style = .{ .background = canvas.Color.rgba8(0, 0, 0, 0), .radius = 0, .stroke_width = 0 },
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
