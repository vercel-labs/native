// WPT support: evaluates check-layout-th.js expectations (data-expected-* attributes) against
// native's layout, without running testharness.js.

import { Element, document } from "./dom.ts";
import { offsetLeft, offsetTop } from "./layout.ts";

function check(el: Element, attr: string, actual: number, out: string[]): void {
  const v = el.getAttribute(attr);
  if (v === null) return;
  const expected = Number(v);
  // check-layout-th.js compares rounded integers for offsets and sizes.
  if (Math.round(actual) !== expected) {
    const name = el.id !== "" ? `#${el.id}` : el.className !== "" ? `.${el.className.split(" ").join(".")}` : el.localName;
    out.push(`${name} ${attr}: expected ${expected}, got ${Math.round(actual * 100) / 100}`);
  }
}

const UNSUPPORTED = ["data-expected-display", "data-expected-padding-top", "data-expected-padding-bottom",
  "data-expected-padding-left", "data-expected-padding-right", "data-expected-margin-top", "data-expected-margin-bottom",
  "data-expected-margin-left", "data-expected-margin-right", "data-total-x", "data-total-y"];

function walk(el: Element, out: string[], counted: number[]): void {
  {
    for (const a of UNSUPPORTED) if (el.hasAttribute(a)) out.push(`unsupported check ${a}`);
    const before = out.length;
    check(el, "data-expected-width", el.w, out);
    check(el, "data-expected-height", el.h, out);
    // offsetLeft/offsetTop, measured from the nearest positioned ancestor (or the
    // initial containing block when there is none).
    check(el, "data-offset-x", offsetLeft(el), out);
    check(el, "data-offset-y", offsetTop(el), out);
    check(el, "data-expected-client-width", el.clientWidth, out);
    check(el, "data-expected-client-height", el.clientHeight, out);
    check(el, "data-expected-scroll-width", el.scrollWidth, out);
    check(el, "data-expected-scroll-height", el.scrollHeight, out);
    for (const name of ["data-expected-width", "data-expected-height", "data-offset-x", "data-offset-y",
      "data-expected-client-width", "data-expected-client-height", "data-expected-scroll-width", "data-expected-scroll-height"]) {
      if (el.hasAttribute(name)) counted[0]++;
    }
    if (out.length > before) counted[1]++;
  }
  for (const c of el.kids) if (c instanceof Element) walk(c, out, counted);
}

/** Returns "PASS <n>" or "FAIL <reasons>"; "NONE" if the page has no expectations. */
export function checkLayout(): string {
  const out: string[] = [];
  const counted = [0, 0];
  walk(document.documentElement, out, counted);
  if (counted[0] === 0 && out.length === 0) return "NONE";
  if (out.length === 0) return `PASS ${counted[0]}`;
  return `FAIL ${out.slice(0, 6).join("; ")}`;
}
