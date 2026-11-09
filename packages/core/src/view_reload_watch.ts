#!/usr/bin/env node
// Watch a TypeScript app's markup while `native dev` runs it, and hand the
// running app each change as a view update (see view_reload.ts).
//
//   view_reload_watch.ts --src <app src dir> --dir <update dir>
//
// The baseline is the markup as it stands when the watcher starts, before
// the build reads it: while the sources match it, the app serves its
// compiled views. The watcher waits for the app to announce its session and
// contract in <dir>/build.json, then writes <dir>/view.update whenever the
// markup changes. It exits when its stdin closes (the CLI that started it
// exited).

import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { appViewSources, type AppViewSources } from "./view_sources.ts";
import {
  compileViewReload, encodeViewDiagnostic, encodeViewUpdate, readViewBuild, viewShapeOf, viewSourcesDigest,
  viewUpdateFile, viewUpdateKind, writeAtomically, type ViewBuild, type ViewShape,
} from "./view_reload.ts";

export interface ViewReloadWatch {
  /** Check the sources and the app session once; true when an update was written. */
  poll(): boolean;
}

export function watchViews(srcDir: string, dir: string, srcLabel = "src"): ViewReloadWatch {
  const baseline = appViewSources(srcDir);
  const baselineDigest = viewSourcesDigest(baseline);
  let build: ViewBuild | null = null;
  let shape: ViewShape | null = null;
  let sent: string | null = null;
  return {
    poll(): boolean {
      const announced = readViewBuild(dir);
      if (announced === null) return false;
      if (build === null || announced.session !== build.session) {
        build = announced;
        shape = viewShapeOf(baseline, build.contract);
        sent = null;
      }
      const current = appViewSources(srcDir);
      const digest = viewSourcesDigest(current);
      // A fresh session starts on its compiled views; say nothing until the
      // markup differs from what the build compiled.
      if (sent === null && digest === baselineDigest) { sent = digest; return false; }
      if (digest === sent) return false;
      shape ??= viewShapeOf(current, build.contract);
      let kind: number, body: Uint8Array;
      if (digest === baselineDigest) {
        kind = viewUpdateKind.compiled; body = new Uint8Array(0);
      } else {
        // Without a shape the markup does not compile, so this is its diagnostic.
        const result = compileViewReload(current, srcDir, build.contract, shape ?? { windows: [], virtual: false }, srcLabel);
        if (result.kind === "program") { kind = viewUpdateKind.program; body = result.program; }
        else { kind = viewUpdateKind.diagnostic; body = encodeViewDiagnostic(result.diagnostic); }
      }
      writeAtomically(path.join(dir, viewUpdateFile), encodeViewUpdate(build.session, kind, body));
      sent = digest;
      return true;
    },
  };
}

function main(argv: readonly string[]): number {
  let srcDir: string | null = null, dir: string | null = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--src") srcDir = argv[++i] ?? null;
    else if (argv[i] === "--dir") dir = argv[++i] ?? null;
    else {
      console.error(`view_reload_watch: unknown argument ${argv[i]}`);
      return 2;
    }
  }
  if (!srcDir || !dir) {
    console.error("usage: view_reload_watch.ts --src <app src dir> --dir <update dir>");
    return 2;
  }
  fs.mkdirSync(dir, { recursive: true });
  const watch = watchViews(srcDir, dir, path.relative(process.cwd(), srcDir).split(path.sep).join("/") || ".");
  const timer = setInterval(() => {
    try {
      watch.poll();
    } catch (err) {
      console.error(`native dev: markup reload stopped: ${err instanceof Error ? err.message : String(err)}`);
      process.exit(1);
    }
  }, 150);
  process.stdin.on("end", () => { clearInterval(timer); process.exit(0); });
  process.stdin.on("error", () => { clearInterval(timer); process.exit(0); });
  process.stdin.resume();
  return 0;
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  process.exitCode = main(process.argv.slice(2));
}
