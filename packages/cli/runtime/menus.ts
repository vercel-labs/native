// Menus: the window's menu bar and the context menus a page declares, in HTML's own menu markup.
// A <menu type="application"> is the bar, a <menu type="context"> a context menu the contextmenu
// attribute puts on an element, and either one holds <menuitem>s (with their own label, accesskey
// and command attributes), <hr> separators and nested <menu label="…"> submenus. The menus are not
// drawn by the page: the host builds them natively from the spec this module writes, and the line
// index of the item chosen comes back here, where clicking its element runs what it says.
//
//   <menu type="application">
//     <menuitem label="New Window" accesskey="N" onclick="openNew()"></menuitem>
//     <hr>
//     <menu label="Edit">
//       <menuitem command="--copy"></menuitem>
//       <menuitem command="--paste" accesskey="Shift+V"></menuitem>
//     </menu>
//   </menu>

import { Element, Node, document } from "./dom.ts";
import { KEY_DELETE, hostAppAction, hostMenuPopup, hostMenuSet, hostWindowMinimize, hostWindowZoom } from "./host.ts";
import { runEditCommand } from "./editing.ts";
import { setRunCommandHook } from "./command-hook.ts";
import { keyDown } from "./app/keyboard.ts";
import { requestQuit, window } from "./window.ts";

/** One line of a menu: a menuitem, a separator, or a submenu's own title. */
interface MenuLine {
  /** The element the line came from; null for a separator, which is nothing to click. */
  el: Element | null;
  label: string;
  /** The accesskey attribute: the shortcut the platform adds its primary modifier to. */
  keys: string;
  disabled: boolean;
  depth: number;
}

/** A built-in command of the menu markup, in the invoker commands' `--` spelling. */
const BUILT_IN_COMMANDS = [
  "--cut", "--copy", "--paste", "--delete", "--select-all", "--undo", "--redo",
  "--close", "--minimize", "--zoom", "--toggle-fullscreen",
  "--hide", "--hide-others", "--show-all", "--quit",
];

/** A menu as the host built it, with the element each line came from. */
class MenuModel {
  readonly lines: MenuLine[] = [];
  readonly spec: string;

  /** `application` reads a menu bar — its items at the top join the app's own menu, and each
   *  `<menu label>` is a menu of the bar — where any other menu's items are its own. */
  constructor(menu: Element, application: boolean) {
    if (application) readApplicationMenu(menu, this.lines);
    else readMenu(menu, 0, this.lines);
    this.spec = menuSpec(this.lines);
  }
}

/**
 * The window's menu bar. A `<menu label="…">` at the top is a menu of the bar; the `<menuitem>`s
 * and `<hr>`s at the top are items of the app's own menu, after the automatic About and Hide and
 * before its Quit. The host builds the app menu from a line with no label.
 */
function readApplicationMenu(menu: Element, out: MenuLine[]): void {
  const own: Element[] = [];
  const menus: Element[] = [];
  for (const child of menu.children) {
    if (child.localName === "menu") menus.push(child);
    else if (child.localName === "menuitem" || child.localName === "hr") own.push(child);
  }
  if (own.length > 0) {
    out.push({ el: null, label: "", keys: "", disabled: false, depth: 0 });
    readItems(own, 1, out);
  }
  for (const submenu of menus) {
    out.push({
      el: submenu,
      label: submenu.getAttribute("label") ?? "",
      keys: "",
      disabled: false,
      depth: 0,
    });
    readMenu(submenu, 1, out);
  }
}

function readMenu(menu: Element, depth: number, out: MenuLine[]): void {
  for (const child of menu.children) {
    if (child.localName === "menu") {
      // A submenu: its title is the line here, its items are the lines inside it.
      out.push({
        el: child,
        label: child.getAttribute("label") ?? "",
        keys: "",
        disabled: false,
        depth: depth,
      });
      readMenu(child, depth + 1, out);
    } else if (child.localName === "menuitem" || child.localName === "hr") {
      readItems([child], depth, out);
    }
  }
}

/** The lines for items — menuitems and separators — at one depth. */
function readItems(items: Element[], depth: number, out: MenuLine[]): void {
  for (const child of items) {
    if (child.localName === "hr") {
      out.push({ el: null, label: "-", keys: "", disabled: false, depth: depth });
      continue;
    }
    out.push({
      el: child,
      label: menuItemLabel(child),
      keys: child.getAttribute("accesskey") ?? "",
      disabled: child.hasAttribute("disabled"),
      depth: depth,
    });
  }
}

/** The standard label of each built-in command, for an item that gives none. */
const COMMAND_LABELS: { command: string; label: string }[] = [
  { command: "--cut", label: "Cut" },
  { command: "--copy", label: "Copy" },
  { command: "--paste", label: "Paste" },
  { command: "--delete", label: "Delete" },
  { command: "--select-all", label: "Select All" },
  { command: "--undo", label: "Undo" },
  { command: "--redo", label: "Redo" },
  { command: "--close", label: "Close Window" },
  { command: "--minimize", label: "Minimize" },
  { command: "--zoom", label: "Zoom" },
  { command: "--toggle-fullscreen", label: "Toggle Full Screen" },
  { command: "--hide", label: "Hide" },
  { command: "--hide-others", label: "Hide Others" },
  { command: "--show-all", label: "Show All" },
  { command: "--quit", label: "Quit" },
];

/** What a menuitem reads: its label attribute, else its text, else the command's standard label. */
function menuItemLabel(el: Element): string {
  const label = el.getAttribute("label");
  if (label !== null && label !== "") return label;
  const text = (el.textContent ?? "").trim();
  if (text !== "") return text;
  const command = el.getAttribute("command") ?? "";
  for (const entry of COMMAND_LABELS) if (entry.command === command) return entry.label;
  return "";
}

/** The spec text the host builds its menus from: one line per item, two spaces per level. */
function menuSpec(lines: MenuLine[]): string {
  const out: string[] = [];
  for (const line of lines) {
    let indent = "";
    for (let i = 0; i < line.depth; i++) indent += "  ";
    const label = line.label.replace(/[\t\n\r]/g, " ");
    out.push(indent + label + "\t" + line.keys + "\t" + (line.disabled ? "1" : "0"));
  }
  return out.join("\n");
}

/** The bar the page declares, with the elements its lines came from. */
let application: MenuModel | null = null;

/**
 * Builds the window's menu bar from the page's first `<menu type="application">`, once its markup
 * is in place. A page with no such menu keeps the app's own (About, Hide and Quit).
 */
export function installApplicationMenu(): void {
  const menu = document.querySelector('menu[type="application"]');
  application = menu instanceof Element ? new MenuModel(menu, true) : null;
  hostMenuSet(application === null ? "" : application.spec);
}

/** The application menu item the host reports as chosen (EV_MENU): a click on its element. */
export function applicationMenuItemChosen(index: number): void {
  if (application !== null) activate(application, index);
}

/** Runs an application menu item by its line index, as choosing it from the bar does. */
export function chooseApplicationMenuItem(index: number): void {
  applicationMenuItemChosen(index);
}

/**
 * The line index of the application menu item a path names — "Edit/Copy" walks into the Edit menu
 * for the item labeled Copy — or -1 when no item answers to it. A path is for driving a menu
 * without the native bar (a headless run's step); a page picks items with clicks.
 */
export function applicationMenuItemIndex(path: string): number {
  if (application === null || path === "") return -1;
  const parts = path.split("/");
  let from = 0;
  let index = -1;
  for (let depth = 0; depth < parts.length; depth++) {
    const found = lineNamed(application.lines, from, depth, parts[depth]);
    if (found < 0) return -1;
    index = found;
    from = found + 1;
  }
  return index;
}

/** The line at `depth` after `from` whose label is `label`, before the next shallower one. */
function lineNamed(lines: MenuLine[], from: number, depth: number, label: string): number {
  for (let i = from; i < lines.length; i++) {
    const line = lines[i];
    if (line.depth < depth) return -1;
    if (line.depth === depth && line.label === label) return i;
  }
  return -1;
}

/** Clicks the element a menu line came from, as choosing the item does. */
function activate(model: MenuModel, index: number): void {
  if (index < 0 || index >= model.lines.length) return;
  const line = model.lines[index];
  if (line.el === null || line.disabled) return;
  line.el.click();
}

/**
 * Shows the context menu the nearest `contextmenu` attribute above `target` names, at a point in
 * the window, and runs the item chosen. A press on an element with no such menu, or one the page
 * cancelled, shows nothing.
 */
export function showContextMenu(target: Node | null, x: number, y: number): void {
  let owner: Element | null = null;
  for (let n: Node | null = target; n !== null; n = n.parentNode) {
    if (n instanceof Element && n.hasAttribute("contextmenu")) {
      owner = n;
      break;
    }
  }
  if (owner === null) return;
  const id = owner.getAttribute("contextmenu") ?? "";
  if (id === "") return;
  const menu = document.getElementById(id);
  if (!(menu instanceof Element) || menu.localName !== "menu") return;
  const model = new MenuModel(menu, false);
  const index = hostMenuPopup(model.spec, x, y);
  if (index >= 0) activate(model, index);
}

/** Whether a menu item's command is one the platform itself knows. */
function isBuiltIn(command: string): boolean {
  return BUILT_IN_COMMANDS.indexOf(command) >= 0;
}

/**
 * Runs a menu item's command, after its `command` event: the editing commands act on the focused
 * field through the same code the keys use, the window commands on the window, and the app's on the
 * app. A command the platform doesn't know is the page's own: its `command` listener has it.
 */
export function runMenuCommand(command: string): void {
  if (!isBuiltIn(command)) return;
  // The editing commands are the ones document.execCommand() runs, so a menu item does exactly
  // what the same command from the page does, clipboard events included.
  if (command === "--copy") {
    runEditCommand("copy", "");
  } else if (command === "--cut") {
    runEditCommand("cut", "");
  } else if (command === "--paste") {
    runEditCommand("paste", "");
  } else if (command === "--delete") {
    keyDown(KEY_DELETE, 0, "");
  } else if (command === "--select-all") {
    runEditCommand("selectall", "");
  } else if (command === "--close") {
    window.close();
  } else if (command === "--minimize") {
    hostWindowMinimize();
  } else if (command === "--zoom") {
    hostWindowZoom();
  } else if (command === "--toggle-fullscreen") {
    if (document.fullscreenElement === null) document.documentElement.requestFullscreen();
    else document.exitFullscreen();
  } else if (command === "--hide") {
    hostAppAction("hide");
  } else if (command === "--hide-others") {
    hostAppAction("hide-others");
  } else if (command === "--show-all") {
    hostAppAction("show-all");
  } else if (command === "--quit") {
    requestQuit();
  }
  // --undo and --redo have no editing history to walk yet: their event reaches the page, which is
  // where a page's own history would live.
}

// The DOM runs a menuitem's command as the click's default action; the commands themselves are
// this module's, so the DOM reaches them through the hook.
setRunCommandHook(runMenuCommand);
