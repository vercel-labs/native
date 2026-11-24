# Windows, menus and the app's life

An app's page is the app. The first window opens the page in `index.html`; every other window runs
the same page at an address of its own — a fragment or a query on it — so `location.hash`,
`location.search` and `window.name` tell a window which view it is showing. A window is a process,
so a window's heap is its own; what has to be shared goes through `localStorage`.

## Windows

A link with a target opens another window. The target names it, and a link to the same name reuses
the window it is already open in:

```html
<a href="#/settings" target="settings">Settings…</a>
<a href="#/about" target="_blank">About</a>
<a href="#/doc/7">Document 7</a>
```

`_blank` always opens a new window, and a link with no target (or `_self`) changes this page's
address. `window.open()` does the same from script, with the window's features:

```ts
const settings = window.open("#/settings", "settings", "width=420,height=300,left=120,top=80");
settings?.postMessage({ theme: "dark" }, "*");
settings?.focus();
```

`window.open()` returns a handle to the window, or null when no window could be opened. A handle is
a `WindowProxy`, which reaches the window itself and not its document: `closed`, `name`, `close()`,
`focus()`, `blur()` and `postMessage()`. The features are a browser's: `width`, `height`, `left`
and `top`, separated by commas or spaces; an unknown feature is ignored.

The window a page opened is there through `window.opener`, as the same kind of handle:

```ts
// In the window that was opened:
window.name;                        // "settings", from the target or window.open()'s name
window.opener?.postMessage("saved", "*");
window.addEventListener("message", (event) => {
  if (!(event instanceof MessageEvent)) return;
  if (event.data === "save") save();
});
```

A `message` event is a `MessageEvent`: `data` is the message as it was sent, `source` the handle of
the window that sent it, and `origin` is `"null"`, the app's opaque origin. The data crosses as
JSON — objects, arrays, strings, numbers, booleans and null — so a function or a live DOM node can't
travel with it. A handle reaches the windows the page opened and the window that opened it; there is
no other path between windows.

A window's own members are the browser's:

```ts
document.title = "Settings";        // the window's title
window.name;                        // the browsing context's name
window.close();                     // beforeunload may cancel it; the last window ends the app
window.closed;                      // false while the page runs
window.resizeTo(500, 400);
window.moveTo(120, 80);
window.screenX; window.screenY;     // where the window is on screen
window.outerWidth; window.outerHeight;
```

`window.close()` runs the page's `beforeunload` listeners first, and one that calls
`preventDefault()` keeps the window open; then `pagehide` fires and the window goes. The window's
own close button asks the same way. Closing a window closes the windows it opened (a window closed
that way doesn't get to ask its page first), and the app ends when its last window closes.

## The window's life

The events are the ones a page already knows:

- **`focus` and `blur`** on the window, as it becomes and stops being the key window.
- **`visibilitychange`** on the document, when the window is minimized or comes back;
  `document.hidden` and `document.visibilityState` say which.
- **`beforeunload`** on the window, cancelable, before the window closes or the app quits.
- **`pagehide`** on the window, once it is going away.
- **`resize`** and **`move`** on the window, when it is resized or moved.
- **`fullscreenchange`** on the document, with `document.fullscreenElement` naming the element
  that asked for fullscreen.

Cmd+Q is the app menu's Quit item: it runs the window's `beforeunload` and `pagehide`, then closes
the window and the windows it opened, and the app ends when its last window closes.

## The menu bar

A `<menu type="application">` in the page is the window's menu bar. It is not drawn by the page —
the app builds a native menu from it — so it takes no room:

```html
<menu type="application">
  <menuitem label="New Window" accesskey="N" onclick="openNew()"></menuitem>
  <menuitem label="Open Recent" disabled></menuitem>
  <hr>
  <menu label="Edit">
    <menuitem command="--undo"></menuitem>
    <menuitem command="--redo"></menuitem>
    <hr>
    <menuitem command="--cut"></menuitem>
    <menuitem command="--copy"></menuitem>
    <menuitem command="--paste"></menuitem>
    <menuitem command="--delete"></menuitem>
    <menuitem command="--select-all"></menuitem>
  </menu>
  <menu label="View">
    <menuitem command="--toggle-fullscreen"></menuitem>
  </menu>
  <menu label="Window">
    <menuitem command="--minimize"></menuitem>
    <menuitem command="--zoom"></menuitem>
    <menuitem command="--close"></menuitem>
  </menu>
</menu>
```

- A top-level `<menu label="…">` is a menu of the bar, and its `<menuitem>`s and `<hr>`s are its
  items. A `<menuitem>` or `<hr>` directly in the application menu is an item of the app's own
  menu, which macOS already fills with About and Hide: the page's items come after those and before
  Quit. Any `menuitem` inside a `<menu>` is an item of that menu.
- **`label`** is what the item reads; without one it reads its text, and an item with only a
  `command` reads the command's standard label (Copy, Select All, …).
- **`accesskey`** is its shortcut. The platform adds its primary modifier — Cmd on macOS — and the
  modifiers the attribute spells out, in any order: `accesskey="N"` is ⌘N,
  `accesskey="Shift+N"` is ⌘⇧N, and `accesskey="Alt+Shift+K"` is ⌘⌥⇧K.
- **`disabled`** greys the item out; choosing it does nothing.
- **`onclick`** runs when the item is chosen, like any element's click.
- **`command`** names an invoker command. Choosing the item fires a `command` event at the
  `menuitem` — a bubbling `CommandEvent` with `command` and `source` — and the platform runs the
  commands it knows:

  | command | what it does |
  | --- | --- |
  | `--cut`, `--copy`, `--paste`, `--delete`, `--select-all` | acts on the focused field |
  | `--undo`, `--redo` | fires the event; the runtime keeps no editing history yet |
  | `--close` | closes the window, `beforeunload` first |
  | `--minimize`, `--zoom` | minimizes the window, or zooms it |
  | `--toggle-fullscreen` | enters or leaves fullscreen |
  | `--hide`, `--hide-others`, `--show-all` | hides the app, hides the others, shows them all |
  | `--quit` | quits the app, `beforeunload` first |

  A command of the page's own — anything else — is the page's: listen for `command` on the
  document (or the menu) and do the work.

macOS puts the app's own menu in front of the bar — About, Hide, Hide Others, Show All and Quit ⌘Q
— so a page doesn't declare it; the items a page puts at the top of the application menu join it. The menu is read when the page loads; changing the markup later
doesn't rebuild it yet.

## Context menus

A `contextmenu` attribute names the menu a right-click shows:

```html
<article id="row" contextmenu="row-menu">…</article>

<menu type="context" id="row-menu">
  <menuitem command="--copy"></menuitem>
  <hr>
  <menuitem label="Remove" onclick="removeRow()"></menuitem>
</menu>
```

The nearest element with the attribute above the press names the menu, as HTML's own `contextmenu`
attribute had it, and `menu[type="context"]` is not drawn either. A right-click fires a cancelable
`contextmenu` event first: `preventDefault()` on it keeps the menu from showing, as when a page draws
a menu of its own.

The items of a context menu are the same `menuitem`s, with the same attributes and commands.
