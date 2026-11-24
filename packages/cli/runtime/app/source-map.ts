// Dev builds only: a runtime exception's stack names the build's copies of the app's modules,
// and this maps those frames back to the files the developer wrote, with their own line numbers.
// The compiler writes the table (see compiler/source-map.ts); mountDev installs the report.

import { existsSync, readFileSync } from "node:fs";
import { setExceptionText } from "../window.ts";

/** The table the compiler writes: a compiled module's path to where its text came from. */
interface DevSources {
  appDir: string;
  entry: string;
  sdk: string;
  files: { [compiled: string]: { file: string; line: number; bundled?: boolean } };
}

/** The table a dev build was started with, or null in a build that has none. */
let sources: DevSources | null = null;

/** Reads the table and makes every exception report use it. Returns false when there is none. */
export function loadSourceMap(file: string): boolean {
  if (file === "" || !existsSync(file)) return false;
  try {
    sources = JSON.parse(readFileSync(file, "utf8")) as DevSources;
  } catch {
    sources = null;
    return false;
  }
  setExceptionText(formatException);
  return true;
}

/**
 * Reads the table, and reports an exception that no script caught against the app's own files.
 * The event loop already catches the exceptions its ticks run (see app/loop.ts); this catches
 * what runs outside one, a module's top-level code or a callback a timer or promise called, and
 * leaves the app running as a browser does.
 */
export function installErrorReporting(file: string): void {
  if (!loadSourceMap(file)) return;
  process.on("uncaughtException", (e: unknown) => {
    console.error(formatException(e, "Uncaught"));
  });
}

/** A frame's function name and location, as scriptc writes them: `at name (file:line:col)`. */
interface Frame {
  before: string;
  location: string;
  after: string;
}

function parseFrame(line: string): Frame | null {
  const t = line.trim();
  if (!t.startsWith("at ")) return null;
  const rest = t.slice(3);
  const open = rest.lastIndexOf(" (");
  if (open >= 0 && rest.endsWith(")")) {
    return { before: rest.slice(0, open + 2), location: rest.slice(open + 2, -1), after: ")" };
  }
  return { before: "", location: rest, after: "" };
}

/** A location's file, line and column, when it has them. A stripped build keeps only the file. */
function splitLocation(location: string): { file: string; line: number; column: number } | null {
  const withColumn = /^(.*):(\d+):(\d+)$/.exec(location);
  if (withColumn !== null) return { file: withColumn[1], line: Number(withColumn[2]), column: Number(withColumn[3]) };
  const withLine = /^(.*):(\d+)$/.exec(location);
  if (withLine !== null) return { file: withLine[1], line: Number(withLine[2]), column: 0 };
  return null;
}

/** The path a frame names, made absolute: scriptc writes the paths it compiled as they were. */
function absolute(file: string, appDir: string): string {
  let p = file;
  if (p.startsWith("file://")) p = p.slice("file://".length);
  return p.startsWith("/") ? p : appDir + "/" + p;
}

/** Whether a path belongs to the SDK itself, whose frames a report leaves out. */
function isSdk(path: string, sdk: string): boolean {
  return sdk !== "" && (path === sdk || path.startsWith(sdk + "/"));
}

/** Maps one frame's location back to the app, or null when the frame is an SDK one. */
function mapLocation(location: string): string | null {
  if (sources === null) return location;
  const at = splitLocation(location);
  if (at === null) return location;
  const path = absolute(at.file, sources.appDir);
  const origin = sources.files[path];
  if (origin !== undefined) {
    if (origin.bundled === true) {
      const kind = path.endsWith(".handlers.js") ? "event handler" : "classic script";
      return `${origin.file} (${kind})`;
    }
    return `${origin.file}:${origin.line + at.line - 1}:${at.column}`;
  }
  if (isSdk(path, sources.sdk)) return null;
  // The build's own generated modules (entry, boot, the dev tables) have no source to name.
  if (path.startsWith(sources.appDir + "/.native/")) return null;
  return location;
}

/** An exception as a browser's console prints it: a heading, and the frames in the app. */
export function formatException(e: unknown, heading: string): string {
  let name = "Error";
  let message = "";
  let stack = "";
  if (e instanceof Error) {
    name = e.name === "" ? "Error" : e.name;
    message = e.message;
    const s = e.stack;
    if (typeof s === "string") stack = s;
  } else {
    message = String(e);
  }
  const first = `${heading} ${name}${message === "" ? "" : ": " + message}`;
  if (stack === "") return first;
  const mapped: string[] = [];
  const unfiltered: string[] = [];
  for (const line of stack.split("\n")) {
    if (line.trim() === "" || /^\S/.test(line)) continue;
    const frame = parseFrame(line);
    if (frame === null) continue;
    unfiltered.push(line);
    const location = mapLocation(frame.location);
    if (location === null) continue;
    mapped.push(`    at ${frame.before}${location}${frame.after}`);
  }
  // An exception raised only inside the SDK still has a stack; a report with no app frame would
  // hide where it came from, so the SDK's frames stay when nothing else does.
  const frames = mapped.length > 0 ? mapped : unfiltered;
  return frames.length === 0 ? first : first + "\n" + frames.join("\n");
}
