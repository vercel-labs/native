// The real Accessibility API round trip: an app built here, and the todo example, launched into
// the user's session and driven through AXUIElement the way an assistive client such as
// agent-desktop drives a browser's page. The app builds no tree until a client asks:
// AXManualAccessibility reads false and is settable, and setting it brings the page's AXWebArea.
// Then the client finds a button by its title and presses it, types into a field and writes its
// value, steps a range, and reads frames, the focused element and the element under a point; in the
// todo example it types a todo and presses Add. Needs the Accessibility permission for the test
// process (true for a process started over ssh on the test Mac); it skips cleanly otherwise.
//   npm test

import { spawn, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, openSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

if (process.platform !== "darwin") {
  console.log(`ok   skipped: AXUIElement is macOS's accessibility API (this is ${process.platform})`);
  process.exit(0);
}

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=420, height=420"><title>Shop</title></head><body>
<main>
<h1>Groceries</h1>
<button id="b">Buy</button>
<input id="i" type="text" aria-label="Search" value="bees">
<input id="n" placeholder="Your name">
<input id="c" type="checkbox" checked aria-label="Agree">
<input id="r" type="range" aria-label="Volume" value="50">
<a id="l" href="https://example.com/help">Help</a>
<div id="row">Clickable row</div>
<table><tr><td>A1</td><td><button id="rowact">Act</button></td></tr><tr><td>B1</td><td>B2</td></tr></table>
</main>
<script>
const say = (t) => console.log(t);
document.getElementById("b").addEventListener("click", () => say("clicked"));
document.getElementById("row").addEventListener("click", () => say("row clicked"));
const n = document.getElementById("n");
n.addEventListener("input", () => say("input [" + n.value + "]"));
n.addEventListener("change", () => say("change [" + n.value + "]"));
document.getElementById("c").addEventListener("change", (e) => say("agree " + e.target.checked));
document.getElementById("r").addEventListener("input", (e) => say("volume " + e.target.value));
n.addEventListener("focus", () => say("focus name"));
</script>
</body></html>`;

// The probe talks to the app the way an assistive client does: AXUIElementCreateApplication, the
// attribute walk, the settable attributes and the actions. An element is found by its AXTitle.
//   trust                          1 when this process may use the API
//   manual <pid>                   AXManualAccessibility's value and whether it is settable
//   activate <pid>                 sets AXManualAccessibility
//   tree <pid>                     role/subrole, title, value, frame and actions per element
//   press|increment <pid> <title>  AXPress / AXIncrement
//   settable <pid> <title> <attr>  whether an attribute is settable
//   set <pid> <title> <attr> <s>   writes a string attribute (AXValue, AXSelectedText)
//   focus <pid> <title>            sets AXFocused
//   focused <pid>                  the app's AXFocusedUIElement
//   frame <pid> <title>            an element's AXPosition and AXSize
//   hit <pid> <x> <y>              AXUIElementCopyElementAtPosition
//   attr <pid> <title> <attr>      one attribute's value
//   string <pid> <title> <loc> <len>  AXStringForRange
const PROBE = String.raw`
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static void cstr(CFTypeRef v, char *out, size_t n) {
  out[0] = 0;
  if (v == NULL) return;
  if (CFGetTypeID(v) == CFStringGetTypeID()) CFStringGetCString((CFStringRef)v, out, n, kCFStringEncodingUTF8);
  else if (CFGetTypeID(v) == CFNumberGetTypeID()) { double d = 0; CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &d); snprintf(out, n, "%g", d); }
  else if (CFGetTypeID(v) == CFBooleanGetTypeID()) snprintf(out, n, "%s", CFBooleanGetValue((CFBooleanRef)v) ? "true" : "false");
  else if (CFGetTypeID(v) == CFURLGetTypeID()) CFStringGetCString(CFURLGetString((CFURLRef)v), out, n, kCFStringEncodingUTF8);
}

static void attr(AXUIElementRef el, CFStringRef name, char *out, size_t n) {
  CFTypeRef v = NULL;
  out[0] = 0;
  if (AXUIElementCopyAttributeValue(el, name, &v) == kAXErrorSuccess && v != NULL) { cstr(v, out, n); CFRelease(v); }
}

static CGRect frame_of(AXUIElementRef el) {
  CFTypeRef pos = NULL, size = NULL;
  CGRect r = CGRectZero;
  AXUIElementCopyAttributeValue(el, kAXPositionAttribute, &pos);
  AXUIElementCopyAttributeValue(el, kAXSizeAttribute, &size);
  if (pos != NULL) { AXValueGetValue((AXValueRef)pos, kAXValueTypeCGPoint, &r.origin); CFRelease(pos); }
  if (size != NULL) { AXValueGetValue((AXValueRef)size, kAXValueTypeCGSize, &r.size); CFRelease(size); }
  return r;
}

static void describe(AXUIElementRef el, char *out, size_t n) {
  char role[128], sub[128], title[256];
  attr(el, kAXRoleAttribute, role, sizeof role);
  attr(el, kAXSubroleAttribute, sub, sizeof sub);
  attr(el, kAXTitleAttribute, title, sizeof title);
  snprintf(out, n, "%s%s%s title=[%s]", role, sub[0] ? "/" : "", sub, title);
}

static void print_element(AXUIElementRef el, int depth) {
  char head[512], value[256];
  describe(el, head, sizeof head);
  attr(el, kAXValueAttribute, value, sizeof value);
  CGRect r = frame_of(el);
  char extra[256] = "";
  if (strncmp(head, "AXCell", 6) == 0) {
    CFTypeRef rr = NULL, cc = NULL;
    CFRange rowRange = CFRangeMake(-1, 0), colRange = CFRangeMake(-1, 0);
    if (AXUIElementCopyAttributeValue(el, kAXRowIndexRangeAttribute, &rr) == kAXErrorSuccess && rr != NULL) {
      AXValueGetValue((AXValueRef)rr, kAXValueTypeCFRange, &rowRange);
      CFRelease(rr);
    }
    if (AXUIElementCopyAttributeValue(el, kAXColumnIndexRangeAttribute, &cc) == kAXErrorSuccess && cc != NULL) {
      AXValueGetValue((AXValueRef)cc, kAXValueTypeCFRange, &colRange);
      CFRelease(cc);
    }
    snprintf(extra, sizeof extra, " cell=%ld,%ld", (long)rowRange.location, (long)colRange.location);
  }
  CFArrayRef actions = NULL;
  char acts[256] = "";
  if (AXUIElementCopyActionNames(el, &actions) == kAXErrorSuccess && actions != NULL) {
    for (CFIndex i = 0; i < CFArrayGetCount(actions); i++) {
      char a[64];
      CFStringGetCString(CFArrayGetValueAtIndex(actions, i), a, sizeof a, kCFStringEncodingUTF8);
      strncat(acts, i == 0 ? " actions=" : ",", sizeof acts - strlen(acts) - 1);
      strncat(acts, a, sizeof acts - strlen(acts) - 1);
    }
    CFRelease(actions);
  }
  for (int i = 0; i < depth; i++) printf("  ");
  printf("%s %.0f,%.0f %.0fx%.0f value=[%s]%s%s\n", head, r.origin.x, r.origin.y, r.size.width, r.size.height, value, extra, acts);
  CFTypeRef kids = NULL;
  if (AXUIElementCopyAttributeValue(el, kAXChildrenAttribute, &kids) == kAXErrorSuccess && kids != NULL) {
    CFArrayRef list = (CFArrayRef)kids;
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
      AXUIElementRef kid = (AXUIElementRef)CFArrayGetValueAtIndex(list, i);
      char role[64];
      attr(kid, kAXRoleAttribute, role, sizeof role);
      if (strcmp(role, "AXMenuBar") == 0) continue;
      print_element(kid, depth + 1);
    }
    CFRelease(kids);
  }
}

static AXUIElementRef find_title(AXUIElementRef el, const char *want) {
  char title[256];
  attr(el, kAXTitleAttribute, title, sizeof title);
  if (strcmp(title, want) == 0) { CFRetain(el); return el; }
  CFTypeRef kids = NULL;
  if (AXUIElementCopyAttributeValue(el, kAXChildrenAttribute, &kids) == kAXErrorSuccess && kids != NULL) {
    CFArrayRef list = (CFArrayRef)kids;
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
      AXUIElementRef hit = find_title((AXUIElementRef)CFArrayGetValueAtIndex(list, i), want);
      if (hit != NULL) { CFRelease(kids); return hit; }
    }
    CFRelease(kids);
  }
  return NULL;
}

static CFStringRef cf(const char *s) { return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8); }

int main(int argc, char **argv) {
  if (argc >= 2 && strcmp(argv[1], "trust") == 0) {
    printf("%d\n", AXIsProcessTrusted() ? 1 : 0);
    return 0;
  }
  if (argc < 3) return 2;
  const char *cmd = argv[1];
  AXUIElementRef app = AXUIElementCreateApplication((pid_t)atoi(argv[2]));
  if (app == NULL) return 3;
  AXUIElementSetMessagingTimeout(app, 3.0);
  char out[512] = "";
  if (strcmp(cmd, "manual") == 0) {
    Boolean settable = false;
    AXUIElementIsAttributeSettable(app, CFSTR("AXManualAccessibility"), &settable);
    attr(app, CFSTR("AXManualAccessibility"), out, sizeof out);
    printf("value=%s settable=%d\n", out, settable ? 1 : 0);
  } else if (strcmp(cmd, "activate") == 0) {
    AXError err = AXUIElementSetAttributeValue(app, CFSTR("AXManualAccessibility"), kCFBooleanTrue);
    printf(err == kAXErrorSuccess ? "SET\n" : "SETFAILED %d\n", err);
  } else if (strcmp(cmd, "tree") == 0) {
    print_element(app, 0);
  } else if (strcmp(cmd, "focused") == 0) {
    CFTypeRef f = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, &f) == kAXErrorSuccess && f != NULL) {
      describe((AXUIElementRef)f, out, sizeof out);
      CFRelease(f);
    }
    printf("%s\n", out);
  } else if (strcmp(cmd, "hit") == 0 && argc >= 5) {
    AXUIElementRef sys = AXUIElementCreateSystemWide();
    AXUIElementRef hit = NULL;
    if (AXUIElementCopyElementAtPosition(sys, (float)atof(argv[3]), (float)atof(argv[4]), &hit) == kAXErrorSuccess && hit != NULL) {
      describe(hit, out, sizeof out);
      CFRelease(hit);
    }
    printf("%s\n", out);
  } else if (argc >= 4) {
    AXUIElementRef target = find_title(app, argv[3]);
    if (target == NULL) { printf("NOTFOUND\n"); return 4; }
    if (strcmp(cmd, "press") == 0 || strcmp(cmd, "increment") == 0) {
      AXError err = AXUIElementPerformAction(target, strcmp(cmd, "press") == 0 ? kAXPressAction : kAXIncrementAction);
      printf(err == kAXErrorSuccess ? "DONE\n" : "FAILED %d\n", err);
    } else if (strcmp(cmd, "focus") == 0) {
      AXError err = AXUIElementSetAttributeValue(target, kAXFocusedAttribute, kCFBooleanTrue);
      printf(err == kAXErrorSuccess ? "DONE\n" : "FAILED %d\n", err);
    } else if (strcmp(cmd, "settable") == 0 && argc >= 5) {
      Boolean settable = false;
      AXUIElementIsAttributeSettable(target, cf(argv[4]), &settable);
      printf("%d\n", settable ? 1 : 0);
    } else if (strcmp(cmd, "set") == 0 && argc >= 6) {
      AXError err = AXUIElementSetAttributeValue(target, cf(argv[4]), cf(argv[5]));
      printf(err == kAXErrorSuccess ? "DONE\n" : "FAILED %d\n", err);
    } else if (strcmp(cmd, "attr") == 0 && argc >= 5) {
      attr(target, cf(argv[4]), out, sizeof out);
      printf("%s\n", out);
    } else if (strcmp(cmd, "frame") == 0) {
      CGRect r = frame_of(target);
      printf("%.0f %.0f %.0f %.0f\n", r.origin.x, r.origin.y, r.size.width, r.size.height);
    } else if (strcmp(cmd, "string") == 0 && argc >= 6) {
      CFRange range = CFRangeMake((CFIndex)atol(argv[4]), (CFIndex)atol(argv[5]));
      AXValueRef boxed = AXValueCreate(kAXValueTypeCFRange, &range);
      CFTypeRef v = NULL;
      if (AXUIElementCopyParameterizedAttributeValue(target, kAXStringForRangeParameterizedAttribute, boxed, &v) == kAXErrorSuccess && v != NULL) {
        cstr(v, out, sizeof out);
        CFRelease(v);
      }
      printf("%s\n", out);
    }
  }
  CFRelease(app);
  return 0;
}
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-ax-"));
const probeSrc = join(dir, "axprobe.c");
const probe = join(dir, "axprobe");
writeFileSync(probeSrc, PROBE);
const cc = spawnSync("clang", [probeSrc, "-framework", "ApplicationServices", "-o", probe], { encoding: "utf8" });
if (cc.status !== 0) throw new Error(`probe build failed\n${cc.stderr}`);

const trust = spawnSync(probe, ["trust"], { encoding: "utf8" }).stdout.trim();
if (trust !== "1") {
  console.log("skip: this process has no Accessibility permission (AXIsProcessTrusted() is false)");
  console.log("\nall passed");
  process.exit(0);
}

const appDir = join(dir, "app");
mkdirSync(appDir, { recursive: true });
writeFileSync(join(appDir, "index.html"), PAGE);
const exe = join(appDir, "native");
const build = spawnSync("node", ["compiler/cli.ts", "build", appDir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const sleep = (ms: number): void => {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
};

// A window needs a GUI session. A process started over ssh can reach the window server when the
// user is logged in; launchctl asuser is the fallback for a session it can't.
const log = join(dir, "app.log");
const fd = openSync(log, "w");
const uid = spawnSync("id", ["-u"], { encoding: "utf8" }).stdout.trim();
const running = (): number => {
  const found = spawnSync("pgrep", ["-f", exe], { encoding: "utf8" }).stdout.trim().split("\n")[0];
  return found === "" ? 0 : Number(found);
};
const waitForApp = (): number => {
  for (let i = 0; i < 60; i++) {
    sleep(200);
    const found = running();
    if (found !== 0) return found;
  }
  return 0;
};
const direct = spawn(exe, [], { detached: true, stdio: ["ignore", fd, fd] });
direct.unref();
let pid = waitForApp();
if (pid === 0) {
  const viaSession = spawn("launchctl", ["asuser", uid, exe], { detached: true, stdio: ["ignore", fd, fd] });
  viaSession.unref();
  pid = waitForApp();
}
if (pid === 0) {
  console.log("skip: the app could not open a window in this session");
  console.log("\nall passed");
  process.exit(0);
}
check("the app is running", pid > 0, `pid ${pid}`);

const run = (...args: string[]): string => spawnSync(probe, [args[0], String(pid), ...args.slice(1)], { encoding: "utf8" }).stdout.trim();
const appLog = (): string => readFileSync(log, "utf8");
/** Waits for the app's log to show a line, as the page's handler prints it. */
const logged = (text: string): boolean => {
  for (let i = 0; i < 50; i++) {
    if (appLog().includes(text)) return true;
    sleep(100);
  }
  return false;
};
/** Waits for a probe command's output to satisfy a test. */
const until = (test: (out: string) => boolean, ...args: string[]): string => {
  let out = "";
  for (let i = 0; i < 100; i++) {
    out = run(...args);
    if (test(out)) return out;
    sleep(100);
  }
  return out;
};

// Wait for the app to answer, without asking for the page's own tree: the app's attributes are
// AppKit's, and reading them builds nothing.
const manual = until((t) => t.endsWith("settable=1"), "manual");
check("the tree is off until a client asks: AXManualAccessibility reads false and is settable",
  manual === "value=false settable=1", manual);
check("setting AXManualAccessibility is accepted", run("activate") === "SET", "");
const text = until((t) => t.includes("AXWebArea") && t.includes("title=[Buy]"), "tree");
for (const line of text.split("\n")) if (line.trim() !== "") console.log(`     ax ${line.trim()}`);
check("the page is an AXWebArea in the window", /AXWindow[^\n]*\n(\s+[^\n]*\n)*?\s+AXWebArea title=\[Shop\]/.test(text), "");
check("the switch now reads true", run("manual") === "value=true settable=1", run("manual"));
check("a heading is AXHeading with its level as value", /AXHeading title=\[Groceries\] .*value=\[1\]/.test(text), "");
check("a landmark is a group with its subrole", /AXGroup\/AXLandmarkMain /.test(text), "");
check("the button has its title and AXPress", /AXButton title=\[Buy\] .*actions=AXPress/.test(text), "");
check("the field carries its name and value", /AXTextField title=\[Search\] .*value=\[bees\]/.test(text), "");
check("a field nothing labels is named by its placeholder", /AXTextField title=\[Your name\]/.test(text), "");
check("the checked box says so", /AXCheckBox title=\[Agree\] .*value=\[1\]/.test(text), "");
check("a range is a slider with its value", /AXSlider title=\[Volume\] .*value=\[50\]/.test(text), "");
check("a link carries its URL", run("attr", "Help", "AXURL") === "https://example.com/help", run("attr", "Help", "AXURL"));
check("an element reports its id as AXDOMIdentifier", run("attr", "Buy", "AXDOMIdentifier") === "b", run("attr", "Buy", "AXDOMIdentifier"));
check("a box the page takes clicks on can be pressed", /AXGroup title=\[\] [^\n]*actions=AXPress\n\s+AXStaticText title=\[Clickable row\]/.test(text), "");
check("static text takes no press", !/AXStaticText [^\n]*actions=[^\n]*AXPress/.test(text), "");
check("a table exposes its rows", /AXTable/.test(text) && (text.match(/AXRow /g) ?? []).length >= 2, "");
check("its cells know where they are", /AXCell .*cell=0,0/.test(text) && /AXCell .*cell=1,1/.test(text), "");
check("a button inside a cell stays reachable", /AXCell [^\n]*title=\[Act\][^\n]*\n\s+AXButton title=\[Act\]/.test(text), "");

// Frames are in the screen's top-left coordinates, inside the window, in page order.
const frame = (title: string): number[] => run("frame", title).split(" ").map(Number);
const area = frame("Shop");
const heading = frame("Groceries");
const button = frame("Buy");
check("frames sit inside the web area", button[0] >= area[0] && button[1] >= area[1] &&
  button[0] + button[2] <= area[0] + area[2] + 1 && button[1] + button[3] <= area[1] + area[3] + 1,
  `button ${button} area ${area}`);
check("and run down the page in order", heading[1] < button[1], `heading ${heading} button ${button}`);
const hit = run("hit", String(button[0] + button[2] / 2), String(button[1] + button[3] / 2));
check("the element under a point is the one there", hit === "AXButton title=[Buy]", hit);

const slice = run("string", "Search", "0", "4");
check("AXStringForRange reads a field's characters", slice === "bees", slice);

check("AXPress succeeds", run("press", "Buy") === "DONE", "");
check("AXPress ran the page's click handler", logged("clicked"), "no click logged");

// Focus and text: the field takes AXFocused, AXSelectedText inserts as typing does, and AXValue
// replaces the value; the page hears focus, input and change.
check("a field's AXValue and AXSelectedText are settable",
  run("settable", "Your name", "AXValue") === "1" && run("settable", "Your name", "AXSelectedText") === "1", "");
check("a button's AXValue is not", run("settable", "Buy", "AXValue") === "0", "");
check("AXFocused moves focus", run("focus", "Your name") === "DONE" && logged("focus name"), "");
const focused = until((t) => t.startsWith("AXTextField"), "focused");
check("AXFocusedUIElement is the focused field", focused === "AXTextField title=[Your name]", focused);
check("AXSelectedText types into the field", run("set", "Your name", "AXSelectedText", "Ada") === "DONE" && logged("input [Ada]"), appLog());
check("AXValue replaces the value and commits it", run("set", "Your name", "AXValue", "Ada Lovelace") === "DONE" &&
  logged("input [Ada Lovelace]") && logged("change [Ada Lovelace]"), appLog());
const value = until((t) => t === "Ada Lovelace", "attr", "Your name", "AXValue");
check("the field reads back the value", value === "Ada Lovelace", value);

check("AXPress on a checkbox unchecks it", run("press", "Agree") === "DONE" && logged("agree false"), appLog());
const box = until((t) => t === "0", "attr", "Agree", "AXValue");
check("and its value follows the checkedness", box === "0", box);
check("AXIncrement steps a range", run("increment", "Volume") === "DONE" && logged("volume 51"), appLog());

spawnSync("pkill", ["-f", exe]);

// The todo example, driven the way agent-desktop drives it: find the field by the name its
// placeholder gives it, type a todo into it, press Add, and read the new item and the count.
const todoExe = join(dir, "todo");
const todoBuild = spawnSync("node", ["compiler/cli.ts", "build", join("..", "..", "examples", "todo"), "-o", todoExe], { encoding: "utf8" });
if (todoBuild.status !== 0) throw new Error(`todo build failed\n${todoBuild.stderr}`);
const todo = spawn(todoExe, [], { detached: true, stdio: "ignore" });
todo.unref();
let todoPid = 0;
for (let i = 0; i < 60 && todoPid === 0; i++) {
  sleep(200);
  const found = spawnSync("pgrep", ["-f", todoExe], { encoding: "utf8" }).stdout.trim().split("\n")[0];
  todoPid = found === "" ? 0 : Number(found);
}
const todoRun = (...args: string[]): string => spawnSync(probe, [args[0], String(todoPid), ...args.slice(1)], { encoding: "utf8" }).stdout.trim();
const todoUntil = (test: (out: string) => boolean, ...args: string[]): string => {
  let out = "";
  for (let i = 0; i < 100; i++) {
    out = todoRun(...args);
    if (test(out)) return out;
    sleep(100);
  }
  return out;
};
todoUntil((t) => t.endsWith("settable=1"), "manual");
todoRun("activate");
const todoTree = todoUntil((t) => t.includes("title=[Add]"), "tree");
check("the todo example's field is named by its placeholder", /AXTextField title=\[What needs doing\?\]/.test(todoTree), todoTree);
check("its field takes typed text", todoRun("set", "What needs doing?", "AXSelectedText", "Buy milk") === "DONE", "");
check("and shows it", todoUntil((t) => t === "Buy milk", "attr", "What needs doing?", "AXValue") === "Buy milk", "");
check("the Add button presses", todoRun("press", "Add") === "DONE", "");
const added = todoUntil((t) => t.includes("title=[Buy milk]") && t.includes("title=[1 item left]"), "tree");
check("the new todo is in the tree, and the count with it",
  added.includes("AXStaticText title=[Buy milk]") && added.includes("title=[1 item left]"), added);
check("the field is empty again", todoUntil((t) => t === "", "attr", "What needs doing?", "AXValue") === "", "");
spawnSync("pkill", ["-f", todoExe]);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
