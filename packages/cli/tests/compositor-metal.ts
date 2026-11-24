// The Metal backend's own test: it compiles tests/compositor-metal.m with the compositor core and
// runs it, checking the same picture the software backend's test draws.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { prepareMetalShaders } from "../compiler/native-host.ts";

if (process.platform !== "darwin") {
  console.log("ok   the Metal backend is macOS's (skipped)");
  process.exit(0);
}

const dir = mkdtempSync(join(tmpdir(), "native-compositor-metal-"));
const shaders = prepareMetalShaders("host", dir);
if (shaders !== null && !shaders.precompiled) {
  console.log(`note the compositor's shaders are not precompiled: ${shaders.note}`);
}
const exe = join(dir, "compositor-metal");
const build = spawnSync("clang", [
  "-fobjc-arc", "-O2", "-Wall",
  "-I", "host/compositor",
  "-I", dir,
  "-o", exe,
  "tests/compositor-metal.m",
  "host/compositor/compositor.c",
  "host/compositor/metal.m",
  "-framework", "Metal",
  "-framework", "QuartzCore",
  "-framework", "Foundation",
], { stdio: "inherit" });
if (build.status !== 0) {
  console.error("native: could not build the Metal backend test");
  process.exit(1);
}

const run = spawnSync(exe, [], { stdio: "inherit" });
process.exit(run.status === 0 ? 0 : 1);
