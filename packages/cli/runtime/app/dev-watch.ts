// The file side of a dev build's runtime: the recompiled tables the dev command leaves behind,
// and the token it writes to ask for a relaunch. Kept apart from dev.ts, which needs a mounted
// DOM, so a test can run this on its own (tests/dev-watch.ts).

import { existsSync, readFileSync } from "node:fs";
import type { AppTables } from "./mount.ts";

/** A dev build's files and what it last read from them. */
export interface DevFiles {
  /** The tables file, and the text last applied from it. */
  dataFile: string;
  data: string;
  /** The restart token's file, and the token last seen in it. */
  ctlFile: string;
  ctl: string;
  /** The scripts token's file, and the token last seen in it: a new one means the app's scripts
   *  were rebundled, and the island runs the new bundle in the page that is already open. */
  scriptsFile: string;
  scripts: string;
  /** What the last background coverage check found, and the text last applied from it. */
  findingsFile: string;
  findings: string;
}

/** How often the files are checked. They are small, and the app already runs on a timer, so
 *  this is cheaper than a platform watch and behaves the same wherever a dev build runs. */
const POLL_MS = 50;

/**
 * The tables a dev build reads: the file the dev command recompiled, or the tables the
 * executable was built with. Both are plain data, so the parsed file takes the same type.
 */
export function readTables(files: DevFiles, compiled: AppTables): AppTables {
  if (files.dataFile === "" || !existsSync(files.dataFile)) return compiled;
  const text = readFileSync(files.dataFile, "utf8");
  files.data = text;
  return JSON.parse(text) as AppTables;
}

/** The restart token the file already holds, if any: a relaunch leaves its token on disk. */
export function readToken(file: string): string {
  return file !== "" && existsSync(file) ? readFileSync(file, "utf8") : "";
}

/** Calls `onTables` when the tables change, `onRestart` when the restart token does,
 *  `onScripts` when the scripts token does, and `onFindings` when the coverage report does. */
export function watchFiles(files: DevFiles, onTables: () => void, onRestart: () => void,
  onScripts: () => void = () => {}, onFindings: () => void = () => {}): void {
  if (files.dataFile !== "") {
    const text = existsSync(files.dataFile) ? readFileSync(files.dataFile, "utf8") : "";
    if (text !== files.data) {
      files.data = text;
      if (text !== "") onTables();
    }
  }
  if (files.ctlFile !== "") {
    const token = readToken(files.ctlFile);
    if (token !== files.ctl) {
      files.ctl = token;
      onRestart();
    }
  }
  if (files.scriptsFile !== "") {
    const token = readToken(files.scriptsFile);
    if (token !== files.scripts) {
      files.scripts = token;
      if (token !== "") onScripts();
    }
  }
  if (files.findingsFile !== "") {
    const text = readToken(files.findingsFile);
    if (text !== files.findings) {
      files.findings = text;
      if (text !== "") onFindings();
    }
  }
  setTimeout(() => watchFiles(files, onTables, onRestart, onScripts, onFindings), POLL_MS);
}
