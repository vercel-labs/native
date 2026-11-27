// The native event loop.

import { HTMLInputElement, Event, dirty, invalidatePaint, markFullPaint, markPaintDirty, focusState, editingHostFor } from "../dom.ts";
import { layoutEpoch } from "../invalidation.ts";
import { viewport } from "../layout.ts";
import { caret } from "../paint.ts";
import { hostEventPhase, hostGlWindow, hostRefreshInterval, hostPoll, hostUntilRefresh, hostEventX, hostEventY, hostViewWidth, hostViewHeight, hostEventDY, hostEventDX, hostEventClicks, EV_NONE, EV_QUIT, EV_DOWN, EV_UP, EV_MOVE, EV_RESIZE, EV_LEAVE, EV_KEY, EV_WHEEL, EV_SETTINGS, EV_AXFOCUS, EV_AXSELRANGE, EV_DROP, EV_CONTEXT, EV_WINDOWMOVE, EV_FULLSCREEN, EV_FOCUS, EV_BLUR, EV_VISIBILITY, EV_MESSAGE, EV_APPQUIT, EV_WINDOWCLOSED, EV_COMPOSE, EV_AXACTION, EV_KEYUP, EV_IMAGE, hostEventMods, hostAxFocus, hostAxSelection, hostWindowClosed, hostWindowHidden, hostMessageSource, hostMessageData, hostMenuItem, EV_MENU } from "../host.ts";
import { pumpImages } from "../images.ts";
import { messageDelivered, openedWindowClosed, pollSystemSettings, reportUncaughtError, requestQuit, runFrameCallbacks, windowBlurred, windowFocused, windowMoved, windowResized } from "../window.ts";
import { setClock } from "../animation.ts";
import { rasterScale } from "../device.ts";
import { usesDisplaySchedule } from "./refresh.ts";
import { hostComposition, hostKey, hostKeyUp } from "./keyboard.ts";
import { config, frame } from "./mount.ts";
import { publishTitlebarArea } from "./titlebar.ts";
import { hitAt, pointerContext, pointerDown, pointerMove, pointerUp, updateHover } from "./pointer.ts";
import { dropFilesAt, hostDropFiles } from "./dnd.ts";
import { fadeScrollbars, wheel } from "./scroll.ts";
import { focusAxNode, selectAxRange } from "../ax-tree.ts";
import { performAxAction } from "./ax-actions.ts";
import { setDocumentVisibility, windowFullscreenChanged } from "../dom.ts";
import { applicationMenuItemChosen } from "../menus.ts";

// ---------------------------------------------------------------------------
// Event loop

/** Runs one host event; false when the app should end (the window closed, or a quit). */
export function handleHostEvent(ev: number): boolean {
  if (ev === EV_QUIT) return false;
  if (ev === EV_DOWN) pointerDown(hostEventX(), hostEventY(), hostEventClicks(), hostEventMods());
  else if (ev === EV_UP) pointerUp(hostEventX(), hostEventY(), hostEventClicks(), hostEventMods());
  else if (ev === EV_MOVE) pointerMove(hostEventX(), hostEventY(), hostEventMods());
  else if (ev === EV_LEAVE) updateHover(null);
  else if (ev === EV_KEY) hostKey();
  else if (ev === EV_KEYUP) hostKeyUp();
  else if (ev === EV_COMPOSE) hostComposition();
  else if (ev === EV_CONTEXT) pointerContext(hostEventX(), hostEventY(), hostEventMods());
  else if (ev === EV_MENU) applicationMenuItemChosen(hostMenuItem());
  else if (ev === EV_WINDOWMOVE) windowMoved();
  else if (ev === EV_FULLSCREEN) windowFullscreenChanged();
  else if (ev === EV_FOCUS) windowFocused();
  else if (ev === EV_BLUR) windowBlurred();
  else if (ev === EV_VISIBILITY) setDocumentVisibility(hostWindowHidden() !== 0);
  else if (ev === EV_MESSAGE) deliverMessage();
  else if (ev === EV_APPQUIT) requestQuit();
  else if (ev === EV_WINDOWCLOSED) openedWindowClosed(hostWindowClosed());
  else if (ev === EV_WHEEL) wheel(hostEventX(), hostEventY(), hostEventDY(), hostEventDX(), hostEventPhase());
  // An image's pixels are ready: the loads waiting for it settle, and the page repaints with it.
  else if (ev === EV_IMAGE) pumpImages();
  // A drag from outside the app was dropped on the window: the page hears dragenter, dragover and,
  // when it takes it, drop, with the files the drag carried.
  else if (ev === EV_DROP) {
    const x = hostEventX(), y = hostEventY();
    dropFilesAt(x, y, hitAt(x, y), hostDropFiles(), hostEventMods());
  }
  else if (ev === EV_AXFOCUS) focusAxNode(hostAxFocus());
  else if (ev === EV_AXSELRANGE) selectAxRange(hostAxSelection(), hostEventX(), hostEventY());
  else if (ev === EV_AXACTION) performAxAction();
  else if (ev === EV_SETTINGS) {
    // The appearance or an accessibility display option changed: restyle and tell matchMedia.
    pollSystemSettings();
  }
  else if (ev === EV_RESIZE) {
    viewport.w = hostViewWidth();
    viewport.h = hostViewHeight();
    publishTitlebarArea(config.windowOptions, viewport.w, true);
    dirty.layout = true;
    // Viewport units and the fixed boxes the viewport contains change with it.
    layoutEpoch.n++;
    markFullPaint();
    windowResized();
  }
  return true;
}

/** A message's body is handed over inside hostMessageData's call; read it, then deliver it. */
function deliverMessage(): void {
  let text = "";
  hostMessageData((data: string) => {
    text = data;
  });
  messageDelivered(hostMessageSource(), text);
}

const blink = { last: 0 };

/** A rate asked for by hand, for a test or a display the host has not reported yet. Unset or
 *  unreadable reads as none. */
const forcedHz = Number(process.env.NATIVE_REFRESH_HZ) || 0;

/** NATIVE_FRAME_TIMER keeps every window on the free-running timer, for a comparison or fallback. */
const frameTimerOnly = process.env.NATIVE_FRAME_TIMER !== undefined &&
  process.env.NATIVE_FRAME_TIMER !== "" && process.env.NATIVE_FRAME_TIMER !== "0";

/** The frame's period in milliseconds: the display's own, from its display link, so a panel that
 *  refreshes at 120 Hz gets 120 frames a second. Sixty is the answer when the host has no display
 *  to ask. */
function framePeriodMs(): number {
  if (forcedHz > 0) return 1000 / forcedHz;
  const ms = hostRefreshInterval();
  return ms > 0 ? ms : 1000 / 60;
}
/** The clock reading the next frame is due at. */
let nextFrameAt = 0;

export function tick(): void {
  // A script that throws in an event, a timer or an animation callback is reported and the page
  // keeps running, as in a browser: the exception doesn't end the app's event loop. The next
  // tick is scheduled whatever happened in this one.
  try {
    tickOnce();
  } catch (e) {
    reportUncaughtError(e);
  }
  setTimeout(tick, 0);
}

/** The scale the last frame drew at, so a scale that changes is reported to the page. */
let lastScale = -1;

function tickOnce(): void {
  // A window's backing scale can become known only after its page's first script has run, since a
  // script sizes a canvas from devicePixelRatio before the window is on a screen. The page hears a
  // resize when the ratio it would read changes, as it does when a browser's zoom does.
  const scale = rasterScale();
  if (scale !== lastScale) {
    lastScale = scale;
    windowResized();
  }
  // Block until this frame is due, then drain the events that arrived meanwhile; yielding back to
  // the scriptc event loop between ticks keeps timers and promises in user code running. Waiting
  // a fixed 16 ms before every frame put the period at the frame's work plus that wait, rather
  // than at the display's own rate.
  const period = framePeriodMs();
  const started = performance.now();
  if (nextFrameAt === 0 || started - nextFrameAt > 4 * period) nextFrameAt = started;
  // Drain the native queue until the frame is due. A poll returns as soon as an event arrives, and
  // a frame run then would land inside the display period before its own: the events are handled,
  // then the loop waits again for what is left of the period.
  for (;;) {
    const now = performance.now();
    const left = (nextFrameAt - now) / 1000;
    let ev = hostPoll(left > 0 ? left : 0);
    if (ev === EV_NONE) {
      if (left <= 0) break;
      continue;
    }
    while (ev !== EV_NONE) {
      if (!handleHostEvent(ev)) process.exit(0);
      if (ev === EV_KEY || ev === EV_DOWN) blink.last = Date.now();
      ev = hostPoll(0);
    }
    if (performance.now() >= nextFrameAt) break;
  }
  const focused = focusState.el;
  if (focused instanceof HTMLInputElement || (focused !== null && editingHostFor(focused) !== null)) {
    const visible = Math.floor((Date.now() - blink.last) / 530) % 2 === 0;
    if (visible !== caret.visible) {
      caret.visible = visible;
      // The caret is inside the focused field or editing host: repaint that box, not the page.
      markPaintDirty(focused);
    }
  }
  fadeScrollbars();
  // Animation callbacks run with this frame's timestamp, before the page is laid out and
  // painted. The clock moves with them, so transitions and animations share the timestamp.
  const time = performance.now();
  setClock(time);
  runFrameCallbacks(time);
  frame();
  // A window that doesn't present through GL starts its next frame at the display's next refresh
  // rather than one free-running period from this one: a timer that drifts slightly behind the
  // display every frame eventually presents just after a refresh and misses it, which shows up as
  // an occasional double-length interval. A GL window keeps the old schedule: its present already
  // waits for the display, and adding a wait after that block costs a whole period.
  const untilNext = usesDisplaySchedule(forcedHz, frameTimerOnly, hostGlWindow()) ? hostUntilRefresh() : 0;
  if (untilNext > 0) {
    nextFrameAt = performance.now() + untilNext;
  } else {
    nextFrameAt += period;
    if (nextFrameAt < time) nextFrameAt = time;
  }
}
