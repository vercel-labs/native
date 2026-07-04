//! Docs component-preview generator: renders every built-in component
//! through the deterministic reference renderer — the same offscreen
//! pipeline the homepage showcase shots use — and writes theme-aware
//! webp pairs into `docs/public/components/`, plus the markup vocabulary
//! JSON (`docs/src/lib/component-vocab.json`) the Components pages read
//! their attribute tables from, so the docs never hand-invent rows.
//!
//! Regenerate everything with ONE command from the repo root:
//!
//!   zig build docs-component-previews
//!
//! Deterministic: the same engine produces the same pixels (estimator
//! text metrics, fixed frame index, no platform fonts). The PNG → webp
//! conversion shells out to `cwebp` in lossless mode (`brew install
//! webp`), so bytes are stable for a given cwebp release.

const std = @import("std");
const native_sdk = @import("native_sdk");
const markup_docs = @import("native-sdk/markup_docs.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const platform = native_sdk.platform;

const Msg = union(enum) { noop };
const Ui = canvas.Ui(Msg);
const Node = Ui.Node;
const Md = canvas.markdown.Markdown(Msg);

/// Logical tile width; every preview renders at 2x, so files are
/// `2 * tile_width` pixels wide.
const tile_width: f32 = 560;
const icon_tile_size: f32 = 56;
const view_label = "preview";
const png_cache_dir = "/tmp/native-sdk-component-previews";

/// Which widget the pointer hovers before capture (hover styling is
/// engine-owned render state, not a source attribute): the `index`-th
/// widget of `kind` in layout order.
const Hover = struct {
    kind: canvas.WidgetKind,
    index: usize = 0,
};

const Scene = struct {
    /// Output stem: `<out_dir>/<name>-{light,dark}.webp`.
    name: []const u8,
    height: f32,
    width: f32 = tile_width,
    build: *const fn (ui: *Ui) Node,
    hover: ?Hover = null,
};

const scenes = [_]Scene{
    .{ .name = "button", .height = 160, .build = buildButton },
    .{ .name = "button-sizes", .height = 160, .build = buildButtonSizes },
    .{ .name = "button-icons", .height = 160, .build = buildButtonIcons },
    .{ .name = "button-states", .height = 160, .build = buildButtonStates, .hover = .{ .kind = .button, .index = 1 } },
    .{ .name = "button-group", .height = 160, .build = buildButtonGroup },
    .{ .name = "toggle", .height = 160, .build = buildToggle },
    .{ .name = "toggle-group", .height = 160, .build = buildToggleGroup },
    .{ .name = "input", .height = 260, .build = buildInput },
    .{ .name = "search-field", .height = 160, .build = buildSearchField },
    .{ .name = "textarea", .height = 220, .build = buildTextarea },
    .{ .name = "select", .height = 180, .build = buildSelect },
    .{ .name = "combobox", .height = 160, .build = buildCombobox },
    .{ .name = "dropdown-menu", .height = 300, .build = buildDropdownMenu },
    .{ .name = "checkbox", .height = 180, .build = buildCheckbox },
    .{ .name = "radio-group", .height = 180, .build = buildRadioGroup },
    .{ .name = "switch", .height = 160, .build = buildSwitch },
    .{ .name = "slider", .height = 180, .build = buildSlider },
    .{ .name = "progress", .height = 140, .build = buildProgress },
    .{ .name = "badge", .height = 140, .build = buildBadge },
    .{ .name = "avatar", .height = 160, .build = buildAvatar },
    .{ .name = "card", .height = 300, .build = buildCard },
    .{ .name = "panel", .height = 180, .build = buildPanel },
    .{ .name = "alert", .height = 220, .build = buildAlert },
    .{ .name = "accordion", .height = 240, .build = buildAccordion },
    .{ .name = "tabs", .height = 160, .build = buildTabs },
    .{ .name = "menu", .height = 280, .build = buildMenu },
    .{ .name = "tooltip", .height = 160, .build = buildTooltip },
    .{ .name = "bubble", .height = 200, .build = buildBubble },
    .{ .name = "breadcrumb", .height = 140, .build = buildBreadcrumb },
    .{ .name = "pagination", .height = 150, .build = buildPagination },
    .{ .name = "list", .height = 260, .build = buildList },
    .{ .name = "table", .height = 240, .build = buildTable },
    .{ .name = "tree", .height = 280, .build = buildTree },
    .{ .name = "split", .height = 240, .build = buildSplit },
    .{ .name = "scroll", .height = 240, .build = buildScroll },
    .{ .name = "dialog", .height = 310, .build = buildDialog },
    .{ .name = "drawer", .height = 300, .build = buildDrawer },
    .{ .name = "sheet", .height = 300, .build = buildSheet },
    .{ .name = "separator", .height = 200, .build = buildSeparator },
    .{ .name = "skeleton", .height = 200, .build = buildSkeleton },
    .{ .name = "spinner", .height = 140, .build = buildSpinner },
    .{ .name = "markdown", .height = 440, .build = buildMarkdown },
    .{ .name = "icon", .height = 150, .build = buildIconHero },
    .{ .name = "chart", .height = 260, .build = buildChart },
    .{ .name = "status-bar", .height = 170, .build = buildStatusBar },
    .{ .name = "stepper", .height = 160, .build = buildStepper },
    .{ .name = "timeline", .height = 320, .build = buildTimeline },
};

// ------------------------------------------------------------- scenes

/// Padded, centered preview tile on the background token — the shadcn
/// component-preview framing.
fn tile(ui: *Ui, children: anytype) Node {
    return ui.column(.{ .padding = 32, .main = .center, .cross = .center, .grow = 1 }, children);
}

fn tileStart(ui: *Ui, children: anytype) Node {
    return ui.column(.{ .padding = 32, .main = .center, .cross = .stretch, .grow = 1 }, children);
}

fn buildButton(ui: *Ui) Node {
    return tile(ui, .{
        ui.row(.{ .gap = 12, .cross = .center }, .{
            ui.button(.{ .variant = .primary }, "Button"),
            ui.button(.{ .variant = .secondary }, "Secondary"),
            ui.button(.{ .variant = .outline }, "Outline"),
            ui.button(.{ .variant = .ghost }, "Ghost"),
            ui.button(.{ .variant = .destructive }, "Destructive"),
        }),
    });
}

fn buildButtonSizes(ui: *Ui) Node {
    return tile(ui, .{
        ui.row(.{ .gap = 12, .cross = .center }, .{
            ui.button(.{ .variant = .outline, .size = .sm }, "Small"),
            ui.button(.{ .variant = .outline }, "Default"),
            ui.button(.{ .variant = .outline, .size = .lg }, "Large"),
            ui.button(.{ .variant = .outline, .size = .icon, .icon = "plus" }, ""),
        }),
    });
}

fn buildButtonIcons(ui: *Ui) Node {
    return tile(ui, .{
        ui.row(.{ .gap = 12, .cross = .center }, .{
            ui.button(.{ .variant = .primary, .icon = "download" }, "Download"),
            ui.button(.{ .variant = .outline, .icon = "git-branch" }, "New Branch"),
            ui.button(.{ .variant = .secondary, .size = .icon, .icon = "settings" }, ""),
        }),
    });
}

fn buildButtonStates(ui: *Ui) Node {
    return tile(ui, .{
        ui.row(.{ .gap = 12, .cross = .center }, .{
            ui.button(.{ .variant = .primary }, "Default"),
            ui.button(.{ .variant = .primary }, "Hovered"),
            ui.button(.{ .variant = .primary, .disabled = true }, "Disabled"),
        }),
    });
}

fn buildButtonGroup(ui: *Ui) Node {
    return tile(ui, .{
        ui.el(.button_group, .{}, .{
            ui.button(.{ .variant = .outline }, "Years"),
            ui.button(.{ .variant = .outline, .selected = true }, "Months"),
            ui.button(.{ .variant = .outline }, "Days"),
        }),
    });
}

fn buildToggle(ui: *Ui) Node {
    return tile(ui, .{
        ui.row(.{ .gap = 12, .cross = .center }, .{
            ui.el(.toggle, .{ .text = "Bold", .selected = true }, .{}),
            ui.el(.toggle, .{ .text = "Italic" }, .{}),
            ui.el(.toggle, .{ .text = "Underline", .disabled = true }, .{}),
        }),
    });
}

fn buildToggleGroup(ui: *Ui) Node {
    return tile(ui, .{
        ui.el(.toggle_group, .{}, .{
            ui.el(.toggle_button, .{ .text = "Left", .selected = true }, .{}),
            ui.el(.toggle_button, .{ .text = "Center" }, .{}),
            ui.el(.toggle_button, .{ .text = "Right" }, .{}),
        }),
    });
}

fn buildInput(ui: *Ui) Node {
    return tile(ui, .{
        ui.column(.{ .gap = 12, .width = 280 }, .{
            ui.el(.input, .{ .placeholder = "Email address" }, .{}),
            ui.el(.text_field, .{ .text = "native-sdk" }, .{}),
            ui.el(.input, .{ .placeholder = "Disabled", .disabled = true }, .{}),
        }),
    });
}

fn buildSearchField(ui: *Ui) Node {
    return tile(ui, .{
        ui.column(.{ .gap = 12, .width = 280 }, .{
            ui.el(.search_field, .{ .placeholder = "Search notes…" }, .{}),
        }),
    });
}

fn buildTextarea(ui: *Ui) Node {
    return tile(ui, .{
        ui.el(.textarea, .{ .width = 320, .height = 96, .placeholder = "Write a release note…" }, .{}),
    });
}

fn buildSelect(ui: *Ui) Node {
    return tile(ui, .{
        ui.column(.{ .gap = 12, .width = 240 }, .{
            ui.el(.select, .{ .text = "Production" }, .{}),
            ui.el(.select, .{ .text = "Staging", .disabled = true }, .{}),
        }),
    });
}

fn buildCombobox(ui: *Ui) Node {
    return tile(ui, .{
        ui.el(.combobox, .{ .width = 240, .placeholder = "Search frameworks…" }, .{}),
    });
}

fn buildDropdownMenu(ui: *Ui) Node {
    return ui.column(.{ .padding = 32, .cross = .center, .grow = 1 }, .{
        ui.stack(.{}, .{
            ui.button(.{ .variant = .outline, .icon = "chevron-down" }, "Actions"),
            ui.el(.dropdown_menu, .{ .anchor = .below, .min_width = 200 }, .{
                ui.el(.menu_item, .{ .text = "Duplicate", .icon = "copy" }, .{}),
                ui.el(.menu_item, .{ .text = "Rename", .icon = "edit" }, .{}),
                ui.el(.menu_item, .{ .text = "Download", .icon = "download" }, .{}),
                ui.separator(.{}),
                ui.el(.menu_item, .{ .text = "Delete", .icon = "trash" }, .{}),
            }),
        }),
    });
}

fn buildCheckbox(ui: *Ui) Node {
    return tile(ui, .{
        ui.column(.{ .gap = 12 }, .{
            ui.checkbox(.{ .text = "Accept terms and conditions", .checked = true }),
            ui.checkbox(.{ .text = "Send usage reports" }),
            ui.checkbox(.{ .text = "Managed by your organization", .checked = true, .disabled = true }),
        }),
    });
}

fn buildRadioGroup(ui: *Ui) Node {
    return tile(ui, .{
        ui.el(.radio_group, .{ .gap = 12 }, .{
            ui.el(.radio, .{ .text = "Default", .checked = true }, .{}),
            ui.el(.radio, .{ .text = "Comfortable" }, .{}),
            ui.el(.radio, .{ .text = "Compact", .disabled = true }, .{}),
        }),
    });
}

fn buildSwitch(ui: *Ui) Node {
    return tile(ui, .{
        ui.column(.{ .gap = 12 }, .{
            ui.el(.switch_control, .{ .text = "Airplane mode", .checked = true }, .{}),
            ui.el(.switch_control, .{ .text = "Notifications" }, .{}),
            ui.el(.switch_control, .{ .text = "Managed setting", .disabled = true }, .{}),
        }),
    });
}

fn buildSlider(ui: *Ui) Node {
    return tile(ui, .{
        ui.column(.{ .gap = 20, .width = 280 }, .{
            ui.el(.slider, .{ .value = 0.4 }, .{}),
            ui.el(.slider, .{ .value = 0.7, .disabled = true }, .{}),
        }),
    });
}

fn buildProgress(ui: *Ui) Node {
    return tile(ui, .{
        ui.el(.progress, .{ .value = 0.62, .width = 280 }, .{}),
    });
}

fn buildBadge(ui: *Ui) Node {
    return tile(ui, .{
        ui.row(.{ .gap = 10, .cross = .center }, .{
            ui.el(.badge, .{ .text = "Badge" }, .{}),
            ui.el(.badge, .{ .text = "Secondary", .variant = .secondary }, .{}),
            ui.el(.badge, .{ .text = "Outline", .variant = .outline }, .{}),
            ui.el(.badge, .{ .text = "Destructive", .variant = .destructive }, .{}),
            ui.el(.badge, .{ .text = "Verified", .variant = .secondary, .icon = "check" }, .{}),
        }),
    });
}

fn buildAvatar(ui: *Ui) Node {
    return tile(ui, .{
        ui.row(.{ .gap = 12, .cross = .center }, .{
            ui.avatar(.{}, "ZN"),
            ui.avatar(.{}, "CT"),
            ui.avatar(.{}, "NS"),
        }),
    });
}

fn buildCard(ui: *Ui) Node {
    return tile(ui, .{
        ui.el(.card, .{ .width = 340 }, .{
            ui.column(.{ .gap = 12, .padding = 4 }, .{
                ui.text(.{}, "Deploy your app"),
                ui.text(.{ .wrap = true, .style_tokens = .{ .foreground = .text_muted } }, "The runtime packages your views, commands, and assets into one native binary."),
                ui.row(.{ .gap = 8 }, .{
                    ui.button(.{ .variant = .primary }, "Deploy"),
                    ui.button(.{ .variant = .ghost }, "Cancel"),
                }),
            }),
        }),
    });
}

fn buildPanel(ui: *Ui) Node {
    return tile(ui, .{
        ui.panel(.{ .width = 340, .padding = 16 }, .{
            ui.column(.{ .gap = 6 }, .{
                ui.text(.{}, "Panel"),
                ui.text(.{ .wrap = true, .style_tokens = .{ .foreground = .text_muted } }, "A plain surface container: background, border, radius."),
            }),
        }),
    });
}

fn buildAlert(ui: *Ui) Node {
    return tile(ui, .{
        ui.column(.{ .gap = 12, .width = 380 }, .{
            ui.el(.alert, .{ .text = "A new version of the shell is available." }, .{}),
            ui.el(.alert, .{ .text = "Your session has expired. Sign in again.", .variant = .destructive }, .{}),
        }),
    });
}

fn buildAccordion(ui: *Ui) Node {
    return tile(ui, .{
        ui.column(.{ .gap = 8, .width = 380 }, .{
            ui.el(.accordion, .{ .text = "Is it accessible?", .selected = true, .height = 116, .gap = 4 }, .{
                ui.column(.{ .padding = 14 }, .{
                    ui.text(.{ .wrap = true, .style_tokens = .{ .foreground = .text_muted } }, "Yes. Widgets carry semantic roles and one roving focus set."),
                }),
            }),
            ui.el(.accordion, .{ .text = "Is it styled?", .height = 44 }, .{
                ui.text(.{}, ""),
            }),
        }),
    });
}

fn buildTabs(ui: *Ui) Node {
    return tile(ui, .{
        ui.el(.tabs, .{}, .{
            ui.el(.segmented_control, .{ .text = "Account", .selected = true }, .{}),
            ui.el(.segmented_control, .{ .text = "Password" }, .{}),
            ui.el(.segmented_control, .{ .text = "Team" }, .{}),
        }),
    });
}

fn buildMenu(ui: *Ui) Node {
    return tile(ui, .{
        ui.el(.menu_surface, .{ .min_width = 220 }, .{
            ui.el(.menu_item, .{ .text = "Cut", .icon = "edit" }, .{}),
            ui.el(.menu_item, .{ .text = "Copy", .icon = "copy" }, .{}),
            ui.el(.menu_item, .{ .text = "Paste", .icon = "file-text", .disabled = true }, .{}),
            ui.separator(.{}),
            ui.el(.menu_item, .{ .text = "Select All" }, .{}),
        }),
    });
}

fn buildTooltip(ui: *Ui) Node {
    return tile(ui, .{
        ui.column(.{ .gap = 8, .cross = .center }, .{
            ui.el(.tooltip, .{ .text = "Add to library" }, .{}),
            ui.button(.{ .variant = .outline }, "Hover"),
        }),
    });
}

fn buildBubble(ui: *Ui) Node {
    return tile(ui, .{
        ui.column(.{ .gap = 10, .width = 340 }, .{
            ui.row(.{}, .{
                ui.el(.bubble, .{ .padding = 10 }, .{
                    ui.text(.{ .wrap = true }, "Ready to ship the components page?"),
                }),
                ui.spacer(1),
            }),
            ui.row(.{}, .{
                ui.spacer(1),
                ui.el(.bubble, .{ .padding = 10, .variant = .primary }, .{
                    ui.text(.{ .wrap = true }, "Previews are rendering now."),
                }),
            }),
        }),
    });
}

fn buildBreadcrumb(ui: *Ui) Node {
    return tile(ui, .{
        ui.el(.breadcrumb, .{ .gap = 8, .cross = .center }, .{
            ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Home"),
            ui.icon(.{ .style_tokens = .{ .foreground = .text_muted } }, "chevron-right"),
            ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Components"),
            ui.icon(.{ .style_tokens = .{ .foreground = .text_muted } }, "chevron-right"),
            ui.text(.{}, "Breadcrumb"),
        }),
    });
}

fn buildPagination(ui: *Ui) Node {
    return tile(ui, .{
        ui.el(.pagination, .{}, .{
            ui.button(.{ .variant = .ghost, .icon = "chevron-left" }, "Previous"),
            ui.button(.{ .variant = .outline, .selected = true }, "1"),
            ui.button(.{ .variant = .ghost }, "2"),
            ui.button(.{ .variant = .ghost }, "3"),
            ui.button(.{ .variant = .ghost, .icon = "chevron-right" }, "Next"),
        }),
    });
}

fn buildList(ui: *Ui) Node {
    return tile(ui, .{
        ui.list(.{ .width = 340, .gap = 2 }, .{
            ui.listItem(.{ .icon = "file-text" }, "Quarterly report.md"),
            ui.listItem(.{ .icon = "file-text", .selected = true }, "Launch checklist.md"),
            ui.listItem(.{ .icon = "folder" }, "Archive"),
            ui.listItem(.{ .icon = "music", .disabled = true }, "demo-track.wav"),
        }),
    });
}

fn buildTable(ui: *Ui) Node {
    return tile(ui, .{
        ui.el(.table, .{ .width = 420 }, .{
            ui.el(.data_row, .{}, .{
                ui.el(.data_cell, .{ .text = "Invoice", .grow = 1 }, .{}),
                ui.el(.data_cell, .{ .text = "Status", .grow = 1 }, .{}),
                ui.el(.data_cell, .{ .text = "Amount", .grow = 1 }, .{}),
            }),
            ui.el(.data_row, .{}, .{
                ui.el(.data_cell, .{ .text = "INV-001", .grow = 1 }, .{}),
                ui.el(.data_cell, .{ .text = "Paid", .grow = 1 }, .{}),
                ui.el(.data_cell, .{ .text = "$250.00", .grow = 1 }, .{}),
            }),
            ui.el(.data_row, .{ .selected = true }, .{
                ui.el(.data_cell, .{ .text = "INV-002", .grow = 1 }, .{}),
                ui.el(.data_cell, .{ .text = "Pending", .grow = 1 }, .{}),
                ui.el(.data_cell, .{ .text = "$150.00", .grow = 1 }, .{}),
            }),
            ui.el(.data_row, .{}, .{
                ui.el(.data_cell, .{ .text = "INV-003", .grow = 1 }, .{}),
                ui.el(.data_cell, .{ .text = "Unpaid", .grow = 1 }, .{}),
                ui.el(.data_cell, .{ .text = "$350.00", .grow = 1 }, .{}),
            }),
        }),
    });
}

fn buildTree(ui: *Ui) Node {
    return tile(ui, .{
        ui.tree(.{ .width = 340, .gap = 2 }, .{
            ui.listItem(.{ .icon = "folder-open", .expanded = true, .semantics = .{ .role = .treeitem } }, "src"),
            ui.column(.{ .padding = 0, .gap = 2 }, .{
                ui.row(.{}, .{
                    ui.spacer(0),
                    ui.column(.{ .width = 20 }, .{}),
                    ui.column(.{ .gap = 2, .grow = 1 }, .{
                        ui.listItem(.{ .icon = "file-text", .selected = true, .semantics = .{ .role = .treeitem } }, "main.zig"),
                        ui.listItem(.{ .icon = "file-text", .semantics = .{ .role = .treeitem } }, "view.zig"),
                    }),
                }),
            }),
            ui.listItem(.{ .icon = "folder", .expanded = false, .semantics = .{ .role = .treeitem } }, "assets"),
        }),
    });
}

fn buildSplit(ui: *Ui) Node {
    return tileStart(ui, .{
        ui.split(.{ .height = 150, .value = 0.35, .gap = 8 }, .{
            ui.panel(.{ .padding = 12, .min_width = 80 }, .{
                ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Sidebar"),
            }),
            ui.panel(.{ .padding = 12, .min_width = 120 }, .{
                ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Content"),
            }),
        }),
    });
}

fn buildScroll(ui: *Ui) Node {
    return tile(ui, .{
        ui.panel(.{ .width = 340, .height = 160 }, .{
            ui.scroll(.{}, .{
                ui.column(.{ .gap = 2, .padding = 8, .height = 240 }, .{
                    ui.listItem(.{}, "Changelog entry 14"),
                    ui.listItem(.{}, "Changelog entry 13"),
                    ui.listItem(.{}, "Changelog entry 12"),
                    ui.listItem(.{}, "Changelog entry 11"),
                    ui.listItem(.{}, "Changelog entry 10"),
                    ui.listItem(.{}, "Changelog entry 9"),
                    ui.listItem(.{}, "Changelog entry 8"),
                }),
            }),
        }),
    });
}

/// Modal surfaces draw their title chrome themselves and stack children
/// over the full content box, so the body column leads with a spacer
/// that clears the title line (the same shape apps use).
fn surfaceTitleSpacer(ui: *Ui) Node {
    return ui.column(.{ .height = 34 }, .{});
}

fn buildDialog(ui: *Ui) Node {
    return tile(ui, .{
        ui.el(.dialog, .{ .text = "Rename note", .width = 380, .height = 240, .padding = 24 }, .{
            ui.column(.{ .gap = 14 }, .{
                surfaceTitleSpacer(ui),
                ui.text(.{ .wrap = true, .style_tokens = .{ .foreground = .text_muted } }, "The new name shows up everywhere this note is linked."),
                ui.el(.input, .{ .text = "Launch checklist" }, .{}),
                ui.row(.{ .gap = 8, .main = .end }, .{
                    ui.button(.{ .variant = .ghost }, "Cancel"),
                    ui.button(.{ .variant = .primary }, "Rename"),
                }),
            }),
        }),
    });
}

fn buildDrawer(ui: *Ui) Node {
    return tileStart(ui, .{
        ui.el(.drawer, .{ .text = "Filters", .width = 260, .height = 230, .padding = 24 }, .{
            ui.column(.{ .gap = 12 }, .{
                surfaceTitleSpacer(ui),
                ui.checkbox(.{ .text = "Only unread", .checked = true }),
                ui.checkbox(.{ .text = "Has attachments" }),
                ui.el(.switch_control, .{ .text = "Compact rows" }, .{}),
            }),
        }),
    });
}

fn buildSheet(ui: *Ui) Node {
    return tile(ui, .{
        ui.el(.sheet, .{ .text = "Share", .width = 380, .height = 190, .padding = 24 }, .{
            ui.column(.{ .gap = 12 }, .{
                surfaceTitleSpacer(ui),
                ui.text(.{ .wrap = true, .style_tokens = .{ .foreground = .text_muted } }, "Anyone with the link can view this board."),
                ui.row(.{ .gap = 8 }, .{
                    ui.el(.input, .{ .text = "https://zero-native.dev/b/9f2", .grow = 1 }, .{}),
                    ui.button(.{ .variant = .secondary, .icon = "copy" }, "Copy"),
                }),
            }),
        }),
    });
}

fn buildSeparator(ui: *Ui) Node {
    return tile(ui, .{
        ui.column(.{ .gap = 12, .width = 300 }, .{
            ui.text(.{}, "Native SDK"),
            ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "A component catalog rendered by the engine."),
            ui.separator(.{}),
            ui.row(.{ .gap = 12, .cross = .center, .height = 20 }, .{
                ui.text(.{}, "Docs"),
                ui.separator(.{ .width = 1, .height = 16 }),
                ui.text(.{}, "Source"),
                ui.separator(.{ .width = 1, .height = 16 }),
                ui.text(.{}, "Changelog"),
            }),
        }),
    });
}

fn buildSkeleton(ui: *Ui) Node {
    return tile(ui, .{
        ui.row(.{ .gap = 12, .width = 320 }, .{
            ui.el(.skeleton, .{ .width = 44, .height = 44 }, .{}),
            ui.column(.{ .gap = 8, .grow = 1, .main = .center }, .{
                ui.el(.skeleton, .{ .height = 14 }, .{}),
                ui.el(.skeleton, .{ .height = 14, .width = 180 }, .{}),
            }),
        }),
    });
}

fn buildSpinner(ui: *Ui) Node {
    return tile(ui, .{
        ui.row(.{ .gap = 12, .cross = .center }, .{
            ui.el(.spinner, .{}, .{}),
            ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Loading…"),
        }),
    });
}

const markdown_sample =
    \\## Release notes
    \\
    \\The **markdown** widget renders headings, emphasis, `inline code`,
    \\lists, and links through the same text pipeline as every other
    \\component.
    \\
    \\- Deterministic layout, selectable text
    \\- [Links](https://zero-native.dev) dispatch a Msg
    \\
    \\```zig
    \\const doc = try fx.readFile("notes.md");
    \\```
;

fn buildMarkdown(ui: *Ui) Node {
    return tileStart(ui, .{
        Md.view(ui, markdown_sample, .{}),
    });
}

fn buildIconHero(ui: *Ui) Node {
    return tile(ui, .{
        ui.row(.{ .gap = 20, .cross = .center }, .{
            ui.icon(.{}, "play"),
            ui.icon(.{}, "search"),
            ui.icon(.{}, "settings"),
            ui.icon(.{}, "git-branch"),
            ui.icon(.{}, "check-circle"),
            ui.icon(.{}, "download"),
            ui.icon(.{}, "moon"),
            ui.icon(.{}, "trash"),
        }),
    });
}

fn buildChart(ui: *Ui) Node {
    return tile(ui, .{
        ui.chart(.{ .width = 420, .height = 160, .grid_lines = 3, .baseline = true }, &.{
            .{ .kind = .line, .fill = true, .label = "cpu", .values = &.{ 0.18, 0.24, 0.21, 0.32, 0.45, 0.38, 0.52, 0.61, 0.55, 0.68, 0.62, 0.74 } },
            .{ .kind = .bar, .color = .text_muted, .label = "jobs", .values = &.{ 0.08, 0.12, 0.1, 0.16, 0.2, 0.15, 0.22, 0.28, 0.24, 0.3, 0.26, 0.34 } },
        }),
    });
}

fn buildStatusBar(ui: *Ui) Node {
    return ui.column(.{ .grow = 1 }, .{
        ui.column(.{ .grow = 1, .padding = 32, .main = .center, .cross = .center }, .{
            ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Window content"),
        }),
        ui.statusBar(.{}, "Ready — 3 notes synced"),
    });
}

fn buildStepper(ui: *Ui) Node {
    return tileStart(ui, .{
        ui.stepper(.{ .active = 1 }, &.{
            .{ .label = "Draft" },
            .{ .label = "Review" },
            .{ .label = "Publish" },
        }),
    });
}

fn buildTimeline(ui: *Ui) Node {
    return tileStart(ui, .{
        ui.timeline(.{ .gap = 0 }, .{
            ui.timelineItem(.{ .icon = "check", .variant = .primary, .title = "Build", .description = "Compiled 214 files in 1.8s.", .meta = "zig build · 1.8s" }),
            ui.timelineItem(.{ .indicator = "2", .variant = .default, .title = "Test", .description = "Canvas and runtime suites passing.", .meta = "zig build test · 42s" }),
            ui.timelineItem(.{ .indicator = "3", .title = "Package", .connector = false }),
        }),
    });
}

// ------------------------------------------------------------ renderer

const PreviewApp = struct {
    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "docs-component-previews",
            .source = platform.WebViewSource.html("<h1>previews</h1>"),
        };
    }
};

fn renderScenePng(
    gpa: std.mem.Allocator,
    io: std.Io,
    width: f32,
    height: f32,
    scheme: canvas.ColorScheme,
    build: *const fn (ui: *Ui) Node,
    hover: ?Hover,
    png_path: []const u8,
) !void {
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(width, height) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    var app_state: PreviewApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = view_label,
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, width, height),
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const tokens = canvas.DesignTokens.theme(.{ .color_scheme = scheme });
    var ui = Ui.init(arena_state.allocator());
    const tree = try ui.finalizeWithTokens(build(&ui), tokens);

    const nodes = try gpa.alloc(canvas.WidgetLayoutNode, native_sdk.runtime.max_canvas_widget_nodes_per_view);
    defer gpa.free(nodes);
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, width, height), nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, view_label, layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, view_label, tokens);

    if (hover) |target| {
        const frame = hoverFrame(layout, target) orelse return error.HoverTargetNotFound;
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = view_label,
            .kind = .pointer_move,
            .x = frame.x + frame.width / 2,
            .y = frame.y + frame.height / 2,
        } });
    }

    const pixel_size = try harness.runtime.canvasScreenshotPixelSize(1, view_label, 2);
    const pixels = try gpa.alloc(u8, pixel_size.byte_len);
    defer gpa.free(pixels);
    const scratch = try gpa.alloc(u8, pixel_size.byte_len);
    defer gpa.free(scratch);
    const screenshot = try harness.runtime.renderCanvasScreenshot(1, view_label, 2, pixels, scratch);

    const encoded = try gpa.alloc(u8, try canvas.png.encodedRgba8ByteLen(screenshot.width, screenshot.height));
    defer gpa.free(encoded);
    var writer = std.Io.Writer.fixed(encoded);
    try canvas.png.writeRgba8(&writer, screenshot.width, screenshot.height, screenshot.rgba8);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = png_path, .data = writer.buffered() });
}

fn hoverFrame(layout: canvas.WidgetLayoutTree, target: Hover) ?geometry.RectF {
    var seen: usize = 0;
    for (layout.nodes) |node| {
        if (node.widget.kind != target.kind) continue;
        if (seen == target.index) return node.frame;
        seen += 1;
    }
    return null;
}

fn encodeWebp(io: std.Io, png_path: []const u8, webp_path: []const u8) !void {
    var child = std.process.spawn(io, .{
        .argv = &.{ "cwebp", "-lossless", "-z", "6", "-exact", "-quiet", png_path, "-o", webp_path },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("error: cwebp not found on PATH — install it (brew install webp) and rerun\n", .{});
        }
        return err;
    };
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.WebpEncodeFailed,
        else => return error.WebpEncodeFailed,
    }
}

fn schemeName(scheme: canvas.ColorScheme) []const u8 {
    return switch (scheme) {
        .light => "light",
        .dark => "dark",
    };
}

// --------------------------------------------------------------- vocab

fn writeDocList(js: *std.json.Stringify, docs: []const markup_docs.Doc) !void {
    try js.beginArray();
    for (docs) |doc| {
        try js.beginObject();
        try js.objectField("name");
        try js.write(doc.name);
        try js.objectField("doc");
        try js.write(doc.doc);
        try js.endObject();
    }
    try js.endArray();
}

fn writeNameList(js: *std.json.Stringify, names: []const []const u8) !void {
    try js.beginArray();
    for (names) |name| try js.write(name);
    try js.endArray();
}

/// The vocabulary JSON the docs attribute tables render from: element,
/// attribute, and event docs come straight from the markup LSP tables
/// (the same strings editors show on hover), the closed value sets from
/// the validator vocabulary — no hand-written rows to drift.
fn writeVocabJson(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var js: std.json.Stringify = .{ .writer = &body.writer, .options = .{ .whitespace = .indent_2 } };

    try js.beginObject();
    try js.objectField("elements");
    try writeDocList(&js, &markup_docs.element_docs);
    try js.objectField("structure");
    try writeDocList(&js, &markup_docs.structure_docs);
    try js.objectField("attributes");
    try writeDocList(&js, &markup_docs.attribute_docs);
    try js.objectField("events");
    try writeDocList(&js, &markup_docs.event_docs);
    try js.objectField("scoped");
    try js.beginObject();
    try js.objectField("markdown");
    try writeDocList(&js, &markup_docs.markdown_attr_docs);
    try js.objectField("stepper");
    try writeDocList(&js, &markup_docs.stepper_attr_docs);
    try js.objectField("timeline");
    try writeDocList(&js, &markup_docs.timeline_attr_docs);
    try js.objectField("timeline-item");
    try writeDocList(&js, &markup_docs.timeline_item_attr_docs);
    try js.objectField("avatar");
    try writeDocList(&js, &markup_docs.avatar_attr_docs);
    try js.objectField("dropdown-menu");
    try writeDocList(&js, &markup_docs.anchor_attr_docs);
    try js.objectField("template");
    try writeDocList(&js, &markup_docs.template_attr_docs);
    try js.objectField("for");
    try writeDocList(&js, &markup_docs.for_attr_docs);
    try js.objectField("if");
    try writeDocList(&js, &markup_docs.if_attr_docs);
    try js.endObject();
    // Pixel dimensions of every preview pair (2x renders), so the docs
    // image components read sizes from here instead of hand-coding them.
    try js.objectField("previews");
    try js.beginObject();
    for (scenes) |scene| {
        try js.objectField(scene.name);
        try js.beginObject();
        try js.objectField("width");
        try js.write(@as(u32, @intFromFloat(scene.width * 2)));
        try js.objectField("height");
        try js.write(@as(u32, @intFromFloat(scene.height * 2)));
        try js.endObject();
    }
    try js.endObject();
    try js.objectField("iconTileSize");
    try js.write(@as(u32, @intFromFloat(icon_tile_size * 2)));
    try js.objectField("icons");
    try writeNameList(&js, canvas.icons.known_icon_names);
    try js.objectField("variants");
    try writeNameList(&js, &enumNames(canvas.WidgetVariant));
    try js.objectField("sizes");
    try writeNameList(&js, &enumNames(canvas.WidgetSize));
    try js.objectField("colorTokens");
    try writeNameList(&js, &canvas.ui_markup.known_color_token_names);
    try js.objectField("radiusTokens");
    try writeNameList(&js, &canvas.ui_markup.known_radius_token_names);
    try js.endObject();

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body.written() });
}

fn enumNames(comptime E: type) [@typeInfo(E).@"enum".fields.len][]const u8 {
    const fields = @typeInfo(E).@"enum".fields;
    var names: [fields.len][]const u8 = undefined;
    inline for (fields, 0..) |field, index| names[index] = field.name;
    return names;
}

// ----------------------------------------------------------------- main

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const out_dir: []const u8 = if (args.len > 1) args[1] else "docs/public/components";
    const vocab_path: []const u8 = if (args.len > 2) args[2] else "docs/src/lib/component-vocab.json";

    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    const icons_dir = try std.fmt.allocPrint(arena, "{s}/icons", .{out_dir});
    try std.Io.Dir.cwd().createDirPath(io, icons_dir);
    try std.Io.Dir.cwd().createDirPath(io, png_cache_dir);

    const schemes = [_]canvas.ColorScheme{ .light, .dark };
    var rendered: usize = 0;

    for (scenes) |scene| {
        for (schemes) |scheme| {
            if (std.c.getenv("DOCS_PREVIEWS_TRACE") != null) std.debug.print("scene {s} ({s})\n", .{ scene.name, schemeName(scheme) });
            const png_path = try std.fmt.allocPrint(arena, "{s}/{s}-{s}.png", .{ png_cache_dir, scene.name, schemeName(scheme) });
            const webp_path = try std.fmt.allocPrint(arena, "{s}/{s}-{s}.webp", .{ out_dir, scene.name, schemeName(scheme) });
            try renderScenePng(gpa, io, scene.width, scene.height, scheme, scene.build, scene.hover, png_path);
            try encodeWebp(io, png_path, webp_path);
            rendered += 1;
        }
    }

    // The icon gallery: one small tile per registry icon, named after it.
    inline for (canvas.icons.known_icon_names) |icon_name| {
        const Builder = struct {
            fn build(ui: *Ui) Node {
                return ui.column(.{ .main = .center, .cross = .center, .grow = 1 }, .{ui.icon(.{}, icon_name)});
            }
        };
        for (schemes) |scheme| {
            const png_path = try std.fmt.allocPrint(arena, "{s}/icon-{s}-{s}.png", .{ png_cache_dir, icon_name, schemeName(scheme) });
            const webp_path = try std.fmt.allocPrint(arena, "{s}/icons/{s}-{s}.webp", .{ out_dir, icon_name, schemeName(scheme) });
            try renderScenePng(gpa, io, icon_tile_size, icon_tile_size, scheme, Builder.build, null, png_path);
            try encodeWebp(io, png_path, webp_path);
            rendered += 1;
        }
    }

    try writeVocabJson(gpa, io, vocab_path);

    std.debug.print("docs-component-previews: wrote {d} webp files to {s} and vocab to {s}\n", .{ rendered, out_dir, vocab_path });
}
