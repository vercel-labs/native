---
name: native-ui
description: Authoring guide for native-rendered zero-native apps - declarative .zml markup views plus Zig logic on the UiApp loop. Use when building or modifying native UI (widgets, layout, bindings, messages), writing .zml files, wiring Model/Msg/update, testing markup views, or verifying a native app through the automation harness.
---

# Author native UI with markup + Zig

A native-rendered zero-native app is a markup view plus Zig logic:

- `src/<view>.zml` — the entire UI: elements, layout, bindings, message dispatch.
- `src/main.zig` — `Model` (plain struct), `Msg` (tagged union), `update(model, msg)`, and a `main` that hands them to `zero_native.UiApp(Model, Msg)`.

The markup compiles to the same widget tree a hand-written `canvas.Ui(Msg)` builder view would produce: identical structural widget ids, identical typed handler table. Markup can never mutate state — it binds values and dispatches messages; all logic lives in Zig.

Start a new app by copying `examples/habits/` (smallest) or `examples/ui-inbox/`: change `app_exe_name` in build.zig, the name/id in app.zon, and put `0x0` as the fingerprint in build.zig.zon — the first build error prints the correct value to paste in. `src/runner.zig` and `assets/` copy verbatim.

## App wiring

```zig
const HabitsApp = zero_native.UiApp(Model, Msg);

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(HabitsApp); // multi-MB struct: never on the stack
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = HabitsApp.init(std.heap.page_allocator, initialModel(), .{
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
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{ ... }, init);
}
```

The runtime owns the loop: install on first GPU frame, presentation, resize, pointer/keyboard dispatch into `update` + rebuild. With `watch_path` set, editing the `.zml` while the app runs hot-reloads the view within ~2s, preserving model state and widget ids; parse failures keep the last good view and set `app_state.markup_diagnostic` (line/column/message).

## Elements

| Markup | Widget | Notes |
| --- | --- | --- |
| `row`, `column` | flex containers | main axis horizontal / vertical |
| `stack`, `panel`, `card` | overlay containers | children stack on top of each other |
| `scroll` | scroll_view | wrap multiple children in a `column` inside it |
| `list`, `grid` | list, grid | vertical stack / cell grid |
| `text`, `badge` | text leaves | text content, `{}` interpolation allowed |
| `button`, `list-item`, `menu-item`, `toggle` | text-bearing controls | label is the text content |
| `checkbox`, `radio`, `slider`, `progress` | value controls | `checked`, `value` |
| `text-field`, `search-field`, `textarea` | text entry | `placeholder`; edits via `on-input` |
| `status-bar` | status bar | text leaf: content only, no children |
| `separator`, `spacer` | separator, flexible space | give `spacer` a `grow` |

## Attributes

Layout: `gap`, `padding` (uniform), `grow`, `width`, `height`, `main` (start|center|end|space_between), `cross` (stretch|start|center|end), `virtualized`, `virtual-item-extent`.
Appearance/state: `variant` (default|primary|secondary|outline|ghost|destructive), `size` (default|sm|lg|icon), `disabled`, `checked`, `selected`, `value`, `placeholder`.
Semantics: `role` (listitem, button, ...), `label` (accessible name).
Identity: `key` (sibling-scoped), `global-key` (parent-independent — use for items that move between containers, e.g. board cards; ids then survive reparenting).

Numbers are plain (`gap="12"`), booleans are `true`/`false` or a binding.

## Expressions — the complete list

Attribute values take a literal or exactly ONE expression; there are only three forms:

1. `{path.to.value}` — a binding
2. `{a == b}` — equality (the only comparison; for `selected` states)
3. on `on-*` attributes: `msg` or `msg:{path}` — message tag plus optional payload binding

Text content (in text-bearing elements) additionally supports interpolation: `{open_count} open · {done_count} done`.

There is NO `!=`, `<`, `>`, arithmetic, function calls with arguments, or ternaries — by design. Any derived value or condition beyond these is a Zig model function you bind to (`{doneEmpty}`, `each="visible"`).

## Binding resolution rules

A path like `{h.streak}` resolves left to right, starting from the model or a `for` variable:

- struct fields bind directly: `{habit_count}`, `{h.done}`
- zero-arg pub methods bind like fields: `{totalDays}` calls `pub fn totalDays(m: *const Model) usize`
- enums resolve to their tag name — so `{f}` renders "active", `{f == filter}` compares tags, and `set_filter:{f}` coerces the tag back into an enum payload
- `for each="name"` resolves, in order: a Model field that is a slice/array, a pub array/slice decl (`pub const filters = [_]Filter{...}`), a pub fn `(*const Model) []const T`, or a pub fn `(*const Model, std.mem.Allocator) []const T` — the allocator variant is how filtered/derived lists work (allocate from the passed arena)
- item methods work too: `{h.name}` may be a field or `pub fn name(h: *const Habit) []const u8`

Bindings are zero-argument. A parameterized query (cards of column X) becomes one model function per case.

## Messages

`on-press`, `on-toggle`, `on-change`, `on-submit` (enter in a text field) take `tag` or `tag:{payload}`. The tag must be a variant of your `Msg` union; payload bindings coerce to the variant's payload type: integers, floats, enums (from tag names), `[]const u8`, bool. `on-input` is special: name a `Msg` variant whose payload is `canvas.TextInputEvent` and the runtime delivers each text edit in it.

## Structure tags

```html
<for each="visible" key="id" as="t"> <row>...</row> </for>   <!-- exactly one element child; key names an item field -->
<if test="{c.movable}"> <button ...>Move</button> </if>
<else> <text>Done!</text> </else>                             <!-- must directly follow the if -->
```

## Validate without building

`zero-native markup check src/view.zml` — instant grammar/structure validation with `file:line:column` errors. Binding paths and message tags are checked against your actual Model/Msg when the app builds (and on hot reload).

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

Runtime-integration tests use `zero_native.TestHarness()` on the null platform; heap-allocate both the harness and the app struct (they are multi-megabyte; stack allocation crashes).

## Verify live through the automation harness

```bash
zig build -Dplatform=macos -Dweb-engine=system -Dautomation=true
./zig-out/bin/<app> &   # run from the example directory
zero-native automate wait                     # blocks until ready=true
cat .zig-cache/zero-native-automation/snapshot.txt   # widgets with ids, roles, names, bounds, state
zero-native automate widget-click <canvas-label> <id>   # id is the bare number (snapshot prints #id)
```

Snapshots expose the same structural widget ids your tests see, so live assertions are greps: click by id, re-read the snapshot, and check names/values/counts changed. Widget ids are stable across rebuilds, reorders, and hot reloads — asserting an id stayed constant while its bounds or state changed is the standard way to prove keyed identity.
