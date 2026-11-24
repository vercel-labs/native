// The sources a dev build compiles, mapped back to the files the developer wrote. A runtime
// stack frame names a copy in the build directory; this table says which line of the app that
// copy's first line is, so an exception can point at the app's own file and line.

import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import type { CompiledApp } from "./compile.ts";

/** The file a dev build's runtime reads the table from. */
export const DEV_SOURCES = "sources.json";

export function devSourcesPath(appDir: string): string {
  return join(appDir, ".native", DEV_SOURCES);
}

/** Where one module of a dev build was written. */
export interface DevSourceOrigin {
  /** The file the module's text came from. */
  file: string;
  /** The line of `file` that the module's first line is. */
  line: number;
  /** The module holds several sources: a classic page's scripts, or its handler attributes. */
  bundled?: boolean;
}

/** The compiled modules of a dev build, by the absolute path a stack frame names. */
export interface DevSources {
  appDir: string;
  /** The page, whose inline scripts and handlers the table maps into. */
  entry: string;
  /** The native checkout the runtime itself was compiled from, whose frames a report leaves out. */
  sdk: string;
  files: { [compiled: string]: DevSourceOrigin };
}

/** What a dev build needs to map its compiled modules back to the app's files. */
export interface DevSourceInput {
  appDir: string;
  htmlPath: string;
  /** The page's compiled front end: its scripts and handler attributes. */
  app: CompiledApp;
  /** The native checkout, whose runtime and shared sources the app's frames hide. */
  sdk: string;
  /** The directory the app's sources were copied into (`.native/src`). */
  srcOut: string;
  /** The app's own source files, as they were copied. */
  appFiles: Iterable<string>;
  /** A vendored dependency's source path to its copy in the build directory. */
  vendored: Map<string, string>;
  /** The module inline scripts, and the line of the page each one's text starts on. */
  inlineFiles: { file: string; line: number }[];
  /** The module a classic page's scripts share, when the page has any. */
  classicBundle: string | null;
  /** The module holding the page's handler attributes, when it has its own file. */
  handlerFile: string | null;
  /** The line of the page its first classic script is on, and its first handler attribute. */
  firstClassicLine: number;
  firstHandlerLine: number;
}

/** The table a dev build's runtime maps its stack frames with. */
export function devSources(input: DevSourceInput): DevSources {
  const files: { [compiled: string]: DevSourceOrigin } = {};
  for (const source of input.appFiles) {
    files[join(input.srcOut, relative(input.appDir, source))] = { file: source, line: 1 };
  }
  for (const [source, copy] of input.vendored) files[copy] = { file: source, line: 1 };
  for (const inline of input.inlineFiles) {
    files[inline.file] = { file: input.htmlPath, line: inline.line };
  }
  if (input.classicBundle !== null) {
    files[input.classicBundle] = { file: input.htmlPath, line: input.firstClassicLine, bundled: true };
  }
  if (input.handlerFile !== null) {
    files[input.handlerFile] = { file: input.htmlPath, line: input.firstHandlerLine, bundled: true };
  }
  return { appDir: input.appDir, entry: input.htmlPath, sdk: input.sdk, files };
}

/** Writes the table the dev executable's runtime reads, replacing it atomically. */
export function writeDevSources(input: DevSourceInput): string {
  const file = devSourcesPath(input.appDir);
  mkdirSync(dirname(file), { recursive: true });
  const tmp = file + ".tmp";
  writeFileSync(tmp, JSON.stringify(devSources(input)));
  renameSync(tmp, file);
  return file;
}
