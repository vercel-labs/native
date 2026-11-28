// A reftest page's ready state: its scripts run, then its load events fire, then the page is given
// the event loop until it takes the `reftest-wait` class off the root element, as WPT's runner
// does before it takes the screenshot.

import { setClock } from "../animation.ts";
import { document } from "../dom.ts";
import { dispatchLoad, dispatchTestRendered, runFrameCallbacks, window } from "../window.ts";
import { frame } from "./mount.ts";

/** How long a page may hold the screenshot back, in ms. WPT's own runner waits five seconds. */
const WAIT_LIMIT = 5000;
/** How long a testharness page has to report its results. A page with dozens of tests, each with
 *  its own style work, reports well after the page itself settles; five seconds cut it off. */
const TESTS_LIMIT = 30000;
/** A guard against a page that reschedules a frame forever without ever clearing the class. */
const MAX_ROUNDS = 1000;

function nextTask(): Promise<void> {
  return new Promise<void>((resolve) => setTimeout(() => resolve(), 1));
}

/**
 * Fires the page's load events and then lets timers, promises and animation frames run, laying out
 * after each round, until the root element's `reftest-wait` class is gone. A page that never
 * removes it runs out of time: it returns false, and the page is reported as a failure rather than
 * compared, as WPT's own runner does when a reftest never becomes ready.
 */
export async function settlePage(): Promise<boolean> {
  const root = document.documentElement;
  // A load listener sees a laid-out page, as it does in a browser.
  frame();
  dispatchLoad();
  // One task and one frame even without reftest-wait: a task the page scheduled at load has run by
  // the time a browser paints, and its change is in the snapshot.
  setClock(performance.now());
  runFrameCallbacks(performance.now());
  frame();
  await nextTask();
  // A rendered frame has gone by, as WPT gives a page before it says this: a test that starts a
  // transition from the painted state depends on it. Then the page may remove reftest-wait.
  dispatchTestRendered();
  const deadline = Date.now() + WAIT_LIMIT;
  let rounds = 0;
  while (root.classList.contains("reftest-wait") && rounds < MAX_ROUNDS && Date.now() < deadline) {
    const t = performance.now();
    setClock(t);
    runFrameCallbacks(t);
    frame();
    await nextTask();
    rounds++;
  }
  // The final state's frame: the task that removed the class may also have changed the page.
  const last = performance.now();
  setClock(last);
  runFrameCallbacks(last);
  frame();
  return !root.classList.contains("reftest-wait");
}

/**
 * Waits for a testharness page's tests: fires the page's load events, then gives the event loop
 * time until the API leaves its outcome on `window.__nativeTestharness`, or five seconds pass.
 * Returns that JSON, or "" when the page never produced one.
 */
export async function settleTests(): Promise<string> {
  frame();
  dispatchLoad();
  runFrameCallbacks(performance.now());
  frame();
  await nextTask();
  const deadline = Date.now() + TESTS_LIMIT;
  while (Date.now() < deadline) {
    const result = (window as unknown as { __nativeTestharness?: string }).__nativeTestharness;
    if (result !== undefined) return result;
    runFrameCallbacks(performance.now());
    frame();
    await nextTask();
  }
  // A page that never reports is named by the tests it is still waiting on, when the harness can
  // say: a silent "no result" hides which promise never settled.
  const stuck = (window as unknown as { __nativePendingTests?: () => string }).__nativePendingTests;
  const waiting = typeof stuck === "function" ? stuck() : "";
  if (waiting !== "") return JSON.stringify({ status: 1, message: "tests still waiting: " + waiting, tests: [] });
  return "";
}
