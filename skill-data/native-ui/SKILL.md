---
name: native-ui
description: Authoring guide for native-rendered Native SDK apps - declarative .zml markup views plus Zig logic on the UiApp loop. Use when building or modifying native UI (widgets, layout, bindings, messages), writing .zml files, wiring Model/Msg/update, testing markup views, or verifying a native app through the automation harness.
---

# Author native UI with markup + Zig

A native-rendered Native SDK app is a markup view plus Zig logic:

- `src/<view>.zml` — the entire UI: elements, layout, bindings, message dispatch.
- `src/main.zig` — `Model` (plain struct), `Msg` (tagged union), `update(model, msg)`, and a `main` that hands them to `native_sdk.UiApp(Model, Msg)`.

The markup compiles to the same widget tree a hand-written `canvas.Ui(Msg)` builder view would produce: identical structural widget ids, identical typed handler table. Markup can never mutate state — it binds values and dispatches messages; all logic lives in Zig.

Editors highlight `.zml` well in HTML mode — projects ship `.vscode/settings.json` with `"files.associations": {"*.zml": "html"}` (add it if missing).

Start a new app by copying `examples/habits/` (smallest) or `examples/ui-inbox/`: change `app_exe_name` in build.zig, the name/id in app.zon, and put `0x0` as the fingerprint in build.zig.zon — the first build error prints the correct value to paste in. `src/runner.zig` and `assets/` copy verbatim.

## App wiring

```zig
const HabitsApp = native_sdk.UiApp(Model, Msg);

pub fn main(init: std.process.Init) !void {
    // `create` heap-allocates the multi-MB app struct and constructs the
    // Model in place — neither ever rides the stack (avoid `App.init(alloc,
    // model, ...)`: its by-value Model is a stack-overflow trap once the
    // Model grows).
    const app_state = try HabitsApp.create(std.heap.page_allocator, .{
        .name = "habits",
        .scene = shell_scene,             // one window, one gpu_surface view
        .canvas_label = "habits-canvas",  // must match the ShellView label
        .update = update,
        .markup = .{
            .source = @embedFile("habits.zml"),
            .watch_path = "src/habits.zml", // dev hot reload; omit in release
            .io = init.io,
        },
    });
    defer app_state.destroy();
    app_state.model = initialModel(); // boot state: assign through the pointer
    try runner.runWithOptions(app_state.app(), .{ ... }, init);
}
```

(`create` requires every Model field to carry a default; the model starts as `.{}` and boot state is assigned through the returned pointer. Tests that instantiate the app per fixture should use `create`/`destroy` too — a runtime-built Model passed to `init` by value crashes the test stack once models get large.)

The runtime owns the loop: install on first GPU frame, presentation, resize, pointer/keyboard dispatch into `update` + rebuild. With `watch_path` set, editing the `.zml` while the app runs hot-reloads the view within ~2s, preserving model state and widget ids; parse failures keep the last good view and set `app_state.markup_diagnostic` (line/column/message).

**Release: compile the markup at comptime.** `canvas.CompiledMarkupView(Model, Msg, source).build` parses the `.zml` entirely at compile time and produces the identical tree (same ids, handlers, dispatch) with no parser in the binary; markup or binding mistakes become compile errors with line/column. Hand it to `.view`, and gate the runtime engine per build mode:

```zig
const dev = @import("builtin").mode == .Debug;
const App = native_sdk.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = dev });
const CompiledView = canvas.CompiledMarkupView(Model, Msg, @embedFile("habits.zml"));
// options:
.view = CompiledView.build,
.markup = if (dev) .{ .source = ..., .watch_path = "src/habits.zml", .io = init.io } else null,
```

With both set (dev), the compiled view renders until the watched file first changes, then the interpreter hot-reloads it. See `examples/habits` for the full pattern.

### Webview panes: canvas + live web content in one window

Declare the webview in the scene next to the gpu_surface (parent it to the canvas view), reserve its region with an empty panel carrying a semantics label, and let `Options.web_panes` snap the webview to that widget's layout frame while the model drives navigation:

```zig
const shell_views = [_]native_sdk.ShellView{
    .{ .label = "app-canvas", .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
    .{ .label = "preview", .kind = .webview, .parent = "app-canvas", .url = "https://example.com/", .x = 240, .y = 76, .width = 704, .height = 548 },
};
// view: ui.panel(.{ .grow = 1, .semantics = .{ .label = "preview-pane" } }, .{})
fn panes(model: *const Model, out: []App.WebViewPane) usize {
    out[0] = .{ .label = "preview", .anchor = "preview-pane", .url = model.url(), .reload_token = model.reload_token };
    return 1;
}
// options: .web_panes = panes,
```

URL changes navigate; bumping `reload_token` reloads the same URL (the CenterPane/Preview-tab shape). Pane URLs must pass `security.navigation.allowed_origins`. Panes reconcile against the runtime's live webview state on every rebuild and presented frame, so shell relayouts cannot detach them. `examples/canvas-preview` is the live reference; `zig build test-canvas-preview-smoke` verifies it.

### Menu-bar extra (status item)

`Options.status_item` installs a macOS `NSStatusItem` once, on the installing frame; its menu items dispatch commands through the same `on_command` mapping the toolbar and menus use (source `.tray`):

```zig
.status_item = .{ .title = "ZN", .tooltip = "My App", .items = &.{
    .{ .id = 1, .label = "Refresh", .command = "app.refresh" },
    .{ .separator = true },
    .{ .id = 2, .label = "Quit", .command = "app.quit" },
} },
```

For a LIVE menu-bar extra (an open-count badge in the title, a latest-items dropdown), add `Options.status_item_fn` — the `web_panes` pattern: consulted on install and after every rebuild, re-applied only when its output changed (title and menu patch independently; the static `status_item` keeps icon/tooltip). Format derived strings into the provided scratch; item `command`s dispatch through `on_command` exactly like static items:

```zig
fn statusItem(model: *const Model, scratch: *App.StatusItemScratch) App.StatusItemState {
    const title = std.fmt.bufPrint(&scratch.title_buffer, "ZN {d}", .{model.open_count}) catch "ZN";
    scratch.items[0] = .{ .id = 1, .label = "Refresh", .command = "app.refresh" };
    var count: usize = 1;
    for (model.latest(), 0..) |issue, i| { // per-row commands: map "issue.select.N" in on_command
        scratch.items[count] = .{ .id = @intCast(10 + i), .label = issue.title, .command = issue.select_command };
        count += 1;
    }
    return .{ .title = title, .items = scratch.items[0..count] };
}
// options: .status_item_fn = statusItem,
```

Title updates retitle the live `NSStatusItem` button without re-creating it; platforms without a tray-title seam keep menu updates and log the title gap once.

### Native scrolling (macOS)

Zero app code: on macOS every non-virtualized `scroll` region is driven by an invisible `NSScrollView` — OS momentum, rubber-band overscroll, and the system overlay scrollbar — while the engine renders the content. `widget.value` stays the offset of record, so the rebuild reconcile rule ("user offset survives rebuilds until the source offset changes"), automation snapshot offsets (`scroll=[offset=..]`), and `Options.sync` all work exactly as before; the engine-drawn scrollbar simply stops painting for natively driven regions. Programmatic scrolls still work: change the source offset (or scroll via keyboard/automation) and the runtime pushes it into the native scroller. GTK/Win32 and mobile embeds keep the engine's wheel physics unchanged. Nested-scroll saturation handoff (inner region exhausted, outer continues) is per-region native today: the inner region rubber-bands at its edge like a standalone scroller.

### Native context menus

`ElementOptions.context_menu` declares per-widget items in the chrome-menu shape with typed messages; right/ctrl-click presents the real OS menu (macOS `NSMenu`) at the pointer and dispatches the selected item's `Msg`:

```zig
ui.listItem(.{
    .on_press = Msg{ .select = entry.index },
    .context_menu = &.{
        .{ .label = "Open Section", .msg = Msg{ .select = entry.index } },
        .{ .separator = true },
        .{ .label = "Refresh Dashboard", .msg = .refresh },
    },
}, entry.title)
```

The deepest declaring widget on the hit route wins; disabled items and separators are fine (`enabled = false`, `.separator = true`). Zero-code defaults need no declaration: editable text fields present the standard Cut / Copy / Paste / Select All menu wired to the existing clipboard actions, and a selected static text presents Copy. Builder-only by design — the closed markup grammar has no list-valued attributes, so markup apps attach menus from a wrapping Zig view function. macOS-only today (GTK popover menus and Win32 `TrackPopupMenu` are the documented future seams; unsupported platforms silently skip presentation). Touch long-press is design-noted for the mobile embeds: the iOS host's under-slop `Pending` touch state is the timer seam, pending a secondary-button leg in the embed ABI and `UIEditMenuInteraction` presentation. `examples/gpu-dashboard` nav rows carry a live menu; `zig build test-example-gpu-dashboard` and the runtime context-menu suite verify dispatch.

## Elements

| Markup | Widget | Notes |
| --- | --- | --- |
| `row`, `column` | flex containers | main axis horizontal / vertical |
| `stack`, `panel`, `card` | overlay containers | children stack on top of each other — `gap` can never space them and is a validation error (put a `column`/`row` inside for flow) |
| `scroll` | scroll_view | wrap multiple children in a `column` inside it |
| `list`, `grid` | list, grid | vertical stack / cell grid |
| `tabs`, `toggle-group`, `button-group`, `radio-group`, `breadcrumb`, `pagination` | row containers | children flow horizontally (tab buttons, toggle-buttons, radios, ...) |
| `table` > `table-row` > `table-cell` | table, data_row, data_cell | rows only inside a table, cells only inside a row (for/if wrappers are fine); cells are text leaves, dispatch with `on-press` |
| `dropdown-menu` | dropdown_menu | vertical menu surface; children are `menu-item`s. `anchor="below\|above"` floats it against its PARENT's frame (see Pickers): late z-pass above the whole tree, window-clipped, auto-flipping at the window edges, zero flow space. Pair with `on-dismiss` |
| `accordion` | accordion | header via `text` attr; children show while `selected`, dispatch `on-toggle` |
| `alert`, `bubble` | surfaces | `alert` title via `text` attr; children stack inside |
| `dialog`, `drawer`, `sheet` | modal surfaces | rendered in place — title via `text` attr, wrap in `<if>` to show conditionally |
| `resizable` | resizable | engine-managed drag handle; `width` sets the initial width |
| `split` | split | two-pane horizontal splitter: exactly two element children (nest splits for more panes), the engine synthesizes the draggable divider between them. `value` binds the model-owned first-pane fraction (0 lays out at 0.5), `on-resize` names an f32 Msg variant dispatched with every applied fraction (echo it back through `value` — see Splitters), `min-width` on the panes bounds the drag, `gap` sets the divider band thickness. The divider is focusable: Left/Right (Shift for bigger steps) adjust, Home/End jump to the clamp edges |
| `tree` | tree | disclosure-tree container (vertical flow): descendant rows carrying `role="treeitem"` — at ANY nesting depth — form one roving keyboard focus set with the ARIA tree keymap. Up/Down walk visible rows (selection follows focus through each row's `on-press`), Left collapses an expanded row or moves to the parent row, Right expands a collapsed row or moves to the first child row, Home/End jump to the edges, Enter/Space activate. Expandable rows bind `expanded` and `on-toggle`; the model owns selection and expansion (collapsed children are simply not rendered) |
| `text`, `badge`, `tooltip` | text leaves | text content, `{}` interpolation allowed; `text` is single-line unless `wrap="true"` |
| `button`, `toggle-button`, `list-item`, `menu-item`, `toggle`, `switch`, `select`, `avatar` | text-bearing controls | label is the text content; `button`, `toggle-button`, `list-item`, and `menu-item` also take `icon="save"` — a vector icon drawn inline (buttons/toggle-buttons before the label, icon-only when the content is empty: add a `label`; list/menu items as a leading slot), ONE hit target whose icon follows the element's enabled/disabled tint (no overlay stacking, no duplicated `on-press`); tab strips are `toggle-button` children, so tabs get icons this way; `select` shows `placeholder` while empty and dispatches `on-press`; `avatar` renders initials, or a runtime image via `image="{binding}"` (see the Images section) |
| `checkbox`, `radio`, `slider`, `progress` | value controls | `checked`, `value` |
| `text-field`, `input`, `search-field`, `combobox`, `textarea` | text entry | `placeholder`; edits via `on-input`, enter via `on-submit` |
| `status-bar` | status bar | text leaf: content only, no children |
| `separator`, `spacer` | separator, flexible space | `separator` is axis-aware: a horizontal rule in a `column`, a thin vertical divider in a `row`; give `spacer` a `grow` |
| `skeleton`, `spinner` | loading leaves | size `skeleton` with `width`/`height` |
| `icon` | built-in vector icon leaf | `name` picks a curated built-in stroke icon (literal, compile-checked; 45 names: search, plus, x, x-circle, check, check-circle, chevron-up/down/left/right, arrow-up/down/right, menu, settings, trash, edit, copy, external-link, play, pause, skip-back/forward, shuffle, repeat, music, volume, info, alert, download, save, folder, folder-open, file-text, sun, moon, eye, clock, git-pull-request, git-merge, git-branch, circle-dot, archive, refresh-cw, send); tint with `foreground`, size with `width`/`height` |
| `markdown` | rendered markdown subtree | leaf; `source` is one `{binding}` — see "Markdown in markup" |
| `stepper` > `step` | composite stage track | `active="{index}"` (required) derives each step's completed/active/pending state; steps are text leaves (no attributes) joined by connectors; stepper also takes `key`, `global-key`, `label` |
| `timeline` > `timeline-item` | composite ledger list | items only inside a timeline (for/if fine); items are leaves — `title` (required), `description`, `meta`, `indicator`, `variant`, `connector="false"` on the last item, `selected`; `on-press` makes the whole item pressable with a trailing chevron |

Not markup-expressible (deliberately — write these as Zig view functions with `canvas.Ui`): `image` (needs `ImageId` pixel references, runtime-registered — see the Images section), `icon_button` (`<button icon="...">` with empty content is the declarative icon button), `data_grid` (per-column cell templates), `popover`/`menu_surface` (anchored to runtime geometry), `segmented_control` (shell chrome kind; use `tabs`/`toggle-group`), `chart` (series are model-derived float arrays; markup's scalar bindings cannot carry arrays — build chart panes with `ui.chart` and compose them into markup apps as Zig subtrees; see the Charts section). Built-in vector icons ARE expressible: `<icon name="search"/>` (closed, compile-checked name set; `Ui.icon` is the Zig-view equivalent). App-authored icons: `canvas.svg_icon.parseComptime(@embedFile("icons/logo.svg"))` parses any SVG in the common 24x24 stroke-icon dialect at comptime; register the parsed table once at boot with `canvas.icons.registerAppIcons(&table)` and draw by name via `ui.appIcon(.{...}, "logo")` or `ElementOptions.icon` — registered names render exactly like built-ins on every draw path. Markup `<icon>`/`<button icon>` stay built-in-only (the compiled engine validates names at comptime, where runtime registrations cannot exist — engine parity). The one image binding markup DOES carry is the avatar's: `<avatar image="{user_image}">CT</avatar>` binds a `u64` ImageId model field/fn (the id is just model data; 0 keeps the initials fallback) — the embedded-asset exclusion stays.

## Attributes

Layout: `gap` (flow containers only — stacking containers `stack`/`panel`/`card`/`alert`/`bubble`/`dialog`/`drawer`/`sheet`/`resizable` layer their children, so `gap` there is a validation error, not silence: wrap the children in a `column`/`row` inside; on `split` it sets the divider band thickness), `padding` (uniform), `grow`, `width`, `height` (definite: the element is exactly that size — intrinsic content neither shrinks nor silently overflows it; `resizable` treats `width` as the initial width), `min-width` (a floor WITHOUT `width`'s definite max — the element may grow past it but never shrink below; on split panes it bounds the divider drag), `wrap` (`text` only: `wrap="true"` word-wraps at the width the element receives and reserves the wrapped height in columns; default is single-line), `text-alignment` (start|center|end — text leaves, status bars, surface titles; controls that own their label placement ignore it), `columns` (`grid` only: fixed column count, omit for the derived near-square grid; a teaching error elsewhere), `main` (start|center|end|space_between), `cross` (stretch|start|center|end), `virtualized`, `virtual-item-extent`, `anchor` (`dropdown-menu` only, literal `below`/`above`: floats the surface against its parent instead of the flow — auto-flips when the preferred side does not fit, height clamps to the chosen side, x clamps into the window), `anchor-alignment` (with `anchor`: `start`/`end`/`stretch` — stretch also widens the surface to at least the anchor's width, the select-menu look), `anchor-offset` (with `anchor`: literal gap in points, default 4).
Appearance/state: `variant` (default|primary|secondary|outline|ghost|destructive), `size` (default|sm|lg|icon), `disabled`, `checked`, `selected`, `value`, `placeholder`, `icon` (`button`, `toggle-button`, `list-item`, `menu-item`: literal built-in icon name drawn inline — buttons/toggle-buttons before the label, list/menu items as a leading slot; a teaching error anywhere else).
Focus: `autofocus` (focusable controls only — a teaching error elsewhere): moves keyboard focus to the element when it MOUNTS or when the bound value turns on, edge-triggered so holding it true never re-steals focus from the user. The TEA way to focus an editor on note-create (`<text-field autofocus="{editing}" ...>` or mount the field under an `<if>` with `autofocus="true"`; Zig views use `ElementOptions.autofocus`) and to give keyboard-first apps their first focus without a click.
Semantics: `role` (listitem, treeitem, button, ...; `treeitem` also makes the row part of its tree's roving keyboard focus set), `label` (accessible name), `expanded` (tree rows: disclosure state, model-owned — omit on leaves).
Identity: `key` (sibling-scoped), `global-key` (parent-independent — use for items that move between containers, e.g. board cards; ids then survive reparenting).
Window chrome: `window-drag="true"` (Zig: `.window_drag = true`) marks the element as a window-drag surface for hidden-titlebar windows — pressing its background or plain text/icons inside moves the WINDOW (drag starts only on actual movement), double-click zooms per the OS convention, and press-claiming children (buttons, fields) stay fully interactive via the ordinary press fall-through. macOS-only; elsewhere the press is dead space. See "Hidden titlebar" below.
Render channel (Zig-only, no markup attributes): `ElementOptions.opacity` and `ElementOptions.transform` wrap the element's emitted commands without reflowing siblings — the defaults (1, identity) emit nothing, opacity 0 culls painting (pair with `disabled` when fading interactive content), and a transform moves both rendering and pointer hit-testing while accessibility frames stay at the layout frame. Pair with `UiApp.Options.animations` for tweening.

Numbers are plain (`gap="12"`), booleans are `true`/`false` or a binding.

When children's minimum sizes exceed their container, debug builds log a `zero_canvas_layout` diagnostic naming the container, axis, and overflow in pixels — flex overflow is never silent. In Zig views, `.gap` on a stacking kind (`ui.panel(.{ .gap = 8 }, ...)`) logs a `zero_canvas_ui` warning in debug builds with the same lesson — it never fails the build.

### Chips: exclusive selection with `selected=`

The chip pattern — an exclusive group where the model owns which one is active — is a `toggle-group` of `toggle-button`s (or plain `button`s) whose `selected=` binds the model:

```html
<toggle-group gap="2" label="Theme">
  <for each="theme_prefs" as="p">
    <toggle-button size="sm" selected="{p == theme_pref}" on-toggle="set_theme:{p}">{p}</toggle-button>
  </for>
</toggle-group>
```

A `toggle-button` whose source asserts `selected` (this rebuild or the previous one) is model-driven: the source wins over the runtime's retained toggle on every rebuild, so exactly the model's selection is active — pressing a chip dispatches the Msg, the model moves the selection, and the old chip deactivates. Without a `selected=` that ever asserts, a `toggle-button` is uncontrolled: the runtime retains its pressed state across rebuilds (the multi-select formatting-bar case — bold/italic chips with zero app wiring). `button` with `selected=` is always model-driven (buttons never retain state) and dispatches `on-press`; `toggle-button` dispatches `on-toggle` (its activation is the toggle intent — an `on-press` there never fires). Model-driven chips need a handler that actually moves the model: a chip whose Msg is ignored keeps its retained press until the model asserts its `selected=`.

### Pickers: select is the trigger — compose the options as an ANCHORED dropdown

`select` and `combobox` are trigger controls, not complete pickers: `select` renders the closed dropdown shape (current value as content, `placeholder` while empty, `on-press` to open) and `combobox` is a text entry with a menu chevron — neither owns an options list. There is no `options=` attribute (the closed grammar has no list-valued attributes, same as `context_menu`); the options ARE the composition — a `dropdown-menu` of `menu-item`s under an `if`, beside the trigger inside a `stack`, floated with `anchor`:

```html
<stack>
  <select placeholder="Pick a repo" text="{current_repo}" on-press="toggle_repo_picker"/>
  <if test="{repo_picker_open}">
    <dropdown-menu anchor="below" anchor-alignment="stretch" on-dismiss="close_repo_picker">
      <for each="repos" key="name" as="r">
        <menu-item on-press="pick_repo:{r.name}" selected="{r.name == current_repo}">{r.name}</menu-item>
      </for>
    </dropdown-menu>
  </if>
</stack>
```

How the pieces fit, all model-owned (TEA):

- **Open state is the model's.** `toggle_repo_picker` flips the bool; the surface exists only while the `if` renders it. There is no hidden engine open flag.
- **`anchor` floats the menu.** The dropdown positions against its PARENT's frame (the `stack`, sized by the trigger): below it by default, flipping above when it doesn't fit and the other side has more room, height clamped to the chosen side, x clamped into the window. It consumes NO space in the flow (siblings never reflow), paints in a late z-pass above the whole tree, and escapes every ancestor scroll/clip region — window-clipped, not pane-clipped. `anchor-alignment="stretch"` widens it to at least the trigger's width (the select look).
- **`on-dismiss` closes it model-side.** Escape and a click outside the menu dismiss the surface and dispatch the Msg; `close_repo_picker` clears the bool. Escape works even when the trigger took no focus (a plain-text crumb): with no relevant focus chain it dismisses the topmost mounted anchored surface. The engine hides the surface immediately (the optimistic echo), and the next rebuild's source tree is truth — a model that keeps `open` true gets it back. Clicking the TRIGGER while open never double-fires: the anchor region owns its surface's toggling, so only `toggle_repo_picker` dispatches.
- **Items close on pick.** `pick_repo` sets the value AND clears the open flag — a click inside the surface never dismisses.
- **Keyboard**: once focus is in the menu (tab into it), tab wraps inside the surface (the floating focus scope) and Enter/Space activate items; Escape dismisses from the trigger or the menu.
- **Automation sees everything**: the floating menu and its items appear in widget snapshots at their real frames and `widget-click <item-id>` works while it is open.

`combobox` composes the same way (the model filters the `for` source as the user types via `on-input`). The Zig mirror is `ElementOptions.anchor`/`anchor_alignment`/`anchor_offset` + `on_dismiss` on a `dropdown_menu` (or `popover`/`menu_surface`, which stay Zig-only) built with `ui.eachCtx` for the options. Budget: at most 16 anchored surfaces may be mounted per view (`max_canvas_widget_anchored_per_view`, loud `error.WidgetAnchoredSurfaceLimitReached`) — an `anchor` inside a `<for>` body is almost always a mistake.

### Splitters: split panes with a model-owned fraction

`split` is the resizable two-pane seam: exactly two element children, and the engine synthesizes the draggable divider between them (resize cursor, focusable, ARIA separator whose value is the fraction). The fraction is MODEL-OWNED — the runtime applies each drag/keyboard step as an optimistic echo, dispatches `on-resize` with the applied fraction, and the model echoes it back through `value` so the next rebuild lays the panes exactly there:

```html
<split value="{sidebar_split}" on-resize="sidebar_resized">
  <column min-width="150">…sidebar…</column>
  <split value="{list_split}" on-resize="list_resized">
    <column min-width="220">…list…</column>
    <column min-width="280">…editor…</column>
  </split>
</split>
```

- **`on-resize` names an f32 Msg variant** (`sidebar_resized: f32`); `update` stores it (`model.sidebar_split = fraction`). The delivered fraction is the value the runtime already applied and clamped, so echoing it never fights the reconcile.
- **`min-width` on the panes bounds the drag** — the divider clamps so neither pane shrinks below its floor, on drag, keyboard, and layout alike.
- **Uncontrolled works too**: without `on-resize`, the divider position survives rebuilds under the source-wins reconcile (a source-side `value` change wins), but pane CONTENT lays out at the declared fraction until the model echoes — bind the handler for the exact controlled loop.
- **Keyboard**: Tab reaches the divider; Left/Right step the fraction (Shift for 2x), Home/End jump to the clamp edges. Automation drives it with `widget-drag`/`widget-key`, and snapshots show the divider as `role=separator` with the fraction as its value.
- Three panes = nested splits, as above. More than two children is a validation error (put conditional content inside a pane).

### Trees: disclosure rows with the ARIA tree keymap

`tree` turns a rail of pressable rows into a keyboard-navigable disclosure tree. Rows are ROLE-driven: any pressable element carrying `role="treeitem"` — at any nesting depth under the tree — joins one roving focus set:

```html
<tree gap="2" label="Folders">
  <for each="folderRows" key="id" as="f">
    <panel role="treeitem" expanded="{f.expanded}" on-press="select_folder:{f.id}" on-toggle="toggle_folder:{f.id}" label="{f.label}">
      <row gap="8" cross="center"><icon name="folder"/><text grow="1">{f.name}</text></row>
    </panel>
  </for>
</tree>
```

- **Up/Down walk the visible rows** in tree order, across nesting levels. Selection follows focus: each move dispatches the landed row's `on-press`, so the model owns the selection exactly like a click.
- **Left/Right are disclosure keys**: Left on an expanded row dispatches its `on-toggle` (collapse); on a collapsed row or leaf it moves focus to the PARENT row. Right on a collapsed row dispatches `on-toggle` (expand); on an expanded row it moves to the first child row.
- **Home/End** jump to the scope's first/last row; **Enter/Space** activate (`on-press`).
- **Expansion is model-owned**: expandable rows bind `expanded` (omit it on leaves) and the model renders child rows only while expanded — collapsed subtrees are simply not in the tree, so "visible rows" needs no engine bookkeeping. Flat rails (the notes folder list) are honest trees of leaves: Up/Down/Home/End/Enter work, Left/Right are inert.
- Single-select: selecting a row clears the previous selection across the WHOLE tree scope (rows nest, so this is not per-parent).

### Press-and-hold: on-hold

`on-hold` is the click-acts, hold-reveals menu-button shape — a control that acts on click and offers more on hold: a pointer held ~350 ms dispatches the hold Msg (the release then presses nothing), a quick click dispatches `on-press` as usual, and a right/ctrl-click whose route offers no context menu dispatches the hold Msg immediately (declared `context_menu`s always win). Like `on-press`, binding it makes any element pressable. The breadcrumb-switcher pattern: `on-press` selects the crumb, `on-hold` opens an anchored `dropdown-menu` of its siblings. Both legs are live-drivable: `native automate widget-hold <view> <id>` runs the pointer+timer gesture, `widget-context-press <view> <id>` the secondary click.

```html
<button on-press="select_crumb:{c.id}" on-hold="open_crumb_menu:{c.id}">{c.name}</button>
```

## Widget budgets and virtualization

Every view has fixed per-view capacities (`src/runtime/canvas_limits.zig`): **1024 retained widget nodes** (`max_canvas_widget_nodes_per_view` — the budget that matters for tree design; semantics and spans match it), 64 KiB retained widget text, **512 declared context-menu items** summed across all widgets of the view (`max_canvas_widget_context_menu_items_per_view` — separators count as items), **64 chart series / 16384 chart points** summed across all charts of the view (`max_canvas_widget_chart_*` — `ui.chart` downsamples every series to 256 points, so this is 64 maximal series or hundreds of sparklines), and per-frame content budgets (2048 commands, 8192 glyphs, 32 KiB frame text, 2048 path elements shared by icons and charts). Overflow is loud: `error.WidgetLayoutListFull` / `error.WidgetNodeLimitReached` / `error.WidgetContextMenuLimitReached` / `error.WidgetAnchoredSurfaceLimitReached` (at most **16 anchored floating surfaces** mounted per view — `max_canvas_widget_anchored_per_view`) fail tests under the harness's propagate policy and log a teaching diagnostic naming the budget in production (the app degrades to the previous frame). Watch headroom without overflowing: automation snapshots report `widget_nodes=N/1024 widget_semantics=N/1024 context_menu_items=N/512` on every gpu_surface view line.

Budget rules of thumb: 1024 nodes is roomy for a three-pane desktop app (~500 nodes measured for a dense sidebar + markdown detail + run surface), but node count scales with what is MOUNTED, not what is visible — so bound every unbounded collection:

- `virtualized` on `scroll`/`list`/`grid`/`table` (with `virtual-item-extent` for fixed-extent items) lays out only the visible window + overscan; a 10,000-item list materializes ~viewport/extent nodes. It bounds NODES, not your source data: the builder still walks every item, so derive bounded slices in the model for very large collections. Virtualized containers are app-driven for scrolling (wheel offsets do not mutate them).
- For non-uniform content (chat transcripts, ledgers, diffs), keep a bounded window in the model and slide it with `on-scroll` (see Messages) or explicit paging — the window follows the scrollbar instead of mounting everything.
- Remember multi-node rows multiply: a 4-node row × 50 mounted rows is 200 nodes before chrome.

## Style token attributes

Color and radius come from the design tokens, referenced by token NAME — literals only, no bindings, no raw colors (dynamic styling stays in Zig via `ElementOptions.style`):

- Color attributes: `background`, `foreground`, `accent`, `accent-foreground`, `border-color`, `focus-ring`. Values are `canvas.ColorTokens` field names — the complete list: `background`, `surface`, `surface_subtle`, `surface_pressed`, `text`, `text_muted`, `border`, `accent`, `accent_text`, `destructive`, `destructive_text`, `success`, `success_text`, `warning`, `warning_text`, `info`, `info_text`, `focus_ring`, `shadow`, `disabled`. `info` is the violet identity hue beside the status trio (merged PR badges, "new" chips). (`border-color`, not bare `border` — that name is reserved for a future width shorthand.)
- `radius` — `canvas.RadiusTokens` field names: `sm`, `md`, `lg`, `xl`.

```html
<row background="surface" radius="md" padding="8">
  <text foreground="text_muted">Muted caption</text>
</row>
```

References resolve against the app's LIVE tokens on every rebuild (`finalizeWithTokens`), so a themed app (`tokens`/`tokens_fn`) re-resolves them when the theme changes — dark mode flips `surface` automatically. An explicit `style` value set in Zig always wins over a token ref on the same field. Unknown token names are validation/compile errors.

## Expressions — the complete list

Attribute values take a literal or exactly ONE expression; there are only three forms:

1. `{path.to.value}` — a binding
2. `{a == b}` — equality (the only comparison; for `selected` states)
3. on `on-*` attributes: `msg` or `msg:{path}` — message tag plus optional payload binding

Text content (in text-bearing elements) additionally supports interpolation: `{open_count} open · {done_count} done`.

There is NO `!=`, `<`, `>`, arithmetic, function calls with arguments, or ternaries — by design. Any derived value or condition beyond these is a Zig model function you bind to (`{doneEmpty}`, `each="visible"`).

## Binding resolution rules

A path like `{h.streak}` resolves left to right, starting from the model or a `for` variable:

- everything bindable is declared INSIDE the Model struct: fields, and `pub fn` METHODS in the struct body. A file-scope `pub fn visibleRows(model: *const Model, ...)` written NEXT TO the struct is invisible to bindings and `for each` — `native markup check` still passes (it is grammar-only), and the view then fails at test/run time with "each does not name an iterable". If a binding or `each` cannot find your fn, first check it lives inside `pub const Model = struct { ... }`
- struct fields bind directly: `{habit_count}`, `{h.done}`
- zero-arg pub methods bind like fields: `{totalDays}` calls `pub fn totalDays(m: *const Model) usize`
- arena-taking scalar methods bind the same way: `{summary}` calls `pub fn summary(m: *const Model, arena: std.mem.Allocator) []const u8` — format derived display strings straight into the build arena (it lives exactly one view build). Works anywhere a scalar binding does — text interpolation, attribute values, message payloads — EXCEPT inside `{a == b}` equality, which rejects arena-computed values with a teaching error: compare the source fields, or bind a `pub fn ... bool`
- enums resolve to their tag name — so `{f}` renders "active", `{f == filter}` compares tags, and `set_filter:{f}` coerces the tag back into an enum payload
- `for each="name"` resolves, in order: a Model field that is a slice/array, a pub array/slice decl (`pub const filters = [_]Filter{...}`), a pub fn `(*const Model) []const T`, or a pub fn `(*const Model, std.mem.Allocator) []const T` — the allocator variant is how filtered/derived lists work (allocate from the passed arena)
- item methods work too: `{h.name}` may be a field or `pub fn name(h: *const Habit) []const u8`

Bindings are zero-argument. A parameterized query (cards of column X) becomes one model function per case.

## Derive, don't store

The model stores source-of-truth state ONLY: the raw items, the current filter, the draft text. Anything the view shows that is computable from those — counts, sums, filtered views, formatted strings — is a pub method the markup binds to, never a model field. A cached derivable must be re-maintained in every `update` arm and goes stale the moment one is missed; a derived method cannot.

```zig
// WRONG: derived state cached in the model, maintained by hand in update()
visible_count: usize,
summary_storage: [64]u8,   // preformatted display string

// RIGHT: the model keeps integers + the filter; methods derive per rebuild
pub fn visibleCount(model: *const Model) usize { ... }
pub fn visibleCents(model: *const Model) u64 { ... }
```

Derived numbers need no allocation: bind the methods and let text interpolation compose the line — this is exactly how the examples' status bars work (`examples/habits`):

```html
<status-bar>{habit_count} habits · {totalDays} total days</status-bar>
```

Computed strings (money, dates, percentages) are formatted into the BUILD ARENA inside the `for each` allocator fn — derive display rows whose string fields are `allocPrint`ed there. The arena lives for exactly one view build, so nothing is stored and nothing goes stale. Store amounts as integer cents; format at view time:

```zig
pub const VisibleExpense = struct { id: u32, date: []const u8, amount: []const u8 };

// A METHOD — declared inside `pub const Model = struct { ... }`. Bindings and
// `for each` resolve Model decls only; the same fn at file scope is invisible.
pub fn visible(model: *const Model, arena: std.mem.Allocator) []const VisibleExpense {
    const out = arena.alloc(VisibleExpense, model.expense_count) catch return &.{};
    var count: usize = 0;
    for (model.expenses[0..model.expense_count]) |*e| {
        if (!model.matches(e.*)) continue;
        out[count] = .{
            .id = e.id,
            .date = e.date(),
            .amount = std.fmt.allocPrint(arena, "${d}.{d:0>2}", .{ e.amount_cents / 100, e.amount_cents % 100 }) catch "",
        };
        count += 1;
    }
    return out[0..count];
}
```

A one-off formatted line that plain interpolation can't express (e.g. a currency total in a summary) is an arena-taking scalar fn bound directly:

```zig
pub fn summary(model: *const Model, arena: std.mem.Allocator) []const u8 {
    return std.fmt.allocPrint(arena, "{d} expenses · {s} total", .{
        model.visibleCount(), formatCents(arena, model.visibleCents()),
    }) catch "";
}
```

```html
<status-bar>{summary}</status-bar>
```

(The old workaround — wrapping the string in a one-element slice and iterating it with `<for each="summary" as="s">` — is no longer needed; bind the fn directly. Item methods take the arena too: `{e.amount}` may call `pub fn amount(e: *const Expense, arena: std.mem.Allocator) []const u8`.)

For `<if test>`, prefer an explicit boolean predicate method over numeric truthiness: `test="{hasHabits}"` with `pub fn hasHabits(m: *const Model) bool` states the condition; `test="{habit_count}"` works (non-zero is truthy, non-empty strings too) but hides it.

## Messages

`on-press`, `on-toggle`, `on-change`, `on-submit` (enter in a text field), `on-dismiss` (dismissible surfaces: dialog, drawer, sheet, dropdown-menu — dispatched when Escape or a click outside dismisses the surface, so the model owns the close), and `on-hold` (press-and-hold, see the Pickers section) take `tag` or `tag:{payload}`. The tag must be a variant of your `Msg` union; payload bindings coerce to the variant's payload type: integers, floats, enums (from tag names), `[]const u8`, bool. `on-input` is special: name a `Msg` variant whose payload is `canvas.TextInputEvent` and the runtime delivers each text edit in it. `on-scroll` (the `scroll` element only) is the same shape: name a `Msg` variant whose payload is `canvas.ScrollState` and the runtime delivers the post-scroll state — `offset`, `viewport_extent`, `content_extent`, `maxOffset()` — after every user scroll (wheel, kinetic momentum steps, keyboard, accessibility). In Zig views the constructors are `Ui.inputMsg(.tag)` / `Ui.scrollMsg(.tag)` on `on_input` / `on_scroll`.

Scroll offsets follow the same mirror discipline as text: the Msg carries the offset the runtime ALREADY applied, so store it in the model and echo it back through the scroll's `value` — the echoed source value equals the runtime offset, which the scroll reconcile rule treats as "unchanged", so rebuilds never stomp live scrolling. `on-scroll` is how long content pages or lazy-loads: keep a bounded window in the model and slide it from `offset` (near-end when `offset + viewport_extent` approaches `content_extent`).

A handler or update error DEGRADES, it does not exit the app: dispatch catches it, records it in a bounded ring (`runtime.dispatchErrors()`, the `error event=... name=...` lines and `dispatch_errors=` count in automation snapshots, and a `dispatch.error` trace record at error level), and the app keeps running. Trace-sink capacity failures likewise never fail dispatch — dropped records are counted (`dropped_trace_records=`), not fatal. Design for it: an arm that can fail should still surface its own status in the model; the error ring is the safety net, not the UX.

Presses follow ONE rule: a click lands on the nearest pressable widget under the pointer — plain text, icons, images, badges, and layout containers let it fall through to their closest pressable ancestor, and dragging still selects text. "Pressable" means an interactive kind (button, checkbox, list-item, ...) or ANY element with a bound `on-press`/`on-toggle` — the handler itself makes the element a hit target, so a pressable row is just `<panel on-press="open:{id}">` (or `<row on-press=...>`, `ui.row(.{ .on_press = ... })`) with plain text children: no empty-text overlays, no duplicating the handler onto every text leaf. Nested pressables resolve to the deepest one (a button inside a pressable row wins over the row); editable text fields, scroll containers, and modal surfaces (dialog, drawer, sheet, popover, menus) always claim their own presses, so a click in a field inside a pressable row places the caret instead of activating the row. The value/text handlers (`on-change`, `on-submit`, `on-input`) still only belong on controls — both engines and `markup check` reject them on layout/decoration elements with a teaching error.

## Text fields: the elm-style mirror pattern

The model applies every edit event and is the source of truth; the runtime keeps caret/selection while your source text matches, and a source-side change (like clearing on submit) wins:

```html
<text-field text="{draft}" placeholder="New task…" on-input="draft_edit" on-submit="add" grow="1" />
```

```zig
draft: canvas.TextBuffer(64) = .{},                   // model field: text + selection + composition
.draft_edit => |edit| model.draft.apply(edit),        // mirror every edit
.add => { model.addTask(model.draft.text()); model.draft.clear(); },  // clearing the source clears the field
```

See `examples/ui-inbox` for the complete pattern.

### Clipboard and selection (free — do not reimplement)

The runtime owns cmd/ctrl+C/X/V in editable text: copy writes the current selection to the system clipboard, cut copies then delivers the removal to your `on-input` handler as an `insert_text ""` edit, and paste arrives as an ordinary `insert_text` edit — the TEA mirror above stays consistent with zero extra code. Paste is clamped to the view's text capacity: when bytes were dropped, the keyboard event carries `edit_truncated = true` and your `TextBuffer` mirror sets its own `truncated` flag (check it if lost paste bytes matter to your UX; `TextBuffer` clamps oversized insertions at a UTF-8 boundary rather than dropping the edit). Shift+arrows/home/end extend the selection from the keyboard.

Static text is selectable too: click-drag inside one `text` leaf or `paragraph` (markdown bodies included) selects with a highlight, cmd/ctrl+C copies it, and pressing anywhere else clears it. Selection and pressing coexist inside pressable rows — dragging selects (and presses nothing), a plain click collapses the selection and lands on the row's `on-press`. Selection is per-widget by design — there is no document model ordering text across widgets, so a drag cannot span two paragraphs (copy per paragraph). The selection survives rebuilds while that widget's text bytes are unchanged, and shows up in semantics/automation snapshots as `selection=a..b` on the widget line. Clipboard access from `update` is `fx.writeClipboard` / `fx.readClipboard` on the effects channel (see Effects) — never a `pbcopy` spawn; `runtime.readClipboard(&buffer)` / `runtime.writeClipboard(text)` remain for code that holds the runtime.

## Effects: subprocesses and HTTP from update

`update` can take a third parameter — the effects channel — by declaring `.update_fx` instead of `.update` (existing two-argument apps are untouched; set exactly one):

```zig
const App = native_sdk.UiApp(Model, Msg);
const Effects = App.Effects;

pub fn update(model: *Model, msg: Msg, fx: *Effects) void { ... }
// options: .update_fx = update,
```

Boot-time effects — fetching the data the app opens with — go in `.init_fx`, TEA's init command. It runs exactly once, on the installing frame, before the first view build, so a loading flag set there is in the very first paint; results arrive as ordinary Msgs. This is THE way to boot-fetch — never a guarded `on_frame` (`on_frame` is the per-frame hook for renderer diagnostics and presented-frame reactions, and unguarded spawning from it refires forever):

```zig
fn boot(model: *Model, fx: *Effects) void {
    model.loading = true;
    fx.spawn(.{
        .key = issues_key,
        .argv = &.{ "gh", "issue", "list", "--json", "number,title" },
        .output = .collect,                        // whole JSON on the exit Msg
        .on_exit = Effects.exitMsg(.issues_loaded),
    });
}
// options: .init_fx = boot,   (works with either update form)
```

`fx.spawn` runs a subprocess on a runtime-owned worker thread and streams each stdout line back as a typed Msg; the exit arrives as one more Msg. Keys are caller-chosen `u64`s you keep in the model — no handles:

```zig
pub const Msg = union(enum) {
    start,
    cancel,
    line: native_sdk.EffectLine,     // payload types are fixed
    exited: native_sdk.EffectExit,
};

.start => fx.spawn(.{
    .key = stream_key,                          // model-stored identity
    .argv = &.{ "gh", "issue", "list" },
    .stdin = null,                              // optional, written once
    .on_line = Effects.lineMsg(.line),          // comptime constructors,
    .on_exit = Effects.exitMsg(.exited),        // like ui.inputMsg(.tag)
}),
.cancel => fx.cancel(stream_key),
.line => |line| model.recordLine(line),         // COPY line.line — it is
                                                // drain scratch, dead after
                                                // this update call
.exited => |exit| model.finish(exit),           // exit.reason, exit.code
```

Rules that keep this honest:

- Effects are update-side ONLY. The view never spawns anything — a button dispatches a Msg, and that Msg's update arm spawns. Markup stays declarative.
- One `on_exit` Msg per spawn, always. A spawn that cannot run (all `max_effects = 16` slots busy, duplicate active key, argv over capacity) still delivers it, with reason `.rejected`. Reasons: `exited` (code is real), `signaled`, `cancelled`, `rejected`, `spawn_failed`.
- After `fx.cancel(key)` returns, no further `on_line` Msgs for that spawn arrive; exactly one `.cancelled` exit follows. The process is killed and reaped — no zombies. Streaming a chat agent's stdout for minutes and cancelling mid-stream is the designed-for case.
- Overflow is never silent: a full completion queue drops lines but the next delivered line's `dropped_before` and the exit's `dropped_lines` carry the count; over-long lines arrive truncated with `truncated = true`. Capacities: 16 in-flight effects, 4 KiB per line by default, 64 queued completions.
- Agent CLIs emit whole events as single NDJSON lines far beyond 4 KiB (`claude -p --output-format stream-json` repeats the entire answer on one line). Raise the bound per spawn with `.max_line_bytes = 64 * 1024` — anything up to `max_effect_line_bytes_ceiling` (256 KiB); requests above the ceiling (or zero) are rejected through `on_exit`, never silently clamped. Lines beyond the granted bound still arrive truncated and flagged. The ceiling has envelope headroom: a stream that WRAPS another stream's lines (sandbox exec NDJSON envelopes carrying JSON-escaped agent events) can carry a full 64 KiB inner line with escaping overhead to spare — size the outer bound at roughly 2-3x the inner one.
- JSON-over-stdout (`gh --json`, `jq -c`, `curl`) emits one giant line the 4 KiB line cap would destroy. Spawn with `.output = .collect` instead of the default `.lines`: whole stdout (up to 512 KiB) arrives ONCE on the exit Msg as `exit.output`, plus the child's stderr tail (last 4 KiB) in `exit.stderr_tail` — check it when `exit.code != 0` (auth errors, usage messages). No `on_line` Msgs fire for a collect spawn; overflow arrives cut with `output_truncated`/`stderr_truncated` set, never silently. COPY `exit.output`/`exit.stderr_tail` in update — drain scratch like `line.line`; the scalar exit fields stay plain data, safe to store. (`.lines` mode still ignores stderr entirely; use `.collect`, or an sh `2>&1` re-route if you truly need interleaved streaming.)

`fx.fetch` runs one HTTP(S) request on a worker thread and delivers its terminal outcome — response, classified failure, timeout, or cancel — as exactly ONE Msg:

```zig
pub const Msg = union(enum) {
    load,
    stop,
    fetched: native_sdk.EffectResponse,   // the fixed payload type
};

.load => fx.fetch(.{
    .key = search_key,                     // same key space + 16 slots as spawns
    .method = .POST,                       // std.http.Method; default .GET
    .url = "https://api.example.com/run",  // http:// or https:// only
    .headers = &.{.{ .name = "authorization", .value = "Bearer abc" }},
    .body = "{\"q\":\"zig\"}",             // optional request payload
    .timeout_ms = 10_000,                  // whole exchange; default 30 s
    .on_response = Effects.responseMsg(.fetched),
}),
.stop => fx.cancel(search_key),
.fetched => |response| model.record(response),  // COPY response.body — drain
                                                // scratch, dead after this call
```

Fetch rules:

- Exactly one `on_response` Msg per fetch, always terminal. `response.outcome` says what happened: `.ok` (real HTTP status in `.status` — non-2xx included; an HTTP-level error is still a delivered response), `.rejected` (never started: slots busy, duplicate active key, malformed URL or non-http(s) scheme, over-capacity URL/headers/payload), `.connect_failed` (DNS or TCP), `.tls_failed`, `.protocol_failed` (mid-exchange), `.timed_out`, `.cancelled`.
- `response.body` is binary-safe bytes (zeros and high bits round-trip). Bodies over 256 KiB arrive cut at that bound with `truncated = true` — never silently. Capacities: 2 KiB URLs, 8 extra headers (1 KiB of names+values total), 64 KiB request payloads.
- `fx.cancel(key)` keeps the spawn promise: exactly one `.cancelled` response Msg, nothing for that fetch after it.

Streaming responses (`.response = .stream`) frame the body into `on_line` Msgs as lines arrive — the spawn `.lines` contract over HTTP. This is THE mode for NDJSON/SSE endpoints that hold the connection open for a command's whole lifetime (Vercel Sandbox `POST .../cmd` with wait+logs, agent event streams):

```zig
.run => fx.fetch(.{
    .key = exec_key,
    .method = .POST,
    .url = sandbox_cmd_url,
    .headers = &.{.{ .name = "authorization", .value = token }},
    .body = cmd_json,
    .timeout_ms = 600_000,                 // covers the STREAM's whole lifetime
    .response = .stream,                   // body arrives as on_line Msgs
    .max_line_bytes = 256 * 1024,          // envelope lines WRAP agent events
                                           // (JSON-escaped): size the outer
                                           // bound 2-3x the inner one
    .on_line = Effects.lineMsg(.exec_event),
    .on_response = Effects.responseMsg(.exec_done),
}),
.exec_event => |line| model.recordEvent(line),  // COPY line.line — drain scratch
.exec_done => |response| model.finish(response), // status set, body always empty
```

Stream rules: each body line is one `on_line` Msg (same payload type and copy rule as spawn lines; `max_line_bytes` mirrors the spawn override with the same 256 KiB ceiling); the terminal `on_response` Msg carries the real HTTP status with an empty body; `fx.cancel(key)` mid-stream stops the lines and delivers exactly one `.cancelled` terminal; the whole-exchange `timeout_ms` covers the stream's full lifetime, so raise it for long-running commands; lines dropped on a full queue that no later line reported ride the terminal's `response.dropped_before`. In the fake executor, `feedLine` feeds a stream fetch's lines and `feedResponse(key, status, "")` delivers its terminal.

`fx.writeFile` / `fx.readFile` are TEA-friendly file persistence — session snapshots, app state — without smuggling an `Io` handle from `main` into `update`. Same discipline as spawn and fetch: bounded, key-based (shared key space and 16 slots), exactly one terminal Msg with an explicit outcome:

```zig
pub const Msg = union(enum) {
    save,
    boot,
    saved: native_sdk.EffectFileResult,   // the fixed payload type
    loaded: native_sdk.EffectFileResult,
};

.save => fx.writeFile(.{
    .key = save_key,
    .path = model.sessionPath(),           // ≤ 1 KiB; parent dirs are created
    .bytes = model.snapshotJson(),         // ≤ 1 MiB, copied at call time
    .on_result = Effects.fileMsg(.saved),
}),
.boot => fx.readFile(.{
    .key = load_key,
    .path = model.sessionPath(),
    .on_result = Effects.fileMsg(.loaded),
}),
.saved => |result| model.noteSaved(result.outcome),
.loaded => |result| model.restore(result),  // COPY result.bytes — drain scratch
```

File rules:

- `result.outcome` is explicit: `.ok` (a read's whole content in `result.bytes`; a write fully on disk), `.not_found` (reads only — writes create the path, parent directories included), `.io_failed` (permissions, path is a directory, disk), `.truncated` (the file exceeds the 1 MiB `max_effect_file_bytes`; `result.bytes` is the first bound bytes — its own outcome, not a flag, because a cut JSON snapshot must not parse as whole), `.rejected` (never ran: slots busy, duplicate key, empty/over-long path, write bytes over the bound — an over-bound WRITE is rejected outright since a partial write would corrupt the file), `.cancelled`.
- Writes replace the file whole; `writeFile` bytes are copied at call time so the caller's buffer is immediately reusable. Reads deliver drain-scratch bytes — copy what the model keeps.
- In the fake executor: `pendingFileAt(0)` records `key`/`op`/`path`/`bytes` for assertions; `feedFileResult(key, .ok, "{...}")` answers a read (over-bound content is cut and rewritten to `.truncated`, mirroring the real reader), `feedFileResult(key, .ok, "")` acknowledges a write; failure outcomes pass through as fed.

`fx.writeClipboard` / `fx.readClipboard` put text on (and read it from) the system clipboard through the platform pasteboard — the same seam the runtime's cmd+C copy uses. Never spawn `pbcopy`/`pbpaste`/`xclip` for this. Same discipline: key-based (shared key space and 16 slots), exactly one terminal Msg with an explicit outcome. The pasteboard call is synchronous on the loop thread (no worker), but the result still arrives as an ordinary Msg on the next drain:

```zig
pub const Msg = union(enum) {
    share,
    copied: native_sdk.EffectClipboardResult,   // the fixed payload type
};

.share => fx.writeClipboard(.{
    .key = share_key,
    .text = model.shareLine(),             // ≤ 64 KiB, copied at call time
    .on_result = Effects.clipboardMsg(.copied),
}),
.copied => |result| model.noteCopied(result.outcome),
```

Clipboard rules:

- `result.outcome` is explicit: `.ok` (a write is on the clipboard whole; a read's content is in `result.text` — drain scratch, copy what the model keeps), `.failed` (the platform refused: no clipboard service on the host, read content over the 64 KiB `max_effect_clipboard_bytes`, pasteboard error — a read never arrives cut), `.rejected` (never ran: slots busy, duplicate key, write text over the bound), `.cancelled`.
- Writes are text/plain and replace the clipboard whole; rich-data clipboard stays on the runtime API (`runtime.writeClipboardData`).
- In the fake executor: `pendingClipboardAt(0)` records `key`/`op`/`text` for assertions; `feedClipboardResult(key, .ok, "pasted")` answers a read, `feedClipboardResult(key, .ok, "")` acknowledges a write; failure outcomes pass through as fed. Under the real executor the test harness's null platform records the write — assert `harness.null_platform.lastClipboardData()`.

`fx.startTimer` / `fx.cancelTimer` are key-based timers on the same channel — an auto-refresh, a poll, a debounce — one-shot or repeating, each fire delivered as one `on_fire` Msg. Timers are their own fixed table (16, `max_effect_timers`) and their own key namespace: they consume none of the 16 effect slots and never collide with spawn/fetch/file keys:

```zig
pub const Msg = union(enum) {
    tick: native_sdk.EffectTimer,    // the fixed payload type
    ...
};

fx.startTimer(.{
    .key = refresh_key,
    .interval_ms = 30_000,
    .mode = .repeating,               // .one_shot (default) fires once, then retires
    .on_fire = Effects.timerMsg(.tick),
}),
.tick => |timer| switch (timer.outcome) {
    .fired => model.refresh(),        // timer.timestamp_ns is the platform fire time
    .rejected => model.noteTimerRejected(timer.key),
},
```

Timer rules: starting a key that is already an active timer REPLACES it (interval/mode/`on_fire` update in place — the friendly behavior for an auto-refresh whose cadence changes); `fx.cancelTimer(key)` stops it, unknown keys are a no-op; rejection is never silent — a full timer table, a zero `interval_ms`, or a platform without a timer service delivers exactly one Msg with outcome `.rejected`. In the fake executor, `pendingTimerAt(0)` records `key`/`interval_ms`/`mode` and `fireTimer(key)` fires by hand (one-shot slots retire after the fire), draining through the same `.wake` path as `feedExit`.

Test effects with the fake executor — deterministic, no processes, no network:

```zig
app_state.effects.executor = .fake;             // before dispatching (and before
                                                // the first frame if using init_fx —
                                                // the boot spawn is then recorded too)
try app_state.dispatch(&harness.runtime, 1, .start);
const request = app_state.effects.pendingSpawnAt(0).?;   // assert key/argv/output mode
try app_state.effects.feedLine(stream_key, "stream line 1");
try app_state.effects.feedExit(stream_key, 0);
try harness.runtime.dispatchPlatformEvent(app, .wake);   // drain -> update

// .collect spawns: feedLine accumulates (bytes + newline, like a real child
// printing that line), feedStderr fills the tail, feedExit delivers both.
try app_state.effects.feedLine(issues_key, "{\"number\":1}");   // no on_line Msg
try app_state.effects.feedStderr(issues_key, "warning: slow\n");
try app_state.effects.feedExit(issues_key, 0);                  // exit.output + exit.stderr_tail

const fetch_req = app_state.effects.pendingFetchAt(0).?; // assert key/method/url/headers/body
try app_state.effects.feedResponse(search_key, 200, "{\"ok\":true}");
try harness.runtime.dispatchPlatformEvent(app, .wake);   // Msg{ .fetched = ... }
```

The `.wake` platform event is how live platforms marshal worker completions onto the loop thread (macOS main-queue dispatch, GTK `g_idle_add`, Win32 `PostMessage`); dispatching it in tests exercises the same drain path. Note that after `fx.cancel(key)` runs in `update`, a subsequent `feedExit(key)` correctly fails with `error.EffectNotFound` — the cancel already delivered the terminal `.cancelled` exit, so there is no active effect left to feed. See `examples/effects-probe` for the complete pattern, including the live cancel flow.

## Secondary windows: model-declared (`windows_fn` + `window_view`)

Windows are model state, like an anchored surface's open flag. `Options.windows_fn` returns the descriptors that should exist RIGHT NOW (presence is visibility — no `visible` flag; the platform window channel has no hide); `Options.window_view` builds each declared window's whole canvas tree by window label. The runtime reconciles after every dispatch: create the newly declared, close the no-longer-declared, rebuild every open window's view from the same model.

```zig
fn windows(model: *const Model, scratch: *App.WindowsScratch) []const App.WindowDescriptor {
    var count: usize = 0;
    if (model.settings_open) {
        scratch.windows[count] = .{
            .label = "settings", .canvas_label = "settings-canvas",
            .title = "Settings", .width = 360, .height = 320,
            .on_close = .settings_closed,   // the user's close button, as a Msg
        };
        count += 1;
    }
    return scratch.windows[0..count];
}
fn windowView(ui: *App.Ui, model: *const Model, window_label: []const u8) App.Ui.Node { ... }
// options: .windows_fn = windows, .window_view = windowView,
```

Rules that matter:
- **Every canvas label must be unique across the app** (main + declared windows); input routes back by it, and automation verbs (`widget-click <canvas-label> <id>`, `screenshot`) address any window's canvas the same way.
- **A user close dispatches `on_close`** (the dismissal precedent): the window is already gone as the optimistic echo; clear the open flag in `update` — or keep declaring the window and the next rebuild brings it back (source wins). A close the model itself initiated never echoes a Msg.
- **Budget**: at most `UiApp.max_ui_windows` (4) declared windows; excess warns and is ignored. Every dispatched Msg rebuilds every open window's view.
- **Present-before-show**: canvas windows (any `gpu_surface` view — startup, scene, and declared windows alike) are created ordered-out and become visible only after their first canvas frame presents, so opening one never flashes blank. Automatic (`WindowOptions.show = .on_first_present`, derived from the views); webview windows show immediately. The null platform records `window_show`, `window_visible`, and present/shown sequence numbers for ordering assertions; `NATIVE_SDK_WINDOW_TIMING=1` logs create→show latency on macOS.
- **Markup binds ONE window's content** — there is no `window` element in the closed grammar. A markup-authored secondary window is a `canvas.CompiledMarkupView` whose `build` `window_view` calls for that label.
- **Titlebar**: descriptors accept `.titlebar = .hidden_inset` (content under a transparent titlebar, macOS keeps the traffic lights) or `.hidden_inset_tall` (the taller unified band; macOS centers the lights in it); give the window's header `window-drag="true"` so it moves the window. See "Hidden titlebar" below.
- Tests: after the open Msg, deliver the new window's `gpu_surface_frame` (its window id from `runtime.listWindows`) to install its tree; simulate a user close by dispatching `.window_frame_changed` with `open = false`. See `examples/system-monitor` (gear chip -> settings window).

## Hidden titlebar: `titlebar = "hidden_inset"`/`"hidden_inset_tall"` + `window-drag` + `on_chrome`

The modern editor-app shape — content under a transparent titlebar, the app's header as the working titlebar. Two heights: `hidden_inset` keeps the compact band (~28pt, traffic lights hug the top), `hidden_inset_tall` switches to the unified-toolbar band (~52pt, macOS vertically centers the traffic lights — the tall unified-toolbar look). Pick tall when the header replacing the titlebar is toolbar-height, so the lights center against it. Three parts, all declared:

1. **app.zon**: `.titlebar = "hidden_inset"` or `"hidden_inset_tall"` on the shell window (and the matching `.titlebar = .hidden_inset`/`.hidden_inset_tall` on the `ShellWindow` in main.zig). The first shell window's declaration threads through the STARTUP window create, so the main window's chrome is right from the first frame; `zig build validate` checks the value.
2. **The header row** gets `window-drag="true"`: its background (and plain text/icons inside) moves the window; buttons inside stay buttons; double-click zooms (macOS honors the user's titlebar double-click preference).
3. **`Options.on_chrome`** (`fn (chrome: platform.WindowChrome) ?Msg`) delivers the chrome overlay geometry — `chrome.insets`: titlebar band height on top (compact or tall), traffic-light extent on the leading edge; `chrome.buttons`: the traffic-light cluster's frame in content coordinates (top-left origin), the vertical truth for centering. All-zero in fullscreen, on standard chrome, and on other platforms. It fires BEFORE the first view build and on changes; store the geometry in the model, pad the header with a leading `<spacer width="{chrome_leading}" />`, and with the tall band match the header's height to `insets.top` (floored at its natural height) so `cross="center"` puts its controls on the lights' centerline.

macOS-first like `resizable = false`: GTK/Win32 keep standard chrome and the whole channel is harmless there. Full retrofit: `examples/markdown-viewer` (tall band; toolbar row is the drag region and tracks the band height). Tests: the null platform records `startWindowDrag` calls (`window_drag_starts`), per-window `window_titlebar`, and serves settable `window_chrome` (insets + buttons frame).

## Time: wall clock + monotonic, with a testable seam

Zig 0.16 puts `std.time.milliTimestamp` behind `std.Io`, which `update` never sees — do NOT call `clock_gettime` yourself. The facade owns the clocks:

```zig
native_sdk.nowMs()                  // wall ms since the Unix epoch (i64) — ledger timestamps
native_sdk.nowNanoseconds()         // wall ns (i128)
native_sdk.monotonicMs()            // duration clock (u64, arbitrary origin, never goes backwards)
native_sdk.monotonicNanoseconds()   // subtract two reads for an elapsed time
```

Time-DEPENDENT logic (elapsed-time display, timeouts driven from update) should hold the seam in the model instead of calling the free functions, so tests stay deterministic:

```zig
pub const Model = struct { clock: native_sdk.Clock = .system, ... };
.step_started => model.entry.started_ms = model.clock.wallMs(),

// in tests:
var test_clock: native_sdk.TestClock = .{};
model.clock = test_clock.clock();
test_clock.advanceMs(1500);          // moves wall + monotonic together
test_clock.setWallMs(1_700_000_000_000);  // NTP-style wall jump, monotonic untouched
```

Wall answers "what time is it?" (jumps with OS clock adjustments); monotonic answers "how long did it take?". Don't subtract wall timestamps for durations.
## Images: runtime-registered pixels + the avatar pattern

Image pixels are runtime-registered resources keyed by a caller-chosen `ImageId` (`u64` in the model, effect-key style; 0 = no image). The framework bundles NO codecs — encoded bytes decode through the platform (CGImageSource / gdk-pixbuf / WIC) via `PlatformServices.decode_image_fn`. Registration lives on the effects channel (synchronous calls, not effects — no Msg follows):

```zig
// The fetch-avatar path, one update arm; id reaches the model ONLY on success,
// so the avatar shows initials while loading and after failure.
.fetched => |response| {
    if (response.outcome == .ok and response.status == 200) {
        _ = fx.registerImageBytes(avatar_image_id, response.body) catch return;
        model.avatar_image = avatar_image_id;
    }
},
```

```zig
// Zig views (image and icon content is markup-excluded):
ui.avatar(.{ .image = model.avatar_image, .semantics = .{ .label = "Octocat" } }, "OC"),
ui.image(.{ .image = model.chart_image, .width = 120, .height = 80, .semantics = .{ .label = "Chart" } }),
```

```html
<!-- Markup avatars bind the same model id: one {binding} to the u64 ImageId
     (a field or pub fn — never a literal); 0 renders the initials fallback. -->
<avatar image="{avatar_image}" label="Octocat">OC</avatar>
```

Rules:

- `fx.registerImage(id, w, h, rgba8)` takes already-decoded straight-alpha RGBA8 (exactly `w*h*4` bytes; the runtime copies — your buffer is free on return). `fx.registerImageBytes(id, bytes)` decodes first. `fx.unregisterImage(id)` frees the slot. Outside UiApp: `Runtime.registerCanvasImage` / `registerCanvasImageBytes` / `unregisterCanvasImage`.
- Re-registering an id replaces the pixels; every view repaints and GPU caches re-upload off the changed content fingerprint — no invalidation calls. For caches, mint fresh ids (effect-key style, monotonically increasing) and `unregisterImage` the evictee — never re-key different content onto a live id.
- Bounded and loud (`canvas_limits`): 16 slots (`max_registered_canvas_images`), 1 MiB per image (`max_registered_canvas_image_pixel_bytes`, 512×512 RGBA8 — avatar/icon scale). Errors: `error.ImageRegistryFull`, `error.ImageTooLarge`, `error.ImageDecodeFailed`, `error.InvalidImageId`/`InvalidImageDimensions`, `error.UnsupportedService` (codec-less platform).
- A draw referencing an unregistered id skips — a transient loading state can never fail presentation. `ui.avatar` clips a set image to the circle (`cover` fit) and renders the initials argument otherwise.
- Registered images render in live presentation AND `renderCanvasScreenshot`/automation screenshots, so goldens can assert on them.
- Deterministic tests: `harness.null_platform.image_decode = true` enables a strict decoder for the exact PNG subset `canvas.png.writeRgba8` emits — encode a raw RGBA fixture with the canvas PNG writer and drive the full decode→register→draw path with no bundled codec (`src/runtime/canvas_image_tests.zig` is the reference).

## Structure tags

```html
<for each="visible" key="id" as="t"> <row>...</row> </for>   <!-- one or more element children; key names an item field -->
<if test="{c.movable}"> <button ...>Move</button> </if>
<else> <text>Done!</text> </else>                             <!-- must directly follow the if -->
```

A `<for>` body takes one or more children — elements, `<use>`, `<if>`/`<else>` arms, or nested `<for>`s — so polymorphic rows need no wrapper node: put the `<if>`/`<else>` arms directly in the body and each item emits whichever arm wins. With `key`, every node an item emits shares the item's identity (same-kind siblings within one item are disambiguated automatically); a node's own `key`/`global-key` still wins. An `<else>` directly after a `</for>` renders the empty state when the iterable has no items:

```html
<for each="visible" key="id" as="t">
  <if test="{t.done}"> <badge>done</badge> </if>
  <else> <text>{t.title}</text> </else>
</for>
<else> <text>Nothing yet</text> </else>                       <!-- renders when visible is empty -->
```

There is no `else-if` chain tag: nest an `<if>`/`<else>` inside the `<else>` body instead. `<if>` has no negation operator either — prefer an explicit boolean predicate method on the model per arm.

## Templates: `<template>` + `<use>`

When the same subtree repeats with different data (board columns, dashboard sections), define it ONCE at the top of the file — zero or more `<template>` definitions, then exactly one view root:

```html
<template name="board-column" args="title cards">
  <column grow="1" gap="8" label="{title}">
    <text foreground="text_muted">{title}</text>
    <for each="cards" key="id" as="c">
      <row global-key="{c.id}"><text>{c.title}</text></row>
    </for>
  </column>
</template>
<row grow="1" gap="12">
  <use template="board-column" title="Todo"  cards="{todoCards}" />
  <use template="board-column" title="Doing" cards="{doingCards}" />
  <use template="board-column" title="Done"  cards="{doneCards}" />
</row>
```

Rules and semantics:

- A template takes `name` (kebab-case), optional `args` (space-separated names), and exactly one element child. `<use template="name">` is allowed anywhere an element is (including as a `for` child or the view root); its other attributes must match the template's `args` exactly — missing or extra args are errors.
- The template body is built IN PLACE of the `<use>`: structural widget ids hash through the parent chain at the expansion site, exactly as if you had written the body inline. Two uses at different sites get different ids; the same site is stable across rebuilds. Rewriting copy-pasted markup as a template does not change any widget id.
- Args bind like `for` variables: an arg whose value is a `{binding}` naming an iterable (model slice/array field, pub decl, or model fn — the same set `for each` accepts) is iterable inside the template (`<for each="cards" ...>`); any other arg (literal or scalar binding) is a value usable in bindings, interpolation, and equality (`{title}`, `label="{title}"`). Args are evaluated at the use site; inside the body only the args, the model, and the body's own loop variables are in scope. Value args are scalars — `{arg.field}` is an error.
- Uses inside a template body may only reference templates defined EARLIER in the file (this also makes recursion impossible). Bindings stay zero-argument: the template deduplicates the view, the per-case query stays a named model function.

Both engines implement templates: the interpreter expands at build time, `CompiledMarkupView` inlines each use at comptime with the identical result. See `examples/kanban/src/board.zml`.

## Markdown in markup: `<markdown>`

A leaf element that renders a markdown string (the GFM subset below) as ordinary widgets, wiring `native_sdk.markdown` for you — both engines implement it identically:

```html
<markdown source="{issue_body}" on-link="open_url" on-details="toggle_details" details-expanded="{details_expanded}" />
```

- `source` (required): one `{binding}` producing the markdown text — a `[]const u8` field, zero-arg fn, or arena-taking fn (compose the document into the build arena at view time).
- `on-link` (optional): a BARE Msg tag — no `:{payload}` — whose payload is the pressed link URL; declare `open_url: []const u8` in `Msg`.
- `on-details` (optional): a bare Msg tag whose payload is the `<details>` block's document-order index; declare `toggle_details: usize`.
- `details-expanded` (optional): one `{binding}` naming a `[]const bool` iterable (a model field, pub decl, or fn — the same sources `for each` accepts); flags are read in details-block document order. Keep a bounded `details_expanded: [8]bool` in the model and toggle it in `update`.
- `issue-link-base` (optional): a literal URL prefix or one `{binding}` producing it; `#123` references at word boundaries become links to base ++ number (`issue-link-base="ghissue://"` links `#123` to `ghissue://123` — an app scheme your `on-link` handler intercepts, or a web base like `https://github.com/owner/repo/issues/`). Off by default: resolving a ref needs repo context.
- No children, no text content, no other attributes (teaching errors point at misuse). Without the details wiring, `<details>` blocks render collapsed and inert; without `on-link`, links render styled but inert.

## Pipeline composites: stepper, timeline, nav

Three composites for pipeline/run UIs — pure compositions of existing widgets (no new kinds), identical from markup and `canvas.Ui`:

```html
<stepper active="{stage_index}">
  <step>Work</step><step>Triage</step><step>Review · {round}</step><step>Fix</step><step>Ready</step>
</stepper>
<timeline gap="4">
  <for each="ledger" key="slot" as="entry">
    <timeline-item title="{entry.title}" description="{entry.summary}" meta="{entry.meta}" variant="{entry.tone}" on-press="open_step:{entry.slot}" />
  </for>
</timeline>
```

- Stepper semantics: a `list` of `listitem`s; the active step is `selected` and every label carries its state (`"Review (active)"`) plus list position — assert pipeline stage from automation snapshots by label.
- Timeline item: leading badge (dot colored by `variant`, or `indicator` text like `"✓"`), connector rail (`connector="false"` ends it), bold title, wrapped muted description, muted meta line. With `on-press` the item gains a trailing chevron and the press binds to the item's root (role `listitem`, focusable, labeled by the title) — clicks on the title/description/meta fall through to it, so a click anywhere dispatches and dragging still selects the text. No hover fill or description line-clamp in v1.
- Zig: `ui.stepper(.{ .active = ... }, &.{ .{ .label = "Work" }, ... })`, `ui.timeline(options, items)`, `ui.timelineItem(.{ .title = ..., .on_press = ... })`.
- Nav (Zig-only; markup swaps with `<if>`): `ui.nav(.{ .active = model.nav_depth, .retain = true }, .{ pageA, pageB })` — the model owns the stack; pages are index-keyed so widget ids (and engine scroll/text state) are stable across swaps; `retain=true` keeps inactive pages mounted-but-hidden (state preserved, excluded from render/hit-test/focus/semantics), default unmounts. Instant swap, no animation in v1; move focus in `update` when pushing/popping if the focused widget lives on the outgoing page.

## Charts (Zig views)

`ui.chart` is the data-visualization leaf (`.chart` widget kind): model-derived series drawn through the vector path pipeline with token colors — charts retheme with the palette, repaint exactly when their data changes (value equality, not identity), and report series semantics to automation. Zig-only: markup bindings are scalar, so chart panes are Zig subtrees.

```zig
// Star-history: cumulative stars per repo. 10k-point series are fine —
// ui.chart downsamples deterministically past 256 points per series.
ui.chart(.{ .grow = 1, .height = 220, .y_min = 0, .grid_lines = 3 }, &.{
    .{ .kind = .line, .values = model.starsFor(0), .fill = true, .color = .accent, .label = "native-sdk" },
    .{ .kind = .line, .values = model.starsFor(1), .color = .info, .label = "ovation" },
})
// Sparkline tile: zero-baseline bars pinned to an absolute 0..1 domain.
ui.chart(.{ .width = 239, .height = 32, .y_min = 0, .y_max = 1 }, &.{
    .{ .kind = .bar, .values = model.cpuHistory(), .color = .accent },
})
```

- Kinds: `.line` (polyline; `fill = true` adds a translucent area to the baseline; one sample draws a dot), `.bar` (one bar per value, ALWAYS anchored at zero — the auto domain forces 0 in, negatives hang below; a zero value draws nothing), `.band` (min/max envelope: `values` upper, `low` lower).
- Data: `values: []const f32` at uniform x steps, oldest first. `NaN` = missing sample, draws a gap — pad a filling ring with leading `NaN` so the trace enters from the right (see examples/system-monitor).
- Domain: derived per side from the data unless `y_min`/`y_max` pin it; a flat series expands symmetrically. `grid_lines = N` draws N horizontal token hairlines (opt-in, none by default); `baseline = true` marks the zero line.
- Colors are token refs (`.accent`, `.info`, `.success`, `.warning`, `.destructive`, ...) — never raw colors — so both themes hold up.
- Downsampling: past 256 points per series, deterministic index-bucket min/max decimation (spikes survive; same series → same pixels, golden-testable). The generated semantics summary still describes the SOURCE series.
- Semantics: role `chart`; label = a generated summary (`"chart: stars 10000 pts last 9999.00"`) unless `semantics.label` is set; accessibility value = the first series' latest point — assert live data from snapshots without pixels.
- Display-only: never a hit target; clicks fall through to the nearest pressable ancestor, so charts inside pressable rows keep the row clickable. Axis labels are composition — put `text` widgets around the plot; the chart draws no text.

## Rich text: inline spans and markdown (Zig views)

Mixed-style text inside ONE wrapped paragraph is a Zig-builder feature (markup exposure is planned; the grammar is currently frozen):

```zig
const spans = [_]canvas.TextSpan{
    .{ .text = "Ship the " },
    .{ .text = "bold", .weight = .bold },
    .{ .text = " parts, run " },
    .{ .text = "zig build test", .monospace = true },
    .{ .text = ", then read " },
    .{ .text = "the guide", .link = "https://example.com/guide" },
};
ui.paragraph(.{ .on_link = Ui.linkMsg(.open_url) }, &spans)
```

- Each span carries `weight` (regular/medium/bold), `italic`, `monospace`, `color` (a `ColorTokens` field name), `underline`, `strikethrough`, `scale` (size multiplier vs the body token — how headings work), and `link`.
- Wrapping is span-aware and measured with the same provider the platform draws with; a paragraph reserves its real wrapped height when stacked in a column.
- Link spans are hit-testable: they appear in automation snapshots as `role=link` named by their visible text, show a pointer cursor, and pressing one dispatches `on_link(span.link)` — declare `open_url: []const u8` in `Msg` and pair with `Ui.linkMsg(.open_url)`.
- Capacities: `canvas.max_text_spans_per_paragraph` (32) spans per paragraph; overflow truncates deterministically.

Markdown (GitHub-flavored subset) maps onto the same widgets. In markup use the `<markdown>` element above; from a Zig view call it directly:

```zig
const Md = native_sdk.markdown.Markdown(Msg);
// inside view():
Md.view(ui, model.body_markdown, .{
    .on_link = Ui.linkMsg(.open_url),
    .on_details = Md.detailsMsg(.toggle_details),   // Msg{ .toggle_details = usize }
    .details_expanded = &model.details_expanded,     // caller-owned [N]bool
})
```

- Supported: `#`–`###` headings, paragraphs with `**bold**`/`*italic*`/`` `code` ``/`~~strike~~`/`[links](url)`, bare `http(s)://` URLs (autolink, trailing punctuation trimmed), `#123` issue refs (opt-in: set `Options.issue_link_base` and the ref links to base ++ number), bullet + ordered + task lists (task checkboxes are display-only, disabled), fenced code blocks, `> blockquotes`, `---` rules, GFM pipe tables (header bold, `:---`/`:--:`/`---:` column alignment, inline spans + clickable links inside cells, `\|` escapes a pipe in a cell; columns share width equally, and a missing/mismatched delimiter row degrades the block to paragraphs), `<details><summary>`.
- Not in v1 (degrades to plain text, never fails): reference links, raw HTML, footnotes, backslash escapes (except `\|` in table rows).
- `<details>` state is elm-style: the CALLER owns the expanded flags. Keep a bounded `details_expanded: [8]bool` in the model, toggle it in `update` on the details message, and pass the slice back in.

## Validate without building

`native markup check src/view.zml` — instant grammar/structure validation with `file:line:column` errors, including the font-coverage tofu guard: literal text with a codepoint outside the bundled face (⌘, ✓, ⑂, dingbats, CJK) is a teaching error naming the character, because it renders as a tofu box on the reference/screenshot and mobile paths — use a vector icon (`icon=` / `<icon name>`) or plain words. Dynamic strings get the same lesson as a Debug-build `zero_canvas_ui` diagnostic when the view builds. Binding paths and message tags are checked against your actual Model/Msg when the app builds (and on hot reload).

## Testing pattern

Unit tests exercise the real dispatch path — no GUI needed:

```zig
var view = try canvas.MarkupView(Model, Msg).init(arena, main.habits_markup);
var ui = canvas.Ui(Msg).init(arena);
const tree = try ui.finalize(try view.build(&ui, &model));
const button = findByText(tree.root, .button, "Done today").?;   // walk tree.root
main.update(&model, tree.msgForPointer(button.id, .up).?);        // dispatch exactly like the runtime
// rebuild and assert: text updated, widget ids stable
```

Two `msgForPointer` traps: a **disabled** control yields `null` (assert `== null` rather than unwrapping when testing disabled states), and the tree is a snapshot — after each dispatch, rebuild the view before pressing anything again.

`msgForPointer` has a sibling for every handler channel — use the one matching the interaction under test, all on the finalized `Tree`: `msgForKeyboard(id, keyboard_event)` (activation keys, slider steps, enter-to-submit, text edits), `msgForResize(id, fraction)` (the split-divider round-trip: dispatch the fraction, assert the model stored it, rebuild, assert the `value` echo), `msgForDismiss(id)` (an anchored surface's `on-dismiss`), `msgForHold(id)` (`on-hold`), `msgForTextEdit(id, edit)` / `msgForValue(id, value)` (text entry, sliders), `msgForScroll(id, state)`, and `msgForContextMenu(id, item_index)`. For tree keyboard NAVIGATION there is nothing app-side to unit test: Up/Down/Left/Right/Home/End run engine-side over `role="treeitem"` rows and dispatch the landed row's `on-press`/`on-toggle` — assert those Msgs (via `msgForPointer`/`msgFor(id, .toggle)`) and the model transitions; the keymap itself is runtime behavior (drive it live with `native automate widget-key`).

Runtime-integration tests use `native_sdk.TestHarness()` on the null platform; heap-allocate both the harness and the app struct (they are multi-megabyte; stack allocation crashes).

## Verify live through the automation harness

```bash
zig build -Dplatform=macos -Dweb-engine=system -Dautomation=true
./zig-out/bin/<app> &   # run from the example directory
native automate wait                     # blocks until ready=true
cat .zig-cache/native-sdk-automation/snapshot.txt   # widgets with ids, roles, names, bounds, state
native automate widget-click <canvas-label> <id>   # id is the bare number (snapshot prints #id)
native automate widget-hold <canvas-label> <id>    # press-and-hold: drives on_hold via the real timer path
native automate widget-context-press <canvas-label> <id>   # right-click: context menu, or on_hold when none
```

Snapshots expose the same structural widget ids your tests see, so live assertions are greps: click by id, re-read the snapshot, and check names/values/counts changed. Widget ids are stable across rebuilds, reorders, and hot reloads — asserting an id stayed constant while its bounds or state changed is the standard way to prove keyed identity.

For scripted checks (and the CI workflow `native init` scaffolds), replace grep-and-sleep with `native automate assert`: each argument is a regex that must match the snapshot, polled up to `--timeout-ms` (default 30000), with `--absent` inverting the check. Failure names the missing patterns and prints the snapshot tail.

```bash
native automate assert 'gpu_nonblank=true' 'role=button name="Reset"' 'count: 0'
native automate assert --absent 'error event='
```
