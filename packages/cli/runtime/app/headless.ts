// Headless runs for tests and CI (NATIVE_STEPS, NATIVE_SNAPSHOT), and the run() entry point.

import * as P from "../../shared/props.ts";
import { File, HTMLElement, HTMLInputElement, HTMLSelectElement, HTMLTextAreaElement, Node, document, dirty, markFullPaint } from "../dom.ts";
import { setIncrementalLayout } from "../layout/incremental.ts";
import { viewport, absolutePosition } from "../layout.ts";
import { hostOpen, hostViewWidth, hostViewHeight, hostSnapshot, hostSnapshotComposited, hostTitle, hostMenuSpec, hostWindowSetHidden, hostWindowSetFrame, hostPoll, hostImagesSettled, EV_NONE, KEY_TEXT, KEY_BACKSPACE, KEY_ENTER, KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, KEY_HOME, KEY_END, KEY_ESCAPE, KEY_TAB, KEY_DELETE, KEY_SELECT_ALL, KEY_COPY, KEY_CUT, KEY_PASTE, MOD_META, MOD_SHIFT, MOD_ALT, MOD_CTRL } from "../host.ts";
import { imagesDecoding, pumpImages } from "../images.ts";
import { dispatchLoad, messageDelivered, reportUncaughtError, requestQuit, runFrameCallbacks, windowBlurred, windowFocused, windowResized } from "../window.ts";
import { setClock } from "../animation.ts";
import { keyDown, keyUp } from "./keyboard.ts";
import { compositionCancel, compositionEnd, compositionUpdate } from "../composition.ts";
import { handleHostEvent, tick } from "./loop.ts";
import { config, frame, paintPage } from "./mount.ts";
import { applicationMenuItemIndex, chooseApplicationMenuItem, installApplicationMenu } from "../menus.ts";
import { publishTitlebarArea } from "./titlebar.ts";
import { pointer, pointerContext, pointerDown, pointerMove, pointerUp } from "./pointer.ts";
import { dropFilesAt, fileFromPath } from "./dnd.ts";
import { fadeScrollbars, wheel } from "./scroll.ts";
import { setSnapshotScale } from "../device.ts";
import { compositorStats } from "../compositor.ts";

// ---------------------------------------------------------------------------
// Headless mode for tests and CI:
//   NATIVE_STEPS='click #new | type Buy milk | key Enter | hover #add | drag #stage 40 0' NATIVE_SNAPSHOT=out.png ./app
// Steps go through the same pointer and keyboard paths as real input. `frame <ms>` runs the
// animation callbacks at a chosen timestamp, and `resize <w> <h>` changes the viewport. With steps
// but no snapshot the app still runs them headlessly, then exits instead of leaving a window up.

const KEY_CODES: Map<string, number> = new Map([
  ["Backspace", KEY_BACKSPACE], ["Enter", KEY_ENTER], ["ArrowLeft", KEY_LEFT], ["ArrowRight", KEY_RIGHT],
  ["ArrowUp", KEY_UP], ["ArrowDown", KEY_DOWN], ["Home", KEY_HOME], ["End", KEY_END], ["Escape", KEY_ESCAPE],
  ["Tab", KEY_TAB], ["Delete", KEY_DELETE], ["SelectAll", KEY_SELECT_ALL], ["Space", KEY_TEXT],
  ["Copy", KEY_COPY], ["Cut", KEY_CUT], ["Paste", KEY_PASTE],
]);

/**
 * The code, modifiers and text a key step names: "Shift+N", "Enter", or a single character,
 * which is typed text. The named keys, and the shortcut keys a browser reports by name (Cmd+C
 * arrives with no text of its own), have codes of their own.
 */
function stepKey(arg: string): { code: number; mods: number; text: string } {
  const parts = arg.split("+");
  let mods = 0;
  for (const m of parts.slice(0, parts.length - 1)) {
    if (m === "Meta") mods |= MOD_META;
    else if (m === "Shift") mods |= MOD_SHIFT;
    else if (m === "Alt") mods |= MOD_ALT;
    else if (m === "Ctrl") mods |= MOD_CTRL;
  }
  const name = parts[parts.length - 1];
  const single = name.length === 1;
  const code = single ? KEY_TEXT : KEY_CODES.get(name);
  if (code === undefined) {
    console.error(`native: unknown key '${arg}'`);
    process.exit(1);
  }
  // Text keys arrive as the character a browser would produce.
  return { code, mods, text: single ? name : name === "Space" ? " " : "" };
}

function center(sel: string): number[] {
  const el = document.querySelector(sel);
  if (el === null) {
    console.error(`native: no element matches '${sel}'`);
    process.exit(1);
  }
  if (el.sv[P.P_DISPLAY] === P.D_INLINE) {
    // Inline elements have no box of their own: use their first fragment's center.
    let box = el.parentElement;
    while (box !== null && box.sv[P.P_DISPLAY] === P.D_INLINE) box = box.parentElement;
    if (box !== null) {
      for (let i = 0; i < box.fragKind.length; i++) {
        let o: Node | null = box.fragOwner[i];
        while (o !== null && o !== el && o !== box) o = o.parentNode;
        if (o === el && box.fragKind[i] === 0) {
          const bp = absolutePosition(box);
          return [bp[0] - box.scrollX + box.fragX[i] + box.fragW[i] / 2, bp[1] - box.scrollY + box.fragTop[i] + 8];
        }
      }
    }
  }
  const p = absolutePosition(el);
  return [p[0] + el.w / 2, p[1] + el.h / 2];
}

/** The MOD_* bits a step's modifier words name, joined with '+': "Meta+Shift". */
function stepMods(words: string[]): number {
  let mods = 0;
  for (const word of words) {
    for (const m of word.split("+")) {
      if (m === "Meta") mods |= MOD_META;
      else if (m === "Shift") mods |= MOD_SHIFT;
      else if (m === "Alt") mods |= MOD_ALT;
      else if (m === "Ctrl") mods |= MOD_CTRL;
    }
  }
  return mods;
}

/**
 * Hands the steps' own effects back to the page the way a real event loop does: a window the page
 * moved, resized or entered fullscreen sends the event its window would, and a closed window
 * reports it. Steps read the page after this, so the state they see is the one that arrived.
 */
function drainHostEvents(): void {
  let ev = hostPoll(0);
  while (ev !== EV_NONE) {
    if (!handleHostEvent(ev)) process.exit(0);
    ev = hostPoll(0);
  }
}

function runStep(step: string): void {
  const sp = step.indexOf(" ");
  const verb = sp < 0 ? step : step.slice(0, sp);
  const arg = sp < 0 ? "" : step.slice(sp + 1);
  if (verb === "click") {
    const c = center(arg);
    pointerDown(c[0], c[1]);
    frame();
    pointerUp(c[0], c[1]);
  } else if (verb === "clickat") {
    // clickat <x> <y> [Meta|Shift|Alt|Ctrl]: a press and release at a viewport point, with the
    // modifier keys a real event would carry.
    const parts = arg.split(" ");
    const mods = stepMods(parts.slice(2));
    pointerDown(Number(parts[0]), Number(parts[1]), 1, mods);
    frame();
    pointerUp(Number(parts[0]), Number(parts[1]), 1, mods);
  } else if (verb === "dragat") {
    // dragat <x0> <y0> <x1> <y1> [Meta|Shift|Alt|Ctrl]: the same two-step drag, between points.
    const parts = arg.split(" ");
    const mods = stepMods(parts.slice(4));
    const x0 = Number(parts[0]);
    const y0 = Number(parts[1]);
    const x1 = Number(parts[2]);
    const y1 = Number(parts[3]);
    pointerDown(x0, y0, 1, mods);
    frame();
    pointerMove((x0 + x1) / 2, (y0 + y1) / 2, mods);
    frame();
    pointerMove(x1, y1, mods);
    frame();
    pointerUp(x1, y1, 1, mods);
  } else if (verb === "hover") {
    const c = center(arg);
    pointerMove(c[0], c[1]);
  } else if (verb === "dblclick" || verb === "tripleclick") {
    // Presses and releases at the same point with the click count a browser reports: two for a
    // double-click, three for a triple-click.
    const c = center(arg);
    const last = verb === "tripleclick" ? 3 : 2;
    for (let n = 1; n <= last; n++) {
      pointerDown(c[0], c[1], n);
      frame();
      pointerUp(c[0], c[1], n);
    }
  } else if (verb === "drag") {
    // drag <selector> <dx> <dy>: press at the element's centre, move by the offset in two steps
    // (so a handler that turns movement into a gesture sees it), then release.
    const parts = arg.split(" ");
    const c = center(parts[0]);
    const dx = Number(parts[1]);
    const dy = Number(parts[2]);
    pointerDown(c[0], c[1]);
    frame();
    pointerMove(c[0] + dx / 2, c[1] + dy / 2);
    frame();
    pointerMove(c[0] + dx, c[1] + dy);
    frame();
    pointerUp(c[0] + dx, c[1] + dy);
  } else if (verb === "dropfiles") {
    // dropfiles <selector> <path>[,<path>…]: files dragged in from outside the app and dropped on
    // the element, through the same path a drop from the Finder takes.
    const parts = arg.split(" ");
    const c = center(parts[0]);
    const files: File[] = [];
    for (const path of parts.slice(1).join(" ").split(",")) if (path !== "") files.push(fileFromPath(path));
    dropFilesAt(c[0], c[1], document.querySelector(parts[0]), files);
  } else if (verb === "type") {
    for (const ch of arg) keyDown(KEY_TEXT, 0, ch);
  } else if (verb === "compose") {
    // compose <text>: an input method reports the marked text it has composed so far.
    compositionUpdate(arg);
  } else if (verb === "commit") {
    // commit <text>: the input method commits the text, ending the composition.
    compositionEnd(arg);
  } else if (verb === "cancelcompose") {
    // cancelcompose: the input method abandons the composition and the value goes back.
    compositionCancel();
  } else if (verb === "key" || verb === "keydown" || verb === "keyrepeat" || verb === "keyup") {
    const key = stepKey(arg);
    // `key` is a press and a release, as a keyboard sends one; `keydown`, `keyrepeat` and
    // `keyup` are the three steps on their own, for a test that holds a key down.
    if (verb === "keyup") keyUp(key.code, key.mods, key.text);
    else {
      keyDown(key.code, key.mods, key.text, verb === "keyrepeat");
      if (verb === "key") keyUp(key.code, key.mods, key.text);
    }
  } else if (verb === "wheel") {
    // wheel <selector> <dy> [dx]: positive dy scrolls down, positive dx scrolls right
    const parts = arg.split(" ");
    const secondLast = parts.length >= 3 ? parts[parts.length - 2] : "";
    const two = secondLast !== "" && !Number.isNaN(Number(secondLast));
    const dyArg = two ? secondLast : parts[parts.length - 1];
    const dxArg = two ? parts[parts.length - 1] : "";
    const sel = parts.slice(0, parts.length - (two ? 2 : 1)).join(" ");
    const c = center(sel);
    wheel(c[0], c[1], -Number(dyArg), dxArg === "" ? 0 : -Number(dxArg));
  } else if (verb === "selected") {
    // selected <selector>: a select's index and which of its options are chosen.
    const el = document.querySelector(arg);
    if (!(el instanceof HTMLSelectElement)) {
      console.log("<none>");
    } else {
      const flags: string[] = [];
      for (const o of el.options) flags.push(o.selected ? "1" : "0");
      console.log("idx " + el.selectedIndex + " " + flags.join(""));
    }
  } else if (verb === "selection") {
    // selection <selector>: a field's selection range, for checking where the caret went.
    const el = document.querySelector(arg);
    if (el instanceof HTMLTextAreaElement) console.log("sel " + el.selectionStart + "," + el.selectionEnd);
    else if (el instanceof HTMLInputElement) console.log("sel " + el.selectionStart + "," + el.selectionEnd);
    else console.log("<none>");
  } else if (verb === "scrolltop" || verb === "scrollleft") {
    const el = document.querySelector(arg);
    if (el === null) console.log("<none>");
    else console.log(String(Math.round(verb === "scrolltop" ? el.scrollTop : el.scrollLeft)));
  } else if (verb === "frame") {
    // frame <ms>: runs the animation callbacks due now, with that timestamp. The clock goes
    // with it, so transitions and animations advance to the same time and stay deterministic.
    // The loop's tick also fades the scrollbars that are due, so a step does the same: a run
    // that waits past the fade then takes a frame sees it.
    const t = arg === "" ? 0 : Number(arg);
    fadeScrollbars();
    setClock(t);
    runFrameCallbacks(t);
  } else if (verb === "snapshotnow") {
    // snapshotnow <path>: writes the display list as the frames left it, without the full paint
    // a snapshot does first, so a test can see what the compositor path presented.
    const ok = hostSnapshot(arg, viewport.w, viewport.h, SNAPSHOT_SCALE);
    process.exit(ok === 1 ? 0 : 1);
  } else if (verb === "snapshotcomposited") {
    // snapshotcomposited <path>: the composited picture of the display list as the frames left
    // it, without a full paint first. A run with NATIVE_COMPOSITOR_LIVE=1 writes the last frame it
    // presented the way the window does.
    const ok = hostSnapshotComposited(arg, viewport.w, viewport.h, SNAPSHOT_SCALE);
    process.exit(ok === 1 ? 0 : 1);
  } else if (verb === "paintstats") {
    console.log(`composited ${compositorStats.frames} fallbacks ${compositorStats.fallbacks}`);
  } else if (verb === "contextmenu") {
    // contextmenu <selector>: the second button's press at the element's centre.
    const c = center(arg);
    pointerContext(c[0], c[1]);
  } else if (verb === "menu") {
    // menu: the menu bar the host built from the page's markup, one line per item.
    let spec = "";
    hostMenuSpec((text: string) => {
      spec = text;
    });
    console.log(spec === "" ? "<none>" : spec);
  } else if (verb === "menuclick") {
    // menuclick <path>: chooses an item of the menu bar by its path ("Edit/--copy" is the label,
    // so a path walks through the submenu titles, then the item's label).
    const index = applicationMenuItemIndex(arg);
    if (index < 0) {
      console.error(`native: no menu item at '${arg}'`);
      process.exit(1);
    }
    chooseApplicationMenuItem(index);
  } else if (verb === "focus") {
    // focus: the window became the key window, as clicking it does.
    windowFocused();
  } else if (verb === "blur") {
    // blur: the window stopped being the key window.
    windowBlurred();
  } else if (verb === "hide" || verb === "show") {
    // hide/show: the window is minimized or comes back, which makes the page hidden or visible.
    hostWindowSetHidden(verb === "hide" ? 1 : 0);
  } else if (verb === "title") {
    // title: the window's title as the host has it, after a page set document.title.
    let title = "";
    hostTitle((text: string) => {
      title = text;
    });
    console.log(title === "" ? "<none>" : title);
  } else if (verb === "message") {
    // message <id> <data>: a message from the window whose id that is, as another window's
    // postMessage() would deliver it.
    const sp2 = arg.indexOf(" ");
    const source = Number(sp2 < 0 ? arg : arg.slice(0, sp2));
    const data = sp2 < 0 ? "null" : arg.slice(sp2 + 1);
    messageDelivered(source, data);
  } else if (verb === "quit") {
    // quit: the app is asked to quit, as Cmd+Q does; beforeunload can keep it open.
    requestQuit();
  } else if (verb === "resize") {
    // resize <width> <height>: the window changes size, as a drag of its corner does.
    const parts = arg.split(" ");
    viewport.w = Number(parts[0]);
    viewport.h = Number(parts[1]);
    // Layout notices the new size itself (layoutRoot), as it does for any other change to it.
    dirty.layout = true;
    markFullPaint();
    windowResized();
  } else if (verb === "layout") {
    // layout incremental|full|verify: turns incremental layout on, off, or on with every frame
    // checked against a full layout (see layout/incremental.ts).
    setIncrementalLayout(arg === "incremental" || arg === "verify", arg === "verify");
    dirty.layout = true;
  } else if (verb === "print") {
    // Prints an element's value (inputs) or text content, for assertions in tests.
    const el = document.querySelector(arg);
    console.log(el instanceof HTMLInputElement ? el.value : el !== null ? el.textContent : "<none>");
  } else if (verb !== "") {
    console.error(`native: unknown step '${step}' (use click, hover, contextmenu, drag, dropfiles, type, key, keydown, keyrepeat, keyup, compose, commit, cancelcompose, wheel, print, scrolltop, scrollleft, frame, resize, layout, menu, menuclick, focus, blur, hide, show, title, message, quit, wait, snapshotnow, snapshotcomposited, paintstats)`);
    process.exit(1);
  }
  frame();
}

/**
 * Waits for the microtask queue to run and its work to paint. A renderer that batches updates
 * (in a resolved promise, as Preact and Solid do) commits them there, so a step's effect is on
 * screen before the next step, or the snapshot, looks at it.
 */
function flushMicrotasks(): Promise<void> {
  return new Promise<void>((resolve) => setTimeout(() => resolve(), 0));
}

async function runSteps(): Promise<void> {
  // Headless time starts at zero; `frame <ms>` moves it, so runs are deterministic.
  setClock(0);
  frame();
  dispatchLoad();
  const steps = process.env.NATIVE_STEPS;
  if (steps === undefined) return;
  for (const s of steps.split("|")) {
    const step = s.trim();
    // `wait <ms>` lets the run's own timers, network requests and promise work finish before the
    // next step (or the snapshot); the other steps are instantaneous.
    if (step.startsWith("wait ")) {
      const ms = Number(step.slice(5).trim());
      await new Promise<void>((resolve) => setTimeout(() => resolve(), isNaN(ms) ? 0 : ms));
      frame();
      continue;
    }
    // A script that throws in the step is reported like one that throws in a window's event,
    // and the run goes on to the next step.
    try {
      runStep(step);
    } catch (e) {
      reportUncaughtError(e);
    }
    await flushMicrotasks();
    frame();
    drainHostEvents();
    frame();
  }
}

/** The device scale a headless snapshot draws at: 2, as a Retina display's snapshot would. */
const SNAPSHOT_SCALE = 2;

/**
 * Waits for every image the page asked for to finish decoding, and for the loads that wait on
 * them: the host makes the pixels on its own threads, and a snapshot is the page as it settles,
 * with every picture decoded and its load handler run, as a browser paints it.
 */
async function settleImages(): Promise<void> {
  for (;;) {
    hostImagesSettled();
    pumpImages();
    if (!imagesDecoding()) return;
    await flushMicrotasks();
  }
}

async function snapshot(path: string): Promise<void> {
  await runSteps();
  // The snapshot reads the display list: paint the page as the steps left it, so the pixels are
  // this page's even where the frame since the last step painted nothing. This paint also loads
  // any picture the steps never drew, which the host decodes on its threads: wait for those
  // decodes (their load handlers run now, and may change the page), then paint again so the
  // snapshot is the page as it settles.
  paintPage();
  await settleImages();
  await flushMicrotasks();
  paintPage();
  // The flat snapshot is the reference, so it is written first; a run may ask for the composited
  // one beside it, to compare them.
  let ok = 1;
  if (path !== "") ok = hostSnapshot(path, viewport.w, viewport.h, SNAPSHOT_SCALE);
  const composited = process.env.NATIVE_SNAPSHOT_COMPOSITED;
  if (ok === 1 && composited !== undefined && composited !== "") {
    ok = hostSnapshotComposited(composited, viewport.w, viewport.h, SNAPSHOT_SCALE);
  }
  process.exit(ok === 1 ? 0 : 1);
}

export function run(): void {
  // The page's menu markup becomes the window's menu bar before anything is shown.
  installApplicationMenu();
  // Vector content rasterizes at the scale the snapshot draws at, so it lands on whole device
  // pixels instead of being upscaled with the rest of the frame.
  setSnapshotScale(SNAPSHOT_SCALE);
  const snap = process.env.NATIVE_SNAPSHOT;
  const composited = process.env.NATIVE_SNAPSHOT_COMPOSITED;
  const wantsSnapshot = (snap !== undefined && snap !== "") || (composited !== undefined && composited !== "");
  const headless = wantsSnapshot || process.env.NATIVE_STEPS !== undefined;
  if (headless) {
    publishTitlebarArea(config.windowOptions, config.width, false);
    // The run has no window to open: its frame is the page's size, at the screen's corner.
    hostWindowSetFrame(0, 0, config.width, config.height);
  }
  if (wantsSnapshot) {
    // Let module-level user code and its timers settle first.
    setTimeout(() => snapshot(snap === undefined ? "" : snap), 0);
    return;
  }
  if (process.env.NATIVE_STEPS !== undefined) {
    // Steps without a snapshot: drive the page headlessly to the last step and then stop, rather
    // than leaving a window up with nothing left to do. Exit status 0 means every step ran.
    setTimeout(() => {
      runSteps().then(() => process.exit(0));
    }, 0);
    return;
  }
  hostOpen(config.width, config.height, config.title, config.windowOptions);
  viewport.w = hostViewWidth();
  viewport.h = hostViewHeight();
  publishTitlebarArea(config.windowOptions, viewport.w, true);
  setClock(performance.now());
  frame();
  // Every script has run by now, and the first layout is behind the page: DOMContentLoaded and
  // load fire, as a browser's do once the page is complete.
  dispatchLoad();
  setTimeout(tick, 0);
}
