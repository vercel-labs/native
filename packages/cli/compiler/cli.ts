#!/usr/bin/env node
// native: compile an HTML/CSS/TS app into a native executable via scriptc.
//
//   native build <app-dir | index.html> [-o out] [--release]
//   native run   <app-dir | index.html> [--release]
//   native dev   <app-dir | index.html> [-o out] [--compiled]
//   native check <app-dir | index.html>

import { build, color, compileFrontEnd, htmlPathOf } from "./build.ts";
import { packageLinux } from "./package-linux.ts";
import { spawnSync } from "node:child_process";

function usage(): never {
  console.error("usage: native <build|run|dev|check> <app-dir | index.html> [-o out] [--release] [--inspect[=port]] [--compiled]");
  process.exit(2);
}

// ---------------------------------------------------------------------------

const args = process.argv.slice(2);
const cmd = args[0];
if (cmd === "wpt") {
  const { main } = await import("./wpt.ts");
  await main(args.slice(1));
  process.exit(process.exitCode ?? 0);
}
const input = args[1];
if (!cmd || !input) usage();
const oi = args.indexOf("-o");
const out = oi >= 0 ? args[oi + 1] ?? usage() : null;
const release = args.includes("--release");
// `--compiled` makes `native dev` rebuild and relaunch the executable on every script edit, as
// builds always did, instead of rerunning the scripts in the dev host's island.
const compiled = args.includes("--compiled");
// `--inspect` starts the dev inspector on 9229; `--inspect=<port>` chooses the port.
const inspectArg = args.find((arg) => arg === "--inspect" || arg.startsWith("--inspect="));
let inspectPort: number | null = null;
if (inspectArg !== undefined) {
  const text = inspectArg.includes("=") ? inspectArg.slice(inspectArg.indexOf("=") + 1) : "9229";
  const port = Number(text);
  if (!Number.isInteger(port) || port < 0 || port > 65535) usage();
  inspectPort = port;
}

try {
  // A Linux release packages the bundle a build writes: a .deb and an AppImage beside the
  // executable, each with a .desktop entry and the app's icon. macOS release builds are their
  // own path inside the build, so they aren't packaged here.
  if (release && process.platform !== "darwin" && (cmd === "build" || cmd === "run")) {
    const result = await build(input, out);
    packageLinux(htmlPathOf(input), result);
    if (cmd === "run") {
      const r = spawnSync(result.output, [], { stdio: "inherit" });
      process.exit(r.status ?? 1);
    }
    process.exit(0);
  }
  if (release && (cmd === "dev" || cmd === "check")) {
    console.error(`native: --release is for build and run, not ${cmd}`);
    process.exit(2);
  }
  if (cmd === "build") {
    await build(input, out, false, release);
  } else if (cmd === "run") {
    const exe = (await build(input, out, false, release)).output;
    const r = spawnSync(exe, [], { stdio: "inherit" });
    process.exit(r.status ?? 1);
  } else if (cmd === "dev") {
    const { dev } = await import("./dev.ts");
    await dev(input, out, inspectPort, compiled);
  } else if (cmd === "check") {
    // The same front end a build compiles, so what it reports is what the build would do: the
    // page's scripts' imports included, since their tags and classes count as possible.
    const { app, diags } = compileFrontEnd(input);
    if (diags.list.length) console.error(diags.format(color));
    // The summary counts what was printed: a collapsed warning is one warning on screen.
    const shown = diags.collapsed();
    const errors = shown.filter((d) => d.severity === "error").length;
    const s = app.stats;
    console.error(`native: ${s.elements} nodes, ${s.rules} rules, ${errors} errors, ${shown.length - errors} warnings/notes`);
    process.exit(diags.errorCount > 0 ? 1 : 0);
  } else {
    usage();
  }
} catch (err) {
  // A failed build or a missing file is one line on stderr, not a stack trace. The dev command
  // catches its own build errors and keeps watching.
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
}
