//! The docs component-preview scene catalog: one deterministic widget
//! tree per component, shared by BOTH preview pipelines so they can
//! never drift apart:
//!
//! - `tools/docs_component_previews.zig` renders each scene offscreen
//!   into the static theme-aware webp pairs (`zig build
//!   docs-component-previews`).
//! - `tools/docs_wasm_preview.zig` compiles the same scenes to
//!   WebAssembly so the docs upgrade those images to live, interactive
//!   engine instances in the browser (`zig build docs-wasm-preview`).
//!
//! Scenes are retained widget trees. Most are stateless: the runtime
//! owns hover, focus, toggle, text-edit, slider, and scroll state, which
//! is exactly the interactivity those previews expose. Scenes whose
//! honest demo needs MODEL-owned state (accordion expansion, tab panel
//! switching, dialog dismiss/reopen, the select's anchored dropdown)
//! declare a tiny shared mini-model (`SceneModel`) and build from it;
//! the wasm host routes the REAL widget event dispatch (press, toggle,
//! dismiss, keyboard activation) through each scene tree's typed
//! handler table into `update`, exactly like a real app's loop.

const std = @import("std");
const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;

pub const Msg = union(enum) {
    noop,
    /// Flip one of the model's boolean slots (accordion items).
    toggle_flag: u8,
    /// Select one of the model's indexed options (tab triggers).
    select_index: u8,
    /// Open or close the model's single open surface (dialog, menus).
    set_open: bool,
    /// Toggle the open surface (the select trigger).
    toggle_open,
    /// Pick option `i` AND close the open surface (select menu items).
    choose: u8,
    /// Apply one text edit to the model's query buffer (the combobox's
    /// `on_input`); suggestions open while the query has text.
    query_edit: canvas.TextInputEvent,
    /// Take suggestion `i` as the query text and close the suggestions
    /// (combobox suggestion rows).
    pick_suggestion: u8,
};

/// The mini-model every model-driven scene shares: a few boolean slots,
/// one selected index, one open flag, one small text query. Deliberately
/// tiny — scenes are demos, and the seam exists so the live previews
/// respond through the same update/rebuild loop a real app runs, not to
/// model real apps.
pub const SceneModel = struct {
    flags: [4]bool = .{ false, false, false, false },
    index: u8 = 0,
    open: bool = false,
    query: canvas.TextBuffer(48) = .{},
};

pub fn update(model: *SceneModel, msg: Msg) void {
    switch (msg) {
        .noop => {},
        .toggle_flag => |slot| {
            if (slot < model.flags.len) model.flags[slot] = !model.flags[slot];
        },
        .select_index => |index| model.index = index,
        .set_open => |open| model.open = open,
        .toggle_open => model.open = !model.open,
        .choose => |index| {
            model.index = index;
            model.open = false;
        },
        .query_edit => |edit| {
            model.query.apply(edit);
            model.open = model.query.text().len > 0;
        },
        .pick_suggestion => |index| {
            model.query.set(combobox_options[@min(index, combobox_options.len - 1)]);
            model.open = false;
        },
    }
}

pub const Ui = canvas.Ui(Msg);
pub const Node = Ui.Node;
const Md = canvas.markdown.Markdown(Msg);

/// Logical tile width; every static preview renders at 2x, so files are
/// `2 * tile_width` pixels wide.
pub const tile_width: f32 = 560;
pub const icon_tile_size: f32 = 56;

/// Which widget the pointer hovers before capture (hover styling is
/// engine-owned render state, not a source attribute): the `index`-th
/// widget of `kind` in layout order. Static-capture concern only; the
/// live previews hover with the real pointer.
pub const Hover = struct {
    kind: canvas.WidgetKind,
    index: usize = 0,
};

pub const Scene = struct {
    /// Output stem: `<out_dir>/<name>-{light,dark}.webp`.
    name: []const u8,
    height: f32,
    width: f32 = tile_width,
    /// Every scene builds from the mini-model; stateless scenes wrap
    /// their plain builder in `stateless` and ignore it. The static
    /// pipeline renders `model` as-is; the live host feeds it through
    /// `update` on dispatched events and rebuilds.
    build: *const fn (ui: *Ui, model: *const SceneModel) Node,
    /// The scene's initial model state (the static previews render it).
    model: SceneModel = .{},
    hover: ?Hover = null,
};

/// Adapt a model-less builder to the scene signature.
fn stateless(comptime build_fn: fn (ui: *Ui) Node) *const fn (ui: *Ui, model: *const SceneModel) Node {
    return struct {
        fn build(ui: *Ui, model: *const SceneModel) Node {
            _ = model;
            return build_fn(ui);
        }
    }.build;
}

pub const scenes = [_]Scene{
    .{ .name = "button", .height = 160, .build = stateless(buildButton) },
    .{ .name = "button-sizes", .height = 160, .build = stateless(buildButtonSizes) },
    .{ .name = "button-icons", .height = 160, .build = stateless(buildButtonIcons) },
    .{ .name = "button-states", .height = 160, .build = stateless(buildButtonStates), .hover = .{ .kind = .button, .index = 1 } },
    .{ .name = "button-group", .height = 160, .build = stateless(buildButtonGroup) },
    .{ .name = "toggle", .height = 160, .build = stateless(buildToggle) },
    .{ .name = "toggle-group", .height = 160, .build = stateless(buildToggleGroup) },
    .{ .name = "input", .height = 260, .build = stateless(buildInput) },
    .{ .name = "search-field", .height = 160, .build = stateless(buildSearchField) },
    .{ .name = "textarea", .height = 220, .build = stateless(buildTextarea) },
    .{ .name = "input-group", .height = 340, .build = stateless(buildInputGroup) },
    .{ .name = "select", .height = 280, .build = buildSelect },
    // Tall enough for the suggestions dropdown the live preview opens
    // beneath the field as you type.
    .{ .name = "combobox", .height = 300, .build = buildCombobox },
    .{ .name = "dropdown-menu", .height = 300, .build = buildDropdownMenu },
    .{ .name = "checkbox", .height = 180, .build = stateless(buildCheckbox) },
    .{ .name = "radio-group", .height = 180, .build = stateless(buildRadioGroup) },
    .{ .name = "switch", .height = 160, .build = stateless(buildSwitch) },
    .{ .name = "slider", .height = 180, .build = stateless(buildSlider) },
    .{ .name = "progress", .height = 140, .build = stateless(buildProgress) },
    .{ .name = "badge", .height = 140, .build = stateless(buildBadge) },
    .{ .name = "avatar", .height = 160, .build = stateless(buildAvatar) },
    .{ .name = "card", .height = 300, .build = stateless(buildCard) },
    .{ .name = "panel", .height = 180, .build = stateless(buildPanel) },
    .{ .name = "alert", .height = 220, .build = stateless(buildAlert) },
    .{ .name = "accordion", .height = 240, .build = buildAccordion, .model = .{ .flags = .{ true, false, false, false } } },
    .{ .name = "tabs", .height = 230, .build = buildTabs },
    .{ .name = "menu", .height = 280, .build = stateless(buildMenu) },
    .{ .name = "tooltip", .height = 160, .build = stateless(buildTooltip), .hover = .{ .kind = .button } },
    .{ .name = "bubble", .height = 300, .build = stateless(buildBubble) },
    .{ .name = "breadcrumb", .height = 140, .build = stateless(buildBreadcrumb) },
    .{ .name = "pagination", .height = 150, .build = stateless(buildPagination) },
    .{ .name = "list", .height = 260, .build = stateless(buildList) },
    .{ .name = "virtual-list", .height = 260, .build = stateless(buildVirtualList) },
    .{ .name = "table", .height = 240, .build = stateless(buildTable) },
    .{ .name = "tree", .height = 280, .build = stateless(buildTree) },
    .{ .name = "split", .height = 240, .build = stateless(buildSplit) },
    .{ .name = "scroll", .height = 240, .build = stateless(buildScroll) },
    .{ .name = "dialog", .height = 310, .build = buildDialog, .model = .{ .open = true } },
    .{ .name = "drawer", .height = 300, .build = stateless(buildDrawer) },
    .{ .name = "sheet", .height = 300, .build = stateless(buildSheet) },
    .{ .name = "separator", .height = 200, .build = stateless(buildSeparator) },
    .{ .name = "spacer", .height = 160, .build = stateless(buildSpacer) },
    .{ .name = "resizable", .height = 240, .build = stateless(buildResizable) },
    .{ .name = "skeleton", .height = 200, .build = stateless(buildSkeleton) },
    .{ .name = "spinner", .height = 140, .build = stateless(buildSpinner) },
    .{ .name = "markdown", .height = 440, .build = stateless(buildMarkdown) },
    .{ .name = "icon", .height = 150, .build = stateless(buildIconHero) },
    .{ .name = "chart", .height = 260, .build = stateless(buildChart) },
    .{ .name = "chart-bar", .height = 260, .build = stateless(buildChartBar) },
    .{ .name = "chart-area", .height = 240, .build = stateless(buildChartArea) },
    .{ .name = "status-bar", .height = 170, .build = stateless(buildStatusBar) },
    .{ .name = "stepper", .height = 160, .build = stateless(buildStepper) },
    .{ .name = "timeline", .height = 320, .build = stateless(buildTimeline) },

    // Catalog hero tiles: ONE representative variation per component,
    // framed 16:9 so the Components index card fills edge to edge and
    // the component reads at a glance. The full variation sets stay on
    // the component pages (the scenes above).
    .{ .name = "accordion-hero", .width = hero_tile_width, .height = hero_tile_height, .build = buildAccordionHero, .model = .{ .flags = .{ true, false, false, false } } },
    heroScene("alert-hero", buildAlertHero),
    heroScene("avatar-hero", buildAvatarHero),
    heroScene("badge-hero", buildBadgeHero),
    heroScene("breadcrumb-hero", buildBreadcrumb),
    heroScene("bubble-hero", buildBubbleHero),
    heroScene("button-group-hero", buildButtonGroupHero),
    heroScene("button-hero", buildButtonHero),
    heroScene("card-hero", buildCardHero),
    heroScene("chart-hero", buildChartHero),
    heroScene("checkbox-hero", buildCheckboxHero),
    heroScene("combobox-hero", buildComboboxHero),
    heroScene("dialog-hero", buildDialogHero),
    heroScene("drawer-hero", buildDrawerHero),
    heroScene("dropdown-menu-hero", buildDropdownMenuHero),
    heroScene("icon-hero", buildIconHeroTile),
    heroScene("input-hero", buildInputHero),
    heroScene("input-group-hero", buildInputGroupHero),
    heroScene("list-hero", buildListHero),
    heroScene("markdown-hero", buildMarkdownHero),
    heroScene("pagination-hero", buildPaginationHero),
    heroScene("panel-hero", buildPanelHero),
    heroScene("progress-hero", buildProgressHero),
    heroScene("radio-hero", buildRadioHero),
    heroScene("resizable-hero", buildResizableHero),
    heroScene("scroll-hero", buildScrollHero),
    .{ .name = "select-hero", .width = hero_tile_width, .height = hero_tile_height, .build = buildSelectHero, .model = .{ .open = true } },
    heroScene("separator-hero", buildSeparatorHero),
    heroScene("sheet-hero", buildSheetHero),
    heroScene("skeleton-hero", buildSkeletonHero),
    heroScene("slider-hero", buildSliderHero),
    heroScene("spacer-hero", buildSpacerHero),
    heroScene("spinner-hero", buildSpinner),
    heroScene("split-hero", buildSplitHero),
    heroScene("status-bar-hero", buildStatusBarHero),
    heroScene("stepper-hero", buildStepperHero),
    heroScene("switch-hero", buildSwitchHero),
    heroScene("table-hero", buildTableHero),
    heroScene("tabs-hero", buildTabsHero),
    heroScene("textarea-hero", buildTextareaHero),
    heroScene("timeline-hero", buildTimelineHero),
    heroScene("toggle-hero", buildToggleHero),
    .{ .name = "tooltip-hero", .width = hero_tile_width, .height = hero_tile_height, .build = stateless(buildTooltipHero), .hover = .{ .kind = .button } },
    heroScene("tree-hero", buildTreeHero),
    heroScene("virtual-list-hero", buildVirtualListHero),
};

/// The catalog hero frame: exactly 16:9, so the index-grid card shows
/// the tile edge to edge with no letterboxing.
pub const hero_tile_width: f32 = 352;
pub const hero_tile_height: f32 = 198;

fn heroScene(comptime name: []const u8, comptime build_fn: fn (ui: *Ui) Node) Scene {
    return .{ .name = name, .width = hero_tile_width, .height = hero_tile_height, .build = stateless(build_fn) };
}

pub fn sceneByName(name: []const u8) ?*const Scene {
    for (&scenes) |*scene| {
        if (std.mem.eql(u8, scene.name, name)) return scene;
    }
    return null;
}

// ------------------------------------------------------------- scenes

/// Padded, centered preview tile on the background token — the house style
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
    // Attached ACTIONS, not an exclusive choice: a group member never
    // carries `selected` state — that is the toggle-group's job.
    return tile(ui, .{
        ui.el(.button_group, .{}, .{
            ui.button(.{ .variant = .outline }, "Cut"),
            ui.button(.{ .variant = .outline }, "Copy"),
            ui.button(.{ .variant = .outline }, "Paste"),
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
    // The middle specimen shows the live editing affordances: focus
    // ring plus the inverted selection (solid accent fill under
    // accent-foreground glyphs). One focused field per tile — only one
    // field can hold focus honestly.
    var selected = ui.el(.text_field, .{ .text = "native-sdk" }, .{});
    selected.widget.state.focused = true;
    selected.widget.text_selection = .{ .anchor = 0, .focus = 6 };
    return tile(ui, .{
        ui.column(.{ .gap = 12, .width = 280 }, .{
            ui.el(.input, .{ .placeholder = "Email address" }, .{}),
            selected,
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

/// The composer shape: one bordered field wrapping the textarea plus the
/// accessory actions row (attach bottom-left, send bottom-right). The
/// entry carries focus, so the GROUP wears the ring — the focus-within
/// treatment the component exists for.
fn inputGroupComposer(ui: *Ui, width: f32, height: f32, focused: bool) Node {
    const entry_text = "Ship the composer today.";
    var entry = ui.el(.textarea, .{
        .text = entry_text,
        .placeholder = "Type a message…",
        .semantics = .{ .label = "Message" },
    }, .{});
    entry.widget.state.focused = focused;
    // The focused composer carries a collapsed selection at the end of
    // its text, so the preview shows the text-ink caret where typing
    // would continue.
    if (focused) entry.widget.text_selection = canvas.TextSelection.collapsed(entry_text.len);
    return ui.inputGroup(.{
        .width = width,
        .height = height,
        .semantics = .{ .label = "Message composer" },
    }, entry, ui.inputGroupActions(.{}, .{
        ui.el(.button, .{ .icon = "plus", .variant = .ghost, .size = .icon, .semantics = .{ .label = "Attach" } }, .{}),
        ui.spacer(1),
        ui.el(.button, .{ .icon = "send", .size = .icon, .variant = .primary, .semantics = .{ .label = "Send" } }, .{}),
    }));
}

fn buildInputGroup(ui: *Ui) Node {
    return tile(ui, .{
        ui.column(.{ .gap = 20 }, .{
            inputGroupComposer(ui, 340, 128, true),
            inputGroupComposer(ui, 340, 128, false),
        }),
    });
}

const select_options = [_][]const u8{ "Production", "Staging", "Preview" };

/// Model-driven select: the trigger toggles the anchored dropdown open,
/// a menu item picks its option and closes, Escape/click-outside
/// dismisses — the sanctioned picker shape (stack wraps the trigger,
/// the anchored dropdown_menu is its sibling, rendered only while open).
fn buildSelect(ui: *Ui, model: *const SceneModel) Node {
    const active: usize = @min(model.index, select_options.len - 1);
    const trigger = ui.el(.select, .{
        .text = select_options[active],
        .selected = model.open,
        .on_press = .toggle_open,
    }, .{});
    const picker = if (model.open)
        ui.stack(.{}, .{
            trigger,
            ui.el(.dropdown_menu, .{
                .anchor = .below,
                .anchor_alignment = .stretch,
                .on_dismiss = .{ .set_open = false },
            }, .{
                ui.el(.menu_item, .{ .text = select_options[0], .selected = active == 0, .on_press = .{ .choose = 0 } }, .{}),
                ui.el(.menu_item, .{ .text = select_options[1], .selected = active == 1, .on_press = .{ .choose = 1 } }, .{}),
                ui.el(.menu_item, .{ .text = select_options[2], .selected = active == 2, .on_press = .{ .choose = 2 } }, .{}),
            }),
        })
    else
        ui.stack(.{}, .{trigger});
    return ui.column(.{ .padding = 32, .main = .center, .cross = .center, .grow = 1 }, .{
        ui.column(.{ .gap = 12, .width = 240 }, .{
            picker,
            ui.el(.select, .{ .text = "Staging", .disabled = true }, .{}),
        }),
    });
}

const combobox_options = [_][]const u8{ "Apple", "Banana", "Blueberry", "Grapes", "Pineapple" };

/// Model-driven combobox: the widget is a real text field with a menu
/// affordance and NO built-in options — the app owns the text through
/// `on_input` and composes the suggestions itself (the select's
/// anchored-dropdown pattern with the option list filtered as you
/// type). Picking a suggestion writes it into the query and closes.
fn buildCombobox(ui: *Ui, model: *const SceneModel) Node {
    const query = model.query.text();
    const field = ui.el(.combobox, .{
        .placeholder = "Search fruit…",
        .text = query,
        .on_input = Ui.inputMsg(.query_edit),
    }, .{});
    var match_indices: [combobox_options.len]u8 = undefined;
    var match_count: usize = 0;
    for (combobox_options, 0..) |option, index| {
        if (std.ascii.indexOfIgnoreCase(option, query) != null) {
            match_indices[match_count] = @intCast(index);
            match_count += 1;
        }
    }
    const entry = if (model.open and match_count > 0) blk: {
        const rows = ui.arena.alloc(Node, match_count) catch break :blk ui.stack(.{}, .{field});
        for (rows, match_indices[0..match_count]) |*row, option_index| {
            row.* = ui.el(.menu_item, .{
                .text = combobox_options[option_index],
                .on_press = .{ .pick_suggestion = option_index },
            }, .{});
        }
        break :blk ui.stack(.{}, .{
            field,
            ui.el(.dropdown_menu, .{
                .anchor = .below,
                .anchor_alignment = .stretch,
                .on_dismiss = .{ .set_open = false },
            }, .{rows}),
        });
    } else ui.stack(.{}, .{field});
    // Top-aligned (not centered) so the suggestions always have room to
    // open beneath the field within the tile.
    return ui.column(.{ .padding = 32, .cross = .center, .grow = 1 }, .{
        ui.column(.{ .width = 240 }, .{entry}),
    });
}

/// Model-driven ACTIONS menu: closed until the trigger opens it, and an
/// item press fires the action and closes through the model — no item
/// ever carries a committed selection (menus act; the select commits).
/// Escape / click-outside dismiss through `on_dismiss`, same as select.
fn buildDropdownMenu(ui: *Ui, model: *const SceneModel) Node {
    const trigger = ui.button(.{ .variant = .outline, .icon = "chevron-down", .on_press = .toggle_open }, "Actions");
    const menu = if (model.open)
        ui.stack(.{}, .{
            trigger,
            ui.el(.dropdown_menu, .{
                .anchor = .below,
                .min_width = 200,
                .on_dismiss = .{ .set_open = false },
            }, .{
                ui.el(.menu_item, .{ .text = "Duplicate", .icon = "copy", .on_press = .{ .set_open = false } }, .{}),
                ui.el(.menu_item, .{ .text = "Rename", .icon = "edit", .on_press = .{ .set_open = false } }, .{}),
                ui.el(.menu_item, .{ .text = "Download", .icon = "download", .on_press = .{ .set_open = false } }, .{}),
                ui.separator(.{}),
                ui.el(.menu_item, .{ .text = "Delete", .icon = "trash", .on_press = .{ .set_open = false } }, .{}),
            }),
        })
    else
        ui.stack(.{}, .{trigger});
    return ui.column(.{ .padding = 32, .cross = .center, .grow = 1 }, .{menu});
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
    // No hand-added inset: the card composite carries the house 24px
    // content padding by default.
    return tile(ui, .{
        ui.el(.card, .{ .width = 340 }, .{
            ui.column(.{ .gap = 12 }, .{
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
            // Title + description: children hang under the title, past
            // the icon column (the standard callout grid).
            ui.el(.alert, .{ .text = "A new version of the shell is available." }, .{
                ui.text(.{ .wrap = true, .style_tokens = .{ .foreground = .text_muted } }, "Restart the app to finish updating."),
            }),
            ui.el(.alert, .{ .text = "Your session has expired. Sign in again.", .variant = .destructive }, .{}),
        }),
    });
}

/// Model-driven accordion: each item's expansion lives in a model flag,
/// flipped through the item's real `on_toggle` dispatch — items size
/// themselves (header band collapsed, header + content expanded), so a
/// toggle reflows the column exactly like a real app.
fn buildAccordion(ui: *Ui, model: *const SceneModel) Node {
    return tile(ui, .{
        ui.column(.{ .width = 380 }, .{
            accordionItem(ui, model, 0, "Is it accessible?", "Yes. Widgets carry semantic roles and one roving focus set."),
            accordionItem(ui, model, 1, "Is it styled?", "Yes. Components default to the house look, driven by design tokens."),
        }),
    });
}

fn accordionItem(ui: *Ui, model: *const SceneModel, comptime slot: u8, title: []const u8, body: []const u8) Node {
    return ui.el(.accordion, .{
        .text = title,
        .selected = model.flags[slot],
        .on_toggle = .{ .toggle_flag = slot },
    }, .{
        ui.column(.{}, .{
            ui.text(.{ .wrap = true, .style_tokens = .{ .foreground = .text_muted } }, body),
            // The house content inset: breathing room above the item's
            // hairline separator.
            ui.column(.{ .height = 14 }, .{}),
        }),
    });
}

const tab_labels = [_][]const u8{ "Account", "Password", "Team" };
const tab_bodies = [_][]const u8{
    "Make changes to your account here.",
    "Change your password here.",
    "Invite and manage your team here.",
};

/// Model-driven tabs: the triggers sit in the tabs component's own
/// TabsList container; pressing one selects its index and the panel
/// below re-renders from the model.
fn buildTabs(ui: *Ui, model: *const SceneModel) Node {
    const active: usize = @min(model.index, tab_labels.len - 1);
    return tile(ui, .{
        ui.column(.{ .gap = 12, .width = 340 }, .{
            // A row wrapper lets the TabsList hug its triggers (w-fit)
            // while the panel below stretches to the column width.
            ui.row(.{}, .{
                ui.el(.tabs, .{}, .{
                    tabTrigger(ui, model, 0),
                    tabTrigger(ui, model, 1),
                    tabTrigger(ui, model, 2),
                }),
                ui.spacer(1),
            }),
            ui.panel(.{ .padding = 16 }, .{
                ui.column(.{ .gap = 4 }, .{
                    ui.text(.{}, tab_labels[active]),
                    ui.text(.{ .wrap = true, .style_tokens = .{ .foreground = .text_muted } }, tab_bodies[active]),
                }),
            }),
        }),
    });
}

fn tabTrigger(ui: *Ui, model: *const SceneModel, comptime index: u8) Node {
    return ui.el(.segmented_control, .{
        .text = tab_labels[index],
        .selected = model.index == index,
        .on_press = .{ .select_index = index },
    }, .{});
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
    // A two-turn thread with the measured reference rhythm: 8 points
    // between bubbles of the SAME sender (a grouped run), 32 between
    // turns. A grouped run is spacing, not vocabulary — the reference
    // keeps full capsule corners inside a run, so there is no group
    // container to reach for; a plain column carries it. Bubbles hug
    // their message up to 80% of the thread, so received runs sit on
    // the leading edge and the sent run right-aligns with cross=end.
    // The received run's last bubble docks a reaction pill (the
    // <reactions> child in markup; the text/text-alignment channels
    // here) straddling its bottom edge — the 32-point turn gap below
    // gives the overlap its breathing room.
    return tile(ui, .{
        ui.column(.{ .gap = 32, .width = 340 }, .{
            ui.column(.{ .gap = 8 }, .{
                ui.el(.bubble, .{}, .{
                    ui.text(.{ .wrap = true }, "Ready to ship the components page?"),
                }),
                ui.el(.bubble, .{ .text = "+2", .text_alignment = .end }, .{
                    ui.text(.{ .wrap = true }, "The previews and the docs page both need one more pass before we cut it."),
                }),
            }),
            ui.column(.{ .gap = 8, .cross = .end }, .{
                ui.el(.bubble, .{ .variant = .primary }, .{
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
            ui.icon(.{}, "ellipsis"),
            ui.button(.{ .variant = .ghost, .icon = "chevron-right", .icon_placement = .trailing }, "Next"),
        }),
    });
}

fn buildList(ui: *Ui) Node {
    return tile(ui, .{
        ui.list(.{ .width = 340 }, .{
            ui.listItem(.{ .icon = "file-text" }, "Quarterly report.md"),
            ui.listItem(.{ .icon = "file-text", .selected = true }, "Launch checklist.md"),
            ui.listItem(.{ .icon = "folder" }, "Archive"),
            ui.listItem(.{ .icon = "music", .disabled = true }, "demo-track.wav"),
        }),
    });
}

/// The WINDOWED virtual list: 2,500 rows exist as arithmetic, the tree
/// holds only the visible window plus overscan, and the runtime owns
/// the scroll offset (the live preview host re-derives the scene on
/// every scroll observation, the `UiApp` loop's shape).
fn buildVirtualList(ui: *Ui) Node {
    const options = Ui.VirtualListOptions{
        .id = "docs-virtual-list",
        .item_count = 2500,
        .item_extent = 28,
        .overscan = 6,
        .width = 340,
        .height = 168,
        .viewport_fallback = 168,
    };
    const window = ui.virtualWindow(options);
    const rows = ui.arena.alloc(Node, window.itemCount()) catch return tile(ui, .{ui.column(.{}, .{})});
    for (rows, 0..) |*row, offset| {
        const index = window.start_index + offset;
        var node = ui.listItem(.{ .icon = "file-text" }, ui.fmt("Row {d} of 2500", .{index}));
        node.key = .{ .int = @intCast(index) };
        row.* = node;
    }
    return tile(ui, .{
        ui.panel(.{}, .{ui.virtualList(options, window, .{rows})}),
    });
}

fn buildTable(ui: *Ui) Node {
    return tile(ui, .{
        // The table register: a muted small header row, right-aligned
        // numeric column, hairline separators from the engine.
        ui.el(.table, .{ .width = 420 }, .{
            ui.el(.data_row, .{}, .{
                ui.el(.data_cell, .{ .text = "Invoice", .grow = 1, .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, .{}),
                ui.el(.data_cell, .{ .text = "Status", .grow = 1, .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, .{}),
                ui.el(.data_cell, .{ .text = "Amount", .grow = 1, .size = .sm, .text_alignment = .end, .style_tokens = .{ .foreground = .text_muted } }, .{}),
            }),
            ui.el(.data_row, .{}, .{
                ui.el(.data_cell, .{ .text = "INV-001", .grow = 1 }, .{}),
                ui.el(.data_cell, .{ .text = "Paid", .grow = 1 }, .{}),
                ui.el(.data_cell, .{ .text = "$250.00", .grow = 1, .text_alignment = .end }, .{}),
            }),
            ui.el(.data_row, .{ .selected = true }, .{
                ui.el(.data_cell, .{ .text = "INV-002", .grow = 1 }, .{}),
                ui.el(.data_cell, .{ .text = "Pending", .grow = 1 }, .{}),
                ui.el(.data_cell, .{ .text = "$150.00", .grow = 1, .text_alignment = .end }, .{}),
            }),
            ui.el(.data_row, .{}, .{
                ui.el(.data_cell, .{ .text = "INV-003", .grow = 1 }, .{}),
                ui.el(.data_cell, .{ .text = "Unpaid", .grow = 1 }, .{}),
                ui.el(.data_cell, .{ .text = "$350.00", .grow = 1, .text_alignment = .end }, .{}),
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

/// Model-driven dialog: Escape/click-outside dismisses through
/// `on_dismiss` (the model owns the close), and the reopen button the
/// closed state renders brings it back — the full open/close loop.
fn buildDialog(ui: *Ui, model: *const SceneModel) Node {
    if (!model.open) {
        return tile(ui, .{
            ui.button(.{ .variant = .outline, .on_press = .{ .set_open = true } }, "Reopen dialog"),
        });
    }
    return tile(ui, .{
        ui.el(.dialog, .{ .text = "Rename note", .width = 380, .height = 240, .padding = 24, .on_dismiss = .{ .set_open = false } }, .{
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
    // The line example, in the fully labeled register: two line series
    // sharing muted x/y ticks in reserved gutters, gridlines riding the
    // y-label lattice. Hover details are on, but they render only under
    // live pointer interaction — the static webp stays cold; the LIVE
    // wasm tile shows the snap cursor, per-point dots, and the floating
    // detail card listing both series' values.
    return tile(ui, .{
        ui.chart(.{
            .width = 420,
            .height = 180,
            .grid_lines = 3,
            .x_labels = &chart_month_labels,
            .y_labels = true,
            .hover_details = true,
        }, &.{
            .{ .kind = .line, .label = "p95", .values = &.{ 38, 44, 41, 52, 61, 48, 57, 72, 66, 78, 70, 85 } },
            .{ .kind = .line, .color = .text_muted, .label = "p50", .values = &.{ 12, 14, 13, 16, 18, 15, 17, 21, 19, 22, 20, 24 } },
        }),
    });
}

fn buildChartBar(ui: *Ui) Node {
    // The bar example: one bar series of small counts over weekday
    // categories. Bars force zero into a derived domain, so the
    // baseline hairline sits at an honest zero; hover details float the
    // hovered day's count on the live tile.
    return tile(ui, .{
        ui.chart(.{
            .width = 420,
            .height = 180,
            .baseline = true,
            .x_labels = &chart_day_labels,
            .hover_details = true,
        }, &.{
            .{ .kind = .bar, .label = "builds", .values = &.{ 12, 18, 9, 22, 17, 6, 4 } },
        }),
    });
}

fn buildChartArea(ui: *Ui) Node {
    // The area example: one line filled to the baseline (markup's
    // kind="area") on an explicit 0..1 domain — the fixed-window
    // sparkline register, no category labels. With no x labels the
    // hover card titles the hovered sample by index.
    return tile(ui, .{
        ui.chart(.{
            .width = 420,
            .height = 160,
            .y_min = 0,
            .y_max = 1,
            .grid_lines = 3,
            .hover_details = true,
        }, &.{
            .{ .kind = .line, .fill = true, .label = "memory", .values = &.{ 0.32, 0.34, 0.33, 0.38, 0.42, 0.4, 0.45, 0.51, 0.48, 0.55, 0.6, 0.57, 0.63, 0.68, 0.64, 0.7, 0.75, 0.72, 0.78, 0.82, 0.79, 0.84, 0.88, 0.86 } },
        }),
    });
}

const chart_month_labels = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
const chart_day_labels = [_][]const u8{ "mon", "tue", "wed", "thu", "fri", "sat", "sun" };

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

fn buildSpacer(ui: *Ui) Node {
    return tile(ui, .{
        ui.panel(.{ .width = 340, .padding = 12 }, .{
            ui.row(.{ .gap = 12, .cross = .center }, .{
                ui.text(.{}, "Docs"),
                ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Source"),
                ui.spacer(1),
                ui.button(.{ .variant = .secondary, .size = .sm }, "Changelog"),
            }),
        }),
    });
}

/// The resizable is an ENGINE-OWNED self-width panel: dragging anywhere
/// on it moves its own right edge (the grip marks the affordance) and
/// the model never hears about it. It resizes only itself — siblings do
/// not reflow with the drag — so the honest demo gives it open room to
/// grow into rather than a neighbor pretending to follow. Two
/// coordinated panes that reflow together are the split's job.
fn buildResizable(ui: *Ui) Node {
    return tileStart(ui, .{
        ui.row(.{ .height = 150 }, .{
            ui.el(.resizable, .{ .width = 180 }, .{
                ui.column(.{ .padding = 12, .gap = 4 }, .{
                    ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Sidebar"),
                    ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Drag the right edge"),
                }),
            }),
        }),
    });
}

// ------------------------------------------------- catalog hero scenes
//
// One representative variation per component for the Components index
// grid, composed inside the 16:9 hero frame. Padded like the page tiles
// but slightly tighter so the single variation renders large.

fn heroTile(ui: *Ui, children: anytype) Node {
    return ui.column(.{ .padding = 20, .main = .center, .cross = .center, .grow = 1 }, children);
}

fn heroTileStart(ui: *Ui, children: anytype) Node {
    return ui.column(.{ .padding = 20, .main = .center, .cross = .stretch, .grow = 1 }, children);
}

fn buildAccordionHero(ui: *Ui, model: *const SceneModel) Node {
    return heroTile(ui, .{
        ui.column(.{ .width = 300 }, .{
            accordionItem(ui, model, 0, "Is it accessible?", "Yes. Widgets carry semantic roles and one roving focus set."),
        }),
    });
}

fn buildAlertHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.column(.{ .width = 310 }, .{
            ui.el(.alert, .{ .text = "A new version of the shell is available." }, .{
                ui.text(.{ .wrap = true, .style_tokens = .{ .foreground = .text_muted } }, "Restart the app to finish updating."),
            }),
        }),
    });
}

fn buildAvatarHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.avatar(.{}, "CT"),
    });
}

fn buildBadgeHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.el(.badge, .{ .text = "Badge" }, .{}),
    });
}

fn buildBubbleHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.row(.{ .width = 300 }, .{
            ui.spacer(1),
            ui.el(.bubble, .{ .variant = .primary }, .{
                ui.text(.{ .wrap = true }, "Previews are rendering now."),
            }),
        }),
    });
}

fn buildButtonHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.button(.{ .variant = .primary }, "Button"),
    });
}

fn buildButtonGroupHero(ui: *Ui) Node {
    // The flush bar IS the component: three attached outline segments
    // with one shared corner language and collapsed interior seams.
    return heroTile(ui, .{
        ui.el(.button_group, .{}, .{
            ui.button(.{ .variant = .outline, .icon = "chevron-left" }, "Back"),
            ui.button(.{ .variant = .outline }, "Today"),
            ui.button(.{ .variant = .outline, .icon = "chevron-right", .icon_placement = .trailing }, "Next"),
        }),
    });
}

fn buildCardHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.el(.card, .{ .width = 300 }, .{
            ui.column(.{ .gap = 10 }, .{
                ui.text(.{}, "Deploy your app"),
                ui.text(.{ .wrap = true, .style_tokens = .{ .foreground = .text_muted } }, "Views, commands, and assets in one native binary."),
                ui.row(.{ .gap = 8 }, .{
                    ui.button(.{ .variant = .primary }, "Deploy"),
                    ui.button(.{ .variant = .ghost }, "Cancel"),
                }),
            }),
        }),
    });
}

fn buildChartHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.chart(.{
            .width = 300,
            .height = 140,
            .grid_lines = 3,
            .baseline = true,
            .x_labels = &chart_month_labels,
            .y_labels = true,
        }, &.{
            .{ .kind = .line, .fill = true, .label = "cpu", .values = &.{ 0.18, 0.24, 0.21, 0.32, 0.45, 0.38, 0.52, 0.61, 0.55, 0.68, 0.62, 0.74 } },
        }),
    });
}

fn buildCheckboxHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.checkbox(.{ .text = "Accept terms and conditions", .checked = true }),
    });
}

fn buildComboboxHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.el(.combobox, .{ .width = 260, .placeholder = "Search fruit…" }, .{}),
    });
}

fn buildDialogHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.el(.dialog, .{ .text = "Rename note", .width = 300, .height = 150, .padding = 20 }, .{
            ui.column(.{ .gap = 10 }, .{
                surfaceTitleSpacer(ui),
                ui.text(.{ .wrap = true, .style_tokens = .{ .foreground = .text_muted } }, "The new name shows up everywhere."),
                ui.row(.{ .gap = 8, .main = .end }, .{
                    ui.button(.{ .variant = .ghost }, "Cancel"),
                    ui.button(.{ .variant = .primary }, "Rename"),
                }),
            }),
        }),
    });
}

fn buildDrawerHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.el(.drawer, .{ .text = "Filters", .width = 220, .height = 155, .padding = 18 }, .{
            ui.column(.{ .gap = 10 }, .{
                surfaceTitleSpacer(ui),
                ui.checkbox(.{ .text = "Only unread", .checked = true }),
                ui.checkbox(.{ .text = "Has attachments" }),
            }),
        }),
    });
}

fn buildDropdownMenuHero(ui: *Ui) Node {
    return ui.column(.{ .padding = 16, .cross = .center, .grow = 1 }, .{
        ui.stack(.{}, .{
            ui.button(.{ .variant = .outline, .icon = "chevron-down" }, "Actions"),
            ui.el(.dropdown_menu, .{ .anchor = .below, .min_width = 180 }, .{
                ui.el(.menu_item, .{ .text = "Duplicate", .icon = "copy" }, .{}),
                ui.el(.menu_item, .{ .text = "Rename", .icon = "edit" }, .{}),
                ui.el(.menu_item, .{ .text = "Delete", .icon = "trash" }, .{}),
            }),
        }),
    });
}

fn buildIconHeroTile(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.row(.{ .gap = 24, .cross = .center }, .{
            ui.icon(.{}, "play"),
            ui.icon(.{}, "search"),
            ui.icon(.{}, "settings"),
            ui.icon(.{}, "git-branch"),
            ui.icon(.{}, "download"),
        }),
    });
}

fn buildInputHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.el(.input, .{ .width = 260, .placeholder = "Email address" }, .{}),
    });
}

fn buildListHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.list(.{ .width = 280 }, .{
            ui.listItem(.{ .icon = "file-text" }, "Quarterly report.md"),
            ui.listItem(.{ .icon = "file-text", .selected = true }, "Launch checklist.md"),
            ui.listItem(.{ .icon = "folder" }, "Archive"),
        }),
    });
}

const markdown_hero_sample =
    \\## Release notes
    \\
    \\The **markdown** widget renders rich text — *emphasis*,
    \\`inline code`, and [links](https://zero-native.dev) — through
    \\native widgets.
;

fn buildMarkdownHero(ui: *Ui) Node {
    return heroTileStart(ui, .{
        Md.view(ui, markdown_hero_sample, .{}),
    });
}

fn buildPaginationHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.el(.pagination, .{}, .{
            ui.button(.{ .variant = .ghost, .size = .icon, .icon = "chevron-left" }, ""),
            ui.button(.{ .variant = .outline, .selected = true }, "1"),
            ui.button(.{ .variant = .ghost }, "2"),
            ui.button(.{ .variant = .ghost }, "3"),
            ui.button(.{ .variant = .ghost, .size = .icon, .icon = "chevron-right" }, ""),
        }),
    });
}

fn buildPanelHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.panel(.{ .width = 280, .padding = 16 }, .{
            ui.column(.{ .gap = 6 }, .{
                ui.text(.{}, "Panel"),
                ui.text(.{ .wrap = true, .style_tokens = .{ .foreground = .text_muted } }, "A plain surface container: background, border, radius."),
            }),
        }),
    });
}

fn buildProgressHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.el(.progress, .{ .value = 0.62, .width = 260 }, .{}),
    });
}

fn buildRadioHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.el(.radio_group, .{ .gap = 10 }, .{
            ui.el(.radio, .{ .text = "Default", .checked = true }, .{}),
            ui.el(.radio, .{ .text = "Comfortable" }, .{}),
            ui.el(.radio, .{ .text = "Compact" }, .{}),
        }),
    });
}

fn buildResizableHero(ui: *Ui) Node {
    return heroTileStart(ui, .{
        ui.row(.{ .height = 130 }, .{
            ui.el(.resizable, .{ .width = 180 }, .{
                ui.column(.{ .padding = 12, .gap = 4 }, .{
                    ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Sidebar"),
                    ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Drag the right edge"),
                }),
            }),
        }),
    });
}

fn buildScrollHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.panel(.{ .width = 280, .height = 140 }, .{
            ui.scroll(.{}, .{
                ui.column(.{ .gap = 2, .padding = 8, .height = 220 }, .{
                    ui.listItem(.{}, "Changelog entry 14"),
                    ui.listItem(.{}, "Changelog entry 13"),
                    ui.listItem(.{}, "Changelog entry 12"),
                    ui.listItem(.{}, "Changelog entry 11"),
                    ui.listItem(.{}, "Changelog entry 10"),
                    ui.listItem(.{}, "Changelog entry 9"),
                }),
            }),
        }),
    });
}

/// The open select: the catalog card shows the anchored options menu,
/// the component's signature rendering.
fn buildSelectHero(ui: *Ui, model: *const SceneModel) Node {
    const active: usize = @min(model.index, select_options.len - 1);
    const trigger = ui.el(.select, .{
        .text = select_options[active],
        .selected = model.open,
        .on_press = .toggle_open,
    }, .{});
    const picker = if (model.open)
        ui.stack(.{}, .{
            trigger,
            ui.el(.dropdown_menu, .{
                .anchor = .below,
                .anchor_alignment = .stretch,
                .on_dismiss = .{ .set_open = false },
            }, .{
                ui.el(.menu_item, .{ .text = select_options[0], .selected = active == 0, .on_press = .{ .choose = 0 } }, .{}),
                ui.el(.menu_item, .{ .text = select_options[1], .selected = active == 1, .on_press = .{ .choose = 1 } }, .{}),
                ui.el(.menu_item, .{ .text = select_options[2], .selected = active == 2, .on_press = .{ .choose = 2 } }, .{}),
            }),
        })
    else
        ui.stack(.{}, .{trigger});
    return ui.column(.{ .padding = 16, .cross = .center, .grow = 1 }, .{
        ui.column(.{ .width = 240 }, .{picker}),
    });
}

fn buildSeparatorHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.column(.{ .gap = 12, .width = 280 }, .{
            ui.text(.{}, "Native SDK"),
            ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "A component catalog rendered by the engine."),
            ui.separator(.{}),
            ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Docs · Source · Changelog"),
        }),
    });
}

fn buildSheetHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.el(.sheet, .{ .text = "Share", .width = 300, .height = 158, .padding = 14 }, .{
            ui.column(.{ .gap = 10 }, .{
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

fn buildSkeletonHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.row(.{ .gap = 12, .width = 280 }, .{
            ui.el(.skeleton, .{ .width = 44, .height = 44 }, .{}),
            ui.column(.{ .gap = 8, .grow = 1, .main = .center }, .{
                ui.el(.skeleton, .{ .height = 14 }, .{}),
                ui.el(.skeleton, .{ .height = 14, .width = 160 }, .{}),
            }),
        }),
    });
}

fn buildSliderHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.el(.slider, .{ .value = 0.4, .width = 260 }, .{}),
    });
}

fn buildSpacerHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.panel(.{ .width = 300, .padding = 12 }, .{
            ui.row(.{ .gap = 12, .cross = .center }, .{
                ui.text(.{}, "Docs"),
                ui.spacer(1),
                ui.button(.{ .variant = .secondary, .size = .sm }, "Changelog"),
            }),
        }),
    });
}

fn buildSplitHero(ui: *Ui) Node {
    return heroTileStart(ui, .{
        ui.split(.{ .height = 130, .value = 0.35, .gap = 8 }, .{
            ui.panel(.{ .padding = 12, .min_width = 70 }, .{
                ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Sidebar"),
            }),
            ui.panel(.{ .padding = 12, .min_width = 100 }, .{
                ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Content"),
            }),
        }),
    });
}

fn buildStatusBarHero(ui: *Ui) Node {
    return ui.column(.{ .grow = 1 }, .{
        ui.column(.{ .grow = 1, .padding = 20, .main = .center, .cross = .center }, .{
            ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Window content"),
        }),
        ui.statusBar(.{}, "Ready — 3 notes synced"),
    });
}

fn buildStepperHero(ui: *Ui) Node {
    return heroTileStart(ui, .{
        ui.stepper(.{ .active = 1 }, &.{
            .{ .label = "Draft" },
            .{ .label = "Review" },
            .{ .label = "Publish" },
        }),
    });
}

fn buildSwitchHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.el(.switch_control, .{ .text = "Airplane mode", .checked = true }, .{}),
    });
}

fn buildTableHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.el(.table, .{ .width = 300 }, .{
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
        }),
    });
}

fn buildTabsHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.column(.{ .gap = 10, .width = 290 }, .{
            ui.row(.{}, .{
                ui.el(.tabs, .{}, .{
                    ui.el(.segmented_control, .{ .text = "Account", .selected = true }, .{}),
                    ui.el(.segmented_control, .{ .text = "Password" }, .{}),
                    ui.el(.segmented_control, .{ .text = "Team" }, .{}),
                }),
                ui.spacer(1),
            }),
            ui.panel(.{ .padding = 14 }, .{
                ui.column(.{ .gap = 4 }, .{
                    ui.text(.{}, "Account"),
                    ui.text(.{ .wrap = true, .style_tokens = .{ .foreground = .text_muted } }, "Make changes to your account here."),
                }),
            }),
        }),
    });
}

fn buildTextareaHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.el(.textarea, .{ .width = 280, .height = 90, .placeholder = "Write a release note…" }, .{}),
    });
}

fn buildInputGroupHero(ui: *Ui) Node {
    return heroTile(ui, .{
        inputGroupComposer(ui, 280, 118, true),
    });
}

fn buildTimelineHero(ui: *Ui) Node {
    return heroTileStart(ui, .{
        ui.timeline(.{ .gap = 0 }, .{
            ui.timelineItem(.{ .icon = "check", .variant = .primary, .title = "Build", .description = "Compiled 214 files in 1.8s." }),
            ui.timelineItem(.{ .indicator = "2", .title = "Test", .description = "Canvas and runtime suites passing.", .connector = false }),
        }),
    });
}

fn buildToggleHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.el(.toggle_group, .{}, .{
            ui.el(.toggle_button, .{ .text = "Left", .selected = true }, .{}),
            ui.el(.toggle_button, .{ .text = "Center" }, .{}),
            ui.el(.toggle_button, .{ .text = "Right" }, .{}),
        }),
    });
}

/// The tooltip in its natural pose: visible, anchored just above the
/// hovered control it annotates (the static capture forces the hover).
fn buildTooltipHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.column(.{ .gap = 8, .cross = .center }, .{
            ui.el(.tooltip, .{ .text = "Add to library" }, .{}),
            ui.button(.{ .variant = .outline }, "Hover"),
        }),
    });
}

fn buildTreeHero(ui: *Ui) Node {
    return heroTile(ui, .{
        ui.tree(.{ .width = 260, .gap = 2 }, .{
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

fn buildVirtualListHero(ui: *Ui) Node {
    const options = Ui.VirtualListOptions{
        .id = "docs-virtual-list-hero",
        .item_count = 2500,
        .item_extent = 28,
        .overscan = 6,
        .width = 280,
        .height = 112,
        .viewport_fallback = 112,
    };
    const window = ui.virtualWindow(options);
    const rows = ui.arena.alloc(Node, window.itemCount()) catch return heroTile(ui, .{ui.column(.{}, .{})});
    for (rows, 0..) |*row, offset| {
        const index = window.start_index + offset;
        var node = ui.listItem(.{ .icon = "file-text" }, ui.fmt("Row {d} of 2500", .{index}));
        node.key = .{ .int = @intCast(index) };
        row.* = node;
    }
    return heroTile(ui, .{
        ui.panel(.{}, .{ui.virtualList(options, window, .{rows})}),
    });
}
