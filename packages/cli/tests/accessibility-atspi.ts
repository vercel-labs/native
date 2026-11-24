// The tree on Linux's accessibility bus: a real AT-SPI client — the library screen readers such as
// Orca use — walks the app built here, reads its roles, names, states, text and table, presses a
// button, moves a caret, focuses a field, and hears the live region and the value change. The app
// runs under a private session bus, so nothing touches the desktop's own.
//   npm test
//
// It skips cleanly on macOS (whose tree is checked by tests/accessibility.ts and
// tests/accessibility-ax.ts) and where a session bus or at-spi's client library is missing.

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

if (process.platform !== "linux") {
  console.log(`ok   skipped: AT-SPI is Linux's accessibility bus (this is ${process.platform})`);
  process.exit(0);
}
const tools = spawnSync("sh", ["-c", "command -v dbus-run-session && python3 -c 'import gi; gi.require_version(\"Atspi\", \"2.0\"); from gi.repository import Atspi'"]);
if (tools.status !== 0) {
  console.log("ok   skipped: needs dbus-run-session and at-spi's python client (at-spi2-core, python3-gi)");
  process.exit(0);
}

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><title>Shop</title><meta name="native-window" content="width=400, height=300"></head><body>
<h1 id="h">Shop</h1>
<p>Hello <b>world</b></p>
<button id="b">Buy</button>
<a href="#x">A link</a>
<nav aria-label="Links"><a href="#y">Nav link</a></nav>
<input id="i" type="text" aria-label="Search" value="bees">
<input id="c" type="checkbox" checked aria-label="Agree">
<input id="vol" type="range" aria-label="Volume" value="25" min="0" max="100">
<div aria-hidden="true"><button>hidden</button></div>
<h2>More</h2>
<table><tr><th>Item</th><th>Price</th></tr><tr><td>Tea</td><td>3</td></tr></table>
<ul id="list"><li>One</li></ul>
<button id="add">Add</button>
<p id="live" aria-live="polite">Ready</p>
<button id="go">Refresh</button>
<input id="val" value="one" aria-label="Amount">
<script>
document.getElementById("b").addEventListener("click", function () {
  document.getElementById("h").textContent = "Bought";
});
document.getElementById("go").addEventListener("click", function () {
  document.getElementById("live").textContent = "Updated";
  document.getElementById("val").value = "two";
});
document.getElementById("add").addEventListener("click", function () {
  var item = document.createElement("li");
  item.textContent = "Two";
  document.getElementById("list").appendChild(item);
});
// What a client's edit of the search field makes the page hear.
var typed = "";
var search = document.getElementById("i");
search.addEventListener("input", function () {
  typed += "input ";
  document.getElementById("live").textContent = typed;
});
search.addEventListener("change", function () {
  typed += "change ";
  document.getElementById("live").textContent = typed;
});
</script>
</body></html>`;

// The client the test drives the app with, through at-spi's own library.
const PROBE = String.raw`
import json, time
import gi
gi.require_version("Atspi", "2.0")
gi.require_version("Gio", "2.0")
from gi.repository import Atspi, GLib, Gio

STATES = ("focused", "focusable", "enabled", "editable", "checked", "visible", "showing", "sensitive", "selectable")
results = {}
events = []

def pump(seconds):
    context = GLib.MainContext.default()
    end = time.time() + seconds
    while time.time() < end:
        while context.iteration(False):
            pass
        time.sleep(0.01)

def state_names(node):
    states = node.get_state_set()
    return [name for name in STATES if states.contains(getattr(Atspi.StateType, name.upper()))]

def interfaces_of(node):
    return [name.split(".")[-1] for name in (node.get_interfaces() or [])]

def walk(node):
    out = []
    for index in range(node.get_child_count()):
        child = node.get_child_at_index(index)
        out.append({"role": child.get_role_name(), "name": child.get_name(),
                    "states": state_names(child), "interfaces": interfaces_of(child)})
        out.extend(walk(child))
    return out

def find(node, role, name):
    for index in range(node.get_child_count()):
        child = node.get_child_at_index(index)
        if child.get_role_name() == role and child.get_name() == name:
            return child
        found = find(child, role, name)
        if found is not None:
            return found
    return None

def named(node, name):
    for index in range(node.get_child_count()):
        child = node.get_child_at_index(index)
        if child.get_name() == name:
            return child
        found = named(child, name)
        if found is not None:
            return found
    return None

def named_contains(node, text):
    for index in range(node.get_child_count()):
        child = node.get_child_at_index(index)
        if text in (child.get_name() or ""):
            return child
        found = named_contains(child, text)
        if found is not None:
            return found
    return None

def app_named(name):
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        candidate = desktop.get_child_at_index(index)
        if candidate.get_name() == name:
            return candidate
    return None

def wait_for(probe, seconds=4.0):
    end = time.time() + seconds
    while time.time() < end:
        value = probe()
        if value:
            return value
        pump(0.05)
    return probe()

def attributes(node):
    try:
        found = node.get_attributes()
        return dict(found) if found is not None else {}
    except Exception:
        return {}

def a11y_connection():
    """A raw connection to the accessibility bus, so the first call that walks the page is
    observable before at-spi's client wraps anything."""
    session = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    address = session.call_sync("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress",
                                None, None, Gio.DBusCallFlags.NONE, 2000, None).unpack()[0]
    return Gio.DBusConnection.new_for_address_sync(
        address,
        Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
        None, None)

def raw_app(bus, name):
    """The application object's reference, found through the registry. Asking its name is a read
    the page doesn't need, so nothing is built yet."""
    desktop = bus.call_sync("org.a11y.atspi.Registry", "/org/a11y/atspi/accessible/root",
                            "org.a11y.atspi.Accessible", "GetChildren", None, None,
                            Gio.DBusCallFlags.NONE, 4000, None).unpack()[0]
    for child_bus, child_path in desktop:
        reply = bus.call_sync(child_bus, child_path, "org.freedesktop.DBus.Properties", "Get",
                              GLib.Variant("(ss)", ("org.a11y.atspi.Accessible", "Name")),
                              None, Gio.DBusCallFlags.NONE, 2000, None)
        if reply.unpack()[0] == name:
            return (child_bus, child_path)
    return None

def raw_children(bus, ref):
    """The application's children, asked of it directly: the first such call starts the build."""
    try:
        reply = bus.call_sync(ref[0], ref[1], "org.a11y.atspi.Accessible", "GetChildren",
                              None, None, Gio.DBusCallFlags.NONE, 4000, None)
        return list(reply.unpack()[0])
    except Exception:
        return []

def main():
    children_changes = []
    watcher = Atspi.EventListener.new(lambda event: children_changes.append(event.type))
    watcher.register("object:children-changed")
    bus = a11y_connection()
    ref = wait_for(lambda: raw_app(bus, "Shop"), 8)
    results["app"] = ref is not None
    if ref is None:
        print(json.dumps(results))
        return
    # The tree costs nothing until a client asks: this first request for the application's
    # children comes back with none, and the page then arrives as children-changed.
    results["lazy_empty"] = len(raw_children(bus, ref)) == 0
    results["lazy_arrived"] = bool(wait_for(lambda: len(raw_children(bus, ref)) > 0, 6))
    pump(0.4)
    results["children_changed"] = any("children-changed" in name for name in children_changes)
    app = wait_for(lambda: app_named("Shop"), 4)
    if app is None:
        print(json.dumps(results))
        return
    results["tree"] = walk(app)

    button = find(app, "button", "Buy")
    if button is not None:
        results["action"] = Atspi.Action.get_action_name(button, 0)
        results["actions"] = Atspi.Action.get_n_actions(button)
        results["toolkit"] = attributes(button).get("toolkit")

    heading = find(app, "heading", "Shop")
    if heading is not None:
        results["heading_level"] = attributes(heading).get("level")

    nav = find(app, "landmark", "Links")
    if nav is not None:
        results["xml_roles"] = attributes(nav).get("xml-roles")

    entry = find(app, "entry", "Search")
    if entry is not None:
        results["text"] = Atspi.Text.get_text(entry, 0, 4)
        results["characters"] = Atspi.Text.get_character_count(entry)
        Atspi.Component.grab_focus(entry)
        results["focused"] = bool(wait_for(lambda: "focused" in state_names(entry), 4))
        Atspi.Text.set_caret_offset(entry, 2)
        results["caret"] = bool(wait_for(lambda: Atspi.Text.get_caret_offset(entry) == 2, 4))
        # EditableText: writing the field runs the page's own input and change.
        results["editable"] = "EditableText" in interfaces_of(entry)
        Atspi.EditableText.set_text_contents(entry, "flies")
        results["edited"] = bool(wait_for(lambda: named_contains(app, "input change") is not None, 5))
        results["edited_text"] = Atspi.Text.get_text(entry, 0, 5)

    volume = find(app, "slider", "Volume")
    if volume is not None:
        results["value_before"] = Atspi.Value.get_current_value(volume)
        Atspi.Value.set_current_value(volume, 60)
        results["value_after"] = bool(wait_for(lambda: Atspi.Value.get_current_value(volume) == 60, 5))

    # A press from the bus runs the page's own handler, which renames the heading in the tree.
    if button is not None:
        Atspi.Action.do_action(button, 0)
        results["pressed"] = bool(wait_for(lambda: find(app, "heading", "Bought") is not None, 5))

    table = find(app, "table", "")
    if table is not None:
        results["table"] = {"rows": Atspi.Table.get_n_rows(table),
                            "columns": Atspi.Table.get_n_columns(table),
                            "first": Atspi.Table.get_accessible_at(table, 1, 0).get_name()}

    # The live region and the field's new value reach a listener as events.
    listener = Atspi.EventListener.new(lambda event: events.append([event.type, str(event.any_data)]))
    listener.register("object:announcement")
    listener.register("object:text-changed")
    listener.register("object:property-change:accessible-value")
    refresh = find(app, "button", "Refresh")
    if refresh is not None:
        Atspi.Action.do_action(refresh, 0)
        wait_for(lambda: len(events) >= 2, 5)
        pump(0.5)
    results["events"] = events

    # A press that grows the page: the new list item is in the tree the client walks.
    added = find(app, "button", "Add")
    if added is not None:
        Atspi.Action.do_action(added, 0)
        results["grew"] = bool(wait_for(lambda: named(find(app, "list", "") or app, "Two") is not None, 5))
    print(json.dumps(results))

main()
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-atspi-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
writeFileSync(join(dir, "probe.py"), PROBE);
// The accessibility bus lives under XDG_RUNTIME_DIR, shared by a user's sessions; a private one
// keeps the test's app off the desktop's own.
writeFileSync(join(dir, "run.sh"), `#!/bin/sh
export XDG_RUNTIME_DIR="${dir}/runtime"
mkdir -p -m 700 "$XDG_RUNTIME_DIR"
"${exe}" > "${dir}/app.log" 2>&1 &
app=$!
trap 'kill $app 2>/dev/null' EXIT
sleep 2
python3 "${join(dir, "probe.py")}"
`);
const run = spawnSync("dbus-run-session", ["--", "/bin/sh", join(dir, "run.sh")], {
  encoding: "utf8", timeout: 120000,
});
const output = run.stdout.trim().split("\n").filter((l) => l.startsWith("{")).pop();
if (output === undefined) {
  console.log(run.stderr);
  throw new Error("no tree from the AT-SPI client");
}
interface Node { role: string; name: string; states: string[]; interfaces: string[] }
const result = JSON.parse(output) as {
  app?: boolean; tree?: Node[]; action?: string; actions?: number; text?: string;
  characters?: number; focused?: boolean; caret?: boolean; pressed?: boolean;
  table?: { rows: number; columns: number; first: string }; events?: [string, string][]; grew?: boolean;
  lazy_empty?: boolean; lazy_arrived?: boolean; children_changed?: boolean;
  toolkit?: string; heading_level?: string; xml_roles?: string; editable?: boolean;
  edited?: boolean; edited_text?: string; value_before?: number; value_after?: boolean;
};
const tree = result.tree ?? [];
for (const node of tree) console.log(`     tree ${node.role} ${JSON.stringify(node.name)} ${node.states.join(",")}`);
const has = (role: string, name: string): Node | undefined =>
  tree.find((n) => n.role === role && n.name === name);

check("the registry lists the application", result.app === true, JSON.stringify(result.app));
check("the page is built only once a client asks for it",
  result.lazy_empty === true && result.lazy_arrived === true,
  `empty=${result.lazy_empty} arrived=${result.lazy_arrived}`);
check("the page arrives as a children-changed event", result.children_changed === true,
  JSON.stringify(result.children_changed));
check("a control says what it is built with", result.toolkit === "Native", JSON.stringify(result.toolkit));
check("a heading says its level", result.heading_level === "1", JSON.stringify(result.heading_level));
check("a landmark says which it is", result.xml_roles === "navigation", JSON.stringify(result.xml_roles));
check("a text field carries EditableText", result.editable === true, JSON.stringify(result.editable));
check("a field written through EditableText runs the page's input and change",
  result.edited === true && result.edited_text === "flies",
  `edited=${result.edited} text=${JSON.stringify(result.edited_text)}`);
check("a slider carries the Value interface",
  result.value_before === 25 && result.value_after === true,
  `${result.value_before} -> ${result.value_after}`);
check("a heading is a heading with its text", has("heading", "Shop") !== undefined, "");
check("the paragraph reads as one static-text stop", has("static", "Hello world") !== undefined, "");
check("a button carries its label", has("button", "Buy") !== undefined, "");
check("a link carries its label", has("link", "A link") !== undefined, "");
check("a text field carries its name", has("entry", "Search") !== undefined, "");
const box = has("check box", "Agree");
check("a checked box says it is checked", box !== undefined && box.states.includes("checked"),
  JSON.stringify(box?.states ?? []));
check("a field says it is editable", has("entry", "Search")?.states.includes("editable") === true, "");
check("a button carries the click action", (has("button", "Buy")?.interfaces ?? []).includes("Action"),
  JSON.stringify(has("button", "Buy")?.interfaces ?? []));
check("an aria-hidden subtree is left out", has("button", "hidden") === undefined, "");
check("a table is a table with rows and cells",
  has("table", "") !== undefined && has("table row", "ItemPrice") !== undefined &&
    has("table cell", "Tea") !== undefined, "");
check("the click action is named", result.action === "click" && result.actions === 1,
  `${result.action} x${result.actions}`);
check("a field hands over its text", result.text === "bees" && result.characters === 4,
  `${result.text} ${result.characters}`);
check("a focus request reaches the page", result.focused === true, "");
check("a caret move reaches the field", result.caret === true, "");
check("a press runs the page's own handler", result.pressed === true, "");
check("a table reports its rows, columns and cells",
  result.table !== undefined && result.table.rows === 2 && result.table.columns === 2 &&
    result.table.first === "Tea", JSON.stringify(result.table));
const events = result.events ?? [];
check("a live region's new text is announced",
  events.some(([type, text]) => type === "object:announcement" && text === "Updated"),
  JSON.stringify(events));
check("a press that grows the page shows the new node", result.grew === true, "");
check("a control's value change is reported",
  events.some(([type]) => type.startsWith("object:text-changed") || type.includes("accessible-value")),
  JSON.stringify(events));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
