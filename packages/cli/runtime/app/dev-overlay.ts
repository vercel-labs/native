// The coverage panel `native dev` draws over the page: what `scriptc coverage` reports about the
// app's scripts, from the file the dev command writes after each background check. The island
// runs the app as Node does, so a release build's refusals and type errors do not stop dev; this
// panel is the part of that report the developer sees without leaving the window. It takes no
// input and disappears when a report has no findings.

import { HTMLElement, document } from "../dom.ts";

const PANEL_ID = "native-dev-coverage";
/** How many findings the panel lists; the rest are counted. */
const SHOWN = 8;

interface Report {
  summary?: string;
  findings?: { code: string; severity: string; file: string; line: number; column: number; message: string }[];
}

function panel(): HTMLElement {
  const existing = document.getElementById(PANEL_ID);
  if (existing !== null) return existing as HTMLElement;
  const element = document.createElement("div");
  element.id = PANEL_ID;
  const style = element.style;
  style.position = "fixed";
  style.left = "12px";
  style.bottom = "12px";
  style.maxWidth = "70%";
  style.zIndex = "2147483647";
  style.padding = "8px 10px";
  style.borderRadius = "8px";
  style.background = "rgba(20, 22, 28, 0.92)";
  style.color = "#f2f2f2";
  style.fontFamily = "ui-monospace, Menlo, monospace";
  style.fontSize = "11px";
  style.lineHeight = "15px";
  style.whiteSpace = "pre-wrap";
  style.pointerEvents = "none";
  document.body.appendChild(element);
  return element;
}

/** Shows the report the dev command last wrote; an empty report removes the panel. */
export function showCoverage(text: string): void {
  let report: Report;
  try {
    report = JSON.parse(text) as Report;
  } catch {
    return;
  }
  const findings = report.findings ?? [];
  if (findings.length === 0) {
    const existing = document.getElementById(PANEL_ID);
    if (existing !== null) existing.remove();
    return;
  }
  const lines = [`coverage · ${report.summary ?? ""}`.trim()];
  for (const finding of findings.slice(0, SHOWN)) {
    const where = finding.file === "" ? "" : `${finding.file}:${finding.line}:${finding.column} `;
    lines.push(`${where}${finding.code} ${finding.message}`);
  }
  if (findings.length > SHOWN) lines.push(`… and ${findings.length - SHOWN} more (native dev's output has all of them)`);
  panel().textContent = lines.join("\n");
}
